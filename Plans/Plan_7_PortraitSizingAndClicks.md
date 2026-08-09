# Plan 7 — Portrait Sizing and Clicks

**Status:** Implemented on `Plan-7-portrait-column`. Four decisions were taken
at the start of implementation and three of them changed what the plan below
says; see *Implementation notes* at the foot of this document, which is the
authoritative record where the two disagree.
**Created:** 2 August 2026
**Branch written on:** `first` — implemented on `Plan-7-portrait-column`

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

---

## Implementation notes

Written after the work. Where this section and the plan above disagree, this
section is what was built.

### The four decisions taken before starting

| Question | Answer | Effect |
|---|---|---|
| Ship `column` as the default, and move existing profiles onto it? | **Both** | Schema 16 |
| Should `reserve`-mode mana count towards the portrait height? | **No** — health + power, always | Contradicts the plan; see below |
| Build the hit-rect trick for `detached`? | **Yes** | `Factory:ApplyHitRect` |
| Add a `square` toggle (width follows height)? | **Yes, and default it on** | The plan proposed offering it; it ships enabled |

### The mana bar is excluded in *both* modes

The plan proposed excluding `append`-mode mana but *including* the `reserve`
slot, on the grounds that reserve mode is the one where the stack has a fixed
height. That was overruled: the portrait tracks health + power and nothing else,
in every mode.

The consequence is worth stating plainly, because it is visible: in `reserve`
mode the mana slot is permanently allocated inside the frame, so the portrait
now ends where the power bar ends and is **shorter than the frame** by the mana
slot. Nothing jumps — the slot is reserved whether or not a druid is shifted —
but the portrait is deliberately not flush with the frame's bottom edge there.

One rule, stated once, is easier to reason about than a rule with a mode
exception, and it is the literal reading of "the combined heights of the health
bar and power bar".

### `matchBarHeight` and `square` apply in every placement

The plan framed the height rule as a property of `column`. It is not: a
`detached` portrait that matches the bar stack is just as reasonable, and the
request ("its height should **always** be equal…") does not carve out a
placement. `Resolve` therefore computes size before it looks at placement, and
only the *slot* — the width the bars give up — is column-specific.

### Migration: the signal is `mode`, not the arriving schema version

The plan's rule was "a profile at schema ≤ 7 predates any chance to deliberately
choose". That signal no longer exists. The plan was written when the schema was
at 7; it is now at 16, schemas 1–11 have since been collapsed into one
declarative step (Plan 8), and every profile has had six versions in which
`outside` could have been a real choice.

What *is* still recoverable is whether the placement was ever seen. The portrait
has shipped `mode = "none"` since 1.0, so a profile that still has it off has
never rendered a portrait at all — there was nothing to judge, and the placement
it carries can only be inherited. Where the portrait is on, "untouched" falls
back to the whole shipped geometry tuple (`width = 40, height = 40, x = 2`),
which is the rule steps 12–14 already used.

So:

- `inside` → `overlay` and `outside` → `detached`: **unconditional**, as planned.
- `detached` → `column`: only where the placement is demonstrably inherited.
- `x = 2` → `0`: only where the placement moved with it. A profile staying on
  `detached` or `overlay` keeps the offset it has.

The collapsed step's `inside` → `outside` rule was deliberately left alone rather
than re-pointed at `column`. It is a truthful record of the schema-≤11 era
default, and step 15 carries every profile the rest of the way under one rule,
from any starting version.

### The narrow-frame clamp does not log

The plan's risk table said "clamp the inset **and log once** if clamped". The
clamp is in `Portrait.Resolve` (`MIN_BAR_WIDTH = 20`) and the portrait shrinks
*with* the slot, so the two never overlap. The log was dropped: the clamp is now
self-evident in the rendered frame — the portrait visibly stops growing — and a
chat line fired from a function that runs on every `LayoutBars` would need
per-frame state to stay quiet, which is a worse trade than the thing it warns
about.

### Spec

`SPEC.md` §FR-7.2 named the two old placements outright, so it was amended in
place (§FR-7.2, plus new §FR-7.2a on the sizing rule and §FR-7.2b on
click-targeting) rather than left standing against the code. Recorded in
`Documents/COMPAT_FINDINGS.md` under *Deviations from SPEC.md*, with the
`PlayerModel` mouse question added to the §0.8 table as the one thing here that
only a client can answer.

### Also changed

- `Elements/ShapeshiftMana`'s bar is inset with the rest of the stack, even
  though the portrait does not reach down to it. A bar lining up with the frame
  edge instead of with the two bars directly above it reads as a mistake.
- The width and height sliders are `disabled` rather than hidden when `square`
  and `matchBarHeight` are driving them, so it is visible *why* they do nothing.
- `x` is relabelled in the tooltip as the gap between the portrait and the bars
  when the placement is `column`.

**Test suite:** 928 → 1004 assertions, all green across all four passes, plus
`luacheck` and `refcheck` clean.
