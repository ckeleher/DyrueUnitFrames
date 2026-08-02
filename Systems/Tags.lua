-- Systems/Tags.lua
--
-- SPEC §4.3.2 — the declarative tag vocabulary.
--
-- No loadstring, no user Lua, no eval. A format string is tokenised ONCE into
-- a compiled segment list and never re-parsed; rendering walks that list.
-- Each provider declares which events invalidate it, so a UNIT_POWER_UPDATE
-- re-renders only the text elements that actually contain power tags
-- (SPEC §5.7).

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

local Tags = {}
ns.Tags = Tags

local format, gsub, sub, len, byte = string.format, string.gsub, string.sub, string.len, string.byte
local floor, abs = math.floor, math.abs
local tconcat = table.concat

--------------------------------------------------------------------------------
-- Number formatting (SPEC §4.3.2 "Formatting behaviour")
--------------------------------------------------------------------------------

local function general()
	return ns:General() or { shortThreshold = 1000, shortDecimals = 1, percentDecimals = 0 }
end

--- 1234 -> "1.2k", 1234567 -> "1.2m". Threshold and decimals are global
-- settings, not per-tag, so numbers look consistent across the whole UI.
function Tags:Short(value)
	if not value then return nil end
	local g = general()
	local threshold = g.shortThreshold or 1000
	local decimals = g.shortDecimals or 1
	local negative = value < 0
	local n = abs(value)

	local out
	if n >= 1000000 and n >= threshold then
		out = format("%." .. decimals .. "fm", n / 1000000)
	elseif n >= 1000 and n >= threshold then
		out = format("%." .. decimals .. "fk", n / 1000)
	else
		out = format("%d", n)
	end
	return negative and ("-" .. out) or out
end

function Tags:Number(value, short)
	if not value then return nil end
	if short then return self:Short(value) end
	return format("%d", value)
end

--- Percent values render WITHOUT a '%' sign unless the user types one in the
-- format string (SPEC §4.3.2).
function Tags:Percent(current, maximum)
	if not current or not maximum or maximum <= 0 then return nil end
	local g = general()
	local decimals = g.percentDecimals or 0
	local pct = current / maximum * 100
	if decimals <= 0 then
		return format("%d", floor(pct + 0.5))
	end
	return format("%." .. decimals .. "f", pct)
end

--- UTF-8 aware truncation for [name:short:N].
function Tags:Truncate(text, maxChars)
	if not text or not maxChars or maxChars <= 0 then return text end
	local chars, i, n = 0, 1, len(text)
	while i <= n do
		local b = byte(text, i)
		local size = 1
		if b >= 240 then size = 4
		elseif b >= 224 then size = 3
		elseif b >= 192 then size = 2 end
		if chars >= maxChars then
			return sub(text, 1, i - 1)
		end
		chars = chars + 1
		i = i + size
	end
	return text
end

--------------------------------------------------------------------------------
-- Provider registry
--
-- fn(unit, frame, a1, a2) -> string|nil. Returning nil means "no data", which
-- triggers separator collapse rather than printing an empty slot.
--------------------------------------------------------------------------------

local providers = {}
Tags.providers = providers

local function register(name, def)
	def.name = name
	providers[name] = def
	return def
end

-- Test mode substitutes a real unit into every frame so that tags, colour
-- rules and auras all run on genuine data (see Config/TestMode.lua). The one
-- thing it does fake is identity, so that four party frames do not all read as
-- your own character. This is the whole of that override's reach.
local function testValue(frame, key)
	local test = frame and frame.test
	return test and test[key] or nil
end

local HEALTH_EVENTS = { UNIT_HEALTH = true, UNIT_MAXHEALTH = true, UNIT_CONNECTION = true }
local POWER_EVENTS = { UNIT_POWER_UPDATE = true, UNIT_MAXPOWER = true, UNIT_DISPLAYPOWER = true }

--------------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------------

register("name", {
	events = { UNIT_NAME_UPDATE = true },
	help = "[name] / [name:short:N]",
	fn = function(unit, frame, a1, a2)
		local name = testValue(frame, "name") or UnitName(unit)
		if not name then return nil end
		if a1 == "short" then
			return Tags:Truncate(name, tonumber(a2) or 10)
		end
		if a1 == "abbrev" then
			-- "Sunwell Plateau Guardian" -> "S. P. Guardian"
			return (gsub(name, "([^%s]+)%s", function(word)
				return sub(word, 1, 1) .. ". "
			end))
		end
		return name
	end,
})

register("class", {
	help = "[class]",
	fn = function(unit, frame)
		local override = testValue(frame, "classFile")
		if override then
			return _G["CLASS_" .. override] or override
		end
		if not UnitIsPlayer(unit) then return nil end
		return (UnitClass(unit))
	end,
})

register("race", {
	help = "[race]",
	fn = function(unit)
		if not UnitIsPlayer(unit) then return nil end
		return (UnitRace(unit))
	end,
})

register("guild", {
	help = "[guild]",
	fn = function(unit)
		if not UnitIsPlayer(unit) then return nil end
		local guild = GetGuildInfo(unit)
		return guild
	end,
})

register("level", {
	events = { UNIT_LEVEL = true },
	help = "[level]",
	fn = function(unit, frame)
		local level = testValue(frame, "level") or UnitLevel(unit)
		if not level then return nil end
		-- SPEC §FR-3.8: unknown level renders as ??.
		if level <= 0 then return "??" end
		return tostring(level)
	end,
})

local CLASSIFICATION_LONG = {
	elite = L["Elite"],
	rare = L["Rare"],
	rareelite = L["Rare Elite"],
	worldboss = L["Boss"],
}
local CLASSIFICATION_SHORT = {
	elite = "+",
	rare = "r",
	rareelite = "r+",
	worldboss = "??",
}

register("classification", {
	events = { UNIT_CLASSIFICATION_CHANGED = true },
	help = "[classification]",
	fn = function(unit)
		return CLASSIFICATION_LONG[UnitClassification(unit) or ""]
	end,
})

register("shortclassification", {
	events = { UNIT_CLASSIFICATION_CHANGED = true },
	help = "[shortclassification]",
	fn = function(unit)
		return CLASSIFICATION_SHORT[UnitClassification(unit) or ""]
	end,
})

--------------------------------------------------------------------------------
-- Health
--
-- SPEC §FR-4.7: absolute health for units outside your group is not real in
-- Classic. Those tags return nil (which collapses their separators) rather
-- than printing "100 / 100" for a full-health raid boss.
--------------------------------------------------------------------------------

register("hp", {
	events = HEALTH_EVENTS,
	help = "[hp:cur] [hp:max] [hp:perc] [hp:deficit] (append :short to cur/max/deficit)",
	fn = function(unit, frame, a1, a2)
		local short = (a2 == "short")

		if a1 == "perc" then
			return Tags:Percent(UnitHealth(unit), UnitHealthMax(unit))
		end

		if not Compat.HasRealHealthValues(unit) then return nil end

		if a1 == "cur" or a1 == nil then
			return Tags:Number(UnitHealth(unit), short)
		elseif a1 == "max" then
			return Tags:Number(UnitHealthMax(unit), short)
		elseif a1 == "deficit" then
			local deficit = UnitHealthMax(unit) - UnitHealth(unit)
			if deficit <= 0 then return nil end
			return Tags:Number(-deficit, short)
		end
		return nil
	end,
})

--------------------------------------------------------------------------------
-- Power (the displayed power type)
--------------------------------------------------------------------------------

register("pp", {
	events = POWER_EVENTS,
	help = "[pp:cur] [pp:max] [pp:perc] [pp:deficit] [pp:type]",
	fn = function(unit, frame, a1, a2)
		local short = (a2 == "short")

		if a1 == "type" then
			local _, token = Compat.GetPowerType(unit)
			return _G[token] or token
		end

		local maximum = UnitPowerMax(unit)
		if not maximum or maximum <= 0 then return nil end

		if a1 == "perc" then
			return Tags:Percent(UnitPower(unit), maximum)
		elseif a1 == "max" then
			return Tags:Number(maximum, short)
		elseif a1 == "deficit" then
			local deficit = maximum - UnitPower(unit)
			if deficit <= 0 then return nil end
			return Tags:Number(-deficit, short)
		end
		return Tags:Number(UnitPower(unit), short)
	end,
})

--------------------------------------------------------------------------------
-- True mana, regardless of the displayed power type (SPEC §4.2)
--------------------------------------------------------------------------------

register("mana", {
	events = POWER_EVENTS,
	help = "[mana:cur] [mana:max] [mana:perc]",
	fn = function(unit, frame, a1, a2)
		local short = (a2 == "short")
		local maximum = UnitPowerMax(unit, Compat.MANA)
		if not maximum or maximum <= 0 then return nil end

		if a1 == "perc" then
			return Tags:Percent(UnitPower(unit, Compat.MANA), maximum)
		elseif a1 == "max" then
			return Tags:Number(maximum, short)
		end
		return Tags:Number(UnitPower(unit, Compat.MANA), short)
	end,
})

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

register("status", {
	events = { UNIT_HEALTH = true, UNIT_CONNECTION = true },
	help = "[status]",
	fn = function(unit)
		if not UnitIsConnected(unit) then return L["Offline"] end
		if UnitIsGhost(unit) then return L["Ghost"] end
		if UnitIsDead(unit) then return L["Dead"] end
		return nil
	end,
})

register("afk", {
	events = { PLAYER_FLAGS_CHANGED = true },
	help = "[afk]",
	fn = function(unit)
		return UnitIsAFK(unit) and (_G.CHAT_FLAG_AFK or "<AFK>") or nil
	end,
})

register("dnd", {
	events = { PLAYER_FLAGS_CHANGED = true },
	help = "[dnd]",
	fn = function(unit)
		return UnitIsDND(unit) and (_G.CHAT_FLAG_DND or "<DND>") or nil
	end,
})

register("pvp", {
	events = { UNIT_FACTION = true },
	help = "[pvp]",
	fn = function(unit)
		return UnitIsPVP(unit) and (_G.PVP or "PvP") or nil
	end,
})

register("leader", {
	globalEvents = { PARTY_LEADER_CHANGED = true, GROUP_ROSTER_UPDATE = true },
	help = "[leader]",
	fn = function(unit)
		if UnitIsGroupLeader and UnitIsGroupLeader(unit) then return L["L"] end
		if UnitIsPartyLeader and UnitIsPartyLeader(unit) then return L["L"] end
		return nil
	end,
})

local RAID_TARGET_TEXT = { "*", "**", "***", "****", "*****", "******", "*******", "********" }

register("raidtarget", {
	globalEvents = { RAID_TARGET_UPDATE = true },
	help = "[raidtarget]",
	fn = function(unit)
		local index = GetRaidTargetIndex and GetRaidTargetIndex(unit)
		if not index then return nil end
		local icon = _G["ICON_TAG_RAID_TARGET_" .. index]
		return icon or RAID_TARGET_TEXT[index] or tostring(index)
	end,
})

register("happiness", {
	events = { UNIT_HAPPINESS = true },
	help = "[happiness] (pet, Classic/TBC only)",
	fn = function(unit)
		if not Compat.hasPetHappiness then return nil end
		if not UnitIsUnit(unit, "pet") then return nil end
		local happiness = GetPetHappiness()
		if not happiness then return nil end
		if happiness == 3 then return L["Happy"] end
		if happiness == 2 then return L["Content"] end
		return L["Unhappy"]
	end,
})

--------------------------------------------------------------------------------
-- Parser (PLAN task 4.1)
--
-- A format string is compiled exactly once. `cache` is keyed by the string
-- itself, so two elements sharing "[name]" share one compiled form.
--------------------------------------------------------------------------------

local cache = {}
Tags.cache = cache

local function splitTag(body)
	local parts = {}
	for piece in string.gmatch(body, "[^:]+") do
		parts[#parts + 1] = piece
	end
	return parts
end

--- Compile `formatString` into a segment list plus its event dependency set.
function Tags:Compile(formatString)
	formatString = formatString or ""
	local compiled = cache[formatString]
	if compiled then return compiled end

	compiled = {
		format = formatString,
		segments = {},
		events = {},
		globalEvents = {},
		tagCount = 0,
	}

	local segments = compiled.segments
	local position = 1
	local n = len(formatString)

	while position <= n do
		local openBracket = string.find(formatString, "[", position, true)
		if not openBracket then
			segments[#segments + 1] = { literal = sub(formatString, position) }
			break
		end

		if openBracket > position then
			segments[#segments + 1] = { literal = sub(formatString, position, openBracket - 1) }
		end

		local closeBracket = string.find(formatString, "]", openBracket + 1, true)
		if not closeBracket then
			-- Unterminated tag: treat the rest as a literal rather than failing.
			segments[#segments + 1] = { literal = sub(formatString, openBracket) }
			break
		end

		local body = sub(formatString, openBracket + 1, closeBracket - 1)
		local parts = splitTag(body)
		local provider = providers[parts[1] or ""]

		if provider then
			segments[#segments + 1] = {
				tag = body,
				fn = provider.fn,
				a1 = parts[2],
				a2 = parts[3],
			}
			compiled.tagCount = compiled.tagCount + 1
			if provider.events then
				for event in pairs(provider.events) do compiled.events[event] = true end
			end
			if provider.globalEvents then
				for event in pairs(provider.globalEvents) do compiled.globalEvents[event] = true end
			end
		else
			-- Unknown tag: keep it visible so the user can see the typo.
			segments[#segments + 1] = { literal = sub(formatString, openBracket, closeBracket) }
		end

		position = closeBracket + 1
	end

	cache[formatString] = compiled
	return compiled
end

--------------------------------------------------------------------------------
-- Render (PLAN task 4.3 — empty-tag collapse)
--
-- Handled in the compiled representation rather than by post-processing the
-- output string, because post-processing here is exactly where the subtle bugs
-- live: a literal "/" is indistinguishable from a separator once it is text.
--------------------------------------------------------------------------------

local resolved = {}   -- reused scratch: index -> string|false
local pieces = {}     -- reused scratch: output fragments

function Tags:Render(compiled, unit, frame)
	local segments = compiled.segments
	local count = #segments
	if count == 0 then return "" end

	-- Pass 1: resolve every tag.
	for i = 1, count do
		local segment = segments[i]
		if segment.tag then
			local value = segment.fn(unit, frame, segment.a1, segment.a2)
			if value == nil or value == "" then
				resolved[i] = false
			else
				resolved[i] = tostring(value)
			end
		else
			resolved[i] = segment.literal
		end
	end

	-- Pass 2: drop separators adjacent to an empty tag.
	local out = 0
	for i = 1, count do
		local segment = segments[i]
		if segment.tag then
			if resolved[i] then
				out = out + 1
				pieces[out] = resolved[i]
			end
		else
			local previous = segments[i - 1]
			local following = segments[i + 1]
			local previousEmpty = previous and previous.tag and resolved[i - 1] == false
			local followingEmpty = following and following.tag and resolved[i + 1] == false
			if not previousEmpty and not followingEmpty then
				out = out + 1
				pieces[out] = segment.literal
			end
		end
	end

	for i = out + 1, #pieces do pieces[i] = nil end
	if out == 0 then return "" end

	local text = tconcat(pieces, "", 1, out)
	-- A collapse can leave leading/trailing whitespace behind.
	return (text:match("^%s*(.-)%s*$")) or text
end

--- Does `event` invalidate this compiled format?
function Tags:Invalidates(compiled, event)
	return compiled.events[event] or compiled.globalEvents[event] or false
end

--------------------------------------------------------------------------------
-- Reference output (PLAN task 4.11)
--------------------------------------------------------------------------------

local REFERENCE_ORDER = {
	{ L["Identity"], { "name", "class", "race", "guild", "level", "classification", "shortclassification" } },
	{ L["Health"], { "hp" } },
	{ L["Power"], { "pp" } },
	{ L["True mana"], { "mana" } },
	{ L["Status"], { "status", "afk", "dnd", "pvp", "leader", "raidtarget", "happiness" } },
}

function Tags:PrintReference(filter)
	local Errors = ns.Errors
	filter = filter and filter:lower()
	if filter == "" then filter = nil end

	Errors:Print(L["Tag vocabulary (no Lua, no eval — these are the whole language):"])
	for _, section in ipairs(REFERENCE_ORDER) do
		local heading, names = section[1], section[2]
		local lines = {}
		for _, name in ipairs(names) do
			local provider = providers[name]
			if provider and (not filter or name:find(filter, 1, true)) then
				lines[#lines + 1] = "    " .. (provider.help or ("[" .. name .. "]"))
			end
		end
		if #lines > 0 then
			Errors:Print("  |cffffcc00" .. heading .. "|r")
			for _, line in ipairs(lines) do Errors:Print(line) end
		end
	end
	Errors:Print(L["Separators next to an empty tag are removed automatically, so \"[hp:cur] / [hp:max]\" on an enemy renders nothing rather than \" / \"."])
end

--- Every tag name, for the options UI.
function Tags:AllHelp()
	local out = {}
	for _, section in ipairs(REFERENCE_ORDER) do
		out[#out + 1] = "|cffffcc00" .. section[1] .. "|r"
		for _, name in ipairs(section[2]) do
			local provider = providers[name]
			if provider then out[#out + 1] = "  " .. (provider.help or ("[" .. name .. "]")) end
		end
	end
	return tconcat(out, "\n")
end
