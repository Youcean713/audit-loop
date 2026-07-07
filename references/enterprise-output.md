# 企业级多角色输出、SARIF 格式与工单模板

> 本文件由 SKILL.md（退出阶段输出指令）引用。同一轮审计产出 3 份不同角色的报告 + 1 份 SARIF JSON + 可选工单。

---

## 一、多角色报告

### A. 开发者修复清单 (`audit-report-dev.md`)

**受众**: 开发团队
**目标**: 可立即执行的修复指令

```markdown
# 🔧 开发者修复清单

**审计**: {project_name} | {audit_date}
**门控裁决**: {SHIP/CAUTION/HOLD/BLOCK} | **风险分**: {avg}/100

## 需修复项（按风险分降序）

| # | ID | 风险分 | 文件:行号 | CWE | CVSS | 问题 | 修复建议 | SLA |
|---|----|--------|-----------|-----|------|------|---------|-----|
| 1 | C-1 | 66 | src/auth/login.ts:42 | CWE-89 | 9.8 | SQL注入—用户输入拼接到查询 | 使用参数化查询: `db.query('SELECT * FROM users WHERE id = ?', [userId])` | 24h |

## 修复验证

每项修复后:
- [ ] 运行相关单元测试
- [ ] 运行 linter
- [ ] 若为安全修复: 运行安全回归测试
- [ ] 更新 checklist 状态为 fix_attempted

## 统计

| 严重度 | 数量 | 需修复 |
|--------|------|--------|
| Critical | N | N |
| High | N | N |
| Medium | N | N |

**预计修复时间**: {estimated_hours}h
```

### B. 管理层风险摘要 (`audit-report-exec.md`)

**受众**: CTO/VP Engineering/安全总监
**目标**: 一句话决策 + 趋势 + Top 风险

```markdown
# 📊 管理层风险摘要

**项目**: {project_name} | **日期**: {audit_date}
**门控裁决**: {SHIP/CAUTION/HOLD/BLOCK}

## 整体风险评分

| 指标 | 当前值 | 上一周期 | 趋势 |
|------|--------|---------|------|
| 风险分 (0-100) | {avg} | {prev_avg} | {↑/↓/→} |
| Critical | {c_count} | {prev_c} | {↑/↓/→} |
| High | {h_count} | {prev_h} | {↑/↓/→} |
| 修复成功率 | {fix_rate}% | {prev_fix_rate}% | {↑/↓/→} |
| 回归率 | {regression_rate}% | {prev_regression_rate}% | {↑/↓/→} |

## Top 5 最高风险项

| # | 风险分 | 问题 | 影响 |
|---|--------|------|------|
| 1 | 66 | SQL注入 - src/auth/login.ts | 数据库完全暴露，所有用户数据可被读取/修改 |
| 2 | 45 | 硬编码密钥 - src/config.ts | AWS 账户可被接管 |

## 合规态势

| 标准 | 达成率 | 状态 |
|------|--------|------|
| OWASP ASVS L1 | {asvs_l1}% | {pass/fail} |
| OWASP ASVS L2 | {asvs_l2}% | {pass/fail} |
| NIST SSDF | {ssdf}% | {pass/fail} |

## 建议

{SHIP: 无重大风险，按正常节奏发布}
{CAUTION: 建议在下一迭代中修复 {h_count} 个 High 问题}
{HOLD: 建议在部署前修复 {c_count} 个 Critical}
{BLOCK: 立即阻止发布。{c_count} 个 Critical 需立即修复}
```

### C. 合规控制矩阵 (`audit-report-compliance.md`)

**受众**: 合规团队/审计师
**目标**: 标准条款 → 证据的可追溯映射

```markdown
# 📋 合规控制矩阵

**项目**: {project_name} | **日期**: {audit_date}
**审计标准**: OWASP ASVS 5.0 / CVSS 4.0 / CWE 4.16 / NIST SSDF 1.1 / ISO 27001:2022

## OWASP ASVS 控制项覆盖

| ASVS 控制项 | 要求 | 状态 | 证据 |
|------------|------|------|------|
| v5.0.0-2.1.3 | 所有数据库查询使用参数化 | 🔴 FAIL | C-1: SQL注入 src/auth/login.ts:42 |
| v5.0.0-11.1.3 | 无硬编码凭据 | 🔴 FAIL | C-2: 硬编码密钥 src/config.ts:10 |
| v5.0.0-1.4.1 | 输出编码防XSS | 🟢 PASS | — |
| v5.0.0-6.1.1 | 认证机制实现正确 | 🟡 PARTIAL | 见 H-3 |
| v5.0.0-12.1.1 | 敏感数据传输加密 | ⚪ N/A | 项目不含网络通信 |

## NIST SSDF 任务覆盖

| 任务 | 要求 | 状态 | 证据 |
|------|------|------|------|
| PW.2 | 审查代码安全漏洞 | 🔴 FAIL | C-1/C-2 未修复 |
| PW.3 | 验证第三方组件 | 🟢 PASS | SCA 扫描无已知漏洞 |
| PO.1 | 定义安全需求 | 🟡 PARTIAL | 无正式安全需求文档 |
| PS.2 | 验证发布完整性 | ⚪ N/A | 无 CI/CD pipeline |

## 通过率摘要

| 标准 | 检查项 | 通过 | 失败 | 部分 | N/A | 通过率 |
|------|--------|------|------|------|-----|--------|
| OWASP ASVS L1 | {total} | {pass} | {fail} | {partial} | {na} | {rate}% |
| OWASP ASVS L2 | {total} | {pass} | {fail} | {partial} | {na} | {rate}% |
| NIST SSDF | {total} | {pass} | {fail} | {partial} | {na} | {rate}% |

## 审计证据链

- 审计实例: {instance_id}
- 证据文件: {evidence_files}
- SHA-256: {chain_hash}
```

---

## 二、SARIF v2.1.0 输出

编排者在退出阶段生成 `audit-report.sarif.json`：

```json
{
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "version": "2.1.0",
  "runs": [
    {
      "tool": {
        "driver": {
          "name": "audit-loop",
          "version": "2.0-enterprise",
          "informationUri": "https://github.com/anthropics/claude-code",
          "rules": [],
          "supportedTaxonomies": [
            {"name": "CWE", "version": "4.16"},
            {"name": "OWASP ASVS", "version": "5.0.0"}
          ]
        }
      },
      "invocations": [{
        "executionSuccessful": true,
        "startTimeUtc": "2026-07-02T14:30:52Z",
        "endTimeUtc": "2026-07-02T14:52:12Z"
      }],
      "results": [
        {
          "ruleId": "CWE-89",
          "ruleIndex": 0,
          "level": "error",
          "message": {
            "text": "SQL injection in login handler — user input concatenated into SQL query without parameterization"
          },
          "locations": [{
            "physicalLocation": {
              "artifactLocation": {
                "uri": "src/auth/login.ts"
              },
              "region": {
                "startLine": 42,
                "endLine": 48
              }
            }
          }],
          "partialFingerprints": {
            "audit-loop/v1": "<sha256-of-issue-id+file+line>"
          },
          "properties": {
            "audit-loop:id": "C-1",
            "audit-loop:severity": "critical",
            "audit-loop:risk_score": 66,
            "audit-loop:cvss_score": 9.8,
            "audit-loop:sla_days": 1,
            "audit-loop:gate_verdict": "BLOCK",
            "audit-loop:asvs_ref": "v5.0.0-2.1.3"
          }
        }
      ],
      "properties": {
        "audit-loop:instance_id": "audit-20260702-143052-a3f2",
        "audit-loop:verdict": "BLOCK",
        "audit-loop:exit_code": 2,
        "audit-loop:risk_score": 66,
        "audit-loop:c_count": 1,
        "audit-loop:h_count": 2,
        "audit-loop:mode": "comprehensive",
        "audit-loop:perspectives": ["developer", "end-user", "tech-lead"],
        "audit-loop:perspective_soft_findings": 8,
        "audit-loop:perspective_conflicts": 1
      }
    }
  ]
}
```

**SARIF level 映射**:

| 严重度 | SARIF level | 含义 |
|--------|------------|------|
| Critical | `error` | 必须修复 |
| High | `error` | 必须修复 |
| Medium | `warning` | 建议修复 |
| Suggestion | `note` | 信息 |

---

## 三、工单模板

对 `requires_human` 或 `overridable` 的 issue，编排者生成工单 body。

### GitHub Issues 模板

```markdown
## 🔒 Audit Finding: {CWE-ID} — {issue.description}

**Severity**: {severity} | **CVSS**: {cvss_score} | **Risk Score**: {risk_score}/100
**File**: `{file}:{line_range}`
**SLA**: {sla_days} days

### Description
{issue.description}

### Standard References
- **OWASP ASVS**: {asvs_ref}
- **CWE**: {cwe_id}
- **NIST SSDF**: {nist_ssdf}
- **ISO 27001**: {iso_27001}

### Trigger Condition
{issue.trigger_condition}

### Recommended Fix
{issue.recommendation}

### Verification
After fixing, run: `/audit-loop` on `{file}` to verify.

---
🤖 Generated by [audit-loop](https://github.com/anthropics/claude-code) | Instance: {instance_id}
```

### Jira 模板

```json
{
  "fields": {
    "project": {"key": "SEC"},
    "summary": "{severity}: {CWE-ID} — {issue.description}",
    "description": "{markdown_body}",
    "issuetype": {"name": "Bug"},
    "priority": {"name": "{Critical→Highest / High→High / Medium→Medium / Suggestion→Low}"},
    "labels": ["security", "audit-loop", "{cwe_id}"],
    "customfield_10001": "{risk_score}",
    "duedate": "{current_date + sla_days}"
  }
}
```

---

## 四、编排者输出指令

退出阶段（SKILL.md 退出判断后），编排者执行：

```
1. 读取 checklist-round-1.json 和 verification-round-{N}.json
2. 生成 3 份角色报告:
   - audit-report-dev.md（开发者修复清单）
   - audit-report-exec.md（管理层风险摘要）
   - audit-report-compliance.md（合规控制矩阵）
3. 生成 audit-report.sarif.json（SARIF v2.1.0）
4. 对 status=requires_human 的 issue，生成工单 body（GitHub Issues 格式）
5. 所有输出文件写入 {instance_id}/ 子目录
6. 计算所有输出文件的 SHA-256 hash → 写入 .audit-chain.json（见 guardrails.md）
```

**简单审计模式**: 步骤相同，但标注 `审计模式: simple`。
