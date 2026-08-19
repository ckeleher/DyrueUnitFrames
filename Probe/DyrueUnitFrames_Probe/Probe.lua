-- DyrueUnitFrames_Probe
--
-- PLAN.md Phase 0, tasks 0.1 - 0.4 and 0.8.
--
-- This is NOT disposable. The patch-day playbook (PLAN §11 step 4) says to
-- re-run it and diff the output against COMPAT_FINDINGS.md, so it stays in the
-- repository and stays current. It deliberately has no library dependencies:
-- on a patch that breaks Ace3, this must still load.
--
-- Usage:
--   /dufprobe            static API survey, written to chat and SavedVariables
--   /dufprobe mana       60-second shapeshift power-event trace (task 0.2)
--   /dufprobe derived    target-of-target / focus event trace (task 0.3)
--   /dufprobe health     enemy health scaling on the current target (task 0.4)
--   /dufprobe portrait   2D and 3D portrait feasibility (task 0.8)
--   /dufprobe auraorder  60-second aura index stability trace (Plan 14)
--   /dufprobe rage       90-second rage decay trace (Plan 17)
--   /dufprobe heals [label]
--                        90-second group heal sourcing trace (Plan 19). Answers
--                        whether other players' casts and HoTs are knowable at
--                        all. Run it in a party or raid, mid-fight; runs
--                        accumulate in DyrueUnitFramesProbeDB.healsRuns, so
--                        label them and /reload once at the end.
--   /dufprobe healcomm [label]
--                        90-second LibHealComm listener (Plan 19). Counts how
--                        many of the raid's healers still broadcast on the LHC40
--                        wire format, which is what decides whether a
--                        receive-only reader is worth designing. Receive-only:
--                        it never transmits.
--   /dufprobe incoming [label]
--                        90-second UnitGetIncomingHeals trace (Plans 11/12/19).
--                        /duf compat says the function EXISTS on Anniversary;
--                        this asks whether it works, whether it covers other
--                        people's heals, and how far ahead of the landing heal
--                        it says so. Also samples UnitGetTotalAbsorbs.
--   /dufprobe secrets [label]
--                        SPEC §1.3 and §FR-8.5. Are any values the text engine
--                        reads actually secret, and does focus really work on
--                        this client? Instant, no trace. Never sets focus.
--   /dufprobe scroll [label]
--                        options panel geometry (Plan 3). Chat gets a summary;
--                        the full ancestry, anchors and overflow list go to
--                        DyrueUnitFramesProbeDB.scrollRuns, which does not
--                        truncate the way the chat frame does. Runs accumulate,
--                        so label them and /reload once at the end.
--   /dufprobe dump       re-print the last survey

local ADDON = ...

DyrueUnitFramesProbeDB = DyrueUnitFramesProbeDB or {}

local function out(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffProbe|r " .. table.concat(parts, " "))
end

local function header(text)
	out("|cffffcc00== " .. text .. " ==|r")
end

local function yn(value)
	if value == nil then return "|cff808080nil|r" end
	if value then return "|cff40ff40yes|r" end
	return "|cffff5555no|r"
end

--- Put a trace's record into SavedVariables the moment it STARTS.
--
-- The mana and rage traces below have always done this. The Plan 19 traces did
-- not: they built a record, ran for ninety seconds and wrote at the end, so a
-- /reload before the timer fired discarded the entire run and left nothing
-- behind to say it had ever happened. Ninety seconds of a raid is not a cheap
-- thing to lose to a keystroke.
--
-- `completed` is the point of the exercise. A partial record read as a finished
-- one is worse than no record, so it starts false and is set true only by the
-- trace's own timer. Anything reading these runs must check it.
local function registerRun(key, record)
	record.completed = false
	local runs = DyrueUnitFramesProbeDB[key .. "Runs"] or {}
	runs[#runs + 1] = record
	while #runs > 10 do table.remove(runs, 1) end
	DyrueUnitFramesProbeDB[key .. "Runs"] = runs
	-- The same table, not a copy, so everything the trace records lands here.
	DyrueUnitFramesProbeDB[key .. "Trace"] = record
	return runs
end

--------------------------------------------------------------------------------
-- Static survey (task 0.1)
--------------------------------------------------------------------------------

local eventProbeFrame = CreateFrame("Frame")

local function eventExists(event)
	if C_EventUtils and C_EventUtils.IsEventValid then
		local ok, valid = pcall(C_EventUtils.IsEventValid, event)
		if ok then return valid and true or false end
	end
	local ok = pcall(eventProbeFrame.RegisterEvent, eventProbeFrame, event)
	if ok then pcall(eventProbeFrame.UnregisterEvent, eventProbeFrame, event) end
	return ok and true or false
end

local function exists(path)
	local current = _G
	for part in path:gmatch("[^%.]+") do
		if type(current) ~= "table" then return false end
		current = current[part]
		if current == nil then return false end
	end
	return true
end

local API_PATHS = {
	"C_UnitAuras.GetAuraDataByIndex",
	"C_UnitAuras.GetAuraDataByAuraInstanceID",
	"C_UnitAuras.GetBuffDataByIndex",
	"UnitAura",
	"AuraUtil.ForEachAura",
	"issecretvalue",
	"canaccessvalue",
	"Enum.PowerType",
	"GetComboPoints",
	"MAX_COMBO_POINTS",
	-- Plan 10. The five second rule ships with a mana-decrease trigger, which
	-- needs no spell data. The obvious second trigger is UNIT_SPELLCAST_SUCCEEDED
	-- restricted to spells that cost mana, and that needs a cost lookup whose
	-- availability here is unverified. Which of these exists decides whether that
	-- trigger is buildable at all, so it is answered by observation rather than
	-- by assumption.
	"GetSpellPowerCost",
	"C_Spell.GetSpellPowerCost",
	-- Plans 11, 12 and 19. COMPAT_FINDINGS recorded all three of these as absent
	-- on expansion-era reasoning, and on Anniversary all three are present --
	-- which turned out to make the difference between "derive it from the combat
	-- log" and "call a function". The survey did not check them, so answering it
	-- on a second client meant reading a chat window.
	--
	-- They belong here for the same reason everything else does: the patch-day
	-- playbook re-runs the survey and diffs the result against the findings file,
	-- and a row nobody measures is a row that goes quietly stale.
	"UnitGetIncomingHeals",
	"UnitGetTotalAbsorbs",
	"UnitGetTotalHealAbsorbs",
	"GetCreatureDifficultyColor",
	"GetQuestDifficultyColor",
	"PowerBarColor",
	"DebuffTypeColor",
	"RAID_CLASS_COLORS",
	"CUSTOM_CLASS_COLORS",
	"FACTION_BAR_COLORS",
	"RegisterUnitWatch",
	"ClickCastFrames",
	"SetPortraitTexture",
	"GetPetHappiness",
	"UnitIsTapDenied",
	"UnitIsTapped",
	"CancelUnitBuff",
	"EditModeManagerFrame",
	"C_EditMode",
	"C_AddOns.GetAddOnMemoryUsage",
	"GetAddOnMemoryUsage",
}

local FRAME_NAMES = {
	"PlayerFrame", "TargetFrame", "TargetFrameToT", "PetFrame",
	"FocusFrame", "FocusFrameToT", "ComboFrame",
	"PartyMemberFrame1", "PartyFrame", "CompactPartyFrame",
	"PlayerCastingBarFrame", "CastingBarFrame",
	-- The frames that use Interface\CharacterFrame\UI-StateIcon, which
	-- DyrueUnitFrames' combat and resting indicators also draw from. Their
	-- presence is a decent proxy for that art still existing.
	"PlayerRestIcon", "PlayerAttackIcon", "PlayerStatusTexture",
}

local EVENTS = {
	"UNIT_HEALTH", "UNIT_HEALTH_FREQUENT", "UNIT_MAXHEALTH",
	"UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
	"UNIT_AURA", "UNIT_TARGET", "UNIT_PET", "UNIT_HAPPINESS",
	"UNIT_PORTRAIT_UPDATE", "UNIT_MODEL_CHANGED", "UNIT_CLASSIFICATION_CHANGED",
	"UNIT_NAME_UPDATE", "UNIT_LEVEL", "UNIT_CONNECTION", "UNIT_FACTION", "UNIT_FLAGS",
	"UNIT_COMBO_POINTS", "UNIT_SPELLCAST_SUCCEEDED",
	-- The push events for the three functions above (Plans 11, 12, 19). Their
	-- presence decides whether reading those values costs a ticker.
	"UNIT_HEAL_PREDICTION", "UNIT_ABSORB_AMOUNT_CHANGED",
	"PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "PLAYER_FLAGS_CHANGED",
	"UPDATE_SHAPESHIFT_FORM", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED",
	"RAID_TARGET_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
}

local function survey()
	local version, build, buildDate, tocVersion = GetBuildInfo()
	local record = {
		timestamp = date("%Y-%m-%d %H:%M:%S"),
		version = version,
		build = build,
		buildDate = buildDate,
		tocVersion = tocVersion,
		projectId = WOW_PROJECT_ID,
		locale = GetLocale(),
		api = {},
		events = {},
		frames = {},
	}

	header("Build")
	out("version", version, "build", build, "date", buildDate, "toc", tocVersion)
	out("WOW_PROJECT_ID", tostring(WOW_PROJECT_ID), "locale", GetLocale())

	header("API")
	for _, path in ipairs(API_PATHS) do
		local present = exists(path)
		record.api[path] = present
		out(" ", path, yn(present))
	end

	-- SPEC §1.3: these must NOT exist in Classic. If either appears, the text
	-- engine's assumptions are void and the spec needs amending immediately.
	-- This used to shout that §1.3 no longer held, on presence alone. It is
	-- present on BOTH clients and nothing is actually secret on either --
	-- measured 11 August 2026, /dufprobe secrets, 26 values apiece. So the alarm
	-- fired every single run and meant nothing, which is the fastest way to
	-- teach someone to ignore an alarm.
	if record.api["issecretvalue"] or record.api["canaccessvalue"] then
		out("|cffffcc00Secret-value functions present|r - expected on these clients, and")
		out("not itself a problem. Measured inert on both as of 11 Aug 2026.")
		out("|cffffcc00/dufprobe secrets|r asks the question that matters: is anything the")
		out("text engine reads ACTUALLY secret?")
	else
		out("|cff40ff40No secret values. SPEC §1.3 holds outright.|r")
	end

	record.manaEnum = Enum and Enum.PowerType and Enum.PowerType.Mana
	out("Enum.PowerType.Mana =", tostring(record.manaEnum), "(0 is the fallback)")

	header("Combo points (Plan 9)")
	record.maxComboPoints = MAX_COMBO_POINTS
	record.comboEnum = Enum and Enum.PowerType and Enum.PowerType.ComboPoints
	out("MAX_COMBO_POINTS =", tostring(record.maxComboPoints), "(5 is the fallback)")
	out("Enum.PowerType.ComboPoints =", tostring(record.comboEnum))
	if record.comboEnum == 4 then
		out("|cffffcc00Note:|r 4 is HAPPINESS in the Classic power numbering. This is")
		out("why the addon never uses a numeric literal for combo points.")
	end
	if GetComboPoints then
		local ok, points = pcall(GetComboPoints, "player", "target")
		record.comboPointsNow = ok and points or nil
		out("GetComboPoints('player','target') =", tostring(record.comboPointsNow))
	else
		out("|cffff5555GetComboPoints is gone|r - the addon falls back to the Enum path.")
	end
	-- The open question this is here to answer: does UnitPowerMax report a real
	-- capacity for combo points? If it returns 5 for a rogue and 0 for, say, a
	-- mage, a later revision can use it as a genuine capability probe and offer
	-- an always-visible empty bar with no class check. Until it is seen in game,
	-- nothing is gated on it.
	if record.comboEnum then
		local ok, maximum = pcall(UnitPowerMax, "player", record.comboEnum)
		record.comboPowerMax = ok and maximum or nil
		out("UnitPowerMax('player', ComboPoints) =", tostring(record.comboPowerMax),
			"(5 here would make an always-visible bar possible without a class check)")
	end

	header("Events")
	for _, event in ipairs(EVENTS) do
		local present = eventExists(event)
		record.events[event] = present
		out(" ", event, yn(present))
	end

	header("Secure frames")
	local ok, testFrame = pcall(CreateFrame, "Button", nil, UIParent, "SecureUnitButtonTemplate")
	record.secureUnitButton = ok and testFrame ~= nil
	out("SecureUnitButtonTemplate", yn(record.secureUnitButton))
	if testFrame then
		record.registerUnitEvent = type(testFrame.RegisterUnitEvent) == "function"
		out("frame:RegisterUnitEvent", yn(record.registerUnitEvent))
		testFrame:Hide()
	end
	out("RegisterUnitWatch", yn(exists("RegisterUnitWatch")))
	out("ClickCastFrames (Clique)", yn(type(ClickCastFrames) == "table"))

	header("Focus (SPEC §FR-8.5 gates on this)")
	record.focusEvent = eventExists("PLAYER_FOCUS_CHANGED")
	record.focusFrame = _G.FocusFrame ~= nil
	record.focusExists = UnitExists("focus")
	out("PLAYER_FOCUS_CHANGED valid", yn(record.focusEvent))
	out("FocusFrame global", yn(record.focusFrame))
	out("UnitExists('focus') right now", yn(record.focusExists))
	out("=> Compat.hasFocus would be", yn(record.focusEvent or record.focusFrame))

	header("Blizzard frames")
	for _, name in ipairs(FRAME_NAMES) do
		local present = _G[name] ~= nil
		record.frames[name] = present
		out(" ", name, yn(present))
	end

	header("Edit Mode")
	record.editMode = _G.EditModeManagerFrame ~= nil
	out("EditModeManagerFrame", yn(record.editMode))
	out("|cffffcc00Manual check required:|r open Edit Mode and see whether Player/Target")
	out("frames can be hidden natively. If they can, SPEC §5.6 option 1 applies and")
	out("DyrueUnitFrames should keep leaving them alone.")

	DyrueUnitFramesProbeDB.survey = record
	out("Saved to DyrueUnitFramesProbeDB.survey")
	return record
end

--------------------------------------------------------------------------------
-- Task 0.2 - shapeshift mana event trace
--------------------------------------------------------------------------------

local manaTracer = CreateFrame("Frame")
manaTracer:Hide()

local MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0

local function startManaTrace(seconds)
	seconds = seconds or 60
	local log = {}
	local started = GetTime()
	local lastMana = UnitPower("player", MANA)

	DyrueUnitFramesProbeDB.manaTrace = log

	local function note(event, detail)
		local mana = UnitPower("player", MANA)
		local entry = {
			t = GetTime() - started,
			event = event,
			detail = detail,
			form = GetShapeshiftForm and GetShapeshiftForm() or -1,
			displayed = UnitPowerType("player"),
			mana = mana,
			manaMax = UnitPowerMax("player", MANA),
			changed = (mana ~= lastMana),
		}
		lastMana = mana
		log[#log + 1] = entry
		out(string.format("%.2fs %s%s form=%d displayed=%d mana=%d%s",
			entry.t, event, detail and (" (" .. detail .. ")") or "",
			entry.form, entry.displayed, entry.mana,
			entry.changed and " |cff40ff40CHANGED|r" or ""))
	end

	for _, event in ipairs({
		"UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER", "UPDATE_SHAPESHIFT_FORM",
	}) do
		pcall(manaTracer.RegisterEvent, manaTracer, event)
	end

	manaTracer:SetScript("OnEvent", function(_, event, unit, powerType)
		if unit and unit ~= "player" then return end
		note(event, powerType)
	end)

	-- A parallel 0.2s sampler answers the actual question: does mana change
	-- WITHOUT an event firing? If it does, the FR-2.5 fallback ticker is
	-- mandatory rather than precautionary.
	local silentChanges = 0
	local sampler = C_Timer.NewTicker(0.2, function()
		local mana = UnitPower("player", MANA)
		if mana ~= lastMana then
			silentChanges = silentChanges + 1
			lastMana = mana
			log[#log + 1] = { t = GetTime() - started, event = "TICKER_ONLY", mana = mana }
			out(string.format("%.2fs |cffff5555TICKER SAW A CHANGE WITH NO EVENT|r mana=%d",
				GetTime() - started, mana))
		end
	end)

	out("Tracing power events for " .. seconds .. "s.")
	out("Shift into Bear and Cat, spend mana in caster form, shift back.")

	C_Timer.After(seconds, function()
		sampler:Cancel()
		manaTracer:UnregisterAllEvents()
		manaTracer:SetScript("OnEvent", nil)
		DyrueUnitFramesProbeDB.manaSilentChanges = silentChanges
		header("Mana trace finished")
		out(#log, "entries,", silentChanges, "change(s) the events did not report")
		if silentChanges > 0 then
			out("|cffff5555FR-2.5 fallback ticker is REQUIRED on this client.|r")
		else
			out("|cff40ff40Events look reliable; the ticker can be opt-in.|r")
		end
	end)
end

--------------------------------------------------------------------------------
-- Task 0.3 - derived unit event probe
--------------------------------------------------------------------------------

local derivedTracer = CreateFrame("Frame")

local function startDerivedTrace(seconds)
	seconds = seconds or 60
	local log = {}
	local started = GetTime()
	local counts = { UNIT_HEALTH = 0, UNIT_POWER_UPDATE = 0, UNIT_AURA = 0, UNIT_TARGET = 0 }
	local pollChanges = 0
	local lastHealth = nil

	DyrueUnitFramesProbeDB.derivedTrace = log

	for _, event in ipairs({ "UNIT_HEALTH", "UNIT_POWER_UPDATE", "UNIT_AURA" }) do
		pcall(derivedTracer.RegisterUnitEvent, derivedTracer, event, "targettarget")
	end
	pcall(derivedTracer.RegisterEvent, derivedTracer, "UNIT_TARGET")
	pcall(derivedTracer.RegisterEvent, derivedTracer, "PLAYER_TARGET_CHANGED")

	derivedTracer:SetScript("OnEvent", function(_, event, unit)
		counts[event] = (counts[event] or 0) + 1
		log[#log + 1] = { t = GetTime() - started, event = event, unit = unit }
		out(string.format("%.2fs %s unit=%s", GetTime() - started, event, tostring(unit)))
	end)

	local sampler = C_Timer.NewTicker(0.25, function()
		if not UnitExists("targettarget") then return end
		local health = UnitHealth("targettarget")
		if lastHealth and health ~= lastHealth then
			pollChanges = pollChanges + 1
		end
		lastHealth = health
	end)

	out("Tracing derived-unit events for " .. seconds .. "s.")
	out("Target something that is fighting a third party, and switch targets a few times.")

	C_Timer.After(seconds, function()
		sampler:Cancel()
		derivedTracer:UnregisterAllEvents()
		derivedTracer:SetScript("OnEvent", nil)
		header("Derived trace finished")
		for event, n in pairs(counts) do out(" ", event, n) end
		out("Polled health changes:", pollChanges)
		DyrueUnitFramesProbeDB.derivedCounts = counts
		DyrueUnitFramesProbeDB.derivedPollChanges = pollChanges
		if counts.UNIT_HEALTH == 0 and pollChanges > 0 then
			out("|cff40ff40Confirms SPEC §4.8: targettarget needs polling.|r")
		elseif counts.UNIT_HEALTH > 0 then
			out("|cffffcc00UNIT_HEALTH DID fire for targettarget - SPEC §4.8 can be amended.|r")
		end
	end)
end

--------------------------------------------------------------------------------
-- Task 0.4 - enemy health scaling
--------------------------------------------------------------------------------

local function healthProbe()
	header("Enemy health (SPEC §FR-4.7)")
	local units = { "player", "target", "targettarget", "pet", "focus" }
	local record = {}
	for _, unit in ipairs(units) do
		if UnitExists(unit) then
			local entry = {
				name = UnitName(unit),
				health = UnitHealth(unit),
				healthMax = UnitHealthMax(unit),
				isPlayer = UnitIsPlayer(unit),
				inParty = UnitPlayerOrPetInParty and UnitPlayerOrPetInParty(unit) or false,
				classification = UnitClassification(unit),
				level = UnitLevel(unit),
			}
			entry.looksScaled = (entry.healthMax == 100)
			record[unit] = entry
			out(string.format("%s: %s  %d/%d  level=%d  %s%s",
				unit, tostring(entry.name), entry.health, entry.healthMax, entry.level,
				entry.classification or "?",
				entry.looksScaled and " |cffff5555SCALED 0-100, absolute values are fiction|r" or ""))
		end
	end
	DyrueUnitFramesProbeDB.healthProbe = record
	out("Repeat this on a same-level mob, an elite and a raid boss.")
end

--------------------------------------------------------------------------------
-- Task 0.8 - portrait feasibility
--------------------------------------------------------------------------------

local portraitFrame = nil

local function portraitProbe()
	header("Portraits (SPEC §FR-7.4)")

	if not portraitFrame then
		portraitFrame = CreateFrame("Frame", nil, UIParent)
		portraitFrame:SetSize(64, 64)
		portraitFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
		portraitFrame.texture = portraitFrame:CreateTexture(nil, "ARTWORK")
		portraitFrame.texture:SetAllPoints()
	end
	portraitFrame:Show()

	local unit = UnitExists("target") and "target" or "player"
	out("Using unit:", unit, "visible:", yn(UnitIsVisible(unit)))

	local ok = pcall(SetPortraitTexture, portraitFrame.texture, unit)
	out("SetPortraitTexture", yn(ok))

	local modelOk, model = pcall(CreateFrame, "PlayerModel", nil, UIParent)
	out("PlayerModel creatable", yn(modelOk and model ~= nil))

	if model then
		model:SetSize(64, 64)
		model:SetPoint("CENTER", UIParent, "CENTER", 80, 200)
		local setOk = pcall(model.SetUnit, model, unit)
		out("model:SetUnit", yn(setOk))
		out("model:SetPortraitZoom", yn(pcall(model.SetPortraitZoom, model, 1)))
		out("model:SetCamDistanceScale", yn(pcall(model.SetCamDistanceScale, model, 1)))
		out("model:SetPosition", yn(pcall(model.SetPosition, model, 0, 0, 0)))
		portraitFrame.model = model
	end

	DyrueUnitFramesProbeDB.portraitProbe = {
		setPortraitTexture = ok,
		playerModel = modelOk,
		unitVisible = UnitIsVisible(unit),
	}

	out("Two squares should now be visible above center screen: 2D on the left,")
	out("3D on the right. Change target, take a loading screen, and target something")
	out("at maximum range, re-running /dufprobe portrait each time.")
	out("/dufprobe portraitoff hides them.")
end

--------------------------------------------------------------------------------
-- Plan 14 - aura index stability
--
-- The addon used to tie-break its aura sort on the index passed to
-- GetAuraDataByIndex, on the assumption that an aura keeps its index for as
-- long as it is applied. If the client's aura container reuses freed slots
-- instead of re-packing, that assumption is false and the displayed order
-- churns for reasons nothing in the addon can see.
--
-- Four questions, in the order they matter:
--   1. does a still-applied aura ever change index?
--   2. is auraInstanceID actually populated on this build?
--   3. is it monotonic, i.e. is ordering by it the same as application order?
--   4. does sourceUnit ever change under a fixed aura? (the rival explanation:
--      `own` flipping would move an aura between sort blocks AND resize it)
--------------------------------------------------------------------------------

local auraTracer = CreateFrame("Frame")

local function startAuraOrderTrace(seconds)
	seconds = seconds or 60

	local findings = {
		indexChanges = 0, instanceIDs = 0, missingInstanceIDs = 0,
		sourceChanges = 0, outOfOrder = 0, samples = 0, examples = {},
	}
	-- Keyed by a stable identity, holding the last index and source seen.
	local seen = {}
	local started = GetTime()

	DyrueUnitFramesProbeDB.auraOrder = findings

	local function note(text)
		if #findings.examples < 12 then
			findings.examples[#findings.examples + 1] = text
			out(text)
		end
	end

	local function sample()
		if not UnitExists("target") then return end
		findings.samples = findings.samples + 1

		for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
			local previousID = nil

			for index = 1, 40 do
				local data = C_UnitAuras
					and C_UnitAuras.GetAuraDataByIndex("target", index, filter)
				if not data or not data.name then break end

				local id = data.auraInstanceID
				if id then
					findings.instanceIDs = findings.instanceIDs + 1
					-- Q3: within one sweep, are IDs ascending? They are issued
					-- per application, so ascending means index order and
					-- application order still agree at this instant.
					if previousID and id < previousID then
						findings.outOfOrder = findings.outOfOrder + 1
					end
					previousID = id
				else
					findings.missingInstanceIDs = findings.missingInstanceIDs + 1
				end

				-- Identity has to come from something that is NOT the index.
				local key = filter .. ":" .. tostring(id or (tostring(data.spellId)
					.. ":" .. tostring(data.sourceUnit)))
				local before = seen[key]

				if before then
					if before.index ~= index then
						findings.indexChanges = findings.indexChanges + 1
						note(string.format("%.1fs %s moved slot %d -> %d",
							GetTime() - started, tostring(data.name), before.index, index))
					end
					if before.source ~= data.sourceUnit then
						findings.sourceChanges = findings.sourceChanges + 1
						note(string.format("%.1fs %s source %s -> %s",
							GetTime() - started, tostring(data.name),
							tostring(before.source), tostring(data.sourceUnit)))
					end
					before.index, before.source = index, data.sourceUnit
				else
					seen[key] = { index = index, source = data.sourceUnit,
						name = data.name }
				end
			end
		end
	end

	header("Aura order trace (Plan 14)")
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
		out("|cffff5555No C_UnitAuras on this client.|r The legacy UnitAura path")
		out("has no auraInstanceID, so the addon orders by spellId there.")
		return
	end

	out("Tracing target aura slots for " .. seconds .. "s.")
	out("Target something with a lot of debuffs on it and let them come and go.")
	out("A dungeon pull with a group on it is the case that broke.")

	auraTracer:RegisterEvent("UNIT_AURA")
	auraTracer:SetScript("OnEvent", function(_, _, unit)
		if unit == "target" then sample() end
	end)
	sample()

	C_Timer.After(seconds, function()
		auraTracer:UnregisterAllEvents()
		auraTracer:SetScript("OnEvent", nil)

		header("Aura order trace finished")
		out("Samples:", findings.samples)
		out("Auras that changed slot while still applied:", findings.indexChanges)
		out("auraInstanceID present:", findings.instanceIDs,
			" absent:", findings.missingInstanceIDs)
		out("Sweeps where instance IDs were not ascending:", findings.outOfOrder)
		out("sourceUnit changes under a fixed aura:", findings.sourceChanges)

		if findings.indexChanges > 0 then
			out("|cff40ff40Confirms Plan 14 candidate 1:|r the index is not stable.")
		elseif findings.samples > 5 then
			out("|cffffcc00No index churn seen.|r Either the container re-packs or")
			out("the trace did not run long enough. Do not conclude from a quiet pull.")
		end

		if findings.missingInstanceIDs > 0 then
			out("|cffff5555auraInstanceID is missing on this build|r - the sort")
			out("falls back to spellId, which ties between two casts of one spell.")
		end
		if findings.sourceChanges > 0 then
			out("|cffffcc00sourceUnit also flapped|r - candidate 2 is live as well,")
			out("and needs its own fix: `own` flipping moves an aura AND resizes it.")
		end
	end)
end

--------------------------------------------------------------------------------
-- Plan 17 - rage decay trace
--
-- Rage decays out of combat instead of regenerating, and the rules for it are not
-- reliably documented for 1.15.9 or 2.5.6. One vanilla source gives ~1 rage per
-- second on a ~2.5s tick; the modern wiki's 1.25/sec is the retail figure; and the
-- delay between combat dropping and rage starting to fall has no stated value at
-- all. Worse, vanilla Anger Management stretches the decay time by 30%, so the
-- numbers differ between the two clients this addon supports.
--
-- The five questions this answers, in the order they matter:
--
--   1. Does UNIT_POWER_UPDATE fire per decay tick, or does the client coalesce
--      them? If it coalesces, the derived interval in Systems/BarSweep.lua is
--      built on sand and detection has to move into the sweep driver's OnUpdate.
--   2. What is the real interval on this client?
--   3. How much rage per tick, and is it the documented 2 or 3?
--   4. How long after the combat flag clears does the first decrease arrive?
--   5. Does anything decay DURING combat, i.e. is the in-combat gate right?
--
-- Run it on a warrior, again on a druid in bear form, and once on a Classic Era
-- warrior with Anger Management talented if one is available.
--------------------------------------------------------------------------------

local rageTracer = CreateFrame("Frame")

local RAGE = (Enum and Enum.PowerType and Enum.PowerType.Rage) or 1

local function startRageTrace(seconds)
	seconds = seconds or 90
	local log = {}
	local started = GetTime()
	local lastRage = UnitPower("player", RAGE)
	local lastDropAt = nil        -- GetTime() of the last decrease, for the interval
	local combatEndedAt = nil     -- and of the last combat drop, for the delay
	local firstDecayDelay = nil
	local intervals, steps = {}, {}
	local inCombatDecays = 0
	local silentChanges = 0

	DyrueUnitFramesProbeDB.rageTrace = log

	local function note(event, source)
		local rage = UnitPower("player", RAGE)
		if rage == lastRage then return end

		local now = GetTime()
		local delta = rage - lastRage
		local combat = UnitAffectingCombat("player") and true or false
		local entry = {
			t = now - started,
			event = event,
			source = source,
			rage = rage,
			delta = delta,
			combat = combat,
			displayed = UnitPowerType("player"),
			form = GetShapeshiftForm and GetShapeshiftForm() or -1,
		}

		if delta < 0 then
			if combat then
				inCombatDecays = inCombatDecays + 1
			else
				steps[#steps + 1] = -delta
				if lastDropAt then
					entry.since = now - lastDropAt
					intervals[#intervals + 1] = entry.since
				end
				if combatEndedAt and not firstDecayDelay then
					firstDecayDelay = now - combatEndedAt
					entry.afterCombat = firstDecayDelay
				end
				lastDropAt = now
			end
		end

		lastRage = rage
		log[#log + 1] = entry

		out(string.format("%.2fs %s rage=%d (%+d)%s%s%s",
			entry.t, event, rage, delta,
			combat and " |cffff5555IN COMBAT|r" or "",
			entry.since and string.format(" since=%.2fs", entry.since) or "",
			entry.afterCombat
				and string.format(" |cffffcc00%.2fs AFTER COMBAT DROPPED|r", entry.afterCombat)
				or ""))
	end

	for _, event in ipairs({
		"UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
		"PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
	}) do
		pcall(rageTracer.RegisterEvent, rageTracer, event)
	end

	rageTracer:SetScript("OnEvent", function(_, event, unit)
		if event == "PLAYER_REGEN_ENABLED" then
			combatEndedAt = GetTime()
			-- The decay timer starts from here, not from the last spend in the
			-- fight, so the interval clock restarts with it.
			lastDropAt = nil
			out(string.format("%.2fs |cff40ff40combat dropped|r rage=%d",
				GetTime() - started, UnitPower("player", RAGE)))
			return
		elseif event == "PLAYER_REGEN_DISABLED" then
			combatEndedAt = nil
			out(string.format("%.2fs |cffff5555combat started|r rage=%d",
				GetTime() - started, UnitPower("player", RAGE)))
			return
		end
		if unit and unit ~= "player" then return end
		note(event, "event")
	end)

	-- Question 1, and the reason it is first: a 0.1s sampler catches any change the
	-- events did not report. Every derived number below is only as good as the
	-- events, and this is the check on them.
	local sampler = C_Timer.NewTicker(0.1, function()
		if UnitPower("player", RAGE) ~= lastRage then
			silentChanges = silentChanges + 1
			note("TICKER_ONLY", "sampler")
		end
	end)

	out("Tracing rage for " .. seconds .. "s.")
	out("Build rage on something, then STOP and stand still until it drains to zero.")
	out("Do that twice if there is time, and once in bear form.")

	C_Timer.After(seconds, function()
		sampler:Cancel()
		rageTracer:UnregisterAllEvents()
		rageTracer:SetScript("OnEvent", nil)

		local function mean(t)
			if #t == 0 then return nil end
			local sum = 0
			for _, v in ipairs(t) do sum = sum + v end
			return sum / #t
		end

		local meanInterval, meanStep = mean(intervals), mean(steps)
		DyrueUnitFramesProbeDB.rageFindings = {
			intervals = intervals,
			steps = steps,
			meanInterval = meanInterval,
			meanStep = meanStep,
			firstDecayDelay = firstDecayDelay,
			inCombatDecays = inCombatDecays,
			silentChanges = silentChanges,
		}

		header("Rage trace finished")
		out(#log, "entries,", #intervals, "decay interval(s) sampled")

		if silentChanges > 0 then
			out("|cffff5555" .. silentChanges .. " change(s) the events did not report.|r")
			out("Decay detection cannot rely on UNIT_POWER_UPDATE alone on this client;")
			out("BarSweep would have to sample rage in the sweep driver instead.")
		else
			out("|cff40ff40Every change arrived as an event. The derived interval is sound.|r")
		end

		if meanInterval then
			out(string.format("Decay interval: mean %.2fs over %d sample(s)",
				meanInterval, #intervals))
			if meanInterval < 1.5 or meanInterval > 4.0 then
				out("|cffff5555Outside BarSweep's 1.5-4.0s band - the band needs widening.|r")
			end
		else
			out("|cffffcc00No decay intervals sampled. Stand out of combat with rage banked.|r")
		end

		if meanStep then
			out(string.format("Rage lost per tick: mean %.2f (documented 2 or 3)", meanStep))
			if meanStep > 5 then
				out("|cffff5555Above BarSweep's 5-rage plausibility guard.|r")
			end
		end

		if firstDecayDelay then
			out(string.format("|cffffcc00First decay landed %.2fs after combat dropped.|r",
				firstDecayDelay))
			out("This is the number nothing documents. Record it in COMPAT_FINDINGS.md.")
		else
			out("|cffffcc00Pre-decay delay not measured - no combat drop with rage banked.|r")
		end

		if inCombatDecays > 0 then
			out("|cffff5555" .. inCombatDecays .. " decrease(s) while IN COMBAT.|r")
			out("Expected: those are spends. If any were unexplained, the in-combat")
			out("gate in the decay provider is wrong.")
		end
	end)
end

--------------------------------------------------------------------------------
-- Plan 24 - does UNIT_HAPPINESS actually fire?
--
-- The survey above reports UNIT_HAPPINESS as an event, and /duf compat reports
-- hasUnitHappiness. BOTH OF THOSE ARE VALIDITY CHECKS -- C_EventUtils.IsEventValid,
-- or a RegisterEvent that did not throw. Neither has ever established that the
-- client SENDS it, and this project has been wrong about exactly that distinction
-- three times: UNIT_COMBO_POINTS, the secret-value functions, and hasFocus on Era.
--
-- Plan 24's happiness indicator refreshes on this event. If it never arrives, the
-- icon goes stale until something else refreshes the frame, so this is the
-- measurement the plan is waiting on.
--
-- The five questions, in the order they matter:
--
--   1. Does UNIT_HAPPINESS arrive at all when happiness changes? The 0.5s sampler
--      is the control: a change it sees that no event reported is the failure
--      case, and is what decides whether the indicator needs another refresh path.
--   2. What unit token does it carry? The element registers it filtered to "pet"
--      (SPEC §5.7). If it arrives for "player" instead, that filter drops it and
--      the frame never wakes -- a live bug that would look exactly like the event
--      not firing at all.
--   3. Does the change arrive as UNIT_POWER_UPDATE instead? Happiness is power
--      type 4 in the Classic numbering, so it is entirely plausible the client
--      reports it that way and UNIT_HAPPINESS is vestigial.
--   4. Is HasPetUI's second return actually true for a hunter pet? Everything
--      Plan 24 shows is gated behind it, including the warlock-pet fix.
--   5. Are damagePercentage and loyaltyRate populated? Neither is used today;
--      both are the obvious follow-up, and this run is free.
--
-- Run it on a HUNTER with a pet out, and feed the pet during the trace -- that is
-- the one thing that moves happiness quickly and on demand. Then, if you have one,
-- run it again on a warlock with a voidwalker out to confirm question 4 negatively.
--------------------------------------------------------------------------------

local happinessTracer = CreateFrame("Frame")

local function readHappiness()
	if not GetPetHappiness then return nil end
	local ok, happiness, damage, loyalty = pcall(GetPetHappiness)
	if not ok then return nil end
	return happiness, damage, loyalty
end

local function startHappinessTrace(seconds)
	seconds = seconds or 120
	local log = {}
	local started = GetTime()
	local lastHappiness = readHappiness()
	local reportedSinceChange = false

	local counts = {
		happinessEvents = 0,      -- UNIT_HAPPINESS firings, changed or not
		happinessSpurious = 0,    -- ...that reported no change
		powerEvents = 0,          -- UNIT_POWER_UPDATE firings that DID change it
		changes = 0,              -- changes seen by anything
		silentChanges = 0,        -- ...that only the sampler saw
	}
	local units = {}              -- unit token -> count, for question 2

	DyrueUnitFramesProbeDB.happinessTrace = log

	local hasUI, isHunterPet = false, false
	if HasPetUI then
		local ok, a, b = pcall(HasPetUI)
		if ok then hasUI, isHunterPet = a, b end
	end

	local happiness, damage, loyalty = readHappiness()

	header("Happiness trace")
	out("UNIT_HAPPINESS valid:", yn(eventExists("UNIT_HAPPINESS")),
		" (validity only -- whether it FIRES is what this measures)")
	out("PET_UI_UPDATE valid:", yn(eventExists("PET_UI_UPDATE")))
	out("HasPetUI() =", tostring(hasUI), tostring(isHunterPet),
		isHunterPet and "|cff40ff40hunter pet|r" or "|cffff5555NOT a hunter pet|r")
	out("GetPetHappiness() =", tostring(happiness),
		" damage=", tostring(damage), " loyalty=", tostring(loyalty))
	out("UnitPowerType('pet') =", tostring(select(1, UnitPowerType("pet"))),
		tostring(select(2, UnitPowerType("pet"))))

	if not isHunterPet then
		out("|cffffcc00No hunter pet out.|r The trace will run, but nothing will")
		out("change. Summon a hunter pet first unless you are deliberately")
		out("checking the warlock case.")
	end

	local function note(event, unit, source)
		local now, current = GetTime(), readHappiness()
		local changed = (current ~= lastHappiness)

		if event == "UNIT_HAPPINESS" then
			counts.happinessEvents = counts.happinessEvents + 1
			units[tostring(unit)] = (units[tostring(unit)] or 0) + 1
			if not changed then counts.happinessSpurious = counts.happinessSpurious + 1 end
			reportedSinceChange = true
		elseif event == "UNIT_POWER_UPDATE" and changed then
			counts.powerEvents = counts.powerEvents + 1
			reportedSinceChange = true
		end

		if changed then
			counts.changes = counts.changes + 1
			-- The whole point of the sampler: a change nothing announced.
			if source == "sampler" and not reportedSinceChange then
				counts.silentChanges = counts.silentChanges + 1
			end
			log[#log + 1] = {
				t = now - started, event = event, unit = unit, source = source,
				from = lastHappiness, to = current,
			}
			out(string.format("%.2fs %s%s happiness %s -> %s%s",
				now - started, event,
				unit and (" [" .. tostring(unit) .. "]") or "",
				tostring(lastHappiness), tostring(current),
				(source == "sampler" and not reportedSinceChange)
					and " |cffff5555SAMPLER ONLY - NO EVENT|r" or ""))
			lastHappiness = current
			reportedSinceChange = false
		end
	end

	for _, event in ipairs({
		"UNIT_HAPPINESS", "UNIT_POWER_UPDATE", "UNIT_PET", "PET_UI_UPDATE",
	}) do
		pcall(happinessTracer.RegisterEvent, happinessTracer, event)
	end

	happinessTracer:SetScript("OnEvent", function(_, event, unit)
		note(event, unit, "event")
	end)

	-- Question 1's control. Happiness moves over minutes, so 0.5s is ample and
	-- costs nothing next to the 0.1s the rage trace needs.
	local sampler = C_Timer.NewTicker(0.5, function()
		if readHappiness() ~= lastHappiness then note("TICKER_ONLY", "pet", "sampler") end
	end)

	out("Tracing happiness for " .. seconds .. "s.")
	out("|cffffcc00FEED THE PET.|r That is the one thing that moves happiness on")
	out("demand; otherwise it only decays, over many minutes.")

	C_Timer.After(seconds, function()
		sampler:Cancel()
		happinessTracer:UnregisterAllEvents()
		happinessTracer:SetScript("OnEvent", nil)

		local endHappiness, endDamage, endLoyalty = readHappiness()
		DyrueUnitFramesProbeDB.happinessFindings = {
			counts = counts,
			units = units,
			isHunterPet = isHunterPet,
			eventValid = eventExists("UNIT_HAPPINESS"),
			petUIUpdateValid = eventExists("PET_UI_UPDATE"),
			damage = endDamage,
			loyalty = endLoyalty,
		}

		header("Happiness trace finished")
		out(counts.changes, "change(s);", counts.happinessEvents, "UNIT_HAPPINESS firing(s)")

		-- The verdict, and the one branch that must not overclaim. A quiet run
		-- proves nothing either way -- the same trap the aura order trace calls
		-- out. Say so rather than reporting a green.
		if counts.changes == 0 then
			out("|cffffcc00Happiness never changed, so nothing was tested.|r")
			out("Re-run on a hunter and feed the pet during the trace. Do NOT")
			out("record this as evidence the event does or does not fire.")
		elseif counts.silentChanges > 0 then
			out("|cffff5555" .. counts.silentChanges .. " change(s) that NO event reported.|r")
			out("Plan 24's indicator cannot rely on UNIT_HAPPINESS on this client.")
			out("It would need the derived poller, or a refresh off PET_UI_UPDATE.")
		elseif counts.happinessEvents > 0 then
			out("|cff40ff40UNIT_HAPPINESS fires. Plan 24's refresh path is sound.|r")
		else
			out("|cffffcc00Every change was reported, but never by UNIT_HAPPINESS.|r")
			out("Something else is carrying it -- see the unit/event lines above.")
			out("The indicator works, but for a reason the code does not state.")
		end

		if counts.powerEvents > 0 then
			out("|cffffcc00" .. counts.powerEvents .. " change(s) also arrived as",
				"UNIT_POWER_UPDATE|r - happiness is power type 4 in this numbering.")
		end
		if counts.happinessSpurious > 0 then
			out(counts.happinessSpurious, "UNIT_HAPPINESS firing(s) reported no change.")
		end

		local tokens = {}
		for unit, n in pairs(units) do tokens[#tokens + 1] = unit .. "x" .. n end
		if #tokens > 0 then
			out("UNIT_HAPPINESS arrived for:", table.concat(tokens, " "))
			if not units["pet"] then
				out("|cffff5555Never for 'pet'.|r The element registers it filtered to")
				out("pet (SPEC §5.7), so that filter is dropping every one of them.")
			end
		end

		out("damagePercentage =", tostring(endDamage),
			" loyaltyRate =", tostring(endLoyalty),
			" (unused today; the obvious follow-up)")
	end)
end

--------------------------------------------------------------------------------
-- Plan 3 - options panel clipping
--
-- The symptom: on a long options tab, content scrolled below the fold is drawn
-- anyway, overlapping the panel border and the Close row, and pairs of scroll
-- arrows float outside any visible container.
--
-- Two rival explanations, and looking at it cannot separate them:
--   1. nothing clips. A WoW ScrollFrame does not clip its scroll child unless
--      SetClipsChildren(true) is set, and AceGUI never sets it - not in our
--      vendored copy and not upstream either, so this is not vendored drift.
--   2. nothing is measured right. AceConfigDialog sizes the scroll child from
--      the height of its descriptions, and a description whose `name` is a
--      function can be measured before it is populated. Config/ has seven such
--      descriptions, so this is not an exotic case.
--
-- Told apart by numbers: (2) shows up as a content height that disagrees with
-- the children actually laid out, (1) shows up as children whose rects sit
-- outside the viewport while GetClipsChildren() is false.
--
-- The third question this answers is whether the obvious fix is even safe. The
-- scrollbar is a CHILD of the scroll frame, anchored outside its right edge, so
-- SetClipsChildren(true) on the scroll frame would clip the scrollbar away
-- along with the overflow. Measured here rather than assumed.
--
-- No library calls, deliberately, in keeping with the top of this file: the
-- scroll frame is reached through the global name its scrollbar is given
-- ("AceConfigDialogScrollFrame<n>ScrollBar"), so this still reports on a patch
-- that breaks Ace3 outright.
--------------------------------------------------------------------------------

local OVERFLOW_TOLERANCE = 1

local function px(value)
	if type(value) ~= "number" then return "?" end
	return tostring(math.floor(value + 0.5))
end

local function rectOf(object)
	if not object then return "absent" end
	local left, bottom = object:GetLeft(), object:GetBottom()
	if not left or not bottom then
		return string.format("unanchored w=%s h=%s", px(object:GetWidth()), px(object:GetHeight()))
	end
	return string.format("w=%s h=%s top=%s bottom=%s",
		px(object:GetWidth()), px(object:GetHeight()), px(object:GetTop()), px(bottom))
end

local function labelOf(object)
	local parts = {}
	local widget = object.obj
	if widget and widget.type then parts[#parts + 1] = "AceGUI:" .. tostring(widget.type) end
	if object.GetObjectType then parts[#parts + 1] = object:GetObjectType() end
	if object.GetName and object:GetName() then parts[#parts + 1] = object:GetName() end
	if object.GetText then
		local ok, text = pcall(object.GetText, object)
		if ok and type(text) == "string" and text ~= "" then
			parts[#parts + 1] = "[" .. text:sub(1, 28):gsub("|", "||") .. "]"
		end
	end
	return table.concat(parts, " ")
end

local function noteOverflow(object, depth, viewTop, viewBottom, results)
	if not (object.IsVisible and object:IsVisible()) then return end
	if not (object.GetTop and object.GetBottom) then return end
	local top, bottom = object:GetTop(), object:GetBottom()
	if not (top and bottom and viewTop and viewBottom) then return end
	local pastBottom, pastTop = viewBottom - bottom, top - viewTop
	if pastBottom <= OVERFLOW_TOLERANCE and pastTop <= OVERFLOW_TOLERANCE then return end
	results[#results + 1] = {
		label = labelOf(object),
		depth = depth,
		height = object:GetHeight(),
		pastBottom = pastBottom > OVERFLOW_TOLERANCE and pastBottom or nil,
		pastTop = pastTop > OVERFLOW_TOLERANCE and pastTop or nil,
	}
end

local function walkOverflow(frame, depth, maxDepth, viewTop, viewBottom, results)
	if depth > maxDepth then return end
	if frame.GetRegions then
		local regions = { frame:GetRegions() }
		for index = 1, #regions do
			noteOverflow(regions[index], depth, viewTop, viewBottom, results)
		end
	end
	if not frame.GetChildren then return end
	local children = { frame:GetChildren() }
	for index = 1, #children do
		local child = children[index]
		noteOverflow(child, depth, viewTop, viewBottom, results)
		if child.IsVisible and child:IsVisible() then
			walkOverflow(child, depth + 1, maxDepth, viewTop, viewBottom, results)
		end
	end
end

-- Which of these containers is ours? The widget numbering and the scrollbar
-- names are global across every addon sharing this AceGUI instance, so the scan
-- picks up other addons' panels too - the first report came back with somebody's
-- character roster as container #1. LibStub is reached through its silent form
-- and every step is optional, so an Ace3 broken by a patch downgrades this to
-- "unknown" rather than erroring, which is the promise at the top of the file.
-- Two registration paths, and the first version of this only knew one. A
-- standalone `/duf` window lands in AceConfigDialog.OpenFrames, but
-- Core/Core.lua:316 also calls AddToBlizOptions, and those live in
-- AceConfigDialog.BlizOptions[appName] keyed by path. Checking only OpenFrames
-- reported "not ours" for a panel that was plainly ours, so both are collected.
local function ourDialogFrames()
	if type(_G.LibStub) ~= "function" then return {} end
	local ok, dialog = pcall(_G.LibStub, "AceConfigDialog-3.0", true)
	if not ok or type(dialog) ~= "table" then return {} end

	local frames = {}
	local widget = type(dialog.OpenFrames) == "table"
		and dialog.OpenFrames["DyrueUnitFrames"] or nil
	if widget and widget.frame then
		frames[#frames + 1] = { source = "OpenFrames", frame = widget.frame }
	end

	local bliz = type(dialog.BlizOptions) == "table"
		and dialog.BlizOptions["DyrueUnitFrames"] or nil
	if type(bliz) == "table" then
		for _, group in pairs(bliz) do
			if group and group.frame then
				frames[#frames + 1] = { source = "BlizOptions", frame = group.frame }
			end
		end
	end
	return frames
end

local function isDescendantOf(frame, owners)
	if not frame or not owners or #owners == 0 then return nil end
	local current, hops = frame, 0
	while current and hops < 30 do
		for index = 1, #owners do
			if current == owners[index].frame then return owners[index].source end
		end
		current = current.GetParent and current:GetParent() or nil
		hops = hops + 1
	end
	return false
end

-- The outer window's own size, and the status table AceConfigDialog sizes it
-- from. The first run showed a 234-wide viewport, which is nothing like the
-- content column of the 700x500 the library falls back to when the status table
-- is empty (AceConfigDialog-3.0.lua:1900-1905). So the window was small rather
-- than merely short, and these are the numbers that say which.
local function describeDialogWindow(record)
	if type(_G.LibStub) ~= "function" then return end
	local ok, dialog = pcall(_G.LibStub, "AceConfigDialog-3.0", true)
	if not ok or type(dialog) ~= "table" then return end

	-- The 23:43 run came back with identifiedOurDialog = false, which means
	-- OpenFrames had no "DyrueUnitFrames" key. Either the window was shut, or it
	-- is registered under a name this probe does not know. Listing the keys
	-- answers which, and costs one line.
	local openNames = {}
	if type(dialog.OpenFrames) == "table" then
		for appName in pairs(dialog.OpenFrames) do
			openNames[#openNames + 1] = tostring(appName)
		end
	end
	table.sort(openNames)
	record.openFrameNames = openNames

	local blizNames = {}
	if type(dialog.BlizOptions) == "table" then
		for appName in pairs(dialog.BlizOptions) do
			blizNames[#blizNames + 1] = tostring(appName)
		end
	end
	table.sort(blizNames)
	record.blizOptionNames = blizNames

	out("OpenFrames:", #openNames > 0 and table.concat(openNames, ", ") or "none",
		"| BlizOptions:", #blizNames > 0 and table.concat(blizNames, ", ") or "none")
	if #openNames == 0 and #blizNames > 0 then
		out("|cffffcc00No standalone window. What is on screen is the Settings-panel copy,|r")
		out("|cffffcc00whose height comes from the Blizzard canvas, not from AceGUI.|r")
	end

	local widget = type(dialog.OpenFrames) == "table"
		and dialog.OpenFrames["DyrueUnitFrames"] or nil
	if widget and widget.frame then
		out("window frame", rectOf(widget.frame))
		record.windowWidth = widget.frame:GetWidth()
		record.windowHeight = widget.frame:GetHeight()
		record.windowRect = rectOf(widget.frame)
	end

	if type(dialog.GetStatusTable) ~= "function" then return end
	local okStatus, status = pcall(dialog.GetStatusTable, dialog, "DyrueUnitFrames")
	if not okStatus or type(status) ~= "table" then return end

	record.statusWidth, record.statusHeight = status.width, status.height
	out("status table width", px(status.width), "height", px(status.height),
		"(the library defaults these to 700 x 500 when unset)")
	if type(status.height) == "number" and status.height < 100 then
		out("|cffff5555The stored height is tiny.|r Either the window has been dragged")
		out("|cffff5555down to nothing, or something wrote a bad height into the status|r")
		out("|cffff5555table. Either way the fix is upstream of the scroll frame.|r")
	end
end

-- The question the first report left open: the viewport had zero height, so
-- everything overflowed trivially. This walks up the parent chain recording each
-- ancestor's size and anchors, to find the frame where the height dies.
--
-- It records into the SavedVariables entry and prints only a one-line verdict.
-- The chat frame's buffer cannot hold the full walk alongside everything else,
-- and a report that scrolls off the top is worse than no report - the file is
-- the deliverable here, chat is only the summary.
local function collectAncestry(frame, entry)
	local chain = {}
	local current, hops = frame, 0
	while current and hops < 12 do
		local points = (current.GetNumPoints and current:GetNumPoints()) or 0
		local step = {
			label = labelOf(current),
			height = current:GetHeight(),
			width = current:GetWidth(),
			shown = (current.IsShown and current:IsShown()) and true or false,
			points = {},
		}
		for index = 1, math.min(points, 4) do
			local ok, point, relativeTo, relativePoint, xOffset, yOffset =
				pcall(current.GetPoint, current, index)
			if ok and point then
				step.points[#step.points + 1] = {
					point = tostring(point),
					relativeTo = relativeTo
						and ((relativeTo.GetName and relativeTo:GetName()) or "unnamed")
						or "nil",
					relativePoint = tostring(relativePoint),
					x = xOffset, y = yOffset,
				}
			end
		end
		chain[#chain + 1] = step
		if current == _G.UIParent then break end
		current = current.GetParent and current:GetParent() or nil
		hops = hops + 1
	end
	entry.ancestry = chain

	-- The one thing worth saying in chat: how far up the zero goes.
	local lastZero
	for index = 1, #chain do
		if type(chain[index].height) == "number" and chain[index].height < 1 then
			lastZero = index
		end
	end
	if lastZero then
		entry.zeroRunsUpTo = chain[lastZero].label
		out(string.format("  ancestry: %d frames, zero height up to and including |cffff5555%s|r",
			#chain, chain[lastZero].label))
	else
		out(string.format("  ancestry: %d frames, none zero-height", #chain))
	end
end

-- TreeGroup keeps its own UIPanelScrollBarTemplate slider (TreeGroup.lua:670),
-- so it contributes a second up/down pair - the likely other half of the "two
-- pairs of arrows" in the original report.
local function treeContainer(number, bar, record)
	local treeframe = bar:GetParent()
	if not (treeframe and treeframe:IsVisible()) then
		out(string.format(" tree #%d exists but is not visible (pooled)", number))
		return
	end

	local treeHeight = treeframe:GetHeight()
	out(string.format(" tree #%d: treeframe %s | bar %s visible %s%s",
		number, rectOf(treeframe), rectOf(bar), yn(bar:IsVisible()),
		(type(treeHeight) == "number" and treeHeight < 1)
			and " |cffff5555<- zero-height treeframe|r" or ""))

	local barName = bar:GetName()
	local arrows = { "ScrollUpButton", "ScrollDownButton" }
	local arrowInfo = {}
	for index = 1, #arrows do
		local button = barName and _G[barName .. arrows[index]]
		if button then
			arrowInfo[arrows[index]] = {
				visible = button:IsVisible(), rect = rectOf(button),
			}
		end
	end

	record.treeBars[#record.treeBars + 1] = {
		number = number,
		barVisible = bar:IsVisible(),
		treeHeight = treeHeight,
		treeframeRect = rectOf(treeframe),
		barRect = rectOf(bar),
		arrows = arrowInfo,
	}
end

local function scrollContainer(number, bar, hasGetter, record, ours)
	local scrollframe = bar:GetParent()
	local widget = scrollframe and scrollframe.obj
	local content = widget and widget.content

	if not (scrollframe and scrollframe:IsVisible()) then
		out(string.format(" #%d exists but is not visible (pooled)", number))
		return
	end

	local mine = isDescendantOf(scrollframe, ours)
	if mine == false then
		out(string.format(" #%d belongs to another addon - skipped. %s",
			number, rectOf(scrollframe)))
		return
	end

	header(string.format("Scroll container #%d%s", number,
		mine and (" (ours, via " .. mine .. ")") or " (owner unknown)"))

	local entry = { number = number, ownedByUs = mine }
	-- Not `hasGetter and ... or nil`: a legitimate false would collapse to nil
	-- there, and false is precisely the answer this probe exists to catch.
	local clips
	if hasGetter then clips = scrollframe:GetClipsChildren() end
	entry.clipsChildren = clips

	entry.viewportRect = rectOf(scrollframe)
	entry.contentRect = rectOf(content)

	local viewHeight = scrollframe:GetHeight()
	local contentHeight = content and content:GetHeight()
	entry.viewHeight, entry.contentHeight = viewHeight, contentHeight
	out(string.format("  viewport %s | content %s | clips %s",
		rectOf(scrollframe), rectOf(content), yn(clips)))

	-- The 8 August report came back with viewport h=0 and content h=797, which
	-- makes every child trivially outside the viewport. Clipping is then beside
	-- the point: there is nothing to clip to. Called out loudly because it
	-- redirects the whole investigation.
	entry.zeroHeightViewport = type(viewHeight) == "number" and viewHeight < 1
	if entry.zeroHeightViewport then
		out("  |cffff5555ZERO-HEIGHT VIEWPORT|r - everything is outside it by definition,")
		out("  so no clipping property can help. Fix the height.")
	end

	-- LayoutFinished does `self.content:SetHeight(height or 0 + 20)`, which Lua
	-- parses as `height or 20` - the 20px pad is never added when height is
	-- non-nil, though the code reads as if (height or 0) + 20 was meant. Noted
	-- because it means the content child is exactly as tall as its layout with
	-- no slack, which matters when comparing the two numbers above.
	entry.contentHeightField = content and content.height

	entry.scrollBarShown = widget and widget.scrollBarShown and true or false
	entry.scrollBarVisible = bar:IsVisible()
	if contentHeight and viewHeight and contentHeight <= viewHeight + 2 and bar:IsVisible() then
		entry.fitsButBarUp = true
		out("  |cffffcc00Content says it fits but the scrollbar is up|r - measurement, not clipping.")
	end
	-- The first report had scrollBarShown true against a hidden bar, which the
	-- check above cannot see because it only tests the other direction.
	if entry.scrollBarShown ~= entry.scrollBarVisible then
		entry.barStateStale = true
		out(string.format("  |cffffcc00Stale: scrollBarShown=%s, bar visible=%s|r",
			tostring(entry.scrollBarShown), tostring(entry.scrollBarVisible)))
	end

	local status = widget and (widget.status or widget.localstatus)
	entry.offset = status and status.offset
	entry.scrollValue = status and status.scrollvalue

	local parentIsView = bar:GetParent() == scrollframe
	local barLeft, viewRight = bar:GetLeft(), scrollframe:GetRight()
	local outside = barLeft and viewRight and barLeft >= viewRight - 1
	entry.barParentIsViewport, entry.barOutsideViewport = parentIsView, outside and true or false
	entry.barRect = rectOf(bar)
	if parentIsView and outside then
		entry.clippingWouldEatTheBar = true
	end

	-- These two are almost certainly the "floating arrow pairs" in the report.
	local barName = bar:GetName()
	local arrows = { "ScrollUpButton", "ScrollDownButton" }
	entry.arrows = {}
	for index = 1, #arrows do
		local button = barName and _G[barName .. arrows[index]]
		if button then
			entry.arrows[arrows[index]] = {
				visible = button:IsVisible(), rect = rectOf(button),
			}
		end
	end

	collectAncestry(scrollframe, entry)

	if content then
		local results = {}
		walkOverflow(content, 1, 4, scrollframe:GetTop(), scrollframe:GetBottom(), results)
		entry.overflowCount = #results
		-- The full list goes to SavedVariables, capped only so the file stays a
		-- sane size; chat gets the count. The first run printed 215 lines and
		-- pushed everything useful off the top of the frame.
		entry.overflow = {}
		for index = 1, math.min(#results, 60) do
			local item = results[index]
			entry.overflow[index] = {
				label = item.label, depth = item.depth, height = item.height,
				pastBottom = item.pastBottom, pastTop = item.pastTop,
			}
		end
		out(string.format("  overflow: %d object(s) outside the viewport", #results))
		if #results == 0 then
			out("  |cff40ff40Nothing overflows right now.|r Drag the window shorter until")
			out("  the scrollbar appears, or scroll down, then re-run.")
		end
	end

	record.containers[#record.containers + 1] = entry
end

local function scrollProbe(label)
	if label == "" then label = nil end
	header("Options panel clipping (Plan 3)" .. (label and (" - " .. label) or ""))

	local version, build, buildDate, tocVersion = GetBuildInfo()
	out("build", version, build, buildDate, "toc", tocVersion,
		"WOW_PROJECT_ID", tostring(WOW_PROJECT_ID))

	local test = CreateFrame("Frame")
	local hasGetter = type(test.GetClipsChildren) == "function"
	local hasSetter = type(test.SetClipsChildren) == "function"
	out("Frame:GetClipsChildren exists", yn(hasGetter))
	out("Frame:SetClipsChildren exists", yn(hasSetter))
	if not hasSetter then
		out("|cffff5555No SetClipsChildren on this build.|r Fix option 2 is impossible and")
		out("the cause has to be something else. This line is the important one.")
	end

	if hasSetter and not hasGetter then
		out("|cffffcc00Setter without a getter on this build.|r The clipping state cannot be")
		out("read back, so GetClipsChildren() below will say nil whatever it is set to.")
	end

	local record = {
		label = label,
		timestamp = date("%Y-%m-%d %H:%M:%S"),
		version = version, build = build, buildDate = buildDate, tocVersion = tocVersion,
		projectId = WOW_PROJECT_ID,
		hasGetClipsChildren = hasGetter,
		hasSetClipsChildren = hasSetter,
		containers = {},
		treeBars = {},
	}

	local ours = ourDialogFrames()
	record.identifiedOurDialog = #ours > 0
	record.ourDialogSources = {}
	for index = 1, #ours do
		record.ourDialogSources[index] = ours[index].source
		record.ourDialogSources["rect" .. index] = rectOf(ours[index].frame)
	end
	out("our options frames found:", #ours > 0
		and table.concat(record.ourDialogSources, ", ")
		or "|cffff5555none - containers cannot be attributed, so none are skipped|r")

	describeDialogWindow(record)

	local seen = 0
	for number = 1, 40 do
		local bar = _G[string.format("AceConfigDialogScrollFrame%dScrollBar", number)]
		if bar then
			seen = seen + 1
			scrollContainer(number, bar, hasGetter, record, ours)
		end
	end
	record.scrollFramesFound = seen

	local trees = 0
	for number = 1, 40 do
		local bar = _G[string.format("AceConfigDialogTreeGroup%dScrollBar", number)]
		if bar then
			trees = trees + 1
			treeContainer(number, bar, record)
		end
	end
	record.treeBarsFound = trees

	if seen == 0 and trees == 0 then
		out("|cffff5555No AceConfigDialog scroll frames exist yet.|r")
		out("Open the options with |cffffcc00/duf|r, click Player -> Text, then re-run.")
		return
	end

	DyrueUnitFramesProbeDB.scrollProbe = record

	-- Runs accumulate rather than overwrite. The interesting comparison is
	-- between UI states - freshly opened against after a tab switch - and
	-- SavedVariables only reach disk on /reload, so overwriting would force a
	-- reload between each one and destroy the state being measured.
	local runs = DyrueUnitFramesProbeDB.scrollRuns or {}
	runs[#runs + 1] = record
	while #runs > 10 do table.remove(runs, 1) end
	DyrueUnitFramesProbeDB.scrollRuns = runs

	out(string.format("|cff40ff40Saved as run %d%s.|r Chat shows the summary only - the ancestry,",
		#runs, record.label and (" labelled '" .. record.label .. "'") or ""))
	out("the anchors and the whole overflow list go to SavedVariables, which does")
	out("not truncate.")
	out("|cffffcc00Run it in each state you want compared, labelling them, e.g.|r")
	out("  /dufprobe scroll fresh      then reopen and switch tabs, then")
	out("  /dufprobe scroll tabswitch")
	out("|cffffcc00Then /reload once|r to flush all of them to disk.")
end

--------------------------------------------------------------------------------
-- Plan 19 - group heal prediction
--
-- Plan 11 predicts only the player's own heals. Plan 19 widens that to the
-- group, and it splits into a half that is certain and a half that hangs on one
-- unanswered question. This probe answers the question.
--
-- The HoT half needs no probe: Compat.GetAura already returns the caster, so
-- another player's HoT is detectable by deleting a filter. What it DOES need is
-- confidence that the caster still resolves at raid distances (Q4) and that
-- their heals reach the combat log at all (Q5) -- if either fails, group HoTs
-- go quiet in exactly the raid where they matter, and the plan's value changes
-- before a line of it is written.
--
-- The direct-cast half needs two things and only one is likely to exist:
--
--   * a cast-start signal for a unit that is not the player (Q1, Q2). Classic
--     Era 1.15 restored native enemy cast bars, so this is expected to work --
--     but "expected" is what this file exists to stop the addon relying on, and
--     an enemy cast bar is not evidence about a FRIENDLY unit token.
--   * the cast's TARGET (Q3), and there is no API for it. UNIT_SPELLCAST_SENT
--     carries a target only for your own casts. The one remaining candidate is
--     the combat log's SPELL_CAST_START, and whether it populates the dest
--     fields could not be settled from documentation either way.
--
-- Q3 is the decisive line in this run. If SPELL_CAST_START carries a target,
-- other players' direct heals become an ordinary plan -- the learning path is
-- already keyed by caster. If it does not, the only honest routes left are
-- LibHealComm's addon-to-addon comms or guessing at the caster's own target,
-- and both are decisions rather than implementations.
--
-- SPELL_CAST_SUCCESS is counted alongside it as a CONTROL. It is expected to
-- carry a target, so a run where neither has one means the trace saw nothing
-- worth measuring, not that the answer is no.
--
-- Run it in a party or raid with at least one other healer, in a real fight.
-- A solo run still reports the static half (CVars, event validity, the aura
-- census) and says plainly that the rest is inconclusive.
--------------------------------------------------------------------------------

local healsTracer = CreateFrame("Frame")
local healsRunning = false

--- The combat log's "no destination" GUID. Some builds send nil instead, so
-- both are treated as absent and the raw value is recorded either way.
local NULL_GUID = "0000000000000000"

--- How far away another unit's combat-log lines still reach you. This bounds
-- LEARNING rather than display: a healer beyond it produces nothing to learn
-- from, so their spells stay unlearned until they are nearby once.
local COMBAT_LOG_RANGE_CVARS = {
	"CombatLogRangeParty",
	"CombatLogRangePartyPet",
	"CombatLogRangeFriendlyPlayers",
	"CombatLogRangeFriendlyPlayersPets",
	"CombatLogRangeHostilePlayers",
	"CombatLogRangeHostilePlayersPets",
	"CombatLogRangeCreature",
}

local SPELLCAST_EVENTS = {
	"UNIT_SPELLCAST_START",
	"UNIT_SPELLCAST_CHANNEL_START",
	"UNIT_SPELLCAST_SENT",
}

local function getCVar(name)
	local fn = _G.GetCVar or (_G.C_CVar and _G.C_CVar.GetCVar)
	if not fn then return nil end
	local ok, value = pcall(fn, name)
	if not ok then return nil end
	return value
end

--- Every unit token in the current group, player included.
local function groupUnits()
	local units = { "player" }
	local total = (GetNumGroupMembers and GetNumGroupMembers()) or 0
	if IsInRaid and IsInRaid() then
		for i = 1, total do units[#units + 1] = "raid" .. i end
	else
		-- GetNumGroupMembers counts the player in a party too, and party tokens
		-- run 1..n-1.
		for i = 1, math.max(total - 1, 0) do units[#units + 1] = "party" .. i end
	end
	return units
end

--- One helpful aura, through whichever accessor this client has. Deliberately
-- a local copy rather than a call into Compat: this addon must still load on a
-- patch that breaks the main one.
local function readHelpfulAura(unit, index)
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		local data = C_UnitAuras.GetAuraDataByIndex(unit, index, "HELPFUL")
		if not data or not data.name then return nil end
		return data.name, data.spellId, data.sourceUnit, data.duration, data.expirationTime
	end
	if not UnitAura then return nil end
	local name, _, _, _, duration, expirationTime, source, _, _, spellId =
		UnitAura(unit, index, "HELPFUL")
	if not name then return nil end
	return name, spellId, source, duration, expirationTime
end

--- Q4. For every helpful aura on every group member, does the CASTER resolve to
-- a unit token, and does that survive the caster being out of range?
--
-- The count that matters is `sourceOutOfRange`: an aura whose source resolved
-- while that source was too far away to interact with is direct evidence that
-- token resolution does not depend on distance. A run with zero of those has
-- not answered the question -- it has just been run at close quarters.
local function auraCensus()
	local census = { units = {}, helpful = 0, withSource = 0, noSource = 0,
		durational = 0, durationalNoSource = 0, sourceOutOfRange = 0, orphans = {} }

	for _, unit in ipairs(groupUnits()) do
		if UnitExists(unit) then
			local entry = {
				name = UnitName(unit),
				visible = UnitIsVisible(unit) and true or false,
				helpful = 0, withSource = 0, noSource = 0,
			}

			if UnitInRange then
				local ok, inRange, checked = pcall(UnitInRange, unit)
				if ok then entry.inRange, entry.rangeChecked = inRange, checked end
			end

			for index = 1, 40 do
				local name, spellID, source, duration, expiration = readHelpfulAura(unit, index)
				if not name then break end

				entry.helpful = entry.helpful + 1
				census.helpful = census.helpful + 1

				-- A HoT always has a duration. Permanent raid buffs are the bulk
				-- of a helpful scan and are noise for this question.
				local hotLike = (duration and duration > 0 and expiration and expiration > 0)
				if hotLike then census.durational = census.durational + 1 end

				if source then
					entry.withSource = entry.withSource + 1
					census.withSource = census.withSource + 1
					if UnitInRange then
						local ok, inRange, checked = pcall(UnitInRange, source)
						if ok and checked and not inRange then
							census.sourceOutOfRange = census.sourceOutOfRange + 1
						end
					end
				else
					entry.noSource = entry.noSource + 1
					census.noSource = census.noSource + 1
					if hotLike then
						census.durationalNoSource = census.durationalNoSource + 1
						if #census.orphans < 20 then
							census.orphans[#census.orphans + 1] = {
								on = unit, aura = name, spellID = spellID,
								onVisible = entry.visible, onInRange = entry.inRange,
							}
						end
					end
				end
			end

			census.units[unit] = entry
		end
	end

	return census
end

local function startHealTrace(seconds, label)
	if healsRunning then
		out("|cffffcc00A heal trace is already running.|r Wait for it to finish.")
		return
	end

	seconds = seconds or 90
	if label == "" then label = nil end

	local started = GetTime()
	local version, build, buildDate, tocVersion = GetBuildInfo()

	local record = {
		timestamp = date("%Y-%m-%d %H:%M:%S"),
		label = label,
		version = version, build = build, buildDate = buildDate, tocVersion = tocVersion,
		projectId = WOW_PROJECT_ID,
		seconds = seconds,
		playerGUID = UnitGUID("player"),

		combatLogRanges = {},
		eventsValid = {},
		roster = {},

		-- Q1: which unit tokens the client actually delivers spellcast events for
		spellcastUnits = {},
		-- Q2: what UnitCastingInfo returns for a unit that is not the player
		castingInfo = {},
		-- Q3, and its control
		castStart = { total = 0, withDest = 0, nullDest = 0, fromGroup = 0, samples = {} },
		castSuccess = { total = 0, withDest = 0, nullDest = 0 },
		-- Sizing the cost of widening the combat-log guard
		lines = 0,
		heals = { direct = 0, periodic = 0, fromGroup = 0, fromOutside = 0, bySource = {}, sources = 0 },
	}

	for _, name in ipairs(COMBAT_LOG_RANGE_CVARS) do
		record.combatLogRanges[name] = getCVar(name)
	end
	for _, event in ipairs(SPELLCAST_EVENTS) do
		record.eventsValid[event] = eventExists(event)
	end

	local runs = registerRun("heals", record)

	-- The roster is both the group census and the "is this line worth reading"
	-- test that Plan 19's combat-log guard will use, so it is built the same way
	-- here: a GUID set, rebuilt on roster change rather than walked per line.
	local roster = {}
	local function rebuildRoster()
		roster = {}
		local named = {}
		for _, unit in ipairs(groupUnits()) do
			local guid = UnitGUID(unit)
			if guid then
				roster[guid] = true
				named[guid] = (UnitName(unit) or unit)
			end
		end
		record.roster = named
		record.rosterSize = 0
		for _ in pairs(named) do record.rosterSize = record.rosterSize + 1 end
	end
	rebuildRoster()

	record.censusBefore = auraCensus()

	local function hasDestination(guid)
		return guid ~= nil and guid ~= "" and guid ~= NULL_GUID
	end

	local function onCombatLog()
		local info = CombatLogGetCurrentEventInfo
		if not info then return end
		local _, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName, _, _,
			spellID, spellName = info()

		record.lines = record.lines + 1

		if subevent == "SPELL_CAST_START" then
			local c = record.castStart
			c.total = c.total + 1
			local dest = hasDestination(destGUID)
			if dest then c.withDest = c.withDest + 1 else c.nullDest = c.nullDest + 1 end
			if roster[sourceGUID] then c.fromGroup = c.fromGroup + 1 end
			-- Samples are capped rather than complete: the counts answer the
			-- question and forty lines are enough to see the SHAPE of a dest
			-- field, which is what a nil-versus-zeroed-GUID distinction needs.
			if #c.samples < 40 then
				c.samples[#c.samples + 1] = {
					t = GetTime() - started,
					source = sourceName, sourceGUID = sourceGUID,
					dest = destName, destGUID = destGUID,
					destPresent = dest,
					spellID = spellID, spell = spellName,
					fromGroup = roster[sourceGUID] and true or false,
				}
			end
			return
		end

		if subevent == "SPELL_CAST_SUCCESS" then
			local c = record.castSuccess
			c.total = c.total + 1
			if hasDestination(destGUID) then
				c.withDest = c.withDest + 1
			else
				c.nullDest = c.nullDest + 1
			end
			return
		end

		if subevent ~= "SPELL_HEAL" and subevent ~= "SPELL_PERIODIC_HEAL" then return end

		local h = record.heals
		if subevent == "SPELL_HEAL" then h.direct = h.direct + 1 else h.periodic = h.periodic + 1 end

		if roster[sourceGUID] then h.fromGroup = h.fromGroup + 1 else h.fromOutside = h.fromOutside + 1 end

		local key = sourceGUID or "unknown"
		local entry = h.bySource[key]
		if not entry then
			-- Bounded so a battleground cannot turn SavedVariables into a
			-- transcript. Counts above are unaffected.
			if h.sources >= 80 then return end
			h.sources = h.sources + 1
			entry = { name = sourceName, inGroup = roster[key] and true or false,
				direct = 0, periodic = 0, spells = {} }
			h.bySource[key] = entry
		end
		if subevent == "SPELL_HEAL" then
			entry.direct = entry.direct + 1
		else
			entry.periodic = entry.periodic + 1
		end
		local id = spellID or 0
		entry.spells[id] = (entry.spells[id] or 0) + 1
	end

	--- Q1 and Q2 together. The event is registered UNFILTERED -- not through
	-- RegisterUnitEvent -- precisely so the unit token the client chooses to
	-- send is the measurement rather than an assumption baked into the filter.
	local function noteSpellcast(event, unit)
		if not unit then return end
		local key = event .. " " .. unit
		record.spellcastUnits[key] = (record.spellcastUnits[key] or 0) + 1
		if unit == "player" or event == "UNIT_SPELLCAST_SENT" then return end
		if #record.castingInfo >= 25 then return end

		-- Recorded as raw returns rather than as named fields: the signature has
		-- moved before (the `rank` return went), and a probe that unpacks into
		-- names it assumed would hide exactly that.
		local sample = { t = GetTime() - started, event = event, unit = unit,
			name = UnitName(unit), returns = {} }
		local fn = _G.UnitCastingInfo
		if event == "UNIT_SPELLCAST_CHANNEL_START" then fn = _G.UnitChannelInfo or fn end
		if fn then
			local packed = { pcall(fn, unit) }
			sample.ok = packed[1]
			for i = 2, 10 do sample.returns[i - 1] = tostring(packed[i]) end
			sample.readable = (packed[1] and packed[2] ~= nil) and true or false
		else
			sample.ok, sample.readable = false, false
		end
		record.castingInfo[#record.castingInfo + 1] = sample
	end

	pcall(healsTracer.RegisterEvent, healsTracer, "COMBAT_LOG_EVENT_UNFILTERED")
	pcall(healsTracer.RegisterEvent, healsTracer, "GROUP_ROSTER_UPDATE")
	for _, event in ipairs(SPELLCAST_EVENTS) do
		pcall(healsTracer.RegisterEvent, healsTracer, event)
	end

	healsTracer:SetScript("OnEvent", function(_, event, unit)
		if event == "COMBAT_LOG_EVENT_UNFILTERED" then
			onCombatLog()
		elseif event == "GROUP_ROSTER_UPDATE" then
			rebuildRoster()
		else
			noteSpellcast(event, unit)
		end
	end)

	healsRunning = true

	header("Heal sourcing trace (Plan 19)")
	out("Tracing for " .. seconds .. "s. Group size:", record.rosterSize or 0)
	out("|cffffcc00Run this in a party or raid with another healer, mid-fight.|r")
	out("Solo, only the CVars and the aura census below mean anything.")

	header("Combat log range (Q5 - bounds LEARNING, not display)")
	for _, name in ipairs(COMBAT_LOG_RANGE_CVARS) do
		local value = record.combatLogRanges[name]
		out(" ", name, value == nil and "|cff808080absent|r" or tostring(value))
	end

	header("Spellcast events valid")
	for _, event in ipairs(SPELLCAST_EVENTS) do
		out(" ", event, yn(record.eventsValid[event]))
	end

	local before = record.censusBefore
	header("Aura census (Q4)")
	out(before.helpful, "helpful aura(s) across the group;",
		before.withSource, "resolved a caster,", before.noSource, "did not")
	out("Durational (HoT-like):", before.durational,
		" of those with no caster:", before.durationalNoSource)
	out("Resolved while the caster was OUT OF RANGE:", before.sourceOutOfRange,
		before.sourceOutOfRange > 0 and "|cff40ff40(distance does not break it)|r" or "")

	C_Timer.After(seconds, function()
		healsTracer:UnregisterAllEvents()
		healsTracer:SetScript("OnEvent", nil)
		healsRunning = false

		record.censusAfter = auraCensus()

		record.completed = true

		header("Heal sourcing trace finished")
		out(record.lines, "combat log line(s) in", seconds .. "s",
			string.format("(%.1f/s)", record.lines / seconds))

		---------------------------------------------------------------- Q1 / Q2
		local tokens, nonPlayer = {}, 0
		for key, count in pairs(record.spellcastUnits) do
			tokens[#tokens + 1] = key .. "=" .. count
			if not key:find(" player$") then nonPlayer = nonPlayer + 1 end
		end
		table.sort(tokens)
		header("Q1 - which units send spellcast events")
		if #tokens == 0 then
			out("|cffffcc00Nothing fired.|r Inconclusive - nobody cast near you.")
		else
			for i = 1, #tokens do out(" ", tokens[i]) end
			if nonPlayer > 0 then
				out("|cff40ff40Spellcast events DO fire for units other than the player.|r")
			else
				out("|cffff5555Only 'player' ever appeared.|r Other units' casts are not")
				out("evented on this client; the combat log is the only source.")
			end
		end

		local readable = 0
		for _, sample in ipairs(record.castingInfo) do
			if sample.readable then readable = readable + 1 end
		end
		header("Q2 - UnitCastingInfo on a non-player unit")
		out(#record.castingInfo, "sample(s),", readable, "returned a cast")
		if #record.castingInfo > 0 and readable == 0 then
			out("|cffff5555The event fires but the reader is empty|r - no end time, so no")
			out("window to predict over. Full returns are in SavedVariables.")
		end

		------------------------------------------------------------------- Q3
		local cs, cc = record.castStart, record.castSuccess
		header("Q3 - does SPELL_CAST_START carry a target? (decisive)")
		out("SPELL_CAST_START:", cs.total, "line(s),", cs.withDest, "with a destination,",
			cs.nullDest, "without.", cs.fromGroup, "from group members")
		out("SPELL_CAST_SUCCESS (control):", cc.total, "line(s),", cc.withDest, "with a destination")

		if cs.total == 0 then
			out("|cffffcc00No cast-start lines at all.|r Inconclusive; run it in a fight.")
		elseif cs.withDest > 0 then
			out("|cff40ff40SPELL_CAST_START CARRIES A TARGET.|r Other players' direct heals")
			out("are buildable with no comms library. Plan 19's deferral is one plan long.")
		elseif cc.withDest == 0 then
			out("|cffffcc00Neither subevent carried a destination|r - including the control,")
			out("so this run measured nothing. Re-run it on targeted casts.")
		else
			out("|cffff5555SPELL_CAST_START never carried a target|r across", cs.total, "line(s),")
			out("while the control did. Others' direct heals need LibHealComm or a guess")
			out("at the caster's own target. The HoT half is unaffected.")
		end

		------------------------------------------------------------------- Q4
		local after = record.censusAfter
		header("Q4 - does the aura caster resolve at distance?")
		out("Durational auras with no caster - before:", before.durationalNoSource,
			" after:", after.durationalNoSource)
		out("Resolved with the caster out of range - before:", before.sourceOutOfRange,
			" after:", after.sourceOutOfRange)
		if after.sourceOutOfRange > 0 or before.sourceOutOfRange > 0 then
			out("|cff40ff40Resolution survives distance.|r The HoT half is sound.")
		elseif after.durationalNoSource > 0 then
			out("|cffff5555Some HoTs have no resolvable caster.|r Named in SavedVariables")
			out("under orphans - check whether those casters were in your group at all.")
		else
			out("|cffffcc00No out-of-range casters were sampled.|r Not answered; re-run")
			out("with the raid spread out.")
		end

		------------------------------------------------------------------- Q5
		local h = record.heals
		header("Q5 - heals reaching the log, and what the guard would cost")
		out("Heals:", h.direct, "direct,", h.periodic, "periodic, from", h.sources, "source(s)")
		out("From group members:", h.fromGroup, " from outside the group:", h.fromOutside)
		if record.lines > 0 then
			out(string.format("Heals are %.1f%% of all lines; the group's share is %.1f%%",
				100 * (h.direct + h.periodic) / record.lines,
				100 * h.fromGroup / record.lines))
		end

		out(string.format("|cff40ff40Saved as run %d%s.|r Chat is the summary; the samples,",
			#runs, label and (" labelled '" .. label .. "'") or ""))
		out("the full UnitCastingInfo returns and the orphan list go to SavedVariables.")
		out("|cffffcc00/reload once|r when you are done to flush it to disk.")
	end)
end

--------------------------------------------------------------------------------
-- Plan 19 - is anyone still broadcasting on LibHealComm?
--
-- /dufprobe heals answered the direct-cast question and the answer was no: 368
-- SPELL_CAST_START lines across two raids, none carrying a destination, against
-- a SPELL_CAST_SUCCESS control that carried one four times in five. The combat
-- log does not know who a cast in flight is aimed at.
--
-- What it also showed is that everything ELSE is exact. UNIT_SPELLCAST_START
-- fires for raid tokens, UnitCastingInfo reads back for them 25 times out of 25,
-- and the amounts are already learned. The gap is one field wide: the target.
--
-- LibHealComm-4.0 fills exactly that field, and vendoring it is not viable --
-- its Classic branch stopped in September 2022 against TOC 1.13.3, two years
-- before Classic Era 1.15 and before Anniversary existed at all. But the library
-- is only one half of what it is. The other half is a WIRE FORMAT that every
-- VuhDo, HealBot, Grid2 and ElvUI user in the raid may still be transmitting on,
-- and receiving that needs no spell database and nothing that can go stale.
--
-- Whether that is worth designing depends on a number nobody can supply from a
-- forum post: HOW MANY HEALERS IN YOUR RAID ARE ACTUALLY BROADCASTING. So this
-- counts them.
--
-- Two properties this deliberately has:
--
--   * IT IS RECEIVE-ONLY. Nothing here ever calls SendAddonMessage. Injecting
--     malformed LHC40 traffic would break heal prediction for every person in
--     the raid running an addon that reads it, which is not a cost a probe gets
--     to impose on other people.
--   * IT REGISTERS SEVERAL PREFIXES. "LHC40" is the real one, confirmed against
--     published forks of the library. The others are kept because a probe that
--     registers ONE prefix and sees nothing cannot tell "nobody is broadcasting"
--     from "wrong prefix", and those two answers point in opposite directions.
--
-- The verdict turns on the OVERLAP, not on the raw message count: of the healers
-- seen healing in the combat log, how many also transmitted. Ten thousand
-- messages from two people is a worse answer than fifty from twelve.
--------------------------------------------------------------------------------

local healcommTracer = CreateFrame("Frame")
local healcommRunning = false

local HEALCOMM_PREFIXES = { "LHC40", "HealComm", "LHC", "LibHealComm" }

--- Heal events in the window before a source counts as "a healer". Filters out
-- the incidental: a warlock's health funnel, a healthstone, a paladin's one
-- panic Flash of Light. Deliberately low -- the question is who CAN heal, not
-- who topped the meters.
local HEALER_THRESHOLD = 5

--- Names arrive as "Name" from the combat log and "Name-Realm" from the addon
-- channel, so both sides get flattened before they are compared. Without this
-- every cross-realm sender would look like a healer who was not broadcasting,
-- which is the exact direction that would produce a false negative.
local function shortName(name)
	if not name then return nil end
	return name:match("^([^-]+)") or name
end

local function registerPrefix(prefix)
	local fn = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix)
		or _G.RegisterAddonMessagePrefix
	if not fn then return nil end
	local ok, result = pcall(fn, prefix)
	if not ok then return false end
	-- C_ChatInfo returns a boolean; the older global returned nothing at all,
	-- so "no error" is the only success signal available there.
	if result == nil then return true end
	return result and true or false
end

local function startHealCommTrace(seconds, label)
	if healcommRunning then
		out("|cffffcc00A healcomm trace is already running.|r Wait for it to finish.")
		return
	end

	seconds = seconds or 90
	if label == "" then label = nil end

	local started = GetTime()
	local version, build, buildDate, tocVersion = GetBuildInfo()

	local record = {
		timestamp = date("%Y-%m-%d %H:%M:%S"),
		label = label,
		version = version, build = build, buildDate = buildDate, tocVersion = tocVersion,
		projectId = WOW_PROJECT_ID,
		seconds = seconds,
		playerName = shortName(UnitName("player")),
		rosterSize = (GetNumGroupMembers and GetNumGroupMembers()) or 0,
		inRaid = (IsInRaid and IsInRaid()) and true or false,
		prefixes = {},
		healers = {},
		healerCount = 0,
		lines = 0,
	}

	header("LibHealComm listener (Plan 19)")

	local anyRegistered = false
	for _, prefix in ipairs(HEALCOMM_PREFIXES) do
		local registered = registerPrefix(prefix)
		if registered then anyRegistered = true end
		record.prefixes[prefix] = {
			registered = registered,
			messages = 0,
			senders = {},
			senderCount = 0,
			channels = {},
			samples = {},
		}
		out(" ", prefix, "registered", yn(registered))
	end

	if not anyRegistered then
		out("|cffff5555No addon message prefix could be registered.|r Nothing to")
		out("listen on; the receive-only route cannot be evaluated on this client.")
		record.registrationFailed = true
	end

	local runs = registerRun("healcomm", record)

	local function onAddonMessage(prefix, text, channel, sender)
		local entry = record.prefixes[prefix]
		if not entry then return end

		entry.messages = entry.messages + 1

		local from = shortName(sender) or "?"
		if not entry.senders[from] then
			entry.senders[from] = 0
			entry.senderCount = entry.senderCount + 1
		end
		entry.senders[from] = entry.senders[from] + 1

		local where = channel or "?"
		entry.channels[where] = (entry.channels[where] or 0) + 1

		-- A few truncated samples, to judge later what parsing the format would
		-- actually cost. Capped and clipped: this is other people's raid traffic
		-- and there is no reason to keep a transcript of it.
		if #entry.samples < 8 then
			entry.samples[#entry.samples + 1] = {
				t = GetTime() - started,
				from = from,
				channel = where,
				text = tostring(text or ""):sub(1, 120),
			}
		end
	end

	local function onCombatLog()
		local info = CombatLogGetCurrentEventInfo
		if not info then return end
		local _, subevent, _, _, sourceName = info()

		record.lines = record.lines + 1
		if subevent ~= "SPELL_HEAL" and subevent ~= "SPELL_PERIODIC_HEAL" then return end

		local name = shortName(sourceName)
		if not name then return end

		if not record.healers[name] then
			record.healers[name] = 0
			record.healerCount = record.healerCount + 1
		end
		record.healers[name] = record.healers[name] + 1
	end

	pcall(healcommTracer.RegisterEvent, healcommTracer, "CHAT_MSG_ADDON")
	pcall(healcommTracer.RegisterEvent, healcommTracer, "COMBAT_LOG_EVENT_UNFILTERED")

	healcommTracer:SetScript("OnEvent", function(_, event, a, b, c, d)
		if event == "CHAT_MSG_ADDON" then
			onAddonMessage(a, b, c, d)
		else
			onCombatLog()
		end
	end)

	healcommRunning = true

	out("Listening for " .. seconds .. "s. Group size:", record.rosterSize,
		record.inRaid and "(raid)" or "(party)")
	out("|cffffcc00Run it mid-fight, with the raid's healers actually healing.|r")
	out("Receive-only - this never transmits anything.")

	C_Timer.After(seconds, function()
		healcommTracer:UnregisterAllEvents()
		healcommTracer:SetScript("OnEvent", nil)
		healcommRunning = false

		-- The overlap, which is the whole question. Three sets rather than one
		-- ratio: healers who transmitted, healers who did not, and senders never
		-- seen healing (a healer who happened not to cast in the window, or an
		-- addon broadcasting for someone who is not healing at all).
		local lhc = record.prefixes["LHC40"]
		local anySender = {}
		for _, entry in pairs(record.prefixes) do
			for name in pairs(entry.senders) do anySender[name] = true end
		end

		local broadcasting, silent, sendersNotHealing = {}, {}, {}
		for name, count in pairs(record.healers) do
			if count >= HEALER_THRESHOLD then
				if anySender[name] then
					broadcasting[#broadcasting + 1] = name
				else
					silent[#silent + 1] = name
				end
			end
		end
		for name in pairs(anySender) do
			if (record.healers[name] or 0) < HEALER_THRESHOLD then
				sendersNotHealing[#sendersNotHealing + 1] = name
			end
		end
		table.sort(broadcasting)
		table.sort(silent)
		table.sort(sendersNotHealing)

		record.broadcastingHealers = broadcasting
		record.silentHealers = silent
		record.sendersNotHealing = sendersNotHealing
		record.healerThreshold = HEALER_THRESHOLD

		record.completed = true

		header("LibHealComm listener finished")
		out(record.lines, "combat log line(s);", record.healerCount,
			"distinct heal source(s), of which", #broadcasting + #silent,
			"cast at least", HEALER_THRESHOLD, "heal(s)")

		header("Traffic by prefix")
		local totalMessages = 0
		for _, prefix in ipairs(HEALCOMM_PREFIXES) do
			local entry = record.prefixes[prefix]
			totalMessages = totalMessages + entry.messages
			local channels = {}
			for where, n in pairs(entry.channels) do channels[#channels + 1] = where .. "=" .. n end
			table.sort(channels)
			out(" ", prefix, entry.messages, "message(s) from", entry.senderCount, "sender(s)",
				#channels > 0 and ("[" .. table.concat(channels, " ") .. "]") or "")
		end

		header("The number this run exists for")
		out("Healers broadcasting:", #broadcasting,
			#broadcasting > 0 and ("(" .. table.concat(broadcasting, ", ") .. ")") or "")
		out("Healers NOT broadcasting:", #silent,
			#silent > 0 and ("(" .. table.concat(silent, ", ") .. ")") or "")
		if #sendersNotHealing > 0 then
			out("Broadcasting but not seen healing:", #sendersNotHealing,
				"(" .. table.concat(sendersNotHealing, ", ") .. ")")
		end

		local observed = #broadcasting + #silent
		if record.registrationFailed then
			out("|cffff5555Registration failed, so zero traffic means nothing.|r")
		elseif totalMessages == 0 and observed == 0 then
			out("|cffffcc00Nothing heard and nobody healed.|r Inconclusive - this run")
			out("measured neither side. Re-run it during a real fight.")
		elseif totalMessages == 0 then
			out("|cffff5555Not one message, across", observed, "healer(s) who were")
			out("actively healing.|r Nobody in this group is transmitting on any prefix")
			out("tried, so a receive-only implementation would show an empty bar.")
			out("The direct-cast half is dead on this client unless the prefix is wrong -")
			out("check the registration lines above before concluding.")
		elseif #broadcasting == 0 then
			out("|cffffcc00Traffic exists but none of it is from the healers.|r Worth")
			out("looking at the samples in SavedVariables before drawing a conclusion.")
		else
			out(string.format("|cff40ff40%d of %d active healers are broadcasting (%.0f%%).|r",
				#broadcasting, observed, observed > 0 and (100 * #broadcasting / observed) or 0))
			out("A receive-only reader would cover that share of the raid's direct heals,")
			out("with no spell database and nothing to go stale. Sample messages are in")
			out("SavedVariables - the format decides what parsing them costs.")
		end

		out(string.format("|cff40ff40Saved as run %d%s.|r", #runs,
			label and (" labelled '" .. label .. "'") or ""))
		out("|cffffcc00/reload once|r when you are done to flush it to disk.")
	end)
end

--------------------------------------------------------------------------------
-- Plan 19 / Plan 11 / Plan 12 - does UnitGetIncomingHeals actually WORK?
--
-- /duf compat reported hasIncomingHeals = true on Anniversary 2.5.6. That flag
-- is `_G.UnitGetIncomingHeals ~= nil` and nothing more, so what it establishes
-- is that the FUNCTION EXISTS. These clients run the modern shared codebase, in
-- which a function can be present and inert.
--
-- This file already records the mirror-image case: UNIT_COMBO_POINTS was gone
-- while GetComboPoints kept working, and Plan 9 shipped subscribed to nothing
-- because presence was read as capability. So the flag being true is a reason to
-- measure, not a reason to believe.
--
-- Five questions, in the order they change what gets built:
--
--   1. Does it ever return non-zero AT ALL, in a raid, with people healing? A
--      function that always answers 0 is absent with extra steps.
--   2. Does it include OTHER PEOPLE'S heals, or only the player's? Answered
--      without any guesswork by sampling both forms at once: the one-argument
--      call is every incoming heal, the two-argument call filtered to "player"
--      is ours alone. If all > mine at any instant, other people are in there,
--      and Plan 19's entire blocker is gone.
--   3. HOW EARLY does it go non-zero? A value that appears at the moment the
--      heal lands predicts nothing. The lead time is the feature.
--   4. Is it PUSHED (UNIT_HEAL_PREDICTION) or must it be polled? Decides
--      whether reading it costs a ticker, which SPEC 5.7 has opinions about.
--   5. Does UnitGetTotalAbsorbs work too? Same shape of question, and a yes
--      deletes most of Plan 12.
--
-- The correlation this run exists for: every non-zero reading is held until a
-- heal actually lands on that unit, then predicted-versus-actual and the lead
-- time are both recorded. That turns "the API exists" into "the API is worth
-- building on", which are very different claims.
--------------------------------------------------------------------------------

local incomingTracer = CreateFrame("Frame")
local incomingRunning = false

--- Sampled at 10 Hz for 90 seconds. Kept to the units this addon can actually
-- draw, plus the player, who is the one most likely to be healed by somebody
-- else. Forty raid tokens at this rate would be 400 calls a second for a
-- question that eight units answer.
local INCOMING_UNITS = {
	"player", "target", "focus",
	"party1", "party2", "party3", "party4",
}

local INCOMING_SAMPLE = 0.1

local function callNumber(fnName, unit, healer)
	local fn = _G[fnName]
	if not fn then return nil end
	local ok, value
	if healer then
		ok, value = pcall(fn, unit, healer)
	else
		ok, value = pcall(fn, unit)
	end
	if not ok then return nil end
	return tonumber(value) or 0
end

local function startIncomingTrace(seconds, label)
	if incomingRunning then
		out("|cffffcc00An incoming trace is already running.|r Wait for it to finish.")
		return
	end

	seconds = seconds or 90
	if label == "" then label = nil end

	local started = GetTime()
	local version, build, buildDate, tocVersion = GetBuildInfo()

	local record = {
		timestamp = date("%Y-%m-%d %H:%M:%S"),
		label = label,
		version = version, build = build, buildDate = buildDate, tocVersion = tocVersion,
		projectId = WOW_PROJECT_ID,
		seconds = seconds,
		playerGUID = UnitGUID("player"),
		rosterSize = (GetNumGroupMembers and GetNumGroupMembers()) or 0,
		inRaid = (IsInRaid and IsInRaid()) and true or false,

		present = {
			UnitGetIncomingHeals = (_G.UnitGetIncomingHeals ~= nil),
			UnitGetTotalAbsorbs = (_G.UnitGetTotalAbsorbs ~= nil),
			UnitGetTotalHealAbsorbs = (_G.UnitGetTotalHealAbsorbs ~= nil),
			UNIT_HEAL_PREDICTION = eventExists("UNIT_HEAL_PREDICTION"),
			UNIT_ABSORB_AMOUNT_CHANGED = eventExists("UNIT_ABSORB_AMOUNT_CHANGED"),
		},

		samples = 0,
		nonZero = 0,               -- samples where all-incoming was above zero
		nonZeroOthers = 0,         -- ... and exceeded the player's own contribution
		maxAll = 0,
		maxMine = 0,
		maxOthers = 0,
		-- The filtered form is the entire basis for "are other people included",
		-- so whether it WORKS is tracked separately from what it returns. A form
		-- that errors would otherwise read as `mine = 0`, making every heal in
		-- the game look like somebody else's -- a false positive on the one
		-- question this run exists to answer.
		twoArgOk = 0,
		twoArgFailed = 0,
		playerHeals = 0,
		absorbNonZero = 0,
		maxAbsorb = 0,
		predictionEvents = 0,
		predictionUnits = {},
		observations = {},         -- resolved predicted-vs-actual pairs
		pending = {},              -- unit -> first sighting, awaiting a landing
		unresolved = 0,
	}

	header("Incoming heals API (Plans 11, 12, 19)")
	for name, present in pairs(record.present) do
		out(" ", name, yn(present))
	end

	if not record.present.UnitGetIncomingHeals then
		out("|cffff5555UnitGetIncomingHeals is not present after all.|r Nothing to trace.")
		return
	end

	local runs = registerRun("incoming", record)

	-- Question 2's whole apparatus, and it is deliberately this small. Sampling
	-- both forms in the same instant means "are other people included" needs no
	-- inference about timing or ordering: the difference IS the answer.
	local function sampleUnit(unit)
		if not UnitExists(unit) then return end

		local all = callNumber("UnitGetIncomingHeals", unit)
		if not all then return end

		local mine = callNumber("UnitGetIncomingHeals", unit, "player")
		local others
		if mine == nil then
			record.twoArgFailed = record.twoArgFailed + 1
		else
			record.twoArgOk = record.twoArgOk + 1
			others = all - mine
			if others < 0 then others = 0 end
		end

		record.samples = record.samples + 1
		if all > record.maxAll then record.maxAll = all end
		if mine and mine > record.maxMine then record.maxMine = mine end
		if others and others > record.maxOthers then record.maxOthers = others end

		local absorb = callNumber("UnitGetTotalAbsorbs", unit)
		if absorb and absorb > 0 then
			record.absorbNonZero = record.absorbNonZero + 1
			if absorb > record.maxAbsorb then record.maxAbsorb = absorb end
		end

		if all <= 0 then return end

		record.nonZero = record.nonZero + 1
		if others and others > 0 then record.nonZeroOthers = record.nonZeroOthers + 1 end

		-- Question 3. The FIRST sighting is what the lead time is measured from,
		-- so a unit already pending is left alone rather than refreshed.
		local guid = UnitGUID(unit)
		if guid and not record.pending[guid] then
			record.pending[guid] = {
				unit = unit, at = GetTime(), all = all, mine = mine, others = others,
			}
		end
	end

	local sampler = C_Timer.NewTicker(INCOMING_SAMPLE, function()
		for i = 1, #INCOMING_UNITS do sampleUnit(INCOMING_UNITS[i]) end
	end)

	local function onCombatLog()
		local info = CombatLogGetCurrentEventInfo
		if not info then return end
		local _, subevent, _, sourceGUID, sourceName, _, _, destGUID, _, _, _,
			spellID, spellName, _, amount, overhealing = info()

		if subevent ~= "SPELL_HEAL" then return end
		if sourceGUID == record.playerGUID then record.playerHeals = record.playerHeals + 1 end
		if not destGUID then return end

		local waiting = record.pending[destGUID]
		if not waiting then return end
		record.pending[destGUID] = nil

		-- Predicted-versus-actual. `amount + overhealing` is the size of the
		-- heal for the same reason Plan 11 learns from the sum: a heal landing
		-- on a nearly-full target reports almost nothing, and comparing the
		-- prediction against that would make a correct API look wrong.
		local landed = (amount or 0) + (overhealing or 0)
		if #record.observations < 60 then
			record.observations[#record.observations + 1] = {
				unit = waiting.unit,
				lead = GetTime() - waiting.at,
				predictedAll = waiting.all,
				predictedMine = waiting.mine,
				predictedOthers = waiting.others,
				landed = landed,
				fromPlayer = (sourceGUID == record.playerGUID),
				source = sourceName,
				spellID = spellID, spell = spellName,
			}
		end
	end

	pcall(incomingTracer.RegisterEvent, incomingTracer, "COMBAT_LOG_EVENT_UNFILTERED")
	if record.present.UNIT_HEAL_PREDICTION then
		pcall(incomingTracer.RegisterEvent, incomingTracer, "UNIT_HEAL_PREDICTION")
	end

	incomingTracer:SetScript("OnEvent", function(_, event, unit)
		if event == "COMBAT_LOG_EVENT_UNFILTERED" then
			onCombatLog()
		elseif event == "UNIT_HEAL_PREDICTION" then
			record.predictionEvents = record.predictionEvents + 1
			local key = unit or "?"
			record.predictionUnits[key] = (record.predictionUnits[key] or 0) + 1
		end
	end)

	incomingRunning = true

	out("Sampling " .. #INCOMING_UNITS .. " unit(s) at " .. INCOMING_SAMPLE ..
		"s for " .. seconds .. "s. Group:", record.rosterSize,
		record.inRaid and "(raid)" or "(party)")
	out("|cffffcc00Get healed by other people.|r Stand in the damage if that is what it takes.")

	C_Timer.After(seconds, function()
		sampler:Cancel()
		incomingTracer:UnregisterAllEvents()
		incomingTracer:SetScript("OnEvent", nil)
		incomingRunning = false

		for _ in pairs(record.pending) do record.unresolved = record.unresolved + 1 end
		record.pending = nil

		record.completed = true

		header("Incoming heals API - results")
		out(record.samples, "sample(s);", record.nonZero, "non-zero;",
			record.nonZeroOthers, "where somebody else's heal was included")
		out("Peak values - all:", record.maxAll, " mine:", record.maxMine,
			" others:", record.maxOthers)

		------------------------------------------------------------- Q1 and Q2
		if record.samples == 0 then
			out("|cffffcc00Nothing sampled.|r No units existed to read. Inconclusive.")
		elseif record.nonZero == 0 then
			out("|cffff5555Never once non-zero|r across", record.samples, "sample(s).")
			out("The function is present and inert - absent with extra steps. Plan 11's")
			out("derived path stays the only one, and COMPAT_FINDINGS should say so.")
		elseif record.twoArgOk == 0 then
			out("|cffffcc00The value is real, but the filtered form never worked|r (",
				record.twoArgFailed, "failed call(s)).")
			out("Ours cannot be separated from theirs, so Q2 is UNPROVEN either way.")
			out("Do not read the totals below as evidence about other people.")
		elseif record.nonZeroOthers == 0 then
			out("|cffffcc00Non-zero, but never more than the player's own heals.|r")
			out("It reports OUR casts only, which Plan 11 already predicts perfectly")
			out("well. Plan 19's blocker is untouched.")
		elseif record.maxMine == 0 and record.playerHeals > 0 then
			-- The false positive this run is most exposed to. The player healed,
			-- those heals were counted somewhere, and the filtered form still
			-- attributed nothing to them -- so the filter is not filtering, and
			-- "everything is somebody else's" is an artifact rather than a
			-- finding. Reported as suspicion rather than as either answer.
			out("|cffff5555Suspicious: you cast", record.playerHeals, "heal(s) and the")
			out("filtered form never attributed one of them to you.|r The second")
			out("argument is probably not a unit token on this client, so 'all of it")
			out("is other people' is an artifact. Q2 UNPROVEN - re-run and check the")
			out("observations in SavedVariables against who actually cast them.")
		else
			out("|cff40ff40OTHER PEOPLE'S HEALS ARE INCLUDED.|r Peak from others:",
				record.maxOthers)
			out("This is the answer Plan 19 spent three probes failing to find by other")
			out("means. The combat log, LibHealComm and HealEngine are all moot.")
		end

		--------------------------------------------------------------------- Q3
		local n, leadSum, leadMax = 0, 0, 0
		local fromOthers, ratioSum, ratioN = 0, 0, 0
		for i = 1, #record.observations do
			local o = record.observations[i]
			n = n + 1
			leadSum = leadSum + o.lead
			if o.lead > leadMax then leadMax = o.lead end
			if not o.fromPlayer then fromOthers = fromOthers + 1 end
			if o.landed > 0 and o.predictedAll > 0 then
				ratioSum = ratioSum + (o.predictedAll / o.landed)
				ratioN = ratioN + 1
			end
		end

		header("Q3 - lead time, which is the whole feature")
		if n == 0 then
			out("|cffffcc00No prediction was ever followed by a landing heal.|r")
			out("Either nothing was sampled or the value appears only as the heal lands.")
		else
			out(string.format("%d resolved observation(s); lead mean %.2fs, max %.2fs",
				n, leadSum / n, leadMax))
			out(fromOthers, "of them were heals cast by somebody other than you")
			if ratioN > 0 then
				out(string.format("Predicted / actual: %.2f on average (1.00 is exact)",
					ratioSum / ratioN))
			end
			if leadMax < 0.3 then
				out("|cffff5555The value never appears more than a moment before the heal.|r")
				out("Nothing to predict with - this is a report, not a prediction.")
			else
				out("|cff40ff40Real lead time.|r There is a window to draw in.")
			end
		end
		out("Predictions that never resolved into a landing heal:", record.unresolved)

		--------------------------------------------------------------------- Q4
		header("Q4 - pushed or polled?")
		out("UNIT_HEAL_PREDICTION valid:", yn(record.present.UNIT_HEAL_PREDICTION),
			" fired:", record.predictionEvents, "time(s)")
		if record.present.UNIT_HEAL_PREDICTION and record.predictionEvents > 0 then
			out("|cff40ff40Pushed.|r No ticker needed; SPEC 5.7 stays intact.")
		elseif record.nonZero > 0 then
			out("|cffffcc00Values change but no event fires|r - reading this would cost a")
			out("ticker, which is a SPEC 5.7 argument that has to be made explicitly.")
		end

		--------------------------------------------------------------------- Q5
		header("Q5 - absorbs (Plan 12)")
		out("UnitGetTotalAbsorbs present:", yn(record.present.UnitGetTotalAbsorbs),
			" non-zero samples:", record.absorbNonZero, " peak:", record.maxAbsorb)
		if record.present.UnitGetTotalAbsorbs and record.absorbNonZero > 0 then
			out("|cff40ff40Absorbs are readable.|r Most of Plan 12 can be deleted.")
		elseif record.present.UnitGetTotalAbsorbs then
			out("|cffffcc00Present but never non-zero here.|r Needs a run with shields")
			out("actually on people before this means anything.")
		end

		out(string.format("|cff40ff40Saved as run %d%s.|r", #runs,
			label and (" labelled '" .. label .. "'") or ""))
		out("|cffffcc00/reload once|r when you are done to flush it to disk.")
	end)
end

--------------------------------------------------------------------------------
-- SPEC §1.3 and §FR-8.5 - two presence flags that are load-bearing
--
-- /duf compat on Classic Era 1.15.9 reported hasSecretValues = true and
-- hasFocus = true. Both contradict the spec, and both are PRESENCE checks:
--
--   Compat.hasSecretValues = (_G.issecretvalue ~= nil) or (_G.canaccessvalue ~= nil)
--   Compat.hasFocus        = C_EventUtils.IsEventValid("PLAYER_FOCUS_CHANGED")
--
-- On a client running the modern shared codebase, a function existing says
-- almost nothing - which is the lesson four Plan 19 probes just paid for, in the
-- other direction. So this asks what the flags are actually standing in for.
--
-- SECRET VALUES. §1.3's premise is that the text engine can read game values and
-- format them. That breaks only if a value is genuinely secret, not if a
-- function that could report one exists. So: call issecretvalue on the values
-- the text engine really reads, across every unit available, and see whether ANY
-- of them come back secret.
--
-- A LITERAL IS THE CONTROL, and it is not decoration. If issecretvalue(42)
-- comes back true then the function does not mean what this probe assumes, and
-- "nothing is secret" would be a misreading rather than a finding. Exactly the
-- role SPELL_CAST_SUCCESS played for the combat-log question.
--
-- FOCUS. §FR-8.5 gates a whole frame on focus not existing on Era, and the flag
-- now says it does. The three signals Compat probes are reported separately,
-- because they can disagree: an event can be valid in shared code while the
-- feature behind it is absent. The question that settles it is whether
-- UnitExists("focus") is ever true, and that needs a focus set - so if there is
-- none, this says so and asks for a re-run rather than guessing.
--
-- Nothing here sets or clears focus. Changing the player's focus target to
-- measure it would be a probe editing the thing it is measuring, and it is the
-- user's targeting, not ours.
--------------------------------------------------------------------------------

local SECRET_UNITS = { "player", "target", "focus", "pet", "party1" }

--- The values Elements/Text.lua actually formats. Testing arbitrary API returns
-- would answer a different, easier question.
local SECRET_ACCESSORS = {
	{ "UnitHealth", function(u) return UnitHealth(u) end },
	{ "UnitHealthMax", function(u) return UnitHealthMax(u) end },
	{ "UnitPower", function(u) return UnitPower(u) end },
	{ "UnitPowerMax", function(u) return UnitPowerMax(u) end },
	{ "UnitName", function(u) return UnitName(u) end },
	{ "UnitLevel", function(u) return UnitLevel(u) end },
	{ "UnitClass", function(u) return select(2, UnitClass(u)) end },
	{ "UnitGUID", function(u) return UnitGUID(u) end },
	{ "UnitIsDead", function(u) return UnitIsDead(u) end },
	{ "UnitIsConnected", function(u) return UnitIsConnected(u) end },
	{ "UnitGetIncomingHeals", function(u)
		local fn = _G.UnitGetIncomingHeals
		return fn and fn(u) or nil
	end },
	{ "aura.name", function(u) local n = readHelpfulAura(u, 1) return n end },
	{ "aura.expirationTime", function(u)
		local _, _, _, _, e = readHelpfulAura(u, 1) return e
	end },
}

--- @return secret, inaccessible, errored -- each a boolean or nil for "not asked"
local function classifyValue(value)
	local secret, inaccessible
	local isSecret = _G.issecretvalue
	if isSecret then
		local ok, result = pcall(isSecret, value)
		if not ok then return nil, nil, true end
		secret = result and true or false
	end
	local canAccess = _G.canaccessvalue
	if canAccess then
		local ok, result = pcall(canAccess, value)
		if not ok then return secret, nil, true end
		inaccessible = (result == false)
	end
	return secret, inaccessible, false
end

local function secretsProbe(label)
	if label == "" then label = nil end

	local version, build, buildDate, tocVersion = GetBuildInfo()
	local record = {
		timestamp = date("%Y-%m-%d %H:%M:%S"),
		label = label,
		version = version, build = build, buildDate = buildDate, tocVersion = tocVersion,
		projectId = WOW_PROJECT_ID,
		hasIsSecretValue = (_G.issecretvalue ~= nil),
		hasCanAccessValue = (_G.canaccessvalue ~= nil),
		checked = 0, secrets = {}, inaccessible = {}, errors = 0,
		control = {},
		focus = {},
	}

	header("Secret values (SPEC §1.3)")
	out("issecretvalue present", yn(record.hasIsSecretValue),
		" canaccessvalue present", yn(record.hasCanAccessValue))

	if not (record.hasIsSecretValue or record.hasCanAccessValue) then
		out("|cff40ff40Neither function exists. §1.3 holds outright.|r")
	else
		-- The control, first, so a bad reading of the API is caught before any
		-- conclusion is drawn from the real values.
		local controlsSane = true
		for _, sample in ipairs({ 42, "a string", true }) do
			local secret, inaccessible, errored = classifyValue(sample)
			record.control[tostring(sample)] = {
				secret = secret, inaccessible = inaccessible, errored = errored,
			}
			if secret or inaccessible or errored then controlsSane = false end
		end
		record.controlsSane = controlsSane
		out("Control - plain literals reported as ordinary:", yn(controlsSane))

		for _, unit in ipairs(SECRET_UNITS) do
			if UnitExists(unit) then
				for _, entry in ipairs(SECRET_ACCESSORS) do
					local name, getter = entry[1], entry[2]
					local ok, value = pcall(getter, unit)
					if ok then
						record.checked = record.checked + 1
						local secret, inaccessible, errored = classifyValue(value)
						if errored then record.errors = record.errors + 1 end
						if secret then
							record.secrets[#record.secrets + 1] = unit .. "." .. name
						end
						if inaccessible then
							record.inaccessible[#record.inaccessible + 1] = unit .. "." .. name
						end
					end
				end
			end
		end

		out(record.checked, "value(s) checked;", #record.secrets, "secret,",
			#record.inaccessible, "inaccessible,", record.errors, "call(s) errored")

		if not controlsSane then
			out("|cffff5555The control failed.|r A plain literal was reported as secret,")
			out("inaccessible or errored, so these functions do not mean what this probe")
			out("assumes. UNPROVEN - do not conclude anything from the count above.")
		elseif #record.secrets == 0 and #record.inaccessible == 0 then
			out("|cff40ff40Present but inert.|r Nothing the text engine reads is secret,")
			out("so §1.3 holds in practice. Amend the row to say so rather than")
			out("leaving it as a contradiction nobody has resolved.")
		else
			out("|cffff5555VALUES ARE ACTUALLY SECRET.|r §1.3's premise is broken and the")
			out("text engine needs rethinking. Named in SavedVariables:")
			for i = 1, math.min(#record.secrets, 6) do out("   ", record.secrets[i]) end
		end
	end

	header("Focus (SPEC §FR-8.5)")

	local f = record.focus
	f.eventValid = eventExists("PLAYER_FOCUS_CHANGED")
	f.focusFrameGlobal = (_G.FocusFrame ~= nil)
	f.focusUnitGlobal = (_G.FocusUnit ~= nil)
	f.clearFocusGlobal = (_G.ClearFocus ~= nil)
	f.exists = UnitExists("focus") and true or false
	f.targetExists = UnitExists("focustarget") and true or false
	f.name = f.exists and UnitName("focus") or nil

	-- Every signal above exists on BOTH clients while /focus only works on one,
	-- so none of them can be the load-time predicate Compat needs.
	--
	-- The slash command was the next candidate and it FAILED, 11 August 2026:
	-- SlashCmdList["FOCUS"] is nil on both clients while SLASH_FOCUS1 is
	-- "/focus" on both. The command is handled in the C client rather than
	-- registered from Lua, the same way /target is, so its absence says nothing
	-- about whether focus works. Still reported, because a future patch could
	-- move it into Lua and make it a discriminator after all.
	f.slashHandler = (_G.SlashCmdList and _G.SlashCmdList["FOCUS"] ~= nil) or false
	f.slashToken = _G.SLASH_FOCUS1
	f.clearSlashHandler = (_G.SlashCmdList and _G.SlashCmdList["CLEARFOCUS"] ~= nil) or false

	out("PLAYER_FOCUS_CHANGED valid", yn(f.eventValid))
	out("FocusFrame global", yn(f.focusFrameGlobal),
		" FocusUnit()", yn(f.focusUnitGlobal), " ClearFocus()", yn(f.clearFocusGlobal))
	out("/focus registered", yn(f.slashHandler),
		" token", tostring(f.slashToken), " /clearfocus", yn(f.clearSlashHandler))
	out("UnitExists('focus') right now", yn(f.exists),
		f.name and ("- " .. tostring(f.name)) or "")
	out("UnitExists('focustarget')", yn(f.targetExists))

	-- §FR-8.5 makes OPPOSITE predictions on the two clients: focus exists on TBC
	-- and not on Era. So the same observation is a contradiction on one and a
	-- confirmation on the other, and a verdict written for Era would announce a
	-- spec breach on TBC where there is none. Which client this is decides what
	-- the finding means.
	f.isEra = (tonumber(tocVersion) or 0) < 20000
	record.client = f.isEra and "Classic Era" or "TBC"

	if f.exists then
		if f.isEra then
			out("|cff40ff40Focus WORKS on Classic Era.|r §FR-8.5 says it does not exist")
			out("here, so that is a feature GAIN - relax the spec rather than distrust")
			out("the probe. The addon is already building the frame; now it is warranted.")
		else
			out("|cff40ff40Focus works, exactly as §FR-8.5 expects on TBC.|r")
			out("No news here - but this run is the positive control for the Era one:")
			out("it shows the check above can detect a working focus at all.")
		end
	elseif f.eventValid and label then
		-- A labelled re-run means the user was asked to focus something and did.
		-- Still nothing focused is therefore a RESULT, not a missing measurement:
		-- /focus does not work on this client, whatever the flags say.
		out("|cffff5555You focused something and 'focus' still does not exist.|r")
		if f.isEra then
			out("So §FR-8.5 is RIGHT about Era - focus does not work here - but")
			out("Compat.hasFocus is wrong, because every signal it probes exists in the")
			out("shared codebase anyway. The addon is building a focus frame that can")
			out("never populate, and offering focus as an anchor target.")
			out("Mitigation today: |cffffcc00general.focusOverride = \"off\"|r.")
		else
			out("On TBC that inverts §FR-8.5. Suspect the install before the spec.")
		end
	elseif f.eventValid then
		out("|cffffcc00The event is valid but nothing is focused|r, which proves nothing")
		out("either way - and the addon is already building a focus frame on the")
		out("strength of that flag.")
		out("|cffffcc00Target something, /focus it, then re-run:|r /dufprobe secrets focused")
	elseif f.isEra then
		out("|cff40ff40No focus event. §FR-8.5 holds as written on Era.|r")
	else
		out("|cffff5555No focus event on TBC, where §FR-8.5 expects focus to EXIST.|r")
		out("That inverts the spec on the other client. Suspect this probe or the")
		out("install before rewriting anything.")
	end

	local runs = DyrueUnitFramesProbeDB.secretsRuns or {}
	runs[#runs + 1] = record
	while #runs > 10 do table.remove(runs, 1) end
	DyrueUnitFramesProbeDB.secretsRuns = runs
	DyrueUnitFramesProbeDB.secretsProbe = record

	out(string.format("|cff40ff40Saved as run %d%s.|r |cffffcc00/reload|r to flush.",
		#runs, label and (" labelled '" .. label .. "'") or ""))
end

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------
-- Plan 25 -- right-clicking a buff does nothing
--
-- The cancel overlay used to be a child of the aura icon, which made the icon
-- protected and froze the whole buff display in combat. It is now a sibling on
-- frame.cancelLayer, above the icon by frame LEVEL rather than by parentage.
-- The test harness stores frame levels and does not order anything by them, so
-- it cannot answer whether the click still lands. This asks the client.
--
-- The one measurement that matters is what the mouse is actually over when it
-- is over a buff icon, and the two answers mean opposite things:
--
--   * the OVERLAY -- the click is arriving and the secure action is what is not
--     working. Look at the attributes below and at whether this client supports
--     "cancelaura" at all. Nothing to do with Plan 25; it would never have
--     worked under the old arrangement either.
--   * the ICON -- the overlay is not on top. A frame level or geometry problem,
--     introduced by Plan 25, and fixable without touching the secure side.
--
-- Everything lands in DyrueUnitFramesProbeDB.cancel. Hover a buff while it
-- runs; the sampler records what changes, so waving the mouse around is the
-- whole of the user's job.
--------------------------------------------------------------------------------

-- Round two. The overlay takes the mouse -- measured 18 August 2026, levels 8
-- over 7, rects identical, and no ADDON_ACTION_BLOCKED from this addon at all.
-- So the click arrives, the attributes are what we set, and nothing happens.
--
-- What is NOT known is whether the secure handler dispatches `cancelaura` at
-- all on this client, and if it does, which API it reaches for. OPie -- which
-- works here -- drives cancelaura with a `spell` attribute rather than the
-- `index` + `filter` pair this addon sets, so the index form may simply not be
-- supported. That is a lead, not a finding, and these three hooks settle it:
--
--   * SecureActionButton_OnClick fires    -> dispatch is happening
--   * CancelUnitBuff called               -> the index form works; the failure
--                                            is the index or the aura itself
--   * CancelSpellByName called            -> the handler wants the spell form
--   * dispatch but neither called         -> cancelaura+index is unsupported
--                                            here, and `spell` is the fix
--
-- hooksecurefunc, so nothing here can taint the secure path it is watching.
local cancelHooked = false
local cancelClicks = nil

local function recordCancelCall(what, a, b, c)
	if not cancelClicks then return end
	cancelClicks[#cancelClicks + 1] = {
		at = date("%H:%M:%S"),
		call = what,
		arg1 = tostring(a), arg2 = tostring(b), arg3 = tostring(c),
	}
end

local function hookCancelPath()
	if cancelHooked then return end
	cancelHooked = true

	if _G.CancelUnitBuff then
		hooksecurefunc("CancelUnitBuff", function(unit, index, filter)
			recordCancelCall("CancelUnitBuff", unit, index, filter)
		end)
	end
	if _G.CancelSpellByName then
		hooksecurefunc("CancelSpellByName", function(spell)
			recordCancelCall("CancelSpellByName", spell)
		end)
	end
	if _G.SecureActionButton_OnClick then
		hooksecurefunc("SecureActionButton_OnClick", function(self, button)
			if not cancelClicks then return end
			-- Only ours. Round two recorded all 1268 action-bar dispatches as
			-- well, which drowned the signal and put a megabyte of noise in
			-- SavedVariables. A button with no cancelaura on it is not part of
			-- this question.
			local ok, type2 = pcall(self.GetAttribute, self, "type2")
			if not ok or type2 ~= "cancelaura" then return end
			local resolved = {}
			pcall(function()
				for _, key in ipairs({ "type", "type2", "unit", "index", "filter", "spell" }) do
					resolved[key] = tostring(self:GetAttribute(key))
				end
			end)
			cancelClicks[#cancelClicks + 1] = {
				at = date("%H:%M:%S"),
				call = "SecureActionButton_OnClick",
				arg1 = tostring(button),
				attributes = resolved,
			}
		end)
	end
end

local cancelTicker = nil

local function widgetFacts(f)
	if not f then return nil end
	local facts = {}
	pcall(function()
		facts.objectType = f:GetObjectType()
		facts.name = f:GetName()
		facts.level = f:GetFrameLevel()
		facts.strata = f:GetFrameStrata()
		facts.shown = f:IsShown() and true or false
		facts.visible = f:IsVisible() and true or false
		facts.left, facts.bottom = f:GetLeft(), f:GetBottom()
		facts.width, facts.height = f:GetWidth(), f:GetHeight()
	end)
	pcall(function() facts.mouseEnabled = f:IsMouseEnabled() and true or false end)
	pcall(function()
		local isProtected, explicitly = f:IsProtected()
		facts.protected = isProtected and true or false
		facts.protectedExplicitly = explicitly and true or false
	end)
	return facts
end

-- GetMouseFocus was replaced by GetMouseFoci, which returns a list. Try the
-- new name first and fall back, because this probe runs on two clients.
local function mouseFocus()
	if _G.GetMouseFoci then
		local ok, foci = pcall(_G.GetMouseFoci)
		if ok and type(foci) == "table" then return foci[1] end
	end
	if _G.GetMouseFocus then
		local ok, focus = pcall(_G.GetMouseFocus)
		if ok then return focus end
	end
	return nil
end

local function cancelProbe(seconds)
	seconds = tonumber(seconds) or 30

	header("Cancel overlay (Plan 25)")

	local frame = _G["DyrueUF_player"]
	if not frame then
		out("|cffff5555No DyrueUF_player.|r The addon is not loaded under that name.")
		return
	end

	local group = frame.elements and frame.elements.auras and frame.elements.auras.buffs
	if not group then
		out("|cffff5555The player frame has no buff group.|r")
		out("Enable player buffs, then run this again.")
		return
	end

	local record = {
		timestamp = date("%Y-%m-%d %H:%M:%S"),
		tocVersion = select(4, GetBuildInfo()),
		completed = false,
		inCombat = InCombatLockdown() and true or false,
		api = {
			hasCancelUnitBuff = _G.CancelUnitBuff ~= nil,
			hasGetMouseFoci = _G.GetMouseFoci ~= nil,
			hasGetMouseFocus = _G.GetMouseFocus ~= nil,
			hasSecureActionButtonTemplate = true,
			-- The identity to compare a button's OnClick against. If ours is
			-- not this, the template is not what we think it is.
			secureOnClick = tostring(_G.SecureActionButton_OnClick),
			-- A button known to work, for the same comparison. Bartender4 and
			-- Blizzard's bars both use SecureActionButtonTemplate, and 1316 of
			-- their clicks were traced last round.
			referenceOnClick = (function()
				for _, name in ipairs({ "BT4Button1", "ActionButton1", "MultiBarBottomLeftButton1" }) do
					local b = _G[name]
					if b and b.GetScript then
						local ok, script = pcall(b.GetScript, b, "OnClick")
						if ok and script then return name .. " = " .. tostring(script) end
					end
				end
				return "no reference button found"
			end)(),
		},
		chain = {
			frame = widgetFacts(frame),
			content = widgetFacts(frame.content),
			cancelLayer = widgetFacts(frame.cancelLayer),
			groupFrame = widgetFacts(group.frame),
		},
		buttons = {},
		focus = {},
		clicks = {},
	}

	hookCancelPath()
	cancelClicks = record.clicks

	-- Frame -> label, so the sampler can say "overlay 2" instead of a pointer.
	local label = {}
	if frame.cancelLayer then label[frame.cancelLayer] = "cancelLayer" end
	if frame.content then label[frame.content] = "content" end
	if group.frame then label[group.frame] = "groupFrame" end
	label[frame] = "unitFrame"

	for i = 1, math.min(#group.buttons, 8) do
		local button = group.buttons[i]
		local overlay = button and button.cancel
		local entry = {
			index = i,
			icon = widgetFacts(button),
			overlay = widgetFacts(overlay),
			hasOverlay = overlay ~= nil,
			cancelFailed = button and button.cancelFailed and true or false,
		}

		if button then label[button] = "icon " .. i end
		if overlay then
			label[overlay] = "overlay " .. i

			-- Round three. Round two proved the overlay never dispatched:
			-- sixteen windows with the mouse sitting on one, 1268 secure
			-- clicks traced, and not one of them ours. So the question is no
			-- longer which API cancelaura reaches for -- it is whether the
			-- click reaches the button at all.
			--
			-- PreClick and PostClick are the sanctioned way to watch a secure
			-- button: the client runs them around the secure action and they
			-- do not taint it, which HookScript on OnClick would.
			--
			--   PreClick fires   -> the click arrives; the secure action ran
			--                       and did nothing
			--   PreClick silent  -> the click never reaches the button, and
			--                       RegisterForClicks or the frame itself is
			--                       the problem, not the attributes
			pcall(function()
				entry.hasOnClick = overlay:GetScript("OnClick") ~= nil
				if not overlay.__probeClickHooked then
					overlay.__probeClickHooked = true
					local which = i
					-- Round four. PreClick and PostClick both fire and the
					-- secure handler never runs, so the click reaches the
					-- widget and the secure dispatch is what is missing.
					-- Two candidates, and these two readings separate them:
					--
					--   * the attributes are gone or different AT CLICK TIME
					--     -- something is clearing them between the update
					--     that sets them and the click that reads them;
					--   * the OnClick script is not the one action bars use
					--     -- the template did not give us what we assumed,
					--     and the identity comparison says so outright.
					overlay:HookScript("PreClick", function(self, clicked)
						local seen = {}
						pcall(function()
							for _, key in ipairs({ "type", "type2", "unit", "index", "filter", "spell" }) do
								seen[key] = tostring(self:GetAttribute(key))
							end
							seen.onClick = tostring(self:GetScript("OnClick"))
						end)
						local entry = {
							at = date("%H:%M:%S"),
							call = "PreClick overlay " .. which,
							arg1 = tostring(clicked),
							attributes = seen,
						}
						if cancelClicks then cancelClicks[#cancelClicks + 1] = entry end
					end)
					overlay:HookScript("PostClick", function(_, clicked)
						recordCancelCall("PostClick overlay " .. which, clicked)
					end)
				end
			end)
			entry.overlayParentIsCancelLayer = (overlay:GetParent() == frame.cancelLayer)
			entry.attributes = {}
			for _, key in ipairs({ "type", "type2", "unit", "index", "filter", "spell" }) do
				pcall(function() entry.attributes[key] = tostring(overlay:GetAttribute(key)) end)
			end
			-- The comparison that decides it, if both are on screen.
			if entry.icon and entry.icon.level and entry.overlay.level then
				entry.overlayIsAbove = entry.overlay.level > entry.icon.level
			end
		end

		record.buttons[#record.buttons + 1] = entry
	end

	registerRun("cancel", record)
	DyrueUnitFramesProbeDB.cancel = record

	out("player buff buttons:", #group.buttons, " overlays:",
		(record.buttons[1] and record.buttons[1].hasOverlay) and "present" or "none")

	for _, entry in ipairs(record.buttons) do
		if entry.hasOverlay then
			out(string.format("  %d  icon level %s  overlay level %s  above %s  parent ok %s  shown %s  mouse %s",
				entry.index,
				tostring(entry.icon and entry.icon.level),
				tostring(entry.overlay and entry.overlay.level),
				yn(entry.overlayIsAbove),
				yn(entry.overlayParentIsCancelLayer),
				yn(entry.overlay and entry.overlay.shown),
				yn(entry.overlay and entry.overlay.mouseEnabled)))
		else
			out(string.format("  %d  icon level %s  |cffff5555no overlay|r  cancelFailed %s",
				entry.index,
				tostring(entry.icon and entry.icon.level),
				yn(entry.cancelFailed)))
		end
	end

	out("|cffffcc00Now RIGHT-CLICK a few of your buffs on the player frame.|r")
	out("Hovering alone is not enough any more -- the click is what is being")
	out("traced. Sampling for", seconds, "seconds.")

	if cancelTicker then cancelTicker:Cancel() end
	local last = nil
	local elapsed = 0
	cancelTicker = C_Timer.NewTicker(0.2, function()
		elapsed = elapsed + 0.2
		local focus = mouseFocus()
		local name = "nothing"
		if focus then
			name = label[focus]
			if not name then
				local ok, widgetName = pcall(function()
					return focus:GetName() or ("unnamed " .. focus:GetObjectType())
				end)
				name = ok and widgetName or "unreadable"
			end
		end

		if name ~= last then
			last = name
			-- Capped. The mouse crosses a lot of frames in thirty seconds and
			-- none of this is worth a megabyte of SavedVariables.
			if #record.focus < 150 then
				record.focus[#record.focus + 1] = {
					at = string.format("%.1f", elapsed),
					over = name,
				}
			end
			if name ~= "nothing" then out("  mouse over:", name) end
		end

		if elapsed >= seconds then
			cancelTicker:Cancel()
			cancelTicker = nil
			record.completed = true
			header("Cancel overlay done")

			local sawOverlay, sawIcon = false, false
			for _, sample in ipairs(record.focus) do
				if sample.over:find("overlay", 1, true) then sawOverlay = true end
				if sample.over:find("icon", 1, true) then sawIcon = true end
			end

			-- Only OUR button counts. Round two counted every secure click on
			-- screen and called 1268 action-bar dispatches a success, which
			-- was worse than no verdict at all.
			local reached, dispatched, cancelCalled = false, false, nil
			for _, click in ipairs(record.clicks) do
				if click.call:find("PreClick", 1, true) then reached = true end
				if click.call == "SecureActionButton_OnClick"
					and click.attributes and click.attributes.type2 == "cancelaura" then
					dispatched = true
				end
				if click.call == "CancelUnitBuff" or click.call == "CancelSpellByName" then
					cancelCalled = click.call
				end
			end
			record.verdict = {
				sawOverlay = sawOverlay,
				reached = reached,
				dispatched = dispatched,
				cancelCalled = cancelCalled,
			}

			out("clicks traced:", #record.clicks,
				" reached the overlay:", yn(reached),
				" dispatched ours:", yn(dispatched),
				" cancel API:", cancelCalled or "|cffff5555never called|r")

			if reached and not dispatched then
				out("|cffff5555The click reaches the button and the secure handler never")
				out("runs.|r Compare the PreClick attributes against the static dump, and")
				out("the overlay's OnClick against api.secureOnClick and")
				out("api.referenceOnClick -- one of those two will not match.")
			elseif not reached and sawOverlay then
				out("|cffff5555The click never reached the overlay.|r It has the mouse and")
				out("it is shown, sized and on top, so RegisterForClicks or the frame")
				out("itself is refusing the click -- not the attributes, and nothing to")
				out("do with whether cancelaura is supported.")
			elseif cancelCalled then
				out("|cff40ff40" .. cancelCalled .. " was called.|r The secure path works end")
				out("to end, so the failure is its arguments or the aura itself.")
			elseif dispatched then
				out("|cffff5555Dispatch happened and no cancel API was called.|r This client")
				out("does not act on cancelaura with index+filter. OPie drives it with a")
				out("`spell` attribute; that is the change to make.")
			elseif sawOverlay then
				out("|cffff5555The overlay took the mouse but no click dispatched.|r Either no")
				out("right-click landed during the window, or RegisterForClicks is not")
				out("catching it. Re-run and right-click the icons.")
			elseif sawIcon then
				out("|cffff5555The ICON took the mouse, never the overlay.|r The overlay is")
				out("not on top. Frame level or geometry, not the secure action.")
			else
				out("|cffffcc00Neither was hovered.|r Nothing was measured -- re-run and")
				out("hover a buff icon on the PLAYER frame while it samples.")
			end
			out("Saved to DyrueUnitFramesProbeDB.cancel")
		end
	end)
end

--------------------------------------------------------------------------------

SLASH_DUFPROBE1 = "/dufprobe"
SlashCmdList.DUFPROBE = function(input)
	local cmd = (input or ""):lower():match("^%s*(%S*)")

	if cmd == "mana" then
		startManaTrace(60)
	elseif cmd == "derived" then
		startDerivedTrace(60)
	elseif cmd == "health" then
		healthProbe()
	elseif cmd == "portrait" then
		portraitProbe()
	elseif cmd == "auraorder" then
		startAuraOrderTrace(60)
	elseif cmd == "rage" then
		startRageTrace(90)
	elseif cmd == "happiness" then
		startHappinessTrace(120)
	elseif cmd == "heals" then
		startHealTrace(90, (input or ""):match("^%s*%S+%s+(.-)%s*$"))
	elseif cmd == "healcomm" then
		startHealCommTrace(90, (input or ""):match("^%s*%S+%s+(.-)%s*$"))
	elseif cmd == "incoming" then
		startIncomingTrace(90, (input or ""):match("^%s*%S+%s+(.-)%s*$"))
	elseif cmd == "secrets" then
		secretsProbe((input or ""):match("^%s*%S+%s+(.-)%s*$"))
	elseif cmd == "scroll" then
		scrollProbe((input or ""):match("^%s*%S+%s+(.-)%s*$"))
	elseif cmd == "cancel" then
		cancelProbe((input or ""):match("^%s*%S+%s+(%S+)"))
	elseif cmd == "portraitoff" then
		if portraitFrame then portraitFrame:Hide() end
		if portraitFrame and portraitFrame.model then portraitFrame.model:Hide() end
	elseif cmd == "dump" then
		local record = DyrueUnitFramesProbeDB.survey
		if not record then out("No survey yet; run /dufprobe first.") return end
		out("Survey from", record.timestamp, "toc", record.tocVersion)
	elseif cmd ~= "" then
		-- An unrecognised subcommand used to fall through to the full survey,
		-- which made a REAL failure indistinguishable from success: the addon is
		-- updated on disk, the client is still running the copy it loaded at
		-- login, the new subcommand does not exist yet, and what the user sees is
		-- a wall of plausible output from a different probe entirely. That is
		-- exactly how a /dufprobe incoming run came back as an API survey.
		out("|cffff5555Unknown subcommand '" .. cmd .. "'.|r")
		out("If you expected it to exist, the probe was updated on disk but this")
		out("client is still running the copy it loaded at login - |cffffcc00/reload|r first.")
		out("Known: |cffffcc00mana derived health portrait auraorder rage happiness heals healcomm incoming secrets scroll cancel dump|r")
	else
		survey()
		out("Also run: |cffffcc00/dufprobe mana|r, |cffffcc00derived|r, |cffffcc00health|r, |cffffcc00portrait|r, |cffffcc00auraorder|r, |cffffcc00rage|r, |cffffcc00happiness|r, |cffffcc00heals|r, |cffffcc00healcomm|r, |cffffcc00incoming|r, |cffffcc00scroll|r")
	end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
	out("loaded. |cffffcc00/dufprobe|r for the API survey.")
end)
