# Round 2/3: 收敛自适应验证 + 条件终裁 + 报告

> 本文件从 round-details.md 拆分而来（P2-1: 按阶段拆分优化 token 消耗）。
> 编排者在对应阶段 **立即 Read** 此文件。

---

## Round 2/3: 收敛自适应验证 + 条件终裁

> 🆕 收敛自适应策略: 根据收敛情况选择重审深度。核心洞察——**快收敛 = 审计可能浅 = 需深度重审；慢收敛 = 审计已找到真问题 = 专注修复**。
> 设计依据: 第二审计员效应（Second Auditor Effect）+ 变异测试哲学（Mutation Testing）。

### 前置检查

读取 `checklist-round-1.json`。如果 issues 中无 Critical 或 High → **不要直接 SHIP**——这属于 Case A（快收敛可疑），需触发全量重审验证。

### Step 1: 计算 blast-radius（脚本强制）

```
bash scripts/compute-blast-radius.sh <project_root> $INSTANCE_DIR <mode>
```
输出 `blast-radius.json`：变更文件 + import 调用链 + 配置文件清单。

### Step 2: Mode C 验证（所有 Case 必经）

```
Agent(model="sonnet",
  prompt="<从 agents/verifier.md 提取 Mode C prompt，{instance_dir} 已替换>")

阶段 A — Checklist 验证 (Mode C):
1. 读取 checklist-round-1.json，逐项验证每个 issue
2. 每项: verdict (resolved/persisting/regressed) + confidence + evidence
3. Blast-Radius 扫描: 读取 blast-radius.json 的 scan_files，做安全模式扫描
4. 输出 verification-round-2.json
```

### Step 3: 收敛分支判定

统计当前 C+H（含 persisting + blast-radius New）:

#### Case A: 总 C+H = 0（快收敛 — 可疑）🆕

> 触发独立全量重审 + 模型洗牌（第二审计员效应）。研究依据：审计发现少 ≠ 代码安全，可能只是审计浅。

```
对 4 个透镜维度，分别用与 Round 1 不同的模型 spawn verifier Agent (Mode A FULL_REAUDIT_SHUFFLED):

| 透镜维度 | Round 1 模型 | Case A 重审模型 | 第二审计员效果 |
|---------|:----------:|:-------------:|---------------|
| 安全 | fable | opus | 不同模型注入链盲区不同 |
| 架构 | sonnet | fable | 不同模型耦合分析角度不同 |
| 质量 | sonnet | opus | 不同模型一致性推理方式不同 |
| 性能 | haiku | sonnet | 不同模型效率盲区不同 |

Agent 心态: 假设 Round 1 遗漏深层问题，采用更高批判性标准。
  "如果代码看起来太干净，可能我没看够深。"
关注: 复杂逻辑流、跨文件语义、边界条件、并发场景、错误处理路径。

输出 reaudit-full-shuffled.json → 运行 match-issues.sh 与 Round 1 checklist 匹配:
  - 匹配的 = Round 1 已发现（确认）
  - 未匹配的 = Round 1 遗漏（Missed）→ 升级审计深度告警

结果判定:
  - 重审也 0 新问题 → ✅ 验证通过 SHIP（真干净，第二审计员确认）
  - 重审发现新问题 → Round 1 浅了，新问题加入 checklist，进入新修复阶段
```

#### Case B: C+H 减少但 >0（正常收敛 — 健康）

```
spawn verifier Agent (sonnet, Mode A BLAST_RADIUS):
  - 读取 blast-radius.json 的 scan_files
  - 以审计心态（非验证心态）对 scan_files 重新执行审计
  - 关注: 修复引入的副作用、边界条件、跨文件一致性
输出 reaudit-blast-radius.json → 运行 match-issues.sh 匹配:
  - 新发现 = 修复引入的回归 → 加入 checklist
进入终裁（阶段 B，若 C+H > 0）→ 退出判断
```

#### Case C: C+H 持平/增加（不收敛 — 硬问题）

```
spawn verifier Agent (sonnet, Mode C 但仅验证 persisting issue):
  - 聚焦 persisting issue 深度分析
  - 换修复策略（不同视角 prompt）
  - 不做全量重审（问题已确认难修，重审浪费）
进入终裁 → 退出判断
已触发 3 轮 → 🔴 BLOCK（真修不了，防无限循环）
```

### Step 4: 终裁（条件触发，仅 Case B/C 且 persisting C+H > 0）

同一 verifier Agent 升级为终裁模式（确认/降级/撤销），无需额外 spawn:

1. 对每个 persisting C/H: 确认(Confirm) / 降级(Demote, C→H→M) / 撤销(Dismiss, 误报)
2. **标记 overridable（关键）**: 裁决时若判定某问题可被编排者自动修复（机械性修复，无需设计决策），设置 `status: "overridable"` 并在 `fix_instruction` 字段中提供具体修复步骤（含文件路径、行号、修复内容）。判断标准：修复为确定性机械操作（替换文本/创建文件/添加行），无需权衡取舍。反例：需要架构决策、需要实证测量、需要跨文件重构的 → 标记 `requires_human`
3. 不可发现新问题
4. 裁决后重算 C+H，套用退出条件表判定最终状态 🟢🟡🔵🔴
5. 输出 verification-round-3.json（含裁决结果 + overridable 标记 + fix_instruction）

**阶段间 checkpoint**: 阶段 A 完成后写 verification-round-2.json，再检查是否需要阶段 B。
若阶段 B 执行，写 verification-round-3.json（仅含裁决结果）。编排者可从 checkpoint 恢复。

### Step 5: overridable 残留检查（🟡 后强制）

```
bash scripts/check-overridable.sh $INSTANCE_DIR
```
- exit 1（存在 overridable）→ 立即修复 → 标记 fix_attempted → 自动进入下一轮（上限 2 轮）
- exit 0（无残留）→ 正常结束

### Step 6: 退出裁决（脚本强制）

```
bash scripts/compute-exit-verdict.sh $INSTANCE_DIR [prev_c_plus_h]
```
脚本执行 8 条决策树规则，输出裁决 + 退出码 + exit-verdict.json。


### 差异对比与报告

> 🆕 **脚本强制执行**: 运行 `bash scripts/generate-diff-table.sh $INSTANCE_DIR <prev_checklist> <curr_verification>`。脚本按 ID 跨轮匹配，输出 Resolved/New/Persisting/Regressed 表 + `diff-table.json`。编排者不再手工匹配。

编排者读取 JSON 输出，按以下算法生成差异表（已由脚本实现）：

1. **匹配键**: 以 `issue.id` 为主键跨轮匹配。ID 跨轮次保持不变。
2. **状态分类规则**:
   - `Resolved`: 上轮存在 + 本轮 verdict=resolved
   - `Persisting`: 上轮存在 + 本轮 verdict=persisting
   - `Regressed`: 上轮已 resolved + 本轮 reappear
   - `New`: 本轮新发现 + 上轮不存在（ID 从 max(上轮ID)+1 开始）
3. **边缘情况**: 若 ID 不同但 file+line_range 相同 → 人工判断后归类为 Regressed 或 Persisting；verification JSON 的 id 与 checklist 不匹配时 → 标记为 unmatched 并人工审核
4. **严重度变更**: 终裁后使用新严重度重新计算 C+H 计数

**输出模板**（每行必须包含 ID + 描述）:

```
# 审计报告: {项目名}

## 状态: {🟢SHIP / 🟡CAUTION / 🔵HOLD / 🔴BLOCK} | 轮次: {N} | 风险分: {avg}/100

## 差异对比
| 状态 | 数量 | ID + 描述 |
|------|------|-----------|
| ✅ Resolved | N | C-5: 修复阶段已加入SKILL.md流程概述和4项职责 |
| 🆕 New | N | H-X: 修复引入的新XSS漏洞 |
| 🔁 Persisting | N | H-4: 注入防御（白名单+6类黑名单+NFKC+反引号替换） |
| ⚠️ Regressed | N | H-Y: 之前修复的问题因新变更而复现 |

## 问题清单（按风险分降序）
| ID | 类型 | 严重度 | 视角 | CWE | CVSS | 风险分 | 文件 | 描述 | SLA |
|----|------|--------|------|-----|------|--------|------|------|-----|
| C-1 | technical | Critical | 👤📊💻 | CWE-89 | 9.8 | 66 | settings.json:5 | 明文API token暴露 | 24h |
| H-4 | technical | High | 💻 | CWE-77 | 7.5 | 45 | lens-config.md:127 | 注入防御可被突破 | 7d |
| P-end-user-1 | soft | Medium | 👤 | — | — | 25 | src/auth/login.ts:42 | 错误提示泄露用户存在性 | 14d |

(列出所有未解决的 Critical/High 问题，含 CWE + CVSS + 风险分 + SLA。视角软性发现单独标注 type=soft。不可只列 ID)

## 审计健康度（如有降级触发）
| 降级事件 | 影响评估 |
|----------|---------|
| ⚠️ 安全透镜(fable)超时→审查官(opus)覆盖 | 安全维度由次优模型审计,置信度降低 |

## 门控裁决: {SHIP/CAUTION/HOLD/BLOCK} (exit {0/1/2})
**策略规则触发**: {无 / CVSS≥9.0→BLOCK / CISA KEV→BLOCK}

## 下一步建议
(SHIP: 通过 / CAUTION: 关注High问题 / HOLD: 修复后重新审计 / BLOCK: 立即阻断)
```

**关键规则**:
- diff 表每行 **必须** 包含 `ID: 一句话描述`，从 checklist JSON 的 `description` 字段截取
- 「问题清单」节每个未解决 C/H 必须包含 CWE + CVSS + 风险分 + 文件 + 描述 + SLA，**禁止只列 ID**
- 「审计健康度」节列出本轮所有降级事件，无降级时可省略
- 「门控裁决」节必须列出裁决结果 + 退出码 + 触发的策略规则
- 企业级多角色报告（dev/exec/compliance）、SARIF JSON、工单生成模板见 `references/enterprise-output.md`
