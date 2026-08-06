from __future__ import annotations

import shlex


def isolated_job_command(command: str, *, start_marker: str, done_prefix: str) -> str:
    """Build a POSIX-shell wrapper whose completion mechanism outlives USER_COMMAND.

    USER_COMMAND runs in a separate `sh -c` process.  `exit`, `exec`, `set -e`,
    and `kill $$` therefore affect the child command shell rather than the
    managed interactive shell that must publish the token-specific DONE marker.

    The parent uses an OR-list to remain resilient even if its own `errexit`
    option was enabled before tmux-tool was invoked.
    """

    return (
        f"printf '\\n{start_marker}\\n'; "
        "__tmux_tool_rc=0; "
        f"command sh -c {shlex.quote(command)} || __tmux_tool_rc=$?; "
        f"printf '\\n{done_prefix}%d\\n' \"$__tmux_tool_rc\""
    )
