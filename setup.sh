#!/usr/bin/env bash
# ============================================================
# Claude Code Config Migration — 一键初始化脚本 v3
# 用法: git clone --recurse-submodules <repo-url> && ./setup.sh
#
# 5 阶段:
#   0. 环境检测 (OS, deps, Claude Code)
#   1. 安装 Claude Code (可选)
#   2. Git Submodules
#   3. 安装插件 (RTK → ECC → context-mode → OpenSpec → superpowers 前半)
#   4. 生成 settings.json + OMC setup (后半)
#   5. 文件验证 + script/check-claude-doctor.sh 插件迁移检查
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SCRIPT_DIR="$REPO_ROOT/script"

DRY_RUN=false
CI_MODE=false
NO_CLAUDE=false
NO_VERIFY=false
FORCE=false
SMOKE_TEST=false

# ----- helpers -----
log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
phase() { echo ""; echo -e "${BLUE}═══ $* ═══${NC}"; echo ""; }

run_installer() {
    local name="$1"
    local script="$SCRIPT_DIR/install-${name}.sh"
    if [[ ! -f "$script" ]]; then
        err "安装脚本不存在: $script"
        return 1
    fi
    info "--- ${name} ---"
    bash "$script" "$REPO_ROOT" "$DRY_RUN"
}

symlink_points_to() {
    local link="$1"
    local target="$2"
    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

render_settings_template() {
    local tmpl="$1"
    local content; content="$(cat "$tmpl")"
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
import sys


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

for key in ['think', 'skipDangerousModePermissionPrompt', 'attribution', 'statusLine', 'language', 'effortLevel']:
    if key in template and key not in current:
        current[key] = template[key]

with open(path, 'w', encoding='utf-8') as fh:
    json.dump(current, fh, indent=4, ensure_ascii=False)
    fh.write('\n')
PYEOF
}

# 幂等跳过: 检测命令成功则跳过 (除非 --force)
skip_if_done() {
    local desc="$1"
    shift
    if [[ "$FORCE" == true ]]; then
        info "$desc: --force 强制重跑"
        return 1
    fi
    if "$@" >/dev/null 2>&1; then
        echo -e "${BLUE}[PASS]${NC} $desc: 已完成，跳过"
        return 0
    fi
    return 1
}

submodules_clean() {
    cd "$REPO_ROOT" && [[ $(git submodule status | grep -c '^-') -eq 0 ]]
}

rtk_ready() {
    command -v rtk >/dev/null 2>&1 && [[ -L "$HOME/.config/rtk/config.toml" ]]
}

ecc_installed() {
    [[ -f "$CLAUDE_HOME/ecc/install-state.json" ]]
}

context_mode_ready() {
    [[ -d "$REPO_ROOT/external/context-mode/node_modules" ]] && symlink_points_to "$CLAUDE_HOME/plugins/marketplaces/context-mode" "$REPO_ROOT/external/context-mode"
}

context_mode_current_ready() {
    local ctx_cache="$CLAUDE_HOME/plugins/cache/context-mode/context-mode"
    [[ -d "$ctx_cache" ]] || return 1
    local ctx_latest
    ctx_latest="$(ls -d "$ctx_cache"/*/ 2>/dev/null | sort -V | tail -1)" || true
    [[ -n "$ctx_latest" ]] || return 1
    ctx_latest="${ctx_latest%/}"
    [[ -L "$ctx_cache/current" ]] && [[ $(readlink "$ctx_cache/current") = "$ctx_latest" ]]
}

openspec_binary_ready() {
    command -v openspec >/dev/null 2>&1
}

openspec_version_ready() {
    openspec --version >/dev/null 2>&1
}

known_marketplaces_paths_ready() {
    local km="$CLAUDE_HOME/plugins/known_marketplaces.json"
    [[ -f "$km" ]] || return 1

    python3 - "$REPO_ROOT" "$km" <<'PY'
import json
import os
import sys

repo_root = sys.argv[1]
km_path = sys.argv[2]
expected = {
    "claude-plugins-official": "external/claude-plugins-official",
    "context-mode": "external/context-mode",
    "ecc": "external/everything-claude-code",
    "omc": "external/oh-my-claudecode",
    "superpowers": "external/superpowers",
}

with open(km_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict):
    raise SystemExit(1)

for name, rel_path in expected.items():
    entry = data.get(name)
    if not isinstance(entry, dict):
        raise SystemExit(1)
    if entry.get("installLocation") != os.path.join(repo_root, rel_path):
        raise SystemExit(1)
    source = entry.get("source")
    if not isinstance(source, dict) or not source:
        raise SystemExit(1)
PY
}

rtk_binary_ready() {
    command -v rtk >/dev/null 2>&1
}

rtk_version_ready() {
    rtk --version >/dev/null 2>&1
}

rtk_config_ready() {
    [[ -L "$HOME/.config/rtk/config.toml" ]]
}

superpowers_ready() {
    symlink_points_to "$CLAUDE_HOME/plugins/marketplaces/superpowers" "$REPO_ROOT/external/superpowers"
}

marketplace_ready() {
    local name="$1"
    local expected
    case "$name" in
        omc) expected="$REPO_ROOT/external/oh-my-claudecode" ;;
        context-mode) expected="$REPO_ROOT/external/context-mode" ;;
        superpowers) expected="$REPO_ROOT/external/superpowers" ;;
        claude-plugins-official) expected="$REPO_ROOT/external/claude-plugins-official" ;;
        *) return 1 ;;
    esac
    symlink_points_to "$CLAUDE_HOME/plugins/marketplaces/$name" "$expected"
}

omc_injected() {
    grep -q 'OMC:START' "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null
}

custom_rules_ready() {
    [[ -f "$CLAUDE_HOME/agents/rules.md" && ! -L "$CLAUDE_HOME/agents/rules.md" ]]
}

custom_git_ready() {
    [[ -f "$CLAUDE_HOME/agents/git.md" && ! -L "$CLAUDE_HOME/agents/git.md" ]]
}

ecc_rules_ready() {
    [[ -d "$CLAUDE_HOME/rules/ecc" ]]
}

ecc_commands_ready() {
    [[ -d "$CLAUDE_HOME/commands" ]]
}

rtk_hooks_ready() {
    grep -q 'rtk-rewrite' "$CLAUDE_HOME/settings.json" 2>/dev/null
}

known_marketplaces_ready() {
    known_marketplaces_paths_ready
}

# ----- 参数解析 -----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --ci) CI_MODE=true; shift ;;
        --no-claude) NO_CLAUDE=true; shift ;;
        --no-verify) NO_VERIFY=true; shift ;;
        --force) FORCE=true; shift ;;
        --smoke-test) SMOKE_TEST=true; shift ;;
        -h|--help)
            echo "用法: ./setup.sh [选项]"
            echo "  --ci            CI 模式 (跳过手动提示)"
            echo "  --dry-run       预览，不实际修改"
            echo "  --no-claude     跳过 Claude Code 安装"
            echo "  --no-verify     跳过验证"
            echo "  --force         强制重跑所有步骤 (忽略幂等检测)"
            echo "  --smoke-test    运行 script/check-claude-doctor.sh 插件迁移检查"
            exit 0 ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Claude Code Config Migration v3    ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN — 不会实际修改文件"
    [[ "$CI_MODE" == true ]] && info "CI 模式"

    # === Phase 0: 环境检测 ===
    phase "Phase 0: 环境检测"
    local missing=()
    for dep in git curl tar node npm; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && { err "缺少依赖: ${missing[*]}"; exit 1; }
    log "git, curl, tar, node, npm 已就绪"
    info "系统: $(uname -s) / $(uname -m)"

    # === Phase 1: Claude Code ===
    phase "Phase 1: Claude Code"
    local CLAUDE_BOOTSTRAP=false
    if [[ "$NO_CLAUDE" == true ]]; then
        info "跳过 Claude Code 安装 (--no-claude)"
    elif ! command -v claude >/dev/null 2>&1; then
        # 未安装 → 安装 + 后台启动
        [[ "$DRY_RUN" == true ]] && { info "[DRY-RUN] npm install -g @anthropic-ai/claude-code"; }
        [[ "$DRY_RUN" == false ]] && {
            npm install -g @anthropic-ai/claude-code;
            log "Claude Code 安装完成";
            claude </dev/null >/dev/null 2>&1 &
            info "Claude Code 已在后台启动 (PID $!)，等待初始化...";
            CLAUDE_BOOTSTRAP=true
        }
    elif [[ ! -d "$CLAUDE_HOME" ]]; then
        # 已安装但 CLAUDE_HOME 未初始化 → 后台启动
        log "Claude Code 已安装: $(claude --version 2>&1 | head -1)"
        claude </dev/null >/dev/null 2>&1 &
        info "CLAUDE_HOME 未初始化，后台启动 Claude Code (PID $!)...";
        CLAUDE_BOOTSTRAP=true
    else
        # 已安装且 CLAUDE_HOME 已就绪 → PASS
        skip_if_done "Claude Code" "true"
    fi

    # === Phase 2: Submodules ===
    phase "Phase 2: Git Submodules"
    if ! skip_if_done "Submodules" submodules_clean; then
        info "初始化 git submodules (5 个)..."
        [[ "$DRY_RUN" == false ]] && { cd "$REPO_ROOT" && git submodule update --init --recursive; }
        log "Submodules 就绪"
    fi

    # 核心配置符号链接 (必须在插件安装之前, 因为 rtk init / omc setup 会修改这些文件)
    info "创建核心配置符号链接..."
    mkdir -p "$CLAUDE_HOME"
    for f in CLAUDE.md RTK.md AGENTS.md; do
        local src="$REPO_ROOT/config/claude/$f" dst="$CLAUDE_HOME/$f"
        [[ -f "$src" ]] || continue
        if skip_if_done "$f symlink" symlink_points_to "$dst" "$src"; then
            continue
        fi
        [[ "$DRY_RUN" == true ]] && { echo "  [DRY-RUN] ln -s $src -> $dst"; continue; }
        [[ -L "$dst" ]] || [[ -f "$dst" ]] && rm -f "$dst"
        ln -s "$src" "$dst"
    done
    # rules 目录
    local rules_dst="$CLAUDE_HOME/rules"
    if ! skip_if_done "rules symlink" symlink_points_to "$rules_dst" "$REPO_ROOT/config/claude/rules"; then
        [[ "$DRY_RUN" == true ]] && { echo "  [DRY-RUN] ln -s $REPO_ROOT/config/claude/rules -> $rules_dst"; }
        [[ "$DRY_RUN" == false ]] && {
            [[ -L "$rules_dst" ]] || [[ -d "$rules_dst" ]] && rm -rf "$rules_dst"
            ln -s "$REPO_ROOT/config/claude/rules" "$rules_dst"
        }
    fi
    # claude-plugins-official marketplace
    local cpo_dst="$CLAUDE_HOME/plugins/marketplaces/claude-plugins-official"
    local cpo_src="$REPO_ROOT/external/claude-plugins-official"
    if [[ -d "$cpo_src" ]] && ! skip_if_done "cpo marketplace" symlink_points_to "$cpo_dst" "$cpo_src"; then
        [[ "$DRY_RUN" == true ]] && { echo "  [DRY-RUN] ln -s $cpo_src -> $cpo_dst"; }
        [[ "$DRY_RUN" == false ]] && {
            mkdir -p "$CLAUDE_HOME/plugins/marketplaces"
            [[ -L "$cpo_dst" ]] || [[ -d "$cpo_dst" ]] && rm -rf "$cpo_dst"
            ln -s "$cpo_src" "$cpo_dst"
        }
    fi
    log "核心配置符号链接已检查"

    # === Phase 3: 安装插件 ===
    phase "Phase 3: 安装插件"
    if ! skip_if_done "RTK" rtk_ready; then
        run_installer rtk
    fi
    if ! skip_if_done "ECC" ecc_installed; then
        run_installer ecc
    fi
    if ! skip_if_done "context-mode" context_mode_ready; then
        run_installer context-mode
    fi
    if ! skip_if_done "OpenSpec" openspec_version_ready; then
        run_installer openspec
    fi
    # context-mode: 创建 current 符号链接指向最新版本，避免 hooks 硬编码版本号
    # 等待 Claude Code 后台初始化产生插件缓存目录
    local ctx_cache="$CLAUDE_HOME/plugins/cache/context-mode/context-mode"
    if [[ ! -d "$ctx_cache" ]]; then
        info "context-mode: 等待缓存目录 (3s)..."
        sleep 3
    fi
    if [[ -d "$ctx_cache" ]]; then
        local ctx_latest; ctx_latest="$(ls -d "$ctx_cache"/*/ 2>/dev/null | sort -V | tail -1)" || true
        if [[ -n "$ctx_latest" ]]; then
            ctx_latest="${ctx_latest%/}"
            if ! skip_if_done "context-mode current" context_mode_current_ready; then
                [[ "$DRY_RUN" == true ]] && { echo "  [DRY-RUN] ln -sfn $ctx_latest $ctx_cache/current"; }
                [[ "$DRY_RUN" == false ]] && { ln -sfn "$ctx_latest" "$ctx_cache/current"; log "context-mode current → $ctx_latest"; }
            fi
        else
            info "context-mode: 缓存目录存在但无版本，跳过 current 链接"
        fi
    else
        info "context-mode: 缓存目录未就绪，跳过 current 链接"
    fi
    if ! skip_if_done "superpowers" superpowers_ready; then
        run_installer superpowers
    fi

    # === Phase 4: settings.json + OMC ===
    phase "Phase 4: 生成 settings.json + OMC setup"
    local tmpl="$REPO_ROOT/config/claude/settings.template.json"
    local target="$CLAUDE_HOME/settings.json"

    if [[ ! -f "$tmpl" ]]; then
        warn "settings.template.json 不存在，跳过"
    else
        local rendered_settings
        rendered_settings="$(render_settings_template "$tmpl")"
        if [[ -f "$target" ]] && [[ "$CI_MODE" != true ]]; then
            info "已有 ~/.claude/settings.json，合并迁移所需关键项..."
            [[ "$DRY_RUN" == false ]] && {
                mkdir -p "$CLAUDE_HOME"
                merge_settings_json "$target" "$rendered_settings"
            }
            [[ "$DRY_RUN" == true ]] && echo "  [DRY-RUN] merge settings.json with template-backed migration keys"
            log "settings.json 已合并关键迁移配置"
        else
            info "从模板生成 settings.json..."
            [[ "$DRY_RUN" == false ]] && {
                mkdir -p "$CLAUDE_HOME"
                printf '%s\n' "$rendered_settings" > "$target"
            }
            [[ "$DRY_RUN" == true ]] && echo "  [DRY-RUN] write rendered settings.json"
            log "settings.json 已生成"
        fi
    fi

    # OMC setup 依赖 settings.json 存在 (合并 hooks)
    run_installer omc

    # RTK hooks 注入 (必须在 settings.json 生成 + OMC 合并之后)
    if command -v rtk >/dev/null 2>&1; then
        if ! skip_if_done "RTK hooks" rtk_hooks_ready; then
            info "RTK hook 注入 (rtk init)..."
            [[ "$DRY_RUN" == false ]] && { rtk init -g --auto-patch 2>&1 || true; }
            log "RTK hooks 已注入"
        fi
    fi

    # known_marketplaces.json 生成 (Claude Code 运行时产物, 提前生成供 CI 验证)
    if ! skip_if_done "known_marketplaces" known_marketplaces_ready; then
        info "生成 known_marketplaces.json..."
        [[ "$DRY_RUN" == false ]] && {
            mkdir -p "$CLAUDE_HOME/plugins"
        python3 - "$REPO_ROOT" "$CLAUDE_HOME" << 'PYEOF' > "$CLAUDE_HOME/plugins/known_marketplaces.json"
import json, sys, os
repo = sys.argv[1]
ts = "2026-01-01T00:00:00.000Z"
markets = {
    "claude-plugins-official": {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}, "dir": "external/claude-plugins-official"},
    "context-mode":            {"source": {"source": "github", "repo": "mksglu/context-mode"}, "dir": "external/context-mode"},
    "ecc":                     {"source": {"source": "github", "repo": "affaan-m/everything-claude-code"}, "dir": "external/everything-claude-code"},
    "omc":                     {"source": {"source": "git", "url": "https://github.com/Yeachan-Heo/oh-my-claudecode.git"}, "dir": "external/oh-my-claudecode"},
    "superpowers":             {"source": {"source": "git", "url": "https://github.com/obra/superpowers.git"}, "dir": "external/superpowers"},
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
    }
    log "known_marketplaces.json 已生成"
    fi

    # === Phase 5: 验证 ===
    if [[ "$NO_VERIFY" == true ]]; then
        info "Phase 5: 跳过验证 (--no-verify)"
    else
        phase "Phase 5: 功能验证"
        local fails=0
        check() {
            local cmd="$1"
            local label="$2"
            shift 2
            if "$cmd" "$@" 2>/dev/null; then echo -e "  ${GREEN}✓${NC} $label"; else echo -e "  ${RED}✗${NC} $label"; fails=$((fails+1)); fi
        }

        for f in CLAUDE.md RTK.md AGENTS.md; do
            check symlink_points_to "核心配置 $f 符号链接" "$CLAUDE_HOME/$f" "$REPO_ROOT/config/claude/$f"
        done
        check symlink_points_to "rules 目录" "$CLAUDE_HOME/rules" "$REPO_ROOT/config/claude/rules"
        check omc_injected "OMC 已注入 CLAUDE.md"
        check ecc_installed "ECC install-state"
        check custom_rules_ready "  自定义 rules.md"
        check custom_git_ready "  自定义 git.md"
        check ecc_rules_ready "ECC rules 目录"
        check ecc_commands_ready "ECC commands 目录"
        check symlink_points_to "superpowers mkt" "$CLAUDE_HOME/plugins/marketplaces/superpowers" "$REPO_ROOT/external/superpowers"
        check symlink_points_to "context-mode mkt" "$CLAUDE_HOME/plugins/marketplaces/context-mode" "$REPO_ROOT/external/context-mode"
        check test "ctx node_modules" -d "$REPO_ROOT/external/context-mode/node_modules"

        export PATH="$HOME/.local/bin:$PATH"
        check openspec_binary_ready "OpenSpec 二进制"
        check openspec_version_ready "OpenSpec --version"
        check rtk_binary_ready "RTK 二进制"
        check rtk_version_ready "RTK --version"
        check rtk_hooks_ready "RTK hook 注入"
        check rtk_config_ready "RTK config"

        local mp="$CLAUDE_HOME/plugins/marketplaces"
        for name in omc context-mode superpowers claude-plugins-official; do
            check marketplace_ready "marketplace: $name" "$name"
        done

        local km="$CLAUDE_HOME/plugins/known_marketplaces.json"
        check known_marketplaces_ready "known_marketplaces.json"
        check known_marketplaces_paths_ready "km.json 路径已替换"

        [[ $fails -gt 0 ]] && warn "文件验证: $fails 项失败" || log "文件验证: 全部通过"

        # 插件迁移检查 (仅 --smoke-test 时执行)
        if [[ "$SMOKE_TEST" == true ]]; then
            echo ""
            info "插件迁移检查 (script/check-claude-doctor.sh)..."
            if timeout 120 script/check-claude-doctor.sh; then
                echo -e "  Claude doctor ... ${GREEN}OK${NC}"
            else
                rc=$?
                [[ $rc -eq 124 ]] && echo -e "  Claude doctor ... ${RED}TIMEOUT${NC}" || echo -e "  Claude doctor ... ${RED}FAIL ($rc)${NC}"
                fails=$((fails+1))
            fi
            echo ""
        fi
        if [[ $fails -gt 0 ]]; then
            err "验证失败: $fails 项未通过"
            exit 1
        fi
        log "验证完成"
    fi

    # --------------- 完成 ---------------
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
