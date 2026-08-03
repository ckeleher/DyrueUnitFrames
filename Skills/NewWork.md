# NewWork

How to turn a list of feature requests or bug reports into plan documents.

Use this whenever the user supplies one or more requests and asks for plans,
rather than asking for the work itself to be done.

---

## The rules

1. **Plans live in a top-level `Plans/` directory.** Create it if it does not
   exist.

2. **One file per request.** Never combine two requests into one plan, even when
   they touch the same code.

3. **Sequential IDs, starting at 1.** The ID is the plan's unique identifier.
   Continue from the highest existing ID — do not restart at 1 for a new batch,
   and do not reuse an ID from a deleted plan.

4. **Filename:** `Plan_<ID>_<Title>.md`

   The title summarises the request in a few words — up to ten, ideally five or
   fewer. No spaces; run the words together in PascalCase.

   ```
   Plan_1_NewTextField.md
   Plan_2_ManaBarColor.md
   Plan_12_TruncateLongNames.md
   ```

5. **Markdown format.**

6. **Include the exact text of the request**, verbatim, in a `## Request`
   section, as a blockquote. Do not paraphrase, tidy, correct spelling, or fix
   grammar — the point is that the original wording survives so the plan can be
   checked against what was actually asked for.

7. **Commit immediately to the head of the `main` branch.** Create `main` if it
   somehow does not exist.

8. **Check the staging area before committing.** Only the plan files (and this
   skill, when it changes) go in that commit. If anything unexpected is staged,
   stop and say so rather than committing it.

9. **If there was only one request**, ask afterwards whether to start
   implementing it. With several, summarise and let the user pick.

---

## Git procedure

Work is usually happening on a feature branch, so this means switching branches
and coming back.

```bash
git status --porcelain          # must be empty; stop if not
git branch --show-current       # remember where to return to
git checkout main
# write the plan files
git status --porcelain          # confirm ONLY the plans are there
git add Plans/
git commit
git checkout -                  # back to the feature branch
```

Never commit plans onto the feature branch, and never carry uncommitted feature
work across the switch.

---

## What goes in a plan

The point is a document that can be handed to someone — including a future
session with no context — and acted on. A restatement of the request is not a
plan.

Required:

- **Title, status, date, branch.**
- **`## Request`** — the exact text, quoted.
- **Interpretation** — what the request means concretely, where it is ambiguous,
  and which reading was taken. If two readings would mean materially different
  work, say so rather than silently choosing.
- **Design** — the actual approach, referring to real files, functions and
  settings in this codebase. Name the module the code belongs in and why.
- **Files** — a table of what gets touched and how.
- **Schema and migration** — does this add keys (free, `EnsureProfile` fills
  them) or change a stored value (needs a migration step, and a rule for
  distinguishing an untouched default from a deliberate choice)?
- **Tests** — what to assert, and note any gap in the existing suite that let
  the bug through.
- **Risks** — with handling, not just a list of worries.
- **Estimate.**

Also worth including when they apply:

- **Diagnosis steps first**, for a bug whose cause is not yet known. Rank the
  candidates; do not pick one and design a fix around a guess.
- **An explicit argument** when the plan breaks a stated rule in `SPEC.md` — for
  example adding a fourth ticker against §5.7, or deviating from a specified
  default. Say which rule, why the breach is justified, and record it in
  `Documents/COMPAT_FINDINGS.md` when implemented.

---

## Tone

Write for someone who has to act on it. Concrete over hedged; state a
recommendation rather than listing options neutrally. Where something is genuinely
unknown, say what would resolve it and what it costs to find out.
