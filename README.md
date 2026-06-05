# Claude Code Configuration

一键收敛 Claude Code 配置与插件栈。脚本幂等，可安全重复运行。

## 快速开始

### 1) 克隆仓库

```bash
git clone --recurse-submodules git@github.com:SweerItTer/claude-config.git
cd ~/claude-config
```

### 2) 选择一种搭建路径

```bash
# 最小路径：只同步核心配置（CLAUDE.md / rules / settings / marketplaces；已存在的 settings.json 会保留并补齐缺失项）
./setup.sh core

# 推荐路径：完整安装 + 4 个基础 ECC 模块
./setup.sh --ecc-focused --force

# 只做检查，不改动已有配置
./setup.sh verify
```

### 3) setup 会先尝试补环境

推荐系统已具备这些命令：`git` `curl` `tar` `node` `npm` `python3`。

如果缺少其中任意一个，`setup.sh` 会先尝试自动补环境：
- `git` / `curl` / `tar` / `python3`：优先走系统包管理器（`apt-get` / `dnf` / `yum` / `brew` / `pacman`）
- `node` / `npm`：改走 Node 官方推荐的脚本方式，先安装 `nvm`，再安装并切换到**最新 LTS** Node.js（自带 npm）；若当前已装的是不兼容的 current 版本，setup 会主动切回 LTS

实在装不上，才会报错并提示你手动补装。

### 4) 安装后验证

```bash
claude --version
rtk --version
./setup.sh verify
ls ~/.claude/plugins/marketplaces/
```

如果你走的是完整安装路径，还可以额外检查：

```bash
grep "OMC:START" ~/.claude/CLAUDE.md
ls ~/.claude/agents/ ~/.claude/commands/
```

## 常用路径

### 最小安装

```bash
./setup.sh core
```

只同步核心配置：
- `~/.claude/CLAUDE.md`
- `~/.claude/itp.md`
- `~/.claude/haiku-throttle.md`
- `~/.claude/RTK.md`
- `rules/` / `rules-available/`
- `settings.json`（缺失时生成，已存在时按模板补齐缺失项）
- `known_marketplaces.json`

适合先把 Claude 环境搭起来，再按需装插件。

### 完整安装

```bash
./setup.sh --ecc-focused --force
```

这条路径会：
- 安装或收敛核心配置
- 安装 `context-mode`、`omc`、`rtk`、`superpowers`
- 显式安装 ECC 的 `focused` 基础模块

说明：ECC 现在是 **显式 opt-in**，不再默认安装。只有传入 `--ecc-*` 参数时才会安装或同步 ECC。

### 日常更新

```bash
git -C ~/claude-config pull --recurse-submodules
~/claude-config/setup.sh
```

默认更新只收敛差异，不会强制刷新第三方到上游最新。若你明确要推进第三方仓库版本：

```bash
~/claude-config/setup.sh --update --update-third-party
```

### 验证 / 状态 / 诊断

```bash
./setup.sh verify
./setup.sh status
./setup.sh doctor
```

- `verify`：检查核心配置是否齐全
- `status`：检查核心配置与模块状态
- `doctor`：走诊断路径，适合排查安装异常

### 按需扩展

#### 启用 MCP 服务器

所有 MCP 默认禁用（`disabledMcpServers`）。在 Claude Code 内：

```text
/mcp add <server-name>
/mcp list
```

#### 添加语言规则

`rules-available/` 中是按需规则，不会自动加载。需要时在对话里明确让 Claude 使用对应规则。

#### 增加 ECC 模块

```bash
# 列出可用模块
cd ~/claude-config/external/everything-claude-code && node scripts/install-plan.js --list-modules

# 安装额外模块（追加）
cd ~/claude-config
./setup.sh --ecc-modules skill-java-coding-standards,skill-cpp-coding-standards
```

只安装指定 ECC skill：

```bash
cd ~/claude-config/external/everything-claude-code && node scripts/install-plan.js --list-components --family skill
cd ~/claude-config
./setup.sh --dry-run --ecc-skills skill-stocktake
```

ECC 范围选项：

| 命令 | 范围 |
|------|------|
| `--ecc-focused` | 4 个基础模块（推荐） |
| `--ecc-full` | full profile |
| `--ecc-profile <name>` | minimal / core / developer / security / research |
| `--ecc-modules <ids>` | 逗号分隔模块 ID |
| `--ecc-skills <ids>` | 逗号分隔 skill ID allowlist |

同时传多个范围参数时，setup 按 `--ecc-full` → `--ecc-focused` → `--ecc-profile` → `--ecc-modules` → `--ecc-skills` 选择安装范围。

#### CodeGraph

- `setup.sh` 会安装并验证 CodeGraph
- Linux/macOS 优先使用上游 shell installer；失败时回退到 `npm i -g @colbymchenry/codegraph@latest`
- 常规运行会跳过已可用的 `codegraph`
- setup 默认不会运行 `codegraph init`

## 故障恢复

- **安装后异常**：
  ```bash
  ~/claude-config/setup.sh --force --ecc-focused
  ```
- **只想检查，不想重装**：
  ```bash
  ~/claude-config/setup.sh verify
  ```
- **需要更深的检查**：
  ```bash
  ~/claude-config/setup.sh --smoke-test
  ```
- **插件 hook 报错**：先 `/reload-plugins`，仍有问题再重跑 setup
- **自动补环境失败**：按 setup 输出的提示补装；其中 `node` / `npm` 建议继续走 Node 官方推荐脚本路径（`nvm` + 最新 LTS Node.js）
- **版本回退**：
  ```bash
  git -C ~/claude-config log --oneline
  git -C ~/claude-config checkout <commit>
  ~/claude-config/setup.sh --force
  ```

## 卸载

```bash
~/claude-config/setup.sh --uninstall core
~/claude-config/setup.sh --uninstall ecc
~/claude-config/setup.sh --uninstall all
```

`settings.json` 默认保留，避免误删你的自定义配置。若你要彻底重置：

```bash
rm ~/.claude/settings.json
```

## 常用选项

| 选项 | 作用 |
|------|------|
| `--force` | 强制重跑安装流程 |
| `--dry-run` | 预览，不实际修改 |
| `--no-claude` | 跳过 Claude Code CLI 安装 |
| `--smoke-test` | 运行 doctor 与上下文注入检查 |
| `--update` | 执行更新流程 |
| `--update-third-party` | 刷新第三方仓库到上游最新 |
| `--ci` | CI 模式 |

## 架构概要

```text
~/.claude/
  CLAUDE.md        → config/claude/CLAUDE.md.ccfg（或由 OMC 注入后的宿主文件）
  itp.md           → config/claude/itp.md
  haiku-throttle.md → config/claude/haiku-throttle.md
  RTK.md           → config/claude/RTK.md
  rules/           → config/claude/rules/
  rules-available/ → config/claude/rules-available/
  skills/          → config/claude/skills/
  agents/          ← ECC agents-core + 自定义覆盖
  commands/        ← ECC commands-core
  settings.json    ← 从 settings.template.json 渲染并合并
  plugins/
    marketplaces/{omc,superpowers,context-mode,claude-plugins-official}
    known_marketplaces.json
```

| Submodule | 来源 | 用途 |
|-----------|------|------|
| oh-my-claudecode | Yeachan-Heo/oh-my-claudecode | 多 Agent 编排 |
| superpowers | obra/superpowers | 开发 skills + SessionStart |
| context-mode | mksglu/context-mode | 上下文压缩 |
| everything-claude-code | affaan-m/everything-claude-code | Agents / Commands / Hooks |
| claude-plugins-official | anthropics/claude-plugins-official | 官方插件市场 |
