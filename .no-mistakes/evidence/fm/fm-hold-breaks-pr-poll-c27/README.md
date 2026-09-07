# Evidence: a metadata key written after `pr=` no longer disarms an armed merge poll

The reported failure is invisible by construction: when it fires, firstmate is never
told a pull request merged. So the evidence is the wake `bin/fm-watch.sh` actually
delivers, captured on the base commit and on this branch, driving the real surfaces
(`bin/fm-pr-check.sh` arms, a real later writer appends, `bin/fm-watch.sh` polls a
MERGED pull request). Only the forge CLI is faked.

| file | what it shows |
| --- | --- |
| `e2e-1-before-fix-merge-notification-lost.txt` | base `1533f47`: `bin/fm-captain-hold.sh complete` lands `decisions_reviewed=` / `decision_keys=` under `pr=`, and the next watcher cycle says `check: rejected unauthenticated state checks: …/task-a.check.sh`. The merge notification is lost. |
| `e2e-2-after-fix-merge-notification-delivered.txt` | same script, this branch `35ea074`: identical metadata, and the watcher delivers `check: …/task-a.check.sh: merged` plus the durable `check: merge landed: task-a https://github.com/o/r/pull/10` wake row. |
| `e2e-4-fail-closed-matrix-before-fix.txt` | base: `control_relaunch_tx=` (the `bin/fm-control.sh relaunch` writer), the captain-hold keys, and an arbitrary future key each disarm the poll; only the whitelisted `x_request=` survives. |
| `e2e-3-fail-closed-matrix.txt` | this branch: all five well-formed later keys deliver the merge, and a second `pr=`, a non-key line, a malformed `not a key=1`, and an invalid `pr_head=` are all still refused as unauthenticated. |

Reproduction scripts (`repro-merge-notification-e2e.sh <repo-root> <label>`,
`repro-fail-closed-e2e.sh <repo-root>`) are included; the base rows were produced
by pointing them at a `git archive` copy of `1533f47`.

`e2e-5-regression-before-after.txt` runs the three new tests unchanged against base
`bin/` and against this branch's `bin/` (only `bin/` differs): each regression case
fails on base and passes here, the tamper guard passes on both, and with `tasks-axi`
removed from `PATH` the captain-hold case skips while the later cases still run.
