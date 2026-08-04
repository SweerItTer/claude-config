---
name: installer-authoring
description: Use when adding or changing a project installer for a Claude Skill, MCP server, hook, plugin, or other optional component, especially when setup.sh must discover install_* scripts, resolve prerequisites, expose dry-run/non-interactive/TUI selection, or preserve safe uninstall and rollback behavior.
---

# Installer Authoring

把每个可选组件当作有 ownership 的事务，而不是把新分支堆进 `setup.sh`。`setup.sh` 只负责兼容参数和调用编排器；组件脚本负责一个组件的生命周期；TUI 只负责选择，不直接改 Claude 配置。

## 目录与边界

- `script/install_*.sh`：一个组件一个脚本；兼容现有 `install-*.sh`，不要再增加新的硬编码 `case`。
- `config/installers.mk`：纯声明数据，描述组件、脚本、依赖、系统命令、平台、冲突、默认选项和受管 scope；禁止 recipe、`eval` 和任意 shell。
- `script/setup-engine.sh`：发现、解析、校验、依赖闭包、稳定拓扑排序、preflight、执行和状态/journal。
- `tools/installer-tui/`：独立 TUI；读取 plan/status，stdout 只返回机器可读选择，界面写 stderr；无 TTY 必须退出或走显式非交互参数，不能阻塞。TUI 与 engine 默认只用系统已有运行时；若声明外部运行时，必须在 preflight 检查并以固定错误退出，不能隐式安装。
- `config/claude/`：Claude 模板、skills、hooks 和 MCP 片段；不要把安装器元数据或 TUI 逻辑塞进模板。

## `install_*` 合约

脚本接收 `REPO_ROOT`、`DRY_RUN`、`FORCE`，通过环境变量 `ACTION` 支持 `install|update|reinstall|uninstall|verify|status|doctor`，并复用 `script/install-common.sh`。engine 对 CI 固定提供 `--non-interactive`（可配合显式 `--components` 或 `--all`），不能把缺少 TTY 当成等待输入。建议固定退出码：`0` 成功，`2` 参数/声明无效，`3` preflight 缺依赖或冲突，`4` 执行/verify 失败，`5` 回滚不完整。要求：

1. 第二次运行是 no-op 或稳定更新；`DRY_RUN=true` 不产生持久化副作用。
2. 修改 JSON 用临时文件后 atomic rename；symlink 只有目标正确才复用。
3. transaction journal 至少记录 `schema`、`component`、`action`、`status`、时间、canonicalized `owned_paths`（路径、类型、预期指纹、创建 run）和本次新增的外部依赖；先写 journal，再做第一次修改。
4. 删除前先 canonicalize 路径并确认它位于声明的 owned root，且 manifest/journal 的类型和指纹仍匹配；禁止无边界 `rm -rf`。普通用户文件、共享资源和预存在的全局包不得擅自删除。
5. 安装后立即 `verify`；失败返回固定非零码并保留可恢复 journal，不输出“全部完成”。
6. 外部 npm/cargo/系统包只有记录为本次新安装时才允许补偿卸载。

## 声明校验与执行顺序

解析器必须拒绝重复 ID、未知字段、缺脚本、越界脚本路径、未知依赖、依赖环、非法布尔值/平台和冲突选择。先计算依赖闭包，再稳定拓扑排序；默认串行，避免并发写 `settings.json`、marketplace registry 或 symlink。

安装前一次性 preflight 平台、`requires` 命令、版本、权限、网络和冲突。非交互模式缺依赖直接失败并给修复命令；不要隐式 `sudo`。执行前创建锁和 transaction journal，逐项执行并验证，成功后才提交 state。TUI 只产生选择，不写配置、不创建 journal、不执行组件；engine 负责所有副作用。

卸载按逆拓扑顺序执行；按 ownership/refcount 清理；`settings.json` 默认保留，彻底删除必须有显式 `--purge`。冲突内容先备份，不覆盖。

## 最小验证

新增组件至少覆盖：`bash -n`、声明解析/缺依赖/环/越界路径、fixture `HOME` 下 dry-run 零修改、连续两次安装结果一致、`--non-interactive` 的固定选择与退出码、非 TTY 不阻塞、组件失败后的回滚，以及保留用户文件。继续运行现有 `script/test-setup-dependencies.sh` 与 `script/test-setup-path-and-marketplace.sh`。

## 禁止的捷径

| 说法 | 处理 |
|---|---|
| “先在 `setup.sh` 加一个 case” | 拒绝；添加声明和通用 engine 扩展点。 |
| “TUI 和安装动作放一个脚本最快” | 拒绝；TUI 只返回选择，engine 执行。 |
| “先写大脚本，测试以后补” | 拒绝；先写失败场景和 dry-run/幂等测试。 |
| “卸载时直接 `rm -rf`” | 拒绝；只删 owned 路径，共享和用户内容保留。 |

新增安装器前先生成 plan；无法证明 ownership、幂等和非交互安全时，先停在 preflight，不执行修改。
