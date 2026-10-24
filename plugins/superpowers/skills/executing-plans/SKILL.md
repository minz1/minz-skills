---
name: executing-plans
description: Use when executing an implementation plan from writing-plans, natively or subagent-driven, interactively or as an autopilot item that names a plan file
---

# Executing Plans

Run the plan task by task in the mode chosen at the writing-plans handoff, without pausing between tasks. The plan already did the thinking: execute it exactly, prove each step, and leave a record that survives compaction.

## Ledger

Conversation memory does not survive compaction, and a controller that lost its place has re-run whole sequences of finished tasks. Track progress in a file, not only in todos.

- Interactive: `<plan path without .md>.ledger.md`, next to the plan. Its first line is `Base: <sha>`, the commit before Task 1.
- Under autopilot: the run's `log.md` is the ledger; keep no second one, and start each line with the plan's filename, since other items write there too. An item that names a plan may span sessions, and the next session resumes from `log.md`.
- One line per task, written in the same message as its commit: `Task N: done <sha>, tests N/N` (`staged` in place of the sha when commits were not approved).
- At start, if the ledger exists, resume after its last done task. Check that task's commit is in `git log` first (for `staged`, that its change is in `git diff --cached`); if it is not, redo that task.

## Rulings, not stalls

Conflicts, ambiguities and plan defects: decide them. The spec is the binding authority, the plan is its argument, and your judgment settles what neither answers. Ledger each decision as `Ruling: <what you decided> — <why> — <what it costs if wrong>` and keep going. A deviation without a ledgered ruling is a decision made in secret.

Don't check in between tasks. Only these stop you: an irreversible or destructive operation; a security-sensitive action; a side effect outside this worktree that norms say you ask about first (a merge, a push to a shared branch, a publish); a plan so broken that every path forward is a guess. Under autopilot, the stop list in `.autopilot/rules.md` replaces these four, and stopping means exit `STOP`.

## Per task

Interactive: commit only when commits were approved at the handoff. Otherwise end each task with `git add -A` instead of committing, so the next task's diff is `git diff` and the whole run's is `git diff <Base>`. Under autopilot: commit on the run branch as the autopilot protocol says.

**Native:**
1. Re-read the task from the plan, not from memory.
2. Work its steps in order with superpowers:test-driven-development; run every verification step and read its output. Output that differs from the plan's Expected: a wrong plan gets a ruling, wrong code gets superpowers:systematic-debugging.
3. Commit as the plan's commit steps say, run the task's tests, write its ledger line.

**Subagent-driven:**
1. Dispatch one fresh `general-purpose` agent with the task text, the plan's header sections, the spec path and whether to commit or stage, never your session history.
2. When it reports back, dispatch `reviewer` on that task's diff and handle the findings with superpowers:receiving-code-review before the next task.
3. Write the ledger line.

## Final review

After the last task, dispatch one fresh `reviewer` on the most capable model over the whole run: `Base..HEAD`, or `git diff <Base>` when tasks were staged. Do not skip it or replace it with your own read of the diff: same author, same blind spots. Handle its findings with superpowers:receiving-code-review: one fix pass, no re-review. Ledger each fix as `Final: fixed <finding>, <test> RED→GREEN, suite N/N` and each deferred minor as `Final: minor (deferred): <one-liner>`.

## Finish

Your final message lists every ledger `Ruling:` line under "Rulings I made", in order and with its cost if wrong, and every deferred minor under "Deferred minors". Both lists are exhaustive: they are the only place the decisions you took on your partner's behalf reach them. Then apply superpowers:verification-before-completion. Delete the interactive ledger only after that message is sent and the tasks are committed.

Under autopilot no one reads the final message, whose last line is the exit word: the rulings stay in `log.md`, deferred minors go to the plan's Parking lot, and declined Critical or Important findings go to `## Owner`.

| Excuse | Reality |
|--------|---------|
| "I'll write the ledger after a few tasks" | Compaction does not wait. One line per task, with its commit. |
| "I read my own diff; the final reviewer is redundant" | The reviewer is the only fresh context the run buys. |
