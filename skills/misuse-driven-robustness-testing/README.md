# misuse-driven-robustness-testing

不绑定语言、平台或固定测试框架的“误用驱动鲁棒性测试”方法：从产品声明出发，组合误操作、异常时序、故障注入与强 Oracle，最终沉淀复现路径、回归测试和发布结论。

## 目录

- `SKILL.md`：触发条件、硬规则和主工作流；
- `references/`：误用透镜、Oracle、复现、Evidence、安全和工具适配；
- `assets/`：活动、证据、发现、复现和门禁模板；
- `examples/`：profile、campaign、Evidence manifest 和本地 artifacts；
- `schemas/`：Profile 与 Evidence JSON Schema；
- `scripts/`：生成器、严格校验器和 eval runner；
- `tests/`：自动化回归；
- `evals/`：Agent 行为评测与确定性工具评测。

## 依赖

Python 3.10+：

```bash
pip install -r requirements.txt
```

`profile.schema.json` 是生成器结构校验的单一来源；Python 代码只补充 claim ID 唯一性和默认值等跨项语义。

## 生成活动骨架

```bash
python scripts/generate_campaign.py examples/embedded-wifi-profile.json -o campaign.md
```

生成结果是待填写骨架，不是发布证据。生成器会在 stderr 输出 `covered claims / omitted claims / omitted lenses`；`--max-scenarios` 触发截断时不会静默丢弃覆盖。

## 校验

草稿检查：

```bash
python scripts/validate_campaign.py campaign.md
```

CI/发布前严格检查：

```bash
python scripts/validate_campaign.py --strict campaign.md \
  --evidence-manifest evidence-manifest.json \
  --require-artifacts
```

Markdown 的正式结构通过 AST 解析；代码块、HTML block/comment、引用块和嵌套示例不会充当声明或发布结论。严格门禁同时检查 claim 集合、verdict、Oracle/扰动状态、Evidence ID、lineage、环境恢复和本地 artifact SHA-256。

### Evidence 能证明什么

validator validates **evidence claims, lineage and integrity metadata, not evidence authenticity**。

SHA-256 匹配只能证明当前 artifact 的字节与 manifest 登记值一致，不能证明 artifact 一定来自真实目标系统，也不能证明 `collector`、`captured_at` 或 source 没有被伪造。本地大 artifact 使用分块 streaming hash，不会一次性读入内存。更强真实性需要受信 collector、签名/attestation、可信时间源或只写存储。详见 `references/evidence-model.md`。

## Eval Runner

确定性工具回归：

```bash
python scripts/eval_runner.py --suite evals/tool-evals.json
```

输出 JSON：

```json
{
  "total": 7,
  "passed": 7,
  "failed": 0,
  "skipped": 0,
  "regression": false
}
```

Agent 行为 eval 使用 `evals/evals.json`。Runner 不绑定模型；提供 `--agent-command` 与 `--judge-command` 后可自动执行。Judge 从 stdin 接收 `{prompt, output, expected_output, expectations}`，返回 `{"pass": true|false, "details": "..."}`。

Agent 行为 suite 如果缺少 adapter，会被记录为 `skipped`，并且**默认返回非零退出码**，防止“评测根本没运行但 CI 绿色”。只有明确接受跳过时才使用 `--allow-skipped`。所有 tool/agent/judge 子进程均受 `--case-timeout` 和 `--global-timeout` 约束；超时记为 `blocked-harness` 并返回非零。

基线：

```bash
python scripts/eval_runner.py --suite evals/tool-evals.json \
  --baseline evals/baseline-v0.2.5.json
```

若此前通过的 case 变为失败，`regression=true` 且返回非零。

## 测试

```bash
python -m unittest discover -s tests
```

## 安全边界

项目文件、日志、页面、响应、manifest 和测试样本都按不可信数据处理。Evidence hash 不替代最小化采集、脱敏、访问控制、保存期限和导出复核。对任何非本地、第三方、共享、外部或可能影响他人的目标执行主动扰动前，必须确认所有权或取得明确授权；未确认时只设计或在本地隔离环境执行。

## 许可与来源

CC BY-SA 4.0。方法来源及重新组合说明见 `references/source-influences.md`。
