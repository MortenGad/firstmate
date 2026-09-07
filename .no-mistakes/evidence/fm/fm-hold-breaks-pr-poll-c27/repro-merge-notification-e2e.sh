#!/usr/bin/env bash
# End-to-end reproduction for "a metadata key written after pr= disarms an
# armed merge poll".
#
# Usage: repro-merge-notification-e2e.sh <repo-root> <label>
#
# Drives the real product surfaces, no unit-test seams:
#   1. bin/fm-pr-check.sh arms a merge poll for a task (fake `gh` forge CLI).
#   2. bin/fm-captain-hold.sh complete   - a real writer - appends
#      decisions_reviewed= / decision_keys= AFTER the pr= line.
#   3. bin/fm-watch.sh runs one bounded cycle with the PR reported MERGED and
#      the wake it delivers to firstmate is printed verbatim.
#
# Expected: "check: <state>/task-a.check.sh: merged" (the merge notification).
# The defect shows up as "check: rejected unauthenticated state checks: ...".
set -u

ROOT_UNDER_TEST=$1
LABEL=$2

# shellcheck source=/dev/null
. "$ROOT_UNDER_TEST/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
URL=https://github.com/o/r/pull/10
ID=task-a

say() { printf '\n=== %s\n' "$*"; }

dir=$(fm_test_tmproot "repro-$LABEL")
mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" \
  "$dir/fakebin" "$dir/root/bin"
state="$dir/home/state"

cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$dir/root/bin/fm-guard.sh"

# Fake forge CLI: the PR is MERGED, exactly what the poll is armed to detect.
cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "api graphql")
    printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main'
    exit 0 ;;
esac
case " $* " in
  *" headRefOid "*) printf '%s\n' "0123456789abcdef0123456789abcdef01234567" ;;
  *" state "*)     printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
esac
SH
cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "$3" ;;
esac
SH
chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi"

printf 'repo under test: %s\n' "$ROOT_UNDER_TEST"
printf 'commit:          %s\n' \
  "$(git -C "$ROOT_UNDER_TEST" rev-parse --short HEAD 2>/dev/null || echo '<archived base copy>')"

fm_write_meta "$state/$ID.meta" \
  "window=firstmate:fm-$ID" "endpoint_task_id=$ID" "worktree=$dir/wt" \
  "project=$dir/project" "kind=ship" "mode=no-mistakes"

say "1. captain arms the merge poll:  bin/fm-pr-check.sh $ID $URL"
FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
  "$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" || exit 1

say "state/$ID.meta once the poll is armed"
cat "$state/$ID.meta"

say "2. a real later writer runs:  bin/fm-captain-hold.sh complete $ID --none"
cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml" 2>/dev/null || true
printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
(cd "$dir/home" && tasks-axi add "$ID" "merge poll fixture" --kind ship --start >/dev/null) || exit 1
PATH="$(dirname "$(command -v tasks-axi)"):$BASE_PATH" \
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
  "$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none >/dev/null || exit 1

say "state/$ID.meta after that writer (note what now sits below pr=)"
cat "$state/$ID.meta"

say "3. the PR merges; one bounded bin/fm-watch.sh cycle"
set +e
perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 20; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
  env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    FM_TEST_GH_STATE=MERGED PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err"
rc=$?
set -e

say "what firstmate is told (bin/fm-watch.sh stdout)"
cat "$dir/watch.out"
printf '(watcher exit=%s)\n' "$rc"

say "durable wake queue row (state/.wake-queue)"
cat "$state/.wake-queue" 2>/dev/null || printf '<no wake queued>\n'

say "verdict"
if grep -q "$ID.check.sh: merged" "$dir/watch.out"; then
  printf 'MERGE NOTIFICATION DELIVERED for %s\n' "$URL"
elif grep -q 'rejected unauthenticated state checks' "$dir/watch.out"; then
  printf 'MERGE NOTIFICATION LOST - the armed poll was refused as unauthenticated\n'
else
  printf 'UNEXPECTED watcher output\n'
fi
