from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum


class ResourceKind(StrEnum):
    SESSION = "session"
    WINDOW = "window"
    PANE = "pane"


POSIX_SHELL_COMMANDS = {"bash", "dash", "ksh", "sh", "zsh", "ash"}


class PaneState(StrEnum):
    DEAD = "DEAD"
    LOCAL = "LOCAL"
    BUSY = "BUSY"
    REMOTE = "REMOTE"
    CONNECTING = "CONNECTING"
    LOGIN = "LOGIN"
    PASSWORD = "PASSWORD"
    VERIFYING = "VERIFYING"
    DISCONNECTED = "DISCONNECTED"
    UNKNOWN = "UNKNOWN"


@dataclass(slots=True)
class Metadata:
    managed: bool = False
    role: str | None = None
    note: str | None = None
    kind: str | None = None
    peer: str | None = None
    seed: bool = False
    busy_hint: bool = False
    foreground: str | None = None
    remote_hint: bool = False
    protocol_state: str | None = None
    output_marker: str | None = None
    job_type: str | None = None
    job_token: str | None = None
    job_state: str | None = None
    job_started_at: float | None = None
    job_completion_marker: str | None = None
    job_result_rc: int | None = None


@dataclass(slots=True)
class Pane:
    id: str
    index: int
    pid: int | None
    current_command: str
    dead: bool
    active: bool
    metadata: Metadata = field(default_factory=Metadata)

    @property
    def state(self) -> PaneState:
        if self.dead:
            return PaneState.DEAD
        # Returning to a local shell proves that a remote client is gone. Stale
        # remote/job hints must not keep a killed Telnet client looking BUSY.
        if self.current_command in POSIX_SHELL_COMMANDS:
            if self.metadata.busy_hint and not self.metadata.remote_hint:
                return PaneState.BUSY
            return PaneState.LOCAL
        if self.metadata.busy_hint:
            return PaneState.BUSY
        if self.current_command == "telnet":
            if self.metadata.remote_hint:
                return PaneState.REMOTE
            if self.metadata.protocol_state in {
                "CONNECTING",
                "LOGIN",
                "PASSWORD",
                "VERIFYING",
                "DISCONNECTED",
            }:
                return PaneState(self.metadata.protocol_state)
        return PaneState.UNKNOWN


@dataclass(slots=True)
class Window:
    id: str
    index: int
    name: str
    panes: list[Pane] = field(default_factory=list)
    metadata: Metadata = field(default_factory=Metadata)


@dataclass(slots=True)
class Session:
    id: str
    name: str
    windows: list[Window] = field(default_factory=list)
    metadata: Metadata = field(default_factory=Metadata)


@dataclass(slots=True)
class Inventory:
    sessions: list[Session] = field(default_factory=list)

    def all_windows(self) -> list[tuple[Session, Window]]:
        return [(session, window) for session in self.sessions for window in session.windows]

    def all_panes(self) -> list[tuple[Session, Window, Pane]]:
        return [
            (session, window, pane)
            for session in self.sessions
            for window in session.windows
            for pane in window.panes
        ]
