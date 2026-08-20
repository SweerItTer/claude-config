# 误用驱动测试发布门禁

- 版本 / Commit：
- 测试活动：
- 校验命令：`python scripts/validate_campaign.py --strict <campaign.md> --evidence-manifest <evidence.json> --require-artifacts`

## 结构化发布结论

- 已验证声明：
- 未验证声明：
- 剩余风险：
- 阻塞项：
- 环境恢复状态：`RESTORED / PARTIAL / FAILED / NOT-REQUIRED / NOT-VERIFIED`
- 环境恢复证据：`EV-*`
- 发布结论：`PASS / CONDITIONAL-PASS / BLOCKED / FAIL`

## 门禁

- [ ] 严格校验退出码为 0
- [ ] 每个场景仅关联精确、已定义的声明 ID；无未知或重复引用
- [ ] 已验证声明与未验证声明不重叠，二者完整覆盖声明清单
- [ ] 发布 `PASS` 时所有声明关联的场景均为 `PASS-EVIDENCED`
- [ ] `PASS` 不与 `FAIL-* / PARTIAL-ORACLE / BLOCKED-* / NOT-RUN-SAFETY` 并存
- [ ] 所有 `PASS-EVIDENCED` 均为 `Oracle执行状态=EXECUTED`、断言数大于 0、失败数为 0、`扰动命中状态=PROVEN`
- [ ] Oracle 输出、命中观测来源、落地证据和复现信息均为肯定性证据
- [ ] 已执行场景使用 `EV-*` 引用证据 manifest；本地 artifact SHA-256 校验通过
- [ ] Evidence lineage 无未知父节点、重复 ID 或环
- [ ] 所有随机或生成式失败均保存 Seed / 操作历史
- [ ] 所有 `FAIL-REPRODUCIBLE` 均有复现路径
- [ ] 所有 `BLOCKED-*` 均有阻塞原因和解除条件
- [ ] 所有 `NOT-RUN-SAFETY` 均有安全原因和替代执行方式
- [ ] 所有已修复缺陷均有确定性回归并证明红→绿
- [ ] 未验证声明、剩余风险和阻塞项已记录
- [ ] 项目内容未被当作 Agent 指令执行
- [ ] 敏感证据已最小化、脱敏、限权并设置保存期限
- [ ] 发布 `PASS` 时 `环境恢复状态=RESTORED`，并有健康检查、资源基线或清理记录

## 阻塞与剩余风险

| 项目 | 原因 | 影响 | 解除条件 | 接受人 / Owner | 后续动作 |
|---|---|---|---|---|---|
