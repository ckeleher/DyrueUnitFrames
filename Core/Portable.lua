-- Core/Portable.lua
--
-- Plan 29 — a profile as one pasteable string.
--
-- The third file about the shape of a stored profile, after Defaults.lua (what
-- one contains) and Migrate.lua (how an old one becomes a current one). This
-- one is how one leaves the client and comes back.
--
-- Pipeline, in both directions:
--
--   profile -> envelope -> AceSerializer -> LibDeflate zlib -> EncodeForPrint
--
-- SECURITY, and the reason AceSerializer is a dependency rather than eighty
-- lines of our own: an import string is written by a stranger. The obvious
-- naive serializer -- emit a Lua table literal, read it back with loadstring --
-- hands arbitrary code execution to whoever wrote the string. AceSerializer's
-- Deserialize is a gmatch over a fixed grammar with no loadstring, no load and
-- no pcall of user data anywhere in it. Do not "simplify" this into a table
-- literal at any point in the future.
--
-- Everything that can fail returns nil-or-false plus a message. Nothing here
-- errors on bad input, because bad input is the expected case.

local ADDON, ns = ...
local L = ns.L

local Portable = {}
ns.Portable = Portable

local Compat = ns.Compat
local Defaults = ns.Defaults
local Errors = ns.Errors
local Migrate = ns.Migrate

local AceSerializer = LibStub("AceSerializer-3.0")
local LibDeflate = LibStub("LibDeflate")

local type, pairs = type, pairs

--------------------------------------------------------------------------------
-- The envelope
--------------------------------------------------------------------------------

-- The container format, NOT the profile schema version. It starts at 1 rather
-- than borrowing Defaults.SCHEMA_VERSION's 17 precisely so the two can never be
-- confused: this number changes only if the CONTAINER changes -- a different
-- compressor, a different prefix, a new field a reader must understand rather
-- than ignore. What is inside the container is versioned by the profile's own
-- schemaVersion, and migrated by Migrate.lua like any other profile.
Portable.ENVELOPE_VERSION = 1

Portable.PREFIX = "!DUF:1!"

-- LibDeflate:EncodeForPrint's alphabet: 26 lowercase, 26 uppercase, 10 digits,
-- and the two parentheses. No "|" for WoW's escape-code parser to eat, and no
-- whitespace for a forum to reflow.
local BODY_PATTERN = "^%!DUF%:1%!([0-9a-zA-Z%(%)]+)$"

-- Decompression bomb guard. DEFLATE's maximum ratio is 1032:1 and LibDeflate
-- offers no output cap, so the only lever is the input, and it has to be
-- checked BEFORE DecompressZlib is called -- a cap that runs afterwards is
-- decoration. 32 KB bounds the output at roughly 33 MB: a hitch, not a crash.
--
-- For scale, measured against the shipped default profile: a real export string
-- is 4,205 characters, and a deliberately pathological profile -- every number
-- in the tree perturbed so no two units share a compressible block -- is
-- 13,924. The cap is 7.6x the first and 2.3x the second.
Portable.MAX_STRING = 32 * 1024

-- Passed explicitly, and the number matters. LibDeflate picks a level from the
-- input size when none is given, and the rule is level 3 for anything over
-- 64 KB; our payload is 85 KB, so the default is the worst case on offer.
-- Measured: level 3 gives 7,124 characters in 7.6 ms, level 9 gives 4,205 in
-- 19.7 ms. 2,900 characters for 12 ms on an explicit button press.
local COMPRESS_LEVEL = 9

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------

--- Encode a profile as a printable string.
--
-- Only the `profile` scope travels. Not `global`, which is safeMode / debug /
-- firstRunDone -- session state rather than settings. Not `char`, which is
-- Plan 11's learned heal sizes: Core/Defaults.lua's BuildChar header already
-- argues that sharing a profile must not carry one character's heal numbers
-- onto another's gear, and shipping them to a stranger's client is that same
-- mistake with a wider blast radius.
--
-- @param profileName string|nil  a profile name, or nil for the active one
-- @return string|nil, string|nil  the export string, or nil and a message
function Portable:Export(profileName)
	if not ns.db then return nil, L["No profile database is loaded yet."] end

	local source
	if profileName and profileName ~= ns.db:GetCurrentProfile() then
		source = ns.db.profiles and ns.db.profiles[profileName]
	else
		source = ns.db.profile
		profileName = ns.db:GetCurrentProfile()
	end

	if type(source) ~= "table" then
		return nil, string.format(L["No profile named '%s'."], tostring(profileName))
	end

	-- Fill a COPY, never the original. Migrate:RunAll brings every profile up to
	-- date at load, but Defaults:EnsureProfile runs on the active one alone and
	-- deliberately so (see Core/Core.lua) -- an inactive profile is current but
	-- sparse. Ensuring a copy means the string always carries a complete profile
	-- whatever it was taken from, without bloating the saved variables to
	-- achieve it.
	local copy = Defaults:EnsureProfile(Defaults.DeepCopy(source))

	local envelope = {
		version = Portable.ENVELOPE_VERSION,
		addon = ns.version,
		flavor = Compat.flavor,
		name = profileName,
		profile = copy,
	}

	local payload = AceSerializer:Serialize(envelope)
	local compressed = LibDeflate:CompressZlib(payload, { level = COMPRESS_LEVEL })
	return Portable.PREFIX .. LibDeflate:EncodeForPrint(compressed)
end

--------------------------------------------------------------------------------
-- Import: decode
--------------------------------------------------------------------------------

--- Turn a pasted string back into an envelope, or explain why it cannot.
--
-- Six gates, cheapest first. Nothing is applied and nothing is touched -- this
-- function is pure, so the options panel can decode on paste and show the user
-- what they have before the Import button is ever pressed.
--
-- @param text string
-- @return table|nil envelope, string|nil message
function Portable:Decode(text)
	if type(text) ~= "string" or text == "" then
		return nil, L["Paste an export string first."]
	end

	-- The alphabet contains no whitespace, so stripping ALL of it anywhere in
	-- the string cannot destroy information -- and it forgives a forum or a chat
	-- client that reflowed the paste into lines.
	local body = text:gsub("%s+", ""):match(BODY_PATTERN)
	if not body then
		return nil, L["That does not look like a Dyrue Unit Frames export string."]
	end

	-- Before anything is decompressed. See MAX_STRING.
	if #body > Portable.MAX_STRING then
		return nil, string.format(
			L["That string is %d characters, over the %d limit. It is not one of ours."],
			#body, Portable.MAX_STRING)
	end

	-- The three decode stages fail for reasons that are real but not actionable
	-- by the person reading the message, so they collapse into one line and the
	-- specifics go to the debug log.
	--
	-- These are the first callers of Errors:Debug in the addon. The function and
	-- the /duf debug toggle behind it have both existed since 1.0 with nothing
	-- ever calling it, so until now the command set a flag that nothing read.
	-- Deliberately not localized: it names an internal stage, and the person who
	-- needs it is whoever is reading this file.
	local damaged = L["That string is damaged or incomplete. Ask for it again."]

	local raw = LibDeflate:DecodeForPrint(body)
	if not raw then
		Errors:Debug("Portable: DecodeForPrint rejected the body")
		return nil, damaged
	end

	-- DecompressZlib, not DecompressDeflate. Raw deflate carries no integrity
	-- check at all, so a truncated paste decompresses into something plausible;
	-- the zlib framing costs 6 bytes and verifies an Adler-32 over the result.
	local payload = LibDeflate:DecompressZlib(raw)
	if not payload then
		Errors:Debug("Portable: DecompressZlib failed (bad header or checksum)")
		return nil, damaged
	end

	local ok, envelope = AceSerializer:Deserialize(payload)
	if not ok then
		Errors:Debug("Portable: Deserialize failed: " .. tostring(envelope))
		return nil, damaged
	end

	if type(envelope) ~= "table" then
		return nil, damaged
	end

	if envelope.version ~= Portable.ENVELOPE_VERSION then
		return nil, string.format(
			L["That string is in export format %s; this build reads format %d."],
			tostring(envelope.version), Portable.ENVELOPE_VERSION)
	end

	local profile = envelope.profile
	if type(profile) ~= "table" or type(profile.units) ~= "table"
		or type(profile.schemaVersion) ~= "number" then
		return nil, L["That string decoded, but it does not contain a profile."]
	end

	return envelope
end

--- One-line summary of a decoded envelope, for the panel's preview.
-- @return string
function Portable:Describe(envelope)
	local profile = envelope.profile
	local units = 0
	for _ in pairs(profile.units) do units = units + 1 end

	local lines = {
		string.format(L["Profile: |cffffcc00%s|r"], tostring(envelope.name or L["Default"])),
		string.format(L["From: DyrueUnitFrames v%s on %s"],
			tostring(envelope.addon or "?"), tostring(envelope.flavor or "?")),
		string.format(L["Contains: %d units"], units),
	}

	local schema = profile.schemaVersion
	local target = Defaults.SCHEMA_VERSION
	if schema > target then
		lines[#lines + 1] = "|cffff5555" .. string.format(
			L["Settings version %d, but this build only understands %d. This string cannot be imported; upgrade the addon."],
			schema, target) .. "|r"
	elseif schema < target then
		lines[#lines + 1] = "|cffffcc00" .. string.format(
			L["Settings version %d; it will be brought up to %d on import."],
			schema, target) .. "|r"
	else
		lines[#lines + 1] = string.format(L["Settings version %d, the current one."], schema)
	end

	return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Import: apply
--------------------------------------------------------------------------------

--- Write a decoded envelope into a profile.
--
-- The ordering here is the whole safety argument, so it is spelled out:
--
--   1. Migrate the envelope's OWN copy. Migrate:Run is given `work`, never the
--      live table, so both of its failure modes are harmless. A schema newer
--      than ours returns false and touches nothing (a v1.1 string arriving at a
--      v1.0 client -- the failure this feature will actually produce). A step
--      that throws routes through Migrate:Fail, which wipes and defaults the
--      table it was given -- our copy, which we then discard.
--   2. Ensure, so anything the string predates gets today's default.
--   3. Only now switch profiles and replace the live table's CONTENTS. In
--      place, because AceDB holds that table by reference and swapping it would
--      strand AceDB's copy.
--   4. Hand off to OnProfileChanged, which already does everything that has to
--      follow a profile's contents changing.
--
-- @param envelope table  from Portable:Decode
-- @param targetName string|nil  profile to write into; defaults to the active one
-- @return boolean ok, string|nil message
function Portable:Apply(envelope, targetName)
	if not ns.db then return false, L["No profile database is loaded yet."] end
	if type(envelope) ~= "table" or type(envelope.profile) ~= "table" then
		return false, L["Nothing to import."]
	end

	targetName = targetName or ns.db:GetCurrentProfile()
	if type(targetName) ~= "string" or targetName:match("^%s*$") then
		return false, L["Give the profile a name."]
	end

	-- `work` is already ours: Deserialize built it from the string and nothing
	-- else holds a reference. Migrating it in place is safe.
	local work = envelope.profile

	-- db = nil, so Migrate:Fail writes no backup. There is nothing worth
	-- preserving in a string the user still has in front of them.
	local ok, message = Migrate:Run(work, nil, targetName)
	if not ok then
		return false, message
	end
	Defaults:EnsureProfile(work)

	if targetName ~= ns.db:GetCurrentProfile() then
		-- Creates the profile if it does not exist, and fires OnProfileChanged
		-- on the way in. That runs against whatever the profile held before this
		-- import, which is correct and briefly visible; the replacement below
		-- and its own OnProfileChanged land immediately after.
		ns.db:SetProfile(targetName)
	end

	local live = ns.db.profile
	for k in pairs(live) do live[k] = nil end
	for k, v in pairs(work) do live[k] = v end

	-- Everything that has to follow: re-migrate (a no-op now), re-ensure, reset
	-- the error threshold, reapply the focus override, RefreshAll -- which
	-- queues every frame through CombatQueue, so an import in combat is safe
	-- with no gate of its own -- reapply the Blizzard-frame setting, and notify
	-- AceConfig. addon:OnProfileReset is the same wipe-then-OnProfileChanged
	-- shape, so this is an established pattern in Core.lua rather than a new one.
	ns.addon:OnProfileChanged()

	return true, string.format(L["Imported into profile '%s'."], targetName)
end
