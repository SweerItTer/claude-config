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

# 检测 Claude Code CLI 本体安装状态（版本/路径/doctor/auth）
./setup.sh check

# 只读列出清单声明的外部 skills/plugins 与仓库本地 skills
./setup.sh list

# 交互式路径（可选）：构建 FTXUI TUI 后勾选安装，见「交互式 TUI 安装器」
./setup.sh --tui
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

带 `--smoke-test` 的安装会执行清单驱动的安装后验证：

- **skills**：`skills.toml` 中的 `name` 是 source 别名，`skill = "*"` 表示该仓库的全部 skills，不是单个实际 skill 名。setup 会用 `npx -y skills@latest list -g --json` 按 `source` 找到实际安装项，检查每个 `SKILL.md`，再逐项确认名称出现在 `claude -p /context` 的 Skills 表中。若当前 `skills` CLI 的 list 输出漏掉已安装 agent，验证器会使用该 CLI 自己维护的 `~/.agents/.skill-lock.json` 精确恢复 source/path，不会退化为模糊目录匹配。
- **plugins**：从 `plugins.toml` 逐项检查精确的 `<name>@<marketplace>`，并要求 `claude plugin list --json` 返回 `scope = "user"`；缓存目录存在不等于已注册。
- **settings**：检查 `settings.template.json` 的非空键已存在于目标 `settings.json`。增量合并的“保留已有值、补齐缺失键、二次运行稳定”由 `tests/test-settings-merge.sh` 在隔离 fixture 中验证。

仓库顶层 `skills/` 下的 skill（包括 `misuse-driven-robustness-testing` 和 `project-governance`）是仓库自有源，不加入外部 `configs/skills.toml`；仅解压到仓库不会自动安装到 `~/.claude/skills`，也不会因此出现在当前用户的 `/context` 中。

## CLI 使用手册

`setup.sh` 是一个幂等安装器：核心配置、外部 skills、第三方 plugins 三者分离，可整体安装，也可按类型、按单项精确操作。技能用 **skills.toml** 声明（`npx skills` 安装），插件用 **plugins.toml** 声明（`claude plugin` 安装）。

### 安装

```bash
# 全自动完整安装：核心配置 + 所有外部 skills + 所有第三方 plugins
./setup.sh

# 只装核心配置（CLAUDE.md / rules / settings.json），不碰 skills/plugins
./setup.sh core

# 强制重跑所有步骤（忽略幂等检测，适合修复异常）
./setup.sh --force
```

**按类型安装**：

```bash
# 只装 skills，跳过 plugins
./setup.sh --skip-plugins

# 只装 plugins，跳过 skills
./setup.sh --skip-skills

# 只装核心配置 + 指定的一个/多个 plugin（可重复，名字取 configs/plugins.toml）
./setup.sh --plugin context-mode --plugin code-review

# 混搭：只装指定 plugin 和仓库自有 skill（本地 skills/ 目录），其余跳过
./setup.sh --plugin context-mode --update-local-skill evidence-driven-analysis
```

> `--skill`（按 skills.toml 选外部 skill）当前无合法值：双源冲突治理后 `configs/skills.toml` 为空清单，外部 skill 全部经 `configs/plugins.toml` 的 claude plugin 机制提供（oh-my-claudecode / ponytail / superpowers 均为 plugin 条目）。若在 skills.toml 新增 npx source，`--skill <名字>` 恢复可用（名字取 source 的 `name`）。

安装时若同时给了 `--skill` 和 `--plugin`，则只装这些指定项，其余项不装。全不指定 = 全量安装所有 skills + plugins。

> 互斥校验：`--skip-skills` 与 `--skill` 不能同时用，`--skip-plugins` 与 `--plugin` 不能同时用。

### 更新

```bash
# 更新全部外部 skills + plugins
./setup.sh --update-all

# 只更新一个/多个指定外部 skill（可重复；当前 skills.toml 为空清单，见下）
# ./setup.sh --update-skill <skills.toml 中的 source 名>

# 更新仓库自有 skill：创建/刷新 ~/.claude/skills 下的软链接（可重复）
./setup.sh --update-local-skill evidence-driven-analysis \
  --update-local-skill three-tier-orchestration

# 只更新一个/多个指定 plugin（可重复）
./setup.sh --update-plugin code-review

# 指定项里混 plugins 和仓库自有 skill
./setup.sh --update-plugin context-mode --update-local-skill evidence-driven-analysis

# 更新某类型全部（core/all 也接受）
./setup.sh --update-skill core
./setup.sh --update-plugin all
```

- 外部 skill 走 `npx skills update`，仓库自有 skill 走 `--update-local-skill` 刷新软链接，plugin 走 `claude plugin update`；外部 skill 的更新现经 plugin 机制（`claude plugin update`）完成，`--update-skill` 仅在 skills.toml 有 npx source 时可用
- 任一项失败，最终退出码非零（失败聚合，不会因后续项成功而覆盖）
- `--update-all` 与 `--update-skill`/`--update-plugin` 互斥，不能同时用

### 卸载

```bash
# 卸载一个/多个指定 plugin（typed，明确区分 skills/plugin）
# （当前 skills.toml 为空清单，外部 skill 经 plugin 提供，`--uninstall-skill` 仅在 skills.toml 有 source 时可用）
./setup.sh --uninstall-plugin oh-my-claudecode
./setup.sh --uninstall-plugin oh-my-claudecode --uninstall-plugin ponytail

# 卸载仓库自有 skill（本地 skills/ 目录下的软链接）
./setup.sh --uninstall-skill evidence-driven-analysis

# 卸载一个/多个指定 plugin（typed）
./setup.sh --uninstall-plugin code-review
./setup.sh --uninstall-plugin code-review --uninstall-plugin feature-dev

# 卸载单个目标（无类型时按 skill-first 解析；context-mode 仅是 plugin，推荐使用 typed flag）
./setup.sh --uninstall-plugin context-mode

# 完全卸载：core 配置 + 全部 skills + plugins
./setup.sh --uninstall all

# 只卸载 core 配置
./setup.sh --uninstall core
```

- skill 走 `npx skills remove`，plugin 走 `claude plugin uninstall`；同一仓库只通过一种来源安装，避免 npx skill 与 plugin skill 重复声明
- 多个清单项并发卸载（默认同时 3 个，`UNINSTALL_JOBS` 可调）；`core`/`all` 串行
- **typed flags（`--uninstall-skill`/`--uninstall-plugin`）优先**：skill 与 plugin 由不同清单声明，即使名称相同也用 typed flag 精确指定来源；当前 `context-mode`、`oh-my-claudecode`、`ponytail`、`superpowers` 均为 plugin 条目（双源冲突治理后 skills.toml 为空清单）
- 卸载只移除 `~/.claude/skills/` 下由 `npx skills` 安装的副本和 `claude plugin uninstall` 卸载的插件，不触碰本仓库源文件
- `settings.json` 默认保留，避免误删你的自定义配置。彻底重置：`rm ~/.claude/settings.json`

### 验证 / 状态 / 诊断

```bash
./setup.sh verify     # 检查核心配置是否齐全
./setup.sh status     # 检查核心配置与模块状态
./setup.sh doctor     # 诊断路径，排查安装异常
./setup.sh check      # 检测 Claude Code CLI 本体安装状态（版本/路径/doctor/auth）
./setup.sh list       # 只读列出声明的外部 skills/plugins 与仓库本地 skills（按资源类型分组，冲突项标注）
./setup.sh --smoke-test   # 运行 doctor + 上下文注入检查
```

### 通用选项

```bash
./setup.sh --dry-run      # 预览，不实际修改
./setup.sh --ci           # CI 模式，跳过手动提示
./setup.sh --no-claude    # 跳过 Claude Code CLI 安装
./setup.sh --no-verify    # 跳过验证
./setup.sh --tui          # 启动交互式 TUI 安装器（见下文）
./setup.sh -h             # 查看帮助
```

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

## 交互式 TUI 安装器

除了纯命令行，还提供基于 FTXUI 的交互式 TUI（`C++17`），让零基础用户不用读 CLI 文档就能勾选安装。

### 构建

TUI 不是默认构建的，需要先安装 FTXUI 并编译：

```bash
# 1) 安装 FTXUI 7.0.2（Ubuntu 24.04 官方源无 libftxui-dev，需从源码构建）
git clone --depth 1 --branch v7.0.2 https://github.com/ArthurSonzogni/FTXUI.git /tmp/FTXUI
cmake -S /tmp/FTXUI -B /tmp/FTXUI/build -DCMAKE_BUILD_TYPE=Release
cmake --install /tmp/FTXUI/build

# 2) 构建 TUI 二进制（输出到 build/installer-tui/installer-tui）
cmake -S tools/installer-tui -B build/installer-tui
cmake --build build/installer-tui
```

> 仅支持 Linux x86_64。CMake 在配置期检查 `CMAKE_SYSTEM_NAME == Linux` 且处理器为 x86_64，否则直接 FATAL_ERROR。

### 启动

```bash
./setup.sh --tui
```

`setup.sh` 在任意 argv 位置识别 `--tui`，找到已构建的二进制后 `exec` 进入 TUI；未构建时给出上面的构建命令并退出 2。

也可以直接运行二进制（默认从 cwd 向上定位 `setup.sh`+`configs/`，或用 `--repo-root` 指定）：

```bash
build/installer-tui/installer-tui --repo-root ~/claude-config
```

### 统一资源语义

TUI 与 CLI 共享同一套资源模型（`script/resource-plan.py`）：资源按 **identity**（`skill:<真实名>` / `plugin:<名>@<marketplace>`）统一管理，不区分「本地 skill / 外部 skill / plugin」入口。本地候选来自仓库 `skills/`，远程候选来自 `configs/` 清单；**只有当同一 identity 同时存在 local 与 remote 候选（冲突）时**才需要用户选择来源，普通唯一资源自动处理，绝不静默默认来源。

### 四个页面

| 页 | 功能 |
|----|------|
| **1 Install** | 统一资源分列勾选（本地 skills / 外部 skills / plugins）。全不勾选 = 全量安装；只勾部分则只装勾选的，未选类别自动跳过（对应 CLI `--skip-skills`/`--skip-plugins`）。页面顶部有冲突时显示冲突区块 |
| **2 Update** | 单选框：`全部外部 skills + plugins`（对应 `--update-all`）/ `选中的项目`（复用 Install 页勾选，本地 skill 走 symlink 同步，冲突走统一 resolver） |
| **3 Uninstall** | 单选框：`完全卸载`（对应 `--uninstall all`）/ `仅 core` / `选中的项目`（本地 skill 卸载只删受控软链接，保留仓库源；冲突资源只能勾选一个来源） |
| **4 诊断** | 单选框：`verify` / `status` / `doctor`（只读检查，对应 CLI 的 `verify`/`status`/`doctor`，执行 `setup.sh <action>`） |

### 冲突处理

同一 identity 的 local（仓库 `skills/` 路径）与 remote（URL/repository）候选同时存在时，Install 页顶部列出冲突区块，每项显示 **local 路径 vs remote URL/repository**，radiobox 三选一：`local` / `remote` / `skip`。未解决冲突时不能确认执行；非交互环境（`--ci`、无 TTY）未解决冲突返回非零。

### 操作

```text
[1] [2] [3] [4]  切页
[a]           全选 / 取消全选（Install 与 Uninstall 页）
[↑/↓] / [j/k] 移动高亮
[Space]       勾选 Checkbox / 确认 Radiobox 当前高亮项
[e] / [Enter] 打开确认弹窗
[q]           退出
```

> 注意：Radiobox（Update 页、Uninstall 页、诊断页的模式选择）用方向键只移动高亮，**需再按空格**才会真正选中该项，然后按 `e` → `Enter` 确认。

### 执行与输出契约

- 按 `[e]` 弹出确认框，选「执行」后：
  - 后台以子进程运行对应的 `setup.sh` 命令，输出实时显示在底部日志面板
  - **stdout** 输出一行机器可读的 tab 分隔记录，格式：`<action>\t<items>`，items 以 tab 分隔
  - 运行期间再按 `e` 会提示「任务正在执行」；`q` 会取消后台子进程并等待清理
- 机器可读记录示例（items 里 `skill:`/`plugin:` 前缀明确区分类型）：

```text
install	all
install	skill:context-mode	plugin:code-review
update	all
update	skill:context-mode
uninstall	all
uninstall	core
uninstall	skill:context-mode	plugin:superpowers
verify	all
status	all
doctor	all
```

- TUI 的 UI 全部输出到 **stderr**，stdout 只保留机器可读记录，方便脚本消费
- `--print-selection` 提供无 UI 的纯打印模式：`build/installer-tui/installer-tui --print-selection` 直接输出统一资源计划的 9 列 TSV 记录（与 `resource-plan.py --format tsv` 一致），无冲突 exit 0、有未决冲突 exit 2，供脚本/测试使用
- 无 TTY（stdin 非终端）时：有 `--help`/`--print-selection` 则正常处理，否则提示并退出 2，不会阻塞挂起

## 清单配置

外部 skills 与 plugins 声明在 `configs/` 下，用 Python `parse-manifests.py` 解析（纯标准库，Python 3.10 无 tomllib 时自动回退）：

```text
configs/skills.toml    → 每个 [[sources]] 声明一个外部 skill 源（当前为空清单）
configs/plugins.toml   → 每个 [[plugins]] 声明一个第三方 plugin
```

- `skills.toml`：`npx -y skills@latest add <repo> -s <skill> -a claude-code -g`
  - **当前为空**：外部 skill 全部经 plugins.toml 的 claude plugin 机制提供，避免同一 skill 同时出现在 npx source 与 plugin（双源冲突）。新增 npx source 时取消注释下方 vercel 示例并按需调整即可。
- `plugins.toml`：`method = "claude-plugin"` → `claude plugin marketplace add + install`；`method = "npx"` → 手动安装，仅备注命令
  - 官方市场（anthropics/claude-plugins-official）需**为每个 plugin 单独声明 `[[plugins]]` 条目**（如 skill-creator、code-review），只声明 marketplace 不会安装任何 plugin；marketplace add 由各条目在 install 前幂等执行

测试：`bash tests/test-manifest-parsing.sh`

## 运行测试

测试脚本在 `tests/` 下，CI（`.github/workflows/test.yml`）与本地共用同一入口。各脚本都是幂等自包含的 bash 回归测试，隔离于 `$HOME`/`~/.claude`（settings-merge 用临时 fixture 验证增量合并）：

```bash
bash tests/test-manifest-parsing.sh        # TOML 清单解析（skills.toml / plugins.toml）
bash tests/test-resource-plan.sh           # 统一资源计划层（discover/normalize/conflict）
bash tests/test-setup-resolver.sh          # setup.sh 统一 resolver 与旧 flags 兼容
bash tests/test-setup-path-and-marketplace.sh  # repo 路径定位与 marketplace 解析
bash tests/test-setup-dependencies.sh      # 依赖 bootstrap 回归
bash tests/test-settings-merge.sh          # settings.json 增量合并语义
bash tests/test-skill-context-verification.sh  # skill 上下文验证 source fallback
bash tests/test-installer-tui.sh           # TUI 集成测试（需先构建 FTXUI，见「交互式 TUI 安装器」）
```

## 架构概要

```text
~/.claude/
  CLAUDE.md        → claude/CLAUDE.md.ccfg（或由 OMC 注入后的宿主文件）
  rules/           → claude/rules/
  rules-available/ → claude/rules-available/
  skills/          → 自有 skill 由软链接安装（本地 skills/ 源）；外部 skill 现由 plugin 提供（见 plugins/）
  settings.json    ← 从 claude/settings.template.json 渲染并合并
  plugins/
    marketplaces/{omc,superpowers,context-mode,ponytail,claude-plugins-official}
    cache/omc/{oh-my-claudecode,context-mode,ponytail,superpowers}/.../skills/ → 外部 skill 经 plugin 注入
```

外部 skills 与 plugins 的来源声明在 `configs/`（见上文清单配置），不由仓库直接管理。
