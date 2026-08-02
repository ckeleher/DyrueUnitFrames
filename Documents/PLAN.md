# Dyrue Unit Frames — Implementation Plan

**Companion to:** `SPEC.md`
**Date:** 2 August 2026
**Targets:** Classic Era / Hardcore 1.15.9 (`11509`) and TBC Anniversary 2.5.6 (`20506`)

---

## 1. Guiding principles

These are the decisions that everything else follows from. If a task conflicts with one of these, the task is wrong.

1. **Contain Blizzard.** All version-sensitive and Blizzard-UI-touching code lives in `Core/Compat.lua`. Nothing else calls a version-sensitive API directly. A patch-day fix should be a diff to one file.
2. **Probe capabilities, don't assume them.** `if Compat.hasFocus` beats `if tocVersion >= 20000`. Every capability flag is set by testing for the thing at load time.
3. **Ship something usable early, then layer.** Phase 2 produces a working replacement for the most-used 60% of SUF. Everything after that is improvement on a thing that already works, not progress toward a thing that doesn't.
4. **Every phase ends with a green test pass on both clients.** No phase is "done" because the code is written.
5. **Degrade, never cascade.** A broken element disables itself. It does not spam the error frame or take down the frame it lives on.
6. **Clean room.** SUF is All Rights Reserved. Its *behaviour* is fair game to reference; its *source* is not to be read while writing the corresponding code.

---

## 2. Effort summary

Estimates assume working sessions of a few hours with AI assistance on the Lua. They are ranges, not commitments — the wide ones are wide for a reason.

| Phase | Scope | Estimate | Requirement satisfied |
|---|---|---|---|
| 0 | Reconnaissance, scaffold, license | 3–5 h | — (de-risks everything) |
| 1 | Foundation: core, secure frames, health/power | 8–12 h | — |
| 2 | Layout, config UI, party frames, **derived units** | 17–23 h | **Easy editing**, **Party frames**, **ToT / focus / focus-target** |
| 3 | Bar colouring, shapeshift mana, **portraits** | 10–15 h | **Class colours**, **Druid mana**, **Portraits** |
| 4 | Text and colour-rule engine | 14–20 h | **Colour-codable text** |
| 5 | Buffs and debuffs | 13–19 h | **Buffs/debuffs** |
| 6 | Hardening, test mode, release | 9–13 h | — |
| **Total to v1.0** | | **74–107 h** | |
| 7 | v1.x backlog | open | — |

Up from 61–90 h at draft. Party frames, portraits, and derived units account for the increase; each was added deliberately with the cost visible.

Phase 4 is the largest single item and the one most likely to overrun; it is also the one with the most design already settled in the spec, which is deliberate.

---

## 3. Phase 0 — Reconnaissance and scaffold

**Why this exists:** every subsequent phase makes assumptions about what the 2.5.6/1.15.9 API actually provides. Guessing wrong in Phase 5 costs a rewrite; finding out in Phase 0 costs an afternoon. This phase produces facts, not features.

### Tasks

**0.1 — Build `DyrueUnitFrames_Probe`, a throwaway diagnostic addon.**
A single Lua file, no libraries, that dumps to chat and to a saved variable:

- `GetBuildInfo()` — confirm interface numbers on both clients
- Existence and signature of: `C_UnitAuras.GetAuraDataByIndex`, `UnitAura`, `AuraUtil.ForEachAura`
- Whether `UNIT_AURA` delivers an `updateInfo` payload, and its shape
- Whether `issecretvalue` / `canaccessvalue` exist at all (they should not — confirm)
- `Enum.PowerType.Mana` value; whether `Enum` exists
- `GetCreatureDifficultyColor`, `GetQuestDifficultyColor`, `PowerBarColor`, `DebuffTypeColor`, `RAID_CLASS_COLORS`
- `SecureUnitButtonTemplate` availability; `RegisterUnitWatch`; `RegisterUnitEvent`
- `UnitExists("focus")` behaviour on Classic Era vs TBC
- Whether Edit Mode exposes an option to hide `PlayerFrame` / `TargetFrame` natively
- Names and existence of the default frames we may need to hide

**0.2 — Shapeshift mana event trace.** *(Druid confirmed available — this is unblocked.)*
Log every `UNIT_POWER_UPDATE`, `UNIT_MAXPOWER`, `UNIT_DISPLAYPOWER`, `UPDATE_SHAPESHIFT_FORM` for 60 seconds while shifting in and out of Bear and Cat and spending mana. **Answers:** does mana fire events while shifted, or is the fallback ticker mandatory?

**0.3 — Derived-unit event probe.** The design in `SPEC.md` §4.8 assumes `targettarget` does not receive reliable unit events. Verify rather than inherit the assumption:
- Register `UNIT_HEALTH`, `UNIT_POWER_UPDATE`, and `UNIT_AURA` for `targettarget` and log every hit while a target's target takes damage.
- Confirm `UNIT_TARGET` fires with `"target"` as its payload when the target switches targets, and with `"focus"` on TBC.
- Confirm `RegisterUnitWatch` shows and hides a `targettarget` frame correctly.
- On TBC: confirm `UnitExists("focus")` and `PLAYER_FOCUS_CHANGED`. On Classic Era: confirm both are absent, which is what `Compat.hasFocus` will key on.

If events *do* fire reliably, the poller becomes a fallback rather than the primary mechanism and §4.8 gets amended — a good outcome, and precisely why this is probed rather than assumed.

**0.4 — Enemy health probe.**
Target a same-level mob, an elite, and a raid boss; record `UnitHealth`, `UnitHealthMax`, and their behaviour as health drops. Confirm the 0–100 scaling and find the cleanest detection predicate.

**0.5 — Scaffold the real addon.**
Folder structure per `SPEC.md` §5.1, TOC with comma-delimited interface versions, Ace3 and LibSharedMedia embedded and pinned, `/duf` slash command that prints the version. Loads clean on both clients.

**0.6 — Set up the repo.**
Git, `.gitignore`, and a symlink or copy script from the repo to both `Interface/AddOns` directories so there is no manual file shuffling for the next hundred hours. This pays for itself in week one.

**0.7 — License and string hedges.** Under an hour, and the entire cost of keeping publication possible later:
- `LICENSE` file at the repo root, **MIT**. Do this on day one, not at release.
- Read and preserve each embedded library's actual license file under `Libs/<Library>/`. Verify the terms rather than assuming — they are all permissive but their attribution requirements differ.
- Create `Core/Locale.lua` with a single enUS `L` table and route user-facing strings through it from the first string onward.

**0.8 — Portrait feasibility probe.** Since all three portrait modes are in scope, confirm on both clients:
- `SetPortraitTexture` behaviour and the fallback texture path for unavailable portraits
- Whether a `PlayerModel` frame with `SetUnit` renders correctly, and what it does on target change, on a loading screen, and for an out-of-range unit
This determines how much defensive handling §FR-7.4 actually needs versus how much is precautionary.

### Deliverables
`COMPAT_FINDINGS.md` (the answers, written down), a loading scaffold, a working dev loop.

### Gate
Scaffold loads without error on **both** clients. Every question in 0.1–0.4 has a written answer. If any finding contradicts `SPEC.md`, the spec is amended before Phase 1 begins.

---

## 4. Phase 1 — Foundation

**Goal:** a player frame and a target frame that are clickable, correctly show health and power, and never error.

### Tasks

**1.1 — `Core/Core.lua`.** Ace3 addon object, `PLAYER_LOGIN` bootstrap, central event dispatcher, module registry.

**1.2 — `Core/Compat.lua`.** Every capability flag and accessor from Phase 0's findings. Written once, from facts.

**1.3 — `Core/Defaults.lua` + AceDB.** Full profile schema for all v1.0 settings, even ones not yet implemented — adding keys later is free, restructuring the tree later is not.

**1.4 — `Core/CombatQueue.lua`.** `Queue(fn)` executes immediately outside combat, defers to `PLAYER_REGEN_ENABLED` inside it. De-duplicate queued operations by key so a slider dragged 200 times in combat queues one apply, not 200.

**1.5 — `Units/Factory.lua`.** Secure button creation, attributes, `RegisterForClicks`, `RegisterUnitWatch`, `ClickCastFrames` registration, per-unit `RegisterUnitEvent` tables.

**1.6 — `Elements/HealthBar.lua`.** StatusBar, background, correct min/max handling, `UNIT_HEALTH` / `UNIT_MAXHEALTH`, dead/ghost/offline states. Single static colour for now.

**1.7 — `Elements/PowerBar.lua`.** Same, driven by `UnitPowerType`, handling `UNIT_DISPLAYPOWER` transitions.

**1.8 — Hide the Blizzard frames** via `Compat.HideBlizzardFrame`, using whichever approach Phase 0 identified as safest, with the "leave them alone" option present from day one.

### Gate
Player and target frames appear at hardcoded positions, show correct health and power on both clients, are click-targetable and right-clickable for the unit menu, survive `/reload`, and produce zero errors across a 30-minute play session including combat, death, and resurrection.

---

## 5. Phase 2 — Layout, configuration UI, and party frames

**Goal:** the "easy editing" requirement complete, and the full v1.0 unit roster in place. After this phase the addon is genuinely usable day-to-day.

**Why party frames belong here rather than at the end:** the element system is data-driven per unit. Register the party units *before* building text, colour rules, auras, and portraits, and all of those phases cover party frames automatically at no extra cost. Add the units last instead, and each element needs a retrofit pass. This single ordering choice is worth several hours.

### Tasks

**2.1 — `Systems/Anchoring.lua`.** Anchor graph, topological apply order, cycle detection with a clear rejection message.

**2.2 — `Config/Options.lua` tree.** AceConfig root, `/duf` opens it, per-unit sub-trees.

**2.3 — Position and size controls.** `range` controls with `softMin`/`softMax` so the slider is bounded but typed values are not. Verify the numeric entry box appears and round-trips correctly — this is the literal requirement and it is worth confirming with your own eyes early rather than assuming AceConfig behaves as documented.

**2.4 — Live apply.** Every control writes to the DB and calls the element's `ApplyLayout` through `CombatQueue`. Sliders must feel live out of combat.

**2.5 — `Config/DragMode.lua`.** `/duf move` unlocks frames, shows a labelled overlay per frame, supports drag with optional grid snap and arrow-key nudge, and writes results back to the same `x`/`y` values the sliders use. One source of truth.

**2.6 — In-combat notice.** Non-blocking banner in the options panel when changes are queued.

**2.7 — Global apply.** "Copy settings from unit → unit" and a multi-select apply, so setting seven frames to height 50 is two actions rather than seven. This was SUF's best usability feature and it is cheap to replicate — and with party frames in scope it earns its keep immediately.

**2.8 — Party unit registration.** `party1`–`party4` and `partypet1`–`partypet4` as static secure buttons through the existing `Units/Factory.lua` (see `SPEC.md` §5.4). No group header, no `initialConfigFunction`, no new frame system. Party pets ship disabled by default.

**2.9 — `Units/PartyGroup.lua`.** Group-level layout: one anchor, growth direction, and spacing that positions all four frames, sitting on top of the same per-frame `x`/`y` values the sliders and drag mode write to. Individual frames remain detachable.

**2.10 — Group visibility and roster handling.** `RegisterUnitWatch` for show/hide. `GROUP_ROSTER_UPDATE` handling routed through `CombatQueue` — this event fires mid-combat and is the most likely source of a protected-action error in the whole project (risk R12). Options: hide-in-raid (default on), show-when-solo (default off).

**2.11 — Derived units: `targettarget`, and on TBC `focus` and `focustarget`.** Ordinary secure buttons from the same factory. Identity updates from `UNIT_TARGET`, `PLAYER_TARGET_CHANGED`, and `PLAYER_FOCUS_CHANGED`.

**2.12 — `Units/DerivedPoller.lua`.** One shared ticker for all derived frames, not one per frame. Starts when the first derived frame becomes visible, stops when the last hides. Default 0.25 s, user range 0.1–1.0 s. Write the start/stop logic first and the update logic second — an idle ticker that never stops is the failure mode here (risk R13).

**2.13 — Focus gating.** `Compat.hasFocus` decides whether focus and focus-target frames are created *and* whether their config subtrees are built at all. On Classic Era the options must be absent, not present-and-broken. Test this by running the identical build on both clients.

**2.14 — Derived-unit defaults.** Ship them text-light (name plus health percent) with auras off. The latency is real and the defaults should not pretend otherwise; everything stays configurable for anyone who wants more.

### Gate
Acceptance criteria 1–4, 10, 13, 14, and 15 in `SPEC.md` §9. A frame can be positioned three ways (slider, typed value, drag) with identical results. Changing size in combat shows the notice and applies on combat exit with no error.

**Explicitly test:** join a group mid-combat, leave a group mid-combat, convert party to raid — none may error. Run the identical build on Classic Era and confirm the focus and focus-target frames and options are entirely absent. Confirm via `/duf profile` that the derived poller is stopped while standing in a city with no target.

---

## 6. Phase 3 — Bar colouring, shapeshift mana, and portraits

**Goal:** three independent visual requirements. None depends on the others, so any can slip alone.

### Tasks

**3.1 — `Systems/Colors.lua`.** Class colour resolution with `CUSTOM_CLASS_COLORS` preference, reaction colours, power-type colours, difficulty colours. `UnitIsPlayer` guard on class colouring.

**3.2 — Health bar colour modes.** `static` (green default) / `class` / `reaction` / `gradient`, configured independently per unit.

**3.3 — Power bar colours** with per-type user overrides.

**3.4 — `Elements/ShapeshiftMana.lua`.** The generic predicate from `SPEC.md` §FR-2.1 — not a druid class check. Show/hide on `UPDATE_SHAPESHIFT_FORM` and `UNIT_DISPLAYPOWER`, update on power events, with the fallback ticker enabled or not depending on what Phase 0 task 0.2 found.

**3.5 — Layout modes for the mana bar** (reserve space vs. append), so appearing and disappearing does not shove the rest of the frame around unexpectedly.

**3.6 — Bar textures** via LibSharedMedia.

**3.7 — `Elements/Portrait.lua`, 2D mode.** `SetPortraitTexture`, question-mark fallback, refresh on `UNIT_PORTRAIT_UPDATE` and unit change. Shared settings: size, anchor, alpha, inside/outside placement. Roughly an hour; do this first and confirm it is solid before touching 3D.

**3.8 — 3D mode.** `PlayerModel` + `SetUnit`, camera distance and Y-offset. Every failure mode in `SPEC.md` §FR-7.4 handled explicitly: re-`SetUnit` on unit change rather than trusting the widget, camera re-applied on `PLAYER_ENTERING_WORLD`, GUID check to skip redundant calls, automatic silent fallback to 2D when a model fails to load.

**3.9 — Portrait config**, including the plain note in the UI that 2D is the more robust option. The choice is the user's; the guidance is honest.

> **Timebox on 3.8:** if 3D portraits consume more than four hours, ship `none` and `2d`, and move `3d` to the v1.x backlog. It is the only cosmetic-only feature in v1.0 and the only one with a high-likelihood risk entry (R11) against it. Nothing else depends on it.

### Gate
Acceptance criteria 5, 8, and 12. Specifically: shift Bear → Cat → caster repeatedly while spending mana and confirm the bar's values track reality, the bar appears and disappears cleanly, and no layout artefacts persist. For portraits: cycle targets rapidly, take a loading screen, and target a unit at maximum range — the 3D portrait must never show a stale model or error.

---

## 7. Phase 4 — Text and colour-rule engine

**Goal:** the largest and most distinctive feature. Build it in the order below; the parser is worthless without the evaluator and the evaluator is unusable without the config UI, but each is independently testable.

### Tasks

**4.1 — `Systems/Tags.lua`, parser.** Tokenise a format string once into a compiled segment list (literals and tag references). Never re-parse per update. Build the tag → invalidating-events dependency map at the same time.

**4.2 — Tag providers.** Implement the vocabulary in `SPEC.md` §4.3.2. Each provider is a small function returning a value plus a "no data" signal.

**4.3 — Empty-tag collapse.** Adjacent literal separators are dropped when a tag yields nothing. Handle it in the compiled representation, not with string post-processing — post-processing here is where subtle bugs live.

**4.4 — Number formatting.** `:short` abbreviation, configurable decimals, percent handling.

**4.5 — `Systems/ColorRules.lua`.** Ordered evaluation, first match wins, static fallback. Metrics decoupled from the coloured element. Precompile each rule set to avoid per-update table walks.

**4.6 — Difficulty colour mode** wrapping `GetCreatureDifficultyColor`, plus `??` handling and classification suffixes.

**4.7 — Gradient mode** with up to three stops.

**4.8 — `Elements/Text.lua`.** Anchoring, fonts via LibSharedMedia, justification, truncation, and per-element string caching (skip `SetText` when unchanged).

**4.9 — Enemy-health detection** per `SPEC.md` §FR-4.7, plus the explanatory note in the config UI.

**4.10 — `Config/Options_Text.lua`.** The rule editor: add, remove, reorder, enable, duplicate, copy rule set to another element or unit. **Do not underestimate this** — a rule engine with a bad editor is a rule engine nobody uses. Budget roughly a third of this phase here.

**4.11 — Tag reference in-client.** `/duf tags` prints the vocabulary with examples. Cheap, and removes the need to alt-tab to a wiki.

### Gate
Acceptance criteria 6, 7, and 10. Concretely: a rule set that turns current health orange below 35% and red below 500 absolute, both firing correctly; target level colours matching the default UI side by side at −5 through +5 level difference and against a boss; no fabricated enemy health numbers.

---

## 8. Phase 5 — Buffs and debuffs

**Goal:** the last functional requirement. Isolated enough that it can slip without blocking anything else.

### Tasks

**5.1 — `Compat.GetAura`** normalising whichever API Phase 0 found, returning a stable table shape regardless of client.

**5.2 — Aura scanning.** Enumerate until nil; handle the incremental `UNIT_AURA` payload if available, full rescan if not.

**5.3 — Icon pool.** Create and reuse button frames; never create per update. Pool sized to the configured maximum.

**5.4 — `Elements/Auras.lua` layout.** Rows, columns, spacing, growth direction, anchoring to frame or bar or other aura group.

**5.5 — Own-aura differentiation.** Size multiplier and optional border colour (both required by the brief), plus optional desaturation and cooldown-swipe differences for others.

**5.6 — Debuff type borders** via `DebuffTypeColor`, with the precedence choice between type colouring and own-source colouring.

**5.7 — Cooldown spirals and stack counts.** Standard `Cooldown` frames so OmniCC attaches; optional built-in duration text.

**5.8 — Unknown-duration handling.** No swipe, no timer, never a fabricated duration. Optional `LibClassicDurations` detection behind a flag with an "estimated" marker.

**5.9 — Filtering.** Own-only, whitelist, blacklist, minimum duration, hide-permanent.

**5.10 — Sorting.** Own-first, time remaining, alphabetical, index.

**5.11 — Tooltips**, with an in-combat suppression option.

**5.12 — `Config/Options_Auras.lua`.**

**5.13 — Verify party coverage.** Auras on party frames should work with no additional code, since the units were registered in Phase 2. Confirm this rather than assume it — if it needs special-casing, the element system has a design flaw worth finding now.

### Gate
Acceptance criterion 9, verified on a target with a mix of your debuffs and other players' debuffs: yours are larger, bordered as configured, and sorted first. Layout holds as auras are added and removed rapidly.

---

## 9. Phase 6 — Hardening and release

**Goal:** turn a working addon into one that stays working. For a project whose entire premise is "the last one kept breaking," this phase is not optional polish.

### Tasks

**6.1 — `Config/TestMode.lua`.** `/duf test` populates every frame with plausible dummy data — including frames for units that don't currently exist — so layout can be configured while standing in a city with no target. This is the single biggest quality-of-life feature in the whole project.

**6.2 — Circuit breaker.** Per-element error counting, automatic disable after N errors, one chat message naming the element. Verify by deliberately introducing a fault.

**6.3 — `/duf safemode`.** Bars only, no text, no auras. The patch-day escape hatch.

**6.4 — `Core/Migrate.lua`.** Schema versioning, forward-only migration, automatic backup on failure. Test by loading a deliberately-old saved variables file.

**6.5 — Performance pass.** Measure against `SPEC.md` §6 in a 25-man raid. Profile with `/duf profile`. Fix what exceeds budget; document what doesn't.

**6.6 — Full test matrix** (§10 below).

**6.7 — Documentation.** README, a short "getting started" section, the tag reference, and a one-page "what to do when a patch breaks it."

**6.8 — Packaging.** Version tagging and changelog. Distribution is settled as private use (`SPEC.md` §10), so no CurseForge project, packager, or CI. Confirm the `LICENSE` file is present and that every embedded library's license file survived into the final folder.

### Gate
All thirteen acceptance criteria in `SPEC.md` §9, on both clients.

---

## 10. Test matrix

Run in full at the Phase 6 gate; run the shaded subset at every phase gate.

### Clients
Classic Era / Hardcore (1.15.9) **and** TBC Anniversary (2.5.6). Every gate requires both.

### Characters
| Character | Tests |
|---|---|
| Druid | Shapeshift mana bar, form transitions, mana tracking while shifted |
| Warrior or rogue | Rage / energy power bars, `UNIT_DISPLAYPOWER` edge cases |
| Any mana class | Baseline mana behaviour, power text |
| Hunter (if convenient) | Pet frame, pet happiness (Classic/TBC-specific) |

### Situations
- Solo questing: target acquisition and loss, dead targets, unknown-level mobs
- **Derived units:** target a unit that is fighting something else and confirm target-of-target tracks it; target a unit with no target and confirm the frame hides; rapid target switching; confirm the poller stops when nothing derived is visible
- **Focus (TBC only):** set and clear focus, focus a unit in combat, confirm focus-target tracks; then run the same build on Classic Era and confirm focus is entirely absent
- Combat: verify layout changes queue correctly, verify no protected-action errors
- Death, release, resurrection, ghost state
- **Group content:** form a party, leave a party, join mid-combat, leave mid-combat, convert party to raid, party member goes offline / dies / zones out
- **Portraits:** all three modes on player and target; rapid target cycling; loading screen; out-of-range unit; a unit with no portrait
- 25-man raid: performance budget, and confirm party frames hide correctly under the default hide-in-raid option
- Battleground: rapid target switching, many auras
- `/reload` and full client restart: settings persistence
- Zone transitions and loading screens
- Targeting each class of player: verify class colours against the default UI

### Hardcore-specific note
Bugs on a Hardcore character are unusually expensive. Do primary development and first-run testing of anything touching combat behaviour on the TBC character or a low-level throwaway Classic Era character, not on the Hardcore main. Promote to the Hardcore character only after a phase gate has passed.

---

## 11. Patch-day playbook

Given that patch 1.15.9 and 2.5.6 landed with essentially no notice to addon authors, assume this happens again. The point of the architecture is that the response is a checklist, not a project.

1. **Before logging in**, check the Warcraft Wiki `Patch X/API changes` page and the WoW UI Dev Discord for the new TOC number and any listed removals.
2. **Bump the TOC** interface version. Often this alone is the entire fix.
3. **Log in with `/duf safemode`** if anything looks wrong. Confirm bars work.
4. **Re-run `DyrueUnitFrames_Probe`** (keep it in the repo — it is the diagnostic, not disposable after Phase 0). Diff its output against `COMPAT_FINDINGS.md`.
5. **Fix in `Compat.lua` only.** If a fix requires touching a second file, ask whether the abstraction is in the wrong place before proceeding.
6. **Re-run the phase-gate subset** of the test matrix.
7. **Update `COMPAT_FINDINGS.md`** with the new facts.

Keeping the probe addon and the findings document current is the difference between a 30-minute patch day and a lost weekend.

---

## 12. Dependency and sequencing notes

```
Phase 0 ──┬─> Phase 1 ──> Phase 2 ──┬─> Phase 3 ──┐
          │                          │              ├─> Phase 6
          └─(findings feed all)      ├─> Phase 4 ──┤
                                     └─> Phase 5 ──┘
```

- Phase 2 now completes the entire v1.0 unit roster — solo, party, and derived. Everything built in Phases 3, 4, and 5 therefore covers every frame automatically.
- Phases 3, 4, and 5 depend on 1 and 2 but **not on each other**. If motivation or time runs short, any one can be deferred without blocking the others.
- Phase 5 (auras) is the most deferrable: the addon is fully usable without it, and Blizzard's default target frame can carry aura duty in the interim.
- Phase 4 (text engine) is on the critical path for perceived quality. If something must be cut for time, cut the *gradient* mode and the copy-rules-between-units convenience, not the rule engine itself.

---

## 13. Definition of done for v1.0

- All thirteen acceptance criteria in `SPEC.md` §9 pass on both clients.
- No known errors in the test matrix.
- Performance within budget.
- `COMPAT_FINDINGS.md` current.
- README and tag reference written.
- Tagged release in git, with the probe addon retained in the repo.

---

## 14. v1.x backlog

Roughly in order of expected value:

1. Focus frame (TBC only)
2. Player cast bar — deliberately deferred; shares no systems with anything else, so it costs the same later as now
3. Profile import/export strings
4. Aura filter presets (dispellable-only, crowd-control-only)
5. Range fading
6. Out-of-combat frame fading
7. Aura indicator squares on frames
8. Party target and party target-of-target frames
9. `pettarget` and `targettargettarget` — once the derived-unit machinery from Phase 2 exists, these are the same code path with a different token and cost close to nothing. Left out of v1.0 only because they were not asked for
10. 3D portraits, **if** timeboxed out of Phase 3
11. Raid frames — **not planned.** Would require a secure group header, which the party-frame design (`SPEC.md` §5.4) deliberately avoids. Reconsider only if Blizzard's post-2.5.6 raid frames prove genuinely unworkable, and treat it as a separate project rather than a v1.x item

---

## 15. Decisions log

All resolved as of 2 August 2026. Full reasoning in `SPEC.md` §10.

| Decision | Outcome |
|---|---|
| Addon name | `DyrueUnitFrames`, slash command `/duf` |
| Party frames | **In v1.0**, static secure buttons, added in Phase 2 so later phases cover them free |
| Party pets | In v1.0, default disabled |
| Target-of-target | **In v1.0**, both clients; derived unit requiring the shared poller |
| Focus and focus-target | **In v1.0, TBC only.** Focus promoted from v1.1 because focus-target requires it |
| Raid frames | **Out**, not planned |
| Player cast bar | Out of v1.0, backlog item 2 |
| Portraits | All three modes; 3D timeboxed at four hours |
| Licensing | MIT, `LICENSE` file created in Phase 0 |
| Distribution | Private for now; two Phase 0 hedges keep publication possible |
| Test druid | Available; primary testing on TBC Anniversary, not Hardcore |

**Phase 0 can begin immediately.** Nothing is blocked.
