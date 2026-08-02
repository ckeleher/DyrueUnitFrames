-- Elements/HealthBar.lua
--
-- PLAN task 1.6 / SPEC §4.4.
--
-- Built entirely from primitives (CreateFrame, StatusBar, Texture). No
-- Blizzard template, no CompactUnitFrame hook, nothing that a shared-code UI
-- patch can take away — that containment is the whole architectural thesis
-- (SPEC §1.2).

local ADDON, ns = ...
local L = ns.L
local Colors = ns.Colors
local Compat = ns.Compat

local element = {
	order = 10,
	configKey = "health",
	events = {
		UNIT_HEALTH = true,
		UNIT_MAXHEALTH = true,
		UNIT_CONNECTION = true,
		UNIT_FLAGS = true,
		UNIT_FACTION = true,
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

	-- Inverse fill: the bar depletes from the opposite side (SPEC §FR-4.5).
	if el.bar.SetReverseFill then
		pcall(el.bar.SetReverseFill, el.bar, cfg.inverseFill and true or false)
	end

	el.bar:SetShown(element.IsEnabled(frame, cfg))
end

--- Geometry is driven by the frame's bar-stack calculation rather than by the
-- element, so health, power and shapeshift mana cannot disagree about who owns
-- which strip of the frame.
function element.SetGeometry(frame, el, x, y, width, height)
	el.bar:SetFrameLevel(ns:Level(frame, "BARS"))
	el.bar:ClearAllPoints()
	el.bar:SetPoint("TOPLEFT", frame.content, "TOPLEFT", x, y)
	el.bar:SetSize(width, height)
end

function element.Update(frame, el, cfg)
	local unit = frame.unit
	if not unit or not UnitExists(unit) then return end

	local maximum = UnitHealthMax(unit) or 0
	local current = UnitHealth(unit) or 0

	local dead = UnitIsDead(unit) or UnitIsGhost(unit)
	local offline = not UnitIsConnected(unit)
	if dead or offline then current = 0 end

	el.bar:SetMinMaxValues(0, maximum > 0 and maximum or 1)
	el.bar:SetValue(maximum > 0 and current or 0)

	local r, g, b = Colors:HealthBar(unit, cfg, frame)
	r, g, b = Colors:Brighten(r, g, b, cfg.brightness)
	if dead and cfg.dimWhenDead then
		r, g, b = r * 0.35, g * 0.35, b * 0.35
	end
	el.bar:SetStatusBarColor(r, g, b)

	local br, bg, bb, ba = Colors:Background(r, g, b, cfg.bgMultiplier, cfg.bgAlpha)
	el.bg:SetVertexColor(br, bg, bb, ba)
end

--- Turning the bar off in the options has to actually take it off screen.
-- ApplyConfig calls Disable and nothing else for an element it no longer
-- wants -- Layout is skipped -- so without this the bar keeps whatever
-- visibility it last had.
function element.Disable(frame, el)
	el.bar:Hide()
end

ns:RegisterElement("health", element)
