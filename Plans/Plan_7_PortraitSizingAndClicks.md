# Plan 7 — Portrait Sizing and Clicks

**Status:** Not started
**Created:** 2 August 2026
**Branch:** `first`

---

## Request

> I want the portrait to also be click-targetable. additionally, the portrait
> should be attached to the health and power bar with no gap, and its height
> should always be equal to the combined heights of the health bar and power
> bar/

---

## Interpretation

Three things, and the first falls out of the other two for free if the design is
right.

The portrait is currently a `detached` slab beside the frame with its own fixed
`width` and `height`, separated by a 4px gap and sized independently of
anything. The request describes it as **a column of the frame** rather than an
ornament next to it: flush against the bars, exactly as tall as they are, and
part of the clickable frame.

That is a third placement mode, not a tweak to the existing two.

---

## The placement model is wrong and should be replaced

Today: `placement = "inside" | "outside"` (renamed in the UI to "over the frame"
/ "beside the frame"). Neither is what was asked for.

- `inside` draws the portrait **behind the bars**, where an opaque flat fill
  hides it. Already known to be a poor default; changed away from in `ab7f37d`.
- `outside` draws it **beyond the frame's bounds**, so it is not inside the
  secure button and cannot be clicked.

Proposed three modes:

| Mode | Meaning | Clickable |
|---|---|---|
| `column` | A column **within** the frame, beside the bars. Bars inset to make room. **New default.** | Yes, free |
| `overlay` | Behind the bars. Today's `inside`. | Yes, already |
| `detached` | Outside the frame entirely. Today's `outside`. | Only with the hit-rect trick below |

---

## Why `column` gets click-targeting for free

`Units/Factory.lua` creates each frame as a `SecureUnitButtonTemplate` button
with `type1 = "target"`. **The button handles clicks over its whole rect.**
Textures are not mouse-enabled, so a portrait texture inside that rect does not
intercept anything — the click lands on the button and targets the unit.

A `PlayerModel` for 3D mode likewise has `EnableMouse` false by default, so it
also passes clicks through. Worth asserting rather than assuming: if a model
frame does swallow clicks on these clients, `model:EnableMouse(false)` fixes it.

So no second secure button, no attribute duplication, no combat-lockdown
problem. The whole feature is "put the portrait inside the button and inset the
bars".

### Making `detached` clickable too

For anyone who keeps the portrait outside the frame, the click area can be
extended past the frame's bounds:

```lua
frame:SetHitRectInsets(-portraitWidth, 0, 0, 0)   -- negative grows the rect
```

Route it through `CombatQueue` with the other protected geometry calls — it is a
frame-geometry method on a protected frame and should not be trusted to be free
in combat. Reset to `0, 0, 0, 0` when the mode changes.

This is a nice-to-have. `column` is the answer to the request; the hit-rect
trick just stops `detached` being a dead end.

---

## Sizing: height tracks the bar stack

`Units/Factory.lua` → `LayoutBars` already computes everything needed:

```lua
healthHeight      -- health bar
powerSlot         -- power height + spacing, or 0 when disabled
manaSlot          -- reserve mode only
```

The request says "health bar and power bar", so:

```
portraitHeight = healthHeight + powerSlot
```

Deliberately **excluding** the shapeshift mana bar in `append` mode — that bar
hangs below the frame's own bounds, and a portrait growing and shrinking every
time a druid shifts form would be exactly the layout jump §FR-2.3 exists to
avoid. In `reserve` mode the mana slot is inside the frame, so it should be
included; that keeps the portrait flush with the full bar stack in the one mode
where the stack has a fixed height.

Add `matchBarHeight` (default true). When false, the existing `height` slider
applies, so anyone who wants a square portrait taller than the bars can have one.

Width stays the `width` slider. A `square` toggle (width follows height) is worth
offering since a square portrait is the common want, but it should not be forced.

## No gap

`x` defaults to `0` and the portrait's inner edge is anchored directly to the
bars' outer edge. The bars already tile with no gap after `c7e8a58`; this makes
the portrait part of the same block. The `x` slider stays, so a gap is available
to anyone who wants one.

---

## Bar inset — the one non-trivial change

`LayoutBars` currently starts every bar at x = 0 and spans the full width:

```lua
ns.elements.health.SetGeometry(self, elements.health, 0, y, width, healthHeight)
```

With a `column` portrait it needs an inset, mirroring how `mana.SlotHeight`
already reserves vertical space:

```lua
local inset = ns.elements.portrait.SlotWidth(self, cfg.portrait)   -- new
local barX     = (side == "LEFT") and inset or 0
local barWidth = width - inset
```

`SlotWidth` returns `0` unless the mode is `column` and the portrait is enabled,
so every other configuration is untouched.

This is the same pattern as the mana bar's vertical slot, which keeps one idea
of "an element reserving space in the frame" rather than inventing a second.

**Ordering:** `Elements/Portrait.lua` registers at `order = 5`, before the bars,
so its config is read before `LayoutBars` runs. `SlotWidth` is a pure function of
config, so ordering does not actually matter — but it is worth noting so nobody
later reorders elements and breaks it silently.

---

## Files

| File | Change |
|---|---|
| `Elements/Portrait.lua` | `column` mode, `SlotWidth`, height from the bar stack, `matchBarHeight`, mouse-through assertion |
| `Units/Factory.lua` | Bar inset in `LayoutBars`; hit-rect insets for `detached` |
| `Core/Defaults.lua` | Placement values renamed, `column` default, `matchBarHeight`; schema bump |
| `Core/Migrate.lua` | Rename `inside`→`overlay`, `outside`→`detached`; move the default to `column` |
| `Config/Options_Layout.lua` | Three-way placement select, `matchBarHeight`, height slider disabled when it is on |
| `Tests/tests.lua` | New assertions |

---

## Migration

Two things at once, so care is needed.

1. **Value rename.** `inside` → `overlay`, `outside` → `detached`. Unconditional
   — these are internal identifiers, not user choices, and leaving a profile on
   an unknown value would silently fall through to the default.
2. **Default move.** Only where the value is still the old default. `outside`
   became the default in `ab7f37d`, so after step 1 a profile on `detached` is
   ambiguous: it might be that default, or a deliberate choice made since.

The distinguishing signal: the schema version the profile is *arriving from*. A
profile at schema ≤ 7 predates any chance to deliberately choose, so `detached`
there is the inherited default and moves to `column`. Later profiles are left
alone.

Worth stating plainly because it is the first migration in this project where
that distinction is actually recoverable — the cosmetic ones (schemas 2–6) had
no way to tell and said so.

---

## Tests

- `column` is the shipped default.
- With a `column` portrait, health and power bars start at `x = portraitWidth`
  and are `frameWidth - portraitWidth` wide.
- Portrait height equals health + power slot; changing the power bar's height
  changes it; disabling the power bar shrinks it to the health height.
- `append`-mode mana does **not** change the portrait height; `reserve` mode
  does.
- `matchBarHeight = false` restores the manual height slider.
- `overlay` and `detached` leave the bars at full width (`SlotWidth` returns 0).
- `detached` sets negative hit-rect insets; changing away resets them to 0.
- The portrait region is inside the button's rect in `column` mode — assert
  geometry, since the harness cannot generate a real click.
- Migration: `inside`→`overlay`, `outside`→`detached`, and a schema-7 profile's
  `detached` becomes `column` while a later one does not.

---

## Risks

| Risk | Handling |
|---|---|
| A `PlayerModel` intercepts clicks in `column` mode | `EnableMouse(false)` on the model; verify in game, it is one line either way |
| `SetHitRectInsets` is protected in combat | Routed through `CombatQueue` with the other geometry calls |
| Narrow frames leave too little bar after the inset | Clamp the inset so bars keep a minimum width (say 20px) and log once if clamped, rather than producing a zero-width bar |
| Two changes in one migration step | Split into two steps so each is independently reversible and testable |

---

## Estimate

3–4 hours. The bar inset touches `LayoutBars`, which every layout test depends
on, so most of the time is re-verification rather than new code.
