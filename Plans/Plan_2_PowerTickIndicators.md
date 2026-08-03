# Plan 2 — Power Tick Indicators

**Status:** Not started
**Created:** 2 August 2026
**Branch:** `first`

---

## Request

> Add mana/energy tick indicators to power bars (including the shapeshift mana
> bar). This is essentially a progress bar towards the next time interval on
> which the player will regenerate energy or mana, except only the progressing
> edge of the status bar is visible. When shapeshifted, both the regular power
> bar and the shapeshift mana bar should show this ticking indicator. The
> indicator should be a thin white line from the top of the power bar to the
> bottom, moving from one edge of the bar to the opposite edge in a configurable
> direction, from left to right by default.

---

## The hard part: this needs a fourth ticker

`SPEC.md` §5.7 lists exactly three permitted tickers and says:

> Any proposal to add a fourth ticker should be treated as a design smell and
> argued for explicitly.

So, explicitly.

**Why an event cannot do it.** The indicator is a continuous sweep between two
regen ticks. Nothing fires between them; `UNIT_POWER_UPDATE` fires *at* the
tick, which is the moment the sweep restarts. There is no event-driven way to
animate the interval. This is the same category as the derived-unit poller: the
game does not push what we need.

**Why it is affordable.** Same discipline as the other three — it runs only
while a bar with the indicator enabled is *visible*, and it stops the instant
that stops being true. Standing in a city with the indicator off costs nothing.
It is one `OnUpdate` moving at most two textures (power bar + shapeshift mana),
not a per-frame timer.

**Boundary.** Player only. The tick interval of another unit is not knowable —
we cannot see their power values change reliably, and `targettarget` cannot even
see its own. The option should be absent, not present-and-broken, on other
units, following the focus-gating precedent in §FR-8.5.

If that argument is not accepted, the fallback is to drop the feature rather
than smuggle in a timer.

---

## Determining the tick

Classic regenerates energy every 2.0s and out-of-combat mana on the same 2s
spirit-regen cadence. Rather than hardcode 2.0 and hope, **derive it**:

1. Watch `UNIT_POWER_UPDATE` for the player.
2. When power *increases* and the player is not spending, record `GetTime()` as
   a tick.
3. The interval is the gap between consecutive ticks, smoothed and clamped to a
   sane band (1.5–3.0s) so one bad sample cannot make the line crawl or fly.
4. Seed with 2.0 so the first sweep is right before any tick is observed.

The sweep position is then `(GetTime() - lastTick) / interval`, clamped 0..1.

This self-corrects if Blizzard ever changes the cadence, which a hardcoded 2.0
would not. Record the observed interval in `/duf profile` so it is visible.

**Edge case:** spending energy also fires `UNIT_POWER_UPDATE` with a *decrease*,
which must not be read as a tick. Only increases count.

**Edge case:** at full power there are no increases, so no ticks are observed.
The sweep should keep running on the last known interval rather than freezing —
the tick is still happening, it just has nothing to add.

---

## Design

### Where it lives

Not a new element. It is a decoration *of* a bar, and it has to work on both
`Elements/PowerBar.lua` and `Elements/ShapeshiftMana.lua`. Two options:

- **(a)** A shared helper module, `Systems/PowerTick.lua`, that owns the ticker
  and exposes `Attach(frame, bar, cfg)` / `Detach(bar)`. Both bar elements call
  it from `Layout`.
- **(b)** Duplicate a small amount of code in both elements.

**(a).** One ticker is the whole point; two elements each starting their own
would be the thing §5.7 warns about.

### The line

A 1–2px `Texture` on the bar, full height, moved by `SetPoint` each frame:

```lua
line:SetPoint("TOPLEFT", bar, "TOPLEFT", fraction * bar:GetWidth(), 0)
line:SetSize(width, bar:GetHeight())
```

Direction reverses the fraction: `RIGHT` (default) uses `fraction`, `LEFT` uses
`1 - fraction`.

The line is a child of the bar, so it inherits the bar's alpha and hides with
it — the shapeshift mana bar disappearing on form change takes its line along
without extra bookkeeping.

### Configuration

Per bar (`power` and `mana` blocks each get a `tick` sub-table):

| Setting | Default |
|---|---|
| `enabled` | false — opt in, since it is a niche readout |
| `width` | 2 |
| `color` | white, `{ r = 1, g = 1, b = 1, a = 0.9 }` |
| `direction` | `RIGHT` |

Default off is deliberate: it is an energy-tick tool that means nothing to most
classes, and shipping a moving line on by default is intrusive.

---

## Files

| File | Change |
|---|---|
| `Systems/PowerTick.lua` | New — tick detection, the shared ticker, attach/detach |
| `DyrueUnitFrames.toc` | Add the file |
| `Elements/PowerBar.lua` | Attach/detach in `Layout` and `Disable` |
| `Elements/ShapeshiftMana.lua` | Same |
| `Core/Defaults.lua` | `tick` block on `power` and `mana` |
| `Config/Options_Layout.lua` | Tick group under Power and Shapeshift mana, hidden for non-player units |
| `Core/Core.lua` | `/duf profile` reports the fourth ticker and the observed interval |
| `Documents/COMPAT_FINDINGS.md` | Record the deviation from §5.7's three-ticker list |
| `Tests/tests.lua` | New suite |

---

## Tests

The animation itself is not testable headlessly, but everything that decides
*whether and where* it draws is:

- Ticker does not start when the indicator is disabled everywhere.
- Ticker starts when a visible bar has it enabled, stops when that bar hides
  (shift out of form) and when the option is turned off.
- Only one ticker exists with both the power bar and the mana bar showing it.
- Tick detection: a power *increase* records a tick; a *decrease* does not.
- Interval derivation clamps to 1.5–3.0s and ignores an outlier gap.
- Fraction maths: at half an interval the line is at 50% of bar width; direction
  `LEFT` mirrors it.
- Fraction clamps to 1 when more than one interval has elapsed with no tick.
- The option is absent on non-player units.

The stub's `GetTime` is already test-controlled (`stub.time`), so advancing time
and firing `UNIT_POWER_UPDATE` covers the detection logic properly.

---

## Risks

| Risk | Handling |
|---|---|
| Fourth ticker, against §5.7 | Argued above; visibility-scoped and reported by `/duf profile`; recorded in COMPAT_FINDINGS |
| Tick cadence differs from 2s on these clients | Derived from observation rather than hardcoded |
| Energy spent at the same instant as a tick masks it | Only increases count; a missed tick self-corrects on the next one |
| `OnUpdate` cost | One handler, two textures, `SetPoint` only; no allocation per frame |

---

## Estimate

4–6 hours. The tick-detection heuristic is the uncertain part and will want
in-game observation before the interval clamps are settled.
