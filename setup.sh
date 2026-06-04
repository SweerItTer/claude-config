#!/usr/bin/env bash
# ============================================================
# Claude Code Config Migration — 一键初始化脚本 v3
# 用法: git clone <repo-url> && ./setup.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ORIGINAL_ARGS=("$@")
SETUP_UPDATE_REEXECED="${SETUP_UPDATE_REEXECED:-false}"

if [[ "$(id -u)" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$REAL_HOME/.claude}"
    export CLAUDE_CONFIG_DIR="$CLAUDE_HOME"
else
    CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
fi

SCRIPT_DIR="$REPO_ROOT/script"

DRY_RUN=false
CI_MODE=false
NO_CLAUDE=false
NO_VERIFY=false
FORCE=false
SMOKE_TEST=false
UPDATE=false
UPDATE_THIRD_PARTY_REMOTE=false
NO_PATCH=false
ECC_FULL=false
ECC_FOCUSED=false
ECC_PROFILE=""
ECC_MODULES=""
ECC_SKILLS=""
ACTION="install"
ACTION_EXPLICIT=false

KNOWN_MARKETPLACES_CONFIG="$REPO_ROOT/config/known_marketplaces.json"
EXTERNAL_DIR="$REPO_ROOT/external"

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
phase() { echo ""; echo -e "${BLUE}═══ $* ═══${NC}"; echo ""; }
pass()  { echo -e "${BLUE}[PASS]${NC} $*"; }

symlink_points_to() {
    local link="$1"
    local target="$2"
    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

ensure_managed_block() {
    local src="$1"
    local dst="$2"
    local block_name="$3"
    local label="$4"
    local start_marker="<!-- ${block_name}:START -->"
    local end_marker="<!-- ${block_name}:END -->"

    [[ -f "$src" ]] || return 0

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] merge $src into $dst as $block_name block"
        return 0
    fi

    mkdir -p "$(dirname "$dst")"

    if symlink_points_to "$dst" "$src"; then
        rm -f "$dst"
    fi

    MANAGED_BLOCK_SRC="$src" \
    MANAGED_BLOCK_DST="$dst" \
    MANAGED_BLOCK_NAME="$block_name" \
    MANAGED_BLOCK_START="$start_marker" \
    MANAGED_BLOCK_END="$end_marker" \
    python3 - <<'PYEOF'
import hashlib
import os
import re
import sys
from pathlib import Path

src = Path(os.environ['MANAGED_BLOCK_SRC'])
dst = Path(os.environ['MANAGED_BLOCK_DST'])
name = os.environ['MANAGED_BLOCK_NAME']
start = os.environ['MANAGED_BLOCK_START']
end = os.environ['MANAGED_BLOCK_END']
start_re = rf'<!--\s*{re.escape(name)}:START\s*-->'
end_re = rf'<!--\s*{re.escape(name)}:END\s*-->'

raw_source = src.read_text(encoding='utf-8').strip()
inner_pattern = re.compile(rf'(?ms)^\s*{start_re}\s*\n(.*?)\n{end_re}\s*$')
match = inner_pattern.match(raw_source)
inner = match.group(1).strip() if match else raw_source
inner = re.sub(r'^<!-- hash:[0-9a-f]+ -->\s*\n', '', inner, count=1).strip()
digest = hashlib.sha256(inner.encode('utf-8')).hexdigest()[:16]
source = f'{start}\n<!-- hash:{digest} -->\n{inner}\n{end}'

existing = dst.read_text(encoding='utf-8') if dst.exists() else ''
block_pattern = re.compile(rf'(?ms)^\s*{start_re}\s*\n(.*?)\n{end_re}\s*')
block_match = block_pattern.search(existing)
if block_match:
    current_hash = re.search(r'<!-- hash:([0-9a-f]+) -->', block_match.group(1))
    if current_hash and current_hash.group(1) == digest:
        sys.exit(0)
    merged = block_pattern.sub(source, existing, count=1).strip() + '\n'
elif existing.strip():
    merged = existing.rstrip() + '\n\n' + source + '\n'
else:
    merged = source + '\n'

dst.write_text(merged, encoding='utf-8')
PYEOF

    log "$label 已合并"
}

ensure_symlink() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if symlink_points_to "$dst" "$src"; then
        pass "$label 已就绪"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        if [[ -d "$dst" && ! -L "$dst" && "$FORCE" != true ]]; then
            info "[DRY-RUN] would fail: $label 目标是已有目录，需 --force 才能替换 ($dst)"
        elif [[ -e "$dst" || -L "$dst" ]]; then
            info "[DRY-RUN] replace $dst with symlink to $src"
        else
            info "[DRY-RUN] ln -s $src -> $dst"
        fi
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    if [[ -L "$dst" || -f "$dst" ]]; then
        rm -f "$dst"
    elif [[ -d "$dst" ]]; then
        if [[ "$FORCE" != true ]]; then
            err "$label 目标已存在且是目录: $dst。为避免删除用户维护内容，请先手动处理或使用 --force。"
            return 1
        fi
        rm -rf "$dst"
    elif [[ -e "$dst" ]]; then
        err "$label 目标已存在且类型不受支持: $dst"
        return 1
    fi
    ln -s "$src" "$dst"
    log "$label 已更新"
}

run_installer() {
    local name="$1"
    local script="$SCRIPT_DIR/install-${name}.sh"
    shift || true

    if [[ ! -f "$script" ]]; then
        err "安装脚本不存在: $script"
        return 1
    fi

    info "--- ${name} [${ACTION}] ---"
    ACTION="$ACTION" bash "$script" "$REPO_ROOT" "$DRY_RUN" "$FORCE" "$@"
}

render_settings_template() {
    local tmpl="$1"
    local content
    content="$(cat "$tmpl")"

    local claude_base_url="${CLAUDE_BASE_URL:-${ANTHROPIC_BASE_URL:-}}"
    local claude_api_key="${CLAUDE_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
    local claude_model="${CLAUDE_MODEL:-${ANTHROPIC_MODEL:-}}"
    local claude_haiku_model="${CLAUDE_HAIKU_MODEL:-${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}}"
    local claude_sonnet_model="${CLAUDE_SONNET_MODEL:-${ANTHROPIC_DEFAULT_SONNET_MODEL:-}}"
    local claude_opus_model="${CLAUDE_OPUS_MODEL:-${ANTHROPIC_DEFAULT_OPUS_MODEL:-}}"

    content="${content//"{{CLAUDE_BASE_URL}}"/$claude_base_url}"
    content="${content//"{{CLAUDE_API_KEY}}"/$claude_api_key}"
    content="${content//"{{CLAUDE_MODEL}}"/$claude_model}"
    content="${content//"{{CLAUDE_HAIKU_MODEL}}"/$claude_haiku_model}"
    content="${content//"{{CLAUDE_SONNET_MODEL}}"/$claude_sonnet_model}"
    content="${content//"{{CLAUDE_OPUS_MODEL}}"/$claude_opus_model}"
    content="${content//"{{REPO_ROOT}}"/$REPO_ROOT}"
    printf '%s\n' "$content"
}

merge_settings_json() {
    local target="$1"
    local rendered_template="$2"

    TARGET_SETTINGS_PATH="$target" RENDERED_TEMPLATE_JSON="$rendered_template" python3 - <<'PYEOF'
import json
import os

PLAYWRIGHT_PLUGIN = 'playwright@claude-plugins-official'
LEGACY_PLUGIN_KEYS = {
    'obra/superpowers@superpowers': 'superpowers@superpowers',
    'ecc@ecc': 'affaan-m/everything-claude-code@ecc',
}
OPT_IN_PLUGIN_KEYS = {
    'affaan-m/everything-claude-code@ecc',
}


def merge_object(dst, src, skip_empty=False, prefer_existing=False):
    base = dict(dst) if isinstance(dst, dict) else {}
    if isinstance(src, dict):
        for key, value in src.items():
            if skip_empty and value == '':
                continue
            if prefer_existing and key in base:
                continue
            base[key] = value
    return base


def merge_list(existing, template):
    existing_list = existing if isinstance(existing, list) else []
    template_list = template if isinstance(template, list) else []
    merged = list(existing_list)
    seen = {json.dumps(item, sort_keys=True, ensure_ascii=False) for item in existing_list}
    for item in template_list:
        key = json.dumps(item, sort_keys=True, ensure_ascii=False)
        if key not in seen:
            merged.append(item)
            seen.add(key)
    return merged


def merge_permissions(existing, template):
    merged = merge_object(existing, template, prefer_existing=True)
    if isinstance(template, dict):
        for key, value in template.items():
            if isinstance(value, list):
                merged[key] = merge_list(merged.get(key), value)
    return merged


def migrate_default_disabled_plugins(current, template):
    enabled = dict(current.get('enabledPlugins') or {})
    template_enabled = template.get('enabledPlugins') if isinstance(template.get('enabledPlugins'), dict) else {}

    for legacy_key, canonical_key in LEGACY_PLUGIN_KEYS.items():
        if legacy_key in enabled:
            if enabled.get(legacy_key) is True and canonical_key not in enabled:
                enabled[canonical_key] = True
            enabled.pop(legacy_key, None)

    for opt_in_key in OPT_IN_PLUGIN_KEYS:
        if opt_in_key not in template_enabled:
            enabled.pop(opt_in_key, None)

    if PLAYWRIGHT_PLUGIN not in template_enabled:
        enabled.pop(PLAYWRIGHT_PLUGIN, None)

    return enabled


path = os.environ['TARGET_SETTINGS_PATH']
rendered_template = os.environ['RENDERED_TEMPLATE_JSON']
with open(path, 'r', encoding='utf-8') as fh:
    current = json.load(fh)
template = json.loads(rendered_template)

current['env'] = merge_object(current.get('env'), template.get('env'), skip_empty=True, prefer_existing=True)
current['enabledPlugins'] = merge_object(current.get('enabledPlugins'), template.get('enabledPlugins'), prefer_existing=True)
current['enabledPlugins'] = migrate_default_disabled_plugins(current, template)
current['extraKnownMarketplaces'] = merge_object(current.get('extraKnownMarketplaces'), template.get('extraKnownMarketplaces'), prefer_existing=True)

hooks = current.get('hooks') if isinstance(current.get('hooks'), dict) else {}
template_hooks = template.get('hooks') if isinstance(template.get('hooks'), dict) else {}
for hook_name, template_items in template_hooks.items():
    hooks[hook_name] = merge_list(hooks.get(hook_name), template_items)
current['hooks'] = hooks

if 'permissions' in template:
    current['permissions'] = merge_permissions(current.get('permissions'), template.get('permissions'))

if 'disabledMcpServers' in template:
    current['disabledMcpServers'] = merge_list(current.get('disabledMcpServers'), template.get('disabledMcpServers'))

for key in ['think', 'skipDangerousModePermissionPrompt', 'attribution', 'statusLine', 'language', 'effortLevel']:
    if key in template and key not in current:
        current[key] = template[key]

with open(path, 'w', encoding='utf-8') as fh:
    json.dump(current, fh, indent=4, ensure_ascii=False)
    fh.write('\n')
PYEOF
}

ensure_claude_code() {
    local claude_bootstrap=false

    if [[ "$NO_CLAUDE" == true ]]; then
        info "跳过 Claude Code 安装 (--no-claude)"
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        info "安装 Claude Code..."
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] npm install -g @anthropic-ai/claude-code"
            return 0
        fi
        npm install -g @anthropic-ai/claude-code
        log "Claude Code 安装完成"
        claude </dev/null >/dev/null 2>&1 &
        info "Claude Code 已在后台启动 (PID $!)"
        return 0
    fi

    log "Claude Code 已安装: $(claude --version 2>&1 | head -1)"
    if [[ ! -d "$CLAUDE_HOME" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] 后台启动 Claude Code 初始化 CLAUDE_HOME"
            return 0
        fi
        claude </dev/null >/dev/null 2>&1 &
        info "CLAUDE_HOME 未初始化，已后台启动 Claude Code (PID $!)"
        claude_bootstrap=true
    fi

    [[ "$claude_bootstrap" == false ]] && pass "Claude Code 已就绪"
}

normalize_git_url() {
    local url="$1"
    url="${url#git+}"
    url="${url%.git}"
    url="${url%/}"
    printf '%s' "$url"
}

remote_urls_compatible() {
    local configured="$1"
    local existing="$2"
    [[ "$(normalize_git_url "$configured")" == "$(normalize_git_url "$existing")" ]]
}

safe_external_target() {
    local target="$1"
    [[ "$target" == "$EXTERNAL_DIR"/* ]] || return 1
    [[ "$target" != "$EXTERNAL_DIR" ]]
}

list_third_party_sources() {
    KNOWN_MARKETPLACES_CONFIG="$KNOWN_MARKETPLACES_CONFIG" \
    REPO_ROOT="$REPO_ROOT" \
    EXTERNAL_DIR="$EXTERNAL_DIR" \
    python3 - <<'PYEOF'
import json
import os
import sys
from pathlib import Path

config_path = Path(os.environ['KNOWN_MARKETPLACES_CONFIG'])
repo_root = Path(os.environ['REPO_ROOT']).resolve()
external_dir = Path(os.environ['EXTERNAL_DIR']).resolve()

if not config_path.is_file():
    print(f"known marketplaces config not found: {config_path}", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(config_path.read_text(encoding='utf-8'))
except json.JSONDecodeError as exc:
    print(f"invalid JSON in {config_path}: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print(f"invalid {config_path}: top-level value must be an object", file=sys.stderr)
    sys.exit(1)

for name, entry in data.items():
    if not isinstance(name, str) or not name:
        print(f"invalid {config_path}: marketplace names must be non-empty strings", file=sys.stderr)
        sys.exit(1)
    if not isinstance(entry, dict):
        print(f"invalid {config_path}: entry {name!r} must be an object", file=sys.stderr)
        sys.exit(1)

    source = entry.get('source')
    if not isinstance(source, dict):
        print(f"invalid {config_path}: entry {name!r} missing source object", file=sys.stderr)
        sys.exit(1)

    source_kind = source.get('source')
    if source_kind == 'github':
        source_ref = source.get('repo')
        if not isinstance(source_ref, str) or '/' not in source_ref or source_ref.count('/') != 1:
            print(f"invalid {config_path}: entry {name!r} github source requires repo like owner/name", file=sys.stderr)
            sys.exit(1)
        clone_url = f"https://github.com/{source_ref}.git"
    elif source_kind == 'git':
        source_ref = source.get('url')
        if not isinstance(source_ref, str) or not source_ref:
            print(f"invalid {config_path}: entry {name!r} git source requires url", file=sys.stderr)
            sys.exit(1)
        clone_url = source_ref
    else:
        print(f"invalid {config_path}: entry {name!r} has unsupported source.source {source_kind!r}", file=sys.stderr)
        sys.exit(1)

    install_location = entry.get('installLocation')
    if not isinstance(install_location, str) or not install_location:
        print(f"invalid {config_path}: entry {name!r} requires installLocation", file=sys.stderr)
        sys.exit(1)

    if install_location.startswith('REPO_ROOT/'):
        resolved = (repo_root / install_location[len('REPO_ROOT/'):]).resolve()
    elif install_location == 'REPO_ROOT':
        print(f"invalid {config_path}: entry {name!r} installLocation must be under REPO_ROOT/external", file=sys.stderr)
        sys.exit(1)
    elif os.path.isabs(install_location):
        resolved = Path(install_location).resolve()
        try:
            resolved.relative_to(repo_root)
        except ValueError:
            print(f"invalid {config_path}: entry {name!r} absolute installLocation is outside repo root", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"invalid {config_path}: entry {name!r} installLocation must use REPO_ROOT/... or a repo-local absolute path", file=sys.stderr)
        sys.exit(1)

    try:
        resolved.relative_to(external_dir)
    except ValueError:
        print(f"invalid {config_path}: entry {name!r} installLocation must resolve under {external_dir}", file=sys.stderr)
        sys.exit(1)
    if resolved == external_dir:
        print(f"invalid {config_path}: entry {name!r} installLocation must be a child of {external_dir}", file=sys.stderr)
        sys.exit(1)

    print('\t'.join([name, source_kind, source_ref, clone_url, str(resolved)]))
PYEOF
}

remove_and_clone_third_party_source() {
    local name="$1"
    local clone_url="$2"
    local target="$3"
    local reason="$4"

    if ! safe_external_target "$target"; then
        err "拒绝删除不安全路径: $target"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] remove $target ($reason)"
        info "[DRY-RUN] git clone --depth=1 $clone_url $target"
        return 0
    fi

    rm -rf "$target"
    git clone --depth=1 "$clone_url" "$target"
    log "第三方 source 已重新克隆: $name"
}

refresh_existing_third_party_source() {
    local name="$1"
    local clone_url="$2"
    local target="$3"
    local origin_url branch remote_branch

    origin_url="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
    if [[ -z "$origin_url" ]]; then
        if [[ "$FORCE" == true ]]; then
            remove_and_clone_third_party_source "$name" "$clone_url" "$target" "missing origin remote"
            return $?
        fi
        err "第三方 source 缺少 origin remote: $name ($target)。使用 --force 可删除并重新 clone。"
        return 1
    fi

    if ! remote_urls_compatible "$clone_url" "$origin_url"; then
        if [[ "$FORCE" == true ]]; then
            remove_and_clone_third_party_source "$name" "$clone_url" "$target" "origin remote mismatch: $origin_url"
            return $?
        fi
        err "第三方 source origin 不匹配: $name ($target)。配置: $clone_url，当前: $origin_url。使用 --force 可删除并重新 clone。"
        return 1
    fi

    if ! git -C "$target" diff --quiet -- || ! git -C "$target" diff --cached --quiet -- || [[ -n "$(git -C "$target" ls-files --others --exclude-standard)" ]]; then
        if [[ "$FORCE" == true ]]; then
            remove_and_clone_third_party_source "$name" "$clone_url" "$target" "dirty checkout"
            return $?
        fi
        err "第三方 source 有本地修改: $name ($target)。请先提交/清理，或使用 --force 删除并重新 clone。"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] refresh shallow checkout $name at $target from $clone_url"
        info "[DRY-RUN] git -C $target fetch --depth=1 origin"
        info "[DRY-RUN] checkout origin default branch or current upstream branch, then reset --hard"
        return 0
    fi

    git -C "$target" fetch --depth=1 origin
    remote_branch="$(git -C "$target" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
    branch="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ -n "$branch" && "$branch" != HEAD ]] && git -C "$target" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        remote_branch="$branch"
    fi
    if [[ -n "$remote_branch" ]] && git -C "$target" show-ref --verify --quiet "refs/remotes/origin/$remote_branch"; then
        git -C "$target" checkout -B "$remote_branch" "origin/$remote_branch"
        git -C "$target" reset --hard "origin/$remote_branch"
    else
        git -C "$target" checkout --detach FETCH_HEAD
        git -C "$target" reset --hard FETCH_HEAD
    fi
    log "第三方 source 已刷新: $name"
}

sync_third_party_source() {
    local name="$1"
    local source_kind="$2"
    local source_ref="$3"
    local clone_url="$4"
    local target="$5"

    if ! safe_external_target "$target"; then
        err "第三方 source 路径不安全: $name ($target)"
        return 1
    fi

    if [[ ! -e "$target" && ! -L "$target" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] git clone --depth=1 $clone_url $target ($name from $source_kind:$source_ref)"
            return 0
        fi
        git clone --depth=1 "$clone_url" "$target"
        log "第三方 source 已克隆: $name"
        return 0
    fi

    if [[ ! -d "$target/.git" && ! -f "$target/.git" ]]; then
        if [[ "$FORCE" == true ]]; then
            remove_and_clone_third_party_source "$name" "$clone_url" "$target" "non-git destination"
            return $?
        fi
        err "第三方 source 目标已存在但不是 git checkout: $name ($target)。使用 --force 可删除并重新 clone。"
        return 1
    fi

    refresh_existing_third_party_source "$name" "$clone_url" "$target"
}

should_sync_marketplace_source() {
    local name="$1"
    if [[ "$name" == "ecc" ]] && ! ecc_requested; then
        return 1
    fi
    return 0
}

ensure_third_party_sources() {
    info "读取 marketplace source 配置: $KNOWN_MARKETPLACES_CONFIG"
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] mkdir -p $EXTERNAL_DIR"
    else
        mkdir -p "$EXTERNAL_DIR"
    fi

    local sources name source_kind source_ref clone_url target
    if ! sources="$(list_third_party_sources)"; then
        return 1
    fi

    while IFS=$'\t' read -r name source_kind source_ref clone_url target; do
        [[ -n "$name" ]] || continue
        if ! should_sync_marketplace_source "$name"; then
            info "未显式请求 ECC，跳过第三方 source: $name"
            continue
        fi
        info "准备第三方 source: $name -> $target"
        sync_third_party_source "$name" "$source_kind" "$source_ref" "$clone_url" "$target"
    done <<< "$sources"

    log "配置中的第三方仓库已准备为最新 shallow checkout"
}

update_repository() {
    if [[ "$SETUP_UPDATE_REEXECED" == true ]]; then
        pass "仓库更新阶段已完成"
        return 0
    fi

    info "更新当前仓库与配置中的第三方仓库..."
    if [[ "$UPDATE_THIRD_PARTY_REMOTE" == true ]]; then
        info "兼容标志 --update-third-party 已启用：第三方仓库会刷新到最新 shallow checkout"
    fi
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] git pull --ff-only"
        ensure_third_party_sources
        info "[DRY-RUN] SETUP_UPDATE_REEXECED=true ./setup.sh ${ORIGINAL_ARGS[*]}"
        return 0
    fi

    (
        cd "$REPO_ROOT"
        git pull --ff-only --depth=1
    )
    ensure_third_party_sources

    export SETUP_UPDATE_REEXECED=true
    log "仓库与配置中的第三方仓库已更新"
    info "重新执行 setup 以加载更新后的脚本..."
    exec "$REPO_ROOT/setup.sh" "${ORIGINAL_ARGS[@]}"
}

ensure_core_config() {
    mkdir -p "$CLAUDE_HOME"

    ensure_symlink "$REPO_ROOT/config/claude/CLAUDE.md.ccfg" "$CLAUDE_HOME/CLAUDE.md" "CLAUDE.md symlink"
    ensure_symlink "$REPO_ROOT/config/claude/itp.md" "$CLAUDE_HOME/itp.md" "itp.md symlink"
    ensure_symlink "$REPO_ROOT/config/claude/haiku-throttle.md" "$CLAUDE_HOME/haiku-throttle.md" "haiku-throttle.md symlink"
    remove_symlink_if_ours "$CLAUDE_HOME/AGENTS.md" "AGENTS.md 旧 symlink" "$REPO_ROOT/config/claude/AGENTS.md"

    for file in RTK.md; do
        local src="$REPO_ROOT/config/claude/$file"
        local dst="$CLAUDE_HOME/$file"
        [[ -f "$src" ]] || continue
        ensure_symlink "$src" "$dst" "$file symlink"
    done

    ensure_symlink "$REPO_ROOT/config/claude/rules" "$CLAUDE_HOME/rules" "rules symlink"
    ensure_symlink "$REPO_ROOT/config/claude/rules-available" "$CLAUDE_HOME/rules-available" "rules-available symlink"
    ensure_symlink "$REPO_ROOT/config/claude/hooks/rules-loader.sh" "$CLAUDE_HOME/hooks/rules-loader.sh" "rules-loader hook"

    local cpo_src="$REPO_ROOT/external/claude-plugins-official"
    local cpo_dst="$CLAUDE_HOME/plugins/marketplaces/claude-plugins-official"
    if [[ -d "$cpo_src" ]]; then
        ensure_symlink "$cpo_src" "$cpo_dst" "claude-plugins-official marketplace"
    fi
}

ensure_settings_json() {
    local template="$REPO_ROOT/config/claude/settings.template.json"
    local target="$CLAUDE_HOME/settings.json"

    if [[ ! -f "$template" ]]; then
        warn "settings.template.json 不存在，跳过"
        return 0
    fi

    local rendered_settings
    rendered_settings="$(render_settings_template "$template")"

    if [[ -f "$target" ]] && [[ "$CI_MODE" != true ]]; then
        info "合并现有 settings.json..."
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] merge settings.json with template-backed migration keys"
            return 0
        fi
        mkdir -p "$CLAUDE_HOME"
        merge_settings_json "$target" "$rendered_settings"
        log "settings.json 已合并"
        return 0
    fi

    info "生成 settings.json..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] write rendered settings.json"
        return 0
    fi

    mkdir -p "$CLAUDE_HOME"
    printf '%s\n' "$rendered_settings" > "$target"
    log "settings.json 已生成"
}

copy_known_marketplaces() {
    local target="$CLAUDE_HOME/plugins/known_marketplaces.json"

    info "同步 known_marketplaces.json..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] copy $KNOWN_MARKETPLACES_CONFIG to $target with REPO_ROOT resolved to $REPO_ROOT"
        return 0
    fi

    mkdir -p "$CLAUDE_HOME/plugins"
    KNOWN_MARKETPLACES_CONFIG="$KNOWN_MARKETPLACES_CONFIG" \
    REPO_ROOT="$REPO_ROOT" \
    python3 - <<'PYEOF' > "$target"
import json
import os
import sys
from pathlib import Path

config_path = Path(os.environ['KNOWN_MARKETPLACES_CONFIG'])
repo_root = os.environ['REPO_ROOT']
with config_path.open('r', encoding='utf-8') as fh:
    data = json.load(fh)

def resolve(value):
    if isinstance(value, str) and value.startswith('REPO_ROOT/'):
        return str(Path(repo_root) / value[len('REPO_ROOT/'):])
    return value

for entry in data.values():
    if isinstance(entry, dict) and 'installLocation' in entry:
        entry['installLocation'] = resolve(entry['installLocation'])

json.dump(data, sys.stdout, indent=4, ensure_ascii=False)
print()
PYEOF
    log "known_marketplaces.json 已同步"
}

verify_repository_cleanliness() {
    if [[ "$NO_VERIFY" == true || "$DRY_RUN" == true ]]; then
        info "跳过仓库洁净验证"
        return 0
    fi

    local failed=0
    local ignored_paths=(
        "package.json"
        "package-lock.json"
        "config/omc/wiki/log.md"
        "config/claude/AGENTS.md"
    )

    local path
    for path in "${ignored_paths[@]}"; do
        if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            err "路径仍被 git 跟踪，不能只依赖 .gitignore: $path"
            failed=1
        elif git -C "$REPO_ROOT" check-ignore -q -- "$path"; then
            pass "已忽略且未跟踪: $path"
        else
            err "缺少忽略规则: $path"
            failed=1
        fi

        if ! git -C "$REPO_ROOT" diff --quiet -- "$path"; then
            err "路径仍产生 tracked diff: $path"
            failed=1
        fi
    done

    local session_log_probe="config/omc/wiki/session-log-setup-smoke.md"
    if git -C "$REPO_ROOT" check-ignore -q -- "$session_log_probe"; then
        pass "已忽略 OMC session-log 模式"
    else
        err "缺少 OMC session-log 忽略规则"
        failed=1
    fi

    if git -C "$REPO_ROOT" ls-files 'config/omc/wiki/session-log-*.md' | grep -q .; then
        err "仍有 OMC session-log 文件被 git 跟踪"
        failed=1
    else
        pass "未跟踪 OMC session-log 文件"
    fi

    [[ $failed -eq 0 ]]
}

verify_core_config() {
    if [[ "$NO_VERIFY" == true || "$DRY_RUN" == true ]]; then
        info "跳过 setup 级验证"
        return 0
    fi

    local failed=0
    if symlink_points_to "$CLAUDE_HOME/CLAUDE.md" "$REPO_ROOT/config/claude/CLAUDE.md.ccfg"; then
        pass "CLAUDE.md symlink"
    else
        err "CLAUDE.md symlink 缺失"
        failed=1
    fi

    if symlink_points_to "$CLAUDE_HOME/itp.md" "$REPO_ROOT/config/claude/itp.md" \
        && symlink_points_to "$CLAUDE_HOME/haiku-throttle.md" "$REPO_ROOT/config/claude/haiku-throttle.md"; then
        pass "ITP/throttle symlink"
    else
        err "ITP/throttle symlink 缺失"
        failed=1
    fi
    
    if symlink_points_to "$CLAUDE_HOME/RTK.md" "$REPO_ROOT/config/claude/RTK.md"; then
        pass "RTK.md symlink"
    else
        err "RTK.md symlink 缺失"
        failed=1
    fi

    local agents_path="$CLAUDE_HOME/AGENTS.md"
    if [[ ! -e "$agents_path" && ! -L "$agents_path" ]]; then
        pass "AGENTS.md 未由核心配置接管"
    elif [[ -L "$agents_path" ]]; then
        local agents_target
        agents_target="$(readlink -f "$agents_path" 2>/dev/null || true)"
        if [[ "$agents_target" == "$REPO_ROOT/config/claude/AGENTS.md" ]]; then
            err "AGENTS.md 不应再链接到仓库内第三方内容"
            failed=1
        else
            warn "AGENTS.md 是外部符号链接，核心 setup 不接管: $agents_path -> $agents_target"
        fi
    elif [[ -f "$agents_path" ]]; then
        info "AGENTS.md 是用户管理文件，核心 setup 不接管: $agents_path"
    else
        warn "AGENTS.md 存在但类型不常见，核心 setup 不接管: $agents_path"
    fi

    if symlink_points_to "$CLAUDE_HOME/rules" "$REPO_ROOT/config/claude/rules"; then
        pass "rules symlink"
    else
        err "rules symlink 缺失"
        failed=1
    fi

    if symlink_points_to "$CLAUDE_HOME/rules-available" "$REPO_ROOT/config/claude/rules-available"; then
        pass "rules-available symlink"
    else
        err "rules-available symlink 缺失"
        failed=1
    fi

    if symlink_points_to "$CLAUDE_HOME/hooks/rules-loader.sh" "$REPO_ROOT/config/claude/hooks/rules-loader.sh"; then
        pass "rules-loader hook"
    else
        err "rules-loader hook 缺失"
        failed=1
    fi

    local cpo_src="$REPO_ROOT/external/claude-plugins-official"
    local cpo_dst="$CLAUDE_HOME/plugins/marketplaces/claude-plugins-official"
    if [[ ! -d "$cpo_src" ]] || symlink_points_to "$cpo_dst" "$cpo_src"; then
        pass "claude-plugins-official marketplace"
    else
        err "claude-plugins-official marketplace 缺失"
        failed=1
    fi

    if [[ -f "$CLAUDE_HOME/settings.json" ]]; then
        pass "settings.json 已存在"
    else
        err "settings.json 不存在"
        failed=1
    fi

    if [[ -f "$CLAUDE_HOME/plugins/known_marketplaces.json" ]]; then
        pass "known_marketplaces.json 已存在"
    else
        err "known_marketplaces.json 不存在"
        failed=1
    fi

    verify_repository_cleanliness || failed=1

    [[ $failed -eq 0 ]]
}

run_context_smoke_test() {
    if ! command -v claude >/dev/null 2>&1; then
        err "Claude -p /context 检查失败: claude 命令不存在"
        return 1
    fi

    local timeout_seconds="${CLAUDE_CONTEXT_TIMEOUT:-180}"
    local tmp
    tmp="$(mktemp)"
    set +e
    timeout "$timeout_seconds" claude -p /context >"$tmp" 2>&1
    local rc=$?
    set -e

    if [[ $rc -eq 124 ]]; then
        err "Claude -p /context 检查超时 (${timeout_seconds}s)"
        rm -f "$tmp"
        return 1
    fi

    if [[ $rc -ne 0 ]]; then
        err "Claude -p /context 检查失败 ($rc)"
        sed -n '1,40p' "$tmp" >&2
        rm -f "$tmp"
        return "$rc"
    fi

    if [[ ! -s "$tmp" ]]; then
        err "Claude -p /context 未输出上下文信息"
        rm -f "$tmp"
        return 1
    fi

    log "Claude -p /context 上下文注入检查通过"
    rm -f "$tmp"
}

run_final_doctor() {
    if [[ "$NO_VERIFY" == true ]]; then
        info "跳过最终 doctor (--no-verify)"
        return 0
    fi

    info "运行 context-mode doctor..."
    local previous_action="$ACTION"
    ACTION="doctor"
    run_installer context-mode "$NO_PATCH"
    ACTION="$previous_action"

    if [[ "$SMOKE_TEST" != true ]]; then
        info "跳过扩展冒烟测试 (--smoke-test 未启用)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] script/check-claude-doctor.sh"
        info "[DRY-RUN] claude -p /context"
        return 0
    fi

    info "运行最终 Claude doctor..."
    if timeout 120 "$REPO_ROOT/script/check-claude-doctor.sh"; then
        log "Claude doctor 通过"
    else
        local rc=$?
        if [[ $rc -eq 124 ]]; then
            err "Claude doctor 超时"
        else
            err "Claude doctor 失败 ($rc)"
        fi
        return 1
    fi

    info "运行 Claude -p /context 上下文注入检查..."
    run_context_smoke_test
    log "安装后冒烟测试通过: Claude doctor + Claude -p /context"
    return 0
}

ecc_requested() {
    [[ "$ECC_FULL" == true || "$ECC_FOCUSED" == true || -n "$ECC_PROFILE" || -n "$ECC_MODULES" || -n "$ECC_SKILLS" ]]
}

set_ecc_mode() {
    ECC_MODE=""
    if [[ "$ECC_FULL" == true ]]; then
        ECC_MODE="full"
    elif [[ "$ECC_FOCUSED" == true ]]; then
        ECC_MODE="focused"
    elif [[ -n "$ECC_PROFILE" ]]; then
        ECC_MODE="profile:$ECC_PROFILE"
    elif [[ -n "$ECC_MODULES" ]]; then
        ECC_MODE="modules:$ECC_MODULES"
    elif [[ -n "$ECC_SKILLS" ]]; then
        ECC_MODE="skills:$ECC_SKILLS"
    fi
}

run_priority_module_actions() {
    run_installer context-mode "$NO_PATCH"
    run_installer omc
    run_installer rtk
    run_installer superpowers
}

run_install_flow() {
    phase "Phase 1: Claude Code"
    ensure_claude_code

    phase "Phase 2: 第三方源码 + 核心配置"
    ensure_third_party_sources
    ensure_core_config
    ensure_settings_json
    copy_known_marketplaces

    if [[ "$UPDATE" == true && "$FORCE" == false ]]; then
        phase "Phase 3: CodeGraph + context-mode + OpenSpec 同步"
        run_installer codegraph true
        run_installer context-mode "$NO_PATCH"
        run_installer openspec
        phase "Phase 5: 最终验证"
        verify_core_config
        run_final_doctor
        return 0
    fi

    phase "Phase 3: 安装器编排"
    set_ecc_mode
    run_installer codegraph "$UPDATE"
    if ecc_requested; then
        run_installer ecc "$ECC_MODE"
    else
        info "未显式请求 ECC，跳过 ECC 安装"
    fi
    run_installer context-mode "$NO_PATCH"
    run_installer openspec

    phase "Phase 4: 后置安装器"
    run_installer omc
    run_installer rtk
    run_installer superpowers
    clean_installed_plugins_json

    phase "Phase 5: 最终验证"
    verify_core_config
    run_final_doctor
}

run_core_flow() {
    phase "Phase 1: Claude Code"
    ensure_claude_code

    phase "Phase 2: 核心配置"
    ensure_core_config
    ensure_settings_json
    copy_known_marketplaces

    phase "Phase 3: 最终验证"
    verify_core_config
}

run_inspection_flow() {
    phase "Phase 1: 核心配置状态"
    verify_core_config

    phase "Phase 2: 生命周期模块状态"
    run_priority_module_actions
}

UNINSTALL=""
ECC_MODE=""

remove_symlink_if_ours() {
    local path="$1"
    local label="$2"
    local expected_src="$3"

    if [[ ! -L "$path" ]]; then
        if [[ -e "$path" ]]; then
            info "跳过非符号链接: $label ($path)"
        fi
        return 0
    fi

    local current_target
    current_target="$(readlink -f "$path" 2>/dev/null || true)"
    if [[ "$current_target" != "$expected_src" ]]; then
        warn "符号链接目标不匹配，跳过: $label ($path -> $current_target, 期望 $expected_src)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] rm $path"
        return 0
    fi

    rm -f "$path"
    log "已移除: $label"
}

remove_managed_block() {
    local path="$1"
    local block_name="$2"
    local label="$3"
    local start_marker="<!-- ${block_name}:START -->"
    local end_marker="<!-- ${block_name}:END -->"

    local start_pattern="<!--[[:space:]]*${block_name}:START[[:space:]]*-->"

    [[ -f "$path" ]] || return 0
    if ! grep -Eq "$start_pattern" "$path" 2>/dev/null; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] remove $block_name block from $path"
        return 0
    fi

    MANAGED_BLOCK_PATH="$path" \
    MANAGED_BLOCK_NAME="$block_name" \
    MANAGED_BLOCK_START="$start_marker" \
    MANAGED_BLOCK_END="$end_marker" \
    python3 - <<'PYEOF'
import os
import re
from pathlib import Path

path = Path(os.environ['MANAGED_BLOCK_PATH'])
name = os.environ['MANAGED_BLOCK_NAME']
content = path.read_text(encoding='utf-8')
start_re = rf'<!--\s*{re.escape(name)}:START\s*-->'
end_re = rf'<!--\s*{re.escape(name)}:END\s*-->'
pattern = re.compile(rf'(?ms)^\s*{start_re}\s*\n.*?\n{end_re}\s*')
updated = pattern.sub('', content, count=1).strip() + '\n'
if updated.strip():
    path.write_text(updated, encoding='utf-8')
else:
    path.unlink()
PYEOF

    log "已移除: $label"
}

uninstall_core() {
    phase "Uninstall: 核心配置"
    local repo="$REPO_ROOT/config/claude"

    remove_symlink_if_ours "$CLAUDE_HOME/CLAUDE.md" "CLAUDE.md symlink" "$repo/CLAUDE.md.ccfg"
    remove_symlink_if_ours "$CLAUDE_HOME/itp.md" "itp.md symlink" "$repo/itp.md"
    remove_symlink_if_ours "$CLAUDE_HOME/haiku-throttle.md" "haiku-throttle.md symlink" "$repo/haiku-throttle.md"

    remove_symlink_if_ours "$CLAUDE_HOME/RTK.md" "RTK.md" "$repo/RTK.md"
    remove_symlink_if_ours "$CLAUDE_HOME/AGENTS.md" "AGENTS.md" "$repo/AGENTS.md"
    remove_symlink_if_ours "$CLAUDE_HOME/rules" "rules/" "$repo/rules"
    remove_symlink_if_ours "$CLAUDE_HOME/rules-available" "rules-available/" "$repo/rules-available"
    remove_symlink_if_ours "$CLAUDE_HOME/hooks/rules-loader.sh" "rules-loader hook" "$repo/hooks/rules-loader.sh"
    # 如果 hooks 目录为空则清理
    if [[ -d "$CLAUDE_HOME/hooks" ]]; then
        rmdir "$CLAUDE_HOME/hooks" 2>/dev/null && info "已清理空 hooks 目录" || true
    fi
}

clean_installed_plugins_json() {
    local target="$CLAUDE_HOME/plugins/installed_plugins.json"
    [[ -f "$target" ]] || return 0
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] 从 installed_plugins.json 移除 ECC 注册"
        return 0
    fi
    python3 - "$target" <<'PYEOF'
import json, sys
plugin_keys = ('ecc@ecc', 'affaan-m/everything-claude-code@ecc')
with open(sys.argv[1], 'r+', encoding='utf-8') as f:
    data = json.load(f)
    plugins = data.get('plugins', {})
    enabled = data.get('enabledPlugins', {})
    for key in plugin_keys:
        plugins.pop(key, None)
        enabled.pop(key, None)
    f.seek(0)
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
    f.truncate()
PYEOF
}

clean_ecc_settings_json() {
    local target="$CLAUDE_HOME/settings.json"
    [[ -f "$target" ]] || return 0
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] 从 settings.json 禁用 ECC plugin"
        return 0
    fi
    python3 - "$target" <<'PYEOF'
import json, sys
plugin_keys = ('ecc@ecc', 'affaan-m/everything-claude-code@ecc')
with open(sys.argv[1], 'r+', encoding='utf-8') as f:
    data = json.load(f)
    enabled = data.get('enabledPlugins', {})
    for key in plugin_keys:
        enabled.pop(key, None)
    f.seek(0)
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write('\n')
    f.truncate()
PYEOF
}

remove_ecc_skill_symlinks() {
    local ecc_dir="$REPO_ROOT/external/everything-claude-code"
    local skills_dir="$CLAUDE_HOME/skills"
    [[ -d "$skills_dir" ]] || return 0

    local skill_path removed=0
    shopt -s nullglob
    for skill_path in "$skills_dir"/*; do
        [[ -L "$skill_path" ]] || continue
        if symlink_points_to "$skill_path" "$ecc_dir/skills/$(basename "$skill_path")"; then
            if [[ "$DRY_RUN" == true ]]; then
                info "[DRY-RUN] rm $skill_path"
            else
                rm -f "$skill_path"
            fi
            removed=$((removed + 1))
        fi
    done
    shopt -u nullglob

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] 预计移除 $removed 个 ECC skills symlink"
    else
        info "已移除 $removed 个 ECC skills symlink"
    fi
}

remove_ecc_skill_tree() {
    local skills_tree="$CLAUDE_HOME/skills/ecc"
    [[ -d "$skills_tree" ]] || return 0

    local skill_count
    skill_count="$(find "$skills_tree" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
    if [[ "$skill_count" -eq 0 ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] rm -rf $skills_tree ($skill_count ECC skills)"
        return 0
    fi

    rm -rf "$skills_tree"
    info "已移除 ECC skills 目录树 ($skill_count skills)"
}

remove_ecc_command_files() {
    local ecc_commands_dir="$REPO_ROOT/external/everything-claude-code/commands"
    local commands_dir="$CLAUDE_HOME/commands"
    [[ -d "$commands_dir" && -d "$ecc_commands_dir" ]] || return 0

    local command_path source_path removed=0
    shopt -s nullglob
    for command_path in "$commands_dir"/*.md; do
        source_path="$ecc_commands_dir/$(basename "$command_path")"
        [[ -f "$source_path" ]] || continue
        if cmp -s "$command_path" "$source_path"; then
            if [[ "$DRY_RUN" == true ]]; then
                info "[DRY-RUN] rm $command_path"
            else
                rm -f "$command_path"
            fi
            removed=$((removed + 1))
        fi
    done
    shopt -u nullglob

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] 预计移除 $removed 个 ECC commands 文件"
    else
        info "已移除 $removed 个 ECC commands 文件"
    fi
}

uninstall_ecc() {
    phase "Uninstall: ECC"
    local ecc_dir="$REPO_ROOT/external/everything-claude-code"
    local ecc_marketplace="$CLAUDE_HOME/plugins/marketplaces/ecc"
    remove_symlink_if_ours "$ecc_marketplace" "ECC marketplace" "$ecc_dir"
    if [[ -d "$ecc_marketplace" && ! -L "$ecc_marketplace" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] rm -rf $ecc_marketplace"
        else
            rm -rf "$ecc_marketplace"
            info "已移除 ECC marketplace 目录"
        fi
    fi
    rm -rf "$CLAUDE_HOME/ecc"
    rm -rf "$CLAUDE_HOME/plugins/cache/ecc"
    remove_ecc_skill_symlinks
    remove_ecc_skill_tree
    remove_ecc_command_files
    clean_ecc_settings_json
    clean_installed_plugins_json
    log "已移除 ECC install-state + plugin cache + marketplace + skills/commands 残留 + settings/installed_plugins 注册"
}

uninstall_all() {
    uninstall_core
    uninstall_ecc
    remove_symlink_if_ours "$CLAUDE_HOME/plugins/marketplaces/claude-plugins-official" "CPO marketplace" "$REPO_ROOT/external/claude-plugins-official"
    rm -f "$CLAUDE_HOME/plugins/known_marketplaces.json"
    log "已移除 known_marketplaces.json"
    phase "Uninstall: 完成"
    info "settings.json 未被移除 (可能包含自定义配置)。如需重置: rm ~/.claude/settings.json"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --ci) CI_MODE=true; shift ;;
        --no-claude) NO_CLAUDE=true; shift ;;
        --no-verify) NO_VERIFY=true; shift ;;
        --force) FORCE=true; shift ;;
        --update) UPDATE=true; shift ;;
        --update-third-party) UPDATE=true; UPDATE_THIRD_PARTY_REMOTE=true; shift ;;
        --no-patch) NO_PATCH=true; shift ;;
        --smoke-test) SMOKE_TEST=true; shift ;;
        --ecc-full) ECC_FULL=true; shift ;;
        --ecc-focused) ECC_FOCUSED=true; shift ;;
        --ecc-profile)
            ECC_PROFILE="${2:-}"
            [[ -n "$ECC_PROFILE" ]] || { err "--ecc-profile 需要 profile 名称"; exit 1; }
            shift 2 ;;
        --ecc-modules)
            ECC_MODULES="${2:-}"
            [[ -n "$ECC_MODULES" ]] || { err "--ecc-modules 需要逗号分隔模块 ID"; exit 1; }
            shift 2 ;;
        --ecc-skills)
            ECC_SKILLS="${2:-}"
            [[ -n "$ECC_SKILLS" ]] || { err "--ecc-skills 需要逗号分隔 skill ID"; exit 1; }
            shift 2 ;;
        --uninstall)
            UNINSTALL="${2:-core}"
            [[ "$UNINSTALL" =~ ^(core|ecc|all)$ ]] || { err "--uninstall 参数无效: $UNINSTALL (有效值: core, ecc, all)"; exit 1; }
            shift 2 ;;
        --uninstall=*)
            UNINSTALL="${1#*=}"
            [[ "$UNINSTALL" =~ ^(core|ecc|all)$ ]] || { err "--uninstall 参数无效: $UNINSTALL (有效值: core, ecc, all)"; exit 1; }
            shift ;;
        -h|--help)
            echo "用法: ./setup.sh [action] [选项]"
            echo "  action          install | update | reinstall | core | uninstall | verify | status | doctor"
            echo "  --ci            CI 模式 (跳过手动提示)"
            echo "  --dry-run       预览，不实际修改"
            echo "  --no-claude     跳过 Claude Code 安装"
            echo "  --no-verify     跳过验证"
            echo "  --force         强制重跑所有步骤 (忽略幂等检测)"
            echo "  --update        兼容旧 flag：等价于 action=update"
            echo "  --update-third-party  兼容别名：刷新配置中的第三方仓库到最新 shallow checkout"
            echo "  --no-patch      跳过 context-mode routing.mjs strict-bash 补丁"
            echo "  环境变量        CTX_INSTALL_MODE=auto|symlink|copy 控制 context-mode 安装方式 (默认 auto: symlink 失败自动 copy)"
            echo "  --smoke-test    运行 Claude doctor 与 claude -p /context 扩展冒烟检查"
            echo "  --ecc-full      安装 ECC full profile"
            echo "  --ecc-focused   安装 4 个基础 ECC 模块（agents/commands/hooks/workflow）"
            echo "  --ecc-profile P 安装 ECC 官方 profile: minimal/core/developer/security/research/full"
            echo "  --ecc-modules M 安装逗号分隔模块 ID"
            echo "  --ecc-skills S 安装逗号分隔 skill ID allowlist"
            echo "  --uninstall [M] 兼容旧卸载模式 (core=核心配置, ecc=含ECC, all=全部)"
            exit 0 ;;
        install|update|reinstall|core|uninstall|verify|status|doctor)
            ACTION="$1"
            ACTION_EXPLICIT=true
            shift ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

if [[ "$UPDATE" == true && "$ACTION_EXPLICIT" == false ]]; then
    ACTION="update"
fi

main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Claude Code Config Migration v3    ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    if [[ -n "$UNINSTALL" ]]; then
        case "$UNINSTALL" in
            core) uninstall_core ;;
            ecc) uninstall_core && uninstall_ecc ;;
            all) uninstall_all ;;
        esac
        echo ""
        log "卸载完成 ($UNINSTALL)"
        [[ "$DRY_RUN" == true ]] && warn "DRY-RUN — 未实际修改文件"
        return 0
    fi

    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN — 不会实际修改文件"
    [[ "$CI_MODE" == true ]] && info "CI 模式"
    [[ "$ACTION" == "update" && "$FORCE" == true ]] && info "Update 模式 — 将更新仓库与配置中的第三方仓库，并强制重跑安装器"
    [[ "$ACTION" == "update" && "$FORCE" == false ]] && info "Update 模式 — 将更新仓库与配置中的第三方仓库；不会重跑第三方安装器"

    if [[ "$ACTION" == "update" ]]; then
        phase "Phase 0: 仓库更新"
        UPDATE=true
        update_repository
    fi

    phase "Phase 0: 环境检测"
    local missing=()
    for dep in git curl tar node npm python3; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && { err "缺少依赖: ${missing[*]}"; exit 1; }
    log "git, curl, tar, node, npm, python3 已就绪"
    info "系统: $(uname -s) / $(uname -m)"

    case "$ACTION" in
        install|update|reinstall)
            run_install_flow
            echo ""
            echo -e "${GREEN}============================================${NC}"
            echo -e "${GREEN}  Claude Code 配置迁移完成!${NC}"
            echo -e "${GREEN}============================================${NC}"
            echo ""
            if [[ "$CI_MODE" == true ]]; then
                log "CI 模式 — 所有配置已自动完成"
            else
                echo "验证: claude --version  |  rtk --version"
                echo "      ls ~/.claude/plugins/marketplaces/"
                echo ""
            fi
            ;;
        core)
            run_core_flow
            echo ""
            echo -e "${GREEN}============================================${NC}"
            echo -e "${GREEN}  Claude Core 配置已同步!${NC}"
            echo -e "${GREEN}============================================${NC}"
            echo ""
            ;;
        verify|status|doctor)
            run_inspection_flow
            ;;
        uninstall)
            uninstall_all
            ;;
        *)
            err "未处理的 action: $ACTION"
            exit 1
            ;;
    esac
}

main "$@"
