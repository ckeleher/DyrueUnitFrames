-- Config/TestMode.lua
--
-- PLAN task 6.1 — "the single biggest quality-of-life feature in the whole
-- project": configure layout while standing in a city with no target.
--
-- The approach is deliberate. Rather than building a parallel fake-data layer
-- that every element, tag and colour rule would have to consult (a second code
-- path, and therefore a second thing to keep correct), test mode *substitutes
-- a real unit token* into each frame and re-registers its events against it.
-- Everything downstream then works on genuine data with no special-casing at
-- all: tags render, colour rules evaluate, auras scan, portraits load.
--
-- The only fiction is identity — name, class and level — which is a small,
-- explicitly-marked override consulted in exactly three places, so that four
-- party frames do not all read as your own character.

local ADDON, ns = ...
local L = ns.L
local Errors = ns.Errors
local Registry = ns.Registry
local CombatQueue = ns.CombatQueue

local TestMode = {}
ns.TestMode = TestMode

TestMode.active = false

-- Frames forced visible, and by how many callers. Drag mode holds them too,
-- so a refcount keeps the two features from fighting over visibility.
local holds = {}

--------------------------------------------------------------------------------
-- Visibility
--------------------------------------------------------------------------------

local function applyVisibility(frame)
	local unitKey = frame.unitKey
	local held = (holds[frame] or 0) > 0

	CombatQueue:Run("visibility:" .. unitKey, function()
		if held then
			UnregisterUnitWatch(frame)
			frame:Show()
			return
		end

		local cfg = ns:UnitConfig(unitKey)
		if not cfg or cfg.enabled == false then
			UnregisterUnitWatch(frame)
			frame:Hide()
		elseif frame.def.unitWatch then
			RegisterUnitWatch(frame)
		else
			frame:Show()
		end
	end)
end

--- Force a frame visible regardless of whether its unit exists.
-- Refcounted: drag mode and test mode can both hold, in any order.
function TestMode:HoldVisible(frame, hold)
	local count = holds[frame] or 0
	count = hold and (count + 1) or (count - 1)
	if count < 0 then count = 0 end
	holds[frame] = count
	applyVisibility(frame)

	-- Releasing the last hold on a party frame hands control back to the group,
	-- which owns the hide-in-raid and show-when-solo rules.
	if count == 0 and frame.def.group then
		ns.PartyGroup:UpdateVisibility()
	end
end

--------------------------------------------------------------------------------
-- Substitution
--------------------------------------------------------------------------------

local SAMPLE_CLASSES = {
	"WARRIOR", "PRIEST", "MAGE", "ROGUE", "DRUID", "HUNTER", "WARLOCK", "PALADIN", "SHAMAN",
}

--- The best real unit to read data from for this frame.
-- The frame's own unit if it exists (real values, real auras), otherwise
-- something that definitely does.
local function substitute(frame)
	local token = frame.def.token
	if UnitExists(token) then return token end
	if frame.def.group == "partypet" and UnitExists("pet") then return "pet" end
	if frame.def.derived and UnitExists("target") then return "target" end
	return "player"
end

local function fakeIdentity(def, index)
	if def.key == "player" then return nil end
	return {
		name = def.label,
		classFile = SAMPLE_CLASSES[((index - 1) % #SAMPLE_CLASSES) + 1],
		level = 60 - ((index * 3) % 12),
	}
end

--------------------------------------------------------------------------------
-- Toggle
--------------------------------------------------------------------------------

function TestMode:Enable()
	if self.active then return end
	self.active = true

	local index = 0
	for _, def in ipairs(Registry:SortedAvailable()) do
		local frame = ns.frames[def.key]
		if frame then
			index = index + 1
			frame.unit = substitute(frame)
			frame.test = fakeIdentity(def, index)
			self:HoldVisible(frame, true)
			frame:RegisterEvents()
			frame:FullUpdate()
		end
	end

	Errors:Print(L["Test mode ON. Every frame is shown with stand-in data so layout can be configured anywhere. /duf test to finish."])
end

function TestMode:Disable()
	if not self.active then return end
	self.active = false

	for _, def in ipairs(Registry:SortedAvailable()) do
		local frame = ns.frames[def.key]
		if frame then
			frame.unit = def.token
			frame.test = nil
			self:HoldVisible(frame, false)
			frame:RegisterEvents()
			frame:FullUpdate()
		end
	end

	ns.PartyGroup:UpdateVisibility()
	Errors:Print(L["Test mode OFF."])
end

function TestMode:Toggle(force)
	local wanted = force
	if wanted == nil then wanted = not self.active end
	if wanted then self:Enable() else self:Disable() end
end

function TestMode:IsActive()
	return self.active
end
