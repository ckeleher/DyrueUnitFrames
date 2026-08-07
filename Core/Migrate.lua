-- Core/Migrate.lua
--
-- SPEC §5.8 — versioned config migration.
--
-- Rules, in order of importance:
--   1. Forward only. Never a jump backwards.
--   2. Never mutate the live table until the whole chain succeeds.
--   3. On failure, keep the original under DyrueUnitFramesDB.backup, load
--      defaults, and say so plainly. Never silently discard a layout somebody
--      spent an hour on.

local ADDON, ns = ...
local L = ns.L

local Migrate = {}
ns.Migrate = Migrate

local Defaults = ns.Defaults
local Errors = ns.Errors

--------------------------------------------------------------------------------
-- Legacy defaults
--
-- Schemas 1 through 11 were ten separate procedural steps, added one per
-- default change over a single afternoon. Several existed only to undo an
-- earlier one -- target of target moved left and then right, the state
-- indicators were raised to 10 and then brought down to 5 -- so the chain read
-- as a transcript of the session rather than as a description of the schema.
--
-- Almost all of it was the same shape: "this key used to default to X, it now
-- defaults to Y, move it if it is still X". That does not need to be
-- procedural, and it does not need one step per change. Listing EVERY
-- historical value a key has defaulted to means one pass brings a profile up to
-- date from any prior version, and the undo-pairs collapse into a list --
-- { 0, 10 } -> 5, rather than two steps fighting each other.
--
-- Three properties this relies on:
--
--   * idempotent, so running it twice changes nothing the second time;
--   * order-independent, so no rule depends on another having run;
--   * it runs BEFORE Defaults:EnsureProfile, so a key that did not exist in the
--     old schema is simply absent here and gets the current default filled in
--     afterwards. Only values actually present are ever rewritten, which is
--     what makes "arriving from version 1" and "arriving from version 9" both
--     land in the right place without either being special-cased.
--------------------------------------------------------------------------------

-- Everything at or below this version is handled by the single collapsed step
-- below. Raise it and fold the new steps in next time the chain gets long.
--
-- Collapsing is only safe once every profile in existence has been carried past
-- the point being collapsed, because the version number is the sole record of
-- what a profile has already had done to it. That is what Migrate:RunAll is
-- for, and it is why it shipped first.
local COLLAPSED_THROUGH = 11

-- Units whose health bar shipped as "reaction" while every other unit shipped
-- static green.
local REACTION_BY_DEFAULT = { target = true, focus = true }

local function isSpecGreen(c)
	return c and c.r == 0 and c.g == 0.9 and c.b == 0.1
end

local function isDefaultBackdrop(c)
	return c and c.r == 0 and c.g == 0 and c.b == 0 and c.a == 0.6
end

--- Per-unit rules. `old` lists every value this key has ever defaulted to.
local UNIT_RULES = {
	-- Bars, from Blizzard's gradient statusbar to a flat fill.
	{ path = { "health", "texture" }, old = { "Blizzard" }, new = "Dyrue Flat" },
	{ path = { "power", "texture" }, old = { "Blizzard" }, new = "Dyrue Flat" },
	{ path = { "mana", "texture" }, old = { "Blizzard" }, new = "Dyrue Flat" },

	-- The 1px gap, which became a slit through to the world once the backdrop
	-- was turned off.
	{ path = { "power", "spacing" }, old = { 1 }, new = 0 },
	{ path = { "mana", "spacing" }, old = { 1 }, new = 0 },

	-- Dimmed. The shapeshift mana bar is deliberately absent from this list:
	-- its color is one the user picks rather than one the game hands us.
	{ path = { "health", "brightness" }, old = { 1 }, new = 0.8 },
	{ path = { "power", "brightness" }, old = { 1 }, new = 0.8 },

	-- The backdrop that was masking the bar background opacity controls. Only
	-- the untouched black-at-60%: a re-colored one was chosen deliberately.
	{
		path = { "background", "enabled" }, old = { true }, new = false,
		when = function(cfg)
			return isDefaultBackdrop(cfg.background and cfg.background.color)
		end,
	},

	-- Health color. The old default differed by unit, so this is two rules.
	{
		path = { "health", "colorMode" }, old = { "reaction" }, new = "class",
		units = REACTION_BY_DEFAULT,
	},
	{
		path = { "health", "colorMode" }, old = { "static" }, new = "class",
		exceptUnits = REACTION_BY_DEFAULT,
		when = function(cfg) return isSpecGreen(cfg.health and cfg.health.color) end,
	},

	-- Portraits, from behind the bars to beside the frame.
	{ path = { "portrait", "placement" }, old = { "inside" }, new = "outside" },

	-- State indicators: shipped at 0, briefly 10, settled at 5. One line.
	{
		path = { "indicators", "y" }, old = { 0, 10 }, new = 5,
		when = function(cfg)
			local i = cfg.indicators
			return i and i.point == "TOPLEFT" and i.relativePoint == "TOPLEFT" and i.x == 0
		end,
	},
}

--- Rules against profile.general.
local GENERAL_RULES = {
	{ path = { "blizzardFrames" }, old = { "none" }, new = "hide" },
	{ path = { "blizzardParty" }, old = { false }, new = true },
}

--- Walk to the table holding the final key of `path`, or nil if it is absent.
local function container(root, path)
	local node = root
	for i = 1, #path - 1 do
		node = node[path[i]]
		if type(node) ~= "table" then return nil end
	end
	return node
end

local function applyRule(root, cfg, rule)
	local parent = container(root, rule.path)
	if not parent then return end

	local key = rule.path[#rule.path]
	local value = parent[key]

	for i = 1, #rule.old do
		if value == rule.old[i] then
			if not rule.when or rule.when(cfg) then
				parent[key] = rule.new
			end
			return
		end
	end
end

--------------------------------------------------------------------------------
-- The two changes that are not "one key, old value to new value"
--------------------------------------------------------------------------------

--- Text elements are a user-owned list, which EnsureProfile seeds once and then
-- leaves alone -- that is what makes deleting one stick. So a new default text
-- has to be appended here or it never reaches an existing profile.
local function appendManaText(cfg)
	if not (cfg.mana and cfg.mana.enabled) then return end
	if type(cfg.texts) ~= "table" then return end

	for i = 1, #cfg.texts do
		if cfg.texts[i] and cfg.texts[i].anchorTo == "mana" then return end
	end

	cfg.texts[#cfg.texts + 1] = Defaults.ManaText()
end

--- Target of target: five anchor fields have to match together rather than one
-- key at a time. Both historical shapes are recognized -- below the target
-- frame, and the interim left-side position -- and either lands on the right.
local function moveTargetOfTarget(profile)
	local cfg = profile.units and profile.units.targettarget
	local anchor = cfg and cfg.anchor
	if not anchor or anchor.to ~= "target" then return end

	local below = anchor.point == "TOPLEFT" and anchor.relativePoint == "BOTTOMLEFT"
		and anchor.x == 0 and anchor.y == -34
	local left = anchor.point == "RIGHT" and anchor.relativePoint == "LEFT"
		and anchor.x == -4 and anchor.y == 0

	if below or left then
		anchor.point = "LEFT"
		anchor.relativePoint = "RIGHT"
		anchor.x = 4
		anchor.y = 0
	end
end

--------------------------------------------------------------------------------
-- The collapsed step
--------------------------------------------------------------------------------

local function collapsed(profile)
	for unitKey, cfg in pairs(profile.units or {}) do
		if type(cfg) == "table" then
			for i = 1, #UNIT_RULES do
				local rule = UNIT_RULES[i]
				local applies = (not rule.units or rule.units[unitKey])
					and (not rule.exceptUnits or not rule.exceptUnits[unitKey])
				if applies then applyRule(cfg, cfg, rule) end
			end
			appendManaText(cfg)
		end
	end

	local general = profile.general
	if type(general) == "table" then
		for i = 1, #GENERAL_RULES do
			applyRule(general, general, GENERAL_RULES[i])
		end
	end

	moveTargetOfTarget(profile)
	return profile
end

--------------------------------------------------------------------------------
-- Incremental steps
--
-- steps[n] migrates a profile at schemaVersion n to n+1, for anything ABOVE
-- COLLAPSED_THROUGH. Adding keys never needs a step -- EnsureProfile fills
-- those in. Steps are for renames, restructures and changed default values.
--------------------------------------------------------------------------------

--- 12 -> 13. Plan 9 put a combo-point bar on the target frame's top edge, where
-- the buff row already was: both anchored BOTTOMLEFT to TOPLEFT at y = 2, so
-- the bar's [top + 2, top + 12] sat inside the first buff row's
-- [top + 2, top + 22]. hideWhenEmpty contains it -- the overlap only exists
-- while points are up -- but that is exactly when the bar is being looked at,
-- so the shipped default is fixed rather than left for the user to find.
--
-- Only the EXACT untouched default moves. Anyone who has positioned their
-- target buffs keeps their position, which is the same rule steps 7-10 followed
-- before the collapse.
local function raiseTargetBuffs(profile)
	local buffs = profile.units and profile.units.target
		and profile.units.target.auras and profile.units.target.auras.buffs
	if type(buffs) ~= "table" then return profile end

	if buffs.anchorTo == "frame" and buffs.point == "BOTTOMLEFT"
		and buffs.relativePoint == "TOPLEFT" and buffs.x == 0 and buffs.y == 2 then
		buffs.y = 14
	end

	return profile
end

--- 13 -> 14. Stack counts shipped ON at 11px. On a 20px icon an outlined
-- two-digit number is most of the art, and a full 8x2 debuff grid came out
-- unreadable (Plan 13). Both numeric overlays now ship off, at 8px, with a
-- configurable anchor.
--
-- Same rule as raiseTargetBuffs: only the EXACT untouched default moves. For a
-- boolean that is not enough on its own -- showStacks == true is equally what a
-- deliberate choice looks like -- so "untouched" is the whole shipped tuple,
-- toggle and size and corner together. Anyone who has already tuned any one of
-- the three keeps all three.
--
-- Duration text is the other way round: it shipped OFF, so a profile carrying
-- `true` set it deliberately and the toggle is left exactly where it is. Only
-- its placement is pinned, because there was no setting to have chosen before
-- now and the new CENTER default would otherwise silently move text that has
-- been sitting below the icon since 1.0.
local function quietAuraOverlays(profile)
	local units = profile.units
	if type(units) ~= "table" then return profile end

	for _, u in pairs(units) do
		local auras = type(u) == "table" and u.auras
		if type(auras) == "table" then
			for _, key in ipairs({ "buffs", "debuffs" }) do
				local g = auras[key]
				if type(g) == "table" then
					if g.showStacks == true and g.stackSize == 11
						and g.stackCorner == "BOTTOMRIGHT" then
						g.showStacks = false
						g.stackSize = 8
					end

					if g.durationSize == 10 then g.durationSize = 8 end

					-- Runs before EnsureProfile, so nil here reliably means
					-- "this profile predates the setting" rather than "the key
					-- has been filled in with the new default already".
					if g.showDurationText and g.durationAnchor == nil then
						g.durationAnchor = "BELOW"
					end
				end
			end
		end
	end

	return profile
end

--- 14 -> 15. Plan 6: a long name ran straight under the health numbers,
-- because a text element had no width limit unless somebody typed a pixel
-- figure into one. The shipped name texts now sit on `fit`, which measures the
-- gap to whatever is rendered at the other end of the same bar.
--
-- Unlike most new keys this cannot be left to EnsureProfile. `texts` is a
-- user-owned LIST, and Core/Defaults.lua's `ensure` deliberately does not
-- descend into lists -- that is what makes a deleted text stay deleted. So a
-- new key inside a text element reaches an existing profile only from here,
-- and every text has to be written, not just the names.
--
-- Three cases:
--   * a pixel width is already set, which is a deliberate choice nobody
--     arrives at by accident: it keeps working, now spelled `pixels`;
--   * an untouched shipped name text: `fit`, which is the actual change;
--   * everything else: `none`, which is exactly what it did before.
--
-- "Untouched" is the format AND the anchor together, the same rule steps 12 and
-- 13 used. A name text somebody has re-anchored or re-worded is a layout they
-- chose, and silently clipping it is the sort of surprise this whole file
-- exists to avoid.
local SHIPPED_NAME_FORMATS = {
	["[name]"] = true,
	["[name:short:10]"] = true,       -- party pets, which ship pre-shortened
}

local function textWidthModes(profile)
	local units = profile.units
	if type(units) ~= "table" then return profile end

	for _, u in pairs(units) do
		local texts = type(u) == "table" and u.texts
		if type(texts) == "table" then
			for i = 1, #texts do
				local t = texts[i]
				if type(t) == "table" then
					if t.maxWidthPercent == nil then t.maxWidthPercent = 55 end

					if t.maxWidthMode == nil then
						if (t.maxWidth or 0) > 0 then
							t.maxWidthMode = "pixels"
						elseif SHIPPED_NAME_FORMATS[t.format] and t.anchorTo == "health" then
							t.maxWidthMode = "fit"
						else
							t.maxWidthMode = "none"
						end
					end
				end
			end
		end
	end

	return profile
end

local steps = {
	[12] = raiseTargetBuffs,
	[13] = quietAuraOverlays,
	[14] = textWidthModes,
}

Migrate.steps = steps
Migrate.COLLAPSED_THROUGH = COLLAPSED_THROUGH
Migrate.collapsedStep = collapsed

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

--- Migrate every profile in the database, not just the active one.
--
-- An unmigrated profile sitting in the saved variables is invisible until
-- somebody selects it. At that point `Defaults:EnsureProfile` fills its missing
-- keys and the stale VALUES it still carries start looking deliberate -- an
-- addon several versions out of date, with no error and nothing to explain it.
--
-- One profile failing must not stop the others, so each is run independently
-- and reported by name.
--
-- @param db table the AceDB object
-- @param sv table the raw saved-variable root, for backup storage
-- @return number migrated, number failed
function Migrate:RunAll(db, sv)
	if not db then return 0, 0 end

	local profiles = db.profiles
	if type(profiles) ~= "table" then
		-- Older AceDB, or a stub. Do the active profile rather than nothing.
		local ok, message = self:Run(db.profile, sv)
		if message then Errors:Print(message) end
		return (ok and message) and 1 or 0, ok and 0 or 1
	end

	local active = db.GetCurrentProfile and db:GetCurrentProfile() or nil
	local migrated, failed = 0, 0

	for name, profile in pairs(profiles) do
		if type(profile) == "table" then
			local ok, message = self:Run(profile, sv, name)
			if not ok then
				failed = failed + 1
			elseif message then
				migrated = migrated + 1
				-- Only the active profile's migration is worth a chat line on
				-- login; the rest are noted together below.
				if name == active then Errors:Print(message) end
			end
		end
	end

	if migrated > 0 then
		local others = migrated - ((active and profiles[active]) and 1 or 0)
		if others > 0 then
			Errors:Print(string.format(
				L["%d other profile(s) were also brought up to date."], others))
		end
	end

	return migrated, failed
end

--- Migrate a profile in place, or fall back to defaults on failure.
-- @param profile table the live AceDB profile
-- @param db table the raw saved-variable root, for backup storage
-- @param name string|nil profile name, for reporting and backup keys
-- @return boolean ok, string|nil message
function Migrate:Run(profile, db, name)
	if type(profile) ~= "table" then return true, nil end
	local target = Defaults.SCHEMA_VERSION
	local current = profile.schemaVersion

	-- A profile with no version is either brand new (empty) or predates
	-- versioning. Empty means new; anything else is treated as version 1.
	if current == nil then
		current = next(profile) == nil and target or 1
		profile.schemaVersion = current
	end

	if current == target then
		return true, nil
	end

	if current > target then
		-- The user has run a newer build of the addon. Downgrading a config is
		-- not something we can do correctly, so we do not pretend to.
		return false, string.format(
			L["Profile '%s' was saved by DyrueUnitFrames schema %d, but this build only understands %d. It has been left untouched; upgrade the addon or switch profiles."],
			name or L["Default"], current, target)
	end

	-- Work on a copy. The live table is only replaced once every step passes.
	local work = Defaults.DeepCopy(profile)
	local version = current

	-- Anything at or below the collapse point is handled by one step, which
	-- knows every historical value of every key it touches.
	if version <= COLLAPSED_THROUGH then
		local ok, result = pcall(collapsed, work)
		if not ok then
			return self:Fail(profile, db, name, string.format(
				L["Migration from schema %d failed: %s"], version, tostring(result)))
		end
		work = result or work
		version = COLLAPSED_THROUGH + 1
		work.schemaVersion = version
	end

	while version < target do
		local step = steps[version]
		if not step then
			return self:Fail(profile, db, name, string.format(
				L["No migration path from schema %d to %d."], version, version + 1))
		end
		local ok, result = pcall(step, work)
		if not ok then
			return self:Fail(profile, db, name, string.format(
				L["Migration from schema %d failed: %s"], version, tostring(result)))
		end
		work = result or work
		version = version + 1
		work.schemaVersion = version
	end

	-- Commit: replace the live table's contents in place so AceDB keeps its
	-- reference.
	for k in pairs(profile) do profile[k] = nil end
	for k, v in pairs(work) do profile[k] = v end

	return true, string.format(
		L["Profile '%s' migrated from schema %d to %d."], name or L["Default"], current, target)
end

--- Preserve the unmigratable profile and start from defaults.
function Migrate:Fail(profile, db, name, message)
	if db then
		db.backup = db.backup or {}
		-- Keyed by profile AND time. Two profiles failing in the same second
		-- would otherwise collide, and the backup would lose one of the two
		-- things it exists to preserve.
		local stamp = date and date("%Y-%m-%d %H:%M:%S") or tostring(time and time() or 0)
		db.backup[string.format("%s @ %s", name or L["Default"], stamp)] =
			Defaults.DeepCopy(profile)
	end

	for k in pairs(profile) do profile[k] = nil end
	Defaults:EnsureProfile(profile)
	profile.schemaVersion = Defaults.SCHEMA_VERSION

	local full = (message or L["Migration failed."]) .. " " ..
		L["Your previous settings have been kept in DyrueUnitFramesDB.backup and defaults have been loaded."]
	Errors:Print("|cffff5555" .. full .. "|r")
	return false, full
end
