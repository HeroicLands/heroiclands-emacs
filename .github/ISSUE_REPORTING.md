# Issue Reporting — heroiclands-emacs

This document defines how issues are created and classified in the
**`heroiclands-emacs`** repository, which ships the Emacs package for authoring
HeroicLands content.

**This repository is its own tracker.** File editor-tooling work here, not in the
system repository. See §7 for where a given piece of work belongs.

The core discipline is simple — three axes, each answering a different question:

- **Type** — _"what shape of work is this?"_ One per issue, from a closed set of five.
- **Priority** — _"how soon and how badly does this need doing?"_ A GitHub issue field, one value, defaults to Medium.
- **Labels** — _"what is this about?"_ Categorization only, chosen **only** from the registry in §3. Never invent a label.

Type and priority are structured single values (one each). Labels stack. Keep the
roles separate: do not encode priority or work-shape as a label, and do not encode
subject matter as a type.

**There are no milestones here.** `sohl-thalorna` and the system repository use
milestones as capability gates, because they ship toward a beta. This package has
no such gates, and an empty milestone set is better than a decorative one.

## 1. Issue types

Exactly **one** type per issue. Do not leave an issue untyped.

Issue types are **organization-level** in the `HeroicLands` org, so the same five
types — and their definitions — are shared with every other repository in the
project. They are not redefined here.

| Type        | Use it when…                                                                                                                   | Do **not** use it for…                                                 |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| **bug**     | Shipped behaviour is wrong — a command errors, a completion offers the wrong thing, the mode fails to activate where it should. | Missing capability (a _feature_); a chore.                             |
| **feature** | A new capability that does not exist yet, deliverable as one shippable unit.                                                    | Anything broken (_bug_); work needing many sub-issues (_epic_).        |
| **epic**    | A body of work that only makes sense decomposed into sub-issues.                                                                | Anything shippable as a single issue. No sub-issues means not an epic. |
| **task**    | Necessary work that is neither defect nor new capability: chores, refactors, CI, docs, releases.                                | Exploratory work with an uncertain outcome (_spike_).                  |
| **spike**   | A **timeboxed** investigation whose deliverable is a decision or recommendation — not shipped code.                             | Work whose steps are already known (a _task_).                         |

**Type rules**

- **MUST** assign exactly one type.
- A **bug** is _broken_; a **feature** is _missing_. Decide which word fits first.
- An **epic** MUST link its sub-issues and SHOULD carry little implementation
  detail of its own.
- A **spike** MUST state the question it answers and its timebox.
- A **refactor** changing no external behaviour is a **task**, tagged `tech-debt`.

**What "broken" means here.** This package's behaviour is largely _conditional_ —
a mode that activates in the right buffers, a completion that offers the right
candidates, a rewrite that fires only while a link is being typed. So the most
valuable bug reports say **what you typed, what happened, and what you expected**,
because the gap is usually a condition rather than a crash. A form that looks
correct and silently does nothing is a bug worth filing even when nothing errored.

## 2. Priority (GitHub issue field)

Priority is a native **Priority** field on the issue — an organization-level issue
field, **not** a label. Set it in the issue sidebar; the issue list filters on it
(`field.priority:high,medium`). One value per issue, from: **Urgent · High ·
Medium · Low**.

| Priority   | Means                                                                      |
| ---------- | -------------------------------------------------------------------------- |
| **Urgent** | The package is unusable, or it damages content. Drop other work.           |
| **High**   | A core workflow is broken or badly degraded, with no reasonable workaround. |
| **Medium** | The default. Worth doing; nothing is on fire.                              |
| **Low**    | Nice to have; polish, or a rare edge.                                      |

**Anything that can corrupt or lose content is Urgent**, regardless of how narrow
the trigger. This package writes into notes — normalization rewrites a link in
place — and a wrong rewrite is not an inconvenience.

## 3. Labels — the closed registry

Labels are **subject matter only**. The registry is `.github/labels.yml`, and it
is **closed**: a label not listed there is deleted from the repository, and from
every issue carrying it, on the next sync. Editing the registry means editing
both that file and this table.

| Label             | Use it for                                                                   |
| ----------------- | ---------------------------------------------------------------------------- |
| `documentation`   | The README, the Info manual, docstrings, process.                            |
| `devops`          | Build, tooling, CI, release, repo config.                                    |
| `security`        | Evaluating untrusted content, file-local variables, subprocess handling.     |
| `tech-debt`       | Restructuring or cleanup of working code; refactors.                         |
| `regression`      | Something that previously worked and stopped. Pairs with type **bug**.       |
| `breaking-change` | Alters a command name, key binding, variable, or the mode's activation rule. |
| `blocked`         | Cannot proceed until an external dependency or another issue clears.         |
| `duplicate`       | Already exists.                                                              |
| `question`        | Further information is requested.                                            |
| `wontfix`         | Will not be worked on.                                                       |

There is **no** `bug` or `enhancement` label — work shape is a _type_, so
filtering on such a label returns nothing.

## 4. Body structure by type

### Bug

```text
## Summary
## What I typed / what I did
## Expected vs. actual
## Environment      (Emacs version, package commit, the project it happened in)
## Notes
```

### Feature

```text
## Problem / motivation
## Proposed solution
## Acceptance criteria
```

### Task

```text
## What needs doing
## Why
## Acceptance criteria
```

### Spike

```text
## Question
## Timebox
## What a conclusion looks like
```

**Root cause goes in a comment, not the body.** The body is the problem
statement — symptoms, reproduction, expectation. What is actually wrong, and the
proposed fix, belong in a comment, so the issue reads as a report rather than as a
half-finished diagnosis.

## 5. Pull requests

- Branch as `<type>/<issue_#>_<short-kebab-summary>`, or `chore/<slug>` for
  issue-free housekeeping.
- `main` is protected: pull request, one approving review, **squash merge only**.
- The PR description says what changed and why; it becomes the squash commit
  message.
- **No AI or assistant attribution** in a commit message, PR title, or PR body.
  The `.githooks/commit-msg` hook refuses such a commit locally (activate with
  `make hooks`), and the **No Attribution** check fails the pull request.

## 6. Verification

There is no content build here, so "done" is what `make` asserts:

- `make check` — every feature loads in a clean Emacs
- `make compile` — byte-compiles without warnings (warnings are failures in CI)
- `make info` — the manual builds

A change to behaviour updates the manual (`doc/heroiclands.texi`) and the
docstring of any command it touches. A command's docstring should end with
``See Info node `(heroiclands)Some Node'.`` — that is what keeps `C-h f` and the
manual joined up.

## 7. Which repository does an issue belong in?

File where the diff will land, not where the symptom shows.

| The change is to…                                                | File it in                         |
| ---------------------------------------------------------------- | ---------------------------------- |
| An Emacs command, the mode, completion, the manual               | **here**                           |
| The content index format, the table expander, a build diagnostic | `HeroicLands/package-build`        |
| A content note — wrong data, a dead link, a stale query          | the repository that ships the note |
| System code, sheets, rules automation                            | `Song-of-Heroic-Lands-FoundryVTT`  |

A wrong completion is usually **here**; a wrong _answer_ from a correct
completion is usually the index, and so `package-build`.
