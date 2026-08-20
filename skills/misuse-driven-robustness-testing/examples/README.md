# 示例说明

- `scenario-examples.md`：跨系统的思路讨论示例；
- `embedded-wifi-profile.json`：生成器输入；
- `embedded-wifi-generated-campaign.md`：由生成器得到的待填写骨架，严格校验应失败；
- `embedded-wifi-completed-campaign.md`：填写完成的示例，严格校验应通过。

验证：

```bash
python scripts/validate_campaign.py --strict \
  examples/embedded-wifi-completed-campaign.md
```

- `evidence-manifest.json`：完整示例使用的 Evidence manifest；
- `artifacts/`：用于演示 SHA-256 与 lineage 校验的最小本地证据。
