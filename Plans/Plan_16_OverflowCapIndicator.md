# Plan 16 — Overflow Cap Indicator

**Status:** Not started
**Created:** 7 August 2026
**Branch:** `Plan-16-overflow-cap-indicator`
**Depends on:** Plan 11 (`Plan-11-predictive-healing`), which is **not yet merged**

---

## Request

> when the overflow is capped (i.e. it has gone as far out from the health bar as
> it's allowed to), I want some indicator on the far edge of the overflow, maybe
> a configurable highlight gradient

---

## Dependency, stated first because it controls sequencing

This modifies `Elements/HealPrediction.lua`, which exists only on the unmerged
`Plan-11-predictive-healing` branch. There is no overflow on `main` to cap.

So either Plan 11 merges first and this branches from `main` afterwards, or this
branches from `Plan-11-predictive-healing` and the two merge together. **Prefer
the first.** Plan 11 is 1400 lines that have never run in a live client; stacking
an unreviewed feature on top of an unverified one means a single bad merge to
untangle when something misbehaves in a raid. The cap indicator is small and
loses nothing by waiting.

---

## Interpretation

### What "capped" means in the existing arithmetic

`element.Place` in `Elements/HealPrediction.lua` walks a cursor rightward:

```
cursor = current * scale          -- where the health fill ends
limit  = overflow and width * (1 + overflowAmount) or width
cursor = segment(direct, …, cursor, direct * scale, limit, inverse)
         segment(hot,    …, cursor, hot    * scale, limit, inverse)
```

`segment()` already returns `cursor + width` — the **full** width, not the drawn
width, deliberately, so a clipped first segment cannot leave room for the second.
That return is exactly the quantity this feature needs, and the second call
currently discards it. Capped is therefore one comparison:

```lua
local predictedEnd = <return of the second segment call>
local capped = predictedEnd > limit
```

No new measurement, no second pass over the geometry. That the value already
exists and is already correct is the reason this plan is small.

### The ambiguity that changes the work: does this apply when overflow is off?

With `overflow = false` the limit is the bar's own end, and clipping still
happens — so "capped" is literally true. **Ship it tied to `overflow` being on
anyway**, and here is why the literal reading is the wrong one:

At full health with overflow off, *every* prediction of any size is capped,
because the cursor already sits at `width` and there is nowhere left to draw. The
indicator would be permanently lit on every topped-up target in the party, which
is precisely the visual noise someone turns overflow off to avoid. With overflow
**on** the degenerate case does not arise: at full health a small heal draws
inside the overflow band and is not capped until it genuinely exceeds the
allowance, which is the state the request describes.

If that reading is wrong, it is a one-condition change (`capped` stops consulting
`cfg.overflow`), not a redesign. Flagged rather than silently chosen.

### "maybe a configurable highlight gradient"

Taken as written, and it is the right shape: a band at the far edge of the drawn
extent, at full strength on the edge itself and fading to nothing inward. That
reads as "there is more heal here than fits", which is the information being
conveyed. A hard-edged line would read as a boundary marker — a different claim.

"Configurable" is taken as **color, width and peak opacity**, plus its own
enable toggle. Not a configurable *direction* or gradient curve; those are knobs
nobody sets twice.

### Naming

`Elements/Highlight.lua` already exists and means something else — the
target/mouseover frame highlight. The word "highlight" is spoken for. Call this
the **cap indicator** throughout: config block `cap`, texture `el.cap`, strings
"Overflow cap".

---

## Design

### Where the code lives

Entirely inside the two Plan 11 files. No new module: this is a third texture on
a geometry pass that already computes everything it needs.

| File | What changes |
|---|---|
| `Elements/HealPrediction.lua` | A third texture, the capped test, the cap geometry |
| `Systems/HealPrediction.lua` | Nothing |

The element keeps its single `configKey = "healPrediction"`, so the cap shares
the prediction's circuit breaker. That is correct: if the cap geometry throws,
the honest response is to take the whole speculative prediction display off for
the session, not to keep drawing a prediction whose "there is more" marker is
known to be broken.

### The texture

Created in `ensureTextures` alongside the other two:

```lua
el.cap = bar:CreateTexture(nil, "ARTWORK", nil, 3)
```

Sublevel 3 — above the two segments at 2, still below the OVERLAY layer that
`BarSweep`'s lines and the text engine use. It is a child of the health bar for
the reasons already recorded in that file's header: it inherits the bar's alpha,
moves with its geometry, and hides with it without bookkeeping.

### Geometry

Anchored to the limit and growing **inward**, opposite to how the segments grow:

```
capWidth = min(cfg.cap.width, limit - cursorAtHealthFill)
x1 = limit                    -- the far edge, where the drawn extent stopped
x0 = limit - capWidth         -- fading out this far back
```

The clamp matters. With a narrow overflow allowance — say 4px of band and a 12px
cap width — an unclamped gradient reaches back over the prediction segments and
onto the health fill itself, where it reads as a health bar artifact rather than
as an edge marker. Clamping to the health fill's end keeps it inside the region
that is actually prediction.

`inverseFill` mirrors exactly as `segment()` does: anchor `TOPRIGHT` and extend
leftward, with the gradient's two color stops swapped so the strong end still
lands on the outer edge.

### The gradient, and the API question that decides it

**Nothing in this addon has ever called `SetGradient`.** A survey of the
non-library source finds `SetColorTexture` and `SetVertexColor` only, and
`Tests/wowstub.lua` implements neither gradient method. This is untested ground
and it is version-sensitive:

| API | Era |
|---|---|
| `Texture:SetGradientAlpha(orientation, r1,g1,b1,a1, r2,g2,b2,a2)` | Pre-10.0 |
| `Texture:SetGradient(orientation, minColor, maxColor)` — color **objects** | 10.0 onward |

These clients run the modern shared code — that is the established finding behind
`C_UnitAuras` and the retired `UNIT_COMBO_POINTS` — so `SetGradient` with
`CreateColor()` objects is the likely one and `SetGradientAlpha` likely absent.
**Likely is not verified**, and this file's own rule is that an assumption gets a
probe rather than trust:

```lua
Compat.hasSetGradient      = <method present on a scratch texture>
Compat.hasSetGradientAlpha = <same>
function Compat.SetGradient(texture, orientation, r1,g1,b1,a1, r2,g2,b2,a2)
```

One wrapper, both signatures, surfaced through `Compat.Describe` so `/duf compat`
answers which path is live.

**Fallback when neither exists: a solid band at half the configured peak alpha.**
One texture either way, no second geometry path, and it still marks the edge —
the indicator degrades to a plainer version of itself rather than vanishing. The
alternative considered and rejected was a stepped stack of four textures faking a
gradient: more code, more state, to approximate something the client is telling
us it cannot do.

### What it costs at runtime

Nothing measurable. No new events, no ticker, no new derived state — the capped
test is one float comparison on a value the geometry already produced, inside an
update that only runs when a prediction is non-zero.

---

## Files

| File | Change |
|---|---|
| `Elements/HealPrediction.lua` | Third texture in `ensureTextures`; color/width applied in `Layout`; `Clear` hides it; `Place` computes `capped` from the second `segment()` return and places or hides the band |
| `Core/Compat.lua` | `hasSetGradient` / `hasSetGradientAlpha` probes, `Compat.SetGradient` wrapper, both surfaced through `Compat.Describe` |
| `Core/Defaults.lua` | `cap` sub-block inside `healPrediction` |
| `Config/Options_Layout.lua` | Four controls appended to `healPredictionArgs`, each disabled unless prediction **and** overflow are on |
| `Core/Locale.lua` | New user-facing strings (§11.4) |
| `Documents/COMPAT_FINDINGS.md` | API-survey rows for the two gradient methods |
| `Tests/wowstub.lua` | `SetGradient` / `SetGradientAlpha` on the texture stub, recording orientation and both color stops for assertion |
| `Tests/tests.lua` | Cap assertions inside the existing `testHealPrediction()` |

---

## Schema and migration

**No `SCHEMA_VERSION` bump.** This adds keys and changes no stored value, so
`Defaults:EnsureProfile` deep-fills `cap` into every profile that lacks it — the
same free path Plan 11 itself took.

Note for whoever implements this: Plan 11's suite pins `SCHEMA_VERSION` to prove
it adds no bump of its own, and that pin is an absolute number that has already
gone stale once during a rebase. If main has moved again, re-pin it after
checking `Core/Defaults.lua` against main rather than assuming this plan caused
the difference.

Defaults, and why:

| Key | Default | Reason |
|---|---|---|
| `cap.enabled` | `true` | Asked for. It is self-limiting — it can only appear in a state that is already unusual |
| `cap.color` | white | Reads as "clipped here" without competing with the direct green or the HoT blue, and stays legible over either |
| `cap.width` | `8` | About a finger's width at default bar sizes; wide enough to read as a gradient rather than a line, narrow enough to clamp rarely |
| `cap.alpha` | `0.9` | Near-opaque at the outer edge. This is the one thing on the bar that means "you are not seeing all of it", so it should not be subtle |

---

## Tests

Extends `testHealPrediction()` rather than adding a suite — same feature, same
setup, and the geometry helpers are already there.

**The capped condition**
* Prediction ending short of the limit → cap hidden.
* Direct alone overruns the limit → cap shown.
* Direct fits, direct + HoT overruns → cap shown. This is the case the "advance
  by full width" rule in `segment()` exists to make correct, and it is the one a
  naive implementation reading drawn widths would get wrong.
* Prediction ending **exactly** at the limit → cap hidden. Pins `>` rather than
  `>=`, so a heal that fits perfectly is not reported as clipped.
* Overflow off, prediction clipped at the bar's end → cap hidden. This is the
  interpretation above, asserted so it stays a decision rather than drifting.

**Geometry**
* Cap's outer edge sits at `limit`, not at the bar's end, whenever overflow is on.
* Width equals `cap.width` when the band is wide enough to hold it.
* Width clamps to the health fill's end when it is not — asserted with a
  deliberately narrow overflow and a wide cap.
* `inverseFill` mirrors the anchor and swaps the gradient stops.

**Gradient plumbing**
* The strong stop carries `cap.color` at `cap.alpha`; the weak stop is the same
  color at zero alpha.
* With both gradient methods absent from the stub, the cap still draws as a solid
  band at half alpha. Run this by removing the methods in the test, the way pass 3
  removes `C_UnitAuras` — the fallback is the whole point of the wrapper and an
  untested fallback is a fallback that does not work.

**Gap this exposes:** the suite has never asserted anything about a texture's
gradient because nothing has ever set one. The stub work here is that coverage,
and it is what makes the fallback assertion possible at all.

---

## Risks

| Risk | Handling |
|---|---|
| **Neither gradient API exists on these clients** | The solid-band fallback, tested. The feature degrades in appearance and not in meaning |
| **`SetGradient`'s color-object signature differs from what is assumed** | Contained in `Compat.SetGradient`, which is the only caller. Same containment bet §5.5 makes everywhere else |
| **The cap reads as part of the health bar rather than as a marker** | Clamped to the prediction region so it never touches the fill, and drawn above both segments. If it still reads wrong the answer is the width slider |
| **Permanently-lit indicator** | The overflow-off exclusion above is exactly this risk, handled by design rather than by a warning |
| **Overhang plus cap reaches further into a neighbouring party frame** | It does not: the cap grows inward from the limit, so it adds nothing to the overhang's extent. This feature cannot make the collision Plan 11 documented any worse |

---

## Estimate

| Piece | Hours |
|---|---|
| Element: texture, capped test, cap geometry, inverse mirroring | 1–1.5 |
| `Compat.SetGradient` wrapper and probes | 0.5 |
| Defaults, Options, Locale | 0.5 |
| Stub gradient support + assertions | 1–1.5 |
| COMPAT_FINDINGS rows | 0.25 |
| **Total** | **3.25–4.25** |

Small because the hard part — knowing where the prediction stopped and why — was
already solved by Plan 11's cursor arithmetic. Most of the hours are the stub
work that lets the gradient be asserted rather than eyeballed.
