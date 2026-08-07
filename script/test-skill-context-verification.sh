#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/home/.agents/skills/context-mode-ops"
cat >"$fixture/home/.agents/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "context-mode-ops": {
      "source": "mksglu/context-mode",
      "sourceType": "github",
      "sourceUrl": "https://github.com/mksglu/context-mode.git",
      "skillPath": "skills/context-mode-ops/SKILL.md"
    }
  }
}
EOF
cat >"$fixture/home/.agents/skills/context-mode-ops/SKILL.md" <<'EOF'
---
name: context-mode-ops
description: fixture
---
EOF

cat >"$fixture/bin/npx" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"skills@latest list -g --json"* ]]; then
  printf '%s\n' '[]'
  exit 0
fi
exit 1
EOF
cat >"$fixture/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "plugin list --json" ]]; then
  printf '%s\n' '[]'
  exit 0
fi
exit 1
EOF
chmod +x "$fixture/bin/npx" "$fixture/bin/claude"

mkdir -p "$fixture/repo/configs"
cat >"$fixture/repo/configs/skills.toml" <<'EOF'
[[sources]]
name = "context-mode"
repo = "mksglu/context-mode"
skill = "*"
agent = "claude-code"
scope = "global"
EOF
cat >"$fixture/repo/configs/plugins.toml" <<'EOF'
[[plugins]]
name = "fixture-plugin"
repo = "fixture/repo"
method = "npx"
marketplace = "fixture"
EOF
context="$fixture/context.md"
printf '%s\n' '### Skills' '' '| Skill | Source | Tokens |' '|-------|--------|--------|' '| context-mode-ops | User | < 20 |' >"$context"

source "$REPO_ROOT/setup.sh"
SKILLS_CONFIG="$fixture/repo/configs/skills.toml"
PLUGINS_CONFIG="$fixture/repo/configs/plugins.toml"
PATH="$fixture/bin:$PATH"
HOME="$fixture/home"
CLAUDE_HOME="$fixture/home/.claude"

if ! verify_installed_skills_context "$context" >"$fixture/pass.out" 2>"$fixture/pass.err"; then
  cat "$fixture/pass.out" "$fixture/pass.err" >&2
  echo "FAIL: lock-file fallback should validate npx-installed skill" >&2
  exit 1
fi
grep -Fq "skill 'context-mode-ops' 已安装且在 Claude /context 中可见 (source=context-mode, via=npx)" "$fixture/pass.out"

sed -i '/context-mode-ops/d' "$context"
if verify_installed_skills_context "$context" >"$fixture/fail.out" 2>"$fixture/fail.err"; then
  echo "FAIL: missing context skill should fail" >&2
  exit 1
fi
grep -Fq "skill 'context-mode-ops' 未出现在 Claude -p /context 的 Skills 表" "$fixture/fail.out"

echo "ALL TESTS PASSED"
