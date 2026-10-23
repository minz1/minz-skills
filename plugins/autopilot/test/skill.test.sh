#!/usr/bin/env bash
DIR=$(cd "$(dirname "$0")" && pwd)
SKILL=$DIR/../skills/autopilot/SKILL.md
PLAN=$DIR/../skills/autopilot/templates/plan.md

die() { echo "$*"; exit 1; }
in_skill() { local p; for p in "$@"; do grep -qF -- "$p" "$SKILL" || die "SKILL.md lacks '$p'"; done; }

test_wait_pid_documented() {
  in_skill 'WAIT <minutes> pid=<n>' 'echo $!' 'fleet lists every' 'cap for hung jobs' 'Board waits need no pid' 'wake a waiting run'
  local warn="Never use \`pgrep -f\`"
  ! grep -vF "$warn" "$SKILL" | grep -qF 'pgrep -f' || die "pgrep -f recommended outside the warning"
}
test_board_aware_exits() { in_skill 're-read every board file' 'could act on it now' 'WAIT <cap>' 'new request or an answer'; }
test_notes_before_shipping() { in_skill 'right before any push, tag, deploy or deploy post'; }
test_stop_hygiene() { in_skill 'git status --porcelain' 'still untracked now' 'exit=nowait' 'must finish before you exit' 'Only detached jobs'; }
test_solo_board_none() {
  in_skill 'board: none'
  grep -q 'none' "$PLAN" || die "template lacks board: none guidance"
}
test_read_tool() { in_skill 'Read tool'; }
test_remote_shas_fetched() { in_skill 'fetched it in that session'; }
test_now_marker() {
  in_skill 'now: <item number>' "clear \`now:\`"
  grep -q '^now:' "$PLAN" || die "template lacks now:"
}
test_usage_line() { in_skill 'usage: /autopilot '; }

test_new_rules() {
  in_skill '[c]' 'committed locally' 'refs/heads/ship/<id>' 'ahead-cap:' 'ack-timeout:' 'serves: <repo>' 'ship: <group>' 'findings:' \
    "git diff --stat A B -- . ':!.autopilot' ':!.gitignore'" 'reject <id>' 'nack <id>' 'watch <id>' 'done <repo>' '(replaces <old-id>)'
}
test_owner_rules() { in_skill '## Owner' 'deviated: <why>' 'owner-notes-used:' '[once]' 'short paraphrase'; }
test_planning_rules() { in_skill 'pgrep -af autopilot-runner' '.claude/settings.local.json' 'Resolve every SHA' 'should be tracked' '.config/autopilot/weekly-ceiling'; }
test_interim_legacy() {
  in_skill '## Interim: legacy plans' 'legacy: true' 'Remove this section once'
  ! grep -qE '^(protocol|legacy):' "$PLAN" || die "template carries a version header"
}
test_templates() {
  local k; for k in '^serves:' '^ahead-cap: 2' '^ack-timeout: 6h' '^owner-notes-used:' '^## Owner'; do grep -q "$k" "$PLAN" || die "plan template lacks $k"; done
  for k in '## Long commands' '## Shared tool locks' '## Peers'; do grep -qF "$k" "$DIR/../skills/autopilot/templates/rules.md" || die "rules template lacks $k"; done
}

test_review_rules() {
  in_skill "\`owner → <repo>: <text>\`" "Sessions never write \`owner\` lines" \
    'explicitly changes an earlier decision is applied' 'skips the "Item states and shipping" and "Board" sections' "\`[to <peer>]\`" \
    "whose \`after:\` items are \`[c]\`, \`[p]\` or \`[x]\`, while fewer than \`ahead-cap\`" 'A ship post still waiting for its ack (not in a legacy plan)' \
    'On an ack of your own ship post (not in a legacy plan)' "set its items back to \`[ ]\`" 'owner-board-applied:' 'exactly as the repo'"'"'s allow rules spell them'
  grep -qF "no \`[c]\` or \`[p]\` items left" "$PLAN" || die "Final template lacks the [c]/[p] rule"
}

test_wait_ack_documented() { in_skill 'WAIT ack <id>' 'There is no timer' 'ack-timeout'; }

test_owner_entries_resolved() { in_skill 'When an entry is resolved' 'owner item resolved:'; }

fail=0
t() {
  if [ "$3" = 0 ] && [ -z "$2" ]; then echo "ok $1"; else echo "FAIL $1: rc=$3 $2"; fail=1; fi
}
out=$(test_wait_pid_documented 2>/dev/null); t test_wait_pid_documented "$out" $?
out=$(test_board_aware_exits 2>/dev/null); t test_board_aware_exits "$out" $?
out=$(test_notes_before_shipping 2>/dev/null); t test_notes_before_shipping "$out" $?
out=$(test_stop_hygiene 2>/dev/null); t test_stop_hygiene "$out" $?
out=$(test_solo_board_none 2>/dev/null); t test_solo_board_none "$out" $?
out=$(test_read_tool 2>/dev/null); t test_read_tool "$out" $?
out=$(test_remote_shas_fetched 2>/dev/null); t test_remote_shas_fetched "$out" $?
out=$(test_now_marker 2>/dev/null); t test_now_marker "$out" $?
out=$(test_usage_line 2>/dev/null); t test_usage_line "$out" $?
out=$(test_new_rules 2>/dev/null); t test_new_rules "$out" $?
out=$(test_owner_rules 2>/dev/null); t test_owner_rules "$out" $?
out=$(test_planning_rules 2>/dev/null); t test_planning_rules "$out" $?
out=$(test_interim_legacy 2>/dev/null); t test_interim_legacy "$out" $?
out=$(test_templates 2>/dev/null); t test_templates "$out" $?
out=$(test_review_rules 2>/dev/null); t test_review_rules "$out" $?
out=$(test_wait_ack_documented 2>/dev/null); t test_wait_ack_documented "$out" $?
out=$(test_owner_entries_resolved 2>/dev/null); t test_owner_entries_resolved "$out" $?
for f in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do grep -q "^out=\$($f " "$0" || { echo "FAIL $f: not registered"; fail=1; }; done
exit $fail
