#!/usr/bin/env bash

pass() { echo "  [PASS] $*"; }
info() { echo "  [INFO] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
err()  { echo "  [ERR] $*"; }

run_module_action() {
    local action="$1"
    shift

    case "$action" in
        install|update)
            install "$@"
            verify "$@"
            ;;
        reinstall)
            uninstall "$@"
            install "$@"
            verify "$@"
            ;;
        uninstall)
            uninstall "$@"
            ;;
        verify)
            verify "$@"
            ;;
        status)
            status "$@"
            ;;
        doctor)
            doctor "$@"
            ;;
        *)
            err "不支持的 ACTION: $action"
            return 1
            ;;
    esac
}

remove_symlink_if_target() {
    local path="$1"
    local expected_target="$2"

    [[ -L "$path" ]] || return 0
    [[ "$(readlink -f "$path")" == "$(readlink -f "$expected_target")" ]] || return 0

    rm -f "$path"
}

remove_legacy_settings_entries() {
    local target_path="${1:?缺少 settings.json 路径}"

    [[ -f "$target_path" ]] || return 0
    if [[ "${DRY_RUN:-false}" == true ]]; then
        info "[DRY-RUN] 清理 settings.json 中旧 ECC plugin 与 RTK hook: $target_path"
        return 0
    fi

    LEGACY_SETTINGS_PATH="$target_path" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

path = Path(os.environ['LEGACY_SETTINGS_PATH'])
data = json.loads(path.read_text(encoding='utf-8'))
changed = False
legacy_plugins = {
    'ecc@ecc',
    'affaan-m/everything-claude-code@ecc',
}
plugins = data.get('enabledPlugins')
if isinstance(plugins, dict):
    for key in legacy_plugins:
        if key in plugins:
            plugins.pop(key)
            changed = True

extra_marketplaces = data.get('extraKnownMarketplaces')
if isinstance(extra_marketplaces, dict) and extra_marketplaces.pop('ecc', None) is not None:
    changed = True

hooks = data.get('hooks')
legacy_commands = {'rtk hook claude', 'rtk-rewrite'}
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
            if len(cleaned_hooks) != len(group['hooks']):
                changed = True
                if cleaned_hooks:
                    updated_group = dict(group)
                    updated_group['hooks'] = cleaned_hooks
                    cleaned_groups.append(updated_group)
            else:
                cleaned_groups.append(group)
        if cleaned_groups != groups:
            hooks[event] = cleaned_groups

if changed:
    path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + '\n', encoding='utf-8')
PYEOF
}

remove_legacy_marketplace_entries() {
    local target_path="${1:?缺少 known_marketplaces.json 路径}"

    [[ -f "$target_path" ]] || return 0
    if [[ "${DRY_RUN:-false}" == true ]]; then
        info "[DRY-RUN] 清理 known_marketplaces.json 中旧 ecc 条目: $target_path"
        return 0
    fi

    LEGACY_MARKETPLACES_PATH="$target_path" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

path = Path(os.environ['LEGACY_MARKETPLACES_PATH'])
data = json.loads(path.read_text(encoding='utf-8'))
if not isinstance(data, dict):
    raise ValueError('known_marketplaces.json 顶层必须是对象')
changed = data.pop('ecc', None) is not None
if changed:
    path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + '\n', encoding='utf-8')
PYEOF
}

remove_legacy_installed_plugins_entries() {
    local target_path="${1:?缺少 installed_plugins.json 路径}"

    [[ -f "$target_path" ]] || return 0
    if [[ "${DRY_RUN:-false}" == true ]]; then
        info "[DRY-RUN] 清理 installed_plugins.json 中旧 ECC 注册: $target_path"
        return 0
    fi

    LEGACY_INSTALLED_PLUGINS_PATH="$target_path" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

path = Path(os.environ['LEGACY_INSTALLED_PLUGINS_PATH'])
data = json.loads(path.read_text(encoding='utf-8'))
if not isinstance(data, dict):
    raise ValueError('installed_plugins.json 顶层必须是对象')
legacy = {'ecc@ecc', 'affaan-m/everything-claude-code@ecc'}
changed = False
for field in ('plugins', 'enabledPlugins'):
    values = data.get(field)
    if isinstance(values, dict):
        for key in legacy:
            if key in values:
                values.pop(key)
                changed = True
if changed:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
PYEOF
}

remove_legacy_rtk_link() {
    local target_path="${1:?缺少 RTK.md 路径}"
    local expected_path="${2:?缺少旧 RTK.md 源路径}"

    [[ -L "$target_path" ]] || return 0
    local link_target
    link_target="$(readlink "$target_path")"
    if [[ "$link_target" != "$expected_path" && "$(readlink -f "$target_path" 2>/dev/null || true)" != "$expected_path" ]]; then
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == true ]]; then
        info "[DRY-RUN] rm $target_path"
    else
        rm -f "$target_path"
        log "已移除旧 RTK.md symlink"
    fi
}
