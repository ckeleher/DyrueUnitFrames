# Plan 25 — Aura layout is blocked in combat

**Status:** Open
**Date:** 2026-08-17
**Branch:** to be created from `main`

---

## Request

> i'm seeing these pop up a bunch in the in-game chat now

Accompanied by a screenshot of the chat frame. Transcribed rather than checked
in, per `Skills/NewWork.md` — it is a picture of text, and the text is the
evidence:

```
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:SetSize()
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:ClearAllPoints()
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:SetPoint()
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:Show()
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:SetSize()
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:ClearAllPoints()
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:SetPoint()
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:Show()
[16:45:42] Tools probe ADDON_ACTION_BLOCKED addon=DyrueUnitFrames function=Button:Hide()
```

`Tools probe` is `DyrueWoWTools_Probe`, a separate addon. Its blocked-action
listener was added on 2026-08-16, one day before this report.

---

## Interpretation

The messages are new. **The bug is not.**

`DyrueWoWTools_Probe` registers `ADDON_ACTION_BLOCKED` and prints every refusal
to chat. Before that listener existed the client refused these calls silently —
`ADDON_ACTION_BLOCKED` reaches no chat frame by default. `git log -S` puts the
offending code in `d4ef9a3`, the original v1.0 implementation commit. So this
has been happening since day one and has only now become audible.

That matters for two reasons:

- Do not go looking for a regression in Plans 20–24. There isn't one.
- The visible symptom (chat spam) belongs to the other addon. The real symptom
  belongs to this one: **aura icons on the player frame do not re-layout during
  combat.** Buffs gained mid-fight land in the wrong cell, at the wrong size, or
  do not appear until combat ends. Nobody reported that, because a stale buff
  icon still looks like a buff icon.

Fixing the chat spam and fixing the aura display are the same fix. This plan
does the second one; the first follows.

---

## Diagnosis

### What is being blocked

The blocked sequence is `SetSize` → `ClearAllPoints` → `SetPoint` → `Show`,
repeated, then a trailing `Hide`. That is `applyButton` in
`Elements/Auras.lua:566-573` and the unused-button loop in `updateGroup`
(`Elements/Auras.lua:659-668`), in exactly that order. Nothing else in the
addon calls those four in that sequence.

### Why the button is protected

`Units/Factory.lua:522` creates each unit frame from `SecureUnitButtonTemplate`,
so the unit frame is explicitly protected. Everything visual then hangs off
`frame.content`, an ordinary `Frame` — the "unprotected content layer"
(`Units/Factory.lua:550`), which exists precisely so elements can be moved and
shown during combat.

Aura icons are `CreateFrame("Button", nil, group.frame)`
(`Elements/Auras.lua:236`) and `group.frame` is a child of `frame.content`.
Being a descendant of a secure frame is not, by itself, what protects them. The
chat log proves that: in the same `applyButton` call, between the blocked
`SetPoint` and the blocked `Show`, `button.cooldown:Show()` or `:Hide()` runs on
a `Cooldown` **frame** with the same secure ancestor — and no `Cooldown:` line
ever appears. If descent alone conferred protection, it would.

What is different about the aura button is `ensureCancelOverlay`
(`Elements/Auras.lua:313`):

```lua
local ok, overlay = pcall(CreateFrame, "Button", nil, button, "SecureActionButtonTemplate")
```

The right-click-cancel overlay is created **as a child of the icon button**. A
frame that owns an explicitly protected descendant cannot be moved, resized,
shown or hidden by insecure code in combat — doing so would relocate or hide the
secure button. So the icon inherits the restriction from its own child, upward.

### Why this is precisely the arrangement the design set out to avoid

`Documents/COMPAT_FINDINGS.md:894` already records the intent:

> §FR-5.9 right-click cancel | Secure attribute on a separate overlay button,
> updated through `CombatQueue` | Aura icons must be shown and hidden constantly
> in combat, which a protected frame cannot do. Splitting insecure icon from
> secure overlay is the only arrangement that satisfies both.

The comment at `Elements/Auras.lua:290-293` states it again — the overlay is
separate "so the icon itself can stay insecure and therefore be shown, hidden
and re-pointed freely during combat."

The reasoning is right. The implementation defeats it by one word: the overlay
is separate, but it is not a *sibling*. Parenting it to the icon hands the icon
exactly the protection the split existed to prevent.

### Scope

`ensureCancelOverlay` is only reached when `updateCancelOverlay` finds
`own and filter == "HELPFUL" and frame.unitKey == "player"`. So only the player
frame's buff group is affected, and only those buttons that have at some point
held one of your own buffs. Every other frame's auras are fine. That matches a
spam burst of a handful of buttons rather than the whole aura display.

---

## Design

Move the overlay out from under the icon. Nothing else about the FR-5.9 design
changes.

### 1. A dedicated cancel layer

Add one frame per unit frame in `Units/Factory:Create`, beside `frame.overlay`:

```lua
-- Secure cancel-buff overlays live here and nowhere else. Anchored once, at
-- creation, and never moved, shown or hidden again — a frame that owns a
-- protected child cannot be touched in combat, so this one must never need to
-- be. See Plan 25.
frame.cancelLayer = CreateFrame("Frame", nil, frame.content)
frame.cancelLayer:SetAllPoints(frame.content)
```

`frame.content` is itself safe to hold this: it is positioned exactly once
(`SetAllPoints(frame)` at `Units/Factory.lua:552`) and never repositioned, shown
or hidden afterwards — verified by grep across `Core`, `Elements`, `Systems`,
`Units` and `Config`.

`group.frame` is **not** safe and must not be used. `updateGroup` calls
`group.frame:Show()` on every aura update (`Elements/Auras.lua:646`), which runs
in combat; parenting overlays there would trade one blocked call for another.

Frame level: the overlay must sit above the icon to take the right-click.
`ns.LEVELS` has `AURAS = 4` and `OVERLAY = 6`, so `ns:Level(frame, "AURAS") + 1`
gives the layer a home between them. Confirm in game that the overlay actually
receives the click — a wrong level here fails silently, which is the failure
mode this whole plan is about.

### 2. Reparent the overlay

`ensureCancelOverlay(button)` becomes `ensureCancelOverlay(frame, button)`:

- parent the new secure button to `frame.cancelLayer`, not `button`;
- keep `SetAllPoints(button)` — cross-parent anchoring is fine, and the overlay
  still tracks the icon's geometry;
- keep every existing guard: the `pcall`s, `cancelFailed`, and the
  `InCombatLockdown()` early return.

### 3. Re-anchor through the queue

Because the overlay is now protected but the icon is not, the overlay's geometry
no longer follows the icon for free. `SetAllPoints` on a protected frame is
refused in combat, so it joins the work already inside `updateCancelOverlay`'s
`CombatQueue:Run` block, alongside the attribute writes.

The cost this adds is the cost FR-5.9 already accepted and documented. In combat
the overlay keeps the position **and** the aura index it had when combat
started; out of combat the next update makes it exact. Previously the stale
thing was only the index. `COMPAT_FINDINGS.md:894` and the comment at
`Elements/Auras.lua:295-298` both need that one word widened.

### 4. Two things worth fixing while in here

- `updateGroup` builds `"auracancel-hide:" .. tostring(button)` per unused
  button per update (`Elements/Auras.lua:664`). `tostring` on a frame allocates,
  and this file is explicit about staying allocation-free under `UNIT_AURA`.
  `button.cancelKey` already exists for exactly this and is stable — use it on
  both the show and the hide path so last-write-wins does the right thing.
- `element.Disable` hides buttons but never hides their overlays. Out of combat
  that leaves an invisible secure button sitting over a hidden aura group, still
  clickable.

---

## Files

| File | Change |
|---|---|
| `Units/Factory.lua` | Add `frame.cancelLayer` in `Create`, anchored once, level above `AURAS` |
| `Elements/Auras.lua` | `ensureCancelOverlay` takes `frame` and parents to `frame.cancelLayer`; `SetAllPoints` moves into the queued block; `updateGroup` uses `button.cancelKey`; `element.Disable` hides overlays |
| `Documents/COMPAT_FINDINGS.md` | Widen the §FR-5.9 row: the overlay is stale in position as well as index, and record why the overlay cannot be a child of the icon |
| `Tests/wowstub.lua` | Model protection and refusal (below) |
| `Tests/tests.lua` | Regression test for a combat aura update on the player frame |

---

## Schema and migration

None. No stored keys change, no defaults change, and the fix is invisible to the
profile. `EnsureProfile` is untouched.

---

## Tests

**The gap that let this through:** `Tests/wowstub.lua:114` is
`function methods:IsProtected() return false, false end`. The stub models combat
(`stub.inCombat`, `Tests/wowstub.lua:628`) but not protection, so every
protected call succeeds in the harness and no test could have caught a blocked
one. The suite has never been able to see this class of bug at all.

Close it:

1. In `wowstub.lua`, mark a frame explicitly protected when `CreateFrame` is
   given a template whose name contains `Secure`. Make `IsProtected` return
   `true` for a frame that is explicitly protected **or** has a protected
   descendant, and return the two values the real API returns.
2. When `stub.inCombat` is true, have `SetPoint`, `ClearAllPoints`, `SetSize`,
   `SetWidth`, `SetHeight`, `SetScale`, `Show`, `Hide` and `SetAttribute` record
   `{frame, method}` onto `stub.blocked` and return without applying, rather
   than silently succeeding.

Then assert:

- `auras/no blocked calls during a combat update` — enter combat, drive a full
  `UNIT_AURA` update on the player frame with own buffs present, and require
  `#stub.blocked == 0`. This test fails on `main` today; that is the point of it.
- `auras/icon is not protected` — the aura button reports unprotected even after
  its overlay exists.
- `auras/overlay is protected and parented to the cancel layer` — the split is
  the fix, so name it in a test rather than leaving it to a comment.
- `auras/icons re-layout in combat` — a buff added during combat lands in the
  right cell at the right size, which is the user-visible behaviour that was
  broken.
- `auras/hide path reuses the stable key` — `button.cancelKey` on both paths.

Run `python Tests/run_tests.py`; `luacheck.py` and `refcheck.py` come with it.

---

## Risks

| Risk | Handling |
|---|---|
| The overlay lands at the wrong frame level and stops taking right-clicks | The one thing that must be checked in game, not in the harness. Right-click one of your own buffs on the player frame out of combat and confirm it cancels. The `Tools` probe's blocked listener is the check for the other direction |
| `frame.cancelLayer` gets repositioned by some later element and re-breaks this | The comment on it says why it must not be, and the new `stub.blocked` assertion fails loudly if anything ever does |
| Overlay drifts off its icon during combat as buffs come and go | Accepted and already documented for the index; now also true of position. Cancelling a buff mid-fight may cancel a neighbour. Out of combat it is exact. This is the FR-5.9 trade, not a new one |
| The restriction propagates further up than assumed — to `frame.content`, or `frame` | Both are already safe: `frame.content` never moves after creation, and `frame` is secure and routed through `CombatQueue` regardless. The design does not depend on which level the restriction stops at |
| Some other addon's protected child is pinning something here too | Out of scope. The probe names the addon, and every line in the report names this one |

---

## Estimate

Two to three hours. The code change is small and contained; most of the time is
the `wowstub.lua` protection model, which is the durable part — it is what stops
the next one of these being invisible for a year.
