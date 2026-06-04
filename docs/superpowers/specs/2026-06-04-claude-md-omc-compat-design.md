# CLAUDE.md / OMC 兼容设计

**日期**: 2026-06-04
**状态**: Draft
**主题**: 让核心配置校验与 OMC 官方 CLAUDE.md 注入方式兼容

## 背景

当前核心配置将 `~/.claude/CLAUDE.md` 视为运行时 symlink，目标为仓库内的 `config/claude/CLAUDE.md.ccfg`。但 OMC 官方安装流程会通过 `setup-claude-md.sh` 直接改写 `~/.claude/CLAUDE.md`，将其变为包含 OMC block 的普通文件，并在同一文件内保留或追加用户自定义 block。

因此，`verify_core_config()` 中“必须是 symlink”的判断会与 OMC 官方行为发生冲突，出现 `CLAUDE.md symlink 缺失` 的误报。

## 目标

1. 兼容 OMC 官方安装与注入流程。
2. 保留仓库内 `config/claude/CLAUDE.md.ccfg` 作为 Claude-Config 的受管来源。
3. 让 `setup.sh` 在以下两种状态下都判定为合法：
   - `~/.claude/CLAUDE.md` 是 symlink，指向 `CLAUDE.md.ccfg`
   - `~/.claude/CLAUDE.md` 是普通文件，但同时包含 OMC block 与 Claude-Config block
4. 卸载核心配置时，既能处理 symlink，也能处理已被注入的普通文件。
5. 不改动 OMC 官方注入脚本本身。

## 非目标

- 不重写 OMC 的 `setup-claude-md.sh`
- 不要求 OMC 改成 companion-file 模式
- 不要求运行时 `~/.claude/CLAUDE.md` 永远保持 symlink

## 方案选择

### 方案 A（采用）

将 `~/.claude/CLAUDE.md` 定义为“OMC 可注入宿主文件”，校验逻辑接受两种合法状态：

- **symlink 状态**：初始核心安装后，`~/.claude/CLAUDE.md -> config/claude/CLAUDE.md.ccfg`
- **注入状态**：OMC 官方安装后，`~/.claude/CLAUDE.md` 为普通文件，且包含：
  - `<!-- OMC:START --> ... <!-- OMC:END -->`
  - `<!-- Claude-Config:START --> ... <!-- Claude-Config:END -->`

### 不采用的方案

- **强制 symlink 优先**：会持续与 OMC 官方注入冲突
- **改成 companion 文件主导**：边界更清晰，但改动面更大，不是本轮最小修复
- **完全回退到 merge-only**：会削弱 `CLAUDE.md.ccfg` 作为受管源的定位

## 设计细节

### 1. `ensure_core_config()`

保留当前行为：

- 初始安装时仍创建 `~/.claude/CLAUDE.md` symlink
- 同时继续创建 `itp.md` 与 `haiku-throttle.md` symlink

原因：

- 在未安装 OMC 时，symlink 是最简单、最可追踪的形态
- OMC 安装后若改写为普通文件，不应视为错误

### 2. `verify_core_config()`

新增专用判断逻辑，例如：

- `claude_md_symlink_ready()`：判断是否为指向 `CLAUDE.md.ccfg` 的 symlink
- `claude_md_injected_ready()`：判断是否为普通文件，且同时存在 OMC block 与 Claude-Config block

`verify_core_config()` 的 `CLAUDE.md` 分支应改为：

- 满足 `symlink_ready` → PASS
- 否则满足 `injected_ready` → PASS（文案应说明为 injected/managed file）
- 两者都不满足 → FAIL

这样能准确表达当前状态，而不是把 OMC 官方行为误报成损坏。

### 3. `uninstall_core()`

需要兼容两种状态：

- **symlink 状态**：直接移除 symlink
- **注入状态**：从 `~/.claude/CLAUDE.md` 中只移除 `Claude-Config` block，不触碰 OMC block

也就是说，应恢复对 `remove_managed_block()` 的使用，但只在文件中实际存在 `Claude-Config` block 时执行；不能删除整个 `CLAUDE.md`，也不能破坏 OMC 注入内容。

### 4. 文案与状态表达

当前错误文案 `CLAUDE.md symlink 缺失` 容易误导，因为它把“非 symlink”直接等同于“损坏”。修复后应区分：

- `PASS CLAUDE.md symlink`
- `PASS CLAUDE.md injected config`
- `ERR CLAUDE.md 缺少受管配置（既不是目标 symlink，也不包含 OMC + Claude-Config blocks）`

### 5. 与 OMC 的边界

边界定义如下：

- 本仓库负责：`Claude-Config` block 的来源与验证
- OMC 负责：向 `~/.claude/CLAUDE.md` 注入其官方 block
- 运行时 `CLAUDE.md` 最终形态允许由 OMC 接管，但必须保留本仓库的受管 block

## 数据流

### 未安装 OMC

1. `setup.sh core/install` 创建 `~/.claude/CLAUDE.md -> CLAUDE.md.ccfg`
2. `verify_core_config()` 以 symlink 形态通过

### 安装 OMC 后

1. OMC 官方脚本读取并改写 `~/.claude/CLAUDE.md`
2. 文件从 symlink 变为普通文件
3. 文件中保留/追加 OMC block 与 Claude-Config block
4. `verify_core_config()` 以 injected 形态通过

### 卸载 core

1. 若是 symlink，移除 symlink
2. 若是 injected file，只移除 `Claude-Config` block
3. OMC block 保持不变

## 错误处理

- 若 `~/.claude/CLAUDE.md` 不存在 → FAIL
- 若存在但既无 OMC block 也无 Claude-Config block → FAIL
- 若仅有 OMC block、无 Claude-Config block → FAIL
- 若仅有 Claude-Config block、无 OMC block：
  - 如果它是目标 symlink → PASS
  - 如果它是普通文件 → 可视为历史/半迁移状态，建议 FAIL 并提示重新运行 core/omc 安装以收敛形态

## 测试与验证

至少验证以下场景：

1. **Core-only 场景**
   - 运行 `./setup.sh core --no-claude`
   - `verify_core_config()` 通过
   - `CLAUDE.md` 为 symlink

2. **OMC 注入场景**
   - 构造一个包含 OMC + Claude-Config blocks 的普通文件
   - `verify_core_config()` 通过
   - 不再报 `CLAUDE.md symlink 缺失`

3. **Core uninstall 场景（symlink）**
   - `uninstall_core()` 正常移除 symlink

4. **Core uninstall 场景（注入文件）**
   - 仅移除 `Claude-Config` block
   - OMC block 仍保留

5. **异常场景**
   - 缺少 `Claude-Config` block 的普通文件应失败

## 风险

- 若 `remove_managed_block()` 的正则边界不够稳，可能误删相邻内容
- 若 OMC 后续调整注入 marker 命名，`claude_md_injected_ready()` 需要同步更新
- 若用户手工改写 `CLAUDE.md`，验证逻辑需要保持“保守失败”而不是误判成功

## 推荐实施顺序

1. 为 `CLAUDE.md` 增加双形态判断 helper
2. 调整 `verify_core_config()` 输出文案
3. 恢复并收敛 `uninstall_core()` 对 injected file 的 block-level 清理
4. 运行 core-only 与 injected-file 两类验证

## 验收标准

- OMC 官方安装后不再出现 `CLAUDE.md symlink 缺失` 误报
- 未安装 OMC 时，core-only 仍保持 symlink 路径通过
- `uninstall_core()` 不会破坏 OMC block
- `CLAUDE.md.ccfg` 继续作为 Claude-Config 的单一受管来源
