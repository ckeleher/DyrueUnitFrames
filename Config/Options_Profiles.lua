-- Config/Options_Profiles.lua
--
-- Plan 29 — the Import / Export tab.
--
-- A sibling of AceDBOptions' Profiles tab rather than args injected into it, so
-- nothing here depends on that library's internal order numbering. It sits at
-- order 91, immediately after Profiles at 90, because that is where somebody
-- looking for this will look.
--
-- All the logic is in Core/Portable.lua. This file is the panel and one cache.

local ADDON, ns = ...
local L = ns.L
local Options = ns.Options
local Errors = ns.Errors
local Portable = ns.Portable

local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")

--------------------------------------------------------------------------------
-- Export
--
-- The string is cached against the profile name AND ns.configSerial, which
-- Core.lua bumps on every configuration change. Without the cache the ~24 ms
-- encode would run on every `get` -- and Options.lua registers a combat-queue
-- listener that calls NotifyChange while the panel is open in combat, so that
-- is not a rare path.
--------------------------------------------------------------------------------

local exportState = { profile = nil, serial = nil, text = "" }

local function exportProfileName()
	return exportState.profile or (ns.db and ns.db:GetCurrentProfile()) or "Default"
end

local function exportText()
	local name = exportProfileName()
	if exportState.text ~= "" and exportState.serial == ns.configSerial
		and exportState.cachedFor == name then
		return exportState.text
	end

	local text, message = Portable:Export(name)
	if not text then
		exportState.text, exportState.serial, exportState.cachedFor = "", nil, nil
		return message or ""
	end

	exportState.text = text
	exportState.serial = ns.configSerial
	exportState.cachedFor = name
	return text
end

local function profileValues()
	local values = {}
	if ns.db and ns.db.GetProfiles then
		for _, name in ipairs(ns.db:GetProfiles()) do values[name] = name end
	end
	if not next(values) then values.Default = "Default" end
	return values
end

--------------------------------------------------------------------------------
-- Import
--
-- Decoding on paste and applying are deliberately separate. Decode is pure --
-- it touches nothing -- so the preview below can tell the user what they are
-- about to overwrite, and with what, before the button exists to be pressed.
--------------------------------------------------------------------------------

local importState = { text = "", envelope = nil, message = nil, target = "" }

local function importIsReady()
	return importState.envelope ~= nil
end

--- The one case worth refusing before the button rather than after: a string
-- from a newer build. Migrate:Run would catch it, but the user has already
-- committed to the import by then.
local function importIsTooNew()
	local envelope = importState.envelope
	return envelope ~= nil
		and envelope.profile.schemaVersion > ns.Defaults.SCHEMA_VERSION
end

--------------------------------------------------------------------------------

function Options.BuildProfiles()
	return {
		type = "group", order = 91, name = L["Import / Export"],
		args = {
			exportHeader = { type = "header", order = 1, name = L["Export"] },
			exportExplain = {
				type = "description", order = 2,
				name = L["Turns a profile into one line of text you can paste anywhere. Click in the box below, press Ctrl+A to select it all, then Ctrl+C to copy.\n\nOnly the profile travels. Your debug and safe-mode settings do not, and neither do the heal sizes this character has learned -- those describe your gear, not your layout."],
			},
			exportProfile = {
				type = "select", order = 3, name = L["Profile to export"],
				values = profileValues,
				get = exportProfileName,
				set = function(_, value) exportState.profile = value end,
			},
			exportText = {
				type = "input", order = 4, multiline = 12, width = "full",
				name = L["Export string"],
				get = exportText,
				-- Read-only in effect. AceConfig requires a setter for `input`,
				-- and discarding the write is what keeps the box from being an
				-- editable copy of something that is generated.
				set = function() end,
			},

			importHeader = { type = "header", order = 10, name = L["Import"] },
			importExplain = {
				type = "description", order = 11,
				name = L["Paste a string below and press Accept. Nothing is changed until you press Import."],
			},
			importText = {
				type = "input", order = 12, multiline = 12, width = "full",
				name = L["Import string"],
				get = function() return importState.text end,
				set = function(_, value)
					importState.text = value or ""
					if importState.text:match("^%s*$") then
						importState.envelope, importState.message = nil, nil
						return
					end
					local envelope, message = Portable:Decode(importState.text)
					importState.envelope = envelope
					importState.message = message
					importState.target = envelope and (envelope.name or "") or ""
				end,
			},
			importError = {
				type = "description", order = 13,
				hidden = function() return importState.message == nil end,
				name = function() return "|cffff5555" .. (importState.message or "") .. "|r" end,
			},
			importPreview = {
				type = "description", order = 14,
				hidden = function() return not importIsReady() end,
				name = function()
					if not importIsReady() then return "" end
					return Portable:Describe(importState.envelope)
				end,
			},
			importTarget = {
				type = "input", order = 15, name = L["Import into profile"],
				desc = L["An existing profile is overwritten. A name that does not exist yet is created."],
				hidden = function() return not importIsReady() end,
				get = function() return importState.target end,
				set = function(_, value) importState.target = value or "" end,
			},
			importGo = {
				type = "execute", order = 16, name = L["Import"],
				hidden = function() return not importIsReady() end,
				disabled = importIsTooNew,
				-- The message names the profile about to be overwritten, so it
				-- has to be built at click time. AceConfigDialog reads
				-- `confirmText` raw rather than through GetOptionsMemberValue
				-- (AceConfigDialog-3.0.lua:769), so a function there would be
				-- handed to the popup verbatim; a `confirm` function RETURNING a
				-- string is the supported way to do this, and the string it
				-- returns becomes the confirmation text (`:783-790`).
				confirm = function()
					return string.format(
						L["This replaces every setting in profile '%s' and switches to it. Continue?"],
						importState.target ~= "" and importState.target or L["Default"])
				end,
				func = function()
					local ok, message = Portable:Apply(importState.envelope, importState.target)
					Errors:Print(ok and message or ("|cffff5555" .. tostring(message) .. "|r"))
					if ok then
						importState.text, importState.envelope = "", nil
						importState.message, importState.target = nil, ""
					end
					AceConfigRegistry:NotifyChange(ADDON)
				end,
			},
		},
	}
end
