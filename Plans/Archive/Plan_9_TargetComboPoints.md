# Plan 9 — Target Combo Points

**Status:** Implemented on `Plan-9-target-combo-points`.
**Created:** 2 August 2026
**Branch:** `Plan-9-target-combo-points`

**Deviation from the plan as written:** the schema numbers moved. This plan was
written against schema 11 and says "migration step `[11]`, schema goes to 12".
Plan 8 part 2 landed first, collapsing schemas 1–11 into one declarative step
and taking `SCHEMA_VERSION` to 12. So the buff-row change is **step `[12]`** and
the schema goes to **13**. Nothing else about it changed: a profile arriving
from any version ≤ 11 runs the collapsed step, lands on 12, and then takes step
12 to 13, so old profiles get the raise too.

One test was written differently from the plan's wording: the plan asks for
`container:GetTop() > frame:GetTop()`, but the headless widget stub does not
model resolved screen coordinates (`GetTop` is an unmodelled no-op). The
assertion is made against the anchor instead — `BOTTOMLEFT` to `TOPLEFT` on
`frame.content` with a positive `y` — which is what actually encodes "sits on
the top edge and grows upward".

---

## Request

> we need combo point indicators on the target frame. use the new work skill to
> make a plan for implementation. the combo points should be five rectangles,
> with a flat fill color that defaults to a dull magenta. This bar should be
> anchored to the top edge of the target frame, growing upward from that edge,
> but does not necessarily need to be the same total width as the health bar.
> There should be clear borders around and between each rectangle.

---

## Interpretation

A new element, `Elements/ComboPoints.lua`, drawing a row of five flat rectangles
above the target frame.

**Whose resource is this.** Combo points belong to the *player* and are spent on
the *target*. The value is read with `GetComboPoints("player", <target>)` — a
player-owned number displayed on the target frame. That asymmetry drives the
one genuinely awkward part of this plan (see *The event trap* below).

**"Five rectangles."** Five is correct for Classic Era and TBC for both rogues
and feral druids. It is still read from `Compat` rather than written as a `5` in
the element, in the same spirit as `Compat.MANA`.

**"Anchored to the top edge … growing upward from that edge"** means the bar
sits *outside* the frame's bounds, occupying `[top, top + height]`. It therefore
takes no slot in the bar stack, `LayoutBars` is untouched, and nothing inside
the frame moves when it appears. Concretely: `BOTTOMLEFT` of the bar to
`TOPLEFT` of the frame, `y = 2`.

**"Does not necessarily need to be the same total width as the health bar"**
reads as permission, not a requirement. So the default is `widthMode =
"inherit"` (frame width) with a `custom` override, reusing the exact vocabulary
the shapeshift mana bar already has in `Core/Defaults.lua`. Someone who wants a
narrow centered bar changes two settings.

**"Clear borders around and between each rectangle"** is read as one uniform
border thickness all the way round the group *and* in the gaps between pips —
i.e. adjacent pips share one border line rather than each carrying its own
(which would render double-thickness between pips and single at the ends).

### Not specified by the request; choices taken

| Question | Choice | Why |
|---|---|---|
| What does an unfilled rectangle look like? | Drawn in a separate dark `emptyColor` | Five rectangles are the *capacity* readout; blanking them entirely loses that |
| Is the bar shown at zero points? | No — `hideWhenEmpty = true` | Matches Blizzard's own `ComboFrame`, and it is what keeps the bar invisible for the eight classes that have no combo points at all, with no class table anywhere (see below) |
| Which units may show it? | `player` and `target` | It is the player's resource against the player's target. On a party frame it would be meaningless. §FR-8.5's rule: absent, not present-and-broken |
| Fill direction | `growth = RIGHT`, `LEFT` available | Same word the indicator row uses |

---

## Design

### 1. Reading the value — `Core/Compat.lua`

Per §5.5, this is the only file allowed to touch a version-sensitive API, and
combo points are exactly that.

```lua
Compat.MAX_COMBO_POINTS = tonumber(_G.MAX_COMBO_POINTS) or 5

--- Combo points the player has on `unit`.
function Compat.GetComboPoints(unit)
    local fn = _G.GetComboPoints
    if fn then
        local ok, points = pcall(fn, "player", unit or "target")
        if ok then return points or 0 end
    end
    local enumType = _G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.ComboPoints
    if enumType then
        return UnitPower("player", enumType) or 0
    end
    return 0
end
```

**A trap worth writing down.** Do *not* reach for `UnitPower("player", 4)`.
Power type `4` is `HAPPINESS` in the numbering this addon already carries in
`Compat`'s `powerTypeNames` table; `4` only means combo points under the modern
`Enum.PowerType`. The Enum path is therefore gated on the Enum actually
existing, never on a literal.

`GetComboPoints` is what Blizzard's own `ComboFrame` uses on these clients and
is the primary path. The Enum branch is insurance against the shared-code UI
eventually retiring the old function.

**Probe additions.** `Compat.Describe()` gains `hasGetComboPoints`,
`maxComboPoints` and `hasComboPointEnum`, and `Probe/…/Probe.lua` reports them.
The open question those answer: does `UnitPowerMax("player",
Enum.PowerType.ComboPoints)` return 5 for a rogue on 1.15.9 / 2.5.6? If it
does, a later revision can use it as a genuine capability probe and offer an
always-visible empty bar without a class check. Until it is observed in game,
nothing is gated on it.

### 2. The element — `Elements/ComboPoints.lua`

Standard contract: `IsEnabled` / `Build` / `Layout` / `Update` / `Disable`,
`configKey = "combo"`.

`order = 35` — with the bars, after `mana` (30) and before `text` (60).
Deliberate: if text or auras are ever allowed to anchor to this bar, they must
lay out after it.

**Build.**

```lua
el.container = CreateFrame("Frame", nil, frame.content)   -- unprotected
el.container:SetFrameLevel(ns:Level(frame, "OVERLAY"))
el.border = el.container:CreateTexture(nil, "BACKGROUND")  -- the whole rect
el.pips = {}                                               -- ARTWORK, n of them
```

A container frame rather than loose textures on `frame.overlay`, for three
reasons: one place to `Show`/`Hide`, one frame level to set, and it gives a real
widget for anything that later wants to anchor to the bar.

**Borders, cheaply.** One texture behind the group, filled with `borderColor`,
sized to the whole bar; the five pips laid on top with a `borderSize` gap
between them and around the outside. The backdrop showing through the gaps *is*
the border. Six textures instead of the twenty-plus that per-pip edges would
need, and the line between two pips is automatically a single shared line of
exactly the requested thickness.

**Pip geometry**, for width `W`, border `b`, `n = 5`:

```
inner     = W - b * (n + 1)
pipWidth  = floor(inner / n)
remainder = inner - pipWidth * n        -- 0..4
```

The remainder is distributed one unit at a time to the first `remainder` pips.
This is deliberate: **borders stay exactly `b` everywhere and pips may differ by
one pixel**, rather than the reverse. The request asks for clear borders, so the
borders are the quantity held constant. (At a frame scale other than 1.0, UI
units are not screen pixels and this is best-effort — worth a comment in the
code, not worth engineering around.)

Pip height is `height - 2 * b`.

**Update.**

```lua
local points = Compat.GetComboPoints(frame.unit)
```

Then: hide the container outright when `points == 0` and `hideWhenEmpty`;
otherwise show it and set each pip's `SetColorTexture` to `color` or
`emptyColor` by index, honouring `growth`. `SetColorTexture` throughout — the
request says flat fill, so there is no statusbar texture and no LibSharedMedia
lookup here.

Anchoring goes through `ns:AnchorWidget(frame, cfg.anchorTo)` exactly as
`Elements/Indicators.lua` does, which brings the hide-if-the-anchor-bar-is-gone
rule along for free.

### 3. The event trap — `Units/Factory.lua`

`UNIT_COMBO_POINTS` fires **with `"player"` as its payload**, but this element
lives on the *target* frame. `Factory:RegisterEvents` registers every `UNIT_*`
event against the frame's own display unit:

```lua
Compat.RegisterUnitEvent(self, event, unit)   -- unit = "target" here
```

so a naive `events = { UNIT_COMBO_POINTS = true }` would register the filter
against `"target"` and **the handler would never run**. This would not error and
would not warn; the bar would simply never update. It is the single most likely
way to lose an afternoon on this feature.

The fix is a small, general addition to the element contract — an optional
per-event unit override, mirroring the `def.owner` mechanism `changeEvents`
already uses for `UNIT_TARGET` and `UNIT_PET`:

```lua
element.eventUnits = { UNIT_COMBO_POINTS = "player" }
```

`subscribe` consults `def.eventUnits and def.eventUnits[event]` and falls back
to the frame's display unit. Three lines.

**One guard is required.** Two elements on the same frame may now ask for the
same event under different units, and `subscribe` registers each event name
once. If a second element asks for an already-registered event with a
*different* unit, register it **unfiltered** (`Compat.RegisterEvent`) so both
elements still receive it, rather than letting the second registration silently
narrow or widen the first. Without that guard, adding `UNIT_POWER_UPDATE` to
this element would quietly break the target frame's power bar.

That guard is why this element does **not** subscribe to `UNIT_POWER_UPDATE`
even though the Enum path would deliver combo points through it:
`UNIT_COMBO_POINTS` is the documented event on both target clients, and staying
off the shared one keeps the conflict path unexercised. Revisit only if the
probe shows `GetComboPoints` is gone.

**Full event set:**

| Event | Registered against | Drives |
|---|---|---|
| `UNIT_COMBO_POINTS` | `"player"` (via `eventUnits`) | Gaining and spending points |
| `PLAYER_TARGET_CHANGED` | global | Points reset on a target switch |
| `PLAYER_ENTERING_WORLD` | global | Zone-in |

`PLAYER_TARGET_CHANGED` is already in the target frame's `changeEvents`, and
`dispatch` handles change events first and returns, so listing it here costs
nothing on the target frame and is what makes the element work if someone
enables it on the player frame.

### 4. Configuration — `Core/Defaults.lua`

A `combo` block in the shared per-unit schema (uniformity, the same reasoning
the comment on `mana` already gives), enabled only on `target`:

```lua
combo = {
    enabled = false,            -- true on target; see buildUnits
    anchorTo = "frame",         -- frame | health | power | mana | portrait
    point = "BOTTOMLEFT",
    relativePoint = "TOPLEFT",
    x = 0,
    y = 2,
    widthMode = "inherit",      -- inherit | custom
    width = 200,
    height = 10,
    borderSize = 1,
    growth = "RIGHT",           -- RIGHT | LEFT
    color = color(0.72, 0.33, 0.63),        -- dull magenta
    emptyColor = color(0.12, 0.12, 0.12, 0.9),
    borderColor = color(0, 0, 0, 1),
    hideWhenEmpty = true,
    alpha = 1,
},
```

**On the magenta.** Full magenta is `(1, 0, 1)` and is punishing as a block of
flat fill — the same problem the health bar's `brightness = 0.8` default exists
to solve, and the comment there says so. `(0.72, 0.33, 0.63)` is magenta pulled
back in both saturation and value: unmistakably magenta, sits next to a
class-coloured health bar without shouting. One colour picker away from
anything else.

`point`/`relativePoint` default to `BOTTOMLEFT`/`TOPLEFT` because the default
width is inherited and flush-left is then flush-both-sides. A custom narrower
width will usually want `BOTTOM`/`TOP` to centre it; that is two dropdowns.

**A single `color`, not five.** The request says "a flat fill color",
singular. Per-point escalating colours (green→yellow→red at 5) are a common
want and would slot in later as a `colors` list beside `color`; nothing here
blocks it. Out of scope now.

### 5. Options — `Config/Options_Layout.lua`

A `comboGroup(def)` following `indicatorsGroup` exactly: enable, anchor target,
point, relative point, x/y via `Options.Range`, width mode, width, height,
border size, growth, hide-when-empty, and three `Options.Color` fields. Added to
`Options.BuildUnit`'s `args` with

```lua
hidden = not (def.key == "player" or def.key == "target"),
```

so it is absent rather than present-and-broken elsewhere, following §FR-8.5.

---

## Beyond the literal request: the buff-row collision

This needs stating plainly because it will be the first thing seen in game.

The target frame's **buff group already anchors to the top edge**:
`anchorTo = "frame"`, `BOTTOMLEFT` → `TOPLEFT`, `y = 2`, growing `UP`, 20px
icons. The first buff row occupies `[top + 2, top + 22]`. A combo bar at
`y = 2`, height 10, occupies `[top + 2, top + 12]`. They overlap outright.

`hideWhenEmpty = true` contains it — the overlap only exists while points are
actually up — but that is precisely when the bar is being looked at, so it is
not a fix.

**Recommendation: fix the shipped default in this plan.** Add migration step
`[11]` raising the target's buff group from `y = 2` to `y = 14`
(`height + borderSize * 2 + gap`), and change the same value in
`Defaults.buildUnits` so new profiles ship correct. Follow the rule steps 7–10
already establish: move it **only** when every field still matches the exact
shipped default, so anyone who has positioned their buffs keeps their position.
Schema goes to **12**.

Cost is about twenty lines plus two assertions. The alternative — ship the
overlap and let the user raise their own buff offset — is one setting, but it
means the default target frame is visibly broken for every rogue and feral
druid on first login, and "it looks wrong out of the box, here is the setting"
is a bad trade for twenty lines.

**What was considered and rejected:** adding `combo` to `ns:AnchorWidget` so the
buff group could anchor *to* the combo bar and follow it automatically. That is
the architecturally cleaner answer, but the anchor contract says a widget that
is not showing reports `available = false` and its dependants **hide** — so
every target buff would vanish whenever combo points dropped to zero. Making
`combo` an exception to that contract is a real design decision and should be
its own plan, made after this bar has been looked at in game. A fixed 14px
offset is the honest interim.

---

## Files

| File | Change |
|---|---|
| `Elements/ComboPoints.lua` | New — the element |
| `DyrueUnitFrames.toc` | Add after `Elements/ShapeshiftMana.lua` |
| `Core/Compat.lua` | `GetComboPoints`, `MAX_COMBO_POINTS`, three `Describe()` entries |
| `Units/Factory.lua` | `def.eventUnits` support in `RegisterEvents`, plus the conflicting-unit guard |
| `Core/Defaults.lua` | `combo` block; `enabled = true` on target; target buff `y` 2 → 14; `SCHEMA_VERSION` 11 → 12 |
| `Core/Migrate.lua` | Step `[11]` — raise the target buff row off the combo bar |
| `Config/Options_Layout.lua` | `comboGroup`, hidden on units other than player and target |
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | Report the combo-point API surface |
| `Tests/wowstub.lua` | `UNIT_COMBO_POINTS` in `validEvents`; `GetComboPoints`; `MAX_COMBO_POINTS`; per-unit combo count in `stub.setUnit` data |
| `Tests/tests.lua` | New suite |

### Schema and migration

Two distinct cases, and they are worth keeping straight:

- **The `combo` block is free.** New keys, so `Defaults:EnsureProfile` fills
  them into existing profiles. No step, and no bump on its own account.
- **The target buff offset is not.** It changes a *stored value* somebody may
  have set, so it needs step `[11]` and the "only the exact untouched default
  moves" test. The distinguishing rule: move only when `anchorTo == "frame"`,
  `point == "BOTTOMLEFT"`, `relativePoint == "TOPLEFT"`, `x == 0` and `y == 2`,
  on the `target` unit only.

---

## Tests

New suite in `Tests/tests.lua`. `stub.setUnit` gains a combo count and
`GetComboPoints` reads it, so the whole element is testable headlessly.

**Defaults and options**
- `combo.enabled` is true on `target`, false on `player`, `pet`, `party1`.
- The options group exists for `player` and `target` and is `hidden` for
  `party1` and `targettarget`.
- Default colour is the dull magenta, not `(1, 0, 1)`.

**Geometry**
- Five pips built.
- With `width = 200`, `borderSize = 1`: pip widths sum to `200 - 6`, every gap
  is exactly 1, and the outer edges are exactly 1 from the container.
- A width where `inner` does not divide by five (e.g. 202) still leaves every
  border at exactly 1 and pip widths differing by at most 1.
- `widthMode = "custom"` uses `cfg.width`; `inherit` tracks a change to frame
  width through `ApplyConfig`.
- The container's bottom edge sits on the frame's top edge plus `y`, and the bar
  extends upward — assert `container:GetTop() > frame:GetTop()`.

**Value**
- 0 points with `hideWhenEmpty` → container hidden.
- 0 points with `hideWhenEmpty = false` → shown, all five pips `emptyColor`.
- 3 points → pips 1–3 `color`, 4–5 `emptyColor`.
- `growth = "LEFT"` fills from the right-hand pip.
- 5 points → all filled; a value above 5 clamps rather than erroring.

**Events**
- `UNIT_COMBO_POINTS` is registered against `"player"` on the **target** frame,
  not against `"target"`. This is the regression test for the whole trap — the
  stub's `fire` honours unit filters, so firing it with `"player"` must reach
  the target frame's handler.
- Firing it updates the pip count without a `FullUpdate`.
- `PLAYER_TARGET_CHANGED` re-reads (already a change event; assert the outcome,
  not the path).
- Two elements requesting the same event under different units end up with an
  unfiltered registration and both still fire.

**Migration**
- A schema-11 profile with the exact shipped target buff anchor comes out at
  `y = 14`.
- A profile whose target buffs were moved (any field differing) is untouched.
- A non-target unit's buff group is untouched.

**Gap this closes.** There is currently no test asserting *which unit* an
element's events are registered against. The `UNIT_TARGET`/`owner` handling in
`Factory` has the same failure mode and is likewise unasserted; the new helper
should be written so it can cover that too.

---

## Risks

| Risk | Handling |
|---|---|
| `UNIT_COMBO_POINTS` registered against the wrong unit — silent, no error, bar never updates | `eventUnits`, plus the explicit test that the registration is against `"player"` |
| A second element later claims `UNIT_POWER_UPDATE` under a different unit and breaks the power bar | The unfiltered-fallback guard in `subscribe`, with a test |
| `GetComboPoints` retired by a shared-code patch | Enum fallback already written; probe reports which path is live |
| `Enum.PowerType.ComboPoints` being `4` collides with Classic's `HAPPINESS = 4` | Never use a numeric literal; the Enum branch is gated on the Enum existing |
| Overlap with the target buff row | Migration step 11 plus the matching default change; argued above |
| Fractional pip widths at non-unit frame scale | Borders held constant, pips absorb the remainder; documented as best-effort |
| Scope creep into per-point colours, animation, a "points spent" flash | All out. The `color` key leaves room for a `colors` list later |

---

## Estimate

**3–4 hours.** The element itself is a couple of hours of assembly — the
contract, `AnchorWidget`, the options patterns and the colour helpers all
already exist. The `eventUnits` change to `Factory` and its conflict guard are
small but sit in the one file where a mistake is expensive, so they carry the
test burden. The buff-row migration adds roughly half an hour.

The one thing that cannot be settled at the desk is whether `10` is the right
default height and whether `y = 14` clears the buff row cleanly at the shipped
frame size. Both are single numbers, settled by looking at it, exactly as the
indicator offset was in schema 10 → 11.
