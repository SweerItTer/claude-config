#!/usr/bin/env bash
# Regression test suite for settings.json merge semantics.
#
# Validates that the merge logic in setup.sh preserves:
#   1. Existing scalar values on conflict (prefer-existing)
#   2. Missing sub-keys in nested objects get backfilled
#   3. Existing settings-owned arrays remain source of truth; template arrays only backfill when missing
#
# Usage:
#   ./script/test-settings-merge.sh          # run all tests
#   ./script/test-settings-merge.sh -v       # verbose output
#
# Exit code: 0 = all pass, 1 = any failure.
# Designed for CI: no $HOME dependency, all I/O under /tmp.

set -euo pipefail

VERBOSE=false
[[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && VERBOSE=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="${SCRIPT_DIR}/../setup.sh"

if [[ ! -f "$SETUP_SH" ]]; then
    echo "ERROR: setup.sh not found at $SETUP_SH" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract merge functions from setup.sh and assemble a self-contained test
# file that runs everything in a single python3 invocation.
# ---------------------------------------------------------------------------

TEST_FILE=$(mktemp /tmp/test-settings-merge-XXXXXX.py)
trap 'rm -f "$TEST_FILE"' EXIT

# Step 1: Write Python imports + the extracted merge helpers + all tests.
python3 -c "
import re, sys
with open(sys.argv[1], 'r') as f:
    src = f.read()
blocks = list(re.finditer(r\"python3.*?<<'PYEOF'\n(.*?)PYEOF\", src, re.DOTALL))
target = None
for b in blocks:
    if 'def merge_object(' in b.group(1):
        target = b
        break
if target is None:
    print('ERROR: merge block not found in setup.sh', file=sys.stderr)
    sys.exit(1)
body = target.group(1)
lines = body.splitlines()
func_lines = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith('path = ') or stripped.startswith('rendered_template = '):
        break
    if stripped.startswith('with open('):
        break
    func_lines.append(line)
merge_code = '\n'.join(func_lines)
print(merge_code)
" "$SETUP_SH" > "$TEST_FILE"

# Step 2: Append the test harness after the merge functions.
cat >> "$TEST_FILE" << 'PYEOF'

# -----------------------------------------------------------------------
# Test harness
# -----------------------------------------------------------------------
import sys
import json
import os
import tempfile

results = []

def ok(label):
    results.append(("PASS", label))

def fail(label, detail=""):
    results.append(("FAIL", label + (" — " + detail if detail else "")))

def assert_eq(label, expected, actual):
    if expected == actual:
        ok(label)
    else:
        fail(label, f"expected {expected!r}, got {actual!r}")

# -----------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------

# T1: merge_object with prefer_existing preserves conflicting scalar values.
def test_merge_object_preserves_existing_scalar():
    result = merge_object({"theme": "dark"}, {"theme": "light"}, prefer_existing=True)
    assert_eq("T1: existing scalar preserved", "dark", result["theme"])

# T2: merge_object with prefer_existing adds missing keys while keeping existing.
def test_merge_object_adds_missing_key():
    result = merge_object({"theme": "dark"}, {"language": "zh-CN"}, prefer_existing=True)
    assert_eq("T2a: existing key kept", "dark", result["theme"])
    assert_eq("T2b: missing key backfilled", "zh-CN", result["language"])

# T3: merge_object WITHOUT prefer_existing overwrites existing values.
def test_merge_object_overwrites_no_prefer():
    result = merge_object({"theme": "dark"}, {"theme": "light"}, prefer_existing=False)
    assert_eq("T3: overwrite when not prefer_existing", "light", result["theme"])

# T4: merge_list keeps existing array unchanged when already present.
def test_merge_list_preserves_existing():
    existing = [{"command": "echo hi"}]
    template = [{"command": "echo hi"}, {"command": "echo bye"}]
    result = merge_list(existing, template)
    assert_eq("T4: existing array preserved as source of truth", existing, result)

# T5: merge_list backfills template array only when existing field is missing.
def test_merge_list_backfills_missing():
    template = [{"command": "echo bye"}]
    result = merge_list(None, template)
    assert_eq("T5: missing array backfilled from template", template, result)

# T6: merge_list handles missing template gracefully.
def test_merge_list_none_template():
    existing = [{"a": 1}]
    result = merge_list(existing, None)
    assert_eq("T6: existing array kept when template missing", existing, result)

# T7: merge_permissions preserves existing array fields and only backfills
#     missing array fields from template while keeping scalar/object behavior.
def test_merge_permissions():
    existing = {"allow": ["Bash(git *)"]}
    template = {"allow": ["Bash(npm *)"], "deny": ["Bash(rm -rf /*)"]}
    result = merge_permissions(existing, template)
    assert_eq("T7a: existing allow preserved", ["Bash(git *)"], result["allow"])
    assert_eq("T7b: missing deny backfilled", ["Bash(rm -rf /*)"], result["deny"])

# T8: Full end-to-end merge mimicking the real merge_settings_json flow.
#     This validates generic recursive missing-only semantics.
def test_full_e2e():
    existing = {
        "env": {"MY_VAR": "user_value"},
        "enabledPlugins": {
            "plugin-a": True,
            "playwright@claude-plugins-official": True,
            "obra/superpowers@superpowers": True,
            "ecc@ecc": True,
        },
        "extraKnownMarketplaces": {},
        "hooks": {"PreToolUse": [{"command": "user-hook.sh"}]},
        "permissions": {"allow": ["Bash(git *)"]},
        "disabledMcpServers": ["user-only-entry"],
        "think": False,
        "language": "en",
        "nested": {
            "scalar": "keep",
            "array": ["keep-array"],
            "object": {"existing": 1},
        },
    }
    template = {
        "$schema": "https://json.schemastore.org/claude-code-settings.json",
        "skillListingBudgetFraction": 0.01,
        "skillOverrides": {"superpowers:using-superpowers": "on"},
        "maxSkillDescriptionChars": 64,
        "theme": "dark",
        "env": {"MY_VAR": "template_value", "NEW_VAR": "new"},
        "enabledPlugins": {"plugin-a": False, "plugin-b": True},
        "extraKnownMarketplaces": {"marketplace-x": {}},
        "hooks": {
            "PreToolUse": [{"command": "user-hook.sh"}, {"command": "template-hook.sh"}],
            "PostToolUse": [{"command": "post-hook.sh"}],
        },
        "permissions": {"allow": ["Bash(npm *)"], "deny": ["Bash(curl *)"]},
        "disabledMcpServers": ["template-default"],
        "think": True,
        "language": "zh-CN",
        "nested": {
            "scalar": "template",
            "array": ["template-array"],
            "object": {"existing": 2, "added": 3},
            "newValue": "backfilled",
        },
    }

    target = tempfile.mktemp(suffix=".json")
    with open(target, "w") as f:
        json.dump(existing, f)

    current = json.load(open(target))
    current = merge_missing(current, template, skip_empty=True)
    current["enabledPlugins"] = migrate_default_disabled_plugins(current.get("enabledPlugins"))

    # -- Assertions --
    assert_eq("T8a: existing env preserved", "user_value", current["env"]["MY_VAR"])
    assert_eq("T8b: new env added", "new", current["env"]["NEW_VAR"])
    assert_eq("T8c: existing plugin preserved", True, current["enabledPlugins"]["plugin-a"])
    assert_eq("T8d: new plugin added", True, current["enabledPlugins"]["plugin-b"])
    assert_eq("T8e: existing PreToolUse preserved",
              [{"command": "user-hook.sh"}], current["hooks"]["PreToolUse"])
    assert_eq("T8f: missing PostToolUse backfilled",
              [{"command": "post-hook.sh"}], current["hooks"]["PostToolUse"])
    assert_eq("T8g: existing allow preserved",
              ["Bash(git *)"], current["permissions"]["allow"])
    assert_eq("T8h: missing deny backfilled",
              ["Bash(curl *)"], current["permissions"]["deny"])
    assert_eq("T8i: disabledMcpServers unchanged",
              ["user-only-entry"], current["disabledMcpServers"])
    assert_eq("T8j: think not overwritten", False, current["think"])
    assert_eq("T8k: language not overwritten", "en", current["language"])
    assert_eq("T8l: schema backfilled", "https://json.schemastore.org/claude-code-settings.json", current["$schema"])
    assert_eq("T8m: skillListingBudgetFraction backfilled", 0.01, current["skillListingBudgetFraction"])
    assert_eq("T8n: skillOverrides backfilled", {"superpowers:using-superpowers": "on"}, current["skillOverrides"])
    assert_eq("T8o: maxSkillDescriptionChars backfilled", 64, current["maxSkillDescriptionChars"])
    assert_eq("T8p: theme backfilled", "dark", current["theme"])
    assert_eq("T8q: nested scalar preserved", "keep", current["nested"]["scalar"])
    assert_eq("T8r: nested array preserved", ["keep-array"], current["nested"]["array"])
    assert_eq("T8s: nested object field preserved", 1, current["nested"]["object"]["existing"])
    assert_eq("T8t: nested object field backfilled", 3, current["nested"]["object"]["added"])
    assert_eq("T8u: nested missing key backfilled", "backfilled", current["nested"]["newValue"])
    assert_eq("T8v: existing playwright plugin not removed", True,
              current["enabledPlugins"]["playwright@claude-plugins-official"])
    assert_eq("T8w: existing legacy superpowers plugin not removed", True,
              current["enabledPlugins"]["obra/superpowers@superpowers"])
    assert_eq("T8x: existing legacy ecc plugin not removed", True,
              current["enabledPlugins"]["ecc@ecc"])

    os.unlink(target)

# T9: merge_object skip_empty=True skips empty string values.
def test_merge_object_skip_empty():
    result = merge_object({"a": "keep"}, {"a": "", "b": ""}, skip_empty=True)
    assert_eq("T9a: non-empty preserved", "keep", result["a"])
    assert_eq("T9b: empty not added", False, "b" in result)

# T10: merge_list preserves the existing array exactly when the field already exists.
def test_merge_list_preserves_existing_shape():
    existing = [{"a": 1, "b": 2}]
    template = [{"b": 2, "a": 1}]
    result = merge_list(existing, template)
    assert_eq("T10: existing array preserved unchanged", existing, result)

# T11: merge_permissions still prefers existing non-list keys and preserves
#      existing array fields unchanged.
def test_merge_permissions_non_list_prefer():
    existing = {"allow": ["x"], "custom_key": "old_val"}
    template = {"allow": ["y"], "custom_key": "new_val"}
    result = merge_permissions(existing, template)
    assert_eq("T11a: non-list key kept", "old_val", result["custom_key"])
    assert_eq("T11b: existing allow preserved", ["x"], result["allow"])

# T12: enabledPlugins must preserve existing explicit booleans and only backfill
#      missing plugin keys from template.
def test_enabled_plugins_preserve_existing_values():
    existing = {
        "existing-true": True,
        "existing-false": False,
    }
    template = {
        "existing-true": False,
        "existing-false": True,
        "new-plugin": True,
    }
    result = merge_missing(existing, template)
    assert_eq("T12a: existing true preserved", True, result["existing-true"])
    assert_eq("T12b: existing false preserved", False, result["existing-false"])
    assert_eq("T12c: missing plugin backfilled", True, result["new-plugin"])

# T13: recursive missing-only merge must backfill missing nested keys while
#      preserving existing scalar, object, and array values unchanged.
def test_merge_missing_recursive_backfill_without_mutation():
    existing = {
        "theme": "dark",
        "nested": {
            "scalar": "user",
            "object": {"keep": 1},
            "array": ["user-only"],
            "partial": {"keep": True},
        },
    }
    template = {
        "theme": "light",
        "nested": {
            "scalar": "template",
            "object": {"keep": 2, "add": 3},
            "array": ["template-only"],
            "partial": {"keep": False, "add": "new"},
            "new_scalar": "backfilled",
        },
    }
    result = merge_missing(existing, template)
    assert_eq("T13a: top-level scalar preserved", "dark", result["theme"])
    assert_eq("T13b: nested scalar preserved", "user", result["nested"]["scalar"])
    assert_eq("T13c: nested object existing field preserved", 1, result["nested"]["object"]["keep"])
    assert_eq("T13d: nested object missing field backfilled", 3, result["nested"]["object"]["add"])
    assert_eq("T13e: nested array preserved unchanged", ["user-only"], result["nested"]["array"])
    assert_eq("T13f: partial object existing field preserved", True, result["nested"]["partial"]["keep"])
    assert_eq("T13g: partial object missing field backfilled", "new", result["nested"]["partial"]["add"])
    assert_eq("T13h: missing nested scalar backfilled", "backfilled", result["nested"]["new_scalar"])

# -----------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------

tests = [
    test_merge_object_preserves_existing_scalar,
    test_merge_object_adds_missing_key,
    test_merge_object_overwrites_no_prefer,
    test_merge_list_preserves_existing,
    test_merge_list_backfills_missing,
    test_merge_list_none_template,
    test_merge_permissions,
    test_full_e2e,
    test_merge_object_skip_empty,
    test_merge_list_preserves_existing_shape,
    test_merge_permissions_non_list_prefer,
    test_enabled_plugins_preserve_existing_values,
    test_merge_missing_recursive_backfill_without_mutation,
]

for t in tests:
    try:
        t()
    except Exception as e:
        fail(f"{t.__name__} — exception: {e}")

pass_count = sum(1 for s, _ in results if s == "PASS")
fail_count = sum(1 for s, _ in results if s == "FAIL")

for status, label in results:
    print(f"  {status}: {label}")

print(f"\n=== Results: {pass_count} passed, {fail_count} failed out of {len(results)} ===")
sys.exit(1 if fail_count > 0 else 0)
PYEOF

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

$VERBOSE && echo "=== settings.json merge regression tests ==="
python3 "$TEST_FILE"
