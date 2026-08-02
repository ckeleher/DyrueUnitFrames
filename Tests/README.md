# Tests

A headless regression suite. It loads the addon into a real **Lua 5.1**
interpreter — the same version WoW runs — against a stubbed WoW API, and
exercises the logic without a game client.

This is not in `SPEC.md`'s file layout. It is here because the premise of the
whole project is "the last one kept breaking", and a suite that can be run in
thirty seconds after a Blizzard patch, before logging in, is worth more than
its weight. Step 6 of the patch-day playbook gets a lot cheaper with it.

## What it catches

It found a real one on its first run: **Lua 5.1's `xpcall` takes no arguments
for the called function.** Every element update was being dispatched through
`xpcall(fn, handler, frame)`, which silently called `fn()` with no arguments —
so every health bar, text element and aura in the addon was quietly failing and
the circuit breaker was eating the evidence. Static analysis cannot see that.
`Core/Errors.lua` now routes arguments through a nullary trampoline.

## Running

Needs Python 3 and [lupa](https://pypi.org/project/lupa/) (which bundles a
Lua 5.1 interpreter — nothing has to be installed system-wide):

```bash
python -m venv venv && venv/Scripts/python -m pip install lupa
```

Then:

```bash
python Tests/run_tests.py
```

Three passes run, each building a fresh runtime:

| Pass | Simulates | Verifies |
|---|---|---|
| 1 | TBC Anniversary — focus present, `C_UnitAuras` present | The full suite: ~270 assertions |
| 2 | Classic Era — no focus anywhere | SPEC §FR-8.5 / AC 14: no focus frame is created, no focus options are built, focus is not offered as an anchor target, and nothing else is disturbed |
| 3 | A client with only the legacy `UnitAura` signature | Risk R3: `Compat.GetAura` produces identical results on either API |

## What is covered

Tags and empty-tag collapse · color rules at both percentage and absolute
thresholds · the defaults deep-merge (specifically that a deleted text element
or color rule *stays* deleted, which is the reason AceDB's metatable defaults
are not used) · anchor cycle detection and topological apply order · combat-queue
de-duplication and ordering · color resolution including the NPC class-color
fallback · the `HasRealHealthValues` predicate · migration including refusal to
downgrade and backup-on-failure · full frame construction and event dispatch ·
the shapeshift mana predicate and its ticker starting and stopping · the derived
poller idling at zero · party group layout and mid-combat roster changes · the
circuit breaker and safe mode · options-tree well-formedness and value
round-tripping · drag-mode commit maths · aura filtering, sorting and own-aura
differentiation · every slash command · global namespace leaks.

## What it cannot cover

Anything that needs a real client: actual rendering, 3D model frames, real
protected-function behaviour and taint, CPU and memory budgets, and whether the
API assumptions in `Documents/COMPAT_FINDINGS.md` are correct in the first
place. A green run means the logic is consistent, not that the addon works —
`Probe/DyrueUnitFrames_Probe` answers the second question.

## Static checks

```bash
python Tests/luacheck.py .      # Lua 5.1 block and bracket balance
python Tests/refcheck.py .      # dangling ns.Module:Method references
```

Both are dependency-free and run without lupa.

## Adding a test

`tests.lua` is a list of suites at the bottom. Add a function, add it to the
list. `wowstub.lua` holds the fake world; `stub.setUnit(token, data)` defines a
unit and `stub.fire(event, ...)` dispatches an event to every frame registered
for it, honouring unit filters.
