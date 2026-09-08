#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-06 Claude Stop guard/auto-arm deadlock,
# run against the branch base (b84e0e3) and against the branch head (915761e).
#
# usage: deadlock-repro.sh <firstmate-checkout> <base-commit>
#
# Both homes are real primary-shaped Firstmate homes carrying the REAL bin/ tree
# of their respective commit (guard, auto-arm, fm-watch-arm.sh, fm-watch.sh) and
# the incident state observed on 2026-09-06:
#   - one task in flight
#   - no live watcher holding the home lock
#   - state/.claude-autoarm-epoch frozen at epoch=165 outcome=rewake
#   - state/.turnend-claude-blocks at count=1 epoch=165
# Each "Stop" is a genuine Claude Stop hook invocation: the guard runs as a child
# of a harness process that owns state/.lock, with the Stop payload on stdin.
# The registered asyncRewake auto-arm hook is NOT run after a refusal, because
# Claude Code cancels sibling hooks when a Stop is blocked - that cancellation is
# the deadlock this change is about.
set -u

ROOT=$1
BASE=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-deadlock-repro.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)

cleanup() {
  local p
  for p in $(pgrep -f "$WORK" 2>/dev/null || true); do kill "$p" 2>/dev/null || true; done
  sleep 0.5
  for p in $(pgrep -f "$WORK" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

seed_home() {  # <dir> base|head
  local dir=$1 which=$2
  mkdir -p "$dir/state" "$dir/bin" "$dir/docs"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  if [ "$which" = base ]; then
    git -C "$ROOT" archive "$BASE" bin | tar -x -C "$dir"
    git -C "$ROOT" archive "$BASE" docs/supervision-protocols | tar -x -C "$dir"
  else
    cp -R "$ROOT/bin/." "$dir/bin/"
    cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  fi
  chmod +x "$dir"/bin/*.sh
  ln -s /bin/bash "$dir/fake-claude"
  : > "$dir/state/task1.meta"
  printf 'epoch=165 owner_pid=41746 outcome=rewake updated_at=1788664081\n' \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  printf 'session=sess-deadlock\ncount=1\nepoch=165\n' > "$dir/state/.turnend-claude-blocks"
}

stop() {  # <dir> -> prints hook output on stdout, returns the hook's exit code
  local dir=$1 home
  home=$(cd "$dir" && pwd -P)
  # shellcheck disable=SC2016 # the fake harness expands FM_HOME inside its child shell
  printf '{"stop_hook_active":true,"session_id":"sess-deadlock"}' \
    | CLAUDECODE=1 FM_HOME="$home" "$dir/fake-claude" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        bash "$FM_HOME/bin/fm-turnend-guard.sh" --claude
      ' 2>&1
}

report() {  # <dir>
  local dir=$1 pid
  pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  printf '    state/.claude-autoarm-epoch : %s\n' \
    "$(head -1 "$dir/state/.claude-autoarm-epoch" 2>/dev/null || echo '<absent, reset by an allowed stop>')"
  if [ -e "$dir/state/.turnend-claude-blocks" ]; then
    printf '    state/.turnend-claude-blocks: %s\n' "$(tr '\n' ' ' < "$dir/state/.turnend-claude-blocks")"
  else
    printf '    state/.turnend-claude-blocks: <absent, reset by an allowed stop>\n'
  fi
  printf '    watcher holding home lock   : %s\n' "${pid:-none}"
  printf '    primed cycle processes      : %s\n' \
    "$(pgrep -f "$dir/bin/fm-watch" 2>/dev/null | tr '\n' ' ' || true)"
}

await_watcher() {  # <dir>
  local dir=$1 i=0 pid
  while [ "$i" -lt 200 ]; do
    pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -e "$dir/state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

run_home() {  # <dir> <title>
  local dir=$1 title=$2 out status n pid p
  printf '==============================================================================\n'
  printf '%s\n' "$title"
  printf '==============================================================================\n'
  printf 'seeded incident state:\n'
  report "$dir"
  printf '\n'
  for n in 1 2 3; do
    out=$(stop "$dir"); status=$?
    printf -- '--- Stop %s ---------------------------------------------------------------\n' "$n"
    printf 'guard exit=%s  (%s)\n' "$status" \
      "$([ "$status" -eq 2 ] && echo 'REFUSED - the turn cannot end' || echo 'ALLOWED - the turn ends')"
    if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '(no output)\n'; fi
    if [ "$n" -eq 1 ]; then
      printf 'state immediately after the refusal:\n'
      report "$dir"
      printf 'waiting up to 10s for a watcher this Stop may have primed...\n'
      if await_watcher "$dir"; then
        printf 'RESULT: a watcher came up and holds the home lock.\n'
      else
        printf 'RESULT: no watcher ever came up.\n'
      fi
    fi
    printf 'state before the next Stop:\n'
    report "$dir"
    printf '\n'
    if [ "$status" -eq 0 ]; then
      printf 'The turn ended normally - the deadlock is broken.\n\n'
      break
    fi
  done
  pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  printf 'live watcher process:\n'
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    ps -o pid=,ppid=,command= -p "$pid" | sed 's/^/    /'
  else
    printf '    <none>\n'
  fi
  for p in $(pgrep -f "$dir/bin/fm-watch" 2>/dev/null || true); do kill "$p" 2>/dev/null || true; done
  sleep 1
  printf 'watcher lifecycle ledger (state/.watch-cycle-exits.log) after the cycle ends:\n'
  if [ -s "$dir/state/.watch-cycle-exits.log" ]; then
    sed 's/^/    /' "$dir/state/.watch-cycle-exits.log"
  else
    printf '    <no cycle ever ran>\n'
  fi
  printf '\n'
}

seed_home "$WORK/before" base
run_home "$WORK/before" "BEFORE the fix - branch base b84e0e3"
seed_home "$WORK/after" head
run_home "$WORK/after" "AFTER the fix - branch head 915761e"

# --- second variant: the epoch ADVANCES (166 failed -> 167 rewake) -------------
# The 07:30-09:00 episode the same day recovered on its own several times instead
# of locking up, and its epoch advanced rather than freezing. The fresh failed
# epoch 166 spends its one automatic handoff (a Stop the guard ALLOWS); once the
# rewake epoch 167 ages past the freshness window, every later Stop refuses.
seed_advancing() {  # <dir> base|head
  local dir=$1 which=$2
  seed_home "$dir" "$which"
  rm -f "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  printf 'epoch=166 owner_pid=999 outcome=failed updated_at=%s\n' "$(date +%s)" \
    > "$dir/state/.claude-autoarm-epoch"
}

run_advancing() {  # <dir> <title>
  local dir=$1 title=$2 out status n p pid
  printf '==============================================================================\n'
  printf '%s\n' "$title"
  printf '==============================================================================\n'
  printf 'seeded state: fresh failed epoch 166 with its failure notice\n'
  report "$dir"
  printf '\n'
  out=$(stop "$dir"); status=$?
  printf -- '--- Stop A (fresh failed epoch 166 spends its one handoff) ----------------\n'
  printf 'guard exit=%s  (%s)\n' "$status" \
    "$([ "$status" -eq 2 ] && echo 'REFUSED - the turn cannot end' || echo 'ALLOWED - the turn ends')"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '(no output)\n'; fi
  report "$dir"
  printf '\n'
  printf 'the auto-arm now advances the epoch to 167 outcome=rewake, which then ages out:\n'
  printf 'epoch=167 owner_pid=41746 outcome=rewake updated_at=2\n' > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  report "$dir"
  printf '\n'
  for n in B C D; do
    out=$(stop "$dir"); status=$?
    printf -- '--- Stop %s ---------------------------------------------------------------\n' "$n"
    printf 'guard exit=%s  (%s)\n' "$status" \
      "$([ "$status" -eq 2 ] && echo 'REFUSED - the turn cannot end' || echo 'ALLOWED - the turn ends')"
    if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '(no output)\n'; fi
    if [ "$n" = B ]; then
      printf 'waiting up to 10s for a watcher this Stop may have primed...\n'
      if await_watcher "$dir"; then
        printf 'RESULT: a watcher came up and holds the home lock.\n'
      else
        printf 'RESULT: no watcher ever came up.\n'
      fi
    fi
    printf 'state before the next Stop:\n'
    report "$dir"
    printf '\n'
    if [ "$status" -eq 0 ] && [ "$n" != A ]; then
      printf 'The turn ended normally - the deadlock is broken.\n\n'
      break
    fi
  done
  pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  printf 'live watcher process:\n'
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    ps -o pid=,ppid=,command= -p "$pid" | sed 's/^/    /'
  else
    printf '    <none>\n'
  fi
  for p in $(pgrep -f "$dir/bin/fm-watch" 2>/dev/null || true); do kill "$p" 2>/dev/null || true; done
  sleep 1
  printf '\n'
}

# Each home is seeded immediately before its own run: the failed epoch 166 must
# still be inside FM_CLAUDE_AUTOARM_EPOCH_FRESH (15s) when its first Stop lands.
seed_advancing "$WORK/before-adv" base
run_advancing "$WORK/before-adv" "BEFORE the fix - advancing epoch (166 failed -> 167 rewake), branch base b84e0e3"
seed_advancing "$WORK/after-adv" head
run_advancing "$WORK/after-adv" "AFTER the fix - advancing epoch (166 failed -> 167 rewake), branch head 915761e"
