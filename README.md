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
# 最小路径：只同步核心配置（CLAUDE.md / rules / settings；已存在的 settings.json 会保留并补齐缺失项）
./setup.sh core

# 推荐路径：完整安装核心配置、外部 skills 与第三方 plugins
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
- `rules/` / `rules-available/`
- `settings.json`（缺失时生成，已存在时按模板补齐缺失项）

适合先把 Claude 环境搭起来，再按需装插件。

### 完整安装

```bash
./setup.sh --force
```

这条路径会：
- 安装或收敛核心配置
- 安装 `configs/skills.toml` 声明的外部 skills（用 `npx skills add` 装到 `~/.claude/skills/`）
- 安装 `configs/plugins.toml` 声明的第三方 plugins（用 `claude plugin marketplace add` + `claude plugin install`）

### 日常更新

```bash
git -C ~/claude-config pull --ff-only
~/claude-config/setup.sh
```

默认更新只收敛差异。若要推进外部 skills 与 plugins 到上游最新：

```bash
~/claude-config/setup.sh --update-all
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

#### 只装某个 skill / plugin

```bash
./setup.sh --skill tmux-session-manager
./setup.sh --plugin context-mode
```

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
# 卸载单个目标（skill 或 plugin，用清单中的名字）
~/claude-config/setup.sh --uninstall context-mode

# 卸载多个目标（有界并发，默认同时 3 个）
~/claude-config/setup.sh --uninstall context-mode --uninstall superpowers

# 卸载全部
~/claude-config/setup.sh --uninstall all
```

> 卸载只移除 `~/.claude/skills/` 下由 `npx skills` 安装的副本，不触碰本仓库源文件。

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
| `--no-verify` | 跳过验证 |
| `--smoke-test` | 运行 doctor 与上下文注入检查 |
| `--update` | 兼容旧 flag：等价于 `action=update` |
| `--update-all` | 更新全部外部 skills + plugins |
| `--update-skill <name>` | 更新指定 skill（`core` = 全部） |
| `--skill <name>` | 只安装指定外部 skill |
| `--plugin <name>` | 只安装指定第三方 plugin |
| `--uninstall <target>` | 卸载（可重复出现，列表并发） |
| `--ci` | CI 模式 |

## 清单配置

外部 skills 与 plugins 声明在 `configs/` 下，用 Python `parse-manifests.py` 解析（纯标准库，Python 3.10 无 tomllib 时自动回退）：

```text
configs/skills.toml    → 每个 [[sources]] 声明一个外部 skill 源
configs/plugins.toml   → 每个 [[plugins]] 声明一个第三方 plugin
```

- `skills.toml`：`npx -y skills@latest add <repo> -s <skill> -a claude-code -g`
- `plugins.toml`：`method = "claude-plugin"` → `claude plugin marketplace add + install`；`method = "npx"` → 手动安装，仅备注命令
  - 官方市场（anthropics/claude-plugins-official）需**为每个 plugin 单独声明 `[[plugins]]` 条目**（如 skill-creator、code-review），只声明 marketplace 不会安装任何 plugin；marketplace add 由各条目在 install 前幂等执行

测试：`bash script/test-manifest-parsing.sh`

## 架构概要

```text
~/.claude/
  CLAUDE.md        → claude/CLAUDE.md.ccfg（或由 OMC 注入后的宿主文件）
  rules/           → claude/rules/
  rules-available/ → claude/rules-available/
  skills/          → 自有 skill 由 npx skills 安装，外部 skill 也装到这里
  settings.json    ← 从 claude/settings.template.json 渲染并合并
  plugins/
    marketplaces/{omc,superpowers,context-mode,ponytail,claude-plugins-official}
```

外部 skills 与 plugins 的来源声明在 `configs/`（见上文清单配置），不由仓库直接管理。
