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

plugin_manifest_version() {
    local plugin_json_path="$1"

    PLUGIN_JSON_PATH="$plugin_json_path" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

path = Path(os.environ['PLUGIN_JSON_PATH'])
if not path.is_file():
    raise SystemExit(1)
version = json.loads(path.read_text(encoding='utf-8')).get('version', '')
if not isinstance(version, str) or not version:
    raise SystemExit(1)
print(version)
PYEOF
}

plugin_cache_entry_path() {
    local marketplace_name="$1"
    local plugin_name="$2"
    local version="$3"
    local claude_home="${4:-${CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}}"

    printf '%s/plugins/cache/%s/%s/%s\n' "$claude_home" "$marketplace_name" "$plugin_name" "$version"
}

merge_known_marketplaces() {
    local config_path="${1:-${KNOWN_MARKETPLACES_CONFIG:?缺少 KNOWN_MARKETPLACES_CONFIG}}"
    local target_path="${2:-${CLAUDE_HOME:?缺少 CLAUDE_HOME}/plugins/known_marketplaces.json}"
    local repo_root="${3:-${REPO_ROOT:?缺少 REPO_ROOT}}"

    info "合并 known_marketplaces.json..."

    if [[ "${DRY_RUN:-false}" == true ]]; then
        KNOWN_MARKETPLACES_CONFIG="$config_path" \
        KNOWN_MARKETPLACES_TARGET="$target_path" \
        REPO_ROOT="$repo_root" \
        python3 - <<'PYEOF'
import json
import os
import sys
from pathlib import Path

config_path = Path(os.environ['KNOWN_MARKETPLACES_CONFIG'])
target_path = Path(os.environ['KNOWN_MARKETPLACES_TARGET'])
repo_root = os.environ['REPO_ROOT']

repo_data = json.loads(config_path.read_text(encoding='utf-8')) if config_path.is_file() else {}
if target_path.is_file():
    try:
        local_data = json.loads(target_path.read_text(encoding='utf-8'))
        if not isinstance(local_data, dict):
            local_data = {}
    except Exception as exc:
        print(f"  [WARN] [DRY-RUN] known_marketplaces.json 读取失败，将按空本地配置预览: {exc}", file=sys.stderr)
        local_data = {}
else:
    local_data = {}
missing = [key for key in repo_data if key not in local_data]
preserved = [key for key in repo_data if key in local_data]
print(f"  [INFO] [DRY-RUN] merge {config_path} into {target_path} with REPO_ROOT={repo_root}")
if missing:
    print(f"  [INFO] [DRY-RUN] 将新增 marketplace: {', '.join(missing)}")
if preserved:
    print(f"  [INFO] [DRY-RUN] 保留已有 marketplace: {', '.join(preserved)}")
if not missing and not preserved:
    print("  [INFO] [DRY-RUN] 没有可合并的 repository marketplace")
PYEOF
        return 0
    fi

    mkdir -p "$(dirname "$target_path")"
    KNOWN_MARKETPLACES_CONFIG="$config_path" \
    KNOWN_MARKETPLACES_TARGET="$target_path" \
    REPO_ROOT="$repo_root" \
    python3 - <<'PYEOF'
import json
import os
from pathlib import Path

config_path = Path(os.environ['KNOWN_MARKETPLACES_CONFIG'])
target_path = Path(os.environ['KNOWN_MARKETPLACES_TARGET'])
repo_root = os.environ['REPO_ROOT']


def render_repo_root(value):
    if isinstance(value, str):
        if value == 'REPO_ROOT':
            return repo_root
        if value.startswith('REPO_ROOT/'):
            return str(Path(repo_root) / value[len('REPO_ROOT/'):])
        return value
    if isinstance(value, list):
        return [render_repo_root(item) for item in value]
    if isinstance(value, dict):
        return {key: render_repo_root(item) for key, item in value.items()}
    return value

repo_data = json.loads(config_path.read_text(encoding='utf-8')) if config_path.is_file() else {}
repo_data = render_repo_root(repo_data)

if target_path.is_file():
    local_data = json.loads(target_path.read_text(encoding='utf-8'))
    if not isinstance(local_data, dict):
        local_data = {}
else:
    local_data = {}

changed = False
for key, value in repo_data.items():
    if key not in local_data:
        local_data[key] = value
        changed = True

if changed or not target_path.is_file():
    target_path.write_text(json.dumps(local_data, indent=4, ensure_ascii=False) + '\n', encoding='utf-8')
PYEOF
    ok "known_marketplaces.json 已合并"
}

register_plugins_to_installed_json() {
    local entries_json="${1:?需要 plugin registration JSON entries}"
    local registry_path="${2:-${CLAUDE_HOME:?缺少 CLAUDE_HOME}/plugins/installed_plugins.json}"
    local claude_home="${3:-${CLAUDE_HOME:?缺少 CLAUDE_HOME}}"

    PLUGIN_REGISTRY_ENTRIES_JSON="$entries_json" \
    INSTALLED_PLUGINS_JSON="$registry_path" \
    CLAUDE_HOME="$claude_home" \
    DRY_RUN="${DRY_RUN:-false}" \
    python3 - <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

entries = json.loads(os.environ['PLUGIN_REGISTRY_ENTRIES_JSON'])
registry_path = Path(os.environ['INSTALLED_PLUGINS_JSON'])
claude_home = Path(os.environ['CLAUDE_HOME'])
dry_run = os.environ.get('DRY_RUN') == 'true'
required = ('pluginKey', 'marketplaceName', 'pluginName', 'sourcePath', 'pluginJsonPath')

if not isinstance(entries, list):
    print('  [ERR] registry: plugin entries 必须是 JSON array', file=sys.stderr)
    raise SystemExit(1)

prepared = []
failed = False

if registry_path.is_file() and not dry_run:
    try:
        registry = json.loads(registry_path.read_text(encoding='utf-8'))
        if not isinstance(registry, dict):
            registry = {}
    except Exception as exc:
        print(f"  [WARN] registry: installed_plugins.json 读取失败，将重新初始化: {exc}", file=sys.stderr)
        registry = {}
else:
    registry = {}

existing_plugins = registry.get('plugins') if isinstance(registry.get('plugins'), dict) else {}

for entry in entries:
    if not isinstance(entry, dict):
        print('  [WARN] registry: 跳过非对象 plugin entry', file=sys.stderr)
        continue

    missing = [key for key in required if not entry.get(key)]
    label = entry.get('pluginKey') or entry.get('pluginName') or '<unknown>'
    if missing:
        print(f"  [WARN] registry: 跳过 {label}，缺少字段: {', '.join(missing)}", file=sys.stderr)
        continue

    plugin_key = str(entry['pluginKey'])
    marketplace_name = str(entry['marketplaceName'])
    plugin_name = str(entry['pluginName'])
    source_path = Path(str(entry['sourcePath']))
    plugin_json_path = Path(str(entry['pluginJsonPath']))
    prefer_managed = entry.get('preferManaged') is True

    if not plugin_json_path.is_file():
        if dry_run:
            print(f"  [INFO] [DRY-RUN] skip plugin cache/registry {plugin_key}: manifest missing at {plugin_json_path}")
        print(f"  [WARN] registry: 跳过 {plugin_key}，plugin manifest 不存在: {plugin_json_path}", file=sys.stderr)
        continue

    if not source_path.exists() and not dry_run:
        print(f"  [WARN] registry: 跳过 {plugin_key}，sourcePath 不存在: {source_path}", file=sys.stderr)
        continue

    try:
        manifest = json.loads(plugin_json_path.read_text(encoding='utf-8'))
    except Exception as exc:
        print(f"  [WARN] registry: 跳过 {plugin_key}，manifest 读取失败: {exc}", file=sys.stderr)
        continue

    version = manifest.get('version')
    if not isinstance(version, str) or not version:
        print(f"  [WARN] registry: 跳过 {plugin_key}，manifest 缺少有效 version: {plugin_json_path}", file=sys.stderr)
        continue

    cache_path = claude_home / 'plugins' / 'cache' / marketplace_name / plugin_name / version

    current_entries = existing_plugins.get(plugin_key)
    if not dry_run and not prefer_managed and isinstance(current_entries, list):
        for candidate in current_entries:
            if not isinstance(candidate, dict):
                continue
            candidate_install_path = candidate.get('installPath')
            if candidate_install_path and Path(candidate_install_path).exists():
                prepared.append({
                    'pluginKey': plugin_key,
                    'cachePath': candidate_install_path,
                    'version': candidate.get('version') or version,
                    'preferManaged': False,
                    'preserveExisting': True,
                })
                print(f"  [OK] registry: 保留已有有效 installPath {plugin_key}")
                break
        if prepared and prepared[-1].get('pluginKey') == plugin_key and prepared[-1].get('preserveExisting'):
            continue

    if dry_run:
        print(f"  [INFO] [DRY-RUN] ensure plugin cache {plugin_key}: {cache_path} -> {source_path}")
        print(f"  [INFO] [DRY-RUN] heal installed_plugins entry {plugin_key} version={version}")
        prepared.append({
            'pluginKey': plugin_key,
            'cachePath': str(cache_path),
            'version': version,
            'preferManaged': prefer_managed,
        })
        continue

    try:
        if cache_path.is_symlink():
            resolved_cache = cache_path.resolve(strict=False)
            resolved_source = source_path.resolve(strict=False)
            if resolved_cache != resolved_source:
                print(f"  [ERR] registry: cache 入口冲突，跳过 {plugin_key}: {cache_path} -> {resolved_cache}，期望 {resolved_source}", file=sys.stderr)
                failed = True
                continue
        elif cache_path.exists():
            print(f"  [ERR] registry: cache 入口已存在且不是 symlink，跳过 {plugin_key}: {cache_path}", file=sys.stderr)
            failed = True
            continue
        else:
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.symlink_to(source_path)
            print(f"  [OK] registry: cache entry {plugin_key} -> {cache_path}")
    except OSError as exc:
        print(f"  [ERR] registry: 无法创建 cache entry {plugin_key}: {exc}", file=sys.stderr)
        failed = True
        continue

    cache_manifest_path = cache_path / '.claude-plugin' / 'plugin.json'
    if not cache_manifest_path.is_file():
        print(f"  [ERR] registry: cache manifest 缺失，跳过 registry 写入 {plugin_key}: {cache_manifest_path}", file=sys.stderr)
        failed = True
        continue

    try:
        cache_version = json.loads(cache_manifest_path.read_text(encoding='utf-8')).get('version')
    except Exception as exc:
        print(f"  [ERR] registry: cache manifest 读取失败，跳过 {plugin_key}: {exc}", file=sys.stderr)
        failed = True
        continue

    if cache_version != version:
        print(f"  [ERR] registry: cache manifest version 不一致，跳过 {plugin_key}: expected={version} actual={cache_version}", file=sys.stderr)
        failed = True
        continue

    prepared.append({
        'pluginKey': plugin_key,
        'cachePath': str(cache_path),
        'version': version,
    })

if dry_run:
    raise SystemExit(0)

if prepared:
    registry_path.parent.mkdir(parents=True, exist_ok=True)

    changed = False
    if registry.get('version') != 2:
        registry['version'] = 2
        changed = True

    plugins = registry.get('plugins')
    if not isinstance(plugins, dict):
        plugins = {}
        registry['plugins'] = plugins
        changed = True

    enabled = registry.get('enabledPlugins')
    if not isinstance(enabled, dict):
        enabled = {}
        registry['enabledPlugins'] = enabled
        changed = True

    now = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

    for item in prepared:
        plugin_key = item['pluginKey']
        cache_path = item['cachePath']
        version = item['version']
        current_entries = plugins.get(plugin_key)
        current_entry = None
        valid_existing_entry = None
        if isinstance(current_entries, list):
            for candidate in current_entries:
                if not isinstance(candidate, dict):
                    continue
                candidate_install_path = candidate.get('installPath')
                if candidate_install_path and Path(candidate_install_path).exists() and valid_existing_entry is None:
                    valid_existing_entry = candidate
                if candidate_install_path == cache_path and Path(cache_path).exists():
                    current_entry = candidate
                    break

        if valid_existing_entry is not None and current_entry is None and not item.get('preferManaged'):
            print(f"  [OK] registry: 保留已有有效 installPath {plugin_key}")
            if enabled.get(plugin_key) is not True:
                enabled[plugin_key] = True
                changed = True
            continue

        expected_entry = {
            'scope': current_entry.get('scope', 'user') if isinstance(current_entry, dict) else 'user',
            'installPath': cache_path,
            'version': version,
            'installedAt': current_entry.get('installedAt', now) if isinstance(current_entry, dict) else now,
            'lastUpdated': current_entry.get('lastUpdated', now) if isinstance(current_entry, dict) else now,
        }

        if current_entries != [expected_entry]:
            plugins[plugin_key] = [expected_entry]
            changed = True
            print(f"  [OK] registry: installed_plugins 已写入 {plugin_key}")
        else:
            print(f"  [OK] registry: installed_plugins 已存在 {plugin_key}")

        if enabled.get(plugin_key) is not True:
            enabled[plugin_key] = True
            changed = True

    if changed or not registry_path.is_file():
        registry_path.write_text(json.dumps(registry, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

if failed:
    raise SystemExit(1)
PYEOF
}
