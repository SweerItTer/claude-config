#!/usr/bin/env bash
# install-context-mode.sh — 上下文窗口管理插件安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"
NO_PATCH="${4:-false}"
ACTION="${ACTION:-install}"

# shellcheck source=./install-common.sh
source "$REPO_ROOT/script/install-common.sh"

CTX_DIR="$REPO_ROOT/external/context-mode"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/context-mode"
CACHE_ROOT="$CLAUDE_HOME/plugins/cache/context-mode/context-mode"
CTX_INSTALL_MODE="${CTX_INSTALL_MODE:-auto}"
SOURCE_REV_FILE=".source-rev"
SETTINGS_JSON="$CLAUDE_HOME/settings.json"
KNOWN_MARKETPLACES_JSON="$CLAUDE_HOME/plugins/known_marketplaces.json"
INSTALLED_PLUGINS_JSON="$CLAUDE_HOME/plugins/installed_plugins.json"
PLUGIN_KEY="context-mode@context-mode"
SETTINGS_PLUGIN_KEY="context-mode@context-mode"
LEGACY_SETTINGS_PLUGIN_KEY="mksglu/context-mode@context-mode"

validate_install_mode() {
    case "$CTX_INSTALL_MODE" in
        auto|symlink|copy) return 0 ;;
        *)
            err "CTX_INSTALL_MODE 仅支持 auto、symlink 或 copy，当前值: $CTX_INSTALL_MODE"
            return 1
            ;;
    esac
}

symlink_points_to() {
    local link="$1"
    local target="$2"

    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

source_rev_path() {
    printf '%s/%s\n' "$MARKETPLACE_DST" "$SOURCE_REV_FILE"
}

get_source_rev() {
    git -C "$CTX_DIR" rev-parse HEAD 2>/dev/null || {
        err "无法读取 context-mode 源 revision: $CTX_DIR"
        return 1
    }
}

routing_patch_applied() {
    grep -q "CTX_STRICT_BASH" "$MARKETPLACE_DST/hooks/core/routing.mjs" 2>/dev/null
}

copy_is_fresh() {
    local expected_rev
    local actual_rev
    local rev_file

    rev_file="$(source_rev_path)"
    [[ -f "$rev_file" ]] || return 1

    expected_rev="$(get_source_rev)" || return 1
    actual_rev="$(tr -d '[:space:]' < "$rev_file")"

    [[ -n "$actual_rev" ]] || return 1
    [[ "$actual_rev" == "$expected_rev" ]]
}

is_ready() {
    [[ -d "$CTX_DIR" ]] || return 1
    [[ -d "$CTX_DIR/node_modules" ]] || return 1
    [[ -d "$MARKETPLACE_DST" ]] || return 1
    routing_patch_applied || return 1

    if [[ "$CTX_INSTALL_MODE" == "symlink" ]]; then
        symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR" || return 1
        return 0
    fi

    if [[ "$CTX_INSTALL_MODE" == "auto" ]] && symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR"; then
        return 0
    fi

    [[ ! -L "$MARKETPLACE_DST" ]] || return 1
    [[ -d "$MARKETPLACE_DST/node_modules" ]] || return 1
    copy_is_fresh || return 1
    return 0
}

marketplace_copy_is_owned() {
    [[ -d "$MARKETPLACE_DST" ]] || return 1
    [[ ! -L "$MARKETPLACE_DST" ]] || return 1
    [[ -f "$(source_rev_path)" ]]
}

reset_marketplace_dst() {
    mkdir -p "$(dirname "$MARKETPLACE_DST")"

    if [[ -L "$MARKETPLACE_DST" || -f "$MARKETPLACE_DST" ]]; then
        rm -f "$MARKETPLACE_DST"
    elif [[ -d "$MARKETPLACE_DST" ]]; then
        if ! marketplace_copy_is_owned; then
            # ponytail: 非受管目录默认拒删以保护用户内容; --force/update 下放行
            # 让同插件残留(通常是上次失败遗留)能被覆盖收敛, 打破"删不掉->heal 失败->永远漂移"的死锁
            if [[ "$FORCE" != true ]]; then
                err "context-mode marketplace 是外部目录，当前 setup 不会删除: $MARKETPLACE_DST (使用 --force 强制覆盖)"
                return 1
            fi
            warn "context-mode marketplace 是非受管目录, --force 下覆盖重建: $MARKETPLACE_DST"
        fi
        rm -rf "$MARKETPLACE_DST"
    fi
}

link_marketplace() {
    if symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR"; then
        ok "context-mode marketplace 已注册 (symlink)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN][mode=symlink] ln -sfn $CTX_DIR -> $MARKETPLACE_DST"
        return 0
    fi

    reset_marketplace_dst || return 1
    ln -sfn "$CTX_DIR" "$MARKETPLACE_DST" || return 1
    ok "context-mode marketplace 已注册 (symlink)"
}

write_source_rev() {
    local rev_file
    local source_rev

    rev_file="$(source_rev_path)"
    source_rev="$(get_source_rev)" || return 1
    printf '%s\n' "$source_rev" > "$rev_file"
}

copy_marketplace() {
    if [[ -d "$MARKETPLACE_DST" ]] && [[ ! -L "$MARKETPLACE_DST" ]] && copy_is_fresh; then
        ok "context-mode marketplace 已复制且为最新副本"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN][mode=copy] rm -rf $MARKETPLACE_DST"
        info "[DRY-RUN][mode=copy] mkdir -p $MARKETPLACE_DST"
        info "[DRY-RUN][mode=copy] cp -a $CTX_DIR/. $MARKETPLACE_DST/"
        info "[DRY-RUN][mode=copy] write $(source_rev_path)"
        return 0
    fi

    reset_marketplace_dst || return 1
    mkdir -p "$MARKETPLACE_DST" || return 1
    cp -a "$CTX_DIR/." "$MARKETPLACE_DST/" || return 1
    write_source_rev || return 1
    ok "context-mode marketplace 已复制"
}

active_install_mode() {
    if [[ "$CTX_INSTALL_MODE" != "auto" ]]; then
        printf '%s\n' "$CTX_INSTALL_MODE"
        return 0
    fi

    if symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR"; then
        printf 'symlink\n'
        return 0
    fi

    printf 'copy\n'
}

settings_have_context_mode() {
    [[ -f "$SETTINGS_JSON" ]] || return 1
    grep -q 'context-mode@context-mode' "$SETTINGS_JSON" 2>/dev/null || return 1
    grep -q 'pretooluse.mjs' "$SETTINGS_JSON" 2>/dev/null
}

known_marketplace_has_context_mode() {
    [[ -f "$KNOWN_MARKETPLACES_JSON" ]] || return 1
    grep -q '"context-mode"' "$KNOWN_MARKETPLACES_JSON" 2>/dev/null || return 1
    grep -q 'context-mode' "$KNOWN_MARKETPLACES_JSON" 2>/dev/null
}

registry_has_context_mode() {
    [[ -f "$INSTALLED_PLUGINS_JSON" ]] || return 1
    grep -q '"context-mode@context-mode"' "$INSTALLED_PLUGINS_JSON" 2>/dev/null || return 1
    grep -q '"enabledPlugins"' "$INSTALLED_PLUGINS_JSON" 2>/dev/null || return 1
    grep -q '"context-mode@context-mode": true' "$INSTALLED_PLUGINS_JSON" 2>/dev/null
}

repo_plugin_version() {
    plugin_manifest_version "$CTX_DIR/.claude-plugin/plugin.json"
}

repo_cache_entry_path() {
    local repo_version="$1"
    plugin_cache_entry_path "context-mode" "context-mode" "$repo_version" "$CLAUDE_HOME"
}

cache_entry_manifest_version() {
    local version="$1"
    local entry
    entry="$(repo_cache_entry_path "$version")"

    plugin_manifest_version "$entry/.claude-plugin/plugin.json"
}

managed_cache_entry_points_to_marketplace() {
    local version="$1"
    local entry
    entry="$(repo_cache_entry_path "$version")"

    [[ -L "$entry" ]] || return 1
    symlink_points_to "$entry" "$MARKETPLACE_DST" || return 1
    [[ "$(cache_entry_manifest_version "$version" 2>/dev/null || true)" == "$version" ]]
}

cleanup_managed_cache_entry() {
    local repo_version="$1"
    local target_path

    [[ -n "$repo_version" ]] || return 0
    managed_cache_entry_points_to_marketplace "$repo_version" || return 0

    target_path="$(repo_cache_entry_path "$repo_version")"
    rm -f "$target_path"
}


registry_plugin_status() {
    REGISTRY_JSON="$INSTALLED_PLUGINS_JSON" PLUGIN_KEY="$PLUGIN_KEY" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

registry_path = Path(os.environ['REGISTRY_JSON'])
plugin_key = os.environ['PLUGIN_KEY']
if not registry_path.is_file():
    print('missing')
    raise SystemExit(0)

data = json.loads(registry_path.read_text(encoding='utf-8'))
plugins = data.get('plugins') or {}
enabled = data.get('enabledPlugins') or {}
entries = plugins.get(plugin_key)
if not isinstance(entries, list) or not entries:
    print('missing')
    raise SystemExit(0)
entry = entries[0] if isinstance(entries[0], dict) else {}
version = entry.get('version') or ''
install_path = entry.get('installPath') or ''
plugin_json = Path(install_path) / '.claude-plugin' / 'plugin.json' if install_path else None
manifest_version = ''
manifest_state = 'missing'
if plugin_json and plugin_json.is_file():
    try:
        manifest_version = json.loads(plugin_json.read_text(encoding='utf-8')).get('version', '')
        manifest_state = 'present'
    except Exception:
        manifest_state = 'broken'
state = 'ready' if enabled.get(plugin_key) is True and install_path else 'incomplete'
print('\t'.join([state, version, install_path, manifest_version, manifest_state]))
PYEOF
}

registry_matches_repo() {
    local repo_version
    local expected_cache_path
    local registry_line
    local state registry_version install_path manifest_version manifest_state

    repo_version="$(repo_plugin_version 2>/dev/null || true)"
    [[ -n "$repo_version" ]] || return 1

    expected_cache_path="$(repo_cache_entry_path "$repo_version")"
    [[ -L "$expected_cache_path" ]] || return 1
    managed_cache_entry_points_to_marketplace "$repo_version" || return 1

    registry_line="$(registry_plugin_status 2>/dev/null || true)"
    [[ -n "$registry_line" ]] || return 1
    IFS=$'\t' read -r state registry_version install_path manifest_version manifest_state <<< "$registry_line"

    [[ "$state" == "ready" ]] || return 1
    [[ "$manifest_state" == "present" ]] || return 1
    [[ "$install_path" == "$expected_cache_path" ]] || return 1
    [[ "$registry_version" == "$repo_version" ]] || return 1
    [[ "$manifest_version" == "$repo_version" ]]
}

heal_registry_drift() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] heal context-mode installed_plugins registry drift"
    fi

    [[ -f "$CTX_DIR/.claude-plugin/plugin.json" ]] || return 0
    [[ -d "$MARKETPLACE_DST" || -L "$MARKETPLACE_DST" ]] || return 0

    local entries_json
    entries_json="$(CTX_DIR="$CTX_DIR" MARKETPLACE_DST="$MARKETPLACE_DST" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

ctx_dir = Path(os.environ['CTX_DIR'])
marketplace_dst = Path(os.environ['MARKETPLACE_DST'])
print(json.dumps([{
    'pluginKey': 'context-mode@context-mode',
    'marketplaceName': 'context-mode',
    'pluginName': 'context-mode',
    'sourcePath': str(marketplace_dst),
    'pluginJsonPath': str(ctx_dir / '.claude-plugin' / 'plugin.json'),
    'preferManaged': True,
}], ensure_ascii=False))
PYEOF
)"

    CTX_DIR="$CTX_DIR" MARKETPLACE_DST="$MARKETPLACE_DST" \
        register_plugins_to_installed_json "$entries_json" "$INSTALLED_PLUGINS_JSON" "$CLAUDE_HOME" || {
        warn "registry: 无法收敛 context-mode installed_plugins registry drift"
        return 1
    }

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    REGISTRY_JSON="$INSTALLED_PLUGINS_JSON" \
    SETTINGS_JSON="$SETTINGS_JSON" \
    PLUGIN_KEY="$PLUGIN_KEY" \
    SETTINGS_PLUGIN_KEY="$SETTINGS_PLUGIN_KEY" \
    LEGACY_SETTINGS_PLUGIN_KEY="$LEGACY_SETTINGS_PLUGIN_KEY" \
    python3 - <<'PYEOF'
import json
import os
from pathlib import Path

registry_path = Path(os.environ['REGISTRY_JSON'])
settings_path = Path(os.environ['SETTINGS_JSON'])
plugin_key = os.environ['PLUGIN_KEY']
settings_plugin_key = os.environ['SETTINGS_PLUGIN_KEY']
legacy_settings_plugin_key = os.environ['LEGACY_SETTINGS_PLUGIN_KEY']

if registry_path.is_file():
    registry = json.loads(registry_path.read_text(encoding='utf-8'))
    enabled = registry.setdefault('enabledPlugins', {})
    if enabled.get(plugin_key) is not True:
        enabled[plugin_key] = True
        registry_path.write_text(json.dumps(registry, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

if settings_path.is_file():
    settings = json.loads(settings_path.read_text(encoding='utf-8'))
    settings_enabled = settings.setdefault('enabledPlugins', {})
    changed = False
    if legacy_settings_plugin_key in settings_enabled:
        settings_enabled.pop(legacy_settings_plugin_key, None)
        changed = True
    if settings_enabled.get(settings_plugin_key) is not True:
        settings_enabled[settings_plugin_key] = True
        changed = True
    if changed:
        settings_path.write_text(json.dumps(settings, indent=4, ensure_ascii=False) + '\n', encoding='utf-8')
PYEOF

    if registry_matches_repo; then
        ok "registry: installed_plugins 已收敛到 repo 版本 cache 入口"
        return 0
    fi

    warn "registry: installed_plugins 仍存在 context-mode 版本漂移"
    return 1
}

runtime_ready() {
    command -v claude >/dev/null 2>&1 || return 1

    local timeout_seconds="${CLAUDE_CONTEXT_TIMEOUT:-60}"
    local tmp
    tmp="$(mktemp)"

    set +e
    timeout "$timeout_seconds" claude -p /context >"$tmp" 2>&1
    local rc=$?
    set -e

    if [[ $rc -ne 0 || ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 1
    fi

    rm -f "$tmp"
    return 0
}

status() {
    local failed=0
    local mode
    local registry_line
    local registry_state
    local registry_version
    local install_path
    local manifest_version
    local manifest_state
    local repo_version
    local expected_cache_path
    mode="$(active_install_mode)"

    [[ -d "$CTX_DIR" ]] && [[ -d "$CTX_DIR/node_modules" ]] && pass "source: $CTX_DIR" || { err "source: 缺少源码或 node_modules"; failed=1; }

    if [[ "$mode" == "symlink" ]]; then
        symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR" && pass "marketplace: symlink" || { err "marketplace: symlink 未就绪"; failed=1; }
    else
        if [[ -d "$MARKETPLACE_DST" ]] && [[ ! -L "$MARKETPLACE_DST" ]] && ! marketplace_copy_is_owned; then
            err "marketplace: copy 目录不受当前 setup 管理"
            failed=1
        else
            [[ -d "$MARKETPLACE_DST" ]] && [[ ! -L "$MARKETPLACE_DST" ]] && copy_is_fresh && pass "marketplace: copy" || { err "marketplace: copy 未就绪"; failed=1; }
        fi
    fi

    routing_patch_applied && pass "config: routing patch" || { err "config: routing patch 缺失"; failed=1; }
    settings_have_context_mode && pass "settings: hooks + plugin" || { err "settings: context-mode 配置缺失"; failed=1; }
    known_marketplace_has_context_mode && pass "catalog: known marketplace" || { err "catalog: known_marketplaces 缺失 context-mode"; failed=1; }
    registry_has_context_mode && pass "registry: installed_plugins" || { err "registry: installed_plugins 缺失 context-mode install-state"; failed=1; }

    repo_version="$(repo_plugin_version 2>/dev/null || true)"
    registry_line="$(registry_plugin_status 2>/dev/null || true)"
    if [[ -z "$repo_version" || -z "$registry_line" ]]; then
        err "registry-version: 无法读取 context-mode 版本信息"
        failed=1
    else
        expected_cache_path="$(repo_cache_entry_path "$repo_version")"
        IFS=$'\t' read -r registry_state registry_version install_path manifest_version manifest_state <<< "$registry_line"
        if [[ "$registry_state" == "missing" ]]; then
            err "registry-version: context-mode install-state 缺失"
            failed=1
        elif [[ "$registry_state" != "ready" ]]; then
            err "registry-version: context-mode install-state 不完整"
            failed=1
        elif [[ "$manifest_state" == "missing" ]]; then
            err "registry-version: cache manifest 缺失 path=${install_path:-missing}"
            failed=1
        elif [[ "$manifest_state" == "broken" ]]; then
            err "registry-version: cache manifest 损坏 path=${install_path:-missing}"
            failed=1
        elif [[ "$manifest_state" != "present" ]]; then
            err "registry-version: cache manifest 状态异常 path=${install_path:-missing} state=${manifest_state:-missing}"
            failed=1
        elif [[ "$install_path" != "$expected_cache_path" || "$registry_version" != "$repo_version" || "$manifest_version" != "$repo_version" ]]; then
            err "registry-version: repo=$repo_version registry=${registry_version:-missing} manifest=${manifest_version:-missing} path=${install_path:-missing} expected=${expected_cache_path:-missing}"
            failed=1
        else
            pass "registry-version: $repo_version"
        fi
    fi

    runtime_ready && pass "runtime: claude -p /context" || { err "runtime: /context 未就绪"; failed=1; }

    return $failed
}


install_marketplace() {
    if [[ "$CTX_INSTALL_MODE" == "copy" ]]; then
        copy_marketplace
        return 0
    fi

    link_marketplace
}

apply_routing_patch() {
    local patch_file="$REPO_ROOT/config/context-mode/strict-bash-routing.patch"

    if [[ "$NO_PATCH" == true ]]; then
        info "跳过 routing.mjs 补丁 (--no-patch)"
        return 0
    fi

    [[ -f "$patch_file" ]] || {
        warn "补丁文件不存在: $patch_file"
        return 0
    }

    if routing_patch_applied; then
        ok "routing.mjs 补丁已应用"
        return 0
    fi

    info "应用 routing.mjs strict-bash 补丁到最终安装目标 ($CTX_INSTALL_MODE)..."

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN][mode=$CTX_INSTALL_MODE] git -C $MARKETPLACE_DST apply $patch_file"
        return 0
    fi

    [[ -d "$MARKETPLACE_DST" ]] || {
        err "context-mode 安装目标不存在: $MARKETPLACE_DST"
        return 1
    }

    if git -C "$MARKETPLACE_DST" rev-parse --is-inside-work-tree >/dev/null 2>&1 && git -C "$MARKETPLACE_DST" apply --check "$patch_file" 2>/dev/null; then
        git -C "$MARKETPLACE_DST" apply "$patch_file"
        ok "routing.mjs 补丁已应用 (git apply)"
    elif patch -p1 -d "$MARKETPLACE_DST" --dry-run --silent < "$patch_file" 2>/dev/null; then
        patch -p1 -d "$MARKETPLACE_DST" --silent < "$patch_file"
        ok "routing.mjs 补丁已应用 (patch)"
    else
        err "routing.mjs 补丁应用失败，请检查补丁与源码是否匹配"
        return 1
    fi
}

install() {
    validate_install_mode || return 1

    if [[ true == "$DRY_RUN" && ! -d "$CTX_DIR" ]]; then
        info "[DRY-RUN] assume prepared source exists: $CTX_DIR"
    elif [[ ! -d "$CTX_DIR" ]]; then
        err "context-mode 源目录不存在: $CTX_DIR"
        return 1
    fi

    info "context-mode 安装模式: $CTX_INSTALL_MODE"

    if [[ ! -d "$CTX_DIR/node_modules" ]]; then
        info "npm install context-mode..."
        if [[ true == "$DRY_RUN" ]]; then
            info "[DRY-RUN][mode=$CTX_INSTALL_MODE] (cd $CTX_DIR && npm install --no-audit --no-fund --loglevel=error)"
        else
            (
                cd "$CTX_DIR"
                npm install --no-audit --no-fund --loglevel=error
            ) || return 1
            ok "context-mode node_modules 已安装"
        fi
    else
        ok "context-mode node_modules 已存在"
    fi

    install_marketplace
    apply_routing_patch
    heal_registry_drift
}

verify() {
    if [[ true == "$DRY_RUN" ]]; then
        info "dry-run 模式跳过 verify (mode=$CTX_INSTALL_MODE)"
        return 0
    fi

    validate_install_mode || return 1
    status
    ok "context-mode verify 通过 ($(active_install_mode))"
}

uninstall() {
    local repo_version
    repo_version="$(repo_plugin_version 2>/dev/null || true)"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] remove owned context-mode marketplace at $MARKETPLACE_DST"
        if [[ -n "$repo_version" ]]; then
            info "[DRY-RUN] remove owned context-mode cache entry $(repo_cache_entry_path "$repo_version")"
        fi
        return 0
    fi

    if [[ -n "$repo_version" ]]; then
        cleanup_managed_cache_entry "$repo_version"
    fi

    if symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR"; then
        rm -f "$MARKETPLACE_DST"
        ok "context-mode owned marketplace symlink 已移除"
        return 0
    fi

    if [[ -d "$MARKETPLACE_DST" ]] && [[ ! -L "$MARKETPLACE_DST" ]]; then
        if ! marketplace_copy_is_owned; then
            warn "context-mode marketplace 是外部目录，跳过卸载: $MARKETPLACE_DST"
            return 0
        fi
        rm -rf "$MARKETPLACE_DST"
        ok "context-mode owned marketplace copy 已移除"
        return 0
    fi

    info "context-mode marketplace 无需卸载"
}

doctor() {
    info "context-mode doctor"
    heal_registry_drift
    status
}

main() {
    validate_install_mode || return 1

    if [[ "$ACTION" == "install" && false == "$FORCE" ]] && is_ready; then
        pass "context-mode 已就绪，跳过 ($(active_install_mode))"
        heal_registry_drift
        verify
        return 0
    fi

    if [[ "$ACTION" == "install" || "$ACTION" == "update" ]] && [[ "$CTX_INSTALL_MODE" == "auto" ]]; then
        CTX_INSTALL_MODE=symlink
        if install && verify; then
            return 0
        fi

        warn "context-mode symlink 安装失败，自动切换为 copy 模式"
        CTX_INSTALL_MODE=copy
        install
        verify
        return 0
    fi

    run_module_action "$ACTION"
}

main "$@"
