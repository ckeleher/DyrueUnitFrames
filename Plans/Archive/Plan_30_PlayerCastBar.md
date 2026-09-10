# Plan 30 — Player Cast Bar

**Status:** Implemented on `Plan-30-player-cast-bar`, merged in PR #24 on
9 September 2026. See Outcome at the end — two things in this plan were wrong.
**Created:** 1 September 2026
**Branch:** `Plan-30-player-cast-bar`
**Depends on:** nothing. Branch from `main`.

---

## Request

> i understand that, per prior docs, player and target cast bars are out of scope. I want you to estimate how difficult it would be to add support for those, as independently movable frames which are by default attached to the player and target frames. consider the difficulty of adding cast bars for other frame types (party, focus, etc) as well

**This plan covers the first quarter of it:** a working player cast bar, as a
registered element inside the player frame. It does **not** make the bar
independently movable — that is Plan 31, and it is the expensive half. It does
not touch any unit other than the player — Plans 32 and 33.

---

## Interpretation

The request asks for movable frames. This plan deliberately does not deliver
that, and the sequencing is the point rather than a shortcut:

`Elements/CastBar.lua` is **identical either way**. An element receives
`frame.content`, `frame.cfg[configKey]` and `frame.unit`, and calls
`ns:Level(frame, "BARS")`. Nothing in the element contract can observe whether
its host frame is a secure button or a plain frame. So the bar written here is
the bar Plan 31 detaches, unmodified, and building it first puts something on
screen before Plan 31 edits `Units/Factory.lua` — the file all twelve existing
frames come out of.

The premise in the request — that this is out of scope — is half right and
worth correcting in passing. `SPEC.md` §2.3 lists **"Player cast bar"** under
*deferred to v1.x, designed for, not built*, and `PLAN.md` §14 makes it backlog
item 2 with the note "shares no systems with anything else, so it costs the same
later as now". Only the *other* units are a stated non-goal (`SPEC.md` §2.2),
and that exclusion is separately wrong — see Plan 32.

---

## Design

### 1. `Compat.GetCastInfo(unit)` — one new function

`Core/Compat.lua:308` already has `GetCastEndTime(unit)`, which pcalls
`UnitCastingInfo` then `UnitChannelInfo` and returns `endTime / 1000, isChannel`.
It is verified present on both clients (`COMPAT_FINDINGS.md:84`, "Present,
milliseconds") and its comment records that it is "only ever called for
`player`".

Widen it rather than duplicate it. `GetCastInfo(unit)` returns
`name, icon, startTime, endTime, isChannel, notInterruptible` with the same
pcall-per-API discipline, and `GetCastEndTime` becomes a thin caller of it so
`Systems/HealPrediction`'s existing use is untouched.

Both APIs are read through `Core/Compat.lua` and nowhere else, per `SPEC.md`
§5.5. No other file learns their names.

**Measured 1 September 2026 — `/dufprobe cast`, five runs, both clients.**
Full findings in `COMPAT_FINDINGS.md`; the two that constrain this function:

> The two readers **diverge after position 6**. `UnitCastingInfo` has `castID`
> at 7, so `notInterruptible` is 8 and `spellID` 9. `UnitChannelInfo` has **no
> `castID` at all** — `notInterruptible` is 7 and `spellID` 8.

Positions 1–6 are identical, which is why `GetCastEndTime` reading 1 and 5 is
correct for both *by accident*. `GetCastInfo` reads the icon and would read past
6, so it **must unpack per-function, not once**. A single positional unpacker
returns a spell ID where an interrupt flag belongs, silently, and only for
channels.

Also: **`notInterruptible` reads `nil`, not `false`** on both clients and from
both functions — return it as a tri-state rather than coercing to a boolean.
And Classic Era's signatures are **identical** to Anniversary's, so there is no
per-client branch to write, only a per-function one.

### 2. `Elements/CastBar.lua`

Follows the element contract exactly — `order`, `configKey`, `events`,
`IsEnabled`, `Build`, `Layout`, `SetGeometry`, `Update`, `Disable`, then
`ns:RegisterElement("cast", element)`. `Elements/ShapeshiftMana.lua` is the
closest existing model: a bar that appears and disappears on its own schedule.

Widgets built: `bar` (StatusBar) + `bg` + `icon` (Texture) + `spellText` +
`timeText` (both via `ns:NewFontString`). Colors resolve through
`Systems/Colors` exactly as the power bar does, including
`Colors:Background(r, g, b, bgMultiplier, bgAlpha)`.

Every event is `UNIT_`-prefixed, so `Factory:RegisterEvents`
(`Units/Factory.lua:427`) filters them per-unit through `RegisterUnitEvent` for
free and no dispatch code changes:

```
UNIT_SPELLCAST_START            UNIT_SPELLCAST_CHANNEL_START
UNIT_SPELLCAST_STOP             UNIT_SPELLCAST_CHANNEL_UPDATE
UNIT_SPELLCAST_DELAYED          UNIT_SPELLCAST_CHANNEL_STOP
UNIT_SPELLCAST_INTERRUPTED
UNIT_SPELLCAST_FAILED
```

Register each through `Compat.HasEvent` (`Core/Compat.lua:60`), which already
skips anything invalid rather than erroring. All twelve — the nine above plus
`SENT`, `INTERRUPTIBLE` and `NOT_INTERRUPTIBLE` — are **measured valid on both
clients**; the gate costs nothing and is what stops a future client difference
becoming a load error.

**Channels drain rather than fill.** `UnitChannelInfo` reports the same
start/end pair but the bar must run the other way.

### 2a. Four measured behaviors the obvious implementation gets wrong

All from the 1 September runs, all reproduced on both clients. Each one is a
bug this plan would otherwise have shipped.

**`SUCCEEDED` fires at a channel's START, not its end.** Tranquility raised
`CHANNEL_START` and `SUCCEEDED` at the *same timestamp*, with `CHANNEL_STOP`
arriving when the channel actually ended. So `SUCCEEDED` may only clear the bar
when no channel is running — clearing on it unconditionally blanks every channel
the instant it begins. This is the sharpest edge in the data.

**`INTERRUPTED` fires four times per interrupt, and does not order stably
against `STOP`.** Era put `INTERRUPTED` first in all five of its interrupts;
one Anniversary run put `STOP` first. The bar must be **idempotent about
ending** — a repeat is not a new event, and neither event may assume it is the
first to arrive.

**Clipping a channel produces `CHANNEL_STOP`, not `CHANNEL_UPDATE`.**
`_CHANNEL_UPDATE` is valid on both clients but **never fired in five runs**.
Its remaining candidate trigger is channel pushback, unobserved. So it is still
wired to the re-read path alongside `_DELAYED` — that is the right handling
whatever raises it — but the plan must not claim it is the clipping signal,
because clipping was measured and it is not.

**A spell's cast time does not decide whether it is instant.** A Regrowth came
through as an instant, presumably under Nature's Swiftness. Instants raise no
`_START` at all, so the bar shows nothing for them and needs no suppression —
but the detection is "no start event", never a spell-ID check.

One more, small and easy to trip on: **`UnitChannelInfo` position 2 is the
literal string `"Channeling"`**, not the spell name. Read position 1.

### 3. The driver — one hidden frame, shared, refcounted

A cast bar's fill has to move between events, so something must run per frame.

`SPEC.md` §5.7 keeps a closed list of three tickers and says a fourth "should be
treated as a design smell and argued for explicitly". `Systems/BarSweep.lua`
already spent that argument and became the fourth. **This is not a fifth**, and
the distinction is real rather than a lawyer's one:

- It is not a poller. Nothing is being sampled because no event exists; the
  start and end times are known exactly, from an event, before the first frame
  is drawn. The driver interpolates between two known numbers.
- `BarSweep.lua:353-375` establishes the mechanism: a hidden frame whose
  `OnUpdate` is set once, where **Show/Hide is the entire start/stop** and there
  is no timer object to leak. A hidden frame's `OnUpdate` does not run. With no
  cast in progress the cost is exactly zero, with nothing to verify or trust.
- One driver serves every cast bar, started by the first bar becoming active and
  stopped by the last one finishing — the same rule `Units/DerivedPoller.lua`
  applies under §FR-8.3, and the reason Plans 32 and 33 add no driver cost at
  all.

Put the driver **in `Elements/CastBar.lua`**, copying BarSweep's pattern rather
than extracting a shared one. BarSweep's `Render` is line-geometry specific and
a shared abstraction over the two would amount to a shared `Show`/`Hide` and
nothing else. Revisit if a third consumer ever appears.

`ns:ProfileReport` (`Core/Core.lua:581`) gains a line reporting whether the
driver is running and how many bars are attached, matching how BarSweep and the
aura ticker already report. An idle driver that claims to be idle and can be
checked is the whole basis of the §5.7 argument.

### 4. Text: owned by the element, not the tag system

Tempting to route the spell name and timer through `Elements/Text.lua` and
`Systems/Tags.lua` and get Plan 6's width modes and the whole of
`Config/Options_Text.lua` for free. Half of it works and half of it cannot:

- A `[cast:name]` tag is well-behaved — it changes on an event, which is exactly
  what the tag dependency map in §5.7 is built around.
- A `[cast:time]` tag is not. It changes **every frame**, and the tag system's
  central optimization is caching the rendered string per element and skipping
  `SetText` when unchanged. A tag that never matches its cache defeats that
  mechanism for every other tag on the frame.

So the element owns two font strings and writes to them directly. Two
mechanisms for one row of text would be worse than one slightly less
configurable mechanism, so the name goes through the element too. Config reuses
the `Defaults.Text` shape (`Core/Defaults.lua:116`) minus `format`, so the font
and color controls read the same as everywhere else.

`[cast:name]` as a tag is a deliberate non-goal here. It can be added later
without invalidating any of this.

### 5. Hide Blizzard's cast bar

`Compat.blizzardFrames` (`Core/Compat.lua:681`) has no casting-bar entry.
Measured 1 September: `PlayerCastingBarFrame` is present on **both** clients as
an **unprotected `StatusBar`**, and `CastingBarFrame` is absent on both.

Add `playercast = { "PlayerCastingBarFrame", "CastingBarFrame" }` — both names,
since `HideBlizzardFrame` resolves lazily and skips what does not exist. Keyed
under its own name rather than appended to `player`, so Plan 31 can move it with
the frame it belongs to.

**Watch Era specifically.** The parents differ, and `HideBlizzardFrame`
reparents to `hiddenHolder`:

| Client | Parent |
|---|---|
| TBC Anniversary | `UIParent` |
| Classic Era | `UIParentBottomManagedFrameContainer` |

Era's is a managed container that lays out its children and may react to one
being reparented out of it. The frame is unprotected so the hide is expected to
work, but this is the one place in this plan to check the result on Era rather
than assume it — and it is the reason the bar earns its own `blizzardFrames`
key instead of being folded in with `PlayerFrame`.

Ship without this and every user gets two cast bars.

---

## Files

| File | Change |
|---|---|
| `Core/Compat.lua` | `GetCastInfo(unit)`; `GetCastEndTime` becomes a caller of it. `blizzardFrames.playercast` entry |
| `Elements/CastBar.lua` | **New.** The element plus the shared driver |
| `Core/Defaults.lua` | `cast` block in `unit()`, off by default everywhere; on for `player` in `buildUnits()`. `SCHEMA_VERSION` 17 → 18 |
| `Config/Options_Layout.lua` | `castGroup(def)`, and a `cast` entry in `Options.BuildUnit`'s args, hidden for units where it is not offered |
| `Core/Core.lua` | `ns:ProfileReport` reports the driver; `castbar` added to `ns:AnchorWidgetValues` and the `ns:AnchorWidget` branch so text elements can anchor to the bar |
| `Core/Locale.lua` | Strings |
| `DyrueUnitFrames.toc` | `Elements\CastBar.lua`, after `ShapeshiftMana.lua` |
| `Tests/tests.lua`, `Tests/wowstub.lua` | Below |

---

## Schema and migration

**Purely additive**, therefore free. `cast` is a new key that no profile has, so
`Defaults:EnsureProfile` (`Core/Defaults.lua:818`) deep-fills it on next login
and `Core/Migrate.lua` needs **no step**. Bump `SCHEMA_VERSION` to 18 anyway and
record in the header comment what 18 was for, following the existing convention.

One thing to get right: the default must be `enabled = false` in the `unit()`
template and `enabled = true` only in `buildUnits()`'s `u.player`. The template
is what every *other* unit inherits and what `EnsureProfile` fills unknown keys
from, so a template default of `true` would silently switch cast bars on for all
twelve frames — before Plans 32 and 33 have established that they work.

---

## Tests

`Tests/wowstub.lua` needs `UnitCastingInfo` / `UnitChannelInfo` returning the
full tuple with **millisecond** times, and a way to drive them from a test.
Stub them at their **real measured widths and orders** — eleven returns each,
with `castID` present in one and absent from the other. A stub that returns a
tidied-up shared tuple cannot catch the divergence bug, which is the single most
likely defect in this plan.

Assertions:

- `Compat.GetCastInfo` converts ms → s and returns nil cleanly for no cast;
  `GetCastEndTime` still returns what it returned before (regression guard on
  `HealPrediction`'s existing caller).
- **`GetCastInfo` returns the right `spellID` and `notInterruptible` for a
  channel**, i.e. it unpacks per-function. Feed it the two real tuples from
  `COMPAT_FINDINGS.md` and assert the channel does not report its spell ID as an
  interrupt flag.
- `notInterruptible` survives as `nil` rather than being coerced to `false`.
- Channel path returns `isChannel = true` and the bar fills in the opposite
  direction, and the label reads the **spell name**, not `"Channeling"`.
- `_DELAYED` and `_CHANNEL_UPDATE` re-read the times rather than restarting the
  bar.
- The bar hides on `_STOP` / `_INTERRUPTED` / `_FAILED`.

The four measured behaviors from §2a, each asserted directly — these are
regression tests for bugs the measurement caught before they were written:

- **`SUCCEEDED` during a channel does not clear the bar**, and `SUCCEEDED` with
  no channel running does.
- **Four `INTERRUPTED` events plus a `STOP` leave the bar hidden and stable**,
  asserted in *both* orders — `INTERRUPTED` first and `STOP` first — since the
  observed order differs between clients.
- A `SUCCEEDED` with no preceding `_START` shows no bar at all (instants).
- A `CHANNEL_STOP` with no `CHANNEL_UPDATE` before it ends the channel cleanly.
- **The driver is stopped when no bar is casting** — this is the §5.7 claim and
  it is the assertion that actually matters. Also: it stops when the only
  casting bar's frame is hidden.
- The element registers only events `Compat.HasEvent` accepts.
- Nothing is attached when `cast.enabled` is false, and `Disable` detaches.

**Gap this exposes:** there is no existing test that a driver-style OnUpdate
consumer idles to zero — BarSweep has `ActiveCount` but the suite checks
attachment rather than the driver's own running state. Add one for BarSweep
while writing the cast bar's, since the assertion is now needed twice.

---

## Risks

| Risk | Handling |
|---|---|
| The §5.7 ticker rule is breached by a fifth animation source | It is a hidden-frame `OnUpdate`, not a ticker, and one driver serves all future cast bars. The argument is written above; record it in `Documents/COMPAT_FINDINGS.md` on implementation, as `NewWork` requires for a SPEC deviation |
| Timer text defeats the string cache | Avoided by design — the timer never enters the tag system. Assert that `Systems/Tags` gains no cast tag |
| A `cast` default of `true` in the `unit()` template switches on eleven untested bars | Covered above; assert the shipped default per unit in tests |
| `PlayerCastingBarFrame` is protected and cannot be hidden in combat | `HideBlizzardFrame` (`Compat.lua:696`) already returns false rather than erroring in that case, and `Core/Core.lua:394` already retries the hide on entering world |

---

## Estimate

**Small — one focused sitting.** Comparable to `Elements/ComboPoints.lua`
(240 lines) or `ShapeshiftMana.lua` (258). Every API it needs is verified
present on both clients, no architectural change, and the one rule it bends
(§5.7) has a written argument and a `/duf profile` line to check it against.

The `PLAN.md` §14 claim that the cast bar "costs the same later as now" is
correct **for this plan and only this plan**. Plan 31 is where the cost is.

---

## Outcome

Merged 9 September 2026, PR #24. The estimate held — one sitting, no
architectural change, `Units/Factory.lua` untouched. Two things this plan got
wrong, recorded because both cost something to find:

**1. "Bump `SCHEMA_VERSION` to 18 anyway, following the existing convention."**
The convention is the opposite. A bump is owned by whatever rewrites a **stored
value**; added keys are filled by `EnsureProfile` and have nothing to migrate.
Two pinned assertions in the suite already said so (`portraitbg/no schema bump
of its own`, `heal/added keys without a schema bump`) and this plan did not
check them.

It is also not the harmless belt-and-braces the plan assumed. `Migrate:Run`
treats a version with no registered step as a profile it cannot carry forward:
it backs the profile up and loads defaults. **An unnecessary bump wipes
layouts.** Shipped at 17, owning no version.

**2. `_CHANNEL_UPDATE` is not the clipping signal.** Already corrected in §2a
before implementation, from the probe run. Recorded here too because the plan
asserted it in its first draft with no measurement behind it, which is exactly
what `COMPAT_FINDINGS.md` exists to stop.

**What the sequencing bought.** Writing `/dufprobe cast` before the element —
and writing the ordering test from the measurement rather than from the code —
caught a real bug that would have shipped: `STOP` arriving before `INTERRUPTED`
cleared the bar, and `fail()`'s obvious `if not el.casting then return end`
guard then swallowed the interrupt, so an interrupted cast vanished instead of
flashing red. On one client and not the other, which is the kind of bug that
survives a long time. The suite caught it on its first run.

The probe also answered three of its four questions from data already sitting in
SavedVariables from Plan 19, unread for three weeks. That the `heals` module
records raw returns rather than unpacking them into assumed names is why. Keep
doing that.
