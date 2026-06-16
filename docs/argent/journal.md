# Argent Alive — Journal

This is Argent's only cross-cycle memory. **Newest cycle on top.** Each entry
records the slice audited, the score, the finding closed (or reverted), open
threads, and dead ends. To reconstruct the slice rotation ledger, read the last
~10 entries.

**Status:** baseline seeded (Cycle 000). First live invocation = **Cycle 001**.
Treat every slice as never-audited; the baseline below already maps a target-rich
frontier, so Cycle 001 should start there unless a quick scan finds something
higher-leverage. Test command on this box: `bash bin/run-tests.sh` (no `make`).

---
<!-- newest cycle entries are prepended directly below this line -->

## Cycle 001 — 2026-06-16 — slice: cross-platform script portability
- Audit: docs/audits/argent-cycle-001.md (score before: 72)
- Finding: HIGH scripts/{tiling-check.py:30,bm25-index.py:49,rerank.py:45} — `import fcntl` is POSIX-only, ModuleNotFoundError on Windows breaks 3 tests
- Hypothesis: 72→84 because closing F1 turns test_tiling_check + test_bm25_index + test_retrieve green (7 HIGH → 4 HIGH), no regression
- Action: new scripts/portable_lock.py (fcntl shim: POSIX re-export / Windows msvcrt emulation, NB→BlockingIOError); each `import fcntl` → sys.path bootstrap + `import portable_lock as fcntl` (no call-site changed); test_retrieve sandbox-copy lists (4 sites) gained portable_lock.py | files: scripts/portable_lock.py, scripts/{tiling-check,bm25-index,rerank}.py, tests/test_retrieve.py
- Verify: score after 84 (Δ+12) | tests: 5 passed/4 failed (was 2/7), no previously-green test red | verifier: 0 BLOCKER / 0 HIGH → SHIP (2 MEDIUM + 1 LOW deferred)
- Result: KEPT @ <sha after commit>
- Open threads: F2 — portable bash lock for wiki-lock.sh:156 / allocate-address.sh (closes test_wiki_lock + test_concurrent_write, 2 tests); F3 — guard symlink assertion at test_boundary_score.py:242 when symlinks unprivileged on Windows (1 test); M1 (verifier) — portable_lock.py:67 blocking LOCK_EX spin-loop has no timeout (parity w/ POSIX flock, but add _BLOCK_TIMEOUT_SEC); M2 (verifier) — no hermetic tests/test_portable_lock.py for the Windows emulation branch
- Dead ends: none

## Cycle 000 — 2026-06-16 — slice: baseline (seeded by operator setup, not a normal cycle)
- Test harness: `bash bin/run-tests.sh` → **2 passed, 7 failed** (make is absent on
  this Windows box; `python3` was the broken Microsoft Store shim — bridged via
  `bin/pyshim/python3` + `PYTHONUTF8=1`).
- GREEN: test_wiki_mode.py, test_contextual_prefix.py.
- Standing findings (each a HIGH; closing any drives the failing-test count down):
  - **F1 — fcntl is Unix-only** `scripts/tiling-check.py:30`, `scripts/bm25-index.py:49`,
    `scripts/rerank.py:45`. `import fcntl` aborts on Windows → breaks
    test_tiling_check, test_bm25_index, test_retrieve (3 tests). Fix direction:
    cross-platform advisory lock (try/except import; msvcrt or mkdir-lock fallback).
  - **F2 — flock not in MSYS/git-bash** `scripts/wiki-lock.sh:156`,
    `scripts/allocate-address.sh:36`. `flock` command missing → breaks
    test_wiki_lock + cascades to test_concurrent_write (2 tests). Fix direction:
    portable lock (mkdir-based or `flock` feature-detect with fallback).
  - **F3 — os.symlink needs privilege on Windows** `tests/test_boundary_score.py:242`
    (`link.symlink_to(real)` → WinError 1314) → breaks test_boundary_score (1 test).
    Fix direction: skip/guard the symlink assertion when symlinks are unavailable.
- Open threads: after the suite is green, resume normal rotating-slice audits.
- Dead ends: none yet.
