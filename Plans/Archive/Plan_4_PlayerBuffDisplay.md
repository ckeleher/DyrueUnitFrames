# Plan 4 — Player Buff Display

**Status:** Implemented on `Plan-4-player-buffs-fix`. One symptom fixed
outright; the other is hardened but still needs the in-game traceback to
confirm the root cause.
**Created:** 2 August 2026
**Branch:** `Plan-4-player-buffs-fix`
**Priority:** Highest of the six. Two elements are currently erroring on the
player frame at login.

---

## Outcome

Step 1 of this plan said reproduce before fixing. A new headless suite
(`player-buffs`) exercises the player's own buffs, which the harness had never
done. Results:

**Symptom 2 — reproduced exactly.** Once the breaker trips, `ApplyConfig`
refuses to re-enable the element no matter what the checkbox says. The test
failed on exactly the two assertions predicted. **Fixed.**

**Symptom 1 — did not reproduce.** Three buffs, three icons, three distinct
positions, no error. That is itself informative: the harness models everything
except `CreateFrame`'s *templates*, which it ignores. So the cause is almost
certainly a real Blizzard template behaving differently in the client —
candidates 1 and 2 below, and nothing else in the ranked list.

Both candidates are now guarded, so neither can take the aura element down
whatever they do. That is not the same as knowing which one it was, and the
traceback is still worth collecting.

### What changed

| Change | Confirmed by |
|---|---|
| Re-enabling an element clears its breaker, keyed on the config transition so a routine refresh does not defeat the breaker | Test |
| `CooldownFrameTemplate` creation guarded; a missing swipe costs the swipe only | Test, via a stub that makes named templates throw |
| `SecureActionButtonTemplate` overlay fully guarded; failure disables right-click-cancel for that button alone | Test, same mechanism |
| No secure overlay built during combat — `RegisterForClicks`, `SetAttribute` and `Hide` are all protected, so a buff gained mid-fight would have thrown | Test |
| `/duf errors reset`, and an in-options notice when an element has been switched off | — |

### Still open

The actual traceback. `/duf debug` then `/reload` on the affected character. If
`player:auras` no longer appears, one of the two guards caught it and the
question is which. `player:text` is a separate line of inquiry and is untouched
by this work.

---

## Request

> buff display on the player doesn't seem to be working correctly (see
> screenshot #2). you can see that I have three buffs in the top-right, but only
> one on the DUF player frame. I can't tell if they're all being put over the
> same spot instead of next to each other, or what, but see if you can figure
> that out and fix it. Additionally, it seems that the frame isn't
> enabling/disabling properly - when enabled on load, it shows something, but if
> i disable it and re-enable it, the visual never comes back.

---

## The evidence in the screenshot

The chat log in screenshot #2 is the most useful thing in this report:

```
[17:38:51] Dyrue player:text hit an error. If it repeats it will be disabled
           automatically; /duf debug for details.
[17:38:51] Probe loaded. /dufprobe for the API survey.
[17:38:52] Dyrue player:auras hit an error. If it repeats it will be disabled
           automatically; /duf debug for details.
```

**Both the text and the aura element are throwing on the player frame, at
login.** The circuit breaker is doing exactly its job — catching them, naming
them, and keeping everything else alive — which is why the frame looks mostly
fine rather than being dead.

This is not a separate problem from the buff report. It is almost certainly
*the* problem.

---

## Why this explains both symptoms

### "Only one buff shows"

`Elements/Auras.lua` → `updateGroup` places buttons in a loop:

```lua
for i = 1, shown do
    applyButton(frame, group, cfg, getButton(group, i), list[i], cells[i], filter)
end
```

An error inside `applyButton` on the **second** iteration leaves button 1 placed
and shown, and buttons 2 and 3 never touched. One buff on screen, three in the
API. That matches the report precisely — better than the "all stacked in one
spot" theory, which would need the cell maths to be wrong, and the cell maths is
covered by tests that pass.

### "Disable and re-enable never comes back"

This one is certain. `Units/Factory.lua` → `ApplyConfig`:

```lua
local wanted = enabled
    and Errors:IsElementAllowed(def.name)
    and not Errors:IsDisabled(self.unitKey .. ":" .. def.name)
    and def.IsEnabled(self, elementConfig) and true or false
```

Once `player:auras` has tripped the breaker, `IsDisabled` returns true and
`wanted` is false **no matter what the options say**. Toggling the checkbox off
and on rewrites the config, re-runs `ApplyConfig`, and gets nowhere. The only
way back is `/reload`.

So the re-enable symptom is not a second bug. It is the breaker working as
designed, plus a genuine design gap in how you get out of it — see the second
fix below.

---

## Step 1 — get the actual error

Everything below is ranked guesswork until this is done. It is cheap:

```
/duf debug
/reload
```

`Errors.debug` makes the handler print the message and a `debugstack`, which
names the file and line. `/duf errors` then lists what has tripped and how often.

---

## Step 2 — ranked candidates for the aura error

To be confirmed or killed by the traceback, not fixed speculatively.

| # | Candidate | Why plausible | Why it might not be |
|---|---|---|---|
| 1 | `CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")` in `createButton` | A missing template throws outright, and it runs on first display of each button | Button 1 was created the same way and survived |
| 2 | `ensureCancelOverlay` — `CreateFrame(..., "SecureActionButtonTemplate")` | Only runs for the **player's own HELPFUL auras**, which is exactly the failing case, and not for target debuffs. Creating a secure frame parented into a secure button's subtree is the least-trodden path in the file | pcall-guarded on creation, but `SetAttribute` and `Show` afterwards are not |
| 3 | `ns:SetFont(button.count, cfg.stackFont, ...)` with a nil size or font | `SetFont` throws on a nil size | `EnsureProfile` fills those keys |
| 4 | `button.icon:SetTexture(entry.icon)` with a nil icon | Some auras report no icon | `SetTexture(nil)` is tolerated |
| 5 | `Compat.GetAura` scratch-table reuse | Returns one shared table; if anything holds it across calls the data is wrong | `scan` copies out immediately |

**Candidate 2 is the one to look at first.** It is the only code path unique to
the player's own buffs, which is the only display that is failing.

Note that `updateCancelOverlay` routes through `CombatQueue`, so the failure may
surface inside a queued function rather than in `applyButton` directly — the
context would then be `combatqueue:auracancel:...` rather than `player:auras`.
Worth checking `/duf errors` for both.

---

## Step 3 — the text error

`player:text` fired one second earlier. It may share a root cause or be separate.
The most recent change to that element is the shapeshift mana readout added in
`ead8492`, and the player frame is the only unit that has one, which makes it
the obvious suspect on timing alone.

`anchorWidget` handles a missing `elements.mana` safely, so the more likely spot
is `Tags:Render` for `[mana:cur:short]` — `UnitPowerMax(unit, Compat.MANA)` at a
moment during login when power data is not yet populated.

Same rule: confirm with the traceback before touching it.

---

## Fix 2 — re-enabling an element must clear its breaker state

Independent of the root cause, and worth doing either way.

Right now a single transient error at login can disable an element for the whole
session, and the options UI gives no indication and no way back. The checkbox
looks like it works and does nothing. That is a bad failure mode for a safety
feature — "degraded, not dead" (SPEC §5.9) should not mean "degraded until you
reload and cannot tell why".

Proposed:

1. **Toggling an element on in the options clears its breaker count.** An
   explicit user action is a reasonable "try again". `Errors:Reset(context)`
   already exists.
2. **The options show it.** A description line on any element group whose
   context is currently disabled: *"This element hit repeated errors and was
   disabled for this session. Re-enabling will try it again; /duf errors has
   the details."*
3. **`/duf errors` gains a `reset` argument** to clear all counts without a
   reload.

---

## Files

| File | Change |
|---|---|
| `Elements/Auras.lua` | The actual fix, once known |
| `Elements/Text.lua` | Likewise, if separate |
| `Core/Errors.lua` | Possibly a guard around the confirmed cause |
| `Units/Factory.lua` | Clear breaker state when an element is re-enabled |
| `Config/Options_Layout.lua`, `Config/Options_Auras.lua` | Disabled-element notice |
| `Core/Core.lua` | `/duf errors reset` |
| `Tests/tests.lua` | See below |

No schema change expected.

---

## Tests

The bug slipped through because the harness only ever exercised auras on the
**target** frame, with buffs enabled from the start. Both gaps are worth closing
regardless of what the root cause turns out to be:

- Player-frame buffs, including own auras — which is the only path that builds a
  cancel overlay.
- Three auras present → three buttons shown, at three distinct positions. Assert
  the positions differ; the current test only counts them.
- Enable → disable → re-enable through the options, asserting the icons come
  back. This alone would have caught the re-enable symptom.
- An element that has tripped the breaker is re-enabled by toggling the option,
  and `IsDisabled` is cleared.
- A regression test for whatever the traceback names.

---

## Risks

| Risk | Handling |
|---|---|
| Fixing a symptom without the traceback | Step 1 is mandatory; nothing below it happens first |
| The cancel overlay is fundamentally awkward | It was already flagged as the least comfortable part of the aura code (`COMPAT_FINDINGS.md`, §FR-5.9 deviation). If it is the cause, dropping right-click-cancel is an acceptable outcome — it is a convenience, and a working buff display beats it |
| Clearing the breaker on re-enable lets a genuinely broken element spin | It still re-trips after N errors; the user chose to retry |

---

## Estimate

2–5 hours. Mostly diagnosis; the fix itself is likely small. The breaker-clearing
work is about an hour and is worth doing whatever the outcome.
