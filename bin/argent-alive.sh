#!/usr/bin/env bash
# argent-alive.sh — headless driver for the Argent Alive self-improvement loop.
#
# Each iteration spawns `claude -p` to run ONE cycle of docs/argent/charter.md.
# Cross-cycle memory lives only in docs/argent/journal.md. Every cycle commits,
# so each cycle is its own checkpoint. Stops on budget, on the ARGENT-STOP
# sentinel (idle/plateau/breaker), or on a non-zero claude exit.
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

Honor the charter's rubric, discipline, and governors exactly. If a stop, idle,
plateau, or circuit-breaker condition fires, write a run digest to the journal
and print the exact token ARGENT-STOP on its own line as your final output.
Otherwise, end your final output with the exact token ARGENT-CONTINUE.
EOF

echo "=== Argent Alive run START $(date '+%F %T') | budget=$BUDGET | branch=$BR ===" | tee -a "$LOG"

for ((i=1; i<=BUDGET; i++)); do
  echo "--- cycle $i/$BUDGET @ $(date '+%F %T') ---" | tee -a "$LOG"
  OUT="$(claude -p "$PROMPT" --permission-mode bypassPermissions --add-dir "$ROOT" 2>&1)"
  RC=$?
  printf '%s\n' "$OUT" | tee -a "$LOG"
  if [ "$RC" -ne 0 ]; then
    echo "!! claude -p exited rc=$RC on cycle $i; ending run." | tee -a "$LOG"
    break
  fi
  if printf '%s' "$OUT" | grep -q 'ARGENT-STOP'; then
    echo ">> Argent signaled ARGENT-STOP on cycle $i; ending run." | tee -a "$LOG"
    break
  fi
  sleep 3
done

echo "=== Argent Alive run END $(date '+%F %T') ===" | tee -a "$LOG"
