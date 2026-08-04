-- Systems/BarSweep.lua
--
-- Plans 2 and 10 — the power tick indicator and the five second rule
-- indicator, which are one mechanism and are built as one.
--
-- Both draw a thin vertical line sweeping across a bar, driven by a timer. The
-- only differences are what sets the fraction and how long the sweep lasts. So
-- there is one module, one driver and one line-rendering path, with a table of
-- PROVIDERS supplying Fraction / Alpha / IsActive. Building them separately
-- would have meant two tickers, which is precisely what SPEC §5.7 warns about.
--
--------------------------------------------------------------------------------
-- THE FOURTH TICKER
--
-- §5.7 lists exactly three permitted tickers and says a fourth should be
-- treated as a design smell and argued for explicitly. The argument, also
-- recorded in Documents/COMPAT_FINDINGS.md:
--
--   * No event can do it. The sweep is a continuous animation *between* two
--     regen ticks, and nothing fires in between. UNIT_POWER_UPDATE fires AT the
--     tick, which is the moment the sweep restarts. This is the same category
--     as the derived-unit poller: the game does not push what we need.
--
--   * It obeys the same discipline as the other three. It runs only while a
--     visible bar has an *active* sweep on it and stops the instant that stops
--     being true, which /duf profile reports. With both indicators off it never
--     starts; with only the five second rule on, it is idle until the player
--     spends mana.
--
--   * Player only. Another unit's tick cadence and mana expenditure are not
--     observable, so the options are absent rather than present and permanently
--     idle, following the focus-gating precedent in §FR-8.5.
--
-- It is one OnUpdate moving at most four textures (two bars x two providers)
-- with no allocation per frame.
--------------------------------------------------------------------------------

local ADDON, ns = ...
local L = ns.L
local Colors = ns.Colors
local Compat = ns.Compat

local BarSweep = {}
ns.BarSweep = BarSweep

--- The five second rule is a game rule, not an observed cadence: there is
-- nothing to measure and nothing to smooth, which is the opposite of the tick
-- interval below and deliberately so. No user option — an editable "how long is
-- the five second rule" control invites misconfiguring something that is not
-- configurable in the game.
BarSweep.FSR_DURATION = 5

-- The regen cadence is *derived* rather than hardcoded at 2.0, so it
-- self-corrects if Blizzard ever changes it. The band is what stops one bad
-- sample making the line crawl or fly.
local MIN_INTERVAL, MAX_INTERVAL = 1.5, 3.0
local DEFAULT_INTERVAL = 2.0
local SMOOTHING = 0.3

--------------------------------------------------------------------------------
-- Shared state
--
-- One state table for every provider, because there is one player and one regen
-- cadence. Providers read it and never write it; the Note* entry points below
-- are the only writers.
--------------------------------------------------------------------------------

local state = {
	interval = DEFAULT_INTERVAL,   -- seconds between regen ticks
	origin = nil,                  -- GetTime() of the last observed tick
	observed = false,              -- has a real tick ever been seen?
	samples = 0,                   -- accepted interval samples

	lastSpend = nil,               -- GetTime() of the last mana expenditure

	lastPower = nil,               -- last seen displayed power value
	lastPowerType = nil,           -- and its type, so a shapeshift is not a spend

	trigger = nil,                 -- trigger name the attached fsr config selected
}
BarSweep.state = state

local function clamp01(v)
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

--------------------------------------------------------------------------------
-- Triggers (Plan 10)
--
-- The five second rule's detector is a named, swappable strategy rather than
-- inline code, because the user asked for room to change the behavior later
-- without reshaping the sweep around it. Adding one is a table entry.
--
-- No options dropdown is built while there is only one entry: a control with a
-- single value is noise.
--------------------------------------------------------------------------------

BarSweep.TRIGGERS = {
	manaSpent = {
		label = L["Mana spent"],
		--- @return true when this power change should start the clock.
		Detect = function(previous, current)
			return current < previous
		end,
	},

	-- The obvious second entry is `spellcast`: UNIT_SPELLCAST_SUCCEEDED filtered
	-- to the player, restricted to spells that cost mana. It is immune to the
	-- one known false positive below. It is not built now because it needs a
	-- spell-cost lookup whose availability on 1.15.9 / 2.5.6 is unverified —
	-- /dufprobe reports which of GetSpellPowerCost / C_Spell.GetSpellPowerCost
	-- exists, so that is answered by observation before anyone commits to it.
}

BarSweep.DEFAULT_TRIGGER = "manaSpent"

--- The named trigger, or the one the attached five-second-rule config selected,
-- or the default. An unknown name falls back rather than erroring: a typo in a
-- saved variable must not take the indicator out.
function BarSweep:Trigger(name)
	return self.TRIGGERS[name or state.trigger or self.DEFAULT_TRIGGER]
		or self.TRIGGERS[self.DEFAULT_TRIGGER]
end

--------------------------------------------------------------------------------
-- Providers
--
-- Each answers three pure questions about the shared state at a moment in time:
-- whether it should be drawing, where the line is (0 = origin edge, 1 = far
-- edge, before `direction` is applied), and how opaque it is.
--------------------------------------------------------------------------------

local PROVIDERS = {
	--- Plan 2. A progress bar towards the next energy/mana regen tick.
	tick = {
		label = L["Power tick"],

		-- Always, while its bar is visible. The tick never stops happening.
		IsActive = function() return true end,

		Fraction = function(st, now)
			local origin, interval = st.origin, st.interval
			if not origin or not interval or interval <= 0 then return 0 end

			local elapsed = now - origin
			if elapsed < 0 then return 0 end

			-- The modulo IS the edge case Plan 2 calls out: at full power
			-- nothing increases, so no tick is ever observed, but the server's
			-- tick is still happening on the same cadence. Wrapping by whole
			-- intervals keeps the sweep running with its phase intact instead of
			-- parking the line against the far edge until the player spends.
			return clamp01((elapsed % interval) / interval)
		end,

		Alpha = function() return 1 end,
	},

	--- Plan 10. The five second rule: spending mana suppresses Spirit-based
	-- regeneration for five seconds, and every fresh expenditure restarts it.
	--
	-- The sweep measures the 5s window only, not the longer wait until regen
	-- actually resumes — Spirit mana is next credited on the first tick *after*
	-- the window closes, so the line lands on the far edge while regen may still
	-- be up to one tick away. That is the correct reading of "five second rule",
	-- and the tick line above covers the remainder when both are on.
	fsr = {
		label = L["Five second rule"],

		IsActive = function(st, now, cfg)
			if not st.lastSpend then return false end
			local fade = (cfg and cfg.fade) or 0
			return (now - st.lastSpend) <= (BarSweep.FSR_DURATION + fade)
		end,

		Fraction = function(st, now)
			if not st.lastSpend then return 0 end
			return clamp01((now - st.lastSpend) / BarSweep.FSR_DURATION)
		end,

		-- Held at the end and faded out rather than snapped off, per the user's
		-- choice. A spend arriving mid-fade restores full opacity and restarts
		-- from the origin edge; without that a fast caster sees a stutter.
		Alpha = function(st, now, cfg)
			if not st.lastSpend then return 0 end
			local over = (now - st.lastSpend) - BarSweep.FSR_DURATION
			if over <= 0 then return 1 end
			local fade = (cfg and cfg.fade) or 0
			if fade <= 0 then return 0 end
			return clamp01(1 - over / fade)
		end,
	},
}

BarSweep.PROVIDERS = PROVIDERS

function BarSweep:ProviderNames()
	return { "tick", "fsr" }
end

--------------------------------------------------------------------------------
-- Attachment
--
-- bar -> provider name -> record. Textures cannot be destroyed in WoW, so a
-- detached record keeps its line and is reused rather than leaked; `active` is
-- what the driver reads.
--------------------------------------------------------------------------------

local attached = {}

--------------------------------------------------------------------------------
-- The driver
--
-- A hidden frame's OnUpdate does not run, so Show/Hide is the whole start/stop
-- mechanism and there is no timer object to leak.
--------------------------------------------------------------------------------

local driver = nil
local running = false

local function onUpdate()
	BarSweep:Render(GetTime())
end

local function start()
	if running then return end
	if not driver then
		driver = CreateFrame("Frame")
		driver:Hide()
		driver:SetScript("OnUpdate", onUpdate)
	end
	driver:Show()
	running = true
end

local function stop()
	if not running then return end
	if driver then driver:Hide() end
	running = false
end

function BarSweep:IsRunning()
	return running
end

--- How many lines are currently attached and enabled, active or not.
function BarSweep:ActiveCount()
	local n = 0
	for _, byProvider in pairs(attached) do
		for _, record in pairs(byProvider) do
			if record.active then n = n + 1 end
		end
	end
	return n
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

--- Where the line sits along the bar, with `direction` applied.
-- RIGHT (the tick default) sweeps from the left edge to the right; LEFT (the
-- five second rule default) mirrors it, so the line starts at the right edge on
-- the spend and reaches the left edge as the rule expires.
local function position(fraction, cfg)
	if cfg and cfg.direction == "LEFT" then return 1 - fraction end
	return fraction
end

local function place(record, at)
	local bar, line = record.bar, record.line
	local width = bar:GetWidth() or 0
	local height = bar:GetHeight() or 0

	local thickness = (record.cfg and record.cfg.width) or 2
	if thickness > width then thickness = width end
	if thickness < 1 then thickness = 1 end

	-- Travel is the bar minus the line's own thickness, not the whole bar, so
	-- the line is fully visible at both ends instead of hanging off the far edge.
	local travel = width - thickness
	if travel < 0 then travel = 0 end

	line:SetSize(thickness, height)
	line:ClearAllPoints()
	line:SetPoint("TOPLEFT", bar, "TOPLEFT", at * travel, 0)
end

--- One pass over every attached line. Returns whether anything is still active,
-- which is also what decides whether the driver keeps running.
function BarSweep:Render(now)
	now = now or GetTime()

	local anyActive = false

	for bar, byProvider in pairs(attached) do
		local visible = bar:IsVisible()
		for name, record in pairs(byProvider) do
			local provider = PROVIDERS[name]
			local cfg = record.cfg

			if record.active and provider and cfg and visible
				and provider.IsActive(state, now, cfg) then
				anyActive = true
				place(record, position(provider.Fraction(state, now, cfg), cfg))
				record.line:SetAlpha(provider.Alpha(state, now, cfg))
				record.line:Show()
			else
				record.line:Hide()
			end
		end
	end

	if anyActive then start() else stop() end
	return anyActive
end

--- Re-evaluate right now: after an attach, a detach, or a spend.
function BarSweep:Refresh()
	return self:Render(GetTime())
end

--------------------------------------------------------------------------------
-- Attach / detach
--------------------------------------------------------------------------------

--- Put `providerName`'s line on `bar`, or take it off if the config says no.
-- Passing a nil or disabled `cfg` detaches, so callers can express a gate as a
-- single call rather than an if/else at every site.
function BarSweep:Attach(frame, bar, providerName, cfg)
	if not bar or not PROVIDERS[providerName] then return end

	if not cfg or not cfg.enabled then
		self:Detach(bar, providerName)
		return
	end

	local byProvider = attached[bar]
	if not byProvider then
		byProvider = {}
		attached[bar] = byProvider
	end

	local record = byProvider[providerName]
	if not record then
		record = { bar = bar, provider = providerName }
		-- OVERLAY so the line sits above the bar's fill, and a child of the bar
		-- so it inherits the bar's alpha and hides with it — the shapeshift mana
		-- bar disappearing on a form change takes its lines along with no extra
		-- bookkeeping.
		record.line = bar:CreateTexture(nil, "OVERLAY")
		byProvider[providerName] = record
	end

	record.frame = frame
	record.cfg = cfg
	record.active = true

	-- The tick sweep needs somewhere to start before any tick has been observed.
	-- Seeding here rather than at load means an indicator turned on mid-session
	-- begins sweeping immediately instead of sitting still until the next tick.
	if providerName == "tick" and not state.origin then
		state.origin = GetTime()
	end

	if providerName == "fsr" then
		state.trigger = cfg.trigger
	end

	record.line:SetColorTexture(Colors:Unpack(cfg.color))

	self:Refresh()
end

--- Remove one provider's line, or every line on the bar when `providerName` is
-- omitted. The texture is kept and reused: textures cannot be destroyed.
function BarSweep:Detach(bar, providerName)
	local byProvider = attached[bar]
	if not byProvider then return end

	for name, record in pairs(byProvider) do
		if not providerName or name == providerName then
			record.active = false
			record.cfg = nil
			record.line:Hide()
		end
	end

	self:Refresh()
end

--- Is this provider currently drawing on this bar?
function BarSweep:IsAttached(bar, providerName)
	local byProvider = attached[bar]
	local record = byProvider and byProvider[providerName]
	return (record and record.active) == true
end

--- The line texture, for tests and for anything that needs to inspect it.
function BarSweep:Line(bar, providerName)
	local byProvider = attached[bar]
	local record = byProvider and byProvider[providerName]
	return record and record.line
end

--------------------------------------------------------------------------------
-- Detection
--
-- Two sources feed one entry point for the five second rule, because
-- UNIT_POWER_UPDATE for mana has historically not fired reliably while
-- shapeshifted (SPEC §FR-2.5) — and a druid in cat form is a first-class case
-- for this feature, so the event alone cannot be trusted there.
--------------------------------------------------------------------------------

--- A regen tick was observed. Only *increases* reach here: spending energy also
-- fires UNIT_POWER_UPDATE and must not be read as a tick.
function BarSweep:NoteTick(now)
	now = now or GetTime()

	local previous = state.origin
	state.origin = now
	state.observed = true

	if not previous then return end

	local sample = now - previous

	-- Outliers are ignored outright rather than folded in and clamped. A 4s gap
	-- is a *missed* tick — at full power nothing increases, so nothing is
	-- observed — not evidence that the cadence is 4s. Dragging the interval
	-- towards a missed tick is how a derived value goes wrong.
	if sample < MIN_INTERVAL or sample > MAX_INTERVAL then return end

	local blended = state.interval * (1 - SMOOTHING) + sample * SMOOTHING
	if blended < MIN_INTERVAL then blended = MIN_INTERVAL end
	if blended > MAX_INTERVAL then blended = MAX_INTERVAL end

	state.interval = blended
	state.samples = state.samples + 1
end

--- Mana actually left the pool. Every fresh expenditure restarts the five
-- seconds.
--
-- Known false positive, accepted: an enemy draining mana (Mana Burn, Viper
-- Sting) is a decrease and starts the clock. It is rare, self-corrects within
-- five seconds, and is exactly the case the swappable trigger exists for.
--
-- Correct positive worth noting: shapeshifting costs mana, so shifting starts
-- the clock. That is right, not a bug.
function BarSweep:NoteManaSpent(now)
	state.lastSpend = now or GetTime()
	self:Refresh()
end

--- Source 1: the player's displayed power changed.
--
-- An increase is a regen tick. A decrease is a spend, but only when the
-- displayed power *is* mana — a rogue burning energy has not touched the five
-- second rule.
function BarSweep:NotePlayerPower(powerType, value, now)
	if type(value) ~= "number" then return end

	local previous, previousType = state.lastPower, state.lastPowerType
	state.lastPower = value
	state.lastPowerType = powerType

	-- A power-type change is a shapeshift, not a spend and not a tick: the two
	-- values are different resources and are not comparable at all.
	if previous == nil or previousType ~= powerType then return end
	if value == previous then return end

	if value > previous then
		self:NoteTick(now)
	elseif powerType == Compat.MANA then
		if self:Trigger().Detect(previous, value) then
			self:NoteManaSpent(now)
		end
	end
end

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

function BarSweep:TickInterval()
	return state.interval
end

function BarSweep:TickObserved()
	return state.observed
end

--- Is the five second rule running right now? Reported by /duf profile, since
-- "it is idle when it should be idle" is the property that justifies the cost.
function BarSweep:IsFiveSecondRuleRunning(now)
	return PROVIDERS.fsr.IsActive(state, now or GetTime(), nil)
end

--- Reset every derived value. Used by the test suite; there is no in-game path
-- that needs it, because the state is per-session by nature.
function BarSweep:Reset()
	state.interval = DEFAULT_INTERVAL
	state.origin = nil
	state.observed = false
	state.samples = 0
	state.lastSpend = nil
	state.lastPower = nil
	state.lastPowerType = nil
	state.trigger = nil

	for bar in pairs(attached) do
		self:Detach(bar)
	end
end
