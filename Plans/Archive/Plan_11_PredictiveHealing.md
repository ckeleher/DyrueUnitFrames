# Plan 11 — Predictive Healing

**Status:** Implemented on `Plan-11-predictive-healing`, merged in PR #13.
**Created:** 3 August 2026
**Branch:** `Plan-11-predictive-healing`

The status line read *Not started* right up to the merge — it was never updated
after the branch was written, and the branch then sat unmerged and unpushed on
one machine for four days. Recorded rather than quietly corrected, because "the
plan says not started" was the only signal available and it was wrong.

**Deviations from the plan as written:**

* **`Core/Locale.lua` needed no changes**, despite being in the Files table.
  enUS is the identity mapping — the keys *are* the strings and `__index`
  returns the key — so new `L["..."]` call sites work with no table entry. The
  same habit that put it in Plan 13's Files table.
* **`Config/TestMode.lua` was changed but is not in the Files table.** The
  Design section describes the synthetic prediction it carries; the table just
  missed it.
* **The order-11 reasoning in *Where the code lives* is wrong.** It claims the
  health fill "is already correct when the prediction measures against it"
  because of the ordering. It is not: `RegisterEvents` builds each event's
  handler list by iterating `activeElements`, which is unordered, so on a
  `UNIT_HEALTH` the prediction may well run before the health bar. The
  implementation is safe for a different reason, recorded in the element's
  header — the fill position is computed from `UnitHealth` directly rather than
  read off the bar. Order 11 is grouping, not a dependency.
* **"No fourth ticker" is off by one.** `Systems/BarSweep.lua` is already the
  fourth (Plans 2 and 10, recorded in `COMPAT_FINDINGS.md`), so what this plan
  declined to add was a fifth. The argument holds either way; only the count
  was wrong.
* **The schema-version assertion needed re-pinning.** The suite pins
  `SCHEMA_VERSION` to prove this plan adds no bump of its own, as an absolute
  number. It was written against 13 and main reached 15 underneath it, so the
  rebase before merge failed on it. Re-pinned to 15 after checking this
  branch's `Core/Defaults.lua` matched main's exactly. It will go stale again
  the same way.

**Still outstanding:** absorb shields are Plan 12 and were never in scope here.
The `healcomm` provider is still a single-entry `PROVIDERS` table, so group
heal prediction remains unbuilt, and no live raid has exercised the combat-log
listener under load.

---

## Request

> I want predictive healing for all health bars. This module should also handle
> indicating HoT healing and absorb shields, with the option of showing HoT
> healing and shielding as separate colors from the direct incoming heal
> prediction, if that makes sense (if not - ask me for clarity). This predictive
> healing should have the option of overflowing the size of the health bar by a
> configurable amount, with the default being on at +10% overflow. Ask me any
> clarification you need, then start making a plan for implementing this
> feature.

---

## Scope split

The request covers three things: direct heal prediction, HoT prediction, and
absorb shields. Absorbs were split out to **Plan 12** on the user's instruction
after the clarification round, because they are a different problem with a
different failure mode (see that plan for why). This plan builds the module,
both heal categories, the overflow behaviour, and the colour slots — including
the slot Plan 12 drops into.

---

## Interpretation

### What was asked, and what was answered

Four things were ambiguous enough to change the work. The answers given:

| Question | Answer |
|---|---|
| How far should heal detection reach, given no API? | **Own casts now, group later.** Build a pluggable provider interface, ship the own-casts provider, leave a LibHealComm provider as a drop-in later plan |
| Absorb shields, given no API at all? | **Defer to a separate plan**, with the colour slot and config shape built now |
| What does "+10% overflow" do to the bar? | **Overhang past the bar's edge.** Full health still fills the bar exactly; prediction spills up to 10% of the bar's width beyond it |
| "All health bars", but non-group units report health 0–100? | **Enable everywhere, render nothing where it is impossible** — uniform config, silent degradation |

### "Separate colors … if that makes sense"

It makes sense, and it is the right default. Direct heals and HoTs answer
different questions — *"is this target about to be topped up"* versus *"is this
target already covered"* — and a healer acts differently on each. They ship as
two colours with a single checkbox to collapse them into one.

### The thing that dominates this plan

**There is no incoming-heal API on these clients.** `UnitGetIncomingHeals`
arrived in Cataclysm and `UnitGetTotalAbsorbs` in Warlords; neither is expected
on 1.15.9 or 2.5.6, and where a Classic client has ever exposed incoming heals
it covered direct casts only — no HoTs, no channels, which is two thirds of what
was asked for.

So this feature does not *read* its data. It **derives** it. That is the whole
design, and every hard decision below follows from it.

The assumption is recorded rather than trusted: `/duf compat` gains rows for
`UnitGetIncomingHeals`, `UnitGetTotalAbsorbs` and `UNIT_HEAL_PREDICTION`, and
`Documents/COMPAT_FINDINGS.md` gets the matching lines to fill in. If the probe
comes back positive on either client, the provider interface below is exactly
the seam where an API-backed provider would be added — but nothing waits on it.

---

## SPEC deviation — required argument

`Documents/SPEC.md` §2.2 lists **"Combat text, threat meters, incoming-heal
prediction"** as *out of domain*. This plan overturns that line for heal
prediction. Per `Skills/NewWork.md`, the argument, to be recorded in
`Documents/COMPAT_FINDINGS.md` under *Deviations from SPEC.md* when implemented:

1. **The reason for the exclusion no longer holds.** §2.2's excluded list is
   two kinds of thing: features belonging to another addon's problem domain
   (combat text, threat, nameplates), and features Classic cannot support (other
   units' cast bars). Heal prediction was filed with the first group. It belongs
   with the second — it is a property of a health bar, not a separate display,
   and the only reason it looked out of domain is that the API for it is absent.
   That made it expensive, not foreign.

2. **The user has asked for it explicitly.** §2.1's first goal is to replace
   SUF's day-to-day functionality for this player. SUF has heal prediction.

3. **It costs nothing that §2.2's other exclusions were protecting.** No secure
   header, no Blizzard frame contact, no new library, and — see below — **no new
   ticker**. The blast radius is two new files and a config block.

§2.2 should be amended in the same commit: strike "incoming-heal prediction"
from the exclusion row and add it to §2.3's deferred-and-now-built list, with
the absorb half noted as pending Plan 12.

**Clean-room (§11.3) note.** SUF implements this feature and its source must not
be read while implementing this plan. Its *behaviour* — segments after the fill,
overheal spilling past the end — is referenced freely and is standard across
every unit frame addon.

---

## Design

### Where the code lives

Two new files, mirroring the split that `Systems/BarSweep.lua` and its callers
already use: **one module owns the derived state, elements only draw**.

| New file | Owns |
|---|---|
| `Systems/HealPrediction.lua` | Every derived value. Providers, the combat-log listener, the learned-amount store, `IncomingHeal(unit)` |
| `Elements/HealPrediction.lua` | Drawing. Two textures on the health bar, the overflow geometry, nothing else |

The element is registered through `ns:RegisterElement("healPrediction", …)` at
**order 11**, immediately after health's 10, so on a `FullUpdate` the health
fill is already correct when the prediction measures against it. It carries
`configKey = "healPrediction"`, giving it circuit-breaker isolation for free —
this is the most speculative code in the addon, and if it errors five times it
gets disabled for the session while the health bar underneath keeps working.
That property alone justifies it being an element rather than twenty lines
inside `Elements/HealthBar.lua`.

### The provider interface

Shaped exactly like `BarSweep.PROVIDERS` and `BarSweep.TRIGGERS` — a named
table of strategies, so adding one is a table entry and not a reshape:

```lua
HealPrediction.PROVIDERS = {
    own = {
        label = L["My casts only"],
        Start = function() … end,   -- register events
        Stop  = function() … end,   -- unregister; must idle to zero
        -- @return direct, hot   (absolute health points, 0 when unknown)
        Incoming = function(guid, now) … end,
    },
}
HealPrediction.DEFAULT_PROVIDER = "own"
```

The second entry, when it comes, is `healcomm`. It is not built now and **no
dropdown is built while there is one entry** — the precedent set by
`BarSweep.TRIGGERS` in Plan 10, for the same reason: a control with a single
value is noise.

### How an own-cast heal is sized — the self-calibrating estimator

The obvious approach is a spell database: base heal per rank, spellpower
coefficient, talent multipliers, per class, across two expansions. It is what
LibHealComm does, it is thousands of lines, and it is wrong the moment anything
changes.

**Do not build it. Learn the numbers instead.**

On `COMBAT_LOG_EVENT_UNFILTERED`, when `sourceGUID` is the player's:

* `SPELL_HEAL` → record `amount + overhealing` against that `spellId`. The sum,
  not `amount` — a heal cast on a nearly-full target lands for almost nothing
  and would otherwise teach the estimator that Greater Heal heals for 40.
* `SPELL_PERIODIC_HEAL` → same, into a separate per-tick store.
* Crits (`critical == true`) are **discarded, not scaled**. A crit is a
  different distribution, and dividing by 1.5 assumes a crit multiplier the
  estimator has no business knowing.

Each store is a rolling blend, using the same smoothing idiom and constant as
`BarSweep:NoteTick`:

```lua
learned[spellID] = learned[spellID] * (1 - SMOOTHING) + sample * SMOOTHING
```

This is the same philosophy as Plan 2's derived tick interval, applied to a
harder problem: the cadence is not hardcoded at 2.0 there, and the heal is not
hardcoded at rank tables here. It self-corrects across gear, talents, buffs,
+healing, and any Blizzard rebalance, and it needs no locale-dependent tooltip
parsing — which was the other candidate and is rejected because Classic spell
tooltips are not confirmed to include spellpower at all.

**The cost, stated plainly:** a spell you have never cast on this character
predicts nothing. The first Flash of Heal of a character's life shows no bar;
the second onwards does. That is the honest failure mode and it is strictly
better than showing a confidently wrong number.

Learned values persist in **`ns.db.char`** — per character, because they are a
function of that character's gear and talents. AceDB provides the `char` scope
already; it needs a `Defaults:EnsureChar` alongside the existing `EnsureProfile`
and `EnsureGlobal`, called from `addon:OnInitialize`. No TOC change: AceDB
stores char scope inside the existing `DyrueUnitFramesDB`.

### Direct casts

Tracked from the player's own spellcast events, all filtered to `"player"`:

| Event | Action |
|---|---|
| `UNIT_SPELLCAST_SENT` | Carries the **target name**. Resolve it to a GUID by scanning only the units this addon draws (`player`, `pet`, `target`, `focus`, `party1-4`, `partypet1-4`). Unresolvable → drop it; there is no frame to draw on anyway |
| `UNIT_SPELLCAST_START` | If the spellID has a learned direct amount, open a prediction against that GUID ending at the cast's end time |
| `UNIT_SPELLCAST_SUCCEEDED` / `_STOP` / `_INTERRUPTED` / `_FAILED` | Close it |
| `UNIT_SPELLCAST_DELAYED` | Pushback — extend the end time, amount unchanged |
| `UNIT_SPELLCAST_CHANNEL_START` / `_UPDATE` / `_STOP` | Channelled heals (Tranquility) are treated as HoTs: remaining ticks × learned per-tick amount |

**Instant heals are deliberately not predicted.** They fire no `_START`; the
heal lands in the same frame the cast completes, so there is nothing to predict
and a segment that appears and vanishes within one frame is noise.

### HoTs

For each helpful aura on the unit where `castByPlayer` is true and the spellID
has a learned *periodic* amount:

```
predicted = ticksRemaining * learnedTickAmount
ticksRemaining = ceil((expirationTime - now) / tickInterval)
```

`tickInterval` is learned the same way everything else here is — from the gap
between consecutive observed ticks of that spellID — defaulting to 3.0 and
clamped to `[1, 6]`, the band idiom from `BarSweep`'s `MIN_INTERVAL` /
`MAX_INTERVAL`. Aura reads go through `Compat.GetAura`, never a raw `UnitAura`.

### No fourth ticker — the §5.7 position

Plan 2 had to argue for a fourth ticker. **This plan needs none**, and that is a
deliberate property of the design rather than luck:

* A direct-cast prediction changes only at cast start and cast end. Both are
  events.
* A HoT's predicted remainder changes only when a tick lands or the aura is
  applied, refreshed or removed. Every one of those is an event —
  `SPELL_PERIODIC_HEAL` and `UNIT_AURA`.
* Between those moments the predicted number is **constant**, so there is
  nothing for a timer to do.

Staleness is handled by **lazy expiry**: `IncomingHeal(unit)` compares `GetTime()`
against the stored cast end plus a grace period and returns zero for anything
past it. No timer object, nothing to leak, nothing to idle.

### The performance risk, and its mitigation

`COMBAT_LOG_EVENT_UNFILTERED` is the noisiest event in the game and it cannot be
unit-filtered. In a 25-man instance it fires thousands of times a minute, and
§6 budgets 0.5 ms/frame for exactly that scenario. Three mitigations, in order:

1. **Registered only while something wants it.** The listener follows
   `BarSweep`'s attach/detach discipline: it registers when the first frame
   enables the element and unregisters when the last one stops. With the feature
   off it is not merely idle, it is not subscribed.
2. **First check is `sourceGUID ~= playerGUID` → return.** One comparison
   against a hoisted local, before any string work, table lookup or allocation.
3. **No per-event allocation.** `CombatLogGetCurrentEventInfo()` is read
   positionally into locals; nothing builds a table per line.

`/duf profile` reports the listener's state and the learned-spell count, in the
same spirit as the other derived values: a derived value nobody can see is a
derived value nobody can check.

### Drawing, and what "+10% overflow" means

Two textures created on the health bar itself — `el.bar:CreateTexture(nil,
"ARTWORK", nil, 2)` — above the StatusBar's own fill at ARTWORK/0 and below the
OVERLAY layer that `BarSweep`'s lines and the text engine use. Being children of
the bar, they inherit its alpha and hide with it automatically, which is the
same reasoning `BarSweep:Attach` records for its lines.

Geometry, with `W` the bar width and `scale = W / UnitHealthMax(unit)`:

```
cursor = UnitHealth(unit) * scale              -- where the health fill ends
limit  = overflow and W * (1 + amount) or W    -- how far anything may draw

for each segment in { direct, hot }:
    x0 = min(cursor, limit)
    x1 = min(cursor + segment * scale, limit)
    draw at x0, width (x1 - x0)   -- hidden when under 1px
    cursor = cursor + segment * scale
```

Full health still fills the bar exactly and the health bar's meaning is
unchanged; a heal that would overheal visibly spills past the end, which is the
entire point of the setting. `inverseFill` mirrors it: anchor from `TOPRIGHT`
and grow leftward.

**The overhang leaves the frame.** It draws outside the frame's bounds and over
the border edges, which live on `frame.overlay` at a higher frame level and so
still draw on top. On horizontally-packed party frames it can reach into the
neighbour. That is inherent to what was asked for; the setting is a slider and
the answer to disliking it is to turn it down.

### Where it renders nothing

* `Compat.HasRealHealthValues(unit)` is false — non-group units report health on
  a 0–100 scale, so an absolute heal amount cannot be converted to a fraction of
  a max health nobody knows. Silent, per the answer given.
* The unit is dead, a ghost, or offline — the health bar already renders 0.
* The health element is disabled on that unit. `IsEnabled(frame, cfg)` checks
  `frame.cfg.health.enabled`, since the textures have no parent bar without it.

### Test mode

`Config/TestMode.lua` already substitutes identity through `frame.test`, which
`Colors:Class` reads. It gains a synthetic prediction on the same table so the
colours and the overflow can be tuned at the config panel without waiting for a
real cast. The element checks `frame.test` before asking the system, mirroring
`Colors:Class(unit, frame)`.

---

## Files

| File | Change |
|---|---|
| `Systems/HealPrediction.lua` | **New.** Providers, combat-log listener, learned-amount store, lazy expiry, `IncomingHeal(unit)`, `Refresh(guid)`, `Reset()` for tests |
| `Elements/HealPrediction.lua` | **New.** Element at order 11: two textures, overflow geometry, inverse-fill mirroring, test-mode stand-in |
| `DyrueUnitFrames.toc` | Two entries — `Systems/HealPrediction.lua` after `BarSweep`, `Elements/HealPrediction.lua` after `HealthBar` |
| `Core/Defaults.lua` | `healPrediction` block in `unit()`; `Defaults:EnsureChar` for the learned store |
| `Core/Core.lua` | Call `EnsureChar` in `OnInitialize`; heal-prediction lines in `ProfileReport` |
| `Core/Compat.lua` | Probes for `UnitGetIncomingHeals`, `UnitGetTotalAbsorbs`, `UNIT_HEAL_PREDICTION`, surfaced through `Compat.Describe` |
| `Config/Options_Layout.lua` | Sub-group inside `healthGroup`: enable, separate colours, two swatches, opacity, overflow toggle, overflow amount |
| `Core/Locale.lua` | Every new user-facing string (§11.4) |
| `Tests/wowstub.lua` | `CombatLogGetCurrentEventInfo`, the `UNIT_SPELLCAST_*` events, `GetTime` control, helpful-aura injection |
| `Tests/tests.lua` | `testHealPrediction()` — see below |
| `Documents/SPEC.md` | §2.2 amendment (strike the exclusion), §2.3 note |
| `Documents/COMPAT_FINDINGS.md` | API-survey rows for the three probes; the §2.2 deviation argument |

---

## Schema and migration

**No `SCHEMA_VERSION` bump.** This adds keys and changes no stored value.
`Defaults:EnsureProfile` deep-fills `healPrediction` into every profile that
lacks it, which is the free path described in `Core/Defaults.lua`'s header and
the same path Plan 2's `tick` and `fsr` blocks took.

Contrast with Plan 9, which *did* bump — it moved the target's buff row, an
existing stored value, and needed a rule for telling an untouched default from a
deliberate choice. Nothing here has that shape.

The learned-amount store in `ns.db.char` is derived data with no user meaning
and is safe to discard at any time; `EnsureChar` creates it empty and a wipe
costs one cast per spell to relearn.

Defaults, and why:

| Key | Default | Reason |
|---|---|---|
| `enabled` | `true` | Asked for: "predictive healing for all health bars". Deviates from the `sweep()` precedent of shipping off, deliberately |
| `separateColors` | `true` | The two categories answer different questions |
| `directColor` | green, distinct from the health fill | Must read as "more health arriving", not as part of the bar |
| `hotColor` | blue-ish | Distinguishable from the direct colour at a glance and from a class-coloured bar behind it |
| `alpha` | `0.55` | Translucent so the bar's own colour reads through. Its own key rather than the swatch's alpha channel, following the reasoning recorded on `sweep()` |
| `overflow` | `true` | Asked for explicitly |
| `overflowAmount` | `0.10` | Asked for explicitly |

---

## Tests

A new `testHealPrediction()` in `Tests/tests.lua`. The stub needs
`CombatLogGetCurrentEventInfo` and a settable clock first; both are additions to
`Tests/wowstub.lua` rather than changes to existing behaviour.

Assertions, grouped by the thing that would break:

**The estimator**
* A `SPELL_HEAL` of `amount = 100, overhealing = 400` teaches **500**, not 100.
  This is the single most important assertion in the file — getting it wrong
  produces a feature that silently under-predicts on exactly the targets a
  healer cares about, and it would never be caught by eye.
* A crit sample leaves the learned value unchanged.
* A heal from another source GUID leaves the learned value unchanged.
* Two samples blend rather than replace.

**Prediction lifecycle**
* `SENT` + `START` for a learned spell → `IncomingHeal` returns that amount for
  the resolved GUID and zero for every other.
* `SUCCEEDED` clears it.
* `INTERRUPTED` clears it.
* An unlearned spell predicts zero — the documented first-cast behaviour,
  asserted so it stays deliberate.
* A prediction past its end time plus grace returns zero **without any timer
  having run** — this is what pins the no-ticker design.

**Geometry** — the overflow arithmetic, against a bar of known width:
* At full health with overflow off, a large predicted heal draws zero width.
* At full health with overflow at 0.10, the same heal draws exactly 10% of the
  bar width and no more.
* At half health, a heal worth 25% of max draws 25% of the bar width starting at
  the midpoint.
* Direct and HoT segments abut, in that order, with the HoT clipped at the limit
  when the pair overruns.
* `inverseFill` mirrors both segments.

**Gating**
* A unit failing `Compat.HasRealHealthValues` draws nothing.
* A dead unit draws nothing.
* With health disabled, the element reports not-enabled rather than erroring.

**Idle-to-zero**
* With the element off on every unit, the combat-log listener is unregistered —
  asserted directly, because this is the §6 performance claim and an assertion
  is the only thing that keeps it true.

**Gap in the existing suite this exposes:** nothing currently drives
`COMBAT_LOG_EVENT_UNFILTERED` or the spellcast events at all, so the stub work
here is the first coverage of either. Plan 10's `spellcast` trigger — parked in
`BarSweep.TRIGGERS` pending exactly this kind of plumbing — becomes cheap
afterwards.

---

## Risks

| Risk | Handling |
|---|---|
| **Combat-log cost in a raid** | The three mitigations above, in that order. `/duf profile` reports the listener state so "is it actually idle when it should be idle" is answerable, per §5.7's discipline |
| **First cast of each spell predicts nothing** | Accepted and documented in the option's description text, not hidden. One cast per spell per character. The alternative — a rank/coefficient database — is thousands of lines that go stale |
| **`UNIT_SPELLCAST_SENT` gives a name, not a GUID** | Resolved against the ≤ 12 units this addon draws. Ambiguity needs two units with the same name in your own party, which is not reachable |
| **A cast that ends with no event leaves a stale segment** | Lazy expiry zeroes the *value*; the redraw arrives with the `UNIT_HEALTH` the landing heal causes. Residual: a cast that ends with neither event nor heal leaves one stale frame until the next event on that unit. Accepted |
| **Overhang collides with an adjacent frame** | Inherent to the request. The amount is a slider and 0 disables it; documented in the option's description |
| **The learned store grows unboundedly** | It is keyed by spellID and bounded by the number of healing spells a character has — tens of entries, never thousands. No pruning needed, and saying so beats adding a sweep nobody can test |
| **Probe comes back saying `UnitGetIncomingHeals` exists** | The provider table is the seam. An `api` provider is a table entry, and it would still need the own-casts provider for HoTs, which that API has never covered |
| **Blizzard changes combat-log argument order** | Contained: all of it is read in `Systems/HealPrediction.lua`, and the parse is one function. This is the same containment bet §5.5 makes everywhere else, though note the parse lives in the system rather than in `Compat` — if it needs a second reader, move it |

---

## Estimate

| Piece | Hours |
|---|---|
| `Systems/HealPrediction.lua` | 3–4 |
| `Elements/HealPrediction.lua` | 1.5–2 |
| Defaults, Options, Locale, TOC | 1.5 |
| Stub extensions + `testHealPrediction` | 2–3 |
| Compat probes, SPEC amendment, COMPAT_FINDINGS | 1 |
| **Total** | **9–12** |

Comparable to Plan 9, with more of the weight in the test harness because the
combat-log plumbing is new ground for the suite.

Plan 12 (absorbs) drops into the second colour slot and the same geometry loop
afterwards, and should be materially cheaper for having this in place.
