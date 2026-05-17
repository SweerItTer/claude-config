#!/usr/bin/env bash
# install-openspec.sh — OpenSpec CLI 安装
# 使用 OpenSpec README 官方方法: npm install -g @fission-ai/openspec@latest
set -euo pipefail

install_openspec() {
    local repo_root="${1:?需要 REPO_ROOT}"
    local dry_run="${2:-false}"

    if openspec --version >/dev/null 2>&1; then
        echo "  [OK] OpenSpec 已安装: $(openspec --version 2>&1 | head -1)"
        return 0
    fi

    echo "  [INFO] 按官方方式安装 OpenSpec..."
    if [[ "$dry_run" == true ]]; then
        echo "  [DRY-RUN] npm install -g @fission-ai/openspec@latest"
        return 0
    fi

    npm install -g @fission-ai/openspec@latest
    echo "  [OK] OpenSpec 安装完成: $(openspec --version 2>&1 | head -1)"
}

install_openspec "$@"
