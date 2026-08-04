# ArchivePlan

What to do with a plan once its work is merged.

Use this the moment a feature branch lands on `main`. Archiving the plan is the
**final action of the merge**, not a separate chore done later — a plan left in
`Plans/` is a claim that the work is still outstanding.

---

## The rule

When a plan's feature is merged, move its file into `Plans/Archive/`.

```bash
git mv Plans/Plan_9_TargetComboPoints.md Plans/Archive/
```

Nothing else changes. Same filename, same contents, same ID. `Plans/` is then a
list of what is still open, which is the only reason to keep the split.

---

## Deciding whether it is actually merged

Three signals, and they disagree often enough that you have to check more than
one.

### 1. The plan's own header is not proof

Every plan carries a `**Branch:**` field, but it records **where the plan was
written**, not where it was implemented. Plans 3, 6 and 7 all say
`**Branch:** first`, and `first` merged in PR #2 — none of the three has been
started. Read `**Status:**` as well, and archive only when both agree the work
shipped.

An `Implemented` status is also not enough on its own: it means someone wrote
code, not that the code reached `main`.

### 2. `--merged` misses squash merges

```bash
git branch -a --merged main
```

This lists branches whose tip is an ancestor of `main` — true merge commits
only. A squash merge rewrites the work into one new commit, so the branch tip is
never an ancestor and **the branch will not appear here even though it is fully
merged**. Both PR #7 and PR #8 in this repo landed that way.

### 3. So confirm by content

The reliable check is whether `main` already contains the branch's changes:

```bash
git diff --stat origin/<branch> main
git log --oneline origin/<branch> ^main     # commits the branch still holds
```

Read the diff in the direction that matters. Lines the branch has and `main`
lacks are the ones that would mean unmerged work. If the only differences are
additions `main` picked up afterwards — later features, follow-up commits — the
branch is in.

GitHub's squash commits are also recognisable by subject: `Plan 2 power tick
indicators (#8)`. Treat that as a strong hint, then confirm with the diff.

When the branch is gone entirely, grep `main` for a file the plan said it would
create (`Elements/ComboPoints.lua`, say). Present means merged.

---

## Cross-references

Plans link to each other with **relative** paths:

```markdown
**Related:** [Plan 2](Plan_2_PowerTickIndicators.md)
```

Moving one plan down a directory and leaving its partner behind breaks that
link. Before moving anything:

```bash
grep -rn "Plan_[0-9]*_[A-Za-z]*\.md" Plans/
```

| Situation | What to do |
|---|---|
| Both plans shipped together | Move them in the same commit; relative links still resolve |
| Archiving one, the other stays open | Fix the path — `Archive/Plan_N_Foo.md` from `Plans/`, `../Plan_N_Foo.md` from inside `Archive/` |
| The reference is a `@Plans/...` mention inside a verbatim `## Request` quote | **Leave it.** The request text is quoted exactly and never edited, even when the path it names has moved |

---

## Git procedure

Plans live on the trunk, so this is a `main` commit — the same rule as
`Skills/NewWork.md`, and the same branch dance if work is happening elsewhere.

```bash
git status --porcelain          # must be empty; stop if not
git branch --show-current       # remember where to return to
git checkout main
git pull --ff-only origin main  # the merge you are archiving has to be here
mkdir -p Plans/Archive
git mv Plans/Plan_<ID>_<Title>.md Plans/Archive/
git status --porcelain          # confirm ONLY the moves are staged
git commit
git checkout -                  # back to the feature branch
```

Use `git mv`, not a delete-and-recreate — `git log --follow` on the archived
file then still reaches the original commit.

`Tools/sync.ps1` excludes the whole top-level `Plans` directory, so `Archive/`
is already kept out of the addon that ships to the game client. Nothing to add
there.

---

## What not to do

- **Do not rewrite the plan on the way in.** Its status line and any *Outcome*
  section are the record of what happened; an archived plan is read to find out
  what was decided and why, not to be tidied.
- **Do not archive a partially-shipped plan silently.** Plan 4 merged with one
  symptom fixed and the other only hardened. It still archives — the branch is
  in — but say so in the report rather than letting the move imply it is closed.
- **Do not renumber.** IDs are permanent and never reused, archived or not.
- **Do not delete.** Archiving is the whole point; the plan is the durable record
  of what was asked for.

---

## Reporting

Say which plans moved and, for each, the evidence that it was merged — the merge
or squash commit, by hash and subject. "Archived Plan 9" gives the user no way
to check you were right about the merge. Name what stayed behind too, and why,
since that list is the answer to "what is still open".
