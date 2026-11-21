#!/usr/bin/env bash
# Tests for script/launch/plan.py — unified resource planner (absorbed from
# resource-plan.py). Bash wrapper driving the module's API + self-check.
#
# Covers: discover→normalize→conflict→select→validate 语义、9 字段 PlannedItem、
# wildcard 集合资源降级、npx 插件 id=name、越界 symlink 拒绝、request 过滤、
# choose 冲突解决。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 -m py_compile "$REPO_ROOT/script/launch/plan.py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 模块自带 __main__ assert 自检（真实仓库 + fixture 冲突/选择/过滤/降级）
python3 "$REPO_ROOT/script/launch/plan.py" || fail "plan 自检失败"

# --- API 级断言：fixture 仓库端到端 ---
python3 - "$REPO_ROOT" <<'PYEOF'
import sys
import tempfile
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "script"))
from launch.plan import PlanError, PlannedItem, plan_resources

fixture = Path(tempfile.mkdtemp())
outside = Path(tempfile.mkdtemp())
try:
    (fixture / "skills" / "local-one").mkdir(parents=True)
    (fixture / "skills" / "local-two").mkdir()
    (fixture / "skills" / "same").mkdir()
    for name in ("local-one", "local-two", "same"):
        (fixture / "skills" / name / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: test\n---\n", encoding="utf-8")
    (fixture / "configs").mkdir()
    (fixture / "configs" / "skills.toml").write_text(
        '[[sources]]\nname = "same"\nrepo = "owner/repo"\nskill = "same"\n'
        '[[sources]]\nname = "remote-a"\nrepo = "owner/repo"\nskill = "remote-a"\n'
        '[[sources]]\nname = "wildcard-src"\nrepo = "owner/wild"\nskill = "*"\n',
        encoding="utf-8")
    (fixture / "configs" / "plugins.toml").write_text(
        '[[plugins]]\nname = "plug"\nrepo = "owner/plugin"\nmethod = "claude-plugin"\n'
        'marketplace = "market"\n'
        '[[plugins]]\nname = "codegraph"\nrepo = "owner/codegraph"\nmethod = "npx"\n'
        'command = "npm i -g codegraph"\n', encoding="utf-8")

    # --- 全量发现：local + remote + wildcard 降级 + 插件 id 规范化 ---
    plan = plan_resources(fixture, [])
    ids = {(i.kind, i.id, i.source) for i in plan.items}
    assert ("skill", "local-one", "local") in ids
    assert ("skill", "same", "local") in ids
    assert ("skill", "same", "remote") in ids
    assert ("skill", "remote-a", "remote") in ids
    assert ("skill", "wildcard-src", "remote") in ids  # wildcard 无 inventory 降级
    assert ("plugin", "plug@market", "remote") in ids   # claude-plugin id=name@marketplace
    assert ("plugin", "codegraph", "remote") in ids     # npx 插件 id=name
    wildcard = next(i for i in plan.items if i.id == "wildcard-src")
    assert wildcard.collection
    assert all(len(vars(i)) >= 9 for i in plan.items)  # 9 字段 PlannedItem
    print("PASS: 全量发现（local/remote/wildcard 降级/插件 id 规范化）")

    # --- 未决冲突：不抛异常，进 conflicts，对应项 conflict=True、action="" ---
    plan = plan_resources(fixture, ["skill:same"])
    assert len(plan.conflicts) == 1 and plan.conflicts[0].id == "same"
    assert plan.conflicts[0].kind == "skill"
    assert {c.source for c in plan.conflicts[0].candidates} == {"local", "remote"}
    assert all(i.conflict and i.action == "" for i in plan.items)
    print("PASS: 未决冲突进 conflicts（不抛异常）")

    # --- choose 解决：local/remote/skip ---
    plan = plan_resources(fixture, ["skill:same"], choices={"skill:same": "local"})
    assert plan.conflicts == []
    assert all(i.action == "local" and not i.conflict for i in plan.items)
    plan = plan_resources(fixture, ["skill:same"], choices={"skill:same": "remote"})
    assert plan.conflicts == [] and all(i.action == "remote" for i in plan.items)
    plan = plan_resources(fixture, ["skill:same"], choices={"skill:same": "skip"})
    assert plan.conflicts == [] and all(i.action == "skip" for i in plan.items)
    print("PASS: choose local/remote/skip 解决冲突")

    # --- 非法 choose 值 → PlanError ---
    try:
        plan_resources(fixture, ["skill:same"], choices={"skill:same": "bogus"})
        raise AssertionError("非法 choose 值应报错")
    except PlanError:
        pass
    print("PASS: 非法 choose 值报错")

    # --- 唯一候选自动计划：local-two 无冲突 → action=local ---
    plan = plan_resources(fixture, ["skill:local-two"])
    assert plan.conflicts == []
    assert all(i.action == "local" for i in plan.items)
    print("PASS: 唯一候选自动计划")

    # --- request 命中 plugin 别名（裸 name 或 name@marketplace）---
    plan = plan_resources(fixture, ["plugin:plug"])
    assert {i.id for i in plan.items} == {"plug@market"}
    plan = plan_resources(fixture, ["plugin:plug@market"])
    assert {i.id for i in plan.items} == {"plug@market"}
    print("PASS: plugin request 裸名与全名均可命中")

    # --- request 不存在 → PlanError ---
    try:
        plan_resources(fixture, ["skill:nope"])
        raise AssertionError("不存在的请求应报错")
    except PlanError:
        pass
    try:
        plan_resources(fixture, ["bogus:x"])
        raise AssertionError("非法 request 格式应报错")
    except PlanError:
        pass
    print("PASS: request 不存在/格式非法报错")

    # --- 越界 symlink 拒绝 ---
    (outside / "SKILL.md").write_text("---\nname: escape\n---\n", encoding="utf-8")
    (fixture / "skills" / "escape").symlink_to(outside)
    try:
        plan_resources(fixture, [])
        raise AssertionError("越界 symlink 应报错")
    except PlanError:
        pass
    (fixture / "skills" / "escape").unlink()
    print("PASS: 越界 symlink 拒绝")
finally:
    import shutil
    shutil.rmtree(fixture, ignore_errors=True)
    shutil.rmtree(outside, ignore_errors=True)

PYEOF

echo "All resource plan tests passed."
