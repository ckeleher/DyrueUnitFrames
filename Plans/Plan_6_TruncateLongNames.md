# Plan 6 — Truncate Long Names

**Status:** Not started
**Created:** 2 August 2026
**Branch:** `first`

---

## Request

> Currently, if the target has a very long name, the text overlaps with the
> numbers on the right. I want the text to truncate

---

## Current state

`Elements/Text.lua` already has the machinery:

```lua
fontString:SetWordWrap(false)
if (text.maxWidth or 0) > 0 then
    fontString:SetWidth(text.maxWidth)
else
    fontString:SetWidth(0)
end
```

`maxWidth` defaults to `0`, meaning unbounded, so a long name grows right until
it runs under the health text. The control exists and is exposed in the options;
it is the *default* that is wrong.

---

## Why a fixed pixel default is not the answer

Setting `maxWidth = 120` on the name would fix the target frame and break
everything else — frame widths are per-unit and user-editable (`width` ranges
40–2000 in `Options.RANGES`). A number that fits a 220px player frame is wrong on
a 130px target-of-target and wasteful on a 400px one.

The name's available space is genuinely dynamic: it is *the distance between the
name's anchor and whatever text is coming the other way*.

---

## Design

Add a `maxWidthMode` beside the existing `maxWidth`:

| Mode | Meaning |
|---|---|
| `none` | Unbounded. Current behavior. |
| `pixels` | Use `maxWidth` exactly. Current behavior when `maxWidth > 0`. |
| `percent` | `maxWidth` is a percentage of the anchor widget's width. |
| `fit` | Computed at layout: the gap to the nearest opposing text. |

Default the shipped **name** texts to `percent` at `55`, and leave every other
text at `none`.

`percent` is the right default rather than `fit` because it is predictable, it
needs no cross-element reasoning, and it degrades sensibly at any frame width.
`fit` is the nicer answer in principle and is worth having, but it needs care —
see below.

### Computing `percent`

In `element.Layout`, after the anchor widget is resolved:

```lua
local basis = widget:GetWidth()      -- the health bar, usually
fontString:SetWidth(basis * text.maxWidth / 100)
```

The anchor widget's width is known at layout time because `LayoutBars` runs
before `Text.Layout` is re-invoked from it, and both re-run whenever the frame
is resized.

### Computing `fit`

Look through the unit's other **enabled** texts for one anchored to the same
widget from the opposing side (`point` containing `RIGHT` when ours contains
`LEFT`, and vice versa), and use:

```
basis - |our x| - |their x| - padding
```

Two caveats that make this the second-phase option rather than the default:

- It cannot know how wide the *other* text will render, only where it is
  anchored. A long `[hp:cur:short] / [hp:max:short]` still eats into the gap.
- It creates an ordering dependency between text elements, which the element
  system otherwise does not have.

### Truncation appearance

A WoW `FontString` with a fixed width and word wrap off clips at the boundary.
It does not add an ellipsis. If a visible "…" is wanted, that has to be done in
the tag layer — `Tags:Truncate` already exists (it backs `[name:short:N]`) but
works in characters, not pixels.

**Recommendation:** ship with clipping, which is what the request asks for, and
treat an ellipsis as a follow-up. Doing it properly means measuring rendered
width and trimming character by character, which is a per-update string
operation on a path that currently caches specifically to avoid that
(`Elements/Text.lua` skips `SetText` when unchanged).

A cheaper middle ground worth considering: `[name:short:N]` is already available
and the user can put it in the format string today.

---

## Migration

Needed, and narrow. Existing profiles have the name texts at `maxWidth = 0`.

Schema 9, on each unit's `texts` list: where a text's `format` is exactly
`[name]` and `maxWidth == 0` and `maxWidthMode` is absent, set
`maxWidthMode = "percent"` and `maxWidth = 55`.

Keying on the exact default format string means an edited name text is left
alone. A user who has already set a pixel width keeps it, because `maxWidth`
would not be 0.

---

## Files

| File | Change |
|---|---|
| `Elements/Text.lua` | `maxWidthMode` handling in `Layout` |
| `Core/Defaults.lua` | `maxWidthMode` key; name texts default to percent; schema to 9 |
| `Core/Migrate.lua` | Step `[8]` |
| `Config/Options_Text.lua` | Mode select; relabel the width control per mode |
| `Tests/tests.lua` | New assertions |

---

## Tests

- Name texts ship at `percent` / 55; other texts at `none`.
- `none` leaves the font string unbounded (`GetWidth() == 0`).
- `pixels` sets exactly the configured width.
- `percent` sets the anchor widget's width × percent, and **recomputes when the
  frame is resized** — the case a fixed default gets wrong.
- `fit`, if built: correct gap with an opposing text, falls back to `percent`
  when there is none.
- Migration converts an untouched name text and leaves an edited one alone.
- The stub models `SetWidth`/`GetWidth` already, so all of this is reachable.

---

## Risks

| Risk | Handling |
|---|---|
| Clipping with no ellipsis looks abrupt | It is what was asked for; ellipsis noted as a follow-up with its cost stated |
| 55% is wrong for some frames | It is a slider, and `pixels` is still there |
| `percent` of a hidden anchor widget | Bar-anchored text already hides with its bar (`ead8492`), so this cannot be reached |

---

## Estimate

1.5–2 hours for `none`/`pixels`/`percent` plus migration and tests. `fit` adds
another 1–2 hours and should be a separate pass, if wanted at all.
