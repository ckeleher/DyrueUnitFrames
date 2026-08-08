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
	if record.api["issecretvalue"] or record.api["canaccessvalue"] then
		out("|cffff5555SECRET VALUES PRESENT - SPEC §1.3 no longer holds.|r")
	else
		out("|cff40ff40No secret values. SPEC §1.3 holds: text engine is viable.|r")
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
-- Slash command
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
	elseif cmd == "portraitoff" then
		if portraitFrame then portraitFrame:Hide() end
		if portraitFrame and portraitFrame.model then portraitFrame.model:Hide() end
	elseif cmd == "dump" then
		local record = DyrueUnitFramesProbeDB.survey
		if not record then out("No survey yet; run /dufprobe first.") return end
		out("Survey from", record.timestamp, "toc", record.tocVersion)
	else
		survey()
		out("Also run: |cffffcc00/dufprobe mana|r, |cffffcc00derived|r, |cffffcc00health|r, |cffffcc00portrait|r, |cffffcc00auraorder|r, |cffffcc00rage|r")
	end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
	out("loaded. |cffffcc00/dufprobe|r for the API survey.")
end)
