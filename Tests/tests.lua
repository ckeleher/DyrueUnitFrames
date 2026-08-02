-- Headless test suite for DyrueUnitFrames.
--
-- Exercises the pure-logic core (tags, colour rules, defaults merging, anchor
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
-- 2. Colour rules
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
	equal("defaults/health is green", profile.units.player.health.color.g, 0.9)
	equal("defaults/party pets disabled", profile.units.partypet1.enabled, false)
	equal("defaults/blizzard frames hidden", profile.general.blizzardFrames, "hide")
	equal("defaults/blizzard party frames hidden too", profile.general.blizzardParty, true)
	check("defaults/target has aura groups enabled", profile.units.target.auras.buffs.enabled)
	check("defaults/derived units ship auras off", not profile.units.targettarget.auras.buffs.enabled)

	-- The behaviour AceDB's metatable defaults would have broken: a deleted
	-- text element must STAY deleted across a re-fill.
	local before = #profile.units.player.texts
	table.remove(profile.units.player.texts, 1)
	Defaults:EnsureProfile(profile)
	equal("defaults/deleted text stays deleted", #profile.units.player.texts, before - 1)

	-- Same for a user-added colour rule.
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
-- 6. Colours
--------------------------------------------------------------------------------

local function testColors()
	local Colors = ns.Colors

	local r, g, b = Colors:Class("player")
	near("colors/class colour for a player", r, 1.0)
	near("colors/druid orange", g, 0.49)

	check("colors/no class colour for an NPC", Colors:Class("target") == nil)

	r = Colors:Reaction("target")
	near("colors/hostile reaction is red", r, 0.87)

	-- FR-4.4: class mode on an NPC falls through to the configured fallback
	local cfg = { colorMode = "class", npcFallback = "reaction",
		color = { r = 0, g = 0.9, b = 0.1 }, offlineColor = {}, tapColor = {} }
	r, g, b = Colors:HealthBar("target", cfg)
	near("colors/NPC falls through to reaction", r, 0.87)

	cfg.npcFallback = "static"
	r, g, b = Colors:HealthBar("target", cfg)
	near("colors/NPC falls through to the static colour", g, 0.9)

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

	-- A missing migration step backs the profile up rather than discarding it.
	local db = {}
	local orphan = { schemaVersion = 0, marker = "precious" }
	success = Migrate:Run(orphan, db)
	check("migrate/missing step fails safely", not success)
	local backedUp = false
	for _, snapshot in pairs(db.backup or {}) do
		if snapshot.marker == "precious" then backedUp = true end
	end
	check("migrate/old settings are backed up", backedUp)
	equal("migrate/defaults loaded after failure", orphan.schemaVersion, Defaults.SCHEMA_VERSION)

	-- Step 1 -> 2: the cosmetic defaults changed, and Defaults:EnsureProfile
	-- never overwrites a stored value, so an existing profile would otherwise
	-- keep the old look on every frame forever.
	local v1 = {
		schemaVersion = 1,
		units = {},
		general = { blizzardFrames = "none", blizzardParty = false },
	}
	for _, key in ipairs({ "player", "target", "party1", "pet", "targettarget" }) do
		v1.units[key] = {
			width = 200, height = 46,
			anchor = { to = "UIParent", point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 },
			background = { enabled = true, color = { r = 0, g = 0, b = 0, a = 0.6 }, inset = 0 },
			health = { texture = "Blizzard" },
			power = { texture = "Blizzard", spacing = 1 },
			mana = { texture = "Blizzard", spacing = 1 },
		}
	end
	-- One frame the user has deliberately customised.
	v1.units.target.health.texture = "Smooth"
	v1.units.target.power.spacing = 6
	v1.units.pet.background.color = { r = 0.2, g = 0, b = 0, a = 0.9 }

	success = Migrate:Run(v1, {})
	check("migrate/v1 profile migrates", success)
	equal("migrate/stamped at the target version", v1.schemaVersion, Defaults.SCHEMA_VERSION)

	local stale = {}
	for _, key in ipairs({ "player", "party1", "targettarget" }) do
		local cfg = v1.units[key]
		if cfg.health.texture ~= "Dyrue Flat" then stale[#stale + 1] = key .. ".health.texture" end
		if cfg.power.texture ~= "Dyrue Flat" then stale[#stale + 1] = key .. ".power.texture" end
		if cfg.mana.texture ~= "Dyrue Flat" then stale[#stale + 1] = key .. ".mana.texture" end
		if cfg.power.spacing ~= 0 then stale[#stale + 1] = key .. ".power.spacing" end
		if cfg.mana.spacing ~= 0 then stale[#stale + 1] = key .. ".mana.spacing" end
		if cfg.background.enabled ~= false then stale[#stale + 1] = key .. ".background" end
	end
	if #stale == 0 then
		ok("migrate/every unit is carried forward, not just the player")
	else
		fail("migrate/every unit is carried forward, not just the player",
			table.concat(stale, ", "))
	end

	-- Deliberate choices survive.
	equal("migrate/custom texture untouched", v1.units.target.health.texture, "Smooth")
	equal("migrate/custom spacing untouched", v1.units.target.power.spacing, 6)
	check("migrate/custom backdrop colour keeps the backdrop on",
		v1.units.pet.background.enabled == true)

	-- Positions are never touched by a cosmetic migration.
	equal("migrate/layout untouched", v1.units.player.width, 200)
	equal("migrate/anchor untouched", v1.units.player.anchor.point, "CENTER")

	-- Step 2 -> 3: Blizzard's frames now ship hidden.
	-- The chain must run EVERY step, not just the first one.
	equal("migrate/v1 chain ran every step", v1.general.blizzardFrames, "hide")
	equal("migrate/party frames hidden by the chain", v1.general.blizzardParty, true)

	local v2 = {
		schemaVersion = 2,
		units = {},
		general = { blizzardFrames = "none", blizzardParty = false },
	}
	success = Migrate:Run(v2, {})
	check("migrate/v2 profile migrates", success)
	equal("migrate/blizzard frames flipped to hide", v2.general.blizzardFrames, "hide")
	equal("migrate/blizzard party flipped on", v2.general.blizzardParty, true)

	-- An explicit "hide" is already correct and must not be disturbed.
	local already = {
		schemaVersion = 2, units = {},
		general = { blizzardFrames = "hide", blizzardParty = true },
	}
	Migrate:Run(already, {})
	equal("migrate/already hiding stays hiding", already.general.blizzardFrames, "hide")

	-- Running it again is a no-op.
	success = Migrate:Run(v1, {})
	check("migrate/re-running is a no-op", success)
	equal("migrate/still at target", v1.schemaVersion, Defaults.SCHEMA_VERSION)
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

	-- Colour round trip
	local color = tree.args.units.args.player.args.health.args.color
	equal("options/health colour is a colour control", color.type, "color")
	color.set(nil, 0.1, 0.2, 0.3, 1)
	local r, g, b = color.get(nil)
	check("options/colour round trip", r == 0.1 and g == 0.2 and b == 0.3)

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
	frame.__left, frame.__bottom = 1060, 640    -- centre would be 1060+110, 640+24
	frame.__w, frame.__h = 220, 48

	local overlay
	for _, f in ipairs(stub.frames) do
		if f.frame == frame and f.__scripts.OnDragStop then overlay = f end
	end
	check("drag/overlay created", overlay ~= nil)

	overlay.dragging = true
	overlay.__scripts.OnDragStop(overlay)

	-- Frame centre (1170, 664) minus UIParent centre (960, 540)
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
-- 18. AC 6 / 7: colour rules and difficulty colour on a real text element
--------------------------------------------------------------------------------

local function testTextColoring()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")

	-- FR-3.3: colour the NAME by the unit's HEALTH. The metric under test is
	-- deliberately unrelated to the element being coloured.
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
	check("text/percentage rule colours the name", r == 1 and g == 0.5 and b == 0)

	-- Absolute rule first this time
	nameText.rules[1], nameText.rules[2] = nameText.rules[2], nameText.rules[1]
	ns:BumpSerial()
	stub.units.player.health = 400
	player:FullUpdate()
	r, g, b = fs:GetTextColor()
	check("text/absolute rule colours the name", r == 1 and g == 0 and b == 0)

	stub.units.player.health = 4200
	nameText.colorMode = "static"
	nameText.rules = {}
	ns:BumpSerial()
	ns:RefreshUnit("player")

	-- AC 7: difficulty colour must equal the game's own function at every
	-- level difference, including the ?? case.
	local target = ns.frames.target
	local levelText = ns:UnitConfig("target").texts[1]
	equal("text/level defaults to difficulty colouring", levelText.colorMode, "difficulty")

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
	equal("text/difficulty colour matches the base game at -8..+8", mismatches, 0)

	stub.units.target.level = -1
	target:FullUpdate()
	equal("text/unknown level renders ??", levelString:GetText(), "????")
	r = levelString:GetTextColor()
	near("text/unknown level uses the boss colour", r, 1)
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

	-- FR-5.3: own auras are larger, and bordered in the chosen colour
	buffs.borderMode = "own"
	buffs.ownBorderColor = { r = 1, g = 0.85, b = 0.1, a = 1 }
	buffs.ownSizeMultiplier = 2
	refresh()
	local group = target.elements.auras.buffs
	equal("auras/own aura scaled by the multiplier",
		group.buttons[1]:GetWidth(), buffs.size * 2)
	equal("auras/other aura at base size", group.buttons[2]:GetWidth(), buffs.size)
	local border = group.buttons[1].border.__color
	check("auras/own aura border colour applied",
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
		check("auras/curse border uses the game's colour",
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
		if not ticker.cancelled and ticker.interval == 0.25 then ticker.callback() end
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
	equal("tools/colour mode copied", destination.health.colorMode, "gradient")
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

	-- Party frames get distinct class colours so class colouring is visible
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
-- 25. Bar brightness
--------------------------------------------------------------------------------

local function testBrightness()
	local player = ns.frames.player
	local cfg = ns:UnitConfig("player")
	local health = ns.Options.table.args.units.args.player.args.health.args

	-- A known colour so the arithmetic is checkable.
	cfg.health.colorMode = "static"
	cfg.health.color = { r = 0.4, g = 0.8, b = 0.2, a = 1 }
	cfg.health.bgMultiplier = 0.5
	cfg.health.bgAlpha = 1
	ns:BumpSerial()
	ns:RefreshUnit("player")

	local bar, bg = player.elements.health.bar, player.elements.health.bg

	equal("brightness/defaults to 1", cfg.health.brightness, 1)
	local r, g, b = bar:GetStatusBarColor()
	near("brightness/1 leaves the colour alone", g, 0.8)

	health.brightness.set(nil, 0.5)
	r, g, b = bar:GetStatusBarColor()
	near("brightness/halved red", r, 0.2)
	near("brightness/halved green", g, 0.4)
	near("brightness/halved blue", b, 0.1)

	-- The background derives from the bar colour, so it must follow.
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
	check("brightness/zero is honoured and not swallowed by an or-default",
		r == 0 and g == 0 and b == 0)

	health.brightness.set(nil, 1)

	-- It applies to whatever the mode resolved, not just to a static colour.
	cfg.health.colorMode = "class"
	ns:BumpSerial()
	ns:RefreshUnit("player")
	local classR, classG, classB = bar:GetStatusBarColor()
	health.brightness.set(nil, 0.5)
	r, g, b = bar:GetStatusBarColor()
	near("brightness/scales a class colour too", g, classG * 0.5)
	health.brightness.set(nil, 1)

	-- Power and shapeshift mana have their own independent controls.
	local power = ns.Options.table.args.units.args.player.args.power.args
	equal("brightness/power defaults to 1", cfg.power.brightness, 1)
	local powerBefore = select(2, player.elements.power.bar:GetStatusBarColor())
	power.brightness.set(nil, 0.5)
	near("brightness/power scales independently",
		select(2, player.elements.power.bar:GetStatusBarColor()), powerBefore * 0.5)
	near("brightness/health unaffected by the power slider",
		select(2, bar:GetStatusBarColor()), classG)
	power.brightness.set(nil, 1)

	equal("brightness/mana defaults to 1", cfg.mana.brightness, 1)

	-- Every unit gets the control, not just the player.
	local missing = {}
	for _, def in ipairs(ns.Registry:SortedAvailable()) do
		local unitCfg = ns:UnitConfig(def.key)
		for _, key in ipairs({ "health", "power", "mana" }) do
			if unitCfg[key].brightness ~= 1 then
				missing[#missing + 1] = def.key .. "." .. key
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
	equal("barstack/separator is honoured when asked for", gapY, -(newHealthHeight + 4))
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

	-- A known bar colour so the maths is checkable.
	cfg.health.colorMode = "static"
	cfg.health.color = { r = 0, g = 1, b = 0, a = 1 }
	ns:BumpSerial()
	ns:RefreshUnit("player")

	local bg = player.elements.health.bg

	health.bgMultiplier.set(nil, 0.5)
	health.bgAlpha.set(nil, 1)
	local r, g, b, a = bg:GetVertexColor()
	near("background/brightness scales the bar colour", g, 0.5)
	near("background/opacity at full", a, 1)

	health.bgAlpha.set(nil, 0.3)
	r, g, b, a = bg:GetVertexColor()
	near("background/opacity reaches the texture", a, 0.3)
	near("background/brightness unaffected by opacity", g, 0.5)

	-- Zero is a legitimate value and must not be swallowed by an `or` default.
	health.bgAlpha.set(nil, 0)
	r, g, b, a = bg:GetVertexColor()
	equal("background/zero opacity is honoured", a, 0)

	health.bgMultiplier.set(nil, 0)
	r, g, b, a = bg:GetVertexColor()
	equal("background/zero brightness is honoured", g, 0)

	-- Power bar has its own independent pair.
	local power = ns.Options.table.args.units.args.player.args.power.args
	power.bgAlpha.set(nil, 0.7)
	local powerBg = player.elements.power.bg
	near("background/power opacity is independent", select(4, powerBg:GetVertexColor()), 0.7)
	near("background/health opacity unchanged", select(4, bg:GetVertexColor()), 0)

	-- The filled portion of the bar is deliberately NOT affected: background
	-- settings describe the depleted part only.
	local barR, barG, barB = player.elements.health.bar:GetStatusBarColor()
	near("background/bar fill colour untouched", barG, 1)

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

	-- 2D
	portrait.mode.set(nil, "2d")
	local el = player.elements.portrait
	check("portrait/2D builds", el ~= nil)
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
-- 25. No stray globals
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
			-- in _G and that is the documented behaviour, not a leak.
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
	{ "text-colouring", testTextColoring },
	{ "aura-filtering", testAuraFiltering },
	{ "derived-identity", testDerivedIdentity },
	{ "tools-and-modes", testToolsAndModes },
	{ "slash-commands", testSlashCommands },
	{ "frame-appearance", testFrameAppearance },
	{ "textures", testTextures },
	{ "brightness", testBrightness },
	{ "bar-stack", testBarStack },
	{ "draw-order", testDrawOrder },
	{ "bar-background", testBarBackground },
	{ "portrait", testPortrait },
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
