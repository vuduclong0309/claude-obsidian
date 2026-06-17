# Argent Cycle 004 — Self-Audit

- **Date:** 2026-06-17
- **Slice:** concurrency primitives — `scripts/portable_lock.py` (the cross-platform advisory-lock shim introduced in Cycle 001). With the full suite green since Cycle 003, the rotation moves off the "make-the-suite-green" portability family to the **test-coverage** dimension of the same machinery: the shim that is the *live* lock path on this Windows box.
- **Test command:** `bash bin/run-tests.sh` (no `make` on this box)
- **Baseline suite state (before):** 9 passed / 0 failed.

## Rubric

`slice_score = max(0, 100 − (8·#BLOCKER + 4·#HIGH + 2·#MEDIUM + 0.5·#LOW) − clarity_penalty)`

Lenses: 10-principle loop (`/think`) + best-practices six-cut. Every finding cites `file:line`.

## Findings (before)

| Tier | Site | Defect |
|------|------|--------|
| MEDIUM | `scripts/portable_lock.py` (whole file, no `tests/test_portable_lock.py`) | **M2** (standing since the Cycle 001 verifier pass). The shim has **zero direct test coverage**. On this Windows box `import fcntl` fails and the msvcrt-emulation branch (lines 35–74) is the *active* lock path for `tiling-check.py`, `bm25-index.py`, `rerank.py`, yet it is exercised only *indirectly* by three consumer tests — none of which assert the shim's documented contract: `BlockingIOError` normalization of Windows' bare `PermissionError` (`:62`), `LOCK_UN` release (`:54`), seek-offset save/restore (`:50`/`:74`), or the blocking poll-loop (`:67-72`). A regression in any of these would pass unnamed or surface only as a confusing downstream failure. |
| MEDIUM | `scripts/portable_lock.py:67` | **M1** (standing since Cycle 001 verifier). The blocking-acquire `while True:` poll-loop has no timeout or diagnostic. This is *intentional parity* with POSIX `fcntl.flock(LOCK_EX)`, which also blocks indefinitely — so closing it by adding a divergent timeout would **break the contract**, not improve it. Left open as a documented parity decision, not closed this cycle. |
| LOW | `scripts/portable_lock.py:65` | Comment notes `msvcrt.LK_LOCK` "gives up after ~10s"; the code instead polls `LK_NBLCK`, which pairs with the no-cap concern in M1. Cosmetic. |

**slice_score before** = 100 − 2·2 (MEDIUM) − 0.5·1 (LOW) = **95.5**

Root cause (six-cut / test-coverage lens): the Cycle 001 fix prioritized turning three red consumer tests green, which it did — but the shim itself, the single point all three depend on, was never pinned by a test of its own. The live (Windows) branch is the one with the most custom logic (`BlockingIOError` normalization, seek save/restore) and the least direct verification.

## Decision

Close **M2**. Smallest change: add a hermetic `tests/test_portable_lock.py` that pins the shim's contract. The test uses **two independent open file descriptions** to the same temp file — these conflict between each other under both POSIX `flock` (locks attach to the open file description) and the Windows byte-range emulation, even inside one process — so every assertion is meaningful and identical on both platforms with no subprocess and no network. It asserts: the exposed `LOCK_*`/`flock` subset and distinct bit-flags; free non-blocking acquire succeeds; a held lock makes a contender raise `BlockingIOError` (not bare `OSError`/`PermissionError`); `LOCK_UN` releases so the contender can then acquire; the caller's seek offset is preserved across lock and unlock; and a blocking acquire on a free lock returns immediately (driving the `:67-72` poll-loop on its first successful iteration with zero hang risk).

M1 is **not** closed — adding a timeout would diverge from POSIX `flock` semantics. It remains an open thread as an accepted parity decision.

Hypothesis: 95.5 → 97.5 because closing M2 removes one MEDIUM and lifts the passing-test count 9 → 10, with **no production code touched** (test + two registration edits only) → no regression risk.

## Action

- `tests/test_portable_lock.py` (new) — four test functions, 11 assertions, pure stdlib, cross-platform.
- `bin/run-tests.sh` — register `python3 tests/test_portable_lock.py` in the `TESTS` array.
- `Makefile` — add `test-portable-lock` target, wire it into the `test` aggregate, `.PHONY`, and `help`. Registered in **both** runners together so the make-ful and make-less paths do not drift.

## Findings (after)

| Tier | Site | Defect |
|------|------|--------|
| MEDIUM | `scripts/portable_lock.py:67` | M1 — unbounded blocking acquire, carried as an accepted-parity open thread (closing it would break POSIX parity). |
| LOW | `scripts/portable_lock.py:65` | Cosmetic comment note (carried). |

**slice_score after** = 100 − 2·1 (MEDIUM) − 0.5·1 (LOW) = **97.5**  (Δ = +2.0)

## Verify

- `python3 tests/test_portable_lock.py` → `All portable-lock tests passed.` (exit 0), 11/11 OK, including `held LOCK_NB raises BlockingIOError` — confirming the msvcrt normalization (`:62`) on the live Windows path.
- `bash bin/run-tests.sh` → **10 passed, 0 failed** (was 9/0), exit 0.
- Regression gate: no previously-passing test went red; no hook/script broke. Passing-test count 9 → 10 (failing count held at 0). **Precondition holds.**

- Verifier (`agents/verifier.md`) on staged diff: **0 BLOCKER / 0 HIGH / 0 MEDIUM → SHIP**. Confirmed the two-open-file-description contention assumption is correct on both POSIX `flock` (OFD-attached) and Windows `msvcrt` (handle byte-range), no hang/fd/temp-dir leak, registrations consistent. Two LOW polish items applied pre-commit: fd2 `os.open` moved inside the `try` (close-on-failure safety), `assert_raises` narrowed `except BaseException` → `except Exception` so Ctrl-C propagates. Re-ran suite after polish → still 10/10.

**Result:** WIN — top finding (M2) closed, score 95.5 → 97.5, suite 10/10 green, shim contract now pinned on its live branch.
