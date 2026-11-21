#!/usr/bin/env bash
# Doctor /context smoke wrapper (replaces the old setup.sh
# test-skill-context-verification.sh): verifies doctor.check_context_smoke's
# /context parsing against a fake `claude` binary — empty Skills section and
# missing declared skill both fail; full table passes.
#
# Usage: bash tests/test-launch-context-smoke.sh   (exit 0 = pass)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/home/.claude/skills/grilling"
export HOME="$fixture/home"
export CLAUDE_CONFIG_DIR="$fixture/home/.claude"
export LAUNCH_REPO_ROOT="$REPO_ROOT"

cat > "$fixture/home/.claude/skills/grilling/SKILL.md" <<'EOF'
---
name: grilling
description: fixture
---
EOF

cat > "$fixture/repo-skills.toml" <<'EOF'
[[sources]]
name = "grilling"
repo = "fixture/grilling"
skill = "*"
agent = "claude-code"
scope = "global"
EOF

cat > "$fixture/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-p" && "$2" == "/context" ]]; then
  if [[ -n "${CONTEXT_FAIL:-}" ]]; then
    echo "boom" >&2
    exit 3
  fi
  cat "${CONTEXT_FIXTURE:?}"
  exit 0
fi
exit 0
EOF
chmod +x "$fixture/bin/claude"
export PATH="$fixture/bin:/usr/bin:/bin"
export CONTEXT_FIXTURE="$fixture/context.md"
# skills.toml 位置由 util.repo_root()/configs 决定 → 用 LAUNCH_REPO_ROOT 指到 fixture 仓库。
mkdir -p "$fixture/repo/configs"
cp "$fixture/repo-skills.toml" "$fixture/repo/configs/skills.toml"
export LAUNCH_REPO_ROOT="$fixture/repo"

python3 - <<'PYEOF'
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(os.environ["REPO_ROOT"]) / "script"))

from launch import util, doctor

def expect(cond, label):
    if not cond:
        print(f"  FAIL: {label}")
        sys.exit(1)
    print(f"  PASS: {label}")

table = "### Skills\n| Skill | Source | Tokens |\n|-------|--------|--------|\n| grilling | User | < 20 |\n"

# 1) Skills 表含声明项 → 通过。
Path(os.environ["CONTEXT_FIXTURE"]).write_text("Context\n" + table)
expect(doctor.check_context_smoke() == 0, "声明 skill 出现在 /context Skills 表 → 通过")

# 2) Skills 段为空 → 失败（未注入）。
Path(os.environ["CONTEXT_FIXTURE"]).write_text("Context\n### Skills\n\n### Other\nx\n")
expect(doctor.check_context_smoke() == 1, "Skills 段空 → 失败")

# 3) 声明的 skill 缺席 Skills 表 → 失败。
Path(os.environ["CONTEXT_FIXTURE"]).write_text("Context\n" + table.replace("| grilling ", "| other    "))
expect(doctor.check_context_smoke() == 1, "声明 skill 缺席 → 失败")

# 4) /context 非零退出 → 失败。
Path(os.environ["CONTEXT_FIXTURE"]).write_text("Context\n" + table)
os.environ["CONTEXT_FAIL"] = "1"
rc = doctor.check_context_smoke()
expect(rc not in (0, None) and rc != 0, f"/context 命令失败 → 非零 (rc={rc})")

print("ALL context smoke tests passed.")
PYEOF
