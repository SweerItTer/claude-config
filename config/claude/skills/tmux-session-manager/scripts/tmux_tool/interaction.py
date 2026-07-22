from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import os
import re
import shlex
import time
import uuid
from typing import Iterator

from .inventory import build_inventory, lookup_pane, option_name
from .locking import pane_lock
from .model import POSIX_SHELL_COMMANDS, Pane, PaneState
from .resolver import ResolveError, resolve_target
from .shellwrap import isolated_job_command
from .tmux import TmuxClient
from .validation import validate_metadata_text


class InteractionError(RuntimeError):
    def __init__(self, code: str, message: str, **facts: object) -> None:
        super().__init__(message)
        self.code = code
        self.facts = facts


@dataclass(slots=True, frozen=True)
class CaptureResult:
    pane: str
    text: str
    lines: int
    truncated: bool


@dataclass(slots=True, frozen=True)
class ExecResult:
    pane: str
    rc: int
    output: str
    lines: int
    truncated: bool
    state: str


@dataclass(slots=True, frozen=True)
class StartResult:
    pane: str
    state: str
    foreground: str | None


@dataclass(slots=True, frozen=True)
class WaitResult:
    pane: str
    matched: bool
    text: str
    lines: int
    truncated: bool


@dataclass(slots=True, frozen=True)
class JobResult:
    pane: str
    present: bool
    job_type: str | None
    job_token: str | None
    job_state: str | None
    rc: int | None
    reconciled: bool
    state: str
    previous_job_state: str | None = None


_AUTO_SHELL_STATES = {PaneState.LOCAL, PaneState.REMOTE}
_JOB_SUFFIXES = (
    "busy", "foreground", "output_marker", "job_type", "job_token", "job_state",
    "job_started_at", "job_completion_marker", "job_result_rc",
)
_PROTOCOL_AND_JOB_SUFFIXES = ("kind", "peer", "protocol_state", "remote", *_JOB_SUFFIXES)


def _full_line_rc_pattern(prefix: str) -> re.Pattern[str]:
    return re.compile(r"(?m)^" + re.escape(prefix) + r"(-?\d+)\r?$")


def _full_line_marker_pattern(marker: str) -> re.Pattern[str]:
    return re.compile(r"(?m)^" + re.escape(marker) + r"\r?$")


class Interaction:
    def __init__(self, tmux: TmuxClient, *, lock_timeout: float = 5.0) -> None:
        self.tmux = tmux
        self.lock_timeout = lock_timeout

    def _pane(self, selector: str) -> Pane:
        if selector.startswith("%"):
            pane = lookup_pane(self.tmux, selector)
            if pane is None:
                raise InteractionError("NOT_FOUND", f"pane not found: {selector}")
            return pane
        inv = build_inventory(self.tmux)
        try:
            item = resolve_target(inv, selector)
        except ResolveError as exc:
            raise InteractionError(exc.code, str(exc), matches=",".join(exc.matches)) from exc
        if item.kind != "pane" or item.pane is None:
            raise InteractionError("TYPE_MISMATCH", "target must resolve to a pane", target=item.id)
        return item.pane

    def _pane_optional(self, pane_id: str) -> Pane | None:
        if not pane_id.startswith("%"):
            return None
        return lookup_pane(self.tmux, pane_id)

    def _unset(self, pane_id: str, suffix: str) -> None:
        self.tmux.unset_user_option("pane", pane_id, option_name("pane", suffix))

    def _reconcile_stale_remote_locked(self, pane: Pane) -> tuple[Pane, bool]:
        """Clear protocol/job hints proven stale by return to the host shell."""
        if pane.current_command not in POSIX_SHELL_COMMANDS or not pane.metadata.remote_hint:
            return pane, False
        for suffix in _PROTOCOL_AND_JOB_SUFFIXES:
            self._unset(pane.id, suffix)
        return self._pane(pane.id), True

    def _set_job(
        self,
        pane_id: str,
        *,
        job_type: str,
        token: str,
        state: str,
        foreground: str | None = None,
        output_marker: str | None = None,
        completion_marker: str | None = None,
    ) -> None:
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "owner"), pane_id)
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "managed"), "1")
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "busy"), "1")
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "job_type"), job_type)
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "job_token"), token)
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "job_state"), state)
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "job_started_at"), f"{time.time():.6f}")
        if foreground is not None:
            self.tmux.set_user_option("pane", pane_id, option_name("pane", "foreground"), foreground)
        if output_marker is not None:
            self.tmux.set_user_option("pane", pane_id, option_name("pane", "output_marker"), output_marker)
        if completion_marker is not None:
            self.tmux.set_user_option("pane", pane_id, option_name("pane", "job_completion_marker"), completion_marker)

    def _set_job_state(self, pane_id: str, state: str) -> None:
        self.tmux.set_user_option("pane", pane_id, option_name("pane", "job_state"), state)

    def _clear_job(self, pane_id: str) -> None:
        for suffix in _JOB_SUFFIXES:
            self._unset(pane_id, suffix)

    def _reconcile_job_locked(self, pane: Pane) -> tuple[Pane, JobResult | None]:
        pane, stale_remote = self._reconcile_stale_remote_locked(pane)
        if stale_remote:
            return pane, JobResult(pane.id, False, None, None, None, None, True, pane.state.value)
        meta = pane.metadata
        if not meta.busy_hint or not meta.job_type or not meta.job_token:
            return pane, None
        prefix = meta.job_completion_marker
        if not prefix:
            return pane, JobResult(pane.id, True, meta.job_type, meta.job_token, meta.job_state, None, False, pane.state.value)

        snapshot = self.tmux.capture_pane(pane.id, lines=1, all_scrollback=True)
        match = _full_line_rc_pattern(prefix).search(snapshot)
        if match is None:
            return pane, JobResult(pane.id, True, meta.job_type, meta.job_token, meta.job_state, None, False, pane.state.value)

        rc = int(match.group(1))
        job_type, job_token, previous_state = meta.job_type, meta.job_token, meta.job_state
        self._clear_job(pane.id)
        refreshed = self._pane(pane.id)
        return refreshed, JobResult(
            refreshed.id, False, job_type, job_token, "DONE", rc, True,
            refreshed.state.value, previous_job_state=previous_state,
        )

    def _require_writeable(
        self,
        pane: Pane,
        *,
        allow_unmanaged: bool,
        allowed_states: set[PaneState] | None = None,
    ) -> None:
        if pane.dead or pane.state is PaneState.DEAD:
            raise InteractionError("PANE_DEAD", "cannot write to dead pane", pane=pane.id)
        if not pane.metadata.managed and not allow_unmanaged:
            raise InteractionError("UNMANAGED_TARGET", "refusing automatic write to unmanaged pane", pane=pane.id)
        if allowed_states is not None and pane.state not in allowed_states:
            code = "PANE_BUSY" if pane.state is PaneState.BUSY else "PANE_STATE_UNSAFE"
            raise InteractionError(
                code,
                "pane state does not permit automatic shell writes",
                pane=pane.id,
                state=pane.state.value,
                fg=pane.metadata.foreground,
                job_type=pane.metadata.job_type,
                job_state=pane.metadata.job_state,
            )

    @contextmanager
    def _locked_pane(
        self,
        selector: str,
        *,
        allow_unmanaged: bool = False,
        allowed_states: set[PaneState] | None = None,
        auto_reconcile: bool = True,
    ) -> Iterator[Pane]:
        initial = self._pane(selector)
        pane_id = initial.id
        with pane_lock(self.tmux.server_identity, pane_id, timeout=self.lock_timeout):
            pane = self._pane(pane_id)
            # Ownership boundary is checked before any reconciliation metadata
            # mutation. --allow-unmanaged is the only explicit escape hatch.
            self._require_writeable(pane, allow_unmanaged=allow_unmanaged, allowed_states=None)
            if auto_reconcile:
                pane, _ = self._reconcile_job_locked(pane)
            else:
                pane, _ = self._reconcile_stale_remote_locked(pane)
            self._require_writeable(pane, allow_unmanaged=allow_unmanaged, allowed_states=allowed_states)
            yield pane

    def capture(self, selector: str, *, lines: int = 40, all_scrollback: bool = False) -> CaptureResult:
        pane = self._pane(selector)
        text = self.tmux.capture_pane(pane.id, lines=lines + 1 if not all_scrollback else lines, all_scrollback=all_scrollback)
        split = text.splitlines()
        truncated = not all_scrollback and len(split) > lines
        if not all_scrollback and truncated:
            split = split[-lines:]
        return CaptureResult(pane.id, "\n".join(split), len(split), truncated)

    def input(self, selector: str, text: str, *, enter: bool = False, allow_unmanaged: bool = False) -> str:
        with self._locked_pane(selector, allow_unmanaged=allow_unmanaged) as pane:
            self.tmux.paste_text(pane.id, text)
            if enter:
                self.tmux.send_keys(pane.id, "Enter")
            return pane.id

    def keys(self, selector: str, keys: list[str], *, allow_unmanaged: bool = False) -> str:
        with self._locked_pane(selector, allow_unmanaged=allow_unmanaged) as pane:
            self.tmux.send_keys(pane.id, *keys)
            return pane.id

    def job_status(self, selector: str) -> JobResult:
        pane = self._pane(selector)
        meta = pane.metadata
        return JobResult(
            pane.id, bool(meta.busy_hint and meta.job_type), meta.job_type, meta.job_token,
            meta.job_state, meta.job_result_rc, False, pane.state.value,
        )

    def job_reconcile(self, selector: str, *, allow_unmanaged: bool = False) -> JobResult:
        initial = self._pane(selector)
        with pane_lock(self.tmux.server_identity, initial.id, timeout=self.lock_timeout):
            pane = self._pane(initial.id)
            self._require_writeable(pane, allow_unmanaged=allow_unmanaged, allowed_states=None)
            refreshed, result = self._reconcile_job_locked(pane)
            if result is None:
                return JobResult(refreshed.id, False, None, None, None, None, False, refreshed.state.value)
            return result

    def exec(
        self,
        selector: str,
        command: str,
        *,
        timeout: float = 10.0,
        max_output_lines: int = 40,
        poll_interval: float = 0.10,
        allow_unmanaged: bool = False,
    ) -> ExecResult:
        token = uuid.uuid4().hex
        start_marker = f"__TMUX_TOOL_START_{token}__"
        done_prefix = f"__TMUX_TOOL_DONE_{token}__="
        marker_pattern = _full_line_rc_pattern(done_prefix)
        wrapped = isolated_job_command(command, start_marker=start_marker, done_prefix=done_prefix)
        deadline = time.monotonic() + timeout
        snapshot = ""
        rc: int | None = None
        saw_start = False
        pane_id = ""

        with self._locked_pane(selector, allow_unmanaged=allow_unmanaged, allowed_states=_AUTO_SHELL_STATES) as pane:
            pane_id = pane.id
            self._set_job(
                pane.id, job_type="exec", token=token, state="RUNNING",
                output_marker=start_marker, completion_marker=done_prefix,
            )
            self.tmux.paste_text(pane.id, wrapped)
            self.tmux.send_keys(pane.id, "Enter")
            while time.monotonic() < deadline:
                snapshot = self.tmux.capture_pane(pane.id, lines=max(max_output_lines + 40, 120))
                match = marker_pattern.search(snapshot)
                if match is not None:
                    rc = int(match.group(1))
                    saw_start = _full_line_marker_pattern(start_marker).search(snapshot) is not None
                    self._clear_job(pane.id)
                    break
                runtime = self._pane_optional(pane.id)
                if runtime is None or runtime.dead:
                    raise InteractionError(
                        "EXEC_SHELL_EXITED",
                        "managed pane/shell disappeared before the completion marker",
                        pane=pane.id,
                        job_type="exec",
                        job_token=token,
                    )
                time.sleep(poll_interval)
            if rc is None:
                self._set_job_state(pane.id, "TIMED_OUT")
                raise InteractionError(
                    "EXEC_TIMEOUT", "completion marker not observed; pane ownership retained",
                    pane=pane.id, timeout=timeout, state="BUSY", job_type="exec", job_token=token,
                )

        done_match = marker_pattern.search(snapshot)
        assert done_match is not None
        if saw_start:
            start_matches = list(_full_line_marker_pattern(start_marker).finditer(snapshot[:done_match.start()]))
            start_pos = start_matches[-1].end() if start_matches else 0
            body = snapshot[start_pos:done_match.start()]
            forced_truncated = not bool(start_matches)
        else:
            body = snapshot[:done_match.start()]
            forced_truncated = True
        output_lines = body.strip("\n").splitlines() if body.strip("\n") else []
        truncated = forced_truncated or len(output_lines) > max_output_lines
        if len(output_lines) > max_output_lines:
            output_lines = output_lines[-max_output_lines:]
        refreshed = self._pane(pane_id)
        return ExecResult(pane_id, rc, "\n".join(output_lines), len(output_lines), truncated, refreshed.state.value)

    def start(self, selector: str, command: str, *, allow_unmanaged: bool = False) -> StartResult:
        try:
            first = shlex.split(command, posix=True)[0]
            foreground = os.path.basename(first)
            if not validate_metadata_text(foreground):
                foreground = None
        except (ValueError, IndexError):
            foreground = None
        job_token = uuid.uuid4().hex
        start_marker = f"__TMUX_TOOL_JOB_START_{job_token}__"
        done_prefix = f"__TMUX_TOOL_JOB_DONE_{job_token}__="
        wrapped = isolated_job_command(command, start_marker=start_marker, done_prefix=done_prefix)
        with self._locked_pane(selector, allow_unmanaged=allow_unmanaged, allowed_states=_AUTO_SHELL_STATES) as pane:
            self._set_job(
                pane.id, job_type="start", token=job_token, state="RUNNING",
                foreground=foreground, output_marker=start_marker, completion_marker=done_prefix,
            )
            self.tmux.paste_text(pane.id, wrapped)
            self.tmux.send_keys(pane.id, "Enter")
            pane_id = pane.id
        refreshed = self._pane(pane_id)
        return StartResult(pane_id, refreshed.state.value, foreground)

    def interrupt(
        self,
        selector: str,
        *,
        timeout: float = 2.0,
        poll_interval: float = 0.10,
        allow_unmanaged: bool = False,
    ) -> StartResult:
        token = uuid.uuid4().hex
        proof_marker = f"__TMUX_TOOL_INTERRUPT_{token}__"
        proof_re = _full_line_marker_pattern(proof_marker)
        proof = f"printf '\\n{proof_marker}\\n'"
        with self._locked_pane(selector, allow_unmanaged=allow_unmanaged, auto_reconcile=True) as pane:
            if pane.state is not PaneState.BUSY:
                raise InteractionError("PANE_NOT_BUSY", "interrupt is reserved for a managed BUSY pane", pane=pane.id, state=pane.state.value)
            self._set_job_state(pane.id, "INTERRUPTING")
            self.tmux.send_keys(pane.id, "C-c")
            self.tmux.paste_text(pane.id, proof)
            self.tmux.send_keys(pane.id, "Enter")
            deadline = time.monotonic() + timeout
            verified = False
            while time.monotonic() < deadline:
                snapshot = self.tmux.capture_pane(pane.id, lines=80)
                if proof_re.search(snapshot):
                    verified = True
                    break
                time.sleep(poll_interval)
            if not verified:
                self._set_job_state(pane.id, "INTERRUPT_PENDING")
                raise InteractionError("INTERRUPT_UNVERIFIED", "Ctrl-C did not prove return to a shell", pane=pane.id, timeout=timeout)
            self._clear_job(pane.id)
            pane_id = pane.id
        refreshed = self._pane(pane_id)
        return StartResult(pane_id, refreshed.state.value, refreshed.metadata.foreground)

    def wait_output(
        self,
        selector: str,
        *,
        match: str | None = None,
        timeout: float = 10.0,
        max_lines: int = 40,
        poll_interval: float = 0.10,
    ) -> WaitResult:
        pane = self._pane(selector)
        before = self.tmux.capture_pane(pane.id, lines=max_lines + 40)
        marker = pane.metadata.output_marker
        deadline = time.monotonic() + timeout
        try:
            pattern = re.compile(match) if match is not None else None
        except re.error as exc:
            raise InteractionError("BAD_REGEX", "invalid wait-output regex", field="match", detail=str(exc)) from exc
        latest = before
        while time.monotonic() < deadline:
            latest = self.tmux.capture_pane(pane.id, lines=max_lines + 40)
            marker_match = _full_line_marker_pattern(marker).search(latest) if marker else None
            marker_source = latest
            if marker and marker_match is None:
                # A high-volume job can push the start marker outside the
                # bounded snapshot before wait-output begins. Search retained
                # tmux history before falling back to snapshot-delta heuristics.
                history = self.tmux.capture_pane(pane.id, lines=1, all_scrollback=True)
                history_match = _full_line_marker_pattern(marker).search(history)
                if history_match is not None:
                    marker_match = history_match
                    marker_source = history
            if marker_match:
                candidate = marker_source[marker_match.end():].lstrip("\r\n")
                ready = bool(candidate) and (pattern.search(candidate) is not None if pattern else True)
            else:
                candidate = latest
                changed = latest != before
                ready = changed and (pattern.search(candidate) is not None if pattern else True)
            if ready:
                lines = candidate.splitlines()
                truncated = len(lines) > max_lines
                if truncated:
                    lines = lines[-max_lines:]
                return WaitResult(pane.id, True, "\n".join(lines), len(lines), truncated)
            time.sleep(poll_interval)
        raise InteractionError("WAIT_TIMEOUT", "no matching new output observed", pane=pane.id, timeout=timeout)
