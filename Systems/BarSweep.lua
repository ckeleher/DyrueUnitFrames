-- Systems/BarSweep.lua
--
-- Plans 2, 10 and 17 — the power tick indicator, the five second rule
-- indicator and the rage decay indicator, which are one mechanism and are built
-- as one.
--
-- All three draw a thin vertical line sweeping across a bar, driven by a timer.
-- The only differences are what sets the fraction and how long the sweep lasts.
-- So there is one module, one driver and one line-rendering path, with a table
-- of PROVIDERS supplying Fraction / Alpha / IsActive. Building them separately
-- would have meant three tickers, which is precisely what SPEC §5.7 warns about.
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
--     being true, which /duf profile reports. With every indicator off it never
--     starts; with only the five second rule on, it is idle until the player
--     spends mana; with only rage decay on, it is idle until rage starts falling.
--
--   * Player only. Another unit's tick cadence, mana expenditure and rage decay
--     are not observable, so the options are absent rather than present and
--     permanently idle, following the focus-gating precedent in §FR-8.5.
--
-- It is one OnUpdate moving at most four textures with no allocation per frame.
-- Three providers over two bars is five possible lines, but the tick and decay
-- lines are mutually exclusive on any one bar — the tick needs a resource that
-- regenerates and decay needs one that does not — so four is the ceiling.
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
-- Rage decay (Plan 17)
--
-- Derived on the same terms as the regen cadence above, for stronger reasons.
-- The plan looked the rules up and found them not reliably documented for either
-- of our clients:
--
--   * Vanilla sources give ~1 rage per second, delivered as 2 or 3 rage on a
--     ~2.5s tick. One source. The modern wiki's 1.25/sec is the RETAIL figure and
--     is the wrong number to copy here.
--
--   * The rate is talent-modifiable on Classic Era and not on TBC. Vanilla Anger
--     Management reads "Increases the time required for your rage to decay while
--     out of combat by 30%"; 2.0.1 redesigned it into in-combat generation. So a
--     hardcoded constant cannot be right for both clients at once.
--
--   * The delay between combat dropping and rage starting to fall has no
--     documented value at all. It is measured here rather than assumed — see
--     NoteRageDecay and /duf profile.
--
-- The band is wider than the regen band because a 30% stretch on a 2.5s base is
-- 3.25s and must not be rejected as an outlier.
local RAGE_MIN_INTERVAL, RAGE_MAX_INTERVAL = 1.5, 4.0
local RAGE_DEFAULT_INTERVAL = 2.5

-- A decay tick is documented as 2 or 3 rage. Anything bigger out of combat is
-- something else — shifting out of bear form zeroes rage, and players report
-- losing the whole bar as combat drops — so it is not read as a cadence sample.
-- A guard against large one-off drops, not a precision instrument.
local RAGE_MAX_DECAY_STEP = 5

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

	-- Rage decay (Plan 17). Deliberately its own fields rather than sharing the
	-- four above: rage is a separate mechanism on a separate cadence, and letting
	-- the two meet is the bug part 1 of this plan fixed.
	rageInterval = RAGE_DEFAULT_INTERVAL,  -- seconds between decay ticks
	rageOrigin = nil,              -- GetTime() of the last observed decay tick,
	                               -- and the "decay has started" signal itself
	rageObserved = false,          -- has a real decay tick ever been seen?
	rageSamples = 0,               -- accepted interval samples
	rageCombatEnd = nil,           -- GetTime() of a combat drop not yet measured
	rageFirstDecay = nil,          -- measured gap from combat drop to first decay
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

		-- While its bar is visible, the tick never stops happening — so the only
		-- question is what to do once the bar is already full, where the tick is
		-- still landing but has nothing to add. That is a judgement call rather
		-- than a fact, so it is the user's:
		--
		--   always   keep sweeping
		--   mana     keep it at full mana, drop it at full energy
		--   energy   keep it at full energy, drop it at full mana
		--   never    drop it whenever the bar is full
		--
		-- `record` carries the power type this particular bar shows, because the
		-- same line is attached to the power bar and the shapeshift mana bar at
		-- once and "at max" means a different thing on each.
		IsActive = function(st, now, cfg, record)
			-- Plan 17. Rage does not regenerate, so on a rage bar this line is a
			-- progress bar towards an event that never happens. It is suppressed at
			-- render time rather than hidden as an option, because `power.tick` is
			-- one config block per BAR and a druid's power bar shows rage in bear
			-- form and energy in cat form — there is no per-power-type config to
			-- hide. The `decay` provider below is what a rage bar gets instead.
			if record and record.powerType == Compat.RAGE then return false end

			if not record or not record.atMax then return true end

			local mode = (cfg and cfg.atMax) or "always"
			if mode == "never" then return false end
			if mode == "mana" then return record.powerType == Compat.MANA end
			if mode == "energy" then return record.powerType == Compat.ENERGY end
			return true
		end,

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

	--- Plan 17. Rage decays out of combat instead of regenerating, so this is the
	-- tick line's mirror image: a progress bar towards the next moment the player
	-- LOSES rage.
	decay = {
		label = L["Rage decay"],

		-- Three gates, and each one is a fact rather than a judgment call — which
		-- is why, unlike the tick line's `atMax`, none of them is a setting:
		--
		--   * Only on a rage bar. Nothing else decays.
		--   * Not in combat. Rage does not decay in combat at all, so there is no
		--     next decay to count down to.
		--   * Not at zero rage. Decay stops at zero; there is nothing left to lose.
		--
		-- `rageOrigin` is the fourth and is the answer to "how long does rage take
		-- to start decaying". That delay is the least verifiable number in this
		-- feature — undocumented, possibly zero, possibly just the combat-drop timer
		-- the game already signals by clearing the combat flag — so rather than
		-- sweep a line for a duration nothing substantiates, the line simply does
		-- not appear until rage is actually observed falling. Correct whatever the
		-- true delay turns out to be. The delay is measured anyway and reported by
		-- /duf profile, so the number becomes known rather than guessed.
		IsActive = function(st, now, cfg, record)
			if not record or record.powerType ~= Compat.RAGE then return false end
			if not st.rageOrigin then return false end
			if (st.lastPower or 0) <= 0 then return false end

			-- Read live rather than tracked from PLAYER_REGEN_DISABLED/ENABLED. One
			-- C call per frame while a decay line is up, in exchange for a combat
			-- state that cannot go stale if an event is ever missed — and NoteRagePower
			-- needs the same answer at the moment of a power event, so one live source
			-- keeps the two from disagreeing.
			return not UnitAffectingCombat("player")
		end,

		-- The modulo is here for the reason it is on the tick line: a decay tick is
		-- only *observed* when the client pushes a decrease, and if one is missed the
		-- phase of the last one is a better estimate than parking against the edge.
		Fraction = function(st, now)
			local origin, interval = st.rageOrigin, st.rageInterval
			if not origin or not interval or interval <= 0 then return 0 end

			local elapsed = now - origin
			if elapsed < 0 then return 0 end

			return clamp01((elapsed % interval) / interval)
		end,

		Alpha = function() return 1 end,
	},
}

BarSweep.PROVIDERS = PROVIDERS

function BarSweep:ProviderNames()
	return { "tick", "fsr", "decay" }
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

		-- A cross-provider interaction, so it lives here rather than inside a
		-- provider: while this bar's five second rule is counting down, that same
		-- bar's tick line is suppressed. Two lines sweeping one bar in opposite
		-- directions is hard to read, and for those five seconds the mana tick is
		-- still landing but has no Spirit contribution to add, so the rule is the
		-- more informative of the two.
		--
		-- Scoped to the SAME bar deliberately. The rule only ever attaches to a
		-- bar that is showing mana, so a druid's energy bar — which the rule has
		-- no bearing on whatsoever — can never have its tick suppressed by it.
		--
		-- The fade is excluded: "counting down" is the five seconds, so the tick
		-- returns as the rule expires and the rule's own line fades out over it.
		local suppressTick = false
		local rule = byProvider.fsr
		if rule and rule.active and rule.cfg and rule.cfg.hideTick ~= false
			and self:IsFiveSecondRuleRunning(now) then
			suppressTick = true
		end

		for name, record in pairs(byProvider) do
			local provider = PROVIDERS[name]
			local cfg = record.cfg

			if record.active and provider and cfg and visible
				and not (name == "tick" and suppressTick)
				and provider.IsActive(state, now, cfg, record) then
				anyActive = true
				place(record, position(provider.Fraction(state, now, cfg), cfg))
				-- Two independent things multiply here: the user's opacity, which
				-- is constant, and the provider's own alpha, which is 1 except
				-- during the five second rule's fade.
				record.line:SetAlpha(provider.Alpha(state, now, cfg) * (cfg.alpha or 1))
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
--
-- `powerType` and `atMax` describe what THIS bar is showing, which the tick
-- provider needs and which differs between the power bar and the shapeshift
-- mana bar. They are passed positionally rather than in a table because this is
-- called on every power event and a per-call allocation is not wanted there.
function BarSweep:Attach(frame, bar, providerName, cfg, powerType, atMax)
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
	record.powerType = powerType
	record.atMax = atMax and true or false

	-- The tick sweep needs somewhere to start before any tick has been observed.
	-- Seeding here rather than at load means an indicator turned on mid-session
	-- begins sweeping immediately instead of sitting still until the next tick.
	if providerName == "tick" and not state.origin then
		state.origin = GetTime()
	end

	if providerName == "fsr" then
		state.trigger = cfg.trigger
	end

	-- Fully opaque here; opacity is applied through SetAlpha in Render, where it
	-- can be combined with the five second rule's fade.
	local r, g, b = Colors:Unpack(cfg.color)
	record.line:SetColorTexture(r, g, b, 1)

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

--- A rage decay tick was observed (Plan 17). Only out-of-combat decreases of a
-- plausible size reach here; NoteRagePower below is the filter.
function BarSweep:NoteRageDecay(now)
	now = now or GetTime()

	local previous = state.rageOrigin
	state.rageOrigin = now
	state.rageObserved = true

	-- The one measurement this feature exists to make honest. Only the FIRST decay
	-- after a combat drop says anything about the delay, so the pending timestamp
	-- is consumed rather than left to be re-measured by every later tick.
	if state.rageCombatEnd then
		state.rageFirstDecay = now - state.rageCombatEnd
		state.rageCombatEnd = nil
	end

	if not previous then
		self:Refresh()
		return
	end

	-- Outliers rejected rather than clamped in, the same discipline NoteTick
	-- follows and for the same reason: a long gap means a decay tick was missed,
	-- not that the cadence is slow.
	local sample = now - previous
	if sample >= RAGE_MIN_INTERVAL and sample <= RAGE_MAX_INTERVAL then
		local blended = state.rageInterval * (1 - SMOOTHING) + sample * SMOOTHING
		if blended < RAGE_MIN_INTERVAL then blended = RAGE_MIN_INTERVAL end
		if blended > RAGE_MAX_INTERVAL then blended = RAGE_MAX_INTERVAL end

		state.rageInterval = blended
		state.rageSamples = state.rageSamples + 1
	end

	self:Refresh()
end

--- The player's rage changed. Decides which of the three things it was.
function BarSweep:NoteRagePower(previous, value, now)
	-- A gain, from a swing or an ability. Not a tick, and it does not reschedule
	-- the server's decay timer either — so the phase of the last observed decay is
	-- left alone rather than pushed forward. Assuming otherwise would put the line
	-- wrong after every swing.
	if value > previous then return end

	-- In combat a decrease is a spend, and rage does not decay in combat at all.
	if UnitAffectingCombat("player") then return end

	-- Too big to be a decay tick: shifting out of bear form zeroes rage, and the
	-- reported whole-bar loss on combat drop has the same shape. The phase is
	-- dropped rather than re-based, so the line waits for a real decay tick instead
	-- of sweeping from an origin that was never a decay at all.
	if (previous - value) > RAGE_MAX_DECAY_STEP then
		state.rageOrigin = nil
		self:Refresh()
		return
	end

	self:NoteRageDecay(now)
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

	-- PLAN 17. Rage is routed out before the increase/decrease split below,
	-- because both halves of that split are wrong for it.
	--
	-- A rage INCREASE is a gain from a weapon swing or an ability, not a regen
	-- tick — and feeding it to NoteTick corrupted a value shared well beyond the
	-- rage bar. Mainhand speeds are typically 2.4-3.6s, so a large share of those
	-- gaps land inside NoteTick's accepted band and were being smoothed into
	-- `state.interval` as if they were regen samples. A druid in bear form has
	-- rage on the power bar and mana on the shapeshift mana bar reading that same
	-- state (Elements/ShapeshiftMana.lua), so every rage gain in bear form reset
	-- the phase of the MANA tick line and dragged its interval towards the bear's
	-- swing timer. The one bar where the indicator earns its keep was the one
	-- being corrupted by this.
	--
	-- A rage DECREASE is a spend in combat and a decay tick out of it, which the
	-- five second rule has no interest in either way.
	if powerType == Compat.RAGE then
		self:NoteRagePower(previous, value, now)
		return
	end

	if value > previous then
		self:NoteTick(now)
	elseif powerType == Compat.MANA then
		if self:Trigger().Detect(previous, value) then
			self:NoteManaSpent(now)
		end
	end
end

--------------------------------------------------------------------------------
-- Combat transitions (Plan 17)
--
-- Neither event is needed for the decay line to be CORRECT — `IsActive` reads the
-- combat state live and the driver re-evaluates every frame, so the line stops of
-- its own accord when a fight starts. They are registered for three things the
-- render path cannot do for itself:
--
--   * Timestamp the combat drop, which is the only way the pre-decay delay can be
--     measured rather than assumed.
--   * Drop the phase when a fight starts. Rage does not decay in combat, so by the
--     time the fight ends the origin from before it means nothing.
--   * Restart a driver that has idled to a stop. Render calls stop() when nothing
--     is active, and for a warrior with only this indicator on, nothing is active
--     for the whole fight.
--
-- Own frame rather than an element's globalEvents table, following the watcher in
-- Config/DragMode.lua: this is module state, not a property of any one frame, and
-- the module is loaded whether or not any frame wants a line.
--------------------------------------------------------------------------------

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
watcher:RegisterEvent("PLAYER_REGEN_DISABLED")
watcher:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_REGEN_ENABLED" then
		state.rageCombatEnd = GetTime()
	else
		state.rageOrigin = nil
		state.rageCombatEnd = nil
	end
	BarSweep:Refresh()
end)

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

function BarSweep:RageInterval()
	return state.rageInterval
end

function BarSweep:RageObserved()
	return state.rageObserved
end

--- Seconds from the last combat drop to the first rage decay after it, or nil if
-- that has not been seen yet. The number the plan could not find documented for
-- either client, so /duf profile reports it and it stops being a guess.
function BarSweep:RageFirstDecayDelay()
	return state.rageFirstDecay
end

--- Is rage decaying right now, as far as we can tell? The `rageOrigin` half of
-- this is the pre-decay gate: true only once rage has been seen falling.
function BarSweep:IsRageDecaying()
	if not state.rageOrigin then return false end
	return not UnitAffectingCombat("player")
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

	state.rageInterval = RAGE_DEFAULT_INTERVAL
	state.rageOrigin = nil
	state.rageObserved = false
	state.rageSamples = 0
	state.rageCombatEnd = nil
	state.rageFirstDecay = nil

	for bar in pairs(attached) do
		self:Detach(bar)
	end
end
