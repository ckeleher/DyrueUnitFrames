# Plan 8 — Migration Coverage and Flattening

**Status:** Both parts implemented on `Plan-8-migration-coverage`.
**Created:** 2 August 2026
**Branch:** `Plan-8-migration-coverage`
**Priority:** Part 1 is a correctness bug and went first. Part 2 depended on it.

---

## Outcome

**Part 1** found exactly what the plan predicted: three profiles across the two
clients at schemas 10, 7 and 2, including the active one on TBC. The schema-2
profile predated nine of the eleven changes. `Migrate:RunAll` brought all three
current on one login, verified afterwards by reading the saved variables.

One thing the plan did not anticipate: `Migrate:Fail` keyed its backup by
timestamp alone, so two profiles failing in the same second would have collided
and the backup would have lost one of the two things it exists to preserve.
Keyed by profile name as well now, and tested.

**Part 2** collapsed ten steps into one declarative table plus two functions,
gated behind `COLLAPSED_THROUGH = 11`.

The runner change is what makes it work: a profile at or below the collapse
point runs the single step and lands at `COLLAPSED_THROUGH + 1`, while anything
above uses the normal incremental loop. Backward compatibility is therefore
*not* lost — a profile from version 1 still migrates correctly — while the chain
reads as a description of the schema rather than a transcript of an afternoon.

Two design points worth recording:

- **Only two changes needed to stay procedural**, not the three estimated. The
  per-unit conditional default (health color) turned out to be expressible with
  `units` / `exceptUnits` / `when` fields on a rule, leaving only the list
  append and the whole-anchor comparison as code.
- **Absent keys need no rule at all.** Migration runs before `EnsureProfile`, so
  a key that did not exist in the old schema is simply not there and picks up
  the current default afterwards. That is why "arriving from version 1" and
  "arriving from version 9" both land correctly without either being
  special-cased, and it is now asserted directly.

Testing shifted from sampling versions to covering all of them: a
legacy-shaped profile is stamped with each version from 1 to 11 in turn and
asserted to land on current defaults. That is the check that made deleting the
old steps defensible.

Reaching the "no migration path" branch now needs a deliberate gap above the
collapse point, since everything at or below it is handled in one step — the
tests raise the target temporarily to create one.

---

## Request

> is there anything we can do to "Flatten" the migrations we have so far?

---

## Interpretation

Ten migration steps have accumulated (`Core/Migrate.lua`, schema 11), several of
them only because an intermediate value was synced while tuning a default by
eye — steps 7 and 8 move target-of-target left then right, steps 9 and 10 raise
the state indicators to 10 then bring them to 5. Each is correct, each is
tested, and together they read as a transcript of the session rather than as a
description of the schema.

The ask is to collapse that. Investigating whether it is *safe* to collapse
turned up a bug that has to be fixed first.

---

## Part 1 — migrations only run on the active profile

`Core/Core.lua:286`:

```lua
local ok, message = Migrate:Run(ns.db.profile, _G.DyrueUnitFramesDB)
```

`ns.db.profile` is the **active** profile. And `OnProfileChanged` calls
`Defaults:EnsureProfile` but never `Migrate:Run`.

So an inactive profile is never migrated, and switching to one fills in missing
keys while leaving stale *values* untouched. `EnsureProfile` makes it look
complete, which is what makes this quiet.

### This is not hypothetical

Reading the live saved variables:

| Client | Profiles | `schemaVersion` |
|---|---|---|
| Classic Era | 1 | 10 |
| TBC Anniversary | 2 | **2** and 7 |

The schema-2 profile has not been touched since before the flat texture, the
bar-gap removal, the backdrop change, class coloring, brightness, the mana
readout and the portrait move. Switching to it today would silently produce an
addon that looks several hours out of date, with no error and no explanation.

### Fix

Migrate **every** profile at load, not just the active one. AceDB exposes the
raw table as `db.profiles` (`Libs/AceDB-3.0/AceDB-3.0.lua:339`), keyed by
profile name.

```lua
for name, profile in pairs(ns.db.profiles) do
    Migrate:Run(profile, _G.DyrueUnitFramesDB, name)
end
```

Points to get right:

- **Report per profile.** A failure in one must not stop the others, and the
  chat line should name which profile it was.
- **`Migrate:Fail` writes to `db.backup` keyed by timestamp.** Two profiles
  failing in the same second would collide; key by profile name as well.
- **`OnProfileChanged` should still run `Migrate:Run`** as a belt-and-braces
  measure, for a profile created by another character between logins.
- **`EnsureProfile` stays where it is** — it runs on the active profile only,
  which is correct, because filling defaults into a profile nobody has selected
  is pure saved-variable bloat. Migration is different: it has to happen before
  the values are read, and it only touches values that are already there.

This is worth doing on its own merits, and it is what makes Part 2 safe.

---

## Part 2 — flatten the chain

### Why the obvious approaches do not work

| Approach | Why not |
|---|---|
| Delete the steps, keep `SCHEMA_VERSION` | A profile below the target hits "no migration path", which routes to `Migrate:Fail` — backed up, but reset to defaults. Fine only if nothing is behind, which is exactly what the table above disproves |
| Delete the steps, reset version to 1 | Every existing profile is then "newer than this build" and refused outright |
| Collapse into one step, version 2 | Same refusal, for the same reason |

All three founder on the same fact: version numbers are the only record of what
a profile has already had done to it.

### What does work: one declarative step

Every step so far except two is the same shape — *"this key used to default to
X, it now defaults to Y, move it if it is still X"*. That does not need to be
procedural, and it does not need one step per change:

```lua
local LEGACY_DEFAULTS = {
    { path = { "health", "texture" }, old = { "Blizzard" },  new = "Dyrue Flat" },
    { path = { "power", "spacing" },  old = { 1 },           new = 0 },
    { path = { "health", "brightness" }, old = { 1 },        new = 0.8 },
    { path = { "indicators", "y" },   old = { 0, 10 },       new = 5 },
    { path = { "portrait", "placement" }, old = { "inside" }, new = "outside" },
    -- ...
}
```

Each entry lists **every** historical old value for that key, so a single pass
brings a profile up to date from *any* prior version. The undo-pairs disappear
into a list: `{ 0, 10 } → 5` is one line, not two steps that fight.

Properties that matter:

- **Idempotent.** Running it twice changes nothing the second time.
- **Order-independent.** No step depends on a previous one having run.
- **Reads as a description**, not a history: "here is what each default used to
  be", which is the thing a future reader actually wants.

### What stays procedural

Three changes are not "one key, old value to new value" and keep real code:

1. **Appending the shapeshift mana text** (schema 6) — inserts into a
   user-owned list, and has to check for an existing mana-anchored text so it
   cannot duplicate.
2. **Per-unit conditional defaults** (schema 4) — target and focus shipped as
   `reaction` while everything else shipped static green, so "was this the
   default" depends on which unit it is.
3. **Whole-anchor comparisons** (schemas 8 and 9) — five fields have to match
   together, not one key at a time.

So: one declarative table plus three small functions, replacing ten procedural
steps.

### Numbering

Keep the version counter monotonic — do **not** renumber. The collapsed step
becomes `[11]`, `SCHEMA_VERSION` goes to 12, and steps 1–10 are deleted only
once every live profile is at 11 or above, which Part 1 guarantees on the next
login.

That ordering is the whole trick: **Part 1 ships first and is allowed to run
once**, which brings every profile to the current version. Only then is deleting
the old steps safe.

---

## Files

| File | Change |
|---|---|
| `Core/Core.lua` | Migrate every profile at load; migrate on profile switch |
| `Core/Migrate.lua` | Per-profile reporting; backup keyed by name; then the declarative table replacing steps 1–10 |
| `Core/Defaults.lua` | Schema bump |
| `Tests/tests.lua` | See below |

---

## Tests

**Part 1:**

- A db with three profiles at mixed versions migrates all three.
- A profile that fails does not prevent the others migrating.
- Two profiles failing in the same second produce two distinct backup entries.
- Switching to a stale profile migrates it.

**Part 2:**

- A profile at each historical version from 1 to 11 arrives at the current
  defaults. This is the assertion that matters — build them as fixtures from the
  real historical shapes and check the end state, not the path.
- Running the collapsed step twice is a no-op.
- A user-modified value at every listed path survives.
- The three procedural cases keep their existing tests.

---

## Risks

| Risk | Handling |
|---|---|
| Deleting steps strands a profile below 11 | Part 1 ships first and brings every profile current on one login. Only delete afterwards, and verify against the live saved variables again before doing it |
| The declarative table loses a case the procedural steps handled | The version-fixture tests are the check: every historical version must land on current defaults |
| `db.profiles` is not the right AceDB surface | Verified: `AceDB-3.0.lua:339` assigns `db.profiles = sv.profiles` |
| Migrating a profile nobody uses writes to saved variables unnecessarily | Only values that already exist are touched, so a profile with nothing stored gains nothing |

---

## Estimate

Part 1: 1–2 hours including tests.
Part 2: 2–3 hours, most of it building the version fixtures — which are the
point, since they are what allow the old steps to be deleted with confidence.

Worth doing in that order and merging separately, so Part 1 gets a login before
Part 2 removes the safety net.
