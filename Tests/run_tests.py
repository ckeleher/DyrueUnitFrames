#!/usr/bin/env python3
"""Load DyrueUnitFrames into a real Lua 5.1 runtime and run the test suite.

WoW runs Lua 5.1, so the runtime here is 5.1 too — a 5.4 interpreter would
happily accept things the game rejects, and would reject `unpack`, which both
the addon and Ace3 use.

Three passes:
  1. TBC Anniversary shape   — focus present, C_UnitAuras present. Full suite.
  2. Classic Era shape       — no focus at all. Verifies SPEC §FR-8.5 / AC 14.
  3. Legacy aura API         — no C_UnitAuras, only UnitAura. Verifies risk R3.
"""
import os
import sys

from lupa.lua51 import LuaRuntime

ADDON_ROOT = sys.argv[1] if len(sys.argv) > 1 else "C:/Users/clayt/Documents/GitHub/DyrueUnitFrames"
HERE = os.path.dirname(os.path.abspath(__file__))

WORLD = """
    local stub = _G.__stub
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
                  expirationTime = 1030, sourceUnit = "player", spellId = 2001, isHarmful = true },
                { name = "Curse of Agony", icon = 4, applications = 0,
                  sourceUnit = "party2", spellId = 2002, dispelName = "Curse", isHarmful = true },
            },
        },
    })
    stub.setUnit("party1", {
        name = "Healbot", class = "PRIEST", className = "Priest", level = 60,
        isPlayer = true, health = 3000, healthMax = 3000, inParty = true,
        power = 900, powerMax = 1000, powerType = 0, powerToken = "MANA",
        reaction = 5, guid = "player-2",
    })
"""


def toc_files(root):
    """The exact load order the game would use, minus the libraries."""
    files = []
    with open(os.path.join(root, "DyrueUnitFrames.toc"), encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or line.lower().endswith(".xml"):
                continue
            files.append(line.replace("\\", "/"))
    return files


def build(mutate=""):
    """Fresh runtime with the stub installed and the addon loaded."""
    lua = LuaRuntime(unpack_returned_tuples=False, register_eval=False)

    with open(os.path.join(HERE, "wowstub.lua"), encoding="utf-8") as fh:
        lua.execute(fh.read())

    if mutate:
        lua.execute(mutate)

    lua.execute("""
        _G.__ns = {}
        _G.DyrueUnitFramesDB = {}
        function __load(path, source)
            local chunk, err = loadstring(source, "@" .. path)
            if not chunk then error("load " .. path .. ": " .. tostring(err), 0) end
            local ok, err2 = pcall(chunk, "DyrueUnitFrames", _G.__ns)
            if not ok then error("run " .. path .. ": " .. tostring(err2), 0) end
        end
    """)

    load = lua.globals().__load
    for rel in toc_files(ADDON_ROOT):
        with open(os.path.join(ADDON_ROOT, rel), encoding="utf-8-sig") as fh:
            load(rel, fh.read())

    lua.execute(WORLD)
    lua.execute("local stub = _G.__stub; stub.addon.OnInitialize(stub.addon)")
    lua.execute("local stub = _G.__stub; stub.addon.OnEnable(stub.addon)")
    return lua


def report(lua, label):
    chat = lua.eval("_G.__stub.chat")
    errored = [str(chat[i]) for i in range(1, len(chat) + 1) if "ff5555" in str(chat[i])]
    if errored:
        print("  %s produced error output:" % label)
        for line in errored:
            print("    " + line)
        return False
    return True


def pass_one():
    print("=== pass 1: TBC Anniversary shape ===")
    lua = build()
    print("  loaded, OnInitialize and OnEnable clean")

    with open(os.path.join(HERE, "tests.lua"), encoding="utf-8") as fh:
        run = lua.execute(fh.read())
    results = run()

    passed, failed = int(results["passed"]), int(results["failed"])
    if failed:
        print("  FAILURES:")
        failures = results["failures"]
        for i in range(1, len(failures) + 1):
            print("    - %s" % failures[i])
    print("  %d passed, %d failed" % (passed, failed))
    return failed == 0


def pass_two():
    """Classic Era: focus does not exist anywhere. SPEC §FR-8.5, AC 14."""
    print("=== pass 2: Classic Era shape (no focus) ===")
    lua = build("""
        local stub = _G.__stub
        stub.validEvents["PLAYER_FOCUS_CHANGED"] = nil
        _G.FocusFrame = nil
        _G.FocusUnit = nil
        function _G.GetBuildInfo() return "1.15.9", "60001", "Jul 21 2026", "11509" end
        _G.WOW_PROJECT_ID = 2
    """)

    checks = lua.execute("""
        local ns = _G.__ns
        local out = {}
        out.flavor = ns.Compat.flavor
        out.hasFocus = ns.Compat.hasFocus and 1 or 0
        out.focusFrame = ns.frames.focus ~= nil and 1 or 0
        out.focusTargetFrame = ns.frames.focustarget ~= nil and 1 or 0
        out.focusOptions = ns.Options.table.args.units.args.focus ~= nil and 1 or 0
        out.focusTargetOptions = ns.Options.table.args.units.args.focustarget ~= nil and 1 or 0
        out.playerFrame = ns.frames.player ~= nil and 1 or 0
        out.targetFrame = ns.frames.target ~= nil and 1 or 0
        out.totFrame = ns.frames.targettarget ~= nil and 1 or 0
        out.partyFrames = ns.frames.party4 ~= nil and 1 or 0
        -- Anchoring must not offer focus as a target either.
        out.focusAnchorOffered = ns.Anchoring:TargetValues("target").focus ~= nil and 1 or 0
        -- And the frame that WOULD be anchored to focus must fall back cleanly.
        out.healthValue = ns.frames.player.elements.health.bar:GetValue()
        return out
    """)

    problems = []
    if checks["hasFocus"] != 0:
        problems.append("Compat.hasFocus should be false")
    if checks["focusFrame"] != 0:
        problems.append("focus frame was created")
    if checks["focusTargetFrame"] != 0:
        problems.append("focustarget frame was created")
    if checks["focusOptions"] != 0:
        problems.append("focus options subtree was built")
    if checks["focusTargetOptions"] != 0:
        problems.append("focustarget options subtree was built")
    if checks["focusAnchorOffered"] != 0:
        problems.append("focus offered as an anchor target")
    for key in ("playerFrame", "targetFrame", "totFrame", "partyFrames"):
        if checks[key] != 1:
            problems.append("%s missing" % key)
    if checks["healthValue"] != 4200:
        problems.append("player health did not update (got %s)" % checks["healthValue"])
    if checks["flavor"] != "vanilla":
        problems.append("flavor should be vanilla, got %s" % checks["flavor"])

    clean = report(lua, "Classic Era pass")
    if problems:
        for p in problems:
            print("  FAIL: %s" % p)
    else:
        print("  focus absent, everything else present, no errors")
    return not problems and clean


def pass_three():
    """A client with only the legacy UnitAura signature. Risk R3."""
    print("=== pass 3: legacy aura API (no C_UnitAuras) ===")
    lua = build("""
        local stub = _G.__stub
        _G.C_UnitAuras = nil
        -- The Classic-era positional signature.
        function _G.UnitAura(u, index, filter)
            local d = stub.units[u]
            if not d or not d.auras then return nil end
            local a = d.auras[filter] and d.auras[filter][index]
            if not a then return nil end
            return a.name, a.icon, a.applications, a.dispelName, a.duration,
                   a.expirationTime, a.sourceUnit, false, nil, a.spellId,
                   nil, nil, a.sourceUnit == "player"
        end
    """)

    checks = lua.execute("""
        local ns = _G.__ns
        local out = {}
        out.usesLegacy = ns.Compat.hasUnitAurasAPI and 1 or 0
        local target = ns.frames.target
        local buffs = target.elements.auras and target.elements.auras.buffs
        out.buffCount = buffs and #buffs.list or -1
        out.firstName = buffs and buffs.list[1] and buffs.list[1].name or "none"
        out.firstOwn = (buffs and buffs.list[1] and buffs.list[1].own) and 1 or 0
        local debuffs = target.elements.auras and target.elements.auras.debuffs
        out.debuffCount = debuffs and #debuffs.list or -1
        out.stacks = debuffs and debuffs.list[1] and debuffs.list[1].count or -1
        out.dispel = debuffs and debuffs.buttons[1] and 1 or 0
        return out
    """)

    problems = []
    if checks["usesLegacy"] != 0:
        problems.append("should have fallen back to UnitAura")
    if checks["buffCount"] != 2:
        problems.append("expected 2 buffs, got %s" % checks["buffCount"])
    if checks["firstName"] != "Blessing":
        problems.append("own-first sort broken on the legacy path (got %s)" % checks["firstName"])
    if checks["firstOwn"] != 1:
        problems.append("source not detected on the legacy path")
    if checks["debuffCount"] != 2:
        problems.append("expected 2 debuffs, got %s" % checks["debuffCount"])
    if checks["stacks"] != 5:
        problems.append("stack count lost on the legacy path (got %s)" % checks["stacks"])

    clean = report(lua, "legacy aura pass")
    if problems:
        for p in problems:
            print("  FAIL: %s" % p)
    else:
        print("  legacy UnitAura path produces identical results")
    return not problems and clean


def pass_four():
    """A client that still has UNIT_COMBO_POINTS.

    The Anniversary client does not — C_EventUtils.IsEventValid says false —
    and the stub models that, because modelling a client that still had it is
    exactly what let the combo bar pass every test and never update in game.
    This pass covers the other side: where the event does exist, it is used,
    and it is filtered against "player" on the TARGET frame.
    """
    print("=== pass 4: a client that still has UNIT_COMBO_POINTS ===")
    lua = build("""
        _G.__stub.validEvents["UNIT_COMBO_POINTS"] = true
    """)

    checks = lua.execute("""
        local ns, stub = _G.__ns, _G.__stub
        local out = {}
        local target = ns.frames.target
        out.valid = ns.Compat.HasEvent("UNIT_COMBO_POINTS") and 1 or 0
        out.described = ns.Compat.Describe().hasUnitComboPoints and 1 or 0

        local reg = target.__events["UNIT_COMBO_POINTS"]
        out.registered = reg ~= nil and 1 or 0
        out.filter = (type(reg) == "table" and tostring(reg[1])) or "unfiltered"

        -- And it actually drives the bar.
        stub.units.target.combo = 3
        target.elements.combo.lastPoints = nil
        stub.fire("UNIT_COMBO_POINTS", "player")
        local el = target.elements.combo
        local c = el.pips[3].__color
        local cfg = ns:UnitConfig("target").combo
        out.thirdPipFilled = (c and c[1] == cfg.color.r) and 1 or 0
        local d = el.pips[4].__color
        out.fourthPipEmpty = (d and d[1] == cfg.emptyColor.r) and 1 or 0
        return out
    """)

    problems = []
    if checks["valid"] != 1:
        problems.append("HasEvent should see the event")
    if checks["described"] != 1:
        problems.append("/duf compat should report it present")
    if checks["registered"] != 1:
        problems.append("UNIT_COMBO_POINTS was not registered")
    if checks["filter"] != "player":
        problems.append("filtered against %s, expected player" % checks["filter"])
    if checks["thirdPipFilled"] != 1 or checks["fourthPipEmpty"] != 1:
        problems.append("the event did not drive the bar")

    clean = report(lua, "combo-point event pass")
    if problems:
        for p in problems:
            print("  FAIL: %s" % p)
    else:
        print("  event present, registered against player, drives the bar")
    return not problems and clean


def main():
    passes = [pass_one(), pass_two(), pass_three(), pass_four()]
    print()
    if all(passes):
        print("ALL PASSES GREEN")
        return 0
    print("SOME PASSES FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
