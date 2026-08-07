# 方法来源与重新组合说明

本 Skill 不是任一现有 Skill 的改名版，也不复制大段原文。它把不同方法族重新组合为：

`声明 → 风险 → 状态模型 → 误用假设 → Oracle/落地证据 → 执行器 → 复现缩减 → 回归 → 发布结论`

## 实际参考

| 来源 | 采用内容 | 在本 Skill 中的位置 |
|---|---|---|
| `petrkindlmann/qa-skills`：`exploratory-testing` | 章程、边界/状态探索、What-if、发现转回归 | 误用透镜、探索执行模式 |
| `phatnguyen975/functional-test-design`：`error-guessing` | 基于历史缺陷和常见失误形成有依据的猜测 | 误用假设生成 |
| `redhatproductsecurity/prodsec-skills`：`property-based-testing` | 不变量、幂等、往返、Shrinking、弱/强 Oracle | Oracle 与生成式测试 |
| `testland/qa`：`fast-check-testing` | 模型命令序列、Seed、操作历史和缩减 | 状态型 API 与乱序操作 |
| `petrkindlmann/qa-skills`：`risk-based-testing`、`ai-qa-review` | 风险优先、断言质量、Mutation | 风险排序与测试质量反查 |
| 多个 `chaos-engineering` Skill | 稳态、Blast Radius、停止条件、故障落地和恢复 | 安全边界与受控故障注入 |
| `shenli/distributed-system-testing` | 声明驱动、历史/Checker、多状态结论、责任归因 | 主工作流、verdict 与落地证据 |
| Trail of Bits 等 Fuzzing Skills | Corpus、结构化变异、覆盖反馈、Artifact 最小化 | 工具适配器 |
| Android ADB Monkey 相关 Skill | UI 事件注入及其局限 | Monkey 仅作为执行器 |

完整研究过程中的来源清单包含 18 份资料，其中 12 份保存了原始 Markdown，6 份保存了逐段阅读笔记。发布包不包含这些第三方原文，只包含重新组织后的方法和来源说明。

## 改编原则

- 从工具导向改为声明导向；
- 把 Fuzz、Monkey、Chaos 降级为执行适配器；
- 统一使用 Oracle、扰动落地证据、复现路径和多状态结论；
- 不绑定语言、平台或固定测试框架；
- 不直接复制第三方示例和大段表述。

## 许可

参考资料中包含 CC BY-SA 4.0 内容。本 Skill 采用 `CC-BY-SA-4.0`，完整文本位于根目录 `LICENSE`。第三方项目仍保留各自原许可，本 Skill 的来源说明不替代原项目许可。
