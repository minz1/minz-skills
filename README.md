# minz-skills

My Claude Code plugins.

## Install

```
claude plugin marketplace add minz1/minz-skills
claude plugin install autopilot@minz-skills
claude plugin install superpowers@minz-skills
```

To pick up new commits:

```
claude plugin marketplace update minz-skills
claude plugin update autopilot@minz-skills
claude plugin update superpowers@minz-skills
```

## autopilot

Runs a queue of work unattended, one fresh Claude session per item, so context stays small. Needs bash, jq, gawk, git and tmux.

```
/autopilot plan            write the plan with Claude (queue, checks, usage ceiling)
/autopilot start           start the runner in tmux
/autopilot status          progress, current item, usage
/autopilot note "..."      change course; the next session applies it
/autopilot stop [--now]    stop after the current session, or right away
/autopilot dash            every running run in one tmux grid with the board;
                           then attach from a terminal: tmux -L autopilot-dash attach
```

Each repo needs `.autopilot/rules.md`: the checks, what may be pushed or deployed mid-run, and what must stop the run. `/autopilot plan` drafts it with you the first time. Runs live in `.autopilot/runs/`, which `plan` adds to `.gitignore`.

A waiting run wakes as soon as the job it's waiting on exits, a peer posts to it on the board, or you add a note, so a long WAIT is only a ceiling. If you want to hear about it when a run stops, an item gets blocked or a session goes quiet for an hour, drop an executable at `~/.config/autopilot/notify`. It gets called as `notify <repo> <run> <event> <detail>`. On WSL, `plugins/autopilot/examples/notify-wsl-toast` turns that into a Windows toast.

## superpowers

My fork of five skills from [obra/superpowers](https://github.com/obra/superpowers): `brainstorming`, `writing-plans`, `test-driven-development`, `systematic-debugging`, `verification-before-completion`. Claude picks them up on its own; you can also call them by name, e.g. `/superpowers:brainstorming`.

## License

MIT. `plugins/superpowers/` keeps its upstream MIT license.
