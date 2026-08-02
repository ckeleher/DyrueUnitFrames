-- Systems/ColorRules.lua
--
-- SPEC §4.3.3 — the color rule engine.
--
-- An ordered list; the first matching rule wins; if none match, the element's
-- static color applies. The metric being *tested* is deliberately independent
-- of the element being *colored* (FR-3.3), so "turn the unit's name red when
-- its health drops below 20%" is an ordinary configuration rather than a
-- special case.
--
-- Rule sets are precompiled and cached against ns.configSerial so that a
-- per-update table walk never happens (PLAN task 4.5).

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

local ColorRules = {}
ns.ColorRules = ColorRules

--------------------------------------------------------------------------------
-- Metrics (SPEC §4.3.3 "Available metrics")
--
-- Every metric returns a number. Boolean facts return 1 or 0 so that there is
-- exactly one comparison path; the options UI presents those as a Yes/No
-- toggle that writes 1 or 0.
--------------------------------------------------------------------------------

local UNKNOWN_LEVEL_DIFFERENCE = 99

local metrics = {
	["health.current"] = {
		label = L["Health: current"],
		fn = function(unit) return UnitHealth(unit) or 0 end,
	},
	["health.max"] = {
		label = L["Health: maximum"],
		fn = function(unit) return UnitHealthMax(unit) or 0 end,
	},
	["health.percent"] = {
		label = L["Health: percent"],
		fn = function(unit)
			local maximum = UnitHealthMax(unit)
			if not maximum or maximum <= 0 then return 0 end
			return (UnitHealth(unit) or 0) / maximum * 100
		end,
	},
	["health.deficit"] = {
		label = L["Health: deficit"],
		fn = function(unit) return (UnitHealthMax(unit) or 0) - (UnitHealth(unit) or 0) end,
	},
	["power.current"] = {
		label = L["Power: current"],
		fn = function(unit) return UnitPower(unit) or 0 end,
	},
	["power.percent"] = {
		label = L["Power: percent"],
		fn = function(unit)
			local maximum = UnitPowerMax(unit)
			if not maximum or maximum <= 0 then return 0 end
			return (UnitPower(unit) or 0) / maximum * 100
		end,
	},
	["power.deficit"] = {
		label = L["Power: deficit"],
		fn = function(unit) return (UnitPowerMax(unit) or 0) - (UnitPower(unit) or 0) end,
	},
	["mana.current"] = {
		label = L["Mana: current"],
		fn = function(unit) return UnitPower(unit, Compat.MANA) or 0 end,
	},
	["mana.percent"] = {
		label = L["Mana: percent"],
		fn = function(unit)
			local maximum = UnitPowerMax(unit, Compat.MANA)
			if not maximum or maximum <= 0 then return 0 end
			return (UnitPower(unit, Compat.MANA) or 0) / maximum * 100
		end,
	},
	["level.value"] = {
		label = L["Level"],
		fn = function(unit) return UnitLevel(unit) or 0 end,
	},
	["level.difference"] = {
		label = L["Level: difference from you"],
		fn = function(unit)
			local level = UnitLevel(unit)
			if not level or level <= 0 then return UNKNOWN_LEVEL_DIFFERENCE end
			return level - (UnitLevel("player") or 0)
		end,
	},
	["unit.isDead"] = {
		label = L["Is dead"],
		boolean = true,
		fn = function(unit) return (UnitIsDead(unit) or UnitIsGhost(unit)) and 1 or 0 end,
	},
	["unit.isOffline"] = {
		label = L["Is offline"],
		boolean = true,
		fn = function(unit) return UnitIsConnected(unit) and 0 or 1 end,
	},
	["unit.isPlayer"] = {
		label = L["Is a player"],
		boolean = true,
		fn = function(unit) return UnitIsPlayer(unit) and 1 or 0 end,
	},
	["unit.reaction"] = {
		label = L["Reaction (1 hostile - 8 friendly)"],
		fn = function(unit) return UnitReaction(unit, "player") or 4 end,
	},
}

ColorRules.metrics = metrics

--- Metric list for the options UI, as an AceConfig `values` table.
function ColorRules:MetricValues()
	local values = {}
	for key, def in pairs(metrics) do values[key] = def.label end
	return values
end

function ColorRules:IsBooleanMetric(key)
	local def = metrics[key]
	return def and def.boolean or false
end

--------------------------------------------------------------------------------
-- Operators
--------------------------------------------------------------------------------

local operators = {
	["<"]  = function(a, b) return a < b end,
	["<="] = function(a, b) return a <= b end,
	[">"]  = function(a, b) return a > b end,
	[">="] = function(a, b) return a >= b end,
	["=="] = function(a, b) return a == b end,
	["~="] = function(a, b) return a ~= b end,
}

ColorRules.operators = operators

function ColorRules:OperatorValues()
	return {
		["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">=",
		["=="] = "==", ["~="] = L["~= (not equal)"],
	}
end

--------------------------------------------------------------------------------
-- Compilation
--------------------------------------------------------------------------------

-- Weak-keyed so that deleting a rule set does not pin its compiled form.
local compiledCache = setmetatable({}, { __mode = "k" })

local function compile(rules)
	local out = { serial = ns.configSerial, list = {} }
	local list = out.list
	for i = 1, #rules do
		local rule = rules[i]
		if rule and rule.enabled ~= false then
			local metric = metrics[rule.metric or ""]
			local op = operators[rule.op or "<="]
			if metric and op then
				list[#list + 1] = {
					fn = metric.fn,
					op = op,
					value = tonumber(rule.value) or 0,
					r = (rule.color and rule.color.r) or 1,
					g = (rule.color and rule.color.g) or 1,
					b = (rule.color and rule.color.b) or 1,
				}
			end
		end
	end
	return out
end

local function getCompiled(rules)
	local compiled = compiledCache[rules]
	if not compiled or compiled.serial ~= ns.configSerial then
		compiled = compile(rules)
		compiledCache[rules] = compiled
	end
	return compiled
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

--- First match wins. Returns nil when nothing matches so the caller can apply
-- its own static fallback (SPEC §FR-3.2).
function ColorRules:Evaluate(rules, unit)
	if type(rules) ~= "table" or #rules == 0 then return nil end
	if not unit or not UnitExists(unit) then return nil end

	local list = getCompiled(rules).list
	for i = 1, #list do
		local rule = list[i]
		local value = rule.fn(unit)
		if value and rule.op(value, rule.value) then
			return rule.r, rule.g, rule.b
		end
	end
	return nil
end

--- Read one metric directly. Used by gradient coloring, which keys off a
-- metric rather than a rule list.
function ColorRules:Metric(key, unit)
	local def = metrics[key]
	if not def or not unit or not UnitExists(unit) then return nil end
	return def.fn(unit)
end

--------------------------------------------------------------------------------
-- Editing helpers (SPEC §FR-3.6)
--
-- Add, remove, reorder, duplicate and copy-between-elements. A rule engine
-- with a bad editor is a rule engine nobody uses, so these are first-class.
--------------------------------------------------------------------------------

function ColorRules:NewRule()
	return {
		enabled = true,
		metric = "health.percent",
		op = "<=",
		value = 35,
		color = { r = 1, g = 0.5, b = 0 },
	}
end

function ColorRules:Add(rules)
	rules[#rules + 1] = self:NewRule()
	ns:BumpSerial()
	return #rules
end

function ColorRules:Remove(rules, index)
	if not rules[index] then return false end
	table.remove(rules, index)
	ns:BumpSerial()
	return true
end

function ColorRules:Duplicate(rules, index)
	local rule = rules[index]
	if not rule then return false end
	table.insert(rules, index + 1, ns.Defaults.DeepCopy(rule))
	ns:BumpSerial()
	return true
end

function ColorRules:Move(rules, index, delta)
	local target = index + delta
	if not rules[index] or not rules[target] then return false end
	rules[index], rules[target] = rules[target], rules[index]
	ns:BumpSerial()
	return true
end

--- Replace `destination`'s contents with a copy of `source`.
function ColorRules:CopyInto(destination, source)
	for i = #destination, 1, -1 do destination[i] = nil end
	for i = 1, #source do destination[i] = ns.Defaults.DeepCopy(source[i]) end
	ns:BumpSerial()
	return #destination
end

--- One-line summary of a rule, for the options tree labels.
function ColorRules:Describe(rule)
	if not rule then return "" end
	local metric = metrics[rule.metric or ""]
	local label = metric and metric.label or (rule.metric or "?")
	local value = rule.value
	if metric and metric.boolean then
		value = (tonumber(value) == 1) and L["yes"] or L["no"]
	end
	local text = string.format("%s %s %s", label, rule.op or "?", tostring(value))
	if rule.enabled == false then
		return "|cff808080" .. text .. "|r"
	end
	local c = rule.color
	if c then
		return string.format("|cff%02x%02x%02x%s|r",
			(c.r or 1) * 255, (c.g or 1) * 255, (c.b or 1) * 255, text)
	end
	return text
end
