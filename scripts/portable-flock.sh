#!/usr/bin/env bash
# portable-flock.sh — sourced helper: cross-platform exclusive lock with
# flock(1)-style auto-release.
#
# Why this exists (Argent cycle 002, closes journal thread F2):
#   scripts/wiki-lock.sh and scripts/allocate-address.sh serialized their
#   critical sections with `flock -x -w N 9`. The flock(1) utility ships with
#   util-linux on Linux/macOS but NOT with MSYS/git-bash, so on Windows those
#   scripts aborted at the lock line with "flock: command not found", taking
#   test_wiki_lock, test_concurrent_write, and test_allocate_address red.
#
#   This mirrors the cycle-001 portable_lock.py strategy for the Python fcntl
#   gap: prefer the native primitive where present, emulate it portably otherwise.
#
# API:
#   portable_lock_acquire <lockpath> [timeout_sec]
#     Acquire an exclusive lock identified by <lockpath>. Blocks up to
#     timeout_sec (default 5). Returns 0 on success, 1 on timeout.
#     LIFETIME CONTRACT: the lock auto-releases when the holding shell — process
#     OR subshell — exits, identical to `flock -x <fd>` holding a redirect open.
#     Callers therefore do NOT release explicitly; they just let their shell
#     (or `( ... )` subshell) exit, exactly as the prior flock-based code did.
#
# Implementation:
#   - flock(1) present → open a dedicated fd on <lockpath> and flock it. The fd
#     stays open for the life of the shell, so the kernel releases the lock on
#     exit precisely as before. Behavior on Linux/macOS is unchanged.
#   - flock(1) absent  → atomic `noclobber` lockFILE spin-lock. `set -o
#     noclobber` makes `> file` an atomic create-or-fail, the same primitive
#     scripts/wiki-lock.sh already uses for its per-file locks (proven under the
#     concurrent_write stress test). A plain file is used rather than a mkdir
#     lockdir because rapid mkdir/rmdir churn livelocks on Windows' deferred
#     directory-delete semantics, whereas single-file create/unlink does not.
#     Auto-release is wired through an EXIT trap; a holder hard-killed without
#     running its trap is reaped once its lockfile epoch is older than
#     _PORTABLE_LOCK_STALE_SEC.

# Stale threshold (seconds): a lockfile whose owner died without releasing is
# reaped after this long. Both consumers hold the lock for milliseconds, so 30s
# is comfortably past any legitimate hold yet bounds deadlock from a hard kill.
_PORTABLE_LOCK_STALE_SEC="${_PORTABLE_LOCK_STALE_SEC:-30}"

# Space-separated list of lockfiles this shell currently owns (noclobber branch).
__PORTABLE_LOCK_FILES=""

__portable_lock_release_all() {
  local f
  for f in $__PORTABLE_LOCK_FILES; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null
  done
  __PORTABLE_LOCK_FILES=""
  return 0
}

portable_lock_acquire() {
  local lockpath="$1"
  local timeout="${2:-5}"

  if command -v flock >/dev/null 2>&1; then
    # Native path: open a dedicated fd, lock it, leave it open. Kernel releases
    # on shell/subshell exit — same contract the callers relied on before.
    local fd
    exec {fd}>"$lockpath" || return 1
    flock -x -w "$timeout" "$fd"
    return $?
  fi

  # ── portable noclobber-file spin-lock ─────────────────────────────────────
  # ~20 polls/second; at least one attempt even for timeout 0.
  local max_polls=$(( timeout * 20 ))
  [ "$max_polls" -lt 1 ] && max_polls=1
  local polls=0

  # Everything in this loop uses bash builtins (printf -v, read < file) rather
  # than spawning date/awk/cat — each external spawn costs ~350ms on MSYS/Windows
  # and this is the contended hot path.
  local now oepoch age _pid _rest
  while :; do
    printf -v now '%(%s)T' -1 2>/dev/null || now=$(date +%s)

    # Atomic create-or-fail. On success we own the lock and record our epoch.
    if (set -o noclobber; printf '%s %s\n' "$$" "$now" > "$lockpath") 2>/dev/null; then
      __PORTABLE_LOCK_FILES="$__PORTABLE_LOCK_FILES $lockpath"
      trap '__portable_lock_release_all' EXIT
      return 0
    fi

    # Held — reap ONLY if the holder's recorded epoch is older than the stale
    # threshold (holder died without releasing). A missing/empty/corrupt epoch is
    # treated as "still held": it is almost always the microsecond window where a
    # fresh holder has created the lockfile (atomic) but not yet written its
    # epoch. Reaping it there would steal a live lock, so we just keep polling;
    # a genuinely corrupt lockfile simply blocks until our timeout (caller errors
    # out safely — no false acquire).
    oepoch=""
    { read -r _pid oepoch _rest < "$lockpath"; } 2>/dev/null || true
    case "$oepoch" in
      ''|*[!0-9]*) : ;;  # empty/corrupt → assume mid-write; poll again
      *)
        age=$(( now - oepoch ))
        if [ "$age" -gt "$_PORTABLE_LOCK_STALE_SEC" ]; then
          rm -f "$lockpath" 2>/dev/null || true
          continue
        fi
        ;;
    esac

    polls=$(( polls + 1 ))
    [ "$polls" -ge "$max_polls" ] && return 1
    sleep 0.05 2>/dev/null || sleep 1
  done
}
