# Plan 28 — A Magnified Icon Stops Overlapping Its Neighbours

**Status:** Not started.
**Created:** 25 August 2026
**Branch:** `Plan-28-magnified-aura-overlap`
**Depends on:** Plan 27, which is implemented on `Plan-27-magnified-aura-growth`
and not yet on `main`. This plan edits the lines Plan 27 wrote. Merge Plan 27
first and branch from `main`; do not implement the two in parallel.

---

## Request

> another update to aura positioning: can we make it so magnified icons don't
> overlap other icons?

The screenshot shows the target frame ("Underbog Colossus", 75%, 412.6k /
553.5k) with two rows of eight debuff icons below it — the shipped target
debuff group, at `perRow = 8`, `rows = 2`, `growthX = RIGHT`, `growthY = DOWN`,
`borderMode = "type"` (`Core/Defaults.lua:656-659`), with the built-in duration
text and stack counts switched on.

Several icons are visibly wider than their neighbours, and they sit **on top of**
them. The evidence is in the text: duration numbers on the covered icons are
clipped mid-digit — `.8` and `.0` where `1.8` and `2.0` should be — and the cut
is always on the **left** edge of an icon that has a magnified icon to its left.
Two stray digits (`2`, `5`) sit below the row they belong to, on the part of a
magnified icon that hangs down into the row underneath.

Both directions of the overlap are visible at once, and both are the directions
the group grows: right and down. That is the report.

Not committed as an asset, for the same reason Plan 27's was not: the overlap is
exactly six pixels, it is derived below, and the number says it better than the
picture does.

---

## Diagnosis

Not a regression from Plan 27. This is Plan 27's own *Deferred* item, inherited
from Plan 20's, arriving as a report:

> **Cells pitched on the base size.** Unchanged and still deferred from Plan 20.
> A run of own auras overlaps by `size × (mult − 1) − spacingX`, 6px at
> defaults, and this plan does not move that number.

Plan 27 measured that overlap for own-against-own and showed it was identical
before and after its change. What it did not say — because it was not what was
reported then — is that the same arithmetic applies to **every** neighbour, not
just another own aura, and to the **vertical** axis as well as the horizontal.

`layoutGroup` pitches cells on the base size (`Elements/Auras.lua:494-508`):

```lua
cells[#cells + 1] = {
    x = padLeft + (c - 0.5) * size + (c - 1) * spacingX,
    y = -(padTop + (r - 0.5) * size + (r - 1) * spacingY),
}
```

so consecutive cell origins are `size + spacing` apart — 22px at the shipped
20px / 2px. `applyButton` then draws an own aura at `size × mult` = 28px, pinned
by the corner its grid grows from (`:580-588`). 28 into a 22 pitch:

```
overlap = size × (mult − 1) − spacing = 20 × 0.4 − 2 = 6 px
```

Six pixels of the neighbour to the right, and six pixels of the neighbour in the
row below. Worked at the target's debuff defaults, measured from the group
frame's `TOPLEFT`:

| Icon | Occupies (x) | Occupies (y) |
|---|---|---|
| Cell 1, own (28px) | `0 … 28` | `0 … −28` |
| Cell 2, base (20px) | `22 … 42` | `0 … −20` |
| Cell 9 (row 2, col 1), base | `0 … 20` | `−22 … −42` |

`28 > 22` on both axes. The magnified icon covers the left 6px of cell 2's icon
and the top 6px of cell 9's icon — which is precisely the clipped `.8` and the
stray digits in the screenshot.

Plan 27 already anticipated the visible half of this and added a frame level so
the covered icon could not clip the covering one (`:592-596`). That made the
overlap *draw* correctly. It is still an overlap.

---

## Interpretation

"Don't overlap other icons" has one honest reading — no icon's rectangle may
intersect another's — and one real consequence: **something has to get bigger or
something has to get smaller.** A 28px icon cannot sit in a 22px pitch without
covering something. The grid gains the room.

### Taken: pitch every cell on the largest icon a cell can hold

```
cellSize = size × max(mult, 1)
```

Every cell becomes 28px instead of 20px, and the pitch between cell origins
becomes `cellSize + spacing` = 30px. An own aura then exactly fills its cell, a
base aura fills the growth-origin corner of it, and the configured spacing is
what separates any two icons — whatever their sizes.

This is what Plan 27's *Deferred* section named as "the honest fix", and it has
three properties nothing else on the list has:

1. **It is static.** Cell positions still depend only on config, never on which
   auras happen to be up. Nothing shifts when a buff lands or falls off.
2. **`applyButton` gets simpler, not more complex.** Plan 27's corner-pinning
   rule is unchanged and is now the *only* placement rule; the base-half-size
   offset arithmetic disappears (see Design).
3. **Plan 20's guarantee stops needing arithmetic.** "The box bounds every icon
   it can draw" becomes a one-line proof: every icon is at most `cellSize`,
   every icon is pinned inside its own cell, and the cells tile the box exactly.

### Rejected: a packed flow, where each icon advances the cursor by its own width

Compute positions at update time from the actual list, so a row of base-size
icons stays tight and only widens where an own aura sits. Rejected on three
counts:

* **The box has to be worst-case anyway.** A group's box cannot resize with its
  contents: buttons anchor to the frame's `TOPLEFT` while the frame itself is
  anchored `BOTTOMLEFT` (buffs) or `TOPLEFT` (debuffs), so a height that changed
  with the aura list would move every icon in the group every time a buff
  landed. Worst case is all-own — which is exactly the uniform grid above. So
  the flow layout buys no space in the box; it only packs icons inside it.
* **Rows stop lining up.** Own auras sort first (`sorters.own_time`), so row one
  fills with wide icons and row two with narrow ones. Column 3 of row 1 would
  not sit above column 3 of row 2. A grid whose columns do not align reads as
  broken, and it changes shape on every aura event.
* **Ragged right edge**, for the same reason.

### Rejected: let the excess eat the spacing

`pitch = max(size + spacing, size × mult)` = 28 rather than 30 saves 14px across
eight columns. It also puts a magnified icon flush against its neighbour with a
zero-pixel gap — two bordered icons touching read as one merged block, and
"don't overlap" plainly wants a gap, not a shared edge. 14px is not worth it.

### Rejected: a new setting to switch this on

Same reasoning as Plan 27, and this time the escape hatch already exists and is
per-group: `ownSizeMultiplier = 1` gives back today's pitch exactly, because
`max(1, 1) = 1`. A second key that also decided the pitch would fight with it.

---

## The cost, stated plainly

The grid spreads out. At the target's debuff defaults:

| | Today | After |
|---|---|---|
| Cell pitch | 22 × 22 | 30 × 30 |
| Box | 182 × 50 | **238 × 58** |
| Column 8's left edge | 154 | 210 |
| Row 2's top edge | −22 | −30 |

The icon in the growth-origin corner **does not move at all** — cell 1's origin
is the box's origin on both axes, before and after. Everything else moves *away*
from it: `(c − 1) × 8` px along the row, `(r − 1) × 8` px down the column. The
box grows away from its anchor point too, so nothing moves toward the unit
frame.

Two consequences worth naming before they are discovered:

**1. The spread happens even when no own auras are on the target.** The pitch is
static, so eight debuffs none of which are yours are still laid out on a 30px
pitch. That is the price of the grid not reshuffling itself; the lever is the
multiplier.

**2. The target's debuff block becomes wider than the target frame.** 238 against
the frame's 220 (`Core/Defaults.lua:645`) — an 18px overhang past the right
edge. Today's 182 fits.

### Open decision: do the shipped target defaults change?

**Recommendation: no.** Leave `size`, `perRow` and `ownSizeMultiplier` alone and
let the user see the result first. A default change here cannot be migrated
honestly — there is no way to tell a profile that kept `perRow = 8` from one
that chose it, so a migration would clobber deliberate settings to fix a
cosmetic overhang. Three one-click levers get under 220 if the overhang is
unwanted:

| Change | Box width | Costs |
|---|---|---|
| `perRow` 8 → 7 | 208 | 7 debuffs per row instead of 8 |
| `size` 20 → 18 | 216 | Slightly smaller icons everywhere |
| `ownSizeMultiplier` 1.4 → 1.25 | 214 | Own auras less prominent |

If the answer turns out to be "yes, change a default", it is a one-line edit and
a `SCHEMA_VERSION` bump, and it should be its own plan rather than folded in
here.

---

## Design

Two functions in `Elements/Auras.lua`. Plan 27's placement rule is unchanged;
what changes is the size of the cell it pins into.

### 1. `layoutGroup` — pitch on the cell, store the corner (`:447-509`)

`padLeft`/`padTop` are deleted. Plan 20 needed padding because the excess lived
*outside* the grid; it now lives inside a cell, so there is nothing to pad.

```lua
-- Cells are pitched on the largest icon a cell can hold, not on the base size
-- (Plan 28). A scaled icon at size x mult used to overhang a pitch of
-- size + spacing by size x (mult - 1) - spacing -- six pixels at the shipped
-- 20px / 1.4x / 2px, rightward AND downward, onto whatever icon was there.
--
-- Paying for it in pitch rather than in a packed layout keeps the grid static:
-- a cell's position depends on the config and never on which auras happen to be
-- up, so nothing reshuffles when a buff lands. It also makes Plan 20's
-- guarantee structural rather than arithmetic -- every icon is at most one
-- cell, every icon is pinned inside its cell, and the cells tile the box.
--
-- math.max is not decoration: the options slider stops at 1, but an imported or
-- hand-edited profile can carry less, and a cell smaller than the base icon
-- would put the overlap back for every icon that is not the user's own.
local cellSize = size * math.max(cfg.ownSizeMultiplier or 1, 1)
local pitchX, pitchY = cellSize + spacingX, cellSize + spacingY

group.frame:SetSize(
    perRow * cellSize + (perRow - 1) * spacingX,
    rows   * cellSize + (rows   - 1) * spacingY)

-- ... unchanged anchoring and SetShown ...

-- Plan 27: an icon is pinned by the corner its grid grows FROM and expands
-- toward the corner it grows TO. The corner is a property of the group, so it
-- is derived once here rather than per button, and the cell stores that corner
-- directly instead of its centre -- nothing is centred in a cell any more.
group.anchorPoint = ((cfg.growthY == "DOWN") and "TOP" or "BOTTOM")
    .. ((cfg.growthX == "LEFT") and "RIGHT" or "LEFT")

local fromLeft = (cfg.growthX ~= "LEFT")
local fromTop  = (cfg.growthY == "DOWN")

for row = 1, rows do
    for col = 1, perRow do
        local c = (cfg.growthX == "LEFT") and (perRow + 1 - col) or col
        local r = (cfg.growthY == "UP") and (rows + 1 - row) or row
        local left = (c - 1) * pitchX
        local top  = -((r - 1) * pitchY)
        cells[#cells + 1] = {
            x = fromLeft and left or (left + cellSize),
            y = fromTop  and top  or (top - cellSize),
        }
    end
end
```

The `c`/`r` reversal is untouched — cell 1 is still the growth-origin cell, so
the fill order and everything that indexes `cells` keeps working.

### 2. `applyButton` — anchor the stored corner (`:562-596`)

Plan 27's `vert` / `horiz` / `half` locals go away. The cell already holds the
point to pin, and the group already holds which point it is:

```lua
button:SetSize(buttonSize, buttonSize)
button:ClearAllPoints()
button:SetPoint(group.anchorPoint or "BOTTOMLEFT", group.frame, "TOPLEFT",
    cell.x, cell.y)
```

The `or "BOTTOMLEFT"` is belt-and-braces only: `updateGroup` caps the loop at
`#cells` (`:679-684`), so no button is ever applied before `layoutGroup` has run
and set both.

`cell.x`/`cell.y` change meaning, from the cell's **centre** to the cell's
**growth-origin corner**. Two places read a cell — this function and
`cellEdges()` in the test — and both are in the Files table below. `GetPoint` on
a laid-out button is unaffected: it returns whatever `SetPoint` was given.

### 3. `applyButton` — the frame level stays, its justification changes

```lua
-- Own auras no longer overhang anything at any setting the options panel can
-- produce (Plan 28 pitches the cell to fit them), but spacing can arrive
-- negative from an imported profile, and then icons do overlap. When they do,
-- the scaled one is the one that should be legible. One line, kept.
local level = group.frame:GetFrameLevel()
button:SetFrameLevel(level + (entry.own and 2 or 1))
```

### Worked example, at the target's debuff defaults

`size = 20`, `mult = 1.4`, `perRow = 8`, `rows = 2`, `spacing = 2, 2`,
`growthX = RIGHT`, `growthY = DOWN`. So `cellSize = 28`, `pitch = 30, 30`,
`anchorPoint = TOPLEFT`, box = `238 × 58`.

| Icon | Cell corner | Occupies (x) | Occupies (y) |
|---|---|---|---|
| Cell 1, own | `(0, 0)` | `0 … 28` | `0 … −28` |
| Cell 2, base | `(30, 0)` | `30 … 50` | `0 … −20` |
| Cell 8, own | `(210, 0)` | `210 … 238` | `0 … −28` |
| Cell 9 (row 2, col 1), own | `(0, −30)` | `0 … 28` | `−30 … −58` |

The gap between cell 1's own icon and cell 2 is `30 − 28 = 2` — the configured
`spacingX`, exactly. Vertically, `−28` to `−30` is `spacingY`, exactly. Cell 8's
own icon ends on `238`, the box's right edge, and cell 9's on `−58`, its bottom.
No pair of icons intersects, at any mix of sizes.

### What is deliberately not changed

* **Text anchored `ABOVE` / `BELOW`** still draws outside its icon and can land
  on a neighbour or outside the box (`placeAuraText:541-559`). Pre-existing,
  independent of icon size, and not what was reported.
* **No default moves.** See the open decision above.
* **Sorting, filtering, `maxShown`, the button pool.** Untouched.

---

## Files

| File | Change |
|---|---|
| `Elements/Auras.lua` | `layoutGroup` (`:447-509`): `cellSize`/`pitchX`/`pitchY` replace `excess`/`padLeft`/`padTop`; box sized on the cell; cells store the growth-origin corner; `group.anchorPoint` recorded |
| `Elements/Auras.lua` | `applyButton` (`:562-596`): pin `group.anchorPoint` at `cell.x, cell.y`; delete the `vert`/`horiz`/`half` arithmetic; rewrite the frame-level comment |
| `Tests/tests.lua` | `testAuraGridBounds` (`:2388`): `cellEdges()` reworked onto the corner convention; box, cell-fill and neighbour assertions updated; new gap assertions on both axes |
| `Documents/SPEC.md` | FR-5.3 (`:291`): cells are pitched on the largest icon a cell can hold, not on the base size |

`Documents/COMPAT_FINDINGS.md` needs no entry. FR-5.3 is being amended, not
broken — the sentence Plan 27 wrote there ("Cells are pitched on the *base* size
so rows stay aligned") is the thing this plan changes, and rows still stay
aligned.

---

## Schema and migration

**Neither.** No key is added and no stored value changes, so `SCHEMA_VERSION`
stays at 17 (`Core/Defaults.lua:33`). Existing profiles re-render at the next
layout, which is the fix.

Nothing to strand: nobody can have hand-compensated for the overlap, because the
only controls that touch it (`size`, `spacingX`, `spacingY`,
`ownSizeMultiplier`) move base and magnified icons together.

---

## Tests

`testAuraGridBounds` (`Tests/tests.lua:2388`, registered `aura-grid-bounds` at
`:6383`) again. It has the fixture, it knows button 1 is the scaled own aura and
button 2 the base-size neighbour, and Plan 27 already gave it a general
`edges(button)` helper that reads the anchor point back rather than assuming it.

**Rework `cellEdges(i)` first.** It currently derives a cell's edges as
`cell.x ± size / 2` (`:2448-2456`), which assumes both the centre convention and
the base-size pitch — wrong on both counts after this change:

```lua
local function cellEdges(i)
    local group = target.elements.auras.buffs
    local cell = group.cells[i]
    local cellSize = cfg.size * math.max(cfg.ownSizeMultiplier or 1, 1)
    local point = group.anchorPoint
    local left = point:find("LEFT") and cell.x or (cell.x - cellSize)
    local top  = point:find("TOP")  and cell.y or (cell.y + cellSize)
    return { left = left, right = left + cellSize,
             top = top, bottom = top - cellSize }
end
```

### The new assertions — the report, as numbers

At the fixture's `size 20 / perRow 8 / rows 2 / spacing 2,2 / mult 1.4 /
RIGHT,UP`, so `cellSize = 28`, `pitch = 30`, `anchorPoint = BOTTOMLEFT`:

* **The gap from the own icon to the next cell along the row is `spacingX`** —
  `cellEdges(2).left - ownIcon().right == 2`. Reads **−6** today. This is the
  horizontal half of the report.
* **The gap from the own icon to the cell in the row above is `spacingY`** —
  `ownIcon().top` against `cellEdges(perRow + 1).bottom`, difference `2`. Cell 9
  is directly above cell 1 (row 1 fills cells 1–8). Also reads **−6** today.
  This half has never been asserted at all.
* **The own icon exactly fills its cell** on all four edges — the positive form
  of both gaps, and what makes `cellSize` the right name for the quantity.
* **The base-size neighbour is pinned at its cell's origin corner and is `size`
  across** — `base.left == cell2.left`, `base.bottom == cell2.bottom`,
  `base.right == cell2.left + cfg.size`, `base.top == cell2.bottom + cfg.size`.
* **The last cell's far edge is the box's far edge** — `cellEdges(8).right ==
  boxW` — so the cells tile the box and the containment argument holds by
  construction rather than by luck.

### Assertions that change and must be rewritten, not deleted

| Assertion | Was | Becomes |
|---|---|---|
| `the box still allows for the whole excess, once` | `boxW == excess + 8×20 + 7×2` = 182 | `boxW == 8×28 + 7×2` = 238 |
| `and the same vertically` | `boxH == excess + 2×20 + 1×2` = 50 | `boxH == 2×28 + 1×2` = 58 |
| `it grows right by the whole excess` | `icon.right == cell.right + excess` | `icon.right == cell.right` |
| `and up by the whole excess` | `icon.top == cell.top + excess` | `icon.top == cell.top` |
| `growing down, it grows down by the whole excess` | `icon.bottom == cell.bottom - excess` | `icon.bottom == cell.bottom` |
| `growing left, it grows left by the whole excess` | `icon.left == cell.left - excess` | `icon.left == cell.left` |
| `an unscaled neighbour still fills its cell exactly` (+ 3 siblings) | base icon fills cell 2 on all four edges | base icon fills the origin `size × size` of a `cellSize` cell — see above |

The last row is the one to be careful with. It is Plan 27's proof that
corner-pinning is a no-op for an unscaled icon, and that proof is still wanted —
but a base-size icon no longer *fills* the cell, so the assertion has to move
from "same rectangle" to "same corner, base size". Deleting it would drop the
guard.

### Assertions that must pass untouched — the control

* All four Plan 20 outer-edge checks (`icon.left == 0`, `icon.bottom == -boxH`,
  and the two mirrors). If any moves, the corner or the pitch is wrong.
* `scaled and base icons share the row's baseline` — Plan 27's fix, and the
  thing most at risk from a botched `cellEdges()` rewrite.
* The entire `mult = 1` block (`:2565-2575`). `max(1, 1) = 1` means `cellSize ==
  size` and the grid is *identical* to today's, number for number. This is the
  strongest control in the suite: if anything in that block moves, the change
  has leaked into grids that do not magnify anything.
* The `mult = 0.5` block (`:2577-2591`). `max(0.5, 1) = 1`, so same again.
* `a scaled icon draws above the icon it overhangs` — the behaviour stays even
  though its justification narrows.

### Control run

Worth repeating what Plan 27 did, because it is what turned that plan's argument
into a measurement: stash the `Elements/Auras.lua` change and run the new
assertions against the code being replaced. The two gap assertions must fail at
**−6** on both axes, and the `mult = 1` block must pass in both directions.

```bash
python Tests/run_tests.py
```

---

## Risks

| Risk | Handling |
|---|---|
| **The grid visibly spreads, even with no own auras present** | Real, unavoidable for a static grid, and quantified above: `(c − 1) × 8` px along the row at defaults. The growth-origin icon does not move and nothing moves toward the frame. The lever is `ownSizeMultiplier = 1`, which restores today's pitch exactly |
| **The target's debuff block outgrows the 220px frame** (238) | Named as an open decision with three one-click levers and a recommendation not to move defaults. Cosmetic, not a defect, and a migration that fixed it would clobber deliberate `perRow` choices |
| **`ownSizeMultiplier` goes to 3 on the slider** — box would be 494 at `perRow = 8` | Inherent to non-overlap, not to this design: at 3× today the icons are 60px on a 22px pitch and each one covers two neighbours outright, so that setting has never been usable. It becomes usable and wide instead of unusable and narrow |
| **A sibling group anchored to this one moves** (`anchorTo = "buffs" \| "debuffs"`) | It does, by the box delta, and away from the frame. Same class of movement Plan 20 accepted when it grew the box; no unit ships with a sibling anchor, so this only reaches hand-configured profiles |
| **`cell.x`/`cell.y` change meaning and a third reader is missed** | `grep -n "\.cells\|cell\.x\|cell\.y"` over `Elements/` and `Tests/` before starting. Today the readers are `applyButton` and `cellEdges()` and nothing else — the cells table is built and consumed inside one file |
| **`cellEdges()` is rewritten wrongly and the suite lies** | The `mult = 1` and `mult = 0.5` blocks are the control: `cellSize == size` there, so every number in them must be unchanged. If they move, the helper is wrong, not the code |
| **`group.anchorPoint` is read before `layoutGroup` sets it** | Cannot happen — `updateGroup` caps its loop at `#cells`, which is zero until `layoutGroup` runs. The `or "BOTTOMLEFT"` fallback is there anyway |

---

## Deferred

**Text anchored `ABOVE` or `BELOW` still escapes its icon.** Those two
placements deliberately sit outside the art (`placeAuraText:541-559`), so a
duration string can still land on a neighbour's icon or past the box edge. It is
independent of magnification — a grid of base-size icons does it too — and
fixing it means either clamping the text into the cell or padding the box for
the font's height. Its own request if it is ever one.

---

## Estimate

| Piece | Hours |
|---|---|
| `layoutGroup` + `applyButton` | 0.5 |
| `cellEdges()` rework, changed assertions, new gap assertions | 1.0 |
| Control run against the old code | 0.25 |
| SPEC line | 0.1 |
| Verify in game | 0.25 |
| **Total** | **~2** |
