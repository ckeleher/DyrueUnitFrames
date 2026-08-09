# Plan 18 — Portrait Background

**Status:** Implemented, on `Plan-7-portrait-column` alongside Plan 7 rather than
on a branch of its own. Two of this plan's recommendations were overruled before
work started — see *Implementation notes* at the foot of this document, which is
the authoritative record where the two disagree.
**Created:** 8 August 2026
**Branch:** `Plan-7-portrait-column` (shared with Plan 7, by decision)
**Builds on:** [Plan 7](Plan_7_PortraitSizingAndClicks.md) — its `place()` and
`Portrait.Resolve` own the portrait's geometry, and this background has to share
them exactly. Plan 7 is implemented but **not yet merged to `main`**; branch this
off `Plan-7-portrait-column`, or wait for it to land.

---

## Request

> the 3D  portrait needs a configurable/toggleable background, defaulting to black

---

## Interpretation

A 3D model frame renders transparent wherever there is no geometry, so a 3D
portrait shows the game world — or whatever is behind the frame — through the
space around the model. That reads as a floating head rather than as a portrait.
A solid fill behind it is what makes it a portrait.

Taking the request literally: a toggle, a color, defaulting to on and black.

### The one place a reading has to be chosen

The request says **3D**. But the 2D portrait has the same transparent-corner
problem, and it is already documented in this codebase:

> The game's portrait art is round: the corners of the texture are transparent.
> — `Elements/Portrait.lua`

`shape = "square"` crops to the inscribed square, which is fully opaque, so no
background shows. `shape = "native"` keeps the round art with its transparent
corners, where a background would show exactly as it does behind a model.

**Recommendation: one background setting that applies to whichever widget is
showing.** It costs nothing extra — the same texture, sized and placed by the
same code — and it makes `native` shape usable instead of an odd-looking
option. It also means the 3D-model-fails-and-falls-back-to-2D path (FR-7.4)
does not lose its background halfway through.

The alternative is a `mode == "3d"` guard on the whole feature. That is a
narrower reading of the request and one line of code, but it leaves a real gap
for no benefit, and someone will ask for it in `native` mode later.

Nothing visible changes for existing 2D users either way: `square` is the
shipped shape and it crops the transparency off.

---

## Design

### Where the texture goes

`Core/Core.lua`'s draw-order comment already states the governing rule:

> Frame level beats draw layer: anything a child frame draws appears above
> EVERY layer of its parent.

The 3D model is a `PlayerModel` — **a child frame** of `frame.content`. So any
texture on `frame.content` is guaranteed to be behind it, with no frame-level
arithmetic and nothing to get wrong. That is the whole mechanism.

```lua
el.background = frame.content:CreateTexture(nil, "BACKGROUND", nil, 1)
```

Sublevels have to be renumbered by one, because there are now three things in
the `BACKGROUND` layer of `frame.content` and two of them can overlap:

| Sublevel | What | Today | Proposed |
|---|---|---|---|
| 0 | `frame.background`, the frame backdrop | 0 | 0 |
| 1 | **portrait background** | — | **1** |
| 2 | portrait 2D texture | 1 | **2** |

Leaving the portrait background at 0 would tie it with the frame backdrop, and
ties in a draw layer resolve by creation order — which is exactly the kind of
thing that works until an element is built in a different order and then breaks
with no error. One texture moves from sublevel 1 to 2; nothing else is affected.

### Geometry

Plan 7 made `place(frame, el, cfg, widget)` a function of a widget, precisely so
the texture and the lazily created model could share it. The background is a
third caller:

```lua
place(frame, el, cfg, el.background)
```

That gets it the right size, corner and placement in all three modes
(`column`, `overlay`, `detached`) for free, including the bar-stack height and
the `square` toggle. No new geometry code at all.

`SetGeometry` gains one line; `Layout`, `Update` and `Disable` gain a show/hide
alongside the existing two widgets.

### Color and opacity

```lua
el.background:SetColorTexture(Colors:Unpack(cfg.background.color))
```

`place()` then applies the portrait's own `cfg.alpha` on top, so the swatch's
alpha and the portrait opacity slider multiply. That is the right relationship:
fading the portrait should fade what is behind it too, or the background is left
floating at full strength over a ghost.

### Config

New keys under the existing `portrait` table, so they inherit its options tab
and its `hidden = isNone` gating:

```lua
portrait = {
    ...
    background = {
        enabled = true,
        color = color(0, 0, 0, 1),     -- Defaults.Color
    },
},
```

An inline `Background` group in the portrait tab, matching the frame's own
Layout → Background group exactly — `Options.Color(..., { hasAlpha = true })`
is already the established pattern there and gives the alpha channel without a
separate opacity slider.

---

## Files

| File | Change |
|---|---|
| `Elements/Portrait.lua` | `el.background` texture, placed through `place()`, shown/hidden with the portrait, colored in `Layout`; 2D texture sublevel 1 → 2 |
| `Core/Defaults.lua` | `portrait.background = { enabled, color }` |
| `Config/Options_Layout.lua` | Inline Background group in `portraitGroup` |
| `Tests/tests.lua` | New assertions |

---

## Schema and migration

**Neither.** These are new keys with no stored value changing, so
`Defaults:EnsureProfile` fills them on load and there is nothing to migrate —
the same shape as Plan 11. **No schema bump**, and the existing
`heal/added keys without a schema bump` assertion is the precedent to follow:
pin the version so a later bump made for some other reason cannot claim this
plan needed one.

Worth stating because the default is `enabled = true`, which *looks* like a
changed default. It is not: the key did not exist, so no profile carries a
contrary value, and portraits ship `mode = "none"` so nothing renders until
someone turns one on deliberately.

---

## Tests

- Background ships enabled and black, with full alpha.
- The texture exists on `frame.content`, not on the model — that is what puts it
  behind a child frame.
- Sublevel ordering: background below the 2D portrait art, both above the frame
  backdrop. Assert the sublevels, since the harness cannot render.
- Geometry matches the portrait's resolved rect in all three placements, and
  tracks the bar stack the same way (change the power bar height, background
  follows).
- Toggling it off hides it; toggling back shows it.
- Color round-trips through the swatch, alpha included.
- Hidden when `mode == "none"`, and when the element is disabled.
- Still shown on the 3D → 2D fallback path (FR-7.4), which is the case a
  `mode == "3d"` guard would have got wrong.
- Schema version unchanged.

---

## Risks

| Risk | Handling |
|---|---|
| A `PlayerModel` renders its own opaque backdrop, so the texture never shows | The request is itself evidence that it does not — a model with an opaque background would not need one adding. Verify in game; it is the same one-minute check as the R11 rows already in `COMPAT_FINDINGS.md` §0.8 |
| If it *does*, this approach cannot work at all | Fallback is `model:SetFogColor(r, g, b)` with `SetFogNear(0)`, which tints the model's own backdrop. Rejected as the primary approach because fog also tints the model itself at distance, so "black background" would come with a darkened portrait — a worse result reached by a stranger route |
| Draw-order tie with the frame backdrop | Sublevels renumbered so all three are explicit rather than creation-order dependent |
| Turning it on changes existing 2D portraits | Only in `native` shape. `square` is the shipped default and crops the transparency off, so nothing moves for anyone who has not chosen otherwise |
| Plan 7 is unmerged, and this shares `place()` with it | Branch off `Plan-7-portrait-column` rather than `main`. Building this on `main` means writing the geometry twice and merging it by hand |

---

## Estimate

1–1.5 hours. The mechanism is one texture on a frame that already exists, and
Plan 7's `place()` means there is no new geometry to write. Most of the time is
the tests and the sublevel renumber.

---

## Implementation notes

Written after the work. Where this section and the plan above disagree, this
section is what was built.

### The three decisions taken before starting

| Question | Answer | Effect |
|---|---|---|
| 2D `native` shape as well, or 3D only? | **3D only** — plan's recommendation overruled | A mode gate on the whole feature |
| Own branch, or on top of Plan 7? | **On the Plan 7 branch** — plan's recommendation overruled | One PR carries both plans |
| Start now, or test Plan 7 in game first? | **Start now** | Neither the R11 model-background question nor the Plan 7 in-game checks are answered yet |

### 3D only, gated on the *mode*

The gate is `cfg.mode == "3d"`, not "the model is what is currently rendering".
Those are not the same thing, and the difference is visible: a model that is
briefly unavailable — out of range, not yet seen — falls back to the 2D texture
per §FR-7.4, and a background keyed on the rendering widget would strobe off and
on with it. The user configured a 3D portrait; a transient failure does not make
it a 2D portrait.

There is a test for exactly this (`portraitbg/survives the 2D fallback`), and it
was verified to fail under the other reading.

The consequence the plan warned about still stands and was accepted: a 2D
portrait in `native` shape keeps its transparent corners with no way to fill
them. `square`, the shipped shape, crops them off, so this is invisible unless
someone has deliberately chosen `native`.

### Draw order is explicit now

The sublevel renumber went in as planned — frame backdrop 0, portrait background
1, portrait art 2 — and `Tests/wowstub.lua` grew `GetDrawLayer`/`SetDrawLayer`
so the ordering is asserted rather than assumed. It was previously a no-op in
the stub, which is why nothing had ever checked it.

### What the plan got right

`place()` took the background as a third caller with no changes at all, so the
background inherits the placement, the bar-stack height and the `square` toggle
for free. That was the main bet of building this on top of Plan 7 rather than on
`main`, and it paid.

### Still unverified

The premise: that a `PlayerModel` renders transparent rather than drawing its own
opaque backdrop. If it does not, none of this shows and the fallback is
`SetFogColor` — with the cost the risk table describes. Nothing in the headless
suite can answer it. Recorded in `Documents/COMPAT_FINDINGS.md` §0.8 with the
other R11 rows.

`SPEC.md` gained **§FR-7.7** for the feature, including the mode-gate reasoning.

**Test suite:** 1004 → 1031 assertions, all four passes green, plus `luacheck`
and `refcheck` clean. The sublevel ordering, the shared geometry and the
fallback behavior were each verified to fail with their fix reverted.
