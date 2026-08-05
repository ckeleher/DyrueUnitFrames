# Plan 14 — Auras Do Not Hold A Consistent Order

**Status:** Not started. **Diagnose before implementing.**
**Created:** 4 August 2026
**Branch:** `Plan-14-aura-order`

---

## Request

> 2) the buffs don't keep a consistent order on some condition, they were jumping
> all over in the list. It kinda looked like it only happened after reaching the
> max number of buffs on the target (even when the target then dropped below the
> max number)? Uncertain, investigate first.

---

## Interpretation

Icons swap cells between updates without the underlying auras changing. The
user's two observations are treated as evidence, not as noise:

* it correlates with a **full grid**, and
* it **persists after the grid empties out again**.

The second half is the useful one. A cause that resolves itself when the count
drops is a display bug; a cause that survives is *state that stays permuted*.
That points away from this addon's per-update code and toward something
remembered — either by the client or by the group — and it is what makes
candidate 1 below the leading candidate rather than one of four equals.

---

## Diagnose before designing

### Candidate 1 — the sort's tie-break is the client's slot index, which is not stable

**Leading candidate.** Every sorter ends the same way
(`Elements/Auras.lua:176-193`):

```lua
own_time = function(a, b)
    if a.own ~= b.own then return a.own end
    local ea, eb = expiryKey(a), expiryKey(b)
    if ea ~= eb then return ea < eb end
    return a.index < b.index          -- <- the whole order, in the common case
end
```

`entry.index` is the loop counter from `scan` (`Elements/Auras.lua:359`), which
is the index passed to `C_UnitAuras.GetAuraDataByIndex`
(`Core/Compat.lua:311`). The test suite confirms this is the live path on the
target clients: `check("compat/uses the C_UnitAuras path", …)` at
`Tests/tests.lua:449`.

Two facts combine badly:

1. **The tie-break decides almost everything on a target.** FR-5.8 is not a
   caveat here, it is the norm: Classic reports duration and expiration only for
   auras *you* applied. Everything else arrives as `0`, so `expiryKey` returns
   `INFINITE` for all of it (`Elements/Auras.lua:172`) and the entire block of
   other people's debuffs is ordered by nothing but `index`.
2. **Index is a slot number, not a position.** Behind the `C_UnitAuras` API the
   client holds auras in a slot container. A removal frees a slot and the
   container does not re-pack in application order — later auras land in
   whatever slot is free. Indices therefore permute as auras come and go.

This is the only candidate that explains **both** halves of the observation. The
grid filling up is when there are enough slots for the churn to be obvious, and
once the slot order has been permuted relative to application order **nothing
ever re-packs it** — so it stays scrambled after the count falls. That is
precisely "even when the target then dropped below the max number".

### Candidate 2 — `own` flips, so the aura jumps between blocks

`isOwn` reads `aura.source` (`Elements/Auras.lua:140`), which is
`data.sourceUnit` (`Core/Compat.lua:320`). That is nil when the caster is not a
resolvable unit token. An aura whose `own` flickers moves between the own-first
block and the rest **and** changes size, since own auras render at 1.4×
(`ownSizeMultiplier`). Very visible, and it would look like jumping.

Distinguishable from candidate 1 in one line of probe output: if `own` is stable
per aura across updates, this is out.

### Candidate 3 — `table.sort` is unstable

Lua's sort is a quicksort and is not stable, so equal elements may be reordered.
Ruled out **by inspection**: every comparator terminates in `a.index < b.index`
and indices are unique within a scan, so the comparator is a strict total order
and the output is deterministic for a given input. Worth recording because it
constrains the fix — see "the comparator must stay total" below.

### Candidate 4 — LibClassicDurations returns a duration with no expiration

`Elements/Auras.lua:370-376` accepts `libDuration > 0` and assigns
`expirationTime = libExpiration`, which may be nil. Such an entry has a duration
but sorts as `INFINITE`, landing it in the churning block. Only reachable with
`useClassicDurations` on, which defaults off (`Core/Defaults.lua:617`). Low, but
a one-line hardening regardless.

### Candidate 5 — the grid is exactly full at the observed threshold

Not a cause, but it is why the symptom reads as "max buffs". Target debuffs ship
`maxShown = 16` with `perRow = 8 × rows = 2` (`Core/Defaults.lua:525-526`), and
`updateGroup` clamps to the cell count (`Elements/Auras.lua:563`). At 16 the
grid is exactly full, so beyond that a reshuffle changes **which** auras are
visible, not just where they sit. Same underlying churn, dramatically louder.

### The probe

`/dufprobe auraorder`, added to `Probe/DyrueUnitFrames_Probe/Probe.lua`
alongside the existing traces. On every `UNIT_AURA` for 60 seconds, sample every
`HARMFUL` and `HELPFUL` index on the target and record
`index → auraInstanceID, spellId, sourceUnit, expirationTime`. Report:

1. **Did any still-applied aura change index?** Direct yes/no on candidate 1.
2. **Is `auraInstanceID` populated on 1.15.9 and on 2.5.6?** The fix depends on
   it. `Compat.hasUnitAurasAPI` being true does not prove the field is filled.
3. **Is `auraInstanceID` monotonically increasing with application order?** If
   yes, sorting by it *is* application order and the fix is free. If it is
   stable but arbitrary, the fix still stops the jumping but "consistent order"
   means "unchanging", not "oldest first".
4. **Did `sourceUnit` ever change for a fixed aura?** Candidate 2.

One session, ten minutes. Same discipline as Plan 12: do not write the fix
before the probe has run.

---

## Design — assuming candidate 1 holds

### Sort on a stable identity, not on a slot number

`Compat.GetAura` already reads `auraInstanceID` (`Core/Compat.lua:325`), and
`scan` already copies ten fields onto the pooled entry
(`Elements/Auras.lua:385-394`) — it simply does not copy that one. Adding it is
one line.

```lua
-- Stable for as long as the aura is applied; `index` is not, because the
-- client's slot container reuses freed slots and never re-packs. On the legacy
-- UnitAura path there is no instance ID (Compat.lua:349), so spellId carries
-- it -- stable per spell, and only ambiguous between two applications of the
-- same spell from different casters.
local function orderKey(entry)
    return entry.auraInstanceID or entry.spellId or 0
end
```

The tie-break chain becomes **expiry → orderKey → index**:

```lua
own_time = function(a, b)
    if a.own ~= b.own then return a.own end
    local ea, eb = expiryKey(a), expiryKey(b)
    if ea ~= eb then return ea < eb end
    local ka, kb = orderKey(a), orderKey(b)
    if ka ~= kb then return ka < kb end
    return a.index < b.index
end
```

**The comparator must stay total.** `index` stays as the final fallback for
exactly this reason: two entries with the same `orderKey` and the same expiry
would otherwise compare equal in both directions, and while that is legal for
`table.sort`, an ordering that is *inconsistent* is not — Lua raises "invalid
order function for sorting" outright. Keeping a unique last key makes that
unreachable by construction. The same change applies to `time` and `name`;
`index` mode is left alone deliberately.

### `sort = "index"` keeps its meaning, and gains a warning

The mode is the escape hatch that means "however the game reports them", and
after this change that is explicitly *not* a stable order. Keep the stored key —
no migration — and change the display string to say so, e.g. *"Game order (can
reshuffle)"*. Anyone who wants unchanging order has `own_time`, `time` and
`name`, all three of which now hold.

### Rejected: remembering which cell each aura occupied

The obvious alternative is positional memory — key each aura, remember its cell,
keep it there until it drops. Rejected: it needs an eviction policy, it leaves
holes in the grid when a middle aura falls off, and it quietly overrides the
sort mode the user picked, which is worse than the bug for anyone sorting by
time. A deterministic sort key achieves the same visible result without a second
source of truth about ordering.

### Two things worth fixing in the same pass

* **`sorters.name` disagrees with itself on nil.**
  `if a.name ~= b.name then return (a.name or "") < (b.name or "") end`
  (`Elements/Auras.lua:188-191`) takes the branch for `nil` vs `""` and then
  returns false both ways. Harmless today because it resolves to "equal", but it
  is one refactor away from being the inconsistent comparator described above.
  Coalesce once, compare once.
* **Candidate 4's nil expiration.** Require `libExpiration` before accepting the
  library's answer, so an estimated aura either sorts by time properly or is
  treated as durationless — not given a duration it cannot place.

---

## Files

| File | Change |
|---|---|
| `Elements/Auras.lua` | Copy `auraInstanceID` in `scan`; add `orderKey`; extend the tie-break in `own_time`, `time`, `name`; tighten the `name` nil case; require `libExpiration` at `:373` |
| `Config/Options_Auras.lua` | Sort-mode value text for `index` |
| `Core/Locale.lua` | The changed string |
| `Probe/DyrueUnitFrames_Probe/Probe.lua` | `/dufprobe auraorder` |
| `Tests/wowstub.lua` | `GetAuraDataByIndex` must be able to permute slots and to report `auraInstanceID` — see below |
| `Tests/tests.lua` | `testAuraOrderStability()` |
| `Core/Compat.lua` | Only if the probe shows `auraInstanceID` unpopulated on one client — then a synthesized key |
| `Documents/COMPAT_FINDINGS.md` | What the probe found on 1.15.9 and 2.5.6, with the date and build |

No schema change. No new settings, no changed defaults, no migration.

---

## Tests

### The gap that let this through

`Tests/wowstub.lua:496-503` returns auras straight out of a fixed array:

```lua
GetAuraDataByIndex = function(u, index, filter)
    local list = unit(u).auras[filter]
    return list and list[index] or nil
end,
```

**The stub's index order is perfectly stable, so no test could ever have caught
an unstable one.** The fixture also gives no aura an `auraInstanceID`
(`Tests/tests.lua:59-75`), which is the field the fix turns on. Both have to
change before a regression test is possible, and that stub work is the real cost
of this plan — not the fix, which is a dozen lines.

Add to the stub: `auraInstanceID` on every fixture aura, and
`stub.permuteAuras(unit, filter, order)` to reorder the backing array in place,
modelling exactly what the client does when a slot is freed.

### `testAuraOrderStability()`

* Scan a target with four durationless debuffs; permute the stub's slot order;
  scan again. **The rendered order is unchanged** — asserted on
  `group.buttons[i]`, not only on `group.list`, because the cell an icon sits in
  is what the user actually sees.
* Remove the second aura. The remaining three shift up by one and hold their
  relative order; nothing else moves.
* Refill past `maxShown` and back down, permuting each time. Order still holds —
  the direct regression test for "even when the target then dropped below the
  max number".
* Legacy path: with `auraInstanceID` absent, `spellId` carries the order and it
  is likewise stable across a permutation.
* Mixed: two own auras with real expirations plus two durationless ones. Own
  come first, the timed pair sorts by expiry, the durationless pair holds
  application order.
* `sort = "index"` still tracks the client's order and is *expected* to change
  under a permutation. Keep the existing assertion at `Tests/tests.lua:1444` and
  retitle it so the intent is explicit.
* The `name` sorter with a nil name does not error and produces a total order.

---

## Risks

| Risk | Handling |
|---|---|
| **`auraInstanceID` is not populated on 1.15.9 or 2.5.6** | Probe question 2, answered before any code is written. Fallback is `spellId`, which is stable and fixes the common case; the residual is two casts of one spell from different casters, which then fall back to `index` and can still swap |
| **`auraInstanceID` is stable but not monotonic** | Jumping stops, but the order is arbitrary rather than application order. Probe question 3. If it lands there, an explicit "application order" mode is a follow-up, not this plan |
| **The real cause is candidate 2** | The probe distinguishes them in one line. The fix is different — coalesce a missing `sourceUnit` against the aura's last known source rather than flipping `own` — and this plan would be re-cut around it rather than shipped on a guess |
| **A one-time visible reshuffle on first login** | Real and harmless: the order changes once, to a stable one, and then stops changing. That is the point |
| **Comparator errors under `table.sort`** | `index` stays as a unique final key in every sorter, which makes an inconsistent comparison unreachable. Covered by the nil-name test |
| **Stub changes break unrelated aura tests** | `testAuraFiltering` (`Tests/tests.lua:1389`) reads names and counts, not order, except for the `index` assertion which is kept deliberately. Adding a field and a permute helper is additive |

---

## Estimate

| Piece | Hours |
|---|---|
| `/dufprobe auraorder`, and run it | 0.75 |
| `orderKey` + tie-breaks + the two hardenings | 1.0 |
| Stub: instance IDs and `permuteAuras` | 1.0 |
| `testAuraOrderStability` | 1.5 |
| Options string, locale, COMPAT_FINDINGS | 0.25 |
| **Total** | **~4.5** |

Most of it is the harness. The fix itself is a dozen lines, and it is the test
that stops it regressing that costs the day.
