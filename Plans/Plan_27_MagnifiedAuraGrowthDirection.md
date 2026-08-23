# Plan 27 — Magnified Own Auras Grow In One Direction, Not Four

**Status:** Not started.
**Created:** 23 August 2026
**Branch:** `Plan-27-magnified-aura-growth`

---

## Request

> right now, when auras are enabled on a frame and the user has selected to
> magnify their own buffs, these magnified buffs grow outward in all directions.
> this leads to awkward overhangs past and overtop of the bar they're anchored
> to. See the screenshot attached for an example. It would be better if these
> icons only grew in one vertical direction and one horizontal direction, with a
> corner anchored to the corner of the bar it's growing from. For example, an
> aura anchored to the top left of the player frame should grow to the right and
> upwards, an aura anchored to the bottom left corner of the target frame should
> grow down and to the left, and so on. this should be the default behavior.

The screenshot shows a single row of six buffs above a unit frame, with the
health bar ("Dyrawr", 93%) directly below. Five icons are base size and carry
built-in duration text (`4m 5m 25m 4m 4m`); the sixth, on the right, is one of
the player's own and is visibly larger. It breaks the row on **both** edges — its
top rises above the other icons' tops and its bottom drops below their bottoms,
into the gap between the row and the bar. That two-sided break is the whole
report.

Not committed as an asset. The geometry is exact and derived below, and a number
says it better than a picture does.

---

## Diagnosis

Not a bug — a deliberate choice whose cost has now been named.

`applyButton` (`Elements/Auras.lua:553-560`) sizes an own aura up and then
anchors it by its **centre** to the cell's centre:

```lua
local buttonSize = entry.own and size * (cfg.ownSizeMultiplier or 1) or size
button:SetSize(buttonSize, buttonSize)
button:SetPoint("CENTER", group.frame, "TOPLEFT", cell.x, cell.y)
```

Cells are pitched on the **base** size (`layoutGroup:487-497`), so the excess
`size × (mult − 1)` is split evenly across all four sides:

```
half-excess = 20 × (1.4 − 1) / 2 = 4 px, top, bottom, left and right
```

Four pixels up, four down. The four *up* are free — nothing is there. The four
*down* are spent growing back toward the thing the group is anchored to, which
is the bar. That is the "overhangs past and overtop of the bar" in the request,
and it is also why the row reads as ragged: the magnified icon shares neither
its top edge nor its bottom edge with its neighbours.

### What Plan 20 already fixed, and what it left

Plan 20 (merged, `9d873fa`) added `pad = half-excess` to the group box on all
four sides and started the cells one `pad` in (`layoutGroup:467-495`). That
stopped the icons escaping *the box*, so the group no longer overhangs the unit
frame. It explicitly did not touch how an icon sits inside its own cell — its
*Deferred* section says so.

So on a synced client the magnified icon no longer reaches the bar itself; it
reaches the bottom edge of the aura box, which is parked `y` pixels off the bar.
The two-sided break in the row is untouched, and that is what the screenshot
shows. This plan is the other half of Plan 20, not a correction to it.

---

## Interpretation

"Only grew in one vertical direction and one horizontal direction, with a corner
anchored" is unambiguous about the *shape* of the fix: pin one corner of the
icon to the corresponding corner of its cell and let it expand away from that
corner only. The question is **which corner**, and there are two candidate
sources for it in the config.

### Reading A — the group's growth axes. **Taken.**

Every aura group already carries `growthX` (`RIGHT | LEFT`) and `growthY`
(`UP | DOWN`) — `Core/Defaults.lua:163-164`, exposed as *Grow horizontally* and
*Grow vertically* (`Config/Options_Auras.lua:136-147`). They already mean
exactly "which way does this grid grow as auras are added". Magnification is
more growth, so it grows the same way: pin the corner the grid grows **from**,
expand toward the corner it grows **to**.

Check it against the shipped defaults, which is the only honest test:

| Group | Anchoring | Growth | Magnified icon grows |
|---|---|---|---|
| Buffs (`auraGroup` default) | `BOTTOMLEFT → TOPLEFT`, above the frame | `RIGHT`, `UP` | up and right |
| Target debuffs | `TOPLEFT → BOTTOMLEFT`, below the frame | `RIGHT`, `DOWN` | down and right |

The first row *is* the request's first example, verbatim: an aura group anchored
to the top left of the frame grows "to the right and upwards". The vertical in
the second row is the request's second example too — a group at the bottom left
grows "down".

The horizontal in the second example is the one thing this reading does not
reproduce: the request says the target's bottom-left auras should grow *left*,
and `growthX` ships as `RIGHT` on every group. Two ways that reconciles, and
both land in the same place:

* the profile that produced the screenshot has `growthX = LEFT` on that group —
  a mirrored target layout is a normal thing to configure, and under this
  reading it grows left automatically; or
* it was a loose sketch, closed with "and so on".

Either way the setting that decides it already exists and is already the right
one. Nothing in the request asks for a *new* control over the direction, and
"grow left" is one dropdown away for any group that wants it.

### Reading B — the group's anchor point (`cfg.point`). **Rejected.**

Pin whichever corner of the icon matches the corner of the box that is anchored
to the widget. At the shipped defaults this is indistinguishable from reading A —
`BOTTOMLEFT` gives up-and-right, `TOPLEFT` gives down-and-right, the same two
rows as the table above.

It is rejected because it is **undefined for five of its nine legal values**.
`point` comes from `ns.Anchoring:PointValues()` (`Systems/Anchoring.lua:30-36`) —
`CENTER`, `TOP`, `BOTTOM`, `LEFT` and `RIGHT` name no corner, and a group
anchored `CENTER` would need an invented fallback. `growthX`/`growthY` name
exactly one direction each, always, so reading A has no undefined case and needs
no fallback. Where the two readings disagree — a group with `point = BOTTOMRIGHT`
but `growthX = RIGHT` — reading A is also the better answer, because it keeps
magnification pointing the same way the grid itself fills.

### "This should be the default behavior"

Taken as **unconditional, with no new key**. Two reasons:

1. The control the request implies already exists and is per-group:
   `growthX`/`growthY`. Adding a second knob that also decides direction would
   make two settings fight over one behaviour.
2. Nothing asks for the old centred behaviour to remain reachable. It is being
   reported as a defect, not as a preference.

If a legacy escape hatch is ever wanted it is one boolean and one branch in
`applyButton`, added later at no cost. It is not worth a schema key today.

---

## Design

Two functions in `Elements/Auras.lua`, and a frame-level line that the change
makes necessary.

### 1. `layoutGroup` — put the padding on the growth side (`:467-497`)

Plan 20's `pad` splits the excess evenly because the icon does. Once the icon
only grows one way per axis, the padding follows it:

```lua
-- Plan 20 padded all four sides by half the excess, because a centred icon
-- overflowed all four. It only overflows toward the growth direction now
-- (Plan 27), so the whole excess goes on that side and the origin side sits
-- flush -- which is what puts the row's baseline on the box edge nearest the
-- bar instead of half the excess away from it.
local excess = size * math.max((cfg.ownSizeMultiplier or 1) - 1, 0)

local padLeft = (cfg.growthX == "LEFT") and excess or 0
local padTop  = (cfg.growthY == "UP")   and excess or 0

group.frame:SetSize(
    excess + perRow * size + (perRow - 1) * spacingX,
    excess + rows   * size + (rows   - 1) * spacingY)

-- ... unchanged anchoring ...

cells[#cells + 1] = {
    x = padLeft + (c - 0.5) * size + (c - 1) * spacingX,
    y = -(padTop + (r - 0.5) * size + (r - 1) * spacingY),
}
```

`math.max(x - 1, 0)` carries the same load `math.max(x, 1)` did in Plan 20: the
slider stops at 1 (`Config/Options_Auras.lua:176-181`) but an imported profile
can carry less, and a negative excess would pull the grid inward.

**The box's total size does not change.** Plan 20's box was `2 × pad + grid`,
and `2 × pad = excess` by definition, so this is the same width and the same
height — only the distribution moves, from both sides to one. That matters
because a sibling group can anchor to this one (`anchorTo = "buffs" |
"debuffs"`, `groupAnchorWidget`), and it means no sibling moves.

`cell.x`/`cell.y` keep their meaning — the cell **centre** — so nothing that
reads a cell has to learn a new convention.

### 2. `applyButton` — anchor the growth-origin corner (`:553-560`)

```lua
-- FR-5.3 scales own auras up. Grow them along the group's own growth axes:
-- pin the corner of the cell the grid grows FROM and expand toward the corner
-- it grows TO, so a scaled icon never crosses the baseline its row sits on.
-- Anchoring CENTER -- what this did before -- spent half the excess growing
-- back toward whatever the group is anchored to, which is the bar (Plan 27).
local vert  = (cfg.growthY == "DOWN") and "TOP"   or "BOTTOM"
local horiz = (cfg.growthX == "LEFT") and "RIGHT" or "LEFT"
local half  = size / 2

button:SetSize(buttonSize, buttonSize)
button:ClearAllPoints()
button:SetPoint(vert .. horiz, group.frame, "TOPLEFT",
    cell.x + ((horiz == "LEFT")   and -half or half),
    cell.y + ((vert  == "BOTTOM") and -half or half))
```

`half` is the **base** half-size, not the button's: the offsets walk from the
cell centre to the cell corner, which is where the icon is pinned regardless of
how big the icon is. That is the whole trick, and it is why a base-size icon is
completely unmoved by this change — pinning its corner to the cell corner and
centring it on the cell centre are the same placement when they are the same
size.

### 3. `applyButton` — lift own icons one frame level

```lua
-- A magnified icon now overhangs ONE neighbour by the full excess instead of
-- two by half each, and sibling frames at equal level draw in creation order,
-- so the next button along would clip the overhang. Own auras sort first, so
-- "the next button along" is exactly the base-size icon it grows over.
local base = group.frame:GetFrameLevel()
button:SetFrameLevel(base + (entry.own and 2 or 1))
```

Nothing else in the file sets a button frame level any more — Plan 26's merge
removed the secure cancel overlay that used to read one (`GetFrameLevel` appears
nowhere in the current file), so this introduces no interaction.

### Worked example, at the shipped defaults

`size = 20`, `mult = 1.4`, `perRow = 8`, `rows = 2`, `spacing = 2, 2`,
`growthX = RIGHT`, `growthY = UP`. So `excess = 8`, `padLeft = 0`, `padTop = 8`,
box = `182 × 50` — the same 182 × 50 the box is today.

| Icon | Cell centre | Pinned `BOTTOMLEFT` | Occupies (x) | Occupies (y) |
|---|---|---|---|---|
| Bottom row, col 1, base | `(10, −40)` | `(0, −50)` | `0 … 20` | `−50 … −30` |
| Bottom row, col 1, own | `(10, −40)` | `(0, −50)` | `0 … 28` | `−50 … −22` |
| Bottom row, col 8, own | `(164, −40)` | `(154, −50)` | `154 … 182` | `−50 … −22` |
| Top row, col 1, own | `(10, −18)` | `(0, −28)` | `0 … 28` | `−28 … 0` |

Every icon, scaled or not, sits on `y = −50` in the bottom row — one baseline,
flush with the box's bottom edge, which is the edge nearest the bar. The outer
edges land exactly on the box edges (`182`, `0`) by construction, so the box
still bounds everything it draws and Plan 20's guarantee is preserved rather
than re-derived.

### What the user sees change

At defaults, the magnified icon's bottom edge does not move at all — it was
already on the box's bottom edge. The **base-size** icons drop 4px to join it,
and the magnified icon's top rises 4px. Net effect: nothing gets closer to the
bar than something already was, the row gains a shared baseline, and the ragged
two-sided break in the screenshot is gone.

### What is deliberately not changed

* **Cells stay pitched on the base size.** A run of own auras still overlaps by
  `size × (mult − 1) − spacingX` — 6px at defaults. Identical to today for
  own-against-own (the arithmetic is in *Deferred*), inherited from Plan 20's
  deferred item, and not what was reported.
* **No default moves.** `x`, `y`, `size`, `ownSizeMultiplier`, `growthX`,
  `growthY` are all untouched.

---

## Files

| File | Change |
|---|---|
| `Elements/Auras.lua` | `layoutGroup` (`:447-500`): `excess` replaces `pad`, applied to one side per axis by growth direction |
| `Elements/Auras.lua` | `applyButton` (`:553-560`): anchor the growth-origin corner instead of `CENTER`; lift own icons one frame level |
| `Tests/tests.lua` | `testAuraGridBounds` (`:2378`): `ownIcon()` must read the anchor point; new interior-of-cell assertions |
| `Documents/SPEC.md` | FR-5.3 (`:291-294`): one line recording that the scaled icon grows along the group's growth axes |

`Documents/COMPAT_FINDINGS.md` needs no entry — no SPEC rule is being broken.
FR-5.2 and FR-5.3 specify that own auras are scaled and by how much, and say
nothing about where the scaled icon sits in its cell; this fills that silence
rather than contradicting it.

---

## Schema and migration

**Neither.** No key is added and no stored value changes, so `SCHEMA_VERSION`
stays at 17 (`Core/Defaults.lua:33`). Existing profiles re-render at the next
layout, which is the fix.

Unlike Plan 20 there is no hand-compensation to strand: nobody can have offset
their way out of this one, because it was symmetric.

---

## Tests

`testAuraGridBounds` (`Tests/tests.lua:2378`, registered `aura-grid-bounds` at
`:6259`) is the right home — it already builds the fixture, already knows button
one is the scaled own aura, and already measures against the group frame.

**Its helper has to change first.** `ownIcon()` computes edges as
`left = x - w/2` (`:2399-2405`), which assumes centre anchoring and would report
nonsense the moment the button is pinned by a corner. It drops the point name
from `GetPoint(1)` today; it must keep it and derive the edges from it. Getting
this wrong makes the whole suite lie in either direction, so it is worth writing
carefully.

The four existing box-edge assertions must **still pass unchanged** — that is
the Plan 20 regression guard, and this plan is required not to break it. Verified
by hand in the worked example above; if any of them moves, the padding split is
wrong.

New assertions, all in the `growthX = RIGHT, growthY = UP` default unless noted:

* **The own icon's bottom edge equals the base-size icon's bottom edge.** One
  baseline. This is the report, stated as a number, and it reads a 4px
  difference today.
* **The own icon's top edge is `size × (mult − 1)` above its cell's top** —
  it grew up, by the whole excess, not half of it.
* **The own icon's left edge is its cell's left edge**, i.e. it did not grow
  left at all.
* **`growthY = DOWN`**: the own icon's *top* edge equals the base icon's top
  edge, and it grew down. The mirror, and the case that protects the target's
  debuffs.
* **`growthX = LEFT`**: the own icon's *right* edge equals its cell's right
  edge and it grew left.
* **The box is the same size as before the change** — `excess + grid` on both
  axes, at `mult = 1.4` and at `mult = 1`. This is what protects a sibling group
  anchored to this one.
* **A base-size icon lands in exactly the same place as before**, at `mult = 1`
  and at `mult = 1.4`, for a 3×2 grid with non-zero spacing. Corner-pinning must
  be a no-op for anything that is not scaled.
* **Own icons draw above base ones** — `buttons[1]:GetFrameLevel() >
  buttons[2]:GetFrameLevel()` with the fixture's own-first sort.

One existing assertion **changes meaning and must be rewritten**, not deleted:

```
aurabounds/nor pull the grid inward   ->  expects left == (20 - 10) / 2 == 5
```

At `ownSizeMultiplier = 0.5` a shrunk icon was centred in its cell, 5px in.
Corner-pinned it sits at the cell's origin corner, `left == 0`, on the same
baseline as its full-size neighbours. That is the consistent answer — one rule,
one code path, and a shrunk icon that still sits on the row's baseline rather
than floating in the middle of a cell — but it is a real behaviour change for
sub-1 multipliers and the assertion should say so in its name.

The stub records `SetPoint` arguments and `SetSize` (`Tests/wowstub.lua`
`__points`, `__w`); confirm it records frame levels before writing the z-order
assertion, and add it if not.

```bash
python Tests/run_tests.py
```

---

## Risks

| Risk | Handling |
|---|---|
| **The base-size icons visibly move 4px** toward the bar at defaults | They do, and that is the fix — they are joining the baseline the magnified icon was already on. Nothing ends up closer to the bar than something already was; shown in the worked example |
| **A magnified icon now covers 6px of one neighbour instead of 2px of each** | Inherent to growing one way, which is what was asked for. Handled where it is visible: own icons get a frame level so the neighbour cannot clip them. Own-against-own overlap is arithmetically unchanged |
| **`ownIcon()` in the test is updated wrongly and the suite lies** | Called out above as the first thing to write. The four Plan 20 assertions are the control: they are hand-verified to still pass, so if they move after the helper change, the helper is wrong, not the code |
| **A group with `growthX`/`growthY` set against its anchor direction now grows into the frame** | It already did, in both directions, and now does it in one. Reading B was considered and rejected for a separate reason; the dropdown fixes it in one click. Worth a sentence in the option's description if it comes up |
| **Sub-1 multipliers change placement** | Stated, tested, and the consistent answer. Below what the UI allows in any case |
| **The frame-level line collides with something** | Nothing else in the file sets one — `GetFrameLevel` appears nowhere in the current `Elements/Auras.lua`. Plan 26's merge removed the secure overlay that used to |

---

## Deferred

**Cells pitched on the base size.** Unchanged and still deferred from Plan 20.
A run of own auras overlaps by `size × (mult − 1) − spacingX`, 6px at defaults,
and this plan does not move that number:

```
centred:  right edge (c + 14) vs next left edge (c + 22 − 14) = 6px
cornered: right edge (L + 28) vs next left edge (L + 22)      = 6px
```

The honest fix is still to pitch cells on the largest size a cell can hold. It
widens every group for the same icon count and is a visible change for everyone,
so it stays a question to ask rather than a thing to fold in.

---

## Estimate

| Piece | Hours |
|---|---|
| `layoutGroup` + `applyButton` | 0.5 |
| `ownIcon()` rework and new assertions | 1.0 |
| SPEC line | 0.1 |
| Verify in game | 0.25 |
| **Total** | **~1.75** |
