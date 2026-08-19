# Plan 26 — Right-clicking a buff does nothing

**Status:** Open — diagnosis in progress, cause not yet established
**Date:** 2026-08-18
**Branch:** `Plan-26-buff-cancel-does-nothing` (diagnostic work already on it)

---

## Request

> right clicking does nothing

Said while verifying [Plan 25](Archive/Plan_25_BlockedAuraLayoutInCombat.md) on TBC
Anniversary. Plan 25 moved the cancel overlay out from under the aura icon, and
the check it asked for was whether right-click-cancel still worked. It did not.

---

## Interpretation

SPEC §FR-5.9 says right-clicking your own buff on the player frame cancels it.
It does not cancel it.

**This is almost certainly not a Plan 25 regression.** Plan 25 changed where the
overlay is parented and what it is anchored to; the measurements below show the
overlay is exactly where it should be, at the right size, on top, and taking the
mouse. What fails is a step further in, and nothing in the repository has ever
demonstrated that step working:

* `COMPAT_FINDINGS.md` records FR-5.9 as a **design decision**, not a measured
  outcome.
* The test suite asserts that the overlay object exists and that its creation
  degrades safely. It has never asserted that a click cancels anything, and it
  cannot — see Tests below.
* No probe run before 18 August 2026 touched it.

So the honest reading is that right-click-cancel has never worked, since
`d4ef9a3`, and Plan 25's verification step is what finally asked.

The alternative reading — that Plan 25 broke it — is not ruled out by argument,
only by measurement, and the measurements point away from it. Diagnosis should
still keep it on the list until the cause is named.

---

## What is already measured

Four probe runs on **TBC Anniversary 2.5.6**, via `/dufprobe cancel`. Raw
records in `DyrueUnitFramesProbeDB.cancel` and `.cancelRuns`.

### The overlay is correct, and the click reaches it

| Fact | Value |
|---|---|
| Mouse focus while over a buff | `overlay 1` … `overlay 7` — the overlay, never the icon |
| Overlay / icon frame level | 8 over 7; `overlayIsAbove` true on every button |
| Overlay rect vs icon rect | identical to the decimal |
| Shown / mouse-enabled | both true |
| Parent | `frame.cancelLayer`, as Plan 25 intended |
| `cancelFailed` | false on every button |
| `PreClick` / `PostClick` | **29 each, with `RightButton`** |
| Attributes at probe time | `type2=cancelaura unit=player filter=HELPFUL`, indices distinct, `spell` populated (`Gift of the Wild`, `Major Agility`, `Omen of Clarity`) |
| `ADDON_ACTION_BLOCKED` from this addon | **none** |

### The secure handler never runs

No traced `SecureActionButton_OnClick` carried `type2 = cancelaura`, and neither
`CancelUnitBuff` nor `CancelSpellByName` was ever called on a buff. The only
cancel calls in the whole window were `CancelSpellByName('cat form')`, twice,
from shifting form.

PreClick and PostClick both firing means the widget's click machinery ran. So
the click is delivered and the secure action is skipped.

### One earlier verdict was wrong, and is recorded here so it is not re-derived

Round two reported "dispatch: yes". It counted **every** `SecureActionButton_OnClick`
on screen, and a busy action bar produced 1268 of them. Zero were ours. The
verdict now matches on `type2 = cancelaura`, and the hook ignores buttons
without it — which also removed a megabyte of another addon's clicks from
SavedVariables.

---

## Diagnosis steps, in order

Round four is **synced and not yet run**. It reads both of the top two
candidates in one pass.

### 1. The overlay's `OnClick` is not the one that works (most likely)

If `PreClick` and `PostClick` fire but the global `SecureActionButton_OnClick`
never does, the most economical explanation is that the overlay's `OnClick` is
not that function — i.e. `SecureActionButtonTemplate` did not give us what the
action bars have. `entry.hasOnClick` is true, so *something* is attached.

**Resolved by:** the identity comparison already added — `api.secureOnClick`,
`api.referenceOnClick` (a live Bartender4/Blizzard button) and the overlay's own
`GetScript("OnClick")`, recorded in PreClick. If ours differs from the
reference, this is the answer and the fix is in how the overlay is created.

### 2. The attributes differ at click time

Everything above was read at probe time. If something clears or rewrites the
attributes between the aura update that sets them and the click that reads them,
the handler would find nothing to do.

**Resolved by:** PreClick now dumps all six attributes as the click sees them.
Compare against the static dump in the same record.

### 3. Taint

An insecure addon created the overlay and writes its attributes, which is the
ordinary arrangement, but a tainted execution path makes the client skip the
secure action. Argues against: no `ADDON_ACTION_BLOCKED` was recorded from this
addon at any point. Argues for: a skipped secure action does not always raise
one.

**Resolved by:** if 1 and 2 both come back clean, build the overlay from a
`/dufprobe` command — probe-created, addon-untouched — and click that. Cancels
means taint; does not cancel means the template or the client.

### 4. `cancelaura` with `index` + `filter` is not supported here

Cannot be reached yet — nothing gets as far as the type handler. Kept on the
list because OPie, which works on this client, drives `cancelaura` with a
`spell` attribute and nothing else.

**Already hedged:** the overlay now sets `spell` alongside `index` and `filter`
(commit `dcf8d0c`, on the Plan 26 branch). A superset, not a guess — whichever
the handler reads first is correct, and the probe records which API it calls.

### 5. Plan 25 caused it

Kept honest rather than kept likely. **Resolved by:** `git stash` the Plan 25
parent change on a scratch branch and click. If it cancels under the old
parenting, everything above is wrong and Plan 25 needs revisiting — but note
that the old arrangement froze the whole buff display in combat, so it is not a
destination either way.

---

## Design

**Deliberately not written yet.** Steps 1–3 name mutually exclusive causes with
different fixes — a different creation call, a different update path, or a
different owner for the frame — and `Skills/NewWork.md` is explicit that a bug
whose cause is unknown gets ranked candidates rather than a fix designed around
a guess. This plan gets a Design section when the probe names the cause.

What is already decided: whatever the fix is, it must not put the overlay back
under the icon. That arrangement is what Plan 25 removed, and it froze the
player's entire buff display for the duration of every fight.

---

## Files

| File | Change |
|---|---|
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | `/dufprobe cancel` — done, four rounds in |
| `Elements/Auras.lua` | `spell` attribute alongside `index`/`filter` — done, pending the run that says whether it mattered |
| — | The actual fix, once the cause is named |
| `Documents/COMPAT_FINDINGS.md` | Record the outcome either way. If FR-5.9 has never worked on a live client, that is a finding worth more than the feature |

---

## Schema and migration

None expected. No stored keys are involved; this is a frame and attribute
problem.

---

## Tests

**The harness cannot answer this one, and should not be stretched to try.**
`Tests/wowstub.lua` models frames as tables. It has no secure execution
environment, no click dispatch, no attribute resolution, and no notion of
`type2` — modelling those convincingly enough to catch this would mean
reimplementing `SecureTemplates.lua` against a source we cannot read, and a
model built from the same assumptions that produced the bug would agree with the
bug.

Plan 25 added what the harness *can* usefully hold: protection and refusal
(`stub.blocked`). Everything past that is a live-client question.

What can be added once the cause is known:

* whatever structural invariant the fix depends on — the overlay's parent, its
  creation call, the attribute set — asserted the way Plan 25 asserts the cancel
  layer;
* a `COMPAT_FINDINGS` row, which is this project's real regression test for
  client behaviour.

Verification stays `/dufprobe cancel` plus right-clicking a buff.

---

## Risks

| Risk | Handling |
|---|---|
| The feature has never worked and cannot be made to | Then FR-5.9 is unimplementable as specified, and the plan ends by amending the spec and saying so in `COMPAT_FINDINGS` — the same treatment §2.2 and §FR-7.2 got. Not a failure; a measured limit |
| Chasing this holds up Plan 25 | It does not. Plan 25 is a separate PR, verified green, and this plan carries its own branch |
| The fix reintroduces the Plan 25 bug by putting the overlay back under the icon | Plan 25's `stub.blocked` assertions fail loudly if anything does. That is exactly what they are for |
| Diagnosis stalls on a client whose Lua cannot be read | Steps 1–3 are all readable from outside. If all three come back clean, the next move is comparison against a working implementation, not more guessing |
| More probe rounds cost real play time | Four rounds so far, each a `/reload` and thirty seconds. Round four reads two candidates at once on purpose. If it comes back clean, stop and reconsider rather than opening a fifth |

---

## Estimate

Unknown, and that is the honest answer. One more probe run settles candidates 1
and 2, and if either lands the fix is likely small — a different creation call
or a different update path. Candidate 3 is half a day. Candidate 4 is already
hedged. If all four come back clean the answer may be that FR-5.9 does not work
on this client, which is a documentation change and a spec amendment rather than
a fix.
