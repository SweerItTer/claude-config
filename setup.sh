#!/usr/bin/env bash
# ============================================================
# Claude Code Config Migration — 一键初始化脚本 v3
# 用法: git clone --recurse-submodules <repo-url> && ./setup.sh
#
# 5 阶段:
#   0. 环境检测 (OS, deps, Claude Code)
#   1. 安装 Claude Code (可选)
#   2. Git Submodules
#   3. 安装插件 (RTK → ECC → context-mode → superpowers 前半)
#   4. 生成 settings.json + OMC setup (后半)
#   5. 文件验证 + claude --print 功能测试
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

# ----- 参数解析 -----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --ci) CI_MODE=true; shift ;;
        --no-claude) NO_CLAUDE=true; shift ;;
        --no-verify) NO_VERIFY=true; shift ;;
        -h|--help)
            echo "用法: ./setup.sh [选项]"
            echo "  --ci            CI 模式 (跳过手动提示)"
            echo "  --dry-run       预览，不实际修改"
            echo "  --no-claude     跳过 Claude Code 安装"
            echo "  --no-verify     跳过验证"
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
    echo -e "${BLUE}║  Claude Code Config Migration v3    ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN — 不会实际修改文件"
    [[ "$CI_MODE" == true ]] && info "CI 模式"

    # === Phase 0: 环境检测 ===
    phase "Phase 0: 环境检测"
    local missing=()
    for dep in git curl tar node; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && { err "缺少依赖: ${missing[*]}"; exit 1; }
    log "git, curl, tar, node 已就绪"
    info "系统: $(uname -s) / $(uname -m)"

    # === Phase 1: Claude Code ===
    if [[ "$NO_CLAUDE" == true ]]; then
        info "Phase 1: 跳过 Claude Code 安装 (--no-claude)"
    elif command -v claude >/dev/null 2>&1; then
        log "Phase 1: Claude Code 已安装: $(claude --version 2>&1 | head -1)"
    else
        phase "Phase 1: 安装 Claude Code"
        [[ "$DRY_RUN" == true ]] && { info "[DRY-RUN] npm install -g @anthropic-ai/claude-code"; }
        [[ "$DRY_RUN" == false ]] && { npm install -g @anthropic-ai/claude-code; log "Claude Code 安装完成"; }
    fi

    # === Phase 2: Submodules ===
    phase "Phase 2: Git Submodules"
    info "初始化 git submodules (5 个)..."
    [[ "$DRY_RUN" == false ]] && { cd "$REPO_ROOT" && git submodule update --init --recursive; }
    log "Submodules 就绪"

    # 核心配置符号链接 (必须在插件安装之前, 因为 rtk init / omc setup 会修改这些文件)
    info "创建核心配置符号链接..."
    mkdir -p "$CLAUDE_HOME"
    for f in CLAUDE.md RTK.md AGENTS.md; do
        local src="$REPO_ROOT/config/claude/$f" dst="$CLAUDE_HOME/$f"
        [[ -f "$src" ]] || continue
        [[ "$DRY_RUN" == true ]] && { echo "  [DRY-RUN] ln -s $src -> $dst"; continue; }
        [[ -L "$dst" ]] || [[ -f "$dst" ]] && rm -f "$dst"
        ln -s "$src" "$dst"
    done
    # rules 目录
    local rules_dst="$CLAUDE_HOME/rules"
    [[ "$DRY_RUN" == true ]] && { echo "  [DRY-RUN] ln -s $REPO_ROOT/config/claude/rules -> $rules_dst"; }
    [[ "$DRY_RUN" == false ]] && {
        [[ -L "$rules_dst" ]] || [[ -d "$rules_dst" ]] && rm -rf "$rules_dst"
        ln -s "$REPO_ROOT/config/claude/rules" "$rules_dst"
    }
    # claude-plugins-official marketplace
    local cpo_dst="$CLAUDE_HOME/plugins/marketplaces/claude-plugins-official"
    local cpo_src="$REPO_ROOT/external/claude-plugins-official"
    if [[ -d "$cpo_src" ]]; then
        [[ "$DRY_RUN" == true ]] && { echo "  [DRY-RUN] ln -s $cpo_src -> $cpo_dst"; }
        [[ "$DRY_RUN" == false ]] && {
            mkdir -p "$CLAUDE_HOME/plugins/marketplaces"
            [[ -L "$cpo_dst" ]] || [[ -d "$cpo_dst" ]] && rm -rf "$cpo_dst"
            ln -s "$cpo_src" "$cpo_dst"
        }
    fi
    log "核心配置符号链接已创建"

    # === Phase 3: 安装插件 ===
    phase "Phase 3: 安装插件"
    run_installer rtk
    run_installer ecc
    run_installer context-mode
    run_installer superpowers

    # === Phase 4: settings.json + OMC ===
    phase "Phase 4: 生成 settings.json + OMC setup"
    local tmpl="$REPO_ROOT/config/claude/settings.template.json"
    local target="$CLAUDE_HOME/settings.json"

    if [[ ! -f "$tmpl" ]]; then
        warn "settings.template.json 不存在，跳过"
    elif [[ -f "$target" ]] && [[ "$CI_MODE" != true ]]; then
        warn "已有 ~/.claude/settings.json，跳过生成"
    else
        info "从模板生成 settings.json..."
        [[ "$DRY_RUN" == false ]] && {
            mkdir -p "$CLAUDE_HOME"
            local content; content="$(cat "$tmpl")"
            for var in CLAUDE_BASE_URL CLAUDE_API_KEY CLAUDE_MODEL \
                       CLAUDE_HAIKU_MODEL CLAUDE_SONNET_MODEL CLAUDE_OPUS_MODEL; do
                content="${content//"{{${var}}}"/${!var:-}}"
            done
            content="${content//"{{REPO_ROOT}}"/$REPO_ROOT}"
            echo "$content" > "$target"
        }
        log "settings.json 已生成"
    fi

    # OMC setup 依赖 settings.json 存在 (合并 hooks)
    run_installer omc

    # RTK hooks 注入 (必须在 settings.json 生成 + OMC 合并之后)
    if command -v rtk >/dev/null 2>&1; then
        info "RTK hook 注入 (rtk init)..."
        [[ "$DRY_RUN" == false ]] && { rtk init -g --auto-patch 2>&1 || true; }
        log "RTK hooks 已注入"
    fi

    # known_marketplaces.json 生成 (Claude Code 运行时产物, 提前生成供 CI 验证)
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

    # === Phase 5: 验证 ===
    if [[ "$NO_VERIFY" == true ]]; then
        info "Phase 5: 跳过验证 (--no-verify)"
    else
        phase "Phase 5: 功能验证"
        local fails=0
        check() {
            if eval "$1" 2>/dev/null; then echo "  ${GREEN}✓${NC} $2"; else echo "  ${RED}✗${NC} $2"; fails=$((fails+1)); fi
        }

        for f in CLAUDE.md RTK.md AGENTS.md; do
            check "[[ -L '$CLAUDE_HOME/$f' ]]" "核心配置 $f 符号链接"
        done
        check "[[ -L '$CLAUDE_HOME/rules' ]]" "rules 目录"
        check "grep -q 'OMC:START' '$CLAUDE_HOME/CLAUDE.md'" "OMC 已注入 CLAUDE.md"
        check "[[ -L '$CLAUDE_HOME/agents' ]]" "agents 目录 (ECC)"
        check "[[ -f '$CLAUDE_HOME/agents/rules.md' && ! -L '$CLAUDE_HOME/agents/rules.md' ]]" "  自定义 rules.md"
        check "[[ -f '$CLAUDE_HOME/agents/git.md' && ! -L '$CLAUDE_HOME/agents/git.md' ]]" "  自定义 git.md"
        check "[[ -L '$CLAUDE_HOME/skills/tdd-workflow' ]]" "ECC skill: tdd-workflow"
        check "[[ -L '$CLAUDE_HOME/commands' ]]" "commands 目录"
        check "[[ -L '$CLAUDE_HOME/plugins/marketplaces/superpowers' ]]" "superpowers mkt"
        check "[[ -L '$CLAUDE_HOME/plugins/marketplaces/context-mode' ]]" "context-mode mkt"
        check "[[ -d '$REPO_ROOT/external/context-mode/node_modules' ]]" "ctx node_modules"

        export PATH="$HOME/.local/bin:$PATH"
        check "command -v rtk >/dev/null 2>&1" "RTK 二进制"
        check "rtk --version >/dev/null 2>&1" "RTK --version"
        check "[[ -L '$HOME/.config/rtk/config.toml' ]]" "RTK config"

        local mp="$CLAUDE_HOME/plugins/marketplaces"
        for name in ecc omc context-mode superpowers claude-plugins-official; do
            check "[[ -L '$mp/$name' ]]" "marketplace: $name"
        done

        local km="$CLAUDE_HOME/plugins/known_marketplaces.json"
        check "[[ -f '$km' ]]" "known_marketplaces.json"
        check "! grep -q 'REPO_ROOT' '$km'" "km.json 路径已替换"

        [[ $fails -gt 0 ]] && warn "文件验证: $fails 项失败" || log "文件验证: 全部通过"

        # 功能测试 (仅非 CI)
        if [[ "$CI_MODE" != true ]]; then
            echo ""
            info "功能测试 (claude --print)..."
            vc() {
                echo -n "  $1 ... "
                local out rc
                if out=$(timeout 120 claude --print --output-format text "$2" 2>&1); then
                    echo "$out" | grep -qi "$3" && echo -e "${GREEN}OK${NC}" || {
                        echo -e "${YELLOW}?${NC}"; echo "    $(echo "$out" | head -1)"
                    }
                else
                    rc=$?; [[ $rc -eq 124 ]] && echo -e "${RED}TIMEOUT${NC}" || echo -e "${RED}FAIL ($rc)${NC}"
                fi
            }
            vc "基础连通" "say OK" "OK"
            vc "OMC 检测"  "简短回答: 你的 agent 框架名称?" "OMC|oh-my-claudecode|agent"
            vc "superpowers" "你是否可以访问 using-superpowers 这个 skill? 只回答是或否" "是|yes|可以"
            echo ""
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
