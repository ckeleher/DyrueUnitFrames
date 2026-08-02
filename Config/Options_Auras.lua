-- Config/Options_Auras.lua
--
-- Buff and debuff groups (PLAN task 5.12).
--
-- Two independent groups per unit with identical controls, built from one
-- function, because SPEC §FR-5.2 specifies them as separate and independently
-- configurable rather than as one group with a filter switch.

local ADDON, ns = ...
local L = ns.L
local Options = ns.Options
local Registry = ns.Registry

local LSM = LibStub("LibSharedMedia-3.0")

--------------------------------------------------------------------------------
-- Filter list editing
--
-- Spell names or IDs, one per line. Names are matched exactly; anything that
-- parses as a number is matched against the spell ID.
--------------------------------------------------------------------------------

local function listGet(getList)
	return function()
		local list = getList()
		return table.concat(list, "\n")
	end
end

local function listSet(getList, apply)
	return function(_, value)
		local list = getList()
		for i = #list, 1, -1 do list[i] = nil end
		for line in (value or ""):gmatch("[^\r\n]+") do
			local trimmed = line:match("^%s*(.-)%s*$")
			if trimmed ~= "" then list[#list + 1] = trimmed end
		end
		apply()
	end
end

--------------------------------------------------------------------------------
-- One aura group
--------------------------------------------------------------------------------

local function buildGroup(def, groupKey, order, label, isDebuff)
	local unitKey = def.key
	local apply = Options.ApplyUnit(unitKey)

	local function group()
		local cfg = ns:UnitConfig(unitKey)
		return cfg and cfg.auras and cfg.auras[groupKey]
	end
	local function whitelist() return group().whitelist end
	local function blacklist() return group().blacklist end

	local anchorValues = {
		frame = L["The frame"],
		health = L["Health bar"],
		power = L["Power bar"],
		buffs = L["The buff group"],
		debuffs = L["The debuff group"],
	}
	-- A group anchored to itself would be a loop; remove the self entry.
	anchorValues[groupKey] = nil

	local args = {
		notice = Options.CombatNotice(0),
		enabled = {
			type = "toggle", order = 1, name = L["Enable"],
			get = function() return group().enabled end,
			set = function(_, v) group().enabled = v; apply() end,
		},

		gridHeader = { type = "header", order = 10, name = L["Grid"] },
		size = {
			type = "range", order = 11, name = L["Icon size"],
			min = 4, max = 100, softMax = 48, step = 1,
			get = function() return group().size end,
			set = function(_, v) group().size = v; apply() end,
		},
		perRow = {
			type = "range", order = 12, name = L["Icons per row"],
			min = 1, max = 40, step = 1,
			get = function() return group().perRow end,
			set = function(_, v) group().perRow = v; apply() end,
		},
		rows = {
			type = "range", order = 13, name = L["Rows"],
			min = 1, max = 10, step = 1,
			get = function() return group().rows end,
			set = function(_, v) group().rows = v; apply() end,
		},
		maxShown = {
			type = "range", order = 14, name = L["Maximum shown"],
			min = 1, max = 40, step = 1,
			get = function() return group().maxShown end,
			set = function(_, v) group().maxShown = v; apply() end,
		},
		spacingX = {
			type = "range", order = 15, name = L["Horizontal spacing"],
			min = 0, max = 20, step = 1,
			get = function() return group().spacingX end,
			set = function(_, v) group().spacingX = v; apply() end,
		},
		spacingY = {
			type = "range", order = 16, name = L["Vertical spacing"],
			min = 0, max = 20, step = 1,
			get = function() return group().spacingY end,
			set = function(_, v) group().spacingY = v; apply() end,
		},
		growthX = {
			type = "select", order = 17, name = L["Grow horizontally"],
			values = { RIGHT = L["Right"], LEFT = L["Left"] },
			get = function() return group().growthX end,
			set = function(_, v) group().growthX = v; apply() end,
		},
		growthY = {
			type = "select", order = 18, name = L["Grow vertically"],
			values = { UP = L["Up"], DOWN = L["Down"] },
			get = function() return group().growthY end,
			set = function(_, v) group().growthY = v; apply() end,
		},

		anchorHeader = { type = "header", order = 20, name = L["Position"] },
		anchorTo = {
			type = "select", order = 21, name = L["Anchor to"],
			values = anchorValues,
			get = function() return group().anchorTo end,
			set = function(_, v) group().anchorTo = v; apply() end,
		},
		point = {
			type = "select", order = 22, name = L["Point on the group"],
			values = ns.Anchoring:PointValues(),
			get = function() return group().point end,
			set = function(_, v) group().point = v; apply() end,
		},
		relativePoint = {
			type = "select", order = 23, name = L["Point on the anchor"],
			values = ns.Anchoring:PointValues(),
			get = function() return group().relativePoint end,
			set = function(_, v) group().relativePoint = v; apply() end,
		},
		x = Options.Range(L["X offset"], 24, "offset", group, "x", apply),
		y = Options.Range(L["Y offset"], 25, "offset", group, "y", apply),

		ownHeader = { type = "header", order = 30, name = L["Your own auras"] },
		ownExplain = {
			type = "description", order = 31,
			name = L["Auras you cast are made larger, and optionally bordered in a colour of your choice, so yours are distinguishable at a glance."],
		},
		ownSizeMultiplier = {
			type = "range", order = 32, name = L["Size multiplier for your own"],
			min = 1, max = 3, step = 0.05,
			get = function() return group().ownSizeMultiplier end,
			set = function(_, v) group().ownSizeMultiplier = v; apply() end,
		},
		countOwnPet = {
			type = "toggle", order = 33, name = L["Count your pet's auras as yours"],
			get = function() return group().countOwnPet end,
			set = function(_, v) group().countOwnPet = v; apply() end,
		},
		desaturateOthers = {
			type = "toggle", order = 34, name = L["Desaturate other people's auras"],
			get = function() return group().desaturateOthers end,
			set = function(_, v) group().desaturateOthers = v; apply() end,
		},
		borderMode = {
			type = "select", order = 35, name = L["Border colour"],
			desc = L["Own-source and debuff-type colouring are mutually exclusive; pick which one takes precedence."],
			values = {
				none = L["No border"],
				own = L["Highlight your own"],
				type = L["By debuff type (Magic / Curse / Disease / Poison)"],
			},
			get = function() return group().borderMode end,
			set = function(_, v) group().borderMode = v; apply() end,
		},
		ownBorderColor = Options.Color(L["Your own border colour"], 36, group, "ownBorderColor", apply, {
			hidden = function() return group().borderMode ~= "own" end,
		}),
		defaultBorderColor = Options.Color(L["Default border colour"], 37, group, "defaultBorderColor", apply, {
			hasAlpha = true,
			hidden = function() return group().borderMode == "none" end,
		}),

		timerHeader = { type = "header", order = 40, name = L["Timers and stacks"] },
		durationNote = {
			type = "description", order = 41,
			name = L["Classic only reports durations for auras you applied. Anything cast by someone else gets no swipe and no timer rather than a made-up one. LibClassicDurations can estimate them if you install it; the switch is under General."],
		},
		showCooldown = {
			type = "toggle", order = 42, name = L["Cooldown swipe"],
			desc = L["A standard Cooldown frame, so OmniCC attaches to it automatically."],
			get = function() return group().showCooldown end,
			set = function(_, v) group().showCooldown = v; apply() end,
		},
		showDurationText = {
			type = "toggle", order = 43, name = L["Built-in duration text"],
			desc = L["Only needed if you do not have OmniCC."],
			get = function() return group().showDurationText end,
			set = function(_, v) group().showDurationText = v; apply() end,
		},
		durationFont = {
			type = "select", order = 44, name = L["Duration font"],
			dialogControl = "LSM30_Font",
			hidden = function() return not group().showDurationText end,
			values = function() return LSM:HashTable("font") end,
			get = function() return group().durationFont end,
			set = function(_, v) group().durationFont = v; apply() end,
		},
		durationSize = {
			type = "range", order = 45, name = L["Duration size"],
			hidden = function() return not group().showDurationText end,
			min = 4, max = 32, step = 1,
			get = function() return group().durationSize end,
			set = function(_, v) group().durationSize = v; apply() end,
		},
		showStacks = {
			type = "toggle", order = 46, name = L["Stack count"],
			get = function() return group().showStacks end,
			set = function(_, v) group().showStacks = v; apply() end,
		},
		stackCorner = {
			type = "select", order = 47, name = L["Stack corner"],
			hidden = function() return not group().showStacks end,
			values = ns.Anchoring:PointValues(),
			get = function() return group().stackCorner end,
			set = function(_, v) group().stackCorner = v; apply() end,
		},
		stackFont = {
			type = "select", order = 48, name = L["Stack font"],
			dialogControl = "LSM30_Font",
			hidden = function() return not group().showStacks end,
			values = function() return LSM:HashTable("font") end,
			get = function() return group().stackFont end,
			set = function(_, v) group().stackFont = v; apply() end,
		},
		stackSize = {
			type = "range", order = 49, name = L["Stack size"],
			hidden = function() return not group().showStacks end,
			min = 4, max = 32, step = 1,
			get = function() return group().stackSize end,
			set = function(_, v) group().stackSize = v; apply() end,
		},

		sortHeader = { type = "header", order = 50, name = L["Sorting and filtering"] },
		sort = {
			type = "select", order = 51, name = L["Sort by"],
			values = {
				own_time = L["Yours first, then time remaining"],
				time = L["Time remaining"],
				name = L["Name"],
				index = L["Game order"],
			},
			get = function() return group().sort end,
			set = function(_, v) group().sort = v; apply() end,
		},
		onlyOwn = {
			type = "toggle", order = 52, name = L["Only show your own"],
			get = function() return group().onlyOwn end,
			set = function(_, v) group().onlyOwn = v; apply() end,
		},
		hidePermanent = {
			type = "toggle", order = 53, name = L["Hide permanent auras"],
			get = function() return group().hidePermanent end,
			set = function(_, v) group().hidePermanent = v; apply() end,
		},
		minDuration = {
			type = "range", order = 54, name = L["Minimum duration (seconds)"],
			desc = L["0 shows everything. Permanent auras are unaffected by this."],
			min = 0, max = 600, softMax = 60, step = 1,
			get = function() return group().minDuration end,
			set = function(_, v) group().minDuration = v; apply() end,
		},
		useWhitelist = {
			type = "toggle", order = 55, name = L["Only show listed spells"],
			get = function() return group().useWhitelist end,
			set = function(_, v) group().useWhitelist = v; apply() end,
		},
		whitelist = {
			type = "input", order = 56, multiline = 6, width = "full",
			name = L["Whitelist (one spell name or ID per line)"],
			hidden = function() return not group().useWhitelist end,
			get = listGet(whitelist),
			set = listSet(whitelist, apply),
		},
		useBlacklist = {
			type = "toggle", order = 57, name = L["Hide listed spells"],
			get = function() return group().useBlacklist end,
			set = function(_, v) group().useBlacklist = v; apply() end,
		},
		blacklist = {
			type = "input", order = 58, multiline = 6, width = "full",
			name = L["Blacklist (one spell name or ID per line)"],
			hidden = function() return not group().useBlacklist end,
			get = listGet(blacklist),
			set = listSet(blacklist, apply),
		},

		tooltipHeader = { type = "header", order = 60, name = L["Tooltips"] },
		tooltips = {
			type = "toggle", order = 61, name = L["Show tooltips on hover"],
			get = function() return group().tooltips end,
			set = function(_, v) group().tooltips = v; apply() end,
		},
		tooltipsInCombat = {
			type = "toggle", order = 62, name = L["Also in combat"],
			disabled = function() return not group().tooltips end,
			get = function() return group().tooltipsInCombat end,
			set = function(_, v) group().tooltipsInCombat = v; apply() end,
		},
	}

	if not isDebuff and unitKey == "player" then
		args.cancelNote = {
			type = "description", order = 63,
			name = L["|cffffcc00Right-click cancels your own buffs on this frame.|r Cancelling is a protected action, so it goes through a secure attribute that can only be updated outside combat. Out of combat it is exact; during a fight the mapping can be one aura stale."],
		}
	end

	return { type = "group", order = order, name = label, args = args }
end

--------------------------------------------------------------------------------

function Options.BuildAuras(def)
	return {
		type = "group", order = 8, name = L["Auras"], childGroups = "tab",
		args = {
			buffs = buildGroup(def, "buffs", 1, L["Buffs"], false),
			debuffs = buildGroup(def, "debuffs", 2, L["Debuffs"], true),
		},
	}
end
