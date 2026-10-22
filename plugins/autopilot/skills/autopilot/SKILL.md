---
name: autopilot
description: Use for /autopilot, "autopilot plan", "start an autonomous run" or "overnight run". Modes: plan, continue, wrapup (one fresh session of an autonomous run), and start, status, note, stop (control a run).
---

# Autopilot

Arguments: $ARGUMENTS

Dispatch on the first argument: `plan`, `continue`, `wrapup`, `start`, `status`, `note`, `stop`.

Templates are in `${CLAUDE_PLUGIN_ROOT}/skills/autopilot/templates/` (`plan.md`, `rules.md`).

## start, status, note, stop

Run `bash "${CLAUDE_PLUGIN_ROOT}/bin/autopilot" <args>` from the repo and show its output unchanged.

## plan

Interactive, with the owner, one step at a time. Never start the runner.

1. Run: new or existing. New picks the run name, the plan-time date (`2026-10-21`; a second run that day is `2026-10-21-2`); a paired run records the shared board path. Existing reopens its `plan.md` for revision.
2. Repo rules: read `.autopilot/rules.md`. If missing, draft it from `templates/rules.md` with the owner and get sign-off. Confirm tonight's push and deploy rules.
3. Scope: bounded (a fixed list) or open (a mandate). For open, write the mandate: what is in scope, where to look for more, what is out.
4. Queue: draft items from the mandate's sources, each with a check; group small items into batches; mark `after:` dependencies; confirm the Final item. Use `templates/plan.md`.
5. Limits: show current weekly and 5-hour utilization from the last `end` line of the repo's latest `runner.log`. If there is none, run `claude -p "reply ok" --model haiku --output-format stream-json --verbose`. Read the last `rate_limit_event` that has `unifiedWindows`: its `seven_day.utilization` and `five_hour.utilization`. Set the weekly ceiling and session cap. Write `weekly-ceiling` as a decimal fraction (`0.80`, not `80%`) and `session-cap` as a whole number; the run card shows the ceiling as a percent. Save the plan as `.autopilot/runs/<run>/plan.md`.
6. Review: show the finished plan; the owner approves or edits.
7. Finish: add `.autopilot/runs/` to `.gitignore` if missing, and print the run card. Plan mode does not start the runner.

Run card (fill in repo, scope, item count, ceiling and tmux name):

```
Run 2026-10-21 in batmanROTJ is ready (open scope, 4 items, ceiling 80%).

  /autopilot start             start it
  /autopilot status            progress, current item, usage
  /autopilot note "..."        change course; the next session applies it
  /autopilot stop              stop after the current session
  /autopilot stop --now        stop immediately (the next start recovers)
  /autopilot plan              revise the plan (before starting, or after a stop)

  From a terminal: tmux attach -t '=autopilot-batmanROTJ'        watch
                   tmux kill-session -t '=autopilot-batmanROTJ'  emergency stop
```

## continue

Headless: no human is present. Invoked as `continue <run-dir>` from the repo; `<run-dir>` is relative to the repo (`.autopilot/runs/<run>`); `<run>` is its last path segment. Do one item (or batch), hand off, exit.

Authority: the approved `plan.md` and the repo's `.autopilot/rules.md` are the owner's explicit go-ahead for commits on run branches (always) and for the pushes, tags and deploys they allow. A global rule such as "only commit when I say so" is satisfied by them. Do nothing they do not allow.

1. Read `.autopilot/rules.md`, `<run-dir>/plan.md`, `<run-dir>/owner.md`, and every other repo's board file (`~/.autopilot/<run>/board/*.md`) for items addressed to this repo. Do not read `log.md` or earlier sessions, except where step 5.2 says so. Never edit `owner.md`; a missing `owner.md` or board file counts as empty.
2. Recovery: the last `start` line in `<run-dir>/runner.log` is this session. The previous session is the highest `session=` below it. Recover only if that session is dirty: it has a `start` line and no `end` line, or its `end` has `exit=killed`, `exit=crash` or `exit=limit`. Then diff the work tree against `refs/autopilot/<run>/<n>` (`<n>` = that session), check worktrees and fleet agent logs against the Handoff, repair the Handoff, and append a `log.md` entry that names the ref and the mismatch. The interrupted item's attempt is not counted. If the previous session ended cleanly (or there is none), skip this step and write no recovery note.
3. `owner-notes-applied` counts the note lines (starting `- `) already applied. Apply the rest in order to the plan (add, drop, reorder items, change the mandate), then advance the counter. An owner note outranks anything else in the plan.
4. Answer board items addressed to this repo. If the only remaining work waits on another repo (the Final item does not count as remaining work), post to your own board file and exit `WAIT 20`.
5. Pick the work, first match wins:
   1. the first `[ ]` item (or batch) whose `after:` items are done; skip an item with `waiting: <id>` until an `ack <id>` line appears in another repo's board file; then remove `waiting:` and work it
   2. a `[!]` item (every `[!]` is still unrevisited): its one revisit, a fresh attempt that starts from its failure notes in `log.md` and tries a different approach
   3. open scope only: survey for more in-scope work using the mandate's sources; add new items under Discovered with where they came from and a check. An empty survey leaves the queue empty
   4. the Final item
6. Work it: subagents, worktrees, fleets. Commit on branch `autopilot/<run>` (create it from `HEAD` if missing) unless the plan or `.autopilot/rules.md` names another branch. Anything found along the way goes under Discovered (open scope, in the mandate) or the Parking lot (bounded scope, out of scope, or on the stop list). Never work a Parking lot item.
7. Run its check. Pass: mark `[x]`; push, tag or deploy only if `.autopilot/rules.md` allows mid-run. Fail: record the attempt on the item line (`attempt 1 failed: <reason>`); second failure `[!]` with `BLOCKED: <reason>`; a failed revisit (5.2) changes `[!]` to `[!!]` with `revisit failed: <reason>`, since a revisited item never stays `[!]`; skip dependants of a blocked item. Skipping a `waiting:` item counts no attempt. Then go to step 8: one item (or batch) per session, never a second pick.
8. Rewrite the Handoff section of `plan.md` (state, open branches and worktrees, what the next session must know; at most ~40 lines). It lists every running fleet agent with its log path and last-known state (running, exited N, silent since). Append the long version to `<run-dir>/log.md`.
9. Final message: exactly one exit line, `AUTOPILOT: <word>`, in plain text (no bold, no code span, nothing before it on the line). It must be the last such line of the message; other plugins' closing text may follow it and is ignored. `<word>` is one of:
   - `NEXT`: relaunch now
   - `WAIT <minutes>`: background work is running (fleet, long check); a positive whole number with no unit (`WAIT 20`). If launched fleet work is still running, exit `WAIT` instead of polling
   - `DONE`: the Final item is finished
   - `STOP <reason>`: hit the stop list or needs the owner; the reason is required, a bare `STOP` is a crash

## wrapup

Invoked as `wrapup <run-dir>`. Follow `continue` but skip step 5 and the `WAIT` exits in steps 4 and 9: work only the Final item. Open and blocked items do not block it; carry out the Final item's own instruction and run its check against whatever is done. Nothing new to commit is not a failure: still create any branch it names, at `HEAD`. Then exit `AUTOPILOT: DONE`, or `AUTOPILOT: STOP <reason>` if the stop list stops the Final item.

## Board

`~/.autopilot/<run>/board/<repo>.md` is written only by this repo's sessions; read the others. Item ids are `<repo>-<n>` (`nixfiles-3`). Reply to an item with an `ack <id>` line in your own file.

```
# nixfiles
- nixfiles-3 → decypharr: deployed v1.4.1 to media-0, still 3 failures/hr, journal in log 01:50
- ack decypharr-2 (v1.4.2 tagged a3f9c1): deploying now
```
