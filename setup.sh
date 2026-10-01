#!/usr/bin/env bash
# ============================================================
# Claude Code Config Migration — 一键初始化脚本 v3
# 用法: git clone <repo-url> && ./setup.sh
# ============================================================
set -euo pipefail

# 非 TTY（管道/CI/重定向）或 NO_COLOR 置位时不注入 ANSI 转义，避免日志里全是控制码。
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

# ponytail: 兼容 source — 直接执行用 $0, 被 source 时用 BASH_SOURCE 还原真实路径
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ORIGINAL_ARGS=("$@")
SETUP_UPDATE_REEXECED="${SETUP_UPDATE_REEXECED:-false}"

if [[ "$(id -u)" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$REAL_HOME/.claude}"
    export CLAUDE_CONFIG_DIR="$CLAUDE_HOME"
else
    CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
fi

SCRIPT_DIR="$REPO_ROOT/script"

# --tui fast-path：启动交互式 TUI 安装器。在 source install-common / 参数预解析前
# 拦截，避免触发顶层 engine 初始化。TUI 是独立可执行文件，本脚本只负责定位与 exec。
TUI_REQUESTED=false
TUI_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--tui" ]]; then
        TUI_REQUESTED=true
    else
        TUI_ARGS+=("$arg")
    fi
done
if [[ "$TUI_REQUESTED" == true ]]; then
    TUI_BIN="$REPO_ROOT/build/installer-tui/installer-tui"
    if [[ ! -x "$TUI_BIN" ]]; then
        echo "installer-tui 未构建，请先构建:" >&2
        echo "  cmake -S tools/installer-tui -B build/installer-tui -DCMAKE_BUILD_TYPE=Release && cmake --build build/installer-tui --parallel" >&2
        exit 2
    fi
    exec "$TUI_BIN" --repo-root "$REPO_ROOT" "${TUI_ARGS[@]}"
fi

# shellcheck source=script/install-common.sh
source "$SCRIPT_DIR/install-common.sh"

DRY_RUN=false
CI_MODE=false
NO_CLAUDE=false
NO_VERIFY=false
FORCE=false
SMOKE_TEST=false
VERBOSE=false
YES=false
SETUP_LOG=""
UPDATE=false
UPDATE_SKILL=""
UPDATE_PLUGIN=""
UPDATE_ALL=false
SELECTED_SKILL=""
SELECTED_PLUGIN=""
# 多选：--skill/--plugin 支持重复出现，逐个追加；--skip-* 显式跳过整类。
# 空数组 ≠ 全量（全量 = 无 --skip 且无显式选择时默认装该类别全部）
SELECTED_SKILLS=()
SELECTED_PLUGINS=()
SKIP_SKILLS=false
SKIP_PLUGINS=false
# typed 卸载：--uninstall-skill/--uninstall-plugin 追加 skill:NAME / plugin:NAME，
# 规避同名 skill/plugin 被 uninstall_one 按 skill-first 误分派
UNINSTALL_TYPED_LIST=()
UPDATE_SKILLS=()
UPDATE_LOCAL_SKILLS=()
UPDATE_PLUGINS=()
# 统一资源入口：--update-resource/--uninstall-resource 追加 kind:spec；
# 旧 typed update/uninstall 参数经兼容转换后并入同一列表，走统一 resolver。
# --choose 提供 kind:id=local|remote|skip 冲突选择。
UPDATE_RESOURCES=()
UNINSTALL_RESOURCES=()
RESOURCE_CHOICES=()
ACTION="install"
ACTION_EXPLICIT=false

NVM_INSTALL_VERSION="v0.40.4"
MIN_SUPPORTED_NODE_MAJOR=20
MAX_SUPPORTED_NODE_MAJOR=25

log()   { printf '%s✔ %s%s\n' "$GREEN"  "$*" "$NC"; }
warn()  { printf '%s▲ %s%s\n' "$YELLOW" "$*" "$NC"; }
err()   { printf '%s✖ %s%s\n' "$RED"    "$*" "$NC"; }
# info 默认静默（-v 恢复），但 [DRY-RUN] 前缀的行恒打印：它们来自 script/install-common.sh
# 的未改动 helper，恰好构成预览内容，被静默会让 --dry-run 少一段、预览不再可信。
info()  { if [[ "$VERBOSE" == true || "$*" == *"[DRY-RUN]"* ]]; then printf '%s• %s%s\n' "$BLUE" "$*" "$NC"; fi; return 0; }
phase() { printf '\n%s▸ %s%s\n' "$BLUE" "$*" "$NC"; }
pass()  { [[ "$VERBOSE" == true ]] && printf '%s· %s%s\n' "$BLUE" "$*" "$NC"; return 0; }

# dry-run 分支的打印点恒打印（预览必须可信，不能被 VERBOSE 静默）。
dry()   { printf '%s[dry-run] %s%s\n' "$BLUE" "$*" "$NC"; }

# 失败后给一条可直接粘贴的重试命令，替代无信息量的「请检查上方日志」。
print_retry_hint() {
    local hint="./setup.sh"
    [[ ${#ORIGINAL_ARGS[@]} -gt 0 ]] && hint+=" ${ORIGINAL_ARGS[*]}"
    [[ " $hint " == *" --force "* ]] || hint+=" --force"
    printf '%s重试: %s%s\n' "$YELLOW" "$hint" "$NC"
}

# 裸跑（零参数）时的预执行摘要：先说清要装什么，再问一次。
summarize_install_plan() {
    local skills plugins
    skills="$(parse_skills_toml "$SKILLS_CONFIG" | awk -F'\t' '{print $1}' | paste -sd' ' -)"
    plugins="$(parse_plugins_toml "$PLUGINS_CONFIG" | awk -F'\t' '{print $1}' | paste -sd' ' -)"
    printf '将执行: 核心配置 (CLAUDE.md / rules / settings.json)\n'
    printf '  外部 skill   : %s\n' "${skills:-无}"
    printf '  第三方 plugin: %s\n' "${plugins:-无}"
}

# $1=提示语；默认 Y。非 TTY / --ci / --dry-run / --yes 直接通过（自动化契约不变）。
read_confirm() {
    [[ "$CI_MODE" == true || "$DRY_RUN" == true || "$YES" == true || ! -t 0 ]] && return 0
    local reply
    printf '%s [Y/n] ' "$1"
    IFS= read -r reply || return 0
    case "$reply" in ''|y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' "apt"
    elif command -v dnf >/dev/null 2>&1; then
        printf '%s\n' "dnf"
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' "yum"
    elif command -v brew >/dev/null 2>&1; then
        printf '%s\n' "brew"
    elif command -v pacman >/dev/null 2>&1; then
        printf '%s\n' "pacman"
    else
        printf '%s\n' "unknown"
    fi
}

run_privileged_install() {
    local manual_cmd="$1"
    shift

    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
        return $?
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        err "缺少 sudo，无法自动安装: $manual_cmd"
        return 1
    fi

    if [[ "$CI_MODE" == true || ! -t 0 ]]; then
        warn "安装依赖需要 sudo 权限，但当前不是交互式终端，无法请求密码。"
        warn "请在交互式终端执行: $manual_cmd"
        return 1
    fi

    info "安装依赖需要 sudo 权限，将请求交互式密码输入..."
    if ! sudo -v; then
        err "sudo 授权失败，无法自动安装: $manual_cmd"
        info "请在交互式终端执行: $manual_cmd"
        return 1
    fi

    sudo "$@"
}

run_package_install() {
    local pkg_mgr="$1"
    shift

    if [[ "$DRY_RUN" == true ]]; then
        dry "自动安装依赖: $pkg_mgr -> $*"
        return 0
    fi

    case "$pkg_mgr" in
        apt)
            run_privileged_install \
                "sudo apt-get update && sudo apt-get install -y $*" \
                bash -c 'apt-get update && apt-get install -y "$@"' bash "$@"
            ;;
        dnf)
            run_privileged_install \
                "sudo dnf install -y $*" \
                dnf install -y "$@"
            ;;
        yum)
            run_privileged_install \
                "sudo yum install -y $*" \
                yum install -y "$@"
            ;;
        brew)
            brew install "$@"
            ;;
        pacman)
            run_privileged_install \
                "sudo pacman -S --noconfirm $*" \
                pacman -S --noconfirm "$@"
            ;;
        *)
            err "未识别系统包管理器，无法自动安装: $*"
            return 1
            ;;
    esac
}

node_major_version() {
    command -v node >/dev/null 2>&1 || return 1
    node -p "process.versions.node.split('.')[0]" 2>/dev/null
}

node_runtime_supported() {
    local major
    major="$(node_major_version)" || return 1
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    (( major >= MIN_SUPPORTED_NODE_MAJOR && major <= MAX_SUPPORTED_NODE_MAJOR ))
}

install_lts_node_with_nvm() {
    if [[ "$DRY_RUN" == true ]]; then
        dry "使用 Node 官方推荐脚本安装 nvm (${NVM_INSTALL_VERSION}) 并切换到最新 LTS Node.js（自带 npm）"
        return 0
    fi

    case "$(uname -s)" in
        Linux|Darwin) ;;
        *)
            err "node/npm 自动安装仅支持 Linux/macOS 的官方脚本路径"
            return 1
            ;;
    esac

    local install_cmd="curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh | bash"
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    local version_file
    version_file="$(mktemp)"

    info "使用 Node 官方推荐脚本安装并切换到最新 LTS Node.js（自带 npm）..."
    if ! LTS_VERSION_FILE="$version_file" bash -lc "set -eo pipefail; ${install_cmd}; export NVM_DIR=\"${nvm_dir}\"; . \"${nvm_dir}/nvm.sh\"; nvm install --lts; nvm alias default 'lts/*' >/dev/null; node -p 'process.versions.node' > \"\$LTS_VERSION_FILE\"; node --version; npm --version"; then
        rm -f "$version_file"
        err "nvm / LTS Node.js 安装失败"
        warn "手动: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh | bash && nvm install --lts"
        return 1
    fi

    local selected_version
    selected_version="$(cat "$version_file" 2>/dev/null || true)"
    rm -f "$version_file"
    if [[ ! "$selected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err "无法确定最新 LTS Node.js 版本"
        return 1
    fi

    export NVM_DIR="$nvm_dir"
    local selected_bin="$NVM_DIR/versions/node/v${selected_version}/bin"
    if [[ ! -d "$selected_bin" ]]; then
        err "未找到已安装的 LTS Node.js 目录: $selected_bin"
        return 1
    fi

    case ":$PATH:" in
        *":$selected_bin:"*) ;;
        *) export PATH="$selected_bin:$PATH" ;;
    esac
    hash -r
}

ensure_supported_node_runtime() {
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 && node_runtime_supported; then
        return 0
    fi

    if command -v node >/dev/null 2>&1; then
        local current_major
        current_major="$(node_major_version 2>/dev/null || true)"
        if [[ -n "$current_major" ]]; then
            warn "当前 Node.js 主版本 $current_major 超出兼容范围，切换到最新 LTS..."
        else
            warn "当前 Node.js 版本无法识别，切换到最新 LTS..."
        fi
    else
        warn "缺少 node/npm，安装最新 LTS..."
    fi

    install_lts_node_with_nvm
}

try_install_dep() {
    local dep="$1"
    local pkg_mgr="$2"

    if command -v "$dep" >/dev/null 2>&1; then
        return 0
    fi

    info "尝试安装缺失依赖: $dep"
    case "$dep" in
        git|curl)
            run_package_install "$pkg_mgr" "$dep"
            ;;
        tar)
            if [[ "$pkg_mgr" == "brew" ]]; then
                warn "brew 无法直接补齐 tar 命令，跳过自动安装"
                return 1
            fi
            run_package_install "$pkg_mgr" tar
            ;;
        node|npm)
            ensure_supported_node_runtime
            ;;
        python3)
            case "$pkg_mgr" in
                apt|dnf|yum)
                    run_package_install "$pkg_mgr" python3
                    ;;
                pacman)
                    run_package_install "$pkg_mgr" python
                    ;;
                brew)
                    run_package_install "$pkg_mgr" python
                    ;;
                *)
                    err "未识别系统包管理器，无法自动安装 python3"
                    return 1
                    ;;
            esac
            ;;
        *)
            err "未知依赖，无法自动安装: $dep"
            return 1
            ;;
    esac
}

print_dependency_install_help() {
    local pkg_mgr="$1"
    local missing=("$@")
    missing=("${missing[@]:1}")

    case "$pkg_mgr" in
        apt)
            info "可手动执行: sudo apt-get update && sudo apt-get install -y ${missing[*]}"
            ;;
        dnf)
            info "可手动执行: sudo dnf install -y ${missing[*]}"
            ;;
        yum)
            info "可手动执行: sudo yum install -y ${missing[*]}"
            ;;
        brew)
            info "可手动执行: brew install ${missing[*]}"
            ;;
        pacman)
            info "可手动执行: sudo pacman -S --noconfirm ${missing[*]}"
            ;;
        *)
            info "请手动安装后重试: ${missing[*]}"
            ;;
    esac

    if printf '%s\n' "${missing[@]}" | grep -Eq '^(node|npm)$'; then
        info "node/npm 建议按 Node.js 官方下载页的推荐脚本方式安装最新版（通过 nvm 安装，npm 随 Node 一起提供）"
    fi
}

ensure_system_dependencies() {
    local deps=(git curl tar python3)
    local missing=()
    local dep
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        local pkg_mgr
        pkg_mgr="$(detect_pkg_manager)"
        warn "缺少依赖: ${missing[*]}，尝试自动安装..."
        for dep in "${missing[@]}"; do
            command -v "$dep" >/dev/null 2>&1 && continue
            try_install_dep "$dep" "$pkg_mgr" || true
        done

        if [[ "$DRY_RUN" == true ]]; then
            dry "跳过依赖安装后的就绪复检"
            return 0
        fi

        local still_missing=()
        for dep in "${deps[@]}"; do
            command -v "$dep" >/dev/null 2>&1 || still_missing+=("$dep")
        done
        if [[ ${#still_missing[@]} -gt 0 ]]; then
            err "以下依赖无法自动安装: ${still_missing[*]}"
            print_dependency_install_help "$pkg_mgr" "${still_missing[@]}"
            return 1
        fi
    fi

    if ! ensure_supported_node_runtime; then
        err "node/npm 无法自动安装或切换到兼容的 LTS 版本"
        info "建议重新运行 Node 官方脚本方式安装并切到最新 LTS：nvm install --lts && nvm use --lts"
        return 1
    fi

    log "git, curl, tar, node, npm, python3 已就绪"
}

symlink_points_to() {
    local link="$1"
    local target="$2"
    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

file_has_block() {
    local path="$1"
    local block_name="$2"
    local pattern="<!--[[:space:]]*${block_name}:START[[:space:]]*-->"
    [[ -f "$path" ]] || return 1
    grep -Eq "$pattern" "$path" 2>/dev/null
}

is_valid_claude_md() {
    local claude_md="$1"
    local ccfg_src="$2"

    if symlink_points_to "$claude_md" "$ccfg_src"; then
        return 0
    fi

    if [[ -f "$claude_md" && ! -L "$claude_md" ]] \
        && file_has_block "$claude_md" "Claude-Config" \
        && file_has_block "$claude_md" "OMC"; then
        return 0
    fi

    return 1
}

ensure_managed_block() {
    local src="$1"
    local dst="$2"
    local block_name="$3"
    local label="$4"
    local start_marker end_marker
    # Shell RC files need # comments; <!-- is a redirect in shell syntax.
    if [[ "$dst" == *.md ]]; then
        start_marker="<!-- ${block_name}:START -->"
        end_marker="<!-- ${block_name}:END -->"
    else
        start_marker="# ${block_name}:START"
        end_marker="# ${block_name}:END"
    fi

    [[ -f "$src" ]] || return 0

    if [[ "$DRY_RUN" == true ]]; then
        dry "merge $src into $dst as $block_name block"
        return 0
    fi

    mkdir -p "$(dirname "$dst")"

    if symlink_points_to "$dst" "$src"; then
        rm -f "$dst"
    fi

    MANAGED_BLOCK_SRC="$src" \
    MANAGED_BLOCK_DST="$dst" \
    MANAGED_BLOCK_NAME="$block_name" \
    MANAGED_BLOCK_START="$start_marker" \
    MANAGED_BLOCK_END="$end_marker" \
    MANAGED_BLOCK_HASH_PREFIX="$([[ "$dst" == *.md ]] && echo '<!-- hash:' || echo '# hash:')" \
    MANAGED_BLOCK_HASH_SUFFIX="$([[ "$dst" == *.md ]] && echo ' -->' || echo '')" \
    python3 - <<'PYEOF'
import hashlib
import os
import re
import sys
from pathlib import Path

src = Path(os.environ['MANAGED_BLOCK_SRC'])
dst = Path(os.environ['MANAGED_BLOCK_DST'])
name = os.environ['MANAGED_BLOCK_NAME']
start = os.environ['MANAGED_BLOCK_START']
end = os.environ['MANAGED_BLOCK_END']
hash_prefix = os.environ['MANAGED_BLOCK_HASH_PREFIX']
hash_suffix = os.environ['MANAGED_BLOCK_HASH_SUFFIX']
start_re = re.escape(start)
end_re = re.escape(end)
# Legacy HTML markers may still live in shell RC files from older installs;
# match them so the block is migrated to the new # format.
legacy_start_re = rf'<!--\s*{re.escape(name)}:START\s*-->'
legacy_end_re = rf'<!--\s*{re.escape(name)}:END\s*-->'
hash_re = rf'(?:<!--\s*hash:|#\s*hash:)([0-9a-f]+)\s*(?:-->)?'

raw_source = src.read_text(encoding='utf-8').strip()
inner_pattern = re.compile(rf'(?ms)^\s*(?:{start_re}|{legacy_start_re})\s*\n(.*?)\n(?:{end_re}|{legacy_end_re})\s*$')
match = inner_pattern.match(raw_source)
inner = match.group(1).strip() if match else raw_source
inner = re.sub(rf'^{hash_re}\s*\n', '', inner, count=1).strip()
digest = hashlib.sha256(inner.encode('utf-8')).hexdigest()[:16]
hash_line = f'{hash_prefix}{digest}{hash_suffix}'
source = f'{start}\n{hash_line}\n{inner}\n{end}'

existing = dst.read_text(encoding='utf-8') if dst.exists() else ''
block_pattern = re.compile(rf'(?ms)^\s*(?:{start_re}|{legacy_start_re})\s*\n(.*?)\n(?:{end_re}|{legacy_end_re})[ \t]*\n?')
block_match = block_pattern.search(existing)
if block_match:
    current_hash = re.search(hash_re, block_match.group(1))
    block_is_legacy = legacy_start_re and re.search(legacy_start_re, block_match.group(0))
    if current_hash and current_hash.group(1) == digest and not block_is_legacy:
        sys.exit(0)
    merged = block_pattern.sub(source + '\n', existing, count=1).strip() + '\n'
elif existing.strip():
    merged = existing.rstrip() + '\n\n' + source + '\n'
else:
    merged = source + '\n'

dst.write_text(merged, encoding='utf-8')
PYEOF

    log "$label 已合并"
}

ensure_user_local_bin_path() {
    local snippet tmp target shell_name
    tmp="$(mktemp)"
    cat > "$tmp" <<'EOF'
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac

    local targets=("$HOME/.profile")
    shell_name="$(basename "${SHELL:-}")"
    if [[ "$shell_name" == "bash" || -f "$HOME/.bashrc" ]]; then
        targets+=("$HOME/.bashrc")
    fi
    if [[ "$shell_name" == "zsh" || -f "$HOME/.zshrc" ]]; then
        targets+=("$HOME/.zshrc")
    fi

    local unique_targets=()
    local existing
    for target in "${targets[@]}"; do
        local seen=false
        for existing in "${unique_targets[@]:-}"; do
            if [[ "$existing" == "$target" ]]; then
                seen=true
                break
            fi
        done
        [[ "$seen" == true ]] || unique_targets+=("$target")
    done

    for target in "${unique_targets[@]}"; do
        ensure_managed_block "$tmp" "$target" "Claude-Config-Path" "PATH ~/.local/bin ($(basename "$target"))"
    done
    rm -f "$tmp"
}

ensure_symlink() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if symlink_points_to "$dst" "$src"; then
        log "$label 已就绪"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        if [[ -d "$dst" && ! -L "$dst" && "$FORCE" != true ]]; then
            dry "would fail: $label 目标是已有目录，需 --force 才能替换 ($dst)"
        elif [[ -e "$dst" || -L "$dst" ]]; then
            dry "replace $dst with symlink to $src"
        else
            dry "ln -s $src -> $dst"
        fi
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    if [[ -L "$dst" || -f "$dst" ]]; then
        rm -f "$dst"
    elif [[ -d "$dst" ]]; then
        if [[ "$FORCE" != true ]]; then
            err "$label 目标已存在且是目录: $dst。为避免删除用户维护内容，请先手动处理或使用 --force。"
            warn "先手动处理该路径，或加 --force 强制替换"
            return 1
        fi
        rm -rf "$dst"
    elif [[ -e "$dst" ]]; then
        err "$label 目标已存在且类型不受支持: $dst"
        warn "先手动处理该路径，或加 --force 强制替换"
        return 1
    fi
    ln -s "$src" "$dst"
    log "$label 已更新"
}

# --plugin <name> / --plugin=<name>：单数，装单个 plugin（SELECTED_PLUGIN）。
# 旧复数过滤体系（--plugins / --only-plugin*）已在阶段 2 移除。
preparse_plugin_filter_args() {
  SETUP_FILTERED_ARGS=()

  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    shift

    case "$arg" in
      --plugin) SETUP_FILTERED_ARGS+=("$arg"); SETUP_FILTERED_ARGS+=("$1"); shift ;;
      --plugin=*) SETUP_FILTERED_ARGS+=("$arg") ;;
      --plugins|--only-plugin|--only-plugins)
        echo "[ERR] $arg 已被移除：用 --plugin <name> 装单个 plugin" >&2
        return 1
        ;;
      --plugins=*|--only-plugin=*|--only-plugins=*)
        echo "[ERR] ${arg%%=*} 已被移除：用 --plugin=<name> 装单个 plugin" >&2
        return 1
        ;;
      *)
        SETUP_FILTERED_ARGS+=("$arg")
        ;;
    esac
  done
}

preparse_plugin_filter_args "$@"
set -- "${SETUP_FILTERED_ARGS[@]}"

render_settings_template() {
    local tmpl="$1"
    local content
    content="$(cat "$tmpl")"

    local claude_base_url="${CLAUDE_BASE_URL:-${ANTHROPIC_BASE_URL:-}}"
    local claude_api_key="${CLAUDE_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
    local claude_model="${CLAUDE_MODEL:-${ANTHROPIC_MODEL:-}}"
    local claude_haiku_model="${CLAUDE_HAIKU_MODEL:-${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}}"
    local claude_sonnet_model="${CLAUDE_SONNET_MODEL:-${ANTHROPIC_DEFAULT_SONNET_MODEL:-}}"
    local claude_opus_model="${CLAUDE_OPUS_MODEL:-${ANTHROPIC_DEFAULT_OPUS_MODEL:-}}"

    content="${content//"{{CLAUDE_BASE_URL}}"/$claude_base_url}"
    content="${content//"{{CLAUDE_API_KEY}}"/$claude_api_key}"
    content="${content//"{{CLAUDE_MODEL}}"/$claude_model}"
    content="${content//"{{CLAUDE_HAIKU_MODEL}}"/$claude_haiku_model}"
    content="${content//"{{CLAUDE_SONNET_MODEL}}"/$claude_sonnet_model}"
    content="${content//"{{CLAUDE_OPUS_MODEL}}"/$claude_opus_model}"
    content="${content//"{{REPO_ROOT}}"/$REPO_ROOT}"
    printf '%s\n' "$content"
}

merge_settings_json() {
    local target="$1"
    local rendered_template="$2"

    TARGET_SETTINGS_PATH="$target" RENDERED_TEMPLATE_JSON="$rendered_template" python3 - <<'PYEOF'
import json
import os

PLAYWRIGHT_PLUGIN = 'playwright@claude-plugins-official'
LEGACY_PLUGIN_KEYS = {
    'obra/superpowers@superpowers': 'superpowers@superpowers',
}


def merge_object(dst, src, skip_empty=False, prefer_existing=False):
    base = dict(dst) if isinstance(dst, dict) else {}
    if isinstance(src, dict):
        for key, value in src.items():
            if skip_empty and value == '':
                continue
            if prefer_existing and key in base:
                existing = base[key]
                if isinstance(existing, dict) and isinstance(value, dict):
                    base[key] = merge_object(existing, value, skip_empty=skip_empty, prefer_existing=True)
                continue
            base[key] = value
    return base


def merge_list(existing, template):
    if isinstance(existing, list):
        return list(existing)
    if isinstance(template, list):
        return list(template)
    return []


def merge_missing(existing, template, skip_empty=False):
    if skip_empty and template == '':
        return existing

    if isinstance(existing, dict) and isinstance(template, dict):
        merged = dict(existing)
        for key, value in template.items():
            if skip_empty and value == '':
                continue
            if key in merged:
                merged[key] = merge_missing(merged.get(key), value, skip_empty=skip_empty)
            else:
                merged[key] = merge_missing(None, value, skip_empty=skip_empty)
        return merged

    if isinstance(existing, list):
        return list(existing)
    if isinstance(template, list):
        return list(template)
    if existing is None:
        return template
    return existing


def merge_permissions(existing, template):
    return merge_missing(existing, template)


def migrate_default_disabled_plugins(enabled_plugins):
    return dict(enabled_plugins) if isinstance(enabled_plugins, dict) else {}


path = os.environ['TARGET_SETTINGS_PATH']
rendered_template = os.environ['RENDERED_TEMPLATE_JSON']
with open(path, 'r', encoding='utf-8') as fh:
    current = json.load(fh)
template = json.loads(rendered_template)

current = merge_missing(current, template, skip_empty=True)
current['enabledPlugins'] = migrate_default_disabled_plugins(current.get('enabledPlugins'))
legacy_plugin_keys = {
    'ecc@ecc',
    'affaan-m/everything-claude-code@ecc',
}
for key in legacy_plugin_keys:
    current['enabledPlugins'].pop(key, None)
extra_marketplaces = current.get('extraKnownMarketplaces')
if isinstance(extra_marketplaces, dict):
    extra_marketplaces.pop('ecc', None)
legacy_commands = {'rtk hook claude', 'rtk-rewrite'}
hooks = current.get('hooks')
if isinstance(hooks, dict):
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        cleaned_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('hooks'), list):
                cleaned_groups.append(group)
                continue
            cleaned_hooks = [
                hook for hook in group['hooks']
                if not (isinstance(hook, dict) and hook.get('command') in legacy_commands)
            ]
            if cleaned_hooks:
                updated_group = dict(group)
                updated_group['hooks'] = cleaned_hooks
                cleaned_groups.append(updated_group)
        hooks[event] = cleaned_groups
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(current, fh, indent=4, ensure_ascii=False)
    fh.write('\n')
PYEOF
}

ensure_claude_code() {
    local claude_bootstrap=false

    if [[ "$NO_CLAUDE" == true ]]; then
        info "跳过 Claude Code 安装 (--no-claude)"
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        info "安装 Claude Code..."
        if [[ "$DRY_RUN" == true ]]; then
            dry "npm install -g @anthropic-ai/claude-code"
            return 0
        fi
        npm install -g @anthropic-ai/claude-code
        log "Claude Code 安装完成"
        claude </dev/null >/dev/null 2>&1 &
        info "Claude Code 已在后台启动 (PID $!)"
        return 0
    fi

    log "Claude Code 已安装: $(claude --version 2>&1 | head -1)"
    if [[ ! -d "$CLAUDE_HOME" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            dry "后台启动 Claude Code 初始化 CLAUDE_HOME"
            return 0
        fi
        claude </dev/null >/dev/null 2>&1 &
        info "CLAUDE_HOME 未初始化，已后台启动 Claude Code (PID $!)"
        claude_bootstrap=true
    fi

    if [[ "$claude_bootstrap" == false ]]; then
        pass "Claude Code 已就绪"
    fi
    # ponytail: 后台初始化分支显式返回 0。原 `[[ false ]] && pass` 在 set -e 下
    # 短路为 exit 1，导致 run_install_flow 裸调用 ensure_claude_code 立即退出、
    # Phase 2 永不执行（CI --smoke-test 2ms 后 exit 1 的根因）。
    return 0
}

update_repository() {
    if [[ "$SETUP_UPDATE_REEXECED" == true ]]; then
        pass "仓库更新阶段已完成"
        return 0
    fi

    info "更新当前仓库..."
    if [[ "$DRY_RUN" == true ]]; then
        dry "git pull --ff-only"
        dry "SETUP_UPDATE_REEXECED=true ./setup.sh ${ORIGINAL_ARGS[*]}"
        return 0
    fi

    (
        cd "$REPO_ROOT"
        git pull --ff-only --depth=1
    )

    export SETUP_UPDATE_REEXECED=true
    log "仓库已更新"
    info "重新执行 setup 以加载更新后的脚本..."
    exec "$REPO_ROOT/setup.sh" "${ORIGINAL_ARGS[@]}"
}

# --- 清单驱动安装（npx skills + claude plugin） ---

SKILLS_CONFIG="$REPO_ROOT/configs/skills.toml"
PLUGINS_CONFIG="$REPO_ROOT/configs/plugins.toml"

# 目标 agent：默认 claude-code（完整 claude 流程）。--agents=<非 claude> 时进入"仅 skills"模式：
# 外部（npx skills -a universal -g）与仓库自有（symlink）统一落到 ~/.agents/skills —— 该目录是
# npx skills 的 universal 全局目录，多个 agent（codex/gemini/cursor/…）共享同一份；不使用
# -a '*'（会按各 agent 目录扩散副本），也不为某个 agent 单独适配。claude code / 核心配置 /
# plugins / 验证在非 claude 模式下全部跳过。install_external_skills / update_local_skill
# 据此选择 npx skills 的 -a 参数与 skills 目标目录。
AGENTS_TARGET="claude-code"
AGENTS_SKILLS_HOME="${AGENTS_SKILLS_HOME:-$HOME/.agents/skills}"
# npx skills 全局 lock（记录每个 skill 的安装来源与 skillFolderHash），最新版比对的数据源。
if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    SKILLS_LOCK_FILE="${SKILLS_LOCK_FILE:-$XDG_STATE_HOME/skills/.skill-lock.json}"
else
    SKILLS_LOCK_FILE="${SKILLS_LOCK_FILE:-$HOME/.agents/.skill-lock.json}"
fi

# 清单解析统一入口：Python 解析器输出 TSV（可安全处理值中的 "="）
#   parse-manifests.py skills  --file $SKILLS_CONFIG   → name\trepo\tskill\tagent\tscope\tnote
#   parse-manifests.py plugins --file $PLUGINS_CONFIG  → name\trepo\tmethod\tmarketplace\tcommand\tnote
MANIFEST_PARSER="$REPO_ROOT/script/parse-manifests.py"

# 统一资源计划层：discover → normalize → conflict → select → validate → execute。
# 本地 skill 只发现 repo_root/skills/<name>/SKILL.md；remote 从清单 + wildcard inventory 展开。
RESOURCE_PLANNER="$REPO_ROOT/script/resource-plan.py"

# skill 最新版比对器：读 manifest TSV → 输出逐项安装决定（up-to-date/outdated/missing/unknown）。
SKILL_FRESHNESS_CHECK="$REPO_ROOT/script/check-skill-freshness.py"

# skill lock 合并器：并行安装的 worker 各写独立 lock，收尾时合并回规范 lock。
SKILL_LOCK_MERGER="$REPO_ROOT/script/merge-skill-locks.py"

# 交互读取单行输入；无 TTY 时返回失败（由调用方按非交互规则处理）。
resource_prompt() {
    local prompt_text="$1"
    local reply
    if [[ "$CI_MODE" == true || "$DRY_RUN" == true || ! -t 0 ]]; then
        return 1
    fi
    printf '%s' "$prompt_text"
    IFS= read -r reply || return 1
    [[ -n "$reply" ]] || return 1
    printf '%s\n' "$reply"
}

# 统一发现：对一批资源请求（kind:spec）生成计划 JSON。
# 输出全局变量 _RESOURCE_PLAN（JSON）。有冲突未决时返回 2。
resource_plan_for() {
    local -a reqs=("$@")
    local -a argv=("$RESOURCE_PLANNER" --repo-root "$REPO_ROOT" --format json)
    local req
    for req in "${reqs[@]}"; do
        [[ -n "$req" ]] && argv+=(--request "$req")
    done
    local choice
    for choice in "${RESOURCE_CHOICES[@]:-}"; do
        [[ -n "$choice" ]] && argv+=(--choose "$choice")
    done
    _RESOURCE_PLAN="$(python3 "${argv[@]}")" || {
        local rc=$?
        err "资源计划失败 (exit $rc)"
        [[ "$rc" == 2 ]] && warn "存在未解决的资源冲突；请用 --choose <kind>:<id>=local|remote|skip 指定来源"
        return "$rc"
    }
    return 0
}

# 对未决冲突逐项交互选择 local/remote/skip。
# 交互成功返回 0（_RESOURCE_PLAN 更新）；非交互/放弃返回 2。
# $1=plan JSON；剩余参数为原始资源请求（re-issue 计划用）。
resource_resolve_conflicts() {
    local plan="$1"
    shift
    local -a reqs=("$@")
    local count
    count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["conflicts"]))' "$plan")" || {
        err "无法解析资源计划"; return 2
    }
    [[ "$count" -gt 0 ]] || return 0
    warn "发现 $count 个资源冲突（同一资源同时存在本地与远程候选）"
    if [[ "$CI_MODE" == true || "$DRY_RUN" == true || ! -t 0 ]]; then
        python3 -c 'import json,sys
d=json.loads(sys.argv[1])
for c in d["conflicts"]:
    print(f"[冲突] {c[\"kind\"]}:{c[\"id\"]}")
    for r in c["resources"]:
        where = r["path"] or r["repo"] or "?"
        print(f"  {r[\"source\"]}\t{where}")' "$plan"
        err "非交互环境存在未决冲突；必须用 --choose <kind>:<id>=local|remote|skip 逐项解决"
        return 2
    fi
    local -a choices=()
    while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        local kind="${cid%%:*}" id="${cid#*:}"
        local reply
        reply="$(resource_prompt "选择 ${kind}:${id} 的来源 (local/remote/skip) [skip]: ")" || {
            err "无法读取选择，放弃"; return 2
        }
        case "$reply" in
            local|remote|skip) choices+=("--choose=${kind}:${id}=${reply}") ;;
            *) warn "无效选择 '$reply'，已跳过 ${kind}:${id}" ;;
        esac
    done <<< "$(python3 -c 'import json,sys
for c in json.loads(sys.argv[1])["conflicts"]:
    print(c["kind"]+":"+c["id"])' "$plan")"
    if [[ ${#choices[@]} -gt 0 ]]; then
        local -a args=("$RESOURCE_PLANNER" --repo-root "$REPO_ROOT" --format json)
        local req
        for req in "${reqs[@]}"; do
            [[ -n "$req" ]] && args+=(--request "$req")
        done
        local ch
        for ch in "${choices[@]}"; do
            args+=("$ch")
        done
        _RESOURCE_PLAN="$(python3 "${args[@]}")" || {
            err "选择后资源计划仍失败 (exit $?)"; return 2
        }
    fi
    return 0
}

# 校验已解决的计划：无未决冲突才可执行，返回 0/2。
resource_validate_plan() {
    local plan="$1"
    python3 -c 'import json,sys
d=json.loads(sys.argv[1])
if d["conflicts"]:
    print("仍有未决冲突，不可执行", file=sys.stderr)
    sys.exit(2)
for p in d["plan"]:
    if p["action"] == "skip":
        print("跳过 %s:%s" % (p["kind"], p["id"]))' "$plan" || return 2
    return 0
}

# 计划中 selected 的 remote 项 exec 键（source alias / plugin 名），每行 kind\tname。
plan_selected_remote() {
    local plan="$1"
    python3 -c 'import json,sys
d=json.loads(sys.argv[1])
for s in d["selected"]:
    if s["source"]=="remote":
        print(s["kind"]+"\t"+s["name"])' "$plan"
}

# 计划中 selected 的 local skill 目录名（= canonical id）。
plan_selected_local_skills() {
    local plan="$1"
    python3 -c 'import json,sys
d=json.loads(sys.argv[1])
for s in d["selected"]:
    if s["kind"]=="skill" and s["source"]=="local":
        print(s["id"])' "$plan"
}

# 统一更新入口：对 UPDATE_RESOURCES 生成计划并执行。
resource_update() {
    [[ ${#UPDATE_RESOURCES[@]} -gt 0 ]] || return 0
    phase "Phase 0: 更新指定资源"
    local rc=0
    resource_plan_for "${UPDATE_RESOURCES[@]}" || {
        rc=$?
        if [[ "$rc" == 2 ]]; then
            resource_resolve_conflicts "$_RESOURCE_PLAN" "${UPDATE_RESOURCES[@]}" || return 2
        else
            return "$rc"
        fi
    }
    resource_validate_plan "$_RESOURCE_PLAN" || return 2
    local kind name
    while IFS=$'\t' read -r kind name; do
        [[ -n "$kind" ]] || continue
        case "$kind" in
            skill) update_skill "$name" || rc=1 ;;
            plugin) update_plugin "$name" || rc=1 ;;
        esac
    done <<< "$(plan_selected_remote "$_RESOURCE_PLAN")"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        update_local_skill "$name" || rc=1
    done <<< "$(plan_selected_local_skills "$_RESOURCE_PLAN")"
    if [[ "$rc" == 0 ]]; then
        log "指定资源更新完成"
    else
        err "部分资源更新失败"; print_retry_hint
    fi
    return "$rc"
}

# 统一卸载入口：对 UNINSTALL_RESOURCES 生成计划并执行。
# local skill 卸载只移除 ~/.claude/skills 下的受控软链接，不触碰仓库源文件。
resource_uninstall() {
    [[ ${#UNINSTALL_RESOURCES[@]} -gt 0 ]] || return 0
    local rc=0
    resource_plan_for "${UNINSTALL_RESOURCES[@]}" || {
        rc=$?
        if [[ "$rc" == 2 ]]; then
            resource_resolve_conflicts "$_RESOURCE_PLAN" "${UNINSTALL_RESOURCES[@]}" || return 2
        else
            return "$rc"
        fi
    }
    resource_validate_plan "$_RESOURCE_PLAN" || return 2
    local kind name
    while IFS=$'\t' read -r kind name; do
        [[ -n "$kind" ]] || continue
        case "$kind" in
            skill) uninstall_skill "$name" || rc=1 ;;
            plugin) uninstall_plugin "$name" || rc=1 ;;
        esac
    done <<< "$(plan_selected_remote "$_RESOURCE_PLAN")"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        uninstall_local_skill "$name" || rc=1
    done <<< "$(plan_selected_local_skills "$_RESOURCE_PLAN")"
    if [[ "$rc" == 0 ]]; then
        log "指定资源卸载完成"
    else
        err "部分资源卸载失败"; print_retry_hint
    fi
    return "$rc"
}

# 卸载仓库自有 skill：只移除 CLAUDE_HOME/skills/<name> 下指向本仓库的软链接。
uninstall_local_skill() {
    local name="${1:?缺少本地 skill 名}"
    local src="$REPO_ROOT/skills/$name"
    local dst="$CLAUDE_HOME/skills/$name"
    if [[ ! -L "$dst" && ! -e "$dst" ]]; then
        warn "本地 skill 未安装，跳过: $name"
        return 0
    fi
    remove_symlink_if_ours "$dst" "repo skill '$name'" "$src"
    log "本地 skill '$name' 已卸载"
}

parse_skills_toml() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    python3 "$MANIFEST_PARSER" skills --file "$file"
}

parse_plugins_toml() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    # --tsv-safe: 空字段（如 npx 插件的 marketplace）输出 <nil> 占位，
    # 否则 bash IFS=$'\t' 会折叠连续 tab 把 command 列错位成 note。
    python3 "$MANIFEST_PARSER" plugins --tsv-safe --file "$file"
}

# 检查名字是否在 skills.toml 中
manifest_has_skill() {
    local name="${1:?缺少 skill 名}"
    [[ -f "$SKILLS_CONFIG" ]] || return 1
    [[ -n "$(parse_skills_toml "$SKILLS_CONFIG" | awk -F'\t' -v n="$name" '$1 == n { print $1 }')" ]]
}

# 检查名字是否在 plugins.toml 中
manifest_has_plugin() {
    local name="${1:?缺少 plugin 名}"
    [[ -f "$PLUGINS_CONFIG" ]] || return 1
    [[ -n "$(parse_plugins_toml "$PLUGINS_CONFIG" | awk -F'\t' -v n="$name" '$1 == n { print $1 }')" ]]
}

# 判断名字是否命中一组 filters（空 filters 视为命中全部）
filter_matches() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# --agents 是否 claude 目标（缺省、claude、claude-code）。其余取值 = 只装 skills 模式。
agents_is_claude() {
    [[ "$AGENTS_TARGET" == "claude" || "$AGENTS_TARGET" == "claude-code" ]]
}

# npx skills 的 -a 取值：claude 目标用自身 key；非 claude 统一 universal
# （universal 的全局目录就是 ~/.agents/skills，各 agent 共享同一份，不扩散副本）。
skills_agent_key() {
    if agents_is_claude; then
        printf '%s\n' "$AGENTS_TARGET"
    else
        printf '%s\n' "universal"
    fi
}

# skills 安装目录：claude 目标 = ~/.claude/skills；非 claude = ~/.agents/skills。
skills_target_dir() {
    if agents_is_claude; then
        printf '%s\n' "$CLAUDE_HOME/skills"
    else
        printf '%s\n' "$AGENTS_SKILLS_HOME"
    fi
}

# 并行 worker：安装一个 skill 组（同仓库 + 同 scope 的多个 skill 合并为一次 npx skills add，
# 一次 clone、一次 lock 写入）。每个 worker 用独立 XDG_STATE_HOME：npx skills 的全局 lock 是
# "读-改-写"且无文件锁，多个 add 并行写同一 lock 会互相覆盖丢条目（实测 4 个并行只剩 3 条），
# 而丢条目的 skill 会被下次最新版比对判成"未安装"反复重装。故各写各的 lock，结束后统一合并。
# 参数：repo scope skills(空格分隔) agent_key 工作目录 组标签(空格分隔的 source 名)
install_skill_group() {
    local repo="$1" scope="$2" skills="$3" agent_key="$4" wdir="$5" label="$6"
    mkdir -p "$wdir"

    local -a skill_list=()
    IFS=' ' read -r -a skill_list <<< "$skills"

    local -a args=(add -y "$repo")
    local s
    for s in "${skill_list[@]}"; do
        args+=(-s "$s")
    done
    args+=(-a "$agent_key")
    [[ "$scope" == "global" ]] && args+=(-g)

    # add 后必须再传 -y：第一个 -y 是 npx 的（自动确认下载包），add -y 才是 skills CLI 的
    #（跳过 "Proceed with installation?" 交互确认）。缺 add -y 时，非 agent 环境
    #（无 AI_AGENT/CLAUDE_* env 且无 TTY，如 cron/CI/普通 shell）skills CLI 会卡在确认提示
    # 不真正安装。update/remove 已带 -y，仅 add 有此问题。
    # 输出落 log 文件：并行时若直接写 stdout，多个 worker 的进度框会互相撕裂。
    if ! XDG_STATE_HOME="$wdir/state" npx -y skills@latest "${args[@]}" </dev/null \
            >"$wdir/out.log" 2>&1; then
        return 1
    fi

    local -a name_list=()
    IFS=' ' read -r -a name_list <<< "$label"
    local n
    for n in "${name_list[@]}"; do
        log "skill '$n' 已安装"
    done >"$wdir/result"
    return 0
}

# 安装外部 skills（读 skills.toml → npx skills add）
# 参数：0 个或多个 name 过滤。无参 = 装全部；有参 = 只装命中的 name。
# 已安装且与远端最新版一致（lock 的 skillFolderHash == 远端 tree oid）的项跳过安装；
# 不存在的、有更新的、比对不了的（离线/限流/非 GitHub 源）照常安装，不因查不到而误跳过。
# 需要安装的项按 仓库+scope 分组后并发执行（默认 SKILLS_INSTALL_JOBS=3），避免逐条串行堵塞。
install_external_skills() {
    local -a filters=("$@")
    [[ -f "$SKILLS_CONFIG" ]] || { info "无 skills.toml，跳过外部 skill"; return 0; }

    local parsed
    parsed="$(parse_skills_toml "$SKILLS_CONFIG")" || {
        err "解析 skills.toml 失败"
        return 1
    }

    local target_dir agent_key
    target_dir="$(skills_target_dir)"
    agent_key="$(skills_agent_key)"

    local -a plan_args=(--target-dir "$target_dir" --lock-file "$SKILLS_LOCK_FILE")
    if [[ "$FORCE" == true ]]; then
        plan_args+=(--force)
    fi
    plan_args+=("${filters[@]}")

    local plan
    plan="$(printf '%s\n' "$parsed" | python3 "$SKILL_FRESHNESS_CHECK" "${plan_args[@]}")" || {
        err "生成 skill 安装计划失败"
        return 1
    }

    # 汇报比对结论，并把"需要安装"的项收集为 name/repo/skill/scope 四列
    local name repo skill manifest_agent scope status detail
    local -a pending=()
    # 幂等跳过合并为一行汇报：逐项一行在重跑时占满屏幕，且与 Phase 5 验证重复。
    local -a skipped_names=()
    while IFS=$'\t' read -r name repo skill manifest_agent scope status detail; do
        [[ -n "$name" ]] || continue

        case "$status" in
            up-to-date)
                skipped_names+=("$name")
                pass "skill '$name' 已安装且为最新版，跳过 (hash $detail)"
                continue ;;
            outdated)
                pass "skill '$name' 有新版本，重新安装 ($detail)" ;;
            missing)
                pass "skill '$name' 未安装，开始安装 ($detail)" ;;
            *)
                warn "skill '$name' 无法比对远端版本（$detail），按需安装" ;;
        esac

        # 兜底：外部 skill 只装到当前目标 agent 目录。npx skills 不带 -a 时会按已检测到的
        # agent 扩散安装，-a '*' 更是装到所有 agent 目录，因此清单里的 agent 字段只作提示，
        # 实际透传的恒为 $agent_key。
        if agents_is_claude && [[ -n "$manifest_agent" && "$manifest_agent" != "$agent_key" ]]; then
            warn "source '$name' 的 agent='$manifest_agent' 非 $agent_key，已按 $agent_key 安装"
        fi

        pending+=("$name"$'\t'"$repo"$'\t'"$skill"$'\t'"$scope")
    done <<< "$plan"

    if [[ ${#skipped_names[@]} -gt 0 ]]; then
        log "已是最新，跳过 ${#skipped_names[@]} 个 skill: ${skipped_names[*]}"
    fi

    [[ ${#pending[@]} -gt 0 ]] || return 0

    # 同一 skill 名被不同仓库重复声明时只保留首个：remote skill 的 identity 就是真实 skill 名
    # (resource-plan.py: id=skill)，同名并发写同一目标目录是数据竞争。wildcard 身份是 source
    # alias，不参与去重。
    local -a deduped=()
    local claimed="" entry e_name e_repo e_skill e_scope
    for entry in "${pending[@]}"; do
        IFS=$'\t' read -r e_name e_repo e_skill e_scope <<< "$entry"
        if [[ "$e_skill" != "*" && "$claimed" == *"|$e_skill|"* ]]; then
            warn "skill '$e_skill' 已被其它 source 声明，跳过 '$e_name'（同名并发安装会互相覆盖）"
            continue
        fi
        [[ "$e_skill" != "*" ]] && claimed+="|$e_skill|"
        deduped+=("$entry")
    done

    [[ ${#deduped[@]} -gt 0 ]] || return 0

    # 分组：repo+scope 相同 → 一次 add（一次 clone、一次 lock 写入），组间并发。
    local grouped
    grouped="$(printf '%s\n' "${deduped[@]}" | awk -F'\t' '
        {
            key = $2 "\t" $4
            if (!(key in order_seen)) { order_seen[key] = 1; order[++n] = key }
            if ($3 == "*") star[key] = 1
            else if (index("|" sk[key] "|", "|" $3 "|") == 0) {
                sk[key] = (sk[key] == "" ? $3 : sk[key] " " $3)
            }
            nm[key] = (nm[key] == "" ? $1 : nm[key] " " $1)
        }
        END {
            for (i = 1; i <= n; i++) {
                key = order[i]
                print key "\t" (key in star ? "*" : sk[key]) "\t" nm[key]
            }
        }
    ')" || { err "分组 skill 安装计划失败"; return 1; }

    local jobs="${SKILLS_INSTALL_JOBS:-3}"
    local work
    work="$(mktemp -d)"
    local -a pids=() pdirs=()
    local rc=0 gidx=0
    local grepo gscope gskills gnames

    while IFS=$'\t' read -r grepo gscope gskills gnames; do
        [[ -n "$grepo" ]] || continue
        [[ -n "$gskills" ]] || continue

        local -a skill_list=()
        IFS=' ' read -r -a skill_list <<< "$gskills"

        if [[ "$DRY_RUN" == true ]]; then
            local scope_flag=""
            [[ "$gscope" == "global" ]] && scope_flag="-g"
            local g
            for g in "${skill_list[@]}"; do
                dry "npx -y skills@latest add -y $grepo -s $g -a $agent_key $scope_flag"
            done
            dry "skill 已安装: $gnames"
            continue
        fi

        gidx=$((gidx + 1))
        local wdir="$work/g$gidx"
        printf '%s\n' "$gnames" >"$wdir.label"

        # 满槽时等最老的作业完成再放新作业（有限并发）
        while ((${#pids[@]} >= jobs)); do
            if ! wait "${pids[0]}"; then
                rc=1
                err "外部 skill 安装失败: $(<"${pdirs[0]}.label")"
                sed -n '1,40p' "${pdirs[0]}/out.log" 2>/dev/null || true
            else
                cat "${pdirs[0]}/result" 2>/dev/null || true
            fi
            pids=("${pids[@]:1}")
            pdirs=("${pdirs[@]:1}")
        done

        install_skill_group "$grepo" "$gscope" "$gskills" "$agent_key" "$wdir" "$gnames" &
        pids+=("$!")
        pdirs+=("$wdir")
    done <<< "$grouped"

    # 收尾：等全部剩余作业，逐组汇报（按批次顺序，输出不交错）
    local i
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            rc=1
            err "外部 skill 安装失败: $(<"${pdirs[$i]}.label")"
            sed -n '1,40p' "${pdirs[$i]}/out.log" 2>/dev/null || true
        else
            cat "${pdirs[$i]}/result" 2>/dev/null || true
        fi
    done

    # 把各 worker 的独立 lock 合并回规范 lock（否则丢失的条目会让 skill 反复重装）
    if [[ "$DRY_RUN" != true && "$gidx" -gt 0 ]]; then
        local -a worker_locks=()
        local lock_file
        for lock_file in "$work"/g*/state/skills/.skill-lock.json; do
            [[ -f "$lock_file" ]] && worker_locks+=("$lock_file")
        done
        if [[ ${#worker_locks[@]} -gt 0 ]]; then
            if ! python3 "$SKILL_LOCK_MERGER" --target "$SKILLS_LOCK_FILE" \
                    "${worker_locks[@]}" >/dev/null; then
                err "合并 skill lock 失败: $SKILL_LOCK_FILE"
                warn "删除该文件后重跑可重建: rm -f $SKILL_LOCK_FILE"
                rc=1
            fi
        fi
    fi

    rm -rf "$work"
    return "$rc"
}

# 安装第三方 plugins（读 plugins.toml → claude plugin install）
# 参数：0 个或多个 name 过滤。无参 = 装全部；有参 = 只装命中的 name。
install_third_party_plugins() {
    local -a filters=("$@")
    [[ -f "$PLUGINS_CONFIG" ]] || { info "无 plugins.toml，跳过第三方 plugin"; return 0; }

    local parsed
    parsed="$(parse_plugins_toml "$PLUGINS_CONFIG")" || {
        err "解析 plugins.toml 失败"
        return 1
    }
    local line name repo method marketplace command note
    while IFS=$'\t' read -r name repo method marketplace command note; do
        [[ -n "$name" ]] || continue
        if [[ ${#filters[@]} -gt 0 ]] && ! filter_matches "$name" "${filters[@]}"; then
            continue
        fi

        case "$method" in
            claude-plugin)
                if [[ "$DRY_RUN" == true ]]; then
                    dry "安装 plugin: $name (marketplace: $marketplace)"
                    dry "claude plugin marketplace add $repo --scope user && claude plugin install ${name}@${marketplace} -s user"
                    dry "plugin '$name' 已安装"
                    continue
                fi
                pass "安装 plugin: $name (marketplace: $marketplace)"
                claude plugin marketplace add "$repo" --scope user 2>/dev/null || \
                    warn "marketplace 添加失败（可能已存在）: $name"
                if ! claude plugin install "${name}@${marketplace}" -s user; then
                    err "安装 plugin '$name' 失败"
                    return 1
                fi
                log "plugin '$name' 已安装"
                ;;
            npx)
                warn "需手动安装 plugin '$name': $command"
                ;;
            *)
                warn "未知安装方式 '$method'，跳过 plugin '$name'"
                ;;
        esac
    done <<< "$parsed"
}

# 更新所有外部 skills（npx skills update）
update_all_skills() {
    [[ -f "$SKILLS_CONFIG" ]] || { info "无 skills.toml，跳过外部 skill 更新"; return 0; }
    local parsed
    parsed="$(parse_skills_toml "$SKILLS_CONFIG")" || {
        err "解析 skills.toml 失败"
        return 1
    }
    : "$parsed"
    info "更新所有外部 skills..."
    if [[ "$DRY_RUN" == true ]]; then
        dry "npx -y skills@latest update -g -y"
        return 0
    fi
    if ! npx -y skills@latest update -g -y; then
        err "更新 skills 失败"
        return 1
    fi
    log "外部 skills 已更新"
}

# 更新单个 plugin（claude plugin update），找不到返回失败
update_plugin() {
    local name="${1:?缺少 plugin 名}"
    [[ -f "$PLUGINS_CONFIG" ]] || { err "无 plugins.toml，无法更新 plugin '$name'"; return 1; }

    local parsed
    parsed="$(parse_plugins_toml "$PLUGINS_CONFIG")" || {
        err "解析 plugins.toml 失败"
        return 1
    }
    local line repo method marketplace command note
    while IFS=$'\t' read -r line repo method marketplace command note; do
        [[ "$line" == "$name" ]] || continue
        if [[ "$method" == "npx" ]]; then
            warn "plugin '$name' 是 npx 手动安装，需手动更新: $command"
            return 0
        fi
        info "更新 plugin: $name"
        if [[ "$DRY_RUN" == true ]]; then
            dry "claude plugin update ${name}@${marketplace} -s user"
            return 0
        fi
        if ! claude plugin update "${name}@${marketplace}" -s user; then
            err "更新 plugin '$name' 失败"
            return 1
        fi
        log "plugin '$name' 已更新"
        return 0
    done <<< "$parsed"

    err "plugins.toml 中找不到 plugin: $name"
    return 1
}

# 更新所有第三方 plugins（claude plugin update），任一项失败最终非零
update_all_plugins() {
    [[ -f "$PLUGINS_CONFIG" ]] || { info "无 plugins.toml，跳过第三方 plugin 更新"; return 0; }

    local parsed
    parsed="$(parse_plugins_toml "$PLUGINS_CONFIG")" || {
        err "解析 plugins.toml 失败"
        return 1
    }
    local line repo method marketplace command note
    local rc=0
    while IFS=$'\t' read -r line repo method marketplace command note; do
        [[ -n "$line" ]] || continue
        if ! update_plugin "$line"; then
            rc=1
        fi
    done <<< "$parsed"
    return "$rc"
}

# 安装/更新单个仓库自有 skill（symlink 到当前目标的 skills 目录）。
# 仓库自有 skill 是源码 symlink，内容即改即生效，不存在版本比对；已是同一 symlink 时幂等跳过。
update_local_skill() {
    local name="${1:?缺少本地 skill 名}"
    local src="$REPO_ROOT/skills/$name"
    local dst
    dst="$(skills_target_dir)/$name"
    [[ -f "$src/SKILL.md" ]] || { err "仓库自有 skill 不存在或缺少 SKILL.md: $name"; return 1; }
    info "更新仓库自有 skill: $name (→ $dst)"
    ensure_symlink "$src" "$dst" "repo skill '$name'"
    [[ "$DRY_RUN" == true ]] && return 0
    log "仓库自有 skill '$name' 已更新"
}

update_skill() {
    local name="${1:?缺少 skill 名}"
    [[ -f "$SKILLS_CONFIG" ]] || { err "无 skills.toml，无法更新 skill '$name'"; return 1; }

    local parsed
    parsed="$(parse_skills_toml "$SKILLS_CONFIG")" || {
        err "解析 skills.toml 失败"
        return 1
    }
    local line repo skill agent scope note
    while IFS=$'\t' read -r line repo skill agent scope note; do
        [[ "$line" == "$name" ]] || continue
        local scope_flag=""
        [[ "$scope" == "global" ]] && scope_flag="-g"
        info "更新 skill: $name"
        if [[ "$DRY_RUN" == true ]]; then
            dry "npx -y skills@latest update $name $scope_flag -y"
            return 0
        fi
        if ! npx -y skills@latest update "$name" $scope_flag -y; then
            err "更新 skill '$name' 失败"
            return 1
        fi
        log "skill '$name' 已更新"
        return 0
    done <<< "$parsed"

    err "skills.toml 中找不到 skill: $name"
    return 1
}

ensure_core_config() {
    mkdir -p "$CLAUDE_HOME"

    remove_legacy_rtk_link "$CLAUDE_HOME/RTK.md" "$REPO_ROOT/claude/RTK.md"
    remove_legacy_marketplace_entries "$CLAUDE_HOME/plugins/known_marketplaces.json"
    remove_legacy_installed_plugins_entries "$CLAUDE_HOME/plugins/installed_plugins.json"

    ensure_user_local_bin_path

    local failed=0
    ensure_symlink "$REPO_ROOT/claude/CLAUDE.md.ccfg" "$CLAUDE_HOME/CLAUDE.md" "CLAUDE.md symlink" || failed=1
    # ensure_symlink "$REPO_ROOT/claude/itp.md" "$CLAUDE_HOME/itp.md" "itp.md symlink"
    # ensure_symlink "$REPO_ROOT/claude/haiku-throttle.md" "$CLAUDE_HOME/haiku-throttle.md" "haiku-throttle.md symlink"
    remove_symlink_if_ours "$CLAUDE_HOME/AGENTS.md" "AGENTS.md 旧 symlink" "$REPO_ROOT/claude/AGENTS.md"

    ensure_symlink "$REPO_ROOT/claude/rules" "$CLAUDE_HOME/rules" "rules symlink" || failed=1
    ensure_symlink "$REPO_ROOT/claude/rules-available" "$CLAUDE_HOME/rules-available" "rules-available symlink" || failed=1
    ensure_symlink "$REPO_ROOT/claude/hooks/rules-loader.sh" "$CLAUDE_HOME/hooks/rules-loader.sh" "rules-loader hook" || failed=1
    # 自定义 subagent 目录（原 claude/agents-custom 已并入 claude/agents）
    ensure_symlink "$REPO_ROOT/claude/agents" "$CLAUDE_HOME/agents" "agents symlink" || failed=1

    # 自有 skill 位于顶层 skills/（npx skills 通用 agent 约定目录）。
    # 仓库内安装由 npx skills 从 GitHub 远程拉取到 ~/.claude/skills/；
    # 开发时也可直接从本地 skills/ 读取。外部 skill 由
    # install_external_skills() 通过 npx skills 安装。
    return "$failed"
}

ensure_settings_json() {
    local template="$REPO_ROOT/claude/settings.template.json"
    local target="$CLAUDE_HOME/settings.json"

    if [[ ! -f "$template" ]]; then
        warn "settings.template.json 不存在，跳过"
        return 0
    fi

    local rendered_settings
    rendered_settings="$(render_settings_template "$template")"
    remove_legacy_settings_entries "$target"

    # settings.json 已存在则始终合并（保留已有值，仅补齐模板缺失键），不区分 CI_MODE。
    # 旧版在 CI_MODE=true 时跳过 merge 直接覆盖，会抹掉用户自建键（env/token/thinking 等）。
    if [[ -f "$target" ]]; then
        info "合并现有 settings.json（保留已有值，仅补齐缺失项）..."
        if [[ "$DRY_RUN" == true ]]; then
            dry "merge settings.json with template-backed migration keys"
            return 0
        fi
        mkdir -p "$CLAUDE_HOME"
        merge_settings_json "$target" "$rendered_settings"
        log "settings.json 已合并并补齐缺失项"
        return 0
    fi

    info "生成 settings.json..."
    if [[ "$DRY_RUN" == true ]]; then
        dry "write rendered settings.json"
        return 0
    fi

    mkdir -p "$CLAUDE_HOME"
    printf '%s\n' "$rendered_settings" > "$target"
    log "settings.json 已生成"
}

verify_repository_cleanliness() {
    if [[ "$NO_VERIFY" == true ]]; then
        info "跳过仓库洁净验证"
        return 0
    fi

    local failed=0
    local ignored_paths=(
        "package.json"
        "package-lock.json"
        "claude/AGENTS.md"
    )

    local path
    for path in "${ignored_paths[@]}"; do
        if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            err "路径仍被 git 跟踪，不能只依赖 .gitignore: $path"
            failed=1
        elif git -C "$REPO_ROOT" check-ignore -q -- "$path"; then
            pass "已忽略且未跟踪: $path"
        else
            err "缺少忽略规则: $path"
            failed=1
        fi

        if ! git -C "$REPO_ROOT" diff --quiet -- "$path"; then
            err "路径仍产生 tracked diff: $path"
            failed=1
        fi
    done

    [[ $failed -eq 0 ]]
}

verify_core_config() {
    if [[ "$NO_VERIFY" == true ]]; then
        info "跳过 setup 级验证"
        return 0
    fi

    local failed=0
    if is_valid_claude_md "$CLAUDE_HOME/CLAUDE.md" "$REPO_ROOT/claude/CLAUDE.md.ccfg"; then
        if symlink_points_to "$CLAUDE_HOME/CLAUDE.md" "$REPO_ROOT/claude/CLAUDE.md.ccfg"; then
            pass "CLAUDE.md symlink"
        else
            pass "CLAUDE.md injected file (OMC + Claude-Config)"
        fi
    else
        if [[ -f "$CLAUDE_HOME/CLAUDE.md" && ! -L "$CLAUDE_HOME/CLAUDE.md" ]]; then
            err "CLAUDE.md 是普通文件但缺少 OMC 或 Claude-Config block"
        else
            err "CLAUDE.md 未配置 (需要 symlink 或包含 OMC + Claude-Config blocks 的普通文件)"
        fi
        failed=1
    fi

    # if symlink_points_to "$CLAUDE_HOME/itp.md" "$REPO_ROOT/claude/itp.md" \
    #     && symlink_points_to "$CLAUDE_HOME/haiku-throttle.md" "$REPO_ROOT/claude/haiku-throttle.md"; then
    #     pass "ITP/throttle symlink"
    # else
    #     err "ITP/throttle symlink 缺失"
    #     failed=1
    # fi
    
    local agents_path="$CLAUDE_HOME/AGENTS.md"
    if [[ ! -e "$agents_path" && ! -L "$agents_path" ]]; then
        pass "AGENTS.md 未由核心配置接管"
    elif [[ -L "$agents_path" ]]; then
        local agents_target
        agents_target="$(readlink -f "$agents_path" 2>/dev/null || true)"
        if [[ "$agents_target" == "$REPO_ROOT/claude/AGENTS.md" ]]; then
            err "AGENTS.md 不应再链接到仓库内第三方内容"
            failed=1
        else
            warn "AGENTS.md 是外部符号链接，核心 setup 不接管: $agents_path -> $agents_target"
        fi
    elif [[ -f "$agents_path" ]]; then
        info "AGENTS.md 是用户管理文件，核心 setup 不接管: $agents_path"
    else
        warn "AGENTS.md 存在但类型不常见，核心 setup 不接管: $agents_path"
    fi

    if symlink_points_to "$CLAUDE_HOME/rules" "$REPO_ROOT/claude/rules"; then
        pass "rules symlink"
    else
        err "rules symlink 缺失"
        failed=1
    fi

    if symlink_points_to "$CLAUDE_HOME/rules-available" "$REPO_ROOT/claude/rules-available"; then
        pass "rules-available symlink"
    else
        err "rules-available symlink 缺失"
        failed=1
    fi

    if symlink_points_to "$CLAUDE_HOME/hooks/rules-loader.sh" "$REPO_ROOT/claude/hooks/rules-loader.sh"; then
        pass "rules-loader hook"
    else
        err "rules-loader hook 缺失"
        failed=1
    fi

    if symlink_points_to "$CLAUDE_HOME/agents" "$REPO_ROOT/claude/agents"; then
        pass "agents symlink"
    else
        err "agents symlink 缺失"
        failed=1
    fi

    local repo_skills_dir="$REPO_ROOT/skills"
    if [[ -d "$repo_skills_dir" ]] && [[ -n "$(ls -A "$repo_skills_dir")" ]]; then
        pass "自有 skills 就绪 ($repo_skills_dir)"
    else
        err "自有 skills 目录缺失或为空: $repo_skills_dir"
        failed=1
    fi

    if [[ -f "$CLAUDE_HOME/settings.json" ]]; then
        pass "settings.json 已存在"
    else
        err "settings.json 不存在"
        failed=1
    fi

    if [[ -f "$CLAUDE_HOME/plugins/known_marketplaces.json" ]]; then
        pass "known_marketplaces.json 已存在"
    else
        warn "known_marketplaces.json 不存在（首次安装时装 plugin 后会自动生成，可接受）"
    fi

    verify_repository_cleanliness || failed=1

    [[ $failed -eq 0 ]]
}

verify_installed_skills_context() {
    local context_file="$1"
    local list_file list_err plugin_file plugin_err
    list_file="$(mktemp)"
    list_err="$(mktemp)"
    plugin_file="$(mktemp)"
    plugin_err="$(mktemp)"

    if ! npx -y skills@latest list -g --json >"$list_file" 2>"$list_err"; then
        err "无法读取全局 skill 清单 (npx skills list)"
        warn "可手动执行: npx -y skills@latest list -g --json 查看原因"
        sed -n '1,20p' "$list_err" >&2
        rm -f "$list_file" "$list_err" "$plugin_file" "$plugin_err"
        return 1
    fi
    if ! claude plugin list --json >"$plugin_file" 2>"$plugin_err"; then
        err "无法读取 plugin skill 的注册清单 (claude plugin list)"
        sed -n '1,20p' "$plugin_err" >&2
        rm -f "$list_file" "$list_err" "$plugin_file" "$plugin_err"
        return 1
    fi

    local failed=0
    local name repo skill agent scope note
    while IFS=$'\t' read -r name repo skill agent scope note; do
        [[ -n "$name" ]] || continue
        local matched source_kind="npx" plugin_id plugin_path
        matched="$(SKILLS_LIST_JSON="$list_file" SKILLS_LOCK_FILE="$HOME/.agents/.skill-lock.json" EXPECTED_REPO="$repo" python3 - <<'PY'
import json
import os
from pathlib import Path

repo = os.environ["EXPECTED_REPO"]
expected_url = "https://github.com/" + repo.removesuffix(".git")
seen = set()

def emit(name, path):
    path = Path(path)
    key = (name, str(path))
    if name and path.is_file() and key not in seen:
        seen.add(key)
        print(name + "\t" + str(path.parent))

with open(os.environ["SKILLS_LIST_JSON"], encoding="utf-8") as fp:
    items = json.load(fp)
for item in items:
    source = item.get("source") or ""
    source_url = (item.get("sourceUrl") or "").removesuffix(".git")
    if source == repo or source_url == expected_url:
        path = item.get("path") or ""
        skill_name = item.get("name") or ""
        if skill_name and path:
            emit(skill_name, Path(path) / "SKILL.md")

# skills CLI versions can omit an installed agent from `list -g --json`.
# Its global lock remains the source-of-truth for the installed path.
lock_path = Path(os.environ["SKILLS_LOCK_FILE"])
if lock_path.is_file():
    with lock_path.open(encoding="utf-8") as fp:
        lock = json.load(fp)
    for skill_name, item in (lock.get("skills") or {}).items():
        source = item.get("source") or ""
        source_url = (item.get("sourceUrl") or "").removesuffix(".git")
        skill_path = item.get("skillPath") or ""
        if (source == repo or source_url == expected_url) and skill_path:
            home_path = lock_path.parent.parent
            candidates = [
                home_path / skill_path,
                home_path / ".claude" / skill_path,
                lock_path.parent / skill_path,
            ]
            for candidate in candidates:
                if candidate.is_file():
                    emit(skill_name, candidate)
                    break
PY
)"

        if [[ -z "$matched" ]]; then
            source_kind="plugin"
            plugin_id="$(parse_plugins_toml "$PLUGINS_CONFIG" | awk -F '\t' -v expected_repo="$repo" '$2 == expected_repo && $3 == "claude-plugin" { print $1 "@" $4; exit }')"
            if [[ -z "$plugin_id" ]]; then
                err "skill source '$name' 既不在 npx 清单中，也没有对应 plugin: $repo"
                failed=1
                continue
            fi
            plugin_path="$(PLUGIN_LIST_JSON="$plugin_file" EXPECTED_PLUGIN_ID="$plugin_id" python3 - <<'PY'
import json
import os

with open(os.environ["PLUGIN_LIST_JSON"], encoding="utf-8") as fp:
    items = json.load(fp)
expected = os.environ["EXPECTED_PLUGIN_ID"]
for item in items:
    if item.get("id") == expected and item.get("scope") == "user":
        path = item.get("installPath") or ""
        if path:
            print(path)
            break
PY
)"
            if [[ -z "$plugin_path" || ! -d "$plugin_path" ]]; then
                err "skill source '$name' 对应 plugin '$plugin_id' 缺少有效 installPath"
                failed=1
                continue
            fi
            matched="$(PLUGIN_SKILLS_ROOT="$plugin_path" python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["PLUGIN_SKILLS_ROOT"])
for skill_file in sorted(root.rglob("SKILL.md")):
    name = ""
    for line in skill_file.read_text(encoding="utf-8", errors="replace").splitlines()[:40]:
        if line.startswith("name:"):
            name = line[5:].strip()
            break
    if name:
        print(name + "\t" + str(skill_file.parent))
PY
)"
            if [[ -z "$matched" ]]; then
                err "skill source '$name' 的 plugin '$plugin_id' 未找到有效 SKILL.md"
                failed=1
                continue
            fi
        fi

        while IFS=$'\t' read -r actual_name actual_path; do
            [[ -n "$actual_name" ]] || continue
            if [[ ! -f "$actual_path/SKILL.md" ]]; then
                err "skill '$actual_name' 缺少 SKILL.md: $actual_path"
                failed=1
                continue
            fi
            if ! awk -v expected="$actual_name" '
                NR <= 40 && $0 ~ /^name:[[:space:]]*/ {
                    value=$0
                    sub(/^name:[[:space:]]*/, "", value)
                    gsub(/[[:space:]]+$/, "", value)
                    found=(value == expected)
                }
                END { exit(found ? 0 : 1) }
            ' "$actual_path/SKILL.md"; then
                err "skill '$actual_name' 的 SKILL.md frontmatter name 不匹配: $actual_path"
                failed=1
                continue
            fi
            # disable-model-invocation=true 的 Skill 仍应安装成功，但 Claude
            # 不会把它加入 /context 的可调用 Skills 表（例如 grill-me）。
            if grep -Eq '^disable-model-invocation:[[:space:]]*true[[:space:]]*$' \
                "$actual_path/SKILL.md"; then
                pass "skill '$actual_name' 已安装（disable-model-invocation=true，不要求出现在 /context）"
                continue
            fi
            local context_skill_name="$actual_name"
            local context_plugin_skill_name=""
            if [[ "$source_kind" == "plugin" ]]; then
                context_plugin_skill_name="${plugin_id%@*}:$actual_name"
            fi
            local context_skill_visible=false
            if grep -Fq "| $context_skill_name |" "$context_file"; then
                context_skill_visible=true
            elif [[ -n "$context_plugin_skill_name" ]] &&
                grep -Fq "| $context_plugin_skill_name |" "$context_file"; then
                context_skill_visible=true
            fi
            if [[ "$context_skill_visible" != true ]]; then
                err "skill '$actual_name' 未出现在 Claude -p /context 的 Skills 表"
                failed=1
                continue
            fi
            pass "skill '$actual_name' 已安装且在 Claude /context 中可见 (source=$name, via=$source_kind)"
        done <<< "$matched"
    done < <(parse_skills_toml "$SKILLS_CONFIG")

    rm -f "$list_file" "$list_err" "$plugin_file" "$plugin_err"
    return "$failed"
}

verify_settings_template_keys() {
    local template="$REPO_ROOT/claude/settings.template.json"
    local target="$CLAUDE_HOME/settings.json"
    [[ -f "$template" ]] || { err "settings 模板不存在: $template"; return 1; }
    [[ -f "$target" ]] || { err "settings.json 不存在: $target"; return 1; }

    if ! TEMPLATE_SETTINGS="$template" TARGET_SETTINGS="$target" python3 - <<'PY'
import json
import os
import sys

with open(os.environ["TEMPLATE_SETTINGS"], encoding="utf-8") as fp:
    template = json.load(fp)
with open(os.environ["TARGET_SETTINGS"], encoding="utf-8") as fp:
    target = json.load(fp)

missing = []
type_errors = []

def check(template_value, target_value, path):
    if template_value == "":
        return
    if isinstance(template_value, dict):
        if not isinstance(target_value, dict):
            type_errors.append(path + " (应为 object)")
            return
        # Claude may normalize a git marketplace source to the equivalent
        # github/repo form after registration; both retain the marketplace.
        if path.endswith(".source") and "url" in template_value and "repo" in target_value:
            if target_value.get("source") == "github" and isinstance(target_value["repo"], str):
                return
        for key, value in template_value.items():
            child = path + "." + key if path else key
            if key not in target_value:
                missing.append(child)
            else:
                check(value, target_value[key], child)
    elif isinstance(template_value, list):
        if not isinstance(target_value, list):
            type_errors.append(path + " (应为 array)")
    elif target_value is not None and type(template_value) is not type(target_value):
        type_errors.append(path + " (类型不匹配)")

check(template, target, "")
if missing or type_errors:
    if missing:
        print("missing=" + ",".join(missing), file=sys.stderr)
    if type_errors:
        print("type_errors=" + ",".join(type_errors), file=sys.stderr)
    sys.exit(1)
PY
    then
        err "settings.json 未完整补齐模板中的非空键"
        return 1
    fi

    local plugin_count
    plugin_count="$(python3 - "$target" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as fp:
    data = json.load(fp)
plugins = data.get("enabledPlugins", {})
print(sum(1 for key, value in plugins.items() if isinstance(key, str) and isinstance(value, bool)))
PY
)"
    pass "settings.json 已补齐模板键并保留用户值 (enabledPlugins=$plugin_count)"
}

verify_registered_plugins() {
    local list_file
    list_file="$(mktemp)"
    if ! claude plugin list --json >"$list_file" 2>&1; then
        err "读取 claude plugin list --json 失败"
        sed -n '1,30p' "$list_file" >&2
        rm -f "$list_file"
        return 1
    fi

    local failed=0
    local name repo method marketplace command note
    while IFS=$'\t' read -r name repo method marketplace command note; do
        [[ -n "$name" ]] || continue
        [[ "$method" == "claude-plugin" ]] || continue
        local plugin_id="${name}@${marketplace}"
        if PLUGIN_LIST_JSON="$list_file" EXPECTED_PLUGIN_ID="$plugin_id" python3 - <<'PY'
import json
import os
import sys
with open(os.environ["PLUGIN_LIST_JSON"], encoding="utf-8") as fp:
    items = json.load(fp)
expected = os.environ["EXPECTED_PLUGIN_ID"]
for item in items:
    if item.get("id") == expected and item.get("scope") == "user":
        sys.exit(0)
sys.exit(1)
PY
        then
            pass "plugin '$plugin_id' 已注册 (scope=user)"
        else
            err "plugin '$plugin_id' 未注册或 scope 不是 user"
            failed=1
        fi
    done < <(parse_plugins_toml "$PLUGINS_CONFIG")

    rm -f "$list_file"
    return "$failed"
}

run_context_smoke_test() {
    if ! command -v claude >/dev/null 2>&1; then
        err "Claude -p /context 检查失败: claude 命令不存在"
        return 1
    fi

    # 默认 15s；CI 冷启动（首次 claude 启动 + 代理握手）需要更长，可用
    # CLAUDE_CONTEXT_TIMEOUT 放宽，不做硬性上限钳制。
    local timeout_seconds="${CLAUDE_CONTEXT_TIMEOUT:-15}"
    local tmp
    tmp="$(mktemp)"
    set +e
    timeout "$timeout_seconds" claude -p /context >"$tmp" 2>&1
    local rc=$?
    set -e

    if [[ $rc -eq 124 ]]; then
        err "Claude -p /context 检查超时 (${timeout_seconds}s)"
        rm -f "$tmp"
        return 1
    fi

    if [[ $rc -ne 0 ]]; then
        err "Claude -p /context 检查失败 ($rc)"
        sed -n '1,40p' "$tmp" >&2
        rm -f "$tmp"
        return "$rc"
    fi

    if [[ ! -s "$tmp" ]]; then
        err "Claude -p /context 未输出上下文信息"
        rm -f "$tmp"
        return 1
    fi

    # 验证 Skills 清单已注入：/context 的 Skills 段应至少含表头 + 一行数据。
    # （/skills 是交互式 slash command，headless -p 模式下不可用，改用 /context
    #  的 Skills 段验证已加载 skill 的可见性。）
    local skill_rows
    skill_rows="$(sed -n '/^### Skills$/,/^### /p' "$tmp" | grep -c '^| ' || true)"
    if (( skill_rows < 2 )); then
        err "Claude -p /context 的 Skills 段为空，skill 未被加载"
        info "/context Skills 段诊断（最多 40 行）:"
        sed -n '/^### Skills$/,/^### /p' "$tmp" | sed -n '1,40p' >&2
        rm -f "$tmp"
        return 1
    fi

    local skills_rc=0
    if ! verify_installed_skills_context "$tmp"; then
        skills_rc=1
        info "/context Skills 段诊断（最多 40 行）:"
        sed -n '/^### Skills$/,/^### /p' "$tmp" | sed -n '1,40p' >&2
    fi
    rm -f "$tmp"
    if [[ $skills_rc -ne 0 ]]; then
        return 1
    fi

    log "Claude -p /context 上下文注入检查通过"
}

run_final_doctor() {
    if [[ "$NO_VERIFY" == true ]]; then
        info "跳过最终 doctor (--no-verify)"
        return 0
    fi

    # 旧 context-mode install-*.sh 的 doctor 分支已随阶段 2 退役；
    # context-mode 由 claude plugin 安装，下方 check-claude-doctor.sh 覆盖其运行状态检查。
    if [[ "$SMOKE_TEST" != true ]]; then
        info "跳过扩展冒烟测试 (--smoke-test 未启用)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "script/check-claude-doctor.sh"
        dry "claude -p /context"
        return 0
    fi

    # 默认 15s；CI 冷启动需要更长，可用 CLAUDE_DOCTOR_TIMEOUT 放宽，不做硬性上限钳制。
    local doctor_timeout_seconds="${CLAUDE_DOCTOR_TIMEOUT:-15}"

    info "运行最终 Claude doctor..."
    if timeout "$doctor_timeout_seconds" "$REPO_ROOT/script/check-claude-doctor.sh"; then
        log "Claude doctor 通过"
    else
        local rc=$?
        if [[ $rc -eq 124 ]]; then
            err "Claude doctor 超时 (${doctor_timeout_seconds}s)"
        else
            err "Claude doctor 失败 ($rc)"
        fi
        return 1
    fi

    info "运行 Claude -p /context 上下文注入检查..."
    if ! run_context_smoke_test; then
        err "Claude -p /context 逐项 skill 检查失败"
        return 1
    fi

    info "运行 settings.json 模板键检查..."
    if ! verify_settings_template_keys; then
        return 1
    fi

    info "运行 claude plugin list 注册检查..."
    if ! verify_registered_plugins; then
        return 1
    fi

    log "安装后冒烟测试通过: Claude doctor + skills/context + settings + plugins"
    return 0
}

run_priority_module_actions() {
    # 清单驱动的生命周期操作：install_external_skills + install_third_party_plugins
    install_external_skills
    install_third_party_plugins
}

run_agents_flow() {
    # 非 claude 目标只支持 skills：外部（skills.toml，npx skills -a universal）+ 仓库自有
    # （skills/ symlink），统一落到 ~/.agents/skills。
    # 全量/指定安装语义：无任何 --skill/--update-local-skill = 全量（外部全部 + 自有全部）；
    # 指定了任一 = 只装被指定的（外部按 --skill，自有按 --update-local-skill），未指定类别不装。
    # 非 skills 流程（claude code / core config / plugins / verify）一律不执行。
    local rc=0

    # 是否处于"指定安装"模式：两类指定任一项出现即只装指定项
    local specified=false
    [[ ${#SELECTED_SKILLS[@]} -gt 0 ]] && specified=true
    local r
    for r in "${UPDATE_RESOURCES[@]}"; do
        [[ "$r" == skill:* ]] && specified=true
    done

    phase "Phase 1: Agents skills（外部，npx skills → $AGENTS_SKILLS_HOME/）"
    if [[ "$SKIP_SKILLS" == true ]]; then
        info "已跳过外部 skills 安装（--skip-skills）"
    elif [[ ${#SELECTED_SKILLS[@]} -gt 0 ]]; then
        install_external_skills "${SELECTED_SKILLS[@]}" || rc=1
    elif [[ "$specified" == true ]]; then
        info "指定安装模式：未指定外部 skill，跳过外部 skills"
    else
        install_external_skills || rc=1
    fi

    phase "Phase 2: Agents skills（仓库自有，symlink → $AGENTS_SKILLS_HOME/）"
    local -a local_names=()
    if [[ ${#UPDATE_RESOURCES[@]} -gt 0 ]]; then
        # 指定安装：--update-local-skill 经参数解析已转为 skill:NAME；
        # 非 claude 模式下 UPDATE_RESOURCES 中的 skill: 一律视为仓库自有（外部指定走 --skill）。
        for r in "${UPDATE_RESOURCES[@]}"; do
            [[ "$r" == skill:* ]] && local_names+=("${r#skill:}")
        done
    elif [[ "$specified" == false ]]; then
        # 全量：仓库 skills/ 下所有含 SKILL.md 的目录
        local dir
        for dir in "$REPO_ROOT"/skills/*/; do
            [[ -d "$dir" && -f "$dir/SKILL.md" ]] || continue
            local_names+=("$(basename "$dir")")
        done
    fi
    local name
    for name in "${local_names[@]}"; do
        update_local_skill "$name" || rc=1
    done

    if [[ "$rc" == 0 ]]; then
        log "Agents skills 已就绪: $AGENTS_SKILLS_HOME/"
    else
        err "部分 Agents skill 安装失败"; print_retry_hint
    fi
    return "$rc"
}

run_install_flow() {
    phase "Phase 1: Claude Code"
    ensure_claude_code

    phase "Phase 2: 核心配置"
    ensure_core_config || { print_retry_hint; return 1; }
    ensure_settings_json

    phase "Phase 3: 外部 skills（npx skills）"
    if [[ "$SKIP_SKILLS" == true ]]; then
        info "已跳过外部 skills 安装（--skip-skills）"
    elif [[ ${#SELECTED_SKILLS[@]} -gt 0 ]]; then
        install_external_skills "${SELECTED_SKILLS[@]}"
    else
        install_external_skills
    fi

    # --skill 是单项入口：没有同时指定 plugin 时，安装完成即退出，
    # 不继续执行全量 plugin 安装和最终验证流程。
    if [[ ${#SELECTED_SKILLS[@]} -gt 0 && ${#SELECTED_PLUGINS[@]} -eq 0 ]]; then
        info "指定 skill 安装完成，跳过后续 plugins/验证流程"
        return 0
    fi

    phase "Phase 4: 第三方 plugins（claude plugin）"
    if [[ "$SKIP_PLUGINS" == true ]]; then
        info "已跳过第三方 plugins 安装（--skip-plugins）"
    elif [[ ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
        install_third_party_plugins "${SELECTED_PLUGINS[@]}"
    else
        install_third_party_plugins
    fi

    phase "Phase 5: 最终验证"
    verify_core_config && log "核心配置验证通过"
    run_final_doctor
}

run_core_flow() {
    phase "Phase 1: Claude Code"
    ensure_claude_code

    phase "Phase 2: 核心配置"
    ensure_core_config || { print_retry_hint; return 1; }
    ensure_settings_json

    phase "Phase 3: 最终验证"
    verify_core_config && log "核心配置验证通过"
}

run_inspection_flow() {
    phase "Phase 1: 核心配置状态"
    verify_core_config

    phase "Phase 2: 生命周期模块状态"
    run_priority_module_actions
}

# 只读列出统一资源：configs/ 清单声明的 remote skill/plugin + 仓库 skills/ 下的本地 skill。
# 复用 resource-plan.py 的 9 列 tsv 输出，按 kind 分组展示。
# exit 0 = 无冲突；2 = 存在未决冲突（列表仍完整输出）。
run_list_flow() {
    local out rc
    out="$(python3 "$RESOURCE_PLANNER" --repo-root "$REPO_ROOT" --format tsv 2>&1)"
    rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
        err "资源计划失败 (exit $rc)"
        return "$rc"
    fi
    if [[ -z "$out" ]]; then
        info "未声明任何 skill/plugin 资源"
        return 0
    fi
    python3 -c 'import sys
from collections import OrderedDict
groups = OrderedDict()
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    f = line.split("\t")
    if len(f) != 9:
        continue
    kind, rid, source, name, repo, marketplace, path, action, conflict = f
    where = repo or marketplace or path or "?"
    groups.setdefault(kind, []).append((rid, source, where, conflict))
for kind, items in groups.items():
    print()
    print(f"=== {kind}s ({len(items)}) ===")
    for rid, source, where, conflict in items:
        flag = "  [冲突]" if conflict == "1" else ""
        print(f"  [{kind}] {rid}\t{source}\t{where}{flag}")' <<< "$out"
    if [[ "$rc" == 2 ]]; then
        warn "存在未决冲突；可用 --choose <kind>:<id>=local|remote|skip 指定来源"
    fi
    return "$rc"
}

# 检测 Claude Code CLI 本体安装状态（区别于 verify=核心配置 symlink、doctor=OMC 插件诊断）。
# 检查: claude 存在性 → 版本/路径 → claude doctor 健康 → claude auth 认证状态。
# exit 0 = 全部通过；1 = claude 缺失或 doctor 失败。
run_check_flow() {
    local failed=0

    phase "Phase 1: Claude Code 存在性"
    if ! command -v claude >/dev/null 2>&1; then
        err "claude 命令未找到 (PATH 中无 claude)"
        return 1
    fi
    local claude_bin claude_path
    claude_bin="$(command -v claude)"
    claude_path="$(readlink -f "$claude_bin" 2>/dev/null || echo "$claude_bin")"
    pass "claude 可执行文件: $claude_path"

    local version
    version="$(claude --version 2>&1 | head -1)"
    log "Claude Code 已安装: $version"

    phase "Phase 2: claude doctor 健康检查"
    if [[ "$DRY_RUN" == true ]]; then
        dry "claude doctor"
    else
        local doctor_out doctor_rc
        doctor_out="$(claude doctor 2>&1)"
        doctor_rc=$?
        if [[ $doctor_rc -eq 0 && "$doctor_out" == *"No installation issues found."* ]]; then
            pass "claude doctor: 无安装问题"
        else
            err "claude doctor 失败 (exit $doctor_rc):"
            echo "$doctor_out" | sed 's/^/    /'
            failed=1
        fi
    fi

    phase "Phase 3: claude auth 认证状态"
    if [[ "$DRY_RUN" == true ]]; then
        dry "claude auth status --json"
    else
        local auth_out
        auth_out="$(claude auth status --json 2>&1)"
        if echo "$auth_out" | grep -q '"loggedIn": true'; then
            local method
            method="$(echo "$auth_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("authMethod") or "unknown")' 2>/dev/null || echo "unknown")"
            pass "claude 已登录 (authMethod=$method)"
        else
            warn "claude 未登录 — 安装可用但需认证才能使用"
        fi
    fi

    [[ $failed -eq 0 ]]
}

UNINSTALL_LIST=()
UNINSTALL_JOBS=3

# 外部 skill 并行安装的并发度（同仓库多 skill 合并为一次 add，组间并发）。
SKILLS_INSTALL_JOBS=3

remove_symlink_if_ours() {
    local path="$1"
    local label="$2"
    local expected_src="$3"

    if [[ ! -L "$path" ]]; then
        if [[ -e "$path" ]]; then
            info "跳过非符号链接: $label ($path)"
        fi
        return 0
    fi

    local current_target
    current_target="$(readlink -f "$path" 2>/dev/null || true)"
    if [[ "$current_target" != "$expected_src" ]]; then
        warn "符号链接目标不匹配，跳过: $label ($path -> $current_target, 期望 $expected_src)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "rm $path"
        return 0
    fi

    rm -f "$path"
    log "已移除: $label"
}

remove_managed_block() {
    local path="$1"
    local block_name="$2"
    local label="$3"
    local start_marker="<!-- ${block_name}:START -->"
    local end_marker="<!-- ${block_name}:END -->"

    local start_pattern="<!--[[:space:]]*${block_name}:START[[:space:]]*-->"

    [[ -f "$path" ]] || return 0
    if ! grep -Eq "$start_pattern" "$path" 2>/dev/null; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "remove $block_name block from $path"
        return 0
    fi

    MANAGED_BLOCK_PATH="$path" \
    MANAGED_BLOCK_NAME="$block_name" \
    MANAGED_BLOCK_START="$start_marker" \
    MANAGED_BLOCK_END="$end_marker" \
    python3 - <<'PYEOF'
import os
import re
from pathlib import Path

path = Path(os.environ['MANAGED_BLOCK_PATH'])
name = os.environ['MANAGED_BLOCK_NAME']
content = path.read_text(encoding='utf-8')
start_re = rf'<!--\s*{re.escape(name)}:START\s*-->'
end_re = rf'<!--\s*{re.escape(name)}:END\s*-->'
pattern = re.compile(rf'(?ms)^\s*{start_re}\s*\n.*?\n{end_re}\s*')
updated = pattern.sub('', content, count=1).strip() + '\n'
if updated.strip():
    path.write_text(updated, encoding='utf-8')
else:
    path.unlink()
PYEOF

    log "已移除: $label"
}

uninstall_skill() {
    local name="${1:?缺少 skill 名}"
    [[ -f "$SKILLS_CONFIG" ]] || { err "无 skills.toml，无法卸载 skill '$name'"; return 1; }

    local parsed
    parsed="$(parse_skills_toml "$SKILLS_CONFIG")" || {
        err "解析 skills.toml 失败"
        return 1
    }
    local line repo skill agent scope note
    while IFS=$'\t' read -r line repo skill agent scope note; do
        [[ "$line" == "$name" ]] || continue
        local scope_flag=""
        [[ "$scope" == "global" ]] && scope_flag="-g"
        info "卸载 skill: $name"
        if [[ "$DRY_RUN" == true ]]; then
            dry "npx -y skills@latest remove $name -a ${agent:-claude-code} $scope_flag -y"
            return 0
        fi
        if ! npx -y skills@latest remove "$name" -a "${agent:-claude-code}" $scope_flag -y; then
            err "卸载 skill '$name' 失败"
            return 1
        fi
        log "skill '$name' 已卸载"
        return 0
    done <<< "$parsed"

    err "skills.toml 中找不到 skill: $name"
    return 1
}

uninstall_plugin() {
    local name="${1:?缺少 plugin 名}"
    [[ -f "$PLUGINS_CONFIG" ]] || { err "无 plugins.toml，无法卸载 plugin '$name'"; return 1; }

    local parsed
    parsed="$(parse_plugins_toml "$PLUGINS_CONFIG")" || {
        err "解析 plugins.toml 失败"
        return 1
    }
    local line repo method marketplace command note
    while IFS=$'\t' read -r line repo method marketplace command note; do
        [[ "$line" == "$name" ]] || continue
        if [[ "$method" == "npx" ]]; then
            warn "plugin '$name' 是 npx 手动安装，需手动卸载: $command"
            return 0
        fi
        info "卸载 plugin: $name"
        if [[ "$DRY_RUN" == true ]]; then
            dry "claude plugin uninstall ${name}@${marketplace} -s user -y"
            return 0
        fi
        if ! claude plugin uninstall "${name}@${marketplace}" -s user -y; then
            err "卸载 plugin '$name' 失败"
            return 1
        fi
        log "plugin '$name' 已卸载"
        return 0
    done <<< "$parsed"

    err "plugins.toml 中找不到 plugin: $name"
    return 1
}

uninstall_core() {
    phase "Uninstall: 核心配置"
    local repo="$REPO_ROOT/claude"

    if [[ -L "$CLAUDE_HOME/CLAUDE.md" ]]; then
        remove_symlink_if_ours "$CLAUDE_HOME/CLAUDE.md" "CLAUDE.md symlink" "$repo/CLAUDE.md.ccfg"
    elif [[ -f "$CLAUDE_HOME/CLAUDE.md" ]] && file_has_block "$CLAUDE_HOME/CLAUDE.md" "Claude-Config"; then
        remove_managed_block "$CLAUDE_HOME/CLAUDE.md" "Claude-Config" "CLAUDE.md Claude-Config block"
    fi
    # remove_symlink_if_ours "$CLAUDE_HOME/itp.md" "itp.md symlink" "$repo/itp.md"
    # remove_symlink_if_ours "$CLAUDE_HOME/haiku-throttle.md" "haiku-throttle.md symlink" "$repo/haiku-throttle.md"

    remove_legacy_rtk_link "$CLAUDE_HOME/RTK.md" "$repo/RTK.md"
    remove_symlink_if_ours "$CLAUDE_HOME/AGENTS.md" "AGENTS.md" "$repo/AGENTS.md"
    remove_symlink_if_ours "$CLAUDE_HOME/rules" "rules/" "$repo/rules"
    remove_symlink_if_ours "$CLAUDE_HOME/rules-available" "rules-available/" "$repo/rules-available"
    remove_symlink_if_ours "$CLAUDE_HOME/hooks/rules-loader.sh" "rules-loader hook" "$repo/hooks/rules-loader.sh"
    remove_symlink_if_ours "$CLAUDE_HOME/agents" "agents/" "$repo/agents"

    local repo_skills_dir="$repo/skills"
    if [[ -d "$repo_skills_dir" && -d "$CLAUDE_HOME/skills" ]]; then
        local skill_src skill_name skill_dst
        for skill_src in "$repo_skills_dir"/*; do
            [[ -e "$skill_src" ]] || continue
            skill_name="$(basename "$skill_src")"
            skill_dst="$CLAUDE_HOME/skills/$skill_name"
            remove_symlink_if_ours "$skill_dst" "repo skill '$skill_name'" "$skill_src"
        done
    fi

    # 如果 hooks 目录为空则清理
    if [[ -d "$CLAUDE_HOME/hooks" ]]; then
        rmdir "$CLAUDE_HOME/hooks" 2>/dev/null && info "已清理空 hooks 目录" || true
    fi
}

remove_legacy_ecc_paths() {
    local path
    for path in "$CLAUDE_HOME/ecc" "$CLAUDE_HOME/plugins/cache/ecc" "$CLAUDE_HOME/plugins/marketplaces/ecc" "$CLAUDE_HOME/skills/ecc"; do
        [[ -e "$path" || -L "$path" ]] || continue
        if [[ "$DRY_RUN" == true ]]; then
            dry "rm -rf $path"
        else
            rm -rf -- "$path"
            log "已移除旧 ECC 路径: $path"
        fi
    done
}

# 并发卸载一组目标（core/all 串行，清单项有限并发）。
# 只移除 ~/.claude/skills/ 与 ~/.claude/plugins 下的安装副本，绝不触碰本仓库源文件。
uninstall_multi() {
    local -a targets=("$@")
    [[ ${#targets[@]} -gt 0 ]] || { err "uninstall_multi: 空目标列表"; return 1; }

    # 先串行处理全局操作 core/all
    local t
    for t in "${targets[@]}"; do
        case "$t" in
            core) uninstall_core ;;
            all) uninstall_all ;;
        esac
    done

    # 仅剩清单项时才需要并发；去重（core/all 已处理）
    local -a items=()
    local seen=""
    for t in "${targets[@]}"; do
        [[ "$t" == core || "$t" == all ]] && continue
        [[ "$seen" == *"|$t|"* ]] && continue
        seen+="|$t|"
        items+=("$t")
    done
    [[ ${#items[@]} -gt 0 ]] || return 0

    local jobs="${UNINSTALL_JOBS:-3}"
    local -a pids=()
    local failed=0
    local pid
    for t in "${items[@]}"; do
        # 满槽时等最老的作业完成再放新作业（有限并发）
        while ((${#pids[@]} >= jobs)); do
            if ! wait "${pids[0]}"; then failed=1; fi
            pids=("${pids[@]:1}")
        done
        uninstall_one "$t" &
        pids+=("$!")
    done
    # 收尾：等全部剩余作业
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then failed=1; fi
    done
    return "$failed"
}

# 单个清单项卸载：根据它是 skill 还是 plugin 分发到对应函数
# 支持 typed 目标 skill:NAME / plugin:NAME（由 --uninstall-skill/--uninstall-plugin 产生），
# 规避同名 skill/plugin 被 skill-first 误分派；未带类型时保持旧 skill-first 兼容。
uninstall_one() {
    local name="${1:?缺少目标名}"
    case "$name" in
        skill:*)
            uninstall_skill "${name#skill:}"
            return ;;
        plugin:*)
            uninstall_plugin "${name#plugin:}"
            return ;;
        core|all)
            err "uninstall_one: core/all 应串行处理，不应进入并发队列"
            return 1 ;;
    esac
    if manifest_has_skill "$name"; then
        uninstall_skill "$name"
    elif manifest_has_plugin "$name"; then
        uninstall_plugin "$name"
    else
        err "未知卸载目标: $name"
        return 1
    fi
}

uninstall_all() {
    uninstall_core
    remove_legacy_settings_entries "$CLAUDE_HOME/settings.json"
    remove_legacy_marketplace_entries "$CLAUDE_HOME/plugins/known_marketplaces.json"
    remove_legacy_installed_plugins_entries "$CLAUDE_HOME/plugins/installed_plugins.json"
    remove_legacy_ecc_paths
    if [[ "$DRY_RUN" == true ]]; then
        dry "rm $CLAUDE_HOME/plugins/known_marketplaces.json"
    else
        rm -f "$CLAUDE_HOME/plugins/known_marketplaces.json"
        log "已移除 known_marketplaces.json"
    fi
    phase "Uninstall: 完成"
    info "settings.json 未被移除 (可能包含自定义配置)。如需重置: rm ~/.claude/settings.json"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -y|--yes) YES=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        --no-color) NO_COLOR=1
            RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
            shift ;;
        --ci) CI_MODE=true; shift ;;
        --no-claude) NO_CLAUDE=true; shift ;;
        --no-verify) NO_VERIFY=true; shift ;;
        --force) FORCE=true; shift ;;
        --update) UPDATE=true; shift ;;
        --smoke-test) SMOKE_TEST=true; shift ;;
        --skill)
            SELECTED_SKILL="${2:-}"
            [[ -n "$SELECTED_SKILL" ]] || { err "--skill 需要参数"; exit 1; }
            SELECTED_SKILLS+=("$SELECTED_SKILL")
            shift 2 ;;
        --skill=*)
            SELECTED_SKILL="${1#*=}"
            [[ -n "$SELECTED_SKILL" ]] || { err "--skill 需要参数"; exit 1; }
            SELECTED_SKILLS+=("$SELECTED_SKILL")
            shift ;;
        --plugin)
            SELECTED_PLUGIN="${2:-}"
            [[ -n "$SELECTED_PLUGIN" ]] || { err "--plugin 需要参数"; exit 1; }
            SELECTED_PLUGINS+=("$SELECTED_PLUGIN")
            shift 2 ;;
        --plugin=*)
            SELECTED_PLUGIN="${1#*=}"
            [[ -n "$SELECTED_PLUGIN" ]] || { err "--plugin 需要参数"; exit 1; }
            SELECTED_PLUGINS+=("$SELECTED_PLUGIN")
            shift ;;
        --skip-skills)
            SKIP_SKILLS=true
            shift ;;
        --skip-plugins)
            SKIP_PLUGINS=true
            shift ;;
        --agents)
            AGENTS_TARGET="${2:-}"
            [[ -n "$AGENTS_TARGET" ]] || { err "--agents 需要参数 (claude-code|<任意 agent 名>)"; exit 1; }
            # claude 是 claude-code 的别名：npx skills 的 agent key 只有 claude-code
            [[ "$AGENTS_TARGET" == "claude" ]] && AGENTS_TARGET="claude-code"
            shift 2 ;;
        --agents=*)
            AGENTS_TARGET="${1#*=}"
            [[ -n "$AGENTS_TARGET" ]] || { err "--agents 需要参数 (claude-code|<任意 agent 名>)"; exit 1; }
            [[ "$AGENTS_TARGET" == "claude" ]] && AGENTS_TARGET="claude-code"
            shift ;;
        --uninstall)
            _uninstall_target="${2:-}"
            [[ -n "$_uninstall_target" ]] || { err "--uninstall 需要参数 (core|all|清单中的 skill/plugin 名)"; exit 1; }
            if [[ "$_uninstall_target" =~ ^(core|all)$ ]] || manifest_has_skill "$_uninstall_target" || manifest_has_plugin "$_uninstall_target"; then
                UNINSTALL_LIST+=("$_uninstall_target")
            else
                err "--uninstall 参数无效: $_uninstall_target (有效值: core, all, 或清单中的 skill/plugin 名)"; exit 1
            fi
            shift 2 ;;
        --uninstall=*)
            _uninstall_target="${1#*=}"
            [[ -n "$_uninstall_target" ]] || { err "--uninstall 需要参数 (core|all|清单中的 skill/plugin 名)"; exit 1; }
            if [[ "$_uninstall_target" =~ ^(core|all)$ ]] || manifest_has_skill "$_uninstall_target" || manifest_has_plugin "$_uninstall_target"; then
                UNINSTALL_LIST+=("$_uninstall_target")
            else
                err "--uninstall 参数无效: $_uninstall_target (有效值: core, all, 或清单中的 skill/plugin 名)"; exit 1
            fi
            shift ;;
        --uninstall-skill)
            _uninstall_target="${2:-}"
            [[ -n "$_uninstall_target" ]] || { err "--uninstall-skill 需要参数"; exit 1; }
            manifest_has_skill "$_uninstall_target" || { err "--uninstall-skill 参数无效: $_uninstall_target (不在 skills.toml 中)"; exit 1; }
            UNINSTALL_TYPED_LIST+=("skill:$_uninstall_target")
            shift 2 ;;
        --uninstall-skill=*)
            _uninstall_target="${1#*=}"
            [[ -n "$_uninstall_target" ]] || { err "--uninstall-skill 需要参数"; exit 1; }
            manifest_has_skill "$_uninstall_target" || { err "--uninstall-skill 参数无效: $_uninstall_target (不在 skills.toml 中)"; exit 1; }
            UNINSTALL_TYPED_LIST+=("skill:$_uninstall_target")
            shift ;;
        --uninstall-plugin)
            _uninstall_target="${2:-}"
            [[ -n "$_uninstall_target" ]] || { err "--uninstall-plugin 需要参数"; exit 1; }
            manifest_has_plugin "$_uninstall_target" || { err "--uninstall-plugin 参数无效: $_uninstall_target (不在 plugins.toml 中)"; exit 1; }
            UNINSTALL_TYPED_LIST+=("plugin:$_uninstall_target")
            shift 2 ;;
        --uninstall-plugin=*)
            _uninstall_target="${1#*=}"
            [[ -n "$_uninstall_target" ]] || { err "--uninstall-plugin 需要参数"; exit 1; }
            manifest_has_plugin "$_uninstall_target" || { err "--uninstall-plugin 参数无效: $_uninstall_target (不在 plugins.toml 中)"; exit 1; }
            UNINSTALL_TYPED_LIST+=("plugin:$_uninstall_target")
            shift ;;
        --uninstall-resource)
            _uninstall_resource="${2:-}"
            [[ -n "$_uninstall_resource" ]] || { err "--uninstall-resource 需要参数"; exit 1; }
            UNINSTALL_RESOURCES+=("$_uninstall_resource")
            shift 2 ;;
        --uninstall-resource=*)
            _uninstall_resource="${1#*=}"
            [[ -n "$_uninstall_resource" ]] || { err "--uninstall-resource 需要参数"; exit 1; }
            UNINSTALL_RESOURCES+=("$_uninstall_resource")
            shift ;;
        --update-skill)
            UPDATE_SKILL="${2:-}"
            [[ -n "$UPDATE_SKILL" ]] || { err "--update-skill 需要参数"; exit 1; }
            [[ "$UPDATE_SKILL" =~ ^(core|all)$ ]] || manifest_has_skill "$UPDATE_SKILL" || { err "--update-skill 参数无效: $UPDATE_SKILL (有效值: core, all, 或 skills.toml 中的 skill 名)"; exit 1; }
            UPDATE_SKILLS+=("$UPDATE_SKILL")
            shift 2 ;;
        --update-skill=*)
            UPDATE_SKILL="${1#*=}"
            [[ "$UPDATE_SKILL" =~ ^(core|all)$ ]] || manifest_has_skill "$UPDATE_SKILL" || { err "--update-skill 参数无效: $UPDATE_SKILL (有效值: core, all, 或 skills.toml 中的 skill 名)"; exit 1; }
            UPDATE_SKILLS+=("$UPDATE_SKILL")
            shift ;;
        --update-local-skill)
            UPDATE_LOCAL_SKILL="${2:-}"
            [[ -n "$UPDATE_LOCAL_SKILL" ]] || { err "--update-local-skill 需要参数"; exit 1; }
            [[ -f "$REPO_ROOT/skills/$UPDATE_LOCAL_SKILL/SKILL.md" ]] || { err "--update-local-skill 参数无效: $UPDATE_LOCAL_SKILL (仓库 skills 中不存在)"; exit 1; }
            UPDATE_RESOURCES+=("skill:$UPDATE_LOCAL_SKILL")
            shift 2 ;;
        --update-local-skill=*)
            UPDATE_LOCAL_SKILL="${1#*=}"
            [[ -n "$UPDATE_LOCAL_SKILL" ]] || { err "--update-local-skill 需要参数"; exit 1; }
            [[ -f "$REPO_ROOT/skills/$UPDATE_LOCAL_SKILL/SKILL.md" ]] || { err "--update-local-skill 参数无效: $UPDATE_LOCAL_SKILL (仓库 skills 中不存在)"; exit 1; }
            UPDATE_RESOURCES+=("skill:$UPDATE_LOCAL_SKILL")
            shift ;;
        --update-plugin)
            UPDATE_PLUGIN="${2:-}"
            [[ -n "$UPDATE_PLUGIN" ]] || { err "--update-plugin 需要参数"; exit 1; }
            [[ "$UPDATE_PLUGIN" =~ ^(core|all)$ ]] || manifest_has_plugin "$UPDATE_PLUGIN" || { err "--update-plugin 参数无效: $UPDATE_PLUGIN (有效值: core, all, 或 plugins.toml 中的 plugin 名)"; exit 1; }
            UPDATE_PLUGINS+=("$UPDATE_PLUGIN")
            shift 2 ;;
        --update-plugin=*)
            UPDATE_PLUGIN="${1#*=}"
            [[ "$UPDATE_PLUGIN" =~ ^(core|all)$ ]] || manifest_has_plugin "$UPDATE_PLUGIN" || { err "--update-plugin 参数无效: $UPDATE_PLUGIN (有效值: core, all, 或 plugins.toml 中的 plugin 名)"; exit 1; }
            UPDATE_PLUGINS+=("$UPDATE_PLUGIN")
            shift ;;
        --update-resource)
            UPDATE_RESOURCE="${2:-}"
            [[ -n "$UPDATE_RESOURCE" ]] || { err "--update-resource 需要参数"; exit 1; }
            UPDATE_RESOURCES+=("$UPDATE_RESOURCE")
            shift 2 ;;
        --update-resource=*)
            UPDATE_RESOURCE="${1#*=}"
            [[ -n "$UPDATE_RESOURCE" ]] || { err "--update-resource 需要参数"; exit 1; }
            UPDATE_RESOURCES+=("$UPDATE_RESOURCE")
            shift ;;
        --choose)
            CHOICE="${2:-}"
            [[ -n "$CHOICE" ]] || { err "--choose 需要参数"; exit 1; }
            RESOURCE_CHOICES+=("$CHOICE")
            shift 2 ;;
        --choose=*)
            CHOICE="${1#*=}"
            [[ -n "$CHOICE" ]] || { err "--choose 需要参数"; exit 1; }
            RESOURCE_CHOICES+=("$CHOICE")
            shift ;;
        --update-all)
            UPDATE_ALL=true
            shift ;;
        -h|--help)
            echo "用法: ./setup.sh [action] [选项]"
            echo ""
            echo "action: install | update | reinstall | core | uninstall | verify | status | doctor | check | list"
            echo ""
            echo "安装  --skill <name>  只安装指定外部 skill（可重复，读 configs/skills.toml）"
            echo "      --plugin <name> 只安装指定第三方 plugin（可重复，读 configs/plugins.toml）"
            echo "      --skip-skills   跳过外部 skills 安装"
            echo "      --skip-plugins  跳过第三方 plugins 安装"
            echo "      --agents=NAME   NAME=claude-code（claude 为别名）走完整 claude 流程（默认）；其余取值"
            echo "                      = 只安装 skills 到 ~/.agents/skills/（跳过 claude code/核心配置/"
            echo "                      plugins/验证，配合 --skill/--update-local-skill 指定安装）"
            echo "      --force         强制重跑所有步骤 (忽略幂等检测)"
            echo ""
            echo "更新  --update                        兼容旧 flag：等价于 action=update"
            echo "      --update-all                    更新全部外部 skills + plugins (npx skills update + claude plugin update)"
            echo "      --update-resource kind:spec     按统一资源 id 更新（skill:<名> / plugin:<名>，冲突时需 --choose）"
            echo "      --update-local-skill N          更新指定仓库自有 skill（legacy；--agents 模式即安装入口，"
            echo "                                      装入 ~/.agents/skills）"
            echo "      --update-skill N                更新指定外部 skill（legacy：等价于 --update-resource skill:N；"
            echo "                                      需 skills.toml 有 source）"
            echo "      --update-plugin N               更新指定 plugin（legacy：等价于 --update-resource plugin:N）"
            echo ""
            echo "卸载  --uninstall T                   卸载单个/多个目标 (core|all|清单中的 skill/plugin 名，可重复出现，列表并发卸载)"
            echo "      --uninstall-resource kind:spec  按统一资源 id 卸载（skill:<名> / plugin:<名>，冲突时需 --choose）"
            echo "      --uninstall-skill N             卸载指定 skill（legacy：等价于 --uninstall-resource skill:N；"
            echo "                                      当前 skills.toml 为空清单，无合法值）"
            echo "      --uninstall-plugin N            卸载指定 plugin（legacy：等价于 --uninstall-resource plugin:N）"
            echo ""
            echo "诊断  --smoke-test    运行 Claude doctor 与 claude -p /context 扩展冒烟检查"
            echo "      --no-verify     跳过验证"
            echo ""
            echo "通用  --ci            CI 模式 (跳过手动提示，完整日志写入临时文件)"
            echo "      --dry-run       预览，不实际修改（与真实运行同构）"
            echo "      -y, --yes       跳过裸跑确认"
            echo "      -v, --verbose   恢复逐项输出"
            echo "      --no-color      关闭 ANSI 颜色"
            echo "      --no-claude     跳过 Claude Code 安装"
            echo "      --tui           启动交互式 TUI 安装器（需先构建 tools/installer-tui）"
            echo ""
            echo "高级  --choose kind:id=local|remote|skip  解决同名 local/remote 资源冲突（可重复）"
            exit 0 ;;
        install|update|reinstall|core|uninstall|verify|status|doctor|check|list)
            ACTION="$1"
            ACTION_EXPLICIT=true
            shift ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

if [[ "$UPDATE" == true && "$ACTION_EXPLICIT" == false ]]; then
    ACTION="update"
fi

# 互斥校验：显式选择与整类跳过冲突；update-all 与单项更新冲突
if [[ "$SKIP_SKILLS" == true && ${#SELECTED_SKILLS[@]} -gt 0 ]]; then
    err "--skip-skills 与 --skill 不能同时使用"; exit 1
fi
if [[ "$SKIP_PLUGINS" == true && ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
    err "--skip-plugins 与 --plugin 不能同时使用"; exit 1
fi
if [[ "$UPDATE_ALL" == true && (${#UPDATE_SKILLS[@]} -gt 0 || ${#UPDATE_LOCAL_SKILLS[@]} -gt 0 || ${#UPDATE_PLUGINS[@]} -gt 0 || ${#UPDATE_RESOURCES[@]} -gt 0) ]]; then
    err "--update-all 与单项 skill/plugin 更新不能同时使用"; exit 1
fi

# --ci 全量落盘：CI 里失败后只能拿到被截断的关键字片段，留完整日志便于事后定位。
# BASH_SOURCE==$0 守卫必须有：测试会 source 本文件，否则会劫持测试进程的 stdout。
if [[ "$CI_MODE" == true && "${BASH_SOURCE[0]}" == "$0" ]]; then
    SETUP_LOG="${SETUP_LOG:-$(mktemp -t setup-ci-XXXXXX.log)}"
    exec > >(tee -a "$SETUP_LOG") 2>&1
    printf '%s完整日志: %s%s\n' "$BLUE" "$SETUP_LOG" "$NC"
fi

main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Claude Code Config Migration v3    ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    # 非 claude 目标：只支持 skills，拦截所有非安装参数，只跑 skills 安装流程后退出。
    # （claude code / core config / plugins / verify 一律不执行。）
    # 注：UPDATE_RESOURCES 允许——--update-local-skill 经参数解析转为 skill:NAME，
    # 是该模式下"指定安装仓库自有 skill"的入口，run_agents_flow 会按本地 skill 处理。
    if ! agents_is_claude; then
        if [[ ${#UNINSTALL_LIST[@]} -gt 0 || ${#UNINSTALL_TYPED_LIST[@]} -gt 0 || \
              ${#UNINSTALL_RESOURCES[@]} -gt 0 || "$UPDATE_ALL" == true || \
              ${#UPDATE_SKILLS[@]} -gt 0 || ${#UPDATE_PLUGINS[@]} -gt 0 ]]; then
            err "--agents=$AGENTS_TARGET 仅支持安装，不支持 update/uninstall 参数"
            return 1
        fi
        [[ "$ACTION" == "install" || "$ACTION" == "update" || "$ACTION" == "reinstall" ]] || {
            err "--agents=$AGENTS_TARGET 仅支持 install/update/reinstall，收到 action: $ACTION"
            return 1
        }

        phase "Phase 0: 环境检测"
        ensure_system_dependencies || exit 1
        run_agents_flow
        echo ""
        echo -e "${GREEN}============================================${NC}"
        echo -e "${GREEN}  Agents skills 安装完成! (--agents=$AGENTS_TARGET)${NC}"
        [[ "$DRY_RUN" == true ]] && dry "(dry-run 预览，未做任何修改)"
        echo -e "${GREEN}============================================${NC}"
        echo ""
        info "非 claude 模式只安装 skills，未安装任何 claude 配置/plugins"
        echo "验证: ls $AGENTS_SKILLS_HOME/"
        return 0
    fi

    # --uninstall: 单个/多个目标卸载（core/all 串行，清单项有限并发）
    # typed 目标（skill:NAME / plugin:NAME）并入同一列表，复用并发/去重/限流
    local -a uninstall_targets=("${UNINSTALL_LIST[@]}" "${UNINSTALL_TYPED_LIST[@]}")
    if [[ ${#uninstall_targets[@]} -gt 0 ]]; then
        uninstall_multi "${uninstall_targets[@]}" || { err "卸载未全部完成"; return 1; }
        echo ""
        log "卸载完成 (${uninstall_targets[*]})"
        [[ "$DRY_RUN" == true ]] && warn "DRY-RUN — 未实际修改文件"
        return 0
    fi
    # 统一资源卸载入口：走同一 discover/conflict/select 流程。
    if [[ ${#UNINSTALL_RESOURCES[@]} -gt 0 ]]; then
        resource_uninstall || return $?
        echo ""
        return 0
    fi

    # 完全裸跑（零参数零 action）时先给预执行摘要，再确认一次；明确意图的调用不打扰。
    if [[ ${#ORIGINAL_ARGS[@]} -eq 0 ]]; then
        summarize_install_plan
        if ! read_confirm "继续安装?"; then
            log "已取消，未做任何修改"
            return 0
        fi
    fi

    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN — 不会实际修改文件"
    [[ "$CI_MODE" == true ]] && info "CI 模式"
    [[ "$ACTION" == "update" && "$FORCE" == true ]] && info "Update 模式 — 将更新仓库与配置中的第三方仓库，并强制重跑安装器"
    [[ "$ACTION" == "update" && "$FORCE" == false ]] && info "Update 模式 — 将更新仓库与配置中的第三方仓库；不会重跑第三方安装器"

    # --update-all / --update-skill / --update-plugin: 单独入口，跑完即退出。
    # 任一项失败最终非零（失败聚合），不能后续项成功覆盖 rc。
    local update_failed=0
    if [[ "$UPDATE_ALL" == true ]]; then
        phase "Phase 0: 更新全部"
        update_all_skills || update_failed=1
        update_all_plugins || update_failed=1
        echo ""
        if [[ "$update_failed" == 0 ]]; then
            log "全部外部 skills + plugins 已更新"
        else
            err "部分更新失败"; print_retry_hint
        fi
        return "$update_failed"
    fi
    # 统一资源更新入口（含旧参数经兼容转换进入的 UPDATE_RESOURCES）。
    if [[ ${#UPDATE_RESOURCES[@]} -gt 0 ]]; then
        resource_update || return $?
        echo ""
        return 0
    fi
    if [[ ${#UPDATE_SKILLS[@]} -gt 0 || ${#UPDATE_LOCAL_SKILLS[@]} -gt 0 || ${#UPDATE_PLUGINS[@]} -gt 0 ]]; then
        phase "Phase 0: 更新指定项"
        local s ls p
        for s in "${UPDATE_SKILLS[@]}"; do
            if [[ "$s" == core || "$s" == all ]]; then
                update_all_skills || update_failed=1
            else
                update_skill "$s" || update_failed=1
            fi
        done
        for ls in "${UPDATE_LOCAL_SKILLS[@]}"; do
            update_local_skill "$ls" || update_failed=1
        done
        for p in "${UPDATE_PLUGINS[@]}"; do
            if [[ "$p" == core || "$p" == all ]]; then
                update_all_plugins || update_failed=1
            else
                update_plugin "$p" || update_failed=1
            fi
        done
        echo ""
        if [[ "$update_failed" == 0 ]]; then
            log "指定项更新完成 (外部 skills: ${UPDATE_SKILLS[*]:-无} / 仓库 skills: ${UPDATE_LOCAL_SKILLS[*]:-无} / plugins: ${UPDATE_PLUGINS[*]:-无})"
        else
            err "部分指定项更新失败"; print_retry_hint
        fi
        return "$update_failed"
    fi

    if [[ "$ACTION" == "update" ]]; then
        phase "Phase 0: 仓库更新"
        UPDATE=true
        update_repository
    fi

    phase "Phase 0: 环境检测"
    ensure_system_dependencies || exit 1
    info "系统: $(uname -s) / $(uname -m)"

    # 检查类 action 的输出本身就是产物，不能被 VERBOSE 静默。
    # --ci 同理：workflow 会 grep 逐项验证证据（如「settings.json 已补齐模板键并保留用户值」），
    # 静默会直接让 CI 判定缺少证据。
    case "$ACTION" in
        check|verify|status|doctor|list) VERBOSE=true ;;
    esac
    [[ "$CI_MODE" == true ]] && VERBOSE=true

    case "$ACTION" in
        install|update|reinstall)
            run_install_flow
            echo ""
            echo -e "${GREEN}============================================${NC}"
            echo -e "${GREEN}  Claude Code 配置迁移完成!${NC}"
            [[ "$DRY_RUN" == true ]] && dry "(dry-run 预览，未做任何修改)"
            echo -e "${GREEN}============================================${NC}"
            echo ""
            if [[ "$CI_MODE" == true ]]; then
                log "CI 模式 — 所有配置已自动完成"
            else
                echo "验证: claude --version"
                echo "      ls ~/.claude/plugins/marketplaces/"
                echo ""
            fi
            ;;
        core)
            run_core_flow
            echo ""
            echo -e "${GREEN}============================================${NC}"
            echo -e "${GREEN}  Claude Core 配置已同步!${NC}"
            [[ "$DRY_RUN" == true ]] && dry "(dry-run 预览，未做任何修改)"
            echo -e "${GREEN}============================================${NC}"
            echo ""
            ;;
        verify|status|doctor)
            run_inspection_flow
            ;;
        check)
            run_check_flow
            ;;
        list)
            run_list_flow
            ;;
        uninstall)
            uninstall_all
            ;;
        *)
            err "未处理的 action: $ACTION"
            exit 1
            ;;
    esac
}

# ponytail: source guard — 允许测试 source 本文件单测各 helper, 不触发 main
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
