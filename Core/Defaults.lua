-- Core/Defaults.lua
--
-- SPEC §5.8 — the database schema and the default profile.
--
-- Design decision worth recording: AceDB's own `defaults` mechanism is NOT
-- used for the per-unit tree. AceDB implements defaults with __index
-- metatables, which works well for flat settings and badly for user-editable
-- *lists* — a removed colour rule or text element reappears on next login
-- because the default is still underneath it.
--
-- Instead AceDB is used purely for profile management (profiles, per-character
-- selection, the AceDBOptions UI) with an empty defaults table, and the schema
-- is deep-filled into the live profile by Ensure() below. The user then owns
-- every table outright: removal works, ordering works, and nothing is hidden
-- behind a metatable. Profile reset is handled by wiping and re-filling.

local ADDON, ns = ...
local L = ns.L

local Defaults = {}
ns.Defaults = Defaults

local type, pairs, ipairs, next = type, pairs, ipairs, next

Defaults.SCHEMA_VERSION = 1

--------------------------------------------------------------------------------
-- Table helpers
--------------------------------------------------------------------------------

local function deepCopy(src)
	if type(src) ~= "table" then return src end
	local out = {}
	for k, v in pairs(src) do
		out[k] = (type(v) == "table") and deepCopy(v) or v
	end
	return out
end
Defaults.DeepCopy = deepCopy

-- A table with [1] set is a user-editable list (text elements, colour rules,
-- gradient stops, filter entries). Lists are seeded once and then left alone,
-- so removing an entry actually removes it.
local function isList(t)
	return type(t) == "table" and t[1] ~= nil
end

--- Deep-fill `target` with anything missing from `template`, without touching
-- values the user has already set.
local function ensure(target, template)
	for k, v in pairs(template) do
		if type(v) == "table" then
			if target[k] == nil then
				target[k] = deepCopy(v)
			elseif type(target[k]) == "table" and not isList(v) then
				ensure(target[k], v)
			end
		elseif target[k] == nil then
			target[k] = v
		end
	end
	return target
end
Defaults.Fill = ensure

--------------------------------------------------------------------------------
-- Shared fragments
--------------------------------------------------------------------------------

-- Registered by Core/Core.lua against base-game media, so the shipped default
-- never depends on another addon being installed. Anything else in
-- LibSharedMedia remains selectable per bar.
local DEFAULT_BAR_TEXTURE = "Dyrue Flat"
local DEFAULT_FONT = "Friz Quadrata TT"

local function color(r, g, b, a)
	return { r = r, g = g, b = b, a = a or 1 }
end
Defaults.Color = color

--- One text element.
local function text(cfg)
	return ensure(cfg or {}, {
		enabled = true,
		name = L["Text"],
		format = "[name]",
		anchorTo = "health",           -- frame | health | power | mana | portrait
		point = "LEFT",
		relativePoint = "LEFT",
		x = 4,
		y = 0,
		font = DEFAULT_FONT,
		size = 12,
		outline = "OUTLINE",           -- NONE | OUTLINE | THICKOUTLINE | MONOCHROME
		shadow = true,
		justify = "LEFT",
		maxWidth = 0,                  -- 0 = no truncation
		colorMode = "static",          -- static | rules | class | reaction | difficulty | gradient
		color = color(1, 1, 1),
		rules = {},
		gradientMetric = "health.percent",
		gradient = { color(1, 0, 0), color(1, 1, 0), color(0, 1, 0) },
	})
end
Defaults.Text = text

--- One aura group (SPEC §FR-5.2).
local function auraGroup(cfg)
	return ensure(cfg or {}, {
		enabled = false,
		size = 20,
		ownSizeMultiplier = 1.4,
		maxShown = 32,
		perRow = 8,
		rows = 2,
		spacingX = 2,
		spacingY = 2,
		anchorTo = "frame",            -- frame | health | power | buffs | debuffs
		point = "BOTTOMLEFT",
		relativePoint = "TOPLEFT",
		x = 0,
		y = 2,
		growthX = "RIGHT",             -- RIGHT | LEFT
		growthY = "UP",                -- UP | DOWN
		sort = "own_time",             -- own_time | time | name | index
		borderMode = "own",            -- none | own | type
		ownBorderColor = color(1, 0.85, 0.1),
		defaultBorderColor = color(0, 0, 0, 0.85),
		countOwnPet = true,
		desaturateOthers = false,
		showCooldown = true,
		showDurationText = false,
		durationFont = DEFAULT_FONT,
		durationSize = 10,
		durationOutline = "OUTLINE",
		showStacks = true,
		stackCorner = "BOTTOMRIGHT",
		stackFont = DEFAULT_FONT,
		stackSize = 11,
		stackOutline = "OUTLINE",
		onlyOwn = false,
		useWhitelist = false,
		whitelist = {},
		useBlacklist = false,
		blacklist = {},
		minDuration = 0,
		hidePermanent = false,
		tooltips = true,
		tooltipsInCombat = false,
	})
end
Defaults.AuraGroup = auraGroup

--------------------------------------------------------------------------------
-- Per-unit schema
--------------------------------------------------------------------------------

--- Build a full unit config. `overrides` is deep-merged on top of the base.
local function unit(overrides)
	local base = {
		enabled = true,

		-- Layout (SPEC §4.1)
		width = 200,
		height = 46,
		scale = 1.0,
		alpha = 1.0,
		strata = "MEDIUM",
		anchor = {
			to = "UIParent",           -- "UIParent" or another unit key
			point = "CENTER",
			relativePoint = "CENTER",
			x = 0,
			y = 0,
		},
		detached = false,              -- party frames: opt out of group layout

		-- Off by default. The bars fill the frame exactly unless you give one a
		-- fixed height, so this backdrop is invisible in the default layout --
		-- except that it sits behind the bars and masks their own background
		-- opacity, which makes that control look broken. Turn it on when you
		-- have deliberately left space for it to show through.
		background = {
			enabled = false,
			color = color(0, 0, 0, 0.6),
			inset = 0,
		},
		border = {
			enabled = false,
			color = color(0, 0, 0, 1),
			size = 1,
		},

		-- SPEC §4.4
		health = {
			enabled = true,
			height = 0,                -- 0 = fill whatever the other bars leave
			texture = DEFAULT_BAR_TEXTURE,
			colorMode = "static",      -- static | class | reaction | gradient
			color = color(0, 0.9, 0.1),
			npcFallback = "reaction",  -- what class mode falls back to for NPCs
			bgMultiplier = 0.25,
			bgAlpha = 1,
			inverseFill = false,
			gradient = { color(1, 0, 0), color(1, 1, 0), color(0, 1, 0) },
			dimWhenDead = true,
			offlineColor = color(0.5, 0.5, 0.5),
			tapColor = color(0.6, 0.6, 0.6),
		},

		power = {
			enabled = true,
			height = 10,
			spacing = 1,
			texture = DEFAULT_BAR_TEXTURE,
			colorMode = "power",       -- power | static | class
			color = color(0.2, 0.4, 1),
			overrides = {},            -- per power token, e.g. RAGE = {r=,g=,b=}
			useOverrides = false,
			bgMultiplier = 0.25,
			bgAlpha = 1,
			hideWhenEmpty = false,
		},

		-- SPEC §4.2 — shapeshift mana. Present on every unit for schema
		-- uniformity; only ever *shown* where the generic predicate fires,
		-- which in Classic/TBC is the player in Bear/Dire Bear/Cat form.
		mana = {
			enabled = false,
			mode = "append",           -- append | reserve
			height = 8,
			spacing = 1,
			widthMode = "inherit",     -- inherit | custom
			width = 200,
			texture = DEFAULT_BAR_TEXTURE,
			color = color(0.25, 0.45, 0.95),
			bgMultiplier = 0.25,
			bgAlpha = 1,
			-- SPEC §FR-2.5. "auto" runs the fallback ticker only while the bar
			-- is visible and counts how often it corrected a value the events
			-- had not delivered; /duf profile reports that number, which is the
			-- honest way to answer the Phase 0 question about whether the
			-- fallback is needed on 2.5.6 / 1.15.9 at all.
			tickerMode = "auto",       -- auto | on | off
			tickerInterval = 0.2,
		},

		-- SPEC §4.7
		portrait = {
			mode = "none",             -- none | 2d | 3d
			placement = "inside",      -- inside | outside
			side = "LEFT",             -- outside placement side
			width = 40,
			height = 40,
			alpha = 1,
			point = "LEFT",
			relativePoint = "LEFT",
			x = 2,
			y = 0,
			camera = 0,
			cameraY = 0,
			desaturate = false,
		},

		highlight = {
			targetEnabled = true,
			targetColor = color(1, 1, 1, 0.9),
			mouseoverEnabled = true,
			mouseoverColor = color(1, 1, 1, 0.35),
			thickness = 1,
		},

		texts = {},
		auras = {
			buffs = auraGroup({ enabled = false }),
			debuffs = auraGroup({
				enabled = false,
				point = "TOPLEFT",
				relativePoint = "BOTTOMLEFT",
				y = -2,
				growthY = "DOWN",
				maxShown = 16,
				borderMode = "type",
			}),
		},
	}

	if overrides then
		ensure(overrides, base)
		return overrides
	end
	return base
end
Defaults.Unit = unit

--------------------------------------------------------------------------------
-- Per-unit default text sets
--------------------------------------------------------------------------------

local function fullTexts(healthFormat)
	return {
		text({ name = L["Name"], format = "[name]", anchorTo = "health",
			point = "LEFT", relativePoint = "LEFT", x = 4, justify = "LEFT" }),
		text({ name = L["Health"], format = healthFormat, anchorTo = "health",
			point = "RIGHT", relativePoint = "RIGHT", x = -4, justify = "RIGHT" }),
		text({ name = L["Power"], format = "[pp:cur:short]", anchorTo = "power",
			point = "RIGHT", relativePoint = "RIGHT", x = -4, justify = "RIGHT", size = 10 }),
	}
end

local function targetTexts()
	local t = {
		text({ name = L["Level"], format = "[level][shortclassification]", anchorTo = "health",
			point = "LEFT", relativePoint = "LEFT", x = 4, justify = "LEFT",
			colorMode = "difficulty" }),
		text({ name = L["Name"], format = "[name]", anchorTo = "health",
			point = "LEFT", relativePoint = "LEFT", x = 32, justify = "LEFT" }),
		text({ name = L["Health"], format = "[hp:cur:short] / [hp:max:short] [hp:perc]%",
			anchorTo = "health", point = "RIGHT", relativePoint = "RIGHT", x = -4, justify = "RIGHT" }),
		text({ name = L["Power"], format = "[pp:cur:short]", anchorTo = "power",
			point = "RIGHT", relativePoint = "RIGHT", x = -4, justify = "RIGHT", size = 10 }),
	}
	return t
end

-- SPEC §FR-8.4: derived frames ship text-light and aura-free, because their
-- values are sampled rather than pushed and the defaults should not pretend
-- otherwise.
local function derivedTexts()
	return {
		text({ name = L["Name"], format = "[name]", anchorTo = "health",
			point = "LEFT", relativePoint = "LEFT", x = 4, justify = "LEFT", size = 11 }),
		text({ name = L["Health"], format = "[hp:perc]%", anchorTo = "health",
			point = "RIGHT", relativePoint = "RIGHT", x = -4, justify = "RIGHT", size = 11 }),
	}
end

--------------------------------------------------------------------------------
-- The default profile
--------------------------------------------------------------------------------

local function buildUnits()
	local u = {}

	u.player = unit({
		width = 220, height = 48,
		anchor = { to = "UIParent", point = "TOPRIGHT", relativePoint = "CENTER", x = -180, y = -140 },
		texts = fullTexts("[hp:cur:short] / [hp:max:short]"),
		mana = { enabled = true },
		highlight = { targetEnabled = false },
	})

	u.target = unit({
		width = 220, height = 48,
		anchor = { to = "UIParent", point = "TOPLEFT", relativePoint = "CENTER", x = 180, y = -140 },
		texts = targetTexts(),
		health = { colorMode = "reaction" },
		auras = {
			buffs = auraGroup({ enabled = true, maxShown = 32, perRow = 8, rows = 4 }),
			debuffs = auraGroup({
				enabled = true, maxShown = 16, perRow = 8, rows = 2,
				point = "TOPLEFT", relativePoint = "BOTTOMLEFT", y = -2,
				growthY = "DOWN", borderMode = "type",
			}),
		},
	})

	u.targettarget = unit({
		width = 130, height = 30,
		anchor = { to = "target", point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = 0, y = -34 },
		power = { enabled = false },
		texts = derivedTexts(),
	})

	u.pet = unit({
		width = 150, height = 32,
		anchor = { to = "player", point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = 0, y = -6 },
		power = { height = 8 },
		texts = fullTexts("[hp:perc]%"),
	})

	u.focus = unit({
		width = 180, height = 40,
		anchor = { to = "UIParent", point = "CENTER", relativePoint = "CENTER", x = 0, y = 180 },
		health = { colorMode = "reaction" },
		texts = fullTexts("[hp:perc]%"),
	})

	u.focustarget = unit({
		width = 130, height = 30,
		anchor = { to = "focus", point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = 0, y = -4 },
		power = { enabled = false },
		texts = derivedTexts(),
	})

	for i = 1, 4 do
		u["party" .. i] = unit({
			width = 180, height = 40,
			anchor = { to = "UIParent", point = "TOPLEFT", relativePoint = "LEFT", x = 30, y = 120 - (i - 1) * 48 },
			health = { colorMode = "class" },
			power = { height = 8 },
			texts = fullTexts("[hp:cur:short] / [hp:max:short]"),
		})
		-- SPEC §FR-6.1: party pets ship disabled.
		u["partypet" .. i] = unit({
			enabled = false,
			width = 100, height = 20,
			anchor = { to = "party" .. i, point = "LEFT", relativePoint = "RIGHT", x = 4, y = 0 },
			power = { enabled = false },
			texts = {
				text({ name = L["Name"], format = "[name:short:10]", anchorTo = "health",
					point = "LEFT", relativePoint = "LEFT", x = 3, size = 10 }),
			},
		})
	end

	return u
end

function Defaults:BuildProfile()
	return {
		schemaVersion = Defaults.SCHEMA_VERSION,

		general = {
			-- SPEC §5.6: prefer leaving Blizzard's frames alone. Now that these
			-- clients have Edit Mode the player may be able to hide them
			-- natively, which is strictly lower risk than us touching them.
			blizzardFrames = "none",   -- none | hide
			blizzardParty = false,

			locked = true,
			gridSnap = false,
			gridSize = 8,
			nudgeStep = 1,
			nudgeStepLarge = 10,

			shortThreshold = 1000,
			shortDecimals = 1,
			percentDecimals = 0,

			derivedPollInterval = 0.25,
			errorThreshold = 5,

			unitTooltips = false,
			unitTooltipsInCombat = false,

			useClassicDurations = false,
			focusOverride = "auto",    -- auto | on | off
		},

		-- SPEC §FR-6.3 — position four frames once, not four times.
		partyGroup = {
			enabled = true,
			anchor = { to = "UIParent", point = "TOPLEFT", relativePoint = "LEFT", x = 30, y = 120 },
			growth = "DOWN",           -- DOWN | UP | RIGHT | LEFT
			spacing = 8,
			overrideSize = true,
			width = 180,
			height = 40,
			hideInRaid = true,
			showWhenSolo = false,
			showPlayer = false,        -- SPEC §FR-6.6: never rendered in the group
		},

		units = buildUnits(),
	}
end

function Defaults:BuildGlobal()
	return {
		safeMode = false,
		debug = false,
		firstRunDone = false,
	}
end

--- Fill any missing keys in a live profile. Safe to call repeatedly.
function Defaults:EnsureProfile(profile)
	local template = self:BuildProfile()
	ensure(profile, template)
	-- A unit key the user carries that we no longer ship a template for still
	-- needs the full unit schema, not just the top-level keys.
	for key, cfg in pairs(profile.units) do
		if not template.units[key] then
			ensure(cfg, unit())
		end
	end
	return profile
end

function Defaults:EnsureGlobal(global)
	return ensure(global, self:BuildGlobal())
end

--- Reset one unit to its shipped defaults, in place.
function Defaults:ResetUnit(profile, unitKey)
	local template = self:BuildProfile().units[unitKey] or unit()
	profile.units[unitKey] = template
	return profile.units[unitKey]
end
