-- Core/CombatQueue.lua
--
-- SPEC §FR-1.6 / §5.3 — deferral of protected operations.
--
-- SetPoint, SetSize, SetScale, Show, Hide, SetAttribute and RegisterUnitWatch
-- are all forbidden on a secure frame during combat. Every one of them in this
-- addon goes through this queue. There is exactly one code path for it, and a
-- direct call anywhere else is a review-blocking defect.
--
-- Values are written to the database immediately regardless, so the config UI
-- reflects intent even while the visual application waits. What is deferred is
-- only the *application*.

local ADDON, ns = ...
local L = ns.L

local CombatQueue = {}
ns.CombatQueue = CombatQueue

local InCombatLockdown = InCombatLockdown

-- Keyed so that a slider dragged 200 times in combat queues one apply, not
-- 200 (PLAN task 1.4). `order` preserves insertion order for the first time a
-- key is seen, which matters when e.g. a parent frame must be positioned
-- before its children.
local pending = {}
local order = {}
local count = 0

local listeners = {}

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function()
	CombatQueue:Flush()
end)

--------------------------------------------------------------------------------

--- Run `fn` now if it is safe, otherwise when combat ends.
-- @param key string  de-duplication key; the last function queued under a key wins
-- @param fn function
-- @return boolean true if it ran immediately, false if it was deferred
function CombatQueue:Run(key, fn, ...)
	if not InCombatLockdown() then
		fn(...)
		return true
	end

	local n = select("#", ...)
	if n > 0 then
		local args = { ... }
		if pending[key] == nil then
			count = count + 1
			order[count] = key
		end
		pending[key] = function() fn(unpack(args, 1, n)) end
	else
		if pending[key] == nil then
			count = count + 1
			order[count] = key
		end
		pending[key] = fn
	end

	self:Notify()
	return false
end

function CombatQueue:Flush()
	if count == 0 then return end
	if InCombatLockdown() then return end

	-- Snapshot first: a queued function may itself queue more work, and that
	-- work belongs to the next flush, not this one.
	local runOrder, runPending, n = order, pending, count
	order, pending, count = {}, {}, 0

	for i = 1, n do
		local key = runOrder[i]
		local fn = runPending[key]
		if fn then
			ns.Errors:Guard("combatqueue:" .. key, fn)
		end
	end

	self:Notify()
end

function CombatQueue:IsPending()
	return count > 0
end

function CombatQueue:PendingCount()
	return count
end

--- The config UI registers here so it can show the non-blocking notice
-- required by FR-1.6 ("Layout changes apply when you leave combat.").
function CombatQueue:RegisterListener(name, fn)
	listeners[name] = fn
end

function CombatQueue:Notify()
	for _, fn in pairs(listeners) do
		pcall(fn, count)
	end
end

--- Human-readable status line for the options panel.
function CombatQueue:StatusText()
	if count == 0 then return nil end
	return string.format(
		L["|cffffcc00In combat:|r %d layout change(s) queued. They apply when you leave combat."],
		count)
end

function CombatQueue:Clear()
	order, pending, count = {}, {}, 0
	self:Notify()
end
