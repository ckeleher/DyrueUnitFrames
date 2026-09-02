# Plan 32 — Target Cast Bar

**Status:** Not started.
**Created:** 1 September 2026
**Branch:** `Plan-32-target-cast-bar`
**Depends on:** Plans 30 and 31. Branch from `main` after both merge.
**Blocked on:** one probe run. See "Measure first", below.

---

## Request

> i understand that, per prior docs, player and target cast bars are out of scope. I want you to estimate how difficult it would be to add support for those, as independently movable frames which are by default attached to the player and target frames. consider the difficulty of adding cast bars for other frame types (party, focus, etc) as well

**This plan covers the target half**, and with it the general question of whether
a cast bar can be driven for any unit that is not the player. Plan 33 spends the
answer on the remaining units.

---

## Interpretation

Here the request's premise is not just half right, it is **wrong on the record**,
and the correction is the whole reason this plan is short.

`SPEC.md:67` excludes cast bars for non-player units with a stated reason:

> Classic clients do not broadcast `UNIT_SPELLCAST_*` for other units; only
> guesswork is possible

`Documents/COMPAT_FINDINGS.md:765` measured the opposite, and marked it
**VERIFIED, 11 August 2026**:

> `UNIT_SPELLCAST_START` and `_CHANNEL_START` fired for **20 distinct raid
> tokens** in one run and 19 in the other. `UnitCastingInfo` on those units was
> readable **25 times out of 25**, with millisecond start and end times at the
> same return positions `Compat.GetCastEndTime` already uses.

That measurement was collected for Plan 19, where it was incidental. Its
consequence for §2.2 was never followed up, and the non-goal has been sitting on
a premise its own compatibility document contradicts for three weeks.

The first task of this plan is therefore documentation, not code: amend
`SPEC.md` §2.2 the way §2.3 was amended for heal prediction, saying what the
reason was, what measurement replaced it, and where that measurement lives.

---

## Measure first

The verified finding covers **`START` and `CHANNEL_START` only.** `Probe.lua`'s
`SPELLCAST_EVENTS` list (`Probe/DyrueUnitFrames_Probe/Probe.lua:1649`) has
exactly three entries:

```lua
local SPELLCAST_EVENTS = {
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_SENT",
}
```

Every event that ends or adjusts a cast — `_STOP`, `_INTERRUPTED`, `_DELAYED`,
`_FAILED`, `_CHANNEL_UPDATE`, `_CHANNEL_STOP` — is **unmeasured for any unit but
the player**. Plan 30 relies on all of them and is safe because the player is
verified; this plan cannot inherit that.

Do not design around a guess. Extend the list, run it once, read the result:

1. Add the six events to `SPELLCAST_EVENTS`. The module already counts per-token
   firings into `record.spellcastUnits` (`Probe.lua:1905`) and already reads
   `UnitCastingInfo` back for non-player tokens (`:1915`), so the reporting needs
   no new code — only the list grows.
2. Run `/dufprobe heals` (or the spellcast module directly) in a party or raid,
   targeting casters. One session is enough: the existing run caught 20 tokens.
3. `/reload` once and read the SavedVariables file. **Do not ask for pasted
   output** — the file is the interface.
4. Record the result in `COMPAT_FINDINGS.md` whichever way it falls.

### The answer does not gate the plan, only its fallback

This is worth stating plainly so the probe run is not treated as a blocker on
starting:

- **If the stop events fire** (expected — Classic Era 1.15 restored native enemy
  cast bars, and the client has to drive those somehow), the target cast bar is
  the player cast bar with a different token. Nothing to design.
- **If they do not**, `UnitCastingInfo(unit)` returning nil *is itself* the stop
  signal, and Plan 30's driver is already reading that unit every frame while the
  bar is visible. The bar then lingers for at most one frame past the true end.

So the failure mode is invisible, and the probe run buys certainty about which
code path is load-bearing rather than permission to proceed. Run it anyway —
`COMPAT_FINDINGS.md` exists because this project does not ship on "expected".

---

## Design

After Plans 30 and 31, this is a Registry entry, a defaults entry and a Blizzard
frame to hide.

```lua
define("targetcast", {
    order = 25,
    label = L["Target Cast Bar"],
    kind = "castbar",
    token = "target",
    secure = false,
    unitWatch = false,
    changeEvents = { "PLAYER_TARGET_CHANGED" },
})
```

`changeEvents` is the one line that is not a copy of `playercast`, and it is
load-bearing. `Factory`'s `dispatch` (`Units/Factory.lua:57`) treats a change
event as *"the unit behind the token is now someone else, so everything is
stale"* and calls `FullUpdate`. That is exactly right here: switching target
mid-cast must abandon the old unit's bar and re-read the new one, not animate the
old cast to completion.

Shipped default, per the request's *"by default attached to the ... target
frames"*:

```lua
u.targetcast = castUnit({
    width = 220, height = 22,
    anchor = { to = "target", point = "TOP", relativePoint = "BOTTOM", x = 0, y = -6 },
})
```

Width matches the target frame's 220 (`Defaults.lua:648`) so the default layout
lines up, and the anchor mirrors `playercast`'s so the two read as a pair.

**`enabled`: ships on.** A target cast bar is the single most useful thing in
this whole sequence — it is what tells you when to interrupt — and Plan 30's
template default of `false` means switching it on here is a deliberate, visible,
one-line decision rather than a default leaking sideways.

### Hiding Blizzard's

Blizzard draws the target's cast bar as `TargetFrameSpellBar`, a child of
`TargetFrame`. `Compat.HideBlizzardFrame` (`Compat.lua:696`) already unregisters
`frame.spellbar` when it hides `TargetFrame` (`:713`), so with
`blizzardFrames = "hide"` — the shipped default — it is already gone.

But that only holds while the user hides the target frame. Add
`targetcast = { "TargetFrameSpellBar" }` as its own key so the two are
independent, exactly as Plan 30 did for the player. A user running our cast bar
with Blizzard's frames visible is a supported combination.

---

## Files

| File | Change |
|---|---|
| `Probe/.../Probe.lua` | Six events added to `SPELLCAST_EVENTS`. **First**, before any of the below |
| `Documents/COMPAT_FINDINGS.md` | The probe result; the §2.2 correction and its evidence |
| `Documents/SPEC.md` | §2.2 amended — the non-goal is retired, with the reason it was wrong. §3 gains the frame |
| `Units/Registry.lua` | `targetcast` |
| `Core/Defaults.lua` | `u.targetcast`; `SCHEMA_VERSION` 19 → 20 |
| `Core/Compat.lua` | `blizzardFrames.targetcast` |
| `Tests/tests.lua` | Below |

---

## Schema and migration

Additive; `EnsureProfile` fills it; no migration step. Bump to 20 and note it.

One judgement call to record rather than make silently: an **existing** user
upgrading gets a new bar under their target frame without asking for it. That is
the right default for a feature this useful, and it is consistent with how heal
prediction shipped on (`Defaults.lua:277-284`, "a prediction is only useful in
the second before a heal lands, which is not a moment anyone can reach the
options panel in"). Same argument, same conclusion. Mention it in the release
note.

---

## Tests

- `PLAYER_TARGET_CHANGED` mid-cast abandons the bar rather than finishing the old
  animation — the one behaviour genuinely new in this plan.
- Targeting a caster mid-cast picks the bar up **already in progress**, from
  `UnitCastingInfo` rather than from a start event that already fired. This is
  the path the player bar never exercises and the most likely place for a bug.
- Losing the target hides the bar.
- `Anchoring:Resolve("targetcast")` returns the target frame; it moves with it;
  `anchor.to = "UIParent"` detaches it.
- The stop-event fallback: with every stop event suppressed, a cast whose end
  time has passed still clears the bar on the next driver frame.
- Shipped `enabled` is `true` for `targetcast` and `false` in the `castUnit`
  template.

**Gap this exposes:** no existing test picks an element up *mid-state* — every
element test starts from an event. The mid-cast acquisition case is the pattern
to add, and it applies to auras and heal prediction too.

---

## Risks

| Risk | Handling |
|---|---|
| The stop events do not fire for non-player units | Measured before implementation; fallback designed above and tested with the events suppressed, so the fallback is exercised whichever way the probe falls |
| A rapidly-retargeting player thrashes the driver | Attach/detach is refcounted and idempotent; the driver is one hidden frame regardless of how many bars attach. Assert the count returns to zero |
| Hostile-unit cast times are server-authoritative and can be wrong | True and unfixable, and no worse than Blizzard's own bar, which reads the same API. Not worth engineering around; say so in the README rather than pretending to precision |
| §2.2's amendment is written from this plan rather than from the measurement | The probe run happens first and `COMPAT_FINDINGS.md` is updated from the SavedVariables file, not from expectation |

---

## Estimate

**Small, with a prerequisite.** The code is a Registry entry, a defaults entry
and one `blizzardFrames` line. The probe run and the documentation correction are
most of the calendar time, and neither is difficult — one raid session and one
honest paragraph in `SPEC.md`.

Nearly all of the apparent difficulty of "target cast bars" turns out to be Plan
31's frame work plus a three-week-old measurement nobody applied.
