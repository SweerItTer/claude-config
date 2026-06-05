#!/usr/bin/env bash
# Regression tests for setup.sh dependency bootstrap behavior.
#
# These tests extract only the dependency-checking functions from setup.sh so
# they can simulate PATH/sudo states without running the full installer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="${SCRIPT_DIR}/../setup.sh"

if [[ ! -f "$SETUP_SH" ]]; then
    echo "ERROR: setup.sh not found at $SETUP_SH" >&2
    exit 1
fi

TEST_FILE="$(mktemp /tmp/test-setup-dependencies-XXXXXX.sh)"
trap 'rm -f "$TEST_FILE"' EXIT

python3 - "$SETUP_SH" > "$TEST_FILE" <<'PYEOF'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text(encoding='utf-8')
start = src.index("RED='\\033[0;31m'")
end = src.index('\nsymlink_points_to() {')
print(src[start:end])
PYEOF

cat >> "$TEST_FILE" <<'BASHEOF'

test_non_interactive_sudo_failure_explains_interactive_requirement() {
    DRY_RUN=false
    CI_MODE=false

    if [[ -t 0 ]]; then
        echo "FAIL: this regression test must run without an interactive stdin" >&2
        return 1
    fi

    command() {
        if [[ "${1:-}" == "-v" ]]; then
            case "${2:-}" in
                git)
                    return 1
                    ;;
                apt-get|sudo|curl|tar|python3|node|npm)
                    return 0
                    ;;
            esac
        fi
        builtin command "$@"
    }

    node() {
        case "${1:-}" in
            -p)
                printf '22\n'
                ;;
            --version)
                printf 'v22.0.0\n'
                ;;
            *)
                printf 'unexpected node args: %s\n' "$*" >&2
                return 1
                ;;
        esac
    }

    npm() { printf '10.0.0\n'; }

    sudo() {
        echo "FAIL: sudo should not be invoked when dependency install requires an interactive terminal" >&2
        return 1
    }

    apt-get() {
        echo "FAIL: apt-get should not be invoked without an interactive sudo path" >&2
        return 1
    }

    set +e
    output="$(ensure_system_dependencies 2>&1)"
    rc=$?
    set -e

    printf '%s\n' "$output"

    if [[ $rc -eq 0 ]]; then
        echo "FAIL: dependency check unexpectedly succeeded" >&2
        return 1
    fi

    if printf '%s\n' "$output" | grep -q '^FAIL:'; then
        echo "FAIL: attempted privileged install instead of explaining interactive requirement" >&2
        return 1
    fi

    printf '%s\n' "$output" | grep -q '当前不是交互式终端'
    printf '%s\n' "$output" | grep -q '请在交互式终端执行'
    printf '%s\n' "$output" | grep -q 'sudo apt-get update && sudo apt-get install -y git'
}

test_missing_curl_is_installed_before_node_bootstrap() {
    DRY_RUN=false
    CI_MODE=false
    local apt_log_file
    apt_log_file="$(mktemp /tmp/test-setup-dependencies-apt-XXXXXX.log)"
    trap 'rm -f "$TEST_FILE" "$apt_log_file"' EXIT
    export apt_log_file

    id() {
        if [[ "${1:-}" == "-u" ]]; then
            printf '0\n'
            return 0
        fi
        command id "$@"
    }

    command() {
        if [[ "${1:-}" == "-v" ]]; then
            case "${2:-}" in
                curl|node|npm)
                    return 1
                    ;;
                apt-get|git|tar|python3)
                    return 0
                    ;;
            esac
        fi
        builtin command "$@"
    }

    apt-get() {
        case "${1:-}" in
            update)
                printf ' update' >> "$apt_log_file"
                return 0
                ;;
            install)
                printf ' install:%s' "${*:3}" >> "$apt_log_file"
                return 0
                ;;
        esac
        echo "FAIL: unexpected apt-get args: $*" >&2
        return 1
    }
    export -f apt-get

    install_lts_node_with_nvm() {
        if [[ ! -s "$apt_log_file" ]]; then
            echo "FAIL: attempted Node bootstrap before installing curl" >&2
        fi
        return 1
    }

    set +e
    output="$(ensure_system_dependencies 2>&1)"
    rc=$?
    set -e

    printf '%s\n' "$output"

    if printf '%s\n' "$output" | grep -q '^FAIL:'; then
        echo "FAIL: dependency order is wrong" >&2
        return 1
    fi

    [[ $rc -ne 0 ]]
    grep -q 'install:curl' "$apt_log_file"
}

test_non_interactive_sudo_failure_explains_interactive_requirement
test_missing_curl_is_installed_before_node_bootstrap
BASHEOF

bash "$TEST_FILE"
