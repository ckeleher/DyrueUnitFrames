# Dyrue Unit Frames — Specification

**Name:** Dyrue Unit Frames — addon folder and TOC `DyrueUnitFrames`, slash command `/duf` (long form `/dyrueunitframes`).
**Status:** Draft v0.1 — pre-implementation
**Target clients:** WoW Classic Era / Hardcore (1.15.9, Interface `11509`) and Burning Crusade Classic Anniversary (2.5.6, Interface `20506`)
**Date:** 2 August 2026

---

## 1. Background and motivation

### 1.1 What broke

Two patches in July 2026 pulled the Classic clients onto modern (Midnight-era) shared UI code:

| Client | Patch | Date | Change |
|---|---|---|---|
| TBC Classic Anniversary | 2.5.6 (TOC `20506`) | 7 Jul 2026 | Edit Mode added; nameplates and raid frames replaced with the Midnight versions |
| Classic Era / Hardcore / SoD | 1.15.9 (TOC `11509`) | 21 Jul 2026 | Same changes; Blizzard states the 1.15.9 addon API "very closely matches" 2.5.6 |

Blizzard's own guidance was that addon authors should target 2.5.6 as the reference environment for 1.15.9. In practice this means **one codebase can serve both clients**, which is a significant simplification.

Shadowed Unit Frames is not the right base to patch forward:

- The author has publicly stated SUF will **not** be updated for the Midnight API direction.
- SUF is licensed **All Rights Reserved**. We cannot copy, adapt, or vendor its source. This project is clean-room: we may replicate *behaviour and UX ideas* (which are not copyrightable), but not code.
- SUF carries ~15 years of retail-first architecture and a Lua-eval tag system that is a persistent source of errors and maintenance load.

### 1.2 Why a rewrite is likely to be *more* stable, not less

The July breakage was overwhelmingly caused by addons **touching Blizzard's own UI internals** — hooking `CompactUnitFrame`, reskinning nameplates, reusing Blizzard templates, or assuming frames exist that Edit Mode now owns. Addons that build their own widgets from primitives (`CreateFrame`, `StatusBar`, `FontString`, `Texture`) were largely unaffected, because those primitives have not meaningfully changed since 2004.

**Core architectural thesis: containment.** Every point of contact with Blizzard's UI lives in exactly one module (`Core/Compat.lua`). Everything else is ours. When Blizzard ships the next shared-code update, the blast radius is one file we can read in a single sitting.

### 1.3 Critical scoping fact — Secret Values do not apply in Classic

Midnight (retail 12.0) introduced **Secret Values**: `UnitHealth()` and friends return opaque values that addon code may store and pass to widgets but may not compare, format, or branch on. If that applied here, requirement §5 (color-coded numeric text with thresholds) would be *impossible*.

It does not apply. Blizzard's 12.0.7 API notes state explicitly that secret-value concepts "don't apply" in Classic, and that same round of changes actively *removed* several Classic restrictions (unit-token restrictions from tainted code, minimap pings, macro-initiated chat).

**Consequence:** we can freely read health/power, compute percentages, compare against thresholds, format strings, and choose colors. The full feature set requested is achievable.

**Residual risk:** Blizzard said they will "continue to refine" Classic's UI. If Secret Values are ever backported, the text engine degrades but bars survive. The architecture in §8.4 accounts for this.

---

## 2. Goals and non-goals

### 2.1 Goals (v1.0)

1. Replace SUF's day-to-day functionality for a solo/small-group Classic and TBC player.
2. Precise, low-friction layout editing: slider **and** exact numeric entry for every position and size value.
3. A druid mana bar that persists through bear/cat form.
4. Fully customizable numeric text with user-defined color rules.
5. Class-colored and reaction-colored health bars, with green as the default.
6. Target buffs and debuffs, anchored flexibly, with player-sourced auras visually distinguished.
7. Party frames with the same element set and configurability as the solo frames.
8. Target-of-target and, on TBC, focus and focus-target frames.
9. Optional portraits in 2D or 3D.
10. Survive a Blizzard patch with, at worst, a one-file fix.

### 2.2 Non-goals (explicitly out of scope for v1.0)

| Excluded | Reason |
|---|---|
| Raid frames (`raid1-40`) | Highest-churn Blizzard area post-2.5.6; would require a secure group header (§5.4), which the party-frame design deliberately avoids; Blizzard's own raid frames now have Edit Mode support |
| Cast bars for units other than the player | Classic clients do not broadcast `UNIT_SPELLCAST_*` for other units; only guesswork is possible |
| Arena and battleground frames | Meaningful only for a use case not stated; deferrable |
| Nameplates | Separate problem domain; Blizzard's new nameplate options cover much of it |
| Combat text, threat meters | Out of domain |
| ~~Incoming-heal prediction~~ | **Amended by Plan 11 (3 August 2026) — built.** It was filed here with the other-addon-domain exclusions, and it belongs with the cannot-be-supported ones: it is a property of a health bar rather than a separate display, and the only thing making it look foreign was the absent API. Derived instead, at the cost of one new module and no new dependency, ticker or Blizzard frame contact. See §2.3 and `Documents/COMPAT_FINDINGS.md` |
| Retail (Mainline) support | Would require a Secret Values–safe parallel implementation; roughly doubles the work |
| Lua-scriptable tags | Deliberate: declarative rules instead (see §4.3.3) |

### 2.3 Deferred to v1.x (designed for, not built)

Player cast bar, profile import/export strings, aura filter presets, further derived units (`pettarget`, `targettargettarget`).

**Absorb shield indication** (Plan 12). Split from Plan 11 deliberately: heal prediction is a number the game will shortly make true, whereas nothing on these clients ever reports how much of a shield is left, so the accuracy ceiling and the failure mode are both worse. The color slot and the segment loop it needs are already built.

---

## 3. Supported units

| Unit token | Client | Phase | Notes |
|---|---|---|---|
| `player` | Both | v1.0 | Includes shapeshift mana bar |
| `target` | Both | v1.0 | Primary aura display host |
| `targettarget` | Both | v1.0 | **Derived unit** — no reliable unit events, requires polling (§4.8) |
| `pet` | Both | v1.0 | Happiness indicator is TBC/Classic-specific — **shipped, Plan 24**: three states in the indicator row (§FR-8.8), gated on `Compat.hasPetHappiness` and on the pet being a *hunter* pet |
| `party1-4` | Both | **v1.0** | Static secure buttons, not a group header — see §5.4 |
| `partypet1-4` | Both | **v1.0** | Same pattern; **default disabled** |
| `focus` | TBC only | **v1.0** | Does not exist in Classic Era; feature-gated on `Compat.hasFocus`, never version-gated by hardcode |
| `focustarget` | TBC only | **v1.0** | Derived unit *and* focus-gated — both constraints apply (§4.8) |
| `raid1-40` | Both | Not planned | See §2.2 — this is the hard boundary |

---

## 4. Functional requirements

### 4.1 Layout: position and size

**FR-1.1** Every frame exposes `x`, `y`, `width`, `height` as independently editable values.

**FR-1.2** Each value is editable by **both** a slider and a text field accepting an exact number. The AceConfig `range` control provides this natively; `softMin`/`softMax` bound the slider while allowing out-of-range values to be typed.

| Value | Slider range | Typed range | Step |
|---|---|---|---|
| X offset | −2000 … 2000 | unbounded | 1 (0.5 with fine mode) |
| Y offset | −2000 … 2000 | unbounded | 1 |
| Width | 40 … 500 | 10 … 2000 | 1 |
| Height | 10 … 300 | 5 … 1000 | 1 |
| Scale | 0.5 … 2.0 | 0.25 … 4.0 | 0.01 |

**FR-1.3** Width and height are independent. No aspect-ratio linkage, no "size" master slider.

**FR-1.4** Alternative input methods, all writing to the same stored values:
- **Drag mode** (`/duf move`): unlocks frames for mouse dragging; optional grid snap (configurable grid, default 8px).
- **Arrow-key nudge** while a frame is selected in drag mode: 1px, Shift+arrow 10px.
- Typed values and slider values are always in sync; changing one updates the other live.

**FR-1.5 Anchoring.** Each frame stores:
- `anchorTo` — `"UIParent"` or another DyrueUnitFrames frame's key
- `anchorPoint` — the point *on this frame* (e.g. `TOPLEFT`)
- `relativePoint` — the point *on the anchor target*
- `x`, `y` — offsets from that pairing

Moving a parent frame moves its children, preserving relative spacing. Circular anchor chains must be detected and rejected at config time with a clear message.

**FR-1.6 Combat deferral.** Position, size, scale, and visibility changes are protected operations. When `InCombatLockdown()` is true, changes are written to the database immediately (so the UI reflects intent) and the *visual* application is queued until `PLAYER_REGEN_ENABLED`. The config UI must show a non-blocking notice: "Layout changes apply when you leave combat." No errors, no silent failure.

**FR-1.7** Positions are stored per profile, in absolute UI units, independent of `UIParent` scale. Frames must land in the same visual place across resolution changes where mathematically possible.

---

### 4.2 Shapeshift mana bar

**FR-2.1** When the player's displayed power type is not mana, but the player *has* a mana pool, an additional bar showing mana is available.

This is deliberately specified as a **general rule**, not "if class == DRUID". The condition is:

```
UnitPowerType("player") ~= MANA  and  UnitPowerMax("player", MANA) > 0
```

In practice this fires for druids in Bear, Dire Bear, and Cat form (Rage/Energy displayed, mana pool retained) and for no one else in Classic/TBC. Writing it generically means no class table to maintain and no breakage if Blizzard adjusts a form.

**FR-2.2** The bar is a first-class element with its own settings: enable/disable, height, width (default: inherit frame width), anchor and offset, texture, color, background alpha, and its own text elements (so `[mana:cur]`, `[mana:perc]` can be shown on it).

**FR-2.3** Appearance and disappearance must not cause layout jump. Two modes:
- **Reserve space** (default off): frame height accounts for the bar whether or not it is shown.
- **Overlay/append** (default on): other elements shift; frame grows.

**FR-2.4** Data source: `UnitPower("player", MANA)` and `UnitPowerMax("player", MANA)`, where `MANA` is resolved once at load as `Enum.PowerType.Mana` with a literal `0` fallback.

**FR-2.5 Known quirk — update reliability.** Historically, `UNIT_POWER_UPDATE` for the mana type has not fired reliably while the player is shapeshifted. Mitigation:
- Primary: event-driven (`UNIT_POWER_UPDATE`, `UNIT_MAXPOWER`, `UNIT_DISPLAYPOWER`, `UPDATE_SHAPESHIFT_FORM`).
- Fallback: a 0.2s ticker that runs **only while the bar is visible** and is cancelled the moment it hides. Bounded cost, no idle overhead.
- Phase 0 must measure whether the fallback is actually needed on 2.5.6/1.15.9; if events fire correctly, the ticker becomes an opt-in setting rather than default-on.

---

### 4.3 Text and color rules

#### 4.3.1 Text elements

**FR-3.1** Each frame supports an arbitrary number of text elements (practical default: 4 — left, right, centre, and one free). Each element has:

| Property | Notes |
|---|---|
| `format` | Tag string, e.g. `[hp:cur] / [hp:max]` |
| `anchorTo` | Frame, health bar, power bar, or shapeshift mana bar |
| `anchorPoint`, `x`, `y` | Standard anchoring |
| `font`, `size`, `outline` | Fonts sourced via LibSharedMedia-3.0 |
| `justify`, `maxWidth` | Truncation behaviour |
| `colorMode` | `static` \| `rules` \| `class` \| `reaction` \| `difficulty` \| `gradient` |
| `color` | Static colour, used when `colorMode == "static"` or as rule fallback |
| `rules` | Ordered rule list (see §4.3.3) |

#### 4.3.2 Tag vocabulary

Tags are declarative tokens replaced at render time. No `loadstring`, no user Lua.

**Identity**
`[name]`, `[name:short:N]`, `[class]`, `[race]`, `[guild]`, `[level]`, `[classification]`, `[shortclassification]`

**Health**
`[hp:cur]`, `[hp:max]`, `[hp:perc]`, `[hp:deficit]`, `[hp:cur:short]`, `[hp:max:short]`

**Power (displayed power type)**
`[pp:cur]`, `[pp:max]`, `[pp:perc]`, `[pp:deficit]`, `[pp:type]`

**True mana (regardless of displayed type)**
`[mana:cur]`, `[mana:max]`, `[mana:perc]`

**Status**
`[status]` (Dead / Ghost / Offline), `[afk]`, `[dnd]`, `[pvp]`, `[leader]`, `[raidtarget]`, `[happiness]` (pet)

**Formatting behaviour:**
- `:short` abbreviates: `1234` → `1.2k`, `1234567` → `1.2m`. Threshold and decimal count configurable globally.
- Percent values render without a `%` sign unless the user types one in the format string.
- **Empty-tag collapse:** if a tag resolves to nothing, adjacent literal separators are removed. `[hp:cur] / [hp:max]` on a unit with unknown health renders as `100` (percent-only), not `100 / `. This is a small feature that removes a large class of ugly edge cases.

#### 4.3.3 Color rule engine

**FR-3.2** When `colorMode == "rules"`, the element evaluates an **ordered list**; the first matching rule wins; if none match, `color` (the static fallback) applies.

Rule shape:

```lua
{
  enabled = true,
  metric  = "health.percent",   -- what to test
  op      = "<=",               -- < <= > >= == ~=
  value   = 35,
  color   = { r = 1, g = 0.5, b = 0 },
}
```

**Available metrics:** `health.current`, `health.max`, `health.percent`, `health.deficit`, `power.current`, `power.percent`, `power.deficit`, `mana.current`, `mana.percent`, `level.value`, `level.difference`, `unit.isDead`, `unit.isOffline`, `unit.isPlayer`, `unit.reaction`.

**FR-3.3** The metric being *tested* is independent of the element being *colored*. Colouring a unit's name red when its health drops below 20% is a valid, first-class configuration — not a special case.

**FR-3.4** Both threshold modes required by the brief are supported natively: `health.percent <= 35` (percentage) and `health.current <= 500` (absolute).

**FR-3.5** A `gradient` colorMode interpolates smoothly across up to three user-defined stops (default green → yellow → red) keyed to health percent. This is offered alongside rules, not instead of them.

**FR-3.6** The config UI for rules must support add, remove, reorder (up/down), enable/disable, and duplicate. Rule sets must be copyable between elements and between units — this is the difference between "configurable" and "actually usable".

#### 4.3.4 Level colouring

**FR-3.7** By default, `[level]` uses `difficulty` colorMode, which calls the game's own `GetCreatureDifficultyColor(level)`. This is not a reimplementation of the base game's thresholds — it *is* the base game's function, so grey/green/yellow/orange/red match exactly and stay matched if Blizzard ever tweaks them.

**FR-3.8** Unknown-level units (`UnitLevel(unit)` returns `-1`) render as `??` in the boss colour, optionally with the skull classification marker.

**FR-3.9** `[classification]` renders Elite / Rare / Rare Elite / Boss; `[shortclassification]` renders `+` / `r` / `r+` / `??`.

**FR-3.10** A user override is available: `difficulty` colorMode may be replaced with an explicit rule set keyed on `level.difference` for anyone who wants non-standard thresholds.

---

### 4.4 Bar colouring

**FR-4.1** Health bar `colorMode`, per unit:

| Mode | Behaviour |
|---|---|
| `static` | Single user-chosen colour. **Default: green** (`0, 0.9, 0.1`) |
| `class` | `RAID_CLASS_COLORS[classFile]` for players; falls back to `reaction` for NPCs |
| `reaction` | Hostile red / neutral yellow / friendly green via `UnitReaction` |
| `gradient` | Interpolated by health percent |

**FR-4.2** Class colouring is opt-in per unit. Enabling it on `target` but not `player` (or vice versa) must be possible — the brief explicitly calls for both to be independently controllable.

**FR-4.3** Class colours are read from `CUSTOM_CLASS_COLORS` when present (the community class-colour addon), otherwise `RAID_CLASS_COLORS`. Always key off the **locale-independent** `classFile` from `select(2, UnitClass(unit))`, never the localized name.

**FR-4.4** Class colour applies only when `UnitIsPlayer(unit)` is true. NPCs fall through to the configured fallback (default: reaction colour). Silently colouring a mob "mage blue" because of a class-token collision is a bug, not a feature.

**FR-4.5** Independently configurable: bar texture (LibSharedMedia), background colour and alpha, border, and an "inverse fill" option (bar depletes from the opposite side).

**FR-4.6** Power bars colour by power type using the game's `PowerBarColor` table by default, with per-type user overrides (mana blue, rage red, energy yellow, focus orange, happiness).

**FR-4.7 Classic health data caveat.** For units outside your group, Classic and TBC report health on a 0–100 scale with `UnitHealthMax` returning `100`. Absolute health numbers for enemies are therefore *not real*. DyrueUnitFrames must detect this (`UnitHealthMax(unit) == 100 and not UnitIsUnit(unit, "player") and not UnitPlayerOrPetInParty(unit)`) and:
- render `[hp:cur]`/`[hp:max]` as empty (triggering separator collapse), and
- surface a one-line explanation in the config UI next to the target frame's text settings.

Showing "100/100" for a full-health raid boss is worse than showing nothing.

---

### 4.5 Buffs and debuffs

**FR-5.1** Buff and debuff display is supported on all v1.0 units, with `target` as the primary case.

**FR-5.2** Buffs and debuffs are **separate, independently configurable groups**. Each group has:

| Setting | Default |
|---|---|
| Enabled | Buffs: on (target), Debuffs: on (target) |
| Icon size | 20px |
| Own-aura size multiplier | 1.4× |
| Max shown | 32 buffs / 16 debuffs |
| Per row | 8 |
| Rows | 2 |
| Spacing (x, y) | 2, 2 |
| Anchor to | Frame / health bar / power bar / other aura group |
| Anchor point + offset | `BOTTOMLEFT` → `TOPLEFT`, 0, 2 |
| Growth direction | Right, then Up |
| Sort order | Own-first, then time remaining ascending |

**FR-5.3 Player-sourced distinction (explicit brief requirement).** An aura counts as "own" when its source is `player` (option: also count `pet`). Own auras are differentiated by:
- **Size** — scaled by the multiplier above (required by the brief)
- **Border colour** — optional, user-chosen (required by the brief, "optionally color-coded")
- Optional: full-opacity cooldown swipe on own auras, desaturated icon on others

**FR-5.4** Debuff borders may instead be coloured by debuff type (Magic / Curse / Disease / Poison) using the game's `DebuffTypeColor` table, matching base-game convention. Own-source colouring and type colouring are mutually exclusive per group; the user picks which takes precedence.

**FR-5.5** Cooldown spiral via a `Cooldown` frame with `SetCooldown(expirationTime - duration, duration)`. Numeric countdown is left to OmniCC when installed; an optional built-in duration `FontString` is provided for users without it.

**FR-5.6** Stack counts render as a `FontString` in a configurable corner.

**FR-5.7 Filtering.** Per group: show-only-own toggle, spell-name/ID whitelist, spell-name/ID blacklist, minimum duration, hide-permanent toggle.

**FR-5.8 Classic duration caveat.** Classic and TBC clients report duration and expiration only for auras **you** applied. Third-party durations are unavailable from the API. DyrueUnitFrames will:
- show no swipe and no timer for auras with unknown duration (never a fake one), and
- optionally integrate `LibClassicDurations` if the user installs it, behind a feature flag and a clear "estimated" indicator.

The library is **not** bundled and **not** a hard dependency. Fewer dependencies, fewer patch-day failure modes.

**FR-5.9** Tooltips on hover, suppressed in combat by user option. Right-click to cancel own buffs on the player frame (this is a protected action — it must go through a secure button attribute, not a script handler).

---

### 4.6 Party frames

**FR-6.1** Frames for `party1`–`party4` are built as **four static secure buttons**, not a `SecureGroupHeaderTemplate`. Rationale in §5.4. `partypet1`–`partypet4` follow the same pattern and ship **disabled by default**.

**FR-6.2** Party frames are full unit frames. Every element built for player and target — health bar, power bar, text elements with colour rules, auras, portrait, highlight — is available on them, with independent per-unit configuration. This is a consequence of the element system being data-driven per unit, not extra work.

**FR-6.3 Group layout.** The four frames form a *group* with its own settings, so they are positioned once rather than four times:

| Setting | Default |
|---|---|
| Group anchor (point, x, y, anchor target) | Standard anchoring per §4.1 |
| Growth direction | Down |
| Spacing between frames | 8px |
| Per-frame width / height | Inherited from the party unit config, overridable |

Individual frames may still be detached and positioned independently for anyone who wants a non-linear arrangement; the group layout is a convenience over the same underlying per-frame values, exactly as drag mode is (§FR-1.4).

**FR-6.4 Visibility.** Party frames are shown when the player is in a party and hidden when solo, via `RegisterUnitWatch`, so no insecure show/hide logic runs in combat. Additional user options:
- Hide party frames while in a raid group (default: **on** — raid frames are out of scope, and 40 stacked party frames helps nobody)
- Show party frames while solo (default: off; useful for configuration, though `/duf test` is the better tool for that)

**FR-6.5 Roster changes.** `GROUP_ROSTER_UPDATE` fires during combat. Any handler responding to it must route every protected operation through `CombatQueue` (§FR-1.6). A player joining the group mid-fight must not produce an error; the frame may simply appear on combat exit.

**FR-6.6** The `player` frame is never rendered inside the party group. Classic has no "show self in party frames" convention and adding one invites layout confusion.

---

### 4.7 Portraits

**FR-7.1** Each unit frame supports three portrait modes, selectable per unit:

| Mode | Implementation | Notes |
|---|---|---|
| `none` | — | **Default** |
| `2d` | `SetPortraitTexture(texture, unit)` | Cheap, reliable, no ongoing liability |
| `3d` | `PlayerModel` frame + `SetUnit(unit)` | Live model; see FR-7.4 for the caveats |

**FR-7.2** Common settings across modes: size (independent width and height per §FR-1.3), anchor point and offset, alpha, and a placement option:

| Placement | Meaning |
|---|---|
| `column` | A column **within** the frame, on the left or right of the bars, which inset to make room. **Default** |
| `overlay` | Overlaid on the frame, behind bars and text |
| `detached` | Its own space to the left or right of the frame, outside its bounds |

*Amended by Plan 7 (8 Aug 2026).* The original spec offered only `inside` and `overlay`'s two-way choice under the names `inside`/`outside`, neither of which puts the portrait beside the bars. The names were changed with the addition because keeping `inside` for "behind the bars" next to a `column` that is also inside the frame would have been actively misleading.

**FR-7.2a Size tracks the bar stack.** By default the portrait's height is the health bar plus the power bar, so it is exactly as tall as the bars it sits beside, and a `square` toggle carries that across to the width. Both are settings; turning them off restores the manual sliders.

The shapeshift mana bar (§4.3) is **excluded from that height in both of its modes.** In `append` it is outside the frame's bounds; in `reserve` it is inside but below the portrait's own stack. Including it would mean a portrait that resized every time a druid changed form, which is the layout jump §FR-2.3 exists to prevent.

**FR-7.2b Portraits are click-targetable.** A `column` or `overlay` portrait is inside the secure button's rect and therefore already targets the unit on click; a model frame must have `EnableMouse(false)` so it does not swallow the click. A `detached` portrait is drawn beyond that rect, so the frame's hit rect is grown to cover it with negative `SetHitRectInsets` — a protected geometry call, routed through `CombatQueue` per §FR-1.6, and reset to zero when the placement changes.

**FR-7.3** 2D mode: fall back to the default question-mark portrait texture when the unit's portrait is unavailable. Refresh on `UNIT_PORTRAIT_UPDATE` and on unit change.

**FR-7.4 3D mode — known failure modes.** Model frames are the least reliable widget in the API and must be defensively handled:

| Failure | Handling |
|---|---|
| Model does not refresh when the unit changes | Explicitly re-call `SetUnit` on unit change, `UNIT_MODEL_CHANGED`, and `UNIT_PORTRAIT_UPDATE` — never assume the widget notices |
| Camera / zoom resets after a loading screen | Re-apply camera settings on `PLAYER_ENTERING_WORLD` |
| Model fails to load for out-of-range or unseen units | Detect and fall back to the 2D portrait for that unit, silently |
| Repeated `SetUnit` calls leak or stutter | Skip the call when the unit GUID is unchanged |

**FR-7.5** 3D mode exposes camera distance and a Y-offset so the framing can be corrected per unit. It does **not** expose free rotation or animation control in v1.0.

**FR-7.6** Because 3D portraits carry a real maintenance cost for a purely cosmetic feature, the config UI notes plainly that 2D is the more robust choice. The option exists; the guidance is honest.

**FR-7.7 3D background** *(added by Plan 18, 8 Aug 2026).* A model renders transparent wherever there is no model, so the game world shows through the space around the portrait. 3D mode therefore has a toggleable background fill with a configurable color, shipping **on and opaque black**.

It is drawn as a texture on `frame.content` rather than on the model, because the model is a *child frame* of content and a child draws above every layer of its parent — so the fill is behind it by construction, with no frame-level arithmetic. Draw order within that layer is set explicitly (frame backdrop 0, portrait background 1, portrait art 2) rather than left to creation order.

**3D only.** The 2D portrait's round art has the same transparent corners in `native` shape, but the shipped `square` shape crops them off and extending the fill there was not asked for. The setting is keyed on the *configured mode*, not on which widget is currently rendering: a model that is briefly unavailable falls back to the 2D texture per §FR-7.4, and the background stays put rather than strobing off with it.

---

### 4.8 Derived units

**FR-8.1** In scope for v1.0: `targettarget` (both clients) and `focus` / `focustarget` (TBC only).

`focustarget` cannot exist without `focus`, so bringing focus-target into scope necessarily brings the focus frame with it. Both are now v1.0.

**FR-8.2 The polling problem.** Units whose token is derived from another unit's target — anything matching `*target` other than `target` itself — **do not reliably receive unit events**. `UNIT_HEALTH` for `targettarget` cannot be depended on. This is a long-standing API characteristic, not a recent regression, and every unit frame addon handles it the same way:

- **Identity changes** are event-driven. `UNIT_TARGET` fires with the *owning* unit as its payload, so `UNIT_TARGET` with `"target"` signals that `targettarget` now points at someone else; `"focus"` signals the same for `focustarget`. `PLAYER_TARGET_CHANGED` and `PLAYER_FOCUS_CHANGED` cover the owning units themselves.
- **Value changes** (health, power, auras) require **polling**.

**FR-8.3 Polling driver.** A single shared ticker services all derived frames rather than one ticker per frame:

| Property | Value |
|---|---|
| Default interval | 0.25 s |
| User-configurable range | 0.1 – 1.0 s |
| Active only when | At least one derived frame is shown |
| Stops when | All derived frames hidden (solo, no target, etc.) |

One ticker updating at most three frames a quarter-second apart is negligible against the §6 budget, but it must be genuinely stopped when idle — a ticker that runs while the player is standing in a city with no target is exactly the kind of unnecessary cost this spec exists to avoid.

**FR-8.4** Because values are sampled rather than pushed, derived frames are inherently slightly stale. This is a property of the game, not a defect to engineer around. Defaults should reflect it: derived frames ship **text-light** (name and health percent), with auras **off by default**. All of it remains configurable — a user who wants full text and auras on target-of-target may have them and accept the update latency.

**FR-8.5 Focus gating.** On Classic Era and Hardcore, `focus` and `focustarget` do not exist. Their frames must not be created, and their config trees must be hidden rather than shown-and-broken. Gating is on the probed `Compat.hasFocus` capability flag, never on a TOC version comparison.

**FR-8.6** Everything else applies unchanged: derived frames are ordinary secure buttons from the same factory, with the same elements, colour rules, portraits, and anchoring. They are a data-source variation, not a second frame system.

**FR-8.7** The enemy-health limitation in §FR-4.7 applies to derived units too, and hits them harder — a target's target is very often a hostile NPC.

**FR-8.8 State gating (Plan 24).** §FR-8.5's rule — *absent, not present-and-broken* — applies to an individual **state** in the indicator row as well as to a whole unit. A state declares where it can appear:

- `requires` names a `Compat` capability flag, exactly as a unit definition does. A client without the capability neither draws the state nor builds its controls.
- `units` is the set of unit keys the state can ever fire on.

Where either excludes a state, **no texture is created for it and no options are generated** — it is not built-and-hidden, and not explained away with a note. Two states depend on this today: `resting`, which the game only reports about the player, and the three pet happiness states, which are `pet`-only for an API reason rather than a design one — `GetPetHappiness` takes no unit argument, so it answers about the player's pet whatever frame is asking, and an ungated happiness state would light an icon on the *target* frame. There is consequently no happiness readout for `partypet1-4` and cannot be one.

---

## 5. Technical design

### 5.1 File layout

```
DyrueUnitFrames/
├── DyrueUnitFrames.toc                 # single TOC, comma-delimited interface versions
├── Libs/                       # embedded, version-pinned
│   ├── LibStub/
│   ├── CallbackHandler-1.0/
│   ├── AceAddon-3.0/  AceEvent-3.0/  AceDB-3.0/
│   ├── AceConfig-3.0/  AceConfigDialog-3.0/  AceGUI-3.0/
│   └── LibSharedMedia-3.0/
├── LICENSE                     # MIT
├── Core/
│   ├── Core.lua                # addon object, bootstrap, event dispatch
│   ├── Locale.lua              # single enUS string table (see §11.2)
│   ├── Compat.lua              # ★ the only file that knows about client versions
│   ├── Defaults.lua            # database schema + default profile
│   ├── Migrate.lua             # versioned config migrations
│   └── CombatQueue.lua         # deferral of protected operations
├── Systems/
│   ├── Colors.lua              # class, reaction, power, difficulty colour resolution
│   ├── Tags.lua                # tag parser, dependency map, formatter
│   ├── ColorRules.lua          # rule evaluation engine
│   └── Anchoring.lua           # anchor graph, cycle detection, apply order
├── Units/
│   ├── Factory.lua             # secure frame construction, RegisterUnitWatch
│   ├── Registry.lua            # unit definitions and per-unit event tables
│   ├── PartyGroup.lua          # group-level layout for party1-4 / partypet1-4
│   └── DerivedPoller.lua       # single shared ticker for targettarget / focustarget
├── Elements/
│   ├── HealthBar.lua
│   ├── PowerBar.lua
│   ├── ShapeshiftMana.lua
│   ├── Text.lua
│   ├── Auras.lua
│   ├── Portrait.lua
│   └── Highlight.lua
└── Config/
    ├── Options.lua             # AceConfig tree root
    ├── Options_Layout.lua
    ├── Options_Text.lua
    ├── Options_Auras.lua
    ├── DragMode.lua
    └── TestMode.lua
```

### 5.2 TOC

Comma-delimited interface versions have been supported since 4.4.0, so a single TOC covers both targets:

```
## Interface: 11509, 20506
## Title: Dyrue Unit Frames
## Notes: Unit frames for Classic Era and TBC Anniversary.
## Author: Clayton
## Version: 0.1.0
## SavedVariables: DyrueUnitFramesDB
## X-Category: Unit Frames
```

Where a file must load on only one flavour, use the conditional file directive rather than a second TOC:

```
Units/Focus.lua [AllowLoadGameType tbc]
```

Note on suffixes, if a split ever becomes necessary: `_Vanilla` targets Classic Era only, `_TBC` targets TBC. The legacy `_Classic` suffix now loads on *all* Classic flavours and should be avoided as ambiguous.

### 5.3 Secure frames and combat lockdown

Unit frames must be clickable for targeting, which means they must be secure:

- Created as `CreateFrame("Button", name, UIParent, "SecureUnitButtonTemplate")`
- `frame:SetAttribute("unit", unit)`, `frame:SetAttribute("type1", "target")`, `frame:SetAttribute("type2", "togglemenu")`
- `frame:RegisterForClicks("AnyUp")`
- `RegisterUnitWatch(frame)` for conditional units (`target`, `pet`, `focus`) so the client shows/hides them without insecure code
- Registered into `ClickCastFrames` so Clique works if installed

**Forbidden in combat:** `SetPoint`, `SetSize`, `SetScale`, `Show`, `Hide`, `SetAttribute`, `RegisterUnitWatch`. Every one of these goes through `CombatQueue`, which either executes immediately or defers to `PLAYER_REGEN_ENABLED`. There must be exactly one code path for this; direct calls outside the queue are a review-blocking defect.

### 5.4 Party frames: static buttons, not a group header

`SecureGroupHeaderTemplate` is the API's sanctioned mechanism for group frames. It manages child creation, sorting, and filtering inside the secure environment, and it scales to 40-player raids. It is also configured entirely through attributes, and its `initialConfigFunction` is a **string of Lua executed in the restricted environment** — one of the least pleasant corners of the API to debug, and a recurring source of taint problems.

Party size in Classic and TBC is fixed at four other members. There is nothing dynamic to manage. Therefore:

- `party1`–`party4` are four ordinary `SecureUnitButtonTemplate` buttons created at load, identical in construction to `player` and `target`.
- `RegisterUnitWatch` handles show/hide as members join and leave, entirely in the secure environment.
- Group layout (§FR-6.3) is applied by our own anchoring system, which already exists.

What this gives up is automatic role and group sorting — neither of which exists in Classic. What it buys is that party frames are *the same code path* as every other frame, so every element, every colour rule, and every config control works on them for free, and there is no second, weirder frame system to maintain across patches.

**This choice is the reason raid frames stay out of scope.** Static buttons do not scale to 40 units; raid frames would genuinely require a group header, and that is a different project with a much worse patch-day risk profile.

### 5.5 The compatibility layer

`Core/Compat.lua` is the project's insurance policy. Nothing else in the codebase may call a version-sensitive API directly. It exposes:

```lua
Compat.flavor              -- "vanilla" | "tbc"
Compat.tocVersion          -- 11509 | 20506
Compat.hasFocus            -- boolean, feature-probed not version-guessed
Compat.hasPetHappiness
Compat.MANA                -- Enum.PowerType.Mana or 0

Compat.GetAura(unit, index, filter)   -- normalises C_UnitAuras vs UnitAura
Compat.GetClassColor(classFile)       -- CUSTOM_CLASS_COLORS aware
Compat.GetDifficultyColor(level)
Compat.HideBlizzardFrame(frame)       -- the ONLY place Blizzard UI is touched
Compat.SupportsIncrementalAuraUpdates()
```

**Feature-probe, don't version-check.** `if Compat.hasFocus` beats `if tocVersion >= 20000`. Probing is robust to Blizzard backporting a feature; hardcoded version comparisons are not. Every capability flag is set by testing for the thing itself at load.

### 5.6 Hiding the default Blizzard frames

The single unavoidable point of contact. Approach, in order of preference:

1. **Check first whether Edit Mode already does it.** Now that Classic has Edit Mode, the player may be able to hide `PlayerFrame`/`TargetFrame` natively. If so, DyrueUnitFrames's default is to *not touch Blizzard's frames at all* and simply tell the user. This is the lowest-risk outcome and Phase 0 must determine whether it is available.
2. If addon-side hiding is required: `UnregisterAllEvents()` plus reparent to a permanently hidden holder frame. Do **not** call `:Hide()` on a protected frame in combat.
3. Provide a "leave Blizzard frames alone" option regardless, so a future Edit Mode change can never brick the addon.

### 5.7 Event and update strategy

**Per-unit event registration.** Use `frame:RegisterUnitEvent(event, unit)` rather than a global handler with a unit filter. The client does the filtering; we avoid waking up on every raid member's health change.

**Event-driven by default.** The permitted tickers are exhaustive, and each must stop when its consumer is not visible:

| Ticker | Interval | Runs while |
|---|---|---|
| Shapeshift-mana fallback (§FR-2.5) | 0.2 s | That bar is visible |
| Aura duration text, if the built-in timer is used | 0.1 s | Auras with known durations are shown |
| Derived-unit poller (§FR-8.3) | 0.25 s | At least one derived frame is shown |

> **Revision note.** The first draft of this spec stated "no OnUpdate for data" as an absolute. Adding target-of-target and focus-target makes that impossible: those units do not receive reliable unit events, so polling is the only mechanism available. The principle is therefore restated as *event-driven by default, with a closed list of tickers that idle to zero* — which is the honest version of what was always meant. Any proposal to add a fourth ticker should be treated as a design smell and argued for explicitly.

**Tag dependency map.** Each tag declares which events invalidate it. A `UNIT_POWER_UPDATE` re-renders only the text elements containing power tags. Cache the rendered string per element and skip `SetText` when unchanged — `SetText` on an unchanged string still causes layout work.

**Aura updates.** Prefer the incremental `UNIT_AURA` payload (`isFullUpdate`, `addedAuras`, `updatedAuraInstanceIDs`, `removedAuraInstanceIDs`) if 2.5.6/1.15.9 provide it; fall back to a full rescan otherwise. Phase 0 determines which. A full rescan of 16 debuffs is cheap enough that this is an optimisation, not a blocker.

### 5.8 Configuration storage

- **AceDB-3.0**, profile-based, with per-character profile selection.
- Every saved variable table carries a `schemaVersion`. `Migrate.lua` steps forward one version at a time and never mutates in place until the whole migration succeeds.
- On a failed migration: keep the old table under `DyrueUnitFramesDB.backup`, load defaults, and tell the user plainly. Never silently discard a layout someone spent an hour on.

### 5.9 Error containment

The July patch produced "infinitely increasing Lua errors" in several addons — one broken update path firing on every event. DyrueUnitFrames must not do this:

- A `pcall` boundary around **config application and layout** (rare, high-risk, cheap to wrap).
- Update paths are not blanket-wrapped (per-frame-per-event `pcall` is a real cost); instead they are defensively written with explicit nil checks, and the dispatcher tracks error counts.
- **Circuit breaker:** if any single element errors more than N times (default 5) in a session, that element is disabled for the session, a single chat message names it, and everything else keeps working. Degraded, not dead.
- `/duf debug` toggles verbose logging; `/duf safemode` loads bars only, no text, no auras — an escape hatch for patch day.

### 5.10 Dependencies

| Library | Purpose | Justification |
|---|---|---|
| Ace3 (AceAddon, AceEvent, AceDB, AceConfig, AceConfigDialog, AceGUI) | Addon lifecycle, profiles, config UI | The config UI is realistically 40–50% of total effort. AceConfig's `range` control gives the slider-plus-exact-entry requirement for free, and Ace3 is maintained across every flavour. |
| LibSharedMedia-3.0 | Bar textures, fonts | Small, stable, expected by users |
| LibStub, CallbackHandler-1.0 | Ace3 requirements | — |

All libraries are **embedded and version-pinned**, never loaded from an external addon. Upgrading a library becomes a deliberate, testable act rather than something that happens to you.

`LibClassicDurations` is *optionally detected*, never bundled.

---

## 6. Performance budget

| Scenario | Target |
|---|---|
| Idle (solo, no target) | < 0.1 ms/frame CPU |
| Combat, target + pet, full text and auras | < 0.5 ms/frame |
| 25-man raid instance (frames for player/target/pet only) | < 0.5 ms/frame |
| Memory after 1 hour | < 500 KB, no unbounded growth |

Measured with `/duf profile` (a built-in wrapper around `GetFrameCPUUsage`) and cross-checked against addon CPU profiling.

---

## 7. Compatibility and interoperability

- **Clique** — register frames in `ClickCastFrames`.
- **OmniCC** — use standard `Cooldown` frames so it attaches automatically.
- **Edit Mode** — must not fight it. DyrueUnitFrames frames are not Edit Mode participants; they simply exist alongside.
- **Other unit frame addons** — no attempt at coexistence; document that they should be disabled.

---

## 8. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Blizzard backports Secret Values to Classic | Low–Medium | Severe (kills text engine) | Compat layer; bars use `SetValue` and would survive; monitor 12.0.x notes and the WoW UI Dev Discord; text engine designed to degrade to bars-only rather than error |
| R2 | Further shared-code UI patches break something | **High** (this will happen again) | Low–Medium | Containment architecture; patch-day playbook (§Plan Phase 6); circuit breaker prevents error cascades |
| R3 | Aura API differs between 1.15.9 and 2.5.6 | Medium | Low | Single `Compat.GetAura` accessor; resolved in Phase 0 before any aura code is written |
| R4 | Combat lockdown taint / protected-action errors | Medium | Medium | Single `CombatQueue` path; no direct protected calls anywhere else; test explicitly in combat |
| R5 | Enemy health is percentage-only in Classic | **Certain** | Low | Detected and handled (§FR-4.7); documented in the config UI |
| R6 | Ace3 breaks on a future patch | Low | Medium | Pinned embedded copies; Ace3 has survived every prior transition |
| R7 | Scope creep (raid frames, cast bars, retail) | **High** | High | Explicit non-goals (§2.2); anything new goes to the v1.x backlog, not into v1.0 |
| R8 | Config loss on upgrade | Low | High | Schema versioning, forward-only migration, automatic backup table |
| R9 | Perf regression in raids | Medium | Medium | Per-unit event registration, no OnUpdate, string caching, measured against §6 budget |
| R10 | Accidentally reproducing SUF code | Low | High (legal) | Clean-room rule: behaviour may be referenced, source may not be read while writing corresponding code |
| R11 | 3D portrait model frames misbehave (stale models, camera resets, leaks) | **High** | Low | Every failure mode in §FR-7.4 handled explicitly; automatic fallback to 2D; feature is default-off and cosmetic, so it can be disabled without affecting anything else |
| R12 | `GROUP_ROSTER_UPDATE` fires in combat and triggers a protected operation | Medium | Medium | All roster handling routed through `CombatQueue`; explicitly tested by joining and leaving a group mid-fight |
| R13 | Derived-unit poller runs when it should be idle, or interval is set too aggressively | Medium | Low–Medium | Single shared ticker tied to frame visibility, not one per frame; verified idle-at-zero in Phase 6 profiling; user interval floored at 0.1 s |
| R14 | Focus code paths execute on Classic Era, where `focus` does not exist | Low | Medium | Gated on the probed `Compat.hasFocus` flag; frames not created and config tree hidden, rather than created-and-broken; Classic Era is a required test client for every gate |

---

## 9. Acceptance criteria for v1.0

The release is complete when all of the following hold on **both** 1.15.9 and 2.5.6:

1. Player, target, target-of-target, pet, and party frames render with health and power bars on both clients; focus and focus-target additionally render on TBC.
2. Every position and size value is adjustable by slider and by typed exact value, and the two stay in sync.
3. Frames can be dragged, with optional grid snap, and dragging updates the stored numbers.
4. Layout changes attempted in combat are queued and applied on combat exit, with a visible notice and no errors.
5. A druid entering Bear or Cat form gains a mana bar showing correct, live values; leaving form removes it without layout artefacts.
6. A color rule set on current health changes its colour at both a percentage threshold and an absolute threshold.
7. The target's level number matches the base game's difficulty colour at every level difference, including `??`.
8. Health bars can be set to green (default), class colour, or reaction colour, independently for player and target.
9. Target buffs and debuffs display, anchored per configuration; player-sourced auras are visibly larger and optionally bordered in a chosen colour.
10. Party frames appear on joining a group and disappear on leaving it, including when the change occurs mid-combat, with no errors. Group layout settings position all four at once.
11. Every element available on the player frame is also available and independently configurable on party frames.
12. Portraits work in all three modes. 3D portraits update correctly on target change and survive a loading screen; an unavailable model falls back to 2D without an error.
13. Target-of-target updates within one poll interval of the underlying unit changing, and its identity updates immediately on `UNIT_TARGET`.
14. On Classic Era, no focus or focus-target frame is created and no focus options appear in the config tree — with zero errors.
15. The derived-unit poller is confirmed stopped when no derived frame is visible.
16. Enemy health text shows no fabricated absolute numbers.
17. A full UI reload preserves every setting.
18. Measured CPU stays within §6 budget in a 25-man raid **with a full party group displayed**.
19. `/duf safemode` produces working bars with no text or auras.

---

## 10. Decisions log

All pre-implementation questions are resolved. Recorded here so the reasoning survives the conversation.

| Decision | Outcome | Date |
|---|---|---|
| Addon name | Dyrue Unit Frames / `DyrueUnitFrames` / `/duf` | 2 Aug 2026 |
| Party frames | **In v1.0**, as static secure buttons (§5.4). Party pets included, default disabled | 2 Aug 2026 |
| Raid frames | **Out**, permanently for v1.x. Hard boundary — see §5.4 | 2 Aug 2026 |
| Player cast bar | **Out** of v1.0. Deferred to v1.x; shares no systems with anything else, so it costs the same later as now. Blizzard's default cast bar covers the gap | 2 Aug 2026 |
| Portraits | **All three modes** — none (default), 2D, 3D (§4.7) | 2 Aug 2026 |
| Distribution | **Private use.** MIT licensed; two cheap hedges preserve the option to publish later (§11) | 2 Aug 2026 |
| Target-of-target | **In v1.0** (both clients). Derived unit — requires the polling driver (§4.8) | 2 Aug 2026 |
| Focus and focus-target | **In v1.0, TBC only.** Focus-target requires focus, so focus was promoted from v1.1 alongside it | 2 Aug 2026 |
| Test druid | Available. Primary testing on TBC Anniversary, not the Hardcore character | 2 Aug 2026 |

**Remaining open:** none blocking. Phase 0 may surface findings that amend this spec; that is its purpose.

---

## 11. Licensing and attribution

### 11.1 Project license

**MIT.** Chosen because it is short, universally recognised in the addon ecosystem, imposes no obligations on you, and is compatible with every library being embedded. It permits others to reuse the code commercially — which is irrelevant here, since there is no monetisation intent and no downside to someone else learning from it.

A `LICENSE` file goes in the repository root **on day one of Phase 0**, not at release. Retroactively licensing a codebase is a small legal annoyance that is trivially avoided by doing it first.

### 11.2 Embedded library licenses

MIT covers *our* code. It does not relicense the embedded libraries, which keep their own terms. Required practice, whether or not this is ever published:

- Preserve each library's original license file under `Libs/<Library>/`.
- Verify each embedded library's actual license text at the point of embedding, in Phase 0 — do not assume. Ace3, LibStub, CallbackHandler, and LibSharedMedia are all permissive, but the specific terms and attribution requirements differ between them and should be read once rather than guessed at.
- Never modify a library in place. If a patch breaks one, wait for upstream or fork it explicitly under a different name.

### 11.3 Clean-room restated

Shadowed Unit Frames is All Rights Reserved. Its *behaviour and UX* may be referenced freely; its *source* must not be read while writing the corresponding feature. This constraint is unaffected by the project being private — private use is not a defence against copying, and it costs nothing to simply not do it.

### 11.4 Hedges preserving the option to publish

Two items, both in Phase 0, totalling well under an hour. They are the entire cost of keeping the door open:

1. **`LICENSE` file at the repo root** (§11.1).
2. **Route every user-facing string through a single `L` table** in `Core/Locale.lua`, containing only enUS. Costs a few keystrokes per string while writing; retrofitting it across several thousand lines later is genuinely miserable.

Explicitly *not* done now: CurseForge project, packager configuration, CI, additional locales, public documentation. If publication ever happens, the natural gate is **after v1.0 has survived one Blizzard patch cycle** — that is the point at which the containment architecture is proven rather than merely intended.
