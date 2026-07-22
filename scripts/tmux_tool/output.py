from __future__ import annotations

import json
import re
from typing import Any, Mapping

from .model import Inventory, Metadata
from .resolver import Resolved


_SAFE_TOKEN = re.compile(r"^[A-Za-z0-9._:/@%$+#=-]+$")
_SAFE_KEY = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]*$")
_SAFE_PREFIX = re.compile(r"^[A-Z][A-Z0-9_-]*$")


def encode_token(value: str) -> str:
    """Encode one compact-text value without permitting line/token injection."""

    if value and _SAFE_TOKEN.fullmatch(value):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _encode_value(value: object) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return format(value, ".15g")
    return encode_token(str(value))


def compact_line(prefix: str, /, **fields: object) -> str:
    """Serialize one control line.

    Every value is encoded centrally. Call sites must never hand-build OK/ERR/
    BLOCKED/NONE control records because arbitrary runtime/user strings may
    contain whitespace, newlines, or strings that look like new control lines.
    """

    if not _SAFE_PREFIX.fullmatch(prefix):
        raise ValueError(f"invalid compact prefix: {prefix!r}")
    parts = [prefix]
    for key, value in fields.items():
        if value is None:
            continue
        if not _SAFE_KEY.fullmatch(key):
            raise ValueError(f"invalid compact field name: {key!r}")
        parts.append(f"{key}={_encode_value(value)}")
    return " ".join(parts)


def compact_payload(text: str) -> str:
    """Frame arbitrary terminal output as one non-control line."""

    return compact_line("OUT", text=text)


def _meta_dict(meta: Metadata) -> dict[str, Any]:
    return {
        "managed": meta.managed,
        "role": meta.role,
        "note": meta.note,
        "kind": meta.kind,
        "peer": meta.peer,
        "seed": meta.seed,
        "busy_hint": meta.busy_hint,
        "foreground": meta.foreground,
        "remote_hint": meta.remote_hint,
        "protocol_state": meta.protocol_state,
        "output_marker": meta.output_marker,
        "job_type": meta.job_type,
        "job_token": meta.job_token,
        "job_state": meta.job_state,
        "job_started_at": meta.job_started_at,
        "job_completion_marker": meta.job_completion_marker,
        "job_result_rc": meta.job_result_rc,
    }


def _job_dict(meta: Metadata) -> dict[str, Any] | None:
    if not (meta.job_type or meta.job_token or meta.job_state or meta.busy_hint):
        return None
    return {
        "type": meta.job_type,
        "token": meta.job_token,
        "state": meta.job_state,
        "started_at": meta.job_started_at,
        "foreground": meta.foreground,
        "output_marker": meta.output_marker,
        "completion_marker": meta.job_completion_marker,
        "result_rc": meta.job_result_rc,
        "owned": meta.busy_hint,
    }


def _protocol_dict(meta: Metadata) -> dict[str, Any] | None:
    if not (meta.kind or meta.peer or meta.protocol_state or meta.remote_hint):
        return None
    return {
        "type": meta.kind,
        "state": meta.protocol_state,
        "peer": meta.peer,
        "remote": meta.remote_hint,
    }


def _field(key: str, value: object) -> str:
    if not _SAFE_KEY.fullmatch(key):
        raise ValueError(f"invalid compact field name: {key!r}")
    return f"{key}={_encode_value(value)}"


def _meta_tokens(metadata: Metadata, *, include_note: bool = False) -> list[str]:
    tokens: list[str] = []
    if metadata.role:
        tokens.append(_field("role", metadata.role))
    if metadata.kind:
        tokens.append(_field("kind", metadata.kind))
    if metadata.peer:
        tokens.append(_field("peer", metadata.peer))
    if metadata.managed:
        tokens.append("managed=1")
    if include_note and metadata.note:
        tokens.append(_field("note", metadata.note))
    return tokens


def render_summary(inventory: Inventory) -> str:
    lines: list[str] = []
    for session in inventory.sessions:
        pane_count = sum(len(window.panes) for window in session.windows)
        meta = _meta_tokens(session.metadata)
        tokens = ["S", encode_token(session.id), encode_token(session.name), _field("W", len(session.windows)), _field("P", pane_count), *meta]
        lines.append(" ".join(tokens))
        for window in session.windows:
            meta = _meta_tokens(window.metadata)
            tokens = [" W", encode_token(window.id), f"#{window.index}", encode_token(window.name), _field("P", len(window.panes)), *meta]
            lines.append(" ".join(tokens))
            for pane in window.panes:
                tokens = ["  P", encode_token(pane.id), f"#{pane.index}"]
                if pane.metadata.role:
                    tokens.append(encode_token(pane.metadata.role))
                tokens.extend([pane.state.value, _field("cmd", pane.current_command or "-")])
                if pane.metadata.peer:
                    tokens.append(_field("peer", pane.metadata.peer))
                if pane.state.value == "BUSY" and pane.metadata.foreground:
                    tokens.append(_field("fg", pane.metadata.foreground))
                if pane.metadata.job_type:
                    tokens.append(_field("job", pane.metadata.job_type))
                if pane.metadata.job_state:
                    tokens.append(_field("job_state", pane.metadata.job_state))
                if pane.metadata.managed:
                    tokens.append("managed=1")
                lines.append(" ".join(tokens))
    return "\n".join(lines)


def render_tree(inventory: Inventory) -> str:
    blocks: list[str] = []
    for session in inventory.sessions:
        header_tokens = [encode_token(session.id), encode_token(session.name), *_meta_tokens(session.metadata, include_note=True)]
        lines = [" ".join(header_tokens)]
        for w_idx, window in enumerate(session.windows):
            w_last = w_idx == len(session.windows) - 1
            w_branch = "└─" if w_last else "├─"
            w_tokens = [
                encode_token(window.id),
                f"#{window.index}",
                encode_token(window.name),
                *_meta_tokens(window.metadata, include_note=True),
            ]
            lines.append(f"{w_branch} " + " ".join(w_tokens))
            pane_prefix = "   " if w_last else "│  "
            for p_idx, pane in enumerate(window.panes):
                p_last = p_idx == len(window.panes) - 1
                p_branch = "└─" if p_last else "├─"
                p_tokens = [encode_token(pane.id)]
                if pane.metadata.role:
                    p_tokens.append(encode_token(pane.metadata.role))
                p_tokens.extend([pane.state.value, encode_token(pane.current_command or "-")])
                p_tokens.extend(_meta_tokens(pane.metadata, include_note=True)[1 if pane.metadata.role else 0 :])
                if pane.metadata.job_type:
                    p_tokens.append(_field("job", pane.metadata.job_type))
                if pane.metadata.job_state:
                    p_tokens.append(_field("job_state", pane.metadata.job_state))
                lines.append(f"{pane_prefix}{p_branch} " + " ".join(p_tokens))
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def render_resolved(item: Resolved) -> str:
    if item.kind == "session":
        session = item.session
        tokens = ["S", encode_token(session.id), _field("name", session.name), _field("windows", len(session.windows))]
        tokens.extend(_meta_tokens(session.metadata, include_note=True))
        return " ".join(tokens)
    if item.kind == "window":
        assert item.window is not None
        window = item.window
        tokens = [
            "W",
            encode_token(window.id),
            _field("session", item.session.id),
            _field("index", window.index),
            _field("name", window.name),
            _field("panes", len(window.panes)),
        ]
        tokens.extend(_meta_tokens(window.metadata, include_note=True))
        return " ".join(tokens)
    assert item.window is not None and item.pane is not None
    pane = item.pane
    tokens = [
        "P",
        encode_token(pane.id),
        _field("session", item.session.id),
        _field("window", item.window.id),
        _field("index", pane.index),
        _field("state", pane.state.value),
        _field("cmd", pane.current_command or "-"),
    ]
    if pane.pid is not None:
        tokens.append(_field("pid", pane.pid))
    tokens.extend(_meta_tokens(pane.metadata, include_note=True))
    if pane.state.value == "BUSY" and pane.metadata.foreground:
        tokens.append(_field("fg", pane.metadata.foreground))
    if pane.metadata.job_type:
        tokens.append(_field("job", pane.metadata.job_type))
    if pane.metadata.job_token:
        tokens.append(_field("job_token", pane.metadata.job_token))
    if pane.metadata.job_state:
        tokens.append(_field("job_state", pane.metadata.job_state))
    if pane.metadata.job_started_at is not None:
        tokens.append(_field("job_started", pane.metadata.job_started_at))
    return " ".join(tokens)


def inventory_to_dict(inventory: Inventory) -> dict[str, Any]:
    return {
        "sessions": [
            {
                "id": session.id,
                "name": session.name,
                "metadata": _meta_dict(session.metadata),
                "windows": [
                    {
                        "id": window.id,
                        "index": window.index,
                        "name": window.name,
                        "metadata": _meta_dict(window.metadata),
                        "panes": [
                            {
                                "id": pane.id,
                                "index": pane.index,
                                "pid": pane.pid,
                                "current_command": pane.current_command,
                                "dead": pane.dead,
                                "active": pane.active,
                                "state": pane.state.value,
                                "metadata": _meta_dict(pane.metadata),
                            }
                            for pane in window.panes
                        ],
                    }
                    for window in session.windows
                ],
            }
            for session in inventory.sessions
        ]
    }


def resolved_to_dict(item: Resolved) -> dict[str, Any]:
    base: dict[str, Any] = {
        "kind": item.kind,
        "id": item.id,
        "session": item.session.id,
        "session_name": item.session.name,
    }
    if item.kind == "session":
        base.update(
            {
                "windows": len(item.session.windows),
                "metadata": _meta_dict(item.session.metadata),
            }
        )
        return base
    assert item.window is not None
    base.update(
        {
            "window": item.window.id,
            "window_index": item.window.index,
            "window_name": item.window.name,
        }
    )
    if item.kind == "window":
        base.update(
            {
                "panes": len(item.window.panes),
                "metadata": _meta_dict(item.window.metadata),
            }
        )
        return base
    assert item.pane is not None
    base.update(
        {
            "pane": item.pane.id,
            "pane_index": item.pane.index,
            "state": item.pane.state.value,
            "runtime": {
                "current_command": item.pane.current_command,
                "pid": item.pane.pid,
                "dead": item.pane.dead,
                "active": item.pane.active,
            },
            "job": _job_dict(item.pane.metadata),
            "protocol": _protocol_dict(item.pane.metadata),
            "metadata": _meta_dict(item.pane.metadata),
        }
    )
    return base


def dump_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
