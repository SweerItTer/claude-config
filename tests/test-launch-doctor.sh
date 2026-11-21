#!/usr/bin/env bash
# Doctor module self-check wrapper (replaces the old setup.sh `check` action
# test-claude-check.sh): verifies doctor.check_claude_cli / doctor.run against
# a fake `claude` binary — version/doctor/auth reporting, doctor failure
# propagation, and missing-claude error.
#
# Usage: bash tests/test-launch-doctor.sh   (exit 0 = pass)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/bin"
export HOME="$fixture/home"
export CLAUDE_CONFIG_DIR="$fixture/home/.claude"
export LAUNCH_REPO_ROOT="$REPO_ROOT"

cat > "$fixture/bin/claude" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --version) echo "2.1.207 (Claude Code)" ;;
    doctor)
        if [[ -n "${DOCTOR_EXIT:-}" ]]; then
            echo "Claude Code doctor"
            echo "Installation issues found."
            exit "$DOCTOR_EXIT"
        fi
        echo "Claude Code doctor"
        echo "No installation issues found."
        exit 0
        ;;
    auth)
        if [[ "$2" == "status" ]]; then
            if [[ -n "${AUTH_EXIT:-}" ]]; then
                echo '{"loggedIn": false, "authMethod": null, "apiProvider": null}'
                exit "$AUTH_EXIT"
            fi
            echo '{"loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"}'
            exit 0
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$fixture/bin/claude"
export PATH="$fixture/bin:/usr/bin:/bin"

python3 - <<'PYEOF'
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(os.environ["LAUNCH_REPO_ROOT"]) / "script"))

from launch import util
from launch import doctor

def expect(cond, label):
    if not cond:
        print(f"  FAIL: {label}")
        sys.exit(1)
    print(f"  PASS: {label}")

util.DRY_RUN = True
# 1) 存在的 claude：doctor 全路径 dry-run 无副作用且通过（version/doctor/auth 都只打印）。
expect(doctor.check_claude_cli() == 0, "doctor.check_claude_cli 通过（dry-run 预览）")

# 2) 真实执行（仍走 fixture claude）：doctor 健康 → 通过。
util.DRY_RUN = False
expect(doctor.check_claude_cli() == 0, "claude 健康 → check_claude_cli 通过")

# 3) doctor 失败 → 失败项聚合非零。
os.environ["DOCTOR_EXIT"] = "1"
expect(doctor.check_claude_cli() == 1, "claude doctor 失败 → 非零")
del os.environ["DOCTOR_EXIT"]

# 4) auth 失败：警告但不阻断（返回 0）。
os.environ["AUTH_EXIT"] = "1"
expect(doctor.check_claude_cli() == 0, "auth 失败仅警告，不阻断")
del os.environ["AUTH_EXIT"]

# 5) claude 缺失 → 明确失败。
Path(os.environ["PATH"].split(":")[0], "claude").rename(
    Path(os.environ["PATH"].split(":")[0], "claude.saved"))
expect(doctor.check_claude_cli() == 1, "claude 缺失 → 非零")
Path(os.environ["PATH"].split(":")[0], "claude.saved").rename(
    Path(os.environ["PATH"].split(":")[0], "claude"))

# 6) doctor.run：no_verify=True 直接 0；--smoke-test dry-run 全路径无副作用。
expect(doctor.run(smoke=False, no_verify=True) == 0, "doctor.run --no-verify → 0")
util.DRY_RUN = True
expect(doctor.run(smoke=True, no_verify=False) in (0, 1), "doctor.run dry-run 全路径无副作用")

print("ALL doctor tests passed.")
PYEOF
