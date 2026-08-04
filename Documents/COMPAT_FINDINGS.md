# Compatibility findings

**Deliverable of PLAN.md Phase 0.** Kept current forever after — step 7 of the
patch-day playbook is to update this file.

**Status: UNVERIFIED.** Every row below is what the code currently *assumes*,
derived from `SPEC.md` and from the API surface, not from a live client. The
implementation was written against these assumptions with each one isolated
behind `Core/Compat.lua`, so correcting any of them is a change to one file.

**To fill this in:** install `DyrueUnitFrames_Probe` (it is in `Probe/`), log in
on each client, and run:

```
/dufprobe
/dufprobe mana
/dufprobe derived
/dufprobe health
/dufprobe portrait
```

Then replace the "Assumed" column with what you actually saw, and note the date
and build. Where a finding contradicts `SPEC.md`, amend the spec — that is what
Phase 0 is for.

---

## Client identification

| | Classic Era / Hardcore | TBC Anniversary |
|---|---|---|
| Expected TOC | `11509` | `20506` |
| Observed TOC | _(fill in)_ | _(fill in)_ |
| Observed build | _(fill in)_ | _(fill in)_ |
| Date tested | _(fill in)_ | _(fill in)_ |

---

## 0.1 — API survey

| Question | Assumed | Classic Era | TBC | Where it is used |
|---|---|---|---|---|
| `issecretvalue` / `canaccessvalue` exist | **No** — SPEC §1.3 | | | If either exists, the text engine's premise is gone. `Compat.hasSecretValues` reports it and the first-run message warns loudly. |
| `C_UnitAuras.GetAuraDataByIndex` | Present (Midnight shared code) | | | `Compat.GetAura`; falls back to `UnitAura` automatically |
| `C_UnitAuras.GetAuraDataByAuraInstanceID` | Present | | | Incremental aura path |
| `UNIT_AURA` carries `updateInfo` | Probably | | | Used only to *skip* no-op updates; a full rescan is the normal path (see the note in `Elements/Auras.lua`) |
| `Enum.PowerType.Mana` | `0` | | | `Compat.MANA` |
| `GetCreatureDifficultyColor` | Present | | | `Compat.GetDifficultyColor` — SPEC §FR-3.7 requires the game's own function, not a reimplementation |
| `PowerBarColor` | Present | | | `Compat.GetPowerColor` |
| `DebuffTypeColor` | Present | | | Aura type borders |
| `RAID_CLASS_COLORS` | Present | | | `Compat.GetClassColor`, `CUSTOM_CLASS_COLORS` preferred when installed |
| `FACTION_BAR_COLORS` | Present | | | Reaction colors; hardcoded fallbacks exist |
| `SecureUnitButtonTemplate` | Present | | | Every frame. If this is ever gone the addon cannot work and says so plainly |
| `RegisterUnitWatch` | Present | | | Show/hide for conditional units |
| `frame:RegisterUnitEvent` | Present | | | Per-unit registration (SPEC §5.7) |
| `UNIT_HEALTH_FREQUENT` | **Probably removed** | | | Not required. `Compat.HasEvent` skips anything invalid rather than erroring |
| `UNIT_COMBO_POINTS` | Present | | **ABSENT — verified 2 Aug 2026** | Combo bar. See the verified finding below; the live path is `UNIT_POWER_UPDATE` for `"player"` |
| `GetComboPoints` | Present | | **Present — verified 2 Aug 2026** | `Compat.GetComboPoints`. Only the event went, not the reader |
| `GetPetHappiness` | Present (Classic/TBC only) | | | `[happiness]` tag |
| `ClickCastFrames` | Only with Clique installed | | | Clique interop |
| `GetAddOnMemoryUsage` vs `C_AddOns.*` | Both handled | | | `/duf profile` |

### VERIFIED — `UNIT_COMBO_POINTS` does not exist on TBC Anniversary

**Observed 2 August 2026, TBC Anniversary.** The first row in this file that is
a measurement rather than an assumption.

```
/run print(C_EventUtils.IsEventValid("UNIT_COMBO_POINTS"))
false
```

`GetComboPoints("player", "target")` still works and returns the right number —
only the *event* is gone. These clients run the modern shared code, which
retired `UNIT_COMBO_POINTS` and delivers combo points as a power type instead,
so `UNIT_POWER_UPDATE` for `"player"` is the live path.

**How it presented, because the shape is worth remembering.** Plan 9 registered
`UNIT_COMBO_POINTS` and nothing else. `Compat.RegisterUnitEvent` skips any event
`HasEvent` rejects — deliberately, so an unknown event never throws — and it
does so *silently*, so the element was subscribed to nothing. The bar showed the
correct count, but only after something forced a full update: changing target
worked, spending a combo point did not. No error, no warning, and a headless
suite that was green because `Tests/wowstub.lua` modelled a client that still
had the event.

Three things changed as a result:

- `Elements/ComboPoints.lua` declares **both** events and lets `Compat.HasEvent`
  pick. Feature-probe, never version-check — if a client has the old event it is
  used, and pass 4 of `Tests/run_tests.py` covers that client.
- `Compat.Describe()` reports `hasUnitComboPoints`, so `/duf compat` answers
  "which path is live" without the probe addon installed.
- The stub no longer lists `UNIT_COMBO_POINTS` as valid. **A stub that models a
  more capable client than the real one turns the suite into a rubber stamp**,
  and that is the general lesson: when a finding here says an API is absent, the
  stub has to say so too.

### The event-registration assumption

The code assumes **registering an unknown event throws**, as it does on modern
builds, and therefore never registers an event without checking
`Compat.HasEvent` first. If these clients still accept unknown events silently
this costs nothing. If they throw, this is what prevents a wall of errors.

---

## 0.2 — Shapeshift mana events (SPEC §FR-2.5)

**The question:** does mana fire `UNIT_POWER_UPDATE` while shapeshifted, or is
the fallback ticker mandatory?

**Assumed:** unreliable, so the ticker ships on in `auto` mode.

| | Result |
|---|---|
| Changes the events reported | _(fill in)_ |
| Changes only the 0.2s sampler saw | _(fill in)_ |
| Verdict | _(fill in)_ |

`/dufprobe mana` answers this directly and prints the verdict. The addon also
answers it *during normal play*: `tickerMode = "auto"` counts every value the
ticker caught that the events had not delivered, and `/duf profile` reports the
running total. If that number stays at zero across a few sessions, set the
ticker to `off` under Player → Shapeshift mana.

---

## 0.3 — Derived unit events (SPEC §4.8)

**The question:** does `targettarget` receive unit events, or is polling the
only mechanism?

**Assumed:** no reliable unit events; identity from `UNIT_TARGET`, values by
polling at 0.25s.

| Question | Assumed | Observed |
|---|---|---|
| `UNIT_HEALTH` fires for `targettarget` | No | _(fill in)_ |
| `UNIT_TARGET` fires with `"target"` as payload when the target switches targets | Yes | _(fill in)_ |
| `UNIT_TARGET` fires with `"focus"` on TBC | Yes | _(fill in)_ |
| `RegisterUnitWatch` shows/hides a `targettarget` frame correctly | Yes | _(fill in)_ |
| `UnitExists("focus")` / `PLAYER_FOCUS_CHANGED` on TBC | Present | _(fill in)_ |
| Same on Classic Era | Absent | _(fill in)_ |

If events *do* fire reliably, that is a good outcome: the poller becomes a
fallback, `Units/DerivedPoller.lua` keeps working unchanged, and the interval
can be raised to 1.0s to make it nearly free.

---

## 0.4 — Enemy health scaling (SPEC §FR-4.7)

**Assumed:** `UnitHealthMax` returns `100` for units outside your group, so
absolute health numbers for enemies are not real.

**Detection predicate in use** (`Compat.HasRealHealthValues`): true for the
player, anything in your party or raid, and your own pet; otherwise
`UnitHealthMax(unit) ~= 100`.

| Target | `UnitHealth` | `UnitHealthMax` | Scaled? |
|---|---|---|---|
| Same-level mob | | | |
| Elite | | | |
| Raid boss | | | |
| Party member | | | |

`/dufprobe health` fills this in. If the predicate is wrong, `[hp:cur]` and
`[hp:max]` are the only things affected and they fail *closed* — rendering
nothing rather than a fabricated number.

---

## 0.8 — Portraits (SPEC §FR-7.4)

| Question | Assumed | Observed |
|---|---|---|
| `SetPortraitTexture` works | Yes | _(fill in)_ |
| Fallback for units with no portrait | `INV_Misc_QuestionMark` | _(fill in)_ |
| `PlayerModel` + `SetUnit` renders | Yes | _(fill in)_ |
| Model updates on target change without an explicit `SetUnit` | **No** — re-called always | _(fill in)_ |
| Camera survives a loading screen | **No** — re-applied on `PLAYER_ENTERING_WORLD` | _(fill in)_ |
| Out-of-range unit | Model will not load; falls back to 2D | _(fill in)_ |

Every one of these is handled defensively already, so a "yes" anywhere just
means the handling was precautionary rather than necessary.

---

## 5.6 — Hiding the Blizzard frames

**The open question that most affects the default configuration.**

`SPEC.md` §5.6 ranks the options: if Edit Mode can hide `PlayerFrame` and
`TargetFrame` natively, DyrueUnitFrames should not touch them at all.

**Current default: `blizzardFrames = "hide"`, `blizzardParty = true`.**

This deliberately inverts the spec's preference order. §5.6 ranks "leave them
alone and let Edit Mode do it" first, and that reasoning still holds — it is
genuinely lower risk, because it involves no addon touching Blizzard's UI at
all. But a unit frame addon whose out-of-the-box state is its own frames
underneath Blizzard's is not usable, and "usable on install" won the trade.

The containment argument is unaffected: hiding still goes through the single
`Compat.HideBlizzardFrame` path, which is the only code in the project that
touches a Blizzard frame. What changed is which way that one switch is thrown
by default, not how many places can throw it.

`/duf blizzard none` reverts it, and the first-run message names the command.

| Question | Observed |
|---|---|
| Does Edit Mode exist on 1.15.9? | _(fill in)_ |
| Does Edit Mode exist on 2.5.6? | _(fill in)_ |
| Can it hide `PlayerFrame` / `TargetFrame`? | _(fill in)_ |
| If not, does `UnregisterAllEvents` + reparent work cleanly? | _(fill in)_ |

If Edit Mode cannot do it, change the default in
`Core/Defaults.lua` → `general.blizzardFrames = "hide"` and note it here.

---

## Deviations from SPEC.md

Recorded as they are made, so the reasoning survives.

| Spec item | What was built | Why |
|---|---|---|
| §5.9 "update paths are not blanket-wrapped" | One `xpcall` per *event dispatch*, plus a single local assignment naming the element about to run | Gives per-element circuit-breaker attribution at the cost of one protected call per event rather than one per element. Satisfies the intent (no per-element pcall) while making the circuit breaker actually implementable |
| §5.8 AceDB defaults | AceDB is used for profile management only; the schema is deep-filled by `Defaults:EnsureProfile` | AceDB implements defaults with `__index` metatables, under which a *deleted* color rule or text element comes back on next login. User-editable lists need real ownership |
| §FR-2.3 append mode | The appended mana bar hangs below the button's own bounds rather than growing the button | Growing a secure button is a protected operation. Hanging the bar outside means a druid shifting form mid-fight sees mana immediately instead of at `PLAYER_REGEN_ENABLED`. Reserve mode is unaffected and keeps everything inside the frame |
| §FR-5.9 right-click cancel | Secure attribute on a separate overlay button, updated through `CombatQueue` | Aura icons must be shown and hidden constantly in combat, which a protected frame cannot do. Splitting insecure icon from secure overlay is the only arrangement that satisfies both. Cost: in combat the overlay can be one aura stale |
| §5.7 incremental aura updates | `updateInfo` is used to *skip* no-op updates; the normal path is a full rescan | The spec calls this an optimization, not a blocker. Maintaining a parallel instance-ID store is a real bug surface and buys nothing measurable at Classic's aura counts |
| §FR-4.1 "Default: green" | Health bars ship in `class` mode, with `reaction` as the NPC fallback | Class color says at a glance who you are looking at, and degrades to something meaningful for NPCs rather than to a fixed color that means nothing. The spec's green is still the stored `color` and is one dropdown away. Schema 4 migrates profiles still on the old default |
| §5.7 three permitted tickers | A fourth was added: one `OnUpdate` driver in `Systems/BarSweep.lua`, shared by the power tick indicator (Plan 2) and the five second rule indicator (Plan 10) | The sweep is a continuous animation *between* two regen ticks and nothing fires in between — `UNIT_POWER_UPDATE` fires AT the tick, which is the moment the sweep restarts. Same category as the derived-unit poller: the game does not push what we need. It obeys the same discipline as the other three, running only while a visible bar has an active sweep and stopping the instant that stops being true, and `/duf profile` reports it. Player only, on the §FR-8.5 boundary: another unit's tick cadence and mana expenditure are not observable. Both plans share the one driver and one line-rendering path with a table of providers, so there is no fifth ticker |
| §5.1 file layout | A `Tests/` directory was added | A headless suite that runs the addon against a stubbed API in a real Lua 5.1 interpreter. Not in the spec's layout, but the project's entire premise is that the last one kept breaking, and this makes step 6 of the patch-day playbook cost thirty seconds instead of an evening |

---

## Language-level findings

Things about the runtime itself, discovered while building. These are not
client-version questions but they belong with the other hard-won facts.

### `xpcall` takes no arguments in Lua 5.1

WoW runs Lua 5.1, where `xpcall(f, handler)` cannot forward arguments to `f` —
that was added in 5.2. Writing `xpcall(fn, handler, frame)` does not error; it
silently calls `fn()` with no arguments at all.

This was live in `Core/Errors.lua` and it meant **every element update in the
addon was failing silently**, with the circuit breaker swallowing the evidence
and attributing it to an unnamed context. Static analysis cannot see it; the
headless suite caught it on its first run.

`Errors:Guard` and `Errors:Dispatch` now pass arguments through upvalues and a
nullary trampoline, with the slots saved and restored so a `Guard` nested inside
a `Dispatch` is safe. It allocates nothing, which is why a closure was not used.

Some WoW builds may have backported the 5.2 behavior. Do not rely on it.
