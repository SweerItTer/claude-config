# Claude Code Configuration

一键迁移 Claude Code 配置到新系统。符号链接 + submodule + 自动化安装。

## 快速开始

```bash
git clone --recurse-submodules git@github.com:SweerItTer/claude-config.git
cd claude-config
chmod +x setup.sh
./setup.sh
```

setup.sh 是幂等的 — 可安全重复运行。

## 包含内容

### 核心配置 (仓库内)
- **CLAUDE.md, RTK.md, AGENTS.md** — 主配置入口
- **Rules** — common/web/zh + 14 语言专属 rules (~89 文件)
- **自定义 Agents** — git.md, progress.md, rules.md, validation.md
- **Superpowers Skills** — 14 个 skills (插件源，纳入仓库)
- **RTK 配置** — config.toml, filters.toml
- **OMC Wiki** — 知识库

### External Submodules
| Submodule | 仓库 | 用途 |
|-----------|------|------|
| oh-my-claudecode | [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) | 多 Agent 编排 |
| context-mode | [mksglu/context-mode](https://github.com/mksglu/context-mode) | 上下文窗口管理 |
| everything-claude-code | [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code) | Agents/Skills/Commands |
| claude-plugins-official | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | 官方插件市场 |

### 符号链接关系 (由 setup.sh 建立)

```
~/.claude/agents    → external/everything-claude-code/agents (+ 自定义覆盖)
~/.claude/commands  → external/everything-claude-code/commands
~/.claude/skills/   → ECC skills (symlink) + OMC (symlink) + superpowers (copy)
~/.claude/rules     → config/claude/rules
~/.claude/CLAUDE.md → config/claude/CLAUDE.md
~/.claude/RTK.md    → config/claude/RTK.md
~/.claude/AGENTS.md → config/claude/AGENTS.md
~/.claude/plugins/marketplaces/{omc,context-mode,everything-claude-code,claude-plugins-official}
                     → external/ 下对应 submodule
```

### 自动安装
- **RTK** — 从 GitHub Releases 下载预编译二进制 (无需 Rust 工具链)
- **ECC 依赖** — `npm install` 在 ECC 目录
- **Marketplace 注册** — known_marketplaces.json

## 前置依赖

- `git`
- `curl` + `tar` (RTK 预编译二进制从此获取)

## setup.sh 完成后

1. 放入 `~/.claude/settings.json`（含 API key，需自行管理）
2. 启动一次 `claude` — 让插件系统发现 marketplace 并完成缓存

## 更新

```bash
cd ~/claude-config
git pull --recurse-submodules
./setup.sh    # 幂等 — 重新链接全部文件
```

## 验证

```bash
claude --version
rtk --version
ls -la ~/.claude/CLAUDE.md          # 应为符号链接
ls ~/.claude/agents/                # ECC agents + 自定义
ls ~/.claude/skills/                # 100+ skills
ls ~/.claude/commands/              # ECC commands
ls ~/.claude/plugins/marketplaces/  # 4 个 marketplace
```
