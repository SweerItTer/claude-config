#!/usr/bin/env bash
# Regression test suite for plugin registry heal semantics.
#
# Validates that setup shared helpers can close the full loop from damaged or
# missing local plugin state to a valid Claude Code plugin registry without
# touching the user's real $HOME.
#
# Usage:
#   ./script/test-plugin-registry-heal.sh
#
# Exit code: 0 = all pass, 1 = any failure.
# Designed for CI: all I/O happens under /tmp.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/install-common.sh"
SETUP_SH="$REPO_ROOT/setup.sh"
CONTEXT_MODE_SH="$SCRIPT_DIR/install-context-mode.sh"
KNOWN_MARKETPLACES_CONFIG="$REPO_ROOT/config/known_marketplaces.json"

if [[ ! -f "$COMMON_SH" || ! -f "$SETUP_SH" || ! -f "$CONTEXT_MODE_SH" ]]; then
    echo "ERROR: required setup scripts are missing" >&2
    exit 1
fi

bash -n "$SETUP_SH" "$COMMON_SH" "$CONTEXT_MODE_SH"

# shellcheck source=./install-common.sh
source "$COMMON_SH"

make_plugin_manifest() {
    local plugin_dir="$1"
    local plugin_name="$2"
    local plugin_version="$3"

    mkdir -p "$plugin_dir/.claude-plugin"
    cat > "$plugin_dir/.claude-plugin/plugin.json" <<JSON
{"name":"$plugin_name","version":"$plugin_version"}
JSON
}

build_entries_json() {
    local fixture="$1"

    python3 - "$fixture" <<'PYEOF'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
entries = [
    {
        "pluginKey": "oh-my-claudecode@omc",
        "marketplaceName": "omc",
        "pluginName": "oh-my-claudecode",
        "sourcePath": str(fixture / "source" / "omc"),
        "pluginJsonPath": str(fixture / "source" / "omc" / ".claude-plugin" / "plugin.json"),
    },
    {
        "pluginKey": "superpowers@superpowers",
        "marketplaceName": "superpowers",
        "pluginName": "superpowers",
        "sourcePath": str(fixture / "source" / "superpowers"),
        "pluginJsonPath": str(fixture / "source" / "superpowers" / ".claude-plugin" / "plugin.json"),
    },
    {
        "pluginKey": "code-review@claude-plugins-official",
        "marketplaceName": "claude-plugins-official",
        "pluginName": "code-review",
        "sourcePath": str(fixture / "source" / "official" / "plugins" / "code-review"),
        "pluginJsonPath": str(fixture / "source" / "official" / "plugins" / "code-review" / ".claude-plugin" / "plugin.json"),
    },
]
print(json.dumps(entries))
PYEOF
}

assert_closed_loop_registry_repair() {
    local fixture
    local entries_json
    local hash_before

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    mkdir -p "$fixture/home/plugins"
    make_plugin_manifest "$fixture/source/omc" "oh-my-claudecode" "4.14.5"
    make_plugin_manifest "$fixture/source/superpowers" "superpowers" "5.1.0"
    make_plugin_manifest "$fixture/source/official/plugins/code-review" "code-review" "1fb8ee762823"

    cat > "$fixture/home/plugins/known_marketplaces.json" <<'JSON'
{
  "custom-local": {"installLocation": "/keep/custom"},
  "omc": {"installLocation": "/keep/omc"}
}
JSON
    printf '{broken installed registry\n' > "$fixture/home/plugins/installed_plugins.json"

    entries_json="$(build_entries_json "$fixture")"

    DRY_RUN=false \
    REPO_ROOT="$REPO_ROOT" \
    CLAUDE_HOME="$fixture/home" \
    KNOWN_MARKETPLACES_CONFIG="$KNOWN_MARKETPLACES_CONFIG" \
        merge_known_marketplaces >/tmp/test-plugin-registry-merge-1.out

    DRY_RUN=false \
    CLAUDE_HOME="$fixture/home" \
        register_plugins_to_installed_json "$entries_json" "$fixture/home/plugins/installed_plugins.json" "$fixture/home" \
        >/tmp/test-plugin-registry-register-1.out \
        2>/tmp/test-plugin-registry-register-1.err

    hash_before="$(sha256sum "$fixture/home/plugins/installed_plugins.json" | cut -d' ' -f1)"

    DRY_RUN=false \
    REPO_ROOT="$REPO_ROOT" \
    CLAUDE_HOME="$fixture/home" \
    KNOWN_MARKETPLACES_CONFIG="$KNOWN_MARKETPLACES_CONFIG" \
        merge_known_marketplaces >/tmp/test-plugin-registry-merge-2.out

    DRY_RUN=false \
    CLAUDE_HOME="$fixture/home" \
        register_plugins_to_installed_json "$entries_json" "$fixture/home/plugins/installed_plugins.json" "$fixture/home" \
        >/tmp/test-plugin-registry-register-2.out \
        2>/tmp/test-plugin-registry-register-2.err

    python3 - "$fixture" "$hash_before" <<'PYEOF'
import hashlib
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
hash_before = sys.argv[2]

known = json.loads((fixture / "home" / "plugins" / "known_marketplaces.json").read_text())
assert known["custom-local"]["installLocation"] == "/keep/custom"
assert known["omc"]["installLocation"] == "/keep/omc"
for marketplace in ["context-mode", "superpowers", "claude-plugins-official"]:
    assert marketplace in known, marketplace

registry_path = fixture / "home" / "plugins" / "installed_plugins.json"
registry = json.loads(registry_path.read_text())
assert registry["version"] == 2
expected = {
    "oh-my-claudecode@omc": "4.14.5",
    "superpowers@superpowers": "5.1.0",
    "code-review@claude-plugins-official": "1fb8ee762823",
}
for key, version in expected.items():
    entries = registry["plugins"][key]
    assert isinstance(entries, list) and len(entries) == 1, (key, entries)
    entry = entries[0]
    assert entry["version"] == version, entry
    for field in ["scope", "installPath", "version", "installedAt", "lastUpdated"]:
        assert field in entry, (field, entry)
    install_path = Path(entry["installPath"])
    assert install_path.exists(), install_path
    assert install_path.is_symlink(), install_path
    manifest = json.loads((install_path / ".claude-plugin" / "plugin.json").read_text())
    assert manifest["version"] == version, manifest
    assert registry["enabledPlugins"][key] is True

hash_after = hashlib.sha256(registry_path.read_bytes()).hexdigest()
assert hash_after == hash_before, (hash_before, hash_after)
print("PASS: closed-loop registry repair and idempotency")
PYEOF
}

assert_dry_run_does_not_write_damaged_known_marketplaces() {
    local fixture
    local before
    local after

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    mkdir -p "$fixture/home/plugins"
    printf '{broken marketplaces\n' > "$fixture/home/plugins/known_marketplaces.json"
    before="$(sha256sum "$fixture/home/plugins/known_marketplaces.json" | cut -d' ' -f1)"

    DRY_RUN=true \
    REPO_ROOT="$REPO_ROOT" \
    CLAUDE_HOME="$fixture/home" \
    KNOWN_MARKETPLACES_CONFIG="$KNOWN_MARKETPLACES_CONFIG" \
        merge_known_marketplaces \
        >/tmp/test-plugin-registry-dry-run.out \
        2>/tmp/test-plugin-registry-dry-run.err

    after="$(sha256sum "$fixture/home/plugins/known_marketplaces.json" | cut -d' ' -f1)"
    [[ "$before" == "$after" ]]
    grep -q "known_marketplaces.json 读取失败" /tmp/test-plugin-registry-dry-run.err
    grep -q "DRY-RUN.*将新增 marketplace" /tmp/test-plugin-registry-dry-run.out
    echo "PASS: dry-run handles damaged known_marketplaces without writing"
}

assert_existing_valid_registry_entry_is_preserved() {
    local fixture
    local entries_json

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    mkdir -p "$fixture/home/plugins" "$fixture/home/plugins/cache/omc/oh-my-claudecode/4.14.5"
    make_plugin_manifest "$fixture/source/omc" "oh-my-claudecode" "4.14.5"
    make_plugin_manifest "$fixture/source/other-valid" "oh-my-claudecode" "4.14.4"

    cat > "$fixture/home/plugins/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "oh-my-claudecode@omc": [
      {"scope":"user","installPath":"$fixture/source/other-valid","version":"4.14.4"}
    ]
  },
  "enabledPlugins": {}
}
JSON

    entries_json="$(python3 - "$fixture" <<'PYEOF'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
print(json.dumps([{
    "pluginKey": "oh-my-claudecode@omc",
    "marketplaceName": "omc",
    "pluginName": "oh-my-claudecode",
    "sourcePath": str(fixture / "source" / "omc"),
    "pluginJsonPath": str(fixture / "source" / "omc" / ".claude-plugin" / "plugin.json"),
}]))
PYEOF
)"

    DRY_RUN=false \
    CLAUDE_HOME="$fixture/home" \
        register_plugins_to_installed_json "$entries_json" "$fixture/home/plugins/installed_plugins.json" "$fixture/home" \
        >/tmp/test-plugin-registry-preserve.out \
        2>/tmp/test-plugin-registry-preserve.err

    python3 - "$fixture" <<'PYEOF'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
registry = json.loads((fixture / "home" / "plugins" / "installed_plugins.json").read_text())
entry = registry["plugins"]["oh-my-claudecode@omc"][0]
assert entry["installPath"] == str(fixture / "source" / "other-valid"), entry
assert entry["version"] == "4.14.4", entry
assert "installedAt" in entry and "lastUpdated" in entry, entry
assert registry["enabledPlugins"]["oh-my-claudecode@omc"] is True
assert not (fixture / "home" / "plugins" / "cache" / "omc" / "oh-my-claudecode" / "4.14.5").is_symlink()
print("PASS: existing valid registry entry is preserved")
PYEOF
}

assert_context_mode_uses_shared_registry_heal() {
    local fixture

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    mkdir -p \
        "$fixture/repo/script" \
        "$fixture/repo/external/context-mode/.claude-plugin" \
        "$fixture/repo/external/context-mode/node_modules" \
        "$fixture/repo/external/context-mode/hooks/core" \
        "$fixture/home/plugins" \
        "$fixture/bin"

    cp "$COMMON_SH" "$fixture/repo/script/install-common.sh"
    cat > "$fixture/repo/external/context-mode/.claude-plugin/plugin.json" <<'JSON'
{"name":"context-mode","version":"1.0.162"}
JSON
    cat > "$fixture/repo/external/context-mode/hooks/core/routing.mjs" <<'JS'
// CTX_STRICT_BASH
JS
    cat > "$fixture/home/settings.json" <<'JSON'
{"enabledPlugins":{"context-mode@context-mode":true},"hooks":{"PreToolUse":[{"hooks":[{"command":"pretooluse.mjs"}]}]}}
JSON
    cat > "$fixture/home/plugins/known_marketplaces.json" <<'JSON'
{"context-mode":{"installLocation":"/tmp/context-mode"}}
JSON
    cat > "$fixture/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'context ok\n'
SH
    chmod +x "$fixture/bin/claude"

    PATH="$fixture/bin:$PATH" \
    DRY_RUN=false \
    ACTION=install \
    CTX_INSTALL_MODE=symlink \
    CLAUDE_CONFIG_DIR="$fixture/home" \
        bash "$CONTEXT_MODE_SH" "$fixture/repo" false false true \
        >/tmp/test-plugin-registry-context-mode.out \
        2>/tmp/test-plugin-registry-context-mode.err

    python3 - "$fixture" <<'PYEOF'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
registry = json.loads((fixture / "home" / "plugins" / "installed_plugins.json").read_text())
entry = registry["plugins"]["context-mode@context-mode"][0]
expected = fixture / "home" / "plugins" / "cache" / "context-mode" / "context-mode" / "1.0.162"
assert entry["installPath"] == str(expected), entry
assert expected.exists(), expected
assert expected.is_symlink(), expected
assert expected.resolve() == (fixture / "home" / "plugins" / "marketplaces" / "context-mode").resolve()
assert (expected / ".claude-plugin" / "plugin.json").is_file()
assert registry["enabledPlugins"]["context-mode@context-mode"] is True
print("PASS: context-mode shared registry heal")
PYEOF
}

assert_context_mode_force_converges_unmanaged_stale_marketplace() {
    local fixture

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    mkdir -p \
        "$fixture/repo/script" \
        "$fixture/repo/external/context-mode/.claude-plugin" \
        "$fixture/repo/external/context-mode/node_modules" \
        "$fixture/repo/external/context-mode/hooks/core" \
        "$fixture/home/plugins/marketplaces/context-mode" \
        "$fixture/home/plugins/cache/context-mode/context-mode" \
        "$fixture/bin"

    cp "$COMMON_SH" "$fixture/repo/script/install-common.sh"
    # repo 源: 新版本
    cat > "$fixture/repo/external/context-mode/.claude-plugin/plugin.json" <<'JSON'
{"name":"context-mode","version":"1.0.169"}
JSON
    cat > "$fixture/repo/external/context-mode/hooks/core/routing.mjs" <<'JS'
// CTX_STRICT_BASH
JS
    git -C "$fixture/repo/external/context-mode" init -q
    git -C "$fixture/repo/external/context-mode" config user.name "CI Test"
    git -C "$fixture/repo/external/context-mode" config user.email "ci@example.invalid"
    git -C "$fixture/repo/external/context-mode" add .
    git -C "$fixture/repo/external/context-mode" commit -q -m "fixture context-mode 1.0.169"

    # marketplace: 非受管真实目录, 内容是旧版本 1.0.162, 无 .source-rev
    mkdir -p "$fixture/home/plugins/marketplaces/context-mode/.claude-plugin"
    cat > "$fixture/home/plugins/marketplaces/context-mode/.claude-plugin/plugin.json" <<'JSON'
{"name":"context-mode","version":"1.0.162"}
JSON
    mkdir -p "$fixture/home/plugins/marketplaces/context-mode/hooks/core"
    cat > "$fixture/home/plugins/marketplaces/context-mode/hooks/core/routing.mjs" <<'JS'
// CTX_STRICT_BASH
JS
    cat > "$fixture/home/settings.json" <<'JSON'
{"enabledPlugins":{"context-mode@context-mode":true},"hooks":{"PreToolUse":[{"hooks":[{"command":"pretooluse.mjs"}]}]}}
JSON
    cat > "$fixture/home/plugins/known_marketplaces.json" <<'JSON'
{"context-mode":{"installLocation":"/tmp/context-mode"}}
JSON
    cat > "$fixture/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'context ok\n'
SH
    chmod +x "$fixture/bin/claude"

    # FORCE=true: 必须收敛 (覆盖非受管残留), 不得因保护逻辑卡死
    PATH="$fixture/bin:$PATH" \
    DRY_RUN=false \
    ACTION=install \
    FORCE=true \
    CTX_INSTALL_MODE=copy \
    CLAUDE_CONFIG_DIR="$fixture/home" \
        bash "$CONTEXT_MODE_SH" "$fixture/repo" false true true \
        >/tmp/test-plugin-registry-force.out \
        2>/tmp/test-plugin-registry-force.err

    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FORCE install failed (rc=$rc):" >&2
        cat /tmp/test-plugin-registry-force.err >&2
        return 1
    fi

    python3 - "$fixture" <<'PYEOF'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
# marketplace 已重建为新版本 (1.0.169), 带 .source-rev 标记为受管 copy
mp_manifest = fixture / "home" / "plugins" / "marketplaces" / "context-mode" / ".claude-plugin" / "plugin.json"
manifest_version = json.loads(mp_manifest.read_text()).get("version")
assert manifest_version == "1.0.169", manifest_version
assert (fixture / "home" / "plugins" / "marketplaces" / "context-mode" / ".source-rev").is_file(), \
    "marketplace copy 未被标记为受管 (.source-rev 缺失)"

registry = json.loads((fixture / "home" / "plugins" / "installed_plugins.json").read_text())
entry = registry["plugins"]["context-mode@context-mode"][0]
expected = fixture / "home" / "plugins" / "cache" / "context-mode" / "context-mode" / "1.0.169"
assert entry["installPath"] == str(expected), entry
assert entry["version"] == "1.0.169", entry
assert registry["enabledPlugins"]["context-mode@context-mode"] is True
print("PASS: force converges unmanaged stale marketplace copy")
PYEOF
}

assert_context_mode_doctor_heals_registry_drift() {
    local fixture

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    mkdir -p \
        "$fixture/repo/script" \
        "$fixture/repo/external/context-mode/.claude-plugin" \
        "$fixture/repo/external/context-mode/node_modules" \
        "$fixture/repo/external/context-mode/hooks/core" \
        "$fixture/home/plugins/marketplaces" \
        "$fixture/bin"

    cp "$COMMON_SH" "$fixture/repo/script/install-common.sh"
    cat > "$fixture/repo/external/context-mode/.claude-plugin/plugin.json" <<'JSON'
{"name":"context-mode","version":"1.0.162"}
JSON
    cat > "$fixture/repo/external/context-mode/hooks/core/routing.mjs" <<'JS'
// CTX_STRICT_BASH
JS
    git -C "$fixture/repo/external/context-mode" init -q
    git -C "$fixture/repo/external/context-mode" config user.name "CI Test"
    git -C "$fixture/repo/external/context-mode" config user.email "ci@example.invalid"
    git -C "$fixture/repo/external/context-mode" add .
    git -C "$fixture/repo/external/context-mode" commit -q -m "fixture context-mode"
    cp -a "$fixture/repo/external/context-mode" "$fixture/home/plugins/marketplaces/context-mode"
    git -C "$fixture/repo/external/context-mode" rev-parse HEAD > "$fixture/home/plugins/marketplaces/context-mode/.source-rev"
    cat > "$fixture/home/settings.json" <<'JSON'
{"enabledPlugins":{"context-mode@context-mode":true},"hooks":{"PreToolUse":[{"hooks":[{"command":"pretooluse.mjs"}]}]}}
JSON
    cat > "$fixture/home/plugins/known_marketplaces.json" <<'JSON'
{"context-mode":{"installLocation":"/tmp/context-mode"}}
JSON
    cat > "$fixture/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'context ok\n'
SH
    chmod +x "$fixture/bin/claude"
    mkdir -p "$fixture/home/plugins/cache/context-mode/context-mode/1.0.162"
    printf 'stale cache directory\n' > "$fixture/home/plugins/cache/context-mode/context-mode/1.0.162/stale.txt"

    PATH="$fixture/bin:$PATH" \
    ACTION=doctor \
    CTX_INSTALL_MODE=copy \
    CLAUDE_CONFIG_DIR="$fixture/home" \
        bash "$CONTEXT_MODE_SH" "$fixture/repo" false false true \
        >/tmp/test-plugin-registry-context-mode-doctor.out \
        2>/tmp/test-plugin-registry-context-mode-doctor.err

    python3 - "$fixture" <<'PYEOF'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
registry = json.loads((fixture / "home" / "plugins" / "installed_plugins.json").read_text())
entry = registry["plugins"]["context-mode@context-mode"][0]
expected = fixture / "home" / "plugins" / "cache" / "context-mode" / "context-mode" / "1.0.162"
assert entry["installPath"] == str(expected), entry
assert expected.exists(), expected
assert expected.is_symlink(), expected
assert expected.resolve() == (fixture / "home" / "plugins" / "marketplaces" / "context-mode").resolve()
assert registry["enabledPlugins"]["context-mode@context-mode"] is True
print("PASS: context-mode doctor heals registry drift")
PYEOF
}

assert_context_mode_install_rewrites_stale_stop_hook() {
    local fixture

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    mkdir -p \
        "$fixture/repo/script" \
        "$fixture/repo/external/context-mode/.claude-plugin" \
        "$fixture/repo/external/context-mode/node_modules" \
        "$fixture/repo/external/context-mode/hooks/core" \
        "$fixture/home/plugins" \
        "$fixture/bin"

    cp "$COMMON_SH" "$fixture/repo/script/install-common.sh"
    cat > "$fixture/repo/external/context-mode/.claude-plugin/plugin.json" <<'JSON'
{"name":"context-mode","version":"1.0.162"}
JSON
    cat > "$fixture/repo/external/context-mode/hooks/core/routing.mjs" <<'JS'
// CTX_STRICT_BASH
JS
    cat > "$fixture/home/settings.json" <<'JSON'
{"enabledPlugins":{"context-mode@context-mode":true},"hooks":{"PreToolUse":[{"hooks":[{"command":"pretooluse.mjs"}]}],"Stop":[{"hooks":[{"command":"\"/old/node\" \"/broken/cache/context-mode/context-mode/1.0.111/hooks/stop.mjs\""}]}]}}
JSON
    cat > "$fixture/home/plugins/known_marketplaces.json" <<'JSON'
{"context-mode":{"installLocation":"/tmp/context-mode"}}
JSON
    cat > "$fixture/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'context ok\n'
SH
    cat > "$fixture/bin/node" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fixture/bin/claude" "$fixture/bin/node"

    PATH="$fixture/bin:$PATH" \
    DRY_RUN=false \
    ACTION=install \
    CTX_INSTALL_MODE=symlink \
    CLAUDE_CONFIG_DIR="$fixture/home" \
        bash "$CONTEXT_MODE_SH" "$fixture/repo" false false true \
        >/tmp/test-plugin-registry-context-mode-stop.out \
        2>/tmp/test-plugin-registry-context-mode-stop.err

    python3 - "$fixture" <<'PYEOF'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
settings = json.loads((fixture / "home" / "settings.json").read_text())
command = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
expected_install = fixture / "home" / "plugins" / "cache" / "context-mode" / "context-mode" / "1.0.162"
expected = f'"{(fixture / "bin" / "node").as_posix()}" "{(expected_install / "hooks" / "stop.mjs").as_posix()}"'
assert command == expected, {"command": command, "expected": expected}
assert "/broken/cache/" not in command, command
print("PASS: context-mode install rewrites stale Stop hook")
PYEOF
}

assert_context_mode_auto_copy_applies_patches() {
    local fixture

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    mkdir -p \
        "$fixture/repo/script" \
        "$fixture/repo/config/context-mode" \
        "$fixture/repo/external/context-mode/.claude-plugin" \
        "$fixture/repo/external/context-mode/node_modules" \
        "$fixture/repo/external/context-mode/hooks/core" \
        "$fixture/home/plugins" \
        "$fixture/bin"

    cp "$COMMON_SH" "$fixture/repo/script/install-common.sh"
    cp "$REPO_ROOT/config/context-mode/strict-bash-routing.patch" "$fixture/repo/config/context-mode/strict-bash-routing.patch"
    cp "$REPO_ROOT/external/context-mode/start.mjs" "$fixture/repo/external/context-mode/start.mjs"
    cp "$REPO_ROOT/external/context-mode/hooks/core/routing.mjs" "$fixture/repo/external/context-mode/hooks/core/routing.mjs"
    cat > "$fixture/repo/external/context-mode/.claude-plugin/plugin.json" <<'JSON'
{"name":"context-mode","version":"1.0.169"}
JSON
    git -C "$fixture/repo/external/context-mode" init -q
    git -C "$fixture/repo/external/context-mode" config user.name "CI Test"
    git -C "$fixture/repo/external/context-mode" config user.email "ci@example.invalid"
    git -C "$fixture/repo/external/context-mode" add .
    git -C "$fixture/repo/external/context-mode" commit -q -m "fixture context-mode auto-copy"
    cat > "$fixture/home/settings.json" <<'JSON'
{"enabledPlugins":{"context-mode@context-mode":true},"hooks":{"PreToolUse":[{"hooks":[{"command":"pretooluse.mjs"}]}]}}
JSON
    cat > "$fixture/home/plugins/known_marketplaces.json" <<'JSON'
{"context-mode":{"installLocation":"/tmp/context-mode"}}
JSON
    cat > "$fixture/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'context ok\n'
SH
    chmod +x "$fixture/bin/claude"

    PATH="$fixture/bin:$PATH" \
    DRY_RUN=false \
    ACTION=install \
    CTX_INSTALL_MODE=auto \
    CLAUDE_CONFIG_DIR="$fixture/home" \
        bash "$CONTEXT_MODE_SH" "$fixture/repo" false false false \
        >/tmp/test-plugin-registry-context-mode-auto.out \
        2>/tmp/test-plugin-registry-context-mode-auto.err

    python3 - "$fixture" <<'PYEOF'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
marketplace = fixture / "home" / "plugins" / "marketplaces" / "context-mode"
source = fixture / "repo" / "external" / "context-mode"
assert marketplace.exists(), marketplace
assert not marketplace.is_symlink(), marketplace
assert (marketplace / ".source-rev").is_file(), marketplace
routing = (marketplace / "hooks" / "core" / "routing.mjs").read_text(encoding='utf-8')
start = (marketplace / "start.mjs").read_text(encoding='utf-8')
assert "CTX_STRICT_BASH" in routing
assert 'marketplaces","context-mode' in start
assert 'mkdirSync(parent,{recursive:true})' in start
assert 'marketplaces","context-mode' not in (source / "start.mjs").read_text(encoding='utf-8')
registry = json.loads((fixture / "home" / "plugins" / "installed_plugins.json").read_text())
entry = registry["plugins"]["context-mode@context-mode"][0]
expected_cache = fixture / "home" / "plugins" / "cache" / "context-mode" / "context-mode" / "1.0.169"
assert entry["installPath"] == str(expected_cache), entry
assert expected_cache.is_symlink(), expected_cache
assert expected_cache.resolve() == marketplace.resolve(), (expected_cache.resolve(), marketplace.resolve())
print("PASS: context-mode auto mode uses copy and applies patches")
PYEOF
}

assert_setup_dry_run_surfaces_registry_phase() {
    local fixture
    local output

    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' RETURN

    output="$(CLAUDE_CONFIG_DIR="$fixture/home" "$SETUP_SH" --dry-run --no-claude --no-verify 2>&1)"
    printf '%s\n' "$output" | grep -q "合并 known_marketplaces.json"
    printf '%s\n' "$output" | grep -q "Phase 4.5: Plugin registry 修复"
    printf '%s\n' "$output" | grep -q "DRY-RUN.*ensure plugin cache oh-my-claudecode@omc"
    echo "PASS: setup dry-run surfaces marketplace and registry heal phase"
}

assert_closed_loop_registry_repair
assert_dry_run_does_not_write_damaged_known_marketplaces
assert_existing_valid_registry_entry_is_preserved
assert_context_mode_uses_shared_registry_heal
assert_context_mode_doctor_heals_registry_drift
assert_context_mode_install_rewrites_stale_stop_hook
assert_context_mode_auto_copy_applies_patches
assert_context_mode_force_converges_unmanaged_stale_marketplace
assert_setup_dry_run_surfaces_registry_phase

echo "All plugin registry heal regression tests passed."
