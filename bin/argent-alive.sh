#!/usr/bin/env bash
# argent-alive.sh — headless driver for the Argent Alive self-improvement loop.
#
# Each iteration spawns `claude -p` to run ONE cycle of docs/argent/charter.md.
# Cross-cycle memory lives only in docs/argent/journal.md. Every cycle commits,
# so each cycle is its own checkpoint. Transient claude failures (e.g. API 500)
# are retried with backoff; the run ends on budget, on the ARGENT-STOP sentinel
# (idle/plateau/breaker), or after MAX_ATTEMPTS consecutive hard failures.
#
# Usage:  bash bin/argent-alive.sh [BUDGET]      (default BUDGET=6)
# Safety: refuses to run on `main`; runs only on the argent/alive branch.
set -uo pipefail

BUDGET="${1:-6}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "cannot cd to repo root"; exit 1; }

BR="$(git branch --show-current 2>/dev/null || echo '?')"
if [ "$BR" = "main" ] || [ "$BR" = "master" ]; then
  echo "Refusing to run on protected branch '$BR'. Use the argent/alive branch."
  exit 2
fi

LOG="$ROOT/docs/argent/runner.log"
mkdir -p "$ROOT/docs/argent"

# Bridge `python3` to a real interpreter (and force UTF-8 I/O) for the entire
# spawned subtree — claude -p and every shell it opens inherit this environment.
export PATH="$ROOT/bin/pyshim:$PATH"
export PYTHONUTF8=1

read -r -d '' PROMPT <<'EOF'
You are Argent, alive. Read docs/argent/charter.md (your program) and
docs/argent/journal.md (your memory) IN FULL before doing anything else.

Then run EXACTLY ONE complete cycle as the charter defines:
ORIENT -> DECIDE -> ACT -> VERIFY -> RECORD. Commit your work on the current
(argent/alive) branch via the normal path. Do NOT start a second cycle.

EXECUTION MODEL: you are a single, synchronous, headless invocation. Run every
command in the FOREGROUND and wait for it inline. NEVER launch a background
process and wait for an async "completion notification" — there is none; your
process simply ends. You MUST finish the entire cycle (run the test suite to
completion AND commit) before you produce your final output. Leaving uncommitted
changes in the working tree means the cycle is lost.

Honor the charter's rubric, discipline, and governors exactly. If a stop, idle,
plateau, or circuit-breaker condition fires, write a run digest to the journal
and print the exact token ARGENT-STOP on its own line as your final output.
Otherwise, end your final output with the exact token ARGENT-CONTINUE.
EOF

echo "=== Argent Alive run START $(date '+%F %T') | budget=$BUDGET | branch=$BR ===" | tee -a "$LOG"

MAX_ATTEMPTS=3
for ((i=1; i<=BUDGET; i++)); do
  echo "--- cycle $i/$BUDGET @ $(date '+%F %T') ---" | tee -a "$LOG"

  # Clean-start guard: a cycle is atomic (commits at the end). Any uncommitted
  # leftovers mean a prior cycle was interrupted mid-flight — discard them so this
  # cycle starts from the last good checkpoint. runner.log is gitignored, so a
  # plain `git clean -fd` (no -x) preserves it.
  if [ -n "$(git status --porcelain)" ]; then
    echo "   (clean-start) discarding uncommitted leftovers from an interrupted cycle" | tee -a "$LOG"
    git reset --hard HEAD >/dev/null 2>&1
    git clean -fd >/dev/null 2>&1
  fi

  # Retry transient failures (e.g. API 500) instead of killing the whole loop.
  RC=1; attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    OUT="$(claude -p "$PROMPT" --permission-mode bypassPermissions --add-dir "$ROOT" 2>&1)"
    RC=$?
    printf '%s\n' "$OUT" | tee -a "$LOG"
    [ "$RC" -eq 0 ] && break
    echo "!! claude -p exited rc=$RC (cycle $i, attempt $attempt/$MAX_ATTEMPTS) — likely transient; backing off." | tee -a "$LOG"
    # discard any half-written work before retrying the cycle from a clean tree
    git reset --hard HEAD >/dev/null 2>&1; git clean -fd >/dev/null 2>&1
    sleep $((attempt * 30))
    attempt=$((attempt + 1))
  done

  if [ "$RC" -ne 0 ]; then
    echo "!! cycle $i failed after $MAX_ATTEMPTS attempts; ending run." | tee -a "$LOG"
    break
  fi
  if printf '%s' "$OUT" | grep -q 'ARGENT-STOP'; then
    echo ">> Argent signaled ARGENT-STOP on cycle $i; ending run." | tee -a "$LOG"
    break
  fi
  sleep 3
done

echo "=== Argent Alive run END $(date '+%F %T') ===" | tee -a "$LOG"
