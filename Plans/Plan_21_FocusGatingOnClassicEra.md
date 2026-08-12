# Plan 21 — Focus Gating on Classic Era

**Status:** Not started.
**Created:** 11 August 2026
**Branch:** `Plan-21-focus-gating-era`

---

## Origin

Not a feature request. This came out of `/dufprobe secrets` while chasing an
unrelated question for Plan 19, and it is a live defect on a shipped client. The
request text below is the instruction to write it up; the reason it exists is the
finding in `Documents/COMPAT_FINDINGS.md` under *§FR-8.5 is right about Era, but
`Compat.hasFocus` is wrong*.

## Request

> yes, write a plan, then refocus on predictive healing

---

## The defect

`Compat.hasFocus` returns **true on Classic Era**, where focus does not work.
Measured on both clients, 11 August 2026:

| Signal | Era 1.15.9 | TBC 2.5.6 |
|---|---|---|
| `PLAYER_FOCUS_CHANGED` valid | yes | yes |
| `FocusFrame` global | yes | yes |
| `FocusUnit()` / `ClearFocus()` | yes | yes |
| `FocusFrame` / `FocusFrameToT` Blizzard frames | yes | yes |
| `SLASH_FOCUS1` | `/focus` | `/focus` |
| `SlashCmdList["FOCUS"]` | nil | nil |
| **`/focus` a target, then `UnitExists("focus")`** | **no** | **yes** |

The TBC column is the positive control: the same check detected a working focus
one minute earlier on the other client, so the Era result is the client's
behaviour rather than a broken probe.

**Consequences today**, all on Era:

* `Units/Registry.lua:75` and `:85` gate the `focus` and `focustarget` frames on
  `requires = "hasFocus"`, so both are created.
* Their config trees are shown.
* `focus` is offered as an anchor target that can never resolve.

**Severity is moderate.** Both frames use `RegisterUnitWatch`, so a unit that
never exists is a frame that never shows. What the user actually sees is config
noise and an anchor option that silently does nothing.

---

## SPEC deviation — required argument

`Documents/SPEC.md` §FR-8.5 says, in terms:

> Gating is on the probed `Compat.hasFocus` capability flag, **never on a TOC
> version comparison.**

This plan breaks that clause deliberately, and the argument has to be recorded in
`COMPAT_FINDINGS.md` when implemented:

1. **The rule is unsatisfiable here.** Eight independent load-time signals were
   measured on both clients and every one is identical while the behaviour
   differs. There is no feature to probe. This is not a shortcut taken instead of
   probing — the probing was done, twice, on two clients, and is written up.

2. **`/focus` is not visible from Lua on either client.** It is handled in the C
   client the same way `/target` is, which is why `SlashCmdList["FOCUS"]` is nil
   even where focus works. The last plausible discriminator is structurally
   unavailable.

3. **The rule's intent is preserved.** §FR-8.5's purpose is that a future client
   which gains or loses focus should not need a code change. A *floor* plus the
   event keeps that: any client from TBC onward gets focus, and one that drops
   the event loses it regardless of version.

4. **The escape hatch already exists and was built for this.**
   `Core/Compat.lua`'s `SetFocusOverride` comment says it exists "purely so a
   wrong probe on a future patch is a setting change rather than a broken
   install." This is a wrong probe on a current patch.

§FR-8.5 should be amended in the same commit: strike "never on a TOC version
comparison", and replace it with the floor-plus-event predicate and a pointer to
the eight-signal finding.

---

## Design

One line, in `Core/Compat.lua`'s `probeFocus`:

```lua
-- Focus exists from TBC onward. A FLOOR rather than an equality so a later
-- client needs no new project ID added to a list, and ANDed with the event so a
-- client that drops focus entirely still loses it.
local FOCUS_TOC_FLOOR = 20000

local function probeFocus()
    if (tonumber(Compat.tocVersion) or 0) < FOCUS_TOC_FLOOR then return false end
    …existing signal checks, unchanged…
end
```

The existing checks stay as the *upper* bound: version alone is not sufficient,
it is necessary. Nothing else in the addon changes — `requires = "hasFocus"`,
the options gating and `Compat.SetFocusOverride` all read the same flag and
start behaving correctly the moment it does.

---

## Schema and migration

**No schema change.** No keys added, no stored values rewritten.

**One real migration question**, and it turns out to be already handled. A user
who anchored a frame to `focus` on Era — possible only because the focus frame
currently exists there — will have that frame's anchor stop resolving.
`Systems/Anchoring.lua:126` already covers it:

> If the target frame does not exist (focus on Classic Era, a disabled unit) we
> silently fall back to the screen rather than erroring.

So the frame reverts to a screen-relative position rather than breaking. That
comment was written in anticipation of exactly this case, before anyone knew the
flag was wrong.

**Deliberately not migrated.** Rewriting such an anchor to something else would
be guessing at intent, and the fallback is visible and correctable in one drag.
Worth a line in the release note rather than a schema bump.

---

## Tests

The suite already runs a **pass 2** that models "Classic Era shape — no focus
anywhere" and asserts no focus frame is created, no focus options are built, and
focus is not offered as an anchor target. That pass currently fakes the absence
by removing the signals.

* **Change pass 2 to model the real client**: signals all present, TOC 11509. It
  must still assert everything it asserts today. This is the test that would have
  caught the defect, and the reason it did not is that the stub modelled a more
  honest client than the real one — the same lesson `COMPAT_FINDINGS` records
  against `UNIT_COMBO_POINTS`.
* TOC 20506 with the same signals → focus present, frames built.
* A client at TOC 20506 with the event absent → focus absent. Pins the AND.
* `focusOverride = "on"` still forces focus on regardless of the floor, and
  `"off"` still forces it off. The escape hatch must outrank the new predicate.
* An anchor targeting `focus` on Era falls back to screen-relative without
  erroring — asserting the behaviour `Anchoring` already documents.

---

## Risks

| Risk | Handling |
|---|---|
| **A later Classic client gains focus and the floor excludes it** | The floor is `>= 20000`, so anything from TBC onward passes. Only a hypothetical Era-line client that gained focus would be wrong, and `focusOverride = "on"` fixes it without a patch |
| **Someone's Era layout is anchored to focus** | Falls back to screen-relative, already documented in `Anchoring`. Visible and fixable in one drag. Release note, not a migration |
| **The floor is wrong for a client nobody has tested** | It is a version comparison and it is honest about being one. `/duf compat` reports `hasFocusProbed` and `hasFocus` separately, so a disagreement is diagnosable in game |
| **This normalises version checks** | The SPEC amendment names this as the exception and cites the eight measured signals. The rule stays; what changes is that it now has a documented boundary |

---

## Estimate

| Piece | Hours |
|---|---|
| `Core/Compat.lua` predicate | 0.25 |
| SPEC §FR-8.5 amendment + `COMPAT_FINDINGS` deviation row | 0.5 |
| Test pass 2 rework + the four new assertions | 1 |
| **Total** | **~1.75** |

Most of it is the test pass, and that is where the value is: pass 2 has been
green this whole time against a client that does not exist.
