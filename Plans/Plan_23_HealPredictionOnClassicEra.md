# Plan 23 — Heal Prediction on Classic Era

**Status:** Not started. **Depends on Plan 19** (merged, `ce6e5ec`).
**Created:** 11 August 2026
**Branch:** `Plan-23-era-heal-prediction`

---

## Origin

One of three items left open when Plan 19 was archived. Every live measurement
behind Plan 19 was taken on TBC Anniversary. Classic Era reports the same API as
**present**, and that is the whole of what is known about it there.

## Request

> all three should get their own plans - two new plans, plus a rewrite of plan 12
> to address absorbs

---

## Why this is a plan and not a chore

It would be easy to file this as "go and check". The reason it is not:

**The addon gates on `Compat.hasIncomingHeals`, which is a presence flag.**

```lua
Compat.hasIncomingHeals = (_G.UnitGetIncomingHeals ~= nil)
```

This project has now been burned by presence-is-not-function **three times**,
and `COMPAT_FINDINGS.md` records all three:

1. `UNIT_COMBO_POINTS` was gone while `GetComboPoints` still worked — Plan 9
   shipped a combo bar subscribed to nothing.
2. `issecretvalue` exists on both clients and nothing is secret.
3. `Compat.hasFocus` is true on Era, where `/focus` does nothing — Plan 21.

Plan 19 avoided the trap on TBC by measuring the function rather than trusting
the flag. **On Era nobody has measured it.** If the function is present and
inert there, the addon's direct prediction silently shows nothing, `/duf profile`
still reports `api direct`, and the derived fallback that would have worked never
runs — because it is gated on the function being absent, not on it being useless.

That is a live, plausible, silent failure on one of two supported clients. It is
worth a plan.

---

## Phase 0 — measure, and the plan may end here

Two runs on a Classic Era character, in a group taking damage:

| Step | What it answers |
|---|---|
| `/dufprobe incoming era` | Does the API return non-zero on Era, does it include other people, and does `UNIT_HEAL_PREDICTION` fire there |
| Play with the addon on, then `/duf profile` | `api direct` should be reported, and the bar should actually show incoming heals |

**If both come back healthy, this plan closes with no code changed.** That is a
successful outcome, and saying so up front is the point — a verification plan
that only "succeeds" by finding a defect will find one.

Record the result in `COMPAT_FINDINGS.md` either way, in the Era column of the
incoming-heals section, which currently says nothing about live behaviour.

---

## Design — only if the API is inert on Era

Three options, in increasing cost. **The plan does not pick one before Phase 0**;
it names them so the decision is quick when the data arrives.

### 1. Report it, and let the user switch (recommended)

Mirror `Compat.SetFocusOverride`, which exists for exactly this shape and whose
comment says so: *"purely so a wrong probe on a future patch is a setting change
rather than a broken install."*

* `general.healPredictionSource = "auto" | "api" | "derived"`, default `auto`.
* `HealPrediction` records whether the API has **ever returned non-zero this
  session** and `/duf profile` reports it.

**The observation cannot flip the path on its own**, and that limit is the honest
part: a quiet session legitimately has no incoming heals, so "never non-zero" is
indistinguishable from "nobody healed you". It can be *reported*, not acted on.
The setting is the fix; the report is what tells you to use it.

### 2. Gate on the TOC version

The Plan 21 answer, if it turns out Era is uniformly inert. Cheap and honest, but
it needs the same SPEC argument Plan 21 makes, and it should not be reached for
before option 1 — a setting is reversible by the user, a version gate is not.

### 3. Run both paths and prefer whichever is non-zero

Rejected pre-emptively, recorded so nobody proposes it later. It doubles the
work on every read, it re-registers the ten spellcast subscriptions Plan 19
removed, and it cannot distinguish "the API is broken" from "nobody is healing
you" — which is the same wall option 1 hits, with more machinery.

---

## Files

Everything below is conditional on Phase 0 failing.

| File | Change |
|---|---|
| `Systems/HealPrediction.lua` | Record first non-zero from the API; honour the source override when choosing the direct path |
| `Core/Defaults.lua` | `general.healPredictionSource` |
| `Config/Options.lua` | The dropdown, in the General tab beside `focusOverride` — same kind of thing, same place |
| `Core/Core.lua` | `/duf profile` reports whether the API has produced a value |
| `Documents/COMPAT_FINDINGS.md` | **Unconditional.** The Era result gets recorded whatever it is |

## Schema and migration

One added key if option 1 is taken, no changed values, **no `SCHEMA_VERSION`
bump**. If Phase 0 passes, no schema change at all.

## Tests

* A pass, or a scripted setup, where `UnitGetIncomingHeals` exists and always
  returns 0: the addon must still be usable, and `/duf profile` must say the API
  has produced nothing.
* `healPredictionSource = "derived"` forces Plan 11's path even where the API is
  present, and re-subscribes the spellcast events.
* `"api"` forces the API path even if it has never produced a value.
* `"auto"` behaves exactly as the merged code does today — the assertion that
  keeps this plan from changing anything for TBC users.

## Risks

| Risk | Handling |
|---|---|
| **Phase 0 is inconclusive** — a quiet group produces no heals either way | The probe already distinguishes "nothing sampled" from "sampled and zero", and says which. Re-run rather than concluding |
| **The fix is a setting nobody knows to change** | `/duf profile` reporting "the API has produced nothing this session" is the discoverability, and it is the whole reason option 1 is preferred over a silent heuristic |
| **This plan changes behaviour for TBC users** | It must not. The `"auto"` assertion above is what pins that |

## Estimate

| Piece | Hours |
|---|---|
| Phase 0 + recording the finding | 0.5 |
| Option 1, if needed | 2–3 |
| **Total** | **0.5 if Era is healthy, 3 if it is not** |

The most likely outcome is the cheap one. It is still worth asking, because the
failure it guards against is silent and this project has met that exact failure
three times already.
