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
/dufprobe auraorder
/dufprobe rage
/dufprobe heals
/dufprobe healcomm
/dufprobe incoming
/dufprobe scroll
```

The probe's Lua is loaded at login, so **`/reload` before running a subcommand
that was added since you last logged in** — otherwise it is not recognised, and
until 11 August 2026 an unrecognised subcommand silently ran the full survey
instead. That cost a 90-second raid run and looked exactly like success.

Then replace the "Assumed" column with what you actually saw, and note the date
and build. Where a finding contradicts `SPEC.md`, amend the spec — that is what
Phase 0 is for.

---

## Client identification

| | Classic Era / Hardcore | TBC Anniversary |
|---|---|---|
| Expected TOC | `11509` | `20506` |
| Observed TOC | `11509` — as expected | `20506` — as expected |
| Observed build | `1.15.9` / `69109`, dated `Aug 3 2026` | `2.5.6` / `69110`, dated `Aug 3 2026` |
| Observed `WOW_PROJECT_ID` | `2` | `5` |
| Date tested | 8 August 2026 | 11 August 2026 |

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
| `FontString:GetStringWidth` returns the **unconstrained** width | **Yes — verified 7 August 2026** | | | `Elements/Text.lua` width modes (Plan 6). See the verified finding below |
| `GetStringWidth` works on a **hidden** font string | Yes | | | Same. Text elements are measured during an update that may run while the frame is not shown. NOT verified — the check below used a font string on a shown parent |
| `UnitGetIncomingHeals` | ~~**Absent** — Cataclysm-era~~ **WRONG** | | **PRESENT and working — verified 11 Aug 2026** | Plan 11 / 19. See the verified finding below: it returns other people's heals, about a second ahead. The assumption this row carried was the premise of Plan 11's whole design |
| `UnitGetTotalAbsorbs` | ~~**Absent** — Warlords-era~~ **WRONG** | | **Present — verified 11 Aug 2026.** Never observed non-zero | Plan 12's candidate 1. Present, so most of that plan may be deletable — but see the UNPROVEN note below before deleting anything |
| `UnitGetTotalHealAbsorbs` | ~~**Absent** — Warlords-era~~ **WRONG** | | **Present — verified 11 Aug 2026** | Still not used. No Classic/TBC mechanic needs it |
| `UNIT_HEAL_PREDICTION` | ~~**Absent**~~ **WRONG** | | **Present and fires — verified 11 Aug 2026** | The push event for the above. 900 firings in 90 s, for `party*`, `raid*` and `targettarget`. Means no ticker is needed |
| `UNIT_ABSORB_AMOUNT_CHANGED` | Not previously asked | | **Present — verified 11 Aug 2026** | Would be Plan 12's push event on the same terms |
| `CombatLogGetCurrentEventInfo` | Present | | | `Compat.GetCombatLogEvent`. Every amount Plan 11 predicts is learned through it |
| `UnitCastingInfo` / `UnitChannelInfo` | Present, milliseconds | | | `Compat.GetCastEndTime`. Only ever called for `"player"` |
| `Texture:SetGradient` takes color **objects** | Present — 10.0 signature | | | Plan 16's overflow cap band, through `Compat.SetGradient`. Needs `CreateColor` too, which is assumed present wherever this is |
| `Texture:SetGradientAlpha` (eight loose numbers) | **Absent** — replaced in 10.0 | | | The pre-10.0 form. Tried second and expected to fail; if it turns out to be the live one on either client, the wrapper already handles it and only this row changes |

### VERIFIED — `GetStringWidth` ignores `SetWidth`

**Observed 7 August 2026.** The premise of Plan 6's `fit` mode, and the one
assumption in it that a headless run cannot check.

```
/run local f=UIParent:CreateFontString(nil,"OVERLAY","GameFontNormal") f:SetWidth(20) f:SetText("aaaaaaaaaaaaaaaaaaaa") print(f:GetStringWidth())
133.688
```

Twenty characters in a font string clamped to 20px measure 133.688. So
`GetStringWidth` reports what the string **would** render at, not what it is
allowed to occupy — which is what makes "measure the neighbor, then take the
gap" possible at all. Had it returned 20, every fitted name would have measured
as already fitting and none would ever have been shortened: a silent no-op, with
the overlap still there and nothing in the logs.

Two details worth keeping:

- **The value is fractional**, and at other UI scales it will be more so.
  Nothing in `Elements/Text.lua` rounds it; budgets and comparisons are all
  floats, and the truncation search is over character boundaries rather than
  pixel counts, so sub-pixel widths never accumulate into an off-by-one.
- **133.688 / 20 ≈ 6.7px per character** at `GameFontNormal`. The stub in
  `Tests/wowstub.lua` models 6px at size 12, so the headless figures are the
  right order and the tests are not passing on a fantasy.

Still unverified: whether this works on a **hidden** font string. Text elements
are measured during updates that can run while a frame is not shown, so if it
returns 0 there, a name would come back unbounded until the frame is next
visible. Nothing has been seen to suggest it does.

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
| Changes only the 0.2s sampler saw | **0**, across 735 ticks in one session (8 August 2026, Anniversary, bear form) |
| Verdict | Provisional: events look reliable. Needs a few more sessions before the ticker goes to `off` |

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
| A `PlayerModel` inside the secure button swallows the click | **No** — `EnableMouse(false)` is set on it anyway (Plan 7) | _(fill in)_ |

Every one of these is handled defensively already, so a "yes" anywhere just
means the handling was precautionary rather than necessary.

**How to close the last row.** Set a unit's portrait to 3D with `column`
placement, then click the portrait itself. It should target the unit. The
headless suite can only assert that the model reports the mouse as disabled,
which is the client's own default — whether a model frame honors it is not
answerable without a client, and is the same R11 category as everything above.

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

## Plan 17 — Rage decay

Not a client-capability question but a **game-rule** question, and it belongs
here for the same reason the others do: the answer was looked for, not found, and
the code was written around the gap rather than around a guess.

**What the sources said.** Rage decays only out of combat — every source agrees on
that and nothing else was contested. Beyond it:

| Claim | Source | Weight before measuring |
|---|---|---|
| ~1 rage/sec, delivered as 2 or 3 rage on a ~2.5 s tick | Vanilla WoW Wiki | One source. The discrete-tick shape is the useful part |
| 1.25 rage/sec (75/min) | warcraft.wiki.gg | Read as retail-only, and therefore dismissed. **This was the wrong call — see below** |
| Decay begins "after a brief delay" | Classic warrior guides | No number given anywhere |
| Vanilla Anger Management: "Increases the time required for your rage to decay while out of combat by 30%" | warcraft.wiki.gg | Solid, and it means **the rate differs between our two clients** |
| Redesigned in 2.0.1 to "Generates 1 rage per 3 seconds while in combat" | same | So nothing modifies out-of-combat decay on TBC |
| Entire rage bar lost instantly when combat drops | Blizzard forums, no developer reply | Player reports only. Handled defensively by the plausibility guard |

**MEASURED — `/dufprobe rage`, Anniversary client (2.5.6), druid in bear form,
8 August 2026.** 56 entries, two full drains to zero, ten decay intervals sampled.

| Question | Assumed | Observed |
|---|---|---|
| Does `UNIT_POWER_UPDATE` fire per decay tick? | Yes — the whole derivation rests on it | **Yes.** Zero changes the 0.1 s sampler caught that the events had not already reported |
| Decay interval, out of combat | ~2.5 s | **2.0 s.** Ten samples, 1.95–2.12 s, mean 2.04. `/duf profile` independently settled on 2.05 s |
| Rage lost per tick | 2–3 | **Alternating 3 and 2**, mean 2.50 |
| Delay from combat drop to first decay | Unknown, not modeled | **None.** 0.41 s and 1.16 s on two drops, both *under* one interval |
| Anything decaying *during* combat | No | **No.** Seven in-combat decreases, all 10–15 rage, all ability spends (Maul, Demoralizing Roar) |
| Interval with vanilla Anger Management talented | ~2.6 s at the observed base, or an amount change instead | **UNEXPLORED** — no Classic Era warrior with the talent was available. See below |

Three of those change what the code should say.

**1. The 1.25/sec figure was right and the plan dismissed it.** 2.5 rage per 2.0 s
tick *is* 1.25 rage/sec — exactly what warcraft.wiki.gg gives. It reads as a retail
number only because it is quoted per-second. The alternating 3, 2, 3, 2 is the
giveaway: Classic stores rage at 10× internally, so 25 units a tick cannot divide
evenly into displayed rage and surfaces as 3 then 2. The vanilla source had the
amounts right and the interval wrong; the modern one had the rate right all along.

**2. The seed moved from 2.5 s to 2.0 s.** Derivation makes the seed almost
irrelevant, but "almost" is the first sweep of a session before anything has been
observed, and that one may as well be right.

**3. There is no pre-decay delay to model.** Both measured gaps are under one
interval, which is what you get when a fixed server cadence keeps running and the
combat drop simply lands somewhere inside it. Nothing documents a delay because
there is nothing to document. `rageFirstDecay` is a phase offset, not a duration —
`/duf profile` still reports it, as evidence of exactly this.

**Also observed in the same session, and it answers 0.2 above:** the shapeshift mana
ticker reported 735 ticks and **0 corrections** — every mana value while shifted had
already been delivered by an event. One session is not the "few sessions" §FR-2.5
asks for before turning the fallback off, but it is the first real data point and it
points at the events being reliable on this client.

### UNEXPLORED — Anger Management on Classic Era

The one row above that is still open, and the only place this feature is known to
differ between the two supported clients. Recorded rather than left as a blank,
because otherwise the next person has to re-derive it from the wiki.

Vanilla Anger Management (Protection tier 1, 1.15.x) reads *"Increases the time
required for your rage to decay while out of combat by 30%."* Patch 2.0.1 replaced
it with in-combat generation, so **Anniversary is unaffected** and the 2.0 s measured
above is the whole story there.

The tooltip covers two different mechanisms, and they are not distinguishable
without measuring:

| Reading | Effect | What the code sees |
|---|---|---|
| The **interval** stretches | ~2.6 s between ticks, same 2–3 rage each | A new cadence, learned within a few ticks |
| The **amount** shrinks | Still 2.0 s, less rage per tick | Nothing. The interval never moves |

**Neither can break the line, which is why this shipped without the answer.** The
band stays at **1.5–4.0 s** — wider than anything measured, deliberately — so 2.6 s
is learned rather than rejected, and so is the 3.25 s a pre-measurement reading of
the docs would have predicted. The amount feeds nothing but the
`RAGE_MAX_DECAY_STEP` guard, and a *smaller* amount moves away from that guard, not
towards it. Nothing is hardcoded to 2.0 except the seed, which governs only the
first sweep of a session.

**To close it:** `/dufprobe rage` on a Classic Era warrior with the talent learned,
then unlearned, comparing the reported mean interval and mean step. If the interval
stretches past 4.0 s — which no reading of the tooltip predicts — `RAGE_MAX_INTERVAL`
in `Systems/BarSweep.lua` is the one constant to change.

---

## Plan 3 — Options panel clipping

### VERIFIED — `GetClipsChildren` does not exist on Classic Era, but the setter does

**Observed 8 August 2026, Classic Era 1.15.9 / 69109, via `/dufprobe scroll`.**

```
Frame:GetClipsChildren exists   no
Frame:SetClipsChildren exists   yes
```

An asymmetric pair, which is the useful part. The clipping state **cannot be
read back** on this build, so any probe or assertion that tries to confirm
clipping by reading the property will report `nil` no matter what was set. The
setter is present, so clipping can still be *applied* — it just cannot be
verified from Lua. Verify by eye, or by measuring whether children still draw.

Not yet checked on TBC Anniversary. Do not assume it matches: the whole reason
this file exists is that the two clients differ.

### VERIFIED — the AceConfigDialog scroll viewport can have zero height

**Same run.** On Player → Text with the options window open:

```
viewport  w=234 h=0   top=322 bottom=322
content   w=234 h=797 top=322 bottom=-475
scrollbar w=16  h=0   top=338 bottom=338
```

The scroll frame had **no height at all**, and the zero propagated up the whole
ancestry — the tree frame beside it was zero too. Consequences worth recording,
because they misdirected the original diagnosis:

- Every one of the 215 laid-out objects was "outside the viewport", trivially.
  The overflow in the bug report is a *symptom* of the zero height, not evidence
  that clipping is misconfigured.
- Nothing was mis-measured. `content.height` and `content:GetHeight()` agreed at
  797, which rules out the dynamic-`name` description theory as the cause.
- The scrollbar is anchored `-16` / `+16` against the viewport's own top and
  bottom, so a zero-height viewport collapses it to `h=0` and leaves its
  `ScrollUpButton` and `ScrollDownButton` 16px either side of a single point,
  both visible, with no container around them. **That is what the "floating
  arrow pairs" in the report are** — and the second pair is the TreeGroup's own
  scrollbar, which has the same template.

### RESOLVED — a tall inline group evicted the nested tree

**Ancestry read 9 August 2026, both a fresh open and after a tab switch —
identical, so it was never a stale layout.** Heights from the window inward:

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

**A group with `childGroups` renders its child groups as a nested tree or tab
widget, and AceGUI places that widget below whatever loose args the group also
has.** `Config/Options_Text.lua` carried the tag reference as an
`inline = true` group at `order = 0`, and `Tags:AllHelp()` is 22 lines — about
325px. The unit's tab content is ~306px, so the nested tree was anchored 324.9px
down inside 306px: its top landed 18.9px below its own bottom and the height
clamped to zero. Every descendant inherited it, including the scroll frame,
whose 797px of content then drew unclipped from y=332 downward.

So the tag reference *was* implicated, but not in the way first guessed. It is
not mis-measured — `content.height` was correct at 796.8 in both runs. It is
simply tall enough to evict its sibling.

**Fix:** the tag reference became its own tree node rather than an inline group,
so it renders inside the scroll frame and costs the parent container nothing.
`Tests/tests.lua` grows a tripwire that estimates the loose lines above any
`childGroups` widget and fails past a budget; reintroducing `inline = true`
trips it on all fourteen units.

**Window height mattered but was never the fix.** At AceConfigDialog's default
500px the tab content is ~373px, leaving the tree ~48px — tiny but non-zero, so
a larger window hid the bug rather than avoiding it.

**A note on which panel this was.** Both runs reported an empty
`AceConfigDialog.OpenFrames`, because `Core/Core.lua:316` also registers through
`AddToBlizOptions`, and those containers live in `AceConfigDialog.BlizOptions`
keyed by path. Anything attributing an AceGUI container to this addon has to
check both tables; `/dufprobe scroll` now does, and reports which path a
container came through.

**A note on the fix.** The scrollbar is a child of the scroll frame anchored
outside its right edge (`AceGUIContainer-ScrollFrame.lua:177`), so
`SetClipsChildren(true)` on the scroll frame would clip the scrollbar away.
Whatever the eventual fix, it is not that call on that frame.

---

## Plans 11, 12 and 19 — incoming heals

**Four probe runs on TBC Anniversary 2.5.6 / 69110, 11 August 2026**, in 24- and
25-man raids: two `/dufprobe heals`, one `/dufprobe healcomm`, one
`/dufprobe incoming`. This section replaces four rows in the survey above that
were assumptions rather than measurements, and one of them was load-bearing for
an entire plan.

### VERIFIED — `UnitGetIncomingHeals` is present, works, and includes other players' heals

The single most consequential row in this file, and it was wrong.

```
5120 samples over 90s      688 non-zero      688 of those included other people
peak: all=13223  mine=0  others=13223
UNIT_HEAL_PREDICTION fired 900 times
lead time: mean 1.20s, median 1.08s, max 7.77s, min 0.07s
59 of 60 resolved observations were heals cast by somebody other than the player
```

Resolved observations name their casters — Kahunazz, Nbamilkboi, Aripriest,
Richholyquan, Ancientdice — so this is other people's healing, arriving on the
API, roughly a second before it lands.

Four things follow:

- **The direct-cast half of Plan 19 is an API call.** No combat log, no comms
  library, no target attribution, no learned amounts.
- **No ticker.** `UNIT_HEAL_PREDICTION` fires — 900 times in 90 s, for `party*`,
  `raid*` and `targettarget` — so this is pushed and SPEC §5.7 needs no new
  argument.
- **Plan 11's premise is narrowed, not destroyed.** The value was non-zero in
  only 13% of samples, in bursts, with lead times shaped like cast times rather
  than a HoT's 12–15 s plateau. Consistent with the historical behaviour of this
  API: direct casts only. The aura-read HoT path stays authoritative.
- **These clients ship the modern shared codebase.** The same fact that took
  `UNIT_COMBO_POINTS` away gives these back. "Expansion X introduced it" is not
  evidence about an Anniversary client, and this file should stop treating it as
  though it were.

### UNPROVEN — the two-argument form

`UnitGetIncomingHeals(unit, "player")` was called 5120 times without a single
failure, and returned **0 every time**, while the player cast only two heals in
the whole run. So the probe's own guard reported Q2 as unproven, which was
correct behaviour: `others` is computed as `all - mine`, and a filtered form that
silently ignored its argument would produce exactly this.

**The conclusion above does not rest on that subtraction.** Two casts cannot
produce 688 non-zero samples peaking at 13,223, and the observations name other
casters directly. Magnitude and identity carry it independently.

**To close it properly:** one run where the player casts several *cast-time*
heals and `mine` is watched for a non-zero. Needed before "my heals versus
theirs" is ever offered as a display distinction, since that feature would rest
on the decomposition rather than on the total.

### UNPROVEN — absorbs (Plan 12)

`UnitGetTotalAbsorbs`, `UnitGetTotalHealAbsorbs` and
`UNIT_ABSORB_AMOUNT_CHANGED` are all present. **Absorbs never read non-zero** in
this run — peak 0 across 5120 samples. The sampled set is only
`player`/`target`/`focus`/`party1-4`, so a run where nobody shielded those seven
units proves nothing either way.

Plan 12 should not be rewritten on the strength of presence alone. Re-run
`/dufprobe incoming` with a priest shielding the party first.

### VERIFIED — the combat log does not carry a cast's target

Across both `heals` runs:

```
SPELL_CAST_START     368 lines, 0 with a destination
SPELL_CAST_SUCCESS  1046 lines, 821 with a destination   (control)
```

The control is what makes this a finding rather than a bad sample. `destGUID`
arrives as an **empty string** — not `nil`, not `0000000000000000` — so anything
testing for the zeroed GUID would conclude the opposite.

Moot now that the API works, but recorded because it is the answer to "why not
just read the combat log", which is the first thing anyone will ask.

### VERIFIED — other units' cast events and `UnitCastingInfo` do work

`UNIT_SPELLCAST_START` and `_CHANNEL_START` fired for **20 distinct raid tokens**
in one run and 19 in the other. `UnitCastingInfo` on those units was readable
**25 times out of 25**, with millisecond start and end times at the same return
positions `Compat.GetCastEndTime` already uses.

`UNIT_SPELLCAST_SENT` remains player-only — it appeared under `player`, `raid4`
and `targettarget` with the first two at an identical count, which is one player
seen through three tokens. No other raider ever sent one.

### VERIFIED — an aura's caster resolves at raid distance

Four censuses across the two runs: 165–323 helpful auras, of which 1–4 had no
resolvable `sourceUnit`, and **three of the four censuses caught auras whose
caster resolved while that caster was out of range**. Every orphan was an
hour-long raid buff (`Gift of the Wild`, `Prayer of Fortitude`,
`Arcane Brilliance`), never a HoT. One run had zero orphaned durational auras.

This is what makes the aura-read HoT path safe, and it is now the half of Plan 19
that the API does *not* replace.

### MEASURED — LibHealComm is effectively dead on this client

`/dufprobe healcomm`, 25-man raid, 7625 combat log lines in 90 s. All four
candidate prefixes registered:

| Prefix | Messages | Senders |
|---|---|---|
| `LHC40` | 32 | **1** |
| `LHC`, `HealComm`, `LibHealComm` | 0 | 0 |

Twenty-three distinct heal sources, eighteen of them casting five or more heals,
and **exactly one** was broadcasting. Traffic on `LHC40` and silence on the other
three is what a correct-prefix run looks like, so the silence is real.

The library itself is unusable anyway — its Classic branch stopped in September
2022 against TOC 1.13.3 — but this closes the receive-only route too, and for a
reason no engineering fixes: there is nobody to receive from.

### UNTESTED — Classic Era

Every measurement in this section is TBC Anniversary. **Nothing here has been
checked on 1.15.9**, which is a different codebase generation, and the addon
supports both. `/duf compat` answers it in one command and reports
`hasIncomingHeals` directly.

If the API is absent there, the design needs both paths — API where present,
Plan 11's derived engine where not — selected on `Compat.hasIncomingHeals`, which
is the seam Plan 11 built for exactly this.

### The lesson, which is the same one as `UNIT_COMBO_POINTS`

`/duf compat` has reported `hasIncomingHeals` since Plan 11 shipped, precisely so
this assumption would be checkable. Nobody ran it for three days, and three
probes went looking for the same answer in the combat log, in an addon comms
protocol, and in a third-party library — all of them harder, all of them
ultimately closed.

**Check the cheap capability flag before building an investigation around its
assumed value.** And note that the flag alone was still not enough:
`hasIncomingHeals` is `_G.UnitGetIncomingHeals ~= nil`, which is presence, not
function. It took a fourth probe to show that the function answers, that it
answers about other people, and that it answers early enough to matter.

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
| §5.7 three permitted tickers | A fourth was added: one `OnUpdate` driver in `Systems/BarSweep.lua`, shared by the power tick indicator (Plan 2), the five second rule indicator (Plan 10) and the rage decay indicator (Plan 17) | The sweep is a continuous animation *between* two regen ticks and nothing fires in between — `UNIT_POWER_UPDATE` fires AT the tick, which is the moment the sweep restarts. Same category as the derived-unit poller: the game does not push what we need. It obeys the same discipline as the other three, running only while a visible bar has an active sweep and stopping the instant that stops being true, and `/duf profile` reports it. Player only, on the §FR-8.5 boundary: another unit's tick cadence, mana expenditure and rage decay are not observable. All three plans share the one driver and one line-rendering path with a table of providers, so a third indicator added no ticker and there is still no fifth |
| §FR-5.6 "a configurable corner" / §FR-5.5 optional duration text | Both numeric overlays take any of the nine points, plus `ABOVE` and `BELOW`, with x/y offsets — and both ship **off** (Plan 13) | Corners were not the constraint; size was. At the specified 20px icon size an outlined stack count is over half the height of the art, and a full 8x2 debuff grid came out unreadable. The capability §FR-5.6 asks for is intact and wider; what changed is the shipped default and the fact that placement is now a setting instead of a hardcoded inset. Schema 14 migrates only the exact untouched default, so anyone who had already chosen a corner or a size keeps it |
| §2.2 "incoming-heal prediction — out of domain" | Built, as `Systems/HealPrediction.lua` plus `Elements/HealPrediction.lua` (Plan 11) | The exclusion grouped it with combat text and threat meters, i.e. another addon's problem domain. It belongs with the other group — the things Classic cannot support — because it is a property of a health bar rather than a separate display, and what made it look foreign was the absent API rather than the feature. §2.1's first goal is replacing SUF day to day, and SUF has it. It costs none of what §2.2's other exclusions were protecting: no secure header, no Blizzard frame contact, no new library, and no new ticker. Amounts are derived by learning from the player's own combat log rather than shipped as a rank database, so there is nothing to go stale. The absorb half is deliberately still excluded, pending Plan 12 |
| §FR-7.2 placement is `inside` or `outside` | A third placement, `column`, is the new default, and the other two were renamed `overlay` and `detached` (Plan 7) | Neither original placement puts the portrait beside the bars, which is what was actually wanted: `inside` hides it behind an opaque fill, `outside` puts it beyond the secure button's rect where it cannot be clicked. `column` is inside the button — so click-targeting falls out for free, with no second secure frame and no attribute duplication — and the bars inset for it the same way the mana bar's slot reserves height, rather than inventing a second notion of an element reserving space. The rename is because keeping `inside` for "behind the bars" alongside a `column` that is also inside the frame would have been actively misleading. §FR-7.2 was amended in place rather than left standing against the code. Schema 16 renames unconditionally and moves only placements that can be shown to be inherited rather than chosen |
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
