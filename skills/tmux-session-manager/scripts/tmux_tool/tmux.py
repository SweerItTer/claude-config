from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import os
from pathlib import Path
import re
import subprocess
from typing import Iterable, Sequence
import uuid


class TmuxError(RuntimeError):
    def __init__(self, message: str, *, code: str = "TMUX_ERROR") -> None:
        super().__init__(message)
        self.code = code


_TMUX_VERSION_RE = re.compile(r"^tmux\s+(?P<major>\d+)\.(?P<minor>\d+)(?P<suffix>[a-z]*)$")


def parse_tmux_version(text: str) -> tuple[int, int, str]:
    match = _TMUX_VERSION_RE.fullmatch(text.strip())
    if match is None:
        raise TmuxError(
            f"unrecognized tmux version output: {text.strip() or '<empty>'}",
            code="TMUX_VERSION_PARSE",
        )
    return int(match.group("major")), int(match.group("minor")), match.group("suffix")


@dataclass(slots=True, frozen=True)
class SessionRow:
    session_id: str
    session_name: str
    options: dict[str, str] = field(default_factory=dict)


@dataclass(slots=True, frozen=True)
class WindowRow:
    session_id: str
    window_id: str
    window_index: int
    window_name: str
    options: dict[str, str] = field(default_factory=dict)


@dataclass(slots=True, frozen=True)
class PaneRow:
    session_id: str
    session_name: str
    window_id: str
    window_index: int
    window_name: str
    pane_id: str
    pane_index: int
    pane_pid: int | None
    pane_current_command: str
    pane_dead: bool
    pane_active: bool
    options: dict[str, str] = field(default_factory=dict)


class TmuxClient:
    """Small subprocess adapter. Runtime topology is always read from tmux."""

    SEP = "\x1f"

    def __init__(
        self,
        binary: str = "tmux",
        *,
        socket_name: str | None = None,
        socket_path: str | None = None,
        subprocess_timeout: float = 10.0,
    ) -> None:
        if socket_name and socket_path:
            raise ValueError("use either tmux socket name or socket path, not both")
        self.binary = binary
        self.socket_name = socket_name
        self.socket_path = socket_path
        self.subprocess_timeout = subprocess_timeout

    @property
    def base_args(self) -> list[str]:
        if self.socket_name:
            return ["-L", self.socket_name]
        if self.socket_path:
            return ["-S", self.socket_path]
        return []

    @property
    def server_identity(self) -> str:
        if self.socket_path:
            descriptor = f"socket:{Path(self.socket_path).expanduser().absolute()}"
        elif self.socket_name:
            tmpdir = os.environ.get("TMUX_TMPDIR") or "/tmp"
            descriptor = f"label:{self.socket_name}:tmp:{tmpdir}:uid:{os.getuid()}"
        else:
            tmux_env = os.environ.get("TMUX", "")
            if tmux_env:
                descriptor = f"socket:{tmux_env.split(',', 1)[0]}"
            else:
                tmpdir = os.environ.get("TMUX_TMPDIR") or "/tmp"
                descriptor = f"socket:{tmpdir}/tmux-{os.getuid()}/default"
        digest = hashlib.sha256(descriptor.encode("utf-8", errors="surrogatepass")).hexdigest()[:24]
        return f"srv-{digest}"

    def version(self) -> tuple[int, int, str]:
        proc = self._run(["-V"], check=True, use_server=False)
        return parse_tmux_version(proc.stdout)

    def ensure_supported_version(self, minimum: tuple[int, int] = (3, 2)) -> tuple[int, int, str]:
        actual = self.version()
        if actual[:2] < minimum:
            required = f">={minimum[0]}.{minimum[1]}"
            suffix = actual[2]
            actual_text = f"{actual[0]}.{actual[1]}{suffix}"
            raise TmuxError(
                f"unsupported tmux version: required {required}, actual {actual_text}",
                code="TMUX_VERSION",
            )
        return actual

    def _run(
        self,
        args: Iterable[str],
        *,
        check: bool = True,
        input_text: str | None = None,
        timeout: float | None = None,
        use_server: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["LC_ALL"] = "C"
        timeout = self.subprocess_timeout if timeout is None else timeout
        try:
            proc = subprocess.run(
                [self.binary, *(self.base_args if use_server else []), *args],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                input=input_text,
                timeout=timeout,
                env=env,
            )
        except FileNotFoundError as exc:
            raise TmuxError(f"tmux binary not found: {self.binary}", code="TMUX_NOT_FOUND") from exc
        except subprocess.TimeoutExpired as exc:
            raise TmuxError("tmux subprocess timed out", code="TMUX_TIMEOUT") from exc
        if check and proc.returncode != 0:
            detail = proc.stderr.strip() or proc.stdout.strip() or f"exit={proc.returncode}"
            raise TmuxError(detail)
        return proc

    @staticmethod
    def _option_fields(option_names: Sequence[str]) -> list[str]:
        return [f"#{{{name}}}" for name in option_names]

    @staticmethod
    def _options(option_names: Sequence[str], values: Sequence[str]) -> dict[str, str]:
        return {name: value for name, value in zip(option_names, values) if value != ""}

    def _no_server(self, proc: subprocess.CompletedProcess[str]) -> bool:
        if proc.returncode == 0:
            return False
        detail = (proc.stderr or proc.stdout).strip().lower()
        return "no server running" in detail or "failed to connect to server" in detail

    def list_session_rows(self, option_names: Sequence[str] = ()) -> list[SessionRow]:
        fixed = ["#{session_id}", "#{session_name}"]
        proc = self._run(["list-sessions", "-F", self.SEP.join([*fixed, *self._option_fields(option_names)])], check=False)
        if self._no_server(proc):
            return []
        if proc.returncode != 0:
            raise TmuxError(proc.stderr.strip() or proc.stdout.strip() or f"exit={proc.returncode}")
        rows: list[SessionRow] = []
        expected = len(fixed) + len(option_names)
        for line in proc.stdout.splitlines():
            if not line:
                continue
            parts = line.split(self.SEP)
            if len(parts) != expected:
                raise TmuxError("unexpected tmux list-sessions field count", code="TMUX_PARSE_ERROR")
            rows.append(SessionRow(parts[0], parts[1], self._options(option_names, parts[2:])))
        return rows

    def list_window_rows(self, option_names: Sequence[str] = ()) -> list[WindowRow]:
        fixed = ["#{session_id}", "#{window_id}", "#{window_index}", "#{window_name}"]
        proc = self._run(["list-windows", "-a", "-F", self.SEP.join([*fixed, *self._option_fields(option_names)])], check=False)
        if self._no_server(proc):
            return []
        if proc.returncode != 0:
            raise TmuxError(proc.stderr.strip() or proc.stdout.strip() or f"exit={proc.returncode}")
        rows: list[WindowRow] = []
        expected = len(fixed) + len(option_names)
        for line in proc.stdout.splitlines():
            if not line:
                continue
            parts = line.split(self.SEP)
            if len(parts) != expected:
                raise TmuxError("unexpected tmux list-windows field count", code="TMUX_PARSE_ERROR")
            rows.append(WindowRow(parts[0], parts[1], int(parts[2]), parts[3], self._options(option_names, parts[4:])))
        return rows

    def list_pane_rows(self, option_names: Sequence[str] = ()) -> list[PaneRow]:
        fixed = [
            "#{session_id}", "#{session_name}", "#{window_id}", "#{window_index}", "#{window_name}",
            "#{pane_id}", "#{pane_index}", "#{pane_pid}", "#{pane_current_command}", "#{pane_dead}", "#{pane_active}",
        ]
        proc = self._run(["list-panes", "-a", "-F", self.SEP.join([*fixed, *self._option_fields(option_names)])], check=False)
        if self._no_server(proc):
            return []
        if proc.returncode != 0:
            raise TmuxError(proc.stderr.strip() or proc.stdout.strip() or f"exit={proc.returncode}")
        rows: list[PaneRow] = []
        expected = len(fixed) + len(option_names)
        for line in proc.stdout.splitlines():
            if not line:
                continue
            parts = line.split(self.SEP)
            if len(parts) != expected:
                raise TmuxError(
                    f"unexpected tmux list-panes field count: got={len(parts)} expected={expected}",
                    code="TMUX_PARSE_ERROR",
                )
            rows.append(
                PaneRow(
                    session_id=parts[0], session_name=parts[1], window_id=parts[2], window_index=int(parts[3]), window_name=parts[4],
                    pane_id=parts[5], pane_index=int(parts[6]), pane_pid=int(parts[7]) if parts[7].isdigit() else None,
                    pane_current_command=parts[8], pane_dead=parts[9] == "1", pane_active=parts[10] == "1",
                    options=self._options(option_names, parts[11:]),
                )
            )
        return rows

    def get_pane_row(self, target: str, option_names: Sequence[str] = ()) -> PaneRow | None:
        fixed = [
            "#{session_id}", "#{session_name}", "#{window_id}", "#{window_index}", "#{window_name}",
            "#{pane_id}", "#{pane_index}", "#{pane_pid}", "#{pane_current_command}", "#{pane_dead}", "#{pane_active}",
        ]
        fmt = self.SEP.join([*fixed, *self._option_fields(option_names)])
        proc = self._run(["display-message", "-p", "-t", target, fmt], check=False)
        if proc.returncode != 0:
            return None
        parts = proc.stdout.rstrip("\n").split(self.SEP)
        expected = len(fixed) + len(option_names)
        if len(parts) != expected or not parts[5].startswith("%"):
            return None
        return PaneRow(
            session_id=parts[0], session_name=parts[1], window_id=parts[2], window_index=int(parts[3]), window_name=parts[4],
            pane_id=parts[5], pane_index=int(parts[6]), pane_pid=int(parts[7]) if parts[7].isdigit() else None,
            pane_current_command=parts[8], pane_dead=parts[9] == "1", pane_active=parts[10] == "1",
            options=self._options(option_names, parts[11:]),
        )

    def get_user_option(self, scope: str, target: str, name: str) -> str | None:
        scope_args = {"session": [], "window": ["-w"], "pane": ["-p"]}.get(scope)
        if scope_args is None:
            raise ValueError(f"invalid tmux option scope: {scope}")
        proc = self._run(["show-options", *scope_args, "-qv", "-t", target, name], check=False)
        if proc.returncode != 0:
            return None
        value = proc.stdout.rstrip("\n")
        return value if value != "" else None

    def get_user_options(self, scope: str, target: str, prefix: str) -> dict[str, str]:
        scope_args = {"session": [], "window": ["-w"], "pane": ["-p"]}.get(scope)
        if scope_args is None:
            raise ValueError(f"invalid tmux option scope: {scope}")
        proc = self._run(["show-options", *scope_args, "-q", "-t", target], check=False)
        if proc.returncode != 0:
            return {}
        result: dict[str, str] = {}
        for line in proc.stdout.splitlines():
            if not line.startswith(prefix):
                continue
            name, sep, value = line.partition(" ")
            result[name] = value if sep else ""
        return result

    def set_user_option(self, scope: str, target: str, name: str, value: str) -> None:
        scope_args = {"session": [], "window": ["-w"], "pane": ["-p"]}.get(scope)
        if scope_args is None:
            raise ValueError(f"invalid tmux option scope: {scope}")
        self._run(["set-option", *scope_args, "-q", "-t", target, name, value])

    def unset_user_option(self, scope: str, target: str, name: str) -> None:
        scope_args = {"session": [], "window": ["-w"], "pane": ["-p"]}.get(scope)
        if scope_args is None:
            raise ValueError(f"invalid tmux option scope: {scope}")
        self._run(["set-option", *scope_args, "-qu", "-t", target, name], check=False)

    def new_session(self, name: str, window_name: str = "main") -> tuple[str, str, str]:
        fmt = self.SEP.join(["#{session_id}", "#{window_id}", "#{pane_id}"])
        proc = self._run(["new-session", "-d", "-s", name, "-n", window_name, "-P", "-F", fmt])
        parts = proc.stdout.strip().split(self.SEP)
        if len(parts) != 3:
            raise TmuxError("unexpected new-session result", code="TMUX_PARSE_ERROR")
        return parts[0], parts[1], parts[2]

    def new_window(self, session_target: str, name: str) -> tuple[str, str]:
        fmt = self.SEP.join(["#{window_id}", "#{pane_id}"])
        proc = self._run(["new-window", "-d", "-t", session_target, "-n", name, "-P", "-F", fmt])
        parts = proc.stdout.strip().split(self.SEP)
        if len(parts) != 2:
            raise TmuxError("unexpected new-window result", code="TMUX_PARSE_ERROR")
        return parts[0], parts[1]

    def split_window(self, pane_target: str, *, horizontal: bool = True) -> str:
        flag = "-h" if horizontal else "-v"
        proc = self._run(["split-window", "-d", flag, "-t", pane_target, "-P", "-F", "#{pane_id}"])
        pane_id = proc.stdout.strip()
        if not pane_id.startswith("%"):
            raise TmuxError("unexpected split-window result", code="TMUX_PARSE_ERROR")
        return pane_id

    def kill_session(self, target: str) -> None:
        self._run(["kill-session", "-t", target])

    def kill_window(self, target: str) -> None:
        self._run(["kill-window", "-t", target])

    def kill_pane(self, target: str) -> None:
        self._run(["kill-pane", "-t", target])

    def capture_pane(self, target: str, *, lines: int = 80, all_scrollback: bool = False) -> str:
        if lines < 1:
            raise ValueError("lines must be positive")
        args = ["capture-pane", "-p", "-J", "-t", target]
        if all_scrollback:
            args.extend(["-S", "-"])
        else:
            args.extend(["-S", f"-{lines}"])
        return self._run(args).stdout

    def paste_text(self, target: str, text: str) -> None:
        buffer_name = f"tmux-tool-{uuid.uuid4().hex}"
        loaded = False
        try:
            self._run(["load-buffer", "-b", buffer_name, "-"], input_text=text)
            loaded = True
            self._run(["paste-buffer", "-b", buffer_name, "-t", target])
        finally:
            if loaded:
                self._run(["delete-buffer", "-b", buffer_name], check=False)

    def send_keys(self, target: str, *keys: str) -> None:
        self._run(["send-keys", "-t", target, *keys])
