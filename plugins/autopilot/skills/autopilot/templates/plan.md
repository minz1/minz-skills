# Autopilot run <YYYY-MM-DD>: <title>
repo: <repo>
run: .autopilot/runs/<YYYY-MM-DD>
board: <~/.autopilot/<run>/board/ for a paired run, none for a solo run>
scope: <bounded|open>
weekly-ceiling: 0.80
session-cap: 60
owner-notes-applied: 0
owner-notes-used:
now:
serves: <paired consumer only: peers it serves; else delete>
ahead-cap: 2
ack-timeout: 6h

## Mandate
<bounded: what done looks like. open: what is in scope, where to look for more,
and what is explicitly out of scope>

## Queue
- [ ] 1. <item>    check: <command>
- [ ] 2. <item>    after: 1, check: <command>
### Discovered
### Final
- [ ] 3. <final item, e.g. merge branches, reviewer, push per .autopilot/rules.md. Paired: no `[c]` or `[p]` items left, every post in this repo's board file is acked or replaced, and the default branch equals the last acked sha>

## Parking lot
<work found but out of scope, or on the stop list; never worked by autopilot>

## Owner
<only the owner can do or allow these; major findings a session won't fix>

## Handoff
<rewritten every session, at most ~40 lines: state, open branches/worktrees,
running fleet agents and their logs, what the next session must know>
