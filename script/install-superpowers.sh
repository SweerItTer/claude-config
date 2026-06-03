#!/usr/bin/env bash
# install-superpowers.sh — Superpowers 插件安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"
ACTION="${ACTION:-install}"

# shellcheck source=./install-common.sh
source "$REPO_ROOT/script/install-common.sh"

SUPERPOWERS_DIR="$REPO_ROOT/external/superpowers"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/superpowers"
SETTINGS_JSON="$CLAUDE_HOME/settings.json"
INSTALLED_PLUGINS_JSON="$CLAUDE_HOME/plugins/installed_plugins.json"
SUPERPOWERS_PLUGIN_KEY="superpowers@superpowers"
LEGACY_SETTINGS_PLUGIN_KEY="obra/superpowers@superpowers"
LEGACY_SKILLS=(
    brainstorming executing-plans finishing-a-development-branch
    receiving-code-review requesting-code-review subagent-driven-development
    systematic-debugging test-driven-development using-git-worktrees
    using-superpowers verification-before-completion writing-plans
    writing-skills dispatching-parallel-agents
)

symlink_points_to() {
    local link="$1"
    local target="$2"
    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

marketplace_state() {
    if symlink_points_to "$MARKETPLACE_DST" "$SUPERPOWERS_DIR"; then
        printf 'managed-symlink\n'
        return 0
    fi

    if [[ ! -e "$MARKETPLACE_DST" ]]; then
        printf 'missing\n'
        return 0
    fi

    if [[ -L "$MARKETPLACE_DST" ]]; then
        printf 'foreign-symlink\n'
        return 0
    fi

    if [[ -d "$MARKETPLACE_DST" ]]; then
        printf 'foreign-directory\n'
        return 0
    fi

    printf 'foreign-file\n'
}

legacy_skills_state() {
    local skills_dir="$CLAUDE_HOME/skills"
    local managed=0
    local foreign=0
    local name path

    [[ -d "$skills_dir" ]] || {
        printf 'cleared\n'
        return 0
    }

    for name in "${LEGACY_SKILLS[@]}"; do
        path="$skills_dir/$name"
        [[ -e "$path" ]] || continue
        if symlink_points_to "$path" "$SUPERPOWERS_DIR/skills/$name"; then
            managed=1
        else
            foreign=1
        fi
    done

    if [[ $managed -eq 0 && $foreign -eq 0 ]]; then
        printf 'cleared\n'
    elif [[ $managed -eq 1 && $foreign -eq 0 ]]; then
        printf 'managed-only\n'
    elif [[ $managed -eq 0 && $foreign -eq 1 ]]; then
        printf 'foreign-only\n'
    else
        printf 'mixed\n'
    fi
}

legacy_skills_cleared() {
    [[ "$(legacy_skills_state)" == "cleared" ]]
}

settings_enable_superpowers() {
    [[ -f "$SETTINGS_JSON" ]] || return 1
    python3 - "$SETTINGS_JSON" "$SUPERPOWERS_PLUGIN_KEY" "$LEGACY_SETTINGS_PLUGIN_KEY" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
plugin_key = sys.argv[2]
legacy_key = sys.argv[3]
data = json.loads(path.read_text(encoding='utf-8'))
enabled = data.setdefault('enabledPlugins', {})
changed = enabled.pop(legacy_key, None) is not None
if enabled.get(plugin_key) is not True:
    enabled[plugin_key] = True
    changed = True
if changed:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
raise SystemExit(0)
PY
}

settings_superpowers_enabled() {
    [[ -f "$SETTINGS_JSON" ]] || return 1
    python3 - "$SETTINGS_JSON" "$SUPERPOWERS_PLUGIN_KEY" <<'PY'
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

installed_plugins_enable_superpowers() {
    [[ -f "$INSTALLED_PLUGINS_JSON" ]] || return 0
    python3 - "$INSTALLED_PLUGINS_JSON" "$SUPERPOWERS_PLUGIN_KEY" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
plugin_key = sys.argv[2]
data = json.loads(path.read_text(encoding='utf-8'))
enabled = data.setdefault('enabledPlugins', {})
if enabled.get(plugin_key) is not True:
    enabled[plugin_key] = True
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
raise SystemExit(0)
PY
}

installed_plugins_superpowers_enabled() {
    [[ -f "$INSTALLED_PLUGINS_JSON" ]] || return 1
    python3 - "$INSTALLED_PLUGINS_JSON" "$SUPERPOWERS_PLUGIN_KEY" <<'PY'
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

is_ready() {
    symlink_points_to "$MARKETPLACE_DST" "$SUPERPOWERS_DIR" || return 1
    legacy_skills_cleared || return 1
    settings_superpowers_enabled || return 1
    installed_plugins_superpowers_enabled || return 1
}

link_marketplace() {
    if symlink_points_to "$MARKETPLACE_DST" "$SUPERPOWERS_DIR"; then
        ok "superpowers marketplace 已注册"
        return 0
    fi

    mkdir -p "$(dirname "$MARKETPLACE_DST")"
    if [[ -L "$MARKETPLACE_DST" || -f "$MARKETPLACE_DST" ]]; then
        rm -f "$MARKETPLACE_DST"
    elif [[ -d "$MARKETPLACE_DST" ]]; then
        rm -rf "$MARKETPLACE_DST"
    fi
    ln -sfn "$SUPERPOWERS_DIR" "$MARKETPLACE_DST"
    ok "superpowers marketplace 已注册"
}

cleanup_legacy_skills() {
    local skills_dir="$CLAUDE_HOME/skills"
    local name path
    [[ -d "$skills_dir" ]] || { ok "superpowers legacy skills 无残留"; return 0; }

    for name in "${LEGACY_SKILLS[@]}"; do
        path="$skills_dir/$name"
        [[ -e "$path" ]] || continue
        if ! symlink_points_to "$path" "$SUPERPOWERS_DIR/skills/$name"; then
            warn "发现外部 superpowers legacy skill，跳过清理: $name"
            continue
        fi
        rm -rf "$path"
        info "清理旧 superpowers skill: $name"
    done
    ok "superpowers legacy skills 已清理"
}

install() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] ln -sfn $SUPERPOWERS_DIR -> $MARKETPLACE_DST"
        info "[DRY-RUN] 清理旧 superpowers skills 残留"
        info "[DRY-RUN] ensure $SETTINGS_JSON enables $SUPERPOWERS_PLUGIN_KEY"
        info "[DRY-RUN] ensure $INSTALLED_PLUGINS_JSON enables $SUPERPOWERS_PLUGIN_KEY"
        return 0
    fi

    link_marketplace
    cleanup_legacy_skills
    settings_enable_superpowers
    installed_plugins_enable_superpowers
}

status() {
    local failed=0
    local marketplace_status
    local skills_status

    marketplace_status="$(marketplace_state)"
    skills_status="$(legacy_skills_state)"

    case "$marketplace_status" in
        managed-symlink)
            pass "marketplace: superpowers"
            ;;
        missing)
            info "marketplace: superpowers 未安装"
            ;;
        foreign-symlink)
            info "marketplace: superpowers 由外部 symlink 管理"
            ;;
        foreign-directory)
            info "marketplace: superpowers 由外部目录管理"
            ;;
        foreign-file)
            info "marketplace: superpowers 由外部文件占位"
            ;;
        *)
            err "marketplace: 未知状态 ($marketplace_status)"
            failed=1
            ;;
    esac

    case "$skills_status" in
        cleared)
            pass "cleanup: legacy skills"
            ;;
        managed-only)
            err "cleanup: 旧 superpowers skills 仍存在"
            failed=1
            ;;
        foreign-only)
            info "cleanup: legacy skills 由外部目录管理"
            ;;
        mixed)
            err "cleanup: superpowers legacy skills 处于 managed + foreign 混合状态"
            failed=1
            ;;
        *)
            err "cleanup: 未知状态 ($skills_status)"
            failed=1
            ;;
    esac

    settings_superpowers_enabled && pass "config: settings enabled superpowers" || { err "config: settings.json 未启用 $SUPERPOWERS_PLUGIN_KEY"; failed=1; }
    installed_plugins_superpowers_enabled && pass "registry: installed_plugins enabled superpowers" || { err "registry: installed_plugins.json 未启用 $SUPERPOWERS_PLUGIN_KEY"; failed=1; }

    return $failed
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    status
    ok "superpowers verify 通过"
}

uninstall() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] remove owned superpowers marketplace symlink"
        return 0
    fi

    remove_symlink_if_target "$MARKETPLACE_DST" "$SUPERPOWERS_DIR"
    ok "superpowers owned marketplace 已移除；legacy skills 保持不动"
}

doctor() {
    info "superpowers doctor"
    status
}

main() {
    if [[ "$ACTION" == "install" && "$FORCE" == false ]] && is_ready; then
        pass "superpowers 已就绪，跳过"
        verify
        return 0
    fi

    run_module_action "$ACTION"
}

main "$@"
