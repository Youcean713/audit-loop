# 风险评分与资产分类

> 本文件由 SKILL.md（Step 0 资产分类、门控裁决）和 round-details.md（合并审查官风险评分）引用。
> 公式基于 ForgeAI 加权复合评分模式 + EPSS 利用概率 + CVSS 4.0。

---

## 一、复合风险评分公式

```
risk_score = (severity_weight × 3) + (exposure × 2) + (asset_criticality × 2)

评分范围: 7-70（最小值: severity_weight=1 × 3 + exposure=1 × 2 + asset_criticality=1 × 2 = 7）
  severity_weight:  C=10, H=7, M=4, S=1
  exposure:         internet-facing=10, internal-api=7, authenticated=4, internal-only=1
  asset_criticality: pci=10, pii=10, phi=10, auth=7, admin=7, api=5, config=5, biz=3, docs=1
```

**归一化为 0-100**（用于管理报告）：
```
normalized_risk = round(risk_score / 70 * 100)
```

**风险等级**：

| 归一化分 | 等级 | 含义 |
|---------|------|------|
| 80-100 | **严重** | 需立即修复，建议 BLOCK |
| 50-79 | **高** | 本迭代必须修复 |
| 20-49 | **中** | 下一迭代修复 |
| 0-19 | **低** | 持续观察 |

---

## 二、EPSS 利用概率集成

> ⚠️ **隐私注意**: EPSS API 查询会将审计目标的 CVE ID 发送到 api.first.org。企业环境使用前需评估数据泄露风险，或在隔离网络环境中禁用此功能。

**集成点**：若 issue 的 `cwe_id` 和上下文可映射到已知 CVE，编排者可选查询 EPSS API：
```
GET https://api.first.org/data/v1/epss?cve=CVE-YYYY-NNNNN
```

**EPSS 阈值规则**：
| EPSS 百分位 | 动作 |
|------------|------|
| > 0.7 | 自动升一级严重度（M→H, H→C） |
| 0.3-0.7 | 保持原严重度，标注 `epss_elevated: true` |
| < 0.3 | 保持原严重度 |

**CISA KEV 检查**：若 CVE 在 KEV 目录中 → 无视其他评分，自动 BLOCK。

> 注意：EPSS/KEV 查询需要外部 API 访问。若不可用，跳过此步骤并在审计健康度中标注"EPSS 不可用——风险评分基于 CVSS only"。

---

## 三、资产分类规则

Step 0 自动扫描文件路径，按以下模式分类：

### 3.1 分类模式

| 分类 | 路径模式（不区分大小写） | criticality | 审计强度 |
|------|------------------------|-------------|---------|
| **PCI** | `payment`, `billing`, `charge`, `card`, `transaction`, `pos` | 10 | L3（最高） |
| **PII** | `user`, `profile`, `email`, `phone`, `ssn`, `passport`, `dob`, `address`, `citizen` | 10 | L3 |
| **PHI** | `patient`, `health`, `medical`, `diagnosis`, `prescription`, `clinical`, `hipaa` | 10 | L3 |
| **AUTH** | `auth`, `login`, `session`, `token`, `jwt`, `oauth`, `sso`, `password`, `credential` | 7 | L2 |
| **ADMIN** | `admin`, `root`, `super`, `sudo`, `dashboard`, `manage` | 7 | L2 |
| **API** | `api`, `graphql`, `rest`, `grpc`, `webhook`, `endpoint` | 5 | L2 |
| **CONFIG** | `config`, `settings`, `secret`, `env`, `dockerfile`, `terraform`, `k8s`, `deploy` | 5 | L1 |
| **BIZ** | `service`, `handler`, `controller`, `model`, `repository`, `domain` | 3 | L1 |
| **DOC** | `readme`, `doc`, `wiki`, `guide`, `changelog`, `spec` | 1 | L1 |

### 3.2 审计强度含义

| 强度 | 含义 |
|------|------|
| **L3** | 所有 4 透镜必须深度覆盖该文件。若安全透镜标记该文件为 out-of-scope → 视为审计失败 |
| **L2** | 所有 4 透镜应覆盖该文件。out-of-scope 需有合理说明 |
| **L1** | 标准覆盖。out-of-scope 允许 |

### 3.3 实现

编排者 Step 0 执行：
1. Glob 扫描所有文件路径
2. 对每个路径匹配分类模式（首个匹配生效）
3. 生成 `asset-inventory.json`：

```json
{
  "instance_id": "audit-20260702-143052-a3f2",
  "classified_at": "2026-07-02T14:30:52Z",
  "assets": [
    {"path": "src/auth/login.ts", "classification": "AUTH", "criticality": 7, "audit_intensity": "L2"},
    {"path": "src/payment/charge.py", "classification": "PCI", "criticality": 10, "audit_intensity": "L3"},
    {"path": "README.md", "classification": "DOC", "criticality": 1, "audit_intensity": "L1"}
  ],
  "summary": {"PCI": 2, "PII": 5, "AUTH": 3, "CONFIG": 8, "BIZ": 20, "DOC": 10}
}
```

4. 将 `asset-inventory.json` 作为所有透镜 Agent prompt 的输入上下文

---

## 四、Exposure（暴露度）判定

编排者在 Step 0 或 Agent 在审计时判定：

| 暴露度 | 条件 | 分值 |
|--------|------|------|
| **internet-facing** | 端点暴露在公网、API 无认证、CDN 直通 | 10 |
| **internal-api** | 内部服务间 API、需服务账户认证 | 7 |
| **authenticated** | 需用户认证后访问 | 4 |
| **internal-only** | 仅内网访问、VPN 后访问 | 1 |

若无法确定 → 默认保守估计 `internal-api (7)`。

---

## 五、合并审查官风险评分指令

合并审查官（或简单审计的编排者去重阶段）对每个 issue 计算 `risk_score`：

```
1. 从 issue severity 获取 severity_weight (C=10, H=7, M=4, S=1)
2. 从 asset-inventory.json 查找该文件 classification → asset_criticality
3. 从审计上下文判断 exposure (保守默认 7)
4. risk_score = (severity_weight × 3) + (exposure × 2) + (asset_criticality × 2)
5. 填入 issue 的 risk_score 字段
6. 在 checklist JSON 中按 risk_score 降序排列 issues
```

---

## 六、SLA 矩阵

基于风险分和门控裁决自动计算修复截止时间：

| 门控裁决 | 风险分 | SLA | 动作 |
|---------|--------|-----|------|
| BLOCK | any | 24 小时 | 立即修复，阻断流水线 |
| HOLD | ≥ 50 | 72 小时 | 本迭代修复 |
| HOLD | < 50 | 7 天 | 下一迭代修复 |
| CAUTION | ≥ 30 | 30 天 | 计划修复 |
| CAUTION | < 30 | 90 天 | backlog |
| SHIP | any | — | 无需修复 |
