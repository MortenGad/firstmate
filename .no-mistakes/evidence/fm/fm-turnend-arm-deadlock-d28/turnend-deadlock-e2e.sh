#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-06 Claude turn-end deadlock, run
# against the REAL bin/ of this repository at two revisions:
#
#   BEFORE = the change's base commit
#   AFTER  = the change under test
#
# Every "turn ends" line below is a real Claude Stop boundary as tracked
# .claude/settings.json registers it: a claude-named harness process writes
# state/.lock and then runs that hook group -
#   1. bin/fm-turnend-guard.sh --claude   (synchronous, decides the Stop)
#   2. bin/fm-claude-stop-autoarm.sh      ("asyncRewake": true, the arm)
#
# HOW THE HARNESS IS MODELLED, and why:
#   Claude Code starts both hooks and CANCELS the sibling asyncRewake hook when
#   the Stop is blocked. The incident report's defining observation is that
#   across forty minutes of refusals the arm never established anything:
#   state/.claude-autoarm-epoch stayed frozen at
#   "epoch=165 owner_pid=41746 outcome=rewake" and never took a new generation.
#   So a BLOCKED Stop here runs the guard and leaves the arm cancelled - it
#   publishes no claim - and an ALLOWED Stop lets the registered asyncRewake arm
#   run for real. That is the deadlock the change exists to break: the guard
#   refuses because no watcher is live, and the refusal is what stops the only
#   hook that could start one.
#
# Nothing else is stubbed: the guard, the auto-arm, bin/fm-watch-arm.sh and
# bin/fm-watch.sh are this repository's own scripts, and the watchers that come
# up are real watcher processes holding the real home lock.
set -u

ROOT=$1                 # worktree checkout (AFTER)
BASE=$2                 # base commit sha  (BEFORE)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-turnend-e2e.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)

cleanup() {
  local i pids p
  # Primed cycles are deliberately setsid-detached and their arm layer retries,
  # so sweep until the temp root has no processes left at all.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pids=$(pgrep -f "$WORK" 2>/dev/null || true)
    [ -n "$pids" ] || break
    for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
    sleep 0.7
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

make_home() {  # <name> <before|after>
  local name=$1 rev=$2 dir
  dir="$WORK/$name"
  mkdir -p "$dir/state" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" -c user.name=fmtest -c user.email=fm@test.invalid commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin/." "$dir/bin/"
  cp -R "$ROOT/docs" "$dir/docs"
  if [ "$rev" = before ]; then
    git -C "$ROOT" show "$BASE:bin/fm-turnend-guard.sh"       > "$dir/bin/fm-turnend-guard.sh"
    git -C "$ROOT" show "$BASE:bin/fm-claude-stop-autoarm.sh" > "$dir/bin/fm-claude-stop-autoarm.sh"
    chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  fi
  ln -s /bin/bash "$dir/fake-claude"
  cat > "$dir/stop-boundary.sh" <<'SH'
#!/usr/bin/env bash
# One Claude Stop boundary, running inside the claude-named harness process.
set -u
payload='{"stop_hook_active":true,"session_id":"sess-incident-2026-09-06"}'
printf '%s\n' "$$" > "$FM_HOME/state/.lock"       # this session owns the home lock
printf '%s' "$payload" | bash "$FM_HOME/bin/fm-turnend-guard.sh" --claude
rc=$?
if [ "$rc" -eq 0 ]; then
  # Stop allowed: the registered asyncRewake arm survives and runs.
  printf '%s' "$payload" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" \
    >"$FM_HOME/state/asyncrewake.out" 2>&1 &
  sleep 2                                          # let it publish its claim
fi
exit "$rc"
SH
  chmod +x "$dir/stop-boundary.sh"
  printf '%s\n' "$dir"
}

stop() {  # <dir> <label>
  local dir=$1 label=$2 out rc=0
  out=$(CLAUDECODE=1 FM_HOME="$dir" FM_ARM_CONFIRM_TIMEOUT=8 \
    "$dir/fake-claude" "$dir/stop-boundary.sh" 2>&1) || rc=$?
  printf '\n$ %s\n' "$label"
  case "$rc" in
    2) printf '  -> Stop BLOCKED (hook exit 2); the asyncRewake arm is cancelled. The model is handed:\n' ;;
    0) printf '  -> Stop ALLOWED (hook exit 0); the turn ends and the asyncRewake arm runs.\n' ;;
    *) printf '  -> hook exit %s\n' "$rc" ;;
  esac
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/     /'
  LAST_RC=$rc
  return 0
}

state_line() {  # <dir>
  local dir=$1 epoch budget lockpid
  epoch=$(sed -n 1p "$dir/state/.claude-autoarm-epoch" 2>/dev/null || true)
  budget=$(cat "$dir/state/.turnend-claude-blocks" 2>/dev/null | tr '\n' ' ' || true)
  lockpid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  printf '     state/.claude-autoarm-epoch : %s\n' "${epoch:-<none>}"
  printf '     state/.turnend-claude-blocks: %s\n' "${budget:-<none>}"
  if [ -n "$lockpid" ] && kill -0 "$lockpid" 2>/dev/null; then
    printf '     live watcher on state/.watch.lock: pid %s\n' "$lockpid"
  else
    printf '     live watcher on state/.watch.lock: NONE\n'
  fi
}

seed_incident() {  # <dir>
  local dir=$1 i
  for i in 1 2 3 4; do printf 'task=parked-%s\n' "$i" > "$dir/state/task$i.meta"; done
  printf 'epoch=165 owner_pid=41746 outcome=rewake updated_at=1788664081\n' \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202601010000 "$dir/state/.claude-autoarm-epoch"
}

seed_wedged() {  # <dir>
  local dir=$1 holder identity i
  for i in 1 2 3 4; do printf 'task=parked-%s\n' "$i" > "$dir/state/task$i.meta"; done
  printf 'epoch=165 owner_pid=41746 outcome=failed updated_at=1788664081\n' \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202601010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.claude-autoarm-failure-notified"
  sleep 400 &
  holder=$!
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$holder" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$dir/bin/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  identity=$(FM_HOME="$dir" bash -c '. "$0/bin/fm-wake-lib.sh"; fm_pid_identity "$1"' "$dir" "$holder" 2>/dev/null || true)
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  touch -t 202601010000 "$dir/state/.last-watcher-beat"
  printf '%s\n' "$holder" > "$dir/holder.pid"
}

await_watcher() {  # <dir>
  local dir=$1 i=0 pid
  while [ "$i" -lt 300 ]; do
    pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -e "$dir/state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

printf '═══════════════════════════════════════════════════════════════════════\n'
printf 'SCENARIO A - the reported incident\n'
printf '═══════════════════════════════════════════════════════════════════════\n'
printf 'Both homes start in the state recorded on 2026-09-06 05:00-05:40: four parked\n'
printf 'tasks in flight, the watcher gone after delivering its last wake, and\n'
printf 'state/.claude-autoarm-epoch frozen at "epoch=165 owner_pid=41746 outcome=rewake".\n'

BEFORE=$(make_home a-before before)
seed_incident "$BEFORE"
printf '\n───── BEFORE  (base %s) ─────\n' "$(git -C "$ROOT" rev-parse --short "$BASE")"
for n in 1 2 3 4; do
  stop "$BEFORE" "turn $n ends"
  state_line "$BEFORE"
done
printf '\n  Every turn end refused. The epoch never moved, the block count never moved,\n'
printf '  no watcher ever came back. This is the state the operator could only escape\n'
printf '  by restarting the session.\n'

AFTER=$(make_home a-after after)
seed_incident "$AFTER"
printf '\n───── AFTER  (%s) ─────\n' "$(git -C "$ROOT" rev-parse --short HEAD)"
stop "$AFTER" "turn 1 ends"
state_line "$AFTER"
if await_watcher "$AFTER"; then
  printf '\n  The detached cycle that refusal primed is live, and its watcher holds the\n'
  printf '  home lock - started by the refused Stop itself, outside the harness session:\n'
  for p in $(pgrep -f "$AFTER/bin/fm-watch" 2>/dev/null); do
    ps -o pid=,ppid=,args= -p "$p" 2>/dev/null | sed "s#$AFTER#<home>#g;s/^/    /"
  done
else
  printf '\n  no watcher came up within 30s\n'
fi
stop "$AFTER" "turn 2 ends"
state_line "$AFTER"
printf '\n  The next turn end was allowed by a live watcher, and the auto-arm chain that\n'
printf '  had been frozen at generation 165 is running again - with no session restart.\n'

printf '\n═══════════════════════════════════════════════════════════════════════\n'
printf 'SCENARIO B - the bounded escape the incident could never spend\n'
printf '═══════════════════════════════════════════════════════════════════════\n'
printf 'Scenario A above already reproduced the reported budget line verbatim -\n'
printf '"count=1 epoch=165", unchanged across every refusal. Here the same home is set\n'
printf 'up so the bounded attended fail-open is in principle AVAILABLE: the frozen epoch\n'
printf 'is a FAILED one whose single notice is already consumed. A live lock holder whose\n'
printf 'beacon is stale past the grace - the third symptom in the report - refuses every\n'
printf 'watcher start, so no primed cycle can succeed and the fail-open is the only exit.\n'
printf '(This seeding starts the counter at 0 rather than the report own 1, because an\n'
printf 'already-consumed failure notice initialises it there; the pinning is the same.)\n'

B_BEFORE=$(make_home b-before before)
seed_wedged "$B_BEFORE"
printf '\n───── BEFORE  (base %s) ─────\n' "$(git -C "$ROOT" rev-parse --short "$BASE")"
for n in 1 2 3 4 5; do
  stop "$B_BEFORE" "turn $n ends" >/dev/null 2>&1
  printf '  turn %s: hook exit %s   state/.turnend-claude-blocks = %s\n' "$n" "$LAST_RC" \
    "$(cat "$B_BEFORE/state/.turnend-claude-blocks" 2>/dev/null | tr '\n' ' ')"
done
printf '  The count never advances: it is keyed on an epoch that cannot change, so the\n'
printf '  bounded fail-open is unreachable and every turn end refuses forever.\n'
kill "$(cat "$B_BEFORE/holder.pid")" 2>/dev/null || true

B_AFTER=$(make_home b-after after)
seed_wedged "$B_AFTER"
printf '\n───── AFTER  (%s) ─────\n' "$(git -C "$ROOT" rev-parse --short HEAD)"
for n in 1 2 3 4 5; do
  stop "$B_AFTER" "turn $n ends" >"$WORK/b.out" 2>&1
  printf '  turn %s: hook exit %s   state/.turnend-claude-blocks = %s\n' "$n" "$LAST_RC" \
    "$(cat "$B_AFTER/state/.turnend-claude-blocks" 2>/dev/null | tr '\n' ' ')"
  if [ "$LAST_RC" -eq 0 ]; then
    printf '\n  The bounded attended fail-open the incident could never reach:\n'
    sed 's/^/  /' "$WORK/b.out"
    break
  fi
done
printf '\n  Each of those refusals also primed a cycle, and each cycle the wedged lock\n'
printf '  holder refused still recorded why, in state/.watch-cycle-exits.log:\n'
i=0
while [ "$i" -lt 200 ]; do
  [ -s "$B_AFTER/state/.watch-cycle-exits.log" ] && break
  sleep 0.1
  i=$((i + 1))
done
tail -2 "$B_AFTER/state/.watch-cycle-exits.log" 2>/dev/null \
  | sed "s#$B_AFTER#<home>#g;s/^/    /"
kill "$(cat "$B_AFTER/holder.pid")" 2>/dev/null || true
printf '\n'
