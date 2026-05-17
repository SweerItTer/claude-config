# Claude Code Configuration

一键迁移 Claude Code 配置到新系统。5 阶段自动化安装：环境检测 → Claude 安装 → Submodules → 插件安装 → 验证。

## 快速开始

先准备认证环境变量。若机器上已经有标准的 `ANTHROPIC_*` 环境变量，`setup.sh` 会自动复用；否则设置仓库约定的 `CLAUDE_*` 变量也可以。

```bash
git clone --recurse-submodules git@github.com:SweerItTer/claude-config.git
cd claude-config
chmod +x setup.sh
./setup.sh
```

setup.sh 是幂等的，可安全重复运行；它会自动串起 submodules、RTK、ECC、context-mode、OMC、superpowers、settings.json 和验证。支持 `--ci`、`--dry-run`、`--no-claude`、`--no-verify`、`--smoke-test`。

## 包含内容

### 核心配置 (仓库内)
- **CLAUDE.md, RTK.md, AGENTS.md** — 主配置入口
- **Rules** — common/web/zh + 14 语言专属 rules (~89 文件)
- **自定义 Agents** — git.md, progress.md, rules.md, validation.md
- **RTK 配置** — config.toml, filters.toml
- **OMC Wiki** — 知识库
- **settings.template.json** — 模板，`{{VAR}}` 占位符由 setup.sh 安装时替换为环境变量

### External Submodules
| Submodule | 仓库 | 用途 |
|-----------|------|------|
| oh-my-claudecode | [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) | 多 Agent 编排 |
| superpowers | [obra/superpowers](https://github.com/obra/superpowers) | 14 个开发 skills + SessionStart hook |
| context-mode | [mksglu/context-mode](https://github.com/mksglu/context-mode) | 上下文窗口管理 |
| everything-claude-code | [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code) | Agents/Skills/Commands |
| claude-plugins-official | [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) | 官方插件市场 |

### 安装脚本 (`script/`)
| 脚本 | 职责 |
|------|------|
| install-rtk.sh | 下载 RTK 预编译二进制 → `~/.local/bin/rtk`，symlink config |
| install-ecc.sh | 官方 `install.sh --profile full --target claude` + 自定义 agents 覆盖 |
| install-context-mode.sh | npm install (含 native better-sqlite3) + marketplace symlink |
| install-superpowers.sh | marketplace symlink + 清理旧版 cp -r 残留 |
| install-openspec.sh | 官方 `npm install -g @fission-ai/openspec@latest` |
| install-omc.sh | npm install + `omc setup --plugin-dir-mode` (hooks, HUD, CLAUDE.md, MCP) + wiki symlink |

### 符号链接关系 (由 setup.sh 建立)

```
~/.claude/agents    → external/everything-claude-code/agents (+ 自定义覆盖)
~/.claude/commands  → external/everything-claude-code/commands
~/.claude/skills/   → ECC skills；OMC/superpowers skills 由 plugin marketplace 发现
~/.claude/rules     → config/claude/rules
~/.claude/CLAUDE.md → config/claude/CLAUDE.md
~/.claude/RTK.md    → config/claude/RTK.md
~/.claude/AGENTS.md → config/claude/AGENTS.md
~/.claude/settings.json ← 从 config/claude/settings.template.json 生成
~/.claude/plugins/marketplaces/{omc,superpowers,context-mode,ecc,claude-plugins-official}
                     → external/ 下对应 submodule
~/.config/rtk/      → config/rtk/ (config.toml, filters.toml)
~/.omc/wiki/        → config/omc/wiki/
```

### 自动安装
- **Claude Code** — `npm install -g @anthropic-ai/claude-code` (已有则跳过)
- **RTK** — 从 GitHub Releases 下载预编译二进制 (无需 Rust 工具链)
- **ECC / OMC / context-mode** — 各自按官方安装入口执行；OpenSpec 使用官方全局 npm 安装
- **OMC setup** — 自动注入 20+ hooks 到 settings.json、合并 CLAUDE.md、注册 MCP 等
- **settings.json** — 从模板生成，env var 替换路径和 API 配置

## 前置依赖

- `git`
- `curl` + `tar`
- `node` >= 18

## setup.sh 完成后

1. 若此前未设置认证变量，补充 `ANTHROPIC_*` 或 `CLAUDE_*` 环境变量后重新运行 `./setup.sh`
2. 启动 `claude` — 插件系统会自动发现 marketplace 并补全缓存

## 更新

```bash
cd ~/claude-config
git pull --recurse-submodules
./setup.sh    # 幂等，会重新收敛整条迁移链路
```

## 验证

```bash
claude --version
rtk --version
ls -la ~/.claude/CLAUDE.md          # 应为符号链接
ls ~/.claude/agents/                # ECC agents + 自定义
ls ~/.claude/skills/                # 100+ skills
ls ~/.claude/commands/              # ECC commands
ls ~/.claude/plugins/marketplaces/  # 5 个 marketplace
grep "OMC:START" ~/.claude/CLAUDE.md  # OMC 已注入
script/check-claude-doctor.sh         # doctor 检查插件迁移状态，不调用模型 API
openspec --version                     # OpenSpec CLI 可用
```
