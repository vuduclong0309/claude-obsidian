#!/usr/bin/env python3
"""test_portable_lock.py — hermetic contract tests for scripts/portable_lock.py.

portable_lock is the cross-platform advisory-lock shim that ``tiling-check.py``,
``bm25-index.py`` and ``rerank.py`` import transparently as ``fcntl``. On this
Windows box it loads the msvcrt-emulation branch; on POSIX it re-exports the real
``fcntl``. Until now the shim had no direct test — only indirect exercise through
three consumer tests, none of which assert its documented contract. This file
pins that contract so a regression in either branch fails by name.

The tests use two independent open file descriptions to the same file. Both
POSIX ``flock`` (locks attach to the open file description) and the Windows
byte-range emulation conflict between them even inside one process, so every
assertion is meaningful and identical on both platforms — no subprocess, no
network, pure stdlib.

Usage:
  python3 tests/test_portable_lock.py
"""
import importlib.util
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "scripts" / "portable_lock.py"

spec = importlib.util.spec_from_file_location("portable_lock", HELPER)
pl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pl)


class Fail(SystemExit):
    pass


def assert_true(label, cond):
    if not cond:
        raise Fail(f"FAIL {label}")
    print(f"OK   {label}")


def assert_raises(label, exc_type, fn):
    try:
        fn()
    except exc_type:
        print(f"OK   {label}")
        return
    except Exception as other:  # surface the wrong type; let BaseException (Ctrl-C) propagate
        raise Fail(f"FAIL {label}: expected {exc_type.__name__}, "
                   f"got {type(other).__name__}: {other}")
    raise Fail(f"FAIL {label}: expected {exc_type.__name__}, no exception raised")


def test_exposes_fcntl_subset():
    for name in ("LOCK_EX", "LOCK_NB", "LOCK_UN"):
        assert_true(f"exposes {name}", isinstance(getattr(pl, name, None), int))
    assert_true("exposes callable flock", callable(getattr(pl, "flock", None)))
    # The three bit-flags must be distinct so callers' ``LOCK_EX | LOCK_NB``
    # bit-ORing addresses independent operations.
    assert_true("LOCK_EX/NB/UN are distinct bits",
                len({pl.LOCK_EX, pl.LOCK_NB, pl.LOCK_UN}) == 3)


def _open_locktarget(path):
    fd = os.open(str(path), os.O_RDWR | os.O_CREAT)
    # Give the file a known, non-empty body so seek-preservation has a real
    # offset to clobber if the shim mishandled it.
    os.write(fd, b"lockbyte\n")
    return fd


def test_nonblocking_acquire_and_contention():
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "lock.target"
        fd1 = _open_locktarget(path)
        fd2 = None
        try:
            fd2 = os.open(str(path), os.O_RDWR)
            # First non-blocking acquire on a free lock succeeds silently.
            pl.flock(fd1, pl.LOCK_EX | pl.LOCK_NB)
            print("OK   free LOCK_NB acquire succeeds")

            # A second open file description contending for the same byte must
            # be rejected as BlockingIOError — the documented normalization of
            # Windows' bare PermissionError (portable_lock.py:62) and of POSIX
            # EWOULDBLOCK alike.
            assert_raises("held LOCK_NB raises BlockingIOError", BlockingIOError,
                          lambda: pl.flock(fd2, pl.LOCK_EX | pl.LOCK_NB))

            # Releasing the holder (LOCK_UN, portable_lock.py:54) lets the
            # contender acquire.
            pl.flock(fd1, pl.LOCK_UN)
            pl.flock(fd2, pl.LOCK_EX | pl.LOCK_NB)
            print("OK   LOCK_UN releases so contender can acquire")
            pl.flock(fd2, pl.LOCK_UN)
        finally:
            os.close(fd1)
            if fd2 is not None:
                os.close(fd2)


def test_seek_offset_preserved():
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "lock.target"
        fd = _open_locktarget(path)
        try:
            os.lseek(fd, 3, os.SEEK_SET)
            before = os.lseek(fd, 0, os.SEEK_CUR)
            pl.flock(fd, pl.LOCK_EX | pl.LOCK_NB)
            after_lock = os.lseek(fd, 0, os.SEEK_CUR)
            assert_true("flock preserves caller seek offset", after_lock == before)
            pl.flock(fd, pl.LOCK_UN)
            after_unlock = os.lseek(fd, 0, os.SEEK_CUR)
            assert_true("unlock preserves caller seek offset", after_unlock == before)
        finally:
            os.close(fd)


def test_blocking_acquire_on_free_lock_returns():
    # A blocking acquire (no LOCK_NB) on a free lock must return immediately —
    # this drives the emulation's poll-loop (portable_lock.py:67-72) on its
    # first, successful iteration with zero risk of a real hang.
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "lock.target"
        fd = _open_locktarget(path)
        try:
            pl.flock(fd, pl.LOCK_EX)
            print("OK   blocking LOCK_EX on free lock returns")
            pl.flock(fd, pl.LOCK_UN)
        finally:
            os.close(fd)


def main():
    print("=== test_portable_lock.py ===")
    test_exposes_fcntl_subset()
    test_nonblocking_acquire_and_contention()
    test_seek_offset_preserved()
    test_blocking_acquire_on_free_lock_returns()
    print("\nAll portable-lock tests passed.")


if __name__ == "__main__":
    main()
