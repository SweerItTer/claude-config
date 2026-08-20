from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.validate_campaign import validate_text


def campaign(
    *,
    oracle: str = "检查状态、数据和资源不变量",
    oracle_status: str | None = None,
    assertion_total: int | str | None = None,
    assertion_failures: int | str | None = None,
    oracle_output: str | None = None,
    oracle_evidence: str = "EV-ORACLE",
    landing_status: str | None = None,
    hit_source: str | None = None,
    landing: str | None = None,
    landing_evidence: str = "EV-LANDING",
    verdict: str = "PASS-EVIDENCED",
    association: str = "C1",
    pre_state: str = "READY",
    seed_path: str = "start → stop",
    misuse: str = "重复 start",
    timeline: str = "T+0 start；T+1 start",
    invariant: str = "副作用只发生一次",
    repro_info: str = "build abc；history run.json",
    repro_path: str | None = None,
    safety_reason: str | None = None,
    alternative: str | None = None,
    blocked_reason: str | None = None,
    unblock: str | None = None,
    remaining: str | None = None,
    landing_attempt: str | None = None,
    unproven_reason: str | None = None,
    placeholder: bool = False,
    release_verdict: str | None = None,
    verified_claims: str | None = None,
    unverified_claims: str | None = None,
    release_risk: str | None = None,
    release_blockers: str | None = None,
    recovery_status: str | None = None,
    recovery_evidence: str | None = None,
    include_global_fields: bool = True,
    claims: str | None = None,
) -> str:
    value = "TODO" if placeholder else pre_state
    blocked_verdicts = {
        "BLOCKED-HARNESS",
        "BLOCKED-ENVIRONMENT",
        "NOT-RUN-SAFETY",
        "INCONCLUSIVE-FAULT-NOT-PROVEN",
        "NOT-RUN",
    }
    if oracle_status is None:
        if verdict == "PARTIAL-ORACLE":
            oracle_status = "PARTIAL"
        elif verdict in blocked_verdicts:
            oracle_status = "NOT-EXECUTED"
        else:
            oracle_status = "EXECUTED"
    if assertion_total is None:
        assertion_total = 0 if oracle_status == "NOT-EXECUTED" else 3
    if assertion_failures is None:
        assertion_failures = 1 if verdict.startswith("FAIL-") else 0
    if oracle_output is None:
        oracle_output = (
            "未执行"
            if oracle_status == "NOT-EXECUTED"
            else ("断言 2 失败：状态为 BROKEN" if verdict.startswith("FAIL-") else "3 项断言执行，全部通过")
        )
    if landing_status is None:
        if verdict == "INCONCLUSIVE-FAULT-NOT-PROVEN":
            landing_status = "NOT-PROVEN"
        elif verdict in blocked_verdicts:
            landing_status = "NOT-EXECUTED"
        else:
            landing_status = "PROVEN"
    if hit_source is None:
        hit_source = "目标端事件计数器 event_hit=1" if landing_status == "PROVEN" else "未执行"
    if landing is None:
        landing = "事件计数器从 0 增加到 1" if landing_status == "PROVEN" else "未执行"

    optional = []
    if repro_path is not None:
        optional.append(f"- 复现路径：{repro_path}")
    if safety_reason is not None:
        optional.append(f"- 安全阻塞原因：{safety_reason}")
    if alternative is not None:
        optional.append(f"- 替代执行方式：{alternative}")
    if blocked_reason is not None:
        optional.append(f"- 阻塞原因：{blocked_reason}")
    if unblock is not None:
        optional.append(f"- 解除条件：{unblock}")
    if remaining is not None:
        optional.append(f"- 剩余未验证：{remaining}")
    if landing_attempt is not None:
        optional.append(f"- 扰动落地尝试：{landing_attempt}")
    if unproven_reason is not None:
        optional.append(f"- 未证明原因：{unproven_reason}")

    if release_verdict is None:
        if verdict.startswith("FAIL-"):
            release_verdict = "FAIL"
        elif verdict in blocked_verdicts:
            release_verdict = "BLOCKED"
        elif verdict == "PARTIAL-ORACLE":
            release_verdict = "CONDITIONAL-PASS"
        else:
            release_verdict = "PASS"
    if verified_claims is None:
        verified_claims = "C1" if verdict == "PASS-EVIDENCED" else "无"
    if unverified_claims is None:
        unverified_claims = "无" if verdict == "PASS-EVIDENCED" else "C1"
    if release_risk is None:
        release_risk = "低概率调度差异继续长稳覆盖" if release_verdict == "PASS" else "C1 尚未完全验证"
    if release_blockers is None:
        release_blockers = "无" if release_verdict in {"PASS", "CONDITIONAL-PASS"} else "当前场景未通过"
    if recovery_status is None:
        recovery_status = "RESTORED" if release_verdict in {"PASS", "CONDITIONAL-PASS", "FAIL"} else "NOT-REQUIRED"
    if recovery_evidence is None:
        recovery_evidence = (
            "EV-RECOVERY"
            if recovery_status == "RESTORED"
            else "活动在修改目标前终止，前后资源快照一致"
        )

    if include_global_fields:
        safety = """- 环境隔离：专用测试环境
- 禁止操作：禁止生产数据和不可逆设备操作
- 自动停止条件：watchdog 超过 2 秒或资源增长超过阈值
- 恢复验证：重启模块并完成正常生命周期
- 证据数据级别：INTERNAL
- 最小采集范围：仅日志、状态快照和事件历史
- 脱敏方式：删除令牌并替换设备标识
- 访问与存放：测试组受控目录
- 保存与销毁：保存 30 天后销毁
- 导出复核：导出前扫描凭证和个人数据"""
        release = f"""- 已验证声明：{verified_claims}
- 未验证声明：{unverified_claims}
- 剩余风险：{release_risk}
- 阻塞项：{release_blockers}
- 环境恢复状态：{recovery_status}
- 环境恢复证据：{recovery_evidence}
- 发布结论：{release_verdict}"""
    else:
        safety = ""
        release = ""

    claim_rows = claims or "| C1 | repeat does not duplicate effects | 4 | 3 | 12 |"
    return f"""# Campaign

## 1. 声明与风险

| ID | 声明 | 影响 | 可能性 | 风险分 |
|---|---|---:|---:|---:|
{claim_rows}

## 2. 轻量行为模型

READY

## 3. 场景

### S01：demo

- 关联声明：{association}
- 前置状态：{value}
- 正常种子路径：{seed_path}
- 主要误用或故障：{misuse}
- 操作与时间线：{timeline}
- 期望不变量：{invariant}
- Oracle：{oracle}
- Oracle 执行状态：{oracle_status}
- Oracle 断言总数：{assertion_total}
- Oracle 失败数：{assertion_failures}
- Oracle 输出：{oracle_output}
- Oracle 证据：{oracle_evidence}
- 扰动命中状态：{landing_status}
- 命中观测来源：{hit_source}
- 扰动落地证据：{landing}
- 扰动命中证据：{landing_evidence}
- 恢复要求：继续 stop 后回到 READY
- 安全边界与停止条件：隔离环境，2 秒 watchdog
- 复现信息：{repro_info}
{chr(10).join(optional)}
- 结果：{verdict}

## 4. 安全与证据数据

{safety}

## 5. 结果与发布结论

{release}
"""


class ValidateCampaignTests(unittest.TestCase):
    def run_validator(self, text: str, *args: str) -> subprocess.CompletedProcess[str]:
        strict = "--strict" in args
        allow_placeholders = "--allow-placeholders" in args and not strict
        errors, warnings, scenario_count = validate_text(
            text, strict=strict, allow_placeholders=allow_placeholders,
            evidence_ids={"EV-ORACLE", "EV-LANDING", "EV-RECOVERY"},
        )
        lines = [*(f"WARN: {item}" for item in warnings), *(f"ERROR: {item}" for item in errors)]
        if errors:
            lines.append(f"FAIL: {len(errors)} error(s), {len(warnings)} warning(s)")
            return subprocess.CompletedProcess([], 1, "\n".join(lines) + "\n", "")
        lines.append(f"PASS: {scenario_count} scenario(s), {len(warnings)} warning(s)")
        return subprocess.CompletedProcess([], 0, "\n".join(lines) + "\n", "")

    def assert_fails(self, text: str, message: str | None = None) -> subprocess.CompletedProcess[str]:
        result = self.run_validator(text, "--strict")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        if message:
            self.assertIn(message, result.stdout)
        return result

    def test_valid_strict_campaign_passes(self) -> None:
        result = self.run_validator(campaign(), "--strict")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_full_campaign_inside_fenced_code_is_ignored(self) -> None:
        self.assert_fails("```markdown\n" + campaign() + "\n```", "missing level-2 section")

    def test_full_campaign_inside_html_comment_is_ignored(self) -> None:
        self.assert_fails("<!--\n" + campaign() + "\n-->", "missing level-2 section")

    def test_full_campaign_inside_blockquote_is_ignored(self) -> None:
        quoted = "\n".join("> " + line for line in campaign().splitlines())
        self.assert_fails(quoted, "missing level-2 section")

    def test_visible_campaign_with_hidden_example_still_passes(self) -> None:
        text = campaign() + "\n```markdown\n" + campaign() + "\n```\n<!--\n" + campaign() + "\n-->"
        result = self.run_validator(text, "--strict")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_duplicate_visible_sections_fail(self) -> None:
        text = campaign().replace("## 2. 轻量行为模型", "## 1.1 声明补充\n\n| ID | 声明 |\n|---|---|\n| C2 | x |\n\n## 2. 轻量行为模型")
        self.assert_fails(text, "duplicate level-2 sections for concept '声明'")

    def test_duplicate_safety_sections_fail(self) -> None:
        text = campaign().replace("## 5. 结果与发布结论", "## 4.1 安全补充\n\n- 环境隔离：x\n\n## 5. 结果与发布结论")
        self.assert_fails(text, "duplicate level-2 sections for concept '安全'")

    def test_duplicate_release_sections_fail(self) -> None:
        text = campaign() + "\n## 6. 发布结论补充\n\n- 发布结论：PASS\n"
        self.assert_fails(text, "duplicate level-2 sections for concept '结果/结论'")

    def test_indented_code_campaign_is_ignored(self) -> None:
        indented = "\n".join("    " + line for line in campaign().splitlines())
        self.assert_fails(indented, "missing level-2 section")

    def test_claim_substring_c1_does_not_match_c10(self) -> None:
        self.assert_fails(campaign(association="C10"), "unknown claim ID 'C10'")

    def test_unknown_claim_in_mixed_list_fails(self) -> None:
        self.assert_fails(campaign(association="C1, C999"), "unknown claim ID 'C999'")

    def test_unknown_release_claim_fails(self) -> None:
        self.assert_fails(campaign(verified_claims="C1, C999"), "unknown claim ID 'C999'")

    def test_duplicate_claim_reference_fails(self) -> None:
        self.assert_fails(campaign(association="C1, C1"), "duplicate claim reference 'C1'")

    def test_duplicate_claim_id_fails(self) -> None:
        rows = "| C1 | first | 4 | 3 | 12 |\n| C1 | conflict | 5 | 5 | 25 |"
        self.assert_fails(campaign(claims=rows), "duplicate claim ID 'C1'")

    def test_invalid_claim_id_fails(self) -> None:
        rows = "| 1-C | invalid | 4 | 3 | 12 |"
        self.assert_fails(campaign(claims=rows, association="1-C", verified_claims="1-C"), "invalid claim ID")

    def test_empty_claim_statement_fails(self) -> None:
        self.assert_fails(campaign(claims="| C1 |  | 4 | 3 | 12 |"), "empty or non-substantive statement")

    def test_claim_table_requires_id_and_statement_columns(self) -> None:
        text = campaign().replace("| ID | 声明 | 影响 | 可能性 | 风险分 |", "| Key | Description | 影响 | 可能性 | 风险分 |")
        self.assert_fails(text, "claim table must contain required columns")

    def test_null_like_values_cannot_form_pass_evidenced(self) -> None:
        for null_value in ("无", "N/A", "none", "不适用", "未执行", "-", "x", "Ｎ／Ａ"):
            with self.subTest(null_value=null_value):
                self.assert_fails(
                    campaign(
                        oracle=null_value,
                        oracle_output=null_value,
                        landing=null_value,
                        misuse=null_value,
                        timeline=null_value,
                        repro_info=null_value,
                        hit_source=null_value,
                    ),
                    "PASS-EVIDENCED requires",
                )

    def test_zero_width_character_does_not_bypass_null_detection(self) -> None:
        value = "无\u200b"
        self.assert_fails(campaign(oracle=value, oracle_output=value, landing=value, hit_source=value))

    def test_negative_evidence_sentences_cannot_form_pass(self) -> None:
        self.assert_fails(
            campaign(
                oracle="没有定义可执行检查",
                oracle_output="没有采集到任何输出",
                landing="未能证明扰动命中目标",
                hit_source="没有记录目标端观测",
                misuse="没有实际执行误用",
                timeline="没有记录操作时间线",
                repro_info="复现信息缺失",
            ),
            "does not contain affirmative evidence",
        )

    def test_weak_oracle_synonym_fails_strict(self) -> None:
        self.assert_fails(campaign(oracle="不发生崩溃"), "only checks process survival")

    def test_pass_requires_executed_oracle(self) -> None:
        self.assert_fails(campaign(oracle_status="NOT-EXECUTED", assertion_total=0), "Oracle执行状态=EXECUTED")

    def test_pass_requires_positive_assertion_count(self) -> None:
        self.assert_fails(campaign(assertion_total=0), "Oracle断言总数 >= 1")

    def test_pass_requires_zero_failed_assertions(self) -> None:
        self.assert_fails(campaign(assertion_failures=1), "Oracle失败数 = 0")

    def test_pass_requires_proven_landing(self) -> None:
        self.assert_fails(campaign(landing_status="NOT-PROVEN"), "扰动命中状态=PROVEN")

    def test_failure_count_cannot_exceed_total(self) -> None:
        self.assert_fails(campaign(assertion_total=1, assertion_failures=2), "cannot exceed")

    def test_todo_is_warning_in_draft_and_error_in_strict(self) -> None:
        draft = self.run_validator(campaign(placeholder=True))
        strict = self.run_validator(campaign(placeholder=True), "--strict")
        self.assertEqual(draft.returncode, 0)
        self.assertIn("WARN:", draft.stdout)
        self.assertEqual(strict.returncode, 1)

    def test_fail_reproducible_requires_path(self) -> None:
        self.assert_fails(campaign(verdict="FAIL-REPRODUCIBLE"), "requires a reproduction path")

    def test_fail_reproducible_accepts_path(self) -> None:
        result = self.run_validator(campaign(verdict="FAIL-REPRODUCIBLE", repro_path="repro-S01.md"), "--strict")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_fail_requires_failed_assertion(self) -> None:
        self.assert_fails(campaign(verdict="FAIL-REPRODUCIBLE", repro_path="repro.md", assertion_failures=0), "Oracle失败数 >= 1")

    def test_not_run_safety_requires_reason_and_alternative(self) -> None:
        self.assert_fails(campaign(verdict="NOT-RUN-SAFETY", safety_reason="没有破坏授权"), "safety reason and a safer alternative")

    def test_not_run_safety_accepts_structured_not_executed(self) -> None:
        result = self.run_validator(
            campaign(
                verdict="NOT-RUN-SAFETY",
                safety_reason="没有生产破坏授权和回滚环境",
                alternative="在脱敏副本和隔离仿真环境执行",
            ),
            "--strict",
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_blocked_requires_reason_and_unblock_condition(self) -> None:
        self.assert_fails(
            campaign(verdict="BLOCKED-HARNESS", blocked_reason="注入器无法观察 namespace"),
            "blocking reason and unblock condition",
        )

    def test_blocked_accepts_structured_not_executed(self) -> None:
        result = self.run_validator(
            campaign(
                verdict="BLOCKED-ENVIRONMENT",
                blocked_reason="测试板驱动缺少故障注入接口",
                unblock="提供带注入点的测试固件后重跑",
            ),
            "--strict",
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_inconclusive_requires_attempt_and_reason_separately(self) -> None:
        self.assert_fails(
            campaign(
                verdict="INCONCLUSIVE-FAULT-NOT-PROVEN",
                landing_attempt="安装网络规则并读取计数器",
            ),
            "requires both attempted landing proof and why it failed",
        )

    def test_inconclusive_accepts_attempt_and_reason(self) -> None:
        result = self.run_validator(
            campaign(
                verdict="INCONCLUSIVE-FAULT-NOT-PROVEN",
                landing_attempt="安装网络规则并读取目标端计数器三次",
                unproven_reason="计数器始终为 0，无法确认测试流量经过该规则",
                hit_source="目标端规则计数器",
                landing="规则已安装但目标端计数器保持 0",
            ),
            "--strict",
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_partial_oracle_requires_remaining_scope(self) -> None:
        self.assert_fails(campaign(verdict="PARTIAL-ORACLE"), "requires the unverified part")

    def test_partial_oracle_passes_with_remaining_scope(self) -> None:
        result = self.run_validator(campaign(verdict="PARTIAL-ORACLE", remaining="持久化恢复尚未验证"), "--strict")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_illegal_verdict_fails(self) -> None:
        self.assert_fails(campaign(verdict="PASS"), "illegal result status")

    def test_not_run_is_rejected_by_strict_gate(self) -> None:
        self.assert_fails(campaign(verdict="NOT-RUN"), "NOT-RUN is not allowed")

    def test_empty_global_sections_fail_strict(self) -> None:
        result = self.assert_fails(campaign(include_global_fields=False))
        self.assertIn("安全与证据数据: missing field", result.stdout)
        self.assertIn("结果与发布结论: missing field", result.stdout)

    def test_release_pass_conflicts_with_failure(self) -> None:
        self.assert_fails(
            campaign(
                verdict="FAIL-REPRODUCIBLE",
                repro_path="repro.md",
                release_verdict="PASS",
                verified_claims="C1",
                unverified_claims="无",
                release_blockers="无",
            ),
            "PASS conflicts",
        )

    def test_release_pass_requires_all_claims_verified(self) -> None:
        rows = "| C1 | first | 4 | 3 | 12 |\n| C2 | second | 5 | 3 | 15 |"
        self.assert_fails(campaign(claims=rows), "must cover every declared claim")

    def test_conditional_pass_cannot_hide_partial_claim(self) -> None:
        self.assert_fails(
            campaign(
                verdict="PARTIAL-ORACLE",
                remaining="数据完整性尚未验证",
                verified_claims="无",
                unverified_claims="无",
            ),
            "must cover every declared claim",
        )

    def test_blocked_release_cannot_hide_not_run_claim(self) -> None:
        self.assert_fails(
            campaign(
                verdict="NOT-RUN-SAFETY",
                safety_reason="没有生产授权",
                alternative="隔离环境重跑",
                verified_claims="无",
                unverified_claims="无",
            ),
            "must cover every declared claim",
        )

    def test_verified_claim_requires_all_associated_scenarios_to_pass(self) -> None:
        second = campaign(verdict="PARTIAL-ORACLE", remaining="恢复未验证", release_verdict="CONDITIONAL-PASS")
        scenario_block = second.split("### S01：demo", 1)[1].split("## 4. 安全与证据数据", 1)[0]
        text = campaign(release_verdict="CONDITIONAL-PASS", verified_claims="C1", unverified_claims="无")
        text = text.replace("## 4. 安全与证据数据", "### S02：partial\n" + scenario_block + "\n## 4. 安全与证据数据")
        self.assert_fails(text, "must exactly match claims whose associated scenarios are all PASS-EVIDENCED")

    def test_pass_rejects_failed_environment_recovery(self) -> None:
        self.assert_fails(
            campaign(recovery_status="FAILED", recovery_evidence="残留线程和测试数据仍未清理"),
            "PASS requires 环境恢复状态=RESTORED",
        )

    def test_pass_rejects_partial_environment_recovery(self) -> None:
        self.assert_fails(
            campaign(recovery_status="PARTIAL", recovery_evidence="线程已清理但测试数据仍残留"),
            "PASS requires 环境恢复状态=RESTORED",
        )

    def test_invalid_recovery_status_fails(self) -> None:
        self.assert_fails(campaign(recovery_status="SUCCESS"), "illegal environment recovery status")

    def test_recovery_evidence_must_be_affirmative(self) -> None:
        self.assert_fails(campaign(recovery_evidence="没有执行恢复检查"), "affirmative check")

    def test_conditional_pass_rejects_not_run_safety(self) -> None:
        self.assert_fails(
            campaign(
                verdict="NOT-RUN-SAFETY",
                safety_reason="没有共享测试环境的主动扰动授权",
                alternative="仅在本地仿真环境生成离线用例",
                release_verdict="CONDITIONAL-PASS",
                verified_claims="无",
                unverified_claims="C1",
                release_blockers="缺少授权",
            ),
            "CONDITIONAL-PASS conflicts",
        )

    def test_conditional_pass_rejects_inconclusive_fault_not_proven(self) -> None:
        self.assert_fails(
            campaign(
                verdict="INCONCLUSIVE-FAULT-NOT-PROVEN",
                landing_attempt="安装规则并检查目标端命中计数",
                unproven_reason="计数始终为 0，无法证明扰动经过目标路径",
                release_verdict="CONDITIONAL-PASS",
                verified_claims="无",
                unverified_claims="C1",
                release_blockers="扰动未证明",
            ),
            "CONDITIONAL-PASS conflicts",
        )

    def test_claim_statement_with_escaped_pipe_is_not_truncated(self) -> None:
        rows = r"| C1 | lhs \| rhs remains one statement | 4 | 3 | 12 |"
        result = self.run_validator(campaign(claims=rows), "--strict")
        self.assertEqual(result.returncode, 0, result.stdout)



if __name__ == "__main__":
    unittest.main()
