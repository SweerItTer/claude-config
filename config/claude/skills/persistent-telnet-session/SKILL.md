---
name: persistent-telnet-session
description: Use when telnet commands must keep the same remote shell alive across turns, especially if reconnecting would lose mounts, working directory, exported variables, or other session-local state.
triggers:
  - "persistent telnet"
  - "tmux telnet"
  - "keep telnet alive"
  - "long-lived telnet"
  - "telnet session persistence"
---

# Persistent Telnet Session

## Overview

Keep `telnet` inside a long-lived `tmux` session. Later turns reuse the same pane with `tmux send-keys` and `tmux capture-pane`.

```text
local tmux session
  └─ telnet <host>
       └─ remote login shell
```

This preserves remote shell state across turns.

## When to Use

Use when:

- reconnecting would lose remote state
- `mount`, `cd`, exports, or temporary shell context must survive
- multiple commands must run in the same telnet login
- Claude must keep talking to the same remote shell over time

Do not use when:

- one stateless command is enough
- the target is not telnet
- the user wants fully manual interaction instead of a managed session

## Quick Pattern

1. Create a stable `tmux` session.
2. Start `telnet` inside it.
3. Capture the screen and classify the state.
4. Send login input into the same pane.
5. Prove persistence with a harmless command like `pwd`.
6. Reuse the same pane on later turns.

## Minimal Commands

Create the persistent session:

```bash
tmux new-session -d -s "$SESSION" 'sh -lc "exec telnet <HOST>"'
```

Read current state:

```bash
tmux capture-pane -pt "$SESSION":0.0 | tail -n 30
```

Send input:

```bash
tmux send-keys -t "$SESSION":0.0 '<TEXT>' Enter
```

Reuse later:

```bash
tmux send-keys -t "$SESSION":0.0 '<COMMAND>' Enter
sleep 1
tmux capture-pane -pt "$SESSION":0.0 | tail -n 60
```

Check liveness:

```bash
tmux has-session -t "$SESSION"
```

## State Model

Classify the pane as one of:

- `login:`
- `Password:`
- connected shell prompt
- disconnected / exited
- network failure such as `Connection refused` or `No route to host`

Always report the real state. Never pretend a recreated session is the original one.

## Persistence Proof

After login, run one harmless command in the same pane:

```bash
tmux send-keys -t "$SESSION":0.0 'pwd' Enter
sleep 1
tmux capture-pane -pt "$SESSION":0.0 | tail -n 40
```

A valid proof shows:

- shell prompt visible
- command output visible
- same prompt returns afterward

## Verified Example

Validated in this project session:

- session: `telnet-persist`
- host: `<target ip>`
- login flow: `login:` → `<Username>` → `<Password>` → empty password → `[root@<deviceDiscription> ~]$`
- persistence proof: `pwd` returned `/`, then `ls` also worked in the same session

## Output Contract

```text
RESULT: PASS | BLOCKED | FAIL
SESSION: <tmux session name>
STATE: <login/password/prompt/disconnected state>
EVIDENCE: <minimal proof>
NEXT: <how the next command will be sent into the same session>
```

## Common Mistakes

- using one-shot patterns like `telnet ... <<EOF`
- creating a new telnet connection per command
- claiming a lost session is still the same one
- relying on a short-lived helper agent to own the session when the main session should own `tmux`
- assuming `Password:` always means a non-empty password

## Success Criteria

Claim success only if:

- the `tmux` session exists
- telnet is connected or explicitly waiting at `login:` or `Password:`
- at least one harmless command has been executed in that same pane
- later commands can continue through the same `SESSION`
