# Claude Code Configuration

一键迁移 Claude Code 配置到新系统。

## 快速开始

```bash
git clone --recurse-submodules git@github.com:mouj-WebDev/claude-config.git
cd claude-config
chmod +x setup.sh
./setup.sh
```

## 包含内容

- **Claude Code 主配置** — CLAUDE.md, RTK.md, AGENTS.md
- **Agent 定义** — ~55 个 sub-agent 入口文件
- **Rules** — common/web/zh + 语言专属 rules (~89 个文件)
- **外部仓库** (git submodule):
  - [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) — 多 Agent 编排
  - [context-mode](https://github.com/mksglu/context-mode) — 上下文窗口管理
  - [everything-claude-code](https://github.com/affaan-m/everything-claude-code) — ECC 工具集
  - [claude-plugins-official](https://github.com/anthropics/claude-plugins-official) — 官方插件市场
- **RTK** — Rust Token Killer 配置
- **OMC Wiki** — 知识库

## 前置依赖

- `git`
- `cargo` (用于安装 RTK)
- `claude` CLI

## 手动步骤

`setup.sh` 完成后，还需:

1. 将 `settings.json` 放入 `~/.claude/`（含 API key，需自行管理）
2. 启动一次 `claude` 让插件系统完成缓存安装

## 验证

```bash
claude --version
rtk --version
ls -la ~/.claude/CLAUDE.md    # 应为符号链接
ls ~/.claude/plugins/marketplaces/  # 应有 4 个 marketplace
```

## 更新

```bash
cd ~/claude-config
git pull --recurse-submodules
./setup.sh    # 重新链接（幂等）
```
