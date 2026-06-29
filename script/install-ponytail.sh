#!/usr/bin/env bash
# Install/update Ponytail as a managed Claude Code plugin marketplace.

set -euo pipefail

REPO_ROOT="${1:?usage: install-ponytail.sh <repo_root> [dry_run] [force]}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"
ACTION="${ACTION:-install}"

# shellcheck source=script/install-common.sh
source "$REPO_ROOT/script/install-common.sh"

PONYTAIL_REPO_URL="${PONYTAIL_REPO_URL:-https://github.com/DietrichGebert/ponytail.git}"
PONYTAIL_DIR="$REPO_ROOT/external/ponytail"

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/ponytail"
SETTINGS_JSON="$CLAUDE_HOME/settings.json"
INSTALLED_PLUGINS_JSON="$CLAUDE_HOME/plugins/installed_plugins.json"

PONYTAIL_MARKETPLACE_NAME="ponytail"
PONYTAIL_PLUGIN_NAME="ponytail"
PONYTAIL_PLUGIN_KEY="ponytail@ponytail"
PONYTAIL_MANIFEST="$PONYTAIL_DIR/.claude-plugin/plugin.json"
PONYTAIL_CACHE_ROOT="$CLAUDE_HOME/plugins/cache/ponytail/ponytail"

is_true() {
  [[ "${1:-false}" == "true" ]]
}

symlink_points_to() {
  local link="$1"
  local target="$2"
  [[ -L "$link" ]] || return 1
  [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

ponytail_version() {
  if command -v plugin_manifest_version >/dev/null 2>&1; then
    plugin_manifest_version "$PONYTAIL_MANIFEST"
    return
  fi

  python3 - "$PONYTAIL_MANIFEST" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
    print(data.get("version", "unknown"))
except Exception:
    print("unknown")
PY
}

marketplace_state() {
  if symlink_points_to "$MARKETPLACE_DST" "$PONYTAIL_DIR"; then
    echo "managed-symlink"
  elif [[ -e "$MARKETPLACE_DST" || -L "$MARKETPLACE_DST" ]]; then
    echo "foreign"
  else
    echo "missing"
  fi
}

ensure_source_checkout() {
  if [[ -f "$PONYTAIL_MANIFEST" ]]; then
    if [[ -d "$PONYTAIL_DIR/.git" || -f "$PONYTAIL_DIR/.git" ]]; then
      if [[ "$ACTION" == "update" || "$ACTION" == "reinstall" ]] || is_true "$FORCE"; then
        if ! is_true "$FORCE" && ! git -C "$PONYTAIL_DIR" diff --quiet --ignore-submodules --; then
          err "Ponytail source has local changes: $PONYTAIL_DIR. Re-run with --force to reset it."
          return 1
        fi

        if is_true "$DRY_RUN"; then
          info "DRY-RUN: would update Ponytail source at $PONYTAIL_DIR"
          return 0
        fi

        git -C "$PONYTAIL_DIR" fetch --depth=1 origin
        local remote_branch
        remote_branch="$(git -C "$PONYTAIL_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
        if [[ -n "$remote_branch" ]]; then
          git -C "$PONYTAIL_DIR" checkout -B "$remote_branch" "origin/$remote_branch"
          git -C "$PONYTAIL_DIR" reset --hard "origin/$remote_branch"
        else
          git -C "$PONYTAIL_DIR" checkout --detach FETCH_HEAD
          git -C "$PONYTAIL_DIR" reset --hard FETCH_HEAD
        fi
      fi
      return 0
    fi

    return 0
  fi

  if [[ -e "$PONYTAIL_DIR" ]]; then
    if ! is_true "$FORCE"; then
      err "Ponytail source exists but is not a valid plugin checkout: $PONYTAIL_DIR"
      return 1
    fi
    if is_true "$DRY_RUN"; then
      info "DRY-RUN: would remove invalid Ponytail source at $PONYTAIL_DIR"
    else
      rm -rf "$PONYTAIL_DIR"
    fi
  fi

  if is_true "$DRY_RUN"; then
    info "DRY-RUN: would clone $PONYTAIL_REPO_URL into $PONYTAIL_DIR"
    return 0
  fi

  mkdir -p "$(dirname "$PONYTAIL_DIR")"
  git clone --depth=1 "$PONYTAIL_REPO_URL" "$PONYTAIL_DIR"
}

link_marketplace() {
  mkdir -p "$(dirname "$MARKETPLACE_DST")"

  case "$(marketplace_state)" in
    managed-symlink)
      pass "Ponytail marketplace link already managed"
      return 0
      ;;
    foreign)
      if ! is_true "$FORCE"; then
        err "Marketplace path already exists and is not managed by this repo: $MARKETPLACE_DST"
        err "Use --force if you want to replace it with a symlink to $PONYTAIL_DIR"
        return 1
      fi
      if is_true "$DRY_RUN"; then
        info "DRY-RUN: would replace foreign marketplace path $MARKETPLACE_DST"
      else
        rm -rf "$MARKETPLACE_DST"
      fi
      ;;
  esac

  if is_true "$DRY_RUN"; then
    info "DRY-RUN: would link $MARKETPLACE_DST -> $PONYTAIL_DIR"
    return 0
  fi

  ln -s "$PONYTAIL_DIR" "$MARKETPLACE_DST"
  pass "Linked Ponytail marketplace"
}

enable_ponytail_in_settings() {
  if is_true "$DRY_RUN"; then
    info "DRY-RUN: would enable $PONYTAIL_PLUGIN_KEY in $SETTINGS_JSON"
    return 0
  fi

  python3 - "$SETTINGS_JSON" "$PONYTAIL_PLUGIN_KEY" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
plugin_key = sys.argv[2]

if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            data = {}
    except Exception:
        data = {}
else:
    data = {}

enabled = data.get("enabledPlugins")
if not isinstance(enabled, dict):
    enabled = {}
    data["enabledPlugins"] = enabled

enabled[plugin_key] = True
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY

  pass "Enabled $PONYTAIL_PLUGIN_KEY in settings.json"
}

settings_has_ponytail_enabled() {
  [[ -f "$SETTINGS_JSON" ]] || return 1
  python3 - "$SETTINGS_JSON" "$PONYTAIL_PLUGIN_KEY" <<'PY'
import json, pathlib, sys
try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if data.get("enabledPlugins", {}).get(sys.argv[2]) is True else 1)
PY
}

installed_plugins_has_ponytail_enabled() {
  [[ -f "$INSTALLED_PLUGINS_JSON" ]] || return 1
  python3 - "$INSTALLED_PLUGINS_JSON" "$PONYTAIL_PLUGIN_KEY" <<'PY'
import json, pathlib, sys
try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
key = sys.argv[2]
plugins = data.get("plugins", {})
enabled = data.get("enabledPlugins", {})
raise SystemExit(0 if isinstance(plugins, dict) and key in plugins and enabled.get(key) is True else 1)
PY
}

register_ponytail_to_installed_json() {
  if ! command -v register_plugins_to_installed_json >/dev/null 2>&1; then
    err "install-common.sh does not expose register_plugins_to_installed_json"
    return 1
  fi

  local entries_json
  entries_json="$(python3 - \
    "$PONYTAIL_PLUGIN_KEY" \
    "$PONYTAIL_MARKETPLACE_NAME" \
    "$PONYTAIL_PLUGIN_NAME" \
    "$PONYTAIL_DIR" \
    "$PONYTAIL_MANIFEST" <<'PY'
import json, sys
plugin_key, marketplace_name, plugin_name, source_path, plugin_json_path = sys.argv[1:]
print(json.dumps([{
    "pluginKey": plugin_key,
    "marketplaceName": marketplace_name,
    "pluginName": plugin_name,
    "sourcePath": source_path,
    "pluginJsonPath": plugin_json_path,
    "preferManaged": True,
}], ensure_ascii=False))
PY
)"

  register_plugins_to_installed_json "$entries_json" "$INSTALLED_PLUGINS_JSON" "$CLAUDE_HOME"
}

disable_ponytail_json_entries() {
  if is_true "$DRY_RUN"; then
    info "DRY-RUN: would disable/remove $PONYTAIL_PLUGIN_KEY from settings and installed_plugins.json"
    return 0
  fi

  python3 - "$SETTINGS_JSON" "$INSTALLED_PLUGINS_JSON" "$PONYTAIL_PLUGIN_KEY" <<'PY'
import json, pathlib, sys
settings_path = pathlib.Path(sys.argv[1])
installed_path = pathlib.Path(sys.argv[2])
plugin_key = sys.argv[3]

for path in (settings_path, installed_path):
    if not path.exists():
        continue
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            continue
    except Exception:
        continue

    enabled = data.get("enabledPlugins")
    if isinstance(enabled, dict):
        enabled.pop(plugin_key, None)

    if path == installed_path:
        plugins = data.get("plugins")
        if isinstance(plugins, dict):
            plugins.pop(plugin_key, None)

    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

remove_owned_cache_links() {
  [[ -d "$PONYTAIL_CACHE_ROOT" ]] || return 0

  local item
  for item in "$PONYTAIL_CACHE_ROOT"/*; do
    [[ -e "$item" || -L "$item" ]] || continue
    if [[ -L "$item" ]] && [[ "$(readlink -f "$item")" == "$(readlink -f "$PONYTAIL_DIR")" ]]; then
      if is_true "$DRY_RUN"; then
        info "DRY-RUN: would remove Ponytail cache link $item"
      else
        rm -f "$item"
      fi
    fi
  done
}

ponytail_ready() {
  [[ -f "$PONYTAIL_MANIFEST" ]] || return 1
  [[ "$(marketplace_state)" == "managed-symlink" ]] || return 1
  settings_has_ponytail_enabled || return 1
  installed_plugins_has_ponytail_enabled || return 1
}

install_ponytail() {
  ensure_source_checkout
  [[ -f "$PONYTAIL_MANIFEST" ]] || { err "Missing Ponytail manifest: $PONYTAIL_MANIFEST"; return 1; }

  link_marketplace
  enable_ponytail_in_settings
  register_ponytail_to_installed_json

  pass "Ponytail installed: $PONYTAIL_PLUGIN_KEY ($(ponytail_version))"
}

uninstall_ponytail() {
  if [[ "$(marketplace_state)" == "managed-symlink" ]]; then
    if is_true "$DRY_RUN"; then
      info "DRY-RUN: would remove marketplace link $MARKETPLACE_DST"
    else
      rm -f "$MARKETPLACE_DST"
    fi
  fi

  remove_owned_cache_links
  disable_ponytail_json_entries
  pass "Ponytail disabled/removed from Claude Code plugin registry"
}

status_ponytail() {
  local state version
  state="$(marketplace_state)"
  version="$(ponytail_version)"

  info "Ponytail source: $PONYTAIL_DIR"
  info "Manifest: $PONYTAIL_MANIFEST"
  info "Version: $version"
  info "Marketplace: $MARKETPLACE_DST [$state]"

  if settings_has_ponytail_enabled; then
    pass "settings.json enables $PONYTAIL_PLUGIN_KEY"
  else
    warn "settings.json does not enable $PONYTAIL_PLUGIN_KEY"
  fi

  if installed_plugins_has_ponytail_enabled; then
    pass "installed_plugins.json registers $PONYTAIL_PLUGIN_KEY"
  else
    warn "installed_plugins.json does not register $PONYTAIL_PLUGIN_KEY"
  fi
}

verify_ponytail() {
  status_ponytail
  if ponytail_ready; then
    pass "Ponytail verification passed"
  else
    err "Ponytail verification failed"
    return 1
  fi
}

doctor_ponytail() {
  status_ponytail

  if [[ ! -f "$PONYTAIL_MANIFEST" ]]; then
    warn "Ponytail source is missing. Run: ./setup.sh --plugins ponytail --force"
  fi

  if [[ "$(marketplace_state)" == "foreign" ]]; then
    warn "Marketplace path is occupied by a non-managed file/directory. Use --force to replace it."
  fi
}

main() {
  if [[ "$ACTION" != "uninstall" ]] && ponytail_ready && ! is_true "$FORCE" && [[ "$ACTION" != "update" ]]; then
    status_ponytail
    pass "Ponytail already installed. Use update/reinstall or --force to refresh."
    return 0
  fi

  run_module_action \
    "$ACTION" \
    install_ponytail \
    install_ponytail \
    install_ponytail \
    uninstall_ponytail \
    verify_ponytail \
    status_ponytail \
    doctor_ponytail
}

main "$@"
