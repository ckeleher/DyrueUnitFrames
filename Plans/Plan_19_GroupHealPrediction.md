# Plan 19 — Group Heal Prediction

**Status:** Not started. **Extends Plan 11.**
**Created:** 9 August 2026
**Branch:** `Plan-19-group-heal-prediction`

---

## Request

> I want to extend on the predictive healing feature. Currently it works fine for
> my heals onto others, but I want to see predictive healing for others, at least
> those in my party/raid, if not from everybody. First, determine whether this is
> a feasible request - if it is, then ask me any follow-up questions you need,
> then make a plan.

---

## Feasibility — asked for explicitly, so it is answered first

**Yes for HoTs. Conditional for direct casts, on one unknown.** The request
splits along a line that is not obvious from outside the code, and the split is
what shapes this plan.

### The HoT half is feasible today. No probe, no library, both clients.

`Systems/HealPrediction:HotTotal` does not remember that a HoT was cast — it
**reads the aura off the unit** on every update, which is the design decision
recorded in that function's header. `Compat.GetAura` already returns the caster
in `a.source` (`sourceUnit` on the `C_UnitAuras` path,
the 7th return of `UnitAura` on the legacy one). So *detecting* another player's
HoT costs exactly one thing: deleting the `aura.castByPlayer` filter at
`Systems/HealPrediction.lua:292`.

What has to be built is **sizing** them, and that is real work — see the design.

### The direct-cast half is blocked on knowing *who they are casting at*.

Two things are needed and only one is likely to exist.

| Needed | Status |
|---|---|
| A cast-start signal for a unit that is not the player | **Probably available.** Classic Era 1.15 restored native enemy cast bars — ClassicCastbars' own page now tells Era users to disable it and use the built-in option — so `UNIT_SPELLCAST_START` for non-player units is likely live on 1.15.9. Unverified for **friendly** units, and unverified on 2.5.6 |
| The cast's **target** | **This is the blocker.** `UNIT_SPELLCAST_SENT` is the only event that carries a cast's target and it fires for your own casts only. The combat log's `SPELL_CAST_START` is expected to leave the dest fields empty — that is why LibHealComm exists at all, and why Warcraft Logs reads cast targets off `SPELL_CAST_SUCCESS`, which fires when the cast *finishes* |

The dest-field question could not be settled from documentation either way, so
this plan treats it as **a probe line rather than a claim** — the same discipline
`COMPAT_FINDINGS.md` applies to everything else. It is one line of output and it
decides whether a future plan can exist.

If dest comes back empty there are two fallbacks, and neither ships here:

* **Read the caster's own target** (`party1target`) at cast start. Correct for a
  healer who clicks targets, wrong for anyone using mouseover or `@player`
  macros — which is to say, wrong for good healers, on exactly the casts that
  matter. Rejected as a default; the user was asked and declined it.
* **LibHealComm-4.0.** Correct amounts, targets and cast ends, for group members
  who also run an addon that embeds it. It is ~6k lines carrying the rank and
  coefficient database that Plan 11 spent its whole design argument refusing.
  Available if the probe closes the door; not taken pre-emptively.

### "From everybody" is mostly moot, for a reason worth recording

A non-group healer's HoT is visible in the aura scan at no extra cost. But the
**healed** unit has to be one with a frame, and `Compat.HasRealHealthValues`
already blanks this element on any unit outside your group
(`Elements/HealPrediction.lua:301`) — a stranger's health bar reports 0–100 and
cannot take an absolute prediction at all. So "everybody" would buy: strangers'
HoTs, on units that are already in your group. The user chose group-only
sourcing, which costs nothing against that.

### The frame-coverage catch

This addon has **no raid frames** — `Units/PartyGroup.lua` is party-only and
`partyGroup.hideInRaid` ships `true`. In a 40-man the only frames that can show
anyone's incoming heals are `player`, `target`, `focus` and `pet`. Raised before
the questions were asked; the user accepted it and left frame scope unchanged.
Recorded here because a future reader will otherwise assume it was missed.

---

## Interpretation

Four things were ambiguous enough to change the work. The answers given:

| Question | Answer |
|---|---|
| How far should the direct-cast half go, given target attribution? | **HoTs now, direct on probe.** Ship the certain half; add probes that decide whether a direct half is possible at all. Nothing ships on a guess |
| Should other people's heals look different from yours? | **No — merge.** Their HoTs add into the existing HoT segment. Two colours total, no new swatches |
| Whose heals count as a source? | **Party and raid members only.** Keeps the combat-log guard to one hash lookup |
| Does the raid frame-coverage limit change the ask? | **No.** Plan stays scoped to the frames that exist |

**The one thing this deliberately does not do:** predict another player's direct
casts. After this plan, a party member's Renew shows on the bar and their Greater
Heal does not. That asymmetry is visible to the user and has to be stated in the
option's description text, for the same reason Plan 11 stated its first-cast
limitation out loud — a limitation the user discovers on their own is
indistinguishable from a bug.

---

## Design

### Scope is a setting, not a strategy

`HealPrediction.PROVIDERS` gains a second entry:

```lua
own   = { label = L["My casts only"],        desc = … }
group = { label = L["My party and raid"],    desc = … }
```

Two entries earns the dropdown that Plan 10's precedent withheld at one.

**Correcting Plan 11's own document while touching this:** that plan describes
`PROVIDERS` as a strategy table with `Start`, `Stop` and `Incoming` functions.
What was actually built is a labelled enum with `label` and `desc`, and the
behaviour lives in the module. This plan keeps it that way — `group` is a
superset of `own`, so a strategy dispatch would be two near-identical closures
where two branches will do. The `Files` table below fixes the stale comment in
`Systems/HealPrediction.lua` rather than leaving the code describing a design
that does not exist.

### Where the setting lives — and why it is not per-unit

**`general.healSources`**, profile level, alongside `useClassicDurations` and
`derivedPollInterval`, which are the same kind of thing: a cross-unit mechanic
rather than an appearance.

Per-unit was considered and rejected. There is one combat-log listener shared by
every frame, so a per-unit answer means the listener runs in the widest mode any
frame asks for and the *reader* filters per unit — more machinery for a
distinction nobody wants ("others' HoTs on party2 but not on my target" is not a
preference anyone holds). It also keeps the per-unit `Incoming heals` inline
group from growing, which matters: it is an `inline = true` group and Plan 3's
finding was that a tall inline group evicts its sibling tree. **No new rows are
added to it.** The dropdown goes in the General tab; the existing `note`
description in `healPredictionArgs` is rewritten in place, because it currently
asserts *"only your own heals are visible at all"* and that becomes false.

An unknown stored value — a profile from a future version — falls back to
`DEFAULT_PROVIDER` rather than erroring or predicting nothing.

### The roster set, and why the hot path does not change shape

Today the first thing that happens on every combat-log line in the game is:

```lua
if not state.playerGUID or sourceGUID ~= state.playerGUID then return end
```

That single comparison is the whole §6 argument for affording
`COMBAT_LOG_EVENT_UNFILTERED`. It becomes:

```lua
if not roster[sourceGUID] then return end
```

`roster` is a GUID set rebuilt on `GROUP_ROSTER_UPDATE` and
`PLAYER_ENTERING_WORLD` from `IsInRaid()` / `GetNumGroupMembers()`. **In `own`
scope it contains exactly one entry — the player's.** So the fast path is one
hash lookup in both modes instead of one comparison in one mode: the setting
changes the *contents* of one table, not the shape of the hottest code in the
addon. That property is asserted in the tests, because it is the entire
performance claim.

Rebuild cost is ≤40 `UnitGUID` calls on a roster change, which is an event that
fires when someone joins or leaves.

### Sizing another player's HoT

The player's own store (`ns.db.char.heals`) is **unchanged and still persisted**
— it is a function of your gear and talents and it stays that way. Other people's
amounts go in a **session-only** table that is never saved:

```lua
session.periodic[casterGUID][spellID]   -- blended, same SMOOTHING as everything else
session.mean[spellID]                   -- blended across every caster seen, incl. you
```

Two-level rather than a `guid..":"..spellID` key, deliberately: a string concat
per combat-log line is an allocation on the noisiest event in the game, which is
the one thing `OnCombatLog`'s header promises it never does.

**Read order** when the element asks for a HoT's per-tick amount:

1. that caster's own learned value,
2. `session.mean[spellID]` — a different priest's Renew is still a Renew, and one
   real observation blends the guess away,
3. nothing. Predict zero, which is Plan 11's documented honest failure mode
   applied unchanged to a new set of casters.

**Why session-only.** It is observed data keyed by another player's GUID.
Persisting it grows without bound across every group you ever join, and it is
stale the moment they change gear or spec. Relearning costs one tick. This is the
same argument `Core/Core.lua:298` already records for keeping the char store out
of the profile, pushed one step further.

**Bounding.** `session.periodic` is only ever written for a GUID in `roster`, so
it is bounded by group size. Casters no longer in the roster are dropped on
`GROUP_ROSTER_UPDATE` — ≤40 entries of a handful of spells each, and the pruning
is a side effect of a rebuild that is already happening.

### Tick intervals need a caster guard

`NoteTick` currently discards a sample when the previous tick of that spellID was
on a different target, because two Rejuvenations on two party members interleave.
With more than one caster in scope the same trap opens sideways: **two druids'
Rejuvenations on the same target** interleave too, and the gap between them is
not a tick interval either.

So `state.lastTick[spellID]` records the caster alongside the target and the
sample is discarded unless **both** match. `learned.interval[spellID]` itself
stays global and per-spell — Classic has effectively no haste, so a Rejuvenation
ticks every 3s for everybody; what changes is that the samples feeding it stop
being garbage.

### Which HoTs count

`HotTotal`'s filter becomes a scope predicate:

| Scope | Predicate |
|---|---|
| `own` | `aura.castByPlayer` — unchanged |
| `group` | `aura.source` is non-nil **and** `roster[UnitGUID(aura.source)]` |

`aura.source` is a unit token and is **nil when the caster has no token**, which
is precisely the non-group case — so group-only sourcing falls out of the data
rather than needing a second test. One structure, `roster`, answers both the
combat-log guard and the aura filter.

### Drawing does not change at all

`Elements/HealPrediction.lua` is untouched. Merged colours were the answer, so
other people's HoTs add into the existing `hot` segment, through the same
geometry, the same overflow limit and the same Plan 16 cap band.

One consequence to state plainly: with this on, the HoT segment on a party member
will frequently be non-zero from other people. That is the feature. If it reads
as noise the answer is the source dropdown, not a new colour.

### No new ticker, still

Plan 11's §5.7 position survives intact and for the same reasons. A HoT's
remainder changes when a tick lands or the aura changes; both are events, and
both already drive this element. Nothing here adds a timer, and `Refresh(guid)`
remains the push path.

### Probes — the part that decides whether a Plan 20 exists

`/dufprobe heals`, a 60-second trace written to `DyrueUnitFramesProbeDB` per the
SavedVariables discipline (chat truncates; the file does not).

| Question | Why it matters |
|---|---|
| Does `UNIT_SPELLCAST_START` **fire** for `party1`–`party4`, `raid1`–`raid40`, `target`, `focus`? | `Compat.HasEvent` only says the event is valid. Only a live trace says it fires for those tokens |
| Does `UnitCastingInfo("party1")` return a name and `endTime` for another player's cast? | Without an end time there is no window to predict over |
| Does CLEU `SPELL_CAST_START` carry a non-empty `destGUID`? | **The decisive one.** If it does, others' direct casts become straightforward and this plan's deferral is one plan long |
| Does `aura.source` resolve for an **out-of-range** raid member? | Bounds the HoT half. If it goes nil at distance, group HoTs quietly stop in exactly the raid where they matter |
| `CombatLogRange*` CVar values | Bounds *learning*. A healer beyond that range produces no lines to learn from |

Results go into `Documents/COMPAT_FINDINGS.md` under a `Plan 19` heading,
filled in from a live run rather than left as assumptions.

---

## Files

| File | Change |
|---|---|
| `Systems/HealPrediction.lua` | The bulk. Roster set + `GROUP_ROSTER_UPDATE`; scope-aware CLEU guard; session per-caster store with roster-driven pruning; caster-aware `NoteTick`; scope predicate in `HotTotal`; `SetScope` / validation against `PROVIDERS`; second `PROVIDERS` entry; `Describe()` reports scope and session-store size. **Also fixes the stale header comment** describing `PROVIDERS` as a strategy table |
| `Core/Defaults.lua` | `general.healSources = "group"`. One key, no `SCHEMA_VERSION` bump |
| `Core/Core.lua` | Apply the stored scope on `OnInitialize`; scope + session-store line in `ProfileReport` |
| `Config/Options.lua` | The `healSources` dropdown in the General tab, populated from `ProviderNames()` |
| `Config/Options_Layout.lua` | Rewrite the `note` string in `healPredictionArgs` — it currently claims only your own heals are visible, and must state the direct/HoT asymmetry. **No new rows** (Plan 3) |
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | `/dufprobe heals` |
| `Documents/COMPAT_FINDINGS.md` | A `Plan 19` section with the five probe rows |
| `Tests/wowstub.lua` | `IsInRaid` / `GetNumGroupMembers` / `UnitGUID` for party tokens; `source` on injected auras |
| `Tests/tests.lua` | Extend `testHealPrediction()` — see below |

**`Core/Locale.lua` is deliberately absent.** enUS is the identity mapping, so
new `L["…"]` call sites work with no table entry. Plan 11 listed it and did not
need it; Plan 13 did the same. Not repeating it.

---

## Schema and migration

**No `SCHEMA_VERSION` bump.** This adds exactly one key (`general.healSources`)
and changes no stored value, so `Defaults:EnsureProfile` deep-fills it — the free
path described in `Core/Defaults.lua`'s header.

`ns.db.char.heals` is **untouched**: other people's amounts live only in a
session table, so there is no `EnsureChar` change and nothing to migrate. That is
a direct consequence of the session-only decision above, and it is worth noticing
that the cheaper storage choice is also the one with no migration.

**Known trap:** `Tests/tests.lua` pins `SCHEMA_VERSION` as an absolute number to
prove a plan adds no bump of its own. Plan 11's branch failed its rebase on
exactly this. Pin it to `16` and expect to re-pin if `main` moves underneath the
branch.

---

## Tests

Extending `testHealPrediction()`. The stub work is roster plumbing, which nothing
in the suite has needed before.

**The guard**
* A `SPELL_HEAL` from a group member's GUID is learned under `group` scope.
* The same line under `own` scope is **not** learned.
* A line from a GUID in neither is never learned, in either scope.
* Under `own`, the roster set contains **exactly one** entry. This is the §6
  performance claim and an assertion is the only thing keeping it true.

**Per-caster sizing**
* Two casters' ticks of the same spellID learn separately and do not blend.
* A caster with no sample of their own falls back to `session.mean`.
* With no sample anywhere, the prediction is **zero** — the documented failure
  mode, asserted so it stays deliberate.
* The player's own persisted `learned.periodic` is unchanged by another caster's
  ticks. This one guards the storage split; getting it wrong silently corrupts a
  saved value with a stranger's gear.

**Tick interval**
* Two casters' ticks on the **same** target, interleaved, produce no interval
  sample. The sideways version of the existing same-target guard, and the
  assertion that pins it.

**Aura filtering**
* `source = "party2"` counts under `group`, not under `own`.
* `source = nil` never counts under `group` — the non-group case.
* `castByPlayer` behaviour under `own` is unchanged, so the Plan 11 assertions
  keep passing untouched.

**Pruning**
* A caster leaving the roster drops their session entries on the next rebuild.

**Unchanged invariants**
* Idle-to-zero: with the element off everywhere, the listener is unregistered.
* Plan 3's inline-group tripwire still passes — no rows were added to
  `healPredictionArgs`.

**Gap this exposes:** the suite has never driven a roster change. Whatever is
built here is also the first coverage of `GROUP_ROSTER_UPDATE`, which
`Units/PartyGroup.lua` has been relying on untested.

---

## Risks

| Risk | Handling |
|---|---|
| **Combat-log cost widens from one caster to forty** | The guard stays one hash lookup and the roster is ≤40 entries. `own` scope is genuinely one entry, asserted. `/duf profile` reports scope, so "which mode is this actually in" is answerable in-game |
| **`Refresh(guid)` fires far more often** — every group HoT tick now pushes a redraw | The walk is ≤14 frames and only redraws ones matching the GUID. If it measures badly, the fix is a dirty set flushed on the next event, **not a ticker** — naming the fallback now so nobody reaches for §5.7 later |
| **`aura.source` goes nil for distant raid members** | Probed before implementation, not assumed. If it does, group HoTs degrade to nothing at range — silently, and in the raid where they matter most. That finding would change the value of this plan and is worth knowing first |
| **Combat-log range bounds learning** | Also probed. A healer beyond `CombatLogRange*` produces no lines, so their spells stay unlearned until they are nearby once. Degrades to the documented zero, never to a wrong number |
| **Session store keyed by another player's GUID** | Written only for roster GUIDs, pruned on roster change, never persisted. The unbounded-growth version of this is exactly what persisting would have caused |
| **The direct/HoT asymmetry confuses the user** | Stated in the option description, in the same spirit as Plan 11's first-cast note. A party member's Renew will show and their Greater Heal will not, until a probe says otherwise |
| **A stale `PROVIDERS` comment survives into a two-entry world** | The comment is in the Files table. Plan 11's document already drifted from its own implementation here; leaving it would make that permanent |
| **Rewriting the `note` string grows the inline group** | It is a rewrite, not an addition. Plan 3's tripwire covers the regression if a future edit adds rows |

---

## Estimate

| Piece | Hours |
|---|---|
| `/dufprobe heals` + a live run + `COMPAT_FINDINGS.md` | 1.5 |
| `Systems/HealPrediction.lua` — roster, scope, session store, tick guard | 3–4 |
| Defaults, Options dropdown, description rewrite, `/duf profile` | 1 |
| Stub roster plumbing + test extensions | 2–3 |
| **Total** | **7.5–10** |

Cheaper than Plan 11 for the reason Plan 12 was expected to be: the element, the
geometry, the config block and the learning machinery all already exist. Nearly
all of it lands in one file.

**If the probe says `SPELL_CAST_START` carries a target**, others' direct casts
become a separate plan and a materially easier one than it looks today — the
learning path built here is already keyed by caster, and cast end times would be
the only new derived value.
