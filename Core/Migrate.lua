-- Core/Migrate.lua
--
-- SPEC §5.8 — versioned config migration.
--
-- Rules, in order of importance:
--   1. Forward only. One step at a time, never a jump.
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
-- Migration steps
--
-- steps[n] migrates a profile at schemaVersion n to schemaVersion n+1.
-- Each receives a *working copy* and mutates it freely; it either returns the
-- table or raises, and raising is safe because the copy is thrown away.
--
-- Adding keys does not need a step: Defaults:EnsureProfile fills those in.
-- Steps exist for renames, restructures and value-format changes only.
--------------------------------------------------------------------------------

local BARS = { "health", "power", "mana" }

local steps = {
	--- 1 -> 2: the cosmetic defaults changed.
	--
	-- Bars went from Blizzard's gradient statusbar to a flat fill, the 1px gap
	-- between bars went to 0, and the frame backdrop went from on to off. Those
	-- are Defaults changes, which means they only reach a NEW profile --
	-- EnsureProfile fills missing keys and never overwrites stored ones. Without
	-- this step an existing profile keeps the old look on every frame forever.
	--
	-- Only values still matching the v1 default are touched. If you deliberately
	-- picked Blizzard's texture or set a deliberate gap, that survives; the
	-- trade is that a deliberate choice which happens to equal the old default
	-- gets moved with everything else, and there is no way to tell those apart
	-- after the fact.
	[1] = function(profile)
		for _, cfg in pairs(profile.units or {}) do
			for i = 1, #BARS do
				local bar = cfg[BARS[i]]
				if bar and bar.texture == "Blizzard" then
					bar.texture = "Dyrue Flat"
				end
			end

			if cfg.power and cfg.power.spacing == 1 then cfg.power.spacing = 0 end
			if cfg.mana and cfg.mana.spacing == 1 then cfg.mana.spacing = 0 end

			-- Only the untouched black-at-60% backdrop, since that is the one
			-- that was silently masking the bar background opacity controls.
			local background = cfg.background
			if background and background.enabled == true then
				local c = background.color
				if c and c.r == 0 and c.g == 0 and c.b == 0 and c.a == 0.6 then
					background.enabled = false
				end
			end
		end
		return profile
	end,

	--- 2 -> 3: Blizzard's own unit frames are hidden by default now, party
	-- frames included.
	--
	-- Same caveat as step 1: "none" was both the old default and a legitimate
	-- choice, and nothing distinguishes them after the fact, so a deliberate
	-- "leave them alone" gets moved too. It is one setting under General and
	-- it is trivially set back.
	[2] = function(profile)
		local general = profile.general
		if general then
			if general.blizzardFrames == "none" then
				general.blizzardFrames = "hide"
			end
			if general.blizzardParty == false then
				general.blizzardParty = true
			end
		end
		return profile
	end,
}

Migrate.steps = steps

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

--- Migrate a profile in place, or fall back to defaults on failure.
-- @param profile table the live AceDB profile
-- @param db table the raw saved-variable root, for backup storage
-- @return boolean ok, string|nil message
function Migrate:Run(profile, db)
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
			L["This profile was saved by DyrueUnitFrames schema %d, but this build only understands %d. Settings have been left untouched; upgrade the addon or switch profiles."],
			current, target)
	end

	-- Work on a copy. The live table is only replaced once every step passes.
	local work = Defaults.DeepCopy(profile)
	local version = current

	while version < target do
		local step = steps[version]
		if not step then
			return self:Fail(profile, db, string.format(
				L["No migration path from schema %d to %d."], version, version + 1))
		end
		local ok, result = pcall(step, work)
		if not ok then
			return self:Fail(profile, db, string.format(
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

	return true, string.format(L["Settings migrated from schema %d to %d."], current, target)
end

--- Preserve the unmigratable profile and start from defaults.
function Migrate:Fail(profile, db, message)
	if db then
		db.backup = db.backup or {}
		db.backup[date and date("%Y-%m-%d %H:%M:%S") or tostring(time and time() or 0)] =
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
