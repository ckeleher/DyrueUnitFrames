-- Core/Defaults.lua
--
-- SPEC §5.8 — the database schema and the default profile.
--
-- Design decision worth recording: AceDB's own `defaults` mechanism is NOT
-- used for the per-unit tree. AceDB implements defaults with __index
-- metatables, which works well for flat settings and badly for user-editable
-- *lists* — a removed color rule or text element reappears on next login
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

-- Schemas 1-11 are folded into a single declarative step in Core/Migrate.lua;
-- see the header there for why, and for the rule about when collapsing is safe.
-- 12 was the first version after that collapse; 13 raises the target's buff row
-- off the combo bar added in Plan 9; 14 quiets the aura overlays (Plan 13);
-- 15 gives every text element a width mode and puts the names on "fit"
-- (Plan 6).
Defaults.SCHEMA_VERSION = 15

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

-- A table with [1] set is a user-editable list (text elements, color rules,
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

--- One sweep-line indicator on a bar (Plans 2, 10 and 17, Systems/BarSweep.lua).
--
-- All three ship OFF. They are niche readouts — the tick line means nothing to
-- most classes, the five second rule means nothing to a class with no mana, and
-- rage decay means nothing to a class without rage — and a moving line on by
-- default is intrusive.
--
-- The default colors all differ deliberately. Two of these lines can be on the
-- same bar at once, and two identical white lines crossing each other is
-- unreadable; a mana-blue reads as "this one is about mana", and a hot orange as
-- "this one is about rage".
local function sweep(direction, lineColor, extra)
	local block = {
		enabled = false,
		width = 2,
		color = lineColor,
		-- Opacity is its own setting rather than the color's alpha channel. The
		-- color picker ships without an alpha channel, so storing it there means
		-- touching the swatch silently resets it to fully opaque.
		alpha = 0.9,
		direction = direction,     -- RIGHT = left to right | LEFT = right to left
	}
	for k, v in pairs(extra or {}) do block[k] = v end
	return block
end

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
		-- How much room this text is allowed before it is cut short. `fit`
		-- measures the gap to whatever is rendered at the other end of the same
		-- widget and follows it; see the header of Elements/Text.lua for why
		-- that is the mode the name texts ship on.
		maxWidthMode = "none",         -- none | pixels | percent | fit
		maxWidth = 0,                  -- pixels, when maxWidthMode is "pixels"
		maxWidthPercent = 55,          -- of the anchor widget, when "percent"
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
		-- Both numeric overlays ship OFF (Plan 13). Stacks used to ship on at
		-- 11px, which on a 20px icon is over half the height of the art and made
		-- a full debuff grid unreadable. The information is genuinely useful, so
		-- this is a default rather than a removal: turn it back on and the 8px
		-- size below is legible instead of dominant.
		showDurationText = false,
		durationFont = DEFAULT_FONT,
		durationSize = 8,
		durationOutline = "OUTLINE",
		durationAnchor = "CENTER",     -- nine points, or ABOVE | BELOW
		durationX = 0,
		durationY = 0,
		showStacks = false,
		stackCorner = "BOTTOMRIGHT",   -- same nine points, plus ABOVE | BELOW
		stackFont = DEFAULT_FONT,
		stackSize = 8,
		stackOutline = "OUTLINE",
		stackX = 0,
		stackY = 0,
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
			-- SPEC §FR-4.1 specifies static green as the default. Class color is
			-- shipped instead: it tells you at a glance who you are looking at,
			-- and it degrades to reaction color for NPCs rather than to
			-- something meaningless. `color` below is still the green the spec
			-- asks for and is one dropdown away.
			colorMode = "class",       -- static | class | reaction | gradient
			color = color(0, 0.9, 0.1),
			-- Class colors and the game's power colors are chosen to be legible
			-- as small text on a dark background, which makes them harsh as a
			-- large block of flat fill. 0.8 takes the edge off without losing
			-- which class is which.
			brightness = 0.8,          -- scales whatever color the mode resolves to
			npcFallback = "reaction",  -- what class mode falls back to for NPCs
			bgMultiplier = 0.25,
			bgAlpha = 1,
			inverseFill = false,
			gradient = { color(1, 0, 0), color(1, 1, 0), color(0, 1, 0) },
			dimWhenDead = true,
			offlineColor = color(0.5, 0.5, 0.5),
			tapColor = color(0.6, 0.6, 0.6),
		},

		-- Plan 11. Its own top-level key rather than a block nested under
		-- `health`, because it is a registered element and the element registry
		-- keys config by configKey. The options UI puts it inside the Health tab
		-- regardless -- where a setting is stored and where it is edited are
		-- separate questions.
		--
		-- Ships ON, unlike the sweep lines below. That is what was asked for,
		-- and it is defensible on its own: a prediction is only useful in the
		-- second before a heal lands, which is not a moment anyone can reach the
		-- options panel in.
		healPrediction = {
			enabled = true,
			separateColors = true,
			-- Distinct from the health fill in hue rather than in brightness, so
			-- it still reads as "more health arriving" against a green bar, a
			-- class-colored bar or a gradient.
			directColor = color(0.1, 0.85, 0.4),
			hotColor = color(0.3, 0.6, 1),
			-- Opacity is its own setting rather than the color's alpha channel,
			-- for the reason recorded on sweep() above: the swatch ships without
			-- an alpha channel, so storing it there means touching the color
			-- silently resets it to opaque.
			alpha = 0.55,
			overflow = true,
			overflowAmount = 0.10,
			-- Plan 16. Marks the far edge when the prediction was clipped at the
			-- overflow limit, i.e. when there is more heal coming than the bar is
			-- allowed to show.
			--
			-- Only ever drawn while `overflow` is on. With overflow off the limit
			-- is the bar's own end, so every prediction on a full-health target is
			-- clipped by definition and the indicator would be permanently lit on
			-- every topped-up unit -- which is the noise someone turns overflow off
			-- to avoid. Deliberate; see Plan 16's interpretation section.
			cap = {
				enabled = true,
				-- White rather than a third hue. It has to read over the direct
				-- green and the HoT blue both, and "clipped here" is a different
				-- kind of statement from "this much healing" -- a color that
				-- joined the other two would invite reading it as a third
				-- category.
				color = color(1, 1, 1),
				width = 8,
				-- Near-opaque at the outer edge. This is the one mark on the bar
				-- that means "you are not seeing all of it", so it is the wrong
				-- thing to make subtle.
				alpha = 0.9,
			},
		},

		power = {
			enabled = true,
			height = 10,
			-- 0 so the bars tile into one solid block. Any gap shows straight
			-- through to the game world unless the frame background is on, so a
			-- separator is something to opt into rather than the default.
			spacing = 0,
			texture = DEFAULT_BAR_TEXTURE,
			colorMode = "power",       -- power | static | class
			color = color(0.2, 0.4, 1),
			brightness = 0.8,
			overrides = {},            -- per power token, e.g. RAGE = {r=,g=,b=}
			useOverrides = false,
			bgMultiplier = 0.25,
			bgAlpha = 1,
			hideWhenEmpty = false,
			-- What to do once the bar is already full. The tick keeps happening,
			-- it just has nothing to add, so whether the sweep is still wanted is
			-- a judgement call: always | mana | energy | never, where the middle
			-- two mean "keep it at max only on that kind of bar".
			tick = sweep("RIGHT", color(1, 1, 1), { atMax = "always" }),
			fsr = sweep("LEFT", color(0.45, 0.75, 1), {
				fade = 0.3,
				-- On by default. Two lines sweeping one bar in opposite
				-- directions is hard to read, and during those five seconds the
				-- mana tick has no Spirit contribution to add anyway.
				hideTick = true,
				-- Which detector starts the five-second clock. One strategy
				-- exists, so there is no dropdown yet; see BarSweep.TRIGGERS.
				trigger = "manaSpent",
			}),
			-- Plan 17. Rage decays out of combat rather than regenerating, so it
			-- gets the tick line's mirror image and never the tick line itself.
			--
			-- LEFT because the resource is draining, the same reasoning that gave
			-- the five second rule its direction. The color has to contrast with
			-- the bar it is drawn on rather than match it: Systems/Colors.lua puts
			-- rage at 0.78/0.25/0.25, so a red line would be invisible, and a hot
			-- orange also stays distinct from the white tick and blue rule lines.
			--
			-- Power bar only. The shapeshift mana bar is a mana bar by definition
			-- and can never show rage, the mirror image of why the five second rule
			-- is never on a rage bar.
			--
			-- No at-max equivalent either. The tick line's is a judgment call, but
			-- decay stopping at zero rage is a fact, so there is nothing to offer.
			decay = sweep("LEFT", color(1, 0.55, 0.3)),
		},

		-- SPEC §4.2 — shapeshift mana. Present on every unit for schema
		-- uniformity; only ever *shown* where the generic predicate fires,
		-- which in Classic/TBC is the player in Bear/Dire Bear/Cat form.
		mana = {
			enabled = false,
			mode = "append",           -- append | reserve
			height = 8,
			spacing = 0,
			widthMode = "inherit",     -- inherit | custom
			width = 200,
			texture = DEFAULT_BAR_TEXTURE,
			color = color(0.25, 0.45, 0.95),
			brightness = 1,
			bgMultiplier = 0.25,
			bgAlpha = 1,
			-- SPEC §FR-2.5. "auto" runs the fallback ticker only while the bar
			-- is visible and counts how often it corrected a value the events
			-- had not delivered; /duf profile reports that number, which is the
			-- honest way to answer the Phase 0 question about whether the
			-- fallback is needed on 2.5.6 / 1.15.9 at all.
			tickerMode = "auto",       -- auto | on | off
			tickerInterval = 0.2,
			-- What to do once the bar is already full. The tick keeps happening,
			-- it just has nothing to add, so whether the sweep is still wanted is
			-- a judgement call: always | mana | energy | never, where the middle
			-- two mean "keep it at max only on that kind of bar".
			tick = sweep("RIGHT", color(1, 1, 1), { atMax = "always" }),
			fsr = sweep("LEFT", color(0.45, 0.75, 1), {
				fade = 0.3,
				-- On by default. Two lines sweeping one bar in opposite
				-- directions is hard to read, and during those five seconds the
				-- mana tick has no Spirit contribution to add anyway.
				hideTick = true,
				-- Which detector starts the five-second clock. One strategy
				-- exists, so there is no dropdown yet; see BarSweep.TRIGGERS.
				trigger = "manaSpent",
			}),
		},

		-- SPEC §4.7
		portrait = {
			mode = "none",             -- none | 2d | 3d
			-- Beside the frame rather than behind the bars. "inside" puts the
			-- portrait under the health bar, where a flat opaque fill hides it
			-- almost completely.
			placement = "outside",     -- inside | outside
			side = "LEFT",             -- outside placement side
			-- 2D only. The game's portrait art has a circular alpha, so "square"
			-- crops to the inscribed square -- the largest fully opaque region --
			-- rather than trying to un-round the texture, which is not possible.
			shape = "square",          -- square | native
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

		-- Plan 1. Only *active* states take a slot, so combat on its own sits
		-- at position one rather than leaving a resting-shaped hole.
		indicators = {
			enabled = false,           -- true on the player; see buildUnits
			anchorTo = "health",
			point = "TOPLEFT",
			relativePoint = "TOPLEFT",
			x = 0,
			-- Raised off the name text. The name is anchored LEFT to LEFT on the
			-- health bar, so on the shipped 48px frame it is centered at -19
			-- with its top edge at -13; a 20px icon at y = 0 reaches -20 and
			-- buries the top third of it.
			--
			-- Fully clearing the text would take y = 7. 5 was chosen by eye
			-- instead: it clips the top couple of pixels, which is above the cap
			-- height of most glyphs and reads fine, and it keeps more of the
			-- icon on the bar.
			y = 5,
			size = 20,
			spacing = 2,
			alpha = 1,
			growth = "RIGHT",          -- RIGHT | LEFT | UP | DOWN
			style = "icon",            -- icon | square
			states = {
				resting = { enabled = true, color = color(1, 1, 1) },
				combat = { enabled = true, color = color(1, 1, 1) },
			},
		},

		-- Plan 9 — combo points. Present on every unit for schema uniformity,
		-- the same reasoning the comment on `mana` gives; only ever *enabled* on
		-- the target, and only ever *offered* on the player and the target.
		--
		-- Sits outside the frame's bounds, above its top edge, so it takes no
		-- slot in the bar stack and nothing inside the frame moves when it
		-- appears. hideWhenEmpty is what keeps it invisible for the eight classes
		-- that have no combo points at all, with no class table anywhere.
		combo = {
			enabled = false,           -- true on target; see buildUnits
			anchorTo = "frame",        -- frame | health | power | mana | portrait
			point = "BOTTOMLEFT",
			relativePoint = "TOPLEFT",
			x = 0,
			y = 2,
			widthMode = "inherit",     -- inherit | custom
			width = 200,
			height = 10,
			borderSize = 1,
			growth = "RIGHT",          -- RIGHT | LEFT
			-- Full magenta is (1, 0, 1) and is punishing as a block of flat fill
			-- -- the same problem health's brightness = 0.8 exists to solve. This
			-- is magenta pulled back in both saturation and value: unmistakably
			-- magenta, and it sits next to a class-colored health bar without
			-- shouting. One color picker away from anything else.
			color = color(0.72, 0.33, 0.63),
			-- Five rectangles are the CAPACITY readout, so an unspent point is
			-- drawn dark rather than blanked -- blanking it loses that.
			emptyColor = color(0.12, 0.12, 0.12, 0.9),
			borderColor = color(0, 0, 0, 1),
			hideWhenEmpty = true,
			alpha = 1,
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
			point = "LEFT", relativePoint = "LEFT", x = 4, justify = "LEFT",
			maxWidthMode = "fit" }),
		text({ name = L["Health"], format = healthFormat, anchorTo = "health",
			point = "RIGHT", relativePoint = "RIGHT", x = -4, justify = "RIGHT" }),
		text({ name = L["Power"], format = "[pp:cur:short]", anchorTo = "power",
			point = "RIGHT", relativePoint = "RIGHT", x = -4, justify = "RIGHT", size = 10 }),
	}
end

--- The shapeshift mana readout, matching the power bar's.
--
-- Anchored to the mana bar rather than to the frame, so it appears and
-- disappears with it: Elements/Text hides a text whose anchor bar is not
-- showing rather than dropping it onto the frame body.
local function manaText()
	return text({ name = L["Mana"], format = "[mana:cur:short]", anchorTo = "mana",
		point = "RIGHT", relativePoint = "RIGHT", x = -4, justify = "RIGHT", size = 10 })
end
Defaults.ManaText = manaText

local function targetTexts()
	local t = {
		text({ name = L["Level"], format = "[level][shortclassification]", anchorTo = "health",
			point = "LEFT", relativePoint = "LEFT", x = 4, justify = "LEFT",
			colorMode = "difficulty" }),
		text({ name = L["Name"], format = "[name]", anchorTo = "health",
			point = "LEFT", relativePoint = "LEFT", x = 32, justify = "LEFT",
			maxWidthMode = "fit" }),
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
			point = "LEFT", relativePoint = "LEFT", x = 4, justify = "LEFT", size = 11,
			maxWidthMode = "fit" }),
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
		texts = (function()
			-- Only the player ships with the shapeshift mana bar enabled, so it
			-- is the only unit that ships with a readout for it.
			local t = fullTexts("[hp:cur:short] / [hp:max:short]")
			t[#t + 1] = manaText()
			return t
		end)(),
		mana = { enabled = true },
		indicators = { enabled = true },
		highlight = { targetEnabled = false },
	})

	u.target = unit({
		width = 220, height = 48,
		anchor = { to = "UIParent", point = "TOPLEFT", relativePoint = "CENTER", x = 180, y = -140 },
		texts = targetTexts(),
		combo = { enabled = true },
		auras = {
			-- Raised clear of the combo bar. Both anchor to the frame's top edge,
			-- and at the shared y = 2 they overlapped outright: the bar occupies
			-- [top + 2, top + 12] and the first buff row [top + 2, top + 22].
			-- 14 is the bar's height plus its two borders plus a 2px gap.
			buffs = auraGroup({ enabled = true, maxShown = 32, perRow = 8, rows = 4, y = 14 }),
			debuffs = auraGroup({
				enabled = true, maxShown = 16, perRow = 8, rows = 2,
				point = "TOPLEFT", relativePoint = "BOTTOMLEFT", y = -2,
				growthY = "DOWN", borderMode = "type",
			}),
		},
	})

	u.targettarget = unit({
		width = 130, height = 30,
		-- Right of the target frame, vertically centered against it. LEFT to
		-- RIGHT rather than aligning tops, because the two frames are different
		-- heights (30 vs 48) and top-aligned reads as drift rather than intent.
		anchor = { to = "target", point = "LEFT", relativePoint = "RIGHT", x = 4, y = 0 },
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
					point = "LEFT", relativePoint = "LEFT", x = 3, size = 10,
					maxWidthMode = "fit" }),
			},
		})
	end

	return u
end

function Defaults:BuildProfile()
	return {
		schemaVersion = Defaults.SCHEMA_VERSION,

		general = {
			-- SPEC §5.6 ranks leaving Blizzard's frames alone above touching
			-- them, on the grounds that Edit Mode might be able to hide them
			-- natively. In practice a unit frame addon that leaves the default
			-- frames sitting on top of its own is not usable out of the box, so
			-- this ships as "hide". Set it back to "none" if you would rather
			-- drive it from Edit Mode; everything still goes through the single
			-- Compat.HideBlizzardFrame path either way.
			blizzardFrames = "hide",   -- none | hide
			blizzardParty = true,

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

--- Per-character scope (Plan 11).
--
-- Separate from `global` because everything in it is a function of THIS
-- character's gear and talents, and separate from `profile` because it is not a
-- setting -- nobody chose any of it, and sharing a profile between two
-- characters must not share one's heal sizes with the other.
--
-- Everything here is derived data with no user meaning. It is safe to discard
-- at any time: the cost of a wipe is one cast per spell to relearn, which is
-- why there is no migration for it and never will be.
function Defaults:BuildChar()
	return {
		heals = { direct = {}, periodic = {}, interval = {} },
	}
end

function Defaults:EnsureChar(char)
	return ensure(char, self:BuildChar())
end

--- Reset one unit to its shipped defaults, in place.
function Defaults:ResetUnit(profile, unitKey)
	local template = self:BuildProfile().units[unitKey] or unit()
	profile.units[unitKey] = template
	return profile.units[unitKey]
end
