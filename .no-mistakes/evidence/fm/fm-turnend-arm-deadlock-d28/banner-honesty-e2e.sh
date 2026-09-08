#!/usr/bin/env bash
# The refusal banner must claim a primed recovery start only when a cycle was
# really detached. This runs the two conditions the change documents as still
# open - away mode, and the auto-arm's session-lock identity gate - against the
# real bin/ at HEAD, and shows what the model is actually handed in each, next
# to the case where a cycle really was forked.
set -u

ROOT=$1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-banner-e2e.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)

cleanup() {
  local i pids p
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pids=$(pgrep -f "$WORK" 2>/dev/null || true)
    [ -n "$pids" ] || break
    for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
    sleep 0.7
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

make_home() {  # <name>
  local name=$1 dir
  dir="$WORK/$name"
  mkdir -p "$dir/state" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" -c user.name=fmtest -c user.email=fm@test.invalid commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin/." "$dir/bin/"
  cp -R "$ROOT/docs" "$dir/docs"
  ln -s /bin/bash "$dir/fake-claude"
  local i
  for i in 1 2 3 4; do printf 'task=parked-%s\n' "$i" > "$dir/state/task$i.meta"; done
  cat > "$dir/stop-boundary.sh" <<'SH'
#!/usr/bin/env bash
set -u
payload='{"stop_hook_active":true,"session_id":"sess-banner"}'
[ "${FM_E2E_OWN_LOCK:-1}" = 1 ] && printf '%s\n' "$$" > "$FM_HOME/state/.lock"
printf '%s' "$payload" | bash "$FM_HOME/bin/fm-turnend-guard.sh" --claude
SH
  chmod +x "$dir/stop-boundary.sh"
  printf '%s\n' "$dir"
}

report() {  # <dir> <title> <own_lock 0|1>
  local dir=$1 title=$2 own=$3 out rc=0 i pids
  printf '\n───── %s\n' "$title"
  out=$(CLAUDECODE=1 FM_HOME="$dir" FM_E2E_OWN_LOCK="$own" FM_ARM_CONFIRM_TIMEOUT=8 \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 \
    "$dir/fake-claude" "$dir/stop-boundary.sh" 2>&1) || rc=$?
  printf '  Stop hook exit %s; the model is handed:\n' "$rc"
  printf '%s\n' "$out" | sed 's/^/     /'
  # A detached cycle is visible as an fm-watch process of THIS home. Give any
  # fork a full second to appear before reporting that none did.
  i=0
  pids=
  while [ "$i" -lt 10 ]; do
    pids=$(pgrep -f "$dir/bin/fm-watch" 2>/dev/null || true)
    [ -n "$pids" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  if [ -n "$pids" ]; then
    printf '  a cycle WAS detached:\n'
    for p in $pids; do ps -o pid=,ppid=,args= -p "$p" 2>/dev/null | sed "s#$dir#<home>#g;s/^/     /"; done
  else
    printf '  no cycle was detached: no fm-watch process exists for this home.\n'
  fi
}

printf '═══════════════════════════════════════════════════════════════════════\n'
printf 'The refusal banner is keyed on the fork, not on the call  (HEAD %s)\n' "$(git -C "$ROOT" rev-parse --short HEAD)"
printf '═══════════════════════════════════════════════════════════════════════\n'
printf 'All three homes below have four tasks in flight and no live watcher, so the\n'
printf 'guard refuses each turn end. What differs is whether the refusal could really\n'
printf 'start anything.\n'

A=$(make_home primes)
report "$A" 'a refusal that CAN prime: the session owns the home lock' 1

B=$(make_home away)
: > "$B/state/.afk"
report "$B" 'away mode is on: the auto-arm stands down, so nothing is forked' 1

C=$(make_home foreign-lock)
ln -s /bin/bash "$WORK/claude"
# The trailing `true` keeps bash from exec-replacing itself with sleep, so this
# stays a claude-named process for the whole wait.
"$WORK/claude" -c 'sleep 300; true' &
FOREIGN=$!
printf '%s\n' "$FOREIGN" > "$C/state/.lock"
printf '\n(state/.lock names pid %s, command name "%s". The shared harness-liveness\n' \
  "$FOREIGN" "$(ps -o comm= -p "$FOREIGN" 2>/dev/null | sed 's#.*/##')"
if FM_HOME="$C" bash -c '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_pid_alive "$1"' "$C" "$FOREIGN"; then
  printf 'predicate reports it LIVE, and it is not an ancestor of this hook, so it is a\n'
  printf 'foreign session owner and the auto-arm identity gate stands every firing down.)\n'
else
  printf 'predicate does NOT report it live - fixture is wrong, see below.)\n'
fi
report "$C" 'a foreign live session-lock owner: the identity gate forks nothing' 0
kill "$FOREIGN" 2>/dev/null || true

printf '\nThe two documented open conditions still refuse - the change does not claim to\n'
printf 'close them - but neither refusal tells the model a recovery start is in flight.\n'
