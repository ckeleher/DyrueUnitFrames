-- Elements/Text.lua
--
-- SPEC §4.3 / PLAN task 4.8.
--
-- An arbitrary number of text elements per frame, each with its own format
-- string, anchor, font and colour policy. Formats are compiled once by
-- Systems/Tags; this element does anchoring, fonts, colour resolution and
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

-- Colour modes that have to be recomputed whenever the unit's state moves,
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

--- The union of every compiled format's events, plus colour dependencies.
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

--- Resolve an anchorTo key to a live widget, falling back to the frame body
-- when the requested bar is disabled or hidden.
local function anchorWidget(frame, key)
	local elements = frame.elements
	if key == "health" and elements.health and elements.health.bar:IsShown() then
		return elements.health.bar
	elseif key == "power" and elements.power and elements.power.bar:IsShown() then
		return elements.power.bar
	elseif key == "mana" and elements.mana and elements.mana.bar:IsShown() then
		return elements.mana.bar
	elseif key == "portrait" and elements.portrait then
		local widget = ns.elements.portrait.GetAnchorWidget(elements.portrait, frame.cfg.portrait)
		if widget and widget:IsShown() then return widget end
	end
	return frame.content
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
			fontString = frame.content:CreateFontString(nil, "OVERLAY")
			el.strings[i] = fontString
		end

		if text.enabled == false then
			fontString:Hide()
		else
			fontString:Show()
			ns:SetFont(fontString, text.font, text.size, text.outline, text.shadow)

			fontString:ClearAllPoints()
			local widget = anchorWidget(frame, text.anchorTo)
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
-- Colour
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
