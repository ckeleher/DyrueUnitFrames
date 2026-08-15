# Plan 22 — Separating Your Heals From Other People's

**Status:** Not started. **Depends on Plan 19** (merged, `ce6e5ec`).
**Created:** 11 August 2026
**Branch:** `Plan-22-own-versus-others`

---

## Origin

One of three items left open when Plan 19 was archived. Plan 19 shows incoming
heals from anyone as a single segment; this would let you see which of it is
yours.

## Request

> all three should get their own plans - two new plans, plus a rewrite of plan 12
> to address absorbs

---

## This revisits a decision that was already made

When Plan 19 was scoped, the question *"should other people's heals look
different from your own?"* was asked and answered **no — merge them**. That
answer was right for Plan 19 and is not being overturned by this plan; it is
being offered as an option.

So the split **ships off**. The default stays exactly what merged.

---

## The blocker, which is a measurement not a design problem

The obvious implementation is one API call:

```lua
mine   = UnitGetIncomingHeals(unit, "player")
theirs = UnitGetIncomingHeals(unit) - mine
```

**That filtered form is unproven on these clients.** From the Plan 19 probe run:
5120 calls, zero failures, and it returned **0 every single time** while the
player cast two heals. A form that silently ignored its second argument would
produce exactly that. The probe reported Q2 as UNPROVEN rather than guessing,
and nothing in Plan 19 depends on it.

Plan 19's conclusion did not rest on the decomposition — magnitude and caster
identity carried it. **This plan's entire feature does.**

### Phase 0 — settle it, before any code

`/dufprobe incoming` already samples both forms in the same instant and already
carries the guard. What it has never had is a run where the player heals enough
for the filtered form to have something to report.

**Run it on a healer, casting several cast-time heals, in a group.** Then read
`maxMine` and `playerHeals` out of SavedVariables:

| Result | Meaning | Which design below |
|---|---|---|
| `maxMine > 0` | The form filters. | **A** — two API calls, done |
| `maxMine == 0` while `playerHeals > 0` | It does not filter | **B**, and B is expensive |
| `playerHeals == 0` | The run measured nothing. Re-run | — |

Instant heals will not do: they land in the frame they are cast and never appear
as incoming. This needs Greater Heal, not Flash of Light.

---

## Design A — the filtered form works

`Systems/HealPrediction:IncomingForGUID` returns a third value:

```
all    = Compat.GetIncomingHeals(unit)
mine   = Compat.GetIncomingHeals(unit, "player")
theirs = max(0, all - mine)
```

`Compat.GetIncomingHeals` already takes the `healer` argument and already
returns nil for "no such API", so **Compat needs no change at all**.

The element gains a third segment between `direct` and `hot`, drawn through the
same `segment()` loop that already sequences them — this is a table entry, not a
reshape, which is the property that geometry was written for.

Roughly a day, most of it options and tests.

## Design B — it does not filter

We can still compute `mine` ourselves: Plan 11's derived machinery does exactly
that, and it is still in the tree as the fallback path.

```
mine   = <Plan 11's derived own-cast prediction>
theirs = max(0, all - mine)
```

**This is materially more expensive than it looks, and the cost is the reason
Design B is not obviously worth taking:**

* **The ten `UNIT_SPELLCAST_*` subscriptions come back.** Plan 19 made them
  conditional precisely because the API made them unnecessary; turning this
  feature on would re-register them. That is a real, measurable cost paid for a
  colour distinction.
* **Plan 11's first-cast limitation returns for you.** A spell you have never
  cast sizes as nothing, so `mine` under-reads and `theirs` over-reads — the
  error lands entirely on the other people's segment, which is the one you would
  be reading to decide whether to cast.
* **Two sources will disagree.** The API's number and our derived one differ in
  rounding and in timing, so `theirs` will flicker at the boundary. Clamping at
  zero stops it going negative; nothing stops it jittering.

**Recommendation if Phase 0 comes back negative: do not build Design B.** Write
the finding into `COMPAT_FINDINGS.md`, close this plan unimplemented, and leave
the merged behaviour alone. A jittering, systematically-biased colour split is
worse than one honest segment, and Plan 19's original answer to this question was
"merge" anyway.

---

## Files

Assuming Design A.

| File | Change |
|---|---|
| `Systems/HealPrediction.lua` | `IncomingForGUID` returns `mine, theirs, hot`; the single-value path stays for callers that do not want the split |
| `Elements/HealPrediction.lua` | A third texture and a third `segment()` call; colour and alpha from config |
| `Core/Defaults.lua` | `healPrediction.separateOwn` (default **false**) and `othersColor` |
| `Config/Options_Layout.lua` | A toggle and one swatch. **Watch the Plan 3 tripwire** — this is the `inline` group that evicted a nested tree once already, and this plan adds rows to it |
| `Tests/tests.lua` | See below |

`Core/Compat.lua` and `Core/Migrate.lua` are untouched.

## Schema and migration

Two added keys, no changed values, **no `SCHEMA_VERSION` bump**.
`Defaults:EnsureProfile` deep-fills them. Shipping the toggle `false` is what
makes it free: no existing profile changes appearance.

## Tests

* `mine + theirs == all`, exactly, for several splits including zero on each side.
* `theirs` clamps at zero when `mine` exceeds `all` rather than going negative.
* With `separateOwn = false` the element draws exactly what it draws today —
  the same texture count and the same widths. This is the assertion that keeps
  the default honest.
* Three segments abut in order and the third clips at the overflow limit like
  the others.
* Pass 5 (no API): the split is unavailable and the element falls back to the
  merged rendering without erroring.

## Risks

| Risk | Handling |
|---|---|
| **Phase 0 says the form does not filter** | Design B exists but is not recommended; the plan closes unimplemented and the finding is recorded |
| **A third segment is visually noisy on a 20px party bar** | Ships off. If it reads badly the answer is the toggle, not a redesign |
| **Rows added to the `inline` options group** | Plan 3's tripwire covers it and will fail the suite if the group grows past its budget |
| **`mine` and `all` are sampled at different instants** | Both come from one function in one call site; read them adjacently and never cache one across an event |

## Estimate

| Piece | Hours |
|---|---|
| Phase 0 probe run + recording the finding | 0.5 |
| Design A implementation | 2–3 |
| Options, defaults, tests | 2 |
| **Total (Design A)** | **4.5–5.5** |

Design B is not estimated because it is not recommended.
