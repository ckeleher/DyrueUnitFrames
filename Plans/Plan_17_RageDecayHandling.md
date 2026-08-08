# Plan 17 — Rage Decay Handling

**Status:** Not started
**Created:** 8 August 2026
**Branch:** `Plan-17-rage-decay`
**Builds on:** [Plan 2](Archive/Plan_2_PowerTickIndicators.md) and
[Plan 10](Archive/Plan_10_FiveSecondRuleIndicator.md) — `Systems/BarSweep.lua`,
its one driver and its providers table. This is the third provider.

---

## Request

> Rage as a power bar behaves differently from the mana and energy ticking
> system, so we need to handle it specially. See if you can look up the rules for
> how long rage takes to start decaying, and the interval on which it decays.
> Make a plan for this work, and ask me any questions you need before starting
> implementation.

---

## What the rules actually are

The request asks for the numbers first, so: they were looked up, and the honest
answer is that they are **not reliably documented for 1.15.9 / 2.5.6**. What is
established, and how much weight each claim carries:

| Claim | Source | Confidence |
|---|---|---|
| Rage decays **only out of combat**. In combat it does not decay at all | every source agrees | High |
| Vanilla/Classic rate: **~1 rage per second average, delivered as 2 or 3 rage per ~2.5 s tick** | Vanilla WoW Wiki | Medium — one source, discrete-tick shape is the useful part |
| Current/retail rate: **1.25 per second** (75/min) | warcraft.wiki.gg | High *for retail*, and therefore the wrong number to copy |
| Decay begins "after a brief delay", duration unstated | noobtoboss Classic warrior guide | Low — no number, no mechanism |
| No separate pre-decay timer is documented anywhere; what players experience as the delay is the **combat drop itself** (the flag clears ~5 s after the last hostile action, 6 s in PvP) | absence across all four wikis | Medium |
| The rate is **talent-modifiable on Classic Era**: vanilla Anger Management reads "Increases the time required for your rage to decay while out of combat by 30%" | warcraft.wiki.gg, Anger Management (Classic) | High |
| That talent was **redesigned in 2.0.1** to "Generates 1 rage per 3 seconds while in combat", so on TBC nothing modifies out-of-combat decay | same | High |
| Some Classic players report losing the **entire** rage bar the instant combat drops | Blizzard forums, no developer reply | Low, unverified |

Two consequences shape the whole design.

**1. Do not hardcode.** The rate differs between our two supported clients'
talent trees, the tick interval is single-sourced, and the pre-decay delay has no
documented value at all. Plan 2 already faced exactly this for the regen cadence
and answered it by *deriving the interval from observation, seeded and clamped to
a band*. The same answer applies here, for stronger reasons.

**2. Whether the client even tells us is an open question.** All of the above is
server behaviour. Whether `UNIT_POWER_UPDATE` fires on each rage decay tick, or
the client coalesces them, is unverified — and §FR-2.5 is the standing precedent
that a power event on these clients cannot be assumed. `/dufprobe rage`
(below) answers it before any of the derived numbers are trusted.

Seeds and band, pending that measurement: **2.5 s**, accepted band **1.5–4.0 s**.
The band is wider than the regen band's 1.5–3.0 because a 30% talent stretch on
a 2.5 s base is 3.25 s and must not be rejected as an outlier.

---

## Interpretation

"Handle it specially" has two readings, and they are materially different work:

- **(i) Stop being wrong about rage.** Rage is fed through a mechanism built for
  regeneration; it does not regenerate. Suppress the tick line on a rage bar and
  stop rage from corrupting the derived cadence.
- **(ii) Also give rage its own readout** — the mirror of the tick indicator: a
  line sweeping towards the next *decay* tick.

The request asks for the decay timings to be looked up, which is only needed for
(ii); (i) needs no numbers at all. So **(ii) is the reading taken**, with (i) as
its first half rather than as an alternative to it. (i) is a live bug and is
worth doing on its own merits — see the next section — so the two parts are
sequenced and either can ship without the other.

---

## Part 1 — The bug that exists today

`Systems/BarSweep.lua:518` `NotePlayerPower` treats *any* increase in the
player's displayed power as a regen tick:

```lua
if value > previous then
    self:NoteTick(now)
```

`NoteTick` smooths the gap into `state.interval` and resets `state.origin`. That
state is **global and shared** — one player, one regen cadence, as the header
says. Rage breaks the assumption:

- A warrior gains rage from weapon swings and ability hits. Mainhand speeds are
  typically 2.4–3.6 s, so a large share of those gaps land **inside** the
  accepted 1.5–3.0 s band and are folded in as if they were regen samples.
- The damage is not confined to the warrior. A **druid in bear form** has rage on
  the power bar and mana on the shapeshift mana bar, and both read the same
  `state.origin` / `state.interval` (`Elements/ShapeshiftMana.lua:227`). So every
  rage gain in bear form resets the phase of the *mana* tick line and drags its
  interval towards the bear's swing timer. The one bar where the indicator is
  most useful is the one being corrupted.

Two fixes, both in `BarSweep`:

**Route by power type in `NotePlayerPower`.** Rage increases never reach
`NoteTick`. They go to the decay bookkeeping instead (Part 2) or, if Part 2 is
deferred, nowhere. `Compat.MANA`/`Compat.ENERGY` keep the existing path.

**Suppress the `tick` provider on a rage bar.** One clause in `tick.IsActive`:
`record.powerType == Compat.RAGE` returns false. This has to be a runtime
suppression rather than a hidden option, because `power.tick` is one config block
per bar and a druid's power bar shows rage in bear form and energy in cat form —
there is no per-power-type config to hide. The consequence is user-visible (a
warrior ticking the power tick box sees nothing happen) and so has to be stated
in the option's own description text, not just in code.

---

## Part 2 — The decay provider

### Where it lives

A third entry in `PROVIDERS` in `Systems/BarSweep.lua`, named `decay`. No new
module, no new ticker: the driver, the line rendering, the attach/detach
bookkeeping, the direction handling and the opacity handling are all already
there and are all wanted unchanged. This is the arrangement the §5.7 deviation
row in `Documents/COMPAT_FINDINGS.md` predicted — that row should be updated to
name three providers so the record stays true, and no new deviation is created.

### Detection

Separate state fields, never the shared ones:

| Field | Meaning |
|---|---|
| `rageOrigin` | `GetTime()` of the last observed decay tick |
| `rageInterval` | derived interval, seeded 2.5 |
| `rageObserved` | has a real decay tick ever been seen? |
| `rageSamples` | accepted samples |
| `rageCombatEnd` | `GetTime()` at the last `PLAYER_REGEN_ENABLED` |
| `rageFirstDecay` | measured gap from combat drop to first decay tick |

Rules, applied only when the displayed power type is rage:

- **Increase** → a rage *gain*. Never a tick. It resets nothing in the shared
  state, and it does not reset `rageOrigin` either: the decay cadence is a server
  timer that a gain does not reschedule, and assuming otherwise would put the
  phase wrong after every swing.
- **Decrease while `UnitAffectingCombat("player")`** → a spend. Ignored.
- **Decrease out of combat, magnitude ≤ 5** → a decay tick. `rageOrigin = now`,
  and the gap from the previous one is smoothed into `rageInterval` on the same
  terms `NoteTick` uses: outliers outside 1.5–4.0 s are **rejected outright**,
  not clamped in, because a long gap is a missed observation and not evidence of
  a slower cadence.
- **Decrease out of combat, magnitude > 5** → not a decay tick. Shifting out of
  bear form zeroes rage, and the unverified "whole bar on combat drop" report is
  the same shape. Phase is reset so the line does not sweep from a stale origin,
  but no interval sample is contributed.

The magnitude band exists because the documented tick is 2–3 rage. It is a
guard against large one-off drops, not a precision instrument, and 5 leaves room
for the rate being different than documented.

The power-type guard at `NotePlayerPower:527` — a change of `powerType` is a
shapeshift and the two values are not comparable — already covers the
form-change case and needs no change.

### Combat events

`PLAYER_REGEN_ENABLED` and `PLAYER_REGEN_DISABLED`, registered on a BarSweep-owned
frame (the precedent is `Config/DragMode.lua:321`; the existing `driver` frame is
hidden, which stops its `OnUpdate` but not its events, so it can carry them).

Neither event is needed for the line to be *correct*: `IsActive` reads
`UnitAffectingCombat("player")` and the driver re-evaluates every frame, so the
line stops of its own accord when combat starts. They are there for two specific
things: timestamping the combat drop so the pre-decay delay can be measured, and
restarting a driver that has idled to a stop so the line does not wait for the
next power event to reappear.

### What the line does

```
IsActive   record.powerType == RAGE
           and not UnitAffectingCombat("player")
           and rage > 0
           and rageObserved
Fraction   ((now - rageOrigin) % rageInterval) / rageInterval
Alpha      1
```

`rage > 0` reads `state.lastPower` — already maintained by `NotePlayerPower`, and
for a rage bar the displayed power *is* rage, so no extra API call per frame.
Inactive at zero rage is a fact rather than a judgement call: decay stops at
zero, so unlike the tick provider's `atMax` there is nothing to make an option
of. Nothing to count down to, no line.

The modulo is there for the same reason as in the tick provider: if a decay tick
is not observed, the phase of the last one survives rather than the line parking
against the far edge.

**`rageObserved` gates the line, and that is the answer to "how long rage takes
to start decaying".** The delay is the least verifiable number in this feature —
undocumented, possibly zero, possibly just the combat-drop timer the game already
signals by clearing the combat flag. Sweeping a line for a duration we cannot
substantiate would be asserting more confidence than we have. So the line does
not appear during the gap; it appears when rage actually starts falling, which is
self-evidently correct whatever the true delay is.

The gap is *measured* anyway — `rageFirstDecay`, reported by `/duf profile` — so
that after a few sessions the number is known rather than guessed. If it turns
out to be stable and real, a grace-window sweep becomes a small follow-up with
evidence behind it. See *Open questions*.

### Defaults

`power.decay`, built from the existing `sweep()` fragment in `Core/Defaults.lua`:

| Setting | Default | Why |
|---|---|---|
| `enabled` | `false` | Same reasoning as the other two: a moving line is intrusive and this one means nothing to five of nine classes |
| `direction` | `LEFT` (right to left) | The resource is draining. Same "direction should mean something" call that gave the five second rule `LEFT` |
| `color` | `{1, 0.55, 0.3}` | Must not match the bar it is drawn on. `Systems/Colors.lua:89` puts rage at `0.78, 0.25, 0.25`, so a red line is invisible; a hot orange reads against it and is distinct from the white tick line and the blue five-second line |
| `width` | 2 | As the others |
| `alpha` | 0.9 | As the others |

**On the power bar only.** `Elements/ShapeshiftMana.lua` gets no decay
attachment at all — that bar is a mana bar by definition and can never show
rage, which is the mirror image of why the five second rule is not on a rage bar.

---

## Files

| File | Change |
|---|---|
| `Core/Compat.lua` | `Compat.RAGE`, alongside `MANA` and `ENERGY` at line 146. The `or 1` literal fallback is safe here — 1 is rage in both the Classic numbering and `Enum.PowerType`, unlike the combo-point trap documented at line 175. Add it to `Compat.Report()` |
| `Systems/BarSweep.lua` | Rage-aware `NotePlayerPower`; `NoteRageDecay`; the `decay` provider; the two combat events; new state fields cleared by `Reset()`; `RageInterval()` / `RageObserved()` / `FirstDecayDelay()` reporters; `ProviderNames()` gains `"decay"` |
| `Elements/PowerBar.lua` | One more `BarSweep:Attach` in `syncSweeps`, gated to a rage power type the way the five second rule is gated to mana |
| `Core/Defaults.lua` | `decay = sweep("LEFT", color(1, 0.55, 0.3))` on the `power` block |
| `Config/Options_Layout.lua` | `sweepGroup(unitKey, power, apply, "decay", 45, ...)` and a `DECAY_DESCRIPTION`; amend `TICK_DESCRIPTION` to say the tick line does not apply to rage |
| `Core/Core.lua` | `/duf profile` reports the decay interval, observed-or-assumed, and the measured first-decay delay, beside the existing three sweep lines at 609–615 |
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | `/dufprobe rage` — see below |
| `Documents/COMPAT_FINDINGS.md` | Update the §5.7 row to three providers; record the measured decay numbers once observed |
| `Tests/tests.lua` | Extend `testBarSweep` |

---

## The probe

`/dufprobe rage`, modelled on the existing `/dufprobe mana` 60-second tracer
(`Probe.lua:248`). It answers the questions this design is currently assuming
answers to:

1. Does `UNIT_POWER_UPDATE` fire per rage decay tick, or does the client
   coalesce them? Log every event with `GetTime()`, the value and the delta.
2. What is the real interval on this client — 2.0, 2.5, something else?
3. How much rage per tick, and is it the documented 2–3?
4. How long after `PLAYER_REGEN_ENABLED` does the first decrease arrive?
5. Does anything arrive *during* combat, i.e. is the in-combat assumption right?

Run it on a warrior, and again on a druid in bear form, and once on a
Classic Era warrior with Anger Management talented if one is available.

**Contingency if the event does not fire per tick.** The driver's `OnUpdate` is
already running whenever a decay line is active, so detection can move there:
one `UnitPower("player", RAGE)` read per frame, no allocation. That is a real
cost and is not the first choice, which is why it is contingent on measurement 1
rather than built speculatively.

---

## Schema and migration

**None needed.** `power.decay` is a new key block, which `Defaults.Fill` /
`EnsureProfile` deep-fill for existing profiles at no cost. No stored value
changes meaning, so `SCHEMA_VERSION` stays at 15.

The one thing that *behaves* differently for an existing profile is the tick line
vanishing from rage bars for anyone who had it on — but that is a bug fix, the
stored value is untouched, and there is no way to distinguish "wanted a
meaningless line on rage" from the default, nor any reason to preserve it.

---

## Tests

Extending `testBarSweep` (`Tests/tests.lua:3592`). The stub already carries what
this needs: the player unit is rage-typed at `tests.lua:51` (`powerType = 1,
powerToken = "RAGE"`), `stub.inCombat` drives `UnitAffectingCombat`
(`wowstub.lua:15, 552`), and `GetTime` is test-controlled — so no new stub
machinery.

Part 1, the regression that motivates it:

- A rage increase does **not** record a regen tick, and leaves `state.interval`
  and `state.origin` untouched.
- Interleaved bear-form traffic — rage gains on the power bar and mana ticks on
  the shapeshift mana bar — derives the mana interval from the mana ticks alone.
  This is the bug stated as an assertion.
- The `tick` provider is inactive on a rage-typed record and unaffected on mana
  and energy records.

Part 2:

- A decrease out of combat records a decay tick; the same decrease in combat does
  not.
- The interval derives from consecutive out-of-combat decreases, rejects a gap
  outside 1.5–4.0 s without moving, and stays inside the band across a long run
  of samples.
- A decrease larger than the magnitude band resets the phase and contributes no
  sample.
- A `UNIT_DISPLAYPOWER` power-type change is neither a gain nor a decay tick.
- `IsActive`: false in combat, false at zero rage, false before any decay has
  been observed, false on a mana or energy record, true otherwise.
- Fraction maths at half an interval, and `direction = LEFT` mirroring it.
- The decay group is absent on non-player units, and absent from the shapeshift
  mana bar's options entirely.
- `Reset()` clears every new field — asserted directly, since the rest of the
  suite depends on it.

**The gap that let this through:** the existing suite drives `NotePlayerPower`
with mana and energy only. Nothing ever fed it rage, so a resource that decays
was passing through a code path written for one that regenerates, unexamined.
The bear-form interleaving test above is the specific coverage that was missing.

---

## Risks

| Risk | Handling |
|---|---|
| `UNIT_POWER_UPDATE` does not fire per decay tick | The probe answers it before the derived numbers are trusted; the per-frame `UnitPower` fallback is designed and costed above |
| The real interval is outside 1.5–4.0 s | Band chosen to cover the documented 2.5 plus a 30% talent stretch; the probe measures it and the band is one constant |
| A rage spend at the same instant as a decay tick masks it | Same posture as Plan 2: a missed observation self-corrects on the next one, and the modulo keeps the phase meanwhile |
| Anger Management changes the *amount* per tick rather than the interval | Then the interval never moves and the line stays correct. Only the reverse case matters, and the band covers it |
| A fifth provider becomes tempting later | This one adds no ticker, no module and no rendering path; the §5.7 row is updated rather than re-argued |
| Suppressing the tick line on rage looks like a regression to a warrior who had it on | Stated in the option description in the panel, not only in the commit |

---

## Estimate

**Part 1** — 1–2 hours including the regression tests. Worth landing first and
on its own; it is a real bug with a small, provable fix.

**Part 2** — 3–4 hours, plus an in-game session with `/dufprobe rage` before the
interval band and the magnitude band are settled. The probe is where the
uncertainty actually is; the code around it is a third entry in an existing
table.

---

## Decisions

Asked before implementation, answered 8 August 2026. All four took the
recommendation, so the design above stands unamended.

1. **Scope: both parts.** Part 1 lands first and separately — it is a bug fix
   with its own regression tests and does not depend on Part 2.
2. **The pre-decay delay: show nothing until rage actually falls.** The line is
   gated on `rageObserved`. The delay is measured into `/duf profile` so the
   number becomes known; a grace-window sweep stays out until it is, and is then
   a follow-up plan rather than part of this one.
3. **Build against the seeded numbers, correct after measuring.** Deriving the
   interval at runtime is what makes the seed unimportant. `/dufprobe rage` still
   ships with Part 2, but it informs the bands afterwards rather than gating the
   work.
4. **Rage only.** Energy, focus and mana all regenerate on a tick, so the
   existing indicator is already right for rogues, cats and hunter pets and none
   of them are touched. Happiness was raised and explicitly excluded.

---

## Sources

- Rage — <https://warcraft.wiki.gg/wiki/Rage> (current/retail rate)
- Rage — <https://vanilla-wow-archive.fandom.com/wiki/Rage> (the ~1/s, 2–3 per
  2.5 s tick figure)
- Anger Management (Classic) —
  <https://warcraft.wiki.gg/wiki/Anger_Management_(Classic)> (the 30% decay-time
  talent, and its 2.0.1 redesign)
- WoW Classic warrior rage guide —
  <https://noobtoboss.com/wow-classic-warrior-rage-guide/> ("after a brief
  delay", no number)
- Warrior instant rage loss on combat drop —
  <https://us.forums.blizzard.com/en/wow/t/warrior-instant-rage-lose-on-combat-drop/307834>
  (unverified player reports, no developer reply)
