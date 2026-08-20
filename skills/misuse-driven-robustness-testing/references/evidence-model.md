# Evidence Manifest 与证据链

Campaign 中只写简短的人类可读摘要，并用 `EV-*` 引用外部证据。证据元数据集中放在 `evidence-manifest.json`，避免把日志、Core、Trace 或大段输出塞进 Markdown。

## 最小模型

每条证据至少登记：

- `id`：稳定的 `EV-*` 标识；
- `type`：Oracle 输出、扰动落地、复现、恢复等；
- `artifact`：相对路径或外部 URI；
- `sha256`：登记时 artifact 的 SHA-256；
- `captured_at`：带时区的 RFC 3339 时间；
- `collector`：采集者或采集器标识；
- `source`：目标系统、接口、计数器或观测点；
- `parents`：派生证据的父证据 ID，形成 lineage；
- `sensitivity`：证据数据级别。

完整结构见 `schemas/evidence.schema.json`，空白样例见 `assets/evidence-manifest-template.json`。

## 信任边界

校验器可以证明：

1. manifest 符合 Schema；
2. Evidence ID 唯一、引用存在、lineage 无环；
3. 本地 artifact 当前字节的 SHA-256 与 manifest 一致；
4. Campaign 声明的证据引用确实指向 manifest 条目。

校验器**不能证明**：

- artifact 确实来自目标系统；
- `collector` 身份真实；
- `captured_at` 没有被伪造；
- 文件在登记之前没有被修改；
- 外部 URI 当前内容等于登记哈希。

因此：**validator validates evidence claims, lineage and integrity metadata, not evidence authenticity.**

若需要更强真实性，应在 CI/实验室侧增加受信 collector、签名/attestation、只写存储、可信时间源或透明日志。

## 本地 Artifact 规则

相对路径以 manifest 所在目录为根。校验器拒绝路径逃逸。`--require-artifacts` 会要求所有被引用 artifact 都能在本地读取并通过 SHA-256 校验；外部 URI 不能满足该模式，应先由受控步骤下载/固化。

## 证据最小化

Hash 与 lineage 不改变数据治理要求。只采集证明声明所需的最少数据；导出 manifest 或 artifact 前仍需执行敏感字段检查与脱敏。
