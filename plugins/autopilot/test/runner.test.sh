#!/usr/bin/env bash
DIR=$(cd "$(dirname "$0")" && pwd)
RUNNER=$DIR/../bin/autopilot-runner
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

NEXT='AUTOPILOT: NEXT'
DONE='AUTOPILOT: DONE'
W81='{"usage":{"weekly":0.81,"five_hour":0.1}}'
RC1='{"rc":1}'

die() { echo "$*"; exit 1; }
eq() { [ "$1" = "$2" ] || die "$3: got '$1' want '$2'"; }

setup() {
  W=$(mktemp -d -p "$BASE")
  export HOME=$W/home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FAKE_SCENARIO=$W/scn
  export CLAUDE_BIN=$DIR/fake-claude SLEEP_CMD=$W/record-sleep
  unset TMUX AUTOPILOT_MODEL
  repo=$W/repo
  mkdir -p "$HOME" "$FAKE_SCENARIO" "$repo/.autopilot/runs/t"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" config user.useConfigOnly true
  echo x > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m init
  RUN=$repo/.autopilot/runs/t
  LOG=$RUN/runner.log
  PLAN=$RUN/plan.md
  printf '# run\nweekly-ceiling: 0.80\nsession-cap: 5\n' > "$PLAN"
  cat > "$W/record-sleep" <<SH
#!/bin/sh
echo "slept \$1" >> "$W/slept"
[ -x "$W/on-sleep" ] && "$W/on-sleep" "\$(wc -l < "$W/slept")"
exit 0
SH
  chmod +x "$W/record-sleep"
}

sc() {
  local x=${3:-}
  [ -n "$x" ] || x='{}'
  jq -nc --arg t "$2" --argjson x "$x" '{text: $t} + $x' > "$FAKE_SCENARIO/$1.json"
}

lim() { printf '{"limit":{"status":"rejected","type":"%s","resets_in":%s,"overage":%s}}' "$1" "$2" "${3:-false}"; }
set_cap() { sed -i "s/^session-cap:.*/session-cap: $1/" "$PLAN"; }
go() {
  OUT=$(bash "$RUNNER" "$repo" .autopilot/runs/t 2>"$W/err")
  RC=$?
  ERR=$(cat "$W/err")
}
calls() { cat "$FAKE_SCENARIO/calls" 2>/dev/null; }
expect_calls() { eq "$(calls | wc -l)" "$1" "call count"; }
call_has() { calls | sed -n "${1}p" | grep -qF -- "$2" || die "call $1 lacks '$2': $(calls)"; }
no_wrapup() { ! calls | grep -qF wrapup || die "unexpected wrapup"; }
log_has() { grep -qF -- "$1" "$LOG" || die "runner.log lacks '$1': $(cat "$LOG")"; }
log_lacks() { ! grep -qF -- "$1" "$LOG" || die "runner.log has '$1'"; }
exits() { grep -o ' end exit=[A-Za-z]*' "$LOG" | sed 's/.*exit=//' | paste -sd' '; }
stopped() {
  [[ $(tail -1 "$LOG") == *"stopped: $1" ]] || die "runner.log does not end 'stopped: $1': $(tail -1 "$LOG")"
  eq "$(tail -1 "$RUN/log.md")" "stopped: $1" "log.md last line"
  ! grep -q '^stopped:' "$PLAN" || die "plan.md has a stopped line"
}
slept() { cat "$W/slept" 2>/dev/null; }
slept_total() { awk '{s += $2} END {print s + 0}' "$W/slept" 2>/dev/null || echo 0; }
all_steps_10() { ! grep -qv '^slept 10$' "$W/slept" 2>/dev/null || die "non-10 step: $(sort -u "$W/slept")"; }
nap_hook() { printf '#!/usr/bin/env bash\ncd "%s" || exit 1\n%s\n' "$repo" "$1" > "$W/on-sleep"; chmod +x "$W/on-sleep"; }
near() { (( $1 >= $2 - 10 && $1 <= $2 + 10 )) || die "$3: got $1 want ~$2"; }
gone() {
  for _ in $(seq 20); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  die "$2 (pid $1) still running"
}
waitfor() {
  for _ in $(seq 50); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  die "timeout waiting for '$2'"
}

test_next_relaunches() {
  setup; sc 1 "$NEXT"; sc 2 "$DONE"; go
  eq "$RC" 0 "exit"; expect_calls 2
  call_has 1 "autopilot continue .autopilot/runs/t"; call_has 2 "autopilot continue .autopilot/runs/t"
  for n in 1 2; do
    grep -q "session=$n start" <<<"$OUT" || die "stdout lacks start $n"
    grep -q "session=$n end" <<<"$OUT" || die "stdout lacks end $n"
  done
  grep -qx "$NEXT" <<<"$OUT" || die "stdout lacks final text 1"
  grep -qx "$DONE" <<<"$OUT" || die "stdout lacks final text 2"
  stopped "done"
}
test_wait_sleeps_minutes() {
  setup; sc 1 "AUTOPILOT: WAIT 20"; sc 2 "$DONE"; go
  eq "$(slept_total)" 1200 "slept"; all_steps_10; log_has 'exit=WAIT detail="20"'
  log_has 'woke reason=timeout after=1200s'
}
test_wait_pid_exits_early() {
  setup; sleep 300 >/dev/null 2>&1 & local p=$!
  sc 1 "AUTOPILOT: WAIT 20 pid=$p"; sc 2 "$DONE"
  nap_hook "[ \$1 -ge 3 ] && kill $p; exit 0"; go
  log_has "woke reason=pid:$p"; eq "$(slept_total)" 30 "slept"; log_has "detail=\"20 pid=$p\""
}
test_wait_pid_outlives_deadline() {
  setup; sleep 300 >/dev/null 2>&1 & local p=$!
  sc 1 "AUTOPILOT: WAIT 1 pid=$p"; sc 2 "$DONE"; go; kill "$p"
  log_has "woke reason=timeout after=60s"; eq "$(slept_total)" 60 "slept"
}
test_wait_pid_gone_at_parse() {
  setup; true >/dev/null & local p=$!; wait "$p"
  sc 1 "AUTOPILOT: WAIT 1 pid=$p"; sc 2 "$DONE"; go
  log_has "pid $p not found at wait start"; log_has "woke reason=timeout"; log_has 'detail="1"'
}
test_wait_pids_some_gone() {
  setup; sleep 300 >/dev/null 2>&1 & local a=$!; true >/dev/null & local b=$!; wait "$b"
  sc 1 "AUTOPILOT: WAIT 1 pid=$b,$a"; sc 2 "$DONE"; go; kill "$a"
  log_has "detail=\"1 pid=$a\""
}
test_wait_malformed_pids_plain() {
  setup; sc 1 "AUTOPILOT: WAIT 1 pid=12x"; sc 2 "$DONE"; go
  eq "$(exits)" "WAIT DONE" "exits"; log_has 'malformed'; eq "$(slept_total)" 60 "slept"
}
test_wait_wakes_on_note() {
  setup; sc 1 "AUTOPILOT: WAIT 20"; sc 2 "$DONE"
  nap_hook 'echo "- n" >> .autopilot/runs/t/owner.md'; go
  log_has "woke reason=note"; eq "$(slept_total)" 10 "slept"
}
test_note_during_session_wakes_first_step() {
  setup; echo "- old" > "$RUN/owner.md"
  sc 1 "AUTOPILOT: WAIT 20" '{"exec":"echo \"- new\" >> .autopilot/runs/t/owner.md"}'; sc 2 "$DONE"; go
  log_has "woke reason=note after=0s"; eq "$(slept_total)" 0 "slept"
}
test_old_note_does_not_wake() {
  setup; echo "- old" > "$RUN/owner.md"; sc 1 "AUTOPILOT: WAIT 1"; sc 2 "$DONE"; go
  log_has "woke reason=timeout"
}
test_wait_stop_file_wakes_and_stops() {
  setup; sc 1 "AUTOPILOT: WAIT 20"; sc 2 "$DONE"
  nap_hook "[ \$1 -ge 2 ] && touch .autopilot/runs/t/STOP; exit 0"; go
  log_has "woke reason=stop after=20s"; expect_calls 1; stopped "stop file"
}
test_limit_nap_ignores_note_and_pid() {
  setup; sleep 300 >/dev/null 2>&1 & local p=$!
  sc 1 "AUTOPILOT: WAIT 1 pid=$p" "$(lim five_hour 600)"; sc 2 "$DONE"
  nap_hook 'echo "- n" >> .autopilot/runs/t/owner.md'; go; kill "$p"
  local t; t=$(slept_total); ((t >= 590)) || die "slept $t"; log_has "woke reason=timeout"
}
board_setup() {
  sed -i '/^board:/d' "$PLAN"; echo 'board: ~/.autopilot/t/board/' >> "$PLAN"
  BOARD=$HOME/.autopilot/t/board; mkdir -p "$BOARD"; printf -- '- old line\n' > "$BOARD/peer.md"
}
board_wait() { sc 1 "AUTOPILOT: WAIT ${1:-20}"; sc 2 "$DONE"; }
test_board_wake_addressed() {
  setup; board_setup; board_wait
  nap_hook "[ \$1 -eq 2 ] && echo '- peer-3 → repo: x' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=board:peer.md after=20s"
}
test_board_no_wake_other_repo() {
  setup; board_setup; board_wait 1
  nap_hook "[ \$1 -eq 2 ] && printf -- '- peer-3 → other: x\n- ack other-2: ok\n- back repo-2\n' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=timeout"
}
test_board_wake_whole_name() {
  setup; board_setup; board_wait 1
  nap_hook "[ \$1 -eq 2 ] && echo '- p-1 → repox: x' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=timeout"
  setup; board_setup; board_wait
  nap_hook "[ \$1 -eq 2 ] && echo '- ack repo-2: ok' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=board:peer.md"
}
test_board_wake_multi_recipient() {
  setup; board_setup; board_wait
  nap_hook "[ \$1 -eq 1 ] && echo '- p-1 → other, repo: x' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=board:peer.md after=10s"
}
test_board_wake_reject_and_done() {
  setup; board_setup; board_wait
  nap_hook "[ \$1 -eq 1 ] && echo '- 2026-10-23T07:33Z reject repo-4: y' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=board:peer.md"
  setup; board_setup; board_wait
  nap_hook "[ \$1 -eq 1 ] && echo '- done peer' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=board:peer.md"
}
test_board_mention_is_not_an_answer() {
  setup; board_setup; board_wait 1
  nap_hook "[ \$1 -eq 1 ] && echo '- peer: still waiting on ack repo-3' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=timeout"
}
test_board_own_file_ignored() {
  setup; board_setup; board_wait 1
  nap_hook "[ \$1 -eq 1 ] && echo '- ack repo-1 → repo: x' >> '$BOARD/repo.md'; exit 0"; go
  log_has "woke reason=timeout"
}
test_board_shrunk_file_resets() {
  setup; board_setup; printf -- '- a\n- b\n- c\n' > "$BOARD/peer.md"; board_wait
  nap_hook "[ \$1 -eq 1 ] && echo '- p-1 → repo: x' > '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=board:peer.md"
}
test_board_partial_line() {
  setup; board_setup; board_wait
  nap_hook "case \$1 in 2) printf -- '- p-1 → repo: x' >> '$BOARD/peer.md' ;; 4) printf '\n' >> '$BOARD/peer.md' ;; esac; exit 0"; go
  eq "$(slept_total)" 40 "slept"; eq "$(grep -c 'woke' "$LOG")" 1 "woke lines"; log_has "woke reason=board:peer.md"
}
test_board_new_file_wakes() {
  setup; board_setup; board_wait
  nap_hook "[ \$1 -eq 1 ] && echo '- n-1 → repo: x' > '$BOARD/newpeer.md'; exit 0"; go
  log_has "woke reason=board:newpeer.md"
}
test_board_none_skipped() {
  setup; echo 'board: none' >> "$PLAN"; board_wait 1; go
  log_has "woke reason=timeout"; eq "$ERR" "" "stderr"
}
test_board_during_session_wakes_first_step() {
  setup; board_setup
  sc 1 "AUTOPILOT: WAIT 20" "$(jq -nc --arg f "$BOARD/peer.md" '{exec: ("echo \"- p-1 → repo: x\" >> " + $f)}')"; sc 2 "$DONE"; go
  log_has "woke reason=board:peer.md after=0s"
}
test_limit_nap_ignores_board() {
  setup; board_setup; sc 1 "" "$(lim five_hour 600)"; sc 2 "$DONE"
  nap_hook "[ \$1 -eq 1 ] && echo '- p-1 → repo: x' >> '$BOARD/peer.md'; exit 0"; go
  local t; t=$(slept_total); ((t >= 590)) || die "slept $t"
}
ago_ts() { date -u -d "@$(( $(date +%s) - $1 ))" +%FT%TZ; }
prior_wait() { # <seconds-ago> <detail> [extra line]
  printf '%s session=3 start mode=continue checkpoint=x\n%s session=3 end exit=WAIT detail="%s" weekly=0.1 five_hour=0.1 peak_ctx=1\n' "$(ago_ts "$1")" "$(ago_ts "$1")" "$2" > "$LOG"
  [ -z "${3:-}" ] || echo "$(ago_ts 30) $3" >> "$LOG"
}
test_resume_wait_naps_remainder() {
  setup; prior_wait 300 20; sc 1 "$DONE"; go
  log_has "resume wait"; local t; t=$(slept_total); ((t >= 890 && t <= 910)) || die "slept $t"
  log_has "session=4 start"
}
test_resume_uses_logged_pids() {
  setup; sleep 300 >/dev/null 2>&1 & local p=$!
  prior_wait 60 "20 pid=$p"; sc 1 "$DONE"
  nap_hook "[ \$1 -ge 2 ] && kill $p; exit 0"; go
  log_has "woke reason=pid:$p after=20s"
}
test_resume_dead_pid_wakes() {
  setup; true >/dev/null & local p=$!; wait "$p"
  prior_wait 60 "20 pid=$p"; sc 1 "$DONE"; go
  log_has "woke reason=pid:$p after=0s"; expect_calls 1
}
test_resume_expired_starts_session() {
  setup; prior_wait 1500 20; sc 1 "$DONE"; go
  log_lacks "resume wait"; eq "$(slept_total)" 0 "slept"; expect_calls 1
}
test_resume_skipped_after_woke() {
  setup; prior_wait 120 20 "woke reason=board:x after=60s"; sc 1 "$DONE"; go
  log_lacks "resume wait"; eq "$(slept_total)" 0 "slept"
}
test_resume_skipped_after_stopped() {
  setup; prior_wait 120 20 "stopped: stop file"; sc 1 "$DONE"; go
  log_lacks "resume wait"
}
test_resume_skipped_on_exec_path() {
  setup; prior_wait 120 20
  sc 1 "$DONE" "$(jq -nc --arg f "$FAKE_SCENARIO/env" '{exec: ("env | grep ^AUTOPILOT_ >> " + $f + "; true")}')"
  AUTOPILOT_RESUME_MODE='continue' go
  log_lacks "resume wait"; ! grep -q RESUME "$FAKE_SCENARIO/env" 2>/dev/null || die "resume env leaked"
}
test_resume_stop_wakes() {
  setup; prior_wait 120 20; sc 1 "$DONE"
  nap_hook "[ \$1 -ge 1 ] && touch .autopilot/runs/t/STOP; exit 0"; go
  log_has "resume wait"; log_has "woke reason=stop"; expect_calls 0; stopped "stop file"
}
test_kill_signal_named() {
  setup; sc 1 "$NEXT" '{"sleep":30}'
  bash "$RUNNER" "$repo" .autopilot/runs/t >"$W/out" 2>&1 &
  local pid=$!
  waitfor "$LOG" "session=1 start"; waitfor "$FAKE_SCENARIO/sleep.pid" ""
  kill -HUP "$pid"; wait "$pid"
  log_has 'session=1 end exit=killed detail="HUP"'
  sleep 0.3; ! pgrep -f "$W/repo" >/dev/null || die "watchdog left after HUP"
}
test_stop_posts_to_own_board() {
  setup; board_setup; sc 1 "AUTOPILOT: STOP need owner"; go
  tail -1 "$BOARD/repo.md" | grep -qE '^- repo: runner stopped [0-9T:-]+Z: owner needed: need owner$' || die "board: $(cat "$BOARD/repo.md")"
}
test_stop_no_board_no_file() {
  setup; sc 1 "$DONE"; go
  [ ! -e "$HOME/.autopilot/t" ] || die "board dir created"
}
hook() {
  mkdir -p "$HOME/.config/autopilot"
  printf '#!/bin/sh\n%s\necho "$*" >> "%s/notified"\n' "${1:-}" "$W" > "$HOME/.config/autopilot/notify"
  chmod +x "$HOME/.config/autopilot/notify"
}
notified() { cat "$W/notified" 2>/dev/null; }
test_notify_stopped() {
  setup; hook; sc 1 "$DONE"; go
  waitfor "$W/notified" "repo t stopped done"
}
test_notify_blocked_new_only() {
  setup; hook; printf -- '- [!] 2. x\n- [ ] 3. y\n' >> "$PLAN"
  sc 1 "$NEXT" '{"exec":"sed -i \"s/^- \\[ \\] 3\\./- [!] 3./\" .autopilot/runs/t/plan.md"}'; sc 2 "$DONE"; go
  waitfor "$W/notified" "stopped done"
  eq "$(grep -c ' blocked ' "$W/notified")" 1 "blocked lines"; grep -q 'blocked - \[!\] 3. y' "$W/notified" || die "$(notified)"
}
test_notify_blocked_revisit() {
  setup; hook; printf -- '- [!] 2. x\n' >> "$PLAN"
  sc 1 "$NEXT" '{"exec":"sed -i \"s/^- \\[!\\] 2\\. x/- [!!] 2. x revisit failed/\" .autopilot/runs/t/plan.md"}'; sc 2 "$DONE"; go
  waitfor "$W/notified" "stopped done"; grep -q 'blocked - \[!!\] 2. x revisit failed' "$W/notified" || die "$(notified)"
}
test_notify_blocked_detail_capped() {
  setup; hook; local long; long=$(printf 'y%.0s' $(seq 300))
  printf -- '- [ ] 3. %s\n' "$long" >> "$PLAN"
  sc 1 "$NEXT" '{"exec":"sed -i \"s/^- \\[ \\] 3\\./- [!] 3./\" .autopilot/runs/t/plan.md"}'; sc 2 "$DONE"; go
  waitfor "$W/notified" "stopped done"
  local l; l=$(grep ' blocked ' "$W/notified"); l=${l#repo t blocked }; eq "${#l}" 200 "detail length"
}
test_notify_missing_hook_ok() { setup; sc 1 "$DONE"; go; stopped "done"; }
test_notify_non_executable_skipped() {
  setup; hook; chmod -x "$HOME/.config/autopilot/notify"; sc 1 "$DONE"; go; sleep 0.3
  [ ! -e "$W/notified" ] || die "ran"
}
test_notify_failing_hook_ok() { setup; hook 'exit 1'; sc 1 "$DONE"; go; stopped "done"; }
test_notify_hanging_hook_ok() {
  setup; hook 'sleep 100'; sc 1 "$NEXT"; sc 2 "$DONE"; local t0=$SECONDS; go
  ((SECONDS - t0 < 5)) || die "slow"; stopped "done"
}
test_stall_alert() {
  setup; hook; export AUTOPILOT_STALL_EVERY=1 AUTOPILOT_STALL_AFTER=1
  sc 1 "$DONE" '{"sleep":3}'; go
  waitfor "$W/notified" "stopped done"
  eq "$(grep -c 'repo t stalled session 1 silent' "$W/notified")" 1 "stalled lines"
  ! grep -qv '^slept 10$' "$W/slept" 2>/dev/null || die "watchdog used SLEEP_CMD"
  ! pgrep -f "$W/repo" >/dev/null || die "watchdog left running"
}
test_stall_rearms() {
  setup; hook; export AUTOPILOT_STALL_EVERY=1 AUTOPILOT_STALL_AFTER=2
  sc 1 "$DONE" '{"sleep":8,"exec":"( sleep 4; echo \"{}\" ) &"}'; go
  waitfor "$W/notified" "stopped done"
  eq "$(grep -c 'stalled session 1' "$W/notified")" 2 "stalled lines"
}
fake_cache() {
  CACHE=$HOME/.claude/plugins/cache/m/autopilot
  local v
  for v in "$@"; do mkdir -p "$CACHE/$v/bin"; cp "$RUNNER" "$CACHE/$v/bin/autopilot-runner"; done
}
install_v() {
  mkdir -p "$HOME/.claude/plugins"
  printf '{"version":2,"plugins":{"autopilot@m":[{"scope":"user","installPath":"%s"}]}}\n' "$HOME/.claude/plugins/cache/m/autopilot/$1" > "$HOME/.claude/plugins/installed_plugins.json"
}
export -f install_v
go_from() {
  OUT=$(bash "$CACHE/$1/bin/autopilot-runner" "$repo" .autopilot/runs/t 2>"$W/err")
  RC=$?
  ERR=$(cat "$W/err")
}
test_upgrade_execs_new_version() {
  setup; fake_cache v1 v2; install_v v1
  sc 1 "$NEXT" '{"exec":"install_v v2"}'; sc 2 "$DONE"; go_from v1
  log_has "runner start version=v1"; log_has "upgrade v1 -> v2"; log_has "runner start version=v2"
  expect_calls 2; call_has 2 "autopilot continue"; stopped "done"
}
test_upgrade_carries_wrapup() {
  setup; fake_cache v1 v2; install_v v1
  sc 1 "$NEXT" "$(jq -nc '{exec: "install_v v2", usage: {weekly: 0.81, five_hour: 0.1}}')"; sc 2 "$DONE"; go_from v1
  log_has "upgrade v1 -> v2"; call_has 2 "autopilot wrapup"; stopped "weekly usage 0.81"
}
test_upgrade_refuses_bad_syntax() {
  setup; fake_cache v1 v2; echo 'if' >> "$CACHE/v2/bin/autopilot-runner"; install_v v2
  sc 1 "$NEXT"; sc 2 "$NEXT"; sc 3 "$DONE"; go_from v1
  eq "$(grep -c 'upgrade skipped: ' "$LOG")" 1 "skip lines"; log_lacks "version=v2"; expect_calls 3
}
test_upgrade_symlink_same() {
  setup; fake_cache v1; ln -s "$CACHE/v1" "$CACHE/link"; install_v link
  sc 1 "$NEXT"; sc 2 "$DONE"; go_from v1
  log_lacks "upgrade"; expect_calls 2
}
test_no_upgrade_from_worktree() {
  setup; fake_cache v2; install_v v2; sc 1 "$NEXT"; sc 2 "$DONE"; go
  log_lacks "upgrade"
}
test_no_upgrade_missing_json() {
  setup; fake_cache v1 v2; sc 1 "$NEXT"; sc 2 "$DONE"; go_from v1
  log_lacks "upgrade"; stopped "done"
}
test_no_upgrade_garbage_json() {
  setup; fake_cache v1 v2; mkdir -p "$HOME/.claude/plugins"; echo '{nope' > "$HOME/.claude/plugins/installed_plugins.json"
  sc 1 "$NEXT"; sc 2 "$DONE"; go_from v1
  log_lacks "upgrade"; stopped "done"
}
test_no_upgrade_pinned() {
  setup; fake_cache v1 v2; install_v v2; sc 1 "$NEXT"; sc 2 "$DONE"
  AUTOPILOT_NO_UPGRADE=1 go_from v1
  log_lacks "upgrade"; stopped "done"
}
test_exec_path_bad_header_stops() {
  setup; hook; sed -i '/^weekly-ceiling:/d' "$PLAN"; sc 1 "$DONE"
  AUTOPILOT_RESUME_MODE='continue' go
  expect_calls 0; stopped ".autopilot/runs/t/plan.md has no valid weekly-ceiling"
  waitfor "$W/notified" "stopped .autopilot/runs/t/plan.md has no valid weekly-ceiling"
}
test_runner_start_after_header() {
  setup; sed -i '/^weekly-ceiling:/d' "$PLAN"; sc 1 "$DONE"; go
  [ ! -s "$LOG" ] || die "log written: $(cat "$LOG")"
}
test_resume_after_stop_now_line() {
  setup; prior_wait 300 20 "stop --now by owner"; sc 1 "$DONE"; go
  log_has "resume wait"
}
test_wait_pid_other_user_kept() {
  setup; sc 1 "AUTOPILOT: WAIT 1 pid=1"; sc 2 "$DONE"; go
  log_lacks "pid 1 not found"; log_has 'detail="1 pid=1"'; log_has "woke reason=timeout"
}
NOWAIT_EVENTS='{"events":[{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Waiting on the reviewer."}]}},{"type":"system","subtype":"task_notification","task_id":"a1","status":"stopped"}]}'
test_nowait_logged() {
  setup; sc 1 "" "$NOWAIT_EVENTS"; sc 2 "$DONE"; go
  eq "$(exits)" "nowait DONE" "exits"; expect_calls 2
}
test_two_nowaits_stop() {
  setup; sc 1 "" "$NOWAIT_EVENTS"; sc 2 "" "$NOWAIT_EVENTS"; go
  stopped "two crashes"
}
test_stopped_task_before_last_message_is_crash() {
  setup; sc 1 "" '{"events":[{"type":"system","subtype":"task_notification","task_id":"a1","status":"stopped"},{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"done"}]}}]}'
  sc 2 "$DONE"; go
  eq "$(exits)" "crash DONE" "exits"
}
test_board_ping_pong_paused() {
  setup; hook; board_setup
  local i; for i in $(seq 13); do sc "$i" "AUTOPILOT: WAIT 1"; done; sc 14 "$NEXT"; sc 15 "AUTOPILOT: WAIT 1"; sc 16 "$DONE"
  nap_hook "echo '- p-1 → repo: x' >> '$BOARD/peer.md'; exit 0"; go
  eq "$(grep -c 'woke reason=board' "$LOG")" 11 "board wakes"; eq "$(grep -c 'woke reason=timeout' "$LOG")" 3 "timeouts"
  waitfor "$W/notified" "stopped done"
  eq "$(grep -c 'stalled 10 board-woken waits in a row' "$W/notified")" 1 "stalled notices"
}
test_exit_word_escapes_cleaned() {
  setup; sc 1 $'AUTOPILOT: STOP a\033]0;pwn\007b'; go
  ! grep -qP '\x1b|\x07' <<<"$OUT" || die "control chars in stdout"; ! grep -qP '\x1b|\x07' "$LOG" || die "control chars in log"
  stopped "owner needed: a]0;pwnb"
}
test_upgrade_ignores_project_scope() {
  setup; fake_cache v1 v2; mkdir -p "$HOME/.claude/plugins"
  printf '{"plugins":{"autopilot@m":[{"scope":"project","installPath":"%s"},{"scope":"user","installPath":"%s"}]}}\n' "$CACHE/v2" "$CACHE/v1" > "$HOME/.claude/plugins/installed_plugins.json"
  sc 1 "$NEXT"; sc 2 "$DONE"; go_from v1
  log_lacks "upgrade"
}
test_watchdog_exits_after_runner_sigkill() {
  setup; export AUTOPILOT_STALL_EVERY=1; sc 1 "$NEXT" '{"sleep":30}'
  bash "$RUNNER" "$repo" .autopilot/runs/t >"$W/out" 2>&1 &
  local pid=$!
  waitfor "$LOG" "session=1 start"; waitfor "$FAKE_SCENARIO/sleep.pid" ""
  kill -KILL "$pid"; wait "$pid" 2>/dev/null; sleep 3
  local left; left=$(pgrep -f "$W/repo"); kill "$(cat "$FAKE_SCENARIO/fake.pid")" "$(cat "$FAKE_SCENARIO/sleep.pid")" 2>/dev/null
  [ -z "$left" ] || die "watchdog survived: $left"
}
test_runner_text_cleaned() {
  setup; sc 1 $'hi\033]0;x\007\nAUTOPILOT: DONE'; go
  ! grep -qP '\x1b|\x07' <<<"$OUT" || die "control chars in runner output"
}
test_notify_owner_section() {
  setup; hook; printf '## Owner\n- old\n## Handoff\n' >> "$PLAN"
  sc 1 "$NEXT" '{"exec":"sed -i \"s/^- old$/- old\\n- decide the ramp/\" .autopilot/runs/t/plan.md"}'; sc 2 "$DONE"; go
  waitfor "$W/notified" "stopped done"; grep -q 'repo t owner - decide the ramp' "$W/notified" || die "$(notified)"
  eq "$(grep -c ' owner ' "$W/notified")" 1 "owner lines"
}
test_global_ceiling_lower() {
  setup; mkdir -p "$HOME/.config/autopilot"; echo 0.50 > "$HOME/.config/autopilot/weekly-ceiling"
  sc 1 "$NEXT" '{"usage":{"weekly":0.55,"five_hour":0.1}}'; sc 2 "$DONE"; go
  call_has 2 wrapup; stopped "weekly usage 0.55"
}
test_global_ceiling_garbage_ignored() {
  setup; mkdir -p "$HOME/.config/autopilot"; echo 'lots' > "$HOME/.config/autopilot/weekly-ceiling"
  sc 1 "$NEXT" '{"usage":{"weekly":0.55,"five_hour":0.1}}'; sc 2 "$DONE"; go
  no_wrapup
}

test_board_owner_line_wakes() {
  setup; board_setup; board_wait
  nap_hook "[ \$1 -eq 1 ] && echo '- 2026-10-23T09:00:00Z owner → repo: hold deploys' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=board:peer.md after=10s"
}
test_owner_heading_exact() {
  setup; hook; printf '## Owner notes\n## Handoff\n' >> "$PLAN"
  sc 1 "$NEXT" '{"exec":"sed -i \"s/^## Owner notes$/## Owner notes\\n- not an owner line/\" .autopilot/runs/t/plan.md"}'; sc 2 "$DONE"; go
  waitfor "$W/notified" "stopped done"; ! grep -q ' owner ' "$W/notified" || die "$(notified)"
}

test_wait_ack_wakes_on_answer() {
  setup; board_setup; sc 1 "AUTOPILOT: WAIT ack repo-3"; sc 2 "$DONE"
  nap_hook "[ \$1 -eq 2 ] && echo '- 2026-10-23T12:00Z ack repo-3: live, healthy' >> '$BOARD/peer.md'; exit 0"; go
  log_has 'exit=WAIT detail="360 ack=repo-3"'; log_has "woke reason=ack:repo-3 after=20s"
}
test_wait_ack_already_answered() {
  setup; board_setup; echo '- nack repo-3: rolled back' >> "$BOARD/peer.md"
  sc 1 "AUTOPILOT: WAIT ack repo-3"; sc 2 "$DONE"; go
  log_has "woke reason=ack:repo-3 after=0s"
}
test_wait_ack_other_id_does_not_wake() {
  setup; board_setup; sed -i '/^ack-timeout:/d' "$PLAN"; echo 'ack-timeout: 1m' >> "$PLAN"
  sc 1 "AUTOPILOT: WAIT ack repo-3"; sc 2 "$DONE"
  nap_hook "[ \$1 -eq 1 ] && echo '- ack repo-30: ok' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=timeout after=60s"
}
test_wait_ack_timeout_alerts() {
  setup; hook; board_setup; echo 'ack-timeout: 2m' >> "$PLAN"; sc 1 "AUTOPILOT: WAIT ack repo-3"; sc 2 "$DONE"; go
  log_has 'detail="2 ack=repo-3"'; log_has "woke reason=timeout after=120s"
  waitfor "$W/notified" "repo t stalled ack repo-3 overdue"
}
test_wait_ack_hours_and_minutes() {
  setup; board_setup; echo 'ack-timeout: 90m' >> "$PLAN"; sc 1 "AUTOPILOT: WAIT ack repo-3"; sc 2 "$DONE"; go
  log_has 'detail="90 ack=repo-3"'
}
test_wait_ack_peer_stop_wakes() {
  setup; board_setup; sc 1 "AUTOPILOT: WAIT ack repo-3"; sc 2 "$DONE"
  nap_hook "[ \$1 -eq 1 ] && echo '- peer: runner stopped 2026-10-23T12:00:00Z: two crashes' >> '$BOARD/peer.md'; exit 0"; go
  log_has "woke reason=board:peer.md after=10s"
}
test_wait_ack_bad_id_is_crash() { setup; sc 1 "AUTOPILOT: WAIT ack nope"; sc 2 "$DONE"; go; eq "$(exits)" "crash DONE" exits; }
test_resume_ack_wait() {
  setup; board_setup; prior_wait 60 "360 ack=repo-3"; echo '- ack repo-3: ok' >> "$BOARD/peer.md"; sc 1 "$DONE"; go
  log_has "resume wait"; log_has "woke reason=ack:repo-3 after=0s"
}
test_limit_nap_wakes_on_stop() {
  setup; sc 1 "" "$(lim five_hour 600)"; sc 2 "$DONE"
  nap_hook "[ \$1 -ge 2 ] && touch .autopilot/runs/t/STOP; exit 0"; go
  log_has "woke reason=stop"; stopped "stop file"
}
test_wait_bad_minutes_is_crash() {
  setup; sc 1 "AUTOPILOT: WAIT soon"; sc 2 "$DONE"; go
  eq "$(exits)" "crash DONE" "exits"
}
test_template_plan_starts() {
  setup
  cp "$DIR/../skills/autopilot/templates/plan.md" "$PLAN"
  sc 1 "$DONE"
  go
  expect_calls 1
}
test_done_exits() { setup; sc 1 "$DONE"; go; expect_calls 1; stopped "done"; }
test_stop_exits() {
  setup; sc 1 "AUTOPILOT: STOP needs owner"; go
  expect_calls 1; no_wrapup
  log_has 'exit=STOP detail="needs owner"'; stopped "owner needed: needs owner"
}
test_wait_zero_is_crash() {
  setup; sc 1 "AUTOPILOT: WAIT 0"; sc 2 "$DONE"; go
  eq "$(exits)" "crash DONE" "exits"
}
test_multiline_final_text() {
  setup; sc 1 $'did things\n\nAUTOPILOT: NEXT\n'; sc 2 "$DONE"; go
  expect_calls 2; eq "$(exits)" "NEXT DONE" "exits"
}
test_trailing_plugin_text() {
  setup; sc 1 $'AUTOPILOT: NEXT\n\nSkipped: nothing. No risk.'; sc 2 "$DONE"; go
  expect_calls 2; eq "$(exits)" "NEXT DONE" "exits"
}
test_last_marker_wins() {
  setup; sc 1 $'AUTOPILOT: WAIT 5\nAUTOPILOT: NEXT'; sc 2 "$DONE"; go
  eq "$(slept)" "" "slept"; log_has "exit=NEXT"
}
test_bare_word_is_crash() {
  setup; sc 1 "NEXT"; sc 2 "$DONE"; go
  eq "$(exits)" "crash DONE" "exits"
}
test_trailing_space_ok() {
  setup; sc 1 "AUTOPILOT: NEXT  "; sc 2 "$DONE"; go
  expect_calls 2; eq "$(exits)" "NEXT DONE" "exits"
}
test_garbled_word_is_crash() {
  setup; sc 1 "AUTOPILOT: Next."; sc 2 "**AUTOPILOT: NEXT**"; go
  stopped "two crashes"
}
test_one_crash_retries() {
  setup; sc 1 garbage; sc 2 "$DONE"; go
  eq "$(exits)" "crash DONE" "exits"
}
test_two_crashes_stop() {
  setup; sc 1 x "$RC1"; sc 2 x "$RC1"; go
  expect_calls 2; stopped "two crashes"
}
test_valid_word_nonzero_rc_is_crash() {
  setup; sc 1 "$NEXT" "$RC1"; sc 2 "$DONE"; go
  eq "$(exits)" "crash DONE" "exits"
}
test_crash_counter_resets() {
  setup; sc 1 garbage; sc 2 "$NEXT"; sc 3 garbage; sc 4 "$DONE"; go
  expect_calls 4; log_lacks "stopped: two crashes"
}
test_ceiling_runs_wrapup_then_stops() {
  setup; sc 1 "$NEXT" "$W81"; sc 2 "$DONE"; go
  call_has 2 "autopilot wrapup .autopilot/runs/t"; stopped "weekly usage 0.81"
}
test_done_beats_ceiling() {
  setup; sc 1 "$DONE" "$W81"; go
  expect_calls 1; no_wrapup; stopped "done"
}
test_stop_beats_ceiling() {
  setup; sc 1 "AUTOPILOT: STOP x" "$W81"; go
  expect_calls 1; no_wrapup
}
CAPMSG="session cap 2 reached; raise session-cap in plan.md to continue"
test_session_cap_runs_wrapup() {
  setup; set_cap 2; sc 1 "$NEXT"; sc 2 "$NEXT"; sc 3 "$DONE"; go
  call_has 3 "autopilot wrapup"; stopped "$CAPMSG"
}
test_cap_counts_work_not_waits() {
  setup; set_cap 2; sc 1 "AUTOPILOT: WAIT 1"; sc 2 "$NEXT"; sc 3 "AUTOPILOT: WAIT 1"; sc 4 "$NEXT"; sc 5 "$DONE"; go
  expect_calls 5; call_has 4 "autopilot continue"; call_has 5 "autopilot wrapup"
}
test_cap_survives_restart() {
  setup; set_cap 2
  printf '%s session=1 end exit=NEXT detail="" w\n%s session=2 end exit=NEXT detail="" w\n' "$(date -u +%FT%TZ)" "$(date -u +%FT%TZ)" > "$LOG"
  sc 1 "$DONE"; go
  call_has 1 "autopilot wrapup"; log_has "session=3 start"; stopped "$CAPMSG"
}
test_header_reread_each_loop() {
  setup; set_cap 1
  sc 1 "$NEXT" "$(jq -nc '{exec: "sed -i \"s/^session-cap:.*/session-cap: 3/\" .autopilot/runs/t/plan.md"}')"
  sc 2 "$NEXT"; sc 3 "$DONE"; go
  expect_calls 3; no_wrapup
}
test_rejected_five_hour_sleeps() {
  setup; sc 1 "" "$(lim five_hour 600)"; sc 2 garbage; sc 3 "$DONE"; go
  near "$(slept_total)" 600 slept
  eq "$(exits)" "limit crash DONE" "exits"
}
test_rejected_past_reset_min_sleep() {
  setup; sc 1 "" "$(lim five_hour -10)"; sc 2 "$DONE"; go
  eq "$(slept_total)" 60 "slept"; all_steps_10
}
test_limit_beats_exit_word() {
  setup; sc 1 "$NEXT" "$(lim five_hour 600)"; sc 2 "$DONE"; go
  eq "$(exits)" "limit DONE" "exits"
  near "$(slept_total)" 600 slept
}
test_rejected_weekly_stops() {
  setup; sc 1 "" "$(lim seven_day_opus 600)"; go
  expect_calls 1; no_wrapup; stopped "limit seven_day_opus reached"
}
test_unknown_limit_type_stops() {
  setup; sc 1 "" "$(lim mystery_window 600)"; go
  expect_calls 1; stopped "limit mystery_window reached"
}
test_wrapup_next_still_stops() {
  setup; sc 1 "$NEXT" "$W81"; sc 2 "$NEXT"; go
  expect_calls 2; stopped "weekly usage 0.81"
}
test_killed_while_sleeping() {
  setup
  cat > "$W/nap" <<SH
#!/bin/sh
echo \$\$ > "$W/nap.pid"
exec sleep "\$1"
SH
  chmod +x "$W/nap"; export SLEEP_CMD=$W/nap
  sc 1 "AUTOPILOT: WAIT 20"; sc 2 "$DONE"
  timeout 30 bash "$RUNNER" "$repo" .autopilot/runs/t >"$W/out" 2>&1 &
  local pid=$!
  waitfor "$LOG" "exit=WAIT"; waitfor "$W/nap.pid" ""
  kill -TERM "$pid"; wait "$pid"; RC=$?
  eq "$RC" 130 "exit"
  eq "$(grep -c 'session=1 end' "$LOG")" 1 "end lines"; eq "$(exits)" WAIT "exits"
  gone "$(cat "$W/nap.pid")" nap
}
test_wrapup_crash_retries_wrapup() {
  setup; sc 1 "$NEXT" "$W81"; sc 2 garbage; sc 3 "$DONE"; go
  expect_calls 3; call_has 2 wrapup; call_has 3 wrapup
}
test_wrapup_limited_five_hour_retries() {
  setup; sc 1 "$NEXT" "$W81"; sc 2 "" "$(lim five_hour 60)"; sc 3 "$DONE"; go
  expect_calls 3; call_has 2 wrapup; call_has 3 wrapup; eq "$(slept_total)" 60 "slept"
}
test_rejected_with_overage_ignored() {
  setup; sc 1 "$NEXT" "$(lim five_hour 600 true)"; sc 2 "$DONE"; go
  expect_calls 2; eq "$(slept)" "" "slept"
}
test_missing_rate_limit_event() {
  setup; sc 1 "$NEXT" '{"usage":null}'; sc 2 "$DONE"; go
  log_has "weekly=?"; no_wrapup
}
test_missing_header_refuses() {
  local f
  for f in session-cap weekly-ceiling; do
    setup; sed -i "/^$f:/d" "$PLAN"; sc 1 "$DONE"; go
    [ "$RC" -ne 0 ] || die "$f: exit 0"
    grep -qF "$f" <<<"$ERR" || die "$f: stderr '$ERR'"
    expect_calls 0
  done
}
test_stop_file_before_start() {
  setup; touch "$RUN/STOP"; sc 1 "$DONE"; go
  expect_calls 0; stopped "stop file"
}
test_stop_file_between_sessions() {
  setup; sc 1 "$NEXT" '{"exec":"touch .autopilot/runs/t/STOP"}'; sc 2 "$DONE"; go
  expect_calls 1; stopped "stop file"
}
test_start_and_end_lines() {
  setup; sc 1 "$NEXT"; sc 2 "$DONE"; go
  local n s e
  for n in 1 2; do
    s=$(grep -n "session=$n start" "$LOG" | cut -d: -f1)
    e=$(grep -n "session=$n end" "$LOG" | cut -d: -f1)
    [ -n "$s" ] || die "session $n has no start"
    [ -n "$e" ] || die "session $n has no end"
    [ "$s" -lt "$e" ] || die "session $n start=$s end=$e"
  done
}
test_checkpoint_refs() {
  setup; echo y >> "$repo/a.txt"; git -C "$repo" add a.txt; echo n > "$repo/new.txt"
  local cached head
  cached=$(git -C "$repo" diff --cached); head=$(git -C "$repo" rev-parse HEAD)
  sc 1 "$NEXT"; sc 2 "$DONE"; go
  local n sha
  for n in 1 2; do
    sha=$(git -C "$repo" rev-parse --verify "refs/autopilot/t/$n") || die "ref $n missing"
    log_has "session=$n start mode=continue checkpoint=$sha"
  done
  git -C "$repo" ls-tree -r --name-only refs/autopilot/t/1 | grep -qx new.txt || die "new.txt not in checkpoint"
  eq "$(git -C "$repo" diff --cached)" "$cached" "index"
  eq "$(git -C "$repo" rev-parse HEAD)" "$head" "HEAD"
}
test_checkpoint_no_identity() {
  setup; sc 1 "$DONE"; go
  git -C "$repo" rev-parse --verify refs/autopilot/t/1 >/dev/null || die "ref missing: $ERR"
}
test_checkpoint_author() {
  setup; sc 1 "$DONE"; go
  eq "$(git -C "$repo" log -1 --format=%an refs/autopilot/t/1)" autopilot "author"
}
test_checkpoint_failure() {
  setup; rm -rf "$repo/.git"; git -C "$repo" init -q 2>/dev/null; sc 1 "$DONE"; go
  expect_calls 0; stopped "checkpoint failed"
}
test_header_broken_mid_run() {
  setup; sc 1 "$NEXT" '{"exec":"sed -i /^session-cap:/d .autopilot/runs/t/plan.md"}'; sc 2 "$DONE"; go
  expect_calls 1; stopped ".autopilot/runs/t/plan.md has no valid session-cap"
}
test_invalid_cap_refused() {
  setup; set_cap 1x; sc 1 "$DONE"; go
  [ "$RC" -ne 0 ] || die "exit 0"
  grep -qF session-cap <<<"$ERR" || die "stderr '$ERR'"
  expect_calls 0
}
test_stop_reason_with_quotes() {
  setup; sc 1 'AUTOPILOT: STOP say "hi" session=99'; go
  FAKE_SCENARIO=$W/scn2; mkdir -p "$FAKE_SCENARIO"; sc 1 "$DONE"; go
  log_has "session=2 start"; log_lacks "session=100"
}
test_checkpoint_skips_ignored() {
  setup; echo ".autopilot/runs/" > "$repo/.gitignore"; sc 1 "$DONE"; go
  ! git -C "$repo" ls-tree -r --name-only refs/autopilot/t/1 | grep -q '^\.autopilot/runs/' || die "ignored path in checkpoint"
  git -C "$repo" rev-parse --verify refs/autopilot/t/1 >/dev/null || die "ref missing"
}
test_peak_ctx_logged() { setup; sc 1 "$DONE"; go; log_has "peak_ctx=43005"; }
test_peak_ctx_ignores_subagents() {
  setup; sc 1 "$DONE" '{"subagent_ctx":150000}'; go; log_has "peak_ctx=43005"
}
test_flags() {
  setup; export AUTOPILOT_MODEL=haiku; sc 1 "$DONE"; go
  local f
  for f in "--permission-mode auto" "--add-dir $HOME/.autopilot" "--output-format stream-json" "--verbose" "--model haiku" "COMPACT=200000"; do
    call_has 1 "$f"
  done
}
test_claude_env_scrubbed() {
  setup; sc 1 "$DONE"
  CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=x go
  calls | sed -n 1p | grep -q 'CLAUDE_VARS=$' || die "claude saw CLAUDE vars: $(calls)"
}
test_stream_saved() {
  setup; sc 1 "$DONE"; go
  eq "$(wc -l < "$RUN/sessions/1.jsonl")" 4 "stream lines"
}
test_killed_logs_end() {
  setup; sc 1 "$NEXT" '{"sleep":30}'
  bash "$RUNNER" "$repo" .autopilot/runs/t >"$W/out" 2>&1 &
  local pid=$! t0
  waitfor "$LOG" "session=1 start"; waitfor "$FAKE_SCENARIO/sleep.pid" ""
  t0=$SECONDS; kill -TERM "$pid"; wait "$pid"; RC=$?
  eq "$RC" 130 "exit"
  [ $((SECONDS - t0)) -le 3 ] || die "slow exit"
  log_has 'session=1 end exit=killed detail="TERM" weekly=? five_hour=? peak_ctx=0'
  gone "$(cat "$FAKE_SCENARIO/fake.pid")" fake-claude
  gone "$(cat "$FAKE_SCENARIO/sleep.pid")" sleep
}

fail=0
t() {
  if [ "$3" = 0 ] && [ -z "$2" ]; then echo "ok $1"; else echo "FAIL $1: rc=$3 $2"; fail=1; fi
}
out=$(test_next_relaunches 2>/dev/null); t test_next_relaunches "$out" $?
out=$(test_wait_sleeps_minutes 2>/dev/null); t test_wait_sleeps_minutes "$out" $?
out=$(test_wait_pid_exits_early 2>/dev/null); t test_wait_pid_exits_early "$out" $?
out=$(test_wait_pid_outlives_deadline 2>/dev/null); t test_wait_pid_outlives_deadline "$out" $?
out=$(test_wait_pid_gone_at_parse 2>/dev/null); t test_wait_pid_gone_at_parse "$out" $?
out=$(test_wait_pids_some_gone 2>/dev/null); t test_wait_pids_some_gone "$out" $?
out=$(test_wait_malformed_pids_plain 2>/dev/null); t test_wait_malformed_pids_plain "$out" $?
out=$(test_wait_wakes_on_note 2>/dev/null); t test_wait_wakes_on_note "$out" $?
out=$(test_note_during_session_wakes_first_step 2>/dev/null); t test_note_during_session_wakes_first_step "$out" $?
out=$(test_old_note_does_not_wake 2>/dev/null); t test_old_note_does_not_wake "$out" $?
out=$(test_wait_stop_file_wakes_and_stops 2>/dev/null); t test_wait_stop_file_wakes_and_stops "$out" $?
out=$(test_limit_nap_ignores_note_and_pid 2>/dev/null); t test_limit_nap_ignores_note_and_pid "$out" $?
out=$(test_board_wake_addressed 2>/dev/null); t test_board_wake_addressed "$out" $?
out=$(test_board_no_wake_other_repo 2>/dev/null); t test_board_no_wake_other_repo "$out" $?
out=$(test_board_wake_whole_name 2>/dev/null); t test_board_wake_whole_name "$out" $?
out=$(test_board_wake_multi_recipient 2>/dev/null); t test_board_wake_multi_recipient "$out" $?
out=$(test_board_wake_reject_and_done 2>/dev/null); t test_board_wake_reject_and_done "$out" $?
out=$(test_board_mention_is_not_an_answer 2>/dev/null); t test_board_mention_is_not_an_answer "$out" $?
out=$(test_board_own_file_ignored 2>/dev/null); t test_board_own_file_ignored "$out" $?
out=$(test_board_shrunk_file_resets 2>/dev/null); t test_board_shrunk_file_resets "$out" $?
out=$(test_board_partial_line 2>/dev/null); t test_board_partial_line "$out" $?
out=$(test_board_new_file_wakes 2>/dev/null); t test_board_new_file_wakes "$out" $?
out=$(test_board_none_skipped 2>/dev/null); t test_board_none_skipped "$out" $?
out=$(test_board_during_session_wakes_first_step 2>/dev/null); t test_board_during_session_wakes_first_step "$out" $?
out=$(test_limit_nap_ignores_board 2>/dev/null); t test_limit_nap_ignores_board "$out" $?
out=$(test_resume_wait_naps_remainder 2>/dev/null); t test_resume_wait_naps_remainder "$out" $?
out=$(test_resume_uses_logged_pids 2>/dev/null); t test_resume_uses_logged_pids "$out" $?
out=$(test_resume_dead_pid_wakes 2>/dev/null); t test_resume_dead_pid_wakes "$out" $?
out=$(test_resume_expired_starts_session 2>/dev/null); t test_resume_expired_starts_session "$out" $?
out=$(test_resume_skipped_after_woke 2>/dev/null); t test_resume_skipped_after_woke "$out" $?
out=$(test_resume_skipped_after_stopped 2>/dev/null); t test_resume_skipped_after_stopped "$out" $?
out=$(test_resume_skipped_on_exec_path 2>/dev/null); t test_resume_skipped_on_exec_path "$out" $?
out=$(test_resume_stop_wakes 2>/dev/null); t test_resume_stop_wakes "$out" $?
out=$(test_kill_signal_named 2>/dev/null); t test_kill_signal_named "$out" $?
out=$(test_stop_posts_to_own_board 2>/dev/null); t test_stop_posts_to_own_board "$out" $?
out=$(test_stop_no_board_no_file 2>/dev/null); t test_stop_no_board_no_file "$out" $?
out=$(test_notify_stopped 2>/dev/null); t test_notify_stopped "$out" $?
out=$(test_notify_blocked_new_only 2>/dev/null); t test_notify_blocked_new_only "$out" $?
out=$(test_notify_blocked_revisit 2>/dev/null); t test_notify_blocked_revisit "$out" $?
out=$(test_notify_blocked_detail_capped 2>/dev/null); t test_notify_blocked_detail_capped "$out" $?
out=$(test_notify_missing_hook_ok 2>/dev/null); t test_notify_missing_hook_ok "$out" $?
out=$(test_notify_non_executable_skipped 2>/dev/null); t test_notify_non_executable_skipped "$out" $?
out=$(test_notify_failing_hook_ok 2>/dev/null); t test_notify_failing_hook_ok "$out" $?
out=$(test_notify_hanging_hook_ok 2>/dev/null); t test_notify_hanging_hook_ok "$out" $?
out=$(test_stall_alert 2>/dev/null); t test_stall_alert "$out" $?
out=$(test_stall_rearms 2>/dev/null); t test_stall_rearms "$out" $?
out=$(test_upgrade_execs_new_version 2>/dev/null); t test_upgrade_execs_new_version "$out" $?
out=$(test_upgrade_carries_wrapup 2>/dev/null); t test_upgrade_carries_wrapup "$out" $?
out=$(test_upgrade_refuses_bad_syntax 2>/dev/null); t test_upgrade_refuses_bad_syntax "$out" $?
out=$(test_upgrade_symlink_same 2>/dev/null); t test_upgrade_symlink_same "$out" $?
out=$(test_no_upgrade_from_worktree 2>/dev/null); t test_no_upgrade_from_worktree "$out" $?
out=$(test_no_upgrade_missing_json 2>/dev/null); t test_no_upgrade_missing_json "$out" $?
out=$(test_no_upgrade_garbage_json 2>/dev/null); t test_no_upgrade_garbage_json "$out" $?
out=$(test_no_upgrade_pinned 2>/dev/null); t test_no_upgrade_pinned "$out" $?
out=$(test_exec_path_bad_header_stops 2>/dev/null); t test_exec_path_bad_header_stops "$out" $?
out=$(test_runner_start_after_header 2>/dev/null); t test_runner_start_after_header "$out" $?
out=$(test_resume_after_stop_now_line 2>/dev/null); t test_resume_after_stop_now_line "$out" $?
out=$(test_wait_pid_other_user_kept 2>/dev/null); t test_wait_pid_other_user_kept "$out" $?
out=$(test_nowait_logged 2>/dev/null); t test_nowait_logged "$out" $?
out=$(test_two_nowaits_stop 2>/dev/null); t test_two_nowaits_stop "$out" $?
out=$(test_stopped_task_before_last_message_is_crash 2>/dev/null); t test_stopped_task_before_last_message_is_crash "$out" $?
out=$(test_board_ping_pong_paused 2>/dev/null); t test_board_ping_pong_paused "$out" $?
out=$(test_exit_word_escapes_cleaned 2>/dev/null); t test_exit_word_escapes_cleaned "$out" $?
out=$(test_upgrade_ignores_project_scope 2>/dev/null); t test_upgrade_ignores_project_scope "$out" $?
out=$(test_watchdog_exits_after_runner_sigkill 2>/dev/null); t test_watchdog_exits_after_runner_sigkill "$out" $?
out=$(test_runner_text_cleaned 2>/dev/null); t test_runner_text_cleaned "$out" $?
out=$(test_notify_owner_section 2>/dev/null); t test_notify_owner_section "$out" $?
out=$(test_global_ceiling_lower 2>/dev/null); t test_global_ceiling_lower "$out" $?
out=$(test_global_ceiling_garbage_ignored 2>/dev/null); t test_global_ceiling_garbage_ignored "$out" $?
out=$(test_board_owner_line_wakes 2>/dev/null); t test_board_owner_line_wakes "$out" $?
out=$(test_owner_heading_exact 2>/dev/null); t test_owner_heading_exact "$out" $?
out=$(test_wait_ack_wakes_on_answer 2>/dev/null); t test_wait_ack_wakes_on_answer "$out" $?
out=$(test_wait_ack_already_answered 2>/dev/null); t test_wait_ack_already_answered "$out" $?
out=$(test_wait_ack_other_id_does_not_wake 2>/dev/null); t test_wait_ack_other_id_does_not_wake "$out" $?
out=$(test_wait_ack_timeout_alerts 2>/dev/null); t test_wait_ack_timeout_alerts "$out" $?
out=$(test_wait_ack_hours_and_minutes 2>/dev/null); t test_wait_ack_hours_and_minutes "$out" $?
out=$(test_wait_ack_peer_stop_wakes 2>/dev/null); t test_wait_ack_peer_stop_wakes "$out" $?
out=$(test_wait_ack_bad_id_is_crash 2>/dev/null); t test_wait_ack_bad_id_is_crash "$out" $?
out=$(test_resume_ack_wait 2>/dev/null); t test_resume_ack_wait "$out" $?
out=$(test_limit_nap_wakes_on_stop 2>/dev/null); t test_limit_nap_wakes_on_stop "$out" $?
out=$(test_wait_bad_minutes_is_crash 2>/dev/null); t test_wait_bad_minutes_is_crash "$out" $?
out=$(test_template_plan_starts 2>/dev/null); t test_template_plan_starts "$out" $?
out=$(test_done_exits 2>/dev/null); t test_done_exits "$out" $?
out=$(test_stop_exits 2>/dev/null); t test_stop_exits "$out" $?
out=$(test_wait_zero_is_crash 2>/dev/null); t test_wait_zero_is_crash "$out" $?
out=$(test_multiline_final_text 2>/dev/null); t test_multiline_final_text "$out" $?
out=$(test_trailing_plugin_text 2>/dev/null); t test_trailing_plugin_text "$out" $?
out=$(test_last_marker_wins 2>/dev/null); t test_last_marker_wins "$out" $?
out=$(test_bare_word_is_crash 2>/dev/null); t test_bare_word_is_crash "$out" $?
out=$(test_trailing_space_ok 2>/dev/null); t test_trailing_space_ok "$out" $?
out=$(test_garbled_word_is_crash 2>/dev/null); t test_garbled_word_is_crash "$out" $?
out=$(test_one_crash_retries 2>/dev/null); t test_one_crash_retries "$out" $?
out=$(test_two_crashes_stop 2>/dev/null); t test_two_crashes_stop "$out" $?
out=$(test_valid_word_nonzero_rc_is_crash 2>/dev/null); t test_valid_word_nonzero_rc_is_crash "$out" $?
out=$(test_crash_counter_resets 2>/dev/null); t test_crash_counter_resets "$out" $?
out=$(test_ceiling_runs_wrapup_then_stops 2>/dev/null); t test_ceiling_runs_wrapup_then_stops "$out" $?
out=$(test_done_beats_ceiling 2>/dev/null); t test_done_beats_ceiling "$out" $?
out=$(test_stop_beats_ceiling 2>/dev/null); t test_stop_beats_ceiling "$out" $?
out=$(test_session_cap_runs_wrapup 2>/dev/null); t test_session_cap_runs_wrapup "$out" $?
out=$(test_cap_counts_work_not_waits 2>/dev/null); t test_cap_counts_work_not_waits "$out" $?
out=$(test_cap_survives_restart 2>/dev/null); t test_cap_survives_restart "$out" $?
out=$(test_header_reread_each_loop 2>/dev/null); t test_header_reread_each_loop "$out" $?
out=$(test_rejected_five_hour_sleeps 2>/dev/null); t test_rejected_five_hour_sleeps "$out" $?
out=$(test_rejected_past_reset_min_sleep 2>/dev/null); t test_rejected_past_reset_min_sleep "$out" $?
out=$(test_limit_beats_exit_word 2>/dev/null); t test_limit_beats_exit_word "$out" $?
out=$(test_rejected_weekly_stops 2>/dev/null); t test_rejected_weekly_stops "$out" $?
out=$(test_unknown_limit_type_stops 2>/dev/null); t test_unknown_limit_type_stops "$out" $?
out=$(test_wrapup_next_still_stops 2>/dev/null); t test_wrapup_next_still_stops "$out" $?
out=$(test_killed_while_sleeping 2>/dev/null); t test_killed_while_sleeping "$out" $?
out=$(test_wrapup_crash_retries_wrapup 2>/dev/null); t test_wrapup_crash_retries_wrapup "$out" $?
out=$(test_wrapup_limited_five_hour_retries 2>/dev/null); t test_wrapup_limited_five_hour_retries "$out" $?
out=$(test_rejected_with_overage_ignored 2>/dev/null); t test_rejected_with_overage_ignored "$out" $?
out=$(test_missing_rate_limit_event 2>/dev/null); t test_missing_rate_limit_event "$out" $?
out=$(test_missing_header_refuses 2>/dev/null); t test_missing_header_refuses "$out" $?
out=$(test_stop_file_before_start 2>/dev/null); t test_stop_file_before_start "$out" $?
out=$(test_stop_file_between_sessions 2>/dev/null); t test_stop_file_between_sessions "$out" $?
out=$(test_start_and_end_lines 2>/dev/null); t test_start_and_end_lines "$out" $?
out=$(test_checkpoint_refs 2>/dev/null); t test_checkpoint_refs "$out" $?
out=$(test_checkpoint_no_identity 2>/dev/null); t test_checkpoint_no_identity "$out" $?
out=$(test_checkpoint_author 2>/dev/null); t test_checkpoint_author "$out" $?
out=$(test_checkpoint_failure 2>/dev/null); t test_checkpoint_failure "$out" $?
out=$(test_header_broken_mid_run 2>/dev/null); t test_header_broken_mid_run "$out" $?
out=$(test_invalid_cap_refused 2>/dev/null); t test_invalid_cap_refused "$out" $?
out=$(test_stop_reason_with_quotes 2>/dev/null); t test_stop_reason_with_quotes "$out" $?
out=$(test_checkpoint_skips_ignored 2>/dev/null); t test_checkpoint_skips_ignored "$out" $?
out=$(test_peak_ctx_logged 2>/dev/null); t test_peak_ctx_logged "$out" $?
out=$(test_peak_ctx_ignores_subagents 2>/dev/null); t test_peak_ctx_ignores_subagents "$out" $?
out=$(test_flags 2>/dev/null); t test_flags "$out" $?
out=$(test_claude_env_scrubbed 2>/dev/null); t test_claude_env_scrubbed "$out" $?
out=$(test_stream_saved 2>/dev/null); t test_stream_saved "$out" $?
out=$(test_killed_logs_end 2>/dev/null); t test_killed_logs_end "$out" $?
for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do grep -q "^out=\$($f " "$0" || { echo "FAIL $f: not registered"; fail=1; }; done
exit $fail
