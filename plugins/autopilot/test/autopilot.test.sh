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
  re='^- [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z skip APU$'
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
  has "$OUT" "stops within ~10 s if waiting" stdout
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
test_stop_now_logs_owner() {
  setup; start_run; ap stop --now
  tmux_gone autopilot-repo; waitfor "$LOG" "exit=killed"
  local o k
  o=$(grep -n 'stop --now by owner' "$LOG" | cut -d: -f1); k=$(grep -n 'exit=killed' "$LOG" | cut -d: -f1)
  if [ -z "$o" ] || [ "$o" -ge "$k" ]; then die "order: $(cat "$LOG")"; fi
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

ts_ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%FT%TZ; }
test_status_running_session() {
  setup; start_run; ap status
  has "$OUT" "running, session 1 since " status
}
test_status_waiting_until() {
  setup; sc 1 "AUTOPILOT: DONE"
  local t; t=$(date +%s)
  tmux new-session -d -s autopilot-repo 'sleep 600'
  printf '%s session=3 start mode=continue checkpoint=x\n%s session=3 end exit=WAIT detail="20 pid=77" weekly=0.1 five_hour=0.1 peak_ctx=1\n' "$(date -u -d "@$t" +%FT%TZ)" "$(date -u -d "@$t" +%FT%TZ)" > "$LOG"
  ap status
  has "$OUT" "waiting until $(date -u -d @$((t + 1200)) +%FT%TZ) (WAIT 20 from session 3, pids 77)" status
}
test_status_woke_is_running() {
  setup; tmux new-session -d -s autopilot-repo 'sleep 600'
  printf '%s session=3 end exit=WAIT detail="20" w\n%s woke reason=board:x after=10s\n' "$(ts_ago 60)" "$(ts_ago 50)" > "$LOG"
  ap status; lacks "$OUT" "waiting until" status
}
test_status_stopped_reason() {
  setup
  printf '%s session=1 end exit=STOP detail="x" w\n%s stopped: owner needed: x\n' "$(ts_ago 60)" "$(ts_ago 60)" > "$LOG"
  ap status; has "$OUT" "stopped: owner needed: x" status
}
test_status_now_and_fallback() {
  setup
  printf '%s\n' '- [x] 1. a' '- [ ] 2. second' '- [ ] 9. ninth item' >> "$R2/plan.md"
  ap status; has "$OUT" "now: 2. second" status
  sed -i '1a now: 9' "$R2/plan.md"; ap status; has "$OUT" "now: 9. ninth item" status
  printf -- '- [ ] 10. %s\n' "$(printf 'z%.0s' $(seq 300))" >> "$R2/plan.md"; sed -i 's/^now: 9/now: 10/' "$R2/plan.md"
  ap status; local l; l=$(grep '^now: ' <<<"$OUT"); eq "${#l}" 165 "now line length"
}
test_status_sessions_and_notes() {
  setup
  for e in NEXT WAIT NEXT WAIT NEXT; do echo "$(ts_ago 999) session=1 end exit=$e detail=\"\" w" >> "$LOG"; done
  sed -i '1a owner-notes-applied: 4' "$R2/plan.md"
  for i in 1 2 3 4 5; do echo "- n$i" >> "$R2/owner.md"; done
  ap status; has "$OUT" "sessions 3/5 · notes 4/5" status
}
test_status_full_handoff() {
  setup; { echo '## Handoff'; for i in $(seq 20); do echo "h$i"; done; } >> "$R2/plan.md"
  ap status; has "$OUT" "h15" status; lacks "$OUT" "h16" status
}
test_status_board_lines() {
  setup; mkdir -p "$HOME/.autopilot/b"; echo 'board: ~/.autopilot/b/' >> "$R2/plan.md"
  printf -- '- old\n- p-1 → repo: newest\n' > "$HOME/.autopilot/b/peer.md"
  ap status; has "$OUT" "board:" status; has "$OUT" "peer  p-1 → repo: newest" status
}
test_status_repo_with_space() {
  setup "my repo"; printf '%s\n' '- [ ] 1. a' >> "$R2/plan.md"; ap status
  eq "$RC" 0 "rc"; has "$OUT" "now: 1. a" status
}
test_note_utc_and_confirm() {
  setup; ap note one; ap note two
  has "$OUT" "note 2 added; a waiting run wakes within ~10 s" stdout
}
test_start_passes_no_upgrade() {
  setup; tmux kill-server; tmux_gone bootstrap
  export AUTOPILOT_NO_UPGRADE=1 AUTOPILOT_STALL_AFTER=5 AUTOPILOT_RESUME_MODE=wrapup
  start_run
  s=$(tmux show-environment -t "=autopilot-repo" | cut -d= -f1)
  grep -qx AUTOPILOT_NO_UPGRADE <<<"$s" || die "no NO_UPGRADE"
  grep -qx AUTOPILOT_STALL_AFTER <<<"$s" || die "no STALL_AFTER"
  ! grep -qx AUTOPILOT_RESUME_MODE <<<"$s" || die "RESUME leaked"
  g=$(tmux show-environment -g | cut -d= -f1)
  ! grep -qx AUTOPILOT_RESUME_MODE <<<"$g" || die "RESUME in global env"
}
test_start_quoting() {
  setup "it's \$(touch pwned) r"; sc 1 "AUTOPILOT: DONE"; ap start
  eq "$RC" 0 rc; waitfor "$LOG" "stopped: done"
  if [ -e "$W/pwned" ] || [ -e "$repo/pwned" ]; then die "injection ran"; fi
}
test_status_cleans_control_chars() {
  setup; printf -- '- [ ] 1. a\033]0;t\007b\n## Handoff\nh\033[2Jx\n' >> "$R2/plan.md"; printf 'now: x[\n' >> "$R2/plan.md"
  ap status
  ! grep -qP '\x1b|\x07' <<<"$OUT" || die "control chars in status"; eq "$ERR" "" stderr; has "$OUT" "now: 1. a]0;tb" now
}
test_usage_lists_dash_register_launcher() {
  setup; ap bogus; eq "$RC" 2 rc
  has "$ERR" "dash" usage; has "$ERR" "register" usage; has "$ERR" "launcher" usage; lacks "$ERR" "watch" usage
}
test_watch_is_usage_error() { setup; ap watch; eq "$RC" 2 rc; has "$ERR" "usage:" stderr; }
test_dash_needs_tty() {
  setup; ap dash </dev/null; [ "$RC" != 0 ] || die "rc 0"; has "$ERR" "run autopilot dash in a terminal" stderr
}
test_dash_needs_uv() {
  setup; local out rc
  out=$(PATH=/usr/bin:/bin script -qec "bash '$AP' dash" /dev/null 2>&1 </dev/null); rc=$?
  [ "$rc" != 0 ] || die "rc 0: $out"; has "$out" "autopilot dash needs uv: https://docs.astral.sh/uv/" output
}
registry() { cat "$HOME/.config/autopilot/repos" 2>/dev/null; }
test_register_dedupes() {
  setup; ap register; eq "$RC" 0 rc; eq "$OUT$ERR" "" output
  (cd "$repo/sub" && bash "$AP" register)
  eq "$(registry)" "$(git rev-parse --show-toplevel)" registry
  [ -e "$HOME/.config/autopilot/repos.lock" ] || die "no lock file"
}
test_start_registers() {
  setup; start_run; eq "$(registry)" "$(git rev-parse --show-toplevel)" registry
}
test_launcher_installs() {
  setup; local dest=$HOME/.local/bin/autopilot
  PATH=/usr/bin:/bin ap launcher; eq "$RC" 0 rc
  has "$OUT" "$dest" stdout; has "$ERR" "$HOME/.local/bin is not on PATH" stderr
  [ -x "$dest" ] || die "not executable"; cmp -s "$dest" "$DIR/../bin/autopilot-launcher" || die "differs"
  PATH=$HOME/.local/bin:$PATH ap launcher; eq "$ERR" "" "stderr with ~/.local/bin on PATH"
}
fake_install() { # <key> <scope> <installPath>
  mkdir -p "$HOME/.claude/plugins" "$3/bin"
  printf '#!/usr/bin/env bash\necho "OK $*"\n' > "$3/bin/autopilot"; chmod +x "$3/bin/autopilot"
  jq -n --arg k "$1" --arg s "$2" --arg p "$3" '{plugins: {($k): [{scope: $s, installPath: $p}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
}
launch() { OUT=$(bash "$DIR/../bin/autopilot-launcher" "$@" 2>"$W/err"); RC=$?; ERR=$(cat "$W/err"); }
test_launcher_resolves() {
  setup; fake_install autopilot@minz-skills user "$HOME/.claude/plugins/cache/minz-skills/autopilot/1.2.3"
  launch note "a b"; eq "$RC" 0 rc; eq "$OUT" "OK note a b" stdout
}
test_launcher_rejects_other_key_and_path() {
  local cache want="autopilot plugin not installed (run: claude plugin install autopilot@minz-skills)"
  setup; cache=$HOME/.claude/plugins/cache/minz-skills/autopilot/1.2.3
  fake_install autopilot@other user "$cache"; launch status; eq "$RC" 1 rc; eq "$ERR" "$want" "other key"
  fake_install autopilot@minz-skills project "$cache"; launch status; eq "$RC" 1 rc; eq "$ERR" "$want" "project scope"
  fake_install autopilot@minz-skills user "$W/evil"; launch status; eq "$RC" 1 rc; eq "$ERR" "$want" "outside cache"
  mkdir -p "$cache"; ln -s "$W/evil" "$cache/link"
  fake_install autopilot@minz-skills user "$cache/link"; launch status; eq "$RC" 1 rc; eq "$ERR" "$want" "symlink out"
  rm -f "$HOME/.claude/plugins/installed_plugins.json"; launch status; eq "$RC" 1 rc; eq "$ERR" "$want" "no file"
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

test_status_new_states() {
  setup; printf '%s\n' '- [x] 1. a' '- [x] 2. b' '- [c] 3. c' '- [p] 4. d' '- [ ] 5. e' >> "$R2/plan.md"
  ap status; has "$OUT" "2 done, 1 committed, 1 pushed, 0 blocked, 1 open" status
}
test_status_owner_section() {
  setup; printf '%s\n' '## Owner' '- o1' '- o2' '- o3' '- o4' '## Handoff' 'h' >> "$R2/plan.md"
  ap status; has "$OUT" "owner: 4" status; has "$OUT" "  - o3" status; lacks "$OUT" "  - o4" status
}
test_note_once() { setup; ap note --once "skip it"; grep -qE '^- [0-9T:-]+Z \[once\] skip it$' "$R2/owner.md" || die "$(cat "$R2/owner.md")"; }
test_note_to_peer() {
  setup; mkdir -p "$HOME/.autopilot/b"; echo 'board: ~/.autopilot/b/' >> "$R2/plan.md"
  ap note --to nixfiles "hold deploys"
  eq "$RC" 0 rc; grep -qE '^- [0-9T:-]+Z owner → nixfiles: hold deploys$' "$HOME/.autopilot/b/repo.md" || die "board: $(cat "$HOME/.autopilot/b/repo.md")"
  has "$(cat "$R2/owner.md")" "hold deploys" owner.md
}
test_note_to_without_board() { setup; ap note --to x "hi"; [ "$RC" != 0 ] || die "rc 0"; has "$ERR" "no board for this run" stderr; }
test_note_warns_done_item() {
  setup; echo '- [x] 3. thing' >> "$R2/plan.md"; ap note "item 3 should change"
  has "$ERR" "warning: item 3 is already done" stderr; has "$(cat "$R2/owner.md")" "item 3 should change" owner.md
}

test_board_trailing_space() {
  setup; mkdir -p "$HOME/.autopilot/b"; echo 'board: ~/.autopilot/b/  ' >> "$R2/plan.md"; printf -- '- p-1 → repo: hi\n' > "$HOME/.autopilot/b/p.md"
  ap status; has "$OUT" "board:" status
  ap note --to p "x"; eq "$RC" 0 "note rc"; grep -q 'owner → p: x' "$HOME/.autopilot/b/repo.md" || die "no owner line"
  grep -qE '^- [0-9T:-]+Z \[to p\] x$' "$R2/owner.md" || die "owner.md: $(cat "$R2/owner.md")"
}

test_status_waiting_for_ack() {
  setup; tmux new-session -d -s autopilot-repo 'sleep 600'
  printf '%s session=3 end exit=WAIT detail="360 ack=repo-7" w\n' "$(date -u +%FT%TZ)" > "$LOG"
  ap status; has "$OUT" "running, waiting for ack repo-7 (alert at " status
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
out=$(test_stop_now_logs_owner 2>/dev/null); t test_stop_now_logs_owner "$out" $?
out=$(test_status_live 2>/dev/null); t test_status_live "$out" $?
out=$(test_status_dirty 2>/dev/null); t test_status_dirty "$out" $?
out=$(test_status_counts 2>/dev/null); t test_status_counts "$out" $?
out=$(test_status_details 2>/dev/null); t test_status_details "$out" $?
out=$(test_status_running_session 2>/dev/null); t test_status_running_session "$out" $?
out=$(test_status_waiting_until 2>/dev/null); t test_status_waiting_until "$out" $?
out=$(test_status_woke_is_running 2>/dev/null); t test_status_woke_is_running "$out" $?
out=$(test_status_stopped_reason 2>/dev/null); t test_status_stopped_reason "$out" $?
out=$(test_status_now_and_fallback 2>/dev/null); t test_status_now_and_fallback "$out" $?
out=$(test_status_sessions_and_notes 2>/dev/null); t test_status_sessions_and_notes "$out" $?
out=$(test_status_full_handoff 2>/dev/null); t test_status_full_handoff "$out" $?
out=$(test_status_board_lines 2>/dev/null); t test_status_board_lines "$out" $?
out=$(test_status_repo_with_space 2>/dev/null); t test_status_repo_with_space "$out" $?
out=$(test_note_utc_and_confirm 2>/dev/null); t test_note_utc_and_confirm "$out" $?
out=$(test_start_passes_no_upgrade 2>/dev/null); t test_start_passes_no_upgrade "$out" $?
out=$(test_start_quoting 2>/dev/null); t test_start_quoting "$out" $?
out=$(test_status_cleans_control_chars 2>/dev/null); t test_status_cleans_control_chars "$out" $?
out=$(test_usage_lists_dash_register_launcher 2>/dev/null); t test_usage_lists_dash_register_launcher "$out" $?
out=$(test_watch_is_usage_error 2>/dev/null); t test_watch_is_usage_error "$out" $?
out=$(test_dash_needs_tty 2>/dev/null); t test_dash_needs_tty "$out" $?
out=$(test_dash_needs_uv 2>/dev/null); t test_dash_needs_uv "$out" $?
out=$(test_register_dedupes 2>/dev/null); t test_register_dedupes "$out" $?
out=$(test_start_registers 2>/dev/null); t test_start_registers "$out" $?
out=$(test_launcher_installs 2>/dev/null); t test_launcher_installs "$out" $?
out=$(test_launcher_resolves 2>/dev/null); t test_launcher_resolves "$out" $?
out=$(test_launcher_rejects_other_key_and_path 2>/dev/null); t test_launcher_rejects_other_key_and_path "$out" $?
out=$(test_session_name_sanitized 2>/dev/null); t test_session_name_sanitized "$out" $?
out=$(test_exact_session_match 2>/dev/null); t test_exact_session_match "$out" $?
out=$(test_exact_match_without_exact_session 2>/dev/null); t test_exact_match_without_exact_session "$out" $?
out=$(test_status_ignores_session_in_detail 2>/dev/null); t test_status_ignores_session_in_detail "$out" $?
out=$(test_start_runner_refuses 2>/dev/null); t test_start_runner_refuses "$out" $?
out=$(test_start_env_scrubbed 2>/dev/null); t test_start_env_scrubbed "$out" $?
out=$(test_stray_file_and_empty_note 2>/dev/null); t test_stray_file_and_empty_note "$out" $?
out=$(test_status_new_states 2>/dev/null); t test_status_new_states "$out" $?
out=$(test_status_owner_section 2>/dev/null); t test_status_owner_section "$out" $?
out=$(test_note_once 2>/dev/null); t test_note_once "$out" $?
out=$(test_note_to_peer 2>/dev/null); t test_note_to_peer "$out" $?
out=$(test_note_to_without_board 2>/dev/null); t test_note_to_without_board "$out" $?
out=$(test_note_warns_done_item 2>/dev/null); t test_note_warns_done_item "$out" $?
out=$(test_board_trailing_space 2>/dev/null); t test_board_trailing_space "$out" $?
out=$(test_status_waiting_for_ack 2>/dev/null); t test_status_waiting_for_ack "$out" $?
for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do grep -q "^out=\$($f " "$0" || { echo "FAIL $f: not registered"; fail=1; }; done
exit $fail
