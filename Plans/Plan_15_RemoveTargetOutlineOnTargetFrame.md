# Plan 15 — Remove The Target Outline On The Target Frame

**Status:** Implemented on `Plan-15-target-outline-option`. Headless suite green
(761 assertions); **not yet seen in a client.**
**Created:** 7 August 2026
**Branch:** `Plan-15-target-outline-option`

---

## Outcome

Both target-outline settings are gone from the target frame's Highlight group,
and `Elements/Highlight.lua` no longer draws that outline there whatever the
profile still says. Everything else about the group is untouched, on the target
frame and everywhere else.

Written after the fact rather than before — the change was asked for as work,
not as a plan. Recorded here because the plan is the durable record of what was
asked and what shipped, and this one has a user-visible consequence worth being
able to find later: **the target frame lost the white outline it has always
had.**

---

## Request

> the option "outline when this unit is your target" on the target frame seems
> pretty pointless. remove it

---

## Interpretation

"On the target frame" locates the option rather than describing the whole
feature. The reason it is pointless is specific to that frame — the target
frame *is* your target, so the condition is never false — and that reasoning
does not carry to focus, party or target-of-target, where the outline answers a
real question. So: removed from the target frame, left alone everywhere else.

The reading that would have been materially different work is "remove the
target outline from every frame". Not taken, and nothing in the request points
at it.

Second question the request does not answer directly: does the outline itself
disappear, or does it become a permanent border with no switch? Removing the
toggle while leaving the border drawn is strictly worse than the state being
complained about — an outline that cannot be turned off or recolored — so the
outline goes with the option. `Layout > Border` is the setting for a border
that is always on, with its own color and thickness, which is what the target
outline had degenerated into on this frame.

---

## Current state

`Core/Defaults.lua` ships `highlight.targetEnabled = true` for every unit
except the player, so the target frame has always drawn it. The condition in
`Elements/Highlight.lua`:

```lua
local isTarget = cfg.targetEnabled and unit and UnitExists(unit)
    and UnitIsUnit(unit, "target") and not UnitIsUnit(unit, "player")
```

On the target frame `unit` is `"target"`, so `UnitIsUnit(unit, "target")` is
true whenever the frame is shown. A 1px white border at 0.9 alpha, permanently,
described in the options as a state indicator.

The player frame is the mirror image: the `not UnitIsUnit(unit, "player")`
clause means its outline can *never* show, and the toggle is offered there
anyway. See "Not done" below.

---

## Change

**`Config/Options_Layout.lua`, `highlightGroup`.** The args table is built as a
local and the two entries are dropped for one unit:

```lua
if unitKey == "target" then
    args.targetEnabled = nil
    args.targetColor = nil
end
```

Removed rather than `hidden`, so there is no dead node in the options tree.
`hidden` is the right idiom when the control comes back under some condition —
`comboGroup` uses it — and this one never does.

**`Elements/Highlight.lua`.** One predicate, consulted in both places that read
`targetEnabled`:

```lua
local function targetOutlineApplies(frame)
    return frame ~= nil and frame.unitKey ~= "target"
end
```

`frame.unitKey` is set by `Units/Factory.lua`. It has to be a *frame* check
rather than a unit-identity check like the existing player clause, because the
unit token on this frame genuinely is your target — that is the whole point.

`IsEnabled` uses it too, not just `Update`: a target-frame profile with the
mouseover outline off and the target outline on should build no element at all
rather than build one that draws nothing.

---

## Schema and migration

**None, deliberately.** Every profile in existence carries
`highlight.targetEnabled = true` on the target frame. Two options:

1. A schema step setting it to `false`. Clears a key nothing reads, and buys a
   version bump for a value that is already inert.
2. Ignore the stored value in code, which is what shipped.

(2) also makes the option and the drawing incapable of disagreeing — the
element does not trust the config for this, so a hand-edited SavedVariables or
a profile copied from another unit cannot resurrect the outline.

The key stays in the schema for the same reason `combo` is present on every
unit: uniform shape across units is worth more than the byte.

The other migration that was considered and rejected: turning
`border.enabled = true` on the target frame to preserve its appearance.
Converting a removed setting into a different visible one, silently, is worse
than the frame simply matching every other frame — and `Layout > Border` is one
checkbox away for anyone who wants it back.

---

## Files

| File | Change |
|---|---|
| `Config/Options_Layout.lua` | `highlightGroup` builds `args` as a local; drops `targetEnabled` and `targetColor` when `unitKey == "target"` |
| `Elements/Highlight.lua` | `targetOutlineApplies` predicate, consulted in `IsEnabled` and `Update` |
| `Tests/tests.lua` | New `highlight` suite (7 assertions) |

No schema, no migration, no doc changes — `SPEC.md` and `README.md` name the
Highlight element but not its individual settings.

---

## Tests

New `highlight` suite. The half that is easy to break is the second one:

- `targetEnabled` and `targetColor` absent from the target unit's options.
- `mouseoverEnabled`, `mouseoverColor` and `thickness` still present there.
- `targetEnabled` still offered on `focus` and `party1`.
- With `targetEnabled` forced back to `true` on the target frame, the element is
  still built (for the mouseover outline) and the target outline is **not**
  shown. This is the assertion that covers every existing profile.
- A frame that merely *happens* to be your target still gets the outline:
  `stub.setUnit("focus", stub.units.target)` puts the same unit table behind
  both tokens, so the stub's `UnitIsUnit` says yes, and the focus frame's
  outline shows.
- And loses it when that stops being true.

**Gap this closes:** the suite had no coverage of the highlight element's
visibility at all — only that its textures were parented to the overlay
(`testDrawOrder`). The permanent-border behavior could not have been caught by
a test because no test looked.

---

## Risks

| Risk | Handling |
|---|---|
| The user liked the white outline on the target frame and now it is gone | Stated plainly when the change was reported, with `Layout > Border` named as the one-checkbox replacement. It is the same 1px rectangle on the same frame, from a setting that admits it is permanent |
| Someone reads `targetEnabled` on the target frame and believes it | Only the element reads it, and the element ignores it. The two comments — one in each file — point at each other |
| The same dead toggle on the player frame now looks inconsistent | Real, and left alone on purpose. See below |

---

## Not done

The player frame offers the same toggle, and `not UnitIsUnit(unit, "player")`
means it can never draw anything — a frame showing you cannot be marked as your
target. Equally pointless, one line to fix (`targetOutlineApplies` returning
false for `unitKey == "player"` as well, plus the same two `args` entries
dropped), and outside what was asked for. Raised with the user separately.

---

## Estimate

Half an hour, including the tests. Small, and the interesting part was deciding
that the outline goes with the option rather than becoming an unswitchable
border.
