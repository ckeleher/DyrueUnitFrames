-- Elements/PowerBar.lua
--
-- PLAN task 1.7 / SPEC §FR-4.6.
--
-- Driven by UnitPowerType, so a warrior's rage, a rogue's energy and a hunter
-- pet's happiness all work without a class table. UNIT_DISPLAYPOWER is the
-- event that matters: it fires when the *displayed* power type changes, which
-- is exactly the druid shapeshift case that FR-2.1 also keys off.

local ADDON, ns = ...
local L = ns.L
local Colors = ns.Colors
local Compat = ns.Compat

local element = {
	order = 20,
	configKey = "power",
	events = {
		UNIT_POWER_UPDATE = true,
		UNIT_MAXPOWER = true,
		UNIT_DISPLAYPOWER = true,
		UNIT_CONNECTION = true,
		UNIT_HAPPINESS = true,
	},
	globalEvents = {},
}

--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	return cfg and cfg.enabled ~= false
end

function element.Build(frame)
	local el = {}

	el.bar = CreateFrame("StatusBar", nil, frame.content)
	el.bar:SetFrameLevel(ns:Level(frame, "BARS"))

	el.bg = el.bar:CreateTexture(nil, "BACKGROUND")
	el.bg:SetAllPoints(el.bar)

	return el
end

function element.Layout(frame, el, cfg)
	local texture = ns:Texture(cfg.texture)
	el.bar:SetStatusBarTexture(texture)
	el.bg:SetTexture(texture)
	el.bar:SetShown(element.IsEnabled(frame, cfg))
end

function element.SetGeometry(frame, el, x, y, width, height)
	el.bar:SetFrameLevel(ns:Level(frame, "BARS"))
	el.bar:ClearAllPoints()
	el.bar:SetPoint("TOPLEFT", frame.content, "TOPLEFT", x, y)
	el.bar:SetSize(width, height)
end

function element.Update(frame, el, cfg)
	local unit = frame.unit
	if not unit or not UnitExists(unit) then return end

	local powerType, token = Compat.GetPowerType(unit)
	local maximum = UnitPowerMax(unit, powerType) or 0
	local current = UnitPower(unit, powerType) or 0

	if maximum <= 0 then
		-- A unit with no power at all (most NPCs, a druid in a form with an
		-- empty pool). Showing an empty bar is a user choice.
		if cfg.hideWhenEmpty then
			el.bar:Hide()
			return
		end
		el.bar:Show()
		el.bar:SetMinMaxValues(0, 1)
		el.bar:SetValue(0)
	else
		el.bar:Show()
		el.bar:SetMinMaxValues(0, maximum)
		el.bar:SetValue(current)
	end

	local r, g, b = Colors:PowerBar(unit, cfg, token, frame)
	r, g, b = Colors:Brighten(r, g, b, cfg.brightness)
	el.bar:SetStatusBarColor(r, g, b)

	local br, bg, bb, ba = Colors:Background(r, g, b, cfg.bgMultiplier, cfg.bgAlpha)
	el.bg:SetVertexColor(br, bg, bb, ba)
end

ns:RegisterElement("power", element)
