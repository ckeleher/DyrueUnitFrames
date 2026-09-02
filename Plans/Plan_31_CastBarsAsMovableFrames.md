# Plan 31 — Cast Bars as Independently Movable Frames

**Status:** Not started.
**Created:** 1 September 2026
**Branch:** `Plan-31-movable-cast-bars`
**Depends on:** Plan 30. Branch from `main` after Plan 30 merges.

---

## Request

> i understand that, per prior docs, player and target cast bars are out of scope. I want you to estimate how difficult it would be to add support for those, as independently movable frames which are by default attached to the player and target frames. consider the difficulty of adding cast bars for other frame types (party, focus, etc) as well

**This plan covers the load-bearing half:** *"as independently movable frames
which are by default attached to the player and target frames"*. It is the only
one of the four that changes the addon's architecture, and it is the only one
carrying real risk.

---

## Interpretation

"Independently movable, but attached by default" is one behavior, not two, and
the addon already has it. `SPEC.md` §FR-1.5's anchor graph means a frame stores
`anchorTo` plus an offset and moves with its parent; the pet frame ships
anchored to `player` (`Core/Defaults.lua:673`) and target-of-target to `target`
(`Defaults.lua:665`). Changing one dropdown to "Screen" detaches either.

So *"by default attached to the player frame"* costs a single default:

```lua
anchor = { to = "player", point = "TOP", relativePoint = "BOTTOM", x = 0, y = -6 }
```

and everything the request asks for — drag it anywhere, or leave it stuck to the
frame — follows from machinery that already exists and is already tested.

**The cost is entirely in one word: *frames*.** Everything movable in this addon
is a *unit* frame, and Plan 30's cast bar is an *element* living inside one. The
work is making the addon able to own a movable frame that is not a unit.

### The reading not taken

An alternative is to leave the cast bar an element and give it a full anchor
block of its own, drawn outside its host frame's bounds. That is not fantasy —
the pet's indicator row already renders outside the frame's right edge
(`Defaults.lua:700-712`) and the shapeshift mana bar's `append` mode hangs below
it, so nothing clips.

Rejected, because it delivers the appearance of the request and not the request.
`Config/DragMode.lua:330` iterates `ns.frames`, so a bar positioned that way
could never be dragged, only typed at. It could not be an anchor target for
anything else. And it would be a second positioning system alongside the anchor
graph, which is exactly what `DragMode.lua`'s header rejects: *"There is one
source of truth; drag mode is an input method, not a parallel layout system."*

---

## Design

### The shape of the problem

Three systems define "movable", and all three key on the same identity —
`ns.frames[unitKey]` plus `profile.units[unitKey].anchor`:

| System | Where | What it assumes |
|---|---|---|
| `Systems/Anchoring.lua` | `anchorParent` :46, `Resolve` :107, `SortedKeys` :140, `TargetValues` :188 | Reads `ns:UnitConfig(key).anchor`; resolves targets out of `ns.frames`; offers targets out of `ns.Registry.units` |
| `Config/DragMode.lua` | :330, `buildOverlay` :196 | Iterates `ns.frames`; labels overlays from `Registry:Get(frame.unitKey).label`; `anchorTarget` :62 reads `ns:UnitConfig` |
| `Config/TestMode.lua` | `HoldVisible` :60 | Refcounted visibility holds, keyed per frame |

**Do not special-case any of them.** Register cast bars as `Registry` entries:

```lua
define("playercast", {
    order = 15,
    label = L["Player Cast Bar"],
    kind = "castbar",
    token = "player",
    secure = false,
    unitWatch = false,
    changeEvents = {},
})
```

`Units/Registry.lua`'s own header states the payoff — *"Adding a unit is a table
entry, which is exactly why party frames and derived units cost nothing extra"*.
Taken at its word, anchoring, drag mode, arrow-key nudging, grid snap,
anchor-loop rejection, the "anchor to" dropdown, test-mode visibility holds and
profile import/export all work **with no edits to those files at all**. Being
able to anchor the target frame *to* the cast bar falls out as a bonus, and is
correct.

Four things then need real work.

### 1. `Factory:Create` builds the wrong kind of frame — and it matters

`Units/Factory.lua:519` unconditionally creates a `Button` from
`SecureUnitButtonTemplate`. For a cast bar that is not merely unnecessary, it is
**disqualifying**:

> `Show` and `Hide` on a protected frame are forbidden in combat.

A cast bar's entire job is appearing and disappearing during combat. Routing
that through `CombatQueue` means the bar surfaces when you *leave* combat, which
is worse than not shipping it.

Two ways out.

**Rejected:** keep the secure button permanently shown and let the insecure
`frame.content` do the showing and hiding. It works, and it costs nothing
structurally — but it leaves a permanently-present click-targeting button
floating wherever the cast bar sits, a mouse dead zone that targets the player
when nothing is casting. Disabling the mouse and stripping the attributes to fix
that means paying for a secure frame you have deliberately broken.

**Taken:** branch on `def.secure == false` and create a plain `Frame`.

Everything downstream is already frame-type agnostic — `content`, `overlay`,
`background`, `borderEdges`, the `methods` table, the element loop in
`ApplyConfig`, `OnEvent` dispatch. What gets skipped for an insecure frame:
`SetAttribute`, `RegisterForClicks`, `Compat.RegisterClickCast`,
`RegisterUnitWatch`, and the `SecureUnitButtonTemplate` failure path with its
error message. `SetMovable(true)` stays — drag mode needs it.

Roughly twenty lines. It is also **the riskiest edit in all four plans**, because
this function is load-bearing for all twelve existing frames. Handling is in
Risks below.

`methods:ApplyLayout` and `methods:ApplyConfig` keep running through
`CombatQueue`. They are harmless on an insecure frame and leaving the call sites
uniform is worth more than the microseconds; the *element's* show/hide is what
had to escape the queue, and it always was outside it.

### 2. `methods:LayoutBars` is a hardcoded stack

`Factory.lua:283` lays out health → power → shapeshift mana, with a portrait
column. A cast-bar frame has one bar filling its whole rect.

Branch on `self.def.kind`. A `castbar` frame calls the cast element's
`SetGeometry` across the frame's full width and height and returns. Keep the
existing path untouched rather than generalizing it — one `if` at the top of the
method is honest about there being exactly two shapes, and a generalized
slot-stack abstraction serving two callers would be harder to read than both.

### 3. The options tree is unit-shaped

`Options.BuildUnit` (`Config/Options_Layout.lua:1133`) hands every registered
unit the full tab set: layout, health, power, mana, combo, portrait, indicators,
highlight, texts, auras. A cast-bar frame wants **`layoutGroup(def)` verbatim** —
size, position, background, border, all of it applies unchanged — plus Plan 30's
`castGroup(def)`, plus `reset`. Nothing else.

So `BuildUnit` grows a branch returning the short arg set for
`def.kind == "castbar"`. `layoutGroup` itself needs no change: its party-group
special-casing is all guarded by `def.group`, which a cast bar does not have.

Two smaller consequences:

- `Factory:CopySettings` and the "copy settings between units" UI
  (`Config/Options.lua:531-560`) would offer cast-bar → health-frame copies,
  which produces nonsense. Filter both lists by `kind`.
- `Anchoring:TargetValues` and `Registry:LabelValues` pick the new keys up
  automatically, which is wanted, and the cycle detector already covers them.

### 4. Defaults must stop assuming one shape

`Defaults.unit()` (`Core/Defaults.lua:209`) builds a ~350-key template. A cast
bar frame needs about fifteen of them: `enabled`, `width`, `height`, `scale`,
`alpha`, `strata`, `anchor`, `background`, `border`, and Plan 30's `cast` block.

Add a `castUnit(overrides)` sibling that shares the anchor/background/border
sub-tables rather than a `kind` parameter threaded through `unit()` — the two
have almost nothing in common and a parameter would mean reading the whole
function to know which half applies.

Two call sites must follow, and missing either is a live bug:

- `Defaults:EnsureProfile` (`Defaults.lua:818`) fills any unit key with no
  template using **`unit()`** — a full unit schema. Correct today; wrong for a
  cast-bar key. Must consult the Registry's `kind`.
- `Defaults:ResetUnit` (`Defaults.lua:856`) falls back to `unit()` for an unknown
  key. Same fix. "Reset this unit" on a cast bar currently would hand it a health
  bar, a portrait and an aura config.

**Shipped defaults.** `playercast` anchored under the player frame as above,
`enabled = true`. `targetcast` is defined by Plan 32, not here.

---

## Files

| File | Change |
|---|---|
| `Units/Registry.lua` | `kind` and `secure` fields; `playercast` entry; a `Registry:IsCastBar(key)` query beside `IsDerived` |
| `Units/Factory.lua` | `Create` branches on `def.secure`; `LayoutBars` branches on `def.kind`; `CopySettings` refuses across kinds |
| `Core/Defaults.lua` | `castUnit()`; `buildUnits` gains `playercast`; `EnsureProfile` and `ResetUnit` consult `kind`. `SCHEMA_VERSION` 18 → 19 |
| `Config/Options_Layout.lua` | `BuildUnit` branches on `def.kind` |
| `Config/Options.lua` | Copy-between-units lists filtered by `kind` |
| `Config/TestMode.lua` | The substitution exception, below |
| `Documents/SPEC.md` | §2.3 records the player cast bar as built and movable; §3 gains the frame; §5.3 records the insecure-frame kind and why |
| `Tests/tests.lua` | Below |

`Config/DragMode.lua` and `Systems/Anchoring.lua` are **deliberately absent from
this table.** If either needs editing, the Registry-entry approach has been
implemented wrong — that is the check on the whole design.

---

## Schema and migration

`SCHEMA_VERSION` 18 → 19. Additive again: `profile.units.playercast` is a new
key, `EnsureProfile` fills it, no migration step.

The **ordering trap** is the thing to be careful about. `Core/Migrate.lua` runs
*before* `EnsureProfile`, and its collapsed step rewrites values that are still
at a historical default. Every rule there is keyed on paths under
`profile.units[*]`. Confirm none of them iterate all unit keys blindly and try to
apply a health-bar rule to a cast-bar frame that has no health block. The rules
are documented as idempotent and order-independent; this adds a key shape they
have never seen.

---

## Tests

- `Factory:Create` on a `secure = false` def produces a frame with `content`,
  `overlay`, `borderEdges` and the full methods table, and **is not** registered
  into `ClickCastFrames`, has no `unit` attribute, and is not unit-watched.
- **The bar can be shown and hidden while `InCombatLockdown()` is true.** This is
  the reason the plan exists; assert it directly rather than inferring it from
  frame type.
- `Anchoring:Resolve("playercast")` returns the player frame — and moving the
  player frame moves the cast bar with it.
- Setting `anchor.to = "UIParent"` detaches it and it stays where it was put.
- `Anchoring:WouldCycle` rejects `player` → `playercast` → `player`.
- `DragMode` builds an overlay for it, labeled from the Registry, and dragging
  writes to `profile.units.playercast.anchor` — through the unmodified DragMode.
- `Options.BuildUnit` for a cast bar yields `layout`, `cast`, `reset` and no
  `health` / `auras` / `portrait` / `texts`.
- `Defaults:ResetUnit(profile, "playercast")` produces a cast-bar config and
  **not** a unit config. Same for `EnsureProfile` against a profile carrying a
  bare `playercast` key.
- `CopySettings("player", "playercast")` is refused.
- Every existing frame test still passes unchanged — the regression surface.

**Gap this exposes:** nothing in the suite currently asserts *what kind of frame*
`Factory:Create` returns, because there has only ever been one kind. That
assertion should exist for the secure frames too, added here.

---

## Test mode needs its first real fiction

`Config/TestMode.lua`'s header states the property plainly: it substitutes a
*real* unit token so that everything downstream works on genuine data, and
*"the only fiction is identity"* — name, class and level, consulted in exactly
three places.

A cast bar breaks that. Nobody is casting while you arrange your UI, so
substituting a real unit yields an empty bar and the frame cannot be positioned.
It needs a fabricated fill — a loop over a plausible cast time with a placeholder
spell name and icon.

That is a **second** category of fiction, and the honest handling is to widen the
header's stated property rather than quietly add an exception underneath it. Keep
it as narrow as possible: the fake cast is driven only while `TestMode.active` or
`DragMode.active`, lives in the cast element behind one `IsFaking()` check, and
touches nothing else.

---

## Risks

| Risk | Handling |
|---|---|
| **`Factory:Create` is load-bearing for twelve frames** and this edit could break all of them | The branch adds a path rather than altering the existing one — the secure path must come out byte-identical. Assert frame type, attributes, click-cast registration and unit-watch state for an existing frame before and after. This is the one place to be slow |
| A protected operation reaches an insecure frame, or vice versa | `CombatQueue` is kept on `ApplyLayout` / `ApplyConfig` uniformly rather than conditionally skipped, so there is no second path to get wrong |
| `EnsureProfile` / `ResetUnit` hand a cast bar a full unit schema | Both call sites named above; both tested. This is the most likely bug in the plan because both are *fallbacks* and fallbacks are not exercised by the happy path |
| Frame count grows and `/duf profile` regresses | Plan 30's driver is shared and idles to zero; a non-casting cast bar is a hidden frame. Measure with `/duf profile` before and after anyway — the claim is cheap to check and worth having on record for Plan 33, which multiplies it |
| Test mode's stated design property is weakened | Documented above and in `SPEC.md` rather than left implicit |

---

## Estimate

**The substantial one — one full working session, most of it careful rather than
difficult.** Seven files, one of which (`Units/Factory.lua`) needs real care.

The payoff is that it is paid **once**. After this, a cast bar for any unit is a
Registry entry and a defaults entry — which is what makes Plans 32 and 33 nearly
free, and what makes the answer to *"how hard is this for party and focus too?"*
"almost nothing, once this plan lands".

`PLAN.md` §14 predicted the cast bar "shares no systems with anything else, so it
costs the same later as now". That is true of the bar and false of the frame.
This plan is the difference.
