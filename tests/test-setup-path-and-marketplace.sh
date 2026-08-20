#!/usr/bin/env bash
# Regression tests for setup.sh shell PATH persistence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SH="$REPO_ROOT/setup.sh"

bash -n "$SETUP_SH"

fixture="$(mktemp -d)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

mkdir -p "$fixture/repo" "$fixture/home"
cp "$SETUP_SH" "$fixture/repo/setup.sh"
mkdir -p "$fixture/repo/script"
cp "$REPO_ROOT/script/install-common.sh" "$fixture/repo/script/install-common.sh"

mkdir -p \
  "$fixture/repo/claude"

test_path_block_is_idempotent() {
  local profile="$fixture/home/.profile"
  local bashrc="$fixture/home/.bashrc"
  local path_after="$fixture/path-after.txt"
  printf '# existing profile\n' > "$profile"
  printf '# existing bashrc\n' > "$bashrc"

  (
    export HOME="$fixture/home"
    export CLAUDE_CONFIG_DIR="$fixture/home/.claude"
    export SHELL="/bin/bash"
    export PATH="/usr/bin:/bin"
    cd "$fixture/repo"
    # shellcheck source=/dev/null
    source "$fixture/repo/setup.sh"
    ensure_user_local_bin_path
    ensure_user_local_bin_path
    printf '%s\n' "$PATH" > "$path_after"
  )

  python3 - "$profile" "$bashrc" "$path_after" "$fixture/home/.local/bin" <<'PYEOF'
from pathlib import Path
import sys

for path_str in sys.argv[1:3]:
    path = Path(path_str)
    text = path.read_text(encoding='utf-8')
    assert text.count('Claude-Config-Path:START') == 1, (path, text)
    assert '$HOME/.local/bin' in text, (path, text)

path_after = Path(sys.argv[3]).read_text(encoding='utf-8').strip().split(':')
assert path_after[0] == sys.argv[4], path_after
print('PASS: PATH block persisted idempotently and exported now')
PYEOF
}


test_path_block_is_idempotent

echo 'All setup PATH regression tests passed.'
