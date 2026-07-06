#!/usr/bin/env bash
# Regression tests for setup.sh shell PATH persistence and marketplace repair.
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
  "$fixture/repo/config/claude" \
  "$fixture/repo/external/claude-plugins-official" \
  "$fixture/home/.claude/plugins/marketplaces"

echo '# cpo source' > "$fixture/repo/external/claude-plugins-official/README.md"
echo '# rtk doc' > "$fixture/repo/config/claude/RTK.md"

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

test_marketplace_conflict_is_backed_up_and_replaced() {
  local dst="$fixture/home/.claude/plugins/marketplaces/claude-plugins-official"
  mkdir -p "$dst"
  echo old > "$dst/stale.txt"

  (
    export HOME="$fixture/home"
    export CLAUDE_CONFIG_DIR="$fixture/home/.claude"
    export SHELL="/bin/bash"
    cd "$fixture/repo"
    # shellcheck source=/dev/null
    source "$fixture/repo/setup.sh"
    ensure_marketplace_symlink \
      "$fixture/repo/external/claude-plugins-official" \
      "$dst" \
      "claude-plugins-official marketplace"
  )

  python3 - "$fixture" <<'PYEOF'
from pathlib import Path
import sys

fixture = Path(sys.argv[1])
dst = fixture / 'home/.claude/plugins/marketplaces/claude-plugins-official'
src = fixture / 'repo/external/claude-plugins-official'
assert dst.is_symlink(), dst
assert dst.resolve() == src.resolve(), (dst.resolve(), src.resolve())
backups = list((fixture / 'home/.claude/plugins/marketplaces').glob('claude-plugins-official.backup.*'))
assert backups, 'missing backup dir'
assert (backups[0] / 'stale.txt').is_file(), backups[0]
print('PASS: conflicting marketplace dir backed up and replaced')
PYEOF
}

test_marketplace_backup_name_collision_still_repairs_target() {
  local dst="$fixture/home/.claude/plugins/marketplaces/claude-plugins-official"
  rm -rf "$dst" "$dst".backup.*

  local backup_root="$dst.backup.$(date +%s)"
  mkdir -p "$dst" "$backup_root"
  echo old > "$dst/stale.txt"
  echo keep > "$backup_root/existing.txt"

  (
    export HOME="$fixture/home"
    export CLAUDE_CONFIG_DIR="$fixture/home/.claude"
    export SHELL="/bin/bash"
    cd "$fixture/repo"
    # shellcheck source=/dev/null
    source "$fixture/repo/setup.sh"
    ensure_marketplace_symlink \
      "$fixture/repo/external/claude-plugins-official" \
      "$dst" \
      "claude-plugins-official marketplace"
  )

  python3 - "$fixture" <<'PYEOF'
from pathlib import Path
import sys

fixture = Path(sys.argv[1])
dst = fixture / 'home/.claude/plugins/marketplaces/claude-plugins-official'
src = fixture / 'repo/external/claude-plugins-official'
backups = sorted((fixture / 'home/.claude/plugins/marketplaces').glob('claude-plugins-official.backup.*'))

assert dst.is_symlink(), dst
assert dst.resolve() == src.resolve(), (dst.resolve(), src.resolve())
assert len(backups) >= 2, backups
backup_with_stale = [path for path in backups if (path / 'stale.txt').is_file()]
assert backup_with_stale, backups
print('PASS: marketplace repair survives backup name collision')
PYEOF
}

test_path_block_is_idempotent
test_marketplace_conflict_is_backed_up_and_replaced
test_marketplace_backup_name_collision_still_repairs_target

echo 'All setup PATH/marketplace regression tests passed.'
