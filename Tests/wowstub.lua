-- Minimal WoW API stub, enough to load and exercise DyrueUnitFrames headlessly.
--
-- Unknown widget methods resolve to no-ops so the stub does not have to model
-- the entire widget API; anything whose RETURN VALUE the addon depends on is
-- implemented for real.

local stub = {}
_G.__stub = stub

--------------------------------------------------------------------------------
-- Test-controlled world state
--------------------------------------------------------------------------------

stub.time = 1000
stub.inCombat = false
stub.inGroup = false
stub.inRaid = false
stub.tickers = {}
stub.chat = {}
stub.units = {}

local function unit(u)
	return stub.units[u]
end

function stub.setUnit(token, data)
	stub.units[token] = data
end

function stub.reset()
	stub.units = {}
	stub.inCombat = false
	stub.inGroup = false
	stub.inRaid = false
	stub.chat = {}
	stub.failTemplates = {}
	stub.resting = false
end

stub.failTemplates = {}

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local noop = function() end

local widgetMT
local function newWidget(objectType, name, parent)
	local w = {
		__type = objectType,
		__name = name,
		__parent = parent,
		__shown = true,
		__w = 100, __h = 20,
		__left = 0, __bottom = 0,
		__level = parent and (parent.__level or 0) + 1 or 1,
		__scripts = {},
		__attributes = {},
		__points = {},
		__events = {},
		__children = {},
		__regions = {},
		__text = nil,
	}
	setmetatable(w, widgetMT)
	if parent and parent.__children then
		parent.__children[#parent.__children + 1] = w
	end
	return w
end

local methods = {}

function methods:GetObjectType() return self.__type end
function methods:GetName() return self.__name end
function methods:GetParent() return self.__parent end
function methods:SetParent(p) self.__parent = p end
function methods:IsProtected() return false, false end

function methods:Show() self.__shown = true; local s = self.__scripts.OnShow; if s then s(self) end end
function methods:Hide() self.__shown = false; local s = self.__scripts.OnHide; if s then s(self) end end
function methods:IsShown() return self.__shown end
function methods:IsVisible() return self.__shown end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end

function methods:SetWidth(v) self.__w = v end
function methods:SetHeight(v) self.__h = v end
function methods:SetSize(w, h) self.__w, self.__h = w, h end
function methods:GetWidth() return self.__w end
function methods:GetHeight() return self.__h end
function methods:GetLeft() return self.__left end
function methods:GetBottom() return self.__bottom end
function methods:GetEffectiveScale() return self.__scale or 1 end
function methods:SetScale(v) self.__scale = v end
function methods:SetAlpha(v) self.__alpha = v end
function methods:GetAlpha() return self.__alpha or 1 end
function methods:SetFrameStrata(v) self.__strata = v end
function methods:GetFrameStrata() return self.__strata or "MEDIUM" end
function methods:GetFrameLevel() return self.__level end
function methods:SetFrameLevel(v) self.__level = v end

function methods:SetPoint(point, relative, relativePoint, x, y)
	self.__points[#self.__points + 1] = {
		point = point, relative = relative, relativePoint = relativePoint, x = x, y = y,
	}
end
function methods:SetAllPoints(other) self.__allPoints = other or self.__parent end
function methods:ClearAllPoints() self.__points = {} end
function methods:GetPoint(i)
	local p = self.__points[i or 1]
	if not p then return nil end
	return p.point, p.relative, p.relativePoint, p.x, p.y
end
function methods:GetNumPoints() return #self.__points end

function methods:SetScript(name, fn) self.__scripts[name] = fn end
function methods:GetScript(name) return self.__scripts[name] end
function methods:HookScript(name, fn)
	local existing = self.__scripts[name]
	if existing then
		self.__scripts[name] = function(...) existing(...) return fn(...) end
	else
		self.__scripts[name] = fn
	end
end

function methods:RegisterEvent(event)
	if not stub.validEvents[event] then error("unknown event " .. tostring(event)) end
	self.__events[event] = true
end
function methods:RegisterUnitEvent(event, u1, u2)
	if not stub.validEvents[event] then error("unknown event " .. tostring(event)) end
	self.__events[event] = { u1, u2 }
end
function methods:UnregisterEvent(event) self.__events[event] = nil end
function methods:UnregisterAllEvents() self.__events = {} end
function methods:IsEventRegistered(event) return self.__events[event] ~= nil end

function methods:SetAttribute(k, v) self.__attributes[k] = v end
function methods:GetAttribute(k) return self.__attributes[k] end

function methods:CreateTexture(name, layer, template, sublevel)
	return newWidget("Texture", name, self)
end
function methods:CreateFontString(name, layer)
	local fs = newWidget("FontString", name, self)
	return fs
end

-- The client throws "FontString:SetText(): Font not set" when SetText is called
-- on a FontString that has never had SetFont succeed. The harness used to
-- accept it silently, which is exactly why a real bug passed every test.
function methods:SetText(t)
	if self.__type == "FontString" and not self.__font then
		error("FontString:SetText(): Font not set", 2)
	end
	self.__text = t
end
function methods:GetText() return self.__text end
function methods:SetFont(path, size, flags)
	if not path then return false end
	self.__font = { path, size, flags }
	return true
end
function methods:GetFont()
	if not self.__font then return nil end
	return self.__font[1], self.__font[2], self.__font[3]
end

function methods:SetStatusBarColor(r, g, b, a) self.__barColor = { r, g, b, a } end
function methods:GetStatusBarColor()
	local c = self.__barColor or {}
	return c[1], c[2], c[3], c[4]
end
function methods:SetVertexColor(r, g, b, a) self.__vertexColor = { r, g, b, a } end
function methods:GetVertexColor()
	local c = self.__vertexColor or {}
	return c[1], c[2], c[3], c[4]
end
function methods:SetColorTexture(r, g, b, a) self.__color = { r, g, b, a } end
function methods:SetTextColor(r, g, b, a) self.__textColor = { r, g, b, a } end
function methods:GetTextColor()
	local c = self.__textColor or {}
	return c[1], c[2], c[3], c[4]
end
function methods:SetMinMaxValues(a, b) self.__min, self.__max = a, b end
function methods:GetMinMaxValues() return self.__min, self.__max end
function methods:SetValue(v) self.__value = v end
function methods:GetValue() return self.__value end
function methods:SetTexture(t) self.__texture = t return true end
function methods:GetTexture() return self.__texture end
function methods:SetTexCoord(l, r, t, b) self.__texCoord = { l, r, t, b } end
function methods:GetTexCoord()
	local c = self.__texCoord or { 0, 1, 0, 1 }
	return c[1], c[2], c[3], c[4]
end
function methods:SetStatusBarTexture(t) self.__statusBarTexture = t return true end
function methods:GetStatusBarTexture() return self.__statusBarTexture end

function methods:GetFrameCPUUsage() return 0 end

-- Anything not modeled above is a no-op that returns nothing. Memoised so
-- repeated lookups do not allocate.
widgetMT = {
	__index = function(t, key)
		local m = methods[key]
		if m then return m end
		if type(key) == "string" and key:match("^%u") then
			rawset(t, key, noop)
			return noop
		end
		return nil
	end,
}

-- Set stub.failTemplates.SomeTemplate = true to make CreateFrame throw for it,
-- which is how a Blizzard template that has moved or gone behaves. The harness
-- otherwise ignores templates entirely, so this is the only way to reach the
-- addon's guards around them.
function _G.CreateFrame(objectType, name, parent, template)
	if template and stub.failTemplates and stub.failTemplates[template] then
		error("CreateFrame: unknown template '" .. tostring(template) .. "'", 2)
	end
	local f = newWidget(objectType, name, parent)
	f.__template = template
	if name then _G[name] = f end
	stub.frames = stub.frames or {}
	stub.frames[#stub.frames + 1] = f
	return f
end

_G.UIParent = newWidget("Frame", "UIParent", nil)
UIParent.__w, UIParent.__h = 1920, 1080
UIParent.__level = 0

_G.WorldFrame = newWidget("Frame", "WorldFrame", nil)

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

stub.validEvents = {}
for _, e in ipairs({
	"UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER",
	"UNIT_DISPLAYPOWER", "UNIT_AURA", "UNIT_TARGET", "UNIT_PET", "UNIT_HAPPINESS",
	"UNIT_PORTRAIT_UPDATE", "UNIT_MODEL_CHANGED", "UNIT_CLASSIFICATION_CHANGED",
	"UNIT_NAME_UPDATE", "UNIT_LEVEL", "UNIT_CONNECTION", "UNIT_FACTION", "UNIT_FLAGS",
	"PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "PLAYER_FLAGS_CHANGED",
	"PLAYER_ENTERING_WORLD", "PLAYER_LOGIN",
	"UPDATE_SHAPESHIFT_FORM", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED",
	"RAID_TARGET_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
}) do
	stub.validEvents[e] = true
end
-- Deliberately absent, mirroring a modern client: UNIT_HEALTH_FREQUENT.

_G.C_EventUtils = {
	IsEventValid = function(event) return stub.validEvents[event] == true end,
}

--- Fire an event at every frame registered for it, honouring unit filters.
function stub.fire(event, ...)
	local a = ...
	for _, f in ipairs(stub.frames or {}) do
		local reg = f.__events[event]
		if reg then
			local matches = true
			if type(reg) == "table" then
				matches = (reg[1] == a) or (reg[2] == a)
			end
			if matches then
				local handler = f.__scripts.OnEvent
				if handler then handler(f, event, ...) end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Timers
--------------------------------------------------------------------------------

_G.C_Timer = {
	NewTicker = function(interval, callback)
		local t = { interval = interval, callback = callback, canceled = false }
		function t:Cancel() self.canceled = true end
		function t:IsCancelled() return self.canceled end
		stub.tickers[#stub.tickers + 1] = t
		return t
	end,
	After = function(delay, callback)
		stub.pending = stub.pending or {}
		stub.pending[#stub.pending + 1] = callback
	end,
}

function stub.activeTickers()
	local n = 0
	for _, t in ipairs(stub.tickers) do
		if not t.canceled then n = n + 1 end
	end
	return n
end

--------------------------------------------------------------------------------
-- Unit API
--------------------------------------------------------------------------------

function _G.UnitExists(u) return unit(u) ~= nil end
function _G.UnitName(u) local d = unit(u); return d and d.name end
function _G.UnitClass(u)
	local d = unit(u)
	if not d then return nil end
	return d.className or d.class, d.class
end
function _G.UnitRace(u) local d = unit(u); return d and d.race end
function _G.UnitLevel(u) local d = unit(u); return d and d.level or 0 end
function _G.UnitClassification(u) local d = unit(u); return d and d.classification or "normal" end
function _G.UnitIsPlayer(u) local d = unit(u); return d and d.isPlayer or false end
function _G.UnitIsConnected(u) local d = unit(u); return d == nil or d.connected ~= false end
function _G.UnitIsDead(u) local d = unit(u); return d and d.dead or false end
function _G.UnitIsGhost(u) local d = unit(u); return d and d.ghost or false end
function _G.UnitIsAFK(u) local d = unit(u); return d and d.afk or false end
function _G.UnitIsDND(u) local d = unit(u); return d and d.dnd or false end
function _G.UnitIsPVP(u) local d = unit(u); return d and d.pvp or false end
function _G.UnitIsVisible(u) local d = unit(u); return d ~= nil and d.visible ~= false end
function _G.UnitGUID(u) local d = unit(u); return d and d.guid end
function _G.UnitReaction(u) local d = unit(u); return d and d.reaction end
function _G.UnitHealth(u) local d = unit(u); return d and d.health or 0 end
function _G.UnitHealthMax(u) local d = unit(u); return d and d.healthMax or 0 end
function _G.UnitPlayerOrPetInParty(u) local d = unit(u); return d and d.inParty or false end
function _G.UnitPlayerOrPetInRaid(u) local d = unit(u); return d and d.inRaid or false end
function _G.UnitIsGroupLeader(u) local d = unit(u); return d and d.leader or false end
function _G.UnitIsTapDenied(u) local d = unit(u); return d and d.tapDenied or false end
function _G.UnitIsUnit(a, b)
	local da, db = unit(a), unit(b)
	return da ~= nil and da == db
end

function _G.UnitPowerType(u)
	local d = unit(u)
	if not d then return 0, "MANA" end
	return d.powerType or 0, d.powerToken or "MANA"
end
function _G.UnitPower(u, powerType)
	local d = unit(u)
	if not d then return 0 end
	if powerType and powerType ~= (d.powerType or 0) then
		return (d.powers and d.powers[powerType]) or 0
	end
	return d.power or 0
end
function _G.UnitPowerMax(u, powerType)
	local d = unit(u)
	if not d then return 0 end
	if powerType and powerType ~= (d.powerType or 0) then
		return (d.powerMaxes and d.powerMaxes[powerType]) or 0
	end
	return d.powerMax or 0
end

function _G.GetGuildInfo(u) local d = unit(u); return d and d.guild end
function _G.GetRaidTargetIndex(u) local d = unit(u); return d and d.raidTarget end
function _G.GetPetHappiness() return stub.petHappiness end
function _G.GetShapeshiftForm() return stub.form or 0 end

function _G.RegisterUnitWatch(frame)
	frame.__unitWatch = true
	local u = frame:GetAttribute("unit")
	frame:SetShown(UnitExists(u))
end
function _G.UnregisterUnitWatch(frame) frame.__unitWatch = nil end

function _G.InCombatLockdown() return stub.inCombat end
function _G.IsResting() return stub.resting and true or false end
function _G.UnitAffectingCombat(u)
	local d = unit(u)
	if d and d.inCombat ~= nil then return d.inCombat end
	-- Default: the player follows the global combat flag.
	return (u == "player") and stub.inCombat or false
end
function _G.IsInGroup() return stub.inGroup end
function _G.IsInRaid() return stub.inRaid end
function _G.IsShiftKeyDown() return false end
function _G.GetTime() return stub.time end

--------------------------------------------------------------------------------
-- Color tables and misc globals
--------------------------------------------------------------------------------

_G.RAID_CLASS_COLORS = {
	WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
	PRIEST  = { r = 1.00, g = 1.00, b = 1.00 },
	MAGE    = { r = 0.41, g = 0.80, b = 0.94 },
	ROGUE   = { r = 1.00, g = 0.96, b = 0.41 },
	DRUID   = { r = 1.00, g = 0.49, b = 0.04 },
	HUNTER  = { r = 0.67, g = 0.83, b = 0.45 },
	WARLOCK = { r = 0.58, g = 0.51, b = 0.79 },
	PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
	SHAMAN  = { r = 0.00, g = 0.44, b = 0.87 },
}

_G.FACTION_BAR_COLORS = {
	[1] = { r = 0.87, g = 0.37, b = 0.37 },
	[2] = { r = 0.87, g = 0.37, b = 0.37 },
	[3] = { r = 0.87, g = 0.37, b = 0.37 },
	[4] = { r = 0.85, g = 0.77, b = 0.36 },
	[5] = { r = 0.29, g = 0.68, b = 0.30 },
	[6] = { r = 0.29, g = 0.68, b = 0.30 },
	[7] = { r = 0.29, g = 0.68, b = 0.30 },
	[8] = { r = 0.29, g = 0.68, b = 0.30 },
}

_G.PowerBarColor = {
	MANA = { r = 0, g = 0, b = 1 },
	RAGE = { r = 1, g = 0, b = 0 },
	ENERGY = { r = 1, g = 1, b = 0 },
	FOCUS = { r = 1, g = 0.5, b = 0.25 },
	HAPPINESS = { r = 0, g = 1, b = 1 },
}

_G.DebuffTypeColor = {
	none = { r = 0.8, g = 0, b = 0 },
	Magic = { r = 0.2, g = 0.6, b = 1 },
	Curse = { r = 0.6, g = 0, b = 1 },
	Disease = { r = 0.6, g = 0.4, b = 0 },
	Poison = { r = 0, g = 0.6, b = 0 },
}

_G.Enum = { PowerType = { Mana = 0, Rage = 1, Focus = 2, Energy = 3, Happiness = 4 } }

function _G.GetCreatureDifficultyColor(level)
	local player = (unit("player") and unit("player").level) or 60
	local diff = level - player
	if diff >= 5 then return { r = 1, g = 0.1, b = 0.1 } end
	if diff >= 3 then return { r = 1, g = 0.5, b = 0.25 } end
	if diff >= -2 then return { r = 1, g = 1, b = 0 } end
	if diff >= -5 then return { r = 0.25, g = 0.75, b = 0.25 } end
	return { r = 0.5, g = 0.5, b = 0.5 }
end

function _G.SetPortraitTexture(texture, u) return UnitExists(u) end

_G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
_G.CHAT_FLAG_AFK = "<AFK>"
_G.CHAT_FLAG_DND = "<DND>"
_G.PVP = "PvP"

_G.DEFAULT_CHAT_FRAME = {
	AddMessage = function(_, msg) stub.chat[#stub.chat + 1] = msg end,
}

_G.GameTooltip = newWidget("Frame", "GameTooltip", UIParent)

function _G.GetBuildInfo() return "2.5.6", "60000", "Jul 7 2026", "20506" end
function _G.GetLocale() return "enUS" end
function _G.GetCVar(name) return "0" end
_G.WOW_PROJECT_ID = 5
_G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5
_G.WOW_PROJECT_CLASSIC = 2

function _G.date(fmt) return "2026-08-02 12:00:00" end
function _G.time() return 1785000000 end
function _G.debugstack() return "stack" end
function _G.wipe(t) for k in pairs(t) do t[k] = nil end return t end

_G.C_AddOns = {
	GetAddOnMetadata = function(_, field) if field == "Version" then return "1.0.0" end end,
	GetAddOnMemoryUsage = function() return 320 end,
	UpdateAddOnMemoryUsage = noop,
	GetAddOnCPUUsage = function() return 12 end,
	UpdateAddOnCPUUsage = noop,
}

_G.C_UnitAuras = {
	GetAuraDataByIndex = function(u, index, filter)
		local d = unit(u)
		if not d or not d.auras then return nil end
		local list = d.auras[filter]
		return list and list[index] or nil
	end,
	GetAuraDataByAuraInstanceID = function() return nil end,
}

--------------------------------------------------------------------------------
-- LibStub and Ace3 stand-ins
--
-- The real libraries are not loaded: they would drag in the whole AceGUI widget
-- tree, and the point of this harness is to exercise OUR code.
--------------------------------------------------------------------------------

local libs = {}

_G.LibStub = setmetatable({
	NewLibrary = function(_, major, minor) libs[major] = libs[major] or {} return libs[major] end,
	GetLibrary = function(_, major, silent) return libs[major] end,
}, {
	__call = function(_, major, silent)
		if not libs[major] and not silent then
			error("LibStub: missing library " .. tostring(major))
		end
		return libs[major]
	end,
})

libs["AceAddon-3.0"] = {
	NewAddon = function(_, name, ...)
		local addon = {
			name = name,
			RegisterEvent = function(self, event, handler) self.__events = self.__events or {}; self.__events[event] = handler end,
			UnregisterEvent = noop,
			RegisterChatCommand = function(self, cmd, handler) stub.slash = stub.slash or {}; stub.slash[cmd] = handler end,
			Print = function(_, ...) stub.chat[#stub.chat + 1] = table.concat({ ... }, " ") end,
		}
		stub.addon = addon
		return addon
	end,
}

libs["AceDB-3.0"] = {
	New = function(_, name, defaults, defaultProfile)
		local db = { profile = {}, global = {}, char = {} }
		db.RegisterCallback = function() end
		db.ResetProfile = function() end
		stub.db = db
		return db
	end,
}

libs["AceConfig-3.0"] = { RegisterOptionsTable = function(_, name, tbl) stub.optionsTable = tbl end }
libs["AceConfigDialog-3.0"] = { AddToBlizOptions = function() return newWidget("Frame") end, Open = noop, OpenFrames = {} }
libs["AceConfigRegistry-3.0"] = { NotifyChange = noop }
libs["AceDBOptions-3.0"] = { GetOptionsTable = function() return { type = "group", name = "Profiles", args = {} } end }
-- Modeled properly rather than stubbed to a constant, so that "unknown media
-- name falls back instead of blanking the bar" is actually testable.
local media = {
	statusbar = { Blizzard = "Interface\\TargetingFrame\\UI-StatusBar" },
	font = { ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF" },
}

libs["LibSharedMedia-3.0"] = {
	Register = function(_, kind, key, path)
		media[kind] = media[kind] or {}
		media[kind][key] = path
		return true
	end,
	Fetch = function(_, kind, key, silent)
		local path = media[kind] and media[kind][key]
		if path then return path end
		if silent then return nil end
		return media[kind] and next(media[kind]) and select(2, next(media[kind])) or nil
	end,
	HashTable = function(_, kind) return media[kind] or {} end,
	List = function(_, kind)
		local list = {}
		for key in pairs(media[kind] or {}) do list[#list + 1] = key end
		table.sort(list)
		return list
	end,
	IsValid = function(_, kind, key) return media[kind] and media[kind][key] ~= nil end,
}
stub.media = media

return stub
