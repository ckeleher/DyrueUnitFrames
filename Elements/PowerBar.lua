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
-- Sweep lines (Plans 2 and 10)
--
-- Player only, on the boundary both plans argue (§FR-8.5): another unit's tick
-- cadence and mana expenditure are not observable.
--------------------------------------------------------------------------------

local function syncSweeps(frame, el, cfg)
	if frame.unitKey ~= "player" then return end

	local BarSweep = ns.BarSweep
	BarSweep:Attach(frame, el.bar, "tick", cfg and cfg.tick)

	-- The five second rule is about mana, so on the power bar the line is
	-- attached only while the DISPLAYED power is mana — a general rule, not a
	-- class check, same reasoning as §4.2. A caster gets it here; a druid in cat
	-- form gets it on the shapeshift mana bar and not on the energy bar; a rogue
	-- never sees it.
	--
	-- This lives in Update rather than Layout so UNIT_DISPLAYPOWER is honoured:
	-- a form change has to attach or detach it without a full config reload.
	local isMana = Compat.GetPowerType(frame.unit) == Compat.MANA
	BarSweep:Attach(frame, el.bar, "fsr", isMana and cfg and cfg.fsr or nil)
end

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

	-- Sweep detection, before anything can early-return below. An increase is a
	-- regen tick; a decrease on a mana bar is a spend. The comparison happens in
	-- BarSweep, which is also fed by the shapeshift mana bar.
	if frame.unitKey == "player" then
		ns.BarSweep:NotePlayerPower(powerType, current)
	end

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

	syncSweeps(frame, el, cfg)
end

--- See the note in Elements/HealthBar.lua: Disable is the only thing called
-- for an element that is no longer wanted.
function element.Disable(frame, el)
	ns.BarSweep:Detach(el.bar)
	el.bar:Hide()
end

ns:RegisterElement("power", element)
