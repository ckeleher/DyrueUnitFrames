# Plan 6 — Truncate Long Names

**Status:** Implemented on `Plan-6-truncate-long-names`. Headless suite green
(801 assertions, 37 of them new); **not yet seen in a client.**
**Created:** 2 August 2026
**Branch:** `Plan-6-truncate-long-names`
(The header used to read `first`, which was where the plan was *written* — see
`Skills/ArchivePlan.md` on why that field is not evidence of anything.)

---

## Request

> Currently, if the target has a very long name, the text overlaps with the
> numbers on the right. I want the text to truncate

---

## Outcome

`maxWidthMode` on every text element, with the four modes below. The shipped
name texts — player, target, target of target, pet, focus, focus target, party
1–4 and the party pets — ship on `fit`. Anything cut short ends in `...`.

Schema 15, migration step `[14]`.

## Deviations from the plan as written

Three, and the first is the substantial one.

**1. `fit` measures rendered width, and is the default. `percent` is not.**

The plan proposed `percent` at 55 as the shipped default, with `fit` as a
second-phase nicety. Worked through against the real numbers, neither of those
fixes the frame in the request:

* The target's name is anchored at `x = 32`, to clear the level text. Its
  health text is `[hp:cur:short] / [hp:max:short] [hp:perc]%`, which renders
  about 105px wide against the right edge of a 220px bar. 55% of 220 puts the
  name's right edge at 153; the numbers start at about 111. Still overlapping,
  by roughly 40px.
* `fit` **as specified** — `basis - |our x| - |their x| - padding` — gives
  `220 - 32 - 4 - 4 = 180` on that same frame, which is worse than the
  percentage. The plan's own caveat ("it cannot know how wide the other text
  will render") is not a rough edge here; it is the whole problem, because the
  opposing text is anchored at the far edge and renders inward.

So `fit` measures the neighbor's **actual** rendered width with
`GetStringWidth`, which gives 75px — the correct answer — and follows it as the
value changes, the frame is resized, or the format is edited. `percent` is
still built, and is the right choice for anyone who wants a limit that does not
move; it is simply not what the names ship on.

**2. Truncation appends an ellipsis rather than relying on clipping.**

The plan recommended shipping with bare clipping and treating an ellipsis as a
follow-up, on the grounds that measuring per update is expensive on a path that
caches to avoid exactly that. Measuring turned out to be required anyway for
`fit`, so the marginal cost of the ellipsis is a binary search over character
boundaries — about five probes — on the rare update where the string or its
budget actually changes.

The caching is what keeps this off the hot path, and the suite asserts it by
counting `SetText` calls: health ticking from `4.2k` to `4.1k` renders at the
same width, so the name's budget is unchanged and it is not touched at all.

`...` rather than `…`: fonts come from LibSharedMedia and are whatever the user
installed, and a missing glyph renders as a box on the exact string whose job
is to say "there is more here".

**3. The migration is wider than the plan describes, and had to be.**

The plan says "Schema 9, step `[8]`"; the live schema was already 14, so this
is 15 and step `[14]`.

More importantly, the plan describes touching only the untouched name texts.
That is not sufficient. `texts` is a user-owned **list**, and `Core/Defaults`'s
`ensure` deliberately does not descend into lists — which is what makes a
deleted text stay deleted. So a new key inside a text element reaches an
existing profile *only* from the migration, and every text has to be written,
not just the names. There is a test asserting that `EnsureProfile` cannot reach
inside a text list, so the next person to add a key here finds out from a red
suite rather than from a user.

A text that already carries a pixel width keeps it, now spelled `pixels`, which
preserves today's behavior exactly for anyone who had set one.

`maxWidth` also kept its meaning rather than being reinterpreted per mode; the
percentage lives in a separate `maxWidthPercent`. Overloading one key would
have made switching modes silently reinterpret 120px as 120%.

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
