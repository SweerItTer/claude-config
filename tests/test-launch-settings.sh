#!/usr/bin/env bash
# Regression tests for launch.core settings merge semantics (replaces the old
# setup.sh-extracting test-settings-merge.sh with direct module-level tests).
#
# Validates that merge_settings_json preserves:
#   1. Existing scalar values on conflict (prefer-existing / missing-only merge)
#   2. Missing sub-keys in nested objects get backfilled
#   3. Existing arrays remain source of truth; template arrays only backfill when missing
#   4. Legacy ECC plugin keys and RTK hooks are cleaned
#
# Usage: bash tests/test-launch-settings.sh   (exit 0 = pass)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LAUNCH_REPO_ROOT="$REPO_ROOT" python3 - <<'PYEOF'
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(os.environ["LAUNCH_REPO_ROOT"]) / "script"))

from launch import core

results = []
ok = lambda label: results.append(("PASS", label))
def fail(label, detail=""):
    results.append(("FAIL", label + (" — " + detail if detail else "")))
def assert_eq(label, expected, actual):
    if expected == actual:
        ok(label)
    else:
        fail(label, f"expected {expected!r}, got {actual!r}")

def merge(e, t, **kw):
    return core._merge_missing(e, t, **kw)

# T1: existing scalar preserved on conflict.
assert_eq("T1: existing scalar preserved", "dark", merge({"theme": "dark"}, {"theme": "light"})["theme"])

# T2: missing key backfilled while existing kept.
r = merge({"theme": "dark"}, {"language": "zh-CN"})
assert_eq("T2a: existing key kept", "dark", r["theme"])
assert_eq("T2b: missing key backfilled", "zh-CN", r["language"])

# T3: skip_empty=True skips empty template strings.
r = merge({"a": "keep"}, {"a": "", "b": ""}, skip_empty=True)
assert_eq("T3a: non-empty preserved", "keep", r["a"])
assert_eq("T3b: empty not added", False, "b" in r)

# T4: existing array preserved as source of truth.
existing = [{"command": "echo hi"}]
assert_eq("T4: existing array preserved", existing, merge(existing, [{"command": "echo bye"}]))

# T5: missing array backfilled.
template = [{"command": "echo bye"}]
assert_eq("T5: missing array backfilled", template, merge(None, template))

# T6: recursive backfill without overwriting nested values.
existing = {"theme": "dark", "nested": {"scalar": "user", "object": {"keep": 1}, "array": ["user-only"]}}
template = {"theme": "light", "nested": {"scalar": "template", "object": {"keep": 2, "add": 3},
                                         "array": ["template-only"], "new_scalar": "backfilled"}}
r = merge(existing, template)
assert_eq("T6a: top-level scalar preserved", "dark", r["theme"])
assert_eq("T6b: nested scalar preserved", "user", r["nested"]["scalar"])
assert_eq("T6c: nested object keep preserved", 1, r["nested"]["object"]["keep"])
assert_eq("T6d: nested object add backfilled", 3, r["nested"]["object"]["add"])
assert_eq("T6e: nested array preserved", ["user-only"], r["nested"]["array"])
assert_eq("T6f: missing nested scalar backfilled", "backfilled", r["nested"]["new_scalar"])

# T7: enabledPlugins booleans preserved, missing backfilled.
r = merge({"existing-true": True, "existing-false": False},
          {"existing-true": False, "existing-false": True, "new-plugin": True})
assert_eq("T7a: existing true preserved", True, r["existing-true"])
assert_eq("T7b: existing false preserved", False, r["existing-false"])
assert_eq("T7c: missing plugin backfilled", True, r["new-plugin"])

# T8: end-to-end merge_settings_json — prefer-existing + backfill + legacy cleanup.
existing = {
    "theme": "dark",
    "env": {"USER_TOKEN": "keepme"},
    "enabledPlugins": {
        "user-only-plugin@github": True,
        "ecc@ecc": True,
        "affaan-m/everything-claude-code@ecc": True,
    },
    "extraKnownMarketplaces": {"ecc": {}},
    "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [
        {"command": "user-hook.sh"}, {"command": "rtk hook claude"}, {"command": "rtk-rewrite"},
    ]}]},
    "permissions": {"allow": ["Bash(git *)"]},
    "think": False,
}
template = {
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "theme": "light",
    "env": {"USER_TOKEN": "template", "NEW_VAR": "new"},
    "enabledPlugins": {"plugin-b": True},
    "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"command": "user-hook.sh"}]}]},
    "permissions": {"allow": ["Bash(npm *)"], "deny": ["Bash(curl *)"]},
    "think": True,
}
with tempfile.TemporaryDirectory() as tmp:
    target = Path(tmp) / "settings.json"
    target.write_text(json.dumps(existing), encoding="utf-8")
    core.merge_settings_json(target, json.dumps(template))
    d = json.loads(target.read_text(encoding="utf-8"))

assert_eq("T8a: existing env preserved", "keepme", d["env"]["USER_TOKEN"])
assert_eq("T8b: new env backfilled", "new", d["env"]["NEW_VAR"])
assert_eq("T8c: user plugin preserved", True, d["enabledPlugins"]["user-only-plugin@github"])
assert_eq("T8d: new plugin backfilled", True, d["enabledPlugins"]["plugin-b"])
assert_eq("T8e: legacy ecc plugin popped", False, "ecc@ecc" in d["enabledPlugins"])
assert_eq("T8f: legacy everything-claude-code popped",
          False, "affaan-m/everything-claude-code@ecc" in d["enabledPlugins"])
assert_eq("T8g: legacy marketplace popped", False, "ecc" in d.get("extraKnownMarketplaces", {}))
assert_eq("T8h: user hook kept", {"command": "user-hook.sh"},
          d["hooks"]["PreToolUse"][0]["hooks"][0])
assert_eq("T8i: rtk hooks removed", 1, len(d["hooks"]["PreToolUse"][0]["hooks"]))
assert_eq("T8j: existing allow preserved", ["Bash(git *)"], d["permissions"]["allow"])
assert_eq("T8k: missing deny backfilled", ["Bash(curl *)"], d["permissions"]["deny"])
assert_eq("T8l: think not overwritten", False, d["think"])
assert_eq("T8m: schema backfilled", "https://json.schemastore.org/claude-code-settings.json", d["$schema"])

# T9: merge_settings_json keeps enabledPlugins a dict even when the file had none.
with tempfile.TemporaryDirectory() as tmp:
    target = Path(tmp) / "settings.json"
    target.write_text(json.dumps({"theme": "dark"}), encoding="utf-8")
    core.merge_settings_json(target, json.dumps({"enabledPlugins": {"p@mp": True}}))
    d = json.loads(target.read_text(encoding="utf-8"))
assert_eq("T9: enabledPlugins dict ensured + backfilled", {"p@mp": True}, d["enabledPlugins"])

fail_count = sum(1 for s, _ in results if s == "FAIL")
for status, label in results:
    print(f"  {status}: {label}")
print(f"\n=== Results: {len(results) - fail_count} passed, {fail_count} failed out of {len(results)} ===")
sys.exit(1 if fail_count else 0)
PYEOF
