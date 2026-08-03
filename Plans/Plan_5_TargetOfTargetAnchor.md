# Plan 5 — Target of Target Anchor

**Status:** Implemented on `Plan-5-target-of-target-anchor`.
**Created:** 2 August 2026
**Branch:** `Plan-5-target-of-target-anchor`

---

## Outcome

Shipped as recommended: `RIGHT` → `LEFT`, `x = -4`, `y = 0`. Vertically centred
against the taller target frame rather than top-aligned.

Schema 8 checks all five fields of the old anchor before moving it, so a frame
that has been dragged, nudged or re-anchored keeps its position. As predicted,
this is the one migration in the project where "untouched default" and
"deliberate choice" are genuinely distinguishable, because drag mode and the
sliders write to these same values.

16 new assertions: the shipped anchor, the live frame actually resolving to the
target frame's left edge, the migration moving an untouched profile, and two
negative cases — a dragged frame and a re-anchored one — left alone.

---

## Request

> Currently, the target of target frame anchors underneath the target frame (see
> screenshot #3). I want it to go to the left of the target frame, instead of
> underneath it.

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

Pin the frame's **right** edge to the target frame's **left** edge:

```lua
anchor = { to = "target", point = "TOPRIGHT", relativePoint = "TOPLEFT",
           x = -4, y = 0 },
```

- `TOPRIGHT` → `TOPLEFT` puts it immediately left of the target frame, tops
  aligned.
- `x = -4` leaves a small gap so the two frames do not touch. Everything else in
  the addon now tiles with no gap by default, but these are two *separate*
  frames rather than bars within one, and butting them edge to edge reads as one
  wide frame rather than two.

`y = 0` aligns the tops. The alternative — aligning centers with
`RIGHT` → `LEFT` — looks better when the two frames are different heights, which
they are (30 vs 48). Worth trying both by eye before settling; `RIGHT`/`LEFT` is
probably the nicer default and is a one-word change either way.

**Recommendation:** ship `RIGHT` → `LEFT`, `x = -4`, `y = 0`. Vertically centered
against a taller target frame looks deliberate; top-aligned looks like it
drifted.

---

## Migration

Needed. `Defaults:EnsureProfile` fills missing keys and never overwrites stored
ones, so an existing profile keeps the old anchor — the same situation as
schemas 2 through 7.

Schema 8, moving `targettarget.anchor` only when it is still on the old default
in full:

```lua
to == "target" and point == "TOPLEFT" and relativePoint == "BOTTOMLEFT"
    and x == 0 and y == -34
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
| `Core/Defaults.lua` | New `targettarget` anchor; schema to 8 |
| `Core/Migrate.lua` | Step `[7]` |
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
| Target frame near the left screen edge pushes ToT off-screen | The frame is not clamped (`SetClampedToScreen(false)` in the factory, deliberate so anchoring is predictable). The user can move it; not worth auto-flipping |
| Overlaps the target's buff/debuff groups if those grow left | Aura groups default to growing right from the frame's own edges, so no overlap by default |

---

## Estimate

30–45 minutes including the migration and tests. Small and well understood.
