-- Systems/Colors.lua
--
-- SPEC §4.4 and PLAN task 3.1 — class, reaction, power and difficulty color
-- resolution in one place, so every bar, text element and border asks the same
-- question and gets the same answer.
--
-- All the version-sensitive lookups live in Core/Compat.lua; this module holds
-- the policy, not the API calls.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

local Colors = {}
ns.Colors = Colors

local UnitIsPlayer, UnitClass, UnitReaction = UnitIsPlayer, UnitClass, UnitReaction
local UnitIsConnected, UnitIsDead, UnitIsGhost = UnitIsConnected, UnitIsDead, UnitIsGhost

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

--- Unpack a stored {r,g,b,a} table with a safe fallback.
function Colors:Unpack(c, defaultAlpha)
	if type(c) ~= "table" then return 1, 1, 1, defaultAlpha or 1 end
	return c.r or 1, c.g or 1, c.b or 1, c.a or defaultAlpha or 1
end

--------------------------------------------------------------------------------
-- Sources
--------------------------------------------------------------------------------

--- Class color, but only for actual players (SPEC §FR-4.4).
-- Silently coloring a mob "mage blue" because of a class-token collision is a
-- bug, not a feature, so this returns nil for NPCs and the caller falls back.
-- @param frame optional; carries test mode's identity override
function Colors:Class(unit, frame)
	if frame and frame.test and frame.test.classFile then
		return Compat.GetClassColor(frame.test.classFile)
	end
	if not unit or not UnitExists(unit) then return nil end
	if not UnitIsPlayer(unit) then return nil end
	local classFile = select(2, UnitClass(unit))
	return Compat.GetClassColor(classFile)
end

function Colors:Reaction(unit)
	if not unit or not UnitExists(unit) then return nil end

	local reaction = UnitReaction(unit, "player")
	if not reaction then
		-- No reaction data: a player we cannot evaluate. Treat as friendly
		-- rather than flashing hostile red at a party member.
		return 0.2, 0.8, 0.2
	end

	local r, g, b = Compat.GetReactionColor(reaction)
	if r then return r, g, b end

	if reaction >= 5 then
		return 0.2, 0.8, 0.2
	elseif reaction == 4 then
		return 0.9, 0.9, 0.2
	else
		return 0.9, 0.2, 0.2
	end
end

function Colors:Difficulty(unit)
	if not unit or not UnitExists(unit) then return 1, 1, 1 end
	local level = UnitLevel(unit)
	if not level or level <= 0 then
		-- Unknown level renders in the boss color (SPEC §FR-3.8).
		return 1, 0.1, 0.1
	end
	return Compat.GetDifficultyColor(level)
end

function Colors:Power(unit, powerToken)
	if not powerToken then
		local _, token = Compat.GetPowerType(unit)
		powerToken = token
	end
	local r, g, b = Compat.GetPowerColor(powerToken)
	if r then return r, g, b end

	-- Only reached if the client's PowerBarColor is missing a token.
	if powerToken == "RAGE" then return 0.78, 0.25, 0.25 end
	if powerToken == "ENERGY" then return 1.0, 0.96, 0.41 end
	if powerToken == "FOCUS" then return 1.0, 0.5, 0.25 end
	if powerToken == "HAPPINESS" then return 0.0, 1.0, 1.0 end
	if powerToken == "RUNIC_POWER" then return 0.0, 0.82, 1.0 end
	return 0.0, 0.0, 1.0
end

--------------------------------------------------------------------------------
-- Gradient (SPEC §FR-3.5)
--------------------------------------------------------------------------------

--- Interpolate across an ordered stop list. `pct` is 0..1, stop 1 is 0%.
function Colors:Gradient(stops, pct)
	if type(stops) ~= "table" or #stops == 0 then return 1, 1, 1 end
	local n = #stops
	if n == 1 then return self:Unpack(stops[1]) end

	pct = pct or 0
	if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end

	local scaled = pct * (n - 1)
	local index = math.floor(scaled) + 1
	if index >= n then return self:Unpack(stops[n]) end

	local t = scaled - (index - 1)
	local r1, g1, b1 = self:Unpack(stops[index])
	local r2, g2, b2 = self:Unpack(stops[index + 1])
	return r1 + (r2 - r1) * t,
	       g1 + (g2 - g1) * t,
	       b1 + (b2 - b1) * t
end

--------------------------------------------------------------------------------
-- Policy: what color is this health bar?
--------------------------------------------------------------------------------

--- Fractional health, 0..1, tolerant of a zero maximum.
function Colors:HealthFraction(unit)
	local maxHealth = UnitHealthMax(unit)
	if not maxHealth or maxHealth <= 0 then return 0 end
	local current = UnitHealth(unit) or 0
	local pct = current / maxHealth
	if pct < 0 then return 0 elseif pct > 1 then return 1 end
	return pct
end

--- Resolve a health bar color for `unit` under `cfg` (a unit's health table).
-- @return r, g, b
function Colors:HealthBar(unit, cfg, frame)
	if not cfg then return 0, 0.9, 0.1 end

	if unit and UnitExists(unit) then
		if not UnitIsConnected(unit) then
			return self:Unpack(cfg.offlineColor)
		end
		if Compat.IsTapDenied(unit) then
			return self:Unpack(cfg.tapColor)
		end
	end

	local mode = cfg.colorMode or "static"

	if mode == "class" then
		local r, g, b = self:Class(unit, frame)
		if r then return r, g, b end
		-- SPEC §FR-4.4: NPCs fall through to the configured fallback.
		mode = cfg.npcFallback or "reaction"
	end

	if mode == "reaction" then
		local r, g, b = self:Reaction(unit)
		if r then return r, g, b end
		return self:Unpack(cfg.color)
	end

	if mode == "gradient" then
		return self:Gradient(cfg.gradient, self:HealthFraction(unit))
	end

	return self:Unpack(cfg.color)
end

--- Resolve a power bar color for `unit` under `cfg` (a unit's power table).
function Colors:PowerBar(unit, cfg, powerToken, frame)
	if not cfg then return 0, 0, 1 end

	local mode = cfg.colorMode or "power"

	if mode == "class" then
		local r, g, b = self:Class(unit, frame)
		if r then return r, g, b end
		mode = "power"
	end

	if mode == "static" then
		return self:Unpack(cfg.color)
	end

	if not powerToken then
		local _, token = Compat.GetPowerType(unit)
		powerToken = token
	end

	if cfg.useOverrides and cfg.overrides then
		local override = cfg.overrides[powerToken]
		if type(override) == "table" and override.r then
			return self:Unpack(override)
		end
	end

	return self:Power(unit, powerToken)
end

--------------------------------------------------------------------------------
-- Brightness
--------------------------------------------------------------------------------

--- Scale a resolved bar color. Applied before anything downstream, so a bar's
-- background -- which derives from the bar color -- tracks it automatically
-- and the two never drift apart.
--
-- Clamped, because SetStatusBarColor above 1 is meaningless: pushing a bright
-- color further just saturates it, and silently letting the stored number run
-- past the point where it does anything is worse than capping it.
function Colors:Brighten(r, g, b, brightness)
	if not brightness or brightness == 1 then return r, g, b end

	r, g, b = r * brightness, g * brightness, b * brightness

	if r > 1 then r = 1 elseif r < 0 then r = 0 end
	if g > 1 then g = 1 elseif g < 0 then g = 0 end
	if b > 1 then b = 1 elseif b < 0 then b = 0 end

	return r, g, b
end

--------------------------------------------------------------------------------
-- Bar backgrounds
--------------------------------------------------------------------------------

--- Backgrounds derive from the bar color rather than being independently
-- configured, so a class-colored bar keeps a matching background without the
-- user having to set seventeen of them.
function Colors:Background(r, g, b, multiplier, alpha)
	multiplier = multiplier or 0.25
	return r * multiplier, g * multiplier, b * multiplier, alpha or 1
end
