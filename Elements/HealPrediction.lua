-- Elements/HealPrediction.lua
--
-- Plan 11 — the drawing half. Every derived number comes from
-- Systems/HealPrediction; this file only decides where the segments go.
--
-- It is a registered element rather than twenty lines inside HealthBar.lua for
-- one reason that outweighs the coupling: the circuit breaker. This is the most
-- speculative code in the addon -- combat-log parsing, spellcast sequencing,
-- estimates -- and as an element it gets its own error context, so five errors
-- take the PREDICTION off for the session and leave the health bar underneath
-- working. Folded into the health bar, the same five errors would take the
-- health bar with it.
--
-- Order 11 groups it with the bars, immediately after health's 10. It is NOT
-- an ordering dependency: RegisterEvents builds each event's handler list by
-- iterating activeElements, which is unordered, so on a UNIT_HEALTH this may
-- well run before the health bar does. That is safe because the fill position
-- is computed from UnitHealth directly rather than read off the bar -- the only
-- thing taken from the health element is its geometry, which changes on layout
-- and not on a health event.
--
--------------------------------------------------------------------------------
-- OVERFLOW
--
-- "+10% overflow" means the prediction may overhang the END of the bar by 10%
-- of the bar's width. Health keeps its meaning exactly -- full health still
-- fills the bar -- and a heal that would overheal visibly spills past the edge,
-- which is the entire point of the setting.
--
-- The overhang therefore leaves the frame, and draws over the border edges
-- (which live on frame.overlay at a higher frame level and so still win). On
-- horizontally packed party frames it can reach into the neighbor. That is
-- inherent to what overflow IS; the amount is a slider and 0 turns it off.

local ADDON, ns = ...
local L = ns.L
local Colors = ns.Colors
local Compat = ns.Compat

local UnitExists, UnitHealth, UnitHealthMax = UnitExists, UnitHealth, UnitHealthMax
local UnitIsDead, UnitIsGhost, UnitIsConnected = UnitIsDead, UnitIsGhost, UnitIsConnected

--- Below this a segment is not drawn at all. A sub-pixel sliver reads as a
-- rendering artifact rather than as information.
local MIN_SEGMENT = 1

local element = {
	order = 11,
	configKey = "healPrediction",
	events = {
		-- The fill moved, so where the prediction starts moved with it.
		UNIT_HEALTH = true,
		UNIT_MAXHEALTH = true,
		-- A HoT was applied, refreshed or fell off. This is half of what
		-- replaces the ticker a HoT remainder would otherwise need; the other
		-- half is the system pushing an update as each tick lands.
		UNIT_AURA = true,
		UNIT_CONNECTION = true,
		UNIT_FLAGS = true,
	},
	globalEvents = {},
}

--------------------------------------------------------------------------------

--- Enabled only where there is a health bar to draw on. `frame.cfg` is set at
-- the top of ApplyConfig, before the element loop runs, so this is safe to read
-- here.
function element.IsEnabled(frame, cfg)
	if not cfg or cfg.enabled == false then return false end
	local health = frame.cfg and frame.cfg.health
	return health ~= nil and health.enabled ~= false
end

--- Create the textures on the health bar itself.
--
-- Children of the bar, like BarSweep's lines and for the same reasons: they
-- inherit its alpha, they move with its geometry, and they hide when it hides
-- with no bookkeeping at all.
--
-- ARTWORK sublevel 2 sits above the StatusBar's own fill (ARTWORK, sublevel 0)
-- and below OVERLAY, which the sweep lines and the text engine use.
local function ensureTextures(frame, el)
	if el.direct then return true end

	local health = frame.elements and frame.elements.health
	local bar = health and health.bar
	-- No health bar yet -- health's own Build was skipped or its breaker tripped.
	-- Reported as not-ready rather than parented somewhere wrong, and retried on
	-- the next Layout, because elements are built once and a bad parent chosen
	-- here would last the session.
	if not bar then return false end

	el.bar = bar
	el.direct = bar:CreateTexture(nil, "ARTWORK", nil, 2)
	el.hot = bar:CreateTexture(nil, "ARTWORK", nil, 2)
	el.direct:Hide()
	el.hot:Hide()

	return true
end

function element.Build(frame)
	local el = {}
	ensureTextures(frame, el)
	return el
end

function element.Layout(frame, el, cfg)
	-- Registering intent, not asking for data: this is what starts the
	-- combat-log listener, and Disable below is what stops it.
	ns.HealPrediction:SetActive(frame, true)

	if not ensureTextures(frame, el) then return end

	-- The health bar's own texture, so the segments read as part of the same
	-- bar rather than as a foreign block sitting on it.
	local healthCfg = frame.cfg and frame.cfg.health
	local texture = ns:Texture(healthCfg and healthCfg.texture)
	local alpha = cfg.alpha or 0.55

	local dr, dg, db = Colors:Unpack(cfg.directColor)
	local hr, hg, hb = Colors:Unpack(cfg.hotColor)
	-- One color for both categories is a single checkbox rather than a second
	-- code path: the HoT segment is still drawn, still ordered second, and just
	-- happens to be the same color.
	if not cfg.separateColors then hr, hg, hb = dr, dg, db end

	el.direct:SetTexture(texture)
	el.direct:SetVertexColor(dr, dg, db, alpha)
	el.hot:SetTexture(texture)
	el.hot:SetVertexColor(hr, hg, hb, alpha)

	element.Clear(el)
end

function element.Clear(el)
	if el.direct then el.direct:Hide() end
	if el.hot then el.hot:Hide() end
end

--- Place one segment and return where the next one starts.
--
-- The cursor advances by the segment's FULL width even when clipping meant only
-- part of it was drawn. Advancing by the drawn width instead would let a
-- clipped first segment leave room for the second, so a huge direct heal would
-- be followed by a HoT segment appearing out of nowhere at the overflow limit.
local function segment(texture, bar, height, cursor, width, limit, inverse)
	local x0 = cursor < limit and cursor or limit
	local x1 = (cursor + width) < limit and (cursor + width) or limit
	local drawn = x1 - x0

	if drawn >= MIN_SEGMENT then
		texture:ClearAllPoints()
		if inverse then
			-- The bar depletes from the other side, so the prediction has to
			-- grow the other way too: measured from the right edge, extending
			-- leftward, and overflowing past the LEFT end of the bar.
			texture:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -x0, 0)
		else
			texture:SetPoint("TOPLEFT", bar, "TOPLEFT", x0, 0)
		end
		texture:SetSize(drawn, height)
		texture:Show()
	else
		texture:Hide()
	end

	return cursor + width
end

--- The geometry, in health points converted to bar pixels.
function element.Place(frame, el, cfg, current, maximum, direct, hot)
	local bar = el.bar
	local width = bar:GetWidth() or 0
	local height = bar:GetHeight() or 0
	if width <= 0 or height <= 0 or maximum <= 0 then
		return element.Clear(el)
	end

	local scale = width / maximum

	-- With overflow off the limit is the bar's end, which is what makes the
	-- setting a real toggle rather than a zero amount that still leaves the
	-- clipping arithmetic running.
	local limit = width
	if cfg.overflow then
		limit = width * (1 + (cfg.overflowAmount or 0))
	end

	local healthCfg = frame.cfg and frame.cfg.health
	local inverse = healthCfg and healthCfg.inverseFill and true or false

	local cursor = current * scale
	if cursor < 0 then cursor = 0 end

	cursor = segment(el.direct, bar, height, cursor, direct * scale, limit, inverse)
	segment(el.hot, bar, height, cursor, hot * scale, limit, inverse)
end

function element.Update(frame, el, cfg)
	if not ensureTextures(frame, el) then return end

	local unit = frame.unit
	if not unit or not UnitExists(unit) then return element.Clear(el) end

	-- SPEC §FR-4.7. Units outside your group report health on a 0-100 scale, so
	-- there is no max health to measure an absolute heal against and no honest
	-- way to turn one into a bar fraction. Renders nothing, silently -- the
	-- config stays uniform across every unit and simply has no effect here.
	if not Compat.HasRealHealthValues(unit) then return element.Clear(el) end

	if UnitIsDead(unit) or UnitIsGhost(unit) or not UnitIsConnected(unit) then
		return element.Clear(el)
	end

	local maximum = UnitHealthMax(unit) or 0
	if maximum <= 0 then return element.Clear(el) end

	local direct, hot

	-- Test mode fakes identity through frame.test and everything else reads
	-- real data (Config/TestMode.lua). A prediction has nothing real to read
	-- while standing in a city, so it is the one other value that gets a
	-- stand-in -- otherwise these colors can only be configured mid-fight.
	local test = frame.test
	if test and test.incomingHeal then
		direct = test.incomingHeal * maximum
		hot = (test.incomingHot or 0) * maximum
	else
		direct, hot = ns.HealPrediction:IncomingHeal(unit)
	end

	if direct <= 0 and hot <= 0 then return element.Clear(el) end

	element.Place(frame, el, cfg, UnitHealth(unit) or 0, maximum, direct, hot)
end

function element.Disable(frame, el)
	ns.HealPrediction:SetActive(frame, false)
	element.Clear(el)
end

ns:RegisterElement("healPrediction", element)
