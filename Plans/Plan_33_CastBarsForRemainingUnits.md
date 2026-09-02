# Plan 33 — Cast Bars for Party, Focus and Pet

**Status:** Not started.
**Created:** 1 September 2026
**Branch:** `Plan-33-remaining-cast-bars`
**Depends on:** Plans 30, 31 and 32. Branch from `main` after all three merge.

---

## Request

> i understand that, per prior docs, player and target cast bars are out of scope. I want you to estimate how difficult it would be to add support for those, as independently movable frames which are by default attached to the player and target frames. consider the difficulty of adding cast bars for other frame types (party, focus, etc) as well

**This plan covers the last clause** — *"cast bars for other frame types (party,
focus, etc)"*. It is deliberately the thinnest of the four, and that thinness is
the finding rather than a gap.

---

## Interpretation

"Other frame types" is read as **every remaining registered unit**, and the
answer is not the same for all of them. Three groups, decided here:

| Group | Decision |
|---|---|
| `focus`, `party1-4` | Ship the frames, **off by default** |
| `pet`, `partypet1-4` | Ship the frames, **off by default** |
| `targettarget`, `focustarget` | **Do not ship.** Argued below |

Once Plan 31 exists, each shipped bar is a `Registry` entry and a `Defaults`
entry — around six lines each. The interesting content of this plan is the
exclusion, the defaults, and one measurement.

---

## Design

### 1. The ones that are table entries

`focus` first, because it demonstrates the machinery is genuinely free:

```lua
define("focuscast", {
    order = 55,
    label = L["Focus Cast Bar"],
    kind = "castbar",
    token = "focus",
    secure = false,
    unitWatch = false,
    requires = "hasFocus",
    changeEvents = { "PLAYER_FOCUS_CHANGED" },
})
```

`requires = "hasFocus"` is the entire Classic Era story. `Registry:IsAvailable`
(`Units/Registry.lua:117`) makes the frame not get created, and
`Options:Build` (`Config/Options.lua:588`) makes its config subtree not get
built — *absent, rather than present and broken*, per §FR-8.5. No new gating
code, and Plan 21's existing focus-gating tests cover it.

Party is the same shape in a loop beside the existing `party` / `partypet`
definitions, with `changeEvents = { "GROUP_ROSTER_UPDATE" }`. Pet takes
`owner = "player"` and `changeEvents = { "UNIT_PET" }`, matching the pet frame's
own definition (`Registry.lua:60-66`) and its comment about `UNIT_PET` firing
with the owner as payload.

Defaults anchor each bar under its own frame, mirroring Plans 31 and 32:
`focuscast` under `focus`, `partyNcast` under `partyN`, `petcast` under `pet`.
Widths match their host frames — 180 for focus and party, 150 for pet — so the
default layout lines up without anyone touching a slider.

### 2. Everything ships off, and that is not timidity

Nine or thirteen new frames all appearing at once on upgrade would be a worse
experience than the feature is worth, and unlike the target cast bar (Plan 32,
shipped on, because interrupting is the point) none of these answers a question
the user is asking every second.

Off also keeps the frame-count claim honest: a disabled unit is never created at
all (`Factory:CreateAll` skips it via `ApplyConfig`'s early return, and
`ApplyConfig` unregisters the unit watch and hides), so a user who wants two cast
bars pays for two.

`party` is the one with a real argument for shipping on — a healer wants to see
party casts. It still ships off, because a healer will find the checkbox and a
non-healer would have to hunt for four they never asked for.

### 3. Derived units are excluded, and the reason is mechanical

`targettarget` and `focustarget` get no cast bar, and this is a decision rather
than an omission.

Their values are sampled by `Units/DerivedPoller.lua` at a default 0.25s
(`DerivedPoller.lua:27`) because, as `SPEC.md` §4.8 records, `*target` tokens do
not receive reliable unit events. A cast bar driven off that poller would:

- start up to 250 ms late on every cast, and
- **miss entirely** any cast shorter than the poll interval — which is every
  instant cast and a good share of the ones worth reacting to.

A bar that silently omits short casts is worse than no bar, because it teaches
the user to trust it. The precedent for the handling is `SPEC.md` §FR-8.5 and the
combo-point treatment in `Options_Layout.lua:1155` — the control is **absent**
rather than present and permanently disappointing.

Two things make this cheap to hold and cheap to revisit:

- `Registry:IsDerived` (`Registry.lua:130`) already exists, so the exclusion is
  one condition rather than a list of keys to maintain.
- The probe's existing run saw `UNIT_SPELLCAST_SENT` under `targettarget`
  (`COMPAT_FINDINGS.md:772`), which hints the events may reach these tokens after
  all. If Plan 32's extended probe run confirms `START` and `STOP` do too, the
  poller stops being relevant and this exclusion can be lifted in a later plan
  on evidence. Note that in `COMPAT_FINDINGS.md` when the probe result lands, so
  the question is recorded rather than rediscovered.

### 4. Measure the frame budget once

Twelve unit frames become up to twenty-five. The claim throughout Plans 30–32 has
been that this is cheap: one shared driver, and a non-casting cast bar is a
hidden frame whose `OnUpdate` does not run.

That claim is now large enough to be worth checking rather than repeating. With
every cast bar enabled in a party, run `/duf profile` and record the memory and
per-frame CPU figures in `COMPAT_FINDINGS.md` against the §6 budget. It is one
command and it either confirms three plans' worth of reasoning or catches the one
place it was wrong.

---

## Files

| File | Change |
|---|---|
| `Units/Registry.lua` | `focuscast`, `petcast`, `party1-4cast`, `partypet1-4cast`; derived units explicitly excluded |
| `Core/Defaults.lua` | Matching `castUnit()` entries, all `enabled = false`. `SCHEMA_VERSION` 20 → 21 |
| `Core/Compat.lua` | `blizzardFrames` entries for the party and focus casting bars |
| `Documents/SPEC.md` | §3's unit table gains the frames; the derived-unit exclusion recorded beside the existing §FR-8.5 cases |
| `Documents/COMPAT_FINDINGS.md` | The `/duf profile` figures; the derived-unit question left open with what would settle it |
| `README.md` | The cast bar section, written once here for all four plans |
| `Tests/tests.lua` | Below |

---

## Schema and migration

Additive, `EnsureProfile` fills, no migration step. Bump to 21.

The `enabled = false` default is what makes this safe: an upgrading user's
profile gains thirteen keys and no visible change whatsoever.

---

## Tests

Do **not** write thirteen near-identical tests. The value here is in the
properties that hold across the set:

- Every `kind == "castbar"` def resolves its anchor to its host unit's frame, and
  moves with it. One loop over the Registry.
- Every one of them ships `enabled = false` except `playercast` and `targetcast`.
- **No derived unit has a cast bar** — assert over `Registry:IsDerived`, so the
  exclusion cannot be silently lost when someone adds a future derived unit.
- On a client with `hasFocus = false`, `focuscast` is neither created nor
  present in the options tree. Extend Plan 21's existing focus-gating test rather
  than writing a new one.
- With every cast bar enabled and none casting, the driver is **stopped** and its
  attached count is zero. This is the §5.7 claim at its largest scale and is the
  single most valuable assertion in the plan.
- A `partypet` cast bar with no pet stays hidden.

---

## Risks

| Risk | Handling |
|---|---|
| Thirteen more frames regress the §6 performance budget | Measured with `/duf profile` as above, not asserted. Everything ships off, so the default install is unaffected regardless |
| The derived-unit exclusion reads as an oversight later | Written into `SPEC.md` beside the other §FR-8.5 cases, asserted in tests, and paired with the specific probe result that would justify lifting it |
| Party cast bars need a group layout like `Units/PartyGroup.lua` | Explicitly **not** in scope. Each bar anchors to its own party frame, so the group layout moves them all for free — that is the anchor graph working as designed. If someone later wants them stacked independently of the frames, that is its own plan |
| Blizzard's party/focus casting bar names are wrong or absent | `HideBlizzardFrame` resolves lazily and returns false for anything missing (`Compat.lua:696`), which is why names may be listed speculatively. Confirm the live names during the same session as the `/duf profile` run |

---

## Estimate

**Trivial in code, worth a sitting for the documentation and the measurement.**
Perhaps thirty lines of table entries, one property-based test loop, one
`/duf profile` run, and the SPEC and README updates that close out all four
plans.

This is the plan that proves the sequence was worth doing in this order. The
answer to *"how hard would cast bars for party and focus be?"* is **six lines
each** — but only because Plan 31 paid for it first, and only for the units where
the game actually pushes the events.
