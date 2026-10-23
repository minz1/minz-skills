#!/usr/bin/env bash
unset TMUX
DIR=$(cd "$(dirname "$0")" && pwd)
WATCH=$DIR/../bin/autopilot-watch
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

die() { echo "$*"; exit 1; }
eq() { [ "$1" = "$2" ] || die "$3: got '$1' want '$2'"; }
has() { grep -qF -- "$2" <<<"$1" || die "$3 lacks '$2': $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || die "$3 has '$2': $1"; }
plain() { sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

NOW=1792700000
ts() { date -u -d "@$((NOW - $1))" +%FT%TZ; }

setup() {
  W=$(mktemp -d -p "$BASE")
  export TMUX_TMPDIR=$W/tmux HOME=$W/home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 AUTOPILOT_NOW=$NOW
  mkdir -p "$TMUX_TMPDIR" "$HOME"
  trap 'tmux kill-server 2>/dev/null' EXIT
  repo=$W/${1:-repo}
  RUN=$repo/.autopilot/runs/2026-10-22
  LOG=$RUN/runner.log PLAN=$RUN/plan.md
  mkdir -p "$RUN/sessions"
  git init -q -b main "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  printf '# run\nweekly-ceiling: 0.80\nsession-cap: 60\nowner-notes-applied: 0\n' > "$PLAN"
}
live() { tmux new-session -d -s "autopilot-$(basename "$repo")" 'sleep 600'; }
session_start() { # <n> <stream-age-seconds>
  echo "$(ts 999) session=$1 start mode=continue checkpoint=x" >> "$LOG"
  echo '{}' > "$RUN/sessions/$1.jsonl"; touch -d "@$((NOW - $2))" "$RUN/sessions/$1.jsonl"
}
session_end() { echo "$(ts "${3:-999}") session=$1 end exit=$2 weekly=0.17 five_hour=0.14 peak_ctx=81000" >> "$LOG"; }
frame() { OUT=$(bash "$WATCH" --once --width "${W_:-100}" --height "${H_:-20}" "$@" "$repo" | plain); }
first() { head -1 <<<"$OUT"; }

test_state_working() { setup; live; session_start 4 60; frame; has "$(first)" "repo · WORKING s4" header; }
test_state_quiet() { setup; live; session_start 4 600; frame; has "$(first)" "QUIET 10m · s4" header; }
test_state_stalled() { setup; live; session_start 4 4000; frame; has "$(first)" "STALLED 66m silent" header; }
test_state_waiting() {
  setup; live; session_start 3 999; session_end 3 'WAIT detail="20 pid=77"' 300; frame
  has "$(first)" "WAITING next ≤15m · pid 77" header
}
test_state_done() { setup; session_start 3 999; session_end 3 'DONE detail=""'; echo "$(ts 1) stopped: done" >> "$LOG"; frame; has "$(first)" "STOPPED: done" header; }
test_state_killed_is_red() {
  setup; session_start 3 999; session_end 3 'killed detail="TERM"'
  OUT=$(bash "$WATCH" --once --width 100 --height 10 "$repo"); has "$(head -1 <<<"$OUT")" $'\033[41;30;1m' header
}
test_state_blocked_is_red() {
  setup; live; session_start 3 10; printf -- '- [!] 2. x\n' >> "$PLAN"
  OUT=$(bash "$WATCH" --once --width 100 --height 10 "$repo"); has "$(head -1 <<<"$OUT")" $'\033[41;30;1m' header
  has "$(plain <<<"$OUT" | head -1)" "1 blocked" header
}
test_info_rows() {
  setup; printf -- '- [x] 1. a\n- [ ] 2. second\n- [ ] 9. ninth  check: x\n' >> "$PLAN"; sed -i 's/^owner-notes-applied: 0/owner-notes-applied: 4/' "$PLAN"
  for i in 1 2 3 4 5; do echo "- n$i" >> "$RUN/owner.md"; done
  session_end 1 'NEXT detail=""'; session_end 2 'WAIT detail="20"'; session_end 3 'crash detail=""'; session_end 4 'NEXT detail=""'
  git init -q --bare "$W/remote.git"; git -C "$repo" push -q "$W/remote.git" main 2>/dev/null; git -C "$repo" branch -q -u "$W/remote.git/main" 2>/dev/null || git -C "$repo" remote add o "$W/remote.git"
  git -C "$repo" fetch -q o 2>/dev/null; git -C "$repo" branch -q -u o/main 2>/dev/null
  frame
  has "$OUT" "item 2. second" item; has "$OUT" "work 3/60" work; has "$OUT" "last N W ✗ N" last
  has "$OUT" "notes 4/5 (1 pending)" notes; has "$OUT" "main  ·  +0 unpushed" branch; has "$OUT" "ctx 81k" ctx
  sed -i '1a now: 9' "$PLAN"; frame; has "$OUT" "item 9. ninth" now; lacks "$OUT" "check: x" now
}
mkstream() {
  {
    echo '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"hello there"}]}}'
    echo '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"thinking","thinking":""}]}}'
    echo '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls","description":"List files"}}]}}'
    printf '%s\n' '{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","is_error":true,"content":"boom\nmore"}]}}'
    echo '{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/y"}}]}}'
  } > "$RUN/sessions/4.jsonl"
  touch -d "@$NOW" "$RUN/sessions/4.jsonl"
}
test_render_stream() {
  setup; live; session_start 4 1; mkstream; frame
  has "$OUT" "hello there" text; has "$OUT" "▸ Bash List files" tool; has "$OUT" "✗ boom" error; lacks "$OUT" "more" error
  has "$OUT" "│ ▸ Read /x/y" sub; lacks "$OUT" "· thinking" think; has "$OUT" "sub✓(1)" count
  frame --sub 0; lacks "$OUT" "Read /x/y" sub0
  frame --think 1; has "$OUT" "· thinking" think1
  frame --compact 1; lacks "$OUT" "hello there" compact; has "$OUT" "▸ Bash" compact
}
test_fit_width_and_height() {
  setup; live; session_start 4 1; mkstream
  W_=30 H_=12 frame
  eq "$(bash "$WATCH" --once --width 30 --height 12 "$repo" | wc -l)" 12 lines
  while IFS= read -r l; do ((${#l} <= 30)) || die "wide line (${#l}): $l"; done <<<"$OUT"
}
test_board_open_requests() {
  setup; local b=$W/board; mkdir -p "$b"
  printf -- '- a-1 → b: x\n- a-2 → b: y\n' > "$b/a.md"; printf -- '- ack a-1: ok\n' > "$b/b.md"
  OUT=$(bash "$WATCH" board --once --width 100 --height 4 "$b" | plain)
  has "$(head -1 <<<"$OUT")" "open: a-2 → b" open; lacks "$(head -1 <<<"$OUT")" "a-1 →" open
  has "$OUT" "b           ack a-1: ok" last
}
test_hostile_plan_values() {
  setup; sed -i "s/^owner-notes-applied: 0/owner-notes-applied: a[\$(touch ${W//\//\\/}\/pwned)]/" "$PLAN"; echo "- n" > "$RUN/owner.md"
  printf 'now: 1|.*\n' >> "$PLAN"; frame
  [ ! -e "$W/pwned" ] || die "arithmetic injection ran"; has "$OUT" "notes 0/1" notes
}
test_control_chars_stripped() {
  setup; live; session_start 4 1
  printf '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"a\\u001b]52;c;Zm9v\\u0007b"}]}}\n' > "$RUN/sessions/4.jsonl"
  printf -- '- [ ] 1. x\033]0;title\007y\n' >> "$PLAN"
  local b=$W/board; mkdir -p "$b"; printf -- '- p-1 → r\033[2Jx: y\n' > "$b/p.md"
  local raw; raw=$(bash "$WATCH" --once --width 100 --height 12 "$repo"; bash "$WATCH" board --once --width 100 --height 3 "$b")
  ! grep -qP '\x1b\]|\x07|\x1b\[2J' <<<"$raw" || die "control sequence passed through"
  has "$raw" "Zm9vb" text
}
test_spaced_repo() { setup "my repo"; live; session_start 1 1; frame; has "$(first)" "my repo · WORKING s1" header; }

test_new_states_and_owner() {
  setup; live; session_start 4 10; printf '%s\n' '- [x] 1. a' '- [c] 2. b' '- [p] 3. c' '- [ ] 4. d' '## Owner' '- decide x' '## Handoff' >> "$PLAN"
  frame; has "$OUT" "1✓ 0✗ 1○ 1c 1p" counts; has "$OUT" "owner 1" owner
  OUT=$(bash "$WATCH" --once --width 100 --height 10 "$repo"); has "$(head -1 <<<"$OUT")" $'\033[41;30;1m' "owner makes it red"
}
test_board2_open_requests() {
  setup; local b=$W/board; mkdir -p "$b"
  printf -- '- 2026-10-23T01:00Z a-1 → b: x\n- 2026-10-23T01:10Z a-2 → b: y\n- 2026-10-23T01:20Z a-3 (replaces a-2) → b: z\n- 2026-10-23T01:30Z a-4 → b, c: w\n- done a\n' > "$b/a.md"
  printf -- '- 2026-10-23T02:00Z reject a-1: no\n- 2026-10-23T02:10Z nack a-4: rolled back\n' > "$b/b.md"
  OUT=$(bash "$WATCH" board --once --width 120 --height 4 "$b" | plain)
  has "$(head -1 <<<"$OUT")" "open: a-3 → b" open; lacks "$(head -1 <<<"$OUT")" "a-1 →" reject; lacks "$(head -1 <<<"$OUT")" "a-2 →" replaced; lacks "$(head -1 <<<"$OUT")" "a-4" nack
}
test_dash_row4_owner_count() { setup; printf '%s\n' '## Owner' '- a' '- b' >> "$PLAN"; frame; has "$OUT" "owner 2" row4; }

fail=0
t() {
  if [ "$3" = 0 ] && [ -z "$2" ]; then echo "ok $1"; else echo "FAIL $1: rc=$3 $2"; fail=1; fi
}
out=$(test_state_working 2>/dev/null); t test_state_working "$out" $?
out=$(test_state_quiet 2>/dev/null); t test_state_quiet "$out" $?
out=$(test_state_stalled 2>/dev/null); t test_state_stalled "$out" $?
out=$(test_state_waiting 2>/dev/null); t test_state_waiting "$out" $?
out=$(test_state_done 2>/dev/null); t test_state_done "$out" $?
out=$(test_state_killed_is_red 2>/dev/null); t test_state_killed_is_red "$out" $?
out=$(test_state_blocked_is_red 2>/dev/null); t test_state_blocked_is_red "$out" $?
out=$(test_info_rows 2>/dev/null); t test_info_rows "$out" $?
out=$(test_render_stream 2>/dev/null); t test_render_stream "$out" $?
out=$(test_fit_width_and_height 2>/dev/null); t test_fit_width_and_height "$out" $?
out=$(test_board_open_requests 2>/dev/null); t test_board_open_requests "$out" $?
out=$(test_hostile_plan_values 2>/dev/null); t test_hostile_plan_values "$out" $?
out=$(test_control_chars_stripped 2>/dev/null); t test_control_chars_stripped "$out" $?
out=$(test_spaced_repo 2>/dev/null); t test_spaced_repo "$out" $?
out=$(test_new_states_and_owner 2>/dev/null); t test_new_states_and_owner "$out" $?
out=$(test_board2_open_requests 2>/dev/null); t test_board2_open_requests "$out" $?
out=$(test_dash_row4_owner_count 2>/dev/null); t test_dash_row4_owner_count "$out" $?
for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do grep -q "^out=\$($f " "$0" || { echo "FAIL $f: not registered"; fail=1; }; done
exit $fail
