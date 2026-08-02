-- Core/Core.lua
--
-- Addon object, bootstrap, element registry and the slash-command surface.
--
-- PLAN task 1.1. Nothing here talks to a version-sensitive API; that is
-- Core/Compat.lua's job exclusively.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Errors = ns.Errors
local Defaults = ns.Defaults
local Migrate = ns.Migrate
local CombatQueue = ns.CombatQueue

local AceAddon = LibStub("AceAddon-3.0")
local AceDB = LibStub("AceDB-3.0")
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local LSM = LibStub("LibSharedMedia-3.0")

local addon = AceAddon:NewAddon(ADDON, "AceEvent-3.0", "AceConsole-3.0")
ns.addon = addon
ns.version = Compat.GetAddOnMetadata(ADDON, "Version") or "1.0.0"

_G.DyrueUnitFrames = addon

--------------------------------------------------------------------------------
-- Element registry
--
-- Elements are data-driven and unit-agnostic. That is the whole reason party
-- frames cost nothing extra (PLAN §5): register the units, and every element
-- covers them automatically.
--------------------------------------------------------------------------------

ns.elements = {}          -- name -> definition
ns.elementOrder = {}      -- ordered list of definitions

function ns:RegisterElement(name, def)
	def.name = name
	def.order = def.order or 100
	ns.elements[name] = def

	local inserted = false
	for i = 1, #ns.elementOrder do
		if ns.elementOrder[i].order > def.order then
			table.insert(ns.elementOrder, i, def)
			inserted = true
			break
		end
	end
	if not inserted then
		ns.elementOrder[#ns.elementOrder + 1] = def
	end
	return def
end

--------------------------------------------------------------------------------
-- Draw order
--
-- Frame level beats draw layer: anything a child frame draws appears above
-- EVERY layer of its parent, OVERLAY included. Bars are child frames, so text
-- and highlights cannot simply live on frame.content at OVERLAY -- the bars
-- would cover them completely.
--
-- Hence one scheme, in one place, expressed as offsets from frame.content:
--
--   PORTRAIT  behind the bars, so an inside-placed portrait reads as a backdrop
--   BARS      health, power, shapeshift mana
--   AURAS     icon groups
--   OVERLAY   text, highlight outlines, border edges -- above all of it
--
-- Gaps are deliberate: they leave room to slot something in without renumbering.
--------------------------------------------------------------------------------

ns.LEVELS = {
	PORTRAIT = 0,
	BARS = 2,
	AURAS = 4,
	OVERLAY = 6,
}

--- Frame level for one band of a unit frame.
function ns:Level(frame, band)
	return frame.content:GetFrameLevel() + (ns.LEVELS[band] or 0)
end

--------------------------------------------------------------------------------
-- Frame registry
--------------------------------------------------------------------------------

ns.frames = {}            -- unitKey -> frame

--- Bumped on every configuration change. Compiled caches (tag formats, color
-- rules) compare against it instead of rebuilding on a timer.
ns.configSerial = 1

function ns:BumpSerial()
	ns.configSerial = ns.configSerial + 1
	return ns.configSerial
end

--------------------------------------------------------------------------------
-- Media
--
-- The default bar texture is registered here, under our own name, pointing at
-- base-game media. Flat textures with better names exist ("Clean" from
-- WeakAuras, ElvUI's "Solid"), but defaulting to one of those would make the
-- addon's out-of-the-box appearance depend on a completely unrelated addon
-- being installed and loaded first. ChatFrameBackground is a solid white fill
-- that has shipped with the game since vanilla.
--
-- LibSharedMedia keys by name, so this adds an entry rather than replacing
-- anyone's. Every other registered texture stays available in the dropdown.
--------------------------------------------------------------------------------

ns.FLAT_TEXTURE = "Dyrue Flat"
LSM:Register("statusbar", ns.FLAT_TEXTURE, [[Interface\ChatFrame\ChatFrameBackground]])

function ns:Texture(name)
	return LSM:Fetch("statusbar", name or "Blizzard", true)
		or LSM:Fetch("statusbar", "Blizzard")
		or "Interface\\TargetingFrame\\UI-StatusBar"
end

function ns:Font(name)
	return LSM:Fetch("font", name or "Friz Quadrata TT", true)
		or LSM:Fetch("font", "Friz Quadrata TT")
		or (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
end

--- Apply font settings to a FontString, tolerating a missing media file.
function ns:SetFont(fontString, fontName, size, outline, shadow)
	local path = ns:Font(fontName)
	local flags = (outline and outline ~= "NONE") and outline or nil
	if not fontString:SetFont(path, size or 12, flags) then
		fontString:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, flags)
	end
	if shadow then
		fontString:SetShadowColor(0, 0, 0, 1)
		fontString:SetShadowOffset(1, -1)
	else
		fontString:SetShadowOffset(0, 0)
	end
end

--------------------------------------------------------------------------------
-- Configuration access
--------------------------------------------------------------------------------

function ns:Profile()
	return ns.db and ns.db.profile
end

function ns:Global()
	return ns.db and ns.db.global
end

function ns:UnitConfig(unitKey)
	local profile = ns:Profile()
	return profile and profile.units and profile.units[unitKey]
end

function ns:General()
	local profile = ns:Profile()
	return profile and profile.general
end

--------------------------------------------------------------------------------
-- Apply / rebuild
--------------------------------------------------------------------------------

--- Full visual refresh of one frame: layout, element enable state, data.
function ns:RefreshUnit(unitKey)
	local frame = ns.frames[unitKey]
	if not frame then return end
	CombatQueue:Run("refresh:" .. unitKey, function()
		frame:ApplyConfig()
	end)
end

--- Full visual refresh of everything. Used after a profile change and by the
-- config UI's coarser controls.
function ns:RefreshAll()
	ns:BumpSerial()
	for unitKey, frame in pairs(ns.frames) do
		CombatQueue:Run("refresh:" .. unitKey, function()
			frame:ApplyConfig()
		end)
	end
	if ns.PartyGroup then ns.PartyGroup:Apply() end
	if ns.DerivedPoller then ns.DerivedPoller:Reconfigure() end
	if ns.Anchoring then ns.Anchoring:ApplyAll() end
end

--- Data-only refresh: no layout work, no protected calls.
function ns:UpdateAll()
	for _, frame in pairs(ns.frames) do
		if frame:IsShown() then frame:FullUpdate() end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function addon:OnInitialize()
	-- Empty AceDB defaults on purpose; see the header of Core/Defaults.lua.
	ns.db = AceDB:New("DyrueUnitFramesDB", { profile = {}, global = {} }, true)

	Defaults:EnsureGlobal(ns.db.global)

	local ok, message = Migrate:Run(ns.db.profile, _G.DyrueUnitFramesDB)
	Defaults:EnsureProfile(ns.db.profile)
	if message then Errors:Print(message) end

	Errors.debug = ns.db.global.debug and true or false
	Errors.safeMode = ns.db.global.safeMode and true or false
	Errors.threshold = ns.db.profile.general.errorThreshold or 5

	Compat.SetFocusOverride(ns.db.profile.general.focusOverride)

	ns.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
	ns.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
	ns.db.RegisterCallback(self, "OnProfileReset", "OnProfileReset")

	ns.Options:Build()
	AceConfig:RegisterOptionsTable(ADDON, ns.Options.table, { "dyrueunitframes" })
	ns.optionsFrame = AceConfigDialog:AddToBlizOptions(ADDON, L["Dyrue Unit Frames"])

	self:RegisterChatCommand("duf", "SlashCommand")

	if Errors.safeMode then
		Errors:Print("|cffffcc00" .. L["Safe mode is active: bars only, no text or auras. /duf safemode to turn it off."] .. "|r")
	end
end

function addon:OnEnable()
	ns.Factory:CreateAll()
	ns.PartyGroup:Initialise()
	ns.DerivedPoller:Initialise()
	ns.Anchoring:ApplyAll()

	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnRegenEnabled")

	ns:ApplyBlizzardFrameSetting()

	if not ns.db.global.firstRunDone then
		ns.db.global.firstRunDone = true
		C_Timer.After(4, function() ns:FirstRunMessage() end)
	end
end

function addon:OnEnteringWorld()
	-- Model frames lose their camera across a loading screen (SPEC §FR-7.4).
	for _, frame in pairs(ns.frames) do
		if frame.elements and frame.elements.portrait then
			ns.elements.portrait.OnEnteringWorld(frame, frame.elements.portrait)
		end
	end
	ns:UpdateAll()
end

function addon:OnRegenEnabled()
	ns:UpdateAll()
end

function addon:OnProfileChanged()
	Defaults:EnsureProfile(ns.db.profile)
	Errors.threshold = ns.db.profile.general.errorThreshold or 5
	Compat.SetFocusOverride(ns.db.profile.general.focusOverride)
	ns:RefreshAll()
	ns:ApplyBlizzardFrameSetting()
	LibStub("AceConfigRegistry-3.0"):NotifyChange(ADDON)
end

function addon:OnProfileReset()
	for k in pairs(ns.db.profile) do ns.db.profile[k] = nil end
	self:OnProfileChanged()
end

--------------------------------------------------------------------------------
-- Blizzard frames (SPEC §5.6)
--------------------------------------------------------------------------------

function ns:ApplyBlizzardFrameSetting()
	local general = ns:General()
	if not general then return end

	local names = {}
	if general.blizzardFrames == "hide" then
		for key, list in pairs(Compat.blizzardFrames) do
			if key ~= "party" or general.blizzardParty then
				for _, name in ipairs(list) do names[#names + 1] = name end
			end
		end
	end

	CombatQueue:Run("blizzard-frames", function()
		if general.blizzardFrames == "hide" then
			for _, name in ipairs(names) do
				Compat.HideBlizzardFrame(name)
			end
		else
			for _, list in pairs(Compat.blizzardFrames) do
				for _, name in ipairs(list) do
					Compat.RestoreBlizzardFrame(name)
				end
			end
		end
	end)
end

function ns:FirstRunMessage()
	Errors:Print(string.format(L["v%s loaded. |cffffcc00/duf|r opens the options."], ns.version))
	if ns:General().blizzardFrames == "none" then
		Errors:Print(L["Blizzard's own unit frames are being left alone. Hide them in Edit Mode if this client offers it, or run |cffffcc00/duf blizzard hide|r to have DyrueUnitFrames do it."])
	else
		Errors:Print(L["Blizzard's own unit frames have been hidden. |cffffcc00/duf blizzard none|r puts them back if you would rather manage them in Edit Mode."])
	end
	if Compat.hasSecretValues then
		Errors:Print("|cffff5555" .. L["This client exposes Secret Values, which SPEC §1.3 assumed Classic would not. Text may be degraded. Please report this."] .. "|r")
	end
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function stripToken(input)
	local token, rest = input:match("^%s*(%S+)%s*(.*)$")
	return token and token:lower() or nil, rest or ""
end

function addon:SlashCommand(input)
	local cmd, rest = stripToken(input or "")

	if not cmd or cmd == "" or cmd == "config" or cmd == "options" then
		-- AceConfigDialog refuses to open while the Blizzard options panel is
		-- up; closing it first makes /duf work from anywhere.
		if _G.SettingsPanel and _G.SettingsPanel:IsShown() then
			_G.HideUIPanel(_G.SettingsPanel)
		elseif _G.InterfaceOptionsFrame and _G.InterfaceOptionsFrame:IsShown() then
			_G.HideUIPanel(_G.InterfaceOptionsFrame)
		end
		AceConfigDialog:Open(ADDON)
		return
	end

	if cmd == "move" or cmd == "unlock" or cmd == "lock" then
		ns.DragMode:Toggle(cmd == "unlock" and true or (cmd == "lock" and false or nil))
		return
	end

	if cmd == "test" then
		ns.TestMode:Toggle()
		return
	end

	if cmd == "tags" then
		ns.Tags:PrintReference(rest)
		return
	end

	if cmd == "debug" then
		local global = ns:Global()
		global.debug = not global.debug
		Errors.debug = global.debug
		Errors:Print(global.debug and L["Debug logging on."] or L["Debug logging off."])
		return
	end

	if cmd == "safemode" then
		local global = ns:Global()
		global.safeMode = not global.safeMode
		Errors:Print(global.safeMode
			and L["Safe mode ON. Reload the UI (/reload) to apply: bars only, no text, no auras."]
			or L["Safe mode OFF. Reload the UI (/reload) to restore text and auras."])
		return
	end

	if cmd == "profile" then
		ns:ProfileReport()
		return
	end

	if cmd == "compat" then
		ns:CompatReport()
		return
	end

	if cmd == "blizzard" then
		local mode = stripToken(rest)
		if mode == "hide" or mode == "none" then
			ns:General().blizzardFrames = mode
			ns:ApplyBlizzardFrameSetting()
			Errors:Print(mode == "hide"
				and L["Hiding Blizzard's unit frames. /reload if any of them linger."]
				or L["Leaving Blizzard's unit frames alone. /reload to bring them back fully."])
		else
			Errors:Print(L["Usage: /duf blizzard hide | none"])
		end
		return
	end

	if cmd == "reset" then
		local unitKey = stripToken(rest)
		if unitKey and ns.Registry.units[unitKey] then
			Defaults:ResetUnit(ns:Profile(), unitKey)
			ns:RefreshAll()
			Errors:Print(string.format(L["%s reset to defaults."], unitKey))
		else
			Errors:Print(L["Usage: /duf reset <unit>"])
		end
		return
	end

	if cmd == "errors" then
		local counts, disabled = Errors:GetCounts()
		local any = false
		for context, n in pairs(counts) do
			any = true
			Errors:Print(string.format("%s: %d%s", context, n, disabled[context] and L[" (disabled)"] or ""))
		end
		if not any then Errors:Print(L["No errors recorded this session."]) end
		return
	end

	Errors:Print(L["Commands:"])
	Errors:Print("  |cffffcc00/duf|r - " .. L["open options"])
	Errors:Print("  |cffffcc00/duf move|r - " .. L["unlock frames for dragging"])
	Errors:Print("  |cffffcc00/duf test|r - " .. L["show every frame with dummy data"])
	Errors:Print("  |cffffcc00/duf tags|r - " .. L["list the tag vocabulary"])
	Errors:Print("  |cffffcc00/duf blizzard hide|none|r - " .. L["hide or restore Blizzard's frames"])
	Errors:Print("  |cffffcc00/duf safemode|r - " .. L["bars only; the patch-day escape hatch"])
	Errors:Print("  |cffffcc00/duf profile|r - " .. L["CPU and memory report"])
	Errors:Print("  |cffffcc00/duf compat|r - " .. L["what this client supports"])
	Errors:Print("  |cffffcc00/duf errors|r - " .. L["errors recorded this session"])
	Errors:Print("  |cffffcc00/duf reset <unit>|r - " .. L["reset one unit to defaults"])
	Errors:Print("  |cffffcc00/duf debug|r - " .. L["verbose logging"])
end

--------------------------------------------------------------------------------
-- Reports
--------------------------------------------------------------------------------

function ns:CompatReport()
	Errors:Print(L["Client capabilities:"])
	local info = Compat.Describe()
	local keys = {}
	for k in pairs(info) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		Errors:Print(string.format("  %s = %s", k, tostring(info[k])))
	end
end

--- SPEC §6 — the built-in profiler.
--
-- The three tickers are reported explicitly, because "is it actually idle when
-- it should be idle" is the property this project cares about most and the one
-- that a budget number alone would hide (risk R13).
function ns:ProfileReport()
	Errors:Print(string.format(L["Memory: %.1f KB"], Compat.GetAddOnMemory(ADDON) or 0))

	if not Compat.IsCPUProfiling() then
		Errors:Print(L["CPU profiling is off. Enable it with /console scriptProfile 1 then /reload."])
	else
		Errors:Print(string.format(L["Addon CPU since load: %.1f ms"], Compat.GetAddOnCPU(ADDON) or 0))

		local total = 0
		for unitKey, frame in pairs(ns.frames) do
			local used = Compat.GetFrameCPU(frame)
			if used then
				total = total + used
				if used > 0 then
					Errors:Print(string.format("  %s: %.2f ms", unitKey, used))
				end
			end
		end
		if total > 0 then
			Errors:Print(string.format(L["Frame total: %.2f ms"], total))
		end
	end

	Errors:Print(string.format(L["Derived poller: %s"], ns.DerivedPoller:Describe()))

	local corrections, ticks = ns.elements.mana.TickerStats()
	Errors:Print(string.format(L["Shapeshift mana ticker: %s (%d tick(s), %d correction(s))"],
		ns.elements.mana.IsTicking() and L["running"] or L["stopped"], ticks, corrections))

	Errors:Print(string.format(L["Aura duration ticker: %s"],
		ns.elements.auras.IsTicking() and L["running"] or L["stopped"]))

	Errors:Print(string.format(L["Queued layout changes: %d"], ns.CombatQueue:PendingCount()))
end
