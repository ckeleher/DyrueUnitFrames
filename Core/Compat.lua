-- Core/Compat.lua
--
-- SPEC §5.5 — the project's insurance policy.
--
-- This is the ONLY file permitted to:
--   * call a version-sensitive API,
--   * branch on client flavor,
--   * touch a Blizzard-owned frame.
--
-- Everything else in the addon goes through the accessors below. When Blizzard
-- ships the next shared-code update, this file is the blast radius.
--
-- Rule: feature-probe, never version-check. `Compat.hasFocus` is set by
-- testing for focus, not by comparing TOC numbers, because Blizzard backports
-- things and hardcoded comparisons do not survive that.

local ADDON, ns = ...
local L = ns.L

local Compat = {}
ns.Compat = Compat

local _G = _G
local pcall, type, select, tonumber = pcall, type, select, tonumber

--------------------------------------------------------------------------------
-- Build identification (informational; never used to gate a feature)
--------------------------------------------------------------------------------

local version, build, buildDate, tocVersion = GetBuildInfo()

Compat.gameVersion = version
Compat.gameBuild = build
Compat.buildDate = buildDate
Compat.tocVersion = tonumber(tocVersion) or 0

if _G.WOW_PROJECT_ID and _G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC
	and _G.WOW_PROJECT_ID == _G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC then
	Compat.flavor = "tbc"
elseif Compat.tocVersion >= 20000 and Compat.tocVersion < 30000 then
	Compat.flavor = "tbc"
else
	Compat.flavor = "vanilla"
end

--------------------------------------------------------------------------------
-- Event validity
--
-- Modern clients throw on RegisterEvent for an unknown event. Since 1.15.9 and
-- 2.5.6 run on the shared Midnight-era code, assume they do too, and never
-- register an event without knowing it exists.
--------------------------------------------------------------------------------

local probeFrame = CreateFrame("Frame")
local eventValidCache = {}

--- Is `event` a real event on this client?
-- @param event string
-- @return boolean
function Compat.HasEvent(event)
	local cached = eventValidCache[event]
	if cached ~= nil then return cached end

	local valid
	if _G.C_EventUtils and _G.C_EventUtils.IsEventValid then
		local ok, result = pcall(_G.C_EventUtils.IsEventValid, event)
		if ok then valid = result and true or false end
	end
	if valid == nil then
		-- Fall back to attempting the registration itself.
		local ok = pcall(probeFrame.RegisterEvent, probeFrame, event)
		if ok then pcall(probeFrame.UnregisterEvent, probeFrame, event) end
		valid = ok and true or false
	end

	eventValidCache[event] = valid
	return valid
end

--- Register a unit-filtered event, skipping events this client does not have.
-- Per-unit registration (SPEC §5.7) so the client does the filtering.
-- @return boolean whether the registration happened
function Compat.RegisterUnitEvent(frame, event, unit1, unit2)
	if not Compat.HasEvent(event) then return false end
	local ok = pcall(frame.RegisterUnitEvent, frame, event, unit1, unit2)
	if not ok then
		-- Some events refuse unit filtering; fall back to a plain registration.
		ok = pcall(frame.RegisterEvent, frame, event)
	end
	return ok and true or false
end

--- Register a non-unit event, skipping events this client does not have.
function Compat.RegisterEvent(frame, event)
	if not Compat.HasEvent(event) then return false end
	local ok = pcall(frame.RegisterEvent, frame, event)
	return ok and true or false
end

--------------------------------------------------------------------------------
-- Capability probes
--------------------------------------------------------------------------------

-- Focus exists on TBC and not on Classic Era. Three independent signals; any
-- one of them being conclusively positive is enough. SPEC §FR-8.5.
local function probeFocus()
	if _G.C_EventUtils and _G.C_EventUtils.IsEventValid then
		local ok, result = pcall(_G.C_EventUtils.IsEventValid, "PLAYER_FOCUS_CHANGED")
		if ok then return result and true or false end
	end
	if _G.FocusFrame ~= nil then return true end
	if _G.FocusUnit ~= nil then return true end
	return Compat.HasEvent("PLAYER_FOCUS_CHANGED")
end

Compat.hasFocusProbed = probeFocus()
Compat.hasFocus = Compat.hasFocusProbed

--- Apply the user's focus override, if any. Called by Core once the DB exists.
-- The probe is the default; the override exists purely so a wrong probe on a
-- future patch is a setting change rather than a broken install.
-- @param mode "auto" | "on" | "off"
function Compat.SetFocusOverride(mode)
	if mode == "on" then
		Compat.hasFocus = true
	elseif mode == "off" then
		Compat.hasFocus = false
	else
		Compat.hasFocus = Compat.hasFocusProbed
	end
	return Compat.hasFocus
end

Compat.hasPetHappiness = (_G.GetPetHappiness ~= nil)
Compat.hasClickCastFrames = (type(_G.ClickCastFrames) == "table")

-- SPEC §1.3 — Secret Values must NOT exist here. If either of these ever shows
-- up, the text engine is in trouble and we want to know immediately rather
-- than discover it through a wall of errors.
Compat.hasSecretValues = (_G.issecretvalue ~= nil) or (_G.canaccessvalue ~= nil)

--------------------------------------------------------------------------------
-- Power types
--------------------------------------------------------------------------------

Compat.MANA = (_G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.Mana) or 0
Compat.ENERGY = (_G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.Energy) or 3

--- Plan 17. Rage decays out of combat instead of regenerating, so it is the one
-- power type the tick machinery in Systems/BarSweep.lua has to recognize by
-- number rather than treat generically.
--
-- The literal fallback is safe here in a way the combo-point one below is NOT:
-- 1 is rage in the Classic numbering the table below carries AND in the modern
-- Enum.PowerType, so the two cannot disagree.
Compat.RAGE = (_G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.Rage) or 1

local powerTypeNames = {
	[0] = "MANA",
	[1] = "RAGE",
	[2] = "FOCUS",
	[3] = "ENERGY",
	[4] = "HAPPINESS",
	[6] = "RUNIC_POWER",
}

--- Displayed power type for a unit.
-- @return number powerType, string token
function Compat.GetPowerType(unit)
	local powerType, token = UnitPowerType(unit)
	if not token or token == "" then
		token = powerTypeNames[powerType] or "MANA"
	end
	return powerType, token
end

--------------------------------------------------------------------------------
-- Combo points (Plan 9)
--
-- A player-owned resource that is spent on a target, so it is read as "the
-- player's points ON this unit" rather than as a property of the unit.
--
-- THE TRAP: do not reach for UnitPower("player", 4). In the numbering the table
-- above carries, 4 is HAPPINESS; 4 only means combo points under the modern
-- Enum.PowerType. The Enum branch below is therefore gated on the Enum entry
-- actually existing and never on a literal.
--
-- GetComboPoints is what Blizzard's own ComboFrame uses on these clients, so it
-- is the primary path. The Enum branch is insurance against the shared-code UI
-- eventually retiring it.
--------------------------------------------------------------------------------

Compat.MAX_COMBO_POINTS = tonumber(_G.MAX_COMBO_POINTS) or 5

Compat.hasGetComboPoints = (_G.GetComboPoints ~= nil)
Compat.hasComboPointEnum =
	(_G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.ComboPoints ~= nil) and true or false

--- Combo points the player currently has on `unit`.
-- @return number 0 when this client has no way to answer
function Compat.GetComboPoints(unit)
	local fn = _G.GetComboPoints
	if fn then
		local ok, points = pcall(fn, "player", unit or "target")
		if ok then return points or 0 end
	end
	local enumType = _G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.ComboPoints
	if enumType then
		return UnitPower("player", enumType) or 0
	end
	return 0
end

--------------------------------------------------------------------------------
-- Pet happiness (Plan 24)
--
-- Classic and TBC only -- Cataclysm removed the mechanic outright, which is
-- exactly the shape of change `hasPetHappiness` exists to absorb. Sits here
-- rather than beside the combo-point block on purpose: the trap named above is
-- that power type 4 is HAPPINESS in the Classic numbering, and this is the real
-- happiness reader that number keeps getting mistaken for.
--
-- TWO conditions, not one, and the second is the one that is easy to miss:
--
--   * `GetPetHappiness` takes no unit argument. It answers about the PLAYER's
--     pet, so there is no version of this for anyone else's -- `partypet1-4`
--     cannot have a happiness readout no matter how the caller asks.
--   * A warlock's voidwalker has no happiness, but a caller that only checks
--     "is there a pet" gets a stale number rather than nothing. Blizzard's own
--     PetFrame gates on the second return of HasPetUI for this reason, and so
--     does this.
--------------------------------------------------------------------------------

Compat.hasPetUI = (_G.HasPetUI ~= nil)

-- Named rather than left as literals at the call sites: 1/2/3 carry no meaning
-- on sight, and this file has already been bitten once by a bare power-type
-- number meaning two different things.
Compat.PET_UNHAPPY = 1
Compat.PET_CONTENT = 2
Compat.PET_HAPPY = 3

--- Is the player's current pet a hunter pet?
-- False for a warlock, mage or death knight pet, and false when there is no pet.
function Compat.IsHunterPet()
	local fn = _G.HasPetUI
	if not fn then return false end
	local ok, _, isHunterPet = pcall(fn)
	if not ok then return false end
	return isHunterPet and true or false
end

--- Happiness of the player's pet.
-- @return number|nil PET_UNHAPPY | PET_CONTENT | PET_HAPPY, or nil when this
--         client has no happiness mechanic, there is no pet, or the pet is not
--         a hunter pet. nil is "do not display", never "unhappy".
function Compat.GetPetHappiness()
	if not Compat.hasPetHappiness then return nil end
	if not Compat.IsHunterPet() then return nil end
	local ok, happiness = pcall(_G.GetPetHappiness)
	if not ok then return nil end
	return happiness
end

--------------------------------------------------------------------------------
-- Heal prediction (Plans 11 and 19)
--
-- This block used to say UnitGetIncomingHeals arrived in Cataclysm and
-- UnitGetTotalAbsorbs in Warlords, so neither was expected here. BOTH ARE
-- PRESENT ON BOTH CLIENTS -- verified 11 August 2026, and the incoming-heals one
-- verified working in a live raid: it returns other players' heals with roughly
-- a second of lead time, and UNIT_HEAL_PREDICTION pushes the changes.
--
-- The expansion-era reasoning was the mistake. These clients run the modern
-- shared codebase, so which expansion introduced a function says nothing about
-- whether it is here -- exactly the way UNIT_COMBO_POINTS went missing. That is
-- what FEATURE-PROBE, NEVER VERSION-CHECK is for, and probing this pair is the
-- only reason the error was recoverable at all.
--
-- What the API does NOT cover is HoTs. Measured directly: a Rejuvenation
-- ticking on the player returned zero across 900 samples. So Plan 11's derived
-- machinery keeps the HoT half and the API takes the direct half, and the two
-- are summed rather than chosen between. See COMPAT_FINDINGS, "Plans 11, 12 and
-- 19 -- incoming heals".
--
-- GetIncomingHeals still returns nil rather than 0 where the function is
-- missing, because that distinction is what lets Systems/HealPrediction fall
-- back to deriving the number on a client that lacks it.
--------------------------------------------------------------------------------

Compat.hasIncomingHeals = (_G.UnitGetIncomingHeals ~= nil)
Compat.hasTotalAbsorbs = (_G.UnitGetTotalAbsorbs ~= nil)
Compat.hasHealAbsorbs = (_G.UnitGetTotalHealAbsorbs ~= nil)

--- Incoming heals from the game's own API.
-- @return number|nil  nil when this client has no such API at all, which is
--         different from 0 and is what the caller branches on.
function Compat.GetIncomingHeals(unit, healer)
	local fn = _G.UnitGetIncomingHeals
	if not fn or not unit then return nil end
	local ok, amount = pcall(fn, unit, healer)
	if not ok then return nil end
	return amount or 0
end

--- Absolute time this unit's current cast or channel ends, or nil.
-- The game reports these in milliseconds on GetTime's epoch.
function Compat.GetCastEndTime(unit)
	local casting = _G.UnitCastingInfo
	if casting then
		local ok, name, _, _, _, endTime = pcall(casting, unit)
		if ok and name and endTime then return endTime / 1000, false end
	end
	local channel = _G.UnitChannelInfo
	if channel then
		local ok, name, _, _, _, endTime = pcall(channel, unit)
		if ok and name and endTime then return endTime / 1000, true end
	end
	return nil
end

--- The current combat-log line.
--
-- A thin passthrough on purpose. The FUNCTION is version-sensitive -- it
-- replaced the old argument-list form and could be renamed again -- so its name
-- belongs here under the §5.5 rule. The ARGUMENT LAYOUT is per-subevent and
-- deliberately stays with the reader in Systems/HealPrediction, because
-- unpacking it into a normalised table here would mean an allocation on the
-- noisiest event in the game, thousands of times a minute, for lines that are
-- almost always discarded on the first comparison.
function Compat.GetCombatLogEvent()
	local fn = _G.CombatLogGetCurrentEventInfo
	if not fn then return nil end
	return fn()
end

--------------------------------------------------------------------------------
-- Texture gradients (Plan 16)
--
-- Nothing else in this addon sets a gradient, and the method that does it was
-- renamed: SetGradientAlpha took eight loose numbers, and 10.0 replaced it with
-- SetGradient taking two color OBJECTS. These clients run the shared modern
-- code so the new form is expected -- but "expected" is exactly what this file
-- exists to stop the rest of the addon relying on, so both are probed and no
-- caller outside this block names either method.
--
-- When neither exists the wrapper reports failure rather than erroring, and
-- Elements/HealPrediction draws a solid band instead. A gradient is how the cap
-- indicator LOOKS; marking the clipped edge at all is what it is FOR, and the
-- second of those should not depend on the first.
--------------------------------------------------------------------------------

local probeTexture = probeFrame:CreateTexture(nil, "BACKGROUND")

Compat.hasSetGradient = (type(probeTexture.SetGradient) == "function")
Compat.hasSetGradientAlpha = (type(probeTexture.SetGradientAlpha) == "function")

--- Apply a two-stop gradient in whichever form this client accepts.
-- @param orientation string "HORIZONTAL" | "VERTICAL"
-- @return boolean false when the client has neither method, so the caller can
--         draw something simpler rather than nothing at all.
function Compat.SetGradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
	if not texture then return false end

	if Compat.hasSetGradient then
		-- The 10.0 signature wants ColorMixin objects, and CreateColor is the
		-- documented way to build one. If it is somehow absent, fall through to
		-- the older form rather than calling nil.
		local create = _G.CreateColor
		if create then
			local ok = pcall(texture.SetGradient, texture, orientation,
				create(r1, g1, b1, a1), create(r2, g2, b2, a2))
			if ok then return true end
		end
	end

	if Compat.hasSetGradientAlpha then
		local ok = pcall(texture.SetGradientAlpha, texture, orientation,
			r1, g1, b1, a1, r2, g2, b2, a2)
		if ok then return true end
	end

	return false
end

--------------------------------------------------------------------------------
-- Colors
--------------------------------------------------------------------------------

--- Class color, preferring the community CUSTOM_CLASS_COLORS addon.
-- Always keyed off the locale-independent classFile (SPEC §FR-4.3).
-- @param classFile string e.g. "DRUID"
-- @return r, g, b (nil if unknown)
function Compat.GetClassColor(classFile)
	if not classFile then return nil end
	local source = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS
	local c = source and source[classFile]
	if not c then return nil end
	return c.r, c.g, c.b
end

--- The base game's own creature-difficulty color (SPEC §FR-3.7).
-- Not a reimplementation of the thresholds — it is the game's function, so the
-- colors match the default UI exactly and stay matched.
function Compat.GetDifficultyColor(level)
	local fn = _G.GetCreatureDifficultyColor or _G.GetQuestDifficultyColor
	if fn then
		local ok, c = pcall(fn, level)
		if ok and type(c) == "table" then
			return c.r, c.g, c.b
		end
	end
	return 1, 1, 1
end

--- Power-bar color from the game's own table, by token.
function Compat.GetPowerColor(token)
	local tbl = _G.PowerBarColor
	local c = tbl and token and tbl[token]
	if type(c) == "table" and c.r then
		return c.r, c.g, c.b
	end
	return nil
end

--- Reaction color band from the game's own FACTION_BAR_COLORS.
function Compat.GetReactionColor(reaction)
	local tbl = _G.FACTION_BAR_COLORS
	local c = tbl and reaction and tbl[reaction]
	if type(c) == "table" and c.r then
		return c.r, c.g, c.b
	end
	return nil
end

--- Is this unit tapped by someone else? The API for this differs between
-- Classic and modern builds, so it lives here rather than in Systems/Colors.
function Compat.IsTapDenied(unit)
	if _G.UnitIsTapDenied then
		local ok, result = pcall(_G.UnitIsTapDenied, unit)
		if ok then return result and true or false end
	end
	if _G.UnitIsTapped then
		local ok, tapped = pcall(_G.UnitIsTapped, unit)
		if ok and tapped then
			if _G.UnitIsTappedByPlayer then
				local ok2, mine = pcall(_G.UnitIsTappedByPlayer, unit)
				if ok2 then return not mine end
			end
			return true
		end
	end
	return false
end

--- Debuff-type color from the game's own table (SPEC §FR-5.4).
function Compat.GetDebuffTypeColor(dispelType)
	local tbl = _G.DebuffTypeColor
	local c = tbl and tbl[dispelType or "none"]
	if type(c) == "table" and c.r then
		return c.r, c.g, c.b
	end
	return nil
end

--------------------------------------------------------------------------------
-- Auras
--
-- SPEC §5.1 / R3: one accessor, one stable table shape, regardless of whether
-- the client exposes C_UnitAuras or the legacy UnitAura signature.
--------------------------------------------------------------------------------

local C_UnitAuras = _G.C_UnitAuras
Compat.hasUnitAurasAPI = (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) and true or false
Compat.hasAuraInstanceLookup = (C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID) and true or false

-- Reused scratch table: aura scanning happens on every UNIT_AURA and must not
-- allocate. Callers copy out anything they intend to keep.
local auraScratch = {}

local function wipeScratch()
	for k in pairs(auraScratch) do auraScratch[k] = nil end
	return auraScratch
end

--- Fetch aura `index` on `unit` matching `filter` ("HELPFUL" / "HARMFUL").
-- @return table|nil  A shared scratch table, valid until the next call.
function Compat.GetAura(unit, index, filter)
	if not unit or not UnitExists(unit) then return nil end

	if Compat.hasUnitAurasAPI then
		local data = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
		if not data or not data.name then return nil end
		local a = wipeScratch()
		a.name = data.name
		a.icon = data.icon
		a.count = data.applications or data.charges or 0
		a.dispelType = data.dispelName
		a.duration = data.duration
		a.expirationTime = data.expirationTime
		a.source = data.sourceUnit
		a.isStealable = data.isStealable
		a.spellId = data.spellId
		a.isHelpful = data.isHelpful
		a.isHarmful = data.isHarmful
		a.auraInstanceID = data.auraInstanceID
		a.castByPlayer = data.isFromPlayerOrPlayerPet
		return a
	end

	local UnitAura = _G.UnitAura
	if not UnitAura then return nil end

	local name, icon, count, dispelType, duration, expirationTime, source,
		isStealable, _, spellId, _, _, castByPlayer = UnitAura(unit, index, filter)
	if not name then return nil end

	local a = wipeScratch()
	a.name = name
	a.icon = icon
	a.count = count or 0
	a.dispelType = dispelType
	a.duration = duration
	a.expirationTime = expirationTime
	a.source = source
	a.isStealable = isStealable
	a.spellId = spellId
	a.isHelpful = (filter == "HELPFUL")
	a.isHarmful = (filter == "HARMFUL")
	a.auraInstanceID = nil
	a.castByPlayer = castByPlayer
	return a
end

-- Whether UNIT_AURA has actually delivered an incremental payload yet. Starts
-- false and is flipped by Elements/Auras the first time a real updateInfo with
-- instance IDs arrives — a runtime observation, not a guess at load.
local sawIncremental = false

function Compat.SupportsIncrementalAuraUpdates()
	return sawIncremental and Compat.hasAuraInstanceLookup
end

function Compat.NoteIncrementalAuraUpdate()
	sawIncremental = true
end

--- Look up a single aura by instance ID (incremental path only).
function Compat.GetAuraByInstanceID(unit, instanceID)
	if not Compat.hasAuraInstanceLookup then return nil end
	local data = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, instanceID)
	if not data or not data.name then return nil end
	local a = wipeScratch()
	a.name = data.name
	a.icon = data.icon
	a.count = data.applications or 0
	a.dispelType = data.dispelName
	a.duration = data.duration
	a.expirationTime = data.expirationTime
	a.source = data.sourceUnit
	a.isStealable = data.isStealable
	a.spellId = data.spellId
	a.isHelpful = data.isHelpful
	a.isHarmful = data.isHarmful
	a.auraInstanceID = data.auraInstanceID
	a.castByPlayer = data.isFromPlayerOrPlayerPet
	return a
end

--------------------------------------------------------------------------------
-- State icons
--
-- Blizzard art, so it lives here: a shared-code patch can move or rename it,
-- and this file is where that costs one diff. Both icons come out of the same
-- sheet, selected by tex coords -- the values Blizzard's own PlayerFrame uses.
--------------------------------------------------------------------------------

local STATE_ICON_SHEET = "Interface\\CharacterFrame\\UI-StateIcon"

-- Plan 24. A second sheet, on the same terms: three 24x23 cells across its top
-- row, happy first, at the tex coords Blizzard's own PetFrame_Update uses.
local HAPPINESS_SHEET = "Interface\\PetPaperDollFrame\\UI-PetHappiness"

local stateIcons = {
	resting = { texture = STATE_ICON_SHEET, left = 0, right = 0.5, top = 0, bottom = 0.421875 },
	combat  = { texture = STATE_ICON_SHEET, left = 0.5, right = 1.0, top = 0, bottom = 0.484375 },
	happy   = { texture = HAPPINESS_SHEET, left = 0,      right = 0.1875, top = 0, bottom = 0.359375 },
	content = { texture = HAPPINESS_SHEET, left = 0.1875, right = 0.375,  top = 0, bottom = 0.359375 },
	unhappy = { texture = HAPPINESS_SHEET, left = 0.375,  right = 0.5625, top = 0, bottom = 0.359375 },
}

--- Art for a unit-state icon.
-- @return texture, left, right, top, bottom -- or nil if we have no art for it
function Compat.GetStateIcon(key)
	local icon = stateIcons[key]
	if not icon then return nil end
	return icon.texture, icon.left, icon.right, icon.top, icon.bottom
end

--------------------------------------------------------------------------------
-- Portraits
--------------------------------------------------------------------------------

Compat.QUESTION_MARK_TEXTURE = "Interface\\Icons\\INV_Misc_QuestionMark"

--- Set a 2D portrait texture, returning false if the unit has no portrait.
function Compat.SetPortraitTexture(texture, unit)
	if not texture or not unit or not UnitExists(unit) then return false end
	local fn = _G.SetPortraitTexture
	if not fn then return false end
	local ok = pcall(fn, texture, unit)
	return ok and true or false
end

--------------------------------------------------------------------------------
-- Classic enemy-health scaling (SPEC §FR-4.7)
--
-- For units outside your group, Classic and TBC report health on a 0-100 scale
-- with UnitHealthMax == 100. Absolute numbers are therefore not real, and
-- rendering "100/100" for a full-health raid boss is worse than rendering
-- nothing.
--------------------------------------------------------------------------------

--- Does this unit report real absolute health values?
function Compat.HasRealHealthValues(unit)
	if not unit or not UnitExists(unit) then return false end
	if UnitIsUnit(unit, "player") then return true end
	if UnitPlayerOrPetInParty and UnitPlayerOrPetInParty(unit) then return true end
	if UnitPlayerOrPetInRaid and UnitPlayerOrPetInRaid(unit) then return true end
	if UnitIsUnit(unit, "pet") then return true end
	local maxHealth = UnitHealthMax(unit)
	-- 100 is the tell. A player or party pet legitimately on 100 max health is
	-- level 1 and already covered by the group checks above.
	return maxHealth ~= 100
end

--------------------------------------------------------------------------------
-- Secure frame plumbing
--------------------------------------------------------------------------------

-- Template availability is not queryable from Lua; the factory guards the
-- CreateFrame call itself and records the result here.
Compat.hasSecureUnitButton = nil

--- Called once by Units/Factory after its first (guarded) CreateFrame.
function Compat.NoteSecureUnitButton(available)
	Compat.hasSecureUnitButton = available and true or false
end

--- Register a frame for Clique and friends (SPEC §7).
function Compat.RegisterClickCast(frame)
	if type(_G.ClickCastFrames) == "table" then
		_G.ClickCastFrames[frame] = true
		return true
	end
	return false
end

function Compat.UnregisterClickCast(frame)
	if type(_G.ClickCastFrames) == "table" then
		_G.ClickCastFrames[frame] = nil
	end
end

--------------------------------------------------------------------------------
-- Hiding the default Blizzard frames (SPEC §5.6)
--
-- The single unavoidable point of contact with Blizzard's UI. Everything here
-- is deliberately cautious: no :Hide() on a protected frame in combat, no
-- assumption that any given frame exists on any given client.
--------------------------------------------------------------------------------

local hiddenHolder = CreateFrame("Frame", ADDON .. "HiddenHolder", UIParent)
hiddenHolder:Hide()
Compat.hiddenHolder = hiddenHolder

local originalParents = {}

--- Frame names we may need to hide, per unit key. Names only — resolved
-- lazily, because which of these exist varies by client and by patch.
Compat.blizzardFrames = {
	player = { "PlayerFrame" },
	pet = { "PetFrame" },
	target = { "TargetFrame", "ComboFrame" },
	targettarget = { "TargetFrameToT" },
	focus = { "FocusFrame" },
	focustarget = { "FocusFrameToT" },
	party = {
		"PartyMemberFrame1", "PartyMemberFrame2", "PartyMemberFrame3", "PartyMemberFrame4",
		"PartyFrame", "CompactPartyFrame",
	},
}

--- Hide one Blizzard frame. THE only place Blizzard UI is touched.
-- Returns false if the frame does not exist or the operation was unsafe.
function Compat.HideBlizzardFrame(frameOrName)
	local frame = frameOrName
	if type(frame) == "string" then frame = _G[frame] end
	if type(frame) ~= "table" or not frame.GetObjectType then return false end
	if originalParents[frame] then return true end -- already handled

	-- Protected frames cannot be reparented or hidden in combat.
	if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
		return false
	end

	originalParents[frame] = frame:GetParent() or UIParent

	pcall(frame.UnregisterAllEvents, frame)
	if frame.healthbar then pcall(frame.healthbar.UnregisterAllEvents, frame.healthbar) end
	if frame.manabar then pcall(frame.manabar.UnregisterAllEvents, frame.manabar) end
	if frame.spellbar then pcall(frame.spellbar.UnregisterAllEvents, frame.spellbar) end
	if frame.powerBarAlt then pcall(frame.powerBarAlt.UnregisterAllEvents, frame.powerBarAlt) end

	pcall(frame.Hide, frame)
	pcall(frame.SetParent, frame, hiddenHolder)

	return true
end

--- Put a frame back where it came from. Used when the user turns hiding off,
-- and by /duf safemode's escape hatch.
function Compat.RestoreBlizzardFrame(frameOrName)
	local frame = frameOrName
	if type(frame) == "string" then frame = _G[frame] end
	if type(frame) ~= "table" then return false end
	local parent = originalParents[frame]
	if not parent then return false end
	if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
		return false
	end
	pcall(frame.SetParent, frame, parent)
	originalParents[frame] = nil
	-- Deliberately not re-registering events: a /reload restores Blizzard's own
	-- setup correctly, and guessing at the event list would be worse.
	return true
end

function Compat.IsBlizzardFrameHidden(frameOrName)
	local frame = frameOrName
	if type(frame) == "string" then frame = _G[frame] end
	return frame ~= nil and originalParents[frame] ~= nil
end

--------------------------------------------------------------------------------
-- Addon metadata and profiling
--
-- These moved into C_AddOns on modern builds and the Classic clients now share
-- that code, so both spellings live here rather than being probed at the call
-- site.
--------------------------------------------------------------------------------

local C_AddOns = _G.C_AddOns

function Compat.GetAddOnMetadata(addon, field)
	local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
	if not fn then return nil end
	local ok, value = pcall(fn, addon, field)
	return ok and value or nil
end

function Compat.IsCPUProfiling()
	local fn = _G.GetCVar or (_G.C_CVar and _G.C_CVar.GetCVar)
	if not fn then return false end
	local ok, value = pcall(fn, "scriptProfile")
	return ok and value == "1"
end

--- @return number|nil kilobytes
function Compat.GetAddOnMemory(addon)
	local update = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or _G.UpdateAddOnMemoryUsage
	local get = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or _G.GetAddOnMemoryUsage
	if not update or not get then return nil end
	pcall(update)
	local ok, value = pcall(get, addon)
	return ok and value or nil
end

--- @return number|nil milliseconds since load
function Compat.GetAddOnCPU(addon)
	local update = (C_AddOns and C_AddOns.UpdateAddOnCPUUsage) or _G.UpdateAddOnCPUUsage
	local get = (C_AddOns and C_AddOns.GetAddOnCPUUsage) or _G.GetAddOnCPUUsage
	if not update or not get then return nil end
	pcall(update)
	local ok, value = pcall(get, addon)
	return ok and value or nil
end

--- @return number|nil milliseconds attributable to one frame
function Compat.GetFrameCPU(frame)
	if not frame or not frame.GetFrameCPUUsage then return nil end
	local ok, value = pcall(frame.GetFrameCPUUsage, frame, true)
	return ok and value or nil
end

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

--- Human-readable capability dump, used by /duf compat and by the probe addon.
function Compat.Describe()
	return {
		gameVersion = Compat.gameVersion,
		gameBuild = Compat.gameBuild,
		tocVersion = Compat.tocVersion,
		flavor = Compat.flavor,
		hasFocusProbed = Compat.hasFocusProbed,
		hasFocus = Compat.hasFocus,
		hasPetHappiness = Compat.hasPetHappiness,
		-- Plan 24. Presence of the reader was already known; these two are what
		-- was NOT known. `hasUnitHappiness` is the open question the plan names
		-- -- nothing had ever asserted the push event fires, and this project
		-- has been burned by presence-is-not-function three times. `hasPetUI`
		-- is what keeps a warlock's voidwalker from showing a happiness face,
		-- so an absent one would be a silent behaviour change rather than a
		-- missing feature.
		hasUnitHappiness = Compat.HasEvent("UNIT_HAPPINESS"),
		hasPetUI = Compat.hasPetUI,
		hasClickCastFrames = Compat.hasClickCastFrames,
		hasSecretValues = Compat.hasSecretValues,
		hasUnitAurasAPI = Compat.hasUnitAurasAPI,
		hasAuraInstanceLookup = Compat.hasAuraInstanceLookup,
		incrementalAurasSeen = Compat.SupportsIncrementalAuraUpdates(),
		MANA = Compat.MANA,
		RAGE = Compat.RAGE,
		hasGetComboPoints = Compat.hasGetComboPoints,
		hasComboPointEnum = Compat.hasComboPointEnum,
		maxComboPoints = Compat.MAX_COMBO_POINTS,
		-- False on the Anniversary client. Reported here rather than left to
		-- the probe addon because when this is false the combo bar depends
		-- entirely on the power-event path, and "which path is live" is the
		-- first thing worth knowing if it ever stops updating again.
		hasUnitComboPoints = Compat.HasEvent("UNIT_COMBO_POINTS"),
		hasUnitHealthFrequent = Compat.HasEvent("UNIT_HEALTH_FREQUENT"),
		-- Plan 11. Expected false on both clients; reported so the assumption
		-- the heal prediction module is built on is checkable rather than
		-- merely asserted, and so Plan 12 has its answer before it starts.
		hasIncomingHeals = Compat.hasIncomingHeals,
		hasTotalAbsorbs = Compat.hasTotalAbsorbs,
		hasHealAbsorbs = Compat.hasHealAbsorbs,
		hasUnitHealPrediction = Compat.HasEvent("UNIT_HEAL_PREDICTION"),
		hasCombatLogInfo = (_G.CombatLogGetCurrentEventInfo ~= nil),
		-- Plan 16. Which of the two decides whether the overflow cap indicator
		-- fades or draws as a solid band, and it is the only difference the
		-- user would see, so it is worth being able to ask.
		hasSetGradient = Compat.hasSetGradient,
		hasSetGradientAlpha = Compat.hasSetGradientAlpha,
		hasUnitAura = Compat.HasEvent("UNIT_AURA"),
		hasPlayerFocusChanged = Compat.HasEvent("PLAYER_FOCUS_CHANGED"),
		hasUnitTarget = Compat.HasEvent("UNIT_TARGET"),
		hasEditMode = _G.EditModeManagerFrame ~= nil,
	}
end
