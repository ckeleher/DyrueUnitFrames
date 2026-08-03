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
}

local EVENTS = {
	"UNIT_HEALTH", "UNIT_HEALTH_FREQUENT", "UNIT_MAXHEALTH",
	"UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
	"UNIT_AURA", "UNIT_TARGET", "UNIT_PET", "UNIT_HAPPINESS",
	"UNIT_PORTRAIT_UPDATE", "UNIT_MODEL_CHANGED", "UNIT_CLASSIFICATION_CHANGED",
	"UNIT_NAME_UPDATE", "UNIT_LEVEL", "UNIT_CONNECTION", "UNIT_FACTION", "UNIT_FLAGS",
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
	elseif cmd == "portraitoff" then
		if portraitFrame then portraitFrame:Hide() end
		if portraitFrame and portraitFrame.model then portraitFrame.model:Hide() end
	elseif cmd == "dump" then
		local record = DyrueUnitFramesProbeDB.survey
		if not record then out("No survey yet; run /dufprobe first.") return end
		out("Survey from", record.timestamp, "toc", record.tocVersion)
	else
		survey()
		out("Also run: |cffffcc00/dufprobe mana|r, |cffffcc00derived|r, |cffffcc00health|r, |cffffcc00portrait|r")
	end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
	out("loaded. |cffffcc00/dufprobe|r for the API survey.")
end)
