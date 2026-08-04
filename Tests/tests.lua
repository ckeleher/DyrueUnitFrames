-- Headless test suite for DyrueUnitFrames.
--
-- Exercises the pure-logic core (tags, color rules, defaults merging, anchor
-- graph, combat queue) plus a full load-and-build integration pass.

local ns = _G.__ns
local stub = _G.__stub

local results = { passed = 0, failed = 0, failures = {} }

local function fail(name, message)
	results.failed = results.failed + 1
	results.failures[#results.failures + 1] = name .. ": " .. tostring(message)
end

local function ok(name)
	results.passed = results.passed + 1
end

local function check(name, condition, message)
	if condition then ok(name) else fail(name, message or "assertion failed") end
end

local function equal(name, actual, expected)
	if actual == expected then
		ok(name)
	else
		fail(name, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
	end
end

local function near(name, actual, expected, tolerance)
	tolerance = tolerance or 0.001
	if type(actual) == "number" and math.abs(actual - expected) <= tolerance then
		ok(name)
	else
		fail(name, string.format("expected ~%s, got %s", tostring(expected), tostring(actual)))
	end
end

--------------------------------------------------------------------------------
-- World setup
--------------------------------------------------------------------------------

local function setupWorld()
	stub.reset()
	stub.setUnit("player", {
		name = "Dyrue", class = "DRUID", className = "Druid", race = "Night Elf",
		level = 60, isPlayer = true, guid = "player-1",
		health = 4200, healthMax = 5000,
		power = 60, powerMax = 100, powerType = 1, powerToken = "RAGE",
		powers = { [0] = 3000 }, powerMaxes = { [0] = 6000 },
		reaction = 5, inParty = true,
	})
	stub.setUnit("target", {
		name = "Onyxia", level = -1, classification = "worldboss",
		health = 87, healthMax = 100, reaction = 2, guid = "npc-1",
		power = 50, powerMax = 100, powerType = 0, powerToken = "MANA",
		auras = {
			HELPFUL = {
				{ name = "Blessing", icon = 1, applications = 0, duration = 300,
				  expirationTime = 1200, sourceUnit = "player", spellId = 1001, isHelpful = true },
				{ name = "Fortitude", icon = 2, applications = 0, duration = 0,
				  expirationTime = 0, sourceUnit = "party1", spellId = 1002, isHelpful = true },
			},
			HARMFUL = {
				{ name = "Sunder Armor", icon = 3, applications = 5, duration = 30,
				  expirationTime = 1030, sourceUnit = "player", spellId = 2001,
				  dispelName = nil, isHarmful = true },
				{ name = "Curse of Agony", icon = 4, applications = 0, duration = nil,
				  expirationTime = nil, sourceUnit = "party2", spellId = 2002,
				  dispelName = "Curse", isHarmful = true },
			},
		},
	})
	stub.setUnit("party1", {
		name = "Healbot", class = "PRIEST", className = "Priest", level = 60,
		isPlayer = true, health = 3000, healthMax = 3000, inParty = true,
		power = 900, powerMax = 1000, powerType = 0, powerToken = "MANA", reaction = 5,
		guid = "player-2",
	})
end

--------------------------------------------------------------------------------
-- 1. Tags: compilation, rendering, empty-tag collapse
--------------------------------------------------------------------------------

local function testTags()
	local Tags = ns.Tags

	local compiled = Tags:Compile("[name]")
	equal("tags/compile caches", Tags:Compile("[name]"), compiled)
	equal("tags/render name", Tags:Render(compiled, "player"), "Dyrue")

	-- FR-4.7: the target's absolute health is not real, so cur/max resolve to
	-- nothing and the " / " separator must vanish with them.
	local mixed = Tags:Compile("[hp:cur] / [hp:max] [hp:perc]%")
	equal("tags/collapse on enemy", Tags:Render(mixed, "target"), "87%")
	equal("tags/no collapse on player",
		Tags:Render(mixed, "player"), "4200 / 5000 84%")

	local trailing = Tags:Compile("[name] - [guild]")
	equal("tags/collapse trailing separator", Tags:Render(trailing, "player"), "Dyrue")

	local literalOnly = Tags:Compile("hello")
	equal("tags/literal passthrough", Tags:Render(literalOnly, "player"), "hello")

	local wrapped = Tags:Compile("<[name]>")
	equal("tags/keeps brackets around a resolved tag",
		Tags:Render(wrapped, "player"), "<Dyrue>")

	local unknown = Tags:Compile("[nosuchtag]")
	equal("tags/unknown tag stays visible", Tags:Render(unknown, "player"), "[nosuchtag]")

	local unterminated = Tags:Compile("[hp:cur")
	equal("tags/unterminated tag does not error", Tags:Render(unterminated, "player"), "[hp:cur")

	-- FR-3.8: unknown level renders as ??
	local level = Tags:Compile("[level][shortclassification]")
	equal("tags/unknown level", Tags:Render(level, "target"), "????")

	-- :short abbreviation
	equal("tags/short thousands", Tags:Short(1234), "1.2k")
	equal("tags/short millions", Tags:Short(1234567), "1.2m")
	equal("tags/short below threshold", Tags:Short(999), "999")
	equal("tags/short negative", Tags:Short(-1500), "-1.5k")

	-- True mana while shapeshifted: displayed power is RAGE, mana still readable
	local mana = Tags:Compile("[mana:cur]/[mana:max]")
	equal("tags/true mana while shifted", Tags:Render(mana, "player"), "3000/6000")

	local power = Tags:Compile("[pp:cur]")
	equal("tags/displayed power", Tags:Render(power, "player"), "60")

	-- Event dependency map
	check("tags/hp depends on UNIT_HEALTH", Tags:Invalidates(mixed, "UNIT_HEALTH"))
	check("tags/hp does not depend on UNIT_POWER_UPDATE",
		not Tags:Invalidates(mixed, "UNIT_POWER_UPDATE"))
	check("tags/mana depends on UNIT_POWER_UPDATE", Tags:Invalidates(mana, "UNIT_POWER_UPDATE"))

	-- name:short:N truncation
	local short = Tags:Compile("[name:short:3]")
	equal("tags/name truncation", Tags:Render(short, "player"), "Dyr")
end

--------------------------------------------------------------------------------
-- 2. Color rules
--------------------------------------------------------------------------------

local function testColorRules()
	local ColorRules = ns.ColorRules

	-- FR-3.4: both threshold modes must work natively.
	local rules = {
		{ enabled = true, metric = "health.percent", op = "<=", value = 35,
		  color = { r = 1, g = 0.5, b = 0 } },
		{ enabled = true, metric = "health.current", op = "<=", value = 500,
		  color = { r = 1, g = 0, b = 0 } },
	}

	stub.units.player.health = 5000
	ns:BumpSerial()
	check("rules/no match at full health", ColorRules:Evaluate(rules, "player") == nil)

	stub.units.player.health = 1500        -- 30%
	ns:BumpSerial()
	local r, g, b = ColorRules:Evaluate(rules, "player")
	check("rules/percentage threshold fires", r == 1 and g == 0.5 and b == 0)

	-- Absolute threshold: 400/5000 is 8%, so BOTH rules match and the first
	-- one in the list has to win.
	stub.units.player.health = 400
	ns:BumpSerial()
	r, g, b = ColorRules:Evaluate(rules, "player")
	check("rules/first match wins", r == 1 and g == 0.5 and b == 0)

	-- Reorder: absolute first
	rules[1], rules[2] = rules[2], rules[1]
	ns:BumpSerial()
	r, g, b = ColorRules:Evaluate(rules, "player")
	check("rules/absolute threshold fires after reorder", r == 1 and g == 0 and b == 0)

	-- Disabled rules are skipped
	rules[1].enabled = false
	ns:BumpSerial()
	r, g, b = ColorRules:Evaluate(rules, "player")
	check("rules/disabled rule skipped", r == 1 and g == 0.5 and b == 0)

	-- Boolean metric
	local deadRule = { { enabled = true, metric = "unit.isDead", op = "==", value = 1,
		color = { r = 0.3, g = 0.3, b = 0.3 } } }
	stub.units.player.dead = false
	ns:BumpSerial()
	check("rules/boolean false", ColorRules:Evaluate(deadRule, "player") == nil)
	stub.units.player.dead = true
	ns:BumpSerial()
	r = ColorRules:Evaluate(deadRule, "player")
	near("rules/boolean true", r, 0.3)
	stub.units.player.dead = false

	-- level.difference against an unknown-level boss
	local bossRule = { { enabled = true, metric = "level.difference", op = ">=", value = 5,
		color = { r = 1, g = 0, b = 1 } } }
	ns:BumpSerial()
	r = ColorRules:Evaluate(bossRule, "target")
	equal("rules/unknown level counts as far above you", r, 1)

	-- Editing helpers
	local list = {}
	ColorRules:Add(list)
	ColorRules:Add(list)
	equal("rules/add", #list, 2)
	list[1].value = 10
	list[2].value = 20
	ColorRules:Move(list, 1, 1)
	equal("rules/move swaps", list[1].value, 20)
	ColorRules:Duplicate(list, 1)
	equal("rules/duplicate inserts after", #list, 3)
	ColorRules:Remove(list, 1)
	equal("rules/remove", #list, 2)

	local destination = {}
	ColorRules:CopyInto(destination, list)
	equal("rules/copy count", #destination, 2)
	check("rules/copy is a deep copy", destination[1] ~= list[1])

	stub.units.player.health = 4200
	ns:BumpSerial()
end

--------------------------------------------------------------------------------
-- 3. Defaults: the deleted-entry problem AceDB defaults would reintroduce
--------------------------------------------------------------------------------

local function testDefaults()
	local Defaults = ns.Defaults

	local profile = {}
	Defaults:EnsureProfile(profile)

	check("defaults/units built", profile.units ~= nil and profile.units.player ~= nil)
	equal("defaults/health is class colored", profile.units.player.health.colorMode, "class")
	equal("defaults/NPCs fall back to reaction", profile.units.player.health.npcFallback, "reaction")
	equal("defaults/the spec's green is still the stored color",
		profile.units.player.health.color.g, 0.9)

	-- Every unit, not just the player -- target and focus used to override to
	-- reaction and no longer should.
	local notClass = {}
	for key, cfg in pairs(profile.units) do
		if cfg.health.colorMode ~= "class" then
			notClass[#notClass + 1] = key .. "=" .. tostring(cfg.health.colorMode)
		end
	end
	if #notClass == 0 then
		ok("defaults/every unit is class colored")
	else
		fail("defaults/every unit is class colored", table.concat(notClass, ", "))
	end
	equal("defaults/party pets disabled", profile.units.partypet1.enabled, false)
	equal("defaults/blizzard frames hidden", profile.general.blizzardFrames, "hide")
	equal("defaults/blizzard party frames hidden too", profile.general.blizzardParty, true)
	check("defaults/target has aura groups enabled", profile.units.target.auras.buffs.enabled)
	check("defaults/derived units ship auras off", not profile.units.targettarget.auras.buffs.enabled)

	-- The behavior AceDB's metatable defaults would have broken: a deleted
	-- text element must STAY deleted across a re-fill.
	local before = #profile.units.player.texts
	table.remove(profile.units.player.texts, 1)
	Defaults:EnsureProfile(profile)
	equal("defaults/deleted text stays deleted", #profile.units.player.texts, before - 1)

	-- Same for a user-added color rule.
	local text = profile.units.player.texts[1]
	text.rules[1] = { enabled = true, metric = "health.percent", op = "<", value = 20,
		color = { r = 1, g = 0, b = 0 } }
	Defaults:EnsureProfile(profile)
	equal("defaults/user rules survive a re-fill", #text.rules, 1)

	-- A newly added key must appear without disturbing anything.
	profile.units.player.width = 999
	Defaults:EnsureProfile(profile)
	equal("defaults/user values are not overwritten", profile.units.player.width, 999)

	-- ResetUnit restores the shipped defaults
	Defaults:ResetUnit(profile, "player")
	equal("defaults/reset restores width", profile.units.player.width, 220)
end

--------------------------------------------------------------------------------
-- 4. Anchoring: cycle detection and apply order
--------------------------------------------------------------------------------

local function testAnchoring()
	local Anchoring = ns.Anchoring
	local units = ns:Profile().units

	-- Target of target ships to the RIGHT of the target frame, not below it.
	equal("anchor/tot anchored to the target", units.targettarget.anchor.to, "target")
	equal("anchor/tot sits right of the target", units.targettarget.anchor.point, "LEFT")
	equal("anchor/tot pins to the target's right edge",
		units.targettarget.anchor.relativePoint, "RIGHT")
	check("anchor/tot is offset clear of the target", units.targettarget.anchor.x > 0)
	equal("anchor/tot is vertically centered on the target", units.targettarget.anchor.y, 0)

	local totFrame = ns.frames.targettarget
	local _, relative, relativePoint = totFrame:GetPoint(1)
	equal("anchor/tot frame is anchored to the target frame", relative, ns.frames.target)
	equal("anchor/tot frame pins to the target's right", relativePoint, "RIGHT")

	units.target.anchor.to = "UIParent"
	units.targettarget.anchor.to = "target"
	units.pet.anchor.to = "player"
	units.player.anchor.to = "UIParent"

	check("anchor/self reference rejected", (Anchoring:WouldCycle("player", "player")))
	check("anchor/simple chain is fine", not (Anchoring:WouldCycle("pet", "target")))

	-- target -> targettarget -> target would be a two-frame loop
	check("anchor/two-frame loop rejected", (Anchoring:WouldCycle("target", "targettarget")))

	-- Three-frame loop: player -> pet -> ... make pet anchor to targettarget
	units.pet.anchor.to = "targettarget"
	check("anchor/three-frame loop rejected", (Anchoring:WouldCycle("target", "pet")))
	units.pet.anchor.to = "player"

	-- SetTarget must refuse and leave the stored value untouched
	local previous = units.target.anchor.to
	local accepted = Anchoring:SetTarget("target", "targettarget")
	check("anchor/SetTarget refuses a loop", not accepted)
	equal("anchor/refused target is unchanged", units.target.anchor.to, previous)

	-- Topological order: a parent must come before its children
	local order = Anchoring:SortedKeys()
	local position = {}
	for i, key in ipairs(order) do position[key] = i end
	check("anchor/parent before child",
		position.target and position.targettarget and position.target < position.targettarget,
		"target at " .. tostring(position.target) .. ", targettarget at " .. tostring(position.targettarget))
	check("anchor/player before pet", position.player < position.pet)

	-- TargetValues must not offer a choice that would loop
	local values = Anchoring:TargetValues("target")
	check("anchor/loop-creating target not offered", values.targettarget == nil)
	check("anchor/screen always offered", values.UIParent ~= nil)
end

--------------------------------------------------------------------------------
-- 5. Combat queue
--------------------------------------------------------------------------------

local function testCombatQueue()
	local CombatQueue = ns.CombatQueue
	CombatQueue:Clear()

	local ran = 0
	stub.inCombat = false
	CombatQueue:Run("a", function() ran = ran + 1 end)
	equal("queue/runs immediately out of combat", ran, 1)

	stub.inCombat = true
	local applied = 0
	for i = 1, 200 do
		CombatQueue:Run("slider", function() applied = applied + 1 end)
	end
	equal("queue/nothing applied during combat", applied, 0)
	equal("queue/200 drags collapse to one entry", CombatQueue:PendingCount(), 1)
	check("queue/status text is offered", CombatQueue:StatusText() ~= nil)

	local order = {}
	CombatQueue:Run("second", function() order[#order + 1] = "second" end)
	CombatQueue:Run("third", function() order[#order + 1] = "third" end)

	stub.inCombat = false
	CombatQueue:Flush()
	equal("queue/applied once on combat exit", applied, 1)
	equal("queue/insertion order preserved", table.concat(order, ","), "second,third")
	equal("queue/empty after flush", CombatQueue:PendingCount(), 0)
	check("queue/status text gone", CombatQueue:StatusText() == nil)

	-- A queued function that queues more work must not run in the same flush.
	stub.inCombat = true
	local nested = 0
	CombatQueue:Run("outer", function()
		CombatQueue:Run("inner", function() nested = nested + 1 end)
	end)
	stub.inCombat = false
	CombatQueue:Flush()
	equal("queue/nested work deferred to the next flush", nested, 1)
end

--------------------------------------------------------------------------------
-- 6. Colors
--------------------------------------------------------------------------------

local function testColors()
	local Colors = ns.Colors

	local r, g, b = Colors:Class("player")
	near("colors/class color for a player", r, 1.0)
	near("colors/druid orange", g, 0.49)

	check("colors/no class color for an NPC", Colors:Class("target") == nil)

	r = Colors:Reaction("target")
	near("colors/hostile reaction is red", r, 0.87)

	-- FR-4.4: class mode on an NPC falls through to the configured fallback
	local cfg = { colorMode = "class", npcFallback = "reaction",
		color = { r = 0, g = 0.9, b = 0.1 }, offlineColor = {}, tapColor = {} }
	r, g, b = Colors:HealthBar("target", cfg)
	near("colors/NPC falls through to reaction", r, 0.87)

	cfg.npcFallback = "static"
	r, g, b = Colors:HealthBar("target", cfg)
	near("colors/NPC falls through to the static color", g, 0.9)

	-- Gradient: red -> yellow -> green
	local stops = { { r = 1, g = 0, b = 0 }, { r = 1, g = 1, b = 0 }, { r = 0, g = 1, b = 0 } }
	r, g, b = Colors:Gradient(stops, 0)
	check("colors/gradient at 0", r == 1 and g == 0)
	r, g, b = Colors:Gradient(stops, 0.5)
	check("colors/gradient at 0.5", r == 1 and g == 1 and b == 0)
	r, g, b = Colors:Gradient(stops, 1)
	check("colors/gradient at 1", r == 0 and g == 1)
	r, g, b = Colors:Gradient(stops, 0.25)
	near("colors/gradient interpolates", g, 0.5)
	r = Colors:Gradient(stops, 5)
	equal("colors/gradient clamps above 1", r, 0)

	-- Offline and tapped states take precedence
	stub.units.target.tapDenied = true
	cfg.tapColor = { r = 0.6, g = 0.6, b = 0.6 }
	r = Colors:HealthBar("target", cfg)
	near("colors/tapped overrides", r, 0.6)
	stub.units.target.tapDenied = false
end

--------------------------------------------------------------------------------
-- 7. Compat predicates
--------------------------------------------------------------------------------

local function testCompat()
	local Compat = ns.Compat

	equal("compat/mana enum", Compat.MANA, 0)
	check("compat/no secret values", not Compat.hasSecretValues)
	check("compat/focus probed from the event table", Compat.hasFocus)
	check("compat/uses the C_UnitAuras path", Compat.hasUnitAurasAPI)

	-- FR-4.7 detection predicate
	check("compat/player has real health", Compat.HasRealHealthValues("player"))
	check("compat/party member has real health", Compat.HasRealHealthValues("party1"))
	check("compat/enemy on the 0-100 scale does not",
		not Compat.HasRealHealthValues("target"))

	-- An event this client does not have must be skipped, not registered
	check("compat/UNIT_HEALTH is valid", Compat.HasEvent("UNIT_HEALTH"))
	check("compat/UNIT_HEALTH_FREQUENT is absent", not Compat.HasEvent("UNIT_HEALTH_FREQUENT"))

	local frame = CreateFrame("Frame")
	equal("compat/registering an absent event is refused",
		Compat.RegisterUnitEvent(frame, "UNIT_HEALTH_FREQUENT", "player"), false)
	equal("compat/registering a valid event succeeds",
		Compat.RegisterUnitEvent(frame, "UNIT_HEALTH", "player"), true)

	-- Focus override
	Compat.SetFocusOverride("off")
	check("compat/focus override off", not Compat.hasFocus)
	Compat.SetFocusOverride("auto")
	check("compat/focus override back to auto", Compat.hasFocus)
end

--------------------------------------------------------------------------------
-- 8. Migration
--------------------------------------------------------------------------------
--- A profile shaped the way the very first schema shaped one: every value at
-- its original default, and none of the keys that were added later.
--
-- Migrating this is the real test of the collapsed step, because it has to
-- recognize old values without any help from the version number.
local function legacyProfile(version)
	return {
		schemaVersion = version,
		general = { blizzardFrames = "none", blizzardParty = false },
		units = {
			player = {
				health = { texture = "Blizzard", colorMode = "static",
					color = { r = 0, g = 0.9, b = 0.1 }, brightness = 1 },
				power = { texture = "Blizzard", spacing = 1, brightness = 1 },
				mana = { texture = "Blizzard", spacing = 1, enabled = true },
				background = { enabled = true, color = { r = 0, g = 0, b = 0, a = 0.6 } },
				portrait = { placement = "inside" },
				indicators = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 0, y = 0 },
				texts = { { anchorTo = "health", format = "[name]" } },
			},
			target = {
				health = { texture = "Blizzard", colorMode = "reaction",
					color = { r = 0, g = 0.9, b = 0.1 }, brightness = 1 },
				power = { texture = "Blizzard", spacing = 1, brightness = 1 },
				mana = { texture = "Blizzard", spacing = 1, enabled = false },
				background = { enabled = true, color = { r = 0, g = 0, b = 0, a = 0.6 } },
				portrait = { placement = "inside" },
				texts = { { anchorTo = "health", format = "[name]" } },
			},
			targettarget = {
				anchor = { to = "target", point = "TOPLEFT",
					relativePoint = "BOTTOMLEFT", x = 0, y = -34 },
				health = { texture = "Blizzard", colorMode = "static",
					color = { r = 0, g = 0.9, b = 0.1 } },
				power = {}, mana = {}, background = {}, portrait = {},
			},
		},
	}
end

--- Everything the collapsed step is supposed to have done to it.
local function assertModern(label, profile)
	local player = profile.units.player
	local target = profile.units.target
	local tot = profile.units.targettarget
	local problems = {}

	local function want(what, actual, expected)
		if actual ~= expected then
			problems[#problems + 1] = string.format("%s: %s vs %s", what,
				tostring(actual), tostring(expected))
		end
	end

	want("health texture", player.health.texture, "Dyrue Flat")
	want("power texture", player.power.texture, "Dyrue Flat")
	want("mana texture", player.mana.texture, "Dyrue Flat")
	want("power spacing", player.power.spacing, 0)
	want("mana spacing", player.mana.spacing, 0)
	want("health brightness", player.health.brightness, 0.8)
	want("power brightness", player.power.brightness, 0.8)
	want("backdrop off", player.background.enabled, false)
	want("player health class colored", player.health.colorMode, "class")
	want("target health class colored", target.health.colorMode, "class")
	want("portrait beside the frame", player.portrait.placement, "outside")
	want("indicators raised", player.indicators.y, 5)
	want("blizzard frames hidden", profile.general.blizzardFrames, "hide")
	want("blizzard party hidden", profile.general.blizzardParty, true)
	want("tot point", tot.anchor.point, "LEFT")
	want("tot relative point", tot.anchor.relativePoint, "RIGHT")
	want("tot x", tot.anchor.x, 4)
	want("tot y", tot.anchor.y, 0)
	want("mana readout appended", #player.texts, 2)
	if player.texts[2] then
		want("mana readout anchored", player.texts[2].anchorTo, "mana")
	end
	want("target gains no mana readout", #target.texts, 1)
	want("stamped at target", profile.schemaVersion, ns.Defaults.SCHEMA_VERSION)

	if #problems == 0 then
		ok(label)
	else
		fail(label, table.concat(problems, "; "))
	end
end

local function testMigration()
	local Migrate = ns.Migrate
	local Defaults = ns.Defaults

	local fresh = {}
	local passed = Migrate:Run(fresh, {})
	check("migrate/fresh profile passes", passed)
	equal("migrate/fresh profile is stamped", fresh.schemaVersion, Defaults.SCHEMA_VERSION)

	local current = { schemaVersion = Defaults.SCHEMA_VERSION, units = {} }
	check("migrate/current version is a no-op", (Migrate:Run(current, {})))

	-- A profile from a NEWER build must be left completely alone.
	local newer = { schemaVersion = Defaults.SCHEMA_VERSION + 5, units = { marker = true } }
	local success, message = Migrate:Run(newer, {})
	check("migrate/newer schema refused", not success)
	check("migrate/newer schema explains itself", message ~= nil)
	check("migrate/newer schema untouched", newer.units.marker == true)

	--------------------------------------------------------------------------
	-- The collapsed step (Plan 8 part 2)
	--
	-- Ten procedural steps became one declarative pass. The property that
	-- matters is that a profile arriving from ANY historical version lands on
	-- current defaults, so that is asserted for every one of them rather than
	-- for a couple of sampled versions.
	--------------------------------------------------------------------------

	for version = 1, Migrate.COLLAPSED_THROUGH do
		local profile = legacyProfile(version)
		local ran = Migrate:Run(profile, {})
		check("migrate/v" .. version .. " migrates", ran)
		assertModern("migrate/v" .. version .. " lands on current defaults", profile)
	end

	-- Idempotent: the collapsed step must be safe to run over its own output.
	local twice = legacyProfile(1)
	Migrate:Run(twice, {})
	local textsAfterFirst = #twice.units.player.texts
	twice.schemaVersion = 1
	Migrate:Run(twice, {})
	equal("migrate/collapsed step is idempotent",
		#twice.units.player.texts, textsAfterFirst)
	assertModern("migrate/still correct after a second pass", twice)

	-- Deliberate choices survive, whatever version they arrive from.
	local customized = legacyProfile(1)
	customized.units.player.health.texture = "Smooth"
	customized.units.player.power.spacing = 6
	customized.units.player.health.brightness = 0.4
	customized.units.target.health.colorMode = "gradient"
	customized.units.player.background.color = { r = 0.2, g = 0, b = 0, a = 0.9 }
	customized.units.targettarget.anchor.x = 137
	customized.units.player.indicators.y = -30
	Migrate:Run(customized, {})
	equal("migrate/custom texture kept", customized.units.player.health.texture, "Smooth")
	equal("migrate/custom spacing kept", customized.units.player.power.spacing, 6)
	equal("migrate/custom brightness kept", customized.units.player.health.brightness, 0.4)
	equal("migrate/custom color mode kept", customized.units.target.health.colorMode, "gradient")
	equal("migrate/re-colored backdrop stays on", customized.units.player.background.enabled, true)
	equal("migrate/dragged tot kept", customized.units.targettarget.anchor.x, 137)
	equal("migrate/positioned indicators kept", customized.units.player.indicators.y, -30)

	-- The interim left-side target-of-target position also lands on the right.
	local interim = legacyProfile(9)
	interim.units.targettarget.anchor = { to = "target", point = "RIGHT",
		relativePoint = "LEFT", x = -4, y = 0 }
	Migrate:Run(interim, {})
	equal("migrate/interim tot position corrected",
		interim.units.targettarget.anchor.point, "LEFT")
	equal("migrate/interim tot offset corrected",
		interim.units.targettarget.anchor.x, 4)

	-- A key that did not exist in the old schema is simply absent, and picks up
	-- the current default from EnsureProfile rather than from a migration.
	local ancient = legacyProfile(1)
	ancient.units.player.health.brightness = nil
	ancient.units.player.indicators = nil
	Migrate:Run(ancient, {})
	check("migrate/absent key is left absent by migration",
		ancient.units.player.health.brightness == nil)
	Defaults:EnsureProfile(ancient)
	equal("migrate/EnsureProfile then supplies the current default",
		ancient.units.player.health.brightness, 0.8)
	equal("migrate/and for keys added even later",
		ancient.units.player.indicators.y, 5)

	--------------------------------------------------------------------------
	-- Failure handling
	--
	-- Reaching the "no migration path" branch needs a gap above the collapse
	-- point, since everything at or below it is handled in one step. Raising
	-- the target with no steps defined creates one.
	--------------------------------------------------------------------------

	local realTarget = Defaults.SCHEMA_VERSION
	Defaults.SCHEMA_VERSION = realTarget + 2

	local db = {}
	local orphan = { schemaVersion = realTarget, marker = "precious" }
	success = Migrate:Run(orphan, db, "Orphan")
	check("migrate/missing step fails safely", not success)
	local backedUp = false
	for _, snapshot in pairs(db.backup or {}) do
		if snapshot.marker == "precious" then backedUp = true end
	end
	check("migrate/old settings are backed up", backedUp)
	equal("migrate/defaults loaded after failure", orphan.schemaVersion,
		Defaults.SCHEMA_VERSION)

	-- Two failures in the same second must produce two backups, not one. Both
	-- profiles are unmigratable here because the raised target is unreachable
	-- for anything -- which is the point: this isolates the backup behavior.
	local broken = {
		profile = nil,
		keys = { profile = "Broken" },
		profiles = {
			Broken = { schemaVersion = realTarget, marker = "precious" },
			AlsoBroken = { schemaVersion = realTarget, marker = "also precious" },
		},
	}
	broken.profile = broken.profiles.Broken
	function broken:GetCurrentProfile() return self.keys.profile end

	local brokenSv = {}
	local okCount, badCount = Migrate:RunAll(broken, brokenSv)
	equal("migrate/nothing migrated when there is no path", okCount, 0)
	equal("migrate/both failures reported", badCount, 2)

	local backups, markers = 0, {}
	for _, snapshot in pairs(brokenSv.backup or {}) do
		backups = backups + 1
		markers[snapshot.marker or ""] = true
	end
	equal("migrate/each failure is backed up separately", backups, 2)
	check("migrate/both profiles' contents survive",
		markers["precious"] and markers["also precious"])

	Defaults.SCHEMA_VERSION = realTarget

	--------------------------------------------------------------------------
	-- Every profile, not just the active one (Plan 8 part 1)
	--------------------------------------------------------------------------

	local all = {
		profile = nil,
		keys = { profile = "Active" },
		profiles = {
			Active = { schemaVersion = Defaults.SCHEMA_VERSION, units = {} },
			Stale = legacyProfile(1),
			AlsoStale = legacyProfile(7),
		},
	}
	all.profile = all.profiles.Active
	function all:GetCurrentProfile() return self.keys.profile end

	local migrated, failedCount = Migrate:RunAll(all, {})
	equal("migrate/two stale profiles were migrated", migrated, 2)
	equal("migrate/none failed", failedCount, 0)

	-- One profile failing must not stop the others. A profile from a future
	-- build is the natural case: it is refused without needing a missing step.
	local withFuture = {
		profile = nil,
		keys = { profile = "Healthy" },
		profiles = {
			Healthy = legacyProfile(1),
			FromTheFuture = { schemaVersion = Defaults.SCHEMA_VERSION + 3, marker = true },
		},
	}
	withFuture.profile = withFuture.profiles.Healthy
	function withFuture:GetCurrentProfile() return self.keys.profile end

	local goodCount, refusedCount = Migrate:RunAll(withFuture, {})
	equal("migrate/the healthy profile still migrated", goodCount, 1)
	equal("migrate/the future one was refused", refusedCount, 1)
	assertModern("migrate/healthy profile is fully current despite the failure",
		withFuture.profiles.Healthy)
	equal("migrate/the future profile is untouched",
		withFuture.profiles.FromTheFuture.schemaVersion, Defaults.SCHEMA_VERSION + 3)
	assertModern("migrate/inactive profile is brought current", all.profiles.Stale)
	assertModern("migrate/the second one too", all.profiles.AlsoStale)
	equal("migrate/the active profile is untouched at the target version",
		all.profiles.Active.schemaVersion, Defaults.SCHEMA_VERSION)

	-- Running it again is a no-op.
	local again, againFailed = Migrate:RunAll(all, {})
	equal("migrate/re-running migrates nothing", again, 0)
	equal("migrate/and fails nothing", againFailed, 0)
end

--------------------------------------------------------------------------------
-- 9. Integration: build every frame and update it
--------------------------------------------------------------------------------

local function testIntegration()
	local frames = ns.frames

	check("frames/player created", frames.player ~= nil)
	check("frames/target created", frames.target ~= nil)
	check("frames/party frames created", frames.party4 ~= nil)
	check("frames/focus created on TBC", frames.focus ~= nil)
	check("frames/derived created", frames.targettarget ~= nil)

	local player = frames.player
	equal("frames/secure attribute set", player:GetAttribute("unit"), "player")
	equal("frames/left click targets", player:GetAttribute("type1"), "target")
	equal("frames/right click opens the menu", player:GetAttribute("type2"), "togglemenu")

	check("frames/health element built", player.elements.health ~= nil)
	check("frames/power element built", player.elements.power ~= nil)
	check("frames/text element built", player.elements.text ~= nil)
	check("frames/auras not built where disabled", player.elements.auras == nil)

	-- The bar stack must fill the frame's height.
	local cfg = ns:UnitConfig("player")
	local healthBar = player.elements.health.bar
	local expected = cfg.height - cfg.power.height - cfg.power.spacing
	equal("frames/health bar fills the remaining height", healthBar:GetHeight(), expected)
	equal("frames/health bar spans the width", healthBar:GetWidth(), cfg.width)

	-- Values
	equal("frames/health max", healthBar:GetMinMaxValues(), 0)
	equal("frames/health value", healthBar:GetValue(), stub.units.player.health)

	-- Text rendered through the tag engine
	local nameString = player.elements.text.strings[1]
	equal("frames/name text rendered", nameString:GetText(), "Dyrue")

	-- Events registered per unit, and only the ones actually needed
	check("frames/UNIT_HEALTH registered", player:IsEventRegistered("UNIT_HEALTH"))
	check("frames/UNIT_HEALTH_FREQUENT skipped", not player:IsEventRegistered("UNIT_HEALTH_FREQUENT"))
	local reg = player.__events["UNIT_HEALTH"]
	equal("frames/UNIT_HEALTH filtered to this unit", reg[1], "player")

	-- targettarget takes UNIT_TARGET for its OWNER, not for itself
	local tot = frames.targettarget
	local totReg = tot.__events["UNIT_TARGET"]
	check("frames/derived watches its owner's target", totReg and totReg[1] == "target")

	-- Health event drives the bar
	stub.units.player.health = 100
	stub.fire("UNIT_HEALTH", "player")
	equal("frames/health event updates the bar", healthBar:GetValue(), 100)
	stub.units.player.health = 4200
	stub.fire("UNIT_HEALTH", "player")

	-- Target frame renders the enemy-safe format
	local target = frames.target
	local healthText
	for _, fs in ipairs(target.elements.text.strings) do
		if fs:GetText() and fs:GetText():find("%%") then healthText = fs end
	end
	check("frames/target health text collapses to a percentage",
		healthText ~= nil and healthText:GetText() == "87%",
		healthText and healthText:GetText() or "no percentage text found")

	-- Auras on the target
	check("frames/target auras built", target.elements.auras ~= nil)
	local buffs = target.elements.auras.buffs
	check("frames/buff icons shown", buffs.buttons[1] ~= nil and buffs.buttons[1]:IsShown())
	equal("frames/two buffs scanned", #buffs.list, 2)
	check("frames/own aura sorted first", buffs.list[1].own == true)
	local ownSize = buffs.buttons[1]:GetWidth()
	local otherSize = buffs.buttons[2]:GetWidth()
	check("frames/own aura is larger", ownSize > otherSize,
		tostring(ownSize) .. " vs " .. tostring(otherSize))

	local debuffs = target.elements.auras.debuffs
	equal("frames/stack count shown", debuffs.buttons[1].count:GetText(), 5)
	-- FR-5.8: an aura someone else applied has no duration in Classic, so it
	-- must get no cooldown swipe rather than a fabricated one.
	local other
	for i = 1, #debuffs.list do
		if not debuffs.list[i].own then other = i end
	end
	check("frames/unknown duration gets no swipe",
		other ~= nil and not debuffs.buttons[other].cooldown:IsShown())
end

--------------------------------------------------------------------------------
-- 10. Shapeshift mana (SPEC §4.2)
--------------------------------------------------------------------------------

local function testShapeshiftMana()
	local mana = ns.elements.mana
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")

	-- The player is currently in RAGE form with a mana pool: the generic
	-- predicate must fire without any class check.
	check("mana/predicate fires while shifted", mana.ShouldShow(player, cfg.mana))

	player:FullUpdate()
	local el = player.elements.mana
	check("mana/bar shown while shifted", el ~= nil and el.shown)
	equal("mana/value tracks true mana", el.bar:GetValue(), 3000)

	local tickersBefore = stub.activeTickers()
	check("mana/fallback ticker running while visible", tickersBefore > 0)

	-- Back to caster form: displayed power becomes mana, bar must disappear.
	stub.units.player.powerType = 0
	stub.units.player.powerToken = "MANA"
	check("mana/predicate stops in caster form", not mana.ShouldShow(player, cfg.mana))
	player:FullUpdate()
	check("mana/bar hidden in caster form", not el.shown)
	check("mana/ticker stopped when the bar hides", not mana.IsTicking())

	-- And back again
	stub.units.player.powerType = 1
	stub.units.player.powerToken = "RAGE"
	player:FullUpdate()
	check("mana/bar returns on reshift", el.shown)
	check("mana/ticker restarted", mana.IsTicking())

	-- Append mode must not change the button's own height (that would be a
	-- protected call in combat).
	equal("mana/append mode leaves the frame height alone", player:GetHeight(), cfg.height)

	-- Reserve mode shortens the health bar instead
	cfg.mana.mode = "reserve"
	player:LayoutBars()
	local expected = cfg.height - cfg.power.height - cfg.power.spacing
		- cfg.mana.height - cfg.mana.spacing
	equal("mana/reserve mode shortens the health bar",
		player.elements.health.bar:GetHeight(), expected)
	cfg.mana.mode = "append"
	player:LayoutBars()
end

--------------------------------------------------------------------------------
-- 11. Derived poller (SPEC §FR-8.3, risk R13)
--------------------------------------------------------------------------------

local function testDerivedPoller()
	local Poller = ns.DerivedPoller
	local tot = ns.frames.targettarget

	-- No target's target exists, so nothing derived should be visible and the
	-- ticker must be stopped. This is the exact failure mode R13 describes.
	tot:Hide()
	if ns.frames.focustarget then ns.frames.focustarget:Hide() end
	check("poller/stopped when nothing derived is visible", not Poller:IsRunning())
	equal("poller/no active frames", Poller:ActiveCount(), 0)

	stub.setUnit("targettarget", {
		name = "Sheep", level = 60, health = 50, healthMax = 100, reaction = 2,
	})
	tot:Show()
	check("poller/starts when a derived frame appears", Poller:IsRunning())
	equal("poller/one active frame", Poller:ActiveCount(), 1)

	tot:Hide()
	check("poller/stops again when the last one hides", not Poller:IsRunning())

	-- Interval clamping
	ns:General().derivedPollInterval = 5
	Poller:Reconfigure()
	equal("poller/interval clamped to the maximum", Poller:Interval(), 1.0)
	ns:General().derivedPollInterval = 0.01
	Poller:Reconfigure()
	equal("poller/interval clamped to the minimum", Poller:Interval(), 0.1)
	ns:General().derivedPollInterval = 0.25
	Poller:Reconfigure()
end

--------------------------------------------------------------------------------
-- 12. Party group and combat safety
--------------------------------------------------------------------------------

local function testPartyGroup()
	local PartyGroup = ns.PartyGroup
	local group = ns:Profile().partyGroup

	check("party/group owns party2 by default", PartyGroup:Owns("party2"))
	local relative, point, relativePoint, x, y = PartyGroup:ResolveAnchor("party2")
	equal("party/party2 chains off party1", relative, ns.frames.party1)
	equal("party/growth down anchors top to bottom", point, "TOPLEFT")
	equal("party/spacing applied", y, -group.spacing)

	relative = PartyGroup:ResolveAnchor("party1")
	equal("party/party1 takes the group anchor", relative, UIParent)

	-- Detaching hands control back to the frame's own anchor
	ns:UnitConfig("party2").detached = true
	check("party/detached frame is not group-owned", not PartyGroup:Owns("party2"))
	ns:UnitConfig("party2").detached = false

	-- Solo with showWhenSolo off: suppressed
	stub.inGroup = false
	group.showWhenSolo = false
	check("party/suppressed while solo", PartyGroup:ShouldSuppress())

	stub.inGroup = true
	check("party/shown in a party", not PartyGroup:ShouldSuppress())

	stub.inRaid = true
	check("party/hidden in a raid by default", PartyGroup:ShouldSuppress())
	group.hideInRaid = false
	check("party/shown in a raid when told to", not PartyGroup:ShouldSuppress())
	group.hideInRaid = true
	stub.inRaid = false

	-- FR-6.5 / R12: a roster change mid-combat must queue, not error.
	stub.inCombat = true
	ns.CombatQueue:Clear()
	local errored = false
	local success = pcall(function() PartyGroup:UpdateVisibility() end)
	errored = not success
	check("party/roster change in combat does not error", not errored)
	check("party/roster change in combat queues instead",
		ns.CombatQueue:PendingCount() > 0)
	stub.inCombat = false
	ns.CombatQueue:Flush()
	equal("party/queue drained on combat exit", ns.CombatQueue:PendingCount(), 0)
end

--------------------------------------------------------------------------------
-- 13. Circuit breaker (SPEC §5.9)
--------------------------------------------------------------------------------

local function testCircuitBreaker()
	local Errors = ns.Errors
	Errors:Reset()
	Errors.threshold = 3

	for i = 1, 3 do
		Errors:Guard("test:element", function() error("boom") end)
	end

	check("errors/disabled after the threshold", Errors:IsDisabled("test:element"))

	local ran = false
	Errors:Guard("test:element", function() ran = true end)
	check("errors/disabled context is skipped", not ran)

	check("errors/something else still runs",
		Errors:Guard("test:other", function() return true end))

	Errors:Reset("test:element")
	check("errors/reset re-enables", not Errors:IsDisabled("test:element"))

	-- The first failure must report WHAT broke, not just that something did.
	-- Otherwise diagnosing anything needs debug mode plus a reproduction, and
	-- by then the breaker has usually already disabled it.
	Errors:Reset()
	local before = #stub.chat
	Errors:Guard("test:message", function()
		error("Interface\\AddOns\\DyrueUnitFrames\\Elements\\Auras.lua:123: boom", 0)
	end)
	local printed = table.concat(stub.chat, "\n", before + 1, #stub.chat)
	check("errors/first failure prints the message", printed:find("boom", 1, true) ~= nil, printed)
	check("errors/message names the file and line",
		printed:find("Auras.lua:123", 1, true) ~= nil, printed)
	check("errors/full interface path is stripped",
		printed:find("Interface\\AddOns", 1, true) == nil, printed)

	local stored = Errors:LastError("test:message")
	check("errors/last message is retrievable for /duf errors",
		stored ~= nil and stored:find("boom", 1, true) ~= nil, tostring(stored))

	-- A very long message is truncated rather than flooding chat.
	Errors:Reset()
	Errors:Guard("test:long", function() error(string.rep("x", 900), 0) end)
	check("errors/long message truncated", #Errors:LastError("test:long") < 300)

	Errors:Reset()

	-- Safe mode allows bars and refuses text and auras
	Errors.safeMode = true
	check("safemode/health allowed", Errors:IsElementAllowed("health"))
	check("safemode/power allowed", Errors:IsElementAllowed("power"))
	check("safemode/shapeshift mana allowed", Errors:IsElementAllowed("mana"))
	check("safemode/text refused", not Errors:IsElementAllowed("text"))
	check("safemode/auras refused", not Errors:IsElementAllowed("auras"))
	check("safemode/portrait refused", not Errors:IsElementAllowed("portrait"))
	Errors.safeMode = false

	Errors.threshold = 5
	Errors:Reset()
end

--------------------------------------------------------------------------------
-- 14. Options tree well-formedness
--------------------------------------------------------------------------------

local VALID_TYPES = {
	group = true, execute = true, input = true, toggle = true, range = true,
	select = true, multiselect = true, color = true, keybinding = true,
	header = true, description = true,
}

local function validateOptions(node, path, report)
	if type(node) ~= "table" then
		report[#report + 1] = path .. ": not a table"
		return
	end
	if not node.type then
		report[#report + 1] = path .. ": missing type"
		return
	end
	if not VALID_TYPES[node.type] then
		report[#report + 1] = path .. ": unknown type '" .. tostring(node.type) .. "'"
	end
	if node.type == "group" then
		if type(node.args) ~= "table" then
			report[#report + 1] = path .. ": group without args"
		else
			for key, child in pairs(node.args) do
				validateOptions(child, path .. "." .. tostring(key), report)
			end
		end
	end
	-- A `values` table or function is mandatory for select/multiselect.
	if node.type == "select" or node.type == "multiselect" then
		if node.values == nil then
			report[#report + 1] = path .. ": " .. node.type .. " without values"
		end
	end
	if node.type == "range" then
		if node.min and node.max and node.min > node.max then
			report[#report + 1] = path .. ": range min > max"
		end
		if node.softMin and node.min and node.softMin < node.min then
			report[#report + 1] = path .. ": softMin below min"
		end
		if node.softMax and node.max and node.softMax > node.max then
			report[#report + 1] = path .. ": softMax above max"
		end
	end
end

local function testOptions()
	local tree = ns.Options.table
	check("options/tree built", tree ~= nil and tree.args ~= nil)

	local report = {}
	validateOptions(tree, "root", report)
	if #report == 0 then
		ok("options/tree is well formed")
	else
		fail("options/tree is well formed", table.concat(report, "; "))
	end

	-- FR-8.5: on a client without focus, the focus subtrees must be ABSENT.
	check("options/focus present on TBC", tree.args.units.args.focus ~= nil)
	check("options/party present", tree.args.units.args.party1 ~= nil)
	check("options/party pets present", tree.args.units.args.partypet1 ~= nil)

	-- FR-1.2: every position/size control must be a range with a soft slider
	-- bound and a wider typed bound.
	local layout = tree.args.units.args.player.args.layout.args
	local width = layout.size.args.width
	equal("options/width is a range", width.type, "range")
	check("options/width slider is bounded", width.softMin and width.softMax)
	check("options/typed width can exceed the slider", width.max > width.softMax)

	local x = layout.position.args.x
	equal("options/x offset is a range", x.type, "range")
	check("options/x offset accepts values beyond the slider", x.max > x.softMax)

	-- Round-trip a typed value through the option's own get/set.
	x.set(nil, 1234)
	equal("options/typed value stored", ns:UnitConfig("player").anchor.x, 1234)
	equal("options/getter reflects it", x.get(nil), 1234)
	x.set(nil, 0)

	-- The color swatch is only offered when something reads it.
	local healthArgs = tree.args.units.args.player.args.health.args
	local healthCfg = ns:UnitConfig("player").health

	healthCfg.colorMode = "class"
	healthCfg.npcFallback = "reaction"
	check("options/swatch hidden in class mode with a reaction fallback",
		healthArgs.color.hidden())

	healthCfg.npcFallback = "static"
	check("options/swatch shown when it is the NPC fallback",
		not healthArgs.color.hidden())
	equal("options/swatch is relabelled as the NPC fallback",
		healthArgs.color.name(), "Color for NPCs")

	healthCfg.colorMode = "static"
	check("options/swatch shown in static mode", not healthArgs.color.hidden())
	equal("options/swatch is plainly the color in static mode",
		healthArgs.color.name(), "Color")

	healthCfg.colorMode = "reaction"
	check("options/swatch hidden in reaction mode", healthArgs.color.hidden())
	healthCfg.colorMode = "gradient"
	check("options/swatch hidden in gradient mode", healthArgs.color.hidden())

	healthCfg.colorMode = "static"
	healthCfg.npcFallback = "reaction"

	-- Color round trip
	local color = tree.args.units.args.player.args.health.args.color
	equal("options/health color is a color control", color.type, "color")
	color.set(nil, 0.1, 0.2, 0.3, 1)
	local r, g, b = color.get(nil)
	check("options/color round trip", r == 0.1 and g == 0.2 and b == 0.3)

	-- The text and aura subtrees exist for every unit
	check("options/text subtree", tree.args.units.args.target.args.texts ~= nil)
	check("options/aura subtree", tree.args.units.args.target.args.auras.args.buffs ~= nil)
end

--------------------------------------------------------------------------------
-- 15. Focus gating on Classic Era (SPEC §FR-8.5, AC 14)
--------------------------------------------------------------------------------

local function testFocusGating()
	local Registry = ns.Registry
	local Compat = ns.Compat

	Compat.SetFocusOverride("off")
	check("focus/unavailable when the probe says no", not Registry:IsAvailable("focus"))
	check("focus/focustarget unavailable too", not Registry:IsAvailable("focustarget"))

	local available = Registry:SortedAvailable()
	local found = false
	for _, def in ipairs(available) do
		if def.key == "focus" or def.key == "focustarget" then found = true end
	end
	check("focus/absent from the available roster", not found)

	-- Rebuilding the options tree must leave the focus subtrees out entirely.
	ns.Options:Build()
	check("focus/options subtree absent", ns.Options.table.args.units.args.focus == nil)
	check("focus/focustarget options absent", ns.Options.table.args.units.args.focustarget == nil)

	-- And anchor targets must not offer them either.
	local values = ns.Anchoring:TargetValues("target")
	check("focus/not offered as an anchor target", values.focus == nil)

	Compat.SetFocusOverride("auto")
	ns.Options:Build()
	check("focus/restored when available", ns.Options.table.args.units.args.focus ~= nil)
end

--------------------------------------------------------------------------------
-- 16. AC 4: a layout change attempted in combat queues and applies on exit
--------------------------------------------------------------------------------

local function testCombatDeferral()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")
	ns.CombatQueue:Clear()

	local originalWidth = player:GetWidth()

	stub.inCombat = true
	local tree = ns.Options.table
	local widthOption = tree.args.units.args.player.args.layout.args.size.args.width

	local success = pcall(function() widthOption.set(nil, 350) end)
	check("combat/setting a width in combat does not error", success)

	-- The VALUE is stored immediately so the options panel reflects intent...
	equal("combat/value stored immediately", cfg.width, 350)
	equal("combat/getter shows the new value", widthOption.get(nil), 350)
	-- ...but the visual application waits.
	equal("combat/frame not resized yet", player:GetWidth(), originalWidth)
	check("combat/change is queued", ns.CombatQueue:IsPending())
	check("combat/notice is shown", ns.CombatQueue:StatusText() ~= nil)

	stub.inCombat = false
	ns.CombatQueue:Flush()
	equal("combat/applied on leaving combat", player:GetWidth(), 350)
	check("combat/notice cleared", ns.CombatQueue:StatusText() == nil)

	widthOption.set(nil, 220)
	equal("combat/restored", player:GetWidth(), 220)
end

--------------------------------------------------------------------------------
-- 17. AC 3: dragging writes back to the same stored numbers
--------------------------------------------------------------------------------

local function testDragMode()
	local DragMode = ns.DragMode
	local anchor = ns:UnitConfig("target").anchor
	anchor.to = "UIParent"
	anchor.point = "CENTER"
	anchor.relativePoint = "CENTER"
	anchor.x, anchor.y = 0, 0

	stub.inCombat = true
	DragMode:Toggle(true)
	check("drag/refuses to unlock in combat", not DragMode:IsActive())
	stub.inCombat = false

	DragMode:Toggle(true)
	check("drag/unlocks out of combat", DragMode:IsActive())

	-- Simulate a drop: place the frame somewhere and let the commit maths turn
	-- that into anchor offsets.
	local frame = ns.frames.target
	local ui = _G.UIParent
	ui.__left, ui.__bottom = 0, 0
	ui.__w, ui.__h = 1920, 1080
	frame.__left, frame.__bottom = 1060, 640    -- center would be 1060+110, 640+24
	frame.__w, frame.__h = 220, 48

	local overlay
	for _, f in ipairs(stub.frames) do
		if f.frame == frame and f.__scripts.OnDragStop then overlay = f end
	end
	check("drag/overlay created", overlay ~= nil)

	overlay.dragging = true
	overlay.__scripts.OnDragStop(overlay)

	-- Frame center (1170, 664) minus UIParent center (960, 540)
	near("drag/x written back", ns:UnitConfig("target").anchor.x, 210)
	near("drag/y written back", ns:UnitConfig("target").anchor.y, 124)

	-- Grid snap rounds those to the configured grid
	ns:General().gridSnap = true
	ns:General().gridSize = 8
	overlay.dragging = true
	overlay.__scripts.OnDragStop(overlay)
	equal("drag/x snapped to the grid", ns:UnitConfig("target").anchor.x % 8, 0)
	equal("drag/y snapped to the grid", ns:UnitConfig("target").anchor.y % 8, 0)
	ns:General().gridSnap = false

	-- Arrow-key nudge writes to the same values
	local before = ns:UnitConfig("target").anchor.x
	ns:General().nudgeStep = 1
	overlay.__scripts.OnKeyDown(overlay, "RIGHT")
	equal("drag/arrow key nudges the stored value",
		ns:UnitConfig("target").anchor.x, before + 1)
	overlay.__scripts.OnKeyDown(overlay, "LEFT")
	equal("drag/nudge is reversible", ns:UnitConfig("target").anchor.x, before)

	-- An unrelated key must not be swallowed
	local handled = pcall(overlay.__scripts.OnKeyDown, overlay, "A")
	check("drag/unhandled key does not error", handled)

	DragMode:Toggle(false)
	check("drag/locks again", not DragMode:IsActive())

	anchor.x, anchor.y = 180, -140
	ns.Anchoring:Apply("target")
end

--------------------------------------------------------------------------------
-- 18. AC 6 / 7: color rules and difficulty color on a real text element
--------------------------------------------------------------------------------

local function testTextColoring()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")

	-- FR-3.3: color the NAME by the unit's HEALTH. The metric under test is
	-- deliberately unrelated to the element being colored.
	local nameText = cfg.texts[1]
	nameText.colorMode = "rules"
	nameText.color = { r = 1, g = 1, b = 1 }
	nameText.rules = {
		{ enabled = true, metric = "health.percent", op = "<=", value = 35,
		  color = { r = 1, g = 0.5, b = 0 } },
		{ enabled = true, metric = "health.current", op = "<=", value = 500,
		  color = { r = 1, g = 0, b = 0 } },
	}
	ns:BumpSerial()
	ns:RefreshUnit("player")

	local fs = player.elements.text.strings[1]

	stub.units.player.health = 5000
	player:FullUpdate()
	local r, g, b = fs:GetTextColor()
	check("text/no rule matches at full health", r == 1 and g == 1 and b == 1)

	stub.units.player.health = 1500      -- 30%
	player:FullUpdate()
	r, g, b = fs:GetTextColor()
	check("text/percentage rule colors the name", r == 1 and g == 0.5 and b == 0)

	-- Absolute rule first this time
	nameText.rules[1], nameText.rules[2] = nameText.rules[2], nameText.rules[1]
	ns:BumpSerial()
	stub.units.player.health = 400
	player:FullUpdate()
	r, g, b = fs:GetTextColor()
	check("text/absolute rule colors the name", r == 1 and g == 0 and b == 0)

	stub.units.player.health = 4200
	nameText.colorMode = "static"
	nameText.rules = {}
	ns:BumpSerial()
	ns:RefreshUnit("player")

	-- AC 7: difficulty color must equal the game's own function at every
	-- level difference, including the ?? case.
	local target = ns.frames.target
	local levelText = ns:UnitConfig("target").texts[1]
	equal("text/level defaults to difficulty coloring", levelText.colorMode, "difficulty")

	local levelString = target.elements.text.strings[1]
	local mismatches = 0
	for difference = -8, 8 do
		stub.units.target.level = 60 + difference
		target:FullUpdate()
		local expected = _G.GetCreatureDifficultyColor(60 + difference)
		local ar, ag, ab = levelString:GetTextColor()
		if math.abs(ar - expected.r) > 0.001 or math.abs(ag - expected.g) > 0.001
			or math.abs(ab - expected.b) > 0.001 then
			mismatches = mismatches + 1
		end
	end
	equal("text/difficulty color matches the base game at -8..+8", mismatches, 0)

	stub.units.target.level = -1
	target:FullUpdate()
	equal("text/unknown level renders ??", levelString:GetText(), "????")
	r = levelString:GetTextColor()
	near("text/unknown level uses the boss color", r, 1)
end

--------------------------------------------------------------------------------
-- 19. Aura filtering and sorting
--------------------------------------------------------------------------------

local function testAuraFiltering()
	local target = ns.frames.target
	local buffs = ns:UnitConfig("target").auras.buffs

	local function refresh()
		ns:BumpSerial()
		ns:RefreshUnit("target")
		return target.elements.auras.buffs.list
	end

	equal("auras/both buffs by default", #refresh(), 2)

	buffs.onlyOwn = true
	local list = refresh()
	equal("auras/only-own filters to one", #list, 1)
	equal("auras/the remaining one is yours", list[1].name, "Blessing")
	buffs.onlyOwn = false

	buffs.hidePermanent = true
	list = refresh()
	equal("auras/hide-permanent drops the durationless one", #list, 1)
	buffs.hidePermanent = false

	buffs.useBlacklist = true
	buffs.blacklist = { "Blessing" }
	list = refresh()
	equal("auras/blacklist by name", #list, 1)
	equal("auras/blacklisted one is gone", list[1].name, "Fortitude")

	buffs.blacklist = { "1002" }
	list = refresh()
	equal("auras/blacklist by spell id", #list, 1)
	equal("auras/id blacklist removed the right one", list[1].name, "Blessing")
	buffs.useBlacklist = false

	buffs.useWhitelist = true
	buffs.whitelist = { "Fortitude" }
	list = refresh()
	equal("auras/whitelist keeps only listed", #list, 1)
	equal("auras/whitelisted one kept", list[1].name, "Fortitude")
	buffs.useWhitelist = false

	buffs.minDuration = 600
	list = refresh()
	equal("auras/minimum duration drops the short one, keeps the permanent one", #list, 1)
	equal("auras/permanent aura is unaffected by minimum duration", list[1].name, "Fortitude")
	buffs.minDuration = 0

	-- Sorting
	buffs.sort = "name"
	list = refresh()
	equal("auras/alphabetical sort", list[1].name, "Blessing")

	buffs.sort = "index"
	list = refresh()
	equal("auras/game order sort", list[1].index, 1)

	buffs.sort = "own_time"
	list = refresh()
	check("auras/own-first sort", list[1].own == true)

	-- FR-5.3: own auras are larger, and bordered in the chosen color
	buffs.borderMode = "own"
	buffs.ownBorderColor = { r = 1, g = 0.85, b = 0.1, a = 1 }
	buffs.ownSizeMultiplier = 2
	refresh()
	local group = target.elements.auras.buffs
	equal("auras/own aura scaled by the multiplier",
		group.buttons[1]:GetWidth(), buffs.size * 2)
	equal("auras/other aura at base size", group.buttons[2]:GetWidth(), buffs.size)
	local border = group.buttons[1].border.__color
	check("auras/own aura border color applied",
		border and border[1] == 1 and math.abs(border[2] - 0.85) < 0.001)
	buffs.ownSizeMultiplier = 1.4

	-- FR-5.4: debuff-type borders come from the game's own table
	local debuffs = ns:UnitConfig("target").auras.debuffs
	debuffs.borderMode = "type"
	ns:BumpSerial()
	ns:RefreshUnit("target")
	local debuffGroup = target.elements.auras.debuffs
	local curseIndex
	for i = 1, #debuffGroup.list do
		if debuffGroup.list[i].dispelType == "Curse" then curseIndex = i end
	end
	check("auras/curse found", curseIndex ~= nil)
	if curseIndex then
		local c = debuffGroup.buttons[curseIndex].border.__color
		local expected = _G.DebuffTypeColor.Curse
		check("auras/curse border uses the game's color",
			c and math.abs(c[1] - expected.r) < 0.001 and math.abs(c[3] - expected.b) < 0.001)
	end

	-- An aura group must never be shown more icons than its grid has cells.
	buffs.perRow, buffs.rows, buffs.maxShown = 1, 1, 32
	ns:BumpSerial()
	ns:RefreshUnit("target")
	group = target.elements.auras.buffs
	check("auras/never more icons than grid cells",
		not (group.buttons[2] and group.buttons[2]:IsShown()))
	buffs.perRow, buffs.rows = 8, 4
	ns:BumpSerial()
	ns:RefreshUnit("target")
end

--------------------------------------------------------------------------------
-- 20. AC 13: derived identity updates on UNIT_TARGET
--------------------------------------------------------------------------------

local function testDerivedIdentity()
	local tot = ns.frames.targettarget

	stub.setUnit("targettarget", {
		name = "First", level = 60, health = 40, healthMax = 100, reaction = 2,
	})
	tot:Show()
	tot:FullUpdate()

	local nameString = tot.elements.text.strings[1]
	equal("derived/initial name", nameString:GetText(), "First")

	-- UNIT_TARGET fires with the OWNING unit as payload.
	stub.setUnit("targettarget", {
		name = "Second", level = 60, health = 90, healthMax = 100, reaction = 2,
	})
	stub.fire("UNIT_TARGET", "target")
	equal("derived/identity updated by UNIT_TARGET on the owner",
		nameString:GetText(), "Second")

	-- A UNIT_TARGET for an unrelated unit must be ignored.
	stub.setUnit("targettarget", {
		name = "Third", level = 60, health = 10, healthMax = 100, reaction = 2,
	})
	stub.fire("UNIT_TARGET", "party1")
	equal("derived/unrelated UNIT_TARGET ignored", nameString:GetText(), "Second")

	-- The shared poller catches it on the next tick instead.
	for _, ticker in ipairs(stub.tickers) do
		if not ticker.canceled and ticker.interval == 0.25 then ticker.callback() end
	end
	equal("derived/poller picks up the change", nameString:GetText(), "Third")

	-- AC 16 / FR-8.7: enemy health on a derived unit must not fabricate numbers.
	local healthString = tot.elements.text.strings[2]
	equal("derived/health renders as a percentage only", healthString:GetText(), "10%")

	tot:Hide()
	stub.units.targettarget = nil
end

--------------------------------------------------------------------------------
-- 21. Copy settings, test mode, safe mode
--------------------------------------------------------------------------------

local function testToolsAndModes()
	-- PLAN 2.7: copy everything except the anchor.
	local source = ns:UnitConfig("player")
	local destination = ns:UnitConfig("focus")
	source.health.colorMode = "gradient"
	source.width = 333
	local focusAnchorX = destination.anchor.x

	check("tools/copy succeeds", ns.Factory:CopySettings("player", "focus"))
	destination = ns:UnitConfig("focus")
	equal("tools/settings copied", destination.width, 333)
	equal("tools/color mode copied", destination.health.colorMode, "gradient")
	equal("tools/anchor deliberately not copied", destination.anchor.x, focusAnchorX)
	check("tools/copy is deep, not shared", destination.health ~= source.health)

	source.health.colorMode = "static"
	source.width = 220
	ns.Defaults:ResetUnit(ns:Profile(), "focus")
	ns:RefreshUnit("focus")

	-- Test mode
	local TestMode = ns.TestMode
	stub.units.focus = nil
	check("testmode/focus unit does not exist", not UnitExists("focus"))

	TestMode:Enable()
	check("testmode/active", TestMode:IsActive())
	local focusFrame = ns.frames.focus
	check("testmode/nonexistent unit's frame is shown anyway", focusFrame:IsShown())
	equal("testmode/substitutes a real unit", focusFrame.unit, "player")
	check("testmode/identity is faked", focusFrame.test ~= nil)

	local focusName = focusFrame.elements.text.strings[1]
	check("testmode/fake name rendered, not the player's",
		focusName:GetText() ~= "Dyrue" and focusName:GetText() ~= nil,
		tostring(focusName:GetText()))

	-- Party frames get distinct class colors so class coloring is visible
	local party1 = ns.frames.party1
	check("testmode/party frame gets a stand-in class", party1.test.classFile ~= nil)

	TestMode:Disable()
	check("testmode/inactive", not TestMode:IsActive())
	equal("testmode/unit restored", focusFrame.unit, "focus")
	check("testmode/identity override cleared", focusFrame.test == nil)

	-- Safe mode: rebuild with it on and confirm text and auras are gone
	ns.Errors.safeMode = true
	ns:RefreshUnit("target")
	ns.CombatQueue:Flush()
	local target = ns.frames.target
	check("safemode/health still active", target.activeElements.health ~= nil)
	check("safemode/text disabled", target.activeElements.text == nil)
	check("safemode/auras disabled", target.activeElements.auras == nil)

	ns.Errors.safeMode = false
	ns:RefreshUnit("target")
	ns.CombatQueue:Flush()
	check("safemode/text restored afterwards", target.activeElements.text ~= nil)
	check("safemode/auras restored afterwards", target.activeElements.auras ~= nil)
end

--------------------------------------------------------------------------------
-- 22. Slash commands
--------------------------------------------------------------------------------

local function testSlashCommands()
	local handler = stub.slash and stub.slash.duf
	check("slash/registered", handler ~= nil)
	if not handler then return end

	local addon = stub.addon
	local commands = { "", "help", "tags", "compat", "profile", "errors",
		"blizzard hide", "blizzard none", "reset player", "reset nosuchunit" }

	local failures = {}
	for _, command in ipairs(commands) do
		local success, err = pcall(addon.SlashCommand, addon, command)
		if not success then
			failures[#failures + 1] = command .. ": " .. tostring(err)
		end
	end
	if #failures == 0 then
		ok("slash/every command runs without error")
	else
		fail("slash/every command runs without error", table.concat(failures, "; "))
	end

	equal("slash/blizzard none applied", ns:General().blizzardFrames, "none")

	-- Toggles must round-trip rather than getting stuck.
	local before = ns:Global().debug
	addon:SlashCommand("debug")
	check("slash/debug toggled", ns:Global().debug ~= before)
	addon:SlashCommand("debug")
	equal("slash/debug toggled back", ns:Global().debug, before)
end

--------------------------------------------------------------------------------
-- 23. Opacity, scale and strata reach the frame
--------------------------------------------------------------------------------

local function testFrameAppearance()
	local player = ns.frames.player
	local layout = ns.Options.table.args.units.args.player.args.layout.args.size.args

	-- Opacity
	equal("appearance/opacity control exists", layout.alpha.type, "range")
	layout.alpha.set(nil, 0.5)
	equal("appearance/opacity stored", ns:UnitConfig("player").alpha, 0.5)
	equal("appearance/opacity getter round-trips", layout.alpha.get(nil), 0.5)
	equal("appearance/opacity reaches the frame", player:GetAlpha(), 0.5)

	layout.alpha.set(nil, 0.25)
	equal("appearance/opacity updates again", player:GetAlpha(), 0.25)

	-- Every other frame must be unaffected
	equal("appearance/opacity is per-unit", ns.frames.target:GetAlpha(), 1)

	layout.alpha.set(nil, 1)
	equal("appearance/opacity restored", player:GetAlpha(), 1)

	-- Scale
	layout.scale.set(nil, 1.5)
	equal("appearance/scale stored", ns:UnitConfig("player").scale, 1.5)
	equal("appearance/scale reaches the frame", player:GetEffectiveScale(), 1.5)
	layout.scale.set(nil, 1)

	-- Strata
	layout.strata.set(nil, "HIGH")
	equal("appearance/strata reaches the frame", player:GetFrameStrata(), "HIGH")
	layout.strata.set(nil, "MEDIUM")

	-- A change made in combat must still land on the frame afterwards.
	stub.inCombat = true
	layout.alpha.set(nil, 0.4)
	equal("appearance/opacity deferred in combat", player:GetAlpha(), 1)
	stub.inCombat = false
	ns.CombatQueue:Flush()
	equal("appearance/opacity applied on combat exit", player:GetAlpha(), 0.4)
	layout.alpha.set(nil, 1)
end

--------------------------------------------------------------------------------
-- 24. Bar textures
--------------------------------------------------------------------------------

local function testTextures()
	local cfg = ns:UnitConfig("player")

	equal("texture/health default", cfg.health.texture, "Dyrue Flat")
	equal("texture/power default", cfg.power.texture, "Dyrue Flat")
	equal("texture/mana default", cfg.mana.texture, "Dyrue Flat")

	-- The cosmetic defaults live in the shared unit template, so they must
	-- reach EVERY unit, not just the player. A per-unit override quietly
	-- reintroducing one of them is exactly the regression to guard against.
	local offenders = {}
	for _, def in ipairs(ns.Registry:SortedAvailable()) do
		local unitCfg = ns:UnitConfig(def.key)
		for _, bar in ipairs({ "health", "power", "mana" }) do
			if unitCfg[bar].texture ~= "Dyrue Flat" then
				offenders[#offenders + 1] = def.key .. "." .. bar .. "=" .. tostring(unitCfg[bar].texture)
			end
		end
		if unitCfg.power.spacing ~= 0 then
			offenders[#offenders + 1] = def.key .. ".power.spacing=" .. tostring(unitCfg.power.spacing)
		end
		if unitCfg.mana.spacing ~= 0 then
			offenders[#offenders + 1] = def.key .. ".mana.spacing=" .. tostring(unitCfg.mana.spacing)
		end
		if unitCfg.background.enabled ~= false then
			offenders[#offenders + 1] = def.key .. ".background.enabled=true"
		end
	end
	if #offenders == 0 then
		ok("texture/every unit gets the flat texture, no gap and no backdrop")
	else
		fail("texture/every unit gets the flat texture, no gap and no backdrop",
			table.concat(offenders, ", "))
	end

	-- The texture must resolve to a real path, not nil.
	local path = ns:Texture("Dyrue Flat")
	check("texture/flat texture resolves", type(path) == "string" and #path > 0)

	-- The flat texture must come from base-game media, not from another addon.
	check("texture/flat texture is base-game media",
		path:find("Interface\\") == 1 and not path:find("AddOns"), path)

	-- An unknown texture name must fall back rather than blanking the bar.
	local fallback = ns:Texture("No Such Texture At All")
	check("texture/unknown name falls back", type(fallback) == "string" and #fallback > 0)

	-- And it must actually reach the bar and its background.
	local health = ns.frames.player.elements.health
	equal("texture/applied to the health bar", health.bar:GetStatusBarTexture(), path)
	equal("texture/applied to the bar background", health.bg:GetTexture(), path)
	equal("texture/applied to the power bar",
		ns.frames.player.elements.power.bar:GetStatusBarTexture(), path)

	-- Changing it through the options must apply.
	local option = ns.Options.table.args.units.args.player.args.health.args.texture
	option.set(nil, "Blizzard")
	equal("texture/option change applies",
		health.bar:GetStatusBarTexture(), ns:Texture("Blizzard"))
	option.set(nil, "Dyrue Flat")
	equal("texture/option change reverts", health.bar:GetStatusBarTexture(), path)
end

--------------------------------------------------------------------------------
-- 25. State indicators (Plan 1)
--------------------------------------------------------------------------------

local function indicatorSlot(icon, cfg)
	-- Offset along the growth axis, relative to the row's own anchor.
	local _, _, _, x, y = icon:GetPoint(1)
	return (x or 0) - (cfg.x or 0), (y or 0) - (cfg.y or 0)
end

local function testIndicators()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player").indicators
	local opts = ns.Options.table.args.units.args.player.args.indicators.args

	equal("indicators/on for the player by default", cfg.enabled, true)
	equal("indicators/off elsewhere by default",
		ns:UnitConfig("target").indicators.enabled, false)
	equal("indicators/anchored to the health bar", cfg.anchorTo, "health")
	equal("indicators/top left of it", cfg.point, "TOPLEFT")
	equal("indicators/no horizontal offset", cfg.x, 0)
	-- Raised off the name text. Fully clearing it needs y = 7 -- the name's top
	-- edge is at -13 on the shipped 48px frame and a 20px icon reaches y - 20 --
	-- but 5 was chosen by eye, clipping the top couple of pixels. Pinned so an
	-- accidental change is caught.
	equal("indicators/raised off the name text", cfg.y, 5)
	-- The floor: however it is tuned, the icon must never reach the text's
	-- vertical center, which is where it would start eating whole glyphs.
	check("indicators/icon never reaches the name's center line",
		cfg.y - cfg.size > -19,
		"y=" .. cfg.y .. " reaches " .. (cfg.y - cfg.size))
	equal("indicators/grows right", cfg.growth, "RIGHT")

	local el = player.elements.indicators
	check("indicators/element built", el ~= nil)
	if not el then return end

	local resting, combat = el.icons.resting, el.icons.combat

	-- Neither state active.
	stub.resting = false
	stub.units.player.inCombat = false
	player:FullUpdate()
	check("indicators/nothing shown when idle",
		not resting:IsShown() and not combat:IsShown())

	-- Combat only: it takes slot one rather than leaving a resting-shaped hole.
	stub.units.player.inCombat = true
	player:FullUpdate()
	check("indicators/combat shown", combat:IsShown())
	check("indicators/resting still hidden", not resting:IsShown())
	local cx = indicatorSlot(combat, cfg)
	equal("indicators/a lone combat icon sits at slot one", cx, 0)

	-- Resting only.
	stub.units.player.inCombat = false
	stub.resting = true
	player:FullUpdate()
	check("indicators/resting shown", resting:IsShown())
	check("indicators/combat hidden", not combat:IsShown())
	equal("indicators/a lone resting icon sits at slot one", indicatorSlot(resting, cfg), 0)

	-- Both: resting first, then combat, as requested.
	stub.units.player.inCombat = true
	player:FullUpdate()
	check("indicators/both shown", resting:IsShown() and combat:IsShown())
	equal("indicators/resting is first", indicatorSlot(resting, cfg), 0)
	equal("indicators/combat is second", indicatorSlot(combat, cfg), cfg.size + cfg.spacing)

	-- Growth direction.
	opts.growth.set(nil, "LEFT")
	player:FullUpdate()
	equal("indicators/growing left puts the second icon to the left",
		indicatorSlot(combat, cfg), -(cfg.size + cfg.spacing))

	opts.growth.set(nil, "DOWN")
	player:FullUpdate()
	local _, dy = indicatorSlot(combat, cfg)
	equal("indicators/growing down puts the second icon below",
		dy, -(cfg.size + cfg.spacing))

	opts.growth.set(nil, "UP")
	player:FullUpdate()
	local _, uy = indicatorSlot(combat, cfg)
	equal("indicators/growing up puts the second icon above", uy, cfg.size + cfg.spacing)
	opts.growth.set(nil, "RIGHT")

	-- Turning one state off frees its slot for the other.
	opts.enabled_resting.set(nil, false)
	player:FullUpdate()
	check("indicators/disabled state is hidden", not resting:IsShown())
	equal("indicators/combat moves up to slot one", indicatorSlot(combat, cfg), 0)
	opts.enabled_resting.set(nil, true)

	-- Resting is a fact about you, not about a unit.
	local target = ns.frames.target
	ns:UnitConfig("target").indicators.enabled = true
	ns:BumpSerial()
	ns:RefreshUnit("target")
	ns.CombatQueue:Flush()
	stub.units.target.inCombat = true
	target:FullUpdate()
	local targetEl = target.elements.indicators
	check("indicators/combat works on the target too", targetEl.icons.combat:IsShown())
	check("indicators/resting never shows on another unit",
		not targetEl.icons.resting:IsShown())
	stub.units.target.inCombat = nil
	ns:UnitConfig("target").indicators.enabled = false

	-- Drawn above the bars, like everything else on the overlay.
	equal("indicators/icons live on the overlay", combat:GetParent(), player.overlay)

	-- Anchored to a bar that is not showing: hide, like bar-anchored text.
	local playerCfg = ns:UnitConfig("player")
	playerCfg.indicators.anchorTo = "mana"
	playerCfg.mana.enabled = false
	ns:BumpSerial()
	ns:RefreshUnit("player")
	ns.CombatQueue:Flush()
	player:FullUpdate()
	check("indicators/hidden when the anchor bar is not showing",
		not resting:IsShown() and not combat:IsShown())

	stub.resting = false
	stub.units.player.inCombat = nil
	ns.Defaults:ResetUnit(ns:Profile(), "player")
	ns.Defaults:ResetUnit(ns:Profile(), "target")
	ns:BumpSerial()
	ns:RefreshUnit("player")
	ns:RefreshUnit("target")
	ns.CombatQueue:Flush()
end

--------------------------------------------------------------------------------
-- 26. Player buffs (Plan 4)
--
-- The aura suite only ever exercised the TARGET frame, with buffs enabled from
-- the start. Two paths were therefore never reached: the player's own auras,
-- which is the only case that builds a right-click-cancel overlay, and turning
-- a group off and on again.
--------------------------------------------------------------------------------

local function playerBuffGroup()
	local el = ns.frames.player.elements.auras
	return el and el.buffs
end

local function shownButtons(group)
	local shown, positions = 0, {}
	for i = 1, #group.buttons do
		local button = group.buttons[i]
		if button and button:IsShown() then
			shown = shown + 1
			local _, _, _, x, y = button:GetPoint(1)
			positions[#positions + 1] = string.format("%.2f,%.2f", x or 0, y or 0)
		end
	end
	return shown, positions
end

local function testPlayerBuffs()
	local player = ns.frames.player
	local buffs = ns.Options.table.args.units.args.player.args.auras.args.buffs.args

	-- Three of the player's own buffs, as in the report.
	stub.units.player.auras = {
		HELPFUL = {
			{ name = "Mark of the Wild", icon = 11, applications = 0, duration = 1800,
			  expirationTime = 2800, sourceUnit = "player", spellId = 3001, isHelpful = true },
			{ name = "Thorns", icon = 12, applications = 0, duration = 600,
			  expirationTime = 1600, sourceUnit = "player", spellId = 3002, isHelpful = true },
			{ name = "Omen of Clarity", icon = 13, applications = 0, duration = 0,
			  expirationTime = 0, sourceUnit = "player", spellId = 3003, isHelpful = true },
		},
		HARMFUL = {},
	}

	ns.Errors:Reset()
	buffs.enabled.set(nil, true)
	ns.CombatQueue:Flush()

	-- The symptom the user saw, asserted directly.
	local counts = ns.Errors:GetCounts()
	check("playerbuffs/updating player auras does not error",
		counts["player:auras"] == nil,
		"player:auras errored " .. tostring(counts["player:auras"]) .. " time(s)")

	local group = playerBuffGroup()
	check("playerbuffs/buff group built", group ~= nil)
	if not group then return end

	equal("playerbuffs/all three scanned", #group.list, 3)

	local shown, positions = shownButtons(group)
	equal("playerbuffs/all three shown", shown, 3)

	-- "I can't tell if they're all being put over the same spot" -- so check.
	local seen, duplicates = {}, 0
	for _, p in ipairs(positions) do
		if seen[p] then duplicates = duplicates + 1 end
		seen[p] = true
	end
	equal("playerbuffs/icons are at distinct positions", duplicates, 0)

	-- Own auras get a cancel overlay; nothing else does. This is the only path
	-- unique to the player's own buffs.
	check("playerbuffs/own buff has a cancel overlay", group.buttons[1].cancel ~= nil)
	check("playerbuffs/cancel overlay is a secure action button",
		group.buttons[1].cancel == nil or group.buttons[1].cancelFailed ~= true)

	-- Disable, then re-enable.
	buffs.enabled.set(nil, false)
	ns.CombatQueue:Flush()
	shown = shownButtons(group)
	equal("playerbuffs/all hidden when disabled", shown, 0)

	buffs.enabled.set(nil, true)
	ns.CombatQueue:Flush()
	shown = shownButtons(group)
	equal("playerbuffs/all back when re-enabled", shown, 3)

	-- And the design gap: once the breaker trips, ApplyConfig refuses to
	-- re-enable the element no matter what the checkbox says.
	ns.Errors.threshold = 1
	ns.Errors:Record("player:auras", "synthetic failure")
	check("playerbuffs/breaker trips", ns.Errors:IsDisabled("player:auras"))

	buffs.enabled.set(nil, false)
	ns.CombatQueue:Flush()
	buffs.enabled.set(nil, true)
	ns.CombatQueue:Flush()

	check("playerbuffs/re-enabling clears the breaker",
		not ns.Errors:IsDisabled("player:auras"))
	shown = shownButtons(playerBuffGroup())
	equal("playerbuffs/icons return after a breaker trip", shown, 3)

	ns.Errors.threshold = 5
	ns.Errors:Reset()

	-- "Degrade, never cascade" (SPEC §5.9). The right-click-cancel overlay and
	-- the cooldown swipe are conveniences built from Blizzard templates; a
	-- template that has moved must cost its own feature and nothing else.
	for _, template in ipairs({ "SecureActionButtonTemplate", "CooldownFrameTemplate" }) do
		buffs.enabled.set(nil, false)
		ns.CombatQueue:Flush()

		-- New buttons, so the guards are actually exercised.
		playerBuffGroup().buttons = {}
		stub.failTemplates[template] = true

		buffs.enabled.set(nil, true)
		ns.CombatQueue:Flush()

		local failCounts = ns.Errors:GetCounts()
		check("playerbuffs/" .. template .. " failure does not error the element",
			failCounts["player:auras"] == nil,
			tostring(failCounts["player:auras"]) .. " error(s)")

		local stillShown = shownButtons(playerBuffGroup())
		equal("playerbuffs/icons still display without " .. template, stillShown, 3)

		stub.failTemplates[template] = nil
		ns.Errors:Reset()
	end

	-- No secure overlay is built during combat: RegisterForClicks, SetAttribute
	-- and Hide are all protected, so a buff gained mid-fight would throw.
	buffs.enabled.set(nil, false)
	ns.CombatQueue:Flush()
	playerBuffGroup().buttons = {}
	stub.inCombat = true
	buffs.enabled.set(nil, true)
	ns.CombatQueue:Flush()

	local combatCounts = ns.Errors:GetCounts()
	check("playerbuffs/no error building auras in combat",
		combatCounts["player:auras"] == nil,
		tostring(combatCounts["player:auras"]) .. " error(s)")
	check("playerbuffs/no cancel overlay built in combat",
		playerBuffGroup().buttons[1] == nil or playerBuffGroup().buttons[1].cancel == nil)
	check("playerbuffs/combat failure is not permanent",
		playerBuffGroup().buttons[1] == nil or playerBuffGroup().buttons[1].cancelFailed ~= true)

	stub.inCombat = false
	ns.CombatQueue:Flush()
	player:FullUpdate()
	check("playerbuffs/overlay built once combat ends",
		playerBuffGroup().buttons[1].cancel ~= nil)

	ns.Errors:Reset()
	buffs.enabled.set(nil, false)
	ns.CombatQueue:Flush()
	stub.units.player.auras = nil
	ns.Defaults:ResetUnit(ns:Profile(), "player")
	ns:BumpSerial()
	ns:RefreshUnit("player")
	ns.CombatQueue:Flush()
end

--------------------------------------------------------------------------------
-- 26. Shapeshift mana readout
--
-- The bar appears and disappears with form, so its text has to as well.
--------------------------------------------------------------------------------

local function findManaText(frame)
	local cfg = ns:UnitConfig(frame.unitKey)
	for i = 1, #cfg.texts do
		if cfg.texts[i].anchorTo == "mana" then
			return i, frame.elements.text.strings[i]
		end
	end
end

local function testManaText()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")

	local index, fontString = findManaText(player)
	check("manatext/player ships with a mana readout", index ~= nil)
	if not index then return end

	equal("manatext/reads current mana", cfg.texts[index].format, "[mana:cur:short]")
	equal("manatext/matches the power bar's placement", cfg.texts[index].point,
		cfg.texts[3].point)
	equal("manatext/matches the power bar's size", cfg.texts[index].size, cfg.texts[3].size)

	-- Caster form: displayed power IS mana, so the bar is hidden and the text
	-- must go with it rather than floating over the power text.
	stub.units.player.powerType = 0
	stub.units.player.powerToken = "MANA"
	player:FullUpdate()
	check("manatext/bar hidden in caster form", not player.elements.mana.shown)
	check("manatext/text hidden with the bar", not fontString:IsShown())

	-- Shifted: rage displayed, mana pool retained.
	stub.units.player.powerType = 1
	stub.units.player.powerToken = "RAGE"
	player:FullUpdate()
	check("manatext/bar shown while shifted", player.elements.mana.shown)
	check("manatext/text shown with the bar", fontString:IsShown())
	-- :short, matching the power bar the user asked it to mirror.
	equal("manatext/shows true mana, not displayed power", fontString:GetText(), "3.0k")

	-- And it tracks the value.
	stub.units.player.powers[0] = 1500
	stub.fire("UNIT_POWER_UPDATE", "player")
	equal("manatext/tracks mana changes", fontString:GetText(), "1.5k")
	stub.units.player.powers[0] = 3000

	-- Anchored to the bar itself, not to the frame body.
	local _, relative = fontString:GetPoint(1)
	equal("manatext/anchored to the mana bar", relative, player.elements.mana.bar)

	-- The same rule protects any bar-anchored text: turn the power bar off and
	-- its readout goes too, rather than landing on the frame edge.
	local powerText = player.elements.text.strings[3]
	check("manatext/power text visible while the bar is", powerText:IsShown())
	cfg.power.enabled = false
	ns:BumpSerial()
	ns:RefreshUnit("player")
	check("manatext/power text hidden with its bar",
		not player.elements.text.strings[3]:IsShown())
	cfg.power.enabled = true

	ns.Defaults:ResetUnit(ns:Profile(), "player")
	ns:BumpSerial()
	ns:RefreshUnit("player")
end

--------------------------------------------------------------------------------
-- 26. Bar brightness
--------------------------------------------------------------------------------

local function testBrightness()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")
	local health = ns.Options.table.args.units.args.player.args.health.args

	-- A known color so the arithmetic is checkable.
	cfg.health.colorMode = "static"
	cfg.health.color = { r = 0.4, g = 0.8, b = 0.2, a = 1 }
	cfg.health.bgMultiplier = 0.5
	cfg.health.bgAlpha = 1
	ns:BumpSerial()
	ns:RefreshUnit("player")

	local bar, bg = player.elements.health.bar, player.elements.health.bg

	equal("brightness/health defaults to 0.8", cfg.health.brightness, 0.8)
	local r, g, b = bar:GetStatusBarColor()
	near("brightness/the 0.8 default is applied", g, 0.8 * 0.8)

	health.brightness.set(nil, 0.5)
	r, g, b = bar:GetStatusBarColor()
	near("brightness/halved red", r, 0.2)
	near("brightness/halved green", g, 0.4)
	near("brightness/halved blue", b, 0.1)

	-- The background derives from the bar color, so it must follow.
	near("brightness/background follows the bar", select(2, bg:GetVertexColor()), 0.4 * 0.5)

	health.brightness.set(nil, 1.5)
	r, g, b = bar:GetStatusBarColor()
	near("brightness/above 1 brightens", g, 1.0)   -- 0.8 * 1.5 clamps to 1
	near("brightness/unclamped channel still scales", r, 0.6)

	health.brightness.set(nil, 2)
	r, g, b = bar:GetStatusBarColor()
	near("brightness/clamped at 1", g, 1)
	check("brightness/clamp never exceeds 1", r <= 1 and g <= 1 and b <= 1)

	health.brightness.set(nil, 0)
	r, g, b = bar:GetStatusBarColor()
	check("brightness/zero is honored and not swallowed by an or-default",
		r == 0 and g == 0 and b == 0)

	health.brightness.set(nil, 1)

	-- It applies to whatever the mode resolved, not just to a static color.
	cfg.health.colorMode = "class"
	ns:BumpSerial()
	ns:RefreshUnit("player")
	local classR, classG, classB = bar:GetStatusBarColor()
	health.brightness.set(nil, 0.5)
	r, g, b = bar:GetStatusBarColor()
	near("brightness/scales a class color too", g, classG * 0.5)
	health.brightness.set(nil, 1)

	-- Power and shapeshift mana have their own independent controls.
	local power = ns.Options.table.args.units.args.player.args.power.args
	equal("brightness/power defaults to 0.8", cfg.power.brightness, 0.8)
	local powerBefore = select(2, player.elements.power.bar:GetStatusBarColor())
	power.brightness.set(nil, 0.5)
	near("brightness/power scales independently",
		select(2, player.elements.power.bar:GetStatusBarColor()), powerBefore * 0.5)
	near("brightness/health unaffected by the power slider",
		select(2, bar:GetStatusBarColor()), classG)
	power.brightness.set(nil, 1)

	-- The shapeshift mana bar keeps full brightness: its color is one you
	-- pick rather than one the game hands us, and it was already muted.
	equal("brightness/mana stays at 1", cfg.mana.brightness, 1)

	-- Back to defaults before the sweep: the suite has been moving the player's
	-- brightness around and the sweep asserts the shipped values.
	ns.Defaults:ResetUnit(ns:Profile(), "player")
	ns:BumpSerial()
	ns:RefreshUnit("player")

	-- Every unit gets the control, not just the player.
	local missing = {}
	for _, def in ipairs(ns.Registry:SortedAvailable()) do
		local unitCfg = ns:UnitConfig(def.key)
		for _, key in ipairs({ "health", "power", "mana" }) do
			local expected = (key == "mana") and 1 or 0.8
			if unitCfg[key].brightness ~= expected then
				missing[#missing + 1] = string.format("%s.%s=%s", def.key, key,
					tostring(unitCfg[key].brightness))
			end
		end
		local args = ns.Options.table.args.units.args[def.key].args
		if not args.health.args.brightness or not args.power.args.brightness
			or not args.mana.args.brightness then
			missing[#missing + 1] = def.key .. " (no slider)"
		end
	end
	if #missing == 0 then
		ok("brightness/present on every bar of every unit")
	else
		fail("brightness/present on every bar of every unit", table.concat(missing, ", "))
	end

	ns.Defaults:ResetUnit(ns:Profile(), "player")
	ns:BumpSerial()
	ns:RefreshUnit("player")
end

--------------------------------------------------------------------------------
-- 26. Bar stack tiling
--
-- With the frame backdrop off by default, any gap between bars is a slit
-- straight through to the game world rather than a separator. The default
-- layout must therefore tile exactly.
--------------------------------------------------------------------------------

local function barGeometry(bar)
	local _, _, _, x, y = bar:GetPoint(1)
	return x, y, bar:GetWidth(), bar:GetHeight()
end

local function testBarStack()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")

	equal("barstack/power spacing defaults to zero", cfg.power.spacing, 0)
	equal("barstack/mana spacing defaults to zero", cfg.mana.spacing, 0)

	local hx, hy, hw, hh = barGeometry(player.elements.health.bar)
	local px, py, pw, ph = barGeometry(player.elements.power.bar)

	equal("barstack/health starts at the top", hy, 0)
	equal("barstack/health starts at the left", hx, 0)
	equal("barstack/power starts exactly where health ends", py, -hh)
	equal("barstack/bars share the frame width", hw, pw)
	equal("barstack/bars span the frame width", hw, cfg.width)
	equal("barstack/stack exactly fills the frame height", hh + ph, cfg.height)

	-- A user-set separator must still work.
	local spacing = ns.Options.table.args.units.args.player.args.power.args.spacing
	spacing.set(nil, 4)
	local _, gapY, _, gapH = barGeometry(player.elements.power.bar)
	local _, _, _, newHealthHeight = barGeometry(player.elements.health.bar)
	equal("barstack/separator is honored when asked for", gapY, -(newHealthHeight + 4))
	equal("barstack/frame height still exactly consumed",
		newHealthHeight + 4 + gapH, cfg.height)
	spacing.set(nil, 0)

	-- Reserve-mode mana takes its slot out of the health bar, still with no gap.
	cfg.mana.enabled = true
	cfg.mana.mode = "reserve"
	ns:BumpSerial()
	ns:RefreshUnit("player")

	local _, _, _, reservedHealth = barGeometry(player.elements.health.bar)
	equal("barstack/reserve mode shortens health by exactly the mana slot",
		reservedHealth, cfg.height - cfg.power.height - cfg.mana.height)

	cfg.mana.mode = "append"
	cfg.mana.enabled = false
	ns.Defaults:ResetUnit(ns:Profile(), "player")
	ns:BumpSerial()
	ns:RefreshUnit("player")
end

--------------------------------------------------------------------------------
-- 26. Draw order
--
-- Frame level beats draw layer in WoW: everything a child frame draws sits
-- above EVERY layer of its parent, OVERLAY included. Text on frame.content is
-- therefore invisible behind the bars, which are child frames. This suite pins
-- the whole ordering so that never silently regresses.
--------------------------------------------------------------------------------

local function testDrawOrder()
	local player = ns.frames.player

	local contentLevel = player.content:GetFrameLevel()
	local overlayLevel = player.overlay:GetFrameLevel()
	local barLevel = player.elements.health.bar:GetFrameLevel()

	check("draworder/bars above the content", barLevel > contentLevel,
		barLevel .. " vs " .. contentLevel)
	check("draworder/overlay above the bars", overlayLevel > barLevel,
		overlayLevel .. " vs " .. barLevel)
	equal("draworder/power bar shares the bar band",
		player.elements.power.bar:GetFrameLevel(), barLevel)

	-- The actual bug: font strings parented to content are covered by the bars.
	local fontString = player.elements.text.strings[1]
	equal("draworder/text is parented to the overlay", fontString:GetParent(), player.overlay)
	check("draworder/text draws above the bars",
		fontString:GetParent():GetFrameLevel() > barLevel)

	-- Highlight outlines and border edges had the same problem.
	equal("draworder/border edges on the overlay",
		player.borderEdges[1]:GetParent(), player.overlay)

	ns:UnitConfig("player").highlight.targetEnabled = true
	ns:BumpSerial()
	ns:RefreshUnit("player")
	local highlight = player.elements.highlight
	check("draworder/highlight built", highlight ~= nil)
	if highlight then
		equal("draworder/highlight outlines on the overlay",
			highlight.target.edges[1]:GetParent(), player.overlay)
	end

	-- Auras sit between the bars and the overlay.
	local target = ns.frames.target
	local auraLevel = target.elements.auras.buffs.frame:GetFrameLevel()
	check("draworder/auras above the bars",
		auraLevel > target.elements.health.bar:GetFrameLevel())
	check("draworder/auras below the overlay",
		auraLevel < target.overlay:GetFrameLevel())

	-- An inside-placed portrait belongs behind the bars, as a backdrop.
	local portraitOption = ns.Options.table.args.units.args.player.args.portrait.args
	portraitOption.mode.set(nil, "3d")
	player:FullUpdate()
	local model = player.elements.portrait and player.elements.portrait.model
	check("draworder/3D portrait model created", model ~= nil)
	if model then
		check("draworder/portrait behind the bars", model:GetFrameLevel() < barLevel,
			model:GetFrameLevel() .. " vs " .. barLevel)
	end
	portraitOption.mode.set(nil, "none")

	-- A strata change must not silently reshuffle any of this.
	local strata = ns.Options.table.args.units.args.player.args.layout.args.size.args.strata
	strata.set(nil, "HIGH")
	check("draworder/survives a strata change",
		player.overlay:GetFrameLevel() > player.elements.health.bar:GetFrameLevel()
		and player.elements.health.bar:GetFrameLevel() > player.content:GetFrameLevel())
	strata.set(nil, "MEDIUM")

	ns.Defaults:ResetUnit(ns:Profile(), "player")
	ns:BumpSerial()
	ns:RefreshUnit("player")
end

--------------------------------------------------------------------------------
-- 26. Bar background brightness and opacity
--------------------------------------------------------------------------------

local function testBarBackground()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")
	local health = ns.Options.table.args.units.args.player.args.health.args

	-- A known bar color so the maths is checkable.
	cfg.health.colorMode = "static"
	cfg.health.color = { r = 0, g = 1, b = 0, a = 1 }
	cfg.health.brightness = 1     -- isolate this suite from the brightness default
	ns:BumpSerial()
	ns:RefreshUnit("player")

	local bg = player.elements.health.bg

	health.bgMultiplier.set(nil, 0.5)
	health.bgAlpha.set(nil, 1)
	local r, g, b, a = bg:GetVertexColor()
	near("background/brightness scales the bar color", g, 0.5)
	near("background/opacity at full", a, 1)

	health.bgAlpha.set(nil, 0.3)
	r, g, b, a = bg:GetVertexColor()
	near("background/opacity reaches the texture", a, 0.3)
	near("background/brightness unaffected by opacity", g, 0.5)

	-- Zero is a legitimate value and must not be swallowed by an `or` default.
	health.bgAlpha.set(nil, 0)
	r, g, b, a = bg:GetVertexColor()
	equal("background/zero opacity is honored", a, 0)

	health.bgMultiplier.set(nil, 0)
	r, g, b, a = bg:GetVertexColor()
	equal("background/zero brightness is honored", g, 0)

	-- Power bar has its own independent pair.
	local power = ns.Options.table.args.units.args.player.args.power.args
	power.bgAlpha.set(nil, 0.7)
	local powerBg = player.elements.power.bg
	near("background/power opacity is independent", select(4, powerBg:GetVertexColor()), 0.7)
	near("background/health opacity unchanged", select(4, bg:GetVertexColor()), 0)

	-- The filled portion of the bar is deliberately NOT affected: background
	-- settings describe the depleted part only.
	local barR, barG, barB = player.elements.health.bar:GetStatusBarColor()
	near("background/bar fill color untouched", barG, 1)

	-- The frame backdrop must default to OFF. It sits behind the bars, so
	-- leaving it on makes every bar-background opacity setting above look like
	-- it does nothing.
	check("background/frame backdrop defaults off", cfg.background.enabled == false)
	check("background/frame backdrop texture hidden", not player.background:IsShown())

	-- Turning it on must still work.
	local layout = ns.Options.table.args.units.args.player.args.layout.args.background.args
	layout.enabled.set(nil, true)
	check("background/frame backdrop can be turned on", player.background:IsShown())
	layout.enabled.set(nil, false)

	health.bgMultiplier.set(nil, 0.25)
	health.bgAlpha.set(nil, 1)
	power.bgAlpha.set(nil, 1)
	ns.Defaults:ResetUnit(ns:Profile(), "player")
	ns:BumpSerial()
	ns:RefreshUnit("player")
end

--------------------------------------------------------------------------------
-- 26. Portrait placement, including the lazily created 3D model
--------------------------------------------------------------------------------

local function testPortrait()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")
	local portrait = ns.Options.table.args.units.args.player.args.portrait.args

	equal("portrait/defaults to none", cfg.portrait.mode, "none")
	-- Widgets are kept once built -- WoW cannot destroy a frame, so elements are
	-- pooled and hidden rather than discarded. "Off" means absent from the
	-- active set, which is what stops it being laid out and updated.
	check("portrait/not active while off", player.activeElements.portrait == nil)

	equal("portrait/placed beside the frame by default", cfg.portrait.placement, "outside")
	equal("portrait/square by default", cfg.portrait.shape, "square")

	-- 2D
	portrait.mode.set(nil, "2d")
	local el = player.elements.portrait
	check("portrait/2D builds", el ~= nil)

	-- Square crops to the inscribed square of the game's round portrait art.
	local left, right, top, bottom = el.texture:GetTexCoord()
	check("portrait/square crops inward", left > 0 and left < 0.25, tostring(left))
	near("portrait/square crop is symmetric", right, 1 - left)
	near("portrait/square crop is the same on both axes", top, left)

	portrait.shape.set(nil, "native")
	player:FullUpdate()
	left, right = el.texture:GetTexCoord()
	equal("portrait/native uses the full texture", left, 0)
	equal("portrait/native right edge", right, 1)
	portrait.shape.set(nil, "square")
	player:FullUpdate()

	-- Beside the frame, not over it.
	local point, relative, relativePoint = el.texture:GetPoint(1)
	equal("portrait/anchored to the frame's left edge", point, "RIGHT")
	equal("portrait/relative to the content's left", relativePoint, "LEFT")
	equal("portrait/2D sized", el.texture:GetWidth(), cfg.portrait.width)
	equal("portrait/2D opacity applied", el.texture:GetAlpha(), 1)

	portrait.alpha.set(nil, 0.4)
	equal("portrait/2D opacity slider works", el.texture:GetAlpha(), 0.4)
	portrait.alpha.set(nil, 1)

	portrait.width.set(nil, 64)
	equal("portrait/2D width slider works", el.texture:GetWidth(), 64)

	-- 3D. The model is created lazily on first render, which is AFTER Layout
	-- has run, so it has to be placed at creation or it arrives with no size,
	-- no anchor and no alpha — and its opacity slider looks dead.
	portrait.mode.set(nil, "3d")
	portrait.alpha.set(nil, 0.6)
	player:FullUpdate()

	el = player.elements.portrait
	check("portrait/3D model created", el.model ~= nil)
	equal("portrait/lazily created model is sized", el.model:GetWidth(), 64)
	equal("portrait/lazily created model is anchored", el.model:GetNumPoints(), 1)
	equal("portrait/lazily created model has its opacity", el.model:GetAlpha(), 0.6)

	-- And a later slider move still reaches it.
	portrait.alpha.set(nil, 0.2)
	equal("portrait/3D opacity slider works after creation", el.model:GetAlpha(), 0.2)

	-- An invisible unit must fall back to 2D rather than showing a dead model.
	stub.units.player.visible = false
	player:FullUpdate()
	check("portrait/out-of-range unit falls back to 2D", el.texture:IsShown())
	check("portrait/model hidden on fallback", not el.model:IsShown())
	stub.units.player.visible = true

	portrait.mode.set(nil, "none")
	portrait.alpha.set(nil, 1)
	portrait.width.set(nil, 40)
end

--------------------------------------------------------------------------------
-- 27. Combo points (Plan 9)
--------------------------------------------------------------------------------

--- The unit an event's registration is filtered against on `frame`.
--
-- There was no test anywhere asserting WHICH unit an element's events are
-- registered against, and that is a silent failure mode: a wrong unit produces
-- no error and no warning, just a widget that never updates. Written generally
-- so it covers the UNIT_TARGET/owner handling too.
--
-- @return string|nil unit, or nil for an unfiltered registration
-- @return boolean whether the event is registered at all
local function eventFilter(frame, event)
	local reg = frame.__events[event]
	if reg == nil then return nil, false end
	if type(reg) ~= "table" then return nil, true end
	return reg[1], true
end

--- Is `elementName` on the dispatch list for `event`?
--
-- Deliberately not a count: which elements happen to want a shared event is
-- unrelated wiring that moves (the target frame's power TEXT wants
-- UNIT_POWER_UPDATE too), and a count would break every time it did.
local function dispatchesTo(frame, event, elementName)
	local list = frame.eventMap[event]
	if not list then return false end
	for i = 1, #list do
		if list[i].name == elementName then return true end
	end
	return false
end

--- Measured borders and pip widths, read back from the actual placements
-- rather than recomputed. `gaps` is outer-left, each gap between pips, then
-- outer-right: one more entry than there are pips.
local function comboGeometry(el)
	local gaps, widths = {}, {}
	local previousRight = 0
	for i = 1, #el.pips do
		local _, _, _, x = el.pips[i]:GetPoint(1)
		widths[i] = el.pips[i]:GetWidth()
		gaps[#gaps + 1] = x - previousRight
		previousRight = x + widths[i]
	end
	gaps[#gaps + 1] = el.container:GetWidth() - previousRight
	return gaps, widths
end

local function pipIsFilled(el, index, cfg)
	local c = el.pips[index].__color
	return c ~= nil and c[1] == cfg.color.r and c[2] == cfg.color.g and c[3] == cfg.color.b
end

local function pipIsEmpty(el, index, cfg)
	local c = el.pips[index].__color
	return c ~= nil and c[1] == cfg.emptyColor.r and c[2] == cfg.emptyColor.g
		and c[3] == cfg.emptyColor.b
end

--- A profile at the schema the combo bar was added on top of, carrying the
-- target buff anchor exactly as it shipped there.
local function schema12Profile()
	local function buffs(y)
		return { enabled = true, anchorTo = "frame", point = "BOTTOMLEFT",
			relativePoint = "TOPLEFT", x = 0, y = y, growthY = "UP" }
	end
	return {
		schemaVersion = 12,
		general = {},
		units = {
			target = { auras = { buffs = buffs(2) } },
			player = { auras = { buffs = buffs(2) } },
		},
	}
end

local function testComboPoints()
	local Compat = ns.Compat
	local target = ns.frames.target
	local cfg = ns:UnitConfig("target").combo
	local opts = ns.Options.table.args.units.args.target.args.combo.args

	----------------------------------------------------------------------------
	-- Reading the value, and the trap underneath it
	----------------------------------------------------------------------------

	equal("combo/max read from Compat, not written as a 5", Compat.MAX_COMBO_POINTS, 5)
	check("combo/GetComboPoints is the live path", Compat.hasGetComboPoints)
	check("combo/capabilities reported by /duf compat",
		Compat.Describe().maxComboPoints == 5
		and Compat.Describe().hasGetComboPoints == true
		and Compat.Describe().hasComboPointEnum == false)

	stub.units.target.combo = 4
	equal("combo/points are read against the target", Compat.GetComboPoints("target"), 4)

	-- THE TRAP. Power type 4 is HAPPINESS in the numbering Compat carries; it
	-- only means combo points under the modern Enum. With neither API present
	-- the answer must be zero rather than a pet's happiness.
	local realGetComboPoints = _G.GetComboPoints
	stub.units.player.powers[4] = 3
	_G.GetComboPoints = nil
	equal("combo/no API reads zero, never HAPPINESS", Compat.GetComboPoints("target"), 0)

	-- With a real Enum entry, that path works and reads the right index.
	_G.Enum.PowerType.ComboPoints = 14
	stub.units.player.powers[14] = 5
	equal("combo/enum fallback reads its own power index",
		Compat.GetComboPoints("target"), 5)

	_G.Enum.PowerType.ComboPoints = nil
	_G.GetComboPoints = realGetComboPoints
	stub.units.player.powers[4] = nil
	stub.units.player.powers[14] = nil

	----------------------------------------------------------------------------
	-- Defaults and options
	----------------------------------------------------------------------------

	equal("combo/on for the target by default", cfg.enabled, true)
	equal("combo/off on the player", ns:UnitConfig("player").combo.enabled, false)
	equal("combo/off on the pet", ns:UnitConfig("pet").combo.enabled, false)
	equal("combo/off on a party frame", ns:UnitConfig("party1").combo.enabled, false)

	-- Dull magenta, not the full (1, 0, 1), which is punishing as flat fill.
	check("combo/default color is not full magenta",
		not (cfg.color.r == 1 and cfg.color.g == 0 and cfg.color.b == 1))
	check("combo/default color is recognizably magenta",
		cfg.color.r > cfg.color.g and cfg.color.b > cfg.color.g,
		string.format("%s/%s/%s", cfg.color.r, cfg.color.g, cfg.color.b))

	local units = ns.Options.table.args.units.args
	check("combo/options offered on the target", units.target.args.combo ~= nil)
	check("combo/options offered on the player", units.player.args.combo ~= nil)
	equal("combo/options not hidden on the target", units.target.args.combo.hidden, false)
	equal("combo/options hidden on a party frame", units.party1.args.combo.hidden, true)
	equal("combo/options hidden on target of target",
		units.targettarget.args.combo.hidden, true)

	----------------------------------------------------------------------------
	-- Geometry
	----------------------------------------------------------------------------

	local el = target.elements.combo
	check("combo/element built", el ~= nil)
	if not el then return end

	equal("combo/five rectangles", #el.pips, Compat.MAX_COMBO_POINTS)

	-- Outside the frame's bounds, growing up off the top edge: it takes no slot
	-- in the bar stack and nothing inside the frame moves when it appears.
	stub.units.target.combo = 1
	target:FullUpdate()
	local point, relative, relativePoint, _, y = el.container:GetPoint(1)
	equal("combo/bottom edge sits on the frame's top edge", point, "BOTTOMLEFT")
	equal("combo/anchored to the frame's top", relativePoint, "TOPLEFT")
	equal("combo/anchored to the frame itself", relative, target.content)
	check("combo/grows upward from that edge", y > 0, tostring(y))
	equal("combo/takes no slot in the bar stack",
		target.elements.health.bar:GetHeight(),
		ns:UnitConfig("target").height - ns:UnitConfig("target").power.height)

	-- 200 divides by five cleanly once the six borders are taken out.
	opts.widthMode.set(nil, "custom")
	opts.width.set(nil, 200)
	opts.borderSize.set(nil, 1)

	local gaps, widths = comboGeometry(el)
	local total = 0
	for i = 1, #widths do total = total + widths[i] end
	equal("combo/pip widths fill the bar minus its borders", total, 200 - 6)
	equal("combo/six borders for five pips", #gaps, 6)
	local uniform, worst = true, nil
	for i = 1, #gaps do
		if gaps[i] ~= 1 then uniform = false; worst = gaps[i] end
	end
	check("combo/every border is exactly the requested thickness", uniform,
		"found a gap of " .. tostring(worst))

	-- A width that does NOT divide by five: the borders are the quantity held
	-- constant and the pips absorb the remainder, never the other way round.
	opts.width.set(nil, 202)
	gaps, widths = comboGeometry(el)
	uniform, worst = true, nil
	for i = 1, #gaps do
		if gaps[i] ~= 1 then uniform = false; worst = gaps[i] end
	end
	check("combo/borders stay exact on an indivisible width", uniform,
		"found a gap of " .. tostring(worst))
	local smallest, largest = widths[1], widths[1]
	total = 0
	for i = 1, #widths do
		if widths[i] < smallest then smallest = widths[i] end
		if widths[i] > largest then largest = widths[i] end
		total = total + widths[i]
	end
	check("combo/pips differ by at most one", largest - smallest <= 1,
		tostring(smallest) .. ".." .. tostring(largest))
	equal("combo/and still fill the bar", total, 202 - 6)

	-- A thicker border still leaves every gap exact.
	opts.borderSize.set(nil, 3)
	gaps = comboGeometry(el)
	uniform = true
	for i = 1, #gaps do
		if gaps[i] ~= 3 then uniform = false end
	end
	check("combo/a thicker border is exact too", uniform)
	equal("combo/pip height clears both borders",
		el.pips[1]:GetHeight(), cfg.height - 6)
	opts.borderSize.set(nil, 1)

	equal("combo/custom width is used", el.container:GetWidth(), 202)

	-- Inherited width tracks the frame through ApplyConfig.
	opts.widthMode.set(nil, "inherit")
	equal("combo/inherited width matches the frame",
		el.container:GetWidth(), ns:UnitConfig("target").width)
	local layoutOpts = units.target.args.layout.args.size.args
	local originalWidth = ns:UnitConfig("target").width
	layoutOpts.width.set(nil, 260)
	equal("combo/inherited width follows a frame resize", el.container:GetWidth(), 260)
	layoutOpts.width.set(nil, originalWidth)

	----------------------------------------------------------------------------
	-- Value
	----------------------------------------------------------------------------

	stub.units.target.combo = 0
	target:FullUpdate()
	check("combo/hidden at zero points", not el.container:IsShown())

	opts.hideWhenEmpty.set(nil, false)
	target:FullUpdate()
	check("combo/shown at zero when asked to be", el.container:IsShown())
	local allEmpty = true
	for i = 1, #el.pips do
		if not pipIsEmpty(el, i, cfg) then allEmpty = false end
	end
	check("combo/all five read as capacity at zero", allEmpty)
	opts.hideWhenEmpty.set(nil, true)

	stub.units.target.combo = 3
	target:FullUpdate()
	check("combo/three points fill the first three",
		pipIsFilled(el, 1, cfg) and pipIsFilled(el, 2, cfg) and pipIsFilled(el, 3, cfg))
	check("combo/and leave the last two empty",
		pipIsEmpty(el, 4, cfg) and pipIsEmpty(el, 5, cfg))

	opts.growth.set(nil, "LEFT")
	target:FullUpdate()
	check("combo/growing left fills from the right-hand pip",
		pipIsFilled(el, 5, cfg) and pipIsFilled(el, 4, cfg) and pipIsFilled(el, 3, cfg))
	check("combo/and leaves the left-hand ones empty",
		pipIsEmpty(el, 1, cfg) and pipIsEmpty(el, 2, cfg))
	opts.growth.set(nil, "RIGHT")

	stub.units.target.combo = 5
	target:FullUpdate()
	local allFilled = true
	for i = 1, #el.pips do
		if not pipIsFilled(el, i, cfg) then allFilled = false end
	end
	check("combo/five points fill every pip", allFilled)

	-- A value above the maximum clamps rather than erroring on pip six.
	stub.units.target.combo = 9
	local survived = pcall(function() target:FullUpdate() end)
	check("combo/a value above the maximum does not error", survived)
	allFilled = true
	for i = 1, #el.pips do
		if not pipIsFilled(el, i, cfg) then allFilled = false end
	end
	check("combo/and clamps to a full row", allFilled)

	-- Anchored to a bar that is not showing: hide, like bar-anchored text.
	stub.units.target.combo = 3
	local targetCfg = ns:UnitConfig("target")
	targetCfg.combo.anchorTo = "mana"
	targetCfg.mana.enabled = false
	ns:BumpSerial()
	ns:RefreshUnit("target")
	target:FullUpdate()
	check("combo/hidden when the anchor bar is not showing", not el.container:IsShown())
	targetCfg.combo.anchorTo = "frame"
	ns:BumpSerial()
	ns:RefreshUnit("target")

	----------------------------------------------------------------------------
	-- Events
	--
	-- The regression test for the bug this shipped with. Combo points are the
	-- PLAYER's, so their events carry "player" -- but the element lives on the
	-- TARGET frame, and Factory filters every UNIT_* event against the frame's
	-- own display unit. Getting that wrong produces no error and no warning,
	-- just a bar that never updates until something else forces a full update.
	--
	-- And the event it was originally written against does not exist here at
	-- all, which is the other half of the same failure: Compat skips an invalid
	-- event silently, so the element was subscribed to nothing.
	----------------------------------------------------------------------------

	check("combo/UNIT_COMBO_POINTS is absent on this client",
		not Compat.HasEvent("UNIT_COMBO_POINTS"))
	check("combo/and that is visible from /duf compat",
		Compat.Describe().hasUnitComboPoints == false)
	local _, registered = eventFilter(target, "UNIT_COMBO_POINTS")
	check("combo/so it is not registered", not registered)

	-- The live path. The power bar on this same frame already wants
	-- UNIT_POWER_UPDATE for "target", so this is a genuine two-element conflict
	-- rather than a contrived one -- and it must not cost either of them.
	local filter
	filter, registered = eventFilter(target, "UNIT_POWER_UPDATE")
	check("combo/UNIT_POWER_UPDATE is registered on the target frame", registered)
	check("combo/the combo bar is on its dispatch list",
		dispatchesTo(target, "UNIT_POWER_UPDATE", "combo"))
	check("combo/and so is the power bar it shares with",
		dispatchesTo(target, "UNIT_POWER_UPDATE", "power"))

	-- Served by ONE registration filtered against BOTH units. Dropping the
	-- filter would also work and is the fallback, but it would wake the target
	-- frame for every raid member's energy tick (SPEC §5.7).
	local reg = target.__events["UNIT_POWER_UPDATE"]
	check("combo/still unit-filtered, not widened to everything",
		type(reg) == "table", "registration was dropped to unfiltered")
	-- Guarded rather than indexed straight: if the check above ever fails, `reg`
	-- is a boolean and indexing it would crash the whole suite, hiding every
	-- assertion after this one.
	local filtered = (type(reg) == "table") and reg or {}
	local servesPlayer = (filtered[1] == "player") or (filtered[2] == "player")
	local servesTarget = (filtered[1] == "target") or (filtered[2] == "target")
	check("combo/filtered against the player, for the combo bar", servesPlayer)
	check("combo/and the target, for the power bar", servesTarget)

	-- The same helper over the cases that have always had this shape and have
	-- never been asserted: UNIT_TARGET belongs to the derived frame's owner.
	equal("combo/derived frames still watch their owner's target",
		(eventFilter(ns.frames.targettarget, "UNIT_TARGET")), "target")
	equal("combo/and the pet frame watches its owner",
		(eventFilter(ns.frames.pet, "UNIT_PET")), "player")

	-- Firing it updates the pips on its own, without a full update. Health is
	-- moved at the same time and must NOT follow: that is what proves only the
	-- elements listening for this event ran.
	local healthBefore = target.elements.health.bar:GetValue()
	stub.units.target.health = 12
	stub.units.target.combo = 2
	stub.fire("UNIT_POWER_UPDATE", "player")
	check("combo/a player power event updates the pips",
		pipIsFilled(el, 2, cfg) and pipIsEmpty(el, 3, cfg))
	equal("combo/without running a full update",
		target.elements.health.bar:GetValue(), healthBefore)
	stub.units.target.health = 87

	-- The event the combo count rides on fires several times a second for an
	-- energy user and carries a changed count on almost none of them.
	stub.units.target.combo = 5
	el.pips[5]:SetColorTexture(0, 0, 0, 0)      -- deliberately wrong
	el.lastPoints = 5
	stub.fire("UNIT_POWER_UPDATE", "player")
	check("combo/an unchanged count does not repaint",
		not pipIsFilled(el, 5, cfg))
	-- ...but anything that is not that event must still repaint unconditionally,
	-- or a config change would leave the bar stale.
	target:FullUpdate()
	check("combo/a full update repaints regardless", pipIsFilled(el, 5, cfg))

	-- PLAYER_TARGET_CHANGED is a change event on this frame, so assert the
	-- outcome rather than the path.
	stub.units.target.combo = 1
	stub.fire("PLAYER_TARGET_CHANGED")
	check("combo/a target change re-reads the points",
		pipIsFilled(el, 1, cfg) and pipIsEmpty(el, 2, cfg))

	-- Three elements wanting three different units cannot be expressed by a
	-- filter, so that -- and only that -- drops to unfiltered.
	local highlight = ns.elements.highlight
	local savedEvents, savedUnits = highlight.events, highlight.eventUnits
	highlight.events = { UNIT_POWER_UPDATE = true }
	highlight.eventUnits = { UNIT_POWER_UPDATE = "focus" }
	target:RegisterEvents()
	check("combo/a third unit drops the filter rather than starving anyone",
		type(target.__events["UNIT_POWER_UPDATE"]) ~= "table")
	check("combo/and every element is still served",
		dispatchesTo(target, "UNIT_POWER_UPDATE", "combo")
		and dispatchesTo(target, "UNIT_POWER_UPDATE", "power")
		and dispatchesTo(target, "UNIT_POWER_UPDATE", "highlight"))

	highlight.events, highlight.eventUnits = savedEvents, savedUnits
	target:RegisterEvents()
	reg = target.__events["UNIT_POWER_UPDATE"]
	check("combo/the filter comes back once the conflict is gone",
		type(reg) == "table"
		and ((reg[1] == "player") or (reg[2] == "player")))

	----------------------------------------------------------------------------
	-- Migration: the target buff row is raised off the new bar
	----------------------------------------------------------------------------

	local shipped = schema12Profile()
	check("combo/schema 12 profile migrates", (ns.Migrate:Run(shipped, {})))
	equal("combo/the shipped target buff row is raised",
		shipped.units.target.auras.buffs.y, 14)
	equal("combo/a non-target unit's buffs are left alone",
		shipped.units.player.auras.buffs.y, 2)
	equal("combo/and it lands on the current schema",
		shipped.schemaVersion, ns.Defaults.SCHEMA_VERSION)

	-- Anyone who has positioned their buffs keeps their position. One differing
	-- field is enough to mean "deliberate".
	local moved = schema12Profile()
	moved.units.target.auras.buffs.y = 6
	ns.Migrate:Run(moved, {})
	equal("combo/a moved buff row is untouched", moved.units.target.auras.buffs.y, 6)

	local nudged = schema12Profile()
	nudged.units.target.auras.buffs.x = 8
	ns.Migrate:Run(nudged, {})
	equal("combo/so is one nudged sideways", nudged.units.target.auras.buffs.y, 2)

	local reanchored = schema12Profile()
	reanchored.units.target.auras.buffs.anchorTo = "health"
	ns.Migrate:Run(reanchored, {})
	equal("combo/and one anchored elsewhere",
		reanchored.units.target.auras.buffs.y, 2)

	-- The shipped default must agree with what the migration produces, or new
	-- and upgraded profiles would disagree about where the buffs go.
	equal("combo/the shipped default matches the migration",
		ns:UnitConfig("target").auras.buffs.y, 14)

	stub.units.target.combo = nil
	stub.units.target.health = 87
	ns.Defaults:ResetUnit(ns:Profile(), "target")
	ns:BumpSerial()
	ns:RefreshUnit("target")
	target:FullUpdate()
end

--------------------------------------------------------------------------------
-- 25. Bar sweep: the power tick and five second rule indicators
--
-- Plans 2 and 10. The animation itself is not testable headlessly, but
-- everything that decides WHETHER and WHERE it draws is, and so is the claim
-- that justifies adding a fourth ticker at all: that it idles to zero.
--------------------------------------------------------------------------------

--- Frames carrying an OnUpdate script. The sweep driver is the only thing in
-- the addon that uses one, so this counts drivers.
local function sweepDrivers()
	local n = 0
	for _, f in ipairs(stub.frames or {}) do
		if f.__scripts and f.__scripts.OnUpdate then n = n + 1 end
	end
	return n
end

local function lineX(line)
	local _, _, _, x = line:GetPoint(1)
	return x
end

local function testBarSweep()
	local BarSweep = ns.BarSweep
	local Compat = ns.Compat
	local st = BarSweep.state
	local tick, fsr = BarSweep.PROVIDERS.tick, BarSweep.PROVIDERS.fsr

	local player = ns.frames.player
	local powerCfg = ns:UnitConfig("player").power
	local manaCfg = ns:UnitConfig("player").mana
	local units = ns.Options.table.args.units.args
	local powerOpts = units.player.args.power.args

	----------------------------------------------------------------------------
	-- Defaults
	----------------------------------------------------------------------------

	equal("sweep/tick ships off", powerCfg.tick.enabled, false)
	equal("sweep/five second rule ships off", powerCfg.fsr.enabled, false)
	equal("sweep/tick sweeps left to right", powerCfg.tick.direction, "RIGHT")
	equal("sweep/five second rule sweeps right to left", powerCfg.fsr.direction, "LEFT")
	equal("sweep/both blocks exist on the shapeshift mana bar too",
		manaCfg.tick ~= nil and manaCfg.fsr ~= nil, true)

	-- Both lines can be on the same mana bar at once, and two identical white
	-- lines crossing each other is unreadable.
	check("sweep/the two lines do not ship the same color",
		not (manaCfg.tick.color.r == manaCfg.fsr.color.r
			and manaCfg.tick.color.g == manaCfg.fsr.color.g
			and manaCfg.tick.color.b == manaCfg.fsr.color.b))

	-- The five seconds are a game rule, not a setting.
	equal("sweep/five second duration is a constant", BarSweep.FSR_DURATION, 5)
	equal("sweep/no user control over the five seconds", powerCfg.fsr.duration, nil)

	-- Opacity is its own setting, not the color's alpha channel. The swatch
	-- ships fully opaque so that touching the color picker -- which has no alpha
	-- channel and therefore writes a = 1 -- cannot silently change the opacity.
	equal("sweep/tick ships at 0.9 opacity", powerCfg.tick.alpha, 0.9)
	equal("sweep/rule ships at 0.9 opacity", powerCfg.fsr.alpha, 0.9)
	equal("sweep/tick color swatch is fully opaque", powerCfg.tick.color.a, 1)
	equal("sweep/rule color swatch is fully opaque", powerCfg.fsr.color.a, 1)

	-- At maximum power: the tick's business, not the rule's.
	equal("sweep/at-max behavior defaults to always showing",
		powerCfg.tick.atMax, "always")
	equal("sweep/no at-max setting on the rule", powerCfg.fsr.atMax, nil)

	----------------------------------------------------------------------------
	-- Options, and the player-only boundary (SPEC §FR-8.5)
	----------------------------------------------------------------------------

	equal("sweep/tick options offered on the player", powerOpts.tick.hidden, false)
	equal("sweep/rule options offered on the player", powerOpts.fsr.hidden, false)
	equal("sweep/tick options hidden on the target",
		units.target.args.power.args.tick.hidden, true)
	equal("sweep/rule options hidden on the target",
		units.target.args.power.args.fsr.hidden, true)
	equal("sweep/rule options hidden on a party frame",
		units.party1.args.power.args.fsr.hidden, true)
	equal("sweep/rule options hidden on target of target",
		units.targettarget.args.power.args.fsr.hidden, true)
	equal("sweep/options offered on the shapeshift mana bar",
		units.player.args.mana.args.fsr.hidden, false)

	-- Controls that belong to one indicator and not the other.
	equal("sweep/no fade control on the tick line", powerOpts.tick.args.fade, nil)
	check("sweep/fade control on the five second rule", powerOpts.fsr.args.fade ~= nil)
	equal("sweep/no at-max control on the five second rule",
		powerOpts.fsr.args.atMax, nil)
	check("sweep/at-max control on the tick line", powerOpts.tick.args.atMax ~= nil)
	-- A dropdown sizes its pullout to its own half-column width and clipped two
	-- of these four labels. Radio rows are full width and cannot truncate.
	equal("sweep/at-max is a radio group, not a truncating dropdown",
		powerOpts.tick.args.atMax.style, "radio")
	equal("sweep/at-max radio rows are full width",
		powerOpts.tick.args.atMax.width, "full")
	-- Every value has a row, and the order is spelled out rather than falling
	-- back to a sort by key.
	equal("sweep/at-max lists every option exactly once",
		#powerOpts.tick.args.atMax.sorting, 4)
	local listed = {}
	for _, key in ipairs(powerOpts.tick.args.atMax.sorting) do listed[key] = true end
	local missing = nil
	for key in pairs(powerOpts.tick.args.atMax.values) do
		if not listed[key] then missing = key end
	end
	check("sweep/no at-max option is left out of the ordering",
		missing == nil, tostring(missing))

	-- Opacity is offered on both.
	check("sweep/opacity slider on the tick line", powerOpts.tick.args.alpha ~= nil)
	check("sweep/opacity slider on the five second rule",
		powerOpts.fsr.args.alpha ~= nil)

	----------------------------------------------------------------------------
	-- The trigger, made swappable
	----------------------------------------------------------------------------

	equal("sweep/manaSpent is the default trigger",
		BarSweep:Trigger(), BarSweep.TRIGGERS.manaSpent)
	equal("sweep/an unknown trigger falls back rather than erroring",
		BarSweep:Trigger("nosuchtrigger"), BarSweep.TRIGGERS.manaSpent)
	check("sweep/manaSpent fires on a decrease",
		BarSweep.TRIGGERS.manaSpent.Detect(100, 90))
	check("sweep/manaSpent ignores an increase",
		not BarSweep.TRIGGERS.manaSpent.Detect(90, 100))

	----------------------------------------------------------------------------
	-- Deriving the tick interval
	----------------------------------------------------------------------------

	BarSweep:Reset()
	equal("sweep/interval is seeded at 2.0s", BarSweep:TickInterval(), 2.0)
	equal("sweep/seeded interval is reported as assumed, not observed",
		BarSweep:TickObserved(), false)

	BarSweep:NoteTick(2000)
	check("sweep/the first tick is recorded", BarSweep:TickObserved())

	-- A clean 2.5s cadence pulls the interval onto it.
	for i = 1, 25 do BarSweep:NoteTick(2000 + i * 2.5) end
	near("sweep/interval converges on the observed cadence",
		BarSweep:TickInterval(), 2.5, 0.02)

	-- A 9s gap is a MISSED tick, not evidence of a 9s cadence.
	local held = BarSweep:TickInterval()
	BarSweep:NoteTick(2000 + 25 * 2.5 + 9.0)
	equal("sweep/an outlier gap does not move the interval",
		BarSweep:TickInterval(), held)

	-- Nor does an implausibly fast one.
	for i = 1, 20 do BarSweep:NoteTick(3000 + i * 0.1) end
	equal("sweep/a too-fast sample does not move the interval either",
		BarSweep:TickInterval(), held)

	-- ...and a real cadence at the edge of the band is accepted and stays in it.
	BarSweep:Reset()
	BarSweep:NoteTick(4000)
	for i = 1, 40 do BarSweep:NoteTick(4000 + i * 2.9) end
	check("sweep/interval never leaves the 1.5-3.0s band",
		BarSweep:TickInterval() >= 1.5 and BarSweep:TickInterval() <= 3.0,
		tostring(BarSweep:TickInterval()))
	near("sweep/a slow-but-plausible cadence is accepted",
		BarSweep:TickInterval(), 2.9, 0.02)

	----------------------------------------------------------------------------
	-- Detection: increases, decreases, and the trap in between
	----------------------------------------------------------------------------

	BarSweep:Reset()
	BarSweep:NotePlayerPower(Compat.MANA, 500, 5000)
	equal("sweep/the first sample cannot be a tick", BarSweep:TickObserved(), false)

	BarSweep:NotePlayerPower(Compat.MANA, 560, 5002)
	check("sweep/a power increase records a tick", BarSweep:TickObserved())
	check("sweep/an increase is not a spend",
		not BarSweep:IsFiveSecondRuleRunning(5002))

	BarSweep:NotePlayerPower(Compat.MANA, 400, 5004)
	check("sweep/a mana decrease starts the five second rule",
		BarSweep:IsFiveSecondRuleRunning(5004))

	-- Spending energy fires the same event with a decrease and must not touch
	-- the rule: a rogue has no five second rule to run.
	BarSweep:Reset()
	BarSweep:NotePlayerPower(3, 100, 6000)
	BarSweep:NotePlayerPower(3, 60, 6001)
	check("sweep/spending energy does not start the five second rule",
		not BarSweep:IsFiveSecondRuleRunning(6001))
	check("sweep/spending energy is not a tick either", not BarSweep:TickObserved())

	-- A power TYPE change is a shapeshift. The two values are different
	-- resources and comparing them would read as an enormous spend or tick.
	BarSweep:Reset()
	BarSweep:NotePlayerPower(Compat.MANA, 3000, 7000)
	BarSweep:NotePlayerPower(3, 100, 7001)
	check("sweep/a power type change is neither a tick nor a spend",
		not BarSweep:TickObserved() and not BarSweep:IsFiveSecondRuleRunning(7001))

	----------------------------------------------------------------------------
	-- The sweep maths
	----------------------------------------------------------------------------

	BarSweep:Reset()
	BarSweep:NoteTick(8000)
	near("sweep/tick fraction is 0 at the tick", tick.Fraction(st, 8000), 0)
	near("sweep/tick fraction is 0.5 at half an interval", tick.Fraction(st, 8001), 0.5)
	near("sweep/tick fraction restarts at a whole interval", tick.Fraction(st, 8002), 0)

	-- Plan 2's edge case: at full power nothing increases, so no tick is ever
	-- observed, but the server's tick keeps happening. The sweep keeps its phase
	-- rather than parking against the far edge.
	near("sweep/phase survives a stretch with no observed tick",
		tick.Fraction(st, 8000 + 5.0), 0.5)
	local strayed = nil
	for i = 0, 60 do
		local f = tick.Fraction(st, 8000 + i * 0.37)
		if f < 0 or f > 1 then strayed = f end
	end
	check("sweep/tick fraction never leaves 0..1", strayed == nil, tostring(strayed))

	local fsrCfg = { enabled = true, fade = 0.3, direction = "LEFT", width = 2 }
	BarSweep:Reset()
	BarSweep:NoteManaSpent(9000)
	near("sweep/rule fraction is 0 at the spend", fsr.Fraction(st, 9000), 0)
	near("sweep/rule fraction is 0.5 at 2.5s", fsr.Fraction(st, 9002.5), 0.5)
	near("sweep/rule fraction is 1 at 5s", fsr.Fraction(st, 9005), 1)
	near("sweep/rule is fully opaque inside the window",
		fsr.Alpha(st, 9004, fsrCfg), 1)
	near("sweep/rule holds at the far edge during the fade",
		fsr.Fraction(st, 9005.15), 1)
	near("sweep/rule is halfway through a 0.3s fade at 5.15s",
		fsr.Alpha(st, 9005.15, fsrCfg), 0.5)
	check("sweep/rule still active mid-fade", fsr.IsActive(st, 9005.15, fsrCfg))
	check("sweep/rule inactive once the fade is done",
		not fsr.IsActive(st, 9005.4, fsrCfg))

	BarSweep:NoteManaSpent(9003)
	near("sweep/a spend restarts the sweep from the origin",
		fsr.Fraction(st, 9003), 0)
	BarSweep:NoteManaSpent(9005.15)
	near("sweep/a spend mid-fade restores full opacity",
		fsr.Alpha(st, 9005.15, fsrCfg), 1)

	----------------------------------------------------------------------------
	-- At maximum power
	--
	-- `record` carries the power type of the bar the line is on, because the
	-- same tick line is attached to the power bar and the shapeshift mana bar at
	-- once and "at max" means a different thing on each.
	----------------------------------------------------------------------------

	local fullMana = { atMax = true, powerType = Compat.MANA }
	local fullEnergy = { atMax = true, powerType = Compat.ENERGY }
	local notFull = { atMax = false, powerType = Compat.ENERGY }

	check("sweep/always keeps the line on a full bar",
		tick.IsActive(st, 0, { atMax = "always" }, fullMana))
	check("sweep/never drops it on a full bar",
		not tick.IsActive(st, 0, { atMax = "never" }, fullMana))
	check("sweep/mana keeps it on a full mana bar",
		tick.IsActive(st, 0, { atMax = "mana" }, fullMana))
	check("sweep/mana drops it on a full energy bar",
		not tick.IsActive(st, 0, { atMax = "mana" }, fullEnergy))
	check("sweep/energy keeps it on a full energy bar",
		tick.IsActive(st, 0, { atMax = "energy" }, fullEnergy))
	check("sweep/energy drops it on a full mana bar",
		not tick.IsActive(st, 0, { atMax = "energy" }, fullMana))

	-- Below maximum the setting has no say at all: every mode shows the line.
	check("sweep/below max every mode shows the line",
		tick.IsActive(st, 0, { atMax = "never" }, notFull)
		and tick.IsActive(st, 0, { atMax = "mana" }, notFull)
		and tick.IsActive(st, 0, { atMax = "energy" }, notFull))
	check("sweep/an unknown at-max mode shows it rather than erroring",
		tick.IsActive(st, 0, { atMax = "nonsense" }, fullMana))
	check("sweep/a missing at-max mode shows it rather than erroring",
		tick.IsActive(st, 0, {}, fullMana))

	----------------------------------------------------------------------------
	-- Attachment: "only applies to mana bars"
	----------------------------------------------------------------------------

	powerOpts.tick.args.enabled.set(nil, true)
	powerOpts.fsr.args.enabled.set(nil, true)
	units.player.args.mana.args.tick.args.enabled.set(nil, true)
	units.player.args.mana.args.fsr.args.enabled.set(nil, true)

	local powerBar = player.elements.power.bar
	local manaBar = player.elements.mana.bar

	-- Cat form: energy displayed, mana pool present, so the shapeshift mana bar
	-- is up. Both halves of the request are asserted here — the rule belongs on
	-- the mana bar and NOT on the energy bar, while the tick belongs on both.
	stub.units.player.powerType = 3
	stub.units.player.powerToken = "ENERGY"
	player:FullUpdate()
	check("sweep/mana bar is up in cat form", player.elements.mana.shown)
	check("sweep/rule is not on the energy bar",
		not BarSweep:IsAttached(powerBar, "fsr"))
	check("sweep/rule is on the shapeshift mana bar",
		BarSweep:IsAttached(manaBar, "fsr"))
	check("sweep/tick is on both bars while shifted",
		BarSweep:IsAttached(powerBar, "tick") and BarSweep:IsAttached(manaBar, "tick"))

	-- UNIT_DISPLAYPOWER flipping the displayed type re-evaluates the attachment
	-- with no config reload. This is why the call lives in Update, not Layout.
	stub.units.player.powerType = 0
	stub.units.player.powerToken = "MANA"
	stub.fire("UNIT_DISPLAYPOWER", "player")
	check("sweep/rule attaches to the power bar once it shows mana",
		BarSweep:IsAttached(powerBar, "fsr"))
	check("sweep/mana bar hides when mana is the displayed power",
		not player.elements.mana.shown)
	check("sweep/a hidden mana bar keeps no attachments",
		not BarSweep:IsAttached(manaBar, "tick")
		and not BarSweep:IsAttached(manaBar, "fsr"))

	-- Turning the option off detaches rather than merely hiding.
	powerOpts.tick.args.enabled.set(nil, false)
	check("sweep/disabling the option detaches the line",
		not BarSweep:IsAttached(powerBar, "tick"))
	powerOpts.tick.args.enabled.set(nil, true)

	----------------------------------------------------------------------------
	-- Geometry and direction
	----------------------------------------------------------------------------

	local tickLine = BarSweep:Line(powerBar, "tick")
	check("sweep/a line texture exists", tickLine ~= nil)

	st.interval = 2.0
	BarSweep:NoteTick(10000)

	powerBar:SetSize(200, 10)
	BarSweep:Render(10000)
	equal("sweep/line is the configured thickness", tickLine:GetWidth(), 2)
	equal("sweep/line spans the bar's full height", tickLine:GetHeight(), 10)
	-- Travel is the bar less the line's own thickness, so the line stays fully
	-- visible at both ends instead of hanging off the far edge.
	equal("sweep/RIGHT starts at the left edge", lineX(tickLine), 0)

	powerBar:SetSize(200, 10)
	BarSweep:Render(10001)
	near("sweep/RIGHT is halfway across at half an interval",
		lineX(tickLine), (200 - 2) / 2)

	powerOpts.tick.args.direction.set(nil, "LEFT")
	powerBar:SetSize(200, 10)
	BarSweep:NoteTick(11000)
	BarSweep:Render(11000)
	equal("sweep/LEFT mirrors it and starts at the right edge",
		lineX(tickLine), 200 - 2)
	powerOpts.tick.args.direction.set(nil, "RIGHT")

	-- The requested right-to-left travel for the five second rule, which is the
	-- default and the whole reason its direction differs from the tick's.
	local fsrLine = BarSweep:Line(powerBar, "fsr")
	BarSweep:NoteManaSpent(12000)
	powerBar:SetSize(200, 10)
	BarSweep:Render(12000)
	equal("sweep/the rule starts at the right edge on the spend",
		lineX(fsrLine), 200 - 2)
	powerBar:SetSize(200, 10)
	BarSweep:Render(12005)
	equal("sweep/the rule reaches the left edge as it expires", lineX(fsrLine), 0)

	----------------------------------------------------------------------------
	-- Opacity
	----------------------------------------------------------------------------

	powerOpts.tick.args.alpha.set(nil, 0.5)
	powerBar:SetSize(200, 10)
	BarSweep:NoteTick(12500)
	BarSweep:Render(12500)
	near("sweep/opacity reaches the line", tickLine:GetAlpha(), 0.5)

	-- The user's opacity and the rule's fade are independent and multiply. If
	-- one replaced the other, a faded line would jump back to full opacity or a
	-- dimmed line would never fade.
	powerOpts.fsr.args.alpha.set(nil, 0.8)
	BarSweep:NoteManaSpent(12600)
	powerBar:SetSize(200, 10)
	BarSweep:Render(12605.15)
	near("sweep/opacity multiplies with the fade rather than replacing it",
		fsrLine:GetAlpha(), 0.8 * 0.5)

	powerOpts.tick.args.alpha.set(nil, 0.9)
	powerOpts.fsr.args.alpha.set(nil, 0.9)

	----------------------------------------------------------------------------
	-- At maximum power, end to end
	--
	-- Isolated to the power bar's tick line: the rule and the mana bar are off,
	-- so the driver's state can only be about the setting under test.
	----------------------------------------------------------------------------

	powerOpts.fsr.args.enabled.set(nil, false)
	units.player.args.mana.args.tick.args.enabled.set(nil, false)
	units.player.args.mana.args.fsr.args.enabled.set(nil, false)
	stub.units.player.powerType = 0
	stub.units.player.powerToken = "MANA"
	stub.units.player.power = stub.units.player.powerMax

	powerOpts.tick.args.atMax.set(nil, "never")
	BarSweep:Reset()
	player:FullUpdate()
	check("sweep/a full bar with 'never' idles the driver outright",
		not BarSweep:IsRunning())

	powerOpts.tick.args.atMax.set(nil, "mana")
	player:FullUpdate()
	check("sweep/'mana' keeps a full mana bar sweeping", BarSweep:IsRunning())

	powerOpts.tick.args.atMax.set(nil, "energy")
	player:FullUpdate()
	check("sweep/'energy' drops that same full mana bar", not BarSweep:IsRunning())

	-- Below maximum the setting has no say, whatever it is set to.
	stub.units.player.power = 60
	player:FullUpdate()
	check("sweep/below max the at-max setting has no say", BarSweep:IsRunning())

	powerOpts.tick.args.atMax.set(nil, "always")
	units.player.args.mana.args.tick.args.enabled.set(nil, true)
	units.player.args.mana.args.fsr.args.enabled.set(nil, true)
	powerOpts.fsr.args.enabled.set(nil, true)

	----------------------------------------------------------------------------
	-- The ticker, and the claim that pays for it
	----------------------------------------------------------------------------

	-- One driver, no matter how many lines. This is the point of building
	-- Plans 2 and 10 as one module rather than two.
	equal("sweep/exactly one driver with every line enabled", sweepDrivers(), 1)

	local timersBefore = stub.activeTickers()
	BarSweep:Refresh()
	equal("sweep/the driver is not a fifth C_Timer ticker",
		stub.activeTickers(), timersBefore)

	-- With only the five second rule enabled and no spend, nothing runs. This is
	-- the claim that justifies the feature's cost and should fail loudly.
	powerOpts.tick.args.enabled.set(nil, false)
	units.player.args.mana.args.tick.args.enabled.set(nil, false)
	BarSweep:Reset()
	powerOpts.fsr.args.enabled.set(nil, true)
	check("sweep/the rule is attached", BarSweep:IsAttached(powerBar, "fsr"))
	check("sweep/idle with the rule enabled and no spend", not BarSweep:IsRunning())

	stub.time = 13000
	BarSweep:NoteManaSpent(13000)
	check("sweep/a spend starts the driver", BarSweep:IsRunning())
	BarSweep:Render(13005.4)
	check("sweep/the driver stops once the window and fade are done",
		not BarSweep:IsRunning())

	-- The tick line, by contrast, holds the driver open for as long as its bar
	-- is visible — that is the cost Plan 2 argued for and Plan 10 rides on.
	powerOpts.tick.args.enabled.set(nil, true)
	check("sweep/the tick line keeps the driver running", BarSweep:IsRunning())
	equal("sweep/still exactly one driver", sweepDrivers(), 1)

	----------------------------------------------------------------------------
	-- Put the world back for the suites that follow
	----------------------------------------------------------------------------

	powerOpts.tick.args.enabled.set(nil, false)
	powerOpts.fsr.args.enabled.set(nil, false)
	units.player.args.mana.args.tick.args.enabled.set(nil, false)
	units.player.args.mana.args.fsr.args.enabled.set(nil, false)
	BarSweep:Reset()
	stub.units.player.powerType = 1
	stub.units.player.powerToken = "RAGE"
	stub.units.player.power = 60
	stub.time = 1000
	player:FullUpdate()
end

--------------------------------------------------------------------------------
-- 26. No stray globals
--
-- A leaked global in an addon is how two addons quietly break each other.
--------------------------------------------------------------------------------

local function testNoGlobalLeaks()
	local allowed = {
		DyrueUnitFrames = true,
		DyrueUnitFramesDB = true,
	}
	local leaked = {}
	for key, value in pairs(_G) do
		if type(key) == "string" and key:find("Dyrue") and not allowed[key] then
			-- Frames are named DyrueUF_* by design; the game puts named frames
			-- in _G and that is the documented behavior, not a leak.
			if not key:find("^DyrueUF_") and key ~= "DyrueUnitFramesHiddenHolder"
				and key ~= "DyrueUnitFramesProbeDB" then
				leaked[#leaked + 1] = key
			end
		end
	end
	if #leaked == 0 then
		ok("globals/no unexpected leaks")
	else
		fail("globals/no unexpected leaks", table.concat(leaked, ", "))
	end

	-- Common accidental leaks from a missing `local`
	local suspects = { "element", "methods", "providers", "Options", "Compat",
		"Colors", "Tags", "ColorRules", "Anchoring", "Registry", "Factory",
		"PartyGroup", "DerivedPoller", "DragMode", "TestMode", "Errors",
		"Defaults", "Migrate", "CombatQueue", "L", "ns" }
	local found = {}
	for _, name in ipairs(suspects) do
		if rawget(_G, name) ~= nil then found[#found + 1] = name end
	end
	if #found == 0 then
		ok("globals/no module tables leaked")
	else
		fail("globals/no module tables leaked", table.concat(found, ", "))
	end
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

local suites = {
	{ "tags", testTags },
	{ "colorrules", testColorRules },
	{ "defaults", testDefaults },
	{ "anchoring", testAnchoring },
	{ "combatqueue", testCombatQueue },
	{ "colors", testColors },
	{ "compat", testCompat },
	{ "migration", testMigration },
	{ "integration", testIntegration },
	{ "shapeshift-mana", testShapeshiftMana },
	{ "derived-poller", testDerivedPoller },
	{ "party-group", testPartyGroup },
	{ "circuit-breaker", testCircuitBreaker },
	{ "options", testOptions },
	{ "focus-gating", testFocusGating },
	{ "combat-deferral", testCombatDeferral },
	{ "drag-mode", testDragMode },
	{ "text-coloring", testTextColoring },
	{ "aura-filtering", testAuraFiltering },
	{ "derived-identity", testDerivedIdentity },
	{ "tools-and-modes", testToolsAndModes },
	{ "slash-commands", testSlashCommands },
	{ "frame-appearance", testFrameAppearance },
	{ "textures", testTextures },
	{ "indicators", testIndicators },
	{ "player-buffs", testPlayerBuffs },
	{ "mana-text", testManaText },
	{ "brightness", testBrightness },
	{ "bar-stack", testBarStack },
	{ "draw-order", testDrawOrder },
	{ "bar-background", testBarBackground },
	{ "portrait", testPortrait },
	{ "combo-points", testComboPoints },
	{ "bar-sweep", testBarSweep },
	{ "global-leaks", testNoGlobalLeaks },
}

local function run()
	setupWorld()
	_G.__setupWorld = setupWorld

	for _, suite in ipairs(suites) do
		local name, fn = suite[1], suite[2]
		local success, err = pcall(fn)
		if not success then
			fail(name .. " (suite crashed)", err)
		end
	end

	return results
end

return run
