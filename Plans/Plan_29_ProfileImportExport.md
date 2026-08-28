# Plan 29 — Profiles Export and Import as Strings

**Status:** Not started.
**Created:** 27 August 2026
**Branch:** `Plan-29-profile-import-export`
**Depends on:** nothing. Branch from `main`.

---

## Request

> i want to make profiles exportable and importable

---

## Interpretation

`SPEC.md` §2.3 and `PLAN.md` §14 both already carry this, under the same name:
**"profile import/export strings"**, v1.x backlog item 3. So the reading is not
in doubt — a profile turns into one line of printable text that can be pasted
into Discord or a forum, and that line turns back into a profile on somebody
else's client.

Three things the phrasing does *not* settle, decided here:

| Question | Taken | Why |
|---|---|---|
| Which scopes travel? | `profile` only. Not `global`, not `char` | `global` is `safeMode` / `debug` / `firstRunDone` — session state, not settings. `char` is Plan 11's learned heal sizes, and `Core/Defaults.lua:838-848` already argues at length that sharing a profile must not carry one character's heal numbers onto another's gear. Both would be actively wrong to ship in a shared string |
| A file, or a string? | A string | The game gives an addon no filesystem. A string in an edit box is the only mechanism, and it is what every addon in the ecosystem does |
| Full profile, or only what differs from defaults? | **Full** | The one genuinely load-bearing decision. Argued below |

### Full profile, not a diff against defaults

A diff is tempting: measured, an untouched profile diffs to nothing and a
customised one to a few hundred bytes, against 4,205 characters for the full
thing. It is still wrong, and the reason is the schema version.

Reconstructing a diff means starting from a base and applying the differences.
The only base available on the importing client is **today's**
`Defaults:BuildProfile()`. If the string was produced by a client on schema 15,
every key the exporter had left at *their* default is absent from the diff and
would silently pick up *our* default instead. `portrait.placement` is the worked
example: it defaulted to `outside` at schema 12 and `column` at 16, so a
schema-12 diff that omits it — because the exporter never touched it — would
import as `column`. `Core/Migrate.lua`'s step 15 would then look at `column`,
see a current value, and correctly leave it alone. The importer ends up with a
layout the exporter never had, with nothing anywhere reporting a problem.

Keeping historical default tables around to diff against would fix it and is a
far worse cost than 4 KB — it is `Migrate.lua`'s collapsed-step problem again,
except that this time nothing may ever be collapsed.

The full profile has none of this. It arrives carrying its own `schemaVersion`,
which is exactly the input `Migrate:Run` was built for, and the import path
becomes the same path a saved variable already takes on login. Every migration
rule in the file works on an imported profile for free, and always will.

---

## What it costs, measured

Everything below is measured, not estimated: the real `LibDeflate` 1.0.2 and
`AceSerializer-3.0` r5 driven against this addon's actual default profile
(1,195 tables, 6,045 leaf values) in the Lua 5.1 interpreter the test harness
already uses.

| Stage | Size |
|---|---|
| `AceSerializer:Serialize(envelope)` | 85,732 bytes |
| `LibDeflate:CompressZlib(payload, { level = 9 })` | 3,148 bytes |
| `LibDeflate:EncodeForPrint(...)` plus the `!DUF:1!` prefix | **4,205 characters** |

Round-tripped back to a table and deep-compared against the original:
**identical**, floats included. The whole string matches
`^!DUF:1![0-9a-zA-Z()]+$` — sixty-four printable ASCII characters and nothing
else, so no `|` for WoW's escape-code parser to eat and no whitespace for a
forum to reflow.

### Compression level: pass 9 explicitly

`CompressDeflate` / `CompressZlib` with no `configs` argument choose a level by
input size, and the rule is **level 3 for anything over 64 KB**. Our payload is
85 KB, so the default is the worst case available:

| Level | Encoded string | Compress time |
|---|---|---|
| default (→ 3) | 7,124 chars | 7.6 ms |
| 5 | 4,873 chars | 15.2 ms |
| **9** | **4,205 chars** | 19.7 ms |

2,900 characters for 12 ms. Level 9, explicitly.

Full export is ~24 ms (serialize 3.8 + compress 19.7); full import ~11 ms.
Reference Lua 5.1 on a desktop rather than WoW's interpreter, so treat these as
the right order of magnitude and not a promise — even a 10× margin leaves an
explicit button press well under a quarter of a second.

### zlib framing, not raw deflate

`CompressDeflate` emits a raw DEFLATE stream with **no integrity check**.
`CompressZlib` wraps it in the 2-byte header and 4-byte Adler-32, and
`DecompressZlib` returns `nil` when that checksum fails
(`LibDeflate.lua:2718-2722`). Measured cost of the difference: **6 bytes, 8
characters** (4,197 → 4,205).

Eight characters to turn "a truncated paste deserializes into something
plausible" into "a truncated paste is refused with a message". Take it.

### How big can it get

The 4,205 figure benefits from fourteen units that are near-copies of each
other, which is what deflate is best at. A deliberately pathological profile —
every single number in the tree perturbed so no two units share a block —
measures **13,924 characters**. A realistically customised profile sits nearer
5–6 KB.

None of these fit in a Discord message (2,000). That is normal for the format
and is why pastebin and Wago exist; it is not something a design decision here
can fix, short of the diff that Interpretation rejects.

---

## Dependencies

Two new embedded libraries. `SPEC.md` §5.10's table gains two rows.

| Library | Version | License | Why |
|---|---|---|---|
| **LibDeflate** | 1.0.2-release (LibStub minor 3) | zlib License | The only piece here that cannot be hand-written. A pure-Lua DEFLATE implementation is 3,605 lines and a spec-conformance problem; the alternative is an 85 KB export string. Single file, no dependencies, used by WeakAuras / Details / Plater / ElvUI |
| **AceSerializer-3.0** | r5 | Ace3 license | Part of Ace3, which §5.10 already justifies wholesale — this adds a *file*, not a dependency. Serializes floats through `frexp`/`ldexp` rather than `%.20g`, so round-trips are exact, and **`Deserialize` is a `gmatch` state machine with no `loadstring` anywhere in it** |

That last clause is the reason not to hand-roll this. Import strings come from
strangers, and the obvious naive serializer — write a Lua table literal, read it
back with `loadstring` — hands arbitrary code execution to whoever wrote the
string. AceSerializer cannot execute anything it reads; a malformed string
produces `false, message` from its own `pcall`, and a maliciously deep one hits
Lua 5.1's C-call limit and is caught by the same `pcall`.

`Libs/LICENSE.md` gains two rows and a zlib License section. Per §11.2 the
license text is to be **read at the point of embedding, not assumed** — the file
header records a GPLv3 → LGPLv3 → zlib relicensing across versions 1.0.0-1.0.2,
so the version pin and the license are one fact rather than two, and the table
entry should say so.

---

## Design

### Module placement

Two new files, matching the existing split between logic in `Core/` and panels
in `Config/`:

* **`Core/Portable.lua`** — `ns.Portable`. Encode, decode, validate, apply. No
  UI, no AceConfig, no frames. Sits beside `Defaults.lua` and `Migrate.lua`
  because it is the third file about the shape of a stored profile.
* **`Config/Options_Profiles.lua`** — the options tab, following
  `Options_Layout` / `Options_Text` / `Options_Auras`.

TOC order: `Core/Portable.lua` after `Core/Migrate.lua` (it calls into it),
`Config/Options_Profiles.lua` after `Config/Options_Auras.lua`.

### The envelope

The profile is not serialized bare. It is wrapped:

```lua
{
    version = 1,               -- envelope format, NOT the schema version
    addon   = ns.version,      -- "1.0.0", informational
    flavor  = Compat.flavor,   -- "tbc" | "vanilla", informational
    name    = "Default",       -- source profile name, the default import target
    profile = <deep copy>,     -- carries its own schemaVersion
}
```

Two reasons for the wrapper. It lets the import panel **show what the string
holds before anything is applied**, which is the difference between a confirm
dialog and a leap of faith. And `version` makes a future envelope change
detectable rather than silently misparsed — the profile's own `schemaVersion`
covers the *contents*, but nothing else would cover the *container*.

`schemaVersion` is deliberately **not** duplicated into the envelope. One
authority per fact; the preview reads `envelope.profile.schemaVersion`.

### Export

```lua
--- @param profileName string|nil  defaults to the active profile
--- @return string
function Portable:Export(profileName)
```

1. Resolve the source table: `ns.db.profiles[profileName]`, or `ns.db.profile`.
2. `local copy = Defaults:EnsureProfile(Defaults:DeepCopy(source))`.
3. Build the envelope, `AceSerializer:Serialize`, `CompressZlib` at level 9,
   `EncodeForPrint`, prefix.

Step 2 is what makes a profile other than the active one safe to export.
`Migrate:RunAll` migrates every profile at load (`Core/Core.lua:289`), but
`EnsureProfile` runs on the **active one alone**, deliberately — so an inactive
profile is up to date but sparse. Filling a *copy* means the string always
carries a complete profile whatever it was taken from, and the live saved
variables are not bloated to achieve it. That is the same reasoning that put the
ensure-only-the-active-profile rule in `Core.lua`, applied to a copy instead of
the original.

### Import

```lua
--- @return table|nil envelope, string|nil message
function Portable:Decode(text)
```

Six gates, cheapest first, each with its own message:

1. Strip **all** whitespace anywhere in the string. The alphabet contains none,
   so this cannot destroy information, and it forgives a forum that reflowed the
   paste into lines.
2. `text:match("^!DUF:1!([0-9a-zA-Z()]+)$")` — nil gets *"That does not look
   like a Dyrue Unit Frames export string."* A WeakAuras `!WA:2!…` string dies
   here, which is the common wrong-string case.
3. Length cap, **32 KB**, checked before anything is decompressed. Arithmetic in
   Risks.
4. `LibDeflate:DecodeForPrint` → nil on any character outside the alphabet.
5. `LibDeflate:DecompressZlib` → nil on a bad header or a failed Adler-32.
6. `AceSerializer:Deserialize` → `false, message`. Then shape checks:
   `type(envelope) == "table"`, `envelope.version == 1`,
   `type(envelope.profile) == "table"`, `type(envelope.profile.units) ==
   "table"`, and `schemaVersion` a number.

Gates 4-6 all collapse to one user-facing line — *"That string is damaged or
incomplete. Ask for it again."* — because the distinction between them is not
actionable by the person reading it. `Errors:Debug` gets the specific reason.

```lua
--- @return boolean ok, string|nil message
function Portable:Apply(envelope, targetName)
```

**Migrate on a copy, commit only on success.** This is the part that must not be
got wrong:

```lua
local work = envelope.profile            -- already ours; Deserialize built it
local ok, message = Migrate:Run(work, nil, targetName)
if not ok then return false, message end -- nothing has been touched yet
Defaults:EnsureProfile(work)
```

`Migrate:Run` is being asked to do exactly what it does on login, and both of
its failure modes are already right for this. A schema *newer* than ours returns
`false` with the "upgrade the addon" message and does not touch the table
(`Migrate.lua:571-577`) — that is a v1.1 user's string arriving at a v1.0
client, and it is the failure this feature will actually produce in the wild. A
step that *throws* routes through `Migrate:Fail`, and because `work` is our own
copy the live profile is untouched whatever `Fail` does to it.

`db = nil` is passed so `Fail` writes no backup — there is nothing worth
preserving in a string the user still has. See the one-line amendment to
`Migrate:Fail` under Files: its message currently ends with "Your previous
settings have been kept in `DyrueUnitFramesDB.backup`", which is already untrue
whenever `db` is nil and would read as a lie here. Make that sentence
conditional on `db`.

Commit, once migration and ensure have both passed:

```lua
if targetName ~= ns.db:GetCurrentProfile() then
    ns.db:SetProfile(targetName)         -- creates it if new; fires OnProfileChanged
end
local live = ns.db.profile
for k in pairs(live) do live[k] = nil end
for k, v in pairs(work) do live[k] = v end
addon:OnProfileChanged()                 -- migrate (no-op), ensure, refresh, notify
```

That last line is the whole apply step, and it is why this plan is small.
`OnProfileChanged` (`Core/Core.lua:356-369`) already re-runs `Migrate`, re-runs
`EnsureProfile`, resets the error threshold, reapplies the focus override, calls
`RefreshAll` — which queues every frame through `CombatQueue`, so **import works
in combat** with no gate of its own — reapplies the Blizzard-frame setting, and
notifies AceConfig. `addon:OnProfileReset` (`:371-374`) is the same wipe-then-
`OnProfileChanged` shape, so this is an established pattern in the file rather
than a new one.

Import always switches to the target profile. Importing into a profile you are
not looking at, then wondering why nothing changed, is a worse failure than one
extra profile switch — which is one click to undo.

### The options tab

A new top-level group, `Import / Export`, at **order 91** — immediately after
AceDBOptions' Profiles tab at 90, which is where someone looking for this will
look. It is a sibling rather than args injected into the library's table, so
nothing depends on AceDBOptions' internal order numbering.

Everything on it is already-used AceConfig vocabulary; `Options_Auras.lua:321`
shows `type = "input", multiline = N, width = "full"` working in this codebase
today, so no AceGUI dialog code is needed.

**Export half**

* `select` — which profile, from `ns.db:GetProfiles()`, defaulting to the
  active one.
* `input`, `multiline = 12`, `width = "full"` — `get` returns the cached string,
  `set` is a no-op. A `description` above it says to click in the box and press
  Ctrl+A then Ctrl+C, because AceGUI does not select the contents for you.
* The cache is keyed on `{ name, ns.configSerial }`. `ns.configSerial`
  (`Core/Core.lua:97-101`) is already bumped on every configuration change, so
  the string regenerates when — and only when — something changed. Without this
  the 24 ms encode runs on every `NotifyChange`, and the combat-queue listener
  at `Options.lua:619` fires those in combat.

**Import half**

* `input`, `multiline = 12` — on Accept, run `Portable:Decode`. Store the
  envelope in module state; **apply nothing**.
* `description` — the preview, `hidden` until a string decodes. Source profile
  name, addon version, client flavour, schema version and whether it will be
  migrated, and the unit count. A schema newer than ours says so here, in
  yellow, before the button is ever pressed.
* `input` — target profile name, pre-filled from `envelope.name`.
* `execute` "Import" — `disabled` until an envelope is decoded, `confirm = true`
  with a `confirmText` naming the target profile and saying it will be
  overwritten. `resetAll` at `Options.lua:566` is the precedent for the wording.

### Slash commands

`/duf export` and `/duf import` open the options panel on this tab
(`AceConfigDialog:SelectGroup(ADDON, "portable")` then `:Open`). Printing a
4,205-character string into the chat frame is not a usable export, so the slash
commands route to the panel rather than pretending otherwise. Two lines each in
`SlashCommand`, plus two lines in the help block at `Core.lua:533-552`.

---

## Files

| File | Change |
|---|---|
| `Libs/LibDeflate/LibDeflate.lua` | **New.** Upstream 1.0.2-release, unmodified |
| `Libs/AceSerializer-3.0/AceSerializer-3.0.lua` | **New.** Upstream r5, unmodified |
| `Libs/Libs.xml` | Two lines. AceSerializer after AceDB, LibDeflate last — it depends on nothing |
| `Libs/LICENSE.md` | Two rows in the version table; a zlib License section; note the relicensing history that ties LibDeflate's license to its version pin |
| `Core/Portable.lua` | **New.** `Export`, `Decode`, `Apply`, and the prefix / cap constants |
| `Core/Migrate.lua` | `Migrate:Fail` (`:619-638`): make the "kept in `DyrueUnitFramesDB.backup`" sentence conditional on `db` being non-nil |
| `Config/Options_Profiles.lua` | **New.** The tab, and the export-string cache |
| `Config/Options.lua` | `Options:Build` (`:596-618`): register the new group at order 91 |
| `Core/Core.lua` | `SlashCommand`: `export` and `import`; two lines in the help block |
| `DyrueUnitFrames.toc` | `Core/Portable.lua`, `Config/Options_Profiles.lua` |
| `Tests/run_tests.py` | `build()` loads the two real libraries before the addon files |
| `Tests/tests.lua` | New `portable` block; see below |
| `Documents/SPEC.md` | §2.3: strike "profile import/export strings" from the deferred list, as Plan 11 struck heal prediction from §2.2. §5.1: the two new files. §5.10: two rows |
| `Documents/PLAN.md` | §14: strike backlog item 3 |

`Documents/COMPAT_FINDINGS.md` needs no entry — no SPEC rule is being broken,
and nothing here rests on an API whose behaviour is in doubt.

---

## Schema and migration

**Neither.** `SCHEMA_VERSION` stays at 17. This feature reads and writes
profiles; it does not change what one contains. Nothing in `Core/Defaults.lua`
moves.

The envelope's `version = 1` is a separate, new number with its own meaning, and
it starts at 1 rather than borrowing the schema's 17 precisely so the two are
never confused. It changes only if the *container* changes — a different
compressor, a different prefix, a new envelope field the reader must understand
rather than ignore.

**One rule this creates for future migration steps**, worth writing into
`Migrate.lua`'s header: a step may change a key's *value*, but changing a key's
*type* now also breaks every export string produced before it, because
`Migrate:Run` on an imported profile is the only thing standing between an old
string and today's schema. No step in schemas 1-17 does this, and none should.

---

## Tests

A new `portable` block in `Tests/tests.lua`, registered alongside the existing
suites.

### Harness change first

`Tests/run_tests.py` skips `.xml` lines from the TOC, so **no real library is
loaded today** — `wowstub.lua:840-846` says so outright and stubs LibStub with
hand-written stand-ins. A round-trip test against a stubbed codec would assert
nothing.

So `build()` gains an explicit list of real library files, loaded before the
addon: `Libs/AceSerializer-3.0/AceSerializer-3.0.lua` and
`Libs/LibDeflate/LibDeflate.lua`. Both are pure Lua that touch no WoW API — the
reason the rest of Ace3 is stubbed ("would drag in the whole AceGUI widget
tree") does not apply to either. They register through the existing LibStub
stub's `NewLibrary` / `GetLibrary` without modification, and with LibStub
present LibDeflate does not write `_G.LibDeflate`, so the existing global-leak
test stays green — **which is itself worth asserting**, since that is the one
way this change could quietly break an unrelated test.

### Assertions

**Round trip**

* Export the default profile, decode it, deep-compare against
  `Defaults:EnsureProfile(Defaults:BuildProfile())`. Equal, floats included.
* Mutate first, then round-trip: move an anchor, change a colour, **delete a
  text element and delete a colour rule**, then export and import. The two
  deletions are the point — they are the property `Core/Defaults.lua`'s header
  gave up AceDB's metatable defaults to get, and an import that resurrects a
  deleted text element has silently reintroduced exactly that bug.
* The exported string matches `^!DUF:1![0-9a-zA-Z()]+$`. This is what makes it
  paste-safe, and it is one line.

**Rejection, each with the live profile asserted unchanged afterwards**

| Input | Expected |
|---|---|
| `""` and `"garbage"` | nil, prefix message |
| `"!WA:2!abcdef"` | nil, prefix message |
| A valid string with one body character flipped | nil, damaged message — the Adler-32 earning its 8 characters |
| A valid string truncated to half its length | nil, damaged message |
| A string over the 32 KB cap | nil, size message, and **`DecompressZlib` never called** — assert via a counter, since a cap that runs after decompression is worthless |
| An envelope with `version = 2` | nil, envelope message |
| An envelope whose `profile` is a string | nil, shape message |
| An envelope with `schemaVersion = 999` | `Apply` returns false with `Migrate`'s own downgrade-refusal message |

**Migration on import**

* Hand-build a schema-12-shaped profile, wrap it, encode it, import it. Lands on
  `schemaVersion == 17`, and spot-check two values that a step between 12 and 17
  actually moves — `target.auras.buffs.y == 14` (step 12) and a text element
  carrying `maxWidthMode` (step 14). This asserts the claim the whole
  full-profile decision rests on: that an old string imports as the layout its
  author had.

**Apply**

* Import into the current profile: the live table is replaced in place —
  `ns:Profile()` is the *same table reference* afterwards, since AceDB holds
  that reference and a swap would strand it.
* Import into a new name: the profile appears in `ns.db.profiles` and becomes
  current.
* `ns.db.global` and `ns.db.char` are untouched by an import. `char.heals`
  specifically, because that is the one an export would be actively wrong to
  carry.

**Options tab**

* The tab is well-formed under the existing options-tree checks.
* The export cache: `get` twice with no change between returns the identical
  string and calls `Serialize` once — a counter again. Then `ns:BumpSerial()`
  and assert it regenerates.

### Control run

Run the suite before touching `tests.lua`, with only the harness change in
place, to confirm that loading two real libraries disturbs nothing:

```bash
python Tests/run_tests.py
```

Then the static checks, which have not seen a `Libs/` file before:

```bash
python Tests/luacheck.py .
```

---

## Risks

| Risk | Handling |
|---|---|
| **A decompression bomb.** DEFLATE's maximum ratio is 1032:1 and LibDeflate offers no output cap, so a small hostile string can expand without bound | The 32 KB input cap, checked before `DecompressZlib` is called, bounds the output at ~33 MB — a hitch, not a crash. The cap is 7.6× the real 4,205-character string and 2.3× the pathological 13,924. Asserted in the tests to run *before* decompression, because a cap in the wrong order is decoration |
| **A crafted profile with a string where a number belongs** | Not deep-validated, deliberately. `SPEC.md` §5.9's circuit breaker is the containment mechanism for exactly this: the element errors five times, is disabled for the session, one chat line names it. Building a second, parallel type-checker over a 1,195-table schema to pre-empt a case the architecture already contains is not worth its maintenance. The gates that *are* cheap — envelope shape, `units` a table, `schemaVersion` a number — are checked |
| **Arbitrary code execution from a pasted string** | Structurally impossible: `AceSerializer:Deserialize` contains no `loadstring`, no `load`, and no `pcall` of user data — it is a `gmatch` over a fixed grammar. This is the reason for the dependency and belongs in `Portable.lua`'s header, so nobody later "simplifies" it into a table literal |
| **The user's own profile is destroyed by a failed import** | The migrate-on-a-copy order above. `Migrate:Run` sees `work`, never the live table, and `Apply` returns before the commit loop on any failure. Tested by asserting the live profile is unchanged after each of the eight rejection cases |
| **`Migrate:Fail`'s backup message is a lie on this path** | The one-line amendment in Files, making the sentence conditional on `db`. It is already conditional in fact — `Fail` writes no backup when `db` is nil — so this makes an existing function honest rather than special-casing import |
| **A v1.1 string arrives at a v1.0 client** | The realistic failure once this ships. `Migrate:Run` already refuses to downgrade and returns a message naming both versions; the import preview shows the schema version *before* the button is pressed, so it is visible rather than discovered |
| **24 ms of encode on every options refresh** | The `configSerial` cache. Without it the combat-queue listener at `Options.lua:619` calls `NotifyChange` while the panel is open in combat, and `get` would re-encode each time |
| **The export string outgrows the edit box** | AceGUI's MultiLineEditBox sets `SetMaxLetters(0)` on acquire (`AceGUIWidget-MultiLineEditBox.lua:181`), so there is no limit to hit. 4,205 characters is unremarkable for the widget |
| **Embedding a library the project has not embedded before** | §11.2's rules apply unchanged: version-pinned, unmodified, license text read at embedding and recorded. LibDeflate's GPLv3 → LGPLv3 → zlib history makes the version pin and the license one fact rather than two, and the table entry says so |
| **The two libraries are loaded in tests but stubbed nowhere** | They are pure Lua and self-contained. The control run above exists to prove it before any new assertion is written |

---

## Deferred

**Sharing anything but a whole profile.** Exporting one unit's layout, or one
aura group's filters, is a different feature with a different envelope and its
own ambiguity about what an anchor to another frame means when that frame is not
in the string. `Options.lua`'s existing copy-between-units tool covers the
within-client half of that want.

**A string short enough for Discord.** Only the diff approach gets there, and
Interpretation rejects it on correctness. If it ever becomes the priority, the
honest version is a diff plus a *pinned copy of every historical default table*
to diff against — a real cost, stated here so nobody re-derives the
cheap-looking version.

**Import over the addon comm channel**, so a party member can push a profile
directly. `LibDeflate:EncodeForWoWAddonChannel` exists for it and the envelope
would not change. Nobody asked; it needs a trust model that a paste does not.

---

## Estimate

| Piece | Hours |
|---|---|
| Embed and license the two libraries | 0.5 |
| `Core/Portable.lua` | 1.5 |
| `Config/Options_Profiles.lua` | 1.5 |
| `Migrate:Fail` amendment, slash commands, TOC | 0.25 |
| Harness change and the control run | 0.5 |
| Test block | 2.0 |
| SPEC / PLAN / LICENSE documentation | 0.5 |
| Verify in game, including a real paste between two clients | 0.5 |
| **Total** | **~7** |
