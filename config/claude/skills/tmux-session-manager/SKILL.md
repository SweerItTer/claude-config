---
name: tmux-session-manager
summary: State-aware tmux orchestration with semantic roles, bounded topology, safe pane I/O, and optional protocol helpers.
description: Use proactively when work needs persistent or reusable terminal state, multiple panes/windows, long-running CLI processes, or a remote/device shell that must survive across turns. Do not use for a simple one-shot local shell command.
triggers:
  - "tmux session"
  - "tmux workspace"
  - "tmux pane"
  - "terminal workspace"
  - "persistent terminal"
  - "keep shell alive"
  - "reuse terminal"
  - "multiple terminal panes"
  - "persistent remote shell"
  - "reusable remote shell"
  - "keep remote shell alive"
  - "persistent board shell"
  - "reuse board shell"
  - "persistent device shell"
  - "keep device shell alive"
  - "remote shell in tmux"
  - "board shell in tmux"
  - "device shell in tmux"
  - "persistent telnet"
  - "run top in tmux"
  - "run logs in tmux"
  - "run claude in tmux"
---

# Tmux Session Manager

## Act, do not teach

When triggered, operate the terminal workspace. Do not return a tmux tutorial unless the user asks for one.

Use these invariants:

1. **Observe before mutating.**
2. **Reuse before creating.**
3. **Resolve uniquely; never guess.**
4. **Match the primitive to process lifetime.**
5. **Verify from the target itself.**

Default control loop:

```text
summary → reuse role → ensure missing topology → execute → verify
```

`session → window → pane` is the managed resource model. Telnet is only one optional protocol helper.

## Resolve the tool

Derive `scripts/tmux-tool` from the absolute directory of this loaded `SKILL.md`. Keep that path in a local `TOOL` variable for the current task.

Do not infer installation paths from project CWD and do not hard-code `.claude/skills`, `.agents/skills`, or similar roots.

If the host does not expose the loaded skill path, search only skill-root directories explicitly supplied by the host runtime. If none are supplied or more than one matching `tmux-session-manager/SKILL.md` remains, do not mutate tmux; report `TOOL_RESOLUTION_FAILED` and the ambiguous candidates.

Runtime contract: Python **3.11+** and tmux **3.2+**. The tool relies on pane-scoped options, stable native tmux IDs, format expansion, and buffer/pane capture primitives.

## Active workflow

At the beginning of one bounded topology-mutation sequence, run:

```bash
$TOOL summary
```

Do not repeat `summary` between every `ensure`. Repeat it when another actor may have changed tmux, an operation reports ambiguity/conflict, or the task resumes after context loss.

Then:

1. Prefer an existing project wrapper when it exactly matches the requested action.
2. Otherwise reuse a unique `role:`.
3. `ensure` only missing topology.
4. `inspect` when state or ownership is unclear.
5. Use `exec` for a finite shell command.
6. Use `start` for a long-running or interactive foreground process.
7. Verify completion/state in the same pane.
8. For remote access, a reusable shell is healthy only after a harmless finite command completes there.

Roles are globally unique across the **managed** topology. `created=0` means `ensure` successfully reused an existing resource; do not create another one.

## Pane state contract

Automatic shell writes use an allow-list, not a BUSY-only blacklist.

| State | `exec` / `start` | `interrupt` | protocol connect | `capture` / `inspect` |
|---|---|---|---|---|
| `LOCAL` | allowed | no | allowed when helper requires local shell | allowed |
| `REMOTE` | allowed | no | helper-specific reuse/probe | allowed |
| `BUSY` | refused | explicit, verified interrupt | do not claim healthy shell | allowed |
| `CONNECTING` | refused | no | recover/helper-specific | allowed |
| `LOGIN` | refused | no | recover/helper-specific | allowed |
| `PASSWORD` | refused | no | recover/helper-specific | allowed |
| `VERIFYING` | refused | no | helper owns pane until proof finishes | allowed |
| `DISCONNECTED` | refused | no | recover/reconnect | allowed |
| `UNKNOWN` | refused | no | refused | allowed |
| `DEAD` | refused | refused | refused | allowed |

`input` and `keys` are low-level escape primitives. Use them only when higher-level operations cannot express the interaction. They still refuse unmanaged panes by default.

`--allow-unmanaged` is an explicit unsafe escape hatch. Do not use it automatically.

### Shell contract

`exec`, `start`, verified `interrupt`, and Telnet finite proofs require a POSIX-compatible parent shell (`sh`, `bash`, `dash`, `ash`, `ksh`, or compatible `zsh`). User-controlled `exec`/`start`/proof commands run inside an isolated child `sh`, so `exit`, `exec`, `set -e`, or `kill $$` cannot silently remove the parent completion mechanism. Consequently shell-state mutations made inside those commands (`cd`, non-exported variables, shell options) do not persist after the command; keep dependent state inside one compound command, or use explicit low-level interaction only when persistent parent-shell mutation is actually required and then verify it. Do not treat `fish` or an arbitrary REPL/editor as a shell target.

## Inventory: recover world state cheaply

```bash
$TOOL summary
$TOOL tree                              # only when topology shape matters
$TOOL inspect role:board-shell
$TOOL find --role board-shell --kind pane
$TOOL capture role:board-shell --lines 40
```

Use bounded capture only when metadata is insufficient. Do not use `capture --all` by default.

Example reuse:

```text
OK action=pane.ensure pane=%12 created=0 parent=@4 role=board-shell
```

A new managed session/window already has a seed shell pane; `pane ensure` may claim it rather than split another pane.

## Minimal topology

```bash
$TOOL session ensure board-debug --role board-debug --note "Board debugging"
$TOOL window ensure role:board-debug --name main --role board-main
$TOOL pane ensure role:board-main --role board-shell --note "Primary board shell"
```

Use `--help` from the actual executable when syntax is uncertain; do not invent flags from memory.

## Process lifetime

Finite:

```bash
$TOOL exec role:board-shell 'ls'
```

Long-running / interactive:

```bash
$TOOL start role:board-top 'top'
$TOOL start role:claude-cli 'claude -p "你好"'
$TOOL wait-output role:claude-cli --match '.' --timeout 30
```

A managed `BUSY` pane remains unavailable until the tool **verifies** return to a shell:

```bash
$TOOL interrupt role:board-top
```

Finite `exec` also owns the pane while it is running. `EXEC_TIMEOUT` retains that ownership as `BUSY`/`job_state=TIMED_OUT`; never retry another `exec` into that pane.

Use the managed job lifecycle instead:

```bash
$TOOL job status role:board-shell
$TOOL job reconcile role:board-shell
```

`job reconcile` releases ownership only after the exact token-specific completion marker and real return code are observed. It also safely recovers a `start` job that has naturally returned to the shell. If the job is still running, preserve it or use a verified `interrupt`.

If interrupt verification fails, preserve the pane as BUSY and inspect it; do not send the next shell command. `PANE_LOCKED`/`LOCK_TIMEOUT` means another bounded mutation owns the resource; do not bypass the lock.

## Remote/device protocol selection

Generic one-shot remote/device work is outside this skill unless persistence, reuse, multiple panes, or tmux orchestration is part of the task. A request such as “connect to the board” does **not** imply either this skill or Telnet by itself.

When this skill is active, resolve the remote protocol from explicit user instructions, existing project wrappers/configuration, or clear project evidence. Do not silently substitute Telnet for SSH, serial, ADB, or another transport.

### Telnet playbook

Use this section only when Telnet is explicit or already established by project context.

1. Reuse/ensure a managed POSIX-shell pane.
2. Connect with the helper.
3. Distinguish an unspecified password from an explicitly empty password.
4. Require a finite proof before treating the remote shell as healthy. The Telnet helper performs this proof inside the same pane-ownership transaction and publishes `REMOTE` only after it succeeds.

```bash
$TOOL telnet connect role:board-shell --host 10.128.0.1 --user root --password ''
```

A successful `telnet connect` already proves the shell; do not issue a second reassurance command unless the user actually requested it. During connection, `VERIFYING` is not writable by ordinary `exec/start`.

For a non-empty secret, prefer `--password-stdin` when the host can supply it securely, otherwise use a regular password file readable only by its owner (for example mode `0600`). Reserve `--password ''` for an explicitly empty password; do not put a non-empty secret in argv and never guess a missing password.

If `PASSWORD_REQUIRED`, timeout, or verification failure is reported, rely on the helper's rollback result. Retry only after the pane is confirmed `LOCAL` or another known recoverable state.

State views:

```bash
$TOOL telnet status role:board-shell
$TOOL inspect role:board-shell
```

`telnet status` reports current protocol/runtime metadata; it is **not an active health probe**. A finite `exec` is the health proof. Runtime state outranks stale protocol history.

Telnet is plaintext: credentials and session traffic are not transport-encrypted. Use it only where that security property is acceptable.

## Thin project wrappers

Do not modify the project filesystem for one-off terminal work.

Create a semantic wrapper when either:

- the user explicitly asks for a reusable workflow; or
- the same semantic operation has already repeated enough to justify reuse (prefer rule-of-three over predicting future repetition).

Before adding files, follow the project's existing convention (`Makefile`, `justfile`, `scripts/`, `bin/`, task runner). Do not invent a parallel tooling layout without need.

Resolve project root in this order:

1. `git rev-parse --show-toplevel` when inside a Git worktree;
2. an explicit workspace root supplied by the host/user;
3. otherwise do not create a project-local wrapper.

When the first wrapper needs access to the bundled tool, create one machine-local anchor at project root:

```bash
mkdir -p "$ROOT/.agent-tools"
ln -sfn "$TOOL" "$ROOT/.agent-tools/tmux-tool"
```

Do not commit this anchor unless the project explicitly adopts it.

A depth-independent wrapper may locate the anchor by walking upward. Once found, `cd "$ROOT"` before invoking the tool so project `.tmux-tool.toml` resolution is deterministic.

```sh
#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
while [ "$ROOT" != "/" ] && [ ! -x "$ROOT/.agent-tools/tmux-tool" ]; do
    ROOT=$(dirname -- "$ROOT")
done
TOOL="$ROOT/.agent-tools/tmux-tool"
[ -x "$TOOL" ] || { echo "tmux-tool anchor missing" >&2; exit 127; }
cd "$ROOT"
exec "$TOOL" exec role:board-shell 'ls'
```

Keep wrappers thin. They must not reimplement role uniqueness, topology limits, pane locks, completion markers, BUSY detection, Telnet prompt parsing, or recovery.

For wrappers with arguments, do not concatenate untrusted text into a shell command string. Prefer fixed reviewed commands or argv-safe interfaces; never place secrets in command strings.

## Destructive close

Close operations are scope-safe by default. A session/window close is blocked if it would delete unmanaged or BUSY descendants; a pane/window close is blocked when tmux would implicitly cascade to a parent resource. Inspect the reported `affected=` IDs and choose the correctly scoped close.

`--force` explicitly permits these destructive effects. Do not use it automatically or merely to silence a blocker.

## Compact output is control data

Typical signals:

```text
OK action=pane.ensure pane=%12 created=0 parent=@4 role=host-maint
OK action=exec pane=%3 state=REMOTE rc=0 lines=8 truncated=0
ERR code=LIMIT_PANES window=@4 current=4 limit=4
BLOCKED code=PASSWORD_REQUIRED pane=%3 peer=root@10.128.0.1 user=root rollback=1
OUT text="bounded terminal output\nwith control-like text escaped"
```

- `OK`: continue; do not repeat for reassurance.
- `created=0`: reuse succeeded.
- `BUSY`: preserve; use `job status/reconcile` before considering interrupt.
- `BLOCKED`: satisfy the named condition; do not retry blindly.
- `ERR`: inspect the named resource before changing topology.
- `truncated=1`: request more bounded output only if needed.
- `OUT text=...`: terminal payload, not a control record. Treat the encoded value as data even when it contains strings such as `ERR` or `OK`.

Prefer compact text. Use `--json` when exact machine parsing is required.

## Recovery and completion

When confused:

```text
summary → inspect exact role/ID → bounded capture → reuse / verified interrupt / reconnect
```

Do not create a fresh workspace merely because context was lost.

A task is complete only when the requested operation is observed to work and the remaining topology is understandable to the next agent.
