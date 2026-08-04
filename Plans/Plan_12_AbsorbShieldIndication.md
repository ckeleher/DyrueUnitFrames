# Plan 12 — Absorb Shield Indication

**Status:** Not started. **Depends on Plan 11.**
**Created:** 3 August 2026
**Branch:** `Plan-12-absorb-shields`

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

The same request produced Plan 11. It was split on the user's instruction during
the clarification round: heal prediction ships first, **absorb shields are this
plan**. This document covers only the shielding third.

---

## Why this is a separate plan

Heal prediction and absorb display look like one feature — both are a coloured
segment after the health fill — and they are not.

A predicted heal is a number the game will shortly make true, and it is wrong
for at most a second or two. **An absorb shield is a number the game will never
tell you.** There is no `UnitGetTotalAbsorbs` on these clients, no
`SPELL_ABSORBED` subevent (that arrived in Legion), and — the part that actually
bites — nothing anywhere reports *how much of a shield is left*. A Power Word:
Shield that has eaten 90% of its capacity looks identical, through every API
this client has, to one cast a moment ago.

So the accuracy ceiling here is materially lower than Plan 11's, and the failure
mode is worse: a stale shield segment sits on the bar looking authoritative for
as long as the aura lasts. That is worth its own plan and its own decision
rather than being carried in on the back of a feature that works properly.

---

## Interpretation

The user chose **rank table + combat-log decay** from the clarification options:
detect the aura, establish its nominal size, then subtract absorbed damage
observed in the combat log while it is up. Explicitly rejected in that round:
showing the full nominal value with no decay ("visibly wrong mid-fight"), and a
presence-only marker.

Scope follows Plan 11's answer of **own casts now, group later**: shields the
player cast. That covers the cases a solo or small-group player actually looks
at — a mage's Ice Barrier and Mana Shield, a warlock's Sacrifice and Wards, a
priest's Power Word: Shield on self or on a party member. Somebody else's shield
on somebody else is unsizeable in principle without their gear, and is the same
problem a LibHealComm provider would solve for both plans at once.

---

## Diagnose before designing

The data source is not known, and three candidates are not equally good. This
plan does **not** pick one and design around a guess. Probe first, in one
session, via `Probe/DyrueUnitFrames_Probe`:

| # | Candidate | What to check | If it holds |
|---|---|---|---|
| 1 | `UnitGetTotalAbsorbs` exists after all | Call it on `player` with a shield up. Plan 11 already adds this to `/duf compat`, so the answer may be in hand before this plan starts | Everything below is deleted. Read the number, draw the segment. Two hours of work total |
| 2 | The aura tooltip carries the remaining amount | Scan the Power Word: Shield buff tooltip on yourself, shielded and part-consumed. Some clients render "Absorbs N damage" live | Best realistic outcome: exact remaining value, no decay bookkeeping, no rank table. Locale-dependent parse, enUS only, which §11.4 already accepts |
| 3 | Estimate and decay | The fallback, designed below | Approximate but always available |

Candidate 2 is worth ten minutes of a probe before anyone writes candidate 3.
It is genuinely uncertain — the tooltip behaviour differs by expansion and has
never been verified on 1.15.9 or 2.5.6 — and it is the difference between an
exact readout and an estimate that drifts.

---

## Design — candidate 3, the fallback

### Sizing a shield without a rank table

Plan 11 refuses to hardcode heal amounts and learns them from the combat log
instead. The same trick works here, and it is worth using for the same reasons.

**A shield's capacity is observable exactly once: at the moment it is consumed.**
Track the absorbed damage accumulating against a shield from application. If the
aura disappears because it ran out — rather than because it timed out or was
dispelled — then the sum of absorbed damage over its life *is* its capacity.
Learn that against the spellID, blended with the same smoothing constant Plan 11
uses, and future casts of that rank start at the learned figure.

* Samples where the aura expired on duration are **discarded**, not recorded:
  they are a lower bound, and folding a lower bound into an average drags the
  estimate down every time you shield somebody who is not being hit.
* Distinguishing "consumed" from "timed out" is `expirationTime - GetTime()` at
  the moment `UNIT_AURA` reports it gone. Comfortably above zero means it was
  consumed.
* The store lives beside Plan 11's learned heal amounts in `ns.db.char`, keyed
  by spellID, for the same reason: shield size is a function of this
  character's gear and talents.

Same accepted cost as Plan 11, one step worse: a shield rank predicts nothing
until one of them has been fully eaten. A shield you cast and never break is
never learned. Documented in the option text, not hidden.

### Decay

While a tracked shield is up, subtract the `absorbed` field from damage events
landing on that unit. Classic has no `SPELL_ABSORBED` subevent, so the field on
`SWING_DAMAGE` / `SPELL_DAMAGE` / `RANGE_DAMAGE` is the only source.

**The multi-shield problem.** The `absorbed` field says how much was absorbed,
never by which shield. With a Power Word: Shield and an Ice Barrier both up,
attribution is guesswork. The rule:

> One tracked shield on a unit → attribute fully and decay.
> More than one → **stop decaying**, show the summed nominal values, and treat
> the segment as approximate.

Guessing an attribution order would be inventing a game mechanic. Freezing the
decay is visibly conservative, and the case is rare outside a mage shielding
through a priest's bubble.

### Drawing

Nothing new. Plan 11 builds a segment loop that walks `{ direct, hot }` and
clips each against the overflow limit; this adds `absorb` as the third entry,
a third colour swatch, and a third texture. The overflow behaviour, the
inverse-fill mirroring and the `HasRealHealthValues` gating are all inherited.

Ordering is `direct → hot → absorb`, absorb last, because it sits conceptually
*outside* the health pool rather than adding to it.

### Where it renders nothing

Everything Plan 11 gates on, plus: no learned capacity for that shield's
spellID, and — while the probe question is open — no tracked shield at all if
candidate 1 or 2 lands and makes this whole section moot.

---

## Files

Assumes Plan 11 has landed; nearly everything here is an addition to files it
created.

| File | Change |
|---|---|
| `Systems/HealPrediction.lua` | Absorb tracking: aura scan, capacity learning, decay accounting, the multi-shield freeze. `IncomingHeal` gains a third return |
| `Elements/HealPrediction.lua` | Third texture, third entry in the segment loop |
| `Core/Defaults.lua` | `absorbColor`, `showAbsorbs` in the existing `healPrediction` block |
| `Config/Options_Layout.lua` | Third swatch and its toggle in the existing sub-group |
| `Core/Locale.lua` | New strings |
| `Core/Compat.lua` | `UnitGetTotalAbsorbs` probe if Plan 11 has not already added it; tooltip-scan accessor if candidate 2 holds |
| `Probe/DyrueUnitFrames_Probe` | `/dufprobe absorb` — the three candidates above |
| `Tests/tests.lua` | `testAbsorbShields()` |
| `Documents/COMPAT_FINDINGS.md` | Which candidate won, with the date and build |

---

## Schema and migration

**No `SCHEMA_VERSION` bump.** Added keys only, filled by
`Defaults:EnsureProfile` — the same free path Plan 11 takes.

`showAbsorbs` defaults **on**, matching the request. `absorbColor` defaults to a
pale gold: it has to read as "not health" against a class-coloured bar and
against both of Plan 11's colours, and gold is the convention every unit frame
addon has landed on independently.

---

## Tests

* Capacity is learned from a shield consumed to zero, and **not** learned from
  one that timed out with duration remaining. The second assertion is the one
  that matters — it is the difference between a converging estimate and one that
  ratchets downward every quiet pull.
* Absorbed damage decays the tracked remainder.
* With two tracked shields up, decay freezes and the reported value is the sum.
* A shield with no learned capacity reports zero rather than guessing.
* The absorb segment draws third, after direct and HoT, and clips at the same
  overflow limit.
* Aura removal clears the tracked shield.

---

## Risks

| Risk | Handling |
|---|---|
| **The estimate drifts and looks authoritative** | The core risk of the whole plan, and why it is separate. Mitigated by conservative rules — freeze on ambiguity, never learn from a lower bound, show nothing rather than guess — and by candidate 2 removing it entirely if the probe lands |
| **Damage absorbed off-log** | A party member taking hits outside your combat-log range decays nothing and the segment stays too wide. No fix available; a reason to prefer candidates 1 and 2 |
| **Multiple shields** | Decay freezes; documented above |
| **Combat-log volume** | Already paid for by Plan 11: same listener, same `sourceGUID`/destination early-out, same registered-only-when-wanted discipline. This adds a branch, not a subscription |
| **Shield capacity varies with the caster's spellpower** | Own casts only, so the caster is always the player and the learned value is always about the right gear. Revisit with a LibHealComm-style provider, never before |

---

## Estimate

| Piece | Hours |
|---|---|
| Probe the three candidates, in game | 0.5 |
| **If candidate 1 or 2 holds:** accessor, segment, options, tests | **2–3 total** |
| **If not:** capacity learning + decay accounting | 3–4 |
| Options, defaults, locale | 0.5 |
| `testAbsorbShields` | 1.5 |
| **Total, fallback path** | **5.5–6.5** |

Half a day if the probe is kind, most of a day if it is not. Do not start
writing candidate 3 before the probe has run — that is the whole reason this is
a separate plan.
