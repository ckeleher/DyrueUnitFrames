# Plan 20 — Aura Groups Overhang The Frame's Left Edge

**Status:** Implemented on `Plan-20-aura-group-overhang`, awaiting review.
**Created:** 9 August 2026
**Branch:** `Plan-20-aura-group-overhang`

**The diagnosis was confirmed by measurement, not by eye.** The new assertions
were run against the unchanged element first, and they read exactly what the
arithmetic predicted:

```
aurabounds/leftmost own icon starts at the group frame's left edge: expected ~0, got -4
aurabounds/bottom row own icon ends at the box's bottom edge:       expected ~-42, got -46
aurabounds/growing down, the top row sits on the box's top edge:    expected ~0, got 4
aurabounds/growing left, the own icon ends at the box's right edge: expected ~174, got 178
```

Four sides, four pixels, in the direction the overflow predicted.

**Deviations from the plan as written:**

* **One extra assertion, and it is load-bearing:** button one is checked to be
  the *scaled* own aura before its edges are measured. If sorting ever stops
  putting the own aura first, every edge assertion would be measuring a
  base-size icon — which is flush with its cell either way, so the whole suite
  would pass with the bug present.
* **The unscaled-grid case asserts the box dimensions and the first cell's
  edges**, not every cell centre as the plan's test list implied. `pad` enters
  every cell through the same term, so the box size plus one cell pins it; six
  more coordinates would restate the formula rather than test it.

---

## Request

> Aura anchors seem to be a bit offset from their associated unit - see
> screenshot, where the auras overhang the target frame to the left a bit. This
> overhang is exaggerated by the highlight border, but even without it, the aura
> box itself overhangs on the left. move these in a bit so they align on the left
> border by default

Accompanied by a screenshot of the player frame with six buffs above it. Five are
the player's own — visibly larger, and carrying the gold `ownBorderColor` edge,
which on adjacent icons merges into one continuous gold box — and the sixth is
someone else's, smaller and dark-bordered. The leftmost own icon starts a few
pixels to the **left** of the frame's own left edge; the gold border is the part
that makes it obvious.

Not committed as an asset: the geometry below is exact and derived, so the image
adds nothing a number does not.

---

## Diagnosis

Not a guess — the arithmetic closes on the screenshot.

Two facts from `Elements/Auras.lua`:

* **Cells are laid out on the base icon size** (`layoutGroup`, `:492-506`), so
  the first column's cell centre sits at `0.5 × size` from the group frame's left
  edge. A base-size button there is exactly flush with it.
* **Own auras are scaled up and overflow their cell, centred** — `buttonSize =
  size × ownSizeMultiplier`, anchored `CENTER` to the cell (`applyButton`,
  `:562-567`). That is deliberate: it keeps rows aligned when only some icons are
  scaled (the comment at `:489` says so).

So an own aura in column one reaches

```
overhang = (size × ownSizeMultiplier − size) / 2
         = (20 × 1.4 − 20) / 2
         = 4 px
```

past the left edge of `group.frame`. The group frame itself is anchored
`BOTTOMLEFT → TOPLEFT` at `x = 0` against `frame.content`
(`Core/Defaults.lua:157-161`), which is correct — the box is where it was asked
to be. The icons simply do not stay inside the box.

The same 4px escapes on all four sides. Two places where that is already doing
harm, unreported:

| Group | Default anchor | What overflows where |
|---|---|---|
| Player buffs | `BOTTOMLEFT → TOPLEFT`, `y = 14` | `y = 14` was chosen to clear the combo bar, which occupies `[top+2, top+12]` (`Core/Defaults.lua:626-630`). The bottom row's own icons dip to `top+10` — **2px inside the combo bar** |
| Target debuffs | `TOPLEFT → BOTTOMLEFT`, `y = −2` | The top row's own icons reach `frame bottom + 2` — **2px inside the frame** |

Both fall out of the same fix, with no default change.

### What the highlight border has to do with it

Nothing causal. `button.border` is `SetAllPoints(button)` (`:242`), i.e. drawn
*inside* the icon, so it adds no width. It makes the misalignment legible: a
4px dark-on-dark overhang is easy to miss, a 4px gold one is not. The request
already says as much; recording it so nobody goes looking for a border inset bug
that is not there.

---

## Interpretation

"Align on the left border by default" is read as: **the leftmost thing an aura
group can draw should start exactly where the unit frame starts**, with no
setting changed.

Two readings of *how*, and they are materially different work:

1. **Nudge the default.** Change `x` from `0` to `4`. Rejected: 4px is only right
   for `size = 20, ownSizeMultiplier = 1.4`. Anyone who changes either slider is
   misaligned again, in the opposite direction if they scale own auras *down*.
   It also does nothing for the other three edges.
2. **Make the group frame bound what it draws.** Pad the box by the maximum
   overflow and start the cells one pad in. `x = 0` then means what it reads as,
   at every icon size and multiplier, on all four sides, for every one of the
   nine anchor points. **Taken.**

"Left border" is taken as `frame.content`'s left edge — the frame's own extent,
which is what `anchorTo = "frame"` already resolves to (`groupAnchorWidget`,
`:455-470`). The optional frame border texture is drawn 1px *outside* content
(`Units/Factory.lua:261`), so with it enabled the aura box lands flush against
the border's inner edge rather than its outer one. That 1px is the same
convention every other element in the frame follows, and chasing it would make
aura placement depend on an unrelated setting.

---

## Design

One function changes: `layoutGroup` in `Elements/Auras.lua:472`.

```lua
local size = cfg.size or 20
local perRow = math.max(1, cfg.perRow or 8)
local rows = math.max(1, cfg.rows or 2)
local spacingX, spacingY = cfg.spacingX or 0, cfg.spacingY or 0

-- Own auras are scaled up and overflow their cell centred (FR-5.3), so an icon
-- in an outer cell reaches half the excess past the grid. Pad the frame by that
-- much and start the cells one pad in: the box then bounds every icon it can
-- draw, so anchoring it at x = 0 puts the leftmost icon's edge exactly on the
-- unit frame's instead of four pixels outside it.
local pad = size * (math.max(cfg.ownSizeMultiplier or 1, 1) - 1) / 2

group.frame:SetSize(
    2 * pad + perRow * size + (perRow - 1) * spacingX,
    2 * pad + rows * size + (rows - 1) * spacingY)

-- ... unchanged anchoring ...

cells[#cells + 1] = {
    x = pad + (c - 0.5) * size + (c - 1) * spacingX,
    y = -(pad + (r - 0.5) * size + (r - 1) * spacingY),
}
```

`math.max(..., 1)` matters: the options slider is capped at `min = 1`
(`Config/Options_Auras.lua:176-181`), but a hand-edited or imported profile can
carry less, and a negative pad would pull the grid *inward* and reintroduce the
bug mirrored.

### Why this is right at every anchor point

`SetPoint` pins one corner and the box grows away from it, and the cells move
with it by the same `pad`, so the grid never shifts relative to the pinned
corner — only the box's own extent changes:

| `point` | Box grows | Leftmost own icon's left edge |
|---|---|---|
| `BOTTOMLEFT` (buff default) | up and right | on the pinned x |
| `TOPLEFT` (debuff default) | down and right | on the pinned x |
| `CENTER` | symmetrically | grid stays centred |

At `pad = 4, size = 20, mult = 1.4`: cell 1 centre moves `10 → 14`, button
half-width is `14`, so its left edge is `0` — the box edge exactly. The outer
edge always lands on the box edge by construction, so no fractional-pixel seam
appears even when `pad` is fractional (`mult = 1.45` gives `pad = 4.5`, centre
`14.5`, half-width `14.5`, edge `0`).

### What is deliberately not changed

* **Cells stay on the base size.** Scaled icons still overflow *into their
  neighbours* — six own buffs at 28px on a 22px pitch overlap by 6px, which is
  visible in the screenshot as icons touching. That is the documented trade for
  keeping rows aligned, it is not what was reported, and changing it means
  choosing between ragged rows and a grid that reflows as auras change source.
  Out of scope; noted below.
* **No default moves.** `x`, `y`, `size`, `ownSizeMultiplier` are all untouched.

---

## Files

| File | Change |
|---|---|
| `Elements/Auras.lua` | `layoutGroup` (`:472-508`): compute `pad`, add it to `SetSize`, offset both cell coordinates by it |
| `Tests/tests.lua` | New `testAuraGridBounds()`, registered as `aura-grid-bounds` |

Nothing else reads `group.frame`'s size — the only external consumer is a
sibling group anchored to it via `anchorTo = "buffs" | "debuffs"`, which gets
*more* correct: the two boxes stop overlapping by the overflow.

---

## Schema and migration

**Neither.** No key is added and no stored value changes, so `SCHEMA_VERSION`
stays where it is. Existing profiles re-render 4px further right at the next
layout, which is the fix.

One consequence to state plainly: anyone who already compensated by hand — set
`x = 4` on a group to shove it back onto the frame — is now 4px too far right.
It is one slider back to `0`, it is not detectable from the stored value (`4` is
also a legitimate deliberate offset), and inventing a migration to guess at it
would be worse than the 4px.

---

## Tests

The suite asserts that own auras are *scaled* (`Tests/tests.lua:1810`) and that
icons land at distinct positions (`:2721`), and nothing about where the grid sits
relative to its own frame. That is the gap the bug lived in.

`testAuraGridBounds()`, on the target's buffs (fixture: one own aura, one not,
own sorts first):

* **The leftmost own icon's left edge is exactly the group frame's left edge** —
  `cellX − width/2 == 0`, read back from `button:GetPoint(1)` and `GetWidth()`.
  This is the regression assertion; it reads `−4` today.
* **The top row's own icon top edge is the box's top edge**, `growthY` both ways.
* **`growthX = "LEFT"`** puts the rightmost own icon's right edge on
  `group.frame:GetWidth()`.
* **`ownSizeMultiplier = 1`** leaves the geometry exactly as it was: box is
  `perRow × size + (perRow−1) × spacingX`, first cell centre at `0.5 × size`.
* **A base-size icon is unmoved by the change** — with `mult = 1`, cell centres
  match the pre-change formula for a 3×2 grid with non-zero spacing.
* **`ownSizeMultiplier = 0.5`** (below what the UI allows, reachable by import)
  does not pull the grid inward: `pad == 0`, first cell centre still
  `0.5 × size`.

The stub records `SetPoint` arguments and `SetSize` already (`Tests/wowstub.lua`
`__points`, `__w`), so no harness work.

---

## Risks

| Risk | Handling |
|---|---|
| **A user's careful hand-alignment shifts by 4px** | Stated above. One slider, no migration guess |
| **`pad` lands on a half pixel and blurs an icon edge** | It cannot at the edges — outer edges land on the box edge by construction, shown above. Interior cell centres were already on half pixels before this change |
| **A group anchored to another group moves** | It does, by `pad`, and in the right direction: the boxes stop overlapping by the overflow. Covered by the top/bottom-edge assertions |
| **`ownSizeMultiplier` below 1 inverts the padding** | `math.max(..., 1)`, with a test at `0.5` |
| **The real complaint was the icons overlapping each other, not the frame edge** | It is not — the request names the left overhang twice and the frame edge explicitly. The overlap is recorded under *Deferred* rather than silently folded in |

---

## Deferred

**Icons overlapping each other.** Cells are pitched at the base size, so a run of
own auras at 1.4× overlap by `size × 0.4 − spacingX` (6px at defaults). The
honest fix is to pitch cells on the *largest* size a cell can hold and let
base-size icons sit centred in a roomier cell — a wider group for the same icon
count, and a visible change for everyone. Worth doing, worth asking about first,
and not what was reported here.

---

## Estimate

| Piece | Hours |
|---|---|
| `layoutGroup` change | 0.25 |
| `testAuraGridBounds` | 0.75 |
| Verify in game | 0.25 |
| **Total** | **~1.25** |
