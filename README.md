# Claude Code Configuration

一键迁移 Claude Code 配置到新系统。克隆即用，幂等收敛。

## 拉取安装

```bash
git clone --recurse-submodules git@github.com:SweerItTer/claude-config.git
chmod +x ./claude-config/setup.sh
./claude-config/setup.sh --ecc-focused --force
```

`setup.sh` 自动检测环境、安装依赖（Claude Code、RTK 等），并串起所有 submodule 插件。幂等，可安全重复运行。

### 前置条件

- `git`
- `curl` + `tar`
- `node` >= 18
- 认证环境变量：`ANTHROPIC_*` 或 `CLAUDE_API_KEY` / `CLAUDE_BASE_URL` / `CLAUDE_CODE_MODEL`

### ECC 安装范围

ECC 使用官方 `install.sh --target claude --modules` 安装（**不注册 marketplace symlink**，避免 228 个 skill 全量注入上下文）。`--ecc-focused` 仅安装 4 个基础模块（不安装 `platform-configs`，避免触发插件缓存全仓库）：

| 模块 | 内容 |
|------|------|
| agents-core | 55 个 sub-agent 定义 |
| commands-core | 72 个 slash command |
| hooks-runtime | 运行时 hook 脚本 |
| workflow-quality | 21 个质量保障 skill |

语言专属模块（C++/Java/TS 等）按需手动安装，见下方「探索更多模块」。

| 命令 | 安装范围 |
|------|---------|
| `./setup.sh --ecc-focused` | 5 个基础模块（推荐） |
| `./setup.sh --ecc-full` | 全量安装（full profile） |
| `./setup.sh --ecc-profile minimal` | 官方 minimal profile |
| `./setup.sh --ecc-profile core` | 官方 core profile |
| `./setup.sh --ecc-profile developer` | 官方 developer profile |
| `./setup.sh --ecc-modules rules-core,agents-core,...` | 指定模块 ID，逗号分隔 |

### 探索更多 ECC 模块

```bash
# 列出所有可用模块
cd ~/claude-config/external/everything-claude-code
node scripts/install-plan.js --list-modules

# 安装额外模块（追加到已有安装）
./install.sh --target claude --modules skill-java-coding-standards,skill-cpp-coding-standards

# 或通过 setup.sh
cd ~/claude-config
./setup.sh --ecc-modules skill-java-coding-standards,skill-cpp-coding-standards
```

### MCP 服务器管理

所有 MCP 服务器配置已安装，但**默认禁用**（通过 `disabledMcpServers`）。仅保留 5 个核心服务器启用：
`context7`, `github`, `memory`, `playwright`, `sequential-thinking`。

在 Claude Code 中通过 `/mcp` 按需开启：

```
/mcp add <server-name>   # 启用指定 MCP 服务器
/mcp list                # 查看当前状态
```

### 其他选项

| 选项 | 作用 |
|------|------|
| `--ci` | CI 模式：跳过交互，ECC 使用 full profile |
| `--dry-run` | 仅打印操作，不执行 |
| `--no-claude` | 跳过 Claude Code CLI 安装 |
| `--no-verify` | 跳过最终验证步骤 |
| `--smoke-test` | 运行快速烟雾测试 |


## 更新

```bash
git -C ~/claude-config pull --recurse-submodules
./setup.sh    # 幂等，重新收敛所有 symlink、插件和配置
```

也可以单独更新某个插件：

```bash
# 更新 ECC
cd ~/claude-config/external/everything-claude-code
git pull
cd ~/claude-config
./script/install-ecc.sh . false false focused

# 更新 OMC
cd ~/claude-config/external/oh-my-claudecode
git pull
cd ~/claude-config
./script/install-omc.sh . false false
```


## 安装完成后验证

```bash
claude --version
rtk --version
ls -la ~/.claude/CLAUDE.md              # 应为符号链接
ls ~/.claude/agents/                    # ECC agents + 自定义覆盖
ls ~/.claude/commands/                  # ECC commands
ls ~/.claude/plugins/marketplaces/      # 4 个 marketplace (不含 ecc)
grep "OMC:START" ~/.claude/CLAUDE.md    # OMC 已注入
script/check-claude-doctor.sh           # doctor 检查插件迁移状态
openspec --version                      # OpenSpec CLI 可用
```


## 包含内容

### 核心配置 (仓库内)

- **CLAUDE.md, RTK.md, AGENTS.md** — 主配置入口
- **Rules** — common/web/zh + 14 语言专属 rules
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
| install-ecc.sh | 使用 ECC 官方 install.sh --modules 安装（无 marketplace symlink），叠加自定义 agents，移动 rules 至 rules-available/ |
| install-context-mode.sh | npm install + marketplace symlink + cache 版本维护 |
| install-superpowers.sh | marketplace symlink + 清理旧版残留 |
| install-openspec.sh | 官方 `npm install -g @fission-ai/openspec@latest` |
| install-omc.sh | npm install + `omc setup` (hooks, HUD, CLAUDE.md, MCP) + wiki symlink |

### 符号链接关系 (由 setup.sh 建立)

```
~/.claude/agents/   ← ECC agents + 自定义覆盖
~/.claude/commands/ ← ECC commands
~/.claude/rules      → config/claude/rules
~/.claude/CLAUDE.md  → config/claude/CLAUDE.md
~/.claude/RTK.md     → config/claude/RTK.md
~/.claude/AGENTS.md  → config/claude/AGENTS.md
~/.claude/settings.json ← 从 config/claude/settings.template.json 生成
~/.claude/plugins/marketplaces/{omc,superpowers,context-mode,claude-plugins-official}
                     → external/ 下对应 submodule
~/.config/rtk/       → config/rtk/ (config.toml, filters.toml)
~/.omc/wiki/         → config/omc/wiki/
```
