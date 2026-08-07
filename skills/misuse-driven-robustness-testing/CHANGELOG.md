# Changelog

## 0.2.5 — 2026-08-07

### Fixed

- `CONDITIONAL-PASS` 不再接受 `NOT-RUN-SAFETY` 或 `INCONCLUSIVE-FAULT-NOT-PROVEN`；当前版本不提供隐式 waiver。
- Agent 行为 eval 全部 skipped 时默认返回非零；只有显式 `--allow-skipped` 才允许绿色退出。
- tool/agent/judge 子进程新增 case/global timeout，超时分类为 `blocked-harness`。
- 声明文本中的转义 `|` 不再在 AST→表格归一化过程中被静默截断。
- Evidence artifact SHA-256 改为分块 streaming hash，避免大 Core/Trace/PCAP 一次性读入内存。
- 删除发布包中的空 `tests/test_generate_campaign.py.tmp`。

### Changed

- 主动扰动授权边界扩大到任何非本地、第三方、共享、外部或可能影响他人的目标，而不只强调生产。
- `--max-scenarios` 每次生成都会输出覆盖摘要，明确 covered claims、omitted claims 和 omitted lenses。
- Eval runner 报告新增 `blocked_harness` 计数。

## 0.2.4

- 新增 Evidence manifest Schema：稳定 `EV-*` ID、artifact、SHA-256、采集时间、collector、source、敏感级别与 lineage。
- 严格校验器可解析 Evidence 引用、拒绝未知 ID/重复 ID/未知 parent/lineage 环，并可重新计算本地 artifact SHA-256。
- 增加 `--evidence-manifest` 与 `--require-artifacts`；明确 Hash/lineage 只验证完整性元数据，不证明证据来源真实性。
- Markdown 正文解析迁移到 Mistune AST；非正文节点不再依赖正则剔除。
- `profile.schema.json` 成为生成器结构验证单一来源，使用 jsonschema；Python 仅保留跨项语义。
- 新增 `eval_runner.py`、确定性 tool eval suite、版本 regression baseline 机制以及可插拔 agent/judge adapter。
- 新增 Evidence、Runner、Schema single-source 等回归测试与行为 Evals。

## 0.2.3 — 2026-08-07

### Added

- 正文预处理：忽略 fenced code block、HTML 注释、引用块和缩进代码；
- 声明表结构解析、ID 格式校验、重复 ID 与空声明检测；
- 精确声明引用列表解析，拒绝子串、未知和重复引用；
- Unicode NFKC 规范化、零宽/Cf 字符清理和否定性证据识别；
- Oracle 执行状态、断言计数、扰动命中状态和命中观测来源；
- 结构化环境恢复状态与恢复证据；
- 所有发布状态下的已验证/未验证声明全集核对；
- 代码块、注释、Unicode、声明引用、恢复冲突和自动链接回归测试；总计 66 个自动化测试。

### Fixed

- 隐藏在代码块或 HTML 注释中的完整示例可绕过严格门禁；
- `C1` 子串错误匹配 `C10`，未知声明被静默忽略；
- 重复声明 ID 被集合静默合并；
- 全角 `N/A`、零宽字符和“未采集/未证明”句子伪造通过证据；
- 发布 `PASS` 与失败或未验证的环境恢复状态并存；
- `CONDITIONAL-PASS`/`BLOCKED` 可隐藏未验证声明；
- `www.` 与邮箱形式仍可能被 GFM 自动链接。

### Changed

- 严格校验器明确定位为结构与一致性门禁，不声称验证证据真实性；
- `INCONCLUSIVE-FAULT-NOT-PROVEN` 分别要求落地尝试和未证明原因；
- Profile claim ID 与 Campaign claim ID 使用统一格式。
## 0.2.2 — 2026-08-06

### Added

- verdict 感知的空值规则：区分通过证据、阻塞未执行和安全未执行；
- 全局安全字段和发布结论字段的严格解析；
- 声明 ID、场景关联、已验证声明和发布结论的一致性校验；
- `BLOCKED-*` 解除条件和 `NOT-RUN-SAFETY` 替代执行方式；
- 远程 Markdown 图片、链接和自动链接中和；
- 未知 profile 字段与重复 lens 拒绝；
- 13 个新增回归测试，总计 35 个自动化测试。

### Fixed

- `无 / N/A / none / 不适用 / 未执行 / - / x` 可伪造 `PASS-EVIDENCED`；
- 空安全章节和空发布结论章节仅凭标题通过；
- 发布 `PASS` 与失败、阻塞、部分 Oracle 或未覆盖声明并存；
- profile 拼写错误字段被静默忽略；
- Markdown 图片或链接语法可能触发远程请求。

### Changed

- 严格校验器从场景格式检查升级为声明覆盖与发布结论门禁；
- JSON Schema 顶层、claim 和 safety 均使用 `additionalProperties: false`；
- 手写验证与 Schema 统一为拒绝重复 lens。

## 0.2.1 — 2026-08-06

### Added

- `validate_campaign.py --strict` 发布门禁模式；
- 场景级 Markdown 解析、空值检查、合法 verdict 与证据一致性检查；
- profile JSON Schema 与严格手写输入验证；
- Markdown/HTML 输入转义；
- 不可信内容、提示注入和敏感证据处理规则；
- 16 个 Skill eval；
- 生成器和校验器单元测试；
- 严格校验可通过的完整活动示例；
- `README.md`、`LICENSE`、Python 版本和发布说明。

### Changed

- 所有输入错误统一输出简洁错误并返回退出码 `2`；
- 活动骨架新增 Oracle 输出、复现路径和 verdict 条件字段；
- 发布门禁明确要求严格模式。

### Fixed

- 空壳场景和全 TODO 活动被误判为 PASS；
- “不发生崩溃”等弱 Oracle 绕过检查；
- 字符串类型的 `states` 被拆成单字符；
- 字符串影响值、错误 `safety` 类型和重复声明 ID 导致 traceback 或静默通过；
- 输入中的竖线、换行和 HTML 破坏 Markdown 结构。

### Packaging

- 移除 `.pyc` 与 `__pycache__`；
- `.skill` 包继续按 skill-creator 规则排除根目录 `evals/`。

## 0.2.0

- 拆分主 Skill、references、assets 和 examples；
- 增加独立复现路径和多状态结论。
