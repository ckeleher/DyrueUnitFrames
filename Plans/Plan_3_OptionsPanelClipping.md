# Plan 3 — Options Panel Clipping

**Status:** Not started — needs diagnosis first
**Created:** 2 August 2026
**Branch:** `first`

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
`SetClipsChildren(true)`. Newer AceGUI-3.0 sets that explicitly. Our vendored
copy came from a Bartender4 build (`Libs/AceGUI-3.0`, widget versions recorded
in `Libs/LICENSE.md`) and may predate it, *or* the Midnight-era shared UI may
have changed the default.

Supporting evidence: the floating arrow pairs are AceGUI's scroll-up/scroll-down
indicators, which live on the scroll frame itself. Their appearing outside the
container is characteristic of an unclipped scroll child rather than anything
our option tree can cause.

**Competing hypothesis worth ruling out:** the Text tab is the one place we use
`type = "description"` with a `name` **function** that returns a long,
dynamically built string (`ns.Tags:AllHelp()`). AceConfigDialog measures
description heights to lay out the scroll child, and a dynamic name can be
measured before it is populated, giving a wrong content height. That would
misplace things without being a clipping bug at all.

The two are distinguishable: if it is clipping, the same overflow appears on any
tab long enough to scroll; if it is the dynamic description, it is specific to
tabs containing one.

---

## Diagnosis, before any fix

1. Open a different long tab (Auras, or a unit with several text elements) and
   see whether the overflow reproduces. Auras has no dynamic-name description.
2. Check the vendored `AceGUI-3.0/widgets/AceGUIContainer-ScrollFrame.lua` for a
   `SetClipsChildren` call and compare against current upstream AceGUI-3.0.
3. In-game, `/dump` the scroll frame's `GetClipsChildren()` to see the live
   value.
4. Temporarily replace `ns.Tags:AllHelp()` with a short literal string and see
   whether the misplacement follows the dynamic name.

---

## Fix options, in order of preference

### 1. Update the vendored AceGUI-3.0

If upstream already fixes it, this is the correct answer. `SPEC.md` §11.2:

> Never modify a library in place. If a patch breaks one, wait for upstream or
> fork it explicitly under a different name.

Updating to a newer pinned release is not "modifying in place" — it is exactly
the "deliberate, testable act" §5.10 describes. Update, re-pin the version table
in `Libs/LICENSE.md`, and re-run the suite.

### 2. Set the property from our side

If upstream has not fixed it, call `SetClipsChildren(true)` on the container
after `AceConfigDialog:Open`, from `Config/Options.lua`. Reaching into a
library's widget from outside is not lovely, but it is a single call in our own
code and leaves `Libs/` untouched, which is the constraint that matters.

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

Depends entirely on the diagnosis. Likely one of:

- `Libs/AceGUI-3.0/**` replaced wholesale plus `Libs/LICENSE.md` version table, or
- `Config/Options.lua` (one call, or the description restructure).

**No schema change, no migration.** This is presentation only.

---

## Tests

Headless tests cannot see this — it is a rendering and measurement problem in a
library the harness stubs out entirely.

What the harness *can* do is guard the restructure if option 3 is taken: assert
the tag-reference entry has a string `name` rather than a function, so it cannot
silently regress to a dynamic one.

Verification is by eye, on both clients, on:

- Player → Text with several text elements,
- Player → Auras → Buffs (long),
- a window resized small enough to force scrolling,
- and after switching tabs, which is when a stale content height would show.

---

## Risks

| Risk | Handling |
|---|---|
| Updating AceGUI changes other behavior | Full suite plus a manual pass over every options tab; the version table in `Libs/LICENSE.md` records exactly what moved |
| It is a client-side change we cannot fix | Option 3 sidesteps it by removing the measurement problem |
| Fixing the symptom and not the cause | Diagnosis steps above run *first*; the two hypotheses are distinguishable |

---

## Estimate

1–4 hours, dominated by diagnosis. If it is the dynamic description, under an
hour. If it needs an AceGUI update, most of the time is re-verification rather
than the change.
