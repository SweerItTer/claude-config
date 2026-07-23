from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from .model import Inventory, Pane, Session, Window


class ResolveError(RuntimeError):
    def __init__(self, code: str, message: str, *, matches: list[str] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.matches = matches or []


@dataclass(slots=True, frozen=True)
class Resolved:
    kind: Literal["session", "window", "pane"]
    session: Session
    window: Window | None = None
    pane: Pane | None = None

    @property
    def id(self) -> str:
        if self.pane is not None:
            return self.pane.id
        if self.window is not None:
            return self.window.id
        return self.session.id


def resolve_target(inventory: Inventory, selector: str) -> Resolved:
    if selector.startswith("role:"):
        role = selector[5:]
        if not role:
            raise ResolveError("BAD_SELECTOR", "role selector is empty")
        matches = find_by_role(inventory, role)
        if len(matches) == 1:
            return matches[0]
        if not matches:
            raise ResolveError("NOT_FOUND", f"role not found: {role}")
        raise ResolveError("AMBIGUOUS_ROLE", f"role is ambiguous: {role}", matches=[item.id for item in matches])

    if selector.startswith("%"):
        for session, window, pane in inventory.all_panes():
            if pane.id == selector:
                return Resolved("pane", session, window, pane)
        raise ResolveError("NOT_FOUND", f"pane not found: {selector}")

    if selector.startswith("@"):
        for session, window in inventory.all_windows():
            if window.id == selector:
                return Resolved("window", session, window)
        raise ResolveError("NOT_FOUND", f"window not found: {selector}")

    if selector.startswith("$"):
        for session in inventory.sessions:
            if session.id == selector:
                return Resolved("session", session)
        raise ResolveError("NOT_FOUND", f"session not found: {selector}")

    # tmux-like aliases: session, session:window, session:window.pane
    session_name, colon, remainder = selector.partition(":")
    matching_sessions = [session for session in inventory.sessions if session.name == session_name]
    if len(matching_sessions) != 1:
        if not matching_sessions:
            raise ResolveError("NOT_FOUND", f"session not found: {session_name}")
        raise ResolveError("AMBIGUOUS_TARGET", f"session name is ambiguous: {session_name}")
    session = matching_sessions[0]
    if not colon:
        return Resolved("session", session)

    window_token, dot, pane_token = remainder.partition(".")
    matching_windows = [
        window
        for window in session.windows
        if window.name == window_token or str(window.index) == window_token
    ]
    if len(matching_windows) != 1:
        ids = [window.id for window in matching_windows]
        code = "AMBIGUOUS_TARGET" if matching_windows else "NOT_FOUND"
        raise ResolveError(code, f"window selector unresolved: {remainder}", matches=ids)
    window = matching_windows[0]
    if not dot:
        return Resolved("window", session, window)

    matching_panes = [pane for pane in window.panes if str(pane.index) == pane_token or pane.id == pane_token]
    if len(matching_panes) != 1:
        ids = [pane.id for pane in matching_panes]
        code = "AMBIGUOUS_TARGET" if matching_panes else "NOT_FOUND"
        raise ResolveError(code, f"pane selector unresolved: {selector}", matches=ids)
    return Resolved("pane", session, window, matching_panes[0])


def find_by_role(inventory: Inventory, role: str, kind: str | None = None) -> list[Resolved]:
    """Find managed resources by semantic role.

    Roles are a tmux-tool managed namespace. Unmanaged resources are deliberately
    excluded even if they happen to carry similarly named user options.
    """

    found: list[Resolved] = []
    if kind in {None, "session"}:
        for session in inventory.sessions:
            if session.metadata.managed and session.metadata.role == role:
                found.append(Resolved("session", session))
    if kind in {None, "window"}:
        for session, window in inventory.all_windows():
            if window.metadata.managed and window.metadata.role == role:
                found.append(Resolved("window", session, window))
    if kind in {None, "pane"}:
        for session, window, pane in inventory.all_panes():
            if pane.metadata.managed and pane.metadata.role == role:
                found.append(Resolved("pane", session, window, pane))
    return found
