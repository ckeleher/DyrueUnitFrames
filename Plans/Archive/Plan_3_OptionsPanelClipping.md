# Plan 3 — Options Panel Clipping

**Status:** Implemented and merged in
[#17](https://github.com/ckeleher/DyrueUnitFrames/pull/17) (`8654680`). **None of
the four fix options below was the answer**, and both of the plan's hypotheses
were wrong. See *Outcome* at the foot of this document, which is the
authoritative record where it and the body disagree.
**Created:** 2 August 2026
**Updated:** 9 August 2026
**Branch:** `Plan-3-options-panel-clipping`

> **Read this first.** Neither of the two hypotheses below is the cause, and
> neither is the zero-height viewport that the first probe run found — that was
> itself a symptom. The real cause was a tall inline group evicting a nested tree
> widget from its parent. The body is kept because its reasoning is what ruled
> the alternatives out, but jump to *Outcome* for what actually happened.

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

## What the first probe run found — 8 August 2026

**Classic Era 1.15.9 / build 69109, toc 11509, via `/dufprobe scroll`** on
Player → Text with the options window open. Recorded in full in
`Documents/COMPAT_FINDINGS.md` under *Plan 3*.

```
viewport  w=234 h=0   top=322 bottom=322
content   w=234 h=797 top=322 bottom=-475
scrollbar w=16  h=0   top=338 bottom=338
```

**The scroll frame has no height.** That is the finding, and it is neither
hypothesis. Three things follow, and they redirect the whole plan:

1. **The overflow is a symptom.** With a zero-height viewport, all 215 laid-out
   objects are outside it by definition. Clipping cannot help, because there is
   no region to clip to. Fixing `SetClipsChildren` would have changed nothing.
2. **Nothing is mis-measured.** `content.height` and `content:GetHeight()` agree
   at 797. The dynamic-`name` description theory is ruled out *as the cause* —
   the layout computed a sane content height, and the viewport it was measured
   against is what is wrong.
3. **The floating arrows are explained exactly.** The scrollbar is anchored `-16`
   and `+16` against the viewport's own top and bottom, so a zero-height viewport
   collapses it to `h=0` and leaves its `ScrollUpButton` and `ScrollDownButton`
   16px either side of a single point, both visible, with no container around
   them. The *second* pair is the TreeGroup's own scrollbar
   (`AceGUIContainer-TreeGroup.lua:670`), which uses the same
   `UIPanelScrollBarTemplate`.

Also measured, and it changes what any fix can verify:

| | Classic Era 1.15.9 |
|---|---|
| `Frame:SetClipsChildren` | **present** |
| `Frame:GetClipsChildren` | **absent** |

The state cannot be read back on this build. Clipping can be applied but not
confirmed from Lua, so verification is by measuring whether children still draw,
not by asserting on the property. Not yet checked on Anniversary.

### Still open: why is the height zero?

Two candidates, needing different fixes:

- **Never sized.** The window's layout never gives the content area a height, in
  which case the fix is wherever that height is supposed to come from.
- **Stale after a tab switch.** The height was right once and was not recomputed,
  in which case the fix is a re-layout at the right moment.

`/dufprobe scroll` now prints the **ancestry** — every ancestor's height, width
and anchor points up to `UIParent` — which separates these. In the first run the
zero went all the way up, and the TreeGroup frame beside it was zero too, so
whatever it is sits above both and is not specific to the content scroll frame.

### What the run exposed in the probe itself

Both fixed on the branch, recorded because they affect how the next output reads:

- It reported **another addon's panel** as container #1, complete with a
  character roster. Widget numbering and scrollbar names are global across every
  addon sharing the AceGUI instance. Containers are now attributed through
  `AceConfigDialog.OpenFrames` (via LibStub's silent form, so a broken Ace3
  degrades to "owner unknown" rather than erroring) and foreign ones collapse to
  one line.
- The scrollbar-state mismatch check only ran in **one direction**, so it missed
  that other addon's `scrollBarShown = true` against a hidden bar. Now reported
  either way round.

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

### 0. Give the viewport a height — the actual fix, pending the ancestry read

Added 8 August 2026, and it supersedes everything below. The measured cause is a
zero-height scroll viewport, so the fix is wherever that height should come from
and does not. Options 1–4 were all written against symptoms.

This cannot be specified further until the ancestry output says which frame the
zero starts at, and whether it is zero on a fresh open or only after a tab
switch. Those are different fixes:

- **Zero from a fresh open** — the window is never sized, and the fix is at the
  point where `AceConfigDialog:Open` and our option tree hand off.
- **Zero only after a tab switch** — a re-layout is missing, and the fix is to
  force one when the selected group changes.

**One candidate already eliminated statically.** `Core/Core.lua:440` calls
`AceConfigDialog:Open(ADDON)` with no size, and we never call
`AceConfigDialog:SetDefaultSize`. That is *not* the cause: the library fills in
its own defaults when the status table is empty
(`AceConfigDialog-3.0.lua:1900-1905`, `width = 700`, `height = 500`), so the
window is sized whether we ask or not. Adding a `SetDefaultSize` call would be
cargo cult.

That elimination sharpens the question. The observed viewport was **234 wide**,
which is nothing like the content column of a 700-wide window — the tree takes
about 175 and padding a little more, leaving roughly 480. So the outer window
itself was small, not merely short. The status table is written back when the
frame is dragged, so a resize during the session is one explanation and a
collapsed or mid-layout frame is another. The probe now reports the status
table's width and height alongside the ancestry, which distinguishes them.

Deliberately not guessed at. The previous two rounds of this plan were both
confident and both wrong; the ancestry read costs one more `/dufprobe scroll`.

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

| File | Change | Status |
|---|---|---|
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | The `scroll` sub-probe: geometry, overflow census, scrollbar parentage, ancestry walk, TreeGroup coverage, container attribution | **Done** — `18910cf`, `2affb2e` |
| `Libs/LICENSE.md` | Note that AceGUI's widgets version independently of the core, with the ScrollFrame row verified against upstream | **Done** — `18910cf` |
| `Documents/COMPAT_FINDINGS.md` | Classic Era build identity, the `GetClipsChildren`-absent finding, the zero-height observation | **Done** — `2affb2e` |
| Wherever the viewport height comes from | The fix, per option 0 | **Blocked** on the ancestry read |
| ~~`Config/Options.lua`~~ | ~~`SetClipsChildren` per option 2~~ | Superseded — clipping is not the cause |
| ~~`Config/Options_Text.lua`~~ | ~~Restructure the dynamic description per option 3~~ | Superseded — the content height measured correctly |

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
| Fixing the symptom and not the cause | **This risk materialized twice.** Both original hypotheses were symptoms; the measured cause is a zero-height viewport. The lesson held anyway: diagnosis ran first, and the numbers overturned the reasoning rather than confirming it |
| The clipping state cannot be verified on Classic Era | `GetClipsChildren` is absent while the setter is present, so no assertion can read it back. Any fix touching clipping is verified by measuring whether children still draw, never by reading the property |
| Trusting the probe's container list | The first run attributed another addon's panel to us. Containers are now attributed through `AceConfigDialog.OpenFrames`; treat any output labelled "owner unknown" with suspicion |
| Reaching into a pooled widget breaks on reuse | Any `SetParent`/`SetClipsChildren` we apply has to be re-applied or proven to survive AceGUI releasing and re-acquiring the container; verify by closing and reopening the options window several times, and by switching tabs |

---

## Estimate

Revised 8 August 2026. Still dominated by diagnosis, but the shape has changed:
the cheap escape (bump the library) is gone, and the cheap fix (one call) has a
trap in it.

- Probe: **done**, two rounds.
- If it is the dynamic description (option 3): ~~under an hour~~ — ruled out.
- If it is clipping and the scrollbar needs reparenting: ~~2–3 hours~~ —
  superseded.

**Revised again, 8 August 2026, after the first live run.** The remaining work is
one more `/dufprobe scroll` to read the ancestry, then a fix whose size depends
on what it says: a missing size or a missing re-layout is likely under an hour,
and a genuine client-behavior change in how these frames resolve their height
could be considerably more. Not worth a tighter number until the ancestry is in —
the two previous estimates were both made against causes that turned out to be
wrong.

**Actual:** roughly a day, essentially all of it diagnosis. The fix is one line.

---

## Outcome

**Merged 9 August 2026 in [#17](https://github.com/ckeleher/DyrueUnitFrames/pull/17),
squashed as `8654680`.** Authoritative where it disagrees with anything above.

### The cause

The ancestry read, on Classic Era 1.15.9, heights from the window inward:

```
AceGUI:Frame        h=433
 TreeGroup          h=420
  Frame             h=420
   TreeGroup        h=400
    TabGroup        h=373
     Frame          h=320
      TabGroup      h=306    <- last healthy frame
       TreeGroup    h=0      TOPLEFT (0, -324.9)   <- collapses here
        Frame       h=0
         TreeGroup  h=0
          ScrollFrame h=0
           content     h=797
```

A group carrying `childGroups` renders its child groups as a nested tree or tab
widget, and AceGUI places that widget **below** whatever loose args the same
group has. The tag reference was an `inline = true` group at `order = 0`, and
`Tags:AllHelp()` is 22 lines — about 325px. The unit's tab content is ~306px, so
the nested tree was anchored 324.9px down inside 306px: its top landed 18.9px
below its own bottom and the height clamped to zero. Every descendant inherited
it, including the scroll frame, whose 797px of content then drew unclipped.

The scrollbar is anchored `-16` / `+16` against the viewport's own edges, so it
collapsed too and left its up and down buttons either side of a single point —
the floating arrows in the request. The second pair was the TreeGroup's own
scrollbar, which uses the same template.

### The fix

`Config/Options_Text.lua`: the tag reference became its own tree node instead of
an inline group, so it renders inside the scroll frame and costs the parent
container nothing. Ordered last, so opening Text still lands on a text element.

### Every option in this plan was wrong

Worth recording plainly, because the plan was rewritten twice and was still
wrong the third time:

| Option | Verdict |
|---|---|
| 1. Update vendored AceGUI | Dead. Byte-identical to upstream `master`, both v26, neither sets `SetClipsChildren`. Nothing to update to |
| 2. `SetClipsChildren` from our side | Would have done nothing — there was no region to clip to — and would have clipped the scrollbar away, since the bar is a child of the scroll frame anchored outside its right edge |
| 3. Restructure the dynamic description | Right file, wrong reason. The description was never mis-measured; `content.height` was correct at 796.8. It was simply tall enough to evict its sibling |
| 4. Fork AceGUI | Never needed. `Libs/` was untouched |
| 0. Give the viewport a height | The closest, but still aimed at a symptom. The viewport's height was inherited |

The one structural lesson: **the plan's diagnosis section was the part that
worked.** Every hypothesis in it was wrong, and it still converged, because it
insisted on measurement before a fix and the measurements kept overturning the
reasoning.

### What else came out of it

- `Tests/tests.lua` gained a tripwire for the *shape*: for any group with
  `childGroups`, estimate the lines of loose text above its nested widget and
  fail past a budget. Verified by reintroducing `inline = true`, which trips it
  on all fourteen units.
- `/dufprobe scroll [label]` is now a permanent sub-probe: geometry, ancestry
  walk, overflow census, scrollbar parentage, window status table. Chat gets a
  summary; the detail goes to SavedVariables, because a ~90-line report is
  silently truncated by the chat frame — and the truncated part was the ancestry.
- Container attribution has to check **both** `AceConfigDialog.OpenFrames` and
  `AceConfigDialog.BlizOptions`; `Core/Core.lua:316` registers through the
  latter. Checking one reported another addon's panel as ours, and ours as
  nobody's.
- `Documents/COMPAT_FINDINGS.md` gained the Classic Era build identity and the
  finding that **`GetClipsChildren` does not exist there while
  `SetClipsChildren` does** — clipping can be applied but never read back.
- `Libs/LICENSE.md` now records that AceGUI's widgets version independently of
  the core, which is the trap that made option 1 look plausible.

### Left undone

Every measurement is Classic Era. **The Anniversary client was never measured**,
and its `GetClipsChildren` absence in particular should not be assumed to match.
The fix is structural and does not depend on the client, but the compat table's
Anniversary column is still `_(fill in)_`.
