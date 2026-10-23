# Autopilot run <YYYY-MM-DD>: <title>
repo: <repo>
run: .autopilot/runs/<YYYY-MM-DD>
board: <~/.autopilot/<run>/board/ for a paired run, none for a solo run>
scope: <bounded|open>
weekly-ceiling: 0.80
session-cap: 60
owner-notes-applied: 0
now:

## Mandate
<bounded: what done looks like. open: what is in scope, where to look for more,
and what is explicitly out of scope>

## Queue
- [ ] 1. <item>    check: <command>
- [ ] 2. <item>    after: 1, check: <command>
### Discovered
### Final
- [ ] 3. <final item, e.g. merge branches, reviewer, push per .autopilot/rules.md>

## Parking lot
<work found but out of scope, or on the stop list; never worked by autopilot>

## Handoff
<rewritten every session, at most ~40 lines: state, open branches/worktrees,
running fleet agents and their logs, what the next session must know>
