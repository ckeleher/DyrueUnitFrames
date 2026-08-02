-- Core/Locale.lua
--
-- The single string table. SPEC §11.4 hedge #2: every user-facing string in
-- the addon goes through `L`, from the first string onward, so that adding a
-- locale later is filling in a table rather than a retrofit across the whole
-- codebase.
--
-- The keys ARE the enUS strings. `__index` returns the key when a translation
-- is missing, which means:
--   * enUS needs no entries at all and can never produce a nil string,
--   * a translator can extract the full string list by grepping for L["..."],
--   * a partially translated locale degrades to English per-string.
--
-- To add a locale: build a table of key -> translation and assign it in
-- SetLocale() below when GetLocale() matches.

local ADDON, ns = ...

local strings = {}

local L = setmetatable({}, {
	__index = function(_, key)
		return key
	end,
})

--- Install a translation table for the running client locale.
-- Called at file scope; kept as a function so future locales are one-liners.
local function SetLocale()
	local locale = GetLocale and GetLocale() or "enUS"
	local tbl = strings[locale]
	if not tbl then return end
	for key, value in pairs(tbl) do
		rawset(L, key, value)
	end
end

-- enUS is the identity mapping and is deliberately absent from `strings`.
-- Future locales go here, e.g.:
--   strings.deDE = { ["Player"] = "Spieler", ... }

SetLocale()

ns.L = L
ns.locales = strings
