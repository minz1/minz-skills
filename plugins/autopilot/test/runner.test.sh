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
  eq "$(tail -1 "$PLAN")" "stopped: $1" "plan.md last line"
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
  sc 1 "AUTOPILOT: WAIT 1 pid=$p"; sc 2 "$DONE"; go; kill $p
  log_has "woke reason=timeout after=60s"; eq "$(slept_total)" 60 "slept"
}
test_wait_pid_gone_at_parse() {
  setup; true >/dev/null & local p=$!; wait $p
  sc 1 "AUTOPILOT: WAIT 1 pid=$p"; sc 2 "$DONE"; go
  log_has "pid $p not found at wait start"; log_has "woke reason=timeout"; log_has 'detail="1"'
}
test_wait_pids_some_gone() {
  setup; sleep 300 >/dev/null 2>&1 & local a=$!; true >/dev/null & local b=$!; wait $b
  sc 1 "AUTOPILOT: WAIT 1 pid=$b,$a"; sc 2 "$DONE"; go; kill $a
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
  nap_hook '[ $1 -ge 2 ] && touch .autopilot/runs/t/STOP; exit 0'; go
  log_has "woke reason=stop after=20s"; expect_calls 1; stopped "stop file"
}
test_limit_nap_ignores_note_and_pid() {
  setup; sleep 300 >/dev/null 2>&1 & local p=$!
  sc 1 "AUTOPILOT: WAIT 1 pid=$p" "$(lim five_hour 600)"; sc 2 "$DONE"
  nap_hook 'echo "- n" >> .autopilot/runs/t/owner.md'; go; kill $p
  local t; t=$(slept_total); ((t >= 590)) || die "slept $t"; log_has "woke reason=timeout"
}
test_limit_nap_wakes_on_stop() {
  setup; sc 1 "" "$(lim five_hour 600)"; sc 2 "$DONE"
  nap_hook '[ $1 -ge 2 ] && touch .autopilot/runs/t/STOP; exit 0'; go
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
test_session_cap_runs_wrapup() {
  setup; set_cap 2; sc 1 "$NEXT"; sc 2 "$NEXT"; sc 3 "$DONE"; go
  call_has 3 "autopilot wrapup"; stopped "session cap 2"
}
test_cap_counts_per_start() {
  setup; set_cap 2; sc 1 "$NEXT"; sc 2 "$NEXT"; sc 3 "$DONE"; go
  FAKE_SCENARIO=$W/scn2; mkdir -p "$FAKE_SCENARIO"; sc 1 "$NEXT"; sc 2 "$NEXT"; sc 3 "$DONE"; go
  call_has 1 "autopilot continue"; call_has 2 "autopilot continue"; call_has 3 "autopilot wrapup"
  log_has "session=4 start"; log_has "session=6 start"
}
test_header_reread_each_loop() {
  setup; set_cap 1
  sc 1 "$NEXT" "$(jq -nc '{exec: "sed -i \"s/^session-cap:.*/session-cap: 3/\" .autopilot/runs/t/plan.md"}')"
  sc 2 "$NEXT"; sc 3 "$DONE"; go
  expect_calls 3; no_wrapup
}
test_rejected_five_hour_sleeps() {
  setup; sc 1 "" "$(lim five_hour 600)"; sc 2 garbage; sc 3 "$DONE"; go
  near "$(slept_total)" 600 slept; all_steps_10
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
  log_has 'session=1 end exit=killed detail="" weekly=? five_hour=? peak_ctx=0'
  gone "$(cat "$FAKE_SCENARIO/fake.pid")" fake-claude
  gone "$(cat "$FAKE_SCENARIO/sleep.pid")" sleep
}

fail=0
t() {
  if [ "$3" = 0 ] && [ -z "$2" ]; then echo "ok $1"; else echo "FAIL $1: rc=$3 $2"; fail=1; fi
}
for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do out=$($f 2>/dev/null); t "$f" "$out" $?; done
exit $fail
