# Plan 26 — Right-clicking a buff does nothing

**Status:** Implemented on `Plan-26-buff-cancel-does-nothing`, awaiting merge. Cause established and design carried out 18 August 2026.
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

**Superseded — kept as the record of how the cause was found.** All five
candidates were closed by builds 5 and 7; the answer is in *THE CAUSE* below,
and it was none of them. The ranking was wrong in an instructive way: it assumed
the secure route worked and asked which part of our use of it was broken.

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

## THE CAUSE — measured 18 August 2026

**The premise the whole feature was built on is false on this client.**

`SPEC.md` §FR-5.9, line 310:

> Right-click to cancel own buffs on the player frame (this is a protected
> action — it must go through a secure button attribute, not a script handler).

The parenthetical is inherited from retail, where it is true. On TBC
Anniversary 2.5.6 it is not, and it is the reason the feature has never worked:
it mandated the one route that does not work here and forbade the one that does.

### `/dufprobe cancelcall`, build 7 — canceling is NOT protected

`CancelUnitBuff("player", 1, "HELPFUL")` called **directly from insecure addon
code**, with an `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN` watcher
running:

```
target: Omen of Clarity index 1
callOk: True   callError: None
blocked events: 0
after 2s: Gift of Arthas   gone: True
```

The buff was cancelled. No error, no refusal, nothing protected about it.

### `/dufprobe canceltest`, build 7 — the secure route does not work here

Three probe-built `SecureActionButtonTemplate` buttons, untouched by
DyrueUnitFrames so no taint of ours could follow them, each carrying a
different form of the same request against `Major Agility`:

| Form | Attributes | after 0.5s | after 2s |
|---|---|---|---|
| A | `type2=cancelaura` + `unit` + `index` + `filter` | still up | still up |
| B | `type2=cancelaura` + `spell` | still up | still up |
| C | `type=cancelaura` + `spell` — OPie's exact form | still up | still up |

None of them cancels anything. `cancelaura` appears not to be a type this
client's `SecureTemplates.lua` acts on at all.

### So both halves of the diagnosis close

* **Taint is ruled out** — the probe's own buttons fail identically.
* **The attribute form is ruled out** — all three, including a form taken from
  an addon that works on this client.
* Candidates 1 and 2 were ruled out in build 5: the overlay's `OnClick` is
  `SecureActionButton_OnClick` (identical function pointer) and the attributes
  at click time are exactly right.

The secure route is a dead end and always was. The direct call works.

### One instrumentation lesson worth keeping

Two verdicts in this investigation were artifacts, not findings:

* **"dispatched=false"** — the overlay's `OnClick` holds a direct reference to
  the original function, bound when the template was applied. `hooksecurefunc`
  replaces the *global*, so calls through that bound reference are invisible.
  Action bars go through a closure that resolves the global at call time, which
  is why 1268 of theirs were traced and none of ours. The same doubt applies to
  the `CancelUnitBuff` / `CancelSpellByName` hooks; their silence proved nothing.
* **"all three still there"** (build 6) — the aura was read in `PostClick`,
  microseconds after the click. Canceling is a server round trip, so a working
  form and a broken one look identical there. Fixed by reading at 2s.

Both are recorded because both cost a round, and both are the kind of mistake
that is invisible unless written down.

---

## Design

Delete the secure overlay. Cancel from an ordinary `OnClick` handler.

### `Elements/Auras.lua`

Remove `ensureCancelOverlay`, `updateCancelOverlay` and `hideCancelOverlay`
entirely, along with `button.cancel`, `button.cancelKey` and
`button.cancelFailed`. In `createButton`:

```lua
button:RegisterForClicks("RightButtonUp")
button:SetScript("OnClick", function(self, mouseButton)
    if mouseButton ~= "RightButton" then return end
    if not self.cancelable or not self.auraIndex then return end
    -- Guarded on the same terms as everything else here: right-click cancel is
    -- a convenience and must never be able to take the aura display down.
    pcall(CancelUnitBuff, "player", self.auraIndex, self.filter)
end)
```

`applyButton` sets `button.cancelable` where it used to call
`updateCancelOverlay` — same condition, `own and filter == "HELPFUL" and
frame.unitKey == "player"`.

### `Units/Factory.lua`

`frame.cancelLayer` becomes unused and is removed. It existed only to hold the
secure overlays; keeping an empty frame per unit frame because Plan 25 added it
would be cargo.

### What this gains beyond working at all

* **No combat staleness.** The overlay's index was frozen for the duration of a
  fight, so canceling mid-combat could cancel a neighboring buff. The handler
  reads `self.auraIndex` at click time, which is always current.
* **Nothing protected under the aura icon**, so the class of bug Plan 25 fixed
  cannot recur through this path.
* **Less code**: three functions, a frame per unit frame, and a queue key.

### In combat — CLOSED, and it went the other way

Shipped ungated on purpose, on the reasoning that the call was measured working
out of combat and gating on a guess would remove a working feature. A bug report
closed it inside the hour:

> i still get those warnings when trying to click off a buff in combat

So the client **does** refuse it during a fight, and every refused click raised
an `ADDON_ACTION_BLOCKED` naming this addon. The shipped behavior was the worst
of both: the click did nothing *and* made noise doing it.

**Canceling is therefore unprotected out of combat and protected within it** —
narrower than either "protected" or "not protected", and a rule neither the spec
nor the original design allowed for.

The handler now checks `InCombatLockdown` before calling, and says so once every
few seconds rather than swallowing the click. Silence would reproduce the report
this plan started from — *"right clicking does nothing"* — and a deliberate click
deserves an answer.

**The decision to ship it ungated still reads as correct.** Had it guessed, it
would have guessed *for* the gate and been right for the wrong reason, which is
precisely how a retail assumption got into §FR-5.9 in the first place. The cost
of being wrong for an hour was one bug report.

**Still worth a probe run** to make it a record rather than an observation:
`/dufprobe cancelcall` already stores `inCombat`, so running it during a fight
captures the refusal's exact function name.

---

## Files

| File | Change |
|---|---|
| `Elements/Auras.lua` | Delete the three overlay functions; right-click `OnClick` calling `CancelUnitBuff`; `button.cancelable` set in `applyButton`. The `spell` attribute added mid-diagnosis goes with the rest |
| `Units/Factory.lua` | Remove `frame.cancelLayer`, now unused |
| `Documents/SPEC.md` | Amend §FR-5.9. The parenthetical mandating a secure button is wrong on this client and is why the feature never worked |
| `Documents/COMPAT_FINDINGS.md` | The finding, and the §FR-5.9 deviation row rewritten. Plan 25's protection rows stay — that bug was real and its fix stands |
| `Tests/wowstub.lua` | Record `CancelUnitBuff` calls |
| `Tests/tests.lua` | Replace the overlay assertions with the behavior that matters: right-click cancels, it works in combat, and nothing protected hangs under the aura icon |
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | `/dufprobe cancel`, `canceltest`, `cancelcall` — done, seven builds in. Keep them; this is the third time a Classic client has disagreed with a retail assumption |

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
  client behavior.

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
