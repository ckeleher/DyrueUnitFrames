-- Config/Options_Text.lua
--
-- Text elements and the colour-rule editor (PLAN task 4.10).
--
-- The plan is explicit that a rule engine with a bad editor is a rule engine
-- nobody uses, so this file carries the full FR-3.6 set: add, remove, reorder,
-- enable/disable, duplicate, and copy a rule set to another element or unit.
--
-- Structural changes (adding or deleting a text or a rule) rebuild the args
-- table in place and call NotifyChange, because AceConfig's option tables are
-- static and the closures below capture list indices.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Registry = ns.Registry
local Options = ns.Options
local ColorRules = ns.ColorRules
local Defaults = ns.Defaults

local LSM = LibStub("LibSharedMedia-3.0")

local function wipeTable(t)
	for k in pairs(t) do t[k] = nil end
	return t
end

--------------------------------------------------------------------------------
-- Copy-source enumeration
--
-- "Copy this rule set to another element or unit" needs a flat list of every
-- text element in the profile. Rebuilt on demand so it always reflects reality.
--------------------------------------------------------------------------------

local function textSourceValues()
	local values = {}
	for _, def in ipairs(Registry:SortedAvailable()) do
		local cfg = ns:UnitConfig(def.key)
		if cfg and cfg.texts then
			for i = 1, #cfg.texts do
				local text = cfg.texts[i]
				values[def.key .. ":" .. i] = string.format("%s - %s", def.label, text.name or i)
			end
		end
	end
	return values
end

local function resolveTextSource(token)
	if type(token) ~= "string" then return nil end
	local unitKey, index = token:match("^(.-):(%d+)$")
	if not unitKey then return nil end
	local cfg = ns:UnitConfig(unitKey)
	return cfg and cfg.texts and cfg.texts[tonumber(index)]
end

--------------------------------------------------------------------------------
-- Rule editor (SPEC §4.3.3)
--------------------------------------------------------------------------------

-- `state` is a plain closure table rather than a field on `container`, because
-- AceConfigRegistry validates every key of an args table as an option and a
-- stray string would fail validation.
local function buildRuleArgs(container, state, getRules, apply, rebuild)
	wipeTable(container)

	container.explain = {
		type = "description", order = 0,
		name = L["Rules are evaluated top to bottom and the first match wins. If none match, the static colour above is used. The thing being tested is independent of the thing being coloured, so 'turn the name red below 20% health' is an ordinary rule."],
	}

	container.add = {
		type = "execute", order = 1, name = L["Add rule"],
		func = function()
			ColorRules:Add(getRules())
			rebuild()
			apply()
		end,
	}

	container.copySource = {
		type = "select", order = 2, name = L["Copy rules from"],
		values = textSourceValues,
		get = function() return state.copySource end,
		set = function(_, value) state.copySource = value end,
	}

	container.copyGo = {
		type = "execute", order = 3, name = L["Copy"],
		disabled = function() return state.copySource == nil end,
		func = function()
			local source = resolveTextSource(state.copySource)
			if not source then return end
			ColorRules:CopyInto(getRules(), source.rules or {})
			rebuild()
			apply()
		end,
	}

	local rules = getRules()
	for i = 1, #rules do
		local index = i
		local function rule() return getRules()[index] end

		container["rule" .. index] = {
			type = "group", order = 10 + index, inline = true,
			name = function()
				local r = rule()
				return r and string.format("%d. %s", index, ColorRules:Describe(r)) or tostring(index)
			end,
			args = {
				enabled = {
					type = "toggle", order = 1, name = L["Enabled"], width = "half",
					get = function() return rule().enabled ~= false end,
					set = function(_, v) rule().enabled = v; ns:BumpSerial(); apply() end,
				},
				metric = {
					type = "select", order = 2, name = L["Test"],
					values = function() return ColorRules:MetricValues() end,
					get = function() return rule().metric end,
					set = function(_, v)
						rule().metric = v
						if ColorRules:IsBooleanMetric(v) then
							rule().op = "=="
							rule().value = 1
						end
						ns:BumpSerial()
						apply()
						Options:Notify()
					end,
				},
				op = {
					type = "select", order = 3, name = L["Operator"], width = "half",
					values = function() return ColorRules:OperatorValues() end,
					get = function() return rule().op end,
					set = function(_, v) rule().op = v; ns:BumpSerial(); apply() end,
				},
				value = {
					type = "input", order = 4, name = L["Value"], width = "half",
					hidden = function() return ColorRules:IsBooleanMetric(rule().metric) end,
					validate = function(_, v)
						return tonumber(v) and true or L["Enter a number."]
					end,
					get = function() return tostring(rule().value or 0) end,
					set = function(_, v)
						rule().value = tonumber(v) or 0
						ns:BumpSerial()
						apply()
					end,
				},
				booleanValue = {
					type = "select", order = 5, name = L["Value"], width = "half",
					hidden = function() return not ColorRules:IsBooleanMetric(rule().metric) end,
					values = { [1] = L["yes"], [0] = L["no"] },
					get = function() return tonumber(rule().value) == 1 and 1 or 0 end,
					set = function(_, v) rule().value = v; ns:BumpSerial(); apply() end,
				},
				color = Options.Color(L["Colour"], 6, rule, "color", function()
					ns:BumpSerial()
					apply()
				end),
				up = {
					type = "execute", order = 10, name = L["Up"], width = "half",
					disabled = function() return index <= 1 end,
					func = function()
						ColorRules:Move(getRules(), index, -1)
						rebuild()
						apply()
					end,
				},
				down = {
					type = "execute", order = 11, name = L["Down"], width = "half",
					disabled = function() return index >= #getRules() end,
					func = function()
						ColorRules:Move(getRules(), index, 1)
						rebuild()
						apply()
					end,
				},
				duplicate = {
					type = "execute", order = 12, name = L["Duplicate"], width = "half",
					func = function()
						ColorRules:Duplicate(getRules(), index)
						rebuild()
						apply()
					end,
				},
				remove = {
					type = "execute", order = 13, name = L["Remove"], width = "half",
					func = function()
						ColorRules:Remove(getRules(), index)
						rebuild()
						apply()
					end,
				},
			},
		}
	end

	return container
end

--------------------------------------------------------------------------------
-- One text element
--------------------------------------------------------------------------------

local function buildTextGroup(def, index, rebuildParent)
	local unitKey = def.key
	local apply = Options.ApplyUnit(unitKey)

	local function texts() local c = ns:UnitConfig(unitKey); return c and c.texts end
	local function text() local t = texts(); return t and t[index] end
	local function gradient() local t = text(); return t and t.gradient end
	local function rules() local t = text(); return t and t.rules end

	local function notGradient() return text().colorMode ~= "gradient" end

	local ruleArgs, ruleState = {}, {}
	local rebuildRules
	rebuildRules = function()
		buildRuleArgs(ruleArgs, ruleState, rules, apply, function()
			rebuildRules()
			Options:Notify()
		end)
	end
	rebuildRules()

	local anchorValues = {
		frame = L["The frame"],
		health = L["Health bar"],
		power = L["Power bar"],
		mana = L["Shapeshift mana bar"],
		portrait = L["Portrait"],
	}

	return {
		type = "group",
		order = index,
		name = function()
			local t = text()
			if not t then return tostring(index) end
			local label = t.name or tostring(index)
			return (t.enabled == false) and ("|cff808080" .. label .. "|r") or label
		end,
		args = {
			enabled = {
				type = "toggle", order = 1, name = L["Enabled"],
				get = function() return text().enabled ~= false end,
				set = function(_, v) text().enabled = v; apply(); Options:Notify() end,
			},
			name = {
				type = "input", order = 2, name = L["Label"],
				desc = L["Only used to identify this element in these options."],
				get = function() return text().name end,
				set = function(_, v) text().name = v; Options:Notify() end,
			},
			format = {
				type = "input", order = 3, width = "full", name = L["Format"],
				desc = L["Tags in square brackets, mixed with any literal text you like. /duf tags lists the vocabulary."],
				get = function() return text().format end,
				set = function(_, v) text().format = v; ns:BumpSerial(); apply() end,
			},
			remove = {
				type = "execute", order = 4, name = L["Remove this text element"],
				confirm = true,
				confirmText = L["Remove this text element?"],
				func = function()
					table.remove(texts(), index)
					ns:BumpSerial()
					rebuildParent()
					apply()
				end,
			},

			anchorHeader = { type = "header", order = 10, name = L["Position"] },
			anchorTo = {
				type = "select", order = 11, name = L["Anchor to"],
				values = anchorValues,
				get = function() return text().anchorTo end,
				set = function(_, v) text().anchorTo = v; apply() end,
			},
			point = {
				type = "select", order = 12, name = L["Point on the text"],
				values = ns.Anchoring:PointValues(),
				get = function() return text().point end,
				set = function(_, v) text().point = v; apply() end,
			},
			relativePoint = {
				type = "select", order = 13, name = L["Point on the anchor"],
				values = ns.Anchoring:PointValues(),
				get = function() return text().relativePoint end,
				set = function(_, v) text().relativePoint = v; apply() end,
			},
			x = Options.Range(L["X offset"], 14, "offset", text, "x", apply),
			y = Options.Range(L["Y offset"], 15, "offset", text, "y", apply),

			fontHeader = { type = "header", order = 20, name = L["Font"] },
			font = {
				type = "select", order = 21, name = L["Font"],
				dialogControl = "LSM30_Font",
				values = function() return LSM:HashTable("font") end,
				get = function() return text().font end,
				set = function(_, v) text().font = v; apply() end,
			},
			size = {
				type = "range", order = 22, name = L["Size"],
				min = 4, max = 64, softMax = 32, step = 1,
				get = function() return text().size end,
				set = function(_, v) text().size = v; apply() end,
			},
			outline = {
				type = "select", order = 23, name = L["Outline"],
				values = Options.OUTLINES,
				get = function() return text().outline end,
				set = function(_, v) text().outline = v; apply() end,
			},
			shadow = {
				type = "toggle", order = 24, name = L["Shadow"],
				get = function() return text().shadow end,
				set = function(_, v) text().shadow = v; apply() end,
			},
			justify = {
				type = "select", order = 25, name = L["Alignment"],
				values = Options.JUSTIFY,
				get = function() return text().justify end,
				set = function(_, v) text().justify = v; apply() end,
			},
			maxWidth = {
				type = "range", order = 26, name = L["Maximum width"],
				desc = L["0 means no truncation."],
				min = 0, max = 500, step = 1,
				get = function() return text().maxWidth end,
				set = function(_, v) text().maxWidth = v; apply() end,
			},

			colorHeader = { type = "header", order = 30, name = L["Colour"] },
			colorMode = {
				type = "select", order = 31, name = L["Colour mode"],
				values = {
					static = L["Single colour"],
					rules = L["Rules"],
					class = L["Class colour"],
					reaction = L["Reaction colour"],
					difficulty = L["Level difficulty"],
					gradient = L["Gradient"],
				},
				get = function() return text().colorMode end,
				set = function(_, v) text().colorMode = v; ns:BumpSerial(); apply(); Options:Notify() end,
			},
			difficultyNote = {
				type = "description", order = 32,
				hidden = function() return text().colorMode ~= "difficulty" end,
				name = L["Uses the game's own GetCreatureDifficultyColor, so grey/green/yellow/orange/red match the default UI exactly and stay matched if Blizzard ever adjusts them. For non-standard thresholds, switch to Rules and test level.difference."],
			},
			color = Options.Color(L["Colour"], 33, text, "color", apply, {
				desc = L["Also the fallback when no rule matches."],
				hidden = function()
					local mode = text().colorMode
					return mode == "difficulty" or mode == "gradient"
				end,
			}),
			gradientMetric = {
				type = "select", order = 34, name = L["Gradient follows"],
				hidden = notGradient,
				values = function() return ColorRules:MetricValues() end,
				get = function() return text().gradientMetric end,
				set = function(_, v) text().gradientMetric = v; ns:BumpSerial(); apply() end,
			},
			gradient1 = Options.GradientColor(L["Gradient: low"], 35, gradient, 1, apply, { hidden = notGradient }),
			gradient2 = Options.GradientColor(L["Gradient: middle"], 36, gradient, 2, apply, { hidden = notGradient }),
			gradient3 = Options.GradientColor(L["Gradient: high"], 37, gradient, 3, apply, { hidden = notGradient }),

			rules = {
				type = "group", order = 40, name = L["Colour rules"],
				hidden = function() return text().colorMode ~= "rules" end,
				args = ruleArgs,
			},
		},
	}
end

--------------------------------------------------------------------------------
-- The texts container
--------------------------------------------------------------------------------

function Options.BuildTexts(def)
	local unitKey = def.key
	local apply = Options.ApplyUnit(unitKey)
	local args = {}

	local function texts() local c = ns:UnitConfig(unitKey); return c and c.texts end

	local rebuild
	rebuild = function()
		wipeTable(args)

		args.tagHelp = {
			type = "group", order = 0, inline = true, name = L["Tag reference"],
			args = {
				body = {
					type = "description", order = 1,
					name = function() return ns.Tags:AllHelp() end,
				},
				collapse = {
					type = "description", order = 2,
					name = L["A tag that resolves to nothing removes its adjacent separators, so \"[hp:cur] / [hp:max] [hp:perc]%\" renders as just the percentage on a unit whose absolute health is unknown."],
				},
			},
		}

		-- SPEC §FR-4.7: the explanation belongs next to the text settings of
		-- the frames it actually affects.
		if def.key ~= "player" and def.group ~= "party" then
			args.enemyHealth = {
				type = "description", order = 1,
				name = L["|cffffcc00Enemy health note.|r Classic and TBC only report real health numbers for you and your group. For everything else the client reports a 0-100 scale, so absolute values would be fiction. [hp:cur], [hp:max] and [hp:deficit] therefore render as nothing on those units and their separators collapse; [hp:perc] is always accurate."],
			}
		end

		args.add = {
			type = "execute", order = 2, name = L["Add a text element"],
			func = function()
				local list = texts()
				list[#list + 1] = Defaults.Text({
					name = string.format(L["Text %d"], #list + 1),
					format = "[name]",
				})
				ns:BumpSerial()
				rebuild()
				apply()
				Options:Notify()
			end,
		}

		local list = texts() or {}
		for i = 1, #list do
			args["text" .. i] = buildTextGroup(def, i, function()
				rebuild()
				Options:Notify()
			end)
		end
	end

	rebuild()

	return {
		type = "group", order = 7, name = L["Text"], childGroups = "tree",
		args = args,
	}
end
