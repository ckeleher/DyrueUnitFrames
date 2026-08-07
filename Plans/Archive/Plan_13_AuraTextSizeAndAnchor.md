# Plan 13 — Aura Text: Off By Default, Sized And Anchored

**Status:** Implemented on `Plan-13-aura-text-placement`, merged in PR #9.
**Created:** 4 August 2026
**Branch:** `Plan-13-aura-text-placement`

**Deviations from the plan as written:**

* **`Documents/SPEC.md` was not touched**, despite being in the Files table. It
  has a single commit in its history and `Tests/anglicize.py` excludes it by name
  as an authored requirement document whose rewording would put the record out of
  step with what was asked. The FR-5.5 / FR-5.6 divergence was recorded in the
  *Deviations from SPEC.md* table in `Documents/COMPAT_FINDINGS.md` instead,
  which is where `Skills/NewWork.md` says it belongs.
* **`Core/Locale.lua` needed no changes.** enUS is the identity mapping — the
  keys *are* the strings and `__index` returns the key — so new `L["..."]` call
  sites work with no table entry. The plan listed the file out of habit.
* **The options renumber went one decade further.** The plan said to move the
  sorting header to 60, which is where the tooltip header already sat. Actual:
  timers 40-54, sorting 60-68, tooltips 70-73.
* **The diagnosis step was never run in game.** Which overlay produced the
  numbers in the screenshot is still formally unconfirmed. It did not block,
  because both text layers got the same treatment, but the *default* change only
  quiets stacks — if it turns out the numbers were duration text switched on
  deliberately, the migration leaves that toggle alone by design and it needs one
  manual flip. See *Which numbers are these?* below for the deduction.

**Open follow-up:** the recommendation in *The concern, stated once* stands — now
that the size is 8px and the anchor is configurable, `showStacks` back **on** is
likely both readable and more useful than off. That is a default change and a
migration step to delete, not new code.

---

## Request

> 1) the timer numbers are too big and make the buffs pretty unreadable. Let's
> disable these numbers by default, and bake in some configuration options like
> resizing the timer and where on the buff icon to anchor it, if that's not too
> much work. if it takes a significant amount of work to implement timer
> customization, then maybe we skip it.

Accompanied by a screenshot of the target frame: two rows of eight debuff icons
below a level 72 elite, each icon carrying a large outlined number that covers
most of the art.

---

## Answer to the escape clause first

**It is not too much work — do it.** Roughly three hours including options,
migration and tests. Two of the three asks are cheaper than they look:

* **Resizing already exists.** `durationSize` and `stackSize` are both live
  settings with a 4–32 range, exposed in `Config/Options_Auras.lua:213` and
  `:240`. Nothing to build; the defaults are simply too large.
* **The anchor dropdown is nearly free.** `ns.Anchoring:PointValues()`
  (`Systems/Anchoring.lua:30`) already returns the nine-point list, and
  `stackCorner` already consumes it. The duration text needs the same control
  plus a shared placement helper.

What is actually new is the placement helper, two offset sliders, the changed
defaults and the migration.

---

## Which numbers are these?

The request says "timer numbers", but `showDurationText` has defaulted to
**`false`** since the initial commit (`Core/Defaults.lua:160` —
`git log -S showDurationText` shows one touch, in `d4ef9a3`). So the numbers on
screen are either stack counts, or duration text the user switched on. It
matters, because it decides what "disable by default" changes.

**They are stack counts.** The deduction is short and checkable:

* Duration text is anchored `("TOP", button, "BOTTOM", 0, -1)` —
  `Elements/Auras.lua:517`. It renders *below* the icon, never on it.
* The target's debuffs grow **downward** from the frame's bottom edge
  (`point = "TOPLEFT"`, `relativePoint = "BOTTOMLEFT"`, `growthY = "DOWN"` —
  `Core/Defaults.lua:525-529`). There is no row above the first one.
* The screenshot's **first** row has numbers sitting inside its icons. Nothing
  above it could have put them there, so they are not duration text.
* Stacks default on at `stackSize = 11` with `OUTLINE`
  (`Core/Defaults.lua:164-168`), drawn inside `stackCorner` on a 20px icon. An
  outlined two-digit number is ~14px wide in a 20px box with 2px of gap to the
  next icon. That is the picture.

One loose end: `applyButton` only draws a stack when `count > 1`
(`Elements/Auras.lua:526`), and the screenshot appears to contain a bare `1`.
The likely explanation is crowding — a `12` on one icon overlapping its
neighbour reads as `1` and `2` — which is the complaint restated. Thirty
seconds in game settles it: `/duf` → target → debuffs → *Timers and stacks*,
and read the two toggles.

**This plan treats both text layers identically**, so the answer is right either
way and the loose end costs nothing.

---

## Interpretation

Three concrete changes:

1. **Both numeric overlays default off.** `showDurationText` already is;
   `showStacks` flips from `true` to `false`.
2. **Both get a nine-point anchor plus x/y offsets**, replacing today's
   hardcoded placement.
3. **Both get smaller default sizes**, so that turning them back on produces
   something legible rather than a repeat of the screenshot.

### The concern, stated once

Stack counts off by default loses real information — a five-stack Sunder and a
one-stack Sunder become indistinguishable, and FR-5.6 exists because that
matters. The legibility problem is a **sizing** problem: 11px outlined on a 20px
icon, not the existence of the number.

The recommendation is to ship it off as asked, then look at the frame once the
size and anchor controls exist. `showStacks = true` with `stackSize = 8`
anchored `BOTTOMRIGHT` is likely to be perfectly readable and strictly more
useful. That is one toggle away, and it is the user's call to make with the
frame in front of them rather than mine to make in a plan.

---

## Design

### One placement helper for both strings

Today the two strings are placed by two different hardcoded rules, and one of
them is wrong:

```lua
-- Elements/Auras.lua:517  — outside the icon, fixed
button.duration:SetPoint("TOP", button, "BOTTOM", 0, -1)

-- Elements/Auras.lua:529  — inside the icon, fixed inset
button.count:SetPoint(cfg.stackCorner, button, cfg.stackCorner, -1, 1)
```

The second is a latent bug independent of this request. The `(-1, 1)` inset
points inward **only for `BOTTOMRIGHT`**. Pick `TOPLEFT` from the existing
dropdown and the text is pushed left and up, off the icon entirely. Nobody has
hit it because nobody has changed the corner.

Replace both with one local in `Elements/Auras.lua`:

```lua
-- Which way is "inward" from each of the nine points. A positive inset always
-- moves the text onto the icon, whichever corner it is anchored to -- which is
-- what the old fixed (-1, 1) got right for BOTTOMRIGHT and wrong for the rest.
local INSET = {
    TOPLEFT     = {  1, -1 }, TOP    = { 0, -1 }, TOPRIGHT    = { -1, -1 },
    LEFT        = {  1,  0 }, CENTER = { 0,  0 }, RIGHT       = { -1,  0 },
    BOTTOMLEFT  = {  1,  1 }, BOTTOM = { 0,  1 }, BOTTOMRIGHT = { -1,  1 },
}

local function placeAuraText(fontString, button, anchor, dx, dy)
    fontString:ClearAllPoints()

    if anchor == "ABOVE" then
        fontString:SetPoint("BOTTOM", button, "TOP", dx or 0, (dy or 0) + 1)
    elseif anchor == "BELOW" then
        fontString:SetPoint("TOP", button, "BOTTOM", dx or 0, (dy or 0) - 1)
    else
        local point = INSET[anchor] and anchor or "BOTTOMRIGHT"
        local sx, sy = INSET[point][1], INSET[point][2]
        fontString:SetPoint(point, button, point, sx + (dx or 0), sy + (dy or 0))
    end
end
```

`dx`/`dy` are plain screen-space nudges on top of a 1px inset, not
direction-flipped — a slider that moves text right should move it right at every
anchor.

### Why `ABOVE` and `BELOW` survive the nine points

They are the only placements that do not cover the icon art, and `BELOW` is what
duration text does today. Dropping them would silently relocate the text for
anyone running with duration text on. They cost two branches.

Note for whoever configures it: `BELOW` on a multi-row group puts the text on
the next row's icons, which is why it is not the new default.

### Defaults

| Key | Now | New | Why |
|---|---|---|---|
| `showStacks` | `true` | `false` | The request |
| `showDurationText` | `false` | `false` | Already correct |
| `stackSize` | `11` | `8` | ~40% of a 20px icon's height instead of 55% |
| `durationSize` | `10` | `8` | Match |
| `stackCorner` | `BOTTOMRIGHT` | `BOTTOMRIGHT` | Unchanged; the existing key is reused as the stack anchor, no rename |
| `stackX`, `stackY` | — | `0`, `0` | New |
| `durationAnchor` | — | `CENTER` | New. The legible place for a timer, and where every aura addon puts one |
| `durationX`, `durationY` | — | `0`, `0` | New |

`durationAnchor` defaulting to `CENTER` rather than `BELOW` is a deliberate
break with current behaviour. It is the placement the request asks for ("where
on the buff icon to anchor it" — *on* the icon), and the migration below keeps
existing profiles on `BELOW` so nothing moves under anyone.

### Options

Extend the *Timers and stacks* block in `Config/Options_Auras.lua` (orders
40–49, currently full). Renumber to 40–56 and add, per group:

* `durationAnchor` — `select`, values `ns.Anchoring:PointValues()` plus `ABOVE`
  and `BELOW`, hidden unless `showDurationText`.
* `durationX`, `durationY` — `range`, −20 to 20, same hide rule.
* `stackX`, `stackY` — `range`, −20 to 20, hidden unless `showStacks`.

`stackCorner` keeps its key and gains the same two extra values, so the two
strings are configured identically. Retitle it `L["Stack anchor"]` since it is
no longer corners-only.

---

## Files

| File | Change |
|---|---|
| `Elements/Auras.lua` | `INSET` table and `placeAuraText`; both `SetPoint` calls in `applyButton` (`:517`, `:529`) route through it |
| `Core/Defaults.lua` | `auraGroup` (`:160-168`): flip `showStacks`, drop both sizes to 8, add five new keys. Bump `SCHEMA_VERSION` 13 → 14 (`:29`) |
| `Core/Migrate.lua` | `steps[13]`, below |
| `Config/Options_Auras.lua` | Five new controls, `stackCorner` gains two values and a new label, orders renumbered |
| `Core/Locale.lua` | New strings — anchor label, offset labels, the two extra anchor values |
| `Tests/tests.lua` | `testAuraTextPlacement()` |
| `Documents/SPEC.md` | FR-5.5 / FR-5.6 note that placement is a nine-point anchor plus offsets, and that both overlays ship off |

---

## Schema and migration

**Bump to 14.** The five added keys are free — `Defaults:EnsureProfile` fills
them — but three changed default *values* are not, and AceDB has already written
the old ones into the user's profile. Changing `Core/Defaults.lua` alone would
do nothing for the frame in the screenshot.

`steps[13]`, following the rule `raiseTargetBuffs` established at
`Core/Migrate.lua:236`: **only the exact untouched default moves.**

```lua
--- 13 -> 14. Stack counts shipped on at 11px, which on a 20px icon covers the
-- art (Plan 13). They now ship off, and both overlays ship at 8px.
--
-- "Untouched" is the whole tuple, not the toggle alone: showStacks == true is
-- also what a deliberate choice looks like, but showStacks == true AND
-- stackSize == 11 AND stackCorner == "BOTTOMRIGHT" is the shipped default and
-- nothing else.
local function quietAuraText(profile)
    for _, u in pairs(profile.units or {}) do
        for _, key in ipairs({ "buffs", "debuffs" }) do
            local g = u.auras and u.auras[key]
            if type(g) == "table" then
                if g.showStacks == true and g.stackSize == 11
                    and g.stackCorner == "BOTTOMRIGHT" then
                    g.showStacks, g.stackSize = false, 8
                end
                -- Duration text shipped OFF, so a profile with it on set it
                -- deliberately. Leave the toggle; only rehome the placement,
                -- which had no setting to have chosen before now.
                if g.durationSize == 10 then g.durationSize = 8 end
                if g.showDurationText and g.durationAnchor == nil then
                    g.durationAnchor = "BELOW"
                end
            end
        end
    end
    return profile
end
```

Two consequences worth being explicit about:

* **A profile that turned duration text on keeps it on.** The shipped default
  was already `false`, so `true` can only be a deliberate choice, and the
  established rule does not overwrite those. If those are the numbers on screen,
  the fix is the one toggle plus the new size — not something the migration can
  or should decide.
* **`durationAnchor` is pinned to `BELOW` for anyone already using it**, so the
  new `CENTER` default applies to new profiles only and no existing frame
  rearranges itself on login.

Steps run before `EnsureProfile` (`Core/Migrate.lua:39-44`), so `durationAnchor`
is reliably `nil` at that point for every pre-14 profile — that is what makes
the `== nil` test a valid "has never had this setting" probe.

---

## Tests

The existing suite asserts sizes, borders, filtering and sort order
(`Tests/tests.lua:1389-1460`) and **nothing at all about where either string
sits**. That gap is exactly why an unreadable default shipped: the stack
overlay was tested for content, never for footprint.

`testAuraTextPlacement()`:

* Each of the nine anchors places the string at that point on the button, with
  the inset pointing inward — the `TOPLEFT` case is the regression test for the
  `(-1, 1)` bug, and it must land on the icon, not off it.
* `ABOVE` and `BELOW` place relative to the button's outside edges.
* `durationX`/`durationY` shift the result by exactly that many pixels, in the
  same direction, at `TOPLEFT` and at `BOTTOMRIGHT`.
* An unknown anchor value falls back to `BOTTOMRIGHT` rather than erroring.
* Defaults: a fresh profile has `showStacks == false` and
  `showDurationText == false`, and neither font string is shown after a refresh.
* Migration: a profile at 13 with the shipped stack tuple comes out with stacks
  off at 8px; one with `stackSize = 16` keeps `showStacks == true` and `16`; one
  with `showDurationText = true` keeps it true and gains
  `durationAnchor == "BELOW"`.

The stub records `SetPoint` arguments already — the border and size assertions
at `Tests/tests.lua:1455` read `__color` and `GetWidth()` off stubbed objects —
so no harness work is needed beyond reading back the recorded points.

---

## Risks

| Risk | Handling |
|---|---|
| **The numbers turn out to be duration text after all** | Costs nothing. Both layers get the same treatment, and the migration deliberately leaves a deliberately-set toggle alone. Confirm with the 30-second check above before starting, so the plan's claim is settled rather than assumed |
| **Turning stacks off loses information the user wants** | Flagged above with a recommendation. One toggle to reverse, and the new 8px default means reversing it produces something legible |
| **The migration overwrites a considered choice** | Only the full shipped tuple matches. A user who changed the size, the corner, or the toggle keeps all three |
| **`CENTER` text is unreadable over a busy icon** | `OUTLINE` is already the default flag and shadow is on (`ns:SetFont`, `Core/Core.lua:206`). If it is still poor in game, `BOTTOM` at 8px is the fallback and it is a default change, not a code change |
| **Renumbering the options block breaks the layout** | Orders are local to the group's `args` table; the header at order 40 and the next header at 50 are the only fixed points. Move the sorting header to 60 |

---

## Deferred

**Scale text with icon size.** A fixed 8px is right for a 20px icon and small
for a 32px one — and own auras already render at 1.4× (`ownSizeMultiplier`), so
a fixed size makes own and others' icons visibly inconsistent *within one
group*. An `auto` size mode taking a fraction of `buttonSize` would fix both.
Out of scope here; it is a fourth setting and a second sizing path, and the
explicit ask was to keep this small.

---

## Estimate

| Piece | Hours |
|---|---|
| Confirm which overlay, in game | 0.1 |
| `placeAuraText` + wiring both call sites | 0.75 |
| Defaults, migration step | 0.5 |
| Options and locale | 0.75 |
| `testAuraTextPlacement` | 1.0 |
| **Total** | **~3** |
