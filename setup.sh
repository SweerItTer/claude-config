#!/usr/bin/env bash
# ============================================================
# Claude Code Config Migration — 一键初始化脚本 v3
# 用法: git clone --recurse-submodules <repo-url> && ./setup.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
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

DRY_RUN=false
CI_MODE=false
NO_CLAUDE=false
NO_VERIFY=false
FORCE=false
SMOKE_TEST=false
UPDATE=false
ECC_FULL=false
ECC_FOCUSED=false
ECC_PROFILE=""
ECC_MODULES=""

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
phase() { echo ""; echo -e "${BLUE}═══ $* ═══${NC}"; echo ""; }
pass()  { echo -e "${BLUE}[PASS]${NC} $*"; }

symlink_points_to() {
    local link="$1"
    local target="$2"
    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

ensure_managed_block() {
    local src="$1"
    local dst="$2"
    local block_name="$3"
    local label="$4"
    local start_marker="<!-- ${block_name}:START -->"
    local end_marker="<!-- ${block_name}:END -->"

    [[ -f "$src" ]] || return 0

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] merge $src into $dst as $block_name block"
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
start_re = rf'<!--\s*{re.escape(name)}:START\s*-->'
end_re = rf'<!--\s*{re.escape(name)}:END\s*-->'

raw_source = src.read_text(encoding='utf-8').strip()
inner_pattern = re.compile(rf'(?ms)^\s*{start_re}\s*\n(.*?)\n{end_re}\s*$')
match = inner_pattern.match(raw_source)
inner = match.group(1).strip() if match else raw_source
inner = re.sub(r'^<!-- hash:[0-9a-f]+ -->\s*\n', '', inner, count=1).strip()
digest = hashlib.sha256(inner.encode('utf-8')).hexdigest()[:16]
source = f'{start}\n<!-- hash:{digest} -->\n{inner}\n{end}'

existing = dst.read_text(encoding='utf-8') if dst.exists() else ''
block_pattern = re.compile(rf'(?ms)^\s*{start_re}\s*\n(.*?)\n{end_re}\s*')
block_match = block_pattern.search(existing)
if block_match:
    current_hash = re.search(r'<!-- hash:([0-9a-f]+) -->', block_match.group(1))
    if current_hash and current_hash.group(1) == digest:
        sys.exit(0)
    merged = block_pattern.sub(source, existing, count=1).strip() + '\n'
elif existing.strip():
    merged = existing.rstrip() + '\n\n' + source + '\n'
else:
    merged = source + '\n'

dst.write_text(merged, encoding='utf-8')
PYEOF

    log "$label 已合并"
}

ensure_symlink() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if symlink_points_to "$dst" "$src"; then
        pass "$label 已就绪"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] ln -sfn $src -> $dst"
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    if [[ -L "$dst" || -f "$dst" ]]; then
        rm -f "$dst"
    elif [[ -d "$dst" ]]; then
        rm -rf "$dst"
    fi
    ln -sfn "$src" "$dst"
    log "$label 已更新"
}

run_installer() {
    local name="$1"
    local script="$SCRIPT_DIR/install-${name}.sh"
    shift || true

    if [[ ! -f "$script" ]]; then
        err "安装脚本不存在: $script"
        return 1
    fi

    info "--- ${name} ---"
    bash "$script" "$REPO_ROOT" "$DRY_RUN" "$FORCE" "$@"
}

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


def merge_object(dst, src, skip_empty=False, prefer_existing=False):
    base = dict(dst) if isinstance(dst, dict) else {}
    if isinstance(src, dict):
        for key, value in src.items():
            if skip_empty and value == '':
                continue
            if prefer_existing and key in base:
                continue
            base[key] = value
    return base


def merge_list(existing, template):
    existing_list = existing if isinstance(existing, list) else []
    template_list = template if isinstance(template, list) else []
    merged = list(existing_list)
    seen = {json.dumps(item, sort_keys=True, ensure_ascii=False) for item in existing_list}
    for item in template_list:
        key = json.dumps(item, sort_keys=True, ensure_ascii=False)
        if key not in seen:
            merged.append(item)
            seen.add(key)
    return merged


def merge_permissions(existing, template):
    merged = merge_object(existing, template, prefer_existing=True)
    if isinstance(template, dict):
        for key, value in template.items():
            if isinstance(value, list):
                merged[key] = merge_list(merged.get(key), value)
    return merged


path = os.environ['TARGET_SETTINGS_PATH']
rendered_template = os.environ['RENDERED_TEMPLATE_JSON']
with open(path, 'r', encoding='utf-8') as fh:
    current = json.load(fh)
template = json.loads(rendered_template)

current['env'] = merge_object(current.get('env'), template.get('env'), skip_empty=True, prefer_existing=True)
current['enabledPlugins'] = merge_object(current.get('enabledPlugins'), template.get('enabledPlugins'), prefer_existing=True)
current['extraKnownMarketplaces'] = merge_object(current.get('extraKnownMarketplaces'), template.get('extraKnownMarketplaces'), prefer_existing=True)

hooks = current.get('hooks') if isinstance(current.get('hooks'), dict) else {}
template_hooks = template.get('hooks') if isinstance(template.get('hooks'), dict) else {}
for hook_name, template_items in template_hooks.items():
    hooks[hook_name] = merge_list(hooks.get(hook_name), template_items)
current['hooks'] = hooks

if 'permissions' in template:
    current['permissions'] = merge_permissions(current.get('permissions'), template.get('permissions'))

if 'disabledMcpServers' in template:
    current['disabledMcpServers'] = merge_list(current.get('disabledMcpServers'), template.get('disabledMcpServers'))

for key in ['think', 'skipDangerousModePermissionPrompt', 'attribution', 'statusLine', 'language', 'effortLevel']:
    if key in template and key not in current:
        current[key] = template[key]

with open(path, 'w', encoding='utf-8') as fh:
    json.dump(current, fh, indent=4, ensure_ascii=False)
    fh.write('\n')
PYEOF
}

submodules_clean() {
    (
        cd "$REPO_ROOT"
        [[ $(git submodule status | grep -c '^-') -eq 0 ]]
    )
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
            info "[DRY-RUN] npm install -g @anthropic-ai/claude-code"
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
            info "[DRY-RUN] 后台启动 Claude Code 初始化 CLAUDE_HOME"
            return 0
        fi
        claude </dev/null >/dev/null 2>&1 &
        info "CLAUDE_HOME 未初始化，已后台启动 Claude Code (PID $!)"
        claude_bootstrap=true
    fi

    [[ "$claude_bootstrap" == false ]] && pass "Claude Code 已就绪"
}

ensure_submodules() {
    if [[ "$FORCE" == false ]] && submodules_clean; then
        pass "Submodules 已就绪"
        return 0
    fi

    info "初始化 git submodules..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] git submodule update --init --recursive"
        return 0
    fi

    (
        cd "$REPO_ROOT"
        git submodule update --init --recursive
    )
    log "Submodules 就绪"
}

update_repository() {
    if [[ "$SETUP_UPDATE_REEXECED" == true ]]; then
        pass "仓库更新阶段已完成"
        return 0
    fi

    info "更新当前仓库与第三方 submodules..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] git pull --ff-only"
        info "[DRY-RUN] git submodule sync --recursive"
        info "[DRY-RUN] git submodule update --init --recursive --remote"
        info "[DRY-RUN] SETUP_UPDATE_REEXECED=true ./setup.sh ${ORIGINAL_ARGS[*]}"
        return 0
    fi

    (
        cd "$REPO_ROOT"
        git pull --ff-only
        git submodule sync --recursive
        git submodule update --init --recursive --remote
    )

    export SETUP_UPDATE_REEXECED=true
    log "仓库与第三方 submodules 已更新"
    info "重新执行 setup 以加载更新后的脚本..."
    exec "$REPO_ROOT/setup.sh" "${ORIGINAL_ARGS[@]}"
}

ensure_core_config() {
    mkdir -p "$CLAUDE_HOME"

    ensure_managed_block "$REPO_ROOT/config/claude/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md" "Claude-Config" "CLAUDE.md 配置块"

    for file in RTK.md AGENTS.md; do
        local src="$REPO_ROOT/config/claude/$file"
        local dst="$CLAUDE_HOME/$file"
        [[ -f "$src" ]] || continue
        ensure_symlink "$src" "$dst" "$file symlink"
    done

    ensure_symlink "$REPO_ROOT/config/claude/rules" "$CLAUDE_HOME/rules" "rules symlink"
    ensure_symlink "$REPO_ROOT/config/claude/rules-available" "$CLAUDE_HOME/rules-available" "rules-available symlink"
    ensure_symlink "$REPO_ROOT/config/claude/hooks/rules-loader.sh" "$CLAUDE_HOME/hooks/rules-loader.sh" "rules-loader hook"

    local cpo_src="$REPO_ROOT/external/claude-plugins-official"
    local cpo_dst="$CLAUDE_HOME/plugins/marketplaces/claude-plugins-official"
    if [[ -d "$cpo_src" ]]; then
        ensure_symlink "$cpo_src" "$cpo_dst" "claude-plugins-official marketplace"
    fi
}

ensure_settings_json() {
    local template="$REPO_ROOT/config/claude/settings.template.json"
    local target="$CLAUDE_HOME/settings.json"

    if [[ ! -f "$template" ]]; then
        warn "settings.template.json 不存在，跳过"
        return 0
    fi

    local rendered_settings
    rendered_settings="$(render_settings_template "$template")"

    if [[ -f "$target" ]] && [[ "$CI_MODE" != true ]]; then
        info "合并现有 settings.json..."
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] merge settings.json with template-backed migration keys"
            return 0
        fi
        mkdir -p "$CLAUDE_HOME"
        merge_settings_json "$target" "$rendered_settings"
        log "settings.json 已合并"
        return 0
    fi

    info "生成 settings.json..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] write rendered settings.json"
        return 0
    fi

    mkdir -p "$CLAUDE_HOME"
    printf '%s\n' "$rendered_settings" > "$target"
    log "settings.json 已生成"
}

generate_known_marketplaces() {
    local target="$CLAUDE_HOME/plugins/known_marketplaces.json"

    info "生成 known_marketplaces.json..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] write $target"
        return 0
    fi

    mkdir -p "$CLAUDE_HOME/plugins"
    python3 - "$REPO_ROOT" <<'PYEOF' > "$target"
import json
import os
import sys

repo = sys.argv[1]
ts = "2026-01-01T00:00:00.000Z"
markets = {
    "claude-plugins-official": {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}, "dir": "external/claude-plugins-official"},
    "context-mode": {"source": {"source": "github", "repo": "mksglu/context-mode"}, "dir": "external/context-mode"},
    "omc": {"source": {"source": "git", "url": "https://github.com/Yeachan-Heo/oh-my-claudecode.git"}, "dir": "external/oh-my-claudecode"},
    "superpowers": {"source": {"source": "git", "url": "https://github.com/obra/superpowers.git"}, "dir": "external/superpowers"},
}
out = {}
for name, info in markets.items():
    out[name] = {
        "source": info["source"],
        "installLocation": os.path.join(repo, info["dir"]),
        "lastUpdated": ts,
    }
json.dump(out, sys.stdout, indent=4)
print()
PYEOF
    log "known_marketplaces.json 已生成"
}

verify_core_config() {
    if [[ "$NO_VERIFY" == true || "$DRY_RUN" == true ]]; then
        info "跳过 setup 级验证"
        return 0
    fi

    local failed=0
    if grep -Eq '<!--[[:space:]]*Claude-Config:START[[:space:]]*-->' "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null \
        && grep -Eq '<!--[[:space:]]*Claude-Config:END[[:space:]]*-->' "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null; then
        pass "CLAUDE.md 配置块"
    else
        err "CLAUDE.md 配置块缺失"
        failed=1
    fi

    for file in RTK.md AGENTS.md; do
        if symlink_points_to "$CLAUDE_HOME/$file" "$REPO_ROOT/config/claude/$file"; then
            pass "$file symlink"
        else
            err "$file symlink 缺失"
            failed=1
        fi
    done

    if symlink_points_to "$CLAUDE_HOME/rules" "$REPO_ROOT/config/claude/rules"; then
        pass "rules symlink"
    else
        err "rules symlink 缺失"
        failed=1
    fi

    if symlink_points_to "$CLAUDE_HOME/rules-available" "$REPO_ROOT/config/claude/rules-available"; then
        pass "rules-available symlink"
    else
        err "rules-available symlink 缺失"
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
        err "known_marketplaces.json 不存在"
        failed=1
    fi

    [[ $failed -eq 0 ]]
}

run_context_smoke_test() {
    if ! command -v claude >/dev/null 2>&1; then
        err "Claude -p /context 检查失败: claude 命令不存在"
        return 1
    fi

    local timeout_seconds="${CLAUDE_CONTEXT_TIMEOUT:-180}"
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

    log "Claude -p /context 上下文注入检查通过"
    rm -f "$tmp"
}

run_final_doctor() {
    if [[ "$NO_VERIFY" == true ]]; then
        info "跳过最终 doctor (--no-verify)"
        return 0
    fi

    if [[ "$SMOKE_TEST" != true ]]; then
        info "跳过最终 doctor (--smoke-test 未启用)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] script/check-claude-doctor.sh"
        info "[DRY-RUN] claude -p /context"
        return 0
    fi

    info "运行最终 Claude doctor..."
    if timeout 120 "$REPO_ROOT/script/check-claude-doctor.sh"; then
        log "Claude doctor 通过"
    else
        local rc=$?
        if [[ $rc -eq 124 ]]; then
            err "Claude doctor 超时"
        else
            err "Claude doctor 失败 ($rc)"
        fi
        return 1
    fi

    info "运行 Claude -p /context 上下文注入检查..."
    run_context_smoke_test
    log "安装后冒烟测试通过: Claude doctor + Claude -p /context"
    return 0
}

UNINSTALL=""

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
        info "[DRY-RUN] rm $path"
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
        info "[DRY-RUN] remove $block_name block from $path"
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

uninstall_core() {
    phase "Uninstall: 核心配置"
    local repo="$REPO_ROOT/config/claude"
    remove_managed_block "$CLAUDE_HOME/CLAUDE.md" "Claude-Config" "CLAUDE.md 配置块"
    remove_symlink_if_ours "$CLAUDE_HOME/CLAUDE.md" "CLAUDE.md symlink" "$repo/CLAUDE.md"
    remove_symlink_if_ours "$CLAUDE_HOME/RTK.md" "RTK.md" "$repo/RTK.md"
    remove_symlink_if_ours "$CLAUDE_HOME/AGENTS.md" "AGENTS.md" "$repo/AGENTS.md"
    remove_symlink_if_ours "$CLAUDE_HOME/rules" "rules/" "$repo/rules"
    remove_symlink_if_ours "$CLAUDE_HOME/rules-available" "rules-available/" "$repo/rules-available"
    remove_symlink_if_ours "$CLAUDE_HOME/hooks/rules-loader.sh" "rules-loader hook" "$repo/hooks/rules-loader.sh"
    # 如果 hooks 目录为空则清理
    if [[ -d "$CLAUDE_HOME/hooks" ]]; then
        rmdir "$CLAUDE_HOME/hooks" 2>/dev/null && info "已清理空 hooks 目录" || true
    fi
}

clean_installed_plugins_json() {
    local target="$CLAUDE_HOME/plugins/installed_plugins.json"
    [[ -f "$target" ]] || return 0
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] 从 installed_plugins.json 移除 ecc@ecc"
        return 0
    fi
    python3 - "$target" <<'PYEOF'
import json, sys
with open(sys.argv[1], 'r+') as f:
    data = json.load(f)
    data.get('plugins', {}).pop('ecc@ecc', None)
    data.get('enabledPlugins', {}).pop('ecc@ecc', None)
    f.seek(0)
    json.dump(data, f, indent=2)
    f.write('\n')
    f.truncate()
PYEOF
}

uninstall_ecc() {
    phase "Uninstall: ECC"
    local ecc_dir="$REPO_ROOT/external/everything-claude-code"
    remove_symlink_if_ours "$CLAUDE_HOME/plugins/marketplaces/ecc" "ECC marketplace" "$ecc_dir"
    rm -rf "$CLAUDE_HOME/ecc"
    rm -rf "$CLAUDE_HOME/plugins/cache/ecc"
    clean_installed_plugins_json
    log "已移除 ECC install-state + plugin cache + installed_plugins 注册"
}

uninstall_all() {
    uninstall_core
    uninstall_ecc
    remove_symlink_if_ours "$CLAUDE_HOME/plugins/marketplaces/claude-plugins-official" "CPO marketplace" "$REPO_ROOT/external/claude-plugins-official"
    rm -f "$CLAUDE_HOME/plugins/known_marketplaces.json"
    log "已移除 known_marketplaces.json"
    phase "Uninstall: 完成"
    info "settings.json 未被移除 (可能包含自定义配置)。如需重置: rm ~/.claude/settings.json"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --ci) CI_MODE=true; shift ;;
        --no-claude) NO_CLAUDE=true; shift ;;
        --no-verify) NO_VERIFY=true; shift ;;
        --force) FORCE=true; shift ;;
        --update) UPDATE=true; shift ;;
        --smoke-test) SMOKE_TEST=true; shift ;;
        --ecc-full) ECC_FULL=true; shift ;;
        --ecc-focused) ECC_FOCUSED=true; shift ;;
        --ecc-profile)
            ECC_PROFILE="${2:-}"
            [[ -n "$ECC_PROFILE" ]] || { err "--ecc-profile 需要 profile 名称"; exit 1; }
            shift 2 ;;
        --ecc-modules)
            ECC_MODULES="${2:-}"
            [[ -n "$ECC_MODULES" ]] || { err "--ecc-modules 需要逗号分隔模块 ID"; exit 1; }
            shift 2 ;;
        --uninstall)
            UNINSTALL="${2:-core}"
            [[ "$UNINSTALL" =~ ^(core|ecc|all)$ ]] || { err "--uninstall 参数无效: $UNINSTALL (有效值: core, ecc, all)"; exit 1; }
            shift 2 ;;
        --uninstall=*)
            UNINSTALL="${1#*=}"
            [[ "$UNINSTALL" =~ ^(core|ecc|all)$ ]] || { err "--uninstall 参数无效: $UNINSTALL (有效值: core, ecc, all)"; exit 1; }
            shift ;;
        -h|--help)
            echo "用法: ./setup.sh [选项]"
            echo "  --ci            CI 模式 (跳过手动提示，ECC 使用全量安装以覆盖测试)"
            echo "  --dry-run       预览，不实际修改"
            echo "  --no-claude     跳过 Claude Code 安装"
            echo "  --no-verify     跳过验证"
            echo "  --force         强制重跑所有步骤 (忽略幂等检测)"
            echo "  --update        更新当前仓库与第三方 submodules；搭配 --force 可强制重跑安装器"
            echo "  --smoke-test    运行 Claude doctor 与 claude -p /context 冒烟检查"
            echo "  --ecc-full      安装 ECC full profile"
            echo "  --ecc-focused   安装 4 个基础 ECC 模块（agents/commands/hooks/workflow）"
            echo "  --ecc-profile P 安装 ECC 官方 profile: minimal/core/developer/security/research/full"
            echo "  --ecc-modules M 安装逗号分隔的 ECC 模块 ID"
            echo "  --uninstall [M] 卸载配置 (core=核心配置, ecc=含ECC, all=全部)"
            exit 0 ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Claude Code Config Migration v3    ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    if [[ -n "$UNINSTALL" ]]; then
        case "$UNINSTALL" in
            core) uninstall_core ;;
            ecc) uninstall_core && uninstall_ecc ;;
            all) uninstall_all ;;
        esac
        echo ""
        log "卸载完成 ($UNINSTALL)"
        [[ "$DRY_RUN" == true ]] && warn "DRY-RUN — 未实际修改文件"
        return 0
    fi

    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN — 不会实际修改文件"
    [[ "$CI_MODE" == true ]] && info "CI 模式"
    [[ "$UPDATE" == true && "$FORCE" == true ]] && info "Update 模式 — 将更新仓库/submodules 并强制重跑安装器"
    [[ "$UPDATE" == true && "$FORCE" == false ]] && info "Update 模式 — 将更新仓库/submodules；不会重跑第三方安装器"

    if [[ "$UPDATE" == true ]]; then
        phase "Phase 0: 仓库更新"
        update_repository
    fi

    phase "Phase 0: 环境检测"
    local missing=()
    for dep in git curl tar node npm python3; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && { err "缺少依赖: ${missing[*]}"; exit 1; }
    log "git, curl, tar, node, npm, python3 已就绪"
    info "系统: $(uname -s) / $(uname -m)"

    phase "Phase 1: Claude Code"
    ensure_claude_code

    phase "Phase 2: Git Submodules + 核心配置"
    ensure_submodules
    ensure_core_config

    if [[ "$UPDATE" == true && "$FORCE" == false ]]; then
        ensure_settings_json
        generate_known_marketplaces
        phase "Phase 5: 最终验证"
        verify_core_config
        run_final_doctor
        echo ""
        echo -e "${GREEN}============================================${NC}"
        echo -e "${GREEN}  Claude Code 配置更新完成!${NC}"
        echo -e "${GREEN}============================================${NC}"
        echo ""
        return 0
    fi

    phase "Phase 3: 安装器编排"
    local ecc_mode="interactive"
    if [[ "$CI_MODE" == true || "$ECC_FULL" == true ]]; then
        ecc_mode="full"
    elif [[ "$ECC_FOCUSED" == true ]]; then
        ecc_mode="focused"
    elif [[ -n "$ECC_PROFILE" ]]; then
        ecc_mode="profile:$ECC_PROFILE"
    elif [[ -n "$ECC_MODULES" ]]; then
        ecc_mode="modules:$ECC_MODULES"
    fi
    run_installer ecc "$ecc_mode"
    run_installer context-mode
    run_installer openspec

    phase "Phase 4: settings.json + 后置安装器"
    ensure_settings_json
    run_installer omc
    run_installer rtk
    run_installer superpowers
    generate_known_marketplaces
    clean_installed_plugins_json

    phase "Phase 5: 最终验证"
    verify_core_config
    run_final_doctor

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Claude Code 配置迁移完成!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    if [[ "$CI_MODE" == true ]]; then
        log "CI 模式 — 所有配置已自动完成"
    else
        echo "验证: claude --version  |  rtk --version"
        echo "      ls ~/.claude/plugins/marketplaces/"
        echo ""
    fi
}

main "$@"
