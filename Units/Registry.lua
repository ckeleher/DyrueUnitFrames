-- Units/Registry.lua
--
-- SPEC §3 — the unit roster, as data.
--
-- Everything downstream (elements, colour rules, auras, portraits, the whole
-- config tree) iterates this table. Adding a unit is a table entry, which is
-- exactly why party frames and derived units cost nothing extra once they are
-- registered here (PLAN §5).
--
-- `requires` names a Compat capability flag, never a TOC version. Gating on
-- `Compat.hasFocus` rather than `tocVersion >= 20000` is the whole point of
-- guiding principle 2.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

local Registry = {}
ns.Registry = Registry

local units = {}
Registry.units = units

local function define(key, def)
	def.key = key
	def.token = def.token or key
	def.label = def.label or key
	units[key] = def
	return def
end

--------------------------------------------------------------------------------
-- Solo units
--------------------------------------------------------------------------------

define("player", {
	order = 10,
	label = L["Player"],
	unitWatch = false,          -- the player always exists
	changeEvents = {},
})

define("target", {
	order = 20,
	label = L["Target"],
	unitWatch = true,
	changeEvents = { "PLAYER_TARGET_CHANGED" },
})

-- SPEC §4.8 — derived units. Identity changes are event-driven; value changes
-- require polling, because *target tokens do not receive reliable unit events.
define("targettarget", {
	order = 30,
	label = L["Target of Target"],
	unitWatch = true,
	derived = true,
	owner = "target",
	changeEvents = { "PLAYER_TARGET_CHANGED", "UNIT_TARGET" },
})

define("pet", {
	order = 40,
	label = L["Pet"],
	unitWatch = true,
	-- UNIT_PET fires with the pet's OWNER as its payload, so it is registered
	-- against "player" rather than against "pet".
	owner = "player",
	changeEvents = { "UNIT_PET" },
})

define("focus", {
	order = 50,
	label = L["Focus"],
	unitWatch = true,
	requires = "hasFocus",
	changeEvents = { "PLAYER_FOCUS_CHANGED" },
})

define("focustarget", {
	order = 60,
	label = L["Focus Target"],
	unitWatch = true,
	derived = true,
	owner = "focus",
	requires = "hasFocus",
	changeEvents = { "PLAYER_FOCUS_CHANGED", "UNIT_TARGET" },
})

--------------------------------------------------------------------------------
-- Party (SPEC §5.4 — four static secure buttons, not a group header)
--------------------------------------------------------------------------------

for i = 1, 4 do
	define("party" .. i, {
		order = 100 + i,
		label = string.format(L["Party %d"], i),
		unitWatch = true,
		group = "party",
		groupIndex = i,
		changeEvents = { "GROUP_ROSTER_UPDATE" },
	})

	define("partypet" .. i, {
		order = 120 + i,
		label = string.format(L["Party Pet %d"], i),
		unitWatch = true,
		group = "partypet",
		groupIndex = i,
		owner = "party" .. i,
		changeEvents = { "GROUP_ROSTER_UPDATE", "UNIT_PET" },
	})
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

--- Is this unit supported on the running client?
-- SPEC §FR-8.5: on Classic Era, focus frames must not be *created* and their
-- config subtrees must not be *built*. Absent, not present-and-broken.
function Registry:IsAvailable(key)
	local def = units[key]
	if not def then return false end
	if def.requires then
		return Compat[def.requires] and true or false
	end
	return true
end

function Registry:IsDerived(key)
	local def = units[key]
	return def and def.derived or false
end

function Registry:Get(key)
	return units[key]
end

local sortedCache, sortedSerial = nil, nil

--- Unit definitions in display order.
function Registry:Sorted()
	if sortedCache and sortedSerial == ns.configSerial then return sortedCache end
	local list = {}
	for _, def in pairs(units) do list[#list + 1] = def end
	table.sort(list, function(a, b) return a.order < b.order end)
	sortedCache, sortedSerial = list, ns.configSerial
	return list
end

--- Available unit definitions only.
function Registry:SortedAvailable()
	local list = {}
	for _, def in ipairs(self:Sorted()) do
		if self:IsAvailable(def.key) then list[#list + 1] = def end
	end
	return list
end

--- Unit-key -> label map, for the options UI's copy-from and anchor-to lists.
function Registry:LabelValues(exclude)
	local values = {}
	for _, def in ipairs(self:SortedAvailable()) do
		if def.key ~= exclude then values[def.key] = def.label end
	end
	return values
end

function Registry:GroupMembers(group)
	local list = {}
	for _, def in ipairs(self:Sorted()) do
		if def.group == group then list[#list + 1] = def end
	end
	return list
end
