# Claude Code Configuration

一键迁移 Claude Code 配置到新系统。幂等 — 可安全重复运行。

## 首次安装

**前置条件**: `git` `curl` `tar` `node>=18`，以及认证环境变量（`ANTHROPIC_*` 或 `CLAUDE_API_KEY`）。

```bash
git clone --recurse-submodules git@github.com:SweerItTer/claude-config.git
~/claude-config/setup.sh --ecc-focused --force
```

安装后重启 Claude Code，验证：

```bash
claude --version
rtk --version
ls ~/.claude/plugins/marketplaces/          # 4 个：omc superpowers context-mode claude-plugins-official
grep "OMC:START" ~/.claude/CLAUDE.md        # OMC 已注入
ls ~/.claude/agents/ ~/.claude/commands/    # ECC agents + commands
```

`--force` 强制跳过幂等检测，`--ecc-focused` 安装 4 个基础 ECC 模块（见下方说明）。

## 更新

```bash
git -C ~/claude-config pull --recurse-submodules
~/claude-config/setup.sh                    # 无 --force，仅收敛差异；第三方 submodules 使用仓库 pinned 版本
```

默认更新不会推进第三方 submodule gitlink，避免每次追上游最新都产生主仓库索引变更。需要显式刷新第三方到上游最新时再运行：

```bash
~/claude-config/setup.sh --update --update-third-party
```

`--update-third-party` 可能产生 `external/*` gitlink 变更；确认后应作为一次有意的第三方版本更新提交。若未来需要“第三方永远最新且主仓库零 gitlink 变更”，应迁移到 setup 管理的 ignored vendor cache，而不是 tracked submodules。

## 按需扩展

### 启用 MCP 服务器

所有 MCP 默认禁用（`disabledMcpServers`）。在 Claude Code 内：

```
/mcp add <server-name>    # 启用
/mcp list                 # 查看状态
```

### 添加语言规则

规则位于 `rules-available/`（不会自动加载）。编辑代码前告诉 Claude 加载对应规则，或在对话中手动引用 `rules-available/<lang>/`。

### 增加 ECC 模块

```bash
# 列出可用模块
cd ~/claude-config/external/everything-claude-code && node scripts/install-plan.js --list-modules

# 安装额外模块（追加）
cd ~/claude-config
./setup.sh --ecc-modules skill-java-coding-standards,skill-cpp-coding-standards
```

只安装指定 ECC skill ID：`./setup.sh --ecc-skills <id,id,...>`。

```bash
# 查看可用 skill ID
cd ~/claude-config/external/everything-claude-code && node scripts/install-plan.js --list-components --family skill

# 预览只安装指定 skill
cd ~/claude-config
./setup.sh --dry-run --ecc-skills skill-stocktake
```

ECC 安装范围选项：

| 命令 | 范围 |
|------|------|
| `--ecc-focused` | 4 个基础模块（推荐） |
| `--ecc-full` | full profile |
| `--ecc-profile <name>` | minimal / core / developer / security / research |
| `--ecc-modules <ids>` | 逗号分隔的模块 ID |
| `--ecc-skills <ids>` | 逗号分隔的 ECC skill ID allowlist |

同时传多个范围参数时，setup 按 `--ecc-full` → `--ecc-focused` → `--ecc-profile` → `--ecc-modules` → `--ecc-skills` 选择安装范围。

### CodeGraph

- `setup.sh` 会安装并验证 CodeGraph。
- Linux/macOS 优先使用上游 shell installer；失败时回退到全局 `npm i -g @colbymchenry/codegraph@latest`。
- 若现有 `codegraph --version` 已可用，常规运行会跳过重装；`--update` 或 `--force` 可刷新安装。
- setup 默认不会运行 `codegraph init`，不会在任意仓库创建 `.codegraph/`；仅做轻量可用性校验。

## 故障回退

- **安装后异常**：直接重跑 `~/claude-config/setup.sh --force --ecc-focused`，幂等恢复所有配置。
- **插件 hook 报错**：运行 `/reload-plugins`；仍有问题则 `~/claude-config/setup.sh --force --ecc-focused && /reload-plugins`。
- **配置冲突**：`--smoke-test` 参数会运行 doctor 诊断具体冲突项。
- **版本回退**：`git -C ~/claude-config log --oneline` 查看历史，`git -C ~/claude-config checkout <commit>` 回退后重跑 `setup.sh --force`。

## 卸载

```bash
~/claude-config/setup.sh --uninstall core   # 仅核心配置
~/claude-config/setup.sh --uninstall ecc    # 核心 + ECC
~/claude-config/setup.sh --uninstall all    # 完全卸载（保留 settings.json）
```

`settings.json` 不会被自动删除以保护自定义配置。如需彻底重置：`rm ~/.claude/settings.json`。

## 其他选项

| 选项 | 作用 |
|------|------|
| `--ci` | CI 模式（ECC 用 full profile） |
| `--dry-run` | 预览，不实际修改 |
| `--no-claude` | 跳过 Claude Code CLI 安装 |
| `--smoke-test` | 运行 doctor 诊断 |

## 架构概要

```
~/.claude/
  CLAUDE.md        → config/claude/CLAUDE.md      (OMC 编排 + 规则入口)
  RTK.md           → config/claude/RTK.md         (token 压缩代理)
  rules/           → config/claude/rules/         (基线自动加载：common/)
  rules-available/ → config/claude/rules-available/ (按需规则：python web zh …)
  agents/          ← ECC agents-core + 自定义覆盖
  commands/        ← ECC commands-core
  settings.json    ← 从 settings.template.json 渲染 + 合并
  plugins/
    marketplaces/{omc,superpowers,context-mode,claude-plugins-official}
    known_marketplaces.json
```

| Submodule | 来源 | 用途 |
|-----------|------|------|
| oh-my-claudecode | Yeachan-Heo/oh-my-claudecode | 多 Agent 编排 |
| superpowers | obra/superpowers | 开发 skills + SessionStart |
| context-mode | mksglu/context-mode | 上下文压缩 (≈70% 节省) |
| everything-claude-code | affaan-m/everything-claude-code | Agents/Commands/Hooks |
| claude-plugins-official | anthropics/claude-plugins-official | 官方插件市场 |
