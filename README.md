# Claude Code Configuration

一键收敛 Claude Code 配置与插件栈。脚本幂等，可安全重复运行。

## 项目 Skill

- [`skills/installer-authoring/SKILL.md`](skills/installer-authoring/SKILL.md)：新增 Skill、MCP、Hook 或 plugin 安装器时的 `install_*` 编写约定，涵盖声明式配置、依赖 preflight、TUI/engine 分层、非交互运行、ownership、回滚和安全卸载。

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

# 推荐路径：完整安装核心配置与常用插件
./setup.sh --force

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
<!-- - `~/.claude/itp.md` -->
<!-- - `~/.claude/haiku-throttle.md` -->
- `rules/` / `rules-available/`
- `settings.json`（缺失时生成，已存在时按模板补齐缺失项）
- `known_marketplaces.json`

适合先把 Claude 环境搭起来，再按需装插件。

### 完整安装

```bash
./setup.sh --force
```

这条路径会：
- 安装或收敛核心配置
- 执行已配置的常用安装器并完成 setup 级验证，如 `codegraph`、`context-mode`、`openspec`、`omc` 和 `superpowers`
- 同步 `known_marketplaces.json` 声明的第三方 source（包括 `external/ponytail`）；普通 `run_install_flow` 不执行 Ponytail installer，也不会自动启用或验证 `ponytail@ponytail`

Ponytail 目前需单独调用其 installer（在仓库根目录执行）：

```bash
# 安装并注册 Ponytail
./script/install-ponytail.sh "$(pwd)" false true

# 检查 Ponytail 状态与注册结果
ACTION=verify ./script/install-ponytail.sh "$(pwd)" false false
```

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

#### CodeGraph

- `setup.sh` 会安装并验证 CodeGraph
- Linux/macOS 优先使用上游 shell installer；失败时回退到 `npm i -g @colbymchenry/codegraph@latest`
- 常规运行会跳过已可用的 `codegraph`
- setup 默认不会运行 `codegraph init`

## 故障恢复

- **安装后异常**：
  ```bash
  ~/claude-config/setup.sh --force
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
  <!-- itp.md           → config/claude/itp.md -->
  <!-- haiku-throttle.md → config/claude/haiku-throttle.md -->
  rules/           → config/claude/rules/
  rules-available/ → config/claude/rules-available/
  skills/          → config/claude/skills/
  settings.json    ← 从 settings.template.json 渲染并合并
  plugins/
    marketplaces/{omc,superpowers,context-mode,ponytail,claude-plugins-official}
    known_marketplaces.json
```

| Submodule | 来源 | 用途 |
|-----------|------|------|
| oh-my-claudecode | Yeachan-Heo/oh-my-claudecode | 多 Agent 编排 |
| superpowers | obra/superpowers | 开发 skills + SessionStart |
| context-mode | mksglu/context-mode | 上下文压缩 |
| claude-plugins-official | anthropics/claude-plugins-official | 官方插件市场 |
