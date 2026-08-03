-- Config/Options.lua
--
-- The AceConfig tree root (PLAN task 2.2).
--
-- AceConfig's `range` control is the reason Ace3 was chosen: it gives the
-- slider-plus-exact-numeric-entry that SPEC §FR-1.2 requires, for free, with
-- softMin/softMax bounding the slider while typed values may go beyond it.
-- Both halves stay in sync because there is one stored value behind them.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Errors = ns.Errors
local Registry = ns.Registry
local CombatQueue = ns.CombatQueue

local Options = {}
ns.Options = Options

local LSM = LibStub("LibSharedMedia-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

--------------------------------------------------------------------------------
-- Shared vocabulary
--------------------------------------------------------------------------------

Options.OUTLINES = {
	NONE = L["None"],
	OUTLINE = L["Outline"],
	THICKOUTLINE = L["Thick outline"],
	MONOCHROME = L["Monochrome"],
	["MONOCHROME,OUTLINE"] = L["Monochrome + outline"],
}

Options.JUSTIFY = { LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"] }

Options.STRATA = {
	BACKGROUND = L["Background"],
	LOW = L["Low"],
	MEDIUM = L["Medium"],
	HIGH = L["High"],
	DIALOG = L["Dialog"],
}

--- FR-1.2's table, in one place so every position and size control agrees.
Options.RANGES = {
	offset = { min = -100000, max = 100000, softMin = -2000, softMax = 2000, step = 1, bigStep = 1 },
	width  = { min = 10, max = 2000, softMin = 40, softMax = 500, step = 1, bigStep = 1 },
	height = { min = 1, max = 1000, softMin = 1, softMax = 300, step = 1, bigStep = 1 },
	scale  = { min = 0.25, max = 4.0, softMin = 0.5, softMax = 2.0, step = 0.01, bigStep = 0.01 },
}

--------------------------------------------------------------------------------
-- Apply helpers
--------------------------------------------------------------------------------

function Options.ApplyUnit(unitKey)
	return function()
		ns:BumpSerial()
		ns:RefreshUnit(unitKey)
	end
end

function Options.ApplyLayout(unitKey)
	return function()
		ns:BumpSerial()
		ns.Anchoring:Apply(unitKey)
		ns:RefreshUnit(unitKey)
	end
end

function Options.ApplyAll()
	ns:RefreshAll()
end

--------------------------------------------------------------------------------
-- Field factories
--
-- Every getter resolves its table at call time rather than closing over it, so
-- switching profiles does not leave the options panel pointed at a dead table.
--------------------------------------------------------------------------------

--- Plain value field.
function Options.Field(getTable, key, apply)
	return
		function()
			local t = getTable()
			return t and t[key]
		end,
		function(_, value)
			local t = getTable()
			if not t then return end
			t[key] = value
			if apply then apply() end
		end
end

--- Color field, in AceConfig's r,g,b,a form.
function Options.ColorField(getTable, key, apply)
	return
		function()
			local t = getTable()
			local c = t and t[key]
			if not c then return 1, 1, 1, 1 end
			return c.r or 1, c.g or 1, c.b or 1, c.a or 1
		end,
		function(_, r, g, b, a)
			local t = getTable()
			local c = t and t[key]
			if not c then return end
			c.r, c.g, c.b, c.a = r, g, b, a
			if apply then apply() end
		end
end

--- Color field for a positional entry in a gradient stop list.
function Options.GradientField(getTable, index, apply)
	return
		function()
			local list = getTable()
			local c = list and list[index]
			if not c then return 1, 1, 1, 1 end
			return c.r or 1, c.g or 1, c.b or 1, 1
		end,
		function(_, r, g, b)
			local list = getTable()
			local c = list and list[index]
			if not c then return end
			c.r, c.g, c.b = r, g, b
			if apply then apply() end
		end
end

--- Complete color control.
function Options.Color(name, order, getTable, key, apply, overrides)
	local get, set = Options.ColorField(getTable, key, apply)
	local option = { type = "color", name = name, order = order, get = get, set = set }
	if overrides then
		for k, v in pairs(overrides) do option[k] = v end
	end
	return option
end

--- Complete color control for one stop in a gradient list.
function Options.GradientColor(name, order, getList, index, apply, overrides)
	local get, set = Options.GradientField(getList, index, apply)
	local option = { type = "color", name = name, order = order, get = get, set = set }
	if overrides then
		for k, v in pairs(overrides) do option[k] = v end
	end
	return option
end

--- Build a range control from one of the FR-1.2 presets.
function Options.Range(name, order, preset, getTable, key, apply, overrides)
	local range = Options.RANGES[preset] or Options.RANGES.offset
	local option = {
		type = "range",
		name = name,
		order = order,
		min = range.min, max = range.max,
		softMin = range.softMin, softMax = range.softMax,
		step = range.step, bigStep = range.bigStep,
	}
	option.get, option.set = Options.Field(getTable, key, apply)
	if overrides then
		for k, v in pairs(overrides) do option[k] = v end
	end
	return option
end

--------------------------------------------------------------------------------
-- The combat notice (SPEC §FR-1.6, PLAN task 2.6)
--
-- Non-blocking: the value is already stored, only the visual application is
-- waiting. No errors, no silent failure, just a line telling the truth.
--------------------------------------------------------------------------------

local function combatNotice(order)
	return {
		type = "description",
		order = order,
		fontSize = "medium",
		name = function()
			return CombatQueue:StatusText() or ""
		end,
		hidden = function()
			return not CombatQueue:IsPending()
		end,
	}
end
Options.CombatNotice = combatNotice

--------------------------------------------------------------------------------
-- General
--------------------------------------------------------------------------------

local function generalGroup()
	local function general() return ns:General() end
	local function global() return ns:Global() end
	local applyAll = Options.ApplyAll

	local args = {}

	args.notice = combatNotice(0)

	args.blizzard = {
		type = "group", order = 10, inline = true, name = L["Blizzard's own frames"],
		args = {
			explain = {
				type = "description", order = 1,
				name = L["Hidden by default, since the default frames sitting on top of these ones is not a usable starting point. If you would rather drive it from Edit Mode -- which these clients have, and which is the lower-risk option because it does not involve an addon reaching into Blizzard's UI at all -- set this to 'Leave alone' and hide them there instead."],
			},
			mode = {
				type = "select", order = 2, name = L["Blizzard unit frames"],
				values = { none = L["Leave alone"], hide = L["Hide"] },
				get = function() return general().blizzardFrames end,
				set = function(_, value)
					general().blizzardFrames = value
					ns:ApplyBlizzardFrameSetting()
				end,
			},
			party = {
				type = "toggle", order = 3, name = L["Also hide Blizzard's party frames"],
				disabled = function() return general().blizzardFrames ~= "hide" end,
				get = function() return general().blizzardParty end,
				set = function(_, value)
					general().blizzardParty = value
					ns:ApplyBlizzardFrameSetting()
				end,
			},
		},
	}

	args.numbers = {
		type = "group", order = 20, inline = true, name = L["Number formatting"],
		args = {
			shortThreshold = {
				type = "range", order = 1, name = L["Abbreviate above"],
				desc = L["Numbers at or above this value render as 1.2k / 1.2m when a tag asks for :short."],
				min = 100, max = 1000000, softMax = 100000, step = 100,
				get = function() return general().shortThreshold end,
				set = function(_, v) general().shortThreshold = v; ns:UpdateAll() end,
			},
			shortDecimals = {
				type = "range", order = 2, name = L["Abbreviated decimals"],
				min = 0, max = 2, step = 1,
				get = function() return general().shortDecimals end,
				set = function(_, v) general().shortDecimals = v; ns:UpdateAll() end,
			},
			percentDecimals = {
				type = "range", order = 3, name = L["Percent decimals"],
				min = 0, max = 2, step = 1,
				get = function() return general().percentDecimals end,
				set = function(_, v) general().percentDecimals = v; ns:UpdateAll() end,
			},
		},
	}

	args.derived = {
		type = "group", order = 30, inline = true, name = L["Derived units"],
		args = {
			explain = {
				type = "description", order = 1,
				name = L["Target-of-target and focus-target do not receive reliable unit events, so their values are sampled rather than pushed. A shorter interval is fresher and costs more; the poller stops entirely when no derived frame is visible."],
			},
			interval = {
				type = "range", order = 2, name = L["Poll interval (seconds)"],
				min = 0.1, max = 1.0, step = 0.05,
				get = function() return general().derivedPollInterval end,
				set = function(_, v)
					general().derivedPollInterval = v
					ns.DerivedPoller:Reconfigure()
				end,
			},
			status = {
				type = "description", order = 3,
				name = function()
					return string.format(L["Poller: %s"], ns.DerivedPoller:Describe())
				end,
			},
		},
	}

	args.behavior = {
		type = "group", order = 40, inline = true, name = L["Behavior"],
		args = {
			unitTooltips = {
				type = "toggle", order = 1, name = L["Tooltips on unit frames"],
				get = function() return general().unitTooltips end,
				set = function(_, v) general().unitTooltips = v end,
			},
			focusOverride = {
				type = "select", order = 2, name = L["Focus support"],
				desc = L["Detected automatically by probing the client. Override only if the probe is wrong on a future patch."],
				values = {
					auto = string.format(L["Automatic (detected: %s)"],
						Compat.hasFocusProbed and L["available"] or L["not available"]),
					on = L["Force on"],
					off = L["Force off"],
				},
				get = function() return general().focusOverride end,
				set = function(_, v)
					general().focusOverride = v
					Compat.SetFocusOverride(v)
					Errors:Print(L["Focus support changed. Reload the UI (/reload) to build or remove the focus frames."])
				end,
			},
			useClassicDurations = {
				type = "toggle", order = 3, width = "double",
				name = L["Use LibClassicDurations for other players' aura timers"],
				desc = L["Classic only reports durations for auras you applied. If LibClassicDurations is installed, it can estimate the rest. Estimated timers are marked as such in the tooltip."],
				disabled = function() return not ns.elements.auras.HasClassicDurations() end,
				get = function() return general().useClassicDurations end,
				set = function(_, v) general().useClassicDurations = v; applyAll() end,
			},
			classicDurationsStatus = {
				type = "description", order = 4,
				name = function()
					return ns.elements.auras.HasClassicDurations()
						and "|cff40ff40" .. L["LibClassicDurations detected."] .. "|r"
						or "|cff808080" .. L["LibClassicDurations is not installed. It is deliberately not bundled."] .. "|r"
				end,
			},
			errorThreshold = {
				type = "range", order = 5, name = L["Disable an element after this many errors"],
				desc = L["A broken element disables itself for the session rather than filling your error frame. /duf errors lists what has tripped."],
				min = 1, max = 50, step = 1,
				get = function() return general().errorThreshold end,
				set = function(_, v) general().errorThreshold = v; Errors.threshold = v end,
			},
			debug = {
				type = "toggle", order = 6, name = L["Debug logging"],
				get = function() return global().debug end,
				set = function(_, v) global().debug = v; Errors.debug = v end,
			},
			safeMode = {
				type = "toggle", order = 7, name = L["Safe mode (bars only)"],
				desc = L["The patch-day escape hatch: no text, no auras. Takes effect after /reload and survives it."],
				get = function() return global().safeMode end,
				set = function(_, v)
					global().safeMode = v
					Errors:Print(L["Safe mode changed. Reload the UI (/reload) to apply."])
				end,
			},
		},
	}

	args.grid = {
		type = "group", order = 50, inline = true, name = L["Drag mode"],
		args = {
			gridSnap = {
				type = "toggle", order = 1, name = L["Snap to grid"],
				get = function() return general().gridSnap end,
				set = function(_, v) general().gridSnap = v end,
			},
			gridSize = {
				type = "range", order = 2, name = L["Grid size"],
				min = 1, max = 64, step = 1,
				get = function() return general().gridSize end,
				set = function(_, v) general().gridSize = v; ns.DragMode:RefreshGrid() end,
			},
			nudgeStep = {
				type = "range", order = 3, name = L["Arrow nudge"],
				min = 0.5, max = 20, step = 0.5,
				get = function() return general().nudgeStep end,
				set = function(_, v) general().nudgeStep = v end,
			},
			nudgeStepLarge = {
				type = "range", order = 4, name = L["Shift+arrow nudge"],
				min = 1, max = 100, step = 1,
				get = function() return general().nudgeStepLarge end,
				set = function(_, v) general().nudgeStepLarge = v end,
			},
		},
	}

	return { type = "group", order = 1, name = L["General"], args = args }
end

--------------------------------------------------------------------------------
-- Party group (SPEC §FR-6.3)
--------------------------------------------------------------------------------

local function partyGroupOptions()
	local function group() return ns:Profile().partyGroup end
	local function anchor() return group().anchor end
	local function apply()
		ns:BumpSerial()
		ns.PartyGroup:Apply()
	end

	return {
		type = "group", order = 20, name = L["Party group"],
		args = {
			notice = combatNotice(0),
			explain = {
				type = "description", order = 1,
				name = L["Positions all four party frames at once. Frame 1 sits at the group anchor and the rest chain off it, so a hidden member leaves no gap. Any individual frame can opt out under its own Layout tab."],
			},
			enabled = {
				type = "toggle", order = 2, name = L["Use group layout"],
				get = function() return group().enabled end,
				set = function(_, v) group().enabled = v; apply() end,
			},
			growth = {
				type = "select", order = 3, name = L["Growth direction"],
				values = ns.PartyGroup:GrowthValues(),
				get = function() return group().growth end,
				set = function(_, v) group().growth = v; apply() end,
			},
			spacing = {
				type = "range", order = 4, name = L["Spacing"],
				min = -50, max = 200, softMax = 60, step = 1,
				get = function() return group().spacing end,
				set = function(_, v) group().spacing = v; apply() end,
			},
			anchorHeader = { type = "header", order = 10, name = L["Group anchor"] },
			anchorTo = {
				type = "select", order = 11, name = L["Anchor to"],
				values = function()
					local values = { UIParent = L["Screen"] }
					for _, def in ipairs(Registry:SortedAvailable()) do
						if def.group ~= "party" then values[def.key] = def.label end
					end
					return values
				end,
				get = function() return anchor().to end,
				set = function(_, v) anchor().to = v; apply() end,
			},
			anchorPoint = {
				type = "select", order = 12, name = L["Point on the group"],
				values = ns.Anchoring:PointValues(),
				get = function() return anchor().point end,
				set = function(_, v) anchor().point = v; apply() end,
			},
			relativePoint = {
				type = "select", order = 13, name = L["Point on the anchor"],
				values = ns.Anchoring:PointValues(),
				get = function() return anchor().relativePoint end,
				set = function(_, v) anchor().relativePoint = v; apply() end,
			},
			x = Options.Range(L["X offset"], 14, "offset", anchor, "x", apply),
			y = Options.Range(L["Y offset"], 15, "offset", anchor, "y", apply),

			sizeHeader = { type = "header", order = 20, name = L["Size"] },
			overrideSize = {
				type = "toggle", order = 21, name = L["Set all four sizes here"],
				get = function() return group().overrideSize end,
				set = function(_, v) group().overrideSize = v; apply() end,
			},
			width = Options.Range(L["Width"], 22, "width", group, "width", apply,
				{ disabled = function() return not group().overrideSize end }),
			height = Options.Range(L["Height"], 23, "height", group, "height", apply,
				{ disabled = function() return not group().overrideSize end }),

			visHeader = { type = "header", order = 30, name = L["Visibility"] },
			hideInRaid = {
				type = "toggle", order = 31, name = L["Hide while in a raid"],
				desc = L["Raid frames are out of scope, and forty stacked party frames helps nobody."],
				get = function() return group().hideInRaid end,
				set = function(_, v) group().hideInRaid = v; apply() end,
			},
			showWhenSolo = {
				type = "toggle", order = 32, name = L["Show while solo"],
				desc = L["Useful for configuration, though /duf test is the better tool for that."],
				get = function() return group().showWhenSolo end,
				set = function(_, v) group().showWhenSolo = v; apply() end,
			},
			selfNote = {
				type = "description", order = 33,
				name = L["The player frame is never rendered inside the party group. Classic has no 'show self in party frames' convention and adding one invites layout confusion."],
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Tools (PLAN task 2.7 — copy settings between units)
--------------------------------------------------------------------------------

local copyState = { from = "player", to = {} }

local function toolsGroup()
	return {
		type = "group", order = 30, name = L["Tools"],
		args = {
			drag = {
				type = "execute", order = 1, name = L["Toggle drag mode"],
				desc = L["Same as /duf move. Drag frames with the mouse, nudge with the arrow keys."],
				func = function() ns.DragMode:Toggle() end,
			},
			test = {
				type = "execute", order = 2, name = L["Toggle test mode"],
				desc = L["Same as /duf test. Shows every frame, including units that do not currently exist, so layout can be configured anywhere."],
				func = function() ns.TestMode:Toggle() end,
			},
			tags = {
				type = "execute", order = 3, name = L["Print tag reference"],
				func = function() ns.Tags:PrintReference() end,
			},
			compat = {
				type = "execute", order = 4, name = L["Print client capabilities"],
				func = function() ns:CompatReport() end,
			},
			profileReport = {
				type = "execute", order = 5, name = L["Print performance report"],
				func = function() ns:ProfileReport() end,
			},

			copyHeader = { type = "header", order = 10, name = L["Copy settings between units"] },
			copyExplain = {
				type = "description", order = 11,
				name = L["Copies everything except the anchor, so the destination frames stay where they are."],
			},
			copyFrom = {
				type = "select", order = 12, name = L["From"],
				values = function() return Registry:LabelValues() end,
				get = function() return copyState.from end,
				set = function(_, v) copyState.from = v end,
			},
			copyTo = {
				type = "multiselect", order = 13, name = L["To"],
				values = function() return Registry:LabelValues(copyState.from) end,
				get = function(_, key) return copyState.to[key] end,
				set = function(_, key, value) copyState.to[key] = value or nil end,
			},
			copyGo = {
				type = "execute", order = 14, name = L["Copy"],
				func = function()
					local count = 0
					for key, on in pairs(copyState.to) do
						if on and key ~= copyState.from then
							if ns.Factory:CopySettings(copyState.from, key) then count = count + 1 end
						end
					end
					AceConfigRegistry:NotifyChange(ADDON)
					Errors:Print(string.format(L["Copied %s to %d frame(s)."], copyState.from, count))
				end,
			},

			resetHeader = { type = "header", order = 20, name = L["Reset"] },
			resetAll = {
				type = "execute", order = 21, name = L["Reset every unit to defaults"],
				confirm = true,
				confirmText = L["This discards all per-unit layout and appearance settings in this profile. Continue?"],
				func = function()
					local profile = ns:Profile()
					for key in pairs(profile.units) do
						ns.Defaults:ResetUnit(profile, key)
					end
					ns:RefreshAll()
					AceConfigRegistry:NotifyChange(ADDON)
				end,
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function Options:Build()
	local units = {}
	-- SPEC §FR-8.5: on Classic Era the focus subtrees are not built at all.
	-- Absent, rather than present and broken.
	for _, def in ipairs(Registry:SortedAvailable()) do
		units[def.key] = Options.BuildUnit(def)
	end

	self.table = {
		type = "group",
		name = L["Dyrue Unit Frames"],
		args = {
			version = {
				type = "description", order = 0,
				name = function()
					return string.format(L["|cff66ccffDyrue Unit Frames|r v%s - %s (%d)"],
						ns.version, Compat.flavor, Compat.tocVersion)
				end,
			},
			notice = combatNotice(1),
			general = generalGroup(),
			units = {
				type = "group", order = 10, name = L["Units"], childGroups = "tree",
				args = units,
			},
			party = partyGroupOptions(),
			tools = toolsGroup(),
			profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(ns.db),
		},
	}
	self.table.args.profiles.order = 90

	-- FR-1.6: the notice must refresh as things queue and flush.
	CombatQueue:RegisterListener("options", function()
		if AceConfigDialog.OpenFrames[ADDON] then
			AceConfigRegistry:NotifyChange(ADDON)
		end
	end)

	return self.table
end

function Options:Notify()
	AceConfigRegistry:NotifyChange(ADDON)
end
