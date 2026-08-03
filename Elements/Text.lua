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
	return { strings = {}, compiled = {} }
end

--------------------------------------------------------------------------------
-- Anchoring
--------------------------------------------------------------------------------

--- Resolve an anchorTo key to a live widget.
--
-- @return widget, available
--
-- `available` is false when the text was anchored to a bar that is not
-- currently showing, and the caller hides the text rather than dropping it onto
-- the frame body. That matters most for the shapeshift mana bar, which appears
-- and disappears with form: a mana readout left floating at the frame's edge in
-- caster form -- on top of the power text -- is worse than no readout. The same
-- reasoning applies to any bar the user has turned off.
local function anchorWidget(frame, key)
	local elements = frame.elements

	if key == "health" then
		local el = elements.health
		if el and el.bar:IsShown() then return el.bar, true end
		return frame.content, false
	elseif key == "power" then
		local el = elements.power
		if el and el.bar:IsShown() then return el.bar, true end
		return frame.content, false
	elseif key == "mana" then
		local el = elements.mana
		if el and el.bar:IsShown() then return el.bar, true end
		return frame.content, false
	elseif key == "portrait" then
		local el = elements.portrait
		if el then
			local widget = ns.elements.portrait.GetAnchorWidget(el, frame.cfg.portrait)
			if widget and widget:IsShown() then return widget, true end
		end
		return frame.content, false
	end

	-- "frame" -- always there.
	return frame.content, true
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

function element.Layout(frame, el, cfg)
	cfg = cfg or {}

	for i = 1, #cfg do
		local text = cfg[i]
		local fontString = el.strings[i]

		if not fontString then
			fontString = ns:NewFontString(frame.overlay, "OVERLAY")
			el.strings[i] = fontString
		end

		local widget, available = anchorWidget(frame, text.anchorTo)

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
			if (text.maxWidth or 0) > 0 then
				fontString:SetWidth(text.maxWidth)
			else
				fontString:SetWidth(0)
			end

			el.compiled[i] = Tags:Compile(text.format)
			el.lastText = el.lastText or {}
			el.lastText[i] = nil     -- force a re-render after any layout change
		end
	end

	-- Font strings for texts the user has deleted.
	for i = #cfg + 1, #el.strings do
		if el.strings[i] then el.strings[i]:Hide() end
	end
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
					fontString:SetText(rendered)
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

	el.staticApplied = ns.configSerial
end

function element.Disable(frame, el)
	for i = 1, #el.strings do
		if el.strings[i] then el.strings[i]:Hide() end
	end
	if el.lastText then
		for i in pairs(el.lastText) do el.lastText[i] = nil end
	end
end

ns:RegisterElement("text", element)
