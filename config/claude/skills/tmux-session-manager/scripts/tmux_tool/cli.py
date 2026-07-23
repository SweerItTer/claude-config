from __future__ import annotations

import argparse
import sys

from . import __version__
from .config import load_config
from .inventory import build_inventory, lookup_pane_context
from .interaction import Interaction, InteractionError
from .lifecycle import Lifecycle, LifecycleError, Mutation
from .locking import LockError
from .output import (
    compact_line,
    compact_payload,
    dump_json,
    inventory_to_dict,
    render_resolved,
    render_summary,
    render_tree,
    resolved_to_dict,
)
from .protocols.telnet import TelnetError, TelnetHelper
from .resolver import ResolveError, Resolved, find_by_role, resolve_target
from .tmux import TmuxClient, TmuxError
from .validation import positive_finite_float, positive_int, tcp_port


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tmux-tool")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.add_argument("--tmux", default="tmux", help=argparse.SUPPRESS)
    sock = parser.add_mutually_exclusive_group()
    sock.add_argument("--tmux-socket-name", help=argparse.SUPPRESS)
    sock.add_argument("--tmux-socket-path", help=argparse.SUPPRESS)
    parser.add_argument("--tmux-timeout", type=positive_finite_float, default=10.0, help=argparse.SUPPRESS)
    parser.add_argument("--lock-timeout", type=positive_finite_float, default=5.0, help="max seconds to acquire a tmux-tool mutation lock")
    parser.add_argument("--json", action="store_true", help="emit compact JSON only")
    parser.add_argument("--config", help="TOML config path; defaults to ./.tmux-tool.toml when present")
    sub = parser.add_subparsers(dest="action", required=True)

    sub.add_parser("summary", help="compact session/window/pane inventory")
    sub.add_parser("tree", help="readable bounded topology")

    inspect = sub.add_parser("inspect", help="inspect one exact/resolved resource")
    inspect.add_argument("target")

    find = sub.add_parser("find", help="find managed resources by semantic role")
    find.add_argument("--role", required=True)
    find.add_argument("--kind", choices=["session", "window", "pane"])

    session = sub.add_parser("session", help="session lifecycle")
    ssub = session.add_subparsers(dest="operation", required=True)
    sensure = ssub.add_parser("ensure")
    sensure.add_argument("name")
    sensure.add_argument("--role")
    sensure.add_argument("--note")
    sclose = ssub.add_parser("close")
    sclose.add_argument("target")
    sclose.add_argument("--force", action="store_true", help="allow BUSY/unmanaged descendant destruction")

    window = sub.add_parser("window", help="window lifecycle")
    wsub = window.add_subparsers(dest="operation", required=True)
    wensure = wsub.add_parser("ensure")
    wensure.add_argument("session")
    wensure.add_argument("--name", required=True)
    wensure.add_argument("--role")
    wensure.add_argument("--note")
    wclose = wsub.add_parser("close")
    wclose.add_argument("target")
    wclose.add_argument("--force", action="store_true", help="allow BUSY/unmanaged descendant or cascade destruction")

    pane = sub.add_parser("pane", help="pane lifecycle")
    psub = pane.add_subparsers(dest="operation", required=True)
    pensure = psub.add_parser("ensure")
    pensure.add_argument("window")
    pensure.add_argument("--role", required=True)
    pensure.add_argument("--note")
    direction = pensure.add_mutually_exclusive_group()
    direction.add_argument("--right", action="store_true")
    direction.add_argument("--down", action="store_true")
    pclose = psub.add_parser("close")
    pclose.add_argument("target")
    pclose.add_argument("--force", action="store_true", help="allow BUSY or cascading close")

    capture = sub.add_parser("capture", help="bounded pane output")
    capture.add_argument("target")
    capture.add_argument("--lines", type=positive_int, default=40)
    capture.add_argument("--all", action="store_true", dest="all_scrollback")

    input_cmd = sub.add_parser("input", help="paste literal text into pane")
    input_cmd.add_argument("target")
    input_cmd.add_argument("text")
    input_cmd.add_argument("--enter", action="store_true")
    input_cmd.add_argument("--allow-unmanaged", action="store_true", help="unsafe: permit writing to unmanaged pane")

    keys = sub.add_parser("keys", help="send tmux key names")
    keys.add_argument("target")
    keys.add_argument("keys", nargs="+")
    keys.add_argument("--allow-unmanaged", action="store_true", help="unsafe: permit writing to unmanaged pane")

    exec_cmd = sub.add_parser("exec", help="run finite command and wait for real rc")
    exec_cmd.add_argument("target")
    exec_cmd.add_argument("shell_command")
    exec_cmd.add_argument("--timeout", type=positive_finite_float, default=10.0)
    exec_cmd.add_argument("--max-output-lines", type=positive_int, default=40)
    exec_cmd.add_argument("--allow-unmanaged", action="store_true", help="unsafe: permit writing to unmanaged pane")

    start = sub.add_parser("start", help="start long-running/interactive foreground command")
    start.add_argument("target")
    start.add_argument("shell_command")
    start.add_argument("--allow-unmanaged", action="store_true", help="unsafe: permit writing to unmanaged pane")

    wait = sub.add_parser("wait-output", help="wait for new bounded output")
    wait.add_argument("target")
    wait.add_argument("--match")
    wait.add_argument("--timeout", type=positive_finite_float, default=10.0)
    wait.add_argument("--max-lines", type=positive_int, default=40)

    interrupt = sub.add_parser("interrupt", help="send Ctrl-C and verify return to shell")
    interrupt.add_argument("target")
    interrupt.add_argument("--timeout", type=positive_finite_float, default=2.0)
    interrupt.add_argument("--allow-unmanaged", action="store_true", help="unsafe: permit writing to unmanaged pane")

    job = sub.add_parser("job", help="inspect/reconcile managed pane jobs")
    jsub = job.add_subparsers(dest="operation", required=True)
    jstatus = jsub.add_parser("status")
    jstatus.add_argument("target")
    jreconcile = jsub.add_parser("reconcile")
    jreconcile.add_argument("target")
    jreconcile.add_argument("--allow-unmanaged", action="store_true", help="unsafe: reconcile metadata on unmanaged pane")

    telnet = sub.add_parser("telnet", help="telnet protocol helper")
    tsub = telnet.add_subparsers(dest="operation", required=True)
    tconnect = tsub.add_parser("connect")
    tconnect.add_argument("target")
    tconnect.add_argument("--host", required=True)
    tconnect.add_argument("--port", type=tcp_port, default=23)
    tconnect.add_argument("--user", required=True)
    cred = tconnect.add_mutually_exclusive_group()
    cred.add_argument("--password", help="unsafe for non-empty secrets: visible in argv/history; empty string means empty password")
    cred.add_argument("--password-file")
    cred.add_argument("--password-stdin", action="store_true", help="read password from stdin without argv exposure")
    tconnect.add_argument("--prompt-regex")
    tconnect.add_argument("--timeout", type=positive_finite_float, default=12.0)
    tstatus = tsub.add_parser("status")
    tstatus.add_argument("target")
    return parser


def _mutation_output(mutation: Mutation, as_json: bool) -> str:
    payload: dict[str, object] = {"ok": True, "action": mutation.action, mutation.resource_kind: mutation.resource_id}
    if mutation.created is not None:
        payload["created"] = mutation.created
    if mutation.parent_id is not None:
        payload["parent"] = mutation.parent_id
    if mutation.role is not None:
        payload["role"] = mutation.role
    if as_json:
        return dump_json(payload)
    fields = {key: value for key, value in payload.items() if key != "ok"}
    return compact_line("OK", **fields)


def _json_error(status: str, code: str, error: str, **facts: object) -> str:
    return dump_json({"ok": False, "status": status, "code": code, "error": error, "facts": facts})


def _job_payload(result: object) -> dict[str, object]:
    return {
        "ok": True,
        "action": "job",
        "pane": result.pane,
        "present": result.present,
        "job_type": result.job_type,
        "job_token": result.job_token,
        "job_state": result.job_state,
        "rc": result.rc,
        "reconciled": result.reconciled,
        "state": result.state,
        "previous_job_state": result.previous_job_state,
    }


def _read_password_stdin() -> str:
    raw = sys.stdin.read()
    if raw.endswith("\r\n"):
        raw = raw[:-2]
    elif raw.endswith("\n") or raw.endswith("\r"):
        raw = raw[:-1]
    return raw


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    tmux = TmuxClient(
        binary=args.tmux,
        socket_name=args.tmux_socket_name,
        socket_path=args.tmux_socket_path,
        subprocess_timeout=args.tmux_timeout,
    )
    try:
        tmux.ensure_supported_version((3, 2))
        config = load_config(args.config)
        lifecycle = Lifecycle(tmux, config.limits, lock_timeout=args.lock_timeout)
        interaction = Interaction(tmux, lock_timeout=args.lock_timeout)
        telnet_helper = TelnetHelper(tmux, lock_timeout=args.lock_timeout)

        if args.action == "summary":
            inventory = build_inventory(tmux)
            print(dump_json(inventory_to_dict(inventory)) if args.json else render_summary(inventory))
            return 0
        if args.action == "tree":
            inventory = build_inventory(tmux)
            print(dump_json(inventory_to_dict(inventory)) if args.json else render_tree(inventory))
            return 0
        if args.action == "inspect":
            if args.target.startswith("%"):
                context = lookup_pane_context(tmux, args.target)
                if context is None:
                    raise ResolveError("NOT_FOUND", f"pane not found: {args.target}")
                session, window, pane = context
                item = Resolved("pane", session, window, pane)
            else:
                inventory = build_inventory(tmux)
                item = resolve_target(inventory, args.target)
            print(dump_json(resolved_to_dict(item)) if args.json else render_resolved(item))
            return 0
        if args.action == "find":
            inventory = build_inventory(tmux)
            matches = find_by_role(inventory, args.role, args.kind)
            if args.json:
                print(dump_json({"matches": [resolved_to_dict(item) for item in matches]}))
            elif not matches:
                print(compact_line("NONE", role=args.role))
            else:
                for item in matches:
                    print(render_resolved(item))
            return 0
        if args.action == "session":
            mutation = lifecycle.session_ensure(args.name, role=args.role, note=args.note) if args.operation == "ensure" else lifecycle.close(args.target, expected_kind="session", force=args.force)
            print(_mutation_output(mutation, args.json)); return 0
        if args.action == "window":
            mutation = lifecycle.window_ensure(args.session, name=args.name, role=args.role, note=args.note) if args.operation == "ensure" else lifecycle.close(args.target, expected_kind="window", force=args.force)
            print(_mutation_output(mutation, args.json)); return 0
        if args.action == "pane":
            mutation = lifecycle.pane_ensure(args.window, role=args.role, note=args.note, horizontal=not args.down) if args.operation == "ensure" else lifecycle.close(args.target, expected_kind="pane", force=args.force)
            print(_mutation_output(mutation, args.json)); return 0
        if args.action == "capture":
            result = interaction.capture(args.target, lines=args.lines, all_scrollback=args.all_scrollback)
            if args.json:
                print(dump_json({"ok": True, "action": "capture", "pane": result.pane, "lines": result.lines, "truncated": result.truncated, "output": result.text}))
            else:
                print(compact_line("OK", action="capture", pane=result.pane, lines=result.lines, truncated=result.truncated))
                if result.text: print(compact_payload(result.text))
            return 0
        if args.action == "input":
            pane_id = interaction.input(args.target, args.text, enter=args.enter, allow_unmanaged=args.allow_unmanaged)
            print(dump_json({"ok": True, "action": "input", "pane": pane_id}) if args.json else compact_line("OK", action="input", pane=pane_id)); return 0
        if args.action == "keys":
            pane_id = interaction.keys(args.target, args.keys, allow_unmanaged=args.allow_unmanaged)
            print(dump_json({"ok": True, "action": "keys", "pane": pane_id}) if args.json else compact_line("OK", action="keys", pane=pane_id)); return 0
        if args.action == "exec":
            result = interaction.exec(args.target, args.shell_command, timeout=args.timeout, max_output_lines=args.max_output_lines, allow_unmanaged=args.allow_unmanaged)
            if args.json:
                print(dump_json({"ok": True, "action": "exec", "pane": result.pane, "state": result.state, "rc": result.rc, "lines": result.lines, "truncated": result.truncated, "output": result.output}))
            else:
                print(compact_line("OK", action="exec", pane=result.pane, state=result.state, rc=result.rc, lines=result.lines, truncated=result.truncated))
                if result.output: print(compact_payload(result.output))
            return 0
        if args.action == "start":
            result = interaction.start(args.target, args.shell_command, allow_unmanaged=args.allow_unmanaged)
            payload = {"ok": True, "action": "start", "pane": result.pane, "state": result.state, "foreground": result.foreground}
            print(dump_json(payload) if args.json else compact_line("OK", action="start", pane=result.pane, state=result.state, foreground=result.foreground)); return 0
        if args.action == "wait-output":
            result = interaction.wait_output(args.target, match=args.match, timeout=args.timeout, max_lines=args.max_lines)
            if args.json:
                print(dump_json({"ok": True, "action": "wait-output", "pane": result.pane, "matched": result.matched, "lines": result.lines, "truncated": result.truncated, "output": result.text}))
            else:
                print(compact_line("OK", action="wait-output", pane=result.pane, matched=result.matched, lines=result.lines, truncated=result.truncated))
                if result.text: print(compact_payload(result.text))
            return 0
        if args.action == "interrupt":
            result = interaction.interrupt(args.target, timeout=args.timeout, allow_unmanaged=args.allow_unmanaged)
            print(dump_json({"ok": True, "action": "interrupt", "pane": result.pane, "state": result.state}) if args.json else compact_line("OK", action="interrupt", pane=result.pane, state=result.state)); return 0
        if args.action == "job":
            result = interaction.job_status(args.target) if args.operation == "status" else interaction.job_reconcile(args.target, allow_unmanaged=args.allow_unmanaged)
            payload = _job_payload(result)
            print(dump_json(payload) if args.json else compact_line("OK", **{k: v for k, v in payload.items() if k != "ok"})); return 0
        if args.action == "telnet":
            if args.operation == "status":
                result = telnet_helper.status(args.target)
                payload = {"ok": True, "action": "telnet.status", "pane": result.pane, "state": result.state, "peer": result.peer, "current_command": result.current_command, "protocol_state": result.protocol_state, "remote_hint": result.remote_hint, "busy_hint": result.busy_hint, "managed": result.managed}
                print(dump_json(payload) if args.json else compact_line("OK", action="telnet.status", pane=result.pane, state=result.state, peer=result.peer, current_command=result.current_command or "-", protocol_state=result.protocol_state or "-", remote=result.remote_hint, busy=result.busy_hint, managed=result.managed)); return 0
            password = _read_password_stdin() if args.password_stdin else args.password
            kwargs: dict[str, object] = {"host": args.host, "port": args.port, "user": args.user, "password": password, "password_file": args.password_file, "timeout": args.timeout}
            if args.prompt_regex is not None: kwargs["prompt_regex"] = args.prompt_regex
            result = telnet_helper.connect(args.target, **kwargs)
            payload = {"ok": True, "action": "telnet.connect", "pane": result.pane, "state": result.state, "peer": result.peer, "reused": result.reused, "proof_lines": result.proof_lines}
            print(dump_json(payload) if args.json else compact_line("OK", action="telnet.connect", pane=result.pane, state=result.state, peer=result.peer, reused=result.reused, proof=result.proof_lines)); return 0
        raise RuntimeError(f"unhandled parsed action: {args.action}")

    except ResolveError as exc:
        print(_json_error("ERR", exc.code, str(exc), matches=exc.matches) if args.json else compact_line("ERR", code=exc.code, detail=str(exc), matches=",".join(exc.matches) or None)); return 2
    except TelnetError as exc:
        status = "BLOCKED" if exc.blocked else "ERR"
        print(_json_error(status, exc.code, str(exc), **exc.facts) if args.json else compact_line(status, code=exc.code, detail=str(exc), **exc.facts)); return 2
    except InteractionError as exc:
        print(_json_error("ERR", exc.code, str(exc), **exc.facts) if args.json else compact_line("ERR", code=exc.code, detail=str(exc), **exc.facts)); return 2
    except LifecycleError as exc:
        print(_json_error("ERR", exc.code, str(exc), **exc.facts) if args.json else compact_line("ERR", code=exc.code, detail=str(exc), **exc.facts)); return 2
    except LockError as exc:
        print(_json_error("BLOCKED", exc.code, str(exc), **exc.facts) if args.json else compact_line("BLOCKED", code=exc.code, detail=str(exc), **exc.facts)); return 2
    except ValueError as exc:
        print(_json_error("ERR", "CONFIG_ERROR", str(exc)) if args.json else compact_line("ERR", code="CONFIG_ERROR", detail=str(exc))); return 2
    except TmuxError as exc:
        print(_json_error("ERR", exc.code, str(exc)) if args.json else compact_line("ERR", code=exc.code, detail=str(exc))); return 3


if __name__ == "__main__":
    raise SystemExit(main())
