# Plan 1 — Combat and Resting Indicators

**Status:** Implemented on `Plan-1-combat-resting-indicators`.
**Created:** 2 August 2026
**Branch:** `Plan-1-combat-resting-indicators`

---

## Outcome

Built as designed. `Elements/Indicators.lua`, on `frame.overlay`, states in a
sorted table so resting comes first and a third state is a table entry.

Two things worth recording that the plan did not anticipate:

**The anchor resolver was duplicated.** `Elements/Text.lua` had a private
`anchorWidget` returning `(widget, available)`, and this element needed exactly
the same logic — including the rule that something anchored to a hidden bar
hides rather than falling onto the frame body. Rather than copy it, it moved to
`ns:AnchorWidget` in Core and Text now calls that. Two elements asking the same
question should not be able to drift apart on the answer.

**No fallback detection is possible.** The plan said to fall back to a colored
square if the art fails to load. A missing texture does not error and does not
report — WoW simply draws nothing — so there is nothing to detect. Instead the
style is a user-facing choice (`Game artwork` / `Solid square`) defaulting to
the art, and the probe now reports whether the frames that use that sheet still
exist, which is the closest thing to a signal available.

Also as planned: no migration. These are new keys, so `EnsureProfile` fills them
into existing profiles.

26 assertions covering each state alone and together, ordering, all four growth
directions, a disabled state freeing its slot, resting never appearing on a
non-player unit, the overlay draw order, and hiding when the anchor bar is not
shown.

---

## Request

> add indicators for Combat state and Resting state. These should have
> configuration options for anchor point, x/y offset, and so on. By default,
> both should be anchored to the top-left of the player's health bar, with the
> icon fully overtop of the health bar. If the player is both resting and in
> combat, it should show the resting indicator first and then the combat
> indicator, with the list growth direction being configurable and defaulted to
> "to the right".

---

## Interpretation

A new element that draws a small ordered row of state icons. Two states in v1
(resting, combat), but the shape should be a *list* so a third (PvP, leader,
raid target) is a table entry rather than a rewrite.

"Fully overtop of the health bar" means the icon is drawn over the bar rather
than beside it — anchored `TOPLEFT` to `TOPLEFT` of the health bar at 0,0, with
no attempt to reserve space.

---

## Design

### New element: `Elements/Indicators.lua`

Follows the standard element contract (`Build` / `Layout` / `Update` /
`Disable`, `configKey = "indicators"`). Registered with an `order` after
`text` so it draws late.

**Draw order matters.** Icons must be created on `frame.overlay`, not
`frame.content` — the bars are child frames and would cover anything on
`content`, which is the bug fixed in `cb746a9`. `ns.LEVELS.OVERLAY` already
exists for this.

### State providers

A table, so adding a state is one entry:

```lua
local STATES = {
    { key = "resting", order = 1,
      active = function(unit) return unit == "player" and IsResting() end,
      texture = ..., texCoord = ... },
    { key = "combat",  order = 2,
      active = function(unit) return UnitAffectingCombat(unit) end,
      texture = ..., texCoord = ... },
}
```

Ordering is by the `order` field, which fixes resting-before-combat as
requested while leaving it changeable.

### Art

Classic's own state icons live in `Interface\CharacterFrame\UI-StateIcon`:
resting is the left half, combat the right half, selected by `SetTexCoord`.
Exact coordinates need confirming against the running client — `/dufprobe`
should be extended to report whether that texture resolves, since the Midnight
shared-code UI may have moved it.

Per SPEC §5.5 the **path and texcoords go in `Core/Compat.lua`**, not in the
element. They are Blizzard art that a patch can move, which is exactly what
Compat exists to absorb. Fall back to a plain colored square if the texture
fails to load, so a moved asset degrades to "a marker" rather than "nothing".

### Layout

A 1D version of the aura grid. Active states are collected in order, then
placed along the growth axis:

| Setting | Default |
|---|---|
| `enabled` | true on `player`, false elsewhere |
| `anchorTo` | `health` |
| `point` / `relativePoint` | `TOPLEFT` / `TOPLEFT` |
| `x`, `y` | 0, 0 |
| `size` | 20 |
| `spacing` | 2 |
| `growth` | `RIGHT` |
| per-state `enabled` | true |

`growth` accepts RIGHT / LEFT / UP / DOWN, matching `Units/PartyGroup.lua`'s
`GROWTH` table — reuse the same shape so there is one idea of "growth
direction" in the codebase.

Only *active* states occupy a slot, so combat alone sits at position 1 rather
than leaving a resting-shaped hole.

### Events

| Event | Drives |
|---|---|
| `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` | combat |
| `PLAYER_UPDATE_RESTING` | resting |
| `PLAYER_ENTERING_WORLD` | both, on zone-in |

All global (no unit payload), registered through `Compat.RegisterEvent` so an
event this client lacks is skipped rather than throwing.

`UnitAffectingCombat(unit)` works for any unit, so combat is meaningful on
target and party too. `IsResting()` is player-only; the resting state's
`active` returns false for other units rather than being special-cased in the
layout.

### Configuration

`Config/Options_Layout.lua` gains an Indicators group per unit: enable, anchor
target, point, relative point, x, y, size, spacing, growth, plus a per-state
enable toggle. All standard controls — no new option machinery needed.

---

## Files

| File | Change |
|---|---|
| `Elements/Indicators.lua` | New |
| `DyrueUnitFrames.toc` | Add the file |
| `Core/Compat.lua` | State icon texture paths and texcoords |
| `Core/Defaults.lua` | `indicators` block; schema bump |
| `Core/Migrate.lua` | None — new keys are filled by `EnsureProfile` |
| `Config/Options_Layout.lua` | Indicators group |
| `Probe/.../Probe.lua` | Report whether the state-icon texture exists |
| `Tests/tests.lua` | New suite |

**No migration needed.** This adds keys rather than changing existing values,
and `Defaults:EnsureProfile` fills new keys into existing profiles. That is the
cheap case — contrast with Plan 5, which changes a stored value.

---

## Tests

- Both inactive → nothing shown.
- Combat only → one icon, at slot 1.
- Resting only → one icon, at slot 1.
- Both → two icons, resting at slot 1, combat at slot 2, offset by
  `size + spacing` along the growth axis.
- Growth LEFT / UP / DOWN place the second icon on the correct side.
- Anchored to the health bar, and hidden when the health bar is (the rule added
  in `ead8492` for bar-anchored text applies here too).
- Icons live on `frame.overlay` and draw above the bars.
- `IsResting` returning true for a non-player unit still yields no resting icon.

---

## Risks

| Risk | Handling |
|---|---|
| `UI-StateIcon` moved or renamed by the Midnight shared UI | Path in Compat, probe reports it, fall back to a colored square |
| Icon over a light bar is hard to see | Optional backdrop behind the icon; defer unless it actually looks bad |
| Scope creep into a general "status icon" system | Two states now; the table shape means a third is cheap, but PvP/leader/raid-target stay out of this plan |

---

## Estimate

2–3 hours including tests. The element contract, anchoring, growth-direction
and options patterns all already exist; this is assembly rather than new
machinery.
