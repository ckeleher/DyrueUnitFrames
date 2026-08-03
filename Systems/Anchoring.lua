-- Systems/Anchoring.lua
--
-- SPEC §FR-1.5 — the anchor graph.
--
-- Each frame stores anchorTo / anchorPoint / relativePoint / x / y. Moving a
-- parent moves its children, preserving relative spacing, because that is just
-- what SetPoint does once the relationship is expressed as a graph.
--
-- Two things this module owns that SetPoint does not do for us:
--   * cycle detection, rejected at config time with a clear message rather
--     than discovered as a client-side error,
--   * a topological apply order, so a parent is sized and placed before the
--     children that hang off it.

local ADDON, ns = ...
local L = ns.L
local CombatQueue = ns.CombatQueue

local Anchoring = {}
ns.Anchoring = Anchoring

local VALID_POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true,
	LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

Anchoring.points = VALID_POINTS

function Anchoring:PointValues()
	return {
		TOPLEFT = L["Top Left"], TOP = L["Top"], TOPRIGHT = L["Top Right"],
		LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"],
		BOTTOMLEFT = L["Bottom Left"], BOTTOM = L["Bottom"], BOTTOMRIGHT = L["Bottom Right"],
	}
end

--------------------------------------------------------------------------------
-- Graph walking
--------------------------------------------------------------------------------

--- The unit key this frame is anchored to, or nil if it hangs off UIParent.
local function anchorParent(unitKey)
	local cfg = ns:UnitConfig(unitKey)
	if not cfg or not cfg.anchor then return nil end
	local to = cfg.anchor.to
	if not to or to == "UIParent" or to == "" then return nil end
	return to
end

--- Would anchoring `unitKey` to `target` create a loop?
-- @return boolean cycles, string|nil description of the loop
function Anchoring:WouldCycle(unitKey, target)
	if not target or target == "UIParent" then return false end
	if target == unitKey then
		return true, string.format(L["%s cannot be anchored to itself."], unitKey)
	end

	local path = { unitKey, target }
	local seen = { [unitKey] = true, [target] = true }
	local cursor = target

	while true do
		local parent = anchorParent(cursor)
		if not parent then return false end
		path[#path + 1] = parent
		if seen[parent] then
			return true, string.format(
				L["That would create an anchor loop: %s. Anchor chains have to end at the screen."],
				table.concat(path, " -> "))
		end
		seen[parent] = true
		cursor = parent
		if #path > 32 then
			-- Defensive: cannot happen with the `seen` set above, but a runaway
			-- loop here would hang the client, which is worse than a wrong answer.
			return true, L["Anchor chain is too deep."]
		end
	end
end

--- Validate and store a new anchor target. Returns false plus a message when
-- the change is rejected (SPEC §FR-1.5).
function Anchoring:SetTarget(unitKey, target)
	local cycles, message = self:WouldCycle(unitKey, target)
	if cycles then
		ns.Errors:Print("|cffff5555" .. (message or L["Rejected: anchor loop."]) .. "|r")
		return false, message
	end
	local cfg = ns:UnitConfig(unitKey)
	if not cfg then return false end
	cfg.anchor.to = target
	return true
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

--- What should this frame actually be anchored to right now?
-- Party frames under group layout defer to Units/PartyGroup, which computes
-- positions from the same stored x/y values (SPEC §FR-6.3).
-- @return relativeFrame, point, relativePoint, x, y
function Anchoring:Resolve(unitKey)
	local cfg = ns:UnitConfig(unitKey)
	if not cfg then return UIParent, "CENTER", "CENTER", 0, 0 end

	if ns.PartyGroup and ns.PartyGroup:Owns(unitKey) then
		local relative, point, relativePoint, x, y = ns.PartyGroup:ResolveAnchor(unitKey)
		if relative then return relative, point, relativePoint, x, y end
	end

	local anchor = cfg.anchor or {}
	local point = VALID_POINTS[anchor.point] and anchor.point or "CENTER"
	local relativePoint = VALID_POINTS[anchor.relativePoint] and anchor.relativePoint or point

	local relative = UIParent
	local target = anchor.to
	if target and target ~= "UIParent" and target ~= "" then
		local targetFrame = ns.frames[target]
		if targetFrame then
			-- A frame anchored to something currently hidden still needs a
			-- valid anchor, and SetPoint against a hidden frame is fine.
			relative = targetFrame
		end
		-- If the target frame does not exist (focus on Classic Era, a disabled
		-- unit) we silently fall back to the screen rather than erroring.
	end

	return relative, point, relativePoint, anchor.x or 0, anchor.y or 0
end

--------------------------------------------------------------------------------
-- Apply order
--------------------------------------------------------------------------------

--- Unit keys in dependency order: parents before children.
function Anchoring:SortedKeys()
	local order, visiting, visited = {}, {}, {}

	local function visit(key)
		if visited[key] or visiting[key] then return end
		visiting[key] = true
		local parent = anchorParent(key)
		if parent and ns.frames[parent] then visit(parent) end
		visiting[key] = nil
		visited[key] = true
		order[#order + 1] = key
	end

	for key in pairs(ns.frames) do visit(key) end
	return order
end

--- Re-apply position and size for every frame, in dependency order, through
-- the combat queue.
function Anchoring:ApplyAll()
	local order = self:SortedKeys()
	for i = 1, #order do
		local key = order[i]
		local frame = ns.frames[key]
		if frame then
			CombatQueue:Run("layout:" .. key, function()
				frame:ApplyLayout()
			end)
		end
	end
end

--- Re-apply one frame and everything hanging off it.
function Anchoring:Apply(unitKey)
	local frame = ns.frames[unitKey]
	if frame then
		CombatQueue:Run("layout:" .. unitKey, function()
			frame:ApplyLayout()
		end)
	end
	for key in pairs(ns.frames) do
		if anchorParent(key) == unitKey then
			self:Apply(key)
		end
	end
end

--- Anchor-target choices for the options UI: the screen plus every other
-- frame that would not create a loop.
function Anchoring:TargetValues(unitKey)
	local values = { UIParent = L["Screen"] }
	for key, definition in pairs(ns.Registry.units) do
		if key ~= unitKey and ns.Registry:IsAvailable(key) then
			if not self:WouldCycle(unitKey, key) then
				values[key] = definition.label
			end
		end
	end
	return values
end
