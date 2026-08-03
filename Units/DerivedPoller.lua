-- Units/DerivedPoller.lua
--
-- SPEC §FR-8.3 — one shared ticker for every derived frame.
--
-- Target-of-target and focus-target do not receive reliable unit events, so
-- their *values* have to be sampled. Their *identity* does not: UNIT_TARGET
-- fires with the owning unit as its payload and is handled event-driven in
-- Units/Factory.
--
-- The failure mode this file exists to avoid (risk R13) is a ticker that runs
-- while the player is standing in a city with no target. Hence: one ticker for
-- all frames rather than one each, started by the first frame becoming visible
-- and stopped by the last one hiding, verifiable with /duf profile.
--
-- PLAN task 2.12 says to write the start/stop logic first and the update logic
-- second. That ordering is preserved below.

local ADDON, ns = ...
local L = ns.L
local Errors = ns.Errors

local DerivedPoller = {}
ns.DerivedPoller = DerivedPoller

local MIN_INTERVAL, MAX_INTERVAL = 0.1, 1.0
local DEFAULT_INTERVAL = 0.25

local active = {}          -- frame -> true
local activeCount = 0
local ticker = nil
local interval = DEFAULT_INTERVAL

--------------------------------------------------------------------------------
-- Start / stop
--------------------------------------------------------------------------------

local function tick()
	for frame in pairs(active) do
		-- IsShown is checked rather than trusted: RegisterUnitWatch hides
		-- frames from inside the secure environment and OnHide is our only
		-- notification, so a belt-and-braces check here is cheap insurance.
		if frame:IsShown() then
			frame:FullUpdate()
		end
	end
end

local function stop()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
end

local function start()
	if ticker then return end
	ticker = C_Timer.NewTicker(interval, tick)
end

local function refresh()
	if activeCount > 0 then
		start()
	else
		stop()
	end
end

function DerivedPoller:Add(frame)
	if active[frame] then return end
	active[frame] = true
	activeCount = activeCount + 1
	refresh()
end

function DerivedPoller:Remove(frame)
	if not active[frame] then return end
	active[frame] = nil
	activeCount = activeCount - 1
	if activeCount < 0 then activeCount = 0 end
	refresh()
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

function DerivedPoller:Interval()
	return interval
end

function DerivedPoller:IsRunning()
	return ticker ~= nil
end

function DerivedPoller:ActiveCount()
	return activeCount
end

--- Re-read the configured interval. A running ticker is recreated, because
-- C_Timer tickers cannot have their period changed in place.
function DerivedPoller:Reconfigure()
	local general = ns:General()
	local wanted = general and general.derivedPollInterval or DEFAULT_INTERVAL

	if wanted < MIN_INTERVAL then wanted = MIN_INTERVAL end
	if wanted > MAX_INTERVAL then wanted = MAX_INTERVAL end

	if wanted == interval then
		refresh()
		return
	end

	interval = wanted
	stop()
	refresh()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function DerivedPoller:Initialize()
	self:Reconfigure()

	-- Frames that are already visible at load (a derived frame can be shown
	-- before its OnShow hook is installed in an edge case) are picked up here.
	for key, frame in pairs(ns.frames) do
		if ns.Registry:IsDerived(key) and frame:IsShown() then
			self:Add(frame)
		end
	end
end

--- Diagnostic line for /duf profile.
function DerivedPoller:Describe()
	if not ticker then return L["stopped"] end
	return string.format(L["running: %d frame(s) every %.2fs"], activeCount, interval)
end
