# Plan 19 — Group Heal Prediction

**Status:** In progress on `Plan-19-group-heal-prediction`. **Extends Plan 11.**
**Design rewritten 11 August 2026** after the probe results below. The original
design — deriving other people's heals from the combat log — is preserved in
*What was measured and closed*, because three separate routes were investigated
and all three are dead, and the next person should not re-open them.
**Created:** 9 August 2026
**Branch:** `Plan-19-group-heal-prediction`

---

## Progress

**Done: four probes, all on `main`.**

| Probe | Commit | Answered |
|---|---|---|
| `/dufprobe heals` | `eb84978` | The combat log carries no cast target; other units' cast events do work; aura casters resolve at raid distance |
| `/dufprobe healcomm` | `87d6e4d` | LibHealComm has one broadcaster in a 25-man |
| `/dufprobe incoming` | `5ebd64b` | **`UnitGetIncomingHeals` works and includes other people's heals** |
| robustness fixes | `ebee3c4` | Unknown subcommands no longer masquerade as a survey; interrupted runs survive |

Findings are written up in `Documents/COMPAT_FINDINGS.md` under *Plans 11, 12
and 19 — incoming heals* (`762f9eb`).

**Not started:** any of the implementation below. `Systems/`, `Elements/`,
`Core/` and `Config/` are untouched on the branch.

**Blocking nothing** — but see *Risks*, where two open measurements would each
change a design decision, and one of them is cheap.

---

## Request

> I want to extend on the predictive healing feature. Currently it works fine for
> my heals onto others, but I want to see predictive healing for others, at least
> those in my party/raid, if not from everybody. First, determine whether this is
> a feasible request - if it is, then ask me any follow-up questions you need,
> then make a plan.

---

## Feasibility — the answer changed twice

**Yes. The game will just tell us.**

`UnitGetIncomingHeals(unit)` is present on TBC Anniversary 2.5.6, returns real
numbers, and **includes heals cast by other players** — measured at 688 non-zero
samples in 90 seconds, peaking at 13,223, with a median of **1.08 s of lead
time** before the heal lands. `UNIT_HEAL_PREDICTION` fires 900 times in the same
window, so it is pushed rather than polled.

This row was recorded in `COMPAT_FINDINGS.md` as **Absent — Cataclysm-era** since
Plan 11, on the reasoning that the API postdates these clients. That reasoning is
wrong for the same reason `UNIT_COMBO_POINTS` disappeared: **Anniversary runs the
modern shared codebase**, so "expansion X introduced it" says nothing about what
is present.

`/duf compat` has reported `hasIncomingHeals` since Plan 11 shipped, specifically
so this would be checkable. It went unrun for three days while three harder
routes were investigated. That is the process lesson and it is recorded in
`COMPAT_FINDINGS.md` rather than here.

### What is still not solved by the API

**HoTs.** The value was non-zero in only 13% of samples, in bursts, with lead
times shaped like cast times rather than a HoT's 12–15 s plateau — consistent
with this API's historical direct-casts-only behaviour. So the HoT half of this
plan survives intact and is still built from aura reads, which the probe also
confirmed work at raid distance.

The feature therefore splits the way it always did, but the *hard* half moved:

| Half | Source | State |
|---|---|---|
| Direct casts, anyone | `UnitGetIncomingHeals` + `UNIT_HEAL_PREDICTION` | An API call |
| HoTs, anyone | Aura scan + learned per-tick amounts | The real work |

---

## What was measured and closed

Recorded so nobody re-investigates. Full numbers in `COMPAT_FINDINGS.md`.

| Route | Why it is dead |
|---|---|
| Combat log `SPELL_CAST_START` | 368 lines, **zero** with a destination, against a `SPELL_CAST_SUCCESS` control carrying one in 78% of 1046 |
| `UNIT_SPELLCAST_SENT` for other units | Player-only, confirmed by absence across two raids |
| LibHealComm, vendored | Classic branch stopped September 2022 at TOC 1.13.3; throws `tickInterval` errors on live clients |
| LibHealComm, receive-only | **1 broadcaster out of 18 active healers** in a 25-man |
| HealEngine (HealPredict) replicated | Also comms — its own `/hp rc` audits the group for it — All Rights Reserved, and an audience of one |
| Caster's own target (`raidNtarget`) | A guess. Never needed now |

One genuinely useful thing came out of the dead ends: `UNIT_SPELLCAST_START`
fires for raid tokens and `UnitCastingInfo` reads back for them (25/25). Not
needed here, but it is the answer to "can this addon ever show another unit's
cast bar", which SPEC §2.2 lists as impossible.

---

## Interpretation

The four clarifications, and how the probes changed them:

| Question | Answer given | Status after measurement |
|---|---|---|
| How far should the direct-cast half go? | HoTs now, direct gated on the probe | **Superseded.** The direct half is an API call, so it ships |
| Should other people's heals look different from yours? | No — merge | **Stands**, and is now also the cheap option: the API returns one total, and splitting it needs a form this plan does not trust (see Risks) |
| Whose heals count as a source? | Party and raid only | **Partly moot.** The API returns what it returns; scope cannot be enforced on the direct half. Retained only as the bound on HoT *learning* |
| Does raid frame coverage change the ask? | No | **Stands.** Still `player`, `target`, `focus`, `pet` and `party1-4` |

**No new user-facing setting.** The original design added
`general.healSources` to choose between own and group sourcing. With the API that
choice does not exist for direct heals, so a control offering it would be a lie
for half the feature. Which path is live is a property of the client, reported by
`/duf compat`, not a preference. Same reasoning Plan 10 used to withhold a
one-value dropdown.

---

## Design

### Direct heals: read them

`Compat.GetIncomingHeals(unit)` already exists (`Core/Compat.lua:239`) and
already returns `nil` — distinct from `0` — when the client has no such API.
That nil-versus-zero distinction is exactly the branch this needs, and it was
built by Plan 11 for this contingency.

```
direct = Compat.GetIncomingHeals(unit)
if direct == nil then          -- no API on this client
    direct = <Plan 11's derived own-cast prediction>
end
```

**The two paths are alternatives, never a sum.** The API total already includes
the player's own casts, so adding the derived value on top would double-count
every heal you cast. This is the single easiest way to get this wrong and it is
asserted in the tests.

**Only the one-argument form is used.** The filtered
`UnitGetIncomingHeals(unit, "player")` returned zero on all 5120 calls while the
player cast two heals, so whether it filters at all is unproven — see Risks. A
"my heals versus theirs" display would rest entirely on that form and is
therefore not built.

### What this deletes

When the API is live, Plan 11's direct-cast machinery is redundant: `state.current`,
`state.sent`, the name-resolution scan over `CANDIDATE_UNITS`, the ten
`UNIT_SPELLCAST_*` subscriptions and the lazy-expiry logic all exist to
reconstruct a number the game now hands over.

It is **kept, not deleted**, because Classic Era is untested and may still need
it. But it becomes the fallback branch rather than the main path, and the
listener's subscriptions become conditional: with the API present, the spellcast
events are not registered at all.

That is a real performance win on top of a correctness win — the remaining
combat-log interest is `SPELL_PERIODIC_HEAL` only.

### HoTs: the half that is still real work

Unchanged from the original design, which the probes validated:

* `HotTotal` drops its `aura.castByPlayer` filter (`Systems/HealPrediction.lua:292`).
  `Compat.GetAura` already returns the caster in `a.source`, and the probe
  confirmed that resolves at raid distance with orphans limited to hour-long
  raid buffs.
* Per-tick amounts are keyed by caster as well as spell — another druid's
  Rejuvenation is not yours — in a **session-only** store, never persisted,
  written only for roster GUIDs and pruned on `GROUP_ROSTER_UPDATE`. Bounded by
  group size.
* Read order: that caster's learned value, then a cross-caster mean for the
  spell, then nothing. Predicting zero is Plan 11's documented honest failure.
* `NoteTick` gains a caster guard. Two druids' Rejuvenations on the *same*
  target interleave, and that gap is not a tick interval — the sideways version
  of the same-target trap already handled there.

The player's own `ns.db.char.heals` store is untouched and still persisted.

### The push event, and the trap it walks into

`UNIT_HEAL_PREDICTION` is added to the element's `events` table. It fires for
`party*`, `raid*` and `targettarget`, so no ticker is needed and SPEC §5.7 needs
no new argument.

**But `Compat.RegisterUnitEvent` silently skips events `HasEvent` rejects.**
That is exactly how Plan 9 shipped a combo bar subscribed to nothing, and it is
recorded in `COMPAT_FINDINGS.md` as the shape to watch for. So the element
declares `UNIT_HEAL_PREDICTION` **alongside** the events it already has, and the
existing `UNIT_HEALTH` / `UNIT_MAXHEALTH` / `UNIT_AURA` subscriptions remain the
floor. If the push event is absent, the prediction is refreshed by the health
event the landing heal causes — one frame later than ideal, never stale.

`/duf compat` already reports `hasUnitHealPrediction`, so which path is live is
answerable in game.

### Drawing

`Elements/HealPrediction.lua` is otherwise untouched. Same two segments, same
merged colours, same overflow geometry, same Plan 16 cap band.

---

## Files

| File | Change |
|---|---|
| `Systems/HealPrediction.lua` | API-first direct path with the derived path as fallback; conditional spellcast subscriptions; roster set; per-caster session store with pruning; caster-aware `NoteTick`; scope predicate in `HotTotal`; `Describe()` reports which direct path is live |
| `Elements/HealPrediction.lua` | One line: `UNIT_HEAL_PREDICTION` in `events` |
| `Core/Compat.lua` | Nothing required — `GetIncomingHeals` and `hasIncomingHeals` already exist. Header comment corrected: it currently asserts the API is absent |
| `Config/Options_Layout.lua` | Rewrite the `note` string; it claims only your own heals are visible. **No new rows** (Plan 3) |
| `Tests/wowstub.lua` | `UnitGetIncomingHeals`, `UNIT_HEAL_PREDICTION`, roster stubs, `source` on injected auras |
| `Tests/tests.lua` | See below, including a new pass for a client without the API |

**Not touched, and deliberately:** `Core/Defaults.lua` and `Core/Migrate.lua` —
this adds no key. `Core/Locale.lua` — enUS is the identity mapping. `SPEC.md` —
§2.2 was already amended by Plan 11.

---

## Schema and migration

**Nothing.** No new keys, no changed values, no `SCHEMA_VERSION` bump, no
migration. The original design added one key; the API removed the need for it.

`Tests/tests.lua` pins `SCHEMA_VERSION` as an absolute number and will need
re-pinning if `main` moves under the branch — the trap that failed Plan 11's
rebase.

---

## Tests

**The one that matters most**

* With the API present, the prediction equals the API's value and the derived
  own-cast path contributes **nothing**. Double-counting your own heals is the
  likeliest defect here and would look plausible on screen.

**Path selection**

* API absent (`GetIncomingHeals` returns nil) → the derived path runs and Plan
  11's existing assertions all still pass.
* API present → the spellcast events are **not registered**. Asserted directly,
  because it is the performance claim.
* A new suite pass modelling a client without the API, mirroring pass 3's legacy
  aura path. A stub that models a more capable client than the real one turns
  the suite into a rubber stamp — this file's own recorded lesson.

**HoTs**

* An aura with `source = "party2"` counts; `source = nil` does not.
* Two casters' ticks of one spellID learn separately; a caster with no sample
  falls back to the spell mean; with nothing anywhere, zero.
* The player's persisted store is unchanged by another caster's ticks.
* Interleaved ticks from two casters on the same target produce no interval
  sample.
* Casters leaving the roster are pruned.

**Events**

* `UNIT_HEAL_PREDICTION` drives an update.
* With the event absent, `UNIT_HEALTH` still refreshes the element — the Plan 9
  silent-no-subscribe guard.

---

## Risks

| Risk | Handling |
|---|---|
| **The API might include HoTs after all** — if it does, the aura path double-counts them | The top risk, and cheap to close: run `/dufprobe incoming` while a HoT ticks on you and nobody is casting. Non-zero means it covers HoTs and the aura path becomes a fallback rather than an addition. The 13%-of-samples burst pattern says it does not, which is evidence rather than proof |
| **Classic Era is untested** | `/duf compat` on a 1.15.9 character answers it in one command. The design already branches on `Compat.hasIncomingHeals`, so a "no" costs nothing but keeps the derived path load-bearing |
| **The two-argument form is unproven** | Not used. Nothing in this plan depends on separating your heals from other people's, and the merge-colours answer means nothing needs to |
| **`UNIT_HEAL_PREDICTION` silently not registered** | The element keeps its existing event subscriptions as a floor, so absence costs a frame of latency rather than a dead feature. `/duf compat` reports it |
| **API returns a value for a unit whose health is 0–100** | `Elements/HealPrediction.lua:301` already blanks on `HasRealHealthValues`. Unchanged |
| **Session store keyed by another player's GUID** | Roster GUIDs only, pruned on roster change, never persisted |
| **Combat-log cost for HoT learning** | Narrowed rather than widened: with the API live the only subevent of interest is `SPELL_PERIODIC_HEAL`. Measured at ~49 lines/s in a 24-man |

---

## Estimate

| Piece | Hours |
|---|---|
| `Systems/HealPrediction.lua` — API path, fallback branch, conditional subscriptions | 1.5–2 |
| HoT widening — roster, per-caster store, tick guard | 2–3 |
| Element event, options text, `/duf profile` line | 0.5 |
| Stub extensions, tests, the no-API suite pass | 2 |
| **Total** | **6–7.5** |

Down from 7.5–10, and the reduction is entirely in the direct half — which was
the part three probes could not solve and one API call does.

The probes themselves cost more than the remaining implementation will. That is
the correct trade and would have been cheaper still in the other order: the
capability flag was one slash command away the whole time.
