#!/usr/bin/env bash
# wiki-lock.sh — per-file advisory locking for safe multi-writer vault mutation.
#
# Closes the latent multi-writer corruption bug in v1.6 where two parallel
# sub-agents writing to the same wiki page could silently trample each other.
# The README and skills/wiki-ingest/SKILL.md §259-264 documented "single-writer
# only" as a convention; this script makes it an enforceable guard.
#
# Design (age-based, not flock-style):
#   flock(2) advisory locks release when the holding process exits. That
#   doesn't fit our model where `acquire` and `release` are SEPARATE bash
#   invocations from the same skill (each Bash tool call is its own short-
#   lived process — neither's PID survives long enough to mean anything).
#   So we use atomic lockfile creation with `set -o noclobber` plus
#   epoch-timestamp AGE-based staleness detection. Race-safe because the
#   noclobber write itself is atomic on POSIX filesystems.
#
#   The PID written into the lockfile is informational only (helpful for
#   `list` and debugging). The acquire decision considers AGE only:
#     - If lockfile age < STALE_AFTER_SEC → refuse (return 75 EX_TEMPFAIL)
#     - If lockfile age >= STALE_AFTER_SEC → reap and acquire
#   Default STALE_AFTER_SEC=60. Long enough for any single skill operation
#   (page writes are milliseconds; a multi-write ingest pass is seconds);
#   short enough that a crashed holder unblocks quickly.
#
# Semantics:
#   acquire <vault-rel-path>
#     - Computes lock_file = .vault-meta/locks/<sha1(path)>.lock
#     - Atomically creates the lockfile with this process's PID + epoch
#     - Returns 0 if acquired, 75 (EX_TEMPFAIL) if held and age < threshold
#     - Auto-reaps locks older than STALE_AFTER_SEC
#   release <vault-rel-path>
#     - Removes the lockfile unconditionally (rm -f). Idempotent.
#     - Cross-process release IS allowed by design — acquire and release
#       are typically separate bash invocations from the same skill, and
#       PID-matching would never succeed. Skill authors are trusted not to
#       release locks they don't own; that's no weaker than `rm` on the
#       lockfile directly.
#   list
#     - Prints currently-held lock records (one per line: pid age path).
#   clear-stale [--max-age N]
#     - Removes lockfiles whose PID is dead OR whose age > N seconds.
#       Default N = 3600 (1h). Returns count removed via stdout.
#       (The N=3600 default is intentionally generous because clear-stale
#       is admin-grade cleanup, distinct from the per-acquire age threshold.)
#   peek <vault-rel-path>
#     - Prints holder info or "unheld"; exit 0; never mutates.
#
# Globals:
#   STALE_AFTER_SEC — default 60. Override via --stale-after-sec N on any cmd.
#
# Age-threshold naming (v1.7.2; closes audit L6):
#   - STALE_AFTER_SEC (default 60) is the PER-ACQUIRE threshold. A new
#     acquire that finds an existing lock will reap-and-take if the lock is
#     older than this; refuse otherwise. Tuned for "single skill operation
#     completes within 60s."
#   - `clear-stale --max-age N` (default 3600) is the ADMIN reaper threshold,
#     meant to be run periodically by an operator or hook to sweep abandoned
#     locks. Tuned for "anything older than an hour is definitely abandoned."
#   These are two distinct concerns; both are time-since-acquire but operate
#   at different scopes. Do not unify the defaults.
#
# Usage:
#   bash scripts/wiki-lock.sh acquire wiki/concepts/Foo.md
#   bash scripts/wiki-lock.sh release wiki/concepts/Foo.md
#   bash scripts/wiki-lock.sh list
#   bash scripts/wiki-lock.sh clear-stale --max-age 1800
#   bash scripts/wiki-lock.sh peek wiki/concepts/Foo.md
#
# Exit codes:
#   0  — success
#   2  — usage error
#   75 — acquire failed (lock held by alive process)
#   3  — vault-meta/locks dir creation failed
#   4  — invalid vault-relative path (escape attempt)

set -euo pipefail

# ${BASH_SOURCE[0]%/*} is dirname via parameter expansion — no dirname(1) spawn
# (~350ms on MSYS). The script is always invoked with a path containing '/'.
VAULT_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
META_DIR="${VAULT_ROOT}/.vault-meta"
LOCK_DIR="${META_DIR}/locks"
META_LOCK="${META_DIR}/.wiki-lock.meta"
STALE_AFTER_SEC=60

# Cross-platform exclusive lock (flock(1) where present, noclobber-file spin-lock
# on MSYS/git-bash where it is not). See scripts/portable-flock.sh.
# shellcheck source=scripts/portable-flock.sh
. "${BASH_SOURCE[0]%/*}/portable-flock.sh"

# ── helpers ──────────────────────────────────────────────────────────────────
die() { echo "ERR: $*" >&2; exit "${2:-2}"; }
log() { echo "$*" >&2; }

# Allow tests / non-default vault roots to override
if [ -n "${WIKI_LOCK_VAULT:-}" ]; then
  VAULT_ROOT="$WIKI_LOCK_VAULT"
  META_DIR="${VAULT_ROOT}/.vault-meta"
  LOCK_DIR="${META_DIR}/locks"
  META_LOCK="${META_DIR}/.wiki-lock.meta"
fi

sha1_of() {
  # Strip the trailing "  -" with parameter expansion instead of piping to awk
  # (one fewer ~350ms subprocess spawn on the lock hot path).
  local out
  if command -v sha1sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha1sum)
  else
    # macOS fallback
    out=$(printf '%s' "$1" | shasum -a 1)
  fi
  printf '%s' "${out%% *}"
}

ensure_dirs() {
  # Cheap guard: skip the mkdir(1) spawn when the dir already exists (this is
  # called on every command, often twice — once here, once via with_meta_lock).
  [ -d "$LOCK_DIR" ] && return 0
  mkdir -p "$LOCK_DIR" 2>/dev/null || die "cannot create $LOCK_DIR" 3
}

validate_path() {
  # Reject empty, absolute, escape, or newline-bearing paths to prevent
  # lock-namespace pollution. v1.7.2 / closes audit M4: newlines would break
  # the meta-lock line format (key=value lines separated by literal \n).
  # v1.9.1 / closes audit M3 (symlink escape): when a vault-relative path
  # resolves through a symlink to outside VAULT_ROOT, treat as path traversal.
  local p="$1"
  [ -z "$p" ] && die "path cannot be empty" 4
  case "$p" in
    /*) die "path must be vault-relative, not absolute: $p" 4 ;;
    *..*) die "path may not contain '..': $p" 4 ;;
    *$'\n'*) die "path may not contain newlines (lockfile format would break)" 4 ;;
    *$'\r'*) die "path may not contain carriage returns" 4 ;;
  esac
  # Fast path: the rigorous symlink resolve below spawns python3 (~0.5s+ on
  # Windows), which is far too costly on the per-acquire hot path (a 10-worker
  # stress test issues hundreds of acquires — see tests/test_concurrent_write.sh).
  # It is only needed when a symlink can redirect the path outside the vault.
  # Since absolute paths and '..' are already rejected above, a candidate whose
  # existing ancestors are all real (non-symlink) directories resolves lexically
  # to <vault>/<candidate>, which is inside the vault by construction. So we walk
  # the candidate's components with the cheap builtin `[ -L ]` test and only fall
  # through to python3 when an ancestor actually IS a symlink. (Argent cycle 002.)
  local need_resolve=0 _prefix="$VAULT_ROOT" _comp _oldifs="$IFS"
  IFS='/'
  for _comp in $p; do
    [ -z "$_comp" ] && continue
    _prefix="$_prefix/$_comp"
    if [ -L "$_prefix" ]; then need_resolve=1; break; fi
  done
  IFS="$_oldifs"
  [ "$need_resolve" -eq 0 ] && return 0

  # Symlink canonicalization (only reached when an ancestor is a symlink).
  # Non-existent leaves can pass; the lock acquire itself creates leaves under
  # LOCK_DIR, not the path itself. We resolve via python3 (portable across
  # GNU coreutils + macOS BSD where realpath flag semantics differ).
  if command -v python3 >/dev/null 2>&1; then
    local resolved root
    resolved=$(VAULT_ROOT_BASH="$VAULT_ROOT" P_BASH="$p" python3 -c '
import os, sys
root = os.path.realpath(os.environ["VAULT_ROOT_BASH"])
candidate = os.environ["P_BASH"]
target = os.path.realpath(os.path.join(root, candidate))
common = os.path.commonpath([root, target]) if target else ""
sys.stdout.write("INSIDE" if common == root else "OUTSIDE")
' 2>/dev/null)
    [ "$resolved" = "OUTSIDE" ] && die "path resolves outside vault via symlink: $p" 4
  fi
  return 0
}

now_epoch() {
  # Bash builtin epoch — no subprocess. On this lock's hot path a date(1) spawn
  # costs ~350ms on MSYS/Windows; the builtin is free. Falls back to date(1) on
  # bash < 4.2 where the %(...)T format is unsupported. (Argent cycle 002.)
  local e
  if printf -v e '%(%s)T' -1 2>/dev/null; then printf '%s\n' "$e"; else date +%s; fi
}

is_alive() {
  # kill -0 returns 0 if process exists and we can signal it
  kill -0 "$1" 2>/dev/null
}

# Atomic meta-lock wrapper. Funcs that mutate LOCK_DIR call under this lock so
# acquire/release/clear-stale don't race against each other.
with_meta_lock() {
  ensure_dirs
  # Portable exclusive lock; meta lock is short-lived per command. The lock
  # auto-releases when this subshell exits (portable_lock_acquire owns its own
  # fd/lockdir + EXIT-trap release — see scripts/portable-flock.sh).
  (
    portable_lock_acquire "$META_LOCK" 5 || die "could not acquire meta-lock within 5s" 1
    "$@"
  )
}

read_lockfile() {
  # Echoes: <pid> <epoch> <path>  (or empty if file missing/unreadable).
  # Uses a builtin `read` redirect — no head(1) spawn (~350ms on MSYS/Windows).
  local lf="$1" line=""
  [ -f "$lf" ] || return 0
  { read -r line < "$lf"; } 2>/dev/null || true
  printf '%s\n' "$line"
}

# ── commands ─────────────────────────────────────────────────────────────────
# NOTE: path validation and sha1 hashing are PURE functions of the input and are
# performed by the dispatcher BEFORE entering with_meta_lock — holding the global
# meta-lock across a ~420ms sha1sum spawn (MSYS) serialized all writers and made
# the concurrent_write stress test time out. The _cmd_* handlers below receive the
# already-computed lockfile path ($2) and run only the LOCK_DIR mutation, which is
# the sole part needing serialization. (Argent cycle 002.)
_cmd_acquire() {
  local path="$1" lf="$2"
  local now
  now=$(now_epoch)

  # Try the cheap path first: noclobber-atomic create
  if (set -o noclobber; printf '%s %s %s\n' "$$" "$now" "$path" > "$lf") 2>/dev/null; then
    return 0
  fi

  # Lockfile already exists — examine age, not PID. Read fields with a builtin
  # (no head/awk spawns inside the critical section).
  local epid="" eepoch="" erest=""
  { read -r epid eepoch erest < "$lf"; } 2>/dev/null || true
  if [ -z "$eepoch" ]; then
    # Empty/unreadable; treat as stale, clean and retry once
    rm -f "$lf"
    if (set -o noclobber; printf '%s %s %s\n' "$$" "$now" "$path" > "$lf") 2>/dev/null; then
      return 0
    fi
    return 75
  fi

  # Numeric sanity (corrupt lockfile → treat as stale)
  case "$eepoch" in
    *[!0-9]*) rm -f "$lf"
                 (set -o noclobber; printf '%s %s %s\n' "$$" "$now" "$path" > "$lf") 2>/dev/null && return 0
                 return 75 ;;
  esac
  local age=$((now - eepoch))

  if [ "$age" -gt "$STALE_AFTER_SEC" ]; then
    # Age exceeds threshold → reap and re-acquire (regardless of holder PID)
    rm -f "$lf"
    if (set -o noclobber; printf '%s %s %s\n' "$$" "$now" "$path" > "$lf") 2>/dev/null; then
      return 0
    fi
    return 75
  fi

  # Held and not yet stale by age — refuse
  return 75
}

_cmd_release() {
  local path="$1" lf="$2"
  # Unconditional remove — cross-process release is allowed by design
  # (acquire and release are typically separate bash invocations from the
  # same skill; PID-matching would never succeed). See header comment.
  rm -f "$lf"
  return 0
}

_cmd_list() {
  ensure_dirs
  local count=0
  for lf in "$LOCK_DIR"/*.lock; do
    [ -f "$lf" ] || continue
    local rec
    rec=$(read_lockfile "$lf")
    [ -n "$rec" ] || continue
    local pid epoch path now age
    pid=$(printf '%s' "$rec" | awk '{print $1}')
    epoch=$(printf '%s' "$rec" | awk '{print $2}')
    path=$(printf '%s' "$rec" | cut -d' ' -f3-)
    now=$(now_epoch)
    age=$((now - epoch))
    printf 'pid=%s age=%ss path=%s\n' "$pid" "$age" "$path"
    count=$((count + 1))
  done
  return 0
}

_cmd_clear_stale() {
  local max_age="$1"
  ensure_dirs
  local removed=0
  local now
  now=$(now_epoch)
  for lf in "$LOCK_DIR"/*.lock; do
    [ -f "$lf" ] || continue
    local rec
    rec=$(read_lockfile "$lf")
    if [ -z "$rec" ]; then
      rm -f "$lf"; removed=$((removed + 1)); continue
    fi
    local pid epoch age
    pid=$(printf '%s' "$rec" | awk '{print $1}')
    epoch=$(printf '%s' "$rec" | awk '{print $2}')
    age=$((now - epoch))
    if ! is_alive "$pid" || [ "$age" -gt "$max_age" ]; then
      rm -f "$lf"; removed=$((removed + 1))
    fi
  done
  echo "$removed"
  return 0
}

_cmd_peek() {
  local path="$1" lf="$2"
  if [ ! -f "$lf" ]; then
    echo "unheld"
    return 0
  fi
  local rec
  rec=$(read_lockfile "$lf")
  echo "$rec"
  return 0
}

# ── arg parsing (flags accepted in any position) ─────────────────────────────
if [ $# -lt 1 ]; then
  sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

CMD=""
ARGS=()
MAX_AGE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stale-after-sec) STALE_AFTER_SEC="$2"; shift 2 ;;
    --max-age)         MAX_AGE_OVERRIDE="$2"; shift 2 ;;
    -h|--help)         sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *)
      if [ -z "$CMD" ]; then
        CMD="$1"
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

[ -n "$CMD" ] || die "no command given"

# Validate (die propagates — NOT run in a subshell) and compute the lockfile path
# BEFORE taking the meta-lock, so the ~420ms sha1sum spawn stays out of the
# critical section. (Argent cycle 002.)
case "$CMD" in
  acquire)
    [ ${#ARGS[@]} -ge 1 ] || die "acquire needs a path"
    validate_path "${ARGS[0]}"
    LF="${LOCK_DIR}/$(sha1_of "${ARGS[0]}").lock"
    with_meta_lock _cmd_acquire "${ARGS[0]}" "$LF"
    ;;
  release)
    [ ${#ARGS[@]} -ge 1 ] || die "release needs a path"
    validate_path "${ARGS[0]}"
    LF="${LOCK_DIR}/$(sha1_of "${ARGS[0]}").lock"
    with_meta_lock _cmd_release "${ARGS[0]}" "$LF"
    ;;
  list)
    with_meta_lock _cmd_list
    ;;
  clear-stale)
    MAX="${MAX_AGE_OVERRIDE:-${ARGS[0]:-3600}}"
    with_meta_lock _cmd_clear_stale "$MAX"
    ;;
  peek)
    [ ${#ARGS[@]} -ge 1 ] || die "peek needs a path"
    validate_path "${ARGS[0]}"
    LF="${LOCK_DIR}/$(sha1_of "${ARGS[0]}").lock"
    with_meta_lock _cmd_peek "${ARGS[0]}" "$LF"
    ;;
  *)
    die "unknown command: $CMD (try acquire|release|list|clear-stale|peek)"
    ;;
esac
