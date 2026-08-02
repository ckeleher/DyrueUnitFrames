-- Elements/ShapeshiftMana.lua
--
-- SPEC §4.2 — the druid mana bar, specified deliberately as a GENERAL rule
-- rather than a class check:
--
--     UnitPowerType(unit) ~= MANA  and  UnitPowerMax(unit, MANA) > 0
--
-- In Classic and TBC that fires for druids in Bear, Dire Bear and Cat form and
-- for nobody else. Writing it generically means there is no class table to
-- maintain and nothing breaks if Blizzard adjusts a form.

local ADDON, ns = ...
local L = ns.L
local Colors = ns.Colors
local Compat = ns.Compat
local Errors = ns.Errors

local element = {
	order = 30,
	configKey = "mana",
	events = {
		UNIT_POWER_UPDATE = true,
		UNIT_MAXPOWER = true,
		UNIT_DISPLAYPOWER = true,
	},
	globalEvents = {
		UPDATE_SHAPESHIFT_FORM = true,
	},
}

--------------------------------------------------------------------------------
-- Fallback ticker (SPEC §FR-2.5)
--
-- Historically UNIT_POWER_UPDATE for the mana type has not fired reliably
-- while shapeshifted. One shared ticker services every visible mana bar, and
-- it is cancelled the moment the last one hides — bounded cost, no idle
-- overhead, which is the standing rule for the three permitted tickers
-- (SPEC §5.7).
--
-- "auto" mode also counts how often the ticker found a value the events had
-- not delivered. That number is reported by /duf profile and is the honest
-- answer to the Phase 0 question of whether the fallback is needed at all.
--------------------------------------------------------------------------------

local ticker = nil
local visible = {}          -- frame -> true
local visibleCount = 0

element.corrections = 0
element.tickCount = 0

local function tick()
	element.tickCount = element.tickCount + 1
	for frame in pairs(visible) do
		local el = frame.elements and frame.elements.mana
		if el and frame:IsShown() then
			local before = el.lastValue
			element.Update(frame, el, frame.cfg.mana, "TICK")
			if before ~= el.lastValue then
				element.corrections = element.corrections + 1
			end
		end
	end
end

local function stopTicker()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
end

local function startTicker(interval)
	if ticker then return end
	ticker = C_Timer.NewTicker(interval or 0.2, tick)
end

local function refreshTicker(frame)
	local cfg = frame and frame.cfg and frame.cfg.mana
	local mode = cfg and cfg.tickerMode or "auto"
	if visibleCount > 0 and mode ~= "off" then
		startTicker(cfg and cfg.tickerInterval or 0.2)
	elseif visibleCount == 0 then
		stopTicker()
	end
end

function element.IsTicking()
	return ticker ~= nil
end

function element.TickerStats()
	return element.corrections, element.tickCount, visibleCount
end

--------------------------------------------------------------------------------
-- The predicate
--------------------------------------------------------------------------------

--- Should this frame be showing a true-mana bar right now?
function element.ShouldShow(frame, cfg)
	if not cfg or not cfg.enabled then return false end

	local unit = frame.unit
	if not unit or not UnitExists(unit) then return false end

	local displayed = UnitPowerType(unit)
	if displayed == Compat.MANA then return false end

	local manaMax = UnitPowerMax(unit, Compat.MANA)
	return (manaMax or 0) > 0
end

--------------------------------------------------------------------------------
-- Element
--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	return cfg and cfg.enabled == true
end

function element.Build(frame)
	local el = {}

	el.bar = CreateFrame("StatusBar", nil, frame.content)
	el.bar:SetFrameLevel(ns:Level(frame, "BARS"))
	el.bar:Hide()

	el.bg = el.bar:CreateTexture(nil, "BACKGROUND")
	el.bg:SetAllPoints(el.bar)

	el.shown = false
	el.lastValue = nil

	return el
end

function element.Layout(frame, el, cfg)
	local texture = ns:Texture(cfg.texture)
	el.bar:SetStatusBarTexture(texture)
	el.bg:SetTexture(texture)

	local r, g, b = Colors:Unpack(cfg.color)
	r, g, b = Colors:Brighten(r, g, b, cfg.brightness)
	el.bar:SetStatusBarColor(r, g, b)
	local br, bgc, bb, ba = Colors:Background(r, g, b, cfg.bgMultiplier, cfg.bgAlpha)
	el.bg:SetVertexColor(br, bgc, bb, ba)
end

function element.SetGeometry(frame, el, x, y, width, height)
	el.bar:SetFrameLevel(ns:Level(frame, "BARS"))
	el.bar:ClearAllPoints()
	el.bar:SetPoint("TOPLEFT", frame.content, "TOPLEFT", x, y)
	el.bar:SetSize(width, height)
end

--- Apply the show/hide decision. Returns true if visibility changed, which
-- tells the caller to re-run the frame's bar-stack layout.
function element.ApplyVisibility(frame, el, cfg)
	local shouldShow = element.ShouldShow(frame, cfg)
	if shouldShow == el.shown then return false end

	el.shown = shouldShow
	el.bar:SetShown(shouldShow)

	if shouldShow then
		if not visible[frame] then
			visible[frame] = true
			visibleCount = visibleCount + 1
		end
	else
		if visible[frame] then
			visible[frame] = nil
			visibleCount = visibleCount - 1
			el.lastValue = nil
		end
	end
	refreshTicker(frame)

	return true
end

function element.Update(frame, el, cfg, event)
	-- Visibility first: a form change arrives as UNIT_DISPLAYPOWER or
	-- UPDATE_SHAPESHIFT_FORM and must be reflected before values are read.
	if element.ApplyVisibility(frame, el, cfg) then
		-- Bar geometry lives inside frame.content, which is not a protected
		-- frame, so this is safe in combat. Deliberate: a druid shifting mid
		-- fight must not have to wait for PLAYER_REGEN_ENABLED to see mana.
		frame:LayoutBars()
	end

	if not el.shown then return end

	local unit = frame.unit
	local maximum = UnitPowerMax(unit, Compat.MANA) or 0
	local current = UnitPower(unit, Compat.MANA) or 0

	el.bar:SetMinMaxValues(0, maximum > 0 and maximum or 1)
	el.bar:SetValue(maximum > 0 and current or 0)
	el.lastValue = current
end

function element.Disable(frame, el)
	if visible[frame] then
		visible[frame] = nil
		visibleCount = visibleCount - 1
	end
	el.shown = false
	el.bar:Hide()
	refreshTicker(frame)
end

--- Space this element occupies in the bar stack. In "reserve" mode the slot is
-- always allocated so nothing jumps when the bar appears; in "append" mode the
-- bar hangs below the frame's own bounds instead, which keeps a form change
-- entirely free of protected calls (SPEC §FR-2.3).
function element.SlotHeight(frame, cfg, el)
	if not cfg or not cfg.enabled then return 0 end
	if cfg.mode == "reserve" then
		return cfg.height + cfg.spacing
	end
	if el and el.shown then
		return cfg.height + cfg.spacing
	end
	return 0
end

ns:RegisterElement("mana", element)
