-- Systems/HealPrediction.lua
--
-- Plan 11 — incoming heal prediction, and the module that owns every derived
-- value behind it. Elements/HealPrediction.lua only draws.
--
--------------------------------------------------------------------------------
-- THE PREMISE
--
-- There is no incoming-heal API on these clients. UnitGetIncomingHeals arrived
-- in Cataclysm, UnitGetTotalAbsorbs in Warlords, and where a Classic client has
-- ever exposed incoming heals it covered direct casts only -- no HoTs, no
-- channels, which is two thirds of what this feature is.
--
-- So this module does not READ its data. It DERIVES it, and every decision
-- below follows from that.
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
-- State
--
-- `current` is a single record rather than a list, and that is correct rather
-- than a simplification: the player has one cast bar. Two heals cannot be in
-- flight at once.
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
-- Providers
--
-- Shaped like BarSweep.PROVIDERS and BarSweep.TRIGGERS: a named table of
-- strategies, so adding one is a table entry and not a reshape.
--
-- One entry today. The second is `healcomm`, which would see heals cast by
-- other group members running a LibHealComm addon; it is a separate plan and a
-- separate dependency decision. NO DROPDOWN IS BUILT WHILE THERE IS ONE ENTRY
-- -- the precedent Plan 10 set for the five-second-rule trigger, for the same
-- reason: a control with a single value is noise.
--
-- If the Compat probes ever come back positive, an `api` provider slots in
-- here too -- and would still need `own` for the HoT half, which that API has
-- never covered.
--------------------------------------------------------------------------------

HealPrediction.PROVIDERS = {
	own = {
		label = L["My casts only"],
		desc = L["Heals you cast yourself. Other people's heals are not broadcast by these clients, so nothing else is knowable without a comms library."],
	},
}

HealPrediction.DEFAULT_PROVIDER = "own"

function HealPrediction:ProviderNames()
	return { "own" }
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

	local direct = 0
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

--- Healing still to come from the player's own HoTs on `unit`.
--
-- A HoT is not tracked by remembering that we cast it -- it is READ OFF THE
-- UNIT every time. That is deliberate: the aura is the authoritative record of
-- whether it is still there and when it expires, so a refresh, an early
-- dispel, a death or a zone change all resolve themselves with no bookkeeping
-- and no way for our copy to drift out of agreement with the game's.
function HealPrediction:HotTotal(unit, now)
	-- Nothing periodic learned yet means nothing can match; skip the scan
	-- entirely rather than walking forty aura slots to find that out.
	if next(learned.periodic) == nil then return 0 end

	now = now or GetTime()
	local total = 0

	for index = 1, MAX_AURA_SCAN do
		local aura = Compat.GetAura(unit, index, "HELPFUL")
		if not aura then break end

		local spellID = aura.spellId
		local per = spellID and learned.periodic[spellID]

		-- expirationTime of 0 means no duration, which a HoT never has.
		if per and aura.castByPlayer and aura.expirationTime and aura.expirationTime > now then
			local interval = learned.interval[spellID] or DEFAULT_TICK
			local ticks = ceil((aura.expirationTime - now) / interval)
			if ticks > 0 then total = total + ticks * per end
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
function HealPrediction:NoteHeal(spellID, amount, overhealing, critical, periodic)
	if not spellID then return end

	-- Crits are discarded, not scaled down. A crit is drawn from a different
	-- distribution, and dividing by 1.5 would be asserting a crit multiplier
	-- this module has no business claiming to know.
	if critical then return end

	local total = (amount or 0) + (overhealing or 0)
	if total <= 0 then return end

	blend(periodic and learned.periodic or learned.direct, spellID, total)
end

--- Observe the gap between two consecutive ticks of the same HoT.
--
-- Guarded on the tick having been on the SAME target: two Rejuvenations
-- ticking on two party members interleave, and the gap between one target's
-- tick and another's is not a tick interval at all.
function HealPrediction:NoteTick(spellID, guid, now)
	if not spellID or not guid then return end
	now = now or GetTime()

	local previous = state.lastTick[spellID]
	state.lastTick[spellID] = { guid = guid, at = now }

	if not previous or previous.guid ~= guid then return end

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
--   * one comparison against a hoisted local before anything else happens,
--   * no table built per line, no string operation on the discard path,
--   * positional unpacking straight into locals, which allocates nothing.
--
-- The base payload is eleven fields; SPELL_HEAL and SPELL_PERIODIC_HEAL then
-- carry spellId, spellName, spellSchool, amount, overhealing, absorbed,
-- critical -- so the fields wanted are 2, 4, 8, 12, 15, 16 and 18.
function HealPrediction:OnCombatLog()
	local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _,
		spellID, _, _, amount, overhealing, _, critical = Compat.GetCombatLogEvent()

	if not state.playerGUID or sourceGUID ~= state.playerGUID then return end

	if subevent == "SPELL_HEAL" then
		self:NoteHeal(spellID, amount, overhealing, critical, false)
	elseif subevent == "SPELL_PERIODIC_HEAL" then
		self:NoteHeal(spellID, amount, overhealing, critical, true)
		self:NoteTick(spellID, destGUID)
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
	for i = 1, #SPELLCAST_EVENTS do
		Compat.RegisterUnitEvent(listener, SPELLCAST_EVENTS[i], "player")
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

--- One line for /duf profile.
function HealPrediction:Describe()
	local direct, periodic = self:LearnedCount()
	return string.format(
		listening and L["listening, %d frame(s), %d direct and %d periodic spell(s) learned"]
			or L["not listening (%d frames, %d direct and %d periodic spell(s) learned)"],
		self:AttachedCount(), direct, periodic)
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
end

ns.HealPrediction = HealPrediction
