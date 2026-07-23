from __future__ import annotations

from contextlib import ExitStack
from dataclasses import dataclass
from typing import Literal

from .config import Limits
from .inventory import build_inventory
from .locking import pane_lock, topology_lock
from .metadata import MetadataWriter
from .model import Inventory
from .resolver import ResolveError, Resolved, find_by_role, resolve_target
from .tmux import TmuxClient
from .validation import validate_metadata_text, validate_role


class LifecycleError(RuntimeError):
    def __init__(self, code: str, message: str, **facts: object) -> None:
        super().__init__(message)
        self.code = code
        self.facts = facts


@dataclass(slots=True, frozen=True)
class Mutation:
    action: str
    resource_kind: Literal["session", "window", "pane"]
    resource_id: str
    created: bool | None = None
    parent_id: str | None = None
    role: str | None = None


class Lifecycle:
    def __init__(self, tmux: TmuxClient, limits: Limits, *, lock_timeout: float = 5.0) -> None:
        self.tmux = tmux
        self.limits = limits
        self.lock_timeout = lock_timeout
        self.meta = MetadataWriter(tmux)

    def _inventory(self) -> Inventory:
        return build_inventory(self.tmux)

    @staticmethod
    def _validate_role(role: str | None) -> None:
        if role is None:
            return
        if not validate_role(role):
            raise LifecycleError(
                "BAD_ROLE",
                "role must match [A-Za-z0-9][A-Za-z0-9._:/-]*",
                role=role,
            )

    @staticmethod
    def _role_matches(inv: Inventory, role: str | None) -> list[Resolved]:
        return find_by_role(inv, role) if role else []

    @classmethod
    def _assert_role_available(
        cls,
        inv: Inventory,
        role: str | None,
        *,
        owner_id: str | None = None,
    ) -> Resolved | None:
        cls._validate_role(role)
        if role is None:
            return None
        matches = cls._role_matches(inv, role)
        if len(matches) > 1:
            raise LifecycleError(
                "AMBIGUOUS_ROLE",
                "semantic role is duplicated in managed topology",
                role=role,
                matches=",".join(item.id for item in matches),
            )
        if not matches:
            return None
        match = matches[0]
        if owner_id is not None and match.id == owner_id:
            return match
        raise LifecycleError(
            "ROLE_CONFLICT",
            "semantic role already belongs to another managed resource",
            role=role,
            owner=match.id,
            owner_kind=match.kind,
        )

    def _verify(self, resource_id: str, *, kind: str) -> Resolved:
        refreshed = self._inventory()
        try:
            resolved = resolve_target(refreshed, resource_id)
        except ResolveError as exc:
            raise LifecycleError(
                "VERIFY_FAILED",
                "mutated resource is not visible after refresh",
                target=resource_id,
            ) from exc
        if resolved.kind != kind:
            raise LifecycleError(
                "VERIFY_FAILED",
                "mutated resource resolved to wrong kind",
                target=resource_id,
                expected=kind,
                actual=resolved.kind,
            )
        return resolved

    def session_ensure(self, name: str, *, role: str | None = None, note: str | None = None) -> Mutation:
        self._validate_role(role)
        if note is not None and not validate_metadata_text(note):
            raise LifecycleError("BAD_NOTE", "note contains control characters")
        with topology_lock(self.tmux.server_identity, timeout=self.lock_timeout):
            # P0 invariant: role/name/limit checks are all made from the inventory
            # rebuilt after topology lock acquisition.
            inv = self._inventory()
            by_name = [s for s in inv.sessions if s.name == name]
            if len(by_name) > 1:
                raise LifecycleError("AMBIGUOUS_ENSURE", "session name is ambiguous", name=name)
            role_owner = self._role_matches(inv, role)
            if len(role_owner) > 1:
                raise LifecycleError(
                    "AMBIGUOUS_ROLE",
                    "semantic role is duplicated in managed topology",
                    role=role,
                    matches=",".join(item.id for item in role_owner),
                )

            candidates: dict[str, object] = {s.id: s for s in by_name}
            if role_owner:
                if role_owner[0].kind != "session":
                    raise LifecycleError(
                        "ROLE_CONFLICT",
                        "requested session role belongs to another resource kind",
                        role=role,
                        owner=role_owner[0].id,
                        owner_kind=role_owner[0].kind,
                    )
                candidates[role_owner[0].id] = role_owner[0].session
            if len(candidates) > 1:
                raise LifecycleError(
                    "AMBIGUOUS_ENSURE",
                    "name and role identify different sessions",
                    matches=",".join(candidates),
                )
            if candidates:
                session = next(iter(candidates.values()))
                assert hasattr(session, "metadata")
                if not session.metadata.managed:
                    raise LifecycleError("UNMANAGED_EXISTS", "matching session is not managed", session=session.id)
                self._assert_role_available(inv, role, owner_id=session.id)
                self.meta.tag_managed(
                    "session", session.id,
                    role=role or session.metadata.role,
                    note=note if note is not None else session.metadata.note,
                )
                verified = self._verify(session.id, kind="session")
                return Mutation(
                    "session.ensure",
                    "session",
                    verified.id,
                    created=False,
                    role=role or verified.session.metadata.role,
                )

            self._assert_role_available(inv, role)
            if len(inv.sessions) >= self.limits.sessions:
                raise LifecycleError(
                    "LIMIT_SESSIONS",
                    "session limit reached",
                    current=len(inv.sessions),
                    limit=self.limits.sessions,
                )
            session_id = window_id = pane_id = ""
            try:
                session_id, window_id, pane_id = self.tmux.new_session(name)
                self.meta.tag_managed("session", session_id, role=role, note=note)
                self.meta.tag_managed("window", window_id)
                self.meta.tag_managed("pane", pane_id, seed=True)
                verified = self._verify(session_id, kind="session")
            except Exception:
                if session_id:
                    try:
                        self.tmux.kill_session(session_id)
                    except Exception:
                        pass
                raise
            return Mutation("session.ensure", "session", verified.id, created=True, role=role)

    def window_ensure(
        self,
        session_selector: str,
        *,
        name: str,
        role: str | None = None,
        note: str | None = None,
    ) -> Mutation:
        self._validate_role(role)
        if note is not None and not validate_metadata_text(note):
            raise LifecycleError("BAD_NOTE", "note contains control characters")
        with topology_lock(self.tmux.server_identity, timeout=self.lock_timeout):
            inv = self._inventory()
            try:
                parent = resolve_target(inv, session_selector)
            except ResolveError as exc:
                raise LifecycleError(exc.code, str(exc), matches=",".join(exc.matches)) from exc
            if parent.kind != "session":
                raise LifecycleError("TYPE_MISMATCH", "window parent must resolve to session", target=parent.id)
            session = parent.session
            if not session.metadata.managed:
                raise LifecycleError("UNMANAGED_PARENT", "refusing to mutate unmanaged session", session=session.id)

            by_name = [w for w in session.windows if w.name == name]
            if len(by_name) > 1:
                raise LifecycleError(
                    "AMBIGUOUS_ENSURE",
                    "window name is ambiguous inside session",
                    session=session.id,
                    name=name,
                    matches=",".join(w.id for w in by_name),
                )
            role_owner = self._role_matches(inv, role)
            if len(role_owner) > 1:
                raise LifecycleError(
                    "AMBIGUOUS_ROLE",
                    "semantic role is duplicated in managed topology",
                    role=role,
                    matches=",".join(item.id for item in role_owner),
                )
            candidates: dict[str, object] = {w.id: w for w in by_name}
            if role_owner:
                item = role_owner[0]
                if item.kind != "window" or item.session.id != session.id:
                    raise LifecycleError(
                        "ROLE_CONFLICT",
                        "requested window role belongs to another managed resource",
                        role=role,
                        owner=item.id,
                        owner_kind=item.kind,
                    )
                assert item.window is not None
                candidates[item.id] = item.window
            if len(candidates) > 1:
                raise LifecycleError(
                    "AMBIGUOUS_ENSURE",
                    "window name and role identify different resources",
                    matches=",".join(candidates),
                )
            if candidates:
                window = next(iter(candidates.values()))
                assert hasattr(window, "metadata")
                if not window.metadata.managed:
                    raise LifecycleError("UNMANAGED_EXISTS", "matching window is not managed", window=window.id)
                self._assert_role_available(inv, role, owner_id=window.id)
                self.meta.tag_managed(
                    "window", window.id,
                    role=role or window.metadata.role,
                    note=note if note is not None else window.metadata.note,
                )
                verified = self._verify(window.id, kind="window")
                return Mutation(
                    "window.ensure",
                    "window",
                    verified.id,
                    created=False,
                    parent_id=session.id,
                    role=role or (verified.window.metadata.role if verified.window else None),
                )

            self._assert_role_available(inv, role)
            if len(session.windows) >= self.limits.windows_per_session:
                raise LifecycleError(
                    "LIMIT_WINDOWS",
                    "window limit reached",
                    session=session.id,
                    current=len(session.windows),
                    limit=self.limits.windows_per_session,
                )
            window_id = pane_id = ""
            try:
                window_id, pane_id = self.tmux.new_window(session.id, name)
                self.meta.tag_managed("window", window_id, role=role, note=note)
                self.meta.tag_managed("pane", pane_id, seed=True)
                verified = self._verify(window_id, kind="window")
            except Exception:
                if window_id:
                    try:
                        self.tmux.kill_window(window_id)
                    except Exception:
                        pass
                raise
            return Mutation(
                "window.ensure",
                "window",
                verified.id,
                created=True,
                parent_id=session.id,
                role=role,
            )

    def pane_ensure(
        self,
        window_selector: str,
        *,
        role: str,
        note: str | None = None,
        horizontal: bool = True,
    ) -> Mutation:
        self._validate_role(role)
        if note is not None and not validate_metadata_text(note):
            raise LifecycleError("BAD_NOTE", "note contains control characters")
        with topology_lock(self.tmux.server_identity, timeout=self.lock_timeout):
            inv = self._inventory()
            try:
                parent = resolve_target(inv, window_selector)
            except ResolveError as exc:
                raise LifecycleError(exc.code, str(exc), matches=",".join(exc.matches)) from exc
            if parent.kind != "window" or parent.window is None:
                raise LifecycleError("TYPE_MISMATCH", "pane parent must resolve to window", target=parent.id)
            window = parent.window
            if not window.metadata.managed:
                raise LifecycleError("UNMANAGED_PARENT", "refusing to mutate unmanaged window", window=window.id)

            role_owner = self._role_matches(inv, role)
            if len(role_owner) > 1:
                raise LifecycleError(
                    "AMBIGUOUS_ROLE",
                    "semantic role is duplicated in managed topology",
                    role=role,
                    matches=",".join(item.id for item in role_owner),
                )
            if role_owner:
                item = role_owner[0]
                if item.kind != "pane":
                    raise LifecycleError(
                        "ROLE_CONFLICT",
                        "requested pane role belongs to another resource kind",
                        role=role,
                        owner=item.id,
                        owner_kind=item.kind,
                    )
                if item.window is None or item.window.id != window.id:
                    raise LifecycleError(
                        "ROLE_CONFLICT",
                        "requested pane role belongs to a different window",
                        role=role,
                        owner=item.id,
                        owner_window=item.window.id if item.window else None,
                    )
                pane = item.pane
                assert pane is not None
                self.meta.tag_managed(
                    "pane", pane.id, role=role,
                    note=note if note is not None else pane.metadata.note,
                    seed=False,
                )
                pane = self._verify(pane.id, kind="pane").pane
                assert pane is not None
                return Mutation("pane.ensure", "pane", pane.id, created=False, parent_id=window.id, role=role)

            self._assert_role_available(inv, role)
            seeds = [
                pane
                for pane in window.panes
                if pane.metadata.managed
                and pane.metadata.seed
                and not pane.metadata.role
                and pane.state.value == "LOCAL"
            ]
            if len(seeds) == 1:
                pane = seeds[0]
                self.meta.tag_managed("pane", pane.id, role=role, note=note, seed=False)
                verified = self._verify(pane.id, kind="pane")
                return Mutation("pane.ensure", "pane", verified.id, created=False, parent_id=window.id, role=role)
            if len(seeds) > 1:
                raise LifecycleError(
                    "AMBIGUOUS_SEED",
                    "multiple reusable seed panes",
                    matches=",".join(p.id for p in seeds),
                )

            if len(window.panes) >= self.limits.panes_per_window:
                raise LifecycleError(
                    "LIMIT_PANES",
                    "pane limit reached",
                    window=window.id,
                    current=len(window.panes),
                    limit=self.limits.panes_per_window,
                )
            source = next((p for p in window.panes if p.active), window.panes[0] if window.panes else None)
            if source is None:
                raise LifecycleError("NO_SOURCE_PANE", "cannot split window without a pane", window=window.id)
            pane_id = ""
            try:
                pane_id = self.tmux.split_window(source.id, horizontal=horizontal)
                self.meta.tag_managed("pane", pane_id, role=role, note=note, seed=False)
                verified = self._verify(pane_id, kind="pane")
            except Exception:
                if pane_id:
                    try:
                        self.tmux.kill_pane(pane_id)
                    except Exception:
                        pass
                raise
            return Mutation("pane.ensure", "pane", verified.id, created=True, parent_id=window.id, role=role)

    def close(
        self,
        selector: str,
        *,
        expected_kind: str | None = None,
        force: bool = False,
    ) -> Mutation:
        with topology_lock(self.tmux.server_identity, timeout=self.lock_timeout):
            # First resolve only enough topology to determine which pane locks are
            # needed. Destructive validation is repeated after those locks are
            # acquired, so exec/start/connect cannot race between check and kill.
            first_inv = self._inventory()
            try:
                first = resolve_target(first_inv, selector)
            except ResolveError as exc:
                raise LifecycleError(exc.code, str(exc), matches=",".join(exc.matches)) from exc
            if expected_kind is not None and first.kind != expected_kind:
                raise LifecycleError(
                    "TYPE_MISMATCH",
                    "close target has wrong resource type",
                    expected=expected_kind,
                    actual=first.kind,
                    target=first.id,
                )

            if first.kind == "session":
                pane_ids = [pane.id for window in first.session.windows for pane in window.panes]
            elif first.kind == "window":
                assert first.window is not None
                pane_ids = [pane.id for pane in first.window.panes]
            else:
                assert first.pane is not None
                pane_ids = [first.pane.id]

            with ExitStack() as locks:
                for pane_id in sorted(set(pane_ids)):
                    locks.enter_context(pane_lock(self.tmux.server_identity, pane_id, timeout=self.lock_timeout))

                inv = self._inventory()
                try:
                    resolved = resolve_target(inv, first.id)
                except ResolveError as exc:
                    raise LifecycleError(exc.code, str(exc), matches=",".join(exc.matches)) from exc
                if expected_kind is not None and resolved.kind != expected_kind:
                    raise LifecycleError(
                        "TYPE_MISMATCH",
                        "close target changed resource type",
                        expected=expected_kind,
                        actual=resolved.kind,
                        target=resolved.id,
                    )
                metadata = (
                    resolved.pane.metadata
                    if resolved.pane is not None
                    else resolved.window.metadata
                    if resolved.window is not None
                    else resolved.session.metadata
                )
                if not metadata.managed:
                    raise LifecycleError("UNMANAGED_TARGET", "refusing to close unmanaged resource", target=resolved.id)

                unmanaged: list[str] = []
                busy: list[str] = []
                cascade: list[str] = []

                if resolved.kind == "session":
                    for window in resolved.session.windows:
                        if not window.metadata.managed:
                            unmanaged.append(window.id)
                        for pane in window.panes:
                            if not pane.metadata.managed:
                                unmanaged.append(pane.id)
                            if pane.state.value == "BUSY":
                                busy.append(pane.id)
                elif resolved.kind == "window":
                    assert resolved.window is not None
                    for pane in resolved.window.panes:
                        if not pane.metadata.managed:
                            unmanaged.append(pane.id)
                        if pane.state.value == "BUSY":
                            busy.append(pane.id)
                    if len(resolved.session.windows) == 1:
                        cascade.append(resolved.session.id)
                else:
                    assert resolved.window is not None and resolved.pane is not None
                    if resolved.pane.state.value == "BUSY":
                        busy.append(resolved.pane.id)
                    if len(resolved.window.panes) == 1:
                        cascade.append(resolved.window.id)
                        if len(resolved.session.windows) == 1:
                            cascade.append(resolved.session.id)

                if not force and unmanaged:
                    raise LifecycleError(
                        "DESCENDANT_UNMANAGED",
                        "close would delete unmanaged descendants",
                        target=resolved.id,
                        affected=",".join(unmanaged),
                    )
                if not force and busy:
                    raise LifecycleError(
                        "DESCENDANT_BUSY",
                        "close would terminate BUSY pane(s)",
                        target=resolved.id,
                        affected=",".join(busy),
                    )
                if not force and cascade:
                    raise LifecycleError(
                        "CASCADE_CLOSE",
                        "close would implicitly delete parent topology",
                        target=resolved.id,
                        affected=",".join(cascade),
                    )

                if resolved.kind == "pane":
                    self.tmux.kill_pane(resolved.id)
                elif resolved.kind == "window":
                    self.tmux.kill_window(resolved.id)
                else:
                    self.tmux.kill_session(resolved.id)

            refreshed = self._inventory()
            try:
                resolve_target(refreshed, resolved.id)
            except ResolveError as exc:
                if exc.code == "NOT_FOUND":
                    return Mutation(f"{resolved.kind}.close", resolved.kind, resolved.id, created=None)
                raise LifecycleError(exc.code, str(exc), matches=",".join(exc.matches)) from exc
            raise LifecycleError("VERIFY_FAILED", "resource still exists after close", target=resolved.id)
