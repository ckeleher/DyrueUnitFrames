# Dyrue Unit Frames

Vibe-coded unit frames for **WoW Classic Era / Hardcore (1.15.9)** and **TBC Anniversary
(2.5.6)**. One codebase, both clients.

Built from primitives — `CreateFrame`, `StatusBar`, `FontString`, `Texture` —
and nothing else. Every point of contact with Blizzard's own UI lives in a
single file, `Core/Compat.lua`, so when the next shared-code patch lands the
blast radius is one file you can read in a sitting. That containment is the
whole point of the project; see `Documents/SPEC.md` §1.2.

> **Status: written and unit-tested, not yet play-tested.** The code is complete
> against `SPEC.md` v1.0 and passes ~270 headless assertions in a real Lua 5.1
> interpreter (see `Tests/`), including a Classic-Era pass and a legacy-aura-API
> pass. It has still never been run on a live client. Read
> `Documents/COMPAT_FINDINGS.md` before trusting any of it, and expect the first
> session to turn up things only a real client can tell you.

---

## Install

Copy the repository into your AddOns folder as `DyrueUnitFrames`, or let the
script do it:

```bash
powershell -ExecutionPolicy Bypass -File Tools/sync.ps1
```

`-Watch` re-copies on every save. `-Link` uses directory junctions so `/reload`
picks up edits with no copy step.

The diagnostic addon in `Probe/DyrueUnitFrames_Probe` is copied too. Install it
at least once — it answers the Phase 0 questions and it is the first thing to
reach for on patch day.

Libraries (Ace3, LibSharedMedia) are embedded and version-pinned under `Libs/`.
Nothing needs to be installed separately.

---

## First run

Blizzard's own unit frames are **hidden by default**, party frames included.

If you would rather manage them through Edit Mode — which these clients have,
and which is lower risk because it involves no addon reaching into Blizzard's
UI at all — run `/duf blizzard none` and hide them there instead.

Then `/duf` to open the options, or `/duf test` to show every frame with
stand-in data so you can lay everything out while standing in a city.

---

## Commands

| Command | Does |
|---|---|
| `/duf` | Open the options |
| `/duf move` | Drag mode: drag to move, click to select then arrow keys to nudge (Shift = larger step), Escape to finish |
| `/duf test` | Show every frame with stand-in data, including units that do not exist |
| `/duf tags` | Print the tag vocabulary |
| `/duf blizzard hide` \| `none` | Hide or restore Blizzard's unit frames |
| `/duf safemode` | Bars only, no text, no auras — survives `/reload` |
| `/duf profile` | Memory, CPU, and whether each of the four tickers is actually idle |
| `/duf compat` | What this client supports, as probed |
| `/duf errors` | Anything that has tripped the circuit breaker this session |
| `/duf reset <unit>` | Reset one unit to defaults |
| `/duf debug` | Verbose logging |

---

## Units

`player`, `target`, `targettarget`, `pet`, `party1-4`, `partypet1-4` on both
clients; `focus` and `focustarget` additionally on TBC.

Party pets ship **disabled**. Focus frames are not created at all on Classic
Era and their options are absent rather than present-and-broken — the gate is a
capability probe (`Compat.hasFocus`), not a TOC comparison, so a backported
feature would just work.

Raid frames are **not planned**. See `SPEC.md` §5.4 for why that boundary is
where it is.

---

## State indicators

A small row of markers for unit state, anchored to whichever bar you point it
at. Only the states currently **active** take a slot, so a lone marker always
sits at the start of the row rather than leaving a gap where the others would
be. Size, spacing, growth direction, opacity and a per-state tint are all
settings, and `Style: solid square` is there for the day a Blizzard patch moves
the artwork.

Ships on for the **player** (resting, in combat) and for the **pet**
(happiness).

The two ship in different places, on purpose. The player's row sits **on the
health bar**, raised to clear the name text. The pet's sits **just outside the
frame's right edge** and grows away from it: a 150×32 pet frame is already full
of name and health text, and anchoring to the frame rather than to a bar means
the row cannot disappear because you turned the health bar off.

**Hunter pet happiness** is three separate states — happy, content, unhappy —
rather than one. They are mutually exclusive, so happiness still spends exactly
one slot; what the split buys is a switch per level. Turning *happy* off and
leaving the other two on means **you are only marked when something is wrong**.

It appears only where it can mean something. On a warlock's voidwalker there is
no happiness, and nothing is shown — the check is `HasPetUI`'s hunter-pet
return, the same one Blizzard's own pet frame uses. There is no happiness
readout for other people's pets, and cannot be: `GetPetHappiness` takes no unit
argument and only ever answers about your own. On a client without the mechanic
at all, the states and their options are simply absent.

The same information is available as text, if you would rather have a word than
a face — see the `[happiness]` tag below.

---

## Positioning

Three ways in, one stored value:

- **Sliders and typed values.** Every position and size control is a slider
  *and* an exact numeric entry box writing to the same number. The slider is
  bounded; typed values can go beyond it.
- **Drag mode.** `/duf move`. Optional grid snap.
- **Arrow keys.** Click a frame in drag mode, then nudge.

Frames anchor to the screen or to each other, and moving a parent moves its
children. Anchor loops are detected and rejected with a message naming the loop.

**In combat**, position, size, scale and visibility are protected operations.
Changes are written to the database immediately, so the options panel reflects
what you asked for, and the visual application is queued until you leave combat.
A notice says so. Nothing errors and nothing is silently dropped.

---

## Tags

Format strings are declarative tokens in square brackets, mixed with any
literal text. There is no Lua, no `loadstring`, and no eval.

**Identity** — `[name]` `[name:short:N]` `[name:abbrev]` `[class]` `[race]`
`[guild]` `[level]` `[classification]` `[shortclassification]`

**Health** — `[hp:cur]` `[hp:max]` `[hp:perc]` `[hp:deficit]`, with `:short` on
the absolute ones (`[hp:cur:short]` → `1.2k`)

**Power** — `[pp:cur]` `[pp:max]` `[pp:perc]` `[pp:deficit]` `[pp:type]`

**True mana**, regardless of displayed power type — `[mana:cur]` `[mana:max]`
`[mana:perc]`

**Status** — `[status]` `[afk]` `[dnd]` `[pvp]` `[leader]` `[raidtarget]`
`[happiness]` (hunter pet only, and empty on anything else)

### Empty-tag collapse

A tag that resolves to nothing takes its adjacent separators with it. So

```
[hp:cur:short] / [hp:max:short] [hp:perc]%
```

renders as `18.2k / 21.5k 85%` on yourself and as just `85%` on an enemy, whose
absolute health the client does not actually report. No stray `" / "`.

---

## Color rules

Any text element can be colored by an **ordered rule list**. First match wins;
if nothing matches, the element's static color applies.

The thing being *tested* is independent of the thing being *colored*, so
"turn the unit's name red below 20% health" is an ordinary rule rather than a
special case.

Metrics: `health.current` `health.max` `health.percent` `health.deficit`
`power.current` `power.percent` `power.deficit` `mana.current` `mana.percent`
`level.value` `level.difference` `unit.isDead` `unit.isOffline` `unit.isPlayer`
`unit.reaction`. Operators: `<` `<=` `>` `>=` `==` `~=`.

Rules can be added, removed, reordered, duplicated, disabled, and copied
wholesale from any other text element on any other unit.

Level text defaults to `difficulty` coloring, which calls the game's own
`GetCreatureDifficultyColor`. That is not a reimplementation of the thresholds —
it *is* the base game's function, so the colors match the default UI exactly
and stay matched if Blizzard ever adjusts them.

---

## Things Classic genuinely cannot do

Not bugs. The addon handles each one by showing nothing rather than showing
something false.

**Enemy health is a percentage.** For anything outside your group the client
reports health on a 0–100 scale. `[hp:cur]`, `[hp:max]` and `[hp:deficit]`
therefore render as empty on those units (and their separators collapse);
`[hp:perc]` is always accurate. Showing "100/100" for a full-health raid boss is
worse than showing nothing.

**Other people's aura durations are unavailable.** Classic reports duration and
expiry only for auras *you* applied. Everyone else's get no swipe and no timer
rather than a fabricated one. If you install
[LibClassicDurations](https://github.com/rgd87/LibClassicDurations) the addon
will detect it and use its estimates, marked as estimated in the tooltip. It is
deliberately not bundled — fewer dependencies, fewer patch-day failure modes.

**Target-of-target and focus-target lag slightly.** Those units do not receive
reliable unit events, so their values are sampled by a shared 0.25s ticker
(configurable 0.1–1.0s). Their *identity* is event-driven and instant. They ship
text-light with auras off because the defaults should not pretend the latency
is not there. The ticker stops entirely when no derived frame is visible —
`/duf profile` will tell you whether it actually did.

**Cast bars for other units** do not exist in Classic, and the player cast bar
is deferred to v1.x. Blizzard's own cast bar covers the gap.

---

## Interoperability

- **Clique** — frames register themselves in `ClickCastFrames`.
- **OmniCC** — aura cooldowns are standard `Cooldown` frames, so it attaches
  automatically.
- **Edit Mode** — DyrueUnitFrames frames are not Edit Mode participants. They
  simply exist alongside it and do not fight it.
- **Other unit frame addons** — no attempt at coexistence. Disable them.

---

## When something breaks

A broken element **disables itself** after five errors, prints one line naming
itself, and everything else keeps working. `/duf errors` lists what tripped;
`/reload` clears it. There is no path here that produces an infinitely
increasing stream of Lua errors.

### Patch day

1. Before logging in, check the Warcraft Wiki `Patch X/API changes` page for the
   new TOC number and any removals.
2. Bump `## Interface:` in `DyrueUnitFrames.toc`. This alone is often the whole
   fix.
3. If anything looks wrong, `/duf safemode` then `/reload`. Confirm bars work.
4. Re-run `/dufprobe` and diff against `Documents/COMPAT_FINDINGS.md`.
5. **Fix in `Core/Compat.lua` only.** If a fix needs a second file, ask whether
   the abstraction is in the wrong place before proceeding.
6. Run `python Tests/run_tests.py` — thirty seconds, no client needed — then the
   phase-gate subset of the test matrix in `Documents/PLAN.md` §10.
7. Update `COMPAT_FINDINGS.md`.

---

## Layout

```
Core/       Compat (the containment file), Defaults, Migrate, CombatQueue, Errors, Core
Systems/    Colors, Tags, ColorRules, Anchoring, BarSweep
Elements/   HealthBar, PowerBar, ShapeshiftMana, ComboPoints, Portrait, Text, Auras,
            Indicators, Highlight
Units/      Registry, Factory, PartyGroup, DerivedPoller
Config/     Options, Options_Layout, Options_Text, Options_Auras, DragMode, TestMode
Libs/       Ace3, LibSharedMedia — embedded, version-pinned, never modified in place
Probe/      DyrueUnitFrames_Probe, the diagnostic addon
Documents/  SPEC.md, PLAN.md, COMPAT_FINDINGS.md
```

Two structural notes worth knowing before reading the code:

**The protected/unprotected split.** Each frame is a `SecureUnitButtonTemplate`
button whose size, position, scale, attributes and visibility are forbidden in
combat and therefore go through `Core/CombatQueue.lua`, always. Everything
visual lives in `frame.content`, an ordinary unprotected child, and can be
re-laid-out freely mid-fight. That is why a druid shifting form in combat gets a
mana bar immediately rather than at `PLAYER_REGEN_ENABLED`.

**Elements are unit-agnostic data.** Nothing in `Elements/` knows what a party
frame is. Register a unit in `Units/Registry.lua` and every element, color
rule, aura group and config control covers it for free.

---

## License

MIT — see `LICENSE`. The embedded libraries keep their own terms; see
`Libs/LICENSE.md`.

This is a clean-room implementation. Shadowed Unit Frames is All Rights
Reserved; its behavior and UX ideas were referenced, its source was not read
while writing the corresponding code.
