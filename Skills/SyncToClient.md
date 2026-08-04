# SyncToClient

How to get the latest code on a branch into the game client.

Use this whenever the user asks to sync, to update the client, or to "put the
latest on main into the game". Two steps that always go together: bring the
working tree up to date, then copy it into WoW's AddOns folders.

---

## The loop

1. **Pick the branch.** `main` unless the user names another one.
2. **Refuse to run on a dirty tree.**
3. **Fetch and fast-forward.**
4. **Copy into the client** with `Tools/sync.ps1`.
5. **Report the commit that is now in the client**, and what the user has to do
   in game.

---

## Git procedure

```powershell
git status --porcelain              # must be empty; stop if not
git fetch origin
git checkout <branch>               # only if not already on it
git pull --ff-only origin <branch>
git log --oneline -1                # this is what ships to the client
```

- **`--ff-only` on purpose.** If local and remote have diverged, the sync stops
  and says so. A merge commit is never an acceptable side effect of "put the
  latest in the game".
- **Never stash, reset, or discard to clean the tree.** A dirty tree means the
  user has work in progress. Say what is uncommitted and let them decide; they
  may well want the uncommitted version synced, which is a different request.
- **You stay on the branch afterwards.** Unlike `Skills/NewWork.md`, there is no
  switching back — the game reads whatever is checked out, so the branch left in
  place *is* the branch being played. Say which one that is.
- Branch that only exists on the remote:
  `git checkout -b <branch> --track origin/<branch>`.

---

## The copy

```powershell
.\Tools\sync.ps1
```

| Flag | When to use it |
|---|---|
| `-WowPath "D:\Games\World of Warcraft"` | The script cannot find the install |
| `-Link` | Junctions instead of copies — see the caveat below |
| `-Watch` | Re-sync on every `.lua` save; leave it running during a session |

What it does:

- Finds the WoW root, then syncs **every Classic flavor folder that exists**
  under it — `_classic_era_`, `_anniversary_`, `_classic_`, `_classic_ptr_`,
  `_classic_beta_`. It does not ask which one you play.
- Stages the repo minus everything that is not the addon (`.git`, `.claude`,
  `Documents`, `Plans`, `Skills`, `Tests`, `Tools`, `Probe`, `README.md`,
  `venv`/`.venv`/`__pycache__`) and copies that as `DyrueUnitFrames`.
- Copies `Probe/DyrueUnitFrames_Probe` separately, as its own addon.
- Only ever writes inside folders named after those two addons, so a mistyped
  `-WowPath` cannot scribble over an unrelated install.
- **SavedVariables are untouched.** They live in `WTF/`, nowhere near the addon
  folder — settings and profiles survive a sync. Worth saying out loud, because
  it is the thing people worry about.

Known install as of 2026-08-03: `D:\Program Files (x86)\World of Warcraft`, with
`_classic_era_` and `_anniversary_` present.

### The `-Link` caveat

The header comment in `Tools/sync.ps1` says the game reads straight out of the
repository under `-Link`. That is true **only for the probe**. The main addon is
junctioned to the staging copy under `%TEMP%\DyrueUnitFrames_stage`, because
linking the repo root would expose `.git` and `Documents` to the game. So a repo
edit does *not* reach the client on its own — re-running the script refreshes
staging in place, and the junction keeps pointing at it. For a hands-off loop use
`-Watch`, not `-Link`.

`-Link` refuses to replace a real folder; delete it yourself first. That is
deliberate — the script will not remove something that might be a real install.

---

## In game

- **Addon already in the list:** `/reload` is enough.
- **First sync of an addon that was not there before, or the TOC's file list
  changed:** quit to desktop and restart. `/reload` will not discover a new addon
  or a newly listed file.

---

## Reporting

"Synced" on its own does not tell the user whether the fix they are waiting on is
actually in there. Say:

- the commit now sitting in the client, by hash and subject;
- which flavor folders got it;
- `/reload`, or restart, per above.
