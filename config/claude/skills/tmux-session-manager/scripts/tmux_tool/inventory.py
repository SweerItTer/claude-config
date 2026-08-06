from __future__ import annotations

from .model import Inventory, Metadata, Pane, Session, Window
from .tmux import PaneRow, TmuxClient


# v0.2.5 uses scope-specific names so tmux option inheritance cannot make a
# parent resource's metadata look like child metadata during format expansion.
LEGACY_PREFIX = "@tmux_tool_"
SCOPE_PREFIX = {
    "session": "@tmux_tool_s_",
    "window": "@tmux_tool_w_",
    "pane": "@tmux_tool_p_",
}
# Compatibility alias for older internal imports/tests. New writes must use
# option_name(scope, suffix), never this generic legacy prefix.
OPT_PREFIX = LEGACY_PREFIX

_METADATA_SUFFIXES = (
    "owner", "managed", "role", "note", "kind", "peer", "seed", "busy", "foreground", "remote",
    "protocol_state", "output_marker", "job_type", "job_token", "job_state", "job_started_at",
    "job_completion_marker", "job_result_rc",
)


def option_name(scope: str, suffix: str) -> str:
    try:
        prefix = SCOPE_PREFIX[scope]
    except KeyError as exc:
        raise ValueError(f"invalid metadata scope: {scope}") from exc
    return f"{prefix}{suffix}"


def metadata_option_names(scope: str) -> tuple[str, ...]:
    return tuple(option_name(scope, suffix) for suffix in _METADATA_SUFFIXES)


SESSION_OPTION_NAMES = metadata_option_names("session")
WINDOW_OPTION_NAMES = metadata_option_names("window")
PANE_OPTION_NAMES = metadata_option_names("pane")


def _truthy(value: str | None) -> bool:
    return value in {"1", "true", "yes", "on"}


def _metadata_from_get(get) -> Metadata:
    rc_raw = get("job_result_rc")
    try:
        result_rc = int(rc_raw) if rc_raw not in (None, "") else None
    except ValueError:
        result_rc = None
    started_raw = get("job_started_at")
    try:
        started_at = float(started_raw) if started_raw not in (None, "") else None
    except ValueError:
        started_at = None
    return Metadata(
        managed=_truthy(get("managed")),
        role=get("role") or None,
        note=get("note") or None,
        kind=get("kind") or None,
        peer=get("peer") or None,
        seed=_truthy(get("seed")),
        busy_hint=_truthy(get("busy")),
        foreground=get("foreground") or None,
        remote_hint=_truthy(get("remote")),
        protocol_state=get("protocol_state") or None,
        output_marker=get("output_marker") or None,
        job_type=get("job_type") or None,
        job_token=get("job_token") or None,
        job_state=get("job_state") or None,
        job_started_at=started_at,
        job_completion_marker=get("job_completion_marker") or None,
        job_result_rc=result_rc,
    )




def metadata_owned_by(scope: str, values: dict[str, str], expected_owner: str) -> bool:
    return values.get(option_name(scope, "owner")) == expected_owner

def metadata_from_options(scope: str, values: dict[str, str], *, expected_owner: str | None = None) -> Metadata:
    if expected_owner is not None and values.get(option_name(scope, "owner")) != expected_owner:
        return Metadata()
    return _metadata_from_get(lambda suffix: values.get(option_name(scope, suffix)))


def legacy_metadata_from_options(values: dict[str, str]) -> Metadata:
    return _metadata_from_get(lambda suffix: values.get(f"{LEGACY_PREFIX}{suffix}"))


def _legacy_exact(tmux: TmuxClient, scope: str, target: str) -> Metadata:
    return legacy_metadata_from_options(tmux.get_user_options(scope, target, LEGACY_PREFIX))


def _pane_from_row(row: PaneRow, metadata: Metadata | None = None) -> Pane:
    return Pane(
        id=row.pane_id,
        index=row.pane_index,
        pid=row.pane_pid,
        current_command=row.pane_current_command,
        dead=row.pane_dead,
        active=row.pane_active,
        metadata=metadata if metadata is not None else metadata_from_options("pane", row.options, expected_owner=row.pane_id),
    )


def lookup_pane_context(tmux: TmuxClient, pane_id: str) -> tuple[Session, Window, Pane] | None:
    """Fast path for one stable native pane ID, including its parent identity."""

    if not pane_id.startswith("%"):
        return None
    row = tmux.get_pane_row(pane_id, PANE_OPTION_NAMES)
    if row is None:
        return None
    meta = metadata_from_options("pane", row.options, expected_owner=row.pane_id)
    if not metadata_owned_by("pane", row.options, row.pane_id):
        legacy = _legacy_exact(tmux, "pane", pane_id)
        if legacy.managed or any((legacy.role, legacy.kind, legacy.peer, legacy.job_type, legacy.protocol_state)):
            meta = legacy
    pane = _pane_from_row(row, meta)
    window = Window(id=row.window_id, index=row.window_index, name=row.window_name, panes=[pane])
    session = Session(id=row.session_id, name=row.session_name, windows=[window])
    return session, window, pane


def lookup_pane(tmux: TmuxClient, pane_id: str) -> Pane | None:
    """Fast path for stable native pane IDs: one targeted tmux query."""

    context = lookup_pane_context(tmux, pane_id)
    return context[2] if context is not None else None


def build_inventory(tmux: TmuxClient) -> Inventory:
    """Build new-metadata topology with three tmux list subprocesses.

    Old v0.2.4 generic metadata is read exactly (non-inherited) only beneath a
    legacy managed session. This preserves compatibility without making the new
    steady-state inventory O(resources).
    """

    # Session rows include only scoped metadata for steady state. A single extra
    # legacy managed/role/note set is included at session scope; session options
    # have no parent scope inside our resource tree, so it is safe as a legacy
    # detector and avoids probing every unmanaged resource.
    legacy_session_names = tuple(f"{LEGACY_PREFIX}{s}" for s in ("managed", "role", "note"))
    session_rows = tmux.list_session_rows((*SESSION_OPTION_NAMES, *legacy_session_names))
    if not session_rows:
        return Inventory()
    window_rows = tmux.list_window_rows(WINDOW_OPTION_NAMES)
    pane_rows = tmux.list_pane_rows(PANE_OPTION_NAMES)

    legacy_sessions: set[str] = set()
    sessions_by_id: dict[str, Session] = {}
    for row in session_rows:
        scoped_values = {k: v for k, v in row.options.items() if k.startswith(SCOPE_PREFIX["session"])}
        meta = metadata_from_options("session", scoped_values, expected_owner=row.session_id)
        if not metadata_owned_by("session", scoped_values, row.session_id):
            legacy_values = {k: v for k, v in row.options.items() if k.startswith(LEGACY_PREFIX)}
            legacy_meta = legacy_metadata_from_options(legacy_values)
            if legacy_meta.managed:
                meta = _legacy_exact(tmux, "session", row.session_id)
                legacy_sessions.add(row.session_id)
        sessions_by_id[row.session_id] = Session(id=row.session_id, name=row.session_name, metadata=meta)

    windows_by_id: dict[str, Window] = {}
    for row in window_rows:
        session = sessions_by_id.get(row.session_id)
        if session is None:
            continue
        meta = metadata_from_options("window", row.options, expected_owner=row.window_id)
        if not metadata_owned_by("window", row.options, row.window_id) and row.session_id in legacy_sessions:
            meta = _legacy_exact(tmux, "window", row.window_id)
        window = Window(id=row.window_id, index=row.window_index, name=row.window_name, metadata=meta)
        windows_by_id[row.window_id] = window
        session.windows.append(window)

    for row in pane_rows:
        window = windows_by_id.get(row.window_id)
        if window is None:
            continue
        meta = metadata_from_options("pane", row.options, expected_owner=row.pane_id)
        if not metadata_owned_by("pane", row.options, row.pane_id):
            # Only legacy managed parents trigger fallback, preventing N+1 on
            # arbitrary unmanaged tmux worlds.
            session_id = row.session_id
            if session_id in legacy_sessions:
                meta = _legacy_exact(tmux, "pane", row.pane_id)
        window.panes.append(_pane_from_row(row, meta))

    inventory = Inventory(sessions=list(sessions_by_id.values()))
    inventory.sessions.sort(key=lambda item: item.id)
    for session in inventory.sessions:
        session.windows.sort(key=lambda item: item.index)
        for window in session.windows:
            window.panes.sort(key=lambda item: item.index)
    return inventory
