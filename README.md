# Claude Code Configuration

一键收敛 Claude Code 配置与插件栈。入口是顶层 `./launch`（Python CLI），幂等，可安全重复运行。

## 快速开始

### 1) 克隆仓库

```bash
git clone --recurse-submodules git@github.com:SweerItTer/claude-config.git
cd ~/claude-config
```

### 2) 选择一种安装路径

```bash
# 最小路径：只同步核心配置（CLAUDE.md / rules / settings；已存在的 settings.json 会保留并补齐缺失项）
./launch core

# 推荐路径：完整安装 Claude Code、核心配置、外部 skills 与第三方 plugins
./launch install

# 只读列出已安装 skills（~/.claude 与 ~/.agents 两组，==== 分隔）
./launch list

# 检测核心配置 + Claude Code CLI（版本/doctor/auth）+ plugin 注册
./launch doctor

# 只安装 skills 到 ~/.agents/skills/（非 claude 目标：跳过 claude 其余流程）
./launch --agent agents install

# 交互式路径（可选）：curses TUI 勾选安装
./launch --tui
```

### 3) 环境依赖

需要系统已具备：`git` `curl` `tar` `node` `npm` `python3`（Python ≥ 3.10）。

`launch` 只检测并提示，不自动安装；缺失时给出可直接粘贴的安装命令（R9：砍掉 sudo/nvm 自动安装）。

### 4) 安装后验证

```bash
claude --version
./launch doctor
ls ~/.claude/plugins/marketplaces/
```

如果你走的是完整安装路径，还可以额外检查：

```bash
grep "OMC:START" ~/.claude/CLAUDE.md
ls ~/.claude/agents/ ~/.claude/commands/
```

带 `--smoke-test` 的 doctor 会执行扩展冒烟验证：

- **skills**：`skills.toml` 中的 `name` 是 source 别名，`skill = "*"` 表示该仓库的全部 skills。逐项确认名称出现在 `claude -p /context` 的 Skills 表中，并结合 `~/.claude/skills/` 的 frontmatter name 判定是否实际安装。
- **plugins**：从 `plugins.toml` 逐项检查精确的 `<name>@<marketplace>`，并要求 `claude plugin list --json` 返回 `scope = "user"`；缓存目录存在不等于已注册。
- **settings**：检查 `settings.template.json` 的非空键已存在于目标 `settings.json`。增量合并的“保留已有值、补齐缺失键、二次运行稳定”由 `tests/test-launch-settings.sh` 在隔离 fixture 中验证。

仓库顶层 `skills/` 下的 skill 是仓库自有源，不加入外部 `configs/skills.toml`；仅解压到仓库不会自动安装到 `~/.claude/skills`，也不会因此出现在当前用户的 `/context` 中。

## CLI 使用手册

`launch` 是一个幂等安装器：核心配置、外部 skills、第三方 plugins 三者分离，可整体安装，也可按类型、按单项精确操作。技能用 **skills.toml** 声明（`npx skills` 安装），插件用 **plugins.toml** 声明（`claude plugin` 安装）。

### 命令面

```text
launch [--agent claude|agents] [--dry-run] [-y] [-v] [--no-color] [--ci]
       [--no-verify] [--no-claude] [--force] [--skip SKILLS,PLUGINS]
       [--smoke-test] [--choose KIND:ID=CHOICE] [--tui]
       <command> [args...]

install [names...] [--plugin N...]   装 skills（无 N=全量；--plugin 装第三方 plugin）
add <owner/repo> <skill...>          试装第三方 skill，成功后追加 [[sources]] 进 skills.toml（--note 备注可选）
remove <names...>                    卸载 skills.toml 条目并从清单删除（自有 skills/ 源不触碰）
uninstall <names...> [--all|--core]  卸载（裸名先 skill 后 plugin；typed skill:/plugin: 直通）
update [names...]                    无 N = git pull + 全量更新；N 可重复 = 指定项
list                                 列已安装 skills（默认双 agent，==== 分隔）
core                                 仅同步 claude 核心配置（claude 目标专属）
doctor [--smoke-test]                核心验证 + claude CLI/诊断/plugin 注册 + 冒烟
```

全局 flag 可放在子命令前或后（`launch install --dry-run` 与 `launch --dry-run install` 等价）。退出码：0 成功、1 部分失败、2 用法错误。无参数裸跑 `./launch` 只打印 help，退出 0，不改任何文件。

### 安装

```bash
# 全自动完整安装：Claude Code + 核心配置 + 所有外部 skills + 所有第三方 plugins
./launch install

# 只装核心配置，不碰 skills/plugins
./launch core

# 强制重跑所有步骤（忽略幂等检测，适合修复异常）
./launch install --force
```

**按指定项安装**：

```bash
# 只装指定的一个/多个 skill（可重复；名字取 configs/skills.toml 的 name 或仓库 skills/ 目录名）
./launch install grilling evidence-driven-analysis

# 只装指定的第三方 plugin（名字取 configs/plugins.toml）
./launch install --plugin context-mode --plugin code-review

# 混搭：--plugin 与位置参数 skill 可同时出现
./launch install --plugin context-mode grilling
```

> 指定了任一 `--plugin` 或位置参数 skill 即进入「指定安装」模式：只装被指定的，未指定类别不装；全不指定 = 全量安装所有 skills + plugins。

> `--plugin` 与 `--skip` 互斥；指定名安装与 `--skip` 也互斥（argparse 校验后报 exit 2）。

### 更新

```bash
# 更新仓库（git pull --ff-only）+ 全部外部 skills + plugins
./launch update

# 只更新一个/多个指定项（可重复；裸名先 skill 后 plugin 消歧，typed skill:/plugin: 直通）
./launch update grilling
./launch update skill:grilling plugin:code-review

# 同名 local/remote 冲突用 --choose 解决（保留现语义）
./launch update skill:evidence-driven-analysis --choose skill:evidence-driven-analysis=local
```

- 外部 skill 走 `npx skills update`，仓库自有 skill 重铺 symlink（源码即改即生效），plugin 走 `claude plugin update`
- 任一项失败，最终退出码非零（失败聚合，不会因后续项成功而覆盖）
- 无参 `update` 与指定项 `update <names...>` 是两条路径，不混用

### 卸载

```bash
# 卸载一个/多个指定目标（裸名先 skill 后 plugin 消歧；typed 精确指定来源）
./launch uninstall oh-my-claudecode
./launch uninstall plugin:oh-my-claudecode plugin:ponytail
./launch uninstall skill:evidence-driven-analysis

# 完全卸载：core 配置 + 清单全部 skills + plugins
./launch uninstall --all

# 只卸载 core 配置
./launch uninstall --core
```

- skill 走 `npx skills remove`（+ 自有 symlink 移除），plugin 走 `claude plugin uninstall`
- 多个目标并发卸载（默认同时 3 个）；`--all`/`--core` 串行先行
- `--all` 与 `--core` 互斥；裸名在两个清单都未命中时报错 exit 2
- 卸载只移除安装目标目录下的受控副本，不触碰仓库源文件
- `settings.json` 默认保留，避免误删你的自定义配置。彻底重置：`rm ~/.claude/settings.json`

### 列表 / 诊断

```bash
./launch list              # ~/.claude 与 ~/.agents 两组，==== 分隔
./launch list --agent agents   # 只列 ~/.agents/skills/
./launch doctor            # 核心验证 + claude CLI（版本/doctor/auth）+ plugin 注册
./launch doctor --smoke-test   # 扩展：OMC doctor 子进程 + claude -p /context 注入冒烟
```

### 通用选项

```bash
./launch --dry-run        # 预览，不实际修改
./launch --ci             # CI 模式，跳过手动提示，完整日志写入临时文件并打印路径
./launch -y / --yes       # 跳过确认
./launch -v / --verbose   # 恢复逐项输出（默认只报每步一行）
./launch --no-color       # 关闭 ANSI 颜色（非 TTY 或 NO_COLOR=1 时自动关闭）
./launch --no-claude      # 跳过 Claude Code CLI 安装
./launch --no-verify      # 跳过最终验证
./launch --agent claude   # 完整 claude 目标（默认；别名 claude-code）
./launch --agent agents   # 只装 skills 到 ~/.agents/skills/（见「非 claude 目标的 skills 安装」）
./launch --tui            # 启动交互式 TUI（见下文）
./launch -h               # 查看帮助
```

#### 输出约定

- 默认每步一行：`✔` 完成/已就绪、`▲` 提醒、`✖` 失败、`▸` 阶段标题。
- 幂等跳过合并成一行，不逐项刷屏；`-v` 恢复逐项。
- `doctor` / `list` 的输出本身就是产物，始终完整打印，不受 `-v` 影响。
- 失败时给出可操作提示；`--ci` 会把完整日志写入 `mktemp` 临时文件并打印路径。

### 非 claude 目标的 skills 安装

`--agent agents` 进入只装 skills 模式：skills 统一装到 `~/.agents/skills/`，**其余全部跳过**（不装 Claude Code / 核心配置 / plugins，也不跑 claude 验证）。

`~/.agents/skills/` 是 `npx skills` 的 universal 全局目录，codex/gemini/cursor/github-copilot 等多个 agent 共享同一份，因此不需要为某个 agent 单独适配。

安装来源两类，与 claude 模式一致：

- **外部 skills**：`configs/skills.toml` 声明的 sources，经 `npx skills add -a universal -g` 装到 `~/.agents/skills/`
- **仓库自有 skills**：`skills/` 目录，symlink 到 `~/.agents/skills/<name>`

```bash
# 全量：外部全部 + 仓库自有全部
./launch --agent agents install

# 指定安装：只装这两个（其余类别不装）
./launch --agent agents install grilling diagram-design
```

### skills 最新版比对（跳过已是最新的）

外部 skills 安装前先比对已安装版本与远端最新版，**已存在且最新则跳过，不重复安装**：

- 数据源是 `npx skills` 的全局 lock（`~/.agents/.skill-lock.json`，`SKILLS_LOCK_FILE` 可覆盖）里记录的 `skillFolderHash`，与远端仓库 tree 中该 skill 目录的 oid 比对（与 `npx skills update` 同一口径）
- `lock` 无记录、来源不符、或目标目录缺 `SKILL.md` → 视为**未安装**，安装
- 远端 sha 与记录不一致 → **有新版本**，重装
- 比对不了（离线、GitHub API 限流、非 GitHub 源）→ **unknown，照常安装**，绝不因为查不到就误跳过
- `--force` 跳过比对，全部重装

仓库自有 skills 是源码 symlink，内容即改即生效，不存在版本比对；已是同一 symlink 时幂等跳过。

### 交互式 TUI

```bash
./launch --tui
```

基于 curses 的面板式多选（无需额外依赖，Python 自带 curses）：available（可安装）/ installed（可卸载）/ update 候选三个面板，`↑/↓` 移动、`space` 勾选、`enter` 执行当前面板勾选批、`tab` 切面板、`a` 切换 agent 目标、`q` 退出、`?` 帮助。

TUI 与 CLI 共享同一套驱动函数；无 TTY（stdin 非终端）时报错退出 2。Windows 无 curses：本仓库用户均为 Linux/macOS/WSL，不做替代实现。

> 旧 C++/FTXUI TUI（`tools/installer-tui`）已随 setup.sh 重写移除；统一资源冲突解析现经 `launch update --choose` 提供。

## 清单配置

外部 skills 与 plugins 声明在 `configs/` 下，由 `script/launch/manifest.py` 解析（纯标准库，兼容 Python 3.10）：

```text
configs/skills.toml    → 每个 [[sources]] 声明一个外部 skill 源（当前为空清单）
configs/plugins.toml   → 每个 [[plugins]] 声明一个第三方 plugin
```

- `skills.toml`：`npx -y skills@latest add <repo> -s <skill> -a claude-code -g`
  - **当前为空**：外部 skill 全部经 plugins.toml 的 claude plugin 机制提供，避免同一 skill 同时出现在 npx source 与 plugin（双源冲突）。新增 npx source 时按现有注释示例补充即可。
- `plugins.toml`：`method = "claude-plugin"` → `claude plugin marketplace add + install`；`method = "npx"` → 手动安装，仅备注命令
  - 官方市场（anthropics/claude-plugins-official）需**为每个 plugin 单独声明 `[[plugins]]` 条目**，只声明 marketplace 不会安装任何 plugin；marketplace add 由各条目在 install 前幂等执行

## 运行测试

测试脚本在 `tests/` 下，CI（`.github/workflows/test.yml`）与本地共用同一入口。各脚本都是幂等自包含的，隔离于临时 `$HOME`/fixture：

```bash
bash tests/test-launch-manifest.sh    # TOML 清单解析（skills.toml / plugins.toml）
bash tests/test-launch-plan.sh        # 统一资源计划层（discover/normalize/conflict）
bash tests/test-launch-settings.sh    # settings.json 增量合并语义（core.merge_settings_json）
bash tests/test-launch-doctor.sh      # doctor 模块：claude CLI/doctor/auth 检测（fixture claude）
bash tests/test-launch-context-smoke.sh  # doctor /context 注入冒烟解析（fixture claude）
```

## 架构概要

```text
./launch              → script/launch/cli.py（argparse + 子命令路由）
script/launch/
  core.py             → 核心配置同步/验证/卸载 + settings.json 渲染合并
  manifest.py         → skills.toml / plugins.toml 解析
  skills.py           → 外部（npx skills）+ 自有（symlink）skills 生命周期
  freshness.py        → lock hash vs 远端 oid 最新版比对
  plugins.py          → claude plugin marketplace 生命周期
  plan.py             → 统一资源计划（local/remote 冲突、--choose 解析）
  doctor.py           → 诊断面（核心验证 + claude CLI + plugin 注册 + 冒烟）
  updater.py          → git pull --ff-only 仓库更新
  agents.py           → claude / agents 双目标解析
  util.py             → 日志/颜色/confirm/symlink/依赖检测

~/.claude/
  CLAUDE.md        → claude/CLAUDE.md.ccfg（或由 OMC 注入后的宿主文件）
  rules/           → claude/rules/
  rules-available/ → claude/rules-available/
  agents/          → claude/agents/（自定义 subagent）
  hooks/rules-loader.sh → claude/hooks/rules-loader.sh
  skills/          → 自有 skill 由软链接安装（本地 skills/ 源）；外部 skill 现由 plugin 提供
  settings.json    ← 从 claude/settings.template.json 渲染并合并
  plugins/
    marketplaces/{omc,superpowers,context-mode,ponytail,claude-plugins-official}
    cache/omc/{oh-my-claudecode,context-mode,ponytail,superpowers}/.../skills/ → 外部 skill 经 plugin 注入
~/.agents/skills/     → universal 共享 skills 目录（--agent agents 目标）

外部 skills 与 plugins 的来源声明在 `configs/`（见上文清单配置），不由仓库直接管理。
```

## 故障恢复

- **安装后异常**：
  ```bash
  ~/claude-config/launch install --force
  ```
- **只想检查，不想重装**：
  ```bash
  ~/claude-config/launch doctor
  ```
- **需要更深的检查**：
  ```bash
  ~/claude-config/launch doctor --smoke-test
  ```
- **插件 hook 报错**：先 `/reload-plugins`，仍有问题再重跑 `./launch install`
- **依赖缺失**：按 `launch` 输出的提示手动补装（`node`/`npm` 建议 nvm + 最新 LTS）
- **版本回退**：
  ```bash
  git -C ~/claude-config log --oneline
  git -C ~/claude-config checkout <commit>
  ~/claude-config/launch install --force
  ```
