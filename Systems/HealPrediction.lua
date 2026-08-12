-- Systems/HealPrediction.lua
--
-- Plans 11 and 19 — incoming heal prediction. Elements/HealPrediction.lua only
-- draws.
--
--------------------------------------------------------------------------------
-- THE PREMISE, AND HOW IT CHANGED
--
-- Plan 11 was built on "there is no incoming-heal API on these clients", and
-- derived every number from the combat log instead. That premise was wrong.
-- UnitGetIncomingHeals is present on both clients, works, and includes OTHER
-- PLAYERS' heals with about a second of lead time (COMPAT_FINDINGS, 11 Aug
-- 2026). The expansion-era reasoning behind the assumption is the same mistake
-- that lost UNIT_COMBO_POINTS: these clients run modern shared code.
--
-- So the module now has two halves with two different sources, and they are
-- SUMMED rather than chosen between:
--
--   DIRECT casts, from anyone   -> UnitGetIncomingHeals, pushed by
--                                  UNIT_HEAL_PREDICTION. Nothing derived.
--   HoTs, from anyone           -> read off the unit's auras, sized by amounts
--                                  learned from the combat log. All of Plan 11's
--                                  machinery, still earning its place.
--
-- The API does not cover HoTs -- measured, not assumed: a Rejuvenation ticking
-- on the player read zero across 900 samples. That disjointness is what makes
-- summing them correct, and if it ever stops being true this file double-counts.
--
-- Plan 11's derived direct-cast path is KEPT as the fallback for any client
-- without the API. Compat.GetIncomingHeals returns nil rather than 0 there,
-- which is the branch. The two are never added together: the API total already
-- includes the player's own casts.
--
--------------------------------------------------------------------------------
-- WHY THERE IS NO SPELL DATABASE
--
-- The conventional answer is a table of base heal amounts per rank, a
-- spellpower coefficient and a talent multiplier, per class, across two
-- expansions. That is what LibHealComm carries. It is thousands of lines, it
-- silently goes stale, and it is wrong the moment anything about the character
-- changes.
--
-- Instead the numbers are LEARNED from the player's own combat log. A heal you
-- have cast once is a heal this module can size, with your gear, your talents,
-- your buffs and any Blizzard rebalance already baked in, because the number
-- came from the game rather than from an assumption about the game.
--
-- This is the same bet Plan 2 makes on the regen tick: derive the value and let
-- it self-correct, rather than hardcoding 2.0 and hoping. It even reuses that
-- module's smoothing constant, deliberately.
--
-- The cost is stated rather than hidden: A SPELL YOU HAVE NEVER CAST PREDICTS
-- NOTHING. The first Flash of Heal of a character's life shows no bar; every
-- one after it does. That is the honest failure mode, and it is strictly better
-- than a confidently wrong number.
--
--------------------------------------------------------------------------------
-- WHY THERE IS NO FIFTH TICKER
--
-- SPEC §5.7 closes the list of permitted tickers and Plan 2 already had to
-- argue a fourth one onto it. This module needs none, and that is designed
-- rather than lucky:
--
--   * A direct cast's prediction changes at cast start and cast end. Events.
--   * A HoT's remainder changes when a tick lands or the aura is applied,
--     refreshed or removed. Events -- SPELL_PERIODIC_HEAL and UNIT_AURA.
--   * Between those moments the predicted number is CONSTANT, so there is
--     nothing for a timer to do.
--
-- Staleness is handled by LAZY EXPIRY: IncomingHeal compares GetTime() against
-- the stored cast end at read time and drops anything past it. No timer object,
-- nothing to leak, nothing to idle.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

local HealPrediction = {}
ns.HealPrediction = HealPrediction

local UnitGUID, UnitExists, UnitName = UnitGUID, UnitExists, UnitName
local GetTime = GetTime
local ceil = math.ceil

--- True when the game will tell us about incoming direct heals itself. Read
-- once at load: the function does not appear mid-session, and this decides
-- which events the listener subscribes to.
local API_DIRECT = Compat.hasIncomingHeals and true or false

--- Shared with Systems/BarSweep deliberately: both are blending a noisy
-- observation into a running estimate, and two different constants would be two
-- different answers to the same question.
local SMOOTHING = 0.3

--- Most Classic and TBC HoTs tick every three seconds. Used only until the
-- real interval has been observed, and bounded so one bad sample cannot make a
-- HoT predict a hundred ticks.
local DEFAULT_TICK = 3.0
local MIN_TICK, MAX_TICK = 1.0, 6.0

--- How long past a cast's expected end a prediction still counts. Covers
-- latency between the client finishing the cast bar and the heal landing.
local EXPIRY_GRACE = 1.0

local MAX_AURA_SCAN = 40

--- Units this addon can actually draw. UNIT_SPELLCAST_SENT reports its target
-- as a NAME, so it has to be resolved against something; this list is both the
-- resolution set and the scope limit, since a heal on anything not in it has no
-- frame to be drawn on anyway.
local CANDIDATE_UNITS = {
	"player", "pet", "target", "focus",
	"party1", "party2", "party3", "party4",
	"partypet1", "partypet2", "partypet3", "partypet4",
	"targettarget", "focustarget",
}

--------------------------------------------------------------------------------
-- Learned amounts
--
-- Bound to ns.db.char by Core once the database exists -- per character,
-- because a heal's size is a function of THIS character's gear and talents.
-- Until then, and in tests, an in-memory table stands in so nothing has to
-- nil-check the store on every combat-log line.
--------------------------------------------------------------------------------

local function newStore()
	return { direct = {}, periodic = {}, interval = {} }
end

local learned = newStore()

--- Point the module at the saved store. Called from Core:OnInitialize.
function HealPrediction:BindStore(store)
	if type(store) ~= "table" then return end
	store.direct = store.direct or {}
	store.periodic = store.periodic or {}
	store.interval = store.interval or {}
	learned = store
end

function HealPrediction:Store()
	return learned
end

local function blend(into, key, sample)
	local previous = into[key]
	if not previous then
		into[key] = sample
		return
	end
	into[key] = previous * (1 - SMOOTHING) + sample * SMOOTHING
end

--- How many distinct spells have been learned. Reported by /duf profile,
-- because "predicts nothing until it has seen one" is only a defensible design
-- if the user can see what it has seen.
function HealPrediction:LearnedCount()
	local direct, periodic = 0, 0
	for _ in pairs(learned.direct) do direct = direct + 1 end
	for _ in pairs(learned.periodic) do periodic = periodic + 1 end
	return direct, periodic
end

--------------------------------------------------------------------------------
-- Other people's HoTs (Plan 19)
--
-- The API covers direct casts only, so a group member's Rejuvenation is still
-- something this module has to size itself. Two structures do it.
--
-- ROSTER is a GUID set rebuilt on GROUP_ROSTER_UPDATE. It is the combat-log
-- guard: Plan 11's first line was one comparison against the player's own GUID,
-- and this replaces it with one hash lookup against a table that holds exactly
-- one entry when you are solo. The hot path keeps its shape -- what changes is
-- the contents of a table, not the cost of the noisiest event in the game.
--
-- SESSION holds per-caster tick amounts and is NEVER PERSISTED. It is observed
-- data keyed by another player's GUID: saving it would grow without bound across
-- every group you ever join, and it is stale the moment they change gear.
-- Relearning costs one tick. Written only for roster GUIDs and pruned when they
-- leave, so it is bounded by group size.
--------------------------------------------------------------------------------

local roster = {}

local function newSession()
	return {
		periodic = {},   -- casterGUID -> spellID -> amount
		mean = {},       -- spellID -> amount, blended across every caster seen
	}
end

local session = newSession()

--- Rebuild the roster GUID set, and drop session data for anyone who left.
--
-- Pruning is a side effect of a rebuild that is already happening, which is why
-- there is no separate sweep to test or forget to call.
local function rebuildRoster()
	local next_ = {}

	-- Read straight from the game rather than from `state`, which is declared
	-- below this and would be captured as a nil global if named here.
	local playerGUID = UnitGUID("player")
	if playerGUID then next_[playerGUID] = true end

	local total = (GetNumGroupMembers and GetNumGroupMembers()) or 0
	local inRaid = IsInRaid and IsInRaid()
	for i = 1, (inRaid and total or (total - 1)) do
		local guid = UnitGUID((inRaid and "raid" or "party") .. i)
		if guid then next_[guid] = true end
	end

	roster = next_

	for guid in pairs(session.periodic) do
		if not roster[guid] then session.periodic[guid] = nil end
	end
end

--- Per-tick amount for `spellID` cast by `casterGUID`.
--
-- Read order, and each step is a real fallback rather than a guess dressed up:
--   1. what THIS caster's ticks have measured,
--   2. the cross-caster mean for the spell -- a different priest's Renew is
--      still a Renew, and one real observation blends the estimate away,
--   3. nothing. Predict zero, which is Plan 11's documented honest failure
--      applied unchanged to a wider set of casters.
local function periodicAmount(casterGUID, spellID)
	local byCaster = casterGUID and session.periodic[casterGUID]
	local amount = byCaster and byCaster[spellID]
	if amount then return amount end
	return session.mean[spellID]
end

--------------------------------------------------------------------------------
-- State
--
-- `current` is a single record rather than a list, and that is correct rather
-- than a simplification: the player has one cast bar. Two heals cannot be in
-- flight at once.
--
-- It is only ever populated on a client WITHOUT UnitGetIncomingHeals. Where the
-- API exists the spellcast events are never registered at all.
--------------------------------------------------------------------------------

local state = {
	playerGUID = nil,
	current = nil,      -- { guid, spellID, amount, endTime, channel }
	sent = {},          -- castGUID -> { guid, at }
	lastTick = {},      -- spellID -> { guid, at }   (tick-interval learning)
}
HealPrediction.state = state

--- Entries are added on UNIT_SPELLCAST_SENT and consumed on _START, so the
-- table holds one or two at a time in normal play. Pruning on insert bounds it
-- anyway, because a spell that is SENT and never STARTed -- out of range, target
-- died, cast canceled before the server answered -- leaves its entry behind.
local SENT_TTL = 10

local function rememberSent(castGUID, guid, now)
	if not castGUID then return end
	for key, record in pairs(state.sent) do
		if now - record.at > SENT_TTL then state.sent[key] = nil end
	end
	state.sent[castGUID] = { guid = guid, at = now }
end

--------------------------------------------------------------------------------
-- Name resolution
--------------------------------------------------------------------------------

--- Resolve a cast target's NAME to a GUID, against the units we draw.
-- A fixed scan of at most fourteen units, run once per cast rather than per
-- frame or per event.
local function resolveTargetName(name)
	if not name or name == "" then return nil end
	for i = 1, #CANDIDATE_UNITS do
		local unit = CANDIDATE_UNITS[i]
		if UnitExists(unit) and UnitName(unit) == name then
			return UnitGUID(unit)
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Which direct-cast path is live
--
-- Plan 11 described this as a table of interchangeable strategies and predicted
-- a second entry would arrive as a user setting. Neither happened, and the
-- reason is worth keeping: THE CHOICE IS NOT THE USER'S. Whether the game
-- reports other people's heals is a property of the client, so a dropdown
-- offering to restrict the source would be a lie on the client where it cannot
-- be restricted, and a redundant control on the one where it never needed to be.
--
-- These entries are therefore descriptive, not selectable. `/duf compat` and
-- `/duf profile` report which one is live, which is the question anyone actually
-- has. Same reasoning Plan 10 used to withhold a one-value dropdown -- a control
-- whose value is decided elsewhere is noise.
--------------------------------------------------------------------------------

HealPrediction.PROVIDERS = {
	api = {
		label = L["Everyone's heals, from the game"],
		desc = L["UnitGetIncomingHeals reports direct heals from anyone, pushed by UNIT_HEAL_PREDICTION. HoTs are not in it and are read off the unit's auras instead."],
	},
	own = {
		label = L["My casts only"],
		desc = L["The fallback for a client with no incoming-heal API: heals you cast yourself, sized from your own combat log."],
	},
}

HealPrediction.DEFAULT_PROVIDER = "own"

--- Which path this client is on. Not a setting.
function HealPrediction:DirectProvider()
	return API_DIRECT and "api" or "own"
end

function HealPrediction:ProviderNames()
	return { "api", "own" }
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

--- Predicted healing about to land on `unit`.
-- @return direct, hot  -- absolute health points, 0 for anything unknown
function HealPrediction:IncomingHeal(unit, now)
	if not unit then return 0, 0 end
	local guid = UnitGUID(unit)
	if not guid then return 0, 0 end
	return self:IncomingForGUID(guid, unit, now)
end

function HealPrediction:IncomingForGUID(guid, unit, now)
	now = now or GetTime()

	local direct

	-- The API where the client has it. It already includes the player's own
	-- casts, so the derived path below is an ALTERNATIVE, never an addend --
	-- summing them would double-count every heal you cast, which looks entirely
	-- plausible on screen and is the easiest defect in this file to ship.
	--
	-- nil, not 0, is what "no such API" returns, and a unit token is needed to
	-- ask at all: IncomingForGUID can be called with a bare GUID.
	if unit then direct = Compat.GetIncomingHeals(unit) end
	if direct then
		local hotOnly = unit and self:HotTotal(unit, now) or 0
		return direct, hotOnly
	end

	direct = 0
	local current = state.current

	if current then
		-- Lazy expiry. This is the whole of the staleness handling and the
		-- reason no timer exists: a prediction nobody reads never needs to be
		-- cleaned up, and one that is read is checked at the moment it matters.
		if now > current.endTime + EXPIRY_GRACE then
			state.current = nil
		elseif current.guid == guid then
			if current.channel then
				-- A channel is a HoT with a cast bar: what is still coming is
				-- the ticks that have not happened yet, which shrinks as the
				-- channel runs without anything having to poll it.
				local per = learned.periodic[current.spellID]
				if per then
					local interval = learned.interval[current.spellID] or DEFAULT_TICK
					local ticks = ceil((current.endTime - now) / interval)
					if ticks > 0 then direct = ticks * per end
				end
			else
				direct = current.amount
			end
		end
	end

	local hot = 0
	if unit then hot = self:HotTotal(unit, now) end

	return direct, hot
end

--- Healing still to come from HoTs on `unit`, cast by anyone in the group.
--
-- A HoT is not tracked by remembering that we cast it -- it is READ OFF THE
-- UNIT every time. That is deliberate: the aura is the authoritative record of
-- whether it is still there and when it expires, so a refresh, an early
-- dispel, a death or a zone change all resolve themselves with no bookkeeping
-- and no way for our copy to drift out of agreement with the game's.
--
-- Plan 19 widened this from the player's own HoTs to the group's, and the whole
-- of the detection change is that `aura.castByPlayer` became a roster test.
-- `aura.source` is a UNIT TOKEN and is nil when the caster has no token, which
-- is precisely the non-group case -- so group-only scoping falls out of the data
-- rather than needing a second test. Verified to survive raid distance:
-- COMPAT_FINDINGS, "an aura's caster resolves at raid distance".
function HealPrediction:HotTotal(unit, now)
	-- Nothing learned anywhere means nothing can match; skip the scan entirely
	-- rather than walking forty aura slots to find that out. Both stores have to
	-- be empty now, not just the player's.
	if next(learned.periodic) == nil and next(session.mean) == nil then return 0 end

	now = now or GetTime()
	local total = 0

	for index = 1, MAX_AURA_SCAN do
		local aura = Compat.GetAura(unit, index, "HELPFUL")
		if not aura then break end

		local spellID = aura.spellId
		-- expirationTime of 0 means no duration, which a HoT never has.
		if spellID and aura.expirationTime and aura.expirationTime > now then
			local casterGUID
			if aura.castByPlayer then
				casterGUID = state.playerGUID
			elseif aura.source then
				casterGUID = UnitGUID(aura.source)
			end

			if casterGUID and roster[casterGUID] then
				local per = (casterGUID == state.playerGUID
					and learned.periodic[spellID])
					or periodicAmount(casterGUID, spellID)
				if per then
					local interval = learned.interval[spellID] or DEFAULT_TICK
					local ticks = ceil((aura.expirationTime - now) / interval)
					if ticks > 0 then total = total + ticks * per end
				end
			end
		end
	end

	return total
end

--------------------------------------------------------------------------------
-- Learning
--------------------------------------------------------------------------------

--- Record an observed heal.
--
-- `overhealing` is added rather than discarded, and this is the single most
-- important line in the module. A heal landing on a nearly-full target reports
-- an `amount` of almost nothing; learning from that would teach the estimator
-- that Greater Heal heals for forty, and it would do it most reliably on
-- exactly the targets a healer is watching. What is being learned is the SIZE
-- OF THE HEAL, and the size of the heal is what it did plus what it wasted.
-- @param casterGUID  nil means the player, which keeps every existing caller
--        and every Plan 11 test working unchanged.
function HealPrediction:NoteHeal(spellID, amount, overhealing, critical, periodic, casterGUID)
	if not spellID then return end

	-- Crits are discarded, not scaled down. A crit is drawn from a different
	-- distribution, and dividing by 1.5 would be asserting a crit multiplier
	-- this module has no business claiming to know.
	if critical then return end

	local total = (amount or 0) + (overhealing or 0)
	if total <= 0 then return end

	if not casterGUID or casterGUID == state.playerGUID then
		blend(periodic and learned.periodic or learned.direct, spellID, total)
		-- The player's own periodic amounts seed the cross-caster mean too. It
		-- is a first guess for a healer nobody has watched yet, and one real
		-- observation of theirs blends it away.
		if periodic then blend(session.mean, spellID, total) end
		return
	end

	-- Somebody else's. Direct amounts are not learned for other casters at all:
	-- the API reports those, so a store of them would be dead weight that also
	-- has to be kept correct.
	if not periodic then return end

	local byCaster = session.periodic[casterGUID]
	if not byCaster then
		byCaster = {}
		session.periodic[casterGUID] = byCaster
	end
	blend(byCaster, spellID, total)
	blend(session.mean, spellID, total)
end

--- Observe the gap between two consecutive ticks of the same HoT.
--
-- Guarded on the tick having been on the SAME target: two Rejuvenations
-- ticking on two party members interleave, and the gap between one target's
-- tick and another's is not a tick interval at all.
--
-- Plan 19 opened the same trap sideways. TWO DRUIDS' REJUVENATIONS ON ONE
-- TARGET also interleave, and that gap is not an interval either, so the caster
-- has to match as well. The interval itself stays global per spell -- Classic
-- has no meaningful haste, so a Rejuvenation ticks every three seconds for
-- everybody. What changed is that the samples feeding it stopped being noise.
function HealPrediction:NoteTick(spellID, guid, now, casterGUID)
	if not spellID or not guid then return end
	now = now or GetTime()

	local previous = state.lastTick[spellID]
	state.lastTick[spellID] = { guid = guid, at = now, caster = casterGUID }

	if not previous or previous.guid ~= guid then return end
	if previous.caster ~= casterGUID then return end

	local sample = now - previous.at
	-- Out of band is a MISSED observation, not evidence of a strange cadence --
	-- the same reasoning BarSweep:NoteTick applies to a skipped regen tick.
	if sample < MIN_TICK or sample > MAX_TICK then return end

	blend(learned.interval, spellID, sample)

	local blended = learned.interval[spellID]
	if blended < MIN_TICK then learned.interval[spellID] = MIN_TICK end
	if blended > MAX_TICK then learned.interval[spellID] = MAX_TICK end
end

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------

--- Every combat-log line in the game arrives here while this is listening, so
-- the shape of this function is a performance decision, not a style one:
--
--   * one hash lookup against a hoisted local before anything else happens,
--   * no table built per line, no string operation on the discard path,
--   * positional unpacking straight into locals, which allocates nothing.
--
-- Plan 11's first line was one comparison against the player's GUID. Plan 19
-- made it a lookup in the roster set, which is the same order of work and the
-- same absence of allocation -- and in a group of one the set holds exactly one
-- entry, so the solo case did not get slower either. What widened is the
-- CONTENTS of a table, not the cost of the noisiest event in the game.
--
-- The base payload is eleven fields; SPELL_HEAL and SPELL_PERIODIC_HEAL then
-- carry spellId, spellName, spellSchool, amount, overhealing, absorbed,
-- critical -- so the fields wanted are 2, 4, 8, 12, 15, 16 and 18.
function HealPrediction:OnCombatLog()
	local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _,
		spellID, _, _, amount, overhealing, _, critical = Compat.GetCombatLogEvent()

	if not sourceGUID or not roster[sourceGUID] then return end

	if subevent == "SPELL_HEAL" then
		-- With the API live this is the player's own direct amounts only, and
		-- they are no longer read by anything. Kept because the moment the API
		-- is absent they are the whole direct prediction, and because learning
		-- costs nothing on a line already being parsed.
		self:NoteHeal(spellID, amount, overhealing, critical, false, sourceGUID)
	elseif subevent == "SPELL_PERIODIC_HEAL" then
		self:NoteHeal(spellID, amount, overhealing, critical, true, sourceGUID)
		self:NoteTick(spellID, destGUID, nil, sourceGUID)
		-- A tick landed, so one fewer is still to come. The bar has to be told:
		-- this is the event that replaces the ticker a HoT would otherwise need.
		self:Refresh(destGUID)
	end
end

function HealPrediction:OnSpellcast(event, castGUID, spellID, targetName)
	local now = GetTime()

	if event == "UNIT_SPELLCAST_SENT" then
		-- The only event carrying the target, and it carries it as a name.
		rememberSent(castGUID, resolveTargetName(targetName), now)
		return
	end

	if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
		local channel = (event == "UNIT_SPELLCAST_CHANNEL_START")

		-- An unlearned spell predicts nothing. Documented, asserted in the
		-- tests, and the reason there is no rank table in this file.
		local amount = channel and learned.periodic[spellID] or learned.direct[spellID]
		if not amount then return self:Clear() end

		local record = state.sent[castGUID]
		-- A channel reports no target: it is cast on whoever is targeted at the
		-- time, and self-channels are the common case. Fall back to the current
		-- target and then to the player rather than dropping it.
		local guid = record and record.guid
		if not guid and channel then
			guid = (UnitExists("target") and UnitGUID("target")) or UnitGUID("player")
		end
		if not guid then return self:Clear() end

		local endTime = Compat.GetCastEndTime("player")
		if not endTime then return self:Clear() end

		state.current = {
			guid = guid,
			spellID = spellID,
			amount = channel and 0 or amount,
			endTime = endTime,
			channel = channel,
		}
		state.sent[castGUID] = nil
		self:Refresh(guid)
		return
	end

	if event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
		-- Pushback, or a channel clipped short. The amount is unchanged; only
		-- the window it occupies moved.
		local current = state.current
		if current then
			local endTime = Compat.GetCastEndTime("player")
			if endTime then
				current.endTime = endTime
				self:Refresh(current.guid)
			end
		end
		return
	end

	-- Everything else -- SUCCEEDED, STOP, INTERRUPTED, FAILED, CHANNEL_STOP --
	-- means the cast is over and the heal has either landed or will not.
	self:Clear()
end

function HealPrediction:Clear()
	local current = state.current
	if not current then return end
	state.current = nil
	self:Refresh(current.guid)
end

--------------------------------------------------------------------------------
-- Pushing to frames
--------------------------------------------------------------------------------

--- Redraw every visible frame currently showing `guid`.
--
-- A unit is not one frame: the same person can be your target, your focus and
-- party3 at once. Walking the frame table is a fixed cost over at most a dozen
-- entries and happens only when a prediction actually changed.
function HealPrediction:Refresh(guid)
	if not guid then return end

	for _, frame in pairs(ns.frames) do
		if frame.configured and frame.activeElements
			and frame.activeElements.healPrediction
			and frame:IsShown() and frame.unit and UnitGUID(frame.unit) == guid then
			frame:UpdateElement("healPrediction")
		end
	end
end

--------------------------------------------------------------------------------
-- The listener
--
-- COMBAT_LOG_EVENT_UNFILTERED cannot be unit-filtered and is the noisiest event
-- in the game -- thousands of lines a minute in a raid, against SPEC §6's
-- 0.5 ms/frame budget. So it follows BarSweep's attach/detach discipline
-- exactly: with the feature off this is not merely idle, IT IS NOT SUBSCRIBED.
--
-- /duf profile reports which, because "is it actually idle when it should be
-- idle" is the property that justifies the cost.
--------------------------------------------------------------------------------

local SPELLCAST_EVENTS = {
	"UNIT_SPELLCAST_SENT",
	"UNIT_SPELLCAST_START",
	"UNIT_SPELLCAST_STOP",
	"UNIT_SPELLCAST_SUCCEEDED",
	"UNIT_SPELLCAST_INTERRUPTED",
	"UNIT_SPELLCAST_FAILED",
	"UNIT_SPELLCAST_DELAYED",
	"UNIT_SPELLCAST_CHANNEL_START",
	"UNIT_SPELLCAST_CHANNEL_UPDATE",
	"UNIT_SPELLCAST_CHANNEL_STOP",
}

local listener = nil
local listening = false
local attached = {}

local function onListenerEvent(_, event, a, b, c, d)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		HealPrediction:OnCombatLog()
	elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LOGIN" then
		state.playerGUID = UnitGUID("player")
		rebuildRoster()
	elseif event == "GROUP_ROSTER_UPDATE" then
		rebuildRoster()
	elseif event == "UNIT_SPELLCAST_SENT" then
		-- SENT alone puts the target where the others put the castGUID:
		-- (unit, target, castGUID, spellID).
		HealPrediction:OnSpellcast(event, c, d, b)
	else
		-- (unit, castGUID, spellID)
		HealPrediction:OnSpellcast(event, b, c)
	end
end

local function start()
	if listening then return end

	if not listener then
		listener = CreateFrame("Frame")
		listener:SetScript("OnEvent", onListenerEvent)
	end

	state.playerGUID = state.playerGUID or UnitGUID("player")

	Compat.RegisterEvent(listener, "COMBAT_LOG_EVENT_UNFILTERED")
	Compat.RegisterEvent(listener, "PLAYER_ENTERING_WORLD")
	-- The roster is both the combat-log guard and the HoT scope test, so it has
	-- to be current before either is consulted.
	Compat.RegisterEvent(listener, "GROUP_ROSTER_UPDATE")
	rebuildRoster()

	-- Ten subscriptions that exist ONLY to reconstruct a number the game will
	-- hand over on a client that has UnitGetIncomingHeals. Where it does, they
	-- are not registered at all -- the cheapest possible version of Plan 11's
	-- direct-cast machinery is not running it.
	if not API_DIRECT then
		for i = 1, #SPELLCAST_EVENTS do
			Compat.RegisterUnitEvent(listener, SPELLCAST_EVENTS[i], "player")
		end
	end

	listening = true
end

local function stop()
	if not listening then return end
	if listener then listener:UnregisterAllEvents() end
	state.current = nil
	listening = false
end

--- Record whether `frame` wants prediction, and start or stop the listener to
-- match. Called from the element's Layout and Disable, which are the two points
-- where that intent is known.
function HealPrediction:SetActive(frame, active)
	if not frame then return end

	if active then
		attached[frame] = true
	else
		attached[frame] = nil
	end

	if next(attached) ~= nil then start() else stop() end
end

function HealPrediction:IsListening()
	return listening
end

function HealPrediction:AttachedCount()
	local n = 0
	for _ in pairs(attached) do n = n + 1 end
	return n
end

--- How many other casters this session has learned HoT amounts for, and how
-- many spells across all of them. Reported so the session store's size is
-- observable rather than asserted to be bounded.
function HealPrediction:SessionCount()
	local casters, spells = 0, 0
	for _, byCaster in pairs(session.periodic) do
		casters = casters + 1
		for _ in pairs(byCaster) do spells = spells + 1 end
	end
	return casters, spells
end

function HealPrediction:RosterCount()
	local n = 0
	for _ in pairs(roster) do n = n + 1 end
	return n
end

--- One line for /duf profile.
--
-- Reports WHICH DIRECT PATH IS LIVE, because that is now a property of the
-- client rather than a setting, and "why am I not seeing other people's heals"
-- has exactly one useful answer.
function HealPrediction:Describe()
	local direct, periodic = self:LearnedCount()
	local casters = self:SessionCount()
	return string.format(
		listening and L["listening, %d frame(s), %s direct, %d/%d spell(s) learned, %d other caster(s), roster %d"]
			or L["not listening (%d frames, %s direct, %d/%d spell(s) learned, %d other caster(s), roster %d)"],
		self:AttachedCount(), self:DirectProvider(), direct, periodic,
		casters, self:RosterCount())
end

--- Drop every derived value. Used by the test suite; there is no in-game path
-- that needs it, since the learned store is meant to persist and the rest is
-- per-cast by nature.
function HealPrediction:Reset()
	state.playerGUID = nil
	state.current = nil
	state.sent = {}
	state.lastTick = {}
	for frame in pairs(attached) do attached[frame] = nil end
	stop()
	learned = newStore()
	session = newSession()
	roster = {}
end

ns.HealPrediction = HealPrediction
