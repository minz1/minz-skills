#!/usr/bin/env bash
DIR=$(cd "$(dirname "$0")" && pwd)
SKILL=$DIR/../skills/autopilot/SKILL.md
PLAN=$DIR/../skills/autopilot/templates/plan.md

die() { echo "$*"; exit 1; }
in_skill() { local p; for p in "$@"; do grep -qF -- "$p" "$SKILL" || die "SKILL.md lacks '$p'"; done; }

test_wait_pid_documented() {
  in_skill 'WAIT <minutes> pid=<n>' 'echo $!' 'fleet lists every' 'cap for hung jobs' 'Board waits need no pid' 'wake a waiting run'
  ! grep -v 'Never use `pgrep -f`' "$SKILL" | grep -qF 'pgrep -f' || die "pgrep -f recommended outside the warning"
}
test_board_aware_exits() { in_skill 're-read every board file' 'could act on it now' 'WAIT <cap>' 'new request or an answer'; }
test_notes_before_shipping() { in_skill 'right before any push, tag, deploy or deploy post'; }
test_stop_hygiene() { in_skill 'git status --porcelain' 'untracked both'; }
test_solo_board_none() {
  in_skill 'board: none'
  grep -q 'none' "$PLAN" || die "template lacks board: none guidance"
}
test_read_tool() { in_skill 'Read tool'; }
test_remote_shas_fetched() { in_skill 'fetched it in that session'; }
test_usage_line() { in_skill 'usage: /autopilot '; }

fail=0
t() {
  if [ "$3" = 0 ] && [ -z "$2" ]; then echo "ok $1"; else echo "FAIL $1: rc=$3 $2"; fail=1; fi
}
for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do out=$($f 2>/dev/null); t "$f" "$out" $?; done
exit $fail
