# 审计循环详细步骤

> 本文件由 SKILL.md 引用。编排者在执行各 Round 时按此处步骤操作。
> 具体透镜配置和 Agent prompt 模板见 `lens-config.md`。

---

## Round 1: 全面审计

### Step 1: 多透镜审计（两阶段并行）

> 🆕 视角透镜需要读取技术透镜的 JSON 输出，因此分为两阶段：阶段 1 技术透镜并行 → 阶段 2 视角透镜并行。不可合并为单次 spawn。

**阶段 1 — 技术透镜（4 个并行）**:

同时发起 4 个 Agent 调用（单次消息中多 tool use，均 `run_in_background: true`）。

编排者从 `agents/` 目录提取 prompt 内容（替换占位符后），使用 inline prompt + model 参数调用 Agent()。模型分配和 prompt 来源见 `lens-config.md`「全面审计 Agent 配置」节。

> **占位符安全**: 所有用户提供的字符串用三个反引号包裹隔离。
> `{审计范围}` 来自用户输入——**完整的输入安全规则（白名单正则+NFKC标准化+6类黑名单+反引号替换+路径约束）见 lens-config.md「输入安全」节。必须完整执行，不可简化。**
> `{输出路径}` / `{文件树}` / `{盲区列表}` / `{issue IDs}` 由编排者内部生成，风险低。

- `{审计范围}` → Step 0 确认的文件范围（用 ``` ``` 包裹隔离）
- `{输出路径}` → `.claude/cache/audit-context/{instance_id}/lens-{name}.json`（{instance_id} 由编排者 Step 0 生成）

| 透镜 | prompt 来源 | model | 输出文件 |
|------|-----------|-------|----------|
| 🔒 安全+合规 | `agents/lens-security.md` | fable | `lens-security.json` |
| 🏗️ 架构 | `agents/lens-architecture.md` | sonnet | `lens-arch.json` |
| 📋 质量 | `agents/lens-quality.md` | sonnet | `lens-quality.json` |
| ⚡ 性能 | `agents/lens-performance.md` | haiku | `lens-perf.json` |

4 透镜共用 3 种模型（fable/sonnet/haiku），真并行不争抢槽位。fable 守安全最高精度，sonnet 守架构+质量大上下文推理，haiku 守性能最低成本。合并审查官使用 opus——全流程 4 种模型参与。

**阶段 2 — 视角透镜（N 个并行，N = 用户选择的视角数，0 ≤ N ≤ 5）**:

> ⚠️ **前置条件**: 阶段 1 的 4 个技术透镜全部完成。视角透镜需要读取 `lens-security.json` 等文件。

对每个启用视角，编排者：
1. 从 `agents/lens-perspective.md` 提取 prompt 模板
2. 从 `lens-config.md`「视角透镜 Prompt 注入模板」填充视角定义（name/icon/focus_areas）并追加到 prompt
3. 使用 inline prompt + model 参数 spawn Agent

| 视角 | prompt 来源 | model | 输出文件 |
|------|-----------|-------|----------|
| {perspective_id} | `agents/lens-perspective.md` + 视角注入 | 见 lens-config.md 视角模型分配表 | `lens-perspective-{perspective_id}.json` |

视角透镜工作方式（不重复扫描代码）:
1. 读取 4 个技术透镜的 JSON 输出
2. 从该视角重新评估每个 finding 的严重度和优先级
3. 补充技术透镜不覆盖的"软性发现"

全部视角透镜并行 spawn 后，等待全部返回再进入 Step 2。

**4 透镜并行 spawn 后，等待全部返回后再进入 Step 2**。编排者收到所有 4 个 lens Agent 的完成通知（超时则标记 incomplete，不阻塞）后，确认 4 个 lens-*.json 文件存在（不存在的标记 incomplete），再 spawn Step 2。

**超时与失败处理**：

> 🚨 **禁止直接跳过**: Agent 超时/崩溃/模型不可用时，**禁止直接标记 incomplete**。必须先按模型降级链逐档重试（规则见 `guardrails.md`「模型降级链」节）。所有降级档位均失败后才标记 incomplete。

- **单个 Agent 失败**: 按降级链重试 → 仍失败 → 标记 incomplete + ⚠️ 降级通知
  - fable 透镜: fable(300s) → sonnet(300s) → haiku(300s) → 全部失败 → incomplete
  - sonnet 透镜: sonnet(300s) → haiku(300s) → 全部失败 → incomplete
  - haiku 透镜: haiku(300s) → 超时 → incomplete（已是最低档）
  - 超时阈值 300s/档，与 900s 轮级截止兼容（最坏情况 fable→sonnet→haiku = 900s）
- **合并审查官失败**: opus(300s) → sonnet(300s) → haiku(300s) → 全部失败 → 编排者自行机械去重 + 🔴 关键降级
- **验证+终裁失败**: sonnet(300s) → haiku(300s) → 全部失败 → 编排者自行验证 + 🟡 降级标记
- **部分透镜失败**（含降级后仍失败的）:
  - 安全透镜最终 incomplete → Step 2 审查官优先覆盖安全维度 + 🔴 关键降级
  - 其他透镜最终 incomplete → Step 2 审查官覆盖该维度
  - 3/4 透镜最终 incomplete → 降级为单透镜模式 + 🟡
- 全部 Agent 失败 → 🔴 红灯终止，通知用户
- 网关限流 → 指数退避重试 2 次（15s, 30s），仍失败 → 降级为串行（顺序 spawn，间隔 5s）
  > 串行模式下再次限流 → 增加间隔至 10s → 30s → 仍失败则标记该 Agent incomplete

### Step 2: 合并审查官（去重 + 盲区识别 + 补充审计）

> 将旧版去重 Agent + 审查官 + 补充审计合并为一次 spawn，消除 2 次额外 Agent 加载和文件重读。
> 🆕 增加视角维度处理——合并技术透镜发现与视角透镜评估，标记视角冲突。

4 个技术透镜 + N 个视角透镜全部返回后（含超时/incomplete），spawn 一个合并审查官 Agent。

**透镜输出缺失降级**: 如果某透镜的 JSON 文件不存在或不可解析 → 标记该透镜为 incomplete。合并审查官仍可继续，但需跳过该维度并在盲区分析中优先覆盖。所有技术透镜均缺失 → 🔴 终止。视角透镜全部缺失 → 降级为纯技术审计，不影响流程。

```
Agent(model="opus",
  prompt="<从 agents/merge-reviewer.md 提取的 prompt，实例目录和文件路径已替换>")

执行四阶段任务（A 去重 → B 跨文件一致性扫描 → C 盲区识别 → D 补盲），按顺序：

阶段 A — 去重合并:
1. 读取技术透镜: lens-{security,quality,arch,perf}.json
2. 🆕 读取视角透镜: lens-perspective-*.json（0-N 个）
3. 执行两级去重：
   Level 1 严格去重: 同文件+同行号范围重叠+同严重度 → 保留描述最完整条目，合并 lens_sources
   Level 2 语义合并: 同 root cause 不同视角 → 合并为一条，融合多透镜多视角描述
4. 分配全局 ID（C-/H-/M-/S-），视角软性发现使用 P-{perspective_id}-{n} 前缀
5. 🆕 关联视角评估: 将视角透镜的 reassessed_findings 写入对应 issue 的 perspective_assessments 字段
6. 🆕 合并视角软性发现: 将视角透镜的 soft_findings 追加到 issues 列表（type="soft"）
7. 🆕 标记视角冲突: 若同一 finding 在不同视角下严重度差异 ≥ 2 级 → perspective_conflict=true
8. **企业风险评分（P0）**: 对每个 issue 计算 risk_score，填写全部企业字段
9. 生成 checklist-round-1.json

阶段 B — 跨文件一致性扫描（🆕 H-2 fix 完整版）:
1. 以 `references/truth-registry.md` 为权威来源
2. 对以下关键声明做跨文件一致性检查：
   - 数值声明: Token 阈值（80K/100K/150K/250K/300K/600K/800K/1.5M）、Agent spawn 计数（3-5/7-13）、降级矩阵条目数（25）
   - 模型分配: 阶段 1 透镜模型（fable/sonnet/sonnet/haiku）、全流程参与模型（fable/opus/sonnet/haiku）
   - 术语定义: "简单审计"/"全面审计"、"阶段 1"/"阶段 2"、"技术透镜"/"视角透镜"
   - 占位符命名: `{审计范围}`、`{输出路径}`、`{instance_dir}`
3. 对每项关键声明，列出其在所有文件中的具体表述
4. 若有文件间表述不一致 → 标记为 `consistency_gap` issue（severity=Medium），指出权威来源和需要修正的文件

阶段 C — 盲区识别:
1. 对比审计范围文件树 vs checklist 已覆盖文件
2. 提取各透镜 out-of-scope 声明
3. 🆕 对比视角关注领域 vs 实际覆盖——视角关心的领域是否有技术发现覆盖？
4. 基于安全关键路径判断盲区风险

阶段 D — 补充审计（条件触发）:
仅当阶段 C 发现高风险盲区时执行。

输出: .claude/cache/audit-context/{instance_id}/checklist-round-1.json
      （包含所有 issues + dedup_summary + blind_spot_summary + 🆕 perspective_summary）
```

更新 `checklist-round-1.json`，标记 `"round": 1, "checklist_status": "complete"`。注意：checklist 级别的完成状态用 `checklist_status` 字段，与 issue 级别的 `status` 枚举（open/fix_attempted/requires_human/resolved/persisting等）区分。

---

## 修复阶段: Round 1 与 Round 2 之间

> ⏸️ **条件执行**: 此阶段仅在用户选择「继续修复」后执行。若用户选择「停止（仅报告）」，跳过此阶段和后续 Round 2/3，直接进入企业级多角色输出。

Round 1 审计完成后、Round 2 验证之前，编排者（主 Claude）需要修复发现的问题。这是审计循环的核心环节。

### 修复优先级

1. **Critical → High → Medium**。先修高危、后修中危。
2. 修复集合：排除 `lens_sources` 仅包含 `performance` 的性能问题（这些通常不影响安全性，可延后）。

### 修复约束

- **只修改审计范围内的文件**。不扩大修改范围。
- **每项修复后做最小验证**：如果项目有 linter/test，运行相关检查确认修复未引入编译错误。
- **无法自动修复的问题**（如"需要架构重构"、"设计权衡"）：标记为 `requires_human`，不强行修改。

### 修复引入错误处理

如果修复引入了编译/lint 错误：
1. 先尝试修复编译错误（通常是小问题，如漏 import、类型不匹配）
2. 无法自动修复 → 回滚该修复，标记为"需人工处理"，继续下一项

### 修复进度追踪

在修复过程中更新 checklist：
- 每修完一项，将对应 issue 的 `status` 改为 `fix_attempted`（不是 `resolved`——后者由验证 Agent 判定）
- 这确保修复状态不预设"已修好"，保持验证 Agent 的独立性

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
