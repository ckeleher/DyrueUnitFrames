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

local steps = {
	-- [1] = function(profile) ... return profile end,
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
