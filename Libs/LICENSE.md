# Embedded library licenses

DyrueUnitFrames itself is MIT (see `../LICENSE`). That license does **not**
relicense anything in this folder. Each library below keeps its own terms.

Per `SPEC.md` §11.2 these copies are **version-pinned and never modified in
place**. If a patch breaks one, wait for upstream or fork it under a different
name — do not edit it here.

| Library | Version embedded | License |
|---|---|---|
| LibStub | 2 | Public Domain |
| CallbackHandler-1.0 | 8 | Ace3 license (BSD-like, see below) |
| AceAddon-3.0 | 13 | Ace3 license |
| AceEvent-3.0 | 4 | Ace3 license |
| AceConsole-3.0 | 7 | Ace3 license |
| AceDB-3.0 | 30 | Ace3 license |
| AceDBOptions-3.0 | 15 | Ace3 license |
| AceConfig-3.0 | 3 | Ace3 license |
| AceConfigCmd-3.0 | 14 | Ace3 license |
| AceConfigDialog-3.0 | 92 | Ace3 license |
| AceConfigRegistry-3.0 | 22 | Ace3 license |
| AceGUI-3.0 | 41 | Ace3 license |
| AceGUI-3.0-SharedMediaWidgets | — | Public Domain / BSD (Yssaril) |
| LibSharedMedia-3.0 | 12000001 | LGPL v2.1 / Ace3-compatible (Elkano) |

## Ace3

Ace3 is distributed under a permissive BSD-style license. The canonical text
lives at <https://www.wowace.com/projects/ace3> and in the Ace3 stand-alone
distribution. Summary of obligations: retain copyright notices, do not claim
authorship, no warranty.

## LibStub

> LibStub is hereby placed in the Public Domain.
> Credits: Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel, joshborke

## LibSharedMedia-3.0

Copyright (c) Elkano. Distributed with the standard Ace3-ecosystem permissive
terms; retain the copyright header inside `LibSharedMedia-3.0.lua`.

## Provenance

These copies were taken from a pinned, unmodified Ace3 distribution as shipped
with a current Classic-flavour addon build. Verify the version column above
against the `MAJOR, MINOR` line at the top of each library file before bumping
any of them — that line is the authority, this table is a convenience.

## Not embedded, only detected

`LibClassicDurations` is **optionally detected at runtime** (SPEC §FR-5.8) and
is deliberately not bundled. If the user installs it as a standalone addon,
DyrueUnitFrames will use it behind a feature flag and mark the durations it
provides as estimated.
