# Autopilot rules: <repo>

## Checks
<the commands that prove an item is done, and the full gate for the Final item>

## May happen mid-run
<what may leave the machine before the Final item: pushes, tags, deploys, or "nothing: branches only">

## Reviewer stand-in
<how the Final item gets reviewed, e.g. run the reviewer agent and fix its findings>

## Fleet
<how fleet agents are launched, where their logs are, how to tell running from exited>

## Stop list
<what a session must stop for and exit STOP: destructive actions, spending, anything needing the owner>

## Where to look for more work
<open scope only: files, surveys and findings that feed new items>

## Long commands
<deploys and suites that can outlast a tool timeout: run them detached and exit `WAIT <cap> pid=<pid>`, or give an explicit timeout>

## Shared tool locks
<tools shared with other runs (e.g. golangci-lint's lock): retry on their lock message instead of failing the item>

## Peers
<paired runs: who serves whom, pacing (how many peer deploys per session), and which peer is on the critical path>
