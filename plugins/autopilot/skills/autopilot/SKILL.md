---
name: autopilot
description: Use for /autopilot, "autopilot plan", "start an autonomous run" or "overnight run". Modes: plan, continue, wrapup (one fresh session of an autonomous run), and start, status, note, stop (control a run).
---

# Autopilot

Arguments: $ARGUMENTS

Dispatch on the first argument: `plan`, `continue`, `wrapup`, `start`, `status`, `note`, `stop`, `watch`, `dash`. For anything else, print `usage: /autopilot plan|continue|wrapup|start|status|note|stop|watch|dash` and do nothing more.

Templates are in `${CLAUDE_PLUGIN_ROOT}/skills/autopilot/templates/` (`plan.md`, `rules.md`).

## start, status, note, stop, watch, dash

Run `bash "${CLAUDE_PLUGIN_ROOT}/bin/autopilot" <args>` from the repo and show its output unchanged. `dash` and `watch` are interactive terminal panes: for `dash`, run it with `TMUX=x` in front so it builds the grid without attaching, then tell the owner to run `tmux -L autopilot-dash attach` in a terminal; for `watch`, give the owner the command `bash "${CLAUDE_PLUGIN_ROOT}/bin/autopilot" watch` (with the path expanded) to run in a terminal from the repo.

## plan

Interactive, with the owner, one step at a time. Never start the runner.

1. Run: new or existing. New picks the run name, the plan-time date (`2026-10-21`; a second run that day is `2026-10-21-2`); a paired run is named `<date>-<group>` (`2026-10-21-media`), records the shared board `~/.autopilot/<run>/board/` in `board:`, and a consumer lists the peers it serves in `serves:`; a solo run writes `board: none`. Existing reopens its `plan.md` for revision.
2. Repo rules: read `.autopilot/rules.md`. If missing, draft it from `templates/rules.md` with the owner and get sign-off. Confirm tonight's push and deploy rules. Ask whether `.autopilot/rules.md` should be tracked; the default is to add it to `.gitignore` next to `.autopilot/runs/`.
   Permissions: list every git, push and deploy command a session will run. Draft prefix-form allow rules (`Bash(git commit:*)`, `Bash(git push origin main:*)`, `Bash(git push . autopilot/*:main)`, …) and, once the owner approves, write them to the repo's `.claude/settings.local.json`. Then probe them headless, e.g. `claude -p "run git push --dry-run origin main" --permission-mode auto`, and fix any denial before the run starts.
3. Scope: bounded (a fixed list) or open (a mandate). For open, write the mandate: what is in scope, where to look for more, what is out.
4. Queue: draft items from the mandate's sources, each with a check; group small items into batches; mark `after:` dependencies; confirm the Final item. Resolve every SHA a check names against `HEAD` and ask the owner when they differ. Use `templates/plan.md`.
5. Limits: show current weekly and 5-hour utilization from the last `end` line of the repo's latest `runner.log`. If there is none, run `claude -p "reply ok" --model haiku --output-format stream-json --verbose`. Read the last `rate_limit_event` that has `unifiedWindows`: its `seven_day.utilization` and `five_hour.utilization`. Set the weekly ceiling and session cap. List the live runners (`pgrep -af autopilot-runner`) and their ceilings: usage is account-wide, and `~/.config/autopilot/weekly-ceiling` (a fraction), if present, caps every run. Write `weekly-ceiling` as a decimal fraction (`0.80`, not `80%`) and `session-cap` as a whole number; the run card shows the ceiling as a percent. Save the plan as `.autopilot/runs/<run>/plan.md`.
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

  /autopilot dash              every live run in one tmux grid, with the board

  From a terminal: tmux -L autopilot-dash attach                 the dash grid
                   tmux attach -t '=autopilot-batmanROTJ'        the raw runner
                   tmux kill-session -t '=autopilot-batmanROTJ'  emergency stop
```

## continue

Headless: no human is present. Invoked as `continue <run-dir>` from the repo; `<run-dir>` is relative to the repo (`.autopilot/runs/<run>`); `<run>` is its last path segment. Do one item (or batch), hand off, exit.

Authority: the approved `plan.md` and the repo's `.autopilot/rules.md` are the owner's explicit go-ahead for commits on run branches (always) and for the pushes, tags and deploys they allow. A global rule such as "only commit when I say so" is satisfied by them. Do nothing they do not allow.

1. Read `.autopilot/rules.md`, `<run-dir>/plan.md`, `<run-dir>/owner.md`, and, when the plan's `board:` is set and is not `none`, every other repo's board file in that directory for items addressed to this repo. Read each file with the Read tool, one file per call; never chain reads with `echo` separators (zsh rejects `====`). Do not read `log.md` or earlier sessions, except where step 5.3 says so. Never edit `owner.md`; a missing `owner.md` or board file counts as empty.
2. Recovery: the last `start` line in `<run-dir>/runner.log` is this session. The previous session is the highest `session=` below it. Recover only if that session is dirty: it has a `start` line and no `end` line, its `end` has `exit=killed`, `exit=crash`, `exit=nowait` or `exit=limit`, or its `end` has `exit=STOP` and `git status --porcelain` is non-empty. Then diff the work tree against `refs/autopilot/<run>/<n>` (`<n>` = that session), check worktrees and fleet agent logs against the Handoff, repair the Handoff, and append a `log.md` entry that names the ref and the mismatch. A file that is in the checkpoint ref but not in `HEAD`, and is still untracked now, counts as unchanged. The interrupted item's attempt is not counted. If the previous session ended cleanly (or there is none), skip this step and write no recovery note.
3. `owner-notes-applied` counts the note lines (starting `- `) already applied. Apply the rest in order to the plan (add, drop, reorder items, change the mandate), then advance the counter. An owner note outranks anything else in the plan. Follow "Owner decisions" below.
4. Answer board items addressed to this repo. On an ack of your own ship post (not in a legacy plan), mark its items `[x]` and fast-forward the default branch to the acked sha (see "Item states and shipping"). On a `reject` or `nack` of your own ship post, set its items back to `[ ]` with the findings on the item line; they ship again (`replaces`) before any later `[c]` item. If the only remaining work waits on another repo or on an ack past `ahead-cap` (the Final item does not count as remaining work), post to your own board file and exit `WAIT <cap>`, where the cap is the longest you would wait before something must be wrong (the runner wakes the run as soon as a board line addressed to this repo appears). When exiting WAIT, never post a board line addressed to a peer unless it is a new request or an answer: board lines wake peers, and wakes don't count toward the session cap.
5. Pick the work, first match wins, then write `now: <item number>` in the plan header (the dashboard and `status` show it):
   1. shipping to a peer and no post of yours is waiting for its ack: the next `[c]` prefix (ship it as one post)
   2. the first `[ ]` item (or batch) whose `after:` items are `[c]`, `[p]` or `[x]`, while fewer than `ahead-cap` items are `[c]` or `[p]`; skip an item with `waiting: <id>` until an `ack <id>` line appears in another repo's board file; then remove `waiting:` and work it
   3. a `[!]` item (every `[!]` is still unrevisited): its one revisit, a fresh attempt that starts from its failure notes in `log.md` and tries a different approach
   4. open scope only: survey for more in-scope work using the mandate's sources; add new items under Discovered with where they came from and a check. An empty survey leaves the queue empty
   5. the Final item
6. Work it: subagents, worktrees, fleets. Background agents and background commands started inside the session must finish before you exit: ending your turn ends the session and stops them (the runner logs `exit=nowait`), so wait for them. Only detached jobs (`setsid … & echo $!`, see `WAIT … pid=` in step 9) outlive the session; list each with its pid and log path in the Handoff. Commit on branch `autopilot/<run>` (create it from `HEAD` if missing) unless the plan or `.autopilot/rules.md` names another branch. Anything found along the way goes under Discovered (open scope, in the mandate) or the Parking lot (bounded scope, out of scope, or on the stop list). Never work a Parking lot item.
7. Run its check. Pass: mark `[x]` (an item that ships to a peer goes `[c]` → `[p]` → `[x]` on its ack; see "Item states and shipping"); push, tag or deploy only if `.autopilot/rules.md` allows mid-run. Re-read `owner.md` right before any push, tag, deploy or deploy post: apply new notes first, or exit `STOP` if one conflicts. Run push, tag and deploy commands exactly as the repo's allow rules spell them (no wrapper such as `nix develop -c`), one per call (no pipes, no `;` or `&&` chains), so the allow rules match them. Fail: record the attempt on the item line (`attempt 1 failed: <reason>`); second failure `[!]` with `BLOCKED: <reason>`; a failed revisit (5.3) changes `[!]` to `[!!]` with `revisit failed: <reason>`, since a revisited item never stays `[!]`; skip dependants of a blocked item. Skipping a `waiting:` item counts no attempt. Then clear `now:` (leave it empty) and go to step 8: one item (or batch) per session, never a second pick.
8. Rewrite the Handoff section of `plan.md` (state, open branches and worktrees, what the next session must know; at most ~40 lines). A remote SHA named in the Handoff must come from a `git fetch` + `git rev-parse` you ran: only name one if you fetched it in that session. It lists every running fleet agent with its log path and last-known state (running, exited N, silent since). Append the long version to `<run-dir>/log.md`.
9. Just before choosing the exit word, re-read every board file (when the plan has a board). If a request addressed to this repo is unanswered and this session could act on it now, exit `NEXT`; if it is blocked (behind another post, or an owner note says hold), exit `WAIT <cap>` and the board wake brings the run back. Before exiting `STOP`, commit or revert, or list every dirty path (`git status --porcelain`) in the Handoff.

   Final message: exactly one exit line, `AUTOPILOT: <word>`, in plain text (no bold, no code span, nothing before it on the line). It must be the last such line of the message; other plugins' closing text may follow it and is ignored. `<word>` is one of:
   - `NEXT`: relaunch now
   - `WAIT <minutes>` or `WAIT <minutes> pid=<n>[,<n>...]`: background work is running (fleet, long check). Minutes are a positive whole number with no unit. The runner wakes the run early when a listed pid exits, a board line addressed to this repo appears, the owner adds a note, or a STOP file appears: owner notes and STOP wake a waiting run. The minutes are a cap for hung jobs, so set them to the job's worst case, not its typical time. Launch a detached job as `setsid <cmd> </dev/null >"$log" 2>&1 & echo $!` and pass that pid; check it with `ps -o pid=,sid=,args= -p <pid>` before exiting. Never use `pgrep -f` to find it: it can return your own shell. A fleet lists every running agent's pid; the woken session merges whatever finished and exits WAIT again for the rest. Board waits need no pid: `WAIT <cap>` is enough.
   - `WAIT ack <id>[,<id>...]`: waiting for a peer's answer to your post. The runner wakes the run only when an `ack`, `nack` or `reject` for that id appears (at once if it is already on the board), a peer's runner stops, the owner adds a note, or STOP. There is no timer: after the plan's `ack-timeout` (6h if unset) the owner gets an alert and one session wakes to handle the overdue ack. Prefer it to `WAIT <minutes>` whenever you are waiting for an answer to your own post. If launched work is still running, exit `WAIT` instead of polling
   - `DONE`: the Final item is finished
   - `STOP <reason>`: hit the stop list or needs the owner; the reason is required, a bare `STOP` is a crash

## wrapup

Invoked as `wrapup <run-dir>`. Follow `continue` but skip step 5 and the `WAIT` and `NEXT` exits in steps 4 and 9: work only the Final item. Open and blocked items do not block it; carry out the Final item's own instruction and run its check against whatever is done. Nothing new to commit is not a failure: still create any branch it names, at `HEAD`. A ship post still waiting for its ack (not in a legacy plan): list it in `## Owner`, leave the default branch at the last acked sha, and do not count it as done. Then exit `AUTOPILOT: DONE`, or `AUTOPILOT: STOP <reason>` if the stop list stops the Final item.

## Item states and shipping

States: `[ ]` open, `[c]` committed locally, `[p]` pushed or posted and waiting for its ack, `[x]` done (check passed, and a shipped item acked), `[!]` blocked, `[!!]` revisit failed. Item numbers never change: a new item takes the next number, the queue is read in file order, and Final stays last.

- Keep the run branch linear in ship order. Unpushed commits may be reordered with a local rebase; never rewrite pushed history.
- Ship a prefix as a review ref: `git push origin <sha>:refs/heads/ship/<id>`, then post `<id> → <consumer>: <sha> (ship/<id>, item <n>)`. The consumer deploys exactly that sha. Fast-forward the default branch to it only after the `ack`; a `reject` or `nack` never touches the default branch.
- `ahead-cap:` (default 2) limits items in `[c]` or `[p]` beyond the last acked one. Past the cap, survey, plan or exit `WAIT <cap>`.
- Items with the same `ship: <group>` ship as one post, with one reviewer pass over the group's range.
- `ack-timeout:` (default `6h`): a post unanswered that long means exit `STOP ack <id> overdue`. Never close out on unconfirmed code.
- A consumer whose plan has `serves: <repo>, …` treats each listed peer without a `done <repo>` line as remaining work: it exits `WAIT <cap>` instead of reaching its Final. It serves open requests oldest first.
- Major or blocking `findings:` in an ack of your own post become Discovered items; no owner note is needed.
- A commit counts as equivalent to one a check names when `git diff --stat A B -- . ':!.autopilot' ':!.gitignore'` is empty; say so on the item when you rely on it.

## Owner decisions

- `## Owner` in `plan.md` lists what only the owner can do or allow, and every major finding you won't fix. Add lines; never drop one silently. When an entry is resolved (an owner note decides it, or you check and the condition is gone, such as a stuck CI run the owner cancelled), remove its line and append `owner item resolved: <short> (<note N, or what you checked>)` to `log.md`; the dashboard and status show the section's count, so a stale line keeps the run marked as needing the owner.
- A note that explicitly changes an earlier decision is applied (step 3). If applying a note would also undo an owner decision or setting the note does not mention, exit `STOP` and name both. Never label a consequence of a note "owner's decision".
- A note marked `[to <peer>]` was sent to that peer (`autopilot note --to`); it is not an instruction for this repo.
- A deviation from an approved design: `deviated: <why>` on the item and a line in `## Owner`.
- Refer to a note by its number and a short paraphrase; never copy its text into `plan.md`.
- A note marked `[once]` applies one time. After using it, add its number to `owner-notes-used:` and skip it afterwards.

## Board

`<board>/<repo>.md` is written by this repo's sessions (plus the runner's stop line and `autopilot note --to`); read the others. Every line starts with its UTC time. Ids are `<repo>-<n>`, the next free n in your own file, assigned when you post; plans name work by item number, not board id.

- `<id> → <repo>[, <repo>]: <request>`: a request; say which item it ships
- `<id> (replaces <old-id>) → <repo>: …`: a re-post after a reject or nack
- `ack <id>: <result>`: done, or deployed and healthy; may end with `findings: <severity> …`
- `reject <id>: <findings>`: not deployed; the producer fixes it and re-posts. Not a stop
- `nack <id>: <reason>`: deployed, unhealthy, rolled back. The producer exits `STOP` only if the nack asks for an owner decision; otherwise it fixes and re-posts
- `watch <id>: <observation>`: a later result, non-blocking
- `done <repo>`: this repo's Final item is finished
- `owner → <repo>: <text>`: an owner note for `<repo>` from `autopilot note --to`. Apply it like a new `owner.md` line, once: record its time in `owner-board-applied:` in the plan header (add the line if missing) and skip lines at or before it. Sessions never write `owner` lines

```
# nixfiles
- 2026-10-23T01:50Z nixfiles-3 → decypharr: deployed 3f9c1a2 to media-0, still 3 failures/hr, journal in log 01:50
- 2026-10-23T02:05Z ack decypharr-2: 3f9c1a2 live on media-0, no regressions
```

## Interim: legacy plans

Remove this section once the 2026-10-22 runs have finished. A plan whose header has `legacy: true` skips the "Item states and shipping" and "Board" sections above and keeps the rules it started with: items are only `[ ]`, `[x]`, `[!]` and `[!!]` (step 7 marks `[x]` when the check passes), and its board follows the old format below. Owner lines (`owner → <repo>: …`, see Board) apply to it too.

`~/.autopilot/<run>/board/<repo>.md` is written only by this repo's sessions, plus the runner's stop line and owner lines from `autopilot note --to`; read the others. Item ids are `<repo>-<n>` (`nixfiles-3`). Reply to an item with an `ack <id>` line in your own file.

```
# nixfiles
- nixfiles-3 → decypharr: deployed v1.4.1 to media-0, still 3 failures/hr, journal in log 01:50
- ack decypharr-2 (v1.4.2 tagged a3f9c1): deploying now
```
