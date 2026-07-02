#!/usr/bin/env bash
# 回归测试: remove_and_clone_third_party_source 必须是原子的
#   - clone 失败时, 原 target 完整保留 (不留下空/半残目录)
#   - clone 成功时, target 被新内容替换
#
# 通过 source setup.sh 复用其 helper 函数 (setup.sh 末尾有 source guard)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SH="$REPO_ROOT/setup.sh"

bash -n "$SETUP_SH"

# setup.sh 内部用相对路径 source 依赖, 必须在 REPO_ROOT 下 source
cd "$REPO_ROOT"
# source setup.sh 获取函数定义, guard 保证不触发 main
# shellcheck source=/dev/null
source "$SETUP_SH"

fixture="$(mktemp -d)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

# 造一个 origin (普通 working repo, git clone 可从本地 working repo clone)
origin="$fixture/origin"
# target 必须落在 safe_external_target 认可的 EXTERNAL_DIR 下
EXTERNAL_DIR="$fixture/external"
export EXTERNAL_DIR
target="$EXTERNAL_DIR/mysrc"
mkdir -p "$origin/hooks" "$EXTERNAL_DIR"
( cd "$origin" && git init -q
  git config user.email ci@example.invalid
  git config user.name "CI Test"
  printf 'original hook\n' > hooks/stop.mjs
  git add -A && git commit -qm "original" >/dev/null 2>&1
)

# 模拟已 clone 的 target
git clone -q "$origin" "$target"

assert_clone_failure_preserves_target() {
    # 用一个不存在的 url 触发 clone 失败 (git 会在 ~瞬间失败, 不依赖网络)
    local bad_url="/dev/null/does-not-exist.git"

    # 关闭 set -e 让我们能检查返回码
    set +e
    DRY_RUN=false remove_and_clone_third_party_source "mysrc" "$bad_url" "$target" "test" >/tmp/atom-fail.out 2>&1
    local rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
        echo "FAIL: clone 失败应返回非零, 实际 $rc" >&2
        return 1
    fi

    # 原 target 必须完整: hooks/stop.mjs 还在, 内容是 original
    if [[ ! -f "$target/hooks/stop.mjs" ]]; then
        echo "FAIL: clone 失败后 target 被删除/破坏: $target" >&2
        return 1
    fi
    if ! diff -q <(printf 'original hook\n') "$target/hooks/stop.mjs" >/dev/null; then
        echo "FAIL: clone 失败后 target 内容被改动" >&2
        return 1
    fi
    # 不应残留 staging 目录
    if ls -d "$EXTERNAL_DIR"/*.staging.* >/dev/null 2>&1; then
        echo "FAIL: 残留 staging 目录未清理" >&2
        return 1
    fi
    echo "PASS: clone 失败时原 target 完整保留"
}

assert_clone_success_replaces_target() {
    # 修改 origin working repo 提交新内容, 期望 reclone 后 target 反映新内容
    printf 'new hook v2\n' > "$origin/hooks/stop.mjs"
    git -C "$origin" commit -qam "v2"

    set +e
    DRY_RUN=false remove_and_clone_third_party_source "mysrc" "$origin" "$target" "test" >/tmp/atom-ok.out 2>&1
    local rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        echo "FAIL: clone 成功应返回 0, 实际 $rc" >&2
        cat /tmp/atom-ok.out >&2
        return 1
    fi
    if [[ ! -f "$target/hooks/stop.mjs" ]]; then
        echo "FAIL: clone 成功后 target 缺少 stop.mjs" >&2
        return 1
    fi
    if ! diff -q <(printf 'new hook v2\n') "$target/hooks/stop.mjs" >/dev/null; then
        echo "FAIL: target 内容未更新为新版本" >&2
        return 1
    fi
    echo "PASS: clone 成功时 target 被新内容替换"
}

assert_clone_failure_preserves_target
assert_clone_success_replaces_target

echo "All atomic-reclone regression tests passed."
