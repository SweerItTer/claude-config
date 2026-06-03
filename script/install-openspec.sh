#!/usr/bin/env bash
# install-openspec.sh — OpenSpec CLI 安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"
ACTION="${ACTION:-install}"

# shellcheck source=./install-common.sh
source "$REPO_ROOT/script/install-common.sh"

OPENSPEC_PACKAGE="@fission-ai/openspec"
OPENSPEC_INIT_ARGS=(--tools claude)
LOCAL_VERSION=""
REMOTE_VERSION=""
INSTALL_REASON=""

extract_semver() {
    python3 - "$1" <<'PY'
import re
import sys

text = sys.argv[1]
match = re.search(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?', text)
if not match:
    raise SystemExit(1)
print(match.group(0))
PY
}

local_openspec_version() {
    command -v openspec >/dev/null 2>&1 || return 1

    local raw
    raw="$(openspec --version 2>&1 | head -1)" || return 1
    extract_semver "$raw"
}

remote_openspec_version() {
    local raw
    raw="$(npm view "$OPENSPEC_PACKAGE" version 2>/dev/null)" || return 1
    extract_semver "$raw"
}

version_gt() {
    python3 - "$1" "$2" <<'PY'
import re
import sys

SEMVER_RE = re.compile(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z.-]+))?'
    r'(?:\+([0-9A-Za-z.-]+))?$'
)


def parse(version: str):
    match = SEMVER_RE.match(version)
    if not match:
        raise SystemExit(2)

    core = tuple(int(match.group(i)) for i in range(1, 4))
    prerelease = match.group(4)
    if prerelease is None:
        return core, None

    identifiers = []
    for identifier in prerelease.split('.'):
        if identifier.isdigit():
            if len(identifier) > 1 and identifier.startswith('0'):
                raise SystemExit(2)
            identifiers.append((0, int(identifier)))
        else:
            identifiers.append((1, identifier))
    return core, identifiers


def compare_prerelease(left, right):
    if left is None and right is None:
        return 0
    if left is None:
        return 1
    if right is None:
        return -1

    for left_part, right_part in zip(left, right):
        if left_part == right_part:
            continue
        if left_part[0] != right_part[0]:
            return 1 if left_part[0] > right_part[0] else -1
        return 1 if left_part[1] > right_part[1] else -1

    if len(left) == len(right):
        return 0
    return 1 if len(left) > len(right) else -1


left_core, left_prerelease = parse(sys.argv[1])
right_core, right_prerelease = parse(sys.argv[2])

if left_core != right_core:
    raise SystemExit(0 if left_core > right_core else 1)

comparison = compare_prerelease(left_prerelease, right_prerelease)
raise SystemExit(0 if comparison > 0 else 1)
PY
}

is_ready() {
    local_openspec_version >/dev/null 2>&1
}

assess_install_requirement() {
    LOCAL_VERSION=""
    REMOTE_VERSION=""
    INSTALL_REASON=""

    if [[ "$FORCE" == true ]]; then
        if LOCAL_VERSION="$(local_openspec_version 2>/dev/null)"; then
            INSTALL_REASON="force-reinstall"
        else
            INSTALL_REASON="force-install"
        fi
        return 0
    fi

    if ! LOCAL_VERSION="$(local_openspec_version 2>/dev/null)"; then
        INSTALL_REASON="missing"
        return 0
    fi

    if ! REMOTE_VERSION="$(remote_openspec_version)"; then
        err "无法获取 OpenSpec 远程版本"
        INSTALL_REASON="remote-query-failed"
        return 20
    fi

    if version_gt "$REMOTE_VERSION" "$LOCAL_VERSION"; then
        INSTALL_REASON="upgrade"
        return 0
    fi

    INSTALL_REASON="up-to-date"
    return 10
}

run_openspec_init() {
    info "初始化 OpenSpec Claude 工具..."
    (
        cd "$HOME"
        openspec init "${OPENSPEC_INIT_ARGS[@]}"
    )
    ok "OpenSpec Claude 工具已初始化"
}

install() {
    case "$INSTALL_REASON" in
        missing)
            info "未检测到 OpenSpec，将执行安装"
            ;;
        upgrade)
            info "检测到 OpenSpec 新版本: $LOCAL_VERSION -> $REMOTE_VERSION"
            ;;
        force-install)
            info "强制安装 OpenSpec"
            ;;
        force-reinstall)
            info "强制重装 OpenSpec: $LOCAL_VERSION"
            ;;
        *)
            info "按官方方式安装 OpenSpec..."
            ;;
    esac

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] npm install -g $OPENSPEC_PACKAGE@latest"
        info "[DRY-RUN] (cd \"$HOME\" && openspec init ${OPENSPEC_INIT_ARGS[*]})"
        return 0
    fi

    npm install -g "$OPENSPEC_PACKAGE@latest"
    run_openspec_init
    ok "OpenSpec 安装完成: $(local_openspec_version)"
}

status() {
    local local_version
    if local_version="$(local_openspec_version 2>/dev/null)"; then
        pass "openspec: $local_version"
        return 0
    fi

    info "openspec: 未安装"
    return 0
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    local local_version
    local_version="$(local_openspec_version 2>/dev/null)" || { err "openspec 命令不存在或版本不可解析"; return 1; }
    ok "OpenSpec verify 通过: $local_version"
}

uninstall() {
    if ! command -v openspec >/dev/null 2>&1; then
        info "OpenSpec 未安装，跳过卸载"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] npm uninstall -g $OPENSPEC_PACKAGE"
        return 0
    fi

    npm uninstall -g "$OPENSPEC_PACKAGE"
    ok "OpenSpec 已卸载"
}

doctor() {
    info "OpenSpec doctor"
    status
}

main() {
    if [[ "$ACTION" == "install" || "$ACTION" == "update" ]]; then
        if assess_install_requirement; then
            run_module_action "$ACTION"
            return 0
        fi

        local assess_status=$?
        case "$assess_status" in
            10)
                pass "OpenSpec 已是最新版本${LOCAL_VERSION:+: $LOCAL_VERSION}"
                verify
                return 0
                ;;
            *)
                return "$assess_status"
                ;;
        esac
    fi

    run_module_action "$ACTION"
}

main "$@"
