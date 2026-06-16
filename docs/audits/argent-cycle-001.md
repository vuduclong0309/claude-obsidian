# Argent Cycle 001 — Audit

- **Date:** 2026-06-16
- **Slice:** cross-platform script portability (the standing failing-test frontier)
- **Test command:** `bash bin/run-tests.sh` (no `make` on this Windows box)
- **Lenses:** 10-principle loop (`/think`) + best-practices six-cut

## Slice score (before)

By the rubric, every failing test is a standing **HIGH** finding. Before-state
suite: **2 passed, 7 failed** → 7 HIGH.

```
slice_score = 100 − 4·7 = 72
```

## Findings (file:line cited)

| ID | Tier | Evidence | Tests broken |
|----|------|----------|--------------|
| F1 | HIGH | `scripts/tiling-check.py:30`, `scripts/bm25-index.py:49`, `scripts/rerank.py:45` — `import fcntl` raises `ModuleNotFoundError: No module named 'fcntl'` on Windows (fcntl is POSIX-only) | test_tiling_check, test_bm25_index, test_retrieve (3) |
| F2 | HIGH | `scripts/wiki-lock.sh:156` (+ `scripts/allocate-address.sh`) — `flock: command not found` under MSYS/git-bash | test_wiki_lock, test_concurrent_write (2) |
| F3 | HIGH | `tests/test_boundary_score.py:242` — `link.symlink_to(real)` → `WinError 1314` (symlink privilege not held) | test_boundary_score (1) |

(F2 also implicated in test_allocate_address; counted under the flock family.)

## DECIDE

**Highest-leverage finding: F1.** One root cause (`import fcntl` is Unix-only)
closes 3 of the 7 failing tests — the largest single-finding leverage on the
frontier. F2 closes 2, F3 closes 1.

**Hypothesis:** closing F1 raises the slice score **72 → 84** (7 HIGH → 4 HIGH)
because test_tiling_check, test_bm25_index, and test_retrieve go green, with no
previously-passing test turning red.

## ACT (smallest change that closes F1)

- New `scripts/portable_lock.py`: a drop-in shim exposing the exact `fcntl`
  subset the scripts use (`LOCK_EX`, `LOCK_NB`, `LOCK_UN`, `flock(fd, op)`). On
  POSIX it re-exports real `fcntl` (zero behavior change on Linux). On Windows it
  emulates flock via `msvcrt.locking` over a single byte at offset 0, normalizing
  a non-blocking would-block to `BlockingIOError` so callers' existing
  `except BlockingIOError` clauses (e.g. `rerank.py:158`) keep working. File
  position is saved/restored around the lock.
- Each consumer's `import fcntl` replaced with a 3-line bootstrap that appends the
  script's own dir to `sys.path` and does `import portable_lock as fcntl` — so
  **no flock call-site changed**. `sys.path.append` (not `insert`) avoids any
  stdlib shadowing (verified no `scripts/*.py` collides with a stdlib name).
- `tests/test_retrieve.py`: the sandbox-copy lists (4 sites) gained
  `portable_lock.py`, since it is now a genuine runtime dependency of the copied
  scripts. The `bm25 build rc=0` assertion is unchanged — only the fixture's
  dependency graph was made faithful (not weakened).

Empirically validated the `msvcrt` primitive out-of-band: NB-acquire on a held
lock raises `PermissionError` (errno 13, an `OSError` subclass); release then
re-acquire succeeds.

## VERIFY

- Suite after: **5 passed, 4 failed** (`bash bin/run-tests.sh`).
- Newly green: test_tiling_check, test_bm25_index, test_retrieve.
- Still green (no regression): test_wiki_mode, test_contextual_prefix.
- Remaining red: test_allocate_address, test_boundary_score, test_wiki_lock,
  test_concurrent_write — all F2/F3, out of scope for a one-finding cycle.

**Slice score (after):** 4 HIGH → `100 − 4·4 = 84`. **Δ +12 (72 → 84).**
Regression gate: **held** (failing-test count 7 → 4; no hook/script broke).
**Result: WIN — KEEP.**

## Open threads (deferred)

- F2 — portable bash lock (mkdir-based or `flock` feature-detect) for
  `wiki-lock.sh:156` / `allocate-address.sh`; closes 2 tests.
- F3 — guard/skip the symlink assertion at `test_boundary_score.py:242` when
  symlinks are unprivileged on Windows; closes 1 test.

## Dead ends

- None this cycle.
