#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$SCRIPT_DIR/resource-plan.py"

python3 -m py_compile "$SCRIPT"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_fail() {
  local desc="$1"; shift
  local out rc
  set +e
  out="$($@ 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "$desc (预期失败却成功)"
  echo "$out" | grep -Eiq 'wildcard|SKILL|越界|mismatch|conflict|marketplace|不存在' || fail "$desc (缺少明确错误: $out)"
  echo "PASS: $desc (exit $rc)"
}

fixture="$(mktemp -d)"
outside="$(mktemp -d)"
cleanup() { rm -rf "$fixture" "$outside"; }
trap cleanup EXIT

: > "$fixture/empty-skills.tsv"
: > "$fixture/empty-plugins.tsv"
actual="$(python3 "$SCRIPT" --repo-root "$REPO_ROOT" --skills-file "$fixture/empty-skills.tsv" --plugins-file "$fixture/empty-plugins.tsv" --format json --remote-skill sample/owner/repo/sample)"
[[ -n "$actual" ]] || fail "真实仓库显式 remote skill 应输出 JSON"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert set(d)=={"version","resources","conflicts","plan","choices","selected"}; assert d["version"] == 1; assert all(r["kind"] in {"skill","plugin"} for r in d["resources"]); print("PASS: 真实仓库 JSON schema")' "$actual"
mkdir -p "$fixture/skills/local-one" "$fixture/skills/local-two" "$fixture/skills/same" "$fixture/config"
: > "$fixture/config/empty-skills.tsv"
: > "$fixture/config/empty-plugins.tsv"
printf '%s\n' '---' 'name: local-one' 'description: test' '---' > "$fixture/skills/local-one/SKILL.md"
printf '%s\n' '---' 'name: local-two' 'description: test' '---' > "$fixture/skills/local-two/SKILL.md"
printf '%s\n' '---' 'name: same' 'description: test' '---' > "$fixture/skills/same/SKILL.md"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' remote-source owner/repo '*' claude-code global wildcard > "$fixture/config/wildcard-skills.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' plug owner/plugin claude-plugin market '' 'plugin fixture' > "$fixture/config/plugins.tsv"
printf '%s\n' '[{"source":"owner/repo","name":"remote-a"},{"source":"owner/repo","name":"remote-b"}]' > "$fixture/config/inventory.json"
printf '%s\n' '---' 'name: outside' '---' > "$outside/SKILL.md"

# wildcard 无 inventory → 降级为集合资源（id=source alias，source=remote），不 PlanError；
# 保留整源更新语义，让真实仓库（全 wildcard）也能走统一 resolver。
set +e
collect_out="$(python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/wildcard-skills.tsv" --plugins-file "$fixture/config/plugins.tsv" --format json 2>&1)"
collect_rc=$?
set -e
[[ "$collect_rc" -eq 0 ]] || fail "wildcard 无 inventory 应降级为集合资源 (exit $collect_rc)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["conflicts"]==[]; assert any(r["kind"]=="skill" and r["id"]=="remote-source" and r["source"]=="remote" and r.get("collection") for r in d["resources"]); assert any(p["action"]=="remote" for p in d["plan"] if p["id"]=="remote-source"); print("PASS: wildcard 无 inventory 降级为集合资源")' "$collect_out"
expanded="$(python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/wildcard-skills.tsv" --plugins-file "$fixture/config/plugins.tsv" --inventory "$fixture/config/inventory.json" --format json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); ids={x["id"] for x in d["resources"] if x["source"]=="remote" and x["kind"]=="skill"}; assert {"remote-a","remote-b"} <= ids; assert "*" not in ids; print("PASS: wildcard inventory 展开为实际 skill")' "$expanded"
ln -s "$outside" "$fixture/skills/escape"
assert_fail "越界 symlink 应拒绝" python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/empty-plugins.tsv" --remote-skill owner/repo/remote

rm "$fixture/skills/escape"
chosen="$(python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/plugins.tsv" --remote-skill same=owner/repo/remote --choose skill:same=local --format json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["conflicts"] == []; assert any(x["id"]=="same" and x["action"]=="local" for x in d["plan"]); assert any(x["id"]=="plug@market" and x["kind"]=="plugin" for x in d["resources"]); assert any(x["id"]=="same" and x["source"]=="local" for x in d["selected"]); print("PASS: choose resolves local/remote conflict and canonicalizes plugin")' "$chosen"

assert_fail "未决冲突应 exit 2" python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/empty-plugins.tsv" --remote-skill local-one=owner/repo/remote

# --request：只对请求的资源做冲突检测与计划，未请求资源不进 plan
set +e
req_out="$(python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/empty-plugins.tsv" --remote-skill same=owner/repo/remote --remote-skill local-one=owner/repo/remote2 --request skill:same --format json 2>&1)"
req_rc=$?
set -e
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["conflicts"] and [c["id"] for c in d["conflicts"]]==["same"]; assert d["plan"]==[]; assert all(r["id"]=="same" for r in d["resources"]); print("PASS: request 过滤到指定资源并检测冲突")' "$req_out"
[[ $req_rc -eq 2 ]] || fail "request 未决冲突应 exit 2 (got $req_rc)"

req_unique="$(python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/empty-plugins.tsv" --request skill:local-one --format json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["conflicts"]==[]; assert [p["action"] for p in d["plan"]]==["local"]; print("PASS: request 唯一候选自动计划")' "$req_unique"

# ---- TSV 计划协议（TUI 消费）：9 列  kind\tid\tsource\tname\trepo\tmarketplace\tpath\taction\tconflict ----
# 未决冲突：两候选行 conflict=1、action 空；choose 解决后 conflict=0、action 为选择结果
set +e
tsv_conflict="$(python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/plugins.tsv" --remote-skill same=owner/repo/remote --request skill:same --format tsv 2>&1)"
tsv_conflict_rc=$?
set -e
[[ "$tsv_conflict_rc" -eq 2 ]] || fail "TSV 未决冲突应 exit 2 (got $tsv_conflict_rc)"
python3 -c 'import sys
rows=[l.split("\t") for l in sys.argv[1].splitlines() if l]
assert len(rows)==2, rows  # local same + remote same
assert all(len(r)==9 for r in rows), "TSV 必须 9 列"
by={r[2]:r for r in rows}
assert by["local"][0]=="skill" and by["local"][1]=="same" and by["local"][8]=="1", by["local"]
assert by["remote"][0]=="skill" and by["remote"][1]=="same" and by["remote"][8]=="1", by["remote"]
assert all(r[7]=="" for r in rows), "未决冲突 action 应为空"
print("PASS: TSV 未决冲突标记 conflict=1 且 exit 2")' "$tsv_conflict"
tsv_out="$(python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/plugins.tsv" --remote-skill same=owner/repo/remote --request skill:same --format tsv --choose skill:same=local)"
python3 -c 'import sys
rows=[l.split("\t") for l in sys.argv[1].splitlines() if l]
assert len(rows)==2, rows
assert all(len(r)==9 for r in rows), "TSV 必须 9 列"
by={r[2]:r for r in rows}
assert by["local"][8]=="0" and by["local"][7]=="local", by["local"]
assert by["remote"][8]=="0" and by["remote"][7]=="local", by["remote"]
print("PASS: TSV choose 解决后 conflict=0 且 action 为选择结果")' "$tsv_out"

req_skip="$(python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/empty-plugins.tsv" --remote-skill same=owner/repo/remote --request skill:same --choose skill:same=skip --format json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["conflicts"]==[]; assert d["plan"][0]["action"]=="skip"; assert d["selected"]==[]; print("PASS: request + choose skip 空计划")' "$req_skip"

assert_fail "request 不存在的资源应失败" python3 "$SCRIPT" --repo-root "$fixture" --skills-file "$fixture/config/empty-skills.tsv" --plugins-file "$fixture/config/empty-plugins.tsv" --request skill:nope

echo "All resource plan tests passed."
