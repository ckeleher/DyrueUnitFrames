# Plan 5 — Target of Target Anchor

**Status:** Implemented on `Plan-5-target-of-target-anchor`.
**Created:** 2 August 2026
**Branch:** `Plan-5-target-of-target-anchor`

---

## Outcome

Shipped as `LEFT` → `RIGHT`, `x = 4`, `y = 0` — right of the target frame,
vertically centred against it rather than top-aligned.

Two schema steps rather than one, because the first implementation followed the
request as written and put it on the **left**. Schema 8 had already shipped to a
live profile by the time that was corrected, so:

- **7 → 8** moves it out from under the target frame, straight to the right.
- **8 → 9** moves a profile that reached the interim left-side value across.

Both check every field of the anchor they are replacing, so a frame that has
been dragged, nudged or re-anchored keeps its position — including one
deliberately placed on the left, which is left alone. As predicted, this is the
one migration in the project where "untouched default" and "deliberate choice"
are genuinely distinguishable, because drag mode and the sliders write to these
same values.

21 assertions: the shipped anchor, the live frame resolving to the target
frame's right edge, both migration steps, and four negative cases — a dragged
frame, a re-anchored one, and a deliberately left-placed one.

---

## Request

> Currently, the target of target frame anchors underneath the target frame (see
> screenshot #3). I want it to go to the left of the target frame, instead of
> underneath it.

---

## Correction

The request says **left**. The actual requirement is **right**, confirmed
directly afterwards:

> maybe i misspoke, i wanted the ToT frame on the right side of the target frame

The quoted request above is left exactly as written, per `Skills/NewWork.md` —
it records what was asked at the time, which is what makes a plan checkable
later. This section records that it was superseded rather than editing the
quote to match.

Everything below reflects the corrected requirement.

---

## Current state

`Core/Defaults.lua`, `buildUnits()`:

```lua
u.targettarget = unit({
    width = 130, height = 30,
    anchor = { to = "target", point = "TOPLEFT", relativePoint = "BOTTOMLEFT",
               x = 0, y = -34 },
    power = { enabled = false },
    texts = derivedTexts(),
})
```

The frame's top-left is pinned to the target frame's bottom-left, dropped 34px.

---

## Change

Pin the frame's **left** edge to the target frame's **right** edge:

```lua
anchor = { to = "target", point = "LEFT", relativePoint = "RIGHT",
           x = 4, y = 0 },
```

- `LEFT` → `RIGHT` puts it immediately right of the target frame.
- `x = 4` leaves a small gap so the two frames do not touch. Everything else in
  the addon now tiles with no gap by default, but these are two *separate*
  frames rather than bars within one, and butting them edge to edge reads as one
  wide frame rather than two.

`LEFT` → `RIGHT` centres the two frames vertically, which matters because they
are different heights (30 vs 48). The alternative — `TOPLEFT` → `TOPRIGHT`,
aligning tops — reads as drift rather than intent against a taller neighbour.

**Recommendation:** ship `LEFT` → `RIGHT`, `x = 4`, `y = 0`.

---

## Migration

Needed. `Defaults:EnsureProfile` fills missing keys and never overwrites stored
ones, so an existing profile keeps the old anchor — the same situation as
schemas 2 through 7.

Two steps, because the first implementation followed the request as written and
shipped a left-side anchor at schema 8 before the correction landed.

**Schema 8** moves `targettarget.anchor` only when it is still on the old
default in full:

```lua
to == "target" and point == "TOPLEFT" and relativePoint == "BOTTOMLEFT"
    and x == 0 and y == -34
```

**Schema 9** moves a profile that reached the interim left-side value across,
under the same all-fields rule:

```lua
to == "target" and point == "RIGHT" and relativePoint == "LEFT"
    and x == -4 and y == 0
```

Checking every field rather than just `to` means a frame the user has dragged,
nudged or re-anchored is left alone. Drag mode writes to these same values
(`Config/DragMode.lua`), so "has the user moved it" is genuinely answerable
here — unlike the cosmetic migrations, where a deliberate choice and an
untouched default are indistinguishable.

That makes this the cleanest migration of the set, and worth doing properly.

---

## Files

| File | Change |
|---|---|
| `Core/Defaults.lua` | New `targettarget` anchor; schema to 9 |
| `Core/Migrate.lua` | Steps `[7]` and `[8]` |
| `Tests/tests.lua` | Default assertion, migration assertions |

---

## Tests

- `targettarget` ships anchored to `target` with the new point pair.
- Migration moves a profile still on the exact old anchor.
- Migration leaves a moved frame alone — assert on a profile whose
  `targettarget.anchor.x` is 200, and on one anchored to `UIParent`.
- The anchor graph still resolves and produces no cycle (`Anchoring:WouldCycle`
  already covers this, but the ordering test in the anchoring suite should
  include the new pairing).
- `Anchoring:SortedKeys` still puts `target` before `targettarget`.

---

## Risks

| Risk | Handling |
|---|---|
| Target frame near the right screen edge pushes ToT off-screen | The frame is not clamped (`SetClampedToScreen(false)` in the factory, deliberate so anchoring is predictable). The user can move it; not worth auto-flipping |
| Overlaps the target's buff/debuff groups, which grow right | Real: aura groups default to `growthX = RIGHT` anchored to the frame's own edges, so a wide buff row will run under the ToT frame. The groups are anchored to the target frame rather than to ToT, so they pass behind it rather than colliding, but it is worth an eye once buffs are enabled on the target |

---

## Estimate

30–45 minutes including the migration and tests. Small and well understood.
