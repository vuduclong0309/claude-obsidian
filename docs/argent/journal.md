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

## Cycle 004 — 2026-06-17 — slice: concurrency primitives (portable_lock.py shim test coverage)
- Audit: docs/audits/argent-cycle-004.md (score before: 95.5)
- Finding: MEDIUM scripts/portable_lock.py (no tests/test_portable_lock.py) — M2 standing since c001 verifier: the cross-platform lock shim has ZERO direct test coverage; on this Windows box the msvcrt-emulation branch (lines 35-74) is the LIVE lock path for tiling-check/bm25-index/rerank but is exercised only indirectly by 3 consumer tests, none asserting its contract (BlockingIOError normalization :62, LOCK_UN release :54, seek save/restore :50/:74, blocking poll-loop :67-72).
- Hypothesis: 95.5→97.5 because closing M2 removes one MEDIUM and lifts passing count 9→10, zero production code touched (no regression risk)
- Action: new tests/test_portable_lock.py — hermetic, pure-stdlib, cross-platform (two independent open file descriptions conflict identically under POSIX flock and Windows msvcrt emulation, single-process, no subprocess/network); 4 funcs / 11 assertions covering the full shim contract incl. the live Windows BlockingIOError normalization. Registered in BOTH bin/run-tests.sh (TESTS array) and Makefile (test-portable-lock target + aggregate + .PHONY + help) together to avoid runner drift. M1 (:67 no timeout) deliberately NOT closed — adding a timeout would break POSIX flock(LOCK_EX) parity; left as accepted-parity open thread. | files: tests/test_portable_lock.py(new), bin/run-tests.sh, Makefile, docs/audits/argent-cycle-004.md
- Verify: score after 97.5 (Δ+2.0) | tests: 10 passed/0 failed (was 9/0) — direct test green incl. "held LOCK_NB raises BlockingIOError" on live Windows path; no previously-green test red, no hook/script broke | verifier: 0 BLOCKER / 0 HIGH / 0 MEDIUM → SHIP (confirmed two-OFD contention assumption holds on both POSIX flock + Windows msvcrt, no hang/leak; 2 LOW polish — fd2 open moved inside try, assert_raises narrowed BaseException→Exception — both fixed pre-commit, suite still 10/10)
- Result: KEPT @ <commit>
- Open threads: M1 portable_lock.py:67 unbounded blocking acquire (accepted POSIX-parity decision — do NOT close by adding a divergent timeout); L portable_lock.py:65 cosmetic comment; L(002-1) no hermetic test_portable_flock.sh; L(002-2) sha1_of spawns sha1sum/op; L(002-3) document _PORTABLE_LOCK_STALE_SEC in consumers; M(002-1) reconcile dragonscale-guide.md:53-65 flock-as-hard-prereq vs fallback; L(003-1) test_boundary_score.py:6 docstring; L(003-2) symlink-rejection branch unverified on unprivileged Windows.
- Dead ends: closing M1 by adding a blocking-acquire timeout — would diverge from POSIX flock(LOCK_EX) which blocks indefinitely; the shim must match. Do not "fix" M1 with a timeout.

## Cycle 003 — 2026-06-17 — slice: test-suite cross-platform portability (boundary-score symlink test)
- Audit: docs/audits/argent-cycle-003.md (score before: 95.5)
- Finding: HIGH tests/test_boundary_score.py:242 — `link.symlink_to(real)` runs unguarded in test setup; on unprivileged Windows it raises OSError WinError 1314, propagating out of test_included_rejects_symlink() and aborting the ENTIRE file (13 unrelated assertions lost, suite reports red). The function under test (boundary-score.py:104 `if path.is_symlink(): return False`) was already correct.
- Hypothesis: 95.5→99 because closing F3 drops failing count 1→0 (full suite green), no regression
- Action: probe symlink-creation capability once (try/except (OSError, NotImplementedError) → symlinks_ok); real-file inclusion asserted unconditionally; symlink-rejection asserted only when symlinks_ok, else print a visible SKIP line. Mirrors the "marked and skipped cleanly" idiom in test_tiling_check.py:6. No production code touched. | files: tests/test_boundary_score.py, docs/audits/argent-cycle-003.md
- Verify: score after 99.0 (Δ+3.5) | tests: 9 passed/0 failed (was 8/1) — full suite green for the first time since baseline (Cycle 000); no previously-green test red | verifier: 0 BLOCKER / 0 HIGH → SHIP (1 MEDIUM doc-typo fixed pre-commit; try/except scope confirmed bounded, no masking of real bugs in included())
- Result: KEPT @ 43f24dc
- Open threads: F3 CLOSED. Now-green-suite residuals from prior cycles: M(002-1) reconcile dragonscale-guide.md:53-65 flock-as-hard-prereq vs fallback; L(002-2) sha1_of still spawns sha1sum/op; L(002-1) no hermetic test_portable_flock.sh; L(002-3) document _PORTABLE_LOCK_STALE_SEC in consumers; (c001) M1 portable_lock.py:67 no LOCK_EX timeout; M2 no test_portable_lock.py; L(003-1) test_boundary_score.py:6 docstring "No external prerequisites" now has a conditional OS-capability skip; L(003-2) symlink-rejection branch unverified on unprivileged Windows (intrinsic OS limit).
- Dead ends: none

## Cycle 002 — 2026-06-17 — slice: cross-platform script portability (bash concurrency-lock layer)
- Audit: docs/audits/argent-cycle-002.md (score before: 88)
- Finding: HIGH scripts/{wiki-lock.sh:156,allocate-address.sh:36} — `flock -x -w 5 9` is POSIX-only; `flock: command not found` on MSYS breaks 3 tests (test_wiki_lock, test_concurrent_write, test_allocate_address). Closing it exposed two latent perf cliffs (validate_path python3 ~0.5s + sha1_of ~0.42s sha1sum held INSIDE the meta-lock) that timed out concurrent_write on Windows process-spawn costs.
- Hypothesis: 88→~97 because closing F2 (all 3 flock-family tests) drops failing count 4→1, no regression
- Action: new scripts/portable-flock.sh (flock(1) where present, else noclobber-FILE spin-lock w/ EXIT-trap release + 30s stale-reap; builtins-only contended path). wiki-lock.sh: meta-lock swap + moved pure validate_path/sha1_of OUT of the meta-lock (dispatcher precomputes lockfile path, passes as $2) so the critical section is sub-ms; validate_path fast-path skips python3 when no symlink ancestor (rigorous check unchanged); now_epoch→printf builtin, read_lockfile/parse→builtin read, sha1_of awk→${out%% *}, dirname→param-expansion, ensure_dirs [-d] guard. allocate-address.sh: helper swap. test_allocate_address.sh: copy portable-flock.sh into sandbox. test_wiki_lock.sh:146: CR-path assertion captured $? directly (MSYS strips CR in $() — verified by od) instead of via $(); validate_path itself was correct. | files: scripts/portable-flock.sh(new), scripts/wiki-lock.sh, scripts/allocate-address.sh, tests/test_allocate_address.sh, tests/test_wiki_lock.sh, docs/audits/argent-cycle-002.md
- Verify: score after 96.5 (Δ+8.5) | tests: 8 passed/1 failed (was 5/4); concurrent_write hang→reliable ~51-58s over 7 runs (~2× margin under 120s budget); no previously-green test red | verifier: 0 BLOCKER / 0 HIGH → SHIP (1 MEDIUM + 4 LOW, all already in open threads; symlink fast-path + lock release/mutual-exclusion confirmed sound)
- Result: KEPT @ 993c491
- Open threads: F3 (test_boundary_score symlink-privilege, last red); M(002-1) reconcile dragonscale-guide.md:53-65 flock-as-hard-prereq vs new fallback; L(002-2) sha1_of still spawns sha1sum/op (dominant residual cost, pure-bash hash would remove it — changes lockfile naming); L(002-1) no hermetic test_portable_flock.sh; L(002-3) document _PORTABLE_LOCK_STALE_SEC in consumers; (c001) M1 portable_lock.py:67 no LOCK_EX timeout; M2 no test_portable_lock.py
- Dead ends: mkdir-based portable lock (`mkdir <path>.lockd`) — livelocks concurrent_write on Windows deferred-directory-delete under ~500 create/delete cycles. Use noclobber-FILE, not mkdir-dir, for churning Windows locks. Do not retry mkdir-lock.

## Cycle 001 — 2026-06-16 — slice: cross-platform script portability
- Audit: docs/audits/argent-cycle-001.md (score before: 72)
- Finding: HIGH scripts/{tiling-check.py:30,bm25-index.py:49,rerank.py:45} — `import fcntl` is POSIX-only, ModuleNotFoundError on Windows breaks 3 tests
- Hypothesis: 72→84 because closing F1 turns test_tiling_check + test_bm25_index + test_retrieve green (7 HIGH → 4 HIGH), no regression
- Action: new scripts/portable_lock.py (fcntl shim: POSIX re-export / Windows msvcrt emulation, NB→BlockingIOError); each `import fcntl` → sys.path bootstrap + `import portable_lock as fcntl` (no call-site changed); test_retrieve sandbox-copy lists (4 sites) gained portable_lock.py | files: scripts/portable_lock.py, scripts/{tiling-check,bm25-index,rerank}.py, tests/test_retrieve.py
- Verify: score after 84 (Δ+12) | tests: 5 passed/4 failed (was 2/7), no previously-green test red | verifier: 0 BLOCKER / 0 HIGH → SHIP (2 MEDIUM + 1 LOW deferred)
- Result: KEPT @ 1d8c642
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
