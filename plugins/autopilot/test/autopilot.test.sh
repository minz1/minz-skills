#!/usr/bin/env bash
unset TMUX
DIR=$(cd "$(dirname "$0")" && pwd)
AP=$DIR/../bin/autopilot
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

mkdir "$BASE/stub"
printf '#!/bin/sh\necho "real claude called" >&2\nexit 1\n' > "$BASE/stub/claude"
chmod +x "$BASE/stub/claude"
export PATH=$BASE/stub:$PATH
export CLAUDE_BIN=$DIR/fake-claude FAKE_SCENARIO=$BASE/scn SLEEP_CMD=$BASE/no-sleep

die() { echo "$*"; exit 1; }
eq() { [ "$1" = "$2" ] || die "$3: got '$1' want '$2'"; }
has() { grep -qF -- "$2" <<<"$1" || die "$3 lacks '$2': $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || die "$3 has '$2': $1"; }
waitfor() {
  for _ in $(seq 50); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  die "timeout waiting for '$2' in $1"
}
tmux_gone() {
  for _ in $(seq 30); do
    tmux has-session -t "=$1" 2>/dev/null || return 0
    sleep 0.1
  done
  die "tmux session $1 still alive"
}

setup() {
  W=$(mktemp -d -p "$BASE")
  export TMUX_TMPDIR=$W/tmux HOME=$W/home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export FAKE_SCENARIO=$W/scn
  unset AUTOPILOT_MODEL
  trap 'tmux kill-server 2>/dev/null' EXIT
  mkdir -p "$TMUX_TMPDIR" "$HOME" "$FAKE_SCENARIO"
  tmux new-session -d -s bootstrap 'sleep 600'
  repo=$W/${1:-repo}
  R1=$repo/.autopilot/runs/2026-10-21
  R2=$repo/.autopilot/runs/2026-10-21-2
  LOG=$R2/runner.log
  mkdir -p "$R1" "$R2" "$repo/sub"
  git -C "$repo" init -q 2>/dev/null
  echo x > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m init
  for r in "$R1" "$R2"; do
    printf '# run\nweekly-ceiling: 0.80\nsession-cap: 5\n' > "$r/plan.md"
  done
  cd "$repo" || exit 1
}

sc() { jq -nc --arg t "${2:-}" --argjson x "${3:-{\}}" '{text: $t} + $x' > "$FAKE_SCENARIO/$1.json"; }
ap() {
  OUT=$(bash "$AP" "$@" 2>"$W/err")
  RC=$?
  ERR=$(cat "$W/err")
}
start_run() {
  sc 1 "AUTOPILOT: NEXT" '{"sleep":30}'
  ap start
  eq "$RC" 0 "start rc"
  waitfor "$LOG" "session=1 start"
}

test_latest_run_default() {
  setup; ap note hi
  eq "$RC" 0 "rc"
  has "$(cat "$R2/owner.md")" hi owner.md
  [ ! -e "$R1/owner.md" ] || die "older run got the note"
}

test_run_flag() {
  setup; ap note hi --run 2026-10-21
  eq "$RC" 0 "rc"
  has "$(cat "$R1/owner.md")" hi owner.md
  [ ! -e "$R2/owner.md" ] || die "latest run got the note"
}

test_from_subdir() {
  setup; cd sub || exit 1; ap note hi
  eq "$RC" 0 "rc"
  has "$(cat "$R2/owner.md")" hi owner.md
}

test_note_format() {
  setup; ap note "skip APU"
  re='^- [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} skip APU$'
  [[ $(cat "$R2/owner.md") =~ $re ]] || die "bad note line: $(cat "$R2/owner.md")"
}

test_no_run_errors() {
  setup; rm -rf "$repo/.autopilot/runs"
  ap note hi; [ "$RC" != 0 ] || die "note exited 0"; has "$ERR" "/autopilot plan" "note stderr"
  ap start; [ "$RC" != 0 ] || die "start exited 0"; has "$ERR" "/autopilot plan" "start stderr"
  ap status; [ "$RC" != 0 ] || die "status exited 0"; has "$ERR" "/autopilot plan" "status stderr"
}

test_env_forwarded() {
  setup; sc 1 "AUTOPILOT: DONE"
  AUTOPILOT_MODEL=haiku ap start
  eq "$RC" 0 "rc"
  eq "$ERR" "" "first start stderr"
  waitfor "$LOG" "stopped: done"
  has "$(cat "$FAKE_SCENARIO/calls")" "--model haiku" calls
}

test_start_twice_refuses() {
  setup; start_run; ap start
  [ "$RC" != 0 ] || die "second start exited 0"
  has "$ERR" "already running" stderr
  has "$ERR" "tmux attach -t '=autopilot-" stderr
}

test_start_clears_stop() {
  setup; touch "$R2/STOP"; sc 1 "AUTOPILOT: DONE"; ap start
  eq "$RC" 0 "rc"
  [ ! -e "$R2/STOP" ] || die "STOP not removed"
  has "$OUT" STOP stdout
}

test_stop_creates_stop() {
  setup; start_run; ap stop
  eq "$RC" 0 "rc"
  [ -e "$R2/STOP" ] || die "no STOP file"
  has "$OUT" "after the current session" stdout
  tmux has-session -t "=autopilot-repo" 2>/dev/null || die "session died after plain stop"
}

test_stop_nothing_running() {
  setup; ap stop
  eq "$RC" 0 "rc"
  has "$OUT" "nothing is running" stdout
  [ ! -e "$R2/STOP" ] || die "STOP created"
}

test_stop_now_kills() {
  setup; start_run; ap stop --now
  eq "$RC" 0 "rc"
  tmux_gone autopilot-repo
  waitfor "$LOG" "exit=killed"
}

test_status_live() {
  setup; start_run; ap status
  eq "$RC" 0 "rc"
  has "$OUT" running status
  lacks "$OUT" "not running" status
  has "$OUT" "tmux attach -t '=autopilot-" status
}

test_status_dirty() {
  setup; start_run; ap stop --now
  waitfor "$LOG" "exit=killed"
  ap status
  has "$OUT" "not running" status
  has "$OUT" "ended dirty (killed)" status
  echo "2026-10-21T00:00:00Z session=1 start mode=continue checkpoint=abc" > "$LOG"
  ap status
  has "$OUT" "ended dirty (no end line)" status
  echo '2026-10-21T00:00:01Z session=1 end exit=limit detail="seven_day" weekly=0.9 five_hour=0.1 peak_ctx=5' >> "$LOG"
  ap status
  has "$OUT" "ended dirty (limit)" status
}

test_status_counts() {
  setup
  printf '%s\n' '- [x] 1. a' '- [x] 2. b' '- [!] 3. c' '- [!!] 4. d' '- [ ] 5. e' '- [ ] 6. f' '- [ ] 7. g' >> "$R2/plan.md"
  ap status
  has "$OUT" "2 done, 2 blocked, 3 open" status
}

test_status_details() {
  setup
  printf '%s\n' '- [x] 1. first thing' '- [ ] 2. second thing' '## Handoff' 'wip on the second thing' >> "$R2/plan.md"
  echo '2026-10-21T00:00:01Z session=1 end exit=NEXT detail="" weekly=0.62 five_hour=0.12 peak_ctx=43005' > "$LOG"
  ap status
  has "$OUT" "2. second thing" status
  has "$OUT" "wip on the second thing" status
  for f in exit=NEXT weekly=0.62 five_hour=0.12 peak_ctx=43005; do has "$OUT" "$f" status; done
}

test_session_name_sanitized() {
  setup my.repo; start_run
  tmux has-session -t "=autopilot-my_repo" 2>/dev/null || die "no session autopilot-my_repo"
}

test_exact_session_match() {
  setup snitch
  tmux new-session -d -s autopilot-snitchbe 'sleep 600'
  start_run; ap status
  has "$OUT" "=autopilot-snitch'" status
  lacks "$OUT" snitchbe status
  ap stop --now
  tmux_gone autopilot-snitch
  tmux has-session -t "=autopilot-snitchbe" 2>/dev/null || die "snitchbe was killed"
}

test_exact_match_without_exact_session() {
  setup snitch
  tmux new-session -d -s autopilot-snitchbe 'sleep 600'
  ap status
  has "$OUT" "not running" status
  lacks "$OUT" "tmux attach" status
  ap stop
  eq "$RC" 0 "stop rc"
  has "$OUT" "nothing is running" stop
  [ ! -e "$R2/STOP" ] || die "STOP created"
  ap stop --now
  has "$OUT" "nothing is running" "stop --now"
  tmux has-session -t "=autopilot-snitchbe" 2>/dev/null || die "snitchbe was killed"
}

test_status_ignores_session_in_detail() {
  setup
  {
    echo "2026-10-21T00:00:00Z session=1 start mode=continue checkpoint=abc"
    echo '2026-10-21T00:00:01Z session=1 end exit=crash detail="needs session=99 check" weekly=? five_hour=? peak_ctx=0'
    echo "2026-10-21T00:00:02Z stopped: two crashes session=7"
  } > "$LOG"
  ap status
  has "$OUT" "session 1 ended dirty (crash)" status
  lacks "$OUT" "session 99" status
  lacks "$OUT" "session 7" status
}

test_start_runner_refuses() {
  setup; sed -i '/session-cap/d' "$R2/plan.md"
  ap start
  [ "$RC" != 0 ] || die "start exited 0"
  has "$ERR" "autopilot-runner" stderr
}

test_start_env_scrubbed() {
  setup; tmux kill-server; tmux_gone bootstrap
  export CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=dummy AUTOPILOT_MODEL=haiku
  start_run
  g=$(tmux show-environment -g | cut -d= -f1)
  for n in CLAUDECODE CLAUDE_CODE_SESSION_ID AUTOPILOT_MODEL; do
    ! grep -qx -- "$n" <<<"$g" || die "global tmux env has $n"
  done
  s=$(tmux show-environment -t "=autopilot-repo" | cut -d= -f1)
  for n in AUTOPILOT_MODEL CLAUDE_BIN SLEEP_CMD FAKE_SCENARIO; do
    grep -qx -- "$n" <<<"$s" || die "session env lacks $n"
  done
}

test_stray_file_and_empty_note() {
  setup; touch "$repo/.autopilot/runs/zzz-stray"
  ap note hi
  eq "$RC" 0 "rc"
  has "$(cat "$R2/owner.md")" hi owner.md
  ap note
  [ "$RC" != 0 ] || die "empty note accepted"
  has "$ERR" usage stderr
  ap note --now x
  has "$(cat "$R2/owner.md")" "--now x" owner.md
}

fail=0
t() {
  if [ "$3" = 0 ] && [ -z "$2" ]; then echo "ok $1"; else echo "FAIL $1: rc=$3 $2"; fail=1; fi
}
out=$(test_latest_run_default 2>/dev/null); t test_latest_run_default "$out" $?
out=$(test_run_flag 2>/dev/null); t test_run_flag "$out" $?
out=$(test_from_subdir 2>/dev/null); t test_from_subdir "$out" $?
out=$(test_note_format 2>/dev/null); t test_note_format "$out" $?
out=$(test_no_run_errors 2>/dev/null); t test_no_run_errors "$out" $?
out=$(test_env_forwarded 2>/dev/null); t test_env_forwarded "$out" $?
out=$(test_start_twice_refuses 2>/dev/null); t test_start_twice_refuses "$out" $?
out=$(test_start_clears_stop 2>/dev/null); t test_start_clears_stop "$out" $?
out=$(test_stop_creates_stop 2>/dev/null); t test_stop_creates_stop "$out" $?
out=$(test_stop_nothing_running 2>/dev/null); t test_stop_nothing_running "$out" $?
out=$(test_stop_now_kills 2>/dev/null); t test_stop_now_kills "$out" $?
out=$(test_status_live 2>/dev/null); t test_status_live "$out" $?
out=$(test_status_dirty 2>/dev/null); t test_status_dirty "$out" $?
out=$(test_status_counts 2>/dev/null); t test_status_counts "$out" $?
out=$(test_status_details 2>/dev/null); t test_status_details "$out" $?
out=$(test_session_name_sanitized 2>/dev/null); t test_session_name_sanitized "$out" $?
out=$(test_exact_session_match 2>/dev/null); t test_exact_session_match "$out" $?
out=$(test_exact_match_without_exact_session 2>/dev/null); t test_exact_match_without_exact_session "$out" $?
out=$(test_status_ignores_session_in_detail 2>/dev/null); t test_status_ignores_session_in_detail "$out" $?
out=$(test_start_runner_refuses 2>/dev/null); t test_start_runner_refuses "$out" $?
out=$(test_start_env_scrubbed 2>/dev/null); t test_start_env_scrubbed "$out" $?
out=$(test_stray_file_and_empty_note 2>/dev/null); t test_stray_file_and_empty_note "$out" $?
exit $fail
