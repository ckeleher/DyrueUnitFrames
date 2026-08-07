-- Elements/Text.lua
--
-- SPEC §4.3 / PLAN task 4.8.
--
-- An arbitrary number of text elements per frame, each with its own format
-- string, anchor, font and color policy. Formats are compiled once by
-- Systems/Tags; this element does anchoring, fonts, color resolution and
-- per-element string caching.
--
-- The caching matters more than it looks: SetText on an unchanged string still
-- causes layout work, and a health bar ticking during a raid fight would
-- otherwise re-lay-out four font strings per frame per tick for no reason.

local ADDON, ns = ...
local L = ns.L
local Tags = ns.Tags
local Colors = ns.Colors
local ColorRules = ns.ColorRules
local Compat = ns.Compat

local element = {
	order = 60,
	configKey = "texts",
	events = {},
	globalEvents = {},
}

-- Color modes that have to be recomputed whenever the unit's state moves,
-- even if the text itself did not change.
local DYNAMIC_COLOR = {
	rules = true,
	gradient = true,
	class = true,
	reaction = true,
	difficulty = true,
}

local DYNAMIC_COLOR_EVENTS = {
	UNIT_HEALTH = true,
	UNIT_MAXHEALTH = true,
	UNIT_POWER_UPDATE = true,
	UNIT_MAXPOWER = true,
	UNIT_LEVEL = true,
	UNIT_FACTION = true,
	UNIT_CONNECTION = true,
}

--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	return type(cfg) == "table" and #cfg > 0
end

--- The union of every compiled format's events, plus color dependencies.
-- Declared dynamically because it depends entirely on what the user typed.
function element.GetEvents(frame, cfg)
	local events, globalEvents = {}, {}
	if type(cfg) ~= "table" then return events, globalEvents end

	local anyDynamicColor = false
	for i = 1, #cfg do
		local text = cfg[i]
		if text and text.enabled ~= false then
			local compiled = Tags:Compile(text.format)
			for event in pairs(compiled.events) do events[event] = true end
			for event in pairs(compiled.globalEvents) do globalEvents[event] = true end
			if DYNAMIC_COLOR[text.colorMode or "static"] then anyDynamicColor = true end
		end
	end

	if anyDynamicColor then
		for event in pairs(DYNAMIC_COLOR_EVENTS) do events[event] = true end
	end

	return events, globalEvents
end

function element.Build(frame)
	return {
		strings = {},
		compiled = {},
		widget = {},        -- resolved anchor widget, or nil when not showing
		shown = {},         -- what is ON the font string, which may be truncated
		natural = {},       -- measured width of lastText[i]; nil when stale
		budget = {},        -- the width limit Layout could settle on its own
		appliedText = {},   -- what the width pass last ran against, so a value
		appliedBudget = {}, -- ticking inside the same rendered width is free
	}
end

--------------------------------------------------------------------------------
-- Width (Plan 6)
--
-- A name longer than its bar used to run straight under whatever was anchored
-- at the other end -- on the shipped target frame, the health numbers.
-- `maxWidthMode` is how a text says how much room it is allowed:
--
--   none      unbounded; what every text did before this existed
--   pixels    exactly `maxWidth`
--   percent   `maxWidthPercent` of the anchor widget's width
--   fit       the gap between this text and the nearest thing coming the other
--             way, measured from what that text is ACTUALLY rendering
--
-- `fit` is what the name texts ship on, because it is the only one that stays
-- right when the frame is resized, the font is changed or the health format is
-- edited. A fixed 55% of the bar, the obvious cheap default, does not even fix
-- the frame that prompted this: the target's name starts at x = 32 and its
-- health text renders about 105px wide against the right edge, so 55% of 220
-- still overlaps by roughly 40px.
--
-- What fit costs is a GetStringWidth per changed string. That is why it hangs
-- off the same "did the rendered string actually change" test the element
-- already uses to skip SetText, rather than running every update.
--------------------------------------------------------------------------------

-- Matches the 4px inset the shipped texts sit at, so a fitted text stops the
-- same distance from its neighbour as it does from the edge of the bar.
local FIT_PADDING = 4

-- ASCII on purpose. Fonts come from LibSharedMedia and are whatever the user
-- installed; U+2026 is not guaranteed to be in one, and a missing glyph renders
-- as a box on the exact string whose job is to say "there is more here".
local ELLIPSIS = "..."

local function hSide(point)
	if type(point) ~= "string" then return nil end
	if point:find("LEFT", 1, true) then return "LEFT" end
	if point:find("RIGHT", 1, true) then return "RIGHT" end
	return nil
end

local function vSide(point)
	if type(point) ~= "string" then return nil end
	if point:find("TOP", 1, true) then return "TOP" end
	if point:find("BOTTOM", 1, true) then return "BOTTOM" end
	return nil
end

--- Where a text's anchored edge sits, in pixels from the widget's left edge.
local function anchorX(text, basis)
	local x = text.x or 0
	local side = hSide(text.relativePoint or text.point)
	if side == "LEFT" then return x end
	if side == "RIGHT" then return basis + x end
	return basis / 2 + x
end

--- The span a text occupies once it is `width` pixels wide.
local function span(text, basis, width)
	local at = anchorX(text, basis)
	local side = hSide(text.point)
	if side == "LEFT" then return at, at + width end
	if side == "RIGHT" then return at - width, at end
	return at - width / 2, at + width / 2
end

--- Are two texts on the same bar close enough vertically to collide?
--
-- Only answerable cheaply when both are measured from the same edge, because
-- otherwise the widget's height comes into it. Anything else is reported as a
-- collision, which errs towards shortening a name that had room rather than
-- leaving one that did not -- the overlap is the bug being fixed.
local function sameRow(a, b)
	if vSide(a.point) ~= vSide(b.point) then return true end
	if vSide(a.relativePoint or a.point) ~= vSide(b.relativePoint or b.point) then return true end

	local gap = (a.y or 0) - (b.y or 0)
	if gap < 0 then gap = -gap end
	return gap < ((a.size or 12) + (b.size or 12)) / 2
end

--- Write to a font string only when what it is showing would change.
local function setString(el, index, value)
	if el.shown[index] ~= value then
		el.strings[index]:SetText(value)
		el.shown[index] = value
	end
end

--- How wide the FULL rendered string is, ignoring any limit placed on it.
--
-- Measuring means putting the full string on the font object, so the result is
-- cached against it and only recomputed when Update says the string moved.
local function naturalWidth(el, index)
	local width = el.natural[index]
	if width then return width end

	setString(el, index, el.lastText[index] or "")
	width = el.strings[index]:GetStringWidth() or 0
	el.natural[index] = width
	return width
end

--- Trim `full` until it plus an ellipsis fits inside `budget` pixels.
--
-- A binary search over character boundaries rather than bytes, so a multi-byte
-- name is never cut through the middle of a character. Each probe is a SetText
-- and a GetStringWidth, which is the only way to ask the client how wide
-- something renders; a twenty-character name costs about five of them, once,
-- when the name changes.
local function shorten(el, index, full, budget)
	local offsets = Tags:CharOffsets(full)
	local fontString = el.strings[index]

	local low, high, best = 0, #offsets - 1, nil
	while low <= high do
		local mid = math.floor((low + high) / 2)
		local candidate = (mid <= 0) and ELLIPSIS or (full:sub(1, offsets[mid]) .. ELLIPSIS)

		setString(el, index, candidate)
		if (fontString:GetStringWidth() or 0) <= budget then
			best = candidate
			low = mid + 1
		else
			high = mid - 1
		end
	end

	-- Nothing fits, not even the ellipsis on its own. The SetWidth below still
	-- stands, so the client clips rather than letting it run.
	return best or ELLIPSIS
end

--- The room between text `index` and the nearest thing coming the other way.
local function fitBudget(el, cfg, index, widths)
	local text = cfg[index]
	local widget = el.widget[index]
	local basis = widget and widget:GetWidth() or 0
	if basis <= 0 then return 0 end

	local at = anchorX(text, basis)

	-- The widget's own edges are the outer limit. A neighbour only ever brings
	-- the boundary closer, so a text with nothing opposite it is still stopped
	-- at the end of the bar instead of running off it.
	local left, right = 0, basis

	for j = 1, #cfg do
		local other = cfg[j]
		if j ~= index and widths[j] and el.widget[j] == widget and sameRow(text, other) then
			local otherLeft, otherRight = span(other, basis, widths[j])
			-- Something already straddling our anchor matches neither test and
			-- is ignored: there is no gap left to measure.
			if otherLeft >= at and otherLeft < right then right = otherLeft end
			if otherRight <= at and otherRight > left then left = otherRight end
		end
	end

	local side = hSide(text.point)
	if side == "LEFT" then return math.max(right - at - FIT_PADDING, 0) end
	if side == "RIGHT" then return math.max(at - left - FIT_PADDING, 0) end

	-- Centered: the text grows both ways, so the tighter of the two gaps sets
	-- the half-width.
	local half = math.min(at - left, right - at) - FIT_PADDING
	return math.max(half * 2, 0)
end

local function applyOne(el, index, budget, natural)
	local fontString = el.strings[index]
	local full = el.lastText[index] or ""

	-- Neither the string nor the room for it has changed, so neither has the
	-- answer. This is what keeps a truncated name off the hot path: health
	-- ticking from 4.2k to 4.1k renders the same WIDTH, so the name's budget
	-- comes out identical and the search below is not run again.
	if el.appliedText[index] == full and el.appliedBudget[index] == budget then
		return
	end
	el.appliedText[index] = full
	el.appliedBudget[index] = budget

	if budget <= 0 then
		fontString:SetWidth(0)
		setString(el, index, full)
		return
	end

	fontString:SetWidth(budget)

	-- Color escapes are the one thing trimming must not touch: cutting between
	-- the |cff and its |r leaves the rest of the line the wrong color. Rare
	-- enough (it takes a hand-typed escape in the format string) to hand back
	-- to the client's own clipping rather than to write a parser for.
	if natural <= budget or full:find("|", 1, true) then
		setString(el, index, full)
	else
		setString(el, index, shorten(el, index, full, budget))
	end
end

--- Resolve every text's width limit and shorten what does not fit.
--
-- Two passes on purpose. All the natural widths are collected BEFORE anything
-- is shortened, so a `fit` text measures what its neighbour really renders and
-- not what an earlier iteration already cut it down to. Otherwise the answer
-- would depend on the order the texts happen to sit in the list, which is the
-- ordering dependency this element has never had.
local function applyWidths(el, cfg)
	local widths = {}

	for i = 1, #cfg do
		local text = cfg[i]
		local rendered = el.lastText[i]
		if text and text.enabled ~= false and el.widget[i] and rendered and rendered ~= "" then
			widths[i] = naturalWidth(el, i)
		end
	end

	for i = 1, #cfg do
		if widths[i] then
			local budget = el.budget[i] or 0
			if (cfg[i].maxWidthMode or "none") == "fit" then
				budget = fitBudget(el, cfg, i, widths)
			end
			applyOne(el, i, budget, widths[i])
		end
	end
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

--- Everything but `fit`, which needs to know what the other texts are
-- rendering and so waits for Update.
local function staticBudget(text, widget)
	local mode = text.maxWidthMode or "none"

	if mode == "pixels" then
		return math.max(text.maxWidth or 0, 0)
	elseif mode == "percent" then
		local basis = widget and widget:GetWidth() or 0
		return math.max(basis * (text.maxWidthPercent or 0) / 100, 0)
	end

	return 0
end

function element.Layout(frame, el, cfg)
	cfg = cfg or {}
	el.lastText = el.lastText or {}

	for i = 1, #cfg do
		local text = cfg[i]
		local fontString = el.strings[i]

		if not fontString then
			fontString = ns:NewFontString(frame.overlay, "OVERLAY")
			el.strings[i] = fontString
		end

		local widget, available = ns:AnchorWidget(frame, text.anchorTo)
		el.widget[i] = nil

		-- Unconditionally, before the visibility branch. Update writes to this
		-- string whether or not Layout showed it, and SetText on a FontString
		-- with no font throws.
		ns:SetFont(fontString, text.font, text.size, text.outline, text.shadow)

		if text.enabled == false or not available then
			fontString:Hide()
		else
			fontString:Show()

			fontString:ClearAllPoints()
			fontString:SetPoint(text.point or "LEFT", widget, text.relativePoint or text.point or "LEFT",
				text.x or 0, text.y or 0)

			fontString:SetJustifyH(text.justify or "LEFT")
			fontString:SetWordWrap(false)

			el.widget[i] = widget
			el.budget[i] = staticBudget(text, widget)
			fontString:SetWidth(el.budget[i])

			el.compiled[i] = Tags:Compile(text.format)
			el.lastText[i] = nil     -- force a re-render after any layout change
			-- The font may have moved with it, so the cached measurement is no
			-- longer about the same glyphs.
			el.natural[i] = nil
			el.shown[i] = nil
			el.appliedText[i] = nil
			el.appliedBudget[i] = nil
		end
	end

	-- Font strings for texts the user has deleted.
	for i = #cfg + 1, #el.strings do
		if el.strings[i] then el.strings[i]:Hide() end
	end

	-- Widths that depend on geometry are settled by the next Update, which is
	-- where the rendered strings the `fit` mode measures actually exist.
	el.widthsDirty = true
end

--------------------------------------------------------------------------------
-- Color
--------------------------------------------------------------------------------

local function resolveColor(frame, text, unit)
	local mode = text.colorMode or "static"

	if mode == "rules" then
		local r, g, b = ColorRules:Evaluate(text.rules, unit)
		if r then return r, g, b end
		return Colors:Unpack(text.color)
	elseif mode == "class" then
		local r, g, b = Colors:Class(unit, frame)
		if r then return r, g, b end
		return Colors:Unpack(text.color)
	elseif mode == "reaction" then
		local r, g, b = Colors:Reaction(unit)
		if r then return r, g, b end
		return Colors:Unpack(text.color)
	elseif mode == "difficulty" then
		if frame.test and frame.test.level then
			return Compat.GetDifficultyColor(frame.test.level)
		end
		return Colors:Difficulty(unit)
	elseif mode == "gradient" then
		local value = ColorRules:Metric(text.gradientMetric or "health.percent", unit)
		return Colors:Gradient(text.gradient, (value or 0) / 100)
	end

	return Colors:Unpack(text.color)
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

function element.Update(frame, el, cfg, event)
	cfg = cfg or {}
	local unit = frame.unit
	el.lastText = el.lastText or {}

	local unitExists = unit and UnitExists(unit)
	local moved = false

	for i = 1, #cfg do
		local text = cfg[i]
		local fontString = el.strings[i]

		if fontString and text and text.enabled ~= false then
			local compiled = el.compiled[i]
			if not compiled then
				compiled = Tags:Compile(text.format)
				el.compiled[i] = compiled
			end

			local dynamicColor = DYNAMIC_COLOR[text.colorMode or "static"]
			-- Skip work when this event cannot possibly have changed this text.
			-- A UNIT_POWER_UPDATE must not re-render a pure [name] element.
			local relevant = (event == nil)
				or Tags:Invalidates(compiled, event)
				or (dynamicColor and DYNAMIC_COLOR_EVENTS[event])

			if relevant then
				local rendered = unitExists and Tags:Render(compiled, unit, frame) or ""
				if rendered ~= el.lastText[i] then
					el.lastText[i] = rendered
					el.natural[i] = nil
					moved = true
					-- The full string goes on first. The width pass below is
					-- what decides whether any of it has to come back off.
					setString(el, i, rendered)
				end

				if unitExists then
					if dynamicColor then
						fontString:SetTextColor(resolveColor(frame, text, unit))
					elseif not el.staticApplied or el.staticApplied ~= ns.configSerial then
						fontString:SetTextColor(Colors:Unpack(text.color))
					end
				end
			end
		end
	end

	-- One text growing changes how much room the one facing it has, so this is
	-- driven by "did anything move" rather than by which element moved.
	if moved or el.widthsDirty then
		el.widthsDirty = false
		applyWidths(el, cfg)
	end

	el.staticApplied = ns.configSerial
end

function element.Disable(frame, el)
	for i = 1, #el.strings do
		if el.strings[i] then el.strings[i]:Hide() end
	end
	if el.lastText then
		for i in pairs(el.lastText) do el.lastText[i] = nil end
	end
	for i in pairs(el.natural) do el.natural[i] = nil end
	for i in pairs(el.shown) do el.shown[i] = nil end
	for i in pairs(el.widget) do el.widget[i] = nil end
	for i in pairs(el.appliedText) do el.appliedText[i] = nil end
	for i in pairs(el.appliedBudget) do el.appliedBudget[i] = nil end
end

ns:RegisterElement("text", element)
