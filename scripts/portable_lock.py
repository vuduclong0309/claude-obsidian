"""portable_lock — cross-platform advisory file-lock shim.

The vault's lock-using scripts (``tiling-check.py``, ``bm25-index.py``,
``rerank.py``) were written against POSIX ``fcntl.flock``, which does not exist
on Windows (``import fcntl`` → ``ModuleNotFoundError``). This module exposes the
exact subset those scripts use — ``LOCK_EX``, ``LOCK_NB``, ``LOCK_UN`` and
``flock(fd, op)`` — delegating to real ``fcntl`` on POSIX and emulating it via
``msvcrt`` on Windows.

Consumers import it transparently as a drop-in:

    import portable_lock as fcntl
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

so no call-site changes are required.

Windows emulation locks a single byte at offset 0 of the (empty) lock file via
``msvcrt.locking``. To preserve ``fcntl`` semantics, a non-blocking acquisition
that would block is re-raised as ``BlockingIOError`` (Windows raises a bare
``PermissionError``), which is what callers' ``except BlockingIOError`` clauses
expect. The file position is saved and restored so the lock never depends on or
disturbs the caller's seek offset.
"""

try:  # POSIX — re-export the genuine article.
    import fcntl as _fcntl

    LOCK_EX = _fcntl.LOCK_EX
    LOCK_NB = _fcntl.LOCK_NB
    LOCK_UN = _fcntl.LOCK_UN

    def flock(fd, op):
        return _fcntl.flock(fd, op)

except ModuleNotFoundError:  # Windows — emulate via msvcrt byte-range locking.
    import msvcrt
    import os
    import time

    # Values mirror the POSIX fcntl constants so callers' ``LOCK_EX | LOCK_NB``
    # bit-ORing keeps working; only this module interprets them.
    LOCK_EX = 0x1
    LOCK_NB = 0x2
    LOCK_UN = 0x8

    _NBYTES = 1
    _BLOCK_POLL_SEC = 0.1

    def flock(fd, op):
        pos = os.lseek(fd, 0, os.SEEK_CUR)
        os.lseek(fd, 0, os.SEEK_SET)
        try:
            if op & LOCK_UN:
                msvcrt.locking(fd, msvcrt.LK_UNLCK, _NBYTES)
                return
            if op & LOCK_NB:
                try:
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, _NBYTES)
                except OSError as exc:
                    # POSIX flock(LOCK_NB) raises BlockingIOError when the lock
                    # is held; Windows raises a bare PermissionError. Normalize.
                    raise BlockingIOError(getattr(exc, "errno", None),
                                          "lock is held by another process")
            else:
                # Emulate a blocking acquire: msvcrt.LK_LOCK gives up after ~10s,
                # so poll LK_NBLCK until it succeeds.
                while True:
                    try:
                        msvcrt.locking(fd, msvcrt.LK_NBLCK, _NBYTES)
                        return
                    except OSError:
                        time.sleep(_BLOCK_POLL_SEC)
        finally:
            os.lseek(fd, pos, os.SEEK_SET)
