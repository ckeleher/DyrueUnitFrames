-- Core/Errors.lua
--
-- SPEC §5.9 — error containment. The July patch produced "infinitely
-- increasing Lua errors" in several addons: one broken update path firing on
-- every event. This module makes that outcome impossible.
--
-- Design note on cost. The spec is explicit that update paths must NOT be
-- blanket-wrapped in pcall, because per-frame-per-event pcall is a real cost.
-- The compromise here is one `xpcall` per *event dispatch* (not per element),
-- with a single local assignment naming the element about to run. That gives
-- full per-element attribution for the price of one protected call per event,
-- which is the same order of cost as the event handler itself.

local ADDON, ns = ...
local L = ns.L

local Errors = {}
ns.Errors = Errors

local xpcall, pcall, select, type = xpcall, pcall, select, type
local format, tostring = string.format, tostring

local DEFAULT_THRESHOLD = 5

Errors.threshold = DEFAULT_THRESHOLD
Errors.debug = false

-- Which element is executing right now. Set immediately before each element
-- update; read by the handler when something blows up.
local currentContext = nil

local counts = {}      -- ["player:health"] = 3
local disabled = {}    -- ["player:health"] = true
local reported = {}    -- one chat line per context, ever

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local PREFIX = "|cff66ccffDyrue|r "

function Errors:Print(...)
	local msg = ""
	for i = 1, select("#", ...) do
		msg = msg .. tostring((select(i, ...))) .. " "
	end
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
	end
end

function Errors:Debug(...)
	if not self.debug then return end
	self:Print("|cff999999[debug]|r", ...)
end

--------------------------------------------------------------------------------
-- Circuit breaker
--------------------------------------------------------------------------------

--- Record an error against a context key and disable it once it misbehaves
-- repeatedly. Degraded, not dead: everything else keeps working.
function Errors:Record(context, err)
	context = context or "unknown"
	local n = (counts[context] or 0) + 1
	counts[context] = n

	if self.debug then
		self:Print(format("|cffff5555error|r in %s (%d): %s", context, n, tostring(err)))
	end

	if n >= self.threshold and not disabled[context] then
		disabled[context] = true
		if not reported[context] then
			reported[context] = true
			self:Print(format(
				L["|cffff5555%s has errored %d times and has been disabled for this session.|r Everything else keeps working. /duf debug shows details; /reload re-enables it."],
				context, n))
		end
	elseif self.debug and n < self.threshold then
		-- Already printed above in debug mode.
	elseif n == 1 and not reported[context] then
		-- First failure outside debug mode: one quiet line so it is not silent.
		reported[context] = true
		self:Print(format(L["%s hit an error. If it repeats it will be disabled automatically; /duf debug for details."], context))
	end

	return n
end

function Errors:IsDisabled(context)
	return disabled[context] == true
end

function Errors:Reset(context)
	if context then
		counts[context], disabled[context], reported[context] = nil, nil, nil
	else
		counts, disabled, reported = {}, {}, {}
	end
end

function Errors:GetCounts()
	return counts, disabled
end

--------------------------------------------------------------------------------
-- Protected execution
--------------------------------------------------------------------------------

local function handler(err)
	Errors:Record(currentContext, err)
	if Errors.debug then
		local traceback = debugstack and debugstack(2, 6, 3) or ""
		Errors:Print("|cff999999" .. traceback .. "|r")
	end
	return err
end

--- Set the element about to execute. One local assignment — this is the cheap
-- half of the attribution scheme.
function Errors:SetContext(context)
	currentContext = context
end

-- Lua 5.1's xpcall takes NO arguments for the called function; passing extras
-- silently calls it with none. WoW's Lua is 5.1, so arguments travel through
-- these upvalues and a nullary trampoline instead. Slots are saved and
-- restored around each call so a Guard nested inside a Dispatch is safe, and
-- the arrangement allocates nothing — which is the reason not to just use a
-- closure here.
local callFn, arg1, arg2, arg3, arg4, arg5

local function trampoline()
	return callFn(arg1, arg2, arg3, arg4, arg5)
end

local function invoke(context, fn, a, b, c, d, e)
	local savedFn, savedA, savedB, savedC, savedD, savedE =
		callFn, arg1, arg2, arg3, arg4, arg5
	local savedContext = currentContext

	callFn, arg1, arg2, arg3, arg4, arg5 = fn, a, b, c, d, e
	currentContext = context

	local ok, result = xpcall(trampoline, handler)

	callFn, arg1, arg2, arg3, arg4, arg5 =
		savedFn, savedA, savedB, savedC, savedD, savedE
	currentContext = savedContext

	return ok, result
end

--- Run `fn` under a single protected call, attributing any error to the
-- context that was current when it failed.
-- Used for event dispatch (once per event, not once per element) and for
-- config application and layout, which are rare and high-risk.
function Errors:Guard(context, fn, a, b, c, d, e)
	if disabled[context] then return false end
	return (invoke(context, fn, a, b, c, d, e))
end

--- Event-dispatch variant. One protected call per event; the dispatch loop
-- inside re-points the context before each element so attribution stays
-- per-element without a per-element pcall.
function Errors:Dispatch(fn, a, b, c, d, e)
	return (invoke(nil, fn, a, b, c, d, e))
end


--------------------------------------------------------------------------------
-- Safe-mode support
--------------------------------------------------------------------------------

-- Safe mode is stored outside the profile so it survives a reload, which is the
-- entire point of it: it is the patch-day escape hatch (SPEC §5.9).
Errors.safeMode = false

--- Elements permitted in safe mode: bars only, no text, no auras, no models.
-- The shapeshift mana bar is a bar and stays, because a druid on patch day
-- still needs to see mana. Portraits are excluded deliberately: model frames
-- are the least reliable widget in the API and safe mode exists precisely for
-- the day when something in that category has broken.
local SAFE_ELEMENTS = {
	health = true,
	power = true,
	mana = true,
	highlight = true,
}

function Errors:IsElementAllowed(elementName)
	if not self.safeMode then return true end
	return SAFE_ELEMENTS[elementName] == true
end
