#!/usr/bin/env bash
# install-omc.sh — OMC (oh-my-claudecode) 插件安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"
ACTION="${ACTION:-install}"

# shellcheck source=./install-common.sh
source "$REPO_ROOT/script/install-common.sh"

OMC_DIR="$REPO_ROOT/external/oh-my-claudecode"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/omc"
WIKI_SRC="$REPO_ROOT/config/omc/wiki"
WIKI_DST="$HOME/.omc/wiki"
OMC_CLAUDE_MD_MODE="${OMC_CLAUDE_MD_MODE:-global}"
OMC_CLAUDE_MD_STYLE="${OMC_CLAUDE_MD_STYLE:-overwrite}"
GLOBAL_CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"
GLOBAL_OMC_COMPANION="$CLAUDE_HOME/CLAUDE-omc.md"
LOCAL_CLAUDE_MD="$REPO_ROOT/.claude/CLAUDE.md"
OMC_PLUGIN_KEY="oh-my-claudecode@omc"
INSTALLED_PLUGINS_JSON="$CLAUDE_HOME/plugins/installed_plugins.json"
OMC_REFERENCE_SKILL_SRC="$OMC_DIR/skills/omc-reference/SKILL.md"
OMC_REFERENCE_SKILL_DST="$CLAUDE_HOME/skills/omc-reference/SKILL.md"

LEGACY_SKILLS=(
    omc-setup omc-doctor ai-slop-cleaner autodoc autopilot autoresearch
    cancel ccg configure-notifications context-mode ctx-doctor ctx-insight ctx-purge
    ctx-stats ctx-upgrade debug deep-dive deep-interview external-context hud learner
    mcp-setup omc-teams omc-setup plan project-session-manager ralph ralplan
    release remember sciomc self-improve setup skill skillify team trace ultraqa ultrawork verify
    visual-verdict wiki writer-memory
)

symlink_points_to() {
    local link="$1"
    local target="$2"

    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

has_omc_markers() {
    local file="$1"

    [[ -f "$file" ]] || return 1
    grep -q '<!-- OMC:START -->' "$file" 2>/dev/null || return 1
    grep -q '<!-- OMC:END -->' "$file" 2>/dev/null || return 1
}

validate_claude_md_config() {
    case "$OMC_CLAUDE_MD_MODE" in
        global|local) ;;
        *)
            err "OMC_CLAUDE_MD_MODE 无效: $OMC_CLAUDE_MD_MODE (有效值: global, local)"
            return 1
            ;;
    esac

    case "$OMC_CLAUDE_MD_STYLE" in
        overwrite|preserve) ;;
        *)
            err "OMC_CLAUDE_MD_STYLE 无效: $OMC_CLAUDE_MD_STYLE (有效值: overwrite, preserve)"
            return 1
            ;;
    esac

    if [[ local == "$OMC_CLAUDE_MD_MODE" && overwrite != "$OMC_CLAUDE_MD_STYLE" ]]; then
        info "local 模式忽略 OMC_CLAUDE_MD_STYLE=$OMC_CLAUDE_MD_STYLE"
    fi
}

claude_md_ready() {
    if [[ local == "$OMC_CLAUDE_MD_MODE" ]]; then
        has_omc_markers "$LOCAL_CLAUDE_MD"
        return
    fi

    if [[ preserve == "$OMC_CLAUDE_MD_STYLE" ]]; then
        has_omc_markers "$GLOBAL_OMC_COMPANION" || return 1
        [[ -f "$GLOBAL_CLAUDE_MD" ]] || return 1
        grep -q '^<!-- OMC:IMPORT:START -->$' "$GLOBAL_CLAUDE_MD" 2>/dev/null || return 1
        grep -q '^@CLAUDE-omc.md$' "$GLOBAL_CLAUDE_MD" 2>/dev/null || return 1
        grep -q '^<!-- OMC:IMPORT:END -->$' "$GLOBAL_CLAUDE_MD" 2>/dev/null
        return
    fi

    has_omc_markers "$GLOBAL_CLAUDE_MD"
}

claude_md_error() {
    if [[ local == "$OMC_CLAUDE_MD_MODE" ]]; then
        err "本地 .claude/CLAUDE.md 未注入 OMC 内容: $LOCAL_CLAUDE_MD"
    elif [[ preserve == "$OMC_CLAUDE_MD_STYLE" ]]; then
        err "global preserve 模式未就绪: 需要 $GLOBAL_OMC_COMPANION 含 OMC markers，且 $GLOBAL_CLAUDE_MD 包含官方 OMC import block"
    else
        err "全局 CLAUDE.md 未注入 OMC 内容: $GLOBAL_CLAUDE_MD"
    fi
}

legacy_skills_cleared() {
    local skills_dir="$CLAUDE_HOME/skills"
    local name

    for name in "${LEGACY_SKILLS[@]}"; do
        [[ -e "$skills_dir/$name" ]] && return 1
    done

    return 0
}

wiki_ready() {
    [[ ! -d "$WIKI_SRC" ]] && return 0
    symlink_points_to "$WIKI_DST" "$WIKI_SRC"
}

omc_reference_skill_ready() {
    [[ -f "$OMC_REFERENCE_SKILL_SRC" ]] || return 1
    [[ -f "$OMC_REFERENCE_SKILL_DST" ]] || return 1
    cmp -s "$OMC_REFERENCE_SKILL_SRC" "$OMC_REFERENCE_SKILL_DST"
}

installed_plugins_enable_omc() {
    [[ -f "$INSTALLED_PLUGINS_JSON" ]] || return 1
    python3 - "$INSTALLED_PLUGINS_JSON" "$OMC_PLUGIN_KEY" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
plugin_key = sys.argv[2]
data = json.loads(path.read_text(encoding='utf-8'))
enabled = data.setdefault('enabledPlugins', {})
changed = enabled.get(plugin_key) is not True
if changed:
    enabled[plugin_key] = True
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
raise SystemExit(0)
PY
}

installed_plugins_omc_enabled() {
    [[ -f "$INSTALLED_PLUGINS_JSON" ]] || return 1
    python3 - "$INSTALLED_PLUGINS_JSON" "$OMC_PLUGIN_KEY" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
plugin_key = sys.argv[2]
data = json.loads(path.read_text(encoding='utf-8'))
enabled = data.get('enabledPlugins', {})
raise SystemExit(0 if enabled.get(plugin_key) is True else 1)
PY
}

installed_plugins_disable_omc() {
    [[ -f "$INSTALLED_PLUGINS_JSON" ]] || return 0
    python3 - "$INSTALLED_PLUGINS_JSON" "$OMC_PLUGIN_KEY" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
plugin_key = sys.argv[2]
data = json.loads(path.read_text(encoding='utf-8'))
enabled = data.get('enabledPlugins', {})
if enabled.pop(plugin_key, None) is not None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
raise SystemExit(0)
PY
}

sync_omc_reference_skill() {
    [[ -f "$OMC_REFERENCE_SKILL_SRC" ]] || {
        err "OMC reference skill 源文件不存在: $OMC_REFERENCE_SKILL_SRC"
        return 1
    }

    mkdir -p "$(dirname "$OMC_REFERENCE_SKILL_DST")"
    cp "$OMC_REFERENCE_SKILL_SRC" "$OMC_REFERENCE_SKILL_DST"
    ok "OMC reference skill 已安装"
}

remove_omc_reference_skill() {
    [[ -f "$OMC_REFERENCE_SKILL_DST" ]] || return 0

    if [[ -f "$OMC_REFERENCE_SKILL_SRC" ]] && cmp -s "$OMC_REFERENCE_SKILL_SRC" "$OMC_REFERENCE_SKILL_DST"; then
        rm -f "$OMC_REFERENCE_SKILL_DST"
        rmdir --ignore-fail-on-non-empty "$(dirname "$OMC_REFERENCE_SKILL_DST")" 2>/dev/null || true
        ok "OMC reference skill 已移除"
        return 0
    fi

    info "跳过移除 OMC reference skill：目标内容已被本地修改"
}

is_ready() {
    [[ -d "$OMC_DIR" ]] || return 1
    [[ -d "$OMC_DIR/node_modules" ]] || return 1
    symlink_points_to "$MARKETPLACE_DST" "$OMC_DIR" || return 1
    claude_md_ready || return 1
    legacy_skills_cleared || return 1
    wiki_ready || return 1
    omc_reference_skill_ready || return 1
    installed_plugins_omc_enabled || return 1
    return 0
}

link_marketplace() {
    if symlink_points_to "$MARKETPLACE_DST" "$OMC_DIR"; then
        ok "OMC marketplace 已注册"
        return 0
    fi

    mkdir -p "$(dirname "$MARKETPLACE_DST")"

    if [[ -L "$MARKETPLACE_DST" || -f "$MARKETPLACE_DST" ]]; then
        rm -f "$MARKETPLACE_DST"
    elif [[ -d "$MARKETPLACE_DST" ]]; then
        rm -rf "$MARKETPLACE_DST"
    fi

    ln -sfn "$OMC_DIR" "$MARKETPLACE_DST"
    ok "OMC marketplace 已注册"
}

cleanup_legacy_skills() {
    local skills_dir="$CLAUDE_HOME/skills"
    local name
    local path

    [[ -d "$skills_dir" ]] || {
        ok "OMC legacy skills 无残留"
        return 0
    }

    for name in "${LEGACY_SKILLS[@]}"; do
        path="$skills_dir/$name"
        [[ -e "$path" ]] || continue
        rm -rf "$path"
        info "清理旧 OMC skill: $name"
    done

    ok "OMC legacy skills 已清理"
}

setup_claude_md() {
    local setup_script="$OMC_DIR/scripts/setup-claude-md.sh"

    [[ -f "$setup_script" ]] || {
        err "OMC 官方 CLAUDE.md 安装脚本不存在: $setup_script"
        return 1
    }

    info "安装 OMC CLAUDE.md 配置 ($OMC_CLAUDE_MD_MODE${OMC_CLAUDE_MD_MODE:+/$OMC_CLAUDE_MD_STYLE})..."

    if [[ local == "$OMC_CLAUDE_MD_MODE" ]]; then
        (
            cd "$REPO_ROOT"
            CLAUDE_PLUGIN_ROOT="$OMC_DIR" bash "$setup_script" local
        )
    else
        CLAUDE_PLUGIN_ROOT="$OMC_DIR" bash "$setup_script" global "$OMC_CLAUDE_MD_STYLE"
    fi

    ok "OMC CLAUDE.md 配置已安装"
}

run_bridge_setup() {
    info "运行 omc setup..."
    (
        cd "$OMC_DIR"
        node bridge/cli.cjs setup --plugin-dir-mode --quiet 2>&1 || info "omc setup 返回非零，继续用 verify 判定结果"
    )
    ok "OMC setup 已执行"
}

link_wiki() {
    [[ -d "$WIKI_SRC" ]] || {
        info "OMC wiki 源目录不存在，跳过"
        return 0
    }

    if symlink_points_to "$WIKI_DST" "$WIKI_SRC"; then
        ok "OMC wiki 已就绪"
        return 0
    fi

    mkdir -p "$(dirname "$WIKI_DST")"

    if [[ -L "$WIKI_DST" || -f "$WIKI_DST" ]]; then
        rm -f "$WIKI_DST"
    elif [[ -d "$WIKI_DST" ]]; then
        rm -rf "$WIKI_DST"
    fi

    ln -sfn "$WIKI_SRC" "$WIKI_DST"
    ok "OMC wiki 已链接"
}

install() {
    if [[ true == "$DRY_RUN" && ! -d "$OMC_DIR" ]]; then
        info "[DRY-RUN] assume prepared source exists: $OMC_DIR"
    elif [[ ! -d "$OMC_DIR" ]]; then
        err "OMC 源目录不存在: $OMC_DIR"
        return 1
    fi

    if [[ ! -d "$OMC_DIR/node_modules" ]]; then
        info "npm install OMC..."
        if [[ true == "$DRY_RUN" ]]; then
            info "[DRY-RUN] (cd $OMC_DIR && npm install --no-audit --no-fund --loglevel=error)"
        else
            (
                cd "$OMC_DIR"
                npm install --no-audit --no-fund --loglevel=error
            )
            ok "OMC node_modules 已安装"
        fi
    else
        ok "OMC node_modules 已存在"
    fi

    # bridge/claude-md-coordinator.cjs 是 build 产物（esbuild 打包，烧入
    # docs/CLAUDE.md 的 SHA256），不在 git 中，npm install 也不生成。
    # setup-claude-md.sh 要求该文件存在且哈希匹配，每次安装必须重新构建。
    info "构建 OMC claude-md-coordinator..."
    if [[ true == "$DRY_RUN" ]]; then
        info "[DRY-RUN] (cd $OMC_DIR && npm run build:claude-md-coordinator)"
    else
        (
            cd "$OMC_DIR"
            npm run build:claude-md-coordinator
        )
        ok "OMC claude-md-coordinator 已构建"
    fi

    if [[ true == "$DRY_RUN" ]]; then
        info "[DRY-RUN] ln -sfn $OMC_DIR -> $MARKETPLACE_DST"
        info "[DRY-RUN] 清理旧 OMC skills 残留"
        if [[ local == "$OMC_CLAUDE_MD_MODE" ]]; then
            info "[DRY-RUN] (cd $REPO_ROOT && CLAUDE_PLUGIN_ROOT=$OMC_DIR bash $OMC_DIR/scripts/setup-claude-md.sh local)"
        else
            info "[DRY-RUN] CLAUDE_PLUGIN_ROOT=$OMC_DIR bash $OMC_DIR/scripts/setup-claude-md.sh global $OMC_CLAUDE_MD_STYLE"
        fi
        info "[DRY-RUN] node bridge/cli.cjs setup --plugin-dir-mode --quiet"
        info "[DRY-RUN] cp $OMC_REFERENCE_SKILL_SRC -> $OMC_REFERENCE_SKILL_DST"
        info "[DRY-RUN] ensure $INSTALLED_PLUGINS_JSON enables $OMC_PLUGIN_KEY"
        info "[DRY-RUN] ln -sfn $WIKI_SRC -> $WIKI_DST"
        return 0
    fi

    link_marketplace
    cleanup_legacy_skills
    setup_claude_md
    run_bridge_setup
    sync_omc_reference_skill
    installed_plugins_enable_omc
    link_wiki
}

status() {
    local failed=0

    [[ -d "$OMC_DIR" ]] && pass "source: $OMC_DIR" || { err "source: OMC 源目录不存在"; failed=1; }
    [[ -d "$OMC_DIR/node_modules" ]] && pass "source: node_modules" || { err "source: node_modules 不存在"; failed=1; }
    symlink_points_to "$MARKETPLACE_DST" "$OMC_DIR" && pass "marketplace: omc" || { err "marketplace: 未指向源码目录"; failed=1; }
    claude_md_ready && pass "config: CLAUDE.md 注入" || { claude_md_error; failed=1; }
    legacy_skills_cleared && pass "cleanup: legacy skills" || { err "cleanup: 旧 OMC skills 仍存在"; failed=1; }
    omc_reference_skill_ready && pass "skills: omc-reference" || { err "skills: omc-reference 未安装或内容漂移"; failed=1; }
    installed_plugins_omc_enabled && pass "registry: installed_plugins enabled OMC" || { err "registry: installed_plugins.json 未启用 $OMC_PLUGIN_KEY"; failed=1; }
    wiki_ready && pass "wiki: linked" || { err "wiki: symlink 不正确"; failed=1; }

    return $failed
}

verify() {
    if [[ true == "$DRY_RUN" ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    status
    ok "OMC verify 通过"
}

uninstall() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] remove owned omc marketplace and wiki symlink"
        info "[DRY-RUN] remove managed omc-reference skill"
        info "[DRY-RUN] disable $OMC_PLUGIN_KEY in $INSTALLED_PLUGINS_JSON"
        return 0
    fi

    remove_symlink_if_target "$MARKETPLACE_DST" "$OMC_DIR"
    remove_symlink_if_target "$WIKI_DST" "$WIKI_SRC"
    remove_omc_reference_skill
    installed_plugins_disable_omc
    ok "OMC owned symlink 与受管注册项已移除；CLAUDE.md 注入内容保持不动"
}

doctor() {
    info "OMC doctor"
    status
}

main() {
    validate_claude_md_config

    if [[ "$ACTION" == "install" && false == "$FORCE" ]] && is_ready; then
        pass "OMC 已就绪，跳过"
        verify
        return 0
    fi

    run_module_action "$ACTION"
}

main "$@"