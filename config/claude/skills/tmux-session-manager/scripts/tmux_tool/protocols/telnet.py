from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import math
import re
import stat
import shlex
import time
import uuid

from ..inventory import build_inventory, lookup_pane, option_name
from ..locking import pane_lock
from ..model import POSIX_SHELL_COMMANDS, Pane, PaneState
from ..resolver import ResolveError, resolve_target
from ..tmux import TmuxClient
from ..shellwrap import isolated_job_command
from ..validation import contains_control


DEFAULT_LOGIN_RE = r"(?im)(?:^|\n)[^\n]{0,80}login:\s*$"
DEFAULT_PASSWORD_RE = r"(?im)(?:^|\n)[^\n]{0,80}password:\s*$"
DEFAULT_PROMPT_RE = r"(?m)(?:^|\n)[^\n]{0,120}[#$]\s*$"
DEFAULT_FAILURE_RE = r"(?im)(connection refused|no route to host|unable to connect|connection timed out|connection reset|unknown host|telnet:[^\n]*not found)"



def _read_password_file(path_text: str) -> str:
    """Open, validate, and read a password file through one file descriptor."""
    path = Path(path_text)
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    before = None
    if not nofollow:
        try:
            before = os.lstat(path)
        except OSError as exc:
            raise TelnetError("PASSWORD_FILE", "cannot stat password file", path=str(path)) from exc
        if stat.S_ISLNK(before.st_mode):
            raise TelnetError("PASSWORD_FILE", "password file must not be a symlink", path=str(path))
    try:
        fd = os.open(path, flags | nofollow)
    except OSError as exc:
        raise TelnetError("PASSWORD_FILE", "cannot securely open password file", path=str(path)) from exc
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise TelnetError("PASSWORD_FILE", "password file must be a regular file", path=str(path))
        if before is not None and (before.st_dev, before.st_ino) != (st.st_dev, st.st_ino):
            raise TelnetError("PASSWORD_FILE_CHANGED", "password file changed during secure open", path=str(path))
        if st.st_mode & 0o044:
            raise TelnetError(
                "PASSWORD_FILE_PERMISSIONS",
                "password file must not be group/world readable",
                path=str(path),
            )
        with os.fdopen(fd, "r", encoding="utf-8", closefd=False) as fp:
            raw = fp.read()
    except UnicodeDecodeError as exc:
        raise TelnetError("PASSWORD_FILE", "password file must be UTF-8 text", path=str(path)) from exc
    finally:
        os.close(fd)
    if raw.endswith("\r\n"):
        raw = raw[:-2]
    elif raw.endswith("\n") or raw.endswith("\r"):
        raw = raw[:-1]
    return raw


class TelnetError(RuntimeError):
    def __init__(self, code: str, message: str, *, blocked: bool = False, **facts: object) -> None:
        super().__init__(message)
        self.code = code
        self.blocked = blocked
        self.facts = facts


@dataclass(slots=True, frozen=True)
class TelnetResult:
    pane: str
    state: str
    peer: str
    reused: bool
    proof_lines: int = 0
    current_command: str | None = None
    protocol_state: str | None = None
    remote_hint: bool = False
    busy_hint: bool = False
    managed: bool = False


class TelnetHelper:
    def __init__(self, tmux: TmuxClient, *, lock_timeout: float = 5.0) -> None:
        self.tmux = tmux
        self.lock_timeout = lock_timeout

    def _pane(self, selector: str) -> Pane:
        if selector.startswith("%"):
            pane = lookup_pane(self.tmux, selector)
            if pane is None:
                raise TelnetError("NOT_FOUND", f"pane not found: {selector}")
            return pane
        inv = build_inventory(self.tmux)
        try:
            item = resolve_target(inv, selector)
        except ResolveError as exc:
            raise TelnetError(exc.code, str(exc), matches=",".join(exc.matches)) from exc
        if item.kind != "pane" or item.pane is None:
            raise TelnetError("TYPE_MISMATCH", "telnet target must be a pane", target=item.id)
        return item.pane

    @staticmethod
    def _compile(pattern: str, *, field: str) -> re.Pattern[str]:
        try:
            return re.compile(pattern)
        except re.error as exc:
            raise TelnetError("BAD_REGEX", "invalid regular expression", field=field, detail=str(exc)) from exc

    def _result(self, pane: Pane, *, peer: str | None = None, reused: bool = False, proof_lines: int = 0) -> TelnetResult:
        return TelnetResult(
            pane=pane.id,
            state=pane.state.value,
            peer=peer or pane.metadata.peer or "-",
            reused=reused,
            proof_lines=proof_lines,
            current_command=pane.current_command or None,
            protocol_state=pane.metadata.protocol_state,
            remote_hint=pane.metadata.remote_hint,
            busy_hint=pane.metadata.busy_hint,
            managed=pane.metadata.managed,
        )

    def status(self, selector: str) -> TelnetResult:
        return self._result(self._pane(selector))

    def connect(
        self,
        selector: str,
        *,
        host: str,
        port: int = 23,
        user: str,
        password: str | None = None,
        password_file: str | None = None,
        prompt_regex: str = DEFAULT_PROMPT_RE,
        login_regex: str = DEFAULT_LOGIN_RE,
        password_regex: str = DEFAULT_PASSWORD_RE,
        timeout: float = 12.0,
        proof_command: str = "pwd",
        poll_interval: float = 0.10,
    ) -> TelnetResult:
        if password is not None and password_file is not None:
            raise TelnetError("CREDENTIAL_CONFLICT", "use either password or password-file, not both")
        if password_file is not None:
            password = _read_password_file(password_file)
        if password is not None and ("\x00" in password or "\r" in password or "\n" in password):
            raise TelnetError("BAD_PASSWORD", "password must not contain NUL/CR/LF")
        if not (1 <= port <= 65535):
            raise TelnetError("BAD_PORT", "port must be 1..65535", port=port)
        if not host or host.startswith("-") or any(ch.isspace() for ch in host) or contains_control(host):
            raise TelnetError("BAD_HOST", "host must be a non-option token without whitespace/control characters")
        if not user or contains_control(user):
            raise TelnetError("BAD_USER", "user must be non-empty and contain no control characters")
        if not math.isfinite(timeout) or timeout <= 0:
            raise TelnetError("BAD_TIMEOUT", "timeout must be a finite positive number", timeout=timeout)

        login_re = self._compile(login_regex, field="login_regex")
        password_re = self._compile(password_regex, field="password_regex")
        prompt_re = self._compile(prompt_regex, field="prompt_regex")
        failure_re = self._compile(DEFAULT_FAILURE_RE, field="failure_regex")

        initial = self._pane(selector)
        pane_id = initial.id
        peer = f"{user}@{host}" + (f":{port}" if port != 23 else "")

        # Handshake + verification is one pane ownership transaction. REMOTE is
        # not published until the proof command completes successfully.
        with pane_lock(self.tmux.server_identity, pane_id, timeout=self.lock_timeout):
            pane = self._pane(pane_id)
            if not pane.metadata.managed:
                raise TelnetError("UNMANAGED_TARGET", "refusing telnet automation on unmanaged pane", pane=pane.id)

            if pane.state is PaneState.BUSY and pane.current_command == "telnet":
                if pane.metadata.peer == peer:
                    raise TelnetError(
                        "TELNET_BUSY_UNVERIFIED",
                        "matching telnet client exists but remote shell is busy and cannot be proven",
                        blocked=True,
                        pane=pane.id,
                        peer=peer,
                    )
                raise TelnetError(
                    "PANE_OCCUPIED",
                    "pane already has another telnet connection",
                    pane=pane.id,
                    peer=pane.metadata.peer,
                )

            if pane.state is PaneState.REMOTE and pane.current_command == "telnet":
                if pane.metadata.peer != peer:
                    raise TelnetError(
                        "PANE_OCCUPIED",
                        "pane already has another telnet connection",
                        pane=pane.id,
                        peer=pane.metadata.peer,
                    )
                try:
                    proof_lines = self._proof_locked(
                        pane.id,
                        peer=peer,
                        proof_command=proof_command,
                        timeout=min(5.0, timeout),
                        poll_interval=poll_interval,
                    )
                    return self._result(self._pane(pane.id), peer=peer, reused=True, proof_lines=proof_lines)
                except TelnetError as exc:
                    rollback_ok = self._rollback_locked(
                        pane.id,
                        timeout=min(3.0, timeout),
                        poll_interval=poll_interval,
                    )
                    if not rollback_ok:
                        raise TelnetError(
                            "TELNET_ROLLBACK_FAILED",
                            "unhealthy reused telnet client could not be returned to local shell",
                            pane=pane.id,
                            peer=peer,
                            cause=exc.code,
                        ) from exc
                    # Keep the lock and reconnect from a proven LOCAL shell.
                    pane = self._pane(pane.id)

            if pane.state is not PaneState.LOCAL:
                raise TelnetError(
                    "PANE_NOT_LOCAL",
                    "telnet connect requires a proven local shell pane",
                    pane=pane.id,
                    state=pane.state.value,
                )

            self._connect_fresh_locked(
                pane.id,
                peer=peer,
                host=host,
                port=port,
                user=user,
                password=password,
                login_re=login_re,
                password_re=password_re,
                prompt_re=prompt_re,
                failure_re=failure_re,
                timeout=timeout,
                poll_interval=poll_interval,
            )
            try:
                proof_lines = self._proof_locked(
                    pane.id,
                    peer=peer,
                    proof_command=proof_command,
                    timeout=min(5.0, timeout),
                    poll_interval=poll_interval,
                )
            except TelnetError as exc:
                rollback_ok = self._rollback_locked(
                    pane.id,
                    timeout=min(3.0, timeout),
                    poll_interval=poll_interval,
                )
                raise TelnetError(
                    "TELNET_VERIFY_FAILED",
                    "remote shell proof command did not complete successfully",
                    pane=pane.id,
                    peer=peer,
                    cause=exc.code,
                    rollback=int(rollback_ok),
                ) from exc
            return self._result(self._pane(pane.id), peer=peer, reused=False, proof_lines=proof_lines)

    def _connect_fresh_locked(
        self,
        pane_id: str,
        *,
        peer: str,
        host: str,
        port: int,
        user: str,
        password: str | None,
        login_re: re.Pattern[str],
        password_re: re.Pattern[str],
        prompt_re: re.Pattern[str],
        failure_re: re.Pattern[str],
        timeout: float,
        poll_interval: float,
    ) -> None:
        token = uuid.uuid4().hex
        marker = f"__TMUX_TOOL_TELNET_{token}__"
        command = f"printf '\\n{marker}\\n'; telnet {shlex.quote(host)} {port}"
        sent_user = False
        sent_password = False
        deadline = time.monotonic() + timeout

        pane = self._pane(pane_id)
        if not pane.metadata.managed:
            raise TelnetError("UNMANAGED_TARGET", "refusing telnet automation on unmanaged pane", pane=pane.id)
        if pane.state is not PaneState.LOCAL:
            raise TelnetError(
                "PANE_NOT_LOCAL",
                "telnet connect requires a proven local shell pane",
                pane=pane.id,
                state=pane.state.value,
            )

        self._set_protocol(pane.id, peer=peer, state="CONNECTING", remote=False)
        self.tmux.paste_text(pane.id, command)
        self.tmux.send_keys(pane.id, "Enter")

        while time.monotonic() < deadline:
            snapshot = self.tmux.capture_pane(pane.id, lines=120)
            region = snapshot[snapshot.rfind(marker) + len(marker) :] if marker in snapshot else ""
            if not region:
                time.sleep(poll_interval)
                continue
            failure = failure_re.search(region)
            if failure:
                rollback_ok = self._rollback_locked(pane.id, timeout=min(3.0, timeout), poll_interval=poll_interval)
                raise TelnetError(
                    "TELNET_CONNECT_FAILED",
                    "telnet connection failed",
                    pane=pane.id,
                    peer=peer,
                    reason=failure.group(1),
                    rollback=int(rollback_ok),
                )
            if prompt_re.search(region):
                runtime = self._pane(pane.id)
                if runtime.current_command != "telnet":
                    rollback_ok = self._rollback_locked(pane.id, timeout=min(3.0, timeout), poll_interval=poll_interval)
                    raise TelnetError(
                        "TELNET_EXITED",
                        "shell prompt returned but telnet client is not running",
                        pane=pane.id,
                        peer=peer,
                        rollback=int(rollback_ok),
                    )
                # Do not publish REMOTE yet. Read-only observers may see VERIFYING,
                # while all writers block on the pane lock or refuse the state.
                self._set_protocol(pane.id, peer=peer, state="VERIFYING", remote=False)
                return
            if password_re.search(region) and not sent_password:
                self._set_protocol(pane.id, peer=peer, state="PASSWORD", remote=False)
                if password is None:
                    rollback_ok = self._rollback_locked(
                        pane.id,
                        timeout=min(3.0, timeout),
                        poll_interval=poll_interval,
                    )
                    raise TelnetError(
                        "PASSWORD_REQUIRED",
                        "remote requested a password",
                        blocked=True,
                        pane=pane.id,
                        peer=peer,
                        user=user,
                        rollback=int(rollback_ok),
                    )
                if password:
                    self.tmux.paste_text(pane.id, password)
                self.tmux.send_keys(pane.id, "Enter")
                sent_password = True
                time.sleep(poll_interval)
                continue
            if login_re.search(region) and not sent_user:
                self._set_protocol(pane.id, peer=peer, state="LOGIN", remote=False)
                self.tmux.paste_text(pane.id, user)
                self.tmux.send_keys(pane.id, "Enter")
                sent_user = True
                time.sleep(poll_interval)
                continue
            time.sleep(poll_interval)

        current = self._pane(pane.id)
        rollback_ok = self._rollback_locked(
            pane.id,
            timeout=min(3.0, timeout),
            poll_interval=poll_interval,
        )
        raise TelnetError(
            "TELNET_TIMEOUT",
            "remote shell prompt not reached",
            pane=pane.id,
            peer=peer,
            state=current.state.value,
            rollback=int(rollback_ok),
        )

    def _proof_locked(
        self,
        pane_id: str,
        *,
        peer: str,
        proof_command: str,
        timeout: float,
        poll_interval: float,
    ) -> int:
        """Prove a remote POSIX shell while retaining pane ownership."""

        current = self._pane(pane_id)
        if current.current_command != "telnet" or current.dead:
            raise TelnetError("TELNET_EXITED", "telnet client is not running during verification", pane=pane_id, peer=peer)

        self._set_protocol(pane_id, peer=peer, state="VERIFYING", remote=False)
        token = uuid.uuid4().hex
        start_marker = f"__TMUX_TOOL_TELNET_PROOF_START_{token}__"
        done_prefix = f"__TMUX_TOOL_TELNET_PROOF_DONE_{token}__="
        done_re = re.compile(r"(?m)^" + re.escape(done_prefix) + r"(-?\d+)\r?$")
        wrapped = isolated_job_command(proof_command, start_marker=start_marker, done_prefix=done_prefix)
        self.tmux.paste_text(pane_id, wrapped)
        self.tmux.send_keys(pane_id, "Enter")
        deadline = time.monotonic() + timeout
        snapshot = ""
        while time.monotonic() < deadline:
            snapshot = self.tmux.capture_pane(pane_id, lines=120)
            match = done_re.search(snapshot)
            if match is not None:
                rc = int(match.group(1))
                if rc != 0:
                    raise TelnetError("TELNET_PROOF_RC", "remote proof command returned non-zero", pane=pane_id, peer=peer, rc=rc)
                self._set_protocol(pane_id, peer=peer, state="REMOTE", remote=True)
                if start_marker in snapshot:
                    region = snapshot[snapshot.rfind(start_marker) + len(start_marker) : match.start()]
                    return len(region.strip("\n").splitlines()) if region.strip("\n") else 0
                return 0
            # If the local telnet process disappeared during verification, fail
            # immediately rather than waiting the full proof timeout.
            runtime = self._pane(pane_id)
            if runtime.current_command != "telnet" or runtime.dead:
                raise TelnetError("TELNET_EXITED", "telnet client exited during verification", pane=pane_id, peer=peer)
            time.sleep(poll_interval)
        raise TelnetError("TELNET_PROOF_TIMEOUT", "remote proof command timed out", pane=pane_id, peer=peer, timeout=timeout)

    def _rollback_locked(self, pane_id: str, *, timeout: float, poll_interval: float) -> bool:
        """Best-effort Telnet rollback to the host shell; caller owns pane lock."""

        try:
            current = self._pane(pane_id)
        except TelnetError:
            return False
        if current.dead:
            return False

        if current.current_command == "telnet":
            self.tmux.send_keys(pane_id, "C-]")
            if poll_interval > 0:
                time.sleep(poll_interval)
            self.tmux.paste_text(pane_id, "quit")
            self.tmux.send_keys(pane_id, "Enter")

        deadline = time.monotonic() + max(timeout, poll_interval)
        while time.monotonic() < deadline:
            current = self._pane(pane_id)
            if current.current_command in POSIX_SHELL_COMMANDS and not current.dead:
                self._clear_protocol(pane_id)
                return True
            time.sleep(poll_interval)
        return False

    def _set_protocol(self, pane_id: str, *, peer: str, state: str, remote: bool) -> None:
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "owner"), pane_id)
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "managed"), "1")
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "kind"), "telnet")
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "peer"), peer)
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "protocol_state"), state)
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "remote"), "1" if remote else "0")
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "busy"), "0")

    def _clear_protocol(self, pane_id: str) -> None:
        for suffix in (
            "kind",
            "peer",
            "protocol_state",
            "remote",
            "busy",
            "foreground",
            "output_marker",
            "job_type",
            "job_token",
            "job_state",
            "job_started_at",
            "job_completion_marker",
            "job_result_rc",
        ):
            if hasattr(self.tmux, "unset_user_option"):
                self.tmux.unset_user_option("pane", pane_id, option_name("pane", suffix))
            else:
                self.tmux.set_user_option("pane", pane_id, option_name("pane", suffix), "")
