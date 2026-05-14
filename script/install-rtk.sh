#!/usr/bin/env bash
# install-rtk.sh — RTK (Rust Token Killer) 安装
# 从 GitHub Releases 下载预编译静态二进制，链接配置文件
set -euo pipefail

install_rtk() {
    local repo_root="${1:?需要 REPO_ROOT}"
    local dry_run="${2:-false}"

    local version="v0.40.0"
    local install_dir="$HOME/.local/bin"
    local cfg_src="$repo_root/config/rtk"
    local cfg_dst="$HOME/.config/rtk"

    # 检查已安装
    if command -v rtk >/dev/null 2>&1; then
        echo "  [OK] RTK 已安装: $(rtk --version 2>&1)"
    else
        echo "  [INFO] 下载 RTK ${version}..."
        if [[ "$dry_run" == true ]]; then
            echo "  [DRY-RUN] 跳过下载"
            return
        fi

        local arch; arch="$(uname -m)"
        local tarball="rtk-${arch}-unknown-linux-gnu.tar.gz"
        [[ "$arch" == "x86_64" ]] && tarball="rtk-x86_64-unknown-linux-musl.tar.gz"

        local url="https://github.com/rtk-ai/rtk/releases/download/${version}/${tarball}"
        local tmpdir; tmpdir="$(mktemp -d)"
        curl --fail -sL "$url" -o "$tmpdir/$tarball" || {
            echo "  [ERR] 下载 RTK 失败: $url"; exit 1
        }
        tar -xzf "$tmpdir/$tarball" -C "$tmpdir"
        mkdir -p "$install_dir"
        local bin; bin="$(find "$tmpdir" -name rtk -type f | head -1)"
        [[ -n "$bin" ]] || { echo "  [ERR] 未找到 rtk 二进制"; exit 1; }
        mv "$bin" "$install_dir/rtk"
        chmod +x "$install_dir/rtk"
        rm -rf "$tmpdir"
        echo "  [OK] RTK 安装完成: $(rtk --version 2>&1)"
    fi

    # 配置文件符号链接
    mkdir -p "$cfg_dst"
    for f in config.toml filters.toml; do
        local src="$cfg_src/$f" dst="$cfg_dst/$f"
        [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sf $src -> $dst"; continue; }
        [[ -L "$dst" ]] || [[ -f "$dst" ]] && rm -f "$dst"
        ln -s "$src" "$dst"
        echo "  [OK] RTK config: $f"
    done
}

install_rtk "$@"
