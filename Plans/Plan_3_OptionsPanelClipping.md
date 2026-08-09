# Plan 3 — Options Panel Clipping

**Status:** In progress — diagnosis under way
**Created:** 2 August 2026
**Updated:** 8 August 2026
**Branch:** `Plan-3-options-panel-clipping`

---

## Request

> There's some weird bug with the edit window: arrow indicators and other
> elements are showing at the bottom edge of the subframe when these elements
> should be invisible because they're "below the fold". See the first attached
> screenshot for a visual example of what i'm talking about.

---

## What the screenshot shows

On the Player → Text tab, below the "Tag reference" box:

- the red "Add a text element" button, half cut off but drawn;
- a "Name" input and a second box beside it, drawn over the panel's bottom edge;
- two pairs of scroll-arrow icons floating near the bottom-right, outside any
  visible container.

All of these belong to content scrolled below the visible area. They are being
drawn instead of clipped, so they overlap the panel border and the Close button
row.

---

## Likely cause

This is almost certainly the embedded **AceGUI-3.0 ScrollFrame** container, not
our option table.

A WoW `ScrollFrame` does not clip its scroll child by default; it relies on
`SetClipsChildren(true)`. Our vendored copy does not call it.

Supporting evidence: the floating arrow pairs are AceGUI's scroll-up/scroll-down
indicators, which live on the scroll frame itself. Their appearing outside the
container is characteristic of an unclipped scroll child rather than anything
our option tree can cause.

### Correction, 8 August 2026 — we are not behind upstream

The original text above guessed that our vendored copy "came from a Bartender4
build and may predate" an upstream fix. **That guess was wrong**, and the fix
option built on it is dead. Checked directly:

- `Libs/AceGUI-3.0/widgets/AceGUIContainer-ScrollFrame.lua` is at
  `local Type, Version = "ScrollFrame", 26`.
- The same file at current upstream (`WoWUIDev/Ace3`, `master`, last pushed
  5 August 2026) is **also version 26, and byte-identical to ours** ignoring
  line endings.
- `SetClipsChildren` appears **nowhere in `Libs/`** — and nowhere in upstream's
  ScrollFrame either.

So this is not vendored-copy drift. Upstream AceGUI-3.0 has never set the
property on this widget. There is nothing to update *to*.

Two consequences: fix option 1 is struck out below, and the remaining
hypothesis space narrows to "the property was never set and the client's default
changed underneath us" versus the dynamic-description measurement problem.

Note also that this plan claimed widget versions are "recorded in
`Libs/LICENSE.md`". They are not — that table records only AceGUI-3.0's library
version (41). Per-widget versions such as ScrollFrame's 26 live in the
`local Type, Version` line of each widget file, which is what the table's own
Provenance note says to treat as authoritative.

**Competing hypothesis worth ruling out:** the Text tab uses
`type = "description"` with a `name` **function** that returns a long,
dynamically built string (`ns.Tags:AllHelp()`, at
`Config/Options_Text.lua:429`). AceConfigDialog measures description heights to
lay out the scroll child, and a dynamic name can be measured before it is
populated, giving a wrong content height. That would misplace things without
being a clipping bug at all.

### Correction, 8 August 2026 — the Text tab is not "the one place"

The original text called the Text tab "the one place" we do this. It is not.
Dynamic-name descriptions are all over `Config/`:

| Where | Visible when |
|---|---|
| `Options_Text.lua:429` — tag reference (`Tags:AllHelp()`) | always |
| `Options.lua:298` — derived poller status | always (General tab) |
| `Options.lua:339` — LibClassicDurations status | always (General tab) |
| `Options.lua:598` — version | always |
| `Options_Layout.lua:707` — ticker stats | always (Layout tab) |
| `Options.lua:166` — `BreakerNotice`, used by Auras, Text, healPrediction, combo, indicators | only when that element's breaker has tripped |
| `Options.lua:204` — `combatNotice` | only when a change is queued behind combat |

This weakens the discriminator the plan proposed. "Auras has no dynamic-name
description" is **false** — `Options_Auras.lua:92` calls `BreakerNotice`. It
survives only on a technicality: `BreakerNotice` and `combatNotice` both carry
`hidden = function() ... end` and contribute no height in the normal case, so
Auras has no *visible* dynamic description **provided** no breaker has tripped
and nothing is queued behind combat.

So step 1 below is still usable, but only with those preconditions stated, and
it is doing less work than it looks like it is. This is the main reason to
measure rather than eyeball: the probe can report the content height AceConfig
actually computed against the viewport height, which settles the question
directly instead of inferring it from which tab misbehaves.

---

## Diagnosis, before any fix

**Step 2 is done** — see the correction above. Our ScrollFrame is byte-identical
to current upstream, and neither sets `SetClipsChildren`. Nothing further to
check statically.

The remaining steps all need a running client. Rather than eyeball them, they go
through the probe addon, which is the established pattern here
(`healthProbe`, `portraitProbe`, the aura-order and rage traces all exist for
the same reason): **`/dufprobe scroll`**, added to
`Probe/DyrueUnitFrames_Probe/Probe.lua`.

The probe reports, with the options window open:

1. **Which client** — `GetBuildInfo()` version, build and interface number, plus
   `WOW_PROJECT_ID`, so the two installed flavors can be compared without
   guessing which one the report came from.
2. **`GetClipsChildren()` live** on the scroll frame, and whether the method
   exists at all on this build — the plan's step 3, measured.
3. **Geometry**: the scroll frame's rect versus the content child's, and the
   content height AceConfig computed versus the viewport height. If content
   height is wrong, the dynamic-description hypothesis is live; if it is right
   and children still draw outside, it is clipping.
4. **Overflow census**: walk the content child's children and list any whose
   rect extends past the scroll frame's bottom edge while still being shown.
   Those are exactly the things in the screenshot, named and measured.
5. **The scrollbar's parentage and rect**, because that determines whether the
   obvious fix is safe — see the trap under fix option 2.

That makes steps 1 and 4 of the original list cheap follow-ups rather than the
main event: open Auras, re-run, compare numbers; then swap `AllHelp()` for a
literal, re-run, compare again. Both are now differences in reported numbers
rather than judgments about a screenshot.

---

## Fix options, in order of preference

### 1. ~~Update the vendored AceGUI-3.0~~ — ruled out, 8 August 2026

**Struck.** This was the preferred option on the assumption that upstream had
already fixed it. It has not: our ScrollFrame is byte-identical to
`WoWUIDev/Ace3` at `master`, both version 26, neither calling
`SetClipsChildren`. There is no newer release to pin to, so there is nothing
this option can do. Keep the reasoning on record — updating a pinned library
*would* have been legitimate under §11.2 and not "modifying in place" — but it
does not apply here.

### 2. Set the property from our side — now the leading candidate

Call `SetClipsChildren(true)` on the container after `AceConfigDialog:Open`,
from `Config/Options.lua`. Reaching into a library's widget from outside is not
lovely, but it leaves `Libs/` untouched, which is the constraint §11.2 actually
imposes.

**The trap, found 8 August 2026: this is not a one-line change.** The scrollbar
is created as a child of the scroll frame and anchored *outside* its right edge
(`Libs/AceGUI-3.0/widgets/AceGUIContainer-ScrollFrame.lua:177`):

```lua
scrollbar:SetPoint("TOPLEFT", scrollframe, "TOPRIGHT", 4, -16)
scrollbar:SetPoint("BOTTOMLEFT", scrollframe, "BOTTOMRIGHT", 4, 16)
```

So a naive `scrollframe:SetClipsChildren(true)` clips the scrollbar away along
with the overflow — and the floating arrow pairs in the screenshot *are* that
scrollbar's `UIPanelScrollBarTemplate` up/down buttons. The fix would trade a
cosmetic overflow for a missing scrollbar, which is worse.

Options, to be chosen once the probe says what is actually unclipped:

- Set the property on the **content child's** relationship instead, if the
  overflow proves to be content children rather than the scrollbar itself.
- Reparent the scrollbar to the widget's outer `frame` before clipping
  (`scrollbar:SetParent(widget.frame)` plus re-anchoring). Still our code, still
  `Libs/` untouched, but a deeper reach and it must survive widget reuse from
  AceGUI's pool.
- If the arrows are the *only* artifact, this may be a scrollbar-positioning
  problem and not a clipping problem at all, which would move the fix elsewhere
  entirely.

The probe's scrollbar-parentage and overflow-census output is what decides
between these, which is why it is worth building before writing any fix.

### 3. Restructure the offending option

If it turns out to be the dynamic description: give the tag reference a fixed
`name` string built once at `Options:Build()` rather than a function, or move it
behind a "Show tag reference" execute that prints to chat (`/duf tags` already
does exactly that). Cheapest of the three and removes a measurement problem
rather than working around it.

### 4. Fork AceGUI under a different name

Only if 1–3 all fail. Heavy, and §11.2 sets the bar high deliberately.

---

## Files

| File | Change | When |
|---|---|---|
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | Add the `scroll` sub-probe and its `/dufprobe` dispatch entry | **Now** — this is the diagnosis vehicle |
| `Config/Options.lua` | The fix itself, per option 2 | After the probe reports |
| `Config/Options_Text.lua` | Only if it proves to be the dynamic description (option 3) | After the probe reports |
| `Libs/LICENSE.md` | Fix the claim that per-widget versions live in that table; they live in each widget's `local Type, Version` line | Now, alongside the probe |
| `Documents/COMPAT_FINDINGS.md` | Record the `GetClipsChildren` default and interface build once measured | With the fix |

~~`Libs/AceGUI-3.0/**` replaced wholesale~~ — ruled out; we are already at
upstream.

**No schema change, no migration.** This is presentation only.

---

## Tests

Headless tests cannot see this — it is a rendering and measurement problem in a
library the harness stubs out entirely.

What the harness *can* do is guard the restructure if option 3 is taken: assert
the tag-reference entry has a string `name` rather than a function, so it cannot
silently regress to a dynamic one.

Verification is by `/dufprobe scroll` plus eye, on both clients, on:

- Player → Text with several text elements,
- Player → Auras → Buffs (long) — **with no breaker tripped and nothing queued
  behind combat**, or the hidden dynamic-name descriptions listed above become
  visible and Auras stops being a clean control,
- a window resized small enough to force scrolling,
- and after switching tabs, which is when a stale content height would show.

Run the probe on each, and keep the output: the numbers are the before-and-after
evidence that the fix did something, which a screenshot pair cannot establish
for a few pixels of overflow.

---

## Risks

| Risk | Handling |
|---|---|
| ~~Updating AceGUI changes other behavior~~ | Moot — option 1 is struck, no library update happens |
| **Clipping the scroll frame hides the scrollbar** | The trap under option 2. The probe reports scrollbar parentage and rect *before* any fix is written, and the fix is verified by confirming the scrollbar still draws and still scrolls |
| It is a client-side change we cannot fix | Option 3 sidesteps it by removing the measurement problem |
| Fixing the symptom and not the cause | Diagnosis runs *first*, and now by measurement rather than by eye — the plan's original discriminator turned out to be weaker than written |
| Reaching into a pooled widget breaks on reuse | Any `SetParent`/`SetClipsChildren` we apply has to be re-applied or proven to survive AceGUI releasing and re-acquiring the container; verify by closing and reopening the options window several times, and by switching tabs |

---

## Estimate

Revised 8 August 2026. Still dominated by diagnosis, but the shape has changed:
the cheap escape (bump the library) is gone, and the cheap fix (one call) has a
trap in it.

- Probe: under an hour, and it is written before anything else.
- If it is the dynamic description (option 3): under an hour after that.
- If it is clipping and the scrollbar needs reparenting: 2–3 hours, most of it
  verifying that the reach-in survives AceGUI's widget pool across
  close/reopen and tab switches.
