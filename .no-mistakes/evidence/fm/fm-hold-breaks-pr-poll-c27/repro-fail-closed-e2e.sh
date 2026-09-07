#!/usr/bin/env bash
# Companion to repro-merge-notification-e2e.sh.
#
# Same real surfaces (bin/fm-pr-check.sh arms the poll, bin/fm-watch.sh runs one
# bounded cycle against a MERGED pull request), one fresh home per row, and each
# row differs only in what is written into state/task-a.meta after the pr= line.
#
# The point: accepting a later well-formed key must not be the same thing as
# accepting anything. Rows marked ACCEPT must still deliver the merge; rows
# marked REFUSE must still be reported as unauthenticated.
set -u

ROOT_UNDER_TEST=$1

# shellcheck source=/dev/null
. "$ROOT_UNDER_TEST/tests/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
URL=https://github.com/o/r/pull/10
ID=task-a
TMP=$(fm_test_tmproot repro-failclosed)

printf 'repo under test: %s (%s)\n\n' "$ROOT_UNDER_TEST" \
  "$(git -C "$ROOT_UNDER_TEST" rev-parse --short HEAD 2>/dev/null || echo 'base copy')"
printf '%-46s | %-9s | %s\n' 'appended after pr= in state/task-a.meta' 'expected' 'what bin/fm-watch.sh tells firstmate'
printf -- '-%.0s' {1..150}; printf '\n'

run_row() {  # <label> <expectation> <appended-line...>
  local label=$1 expect=$2; shift 2
  local dir state rc out verdict
  dir="$TMP/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-')"
  state="$dir/home/state"
  mkdir -p "$state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$dir/fakebin" "$dir/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/root/bin/fm-guard.sh"
  chmod +x "$dir/root/bin/fm-guard.sh"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "api graphql") printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main'; exit 0 ;;
esac
case " $* " in
  *" headRefOid "*) printf '%s\n' "0123456789abcdef0123456789abcdef01234567" ;;
  *" state "*)     printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  printf 'window=fm-%s\nendpoint_task_id=%s\nworktree=%s\nkind=ship\n' \
    "$ID" "$ID" "$dir/wt" > "$state/$ID.meta"
  chmod 0600 "$state/$ID.meta"
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" >/dev/null || { printf 'ARM FAILED %s\n' "$label"; return 1; }
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$state/$ID.meta"; done

  set +e
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 20; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
      FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_TEST_GH_STATE=MERGED PATH="$dir/fakebin:$BASE_PATH" \
      "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2>/dev/null
  rc=$?
  set -e
  out=$(sed "s#$state/##g" "$dir/watch.out" | head -1)
  case "$out" in
    *"$ID.check.sh: merged"*) verdict=ACCEPT ;;
    *"rejected unauthenticated state checks"*) verdict=REFUSE ;;
    *) verdict="?? (rc=$rc)" ;;
  esac
  printf '%-46s | %-9s | %s\n' "$label" "$expect" "$out"
  [ "$verdict" = "$expect" ] || printf '  ^^ MISMATCH: got %s, expected %s\n' "$verdict" "$expect"
}

run_row '(nothing - plain armed poll)'                 ACCEPT
run_row 'control_relaunch_tx=12345.20260907T0000Z.1'   ACCEPT 'control_relaunch_tx=12345.20260907T0000Z.1'
run_row 'decisions_reviewed=1 + decision_keys='        ACCEPT 'decisions_reviewed=1' 'decision_keys='
run_row 'some_future_key=whatever'                     ACCEPT 'some_future_key=whatever'
run_row 'x_request=req-1'                              ACCEPT 'x_request=req-1'
run_row 'pr=https://github.com/o/r/pull/99 (2nd pr=)'  REFUSE 'pr=https://github.com/o/r/pull/99'
run_row '# not-a-key'                                  REFUSE '# not-a-key'
run_row 'not a key=1'                                  REFUSE 'not a key=1'
run_row 'pr_head=not-a-sha'                            REFUSE 'pr_head=not-a-sha'
