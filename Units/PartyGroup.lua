-- Units/PartyGroup.lua
--
-- SPEC §FR-6.3 — group-level layout for party1-4.
--
-- This sits ON TOP of the same per-frame x/y values the sliders and drag mode
-- write to; it is a convenience, not a second positioning system. Frame 1
-- takes the group anchor and frames 2-4 chain off their predecessor, so
-- changing one anchor moves all four and a hidden member does not leave a gap.
--
-- Visibility is RegisterUnitWatch (SPEC §FR-6.4), so members joining and
-- leaving are handled entirely inside the secure environment. The two user
-- options that RegisterUnitWatch cannot express — hide-in-raid and
-- show-when-solo — are applied by registering or unregistering the watch, and
-- every one of those calls goes through CombatQueue, because
-- GROUP_ROSTER_UPDATE fires mid-combat and is the single most likely source of
-- a protected-action error in the project (risk R12).

local ADDON, ns = ...
local L = ns.L
local Registry = ns.Registry
local CombatQueue = ns.CombatQueue
local Errors = ns.Errors

local PartyGroup = {}
ns.PartyGroup = PartyGroup

local GROWTH = {
	DOWN  = { point = "TOPLEFT",     relativePoint = "BOTTOMLEFT", x = 0,  y = -1 },
	UP    = { point = "BOTTOMLEFT",  relativePoint = "TOPLEFT",    x = 0,  y = 1 },
	RIGHT = { point = "LEFT",        relativePoint = "RIGHT",      x = 1,  y = 0 },
	LEFT  = { point = "RIGHT",       relativePoint = "LEFT",       x = -1, y = 0 },
}

function PartyGroup:GrowthValues()
	return { DOWN = L["Down"], UP = L["Up"], RIGHT = L["Right"], LEFT = L["Left"] }
end

local eventFrame = nil

--------------------------------------------------------------------------------

local function config()
	local profile = ns:Profile()
	return profile and profile.partyGroup
end

--- Does the group layout own this unit's position right now?
function PartyGroup:Owns(unitKey)
	local group = config()
	if not group or not group.enabled then return false end

	local def = Registry:Get(unitKey)
	if not def or def.group ~= "party" then return false end

	local cfg = ns:UnitConfig(unitKey)
	-- SPEC §FR-6.3: individual frames remain detachable for anyone who wants a
	-- non-linear arrangement.
	if cfg and cfg.detached then return false end

	return true
end

--- Anchor for a group-managed party frame.
-- @return relativeFrame, point, relativePoint, x, y
function PartyGroup:ResolveAnchor(unitKey)
	local group = config()
	local def = Registry:Get(unitKey)
	if not group or not def then return nil end

	local index = def.groupIndex or 1

	if index <= 1 then
		local anchor = group.anchor or {}
		local relative = UIParent
		if anchor.to and anchor.to ~= "UIParent" and ns.frames[anchor.to] then
			relative = ns.frames[anchor.to]
		end
		return relative, anchor.point or "TOPLEFT", anchor.relativePoint or "LEFT",
			anchor.x or 0, anchor.y or 0
	end

	local previous = ns.frames["party" .. (index - 1)]
	if not previous then return nil end

	local growth = GROWTH[group.growth or "DOWN"] or GROWTH.DOWN
	local spacing = group.spacing or 8
	return previous, growth.point, growth.relativePoint, growth.x * spacing, growth.y * spacing
end

--------------------------------------------------------------------------------
-- Size override
--------------------------------------------------------------------------------

--- Push the group's width/height into the four per-frame configs.
-- Writing through rather than shadowing means the per-unit sliders keep
-- showing the truth and drag mode keeps writing to one place.
function PartyGroup:ApplySize()
	local group = config()
	if not group or not group.enabled or not group.overrideSize then return end
	for _, def in ipairs(Registry:GroupMembers("party")) do
		local cfg = ns:UnitConfig(def.key)
		if cfg and not cfg.detached then
			cfg.width = group.width
			cfg.height = group.height
		end
	end
end

--------------------------------------------------------------------------------
-- Visibility (SPEC §FR-6.4, §FR-6.5)
--------------------------------------------------------------------------------

function PartyGroup:ShouldSuppress()
	local group = config()
	if not group then return false end

	-- Raid frames are out of scope and 40 stacked party frames helps nobody.
	if group.hideInRaid and IsInRaid and IsInRaid() then return true end

	local inGroup = IsInGroup and IsInGroup() or false
	if not inGroup and not group.showWhenSolo then return true end

	return false
end

function PartyGroup:UpdateVisibility()
	local suppress = self:ShouldSuppress()

	for _, groupName in ipairs({ "party", "partypet" }) do
		for _, def in ipairs(Registry:GroupMembers(groupName)) do
			local frame = ns.frames[def.key]
			local cfg = ns:UnitConfig(def.key)
			if frame and cfg then
				local hide = suppress or cfg.enabled == false
				-- Every branch here is a protected operation and every one of
				-- them is queued. A player joining the group mid-fight must not
				-- produce an error; the frame may simply appear on combat exit.
				CombatQueue:Run("partyvis:" .. def.key, function()
					if hide then
						UnregisterUnitWatch(frame)
						frame:Hide()
					else
						RegisterUnitWatch(frame)
					end
				end)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function PartyGroup:Apply()
	self:ApplySize()
	self:UpdateVisibility()
	for _, groupName in ipairs({ "party", "partypet" }) do
		for _, def in ipairs(Registry:GroupMembers(groupName)) do
			ns.Anchoring:Apply(def.key)
		end
	end
end

function PartyGroup:Initialise()
	if eventFrame then
		self:Apply()
		return
	end

	eventFrame = CreateFrame("Frame")
	ns.Compat.RegisterEvent(eventFrame, "GROUP_ROSTER_UPDATE")
	ns.Compat.RegisterEvent(eventFrame, "PLAYER_ENTERING_WORLD")
	eventFrame:SetScript("OnEvent", function()
		Errors:Guard("partygroup:roster", function()
			PartyGroup:UpdateVisibility()
		end)
	end)

	self:Apply()
end
