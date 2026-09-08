# Evidence index

## Current for branch head 915761e

- `deadlock-before-after.txt` - end-to-end before/after transcript of the
  2026-09-06 deadlock, produced by `deadlock-repro.sh`. Real Firstmate homes
  carrying the real `bin/` tree of the branch base (b84e0e3) and of the branch
  head (915761e); every "Stop" is a real `fm-turnend-guard.sh --claude` hook
  invocation under a harness process that owns `state/.lock`. Covers both
  variants the intent names: the frozen epoch (165 rewake) and the advancing
  epoch (166 failed -> 167 rewake).
- `deadlock-repro.sh` - the reproducer. Run as
  `deadlock-repro.sh <firstmate-checkout> b84e0e362face25f3dd8945297a3df1320d7668c`.

## Superseded - do not read as head behaviour

- `banner-honesty-e2e.txt` / `banner-honesty-e2e.sh` (captured at e823344)
- `turnend-deadlock-e2e.txt` / `turnend-deadlock-e2e.sh` (captured against base 6d396da)

Both were captured before d8e407d collapsed the refusal banner to one
unconditional sentence, so they show a banner line that no longer exists:
"This refusal primed a detached watcher start that survives it ...". They also
predate 915761e, which moved priming below the attended fail-open. The banner
text at head is the one in `deadlock-before-after.txt`.
