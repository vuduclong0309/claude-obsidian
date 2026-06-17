# Argent Cycle 003 — Self-Audit

- **Date:** 2026-06-17
- **Slice:** test-suite cross-platform portability — `tests/test_boundary_score.py` (the last red test; same portability family as cycles 001/002)
- **Test command:** `bash bin/run-tests.sh` (no `make` on this box)
- **Baseline suite state (before):** 8 passed / 1 failed — `test_boundary_score.py` the sole failure.

## Rubric

`slice_score = max(0, 100 − (8·#BLOCKER + 4·#HIGH + 2·#MEDIUM + 0.5·#LOW) − clarity_penalty)`

Lenses: 10-principle loop (`/think`) + best-practices six-cut. Every finding cites `file:line`.

## Findings (before)

| Tier | Site | Defect |
|------|------|--------|
| HIGH | `tests/test_boundary_score.py:242` | `link.symlink_to(real)` runs unguarded during test **setup**. On Windows without admin/Developer-Mode privilege it raises `OSError: [WinError 1314]`, which propagates out of `test_included_rejects_symlink()` and aborts the **entire** test file — every other assertion in the file (parser, recency, wikilink fences, graph, CLI) is lost and the suite reports red. A single OS-privilege limitation takes down 13 unrelated assertions. |
| LOW | `tests/test_boundary_score.py:6` | Module docstring claims "No external prerequisites"; with a conditional OS-capability skip introduced, a one-line note would be more accurate. Deferred (docstring remains literally true — no *external* prereq, only an OS privilege). |

**slice_score before** = 100 − 4·1 (HIGH) − 0.5·1 (LOW) = **95.5**

Root cause (six-cut / failure-mode lens): the test conflated *exercising* behavior (does `included()` reject a symlink?) with *constructing the fixture* (can this OS make a symlink?). The fixture-construction step has an OS precondition that the assertion does not. The `included()` function under test (`scripts/boundary-score.py:104` `if path.is_symlink(): return False`) is itself correct and unchanged.

## Decision

Close the HIGH. Smallest change: probe symlink-creation capability once; run the real-file assertion unconditionally, and run the symlink-rejection assertion only when the OS could create the symlink — printing a visible `SKIP` line otherwise. This mirrors the "marked and skipped cleanly" idiom already documented in `tests/test_tiling_check.py:6` for ollama-dependent tests. No production code touched.

Hypothesis: 95.5 → 99.0 because closing F3 drops failing-test count 1→0 (full suite green) with no regression; residual is the one cosmetic LOW.

## Action

`tests/test_boundary_score.py` — `test_included_rejects_symlink()`:
- Wrap `link.symlink_to(real)` in `try/except (OSError, NotImplementedError)` → `symlinks_ok` flag.
- Real-file inclusion asserted unconditionally.
- Symlink-rejection asserted only when `symlinks_ok`; else print `SKIP symlink excluded (...)`.

## Findings (after)

| Tier | Site | Defect |
|------|------|--------|
| LOW | `tests/test_boundary_score.py:6` | Same cosmetic docstring note (carried as open thread). |
| LOW | (coverage) | Symlink-rejection branch of `included()` is unverified on unprivileged Windows hosts. Intrinsic to the OS; the assertion still runs everywhere symlinks are creatable (CI Linux/macOS, privileged Windows). |

**slice_score after** = 100 − 0.5·2 = **99.0**  (Δ = +3.5)

## Verify

- `python3 tests/test_boundary_score.py` → `All tests passed.` (exit 0), SKIP line emitted on this unprivileged Windows host.
- `bash bin/run-tests.sh` → **9 passed, 0 failed** (was 8/1). Full suite green for the first time since baseline (Cycle 000).
- Regression gate: no previously-passing test went red; no hook/script broke. Failing-test count 1→0 (cannot rise). **Precondition holds.**

**Result:** WIN — top finding closed, score 95.5 → 99.0, suite fully green.
