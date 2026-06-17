# Argent Cycle 002 — Audit

**Date:** 2026-06-17
**Slice:** cross-platform script portability — bash concurrency-lock layer
**Lenses:** 10-principle loop (`/think`) + best-practices six-cut
**Test command:** `bash bin/run-tests.sh` (no `make` on this Windows/MSYS box)

## ORIENT — baseline

Suite before this cycle: **5 passed, 4 failed** (unchanged from end of cycle 001).

Failing tests:

| Test | Root cause | Slice |
|------|-----------|-------|
| `tests/test_wiki_lock.sh` | `scripts/wiki-lock.sh:156` `flock: command not found` (MSYS has no `flock(1)`) | this slice (F2) |
| `tests/test_concurrent_write.sh` | cascades from `wiki-lock.sh:156` (same `flock`) | this slice (F2) |
| `tests/test_allocate_address.sh` | `scripts/allocate-address.sh:36` `flock: command not found` | this slice (F2) |
| `tests/test_boundary_score.py` | `os.symlink` needs privilege on Windows (F3) | NOT this slice |

`command -v flock` → empty; `bash --version` → `5.2.37(1)-release (x86_64-pc-msys)`. The
`flock(1)` utility ships with util-linux on Linux/macOS but not with MSYS/git-bash, so
both bash scripts that serialize a critical section with `flock -x -w 5 9` abort at the
lock line on Windows.

This is the continuation of cycle 001's portability slice. Cycle 001 closed the **Python**
`fcntl` half (F1) via `scripts/portable_lock.py`; the **bash** `flock(1)` half (F2) was left
as an open thread. The `.py` scripts (`tiling-check.py`, `bm25-index.py`, `rerank.py`) already
route through the `portable_lock` shim and are unaffected.

## Slice findings (with `file:line` evidence)

| ID | Tier | Evidence | Tests blocked |
|----|------|----------|---------------|
| F2a | HIGH | `scripts/wiki-lock.sh:156` — `flock -x -w 5 9` is the sole `flock(1)` dependency; the per-file locks already use portable `noclobber` atomic create | test_wiki_lock |
| F2b | HIGH | `scripts/wiki-lock.sh:156` (same) cascades into the multi-writer stress test | test_concurrent_write |
| F2c | HIGH | `scripts/allocate-address.sh:36` — `flock -x -w 5 9` guarding the counter read-increment-write | test_allocate_address |

**Score before = 100 − (4 × 3 HIGH) = 88.**

(F3 — symlink-privilege at `tests/test_boundary_score.py:242` — is a different surface
[Python test fixture, not bash locking] and is left for a later cycle.)

## DECIDE

Highest-leverage: F2 (one root cause, three red tests). Mirror the cycle-001 strategy:
prefer the native primitive where present, emulate it portably otherwise — but for shell.

**Hypothesis:** 88 → ~97 because a feature-detecting `portable_lock_acquire` turns
test_wiki_lock + test_concurrent_write + test_allocate_address green (3 HIGH → 0),
leaving only minor residue (a doc-drift MEDIUM + missing-unit-test LOW), with no
previously-green test going red.

## ACT

The flock swap was the *start*; closing all three F2 tests on Windows required dealing
with two perf cliffs that the swap exposed (they were masked while `flock`'s fast "command
not found" abort short-circuited the whole handler). On MSYS/Windows every external process
spawn costs ~350-420ms and bash startup ~436ms — costs that are ~3ms on POSIX, which is why
the original code never noticed them.

**1. New `scripts/portable-flock.sh` (sourced helper).**
`portable_lock_acquire <lockpath> [timeout_sec]` — exclusive lock with `flock(1)`-style
auto-release (lives for the holding shell/subshell, released on its exit).
- `flock(1)` present → open a dedicated fd on `<lockpath>` and `flock -x -w` it —
  byte-for-byte the prior behavior on Linux/macOS; kernel releases on fd close.
- `flock(1)` absent → atomic **`noclobber`-file** spin-lock (`set -o noclobber; > file` is
  the same atomic create-or-fail primitive `wiki-lock.sh`'s per-file locks already use).
  An initial `mkdir <lockpath>.lockd` design **livelocked** `concurrent_write` on Windows'
  deferred directory-delete semantics under ~500 rapid create/delete cycles; the single-file
  primitive does not. Auto-release via `EXIT` trap; stale-reap (`_PORTABLE_LOCK_STALE_SEC`,
  default 30s) for a hard-killed holder. Loop uses only bash builtins (`printf -v` epoch,
  `read < file`) — zero spawns on the contended path. A missing/empty/corrupt epoch is
  treated as *still-held* (not reaped) to avoid stealing a lock during the create-then-write
  window.

**2. `scripts/wiki-lock.sh` — swap + critical-section shrink (the real fix for
`concurrent_write`).** The headline defect the six-cut "minimal critical section" lens
surfaced: `_cmd_acquire` ran `validate_path` + `sha1_of` (a ~420ms `sha1sum` spawn) **inside**
the global meta-lock, so 10 writers serialized through a ~500ms-held lock → time-out.
- `validate_path` + `sha1_of` are pure functions of the input → moved to the dispatcher,
  BEFORE `with_meta_lock`. `_cmd_acquire/_cmd_release/_cmd_peek` now receive the precomputed
  lockfile path (`$2`); the meta-lock now wraps only the `LOCK_DIR` mutation (sub-ms).
- `with_meta_lock` sources the helper and calls `portable_lock_acquire "$META_LOCK" 5`
  inside its subshell (subshell exit → trap releases); the `9>"$META_LOCK"` fd redirect dropped.
- Spawn cuts on the hot path: `validate_path` gains a fast-path that skips the ~0.5s `python3`
  symlink canonicalization when no ancestor of the candidate is a symlink (cheap builtin
  `[ -L ]` walk; rigorous `python3` check unchanged and still runs when a symlink IS present —
  M3 protection intact); `now_epoch` uses the `printf '%(%s)T'` builtin (no `date` spawn);
  `read_lockfile` + the in-loop field parse use builtin `read` (no `head`/`awk`); `sha1_of`
  strips with `${out%% *}` (no `awk`); `dirname` → `${BASH_SOURCE[0]%/*}`; `ensure_dirs`
  guards on `[ -d ]`.

**3. `scripts/allocate-address.sh`** — sources the helper; `portable_lock_acquire "$LOCK_FILE"
5`; script exit → trap releases; exit-1-on-timeout preserved. `dirname` → param expansion.

**4. Tests.**
- `tests/test_allocate_address.sh:32` — also copies `portable-flock.sh` into the sandbox so
  the `source` resolves (analogue of cycle 001's `test_retrieve.py` copy-list extension).
- `tests/test_wiki_lock.sh:146` — the CR-path assertion was a latent test-portability bug
  exposed once the lock worked: MSYS strips CR (`0x0d`) from a child's argv inside `$(...)`
  command substitution (verified by `od`: `Foo\rbar.md` → `Foobar.md`; newlines survive), so
  the path arrived without a CR and `validate_path` had nothing to reject (false `rc=0`),
  which also created a spurious 11th lock and failed the "10 unique paths" assertion. Fixed by
  capturing `$?` directly from the subshell instead of via `$(...)`, preserving the CR on all
  platforms. `validate_path` itself was already correct — not touched for this.

## VERIFY

`bash bin/run-tests.sh` — **before: 5 passed / 4 failed → after: 8 passed / 1 failed.**
The lone remaining red is `test_boundary_score.py` (pre-existing F3 symlink-privilege, a
different slice, untouched). The three F2 tests are green; no previously-green test went red.

`test_concurrent_write` characterization: hard hang (>120s timeout) → reliable **~51-58s**
across 7 consecutive runs (≈2× margin under the runner's 120s per-test budget). The mkdir-lock
intermediate and the in-critical-section `sha1sum` were each independently capable of timing
it out; both are resolved.

Re-audit of the touched surface:

| Residual | Tier | Evidence |
|----------|------|----------|
| Doc/behavior drift | MEDIUM | `docs/dragonscale-guide.md:53-65` still calls `flock` a hard prerequisite ("treat as a blocker") though both bash lock paths now degrade gracefully. Reconcile next cycle. |
| sha1sum still per-invocation | LOW | `sha1_of` still spawns one `sha1sum` (~420ms) per lock op; it is now OUT of the critical section (parallelizes) but is the dominant remaining per-op cost. A pure-bash filename derivation would remove it (changes the lockfile-naming scheme → deferred). |
| No isolated unit test | LOW | `portable-flock.sh`'s explicit timeout-returns-1 branch is exercised only indirectly by the integration tests; no `tests/test_portable_flock.sh`. |
| Undocumented stale knob | LOW | `_PORTABLE_LOCK_STALE_SEC` default (30s) is documented only in the helper, not in the two consuming scripts. |

**Score before = 88 (3 standing HIGH). Score after = 100 − (2×1 MEDIUM + 0.5×3 LOW) = 96.5. Δ = +8.5.**
Failing-test count: 4 → 1. WIN — top finding (F2, all 3 tests) closed, score strictly rose,
regression gate held.

## Open threads (carried forward)

- **F3** — guard the symlink assertion at `tests/test_boundary_score.py:242` when symlinks are
  unprivileged on Windows (1 test, the last remaining red — highest-leverage next move).
- **M(002-1)** — reconcile `docs/dragonscale-guide.md:53-65` flock-prerequisite language
  ("treat as a blocker") with the new bash fallback now that allocator + wiki-lock degrade
  gracefully.
- **L(002-1)** — add hermetic `tests/test_portable_flock.sh` covering the timeout-returns-1
  and mutual-exclusion branches of `portable_lock_acquire` in isolation.
- **L(002-2)** — `sha1_of` still spawns one `sha1sum` per lock op (~420ms on Windows); a
  pure-bash filename derivation would remove the dominant remaining per-op cost (changes the
  lockfile-naming scheme — needs its own audit).
- **L(002-3)** — document `_PORTABLE_LOCK_STALE_SEC` in the two consuming scripts, not only in
  the helper.
- (from cycle 001) M1 — `portable_lock.py:67` blocking `LOCK_EX` spin-loop has no timeout.
- (from cycle 001) M2 — no hermetic `tests/test_portable_lock.py` for the Windows emulation branch.

## Dead ends

None.
