# Plan 10 — Five Second Rule Indicator

**Status:** Not started
**Created:** 2 August 2026
**Branch:** `Plan-10-five-second-rule` (to be created from `main`)
**Related:** [Plan 2](Plan_2_PowerTickIndicators.md) — shares one ticker and one
line-rendering path with this. See *Sequencing* below.

---

## Request

> Add an indicator for the "five second rule" of mana regeneration. this should
> behave very similarly to the power tick indicator described in
> @Plans/Plan_2_PowerTickIndicators.md, except the indicator by default should
> move from right to left, and it only applies to mana bars. Let me know if you
> need help understanding the conditions on which the countdown should start
> before you begin writing the plan. For reference, this weakaura is similar in
> function to what I'm asking for: https://wago.io/oSJsslBCz

---

## The mechanic

Spending mana suppresses **Spirit-based** regeneration for five seconds. The
clock starts at the moment mana actually leaves the pool:

- **Instant casts** — immediately.
- **Normal casts** — at *completion*, not at start. Interrupting your own cast
  costs nothing, so nothing has been spent until it lands.
- **Channels** — at the start of the channel.

Every fresh expenditure restarts the five seconds. Throughout the window the
mana tick keeps running on its own ~2s cadence; it simply has no Spirit
contribution to add. MP5 from gear is unaffected by the rule and continues to
land on those ticks, as does the fraction of Spirit regen allowed through by
Meditation / Arcane Meditation / Reflection.

**Consequence worth stating up front:** the five-second window and the moment
regen resumes are *not* the same instant. Spirit mana is next credited on the
first tick after the window closes, which is somewhere between 5 and 7 seconds
after the last spend.

The reference WeakAura could not be read — <https://wago.io/oSJsslBCz> renders
its content client-side and serves an empty document to a fetch, so nothing was
taken from it. Everything below comes from the mechanic and from the decisions
recorded next.

---

## Decisions taken with the user

Asked before writing, since each one changes what gets built:

| Question | Answer |
|---|---|
| What does the sweep measure? | **The 5s window only.** Not the extended wait to the next tick |
| What starts the countdown? | **Mana actually decreasing** — "but leave room to change this behavior later if it needs to change" |
| What happens when the rule is not running? | **Fade out** — sweep to the end, then fade |

The second answer is a design constraint, not just a default: the trigger is
built as a **named, swappable strategy** rather than as inline code in the
sweep, so replacing it later is a table entry (see *The trigger, made
swappable*).

Taking the 5s window rather than the full wait means the line lands on the far
edge while regen may still be up to 2s away. That is the correct reading of
"five second rule", and Plan 2's tick line — on the same bar, if enabled —
covers the remaining gap. Worth confirming by eye once both are in.

---

## Sequencing: this and Plan 2 are one mechanism

Both plans draw **a thin vertical line sweeping across a bar, driven by a
timer**. The only differences are what sets the fraction and how long the sweep
lasts. Building them as two modules would mean two tickers, which is precisely
what §5.7 warns about — and Plan 2 has already spent that argument once.

So: **one module, one ticker, two sweep providers.**

`Systems/BarSweep.lua` (Plan 2 proposed `Systems/PowerTick.lua`; this is that
module with the name generalized) owns:

- the single ticker, started when any attached sweep is *active* and a visible
  bar wants it, stopped the moment that stops being true;
- the line texture, its attach/detach lifecycle on a bar, and the
  fraction → `SetPoint` rendering;
- a table of **providers**, each of which answers only `Fraction(state, now)`
  and `IsActive(state, now)`.

Two providers ship across the two plans:

| Provider | Owned by | Duration | Active when |
|---|---|---|---|
| `tick` | Plan 2 | Derived, ~2s | Always, while its bar is visible |
| `fsr` | This plan | 5s fixed | Within 5s (+ fade) of the last mana spend |

**Whichever plan is implemented first creates the module** and records the
fourth-ticker deviation in `Documents/COMPAT_FINDINGS.md`; the second adds a
provider and a config block and touches nothing else. This plan is written so
it can go first. If Plan 2 has already landed, drop its *Files* rows for
`Systems/BarSweep.lua` down to "add the `fsr` provider" and the estimate roughly
halves.

**This adds no fifth ticker.** That is the point of doing it this way and should
be stated plainly in the commit.

---

## Design

### Which bars it attaches to

"It only applies to mana bars" resolves to two attachment points, and the rule
is about the *displayed power type*, not the class:

| Bar | Attach when |
|---|---|
| `Elements/ShapeshiftMana.lua` | Always, while that bar is shown — it is a mana bar by definition |
| `Elements/PowerBar.lua` | Only while `UnitPowerType(player) == Compat.MANA` |

So a caster gets the line on their power bar; a druid in cat form gets it on the
shapeshift mana bar and *not* on the energy bar; a rogue never sees it. No class
table, same general-rule reasoning as §4.2.

The power bar's attachment therefore has to be re-evaluated on
`UNIT_DISPLAYPOWER`, which `Elements/PowerBar.lua` already handles — the attach
call goes next to the existing colour work in `Update`, not only in `Layout`.

**Player only**, on the same boundary Plan 2 argues (§FR-8.5): another unit's
mana expenditure is not observable, so the option is absent on other units
rather than present and permanently idle.

### Detecting the spend

Two sources feed one entry point, `BarSweep:NoteManaSpent(now)`:

**1. `UNIT_POWER_UPDATE` for the player, mana only.** Keep the last seen mana
value; a *decrease* restarts the clock, an increase does not. This is the whole
mechanism for anyone whose displayed power is mana, costs nothing when idle, and
needs no spell-cost table — it measures the thing the rule actually keys off.

**2. The shapeshift-mana fallback ticker.** This one matters and is easy to
miss. `Elements/ShapeshiftMana.lua`'s header records that
`UNIT_POWER_UPDATE` for mana **has historically not fired reliably while
shapeshifted**, which is exactly why that element runs a 0.2s fallback ticker
and counts how often it corrects a value the events did not deliver. A druid in
cat form is a first-class case for this feature, so source 1 cannot be trusted
there.

The fix costs nothing: that ticker is *already running and already comparing
`el.lastValue`* whenever the shapeshift mana bar is visible. When its comparison
shows a decrease, it calls `NoteManaSpent`. No new sampling, no new timer —
the mechanism built for this unreliability gets a second consumer.

### The trigger, made swappable

Per the user's answer, the detector is a named strategy rather than inline code:

```lua
BarSweep.TRIGGERS = {
    manaSpent = {
        label  = L["Mana spent"],
        events = { UNIT_POWER_UPDATE = "player" },
        Detect = function(state, unit, previous, current)
            return current < previous
        end,
    },
    -- spellcast = { ... }  -- see below; not built
}
```

`cfg.trigger` selects one, defaulting to `"manaSpent"`. **No options dropdown is
built while there is only one entry** — an options control with a single value
is noise. Adding the second trigger later is: one table entry, one dropdown,
done.

The obvious second entry is `spellcast` — `UNIT_SPELLCAST_SUCCEEDED` filtered to
the player, restricted to spells that cost mana. It is immune to the one
known false positive below. It is not built now because it needs a spell-cost
lookup whose availability on 1.15.9 / 2.5.6 is unverified (`GetSpellPowerCost`,
`C_Spell.GetSpellPowerCost`, or neither). **`Probe/…/Probe.lua` should report
which of those exist**, so the question is answered by observation before anyone
commits to the approach.

**Known false positive, accepted:** an enemy draining your mana (Mana Burn,
Viper Sting) is a decrease and will start the clock. It is rare, it is
self-correcting within five seconds, and it is precisely the case the swappable
trigger exists for. Documented rather than defended.

**Correct positive worth noting:** shapeshifting costs mana, so shifting starts
the clock. That is right, not a bug.

### The sweep

```
elapsed = now - lastSpend

elapsed <= 5.0            fraction = elapsed / 5, alpha = 1
5.0 < elapsed <= 5.0+fade held at the end, alpha = 1 - (elapsed - 5) / fade
elapsed > 5.0+fade        inactive: hide, and stop the ticker if nothing else wants it
```

`direction` reverses the fraction exactly as Plan 2 specifies — `RIGHT` uses
`fraction`, `LEFT` uses `1 - fraction`. **Default `LEFT`**, giving the requested
right-to-left travel: the line starts at the right edge on the spend and reaches
the left edge as the rule expires.

A spend arriving *during* the fade snaps alpha back to 1 and restarts from the
origin edge. Cheap, and without it a fast caster sees a stutter.

**The idle-cost difference from Plan 2, in this plan's favour.** Plan 2's sweep
runs continuously while its bar is visible. This one is active only inside a 5.3s
window, so a caster standing in a city with it enabled costs *nothing* until
they cast. The ticker is shared, so when both are enabled Plan 2's is the one
holding it open — this provider adds no time to an already-running loop.

### The five seconds

A module constant, `FSR_DURATION = 5`, with a comment saying it is a game rule
rather than an observed cadence — the opposite of Plan 2's derived interval, and
deliberately so. There is nothing to measure here and nothing to smooth. No user
option: an editable "how long is the five second rule" control is an invitation
to misconfigure something that is not configurable in the game.

### Configuration

A `fsr` sub-table beside Plan 2's `tick`, on both the `power` and `mana` blocks:

| Setting | Default | Note |
|---|---|---|
| `enabled` | `false` | Opt in, same reasoning Plan 2 gives — a moving line on by default is intrusive |
| `width` | 2 | Matches `tick` |
| `color` | `(0.45, 0.75, 1, 0.9)` | **Deliberately not Plan 2's white.** Both lines can be on the same mana bar at once, and two identical white lines crossing each other is unreadable. A mana-blue reads as "this one is about mana" |
| `direction` | `LEFT` | Right to left, as requested |
| `fade` | 0.3 | Seconds |
| `trigger` | `"manaSpent"` | No UI until there is a second one |

### Out of scope, stated so it is not mistaken for an oversight

**Meditation-style talents and Innervate.** A priest with Meditation regenerates
a percentage of Spirit mana *during* the window, and Innervate lifts the
suppression outright. The line means "the rule is running", not "you are getting
nothing" — a Meditation priest reads it as "partial". Modelling talent ranks and
buff states to dim or shorten the line is a much larger feature for a much
smaller payoff, and it would need a talent scan plus an aura watch. If it is
wanted later it is its own plan.

---

## Files

Rows marked † are Plan 2's if that lands first; this plan then only extends them.

| File | Change |
|---|---|
| `Systems/BarSweep.lua` † | New — the shared ticker, line rendering, attach/detach, and the provider table. This plan adds the `fsr` provider and the `TRIGGERS` table |
| `DyrueUnitFrames.toc` † | Add the file |
| `Elements/PowerBar.lua` † | Attach/detach, gated on `UnitPowerType == Compat.MANA`, re-evaluated in `Update` so `UNIT_DISPLAYPOWER` is honoured |
| `Elements/ShapeshiftMana.lua` † | Attach/detach; plus call `BarSweep:NoteManaSpent` from the existing fallback ticker when it sees a decrease |
| `Core/Defaults.lua` | `fsr` block on `power` and `mana` |
| `Config/Options_Layout.lua` | Five-second-rule group under Power and Shapeshift mana, hidden on non-player units |
| `Core/Core.lua` | `/duf profile` reports the shared sweep ticker and whether the rule is currently running |
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | Report which spell-cost API exists, for the future `spellcast` trigger |
| `Documents/COMPAT_FINDINGS.md` † | The fourth-ticker deviation from §5.7 — recorded once, by whichever plan lands first |
| `Tests/wowstub.lua` | `UNIT_SPELLCAST_SUCCEEDED` in `validEvents` (for the future trigger); nothing else new — `stub.time` and `UNIT_POWER_UPDATE` already exist |
| `Tests/tests.lua` | New suite |

### Schema and migration

**None.** `fsr` is new keys, so `Defaults:EnsureProfile` fills them into
existing profiles and `SCHEMA_VERSION` does not move. The cheap case, same as
Plan 1 and unlike Plan 9's buff-row change.

---

## Tests

`stub.time` already drives `GetTime`, so the whole thing is testable headlessly
by advancing time and firing events.

**Detection**
- A mana *decrease* on `UNIT_POWER_UPDATE` starts the clock; an *increase* does
  not; an unchanged value does not.
- A decrease on a *different* unit does not start the player's clock.
- The shapeshift-mana fallback ticker seeing a decrease starts the clock — the
  regression test for the cat-form case, and the one most likely to rot.
- `TRIGGERS.manaSpent` is selected by default and a `cfg.trigger` naming an
  unknown strategy falls back to it rather than erroring.

**The sweep**
- At 2.5s the fraction is 0.5; at 0s it is 0; at 5s it is 1.
- `direction = "LEFT"` (the default) puts the line at the **right** edge at
  t = 0 and the left edge at t = 5.
- `RIGHT` mirrors it.
- At 5.15s with `fade = 0.3` the line is held at the end and alpha is ~0.5.
- At 5.4s it is hidden and inactive.
- A spend at t = 3 restarts the sweep from 0.
- A spend at t = 5.15, mid-fade, restores alpha to 1 and restarts from 0.

**Attachment**
- Power bar with `UnitPowerType == MANA`: line attached.
- Power bar in cat form (`UnitPowerType == ENERGY`): **not** attached, while the
  shapeshift mana bar's **is**. Assert both halves; this is the request's "only
  applies to mana bars" in one test.
- `UNIT_DISPLAYPOWER` flipping the displayed type attaches/detaches without a
  full config reload.
- The option is absent on non-player units.

**The ticker**
- Idle with the indicator enabled and no spend: **no ticker running.** This is
  the claim that justifies the feature's cost and should fail loudly if broken.
- A spend starts it; 5.3s later it stops.
- With Plan 2's `tick` also enabled there is still exactly **one** ticker.

---

## Risks

| Risk | Handling |
|---|---|
| `UNIT_POWER_UPDATE` for mana unreliable while shapeshifted — the case the feature most needs | Second detection source through the existing shapeshift fallback ticker; tested explicitly |
| Enemy mana drain starts the clock spuriously | Accepted and documented; self-corrects in 5s; the swappable trigger is the fix if it ever matters |
| Two sweep lines on one bar are unreadable | Different default colour and a documented reason; both are user-configurable |
| Diverging from Plan 2 into a second module and a fifth ticker | One module, one ticker, two providers — argued above and asserted by a test |
| Plan 2 lands later and reshapes the module | This plan defines the provider contract, so Plan 2 becomes an added table entry either way |
| 5s window ending before regen actually resumes reads as a bug | Deliberate, per the user's choice; Plan 2's tick line covers the remainder. Re-check by eye once both are in |

---

## Estimate

**2–3 hours if Plan 2 has landed** — a provider, a config block, an options
group and a test suite, on machinery that already exists.

**4–5 hours if this goes first**, since it then builds `Systems/BarSweep.lua`,
the attach/detach lifecycle on both bar elements, and the COMPAT_FINDINGS entry.

Either way this is the cheaper of the two plans: the timing is a fixed constant
rather than Plan 2's derived-and-clamped interval, which is the part of that
plan needing in-game observation before it can be settled.
