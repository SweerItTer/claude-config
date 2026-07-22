from __future__ import annotations

from contextlib import contextmanager
import errno
import fcntl
import hashlib
import math
import os
from pathlib import Path
import threading
import time
import stat
from typing import Iterator


class LockError(RuntimeError):
    def __init__(self, code: str, message: str, **facts: object) -> None:
        super().__init__(message)
        self.code = code
        self.facts = facts


_LOCAL_GUARD = threading.Lock()
_LOCAL_LOCKS: dict[str, threading.RLock] = {}


def _safe_name(raw: str) -> str:
    digest = hashlib.sha256(raw.encode("utf-8", errors="surrogatepass")).hexdigest()[:24]
    readable = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in raw)[:32]
    return f"{readable}-{digest}" if readable else digest


def _local_lock(key: str) -> threading.RLock:
    with _LOCAL_GUARD:
        lock = _LOCAL_LOCKS.get(key)
        if lock is None:
            lock = threading.RLock()
            _LOCAL_LOCKS[key] = lock
        return lock


def _ensure_private_dir(path: Path) -> None:
    """Create/validate one tmux-tool-owned private directory.

    Runtime paths may live below a shared parent such as /tmp, so never follow
    a pre-existing symlink and never chmod a directory owned by another user.
    """

    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise LockError("RUNTIME_DIR_UNSAFE", "runtime path is not a real directory", path=str(path))
    if st.st_uid != os.getuid():
        raise LockError(
            "RUNTIME_DIR_OWNERSHIP",
            "runtime directory is not owned by current user",
            path=str(path),
            owner=st.st_uid,
            uid=os.getuid(),
        )
    os.chmod(path, 0o700)


def runtime_root(server_id: str) -> Path:
    """Return a private runtime namespace owned by tmux-tool only.

    Never chmod XDG_RUNTIME_DIR itself: it belongs to the login/session manager.
    """

    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        parent = Path(xdg)
        base = parent / "tmux-tool"
    else:
        parent = Path("/tmp")
        base = parent / f"tmux-tool-{os.getuid()}"
    _ensure_private_dir(base)
    server = base / _safe_name(server_id)
    _ensure_private_dir(server)
    _ensure_private_dir(server / "locks")
    return server


def _acquire_flock(fd: int, *, deadline: float) -> bool:
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                raise
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.05, remaining))


@contextmanager
def resource_lock(
    server_id: str,
    namespace: str,
    resource_id: str,
    *,
    timeout: float,
) -> Iterator[None]:
    """Serialize mutations across threads/processes with bounded acquisition."""

    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("lock timeout must be a finite positive number")
    key = f"{server_id}:{namespace}:{resource_id}"
    deadline = time.monotonic() + timeout
    local = _local_lock(key)

    if not local.acquire(timeout=max(0.0, deadline - time.monotonic())):
        raise LockError(
            "LOCK_TIMEOUT",
            "timed out acquiring in-process resource lock",
            namespace=namespace,
            resource=resource_id,
            server=server_id,
            timeout=timeout,
        )
    try:
        root = runtime_root(server_id) / "locks"
        path = root / f"{_safe_name(f'{namespace}:{resource_id}')}.lock"
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(path, flags, 0o600)
        except OSError as exc:
            raise LockError("LOCK_FILE_UNSAFE", "cannot open private lock file", path=str(path)) from exc
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                raise LockError("LOCK_FILE_UNSAFE", "lock path is not a private regular file", path=str(path))
            try:
                os.fchmod(fd, 0o600)
            except OSError:
                pass
            if not _acquire_flock(fd, deadline=deadline):
                code = "PANE_LOCKED" if namespace == "pane" else "LOCK_TIMEOUT"
                raise LockError(
                    code,
                    "timed out acquiring resource lock",
                    namespace=namespace,
                    resource=resource_id,
                    server=server_id,
                    timeout=timeout,
                )
            try:
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
    finally:
        local.release()


@contextmanager
def pane_lock(server_id: str, pane_id: str, *, timeout: float) -> Iterator[None]:
    with resource_lock(server_id, "pane", pane_id, timeout=timeout):
        yield


@contextmanager
def topology_lock(server_id: str, *, timeout: float) -> Iterator[None]:
    # Coarse within one tmux server; independent servers do not block each other.
    with resource_lock(server_id, "topology", "global", timeout=timeout):
        yield
