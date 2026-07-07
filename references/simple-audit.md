# 简单审计详细步骤

> 本文件由 SKILL.md 引用。编排者在执行简单审计时按此处步骤操作。
> **简单审计 ≠ 简陋审计**。覆盖全部 4 维度（安全+架构+质量+性能），具备完整的修复-验证循环。
> 速度提升来自**模块合并**（2 个合并透镜替代 4 个独立透镜）和 **Agent spawn 精简**（编排者验证替代部分 Agent 调用），而非砍审计范围。

---

## 与全面审计的核心区别

> 模式对比详见 `references/mode-comparison.md`（单一权威来源）。简单审计的关键区别：流程精简（合并模块、减少 spawn），审计清单不缩减。

---

## 流程概述

```
Step 0a: 确认审计范围 → 选 Token 档位
Step 0b: 🆕 视角推荐（haiku 快速扫描，~1min）
  ↓
Round 1 Step 1（两阶段）:
  阶段 1: 2 合并透镜并行审计
    Agent A (S+A): sonnet → lens-sa-simple.json
    Agent B (Q+P): haiku  → lens-qp-simple.json
  阶段 2: 视角透镜（0-1 个，条件触发）
    Agent C (Perspective): haiku → lens-perspective-merged.json
  ↓
Round 1 Step 2: 编排者机械去重 → 输出 checklist
  ↓
修复阶段: 编排者按 C→H→M 优先级修复 → 标记 fix_attempted/requires_human
  ↓
Round 2/3: 编排者验证 → C+H=0? 🟢结束 : 🔵自动进入下一轮
  条件触发: Critical > 0 或修复无效 → spawn 深度验证 Agent
  ↓
退出判断: 🟢🟡🔵🔴 四灯决策 + 自动推进
```

---

## Step 0: 审计范围确认

### Step 0a: 范围确认

与全面审计相同：
1. 用 `Glob` 扫描项目文件树，统计文件数量和类型。
2. 检测是否为 git 仓库。
3. 若用户已明确指定范围 → 直接进入。仅当范围模糊时向用户确认。
4. 运行 `bash scripts/select-token-tier.sh <file_count> simple` 自动选择 Token 档位。权威阈值见 `references/guardrails.md`。
5. 确保 `.claude/cache/audit-context/` 目录存在。

### Step 0b: 视角推荐（简单审计版）🆕

> 简单审计下视角推荐使用 haiku 快速扫描（~1min），推荐 1-3 个视角。

编排者 spawn 视角推荐 Agent：
- Prompt 来源: `agents/perspective-recommender.md`
- Model: **haiku**（快速扫描）
- 输入: 仅 README（前 100 行）+ package.json + 一级目录名
- 输出: 1-3 个推荐视角 JSON

展示模板与全面审计相同（见 SKILL.md Step 0b）。用户确认后视角列表写入 instance 上下文。

**视角上限**: 简单审计最多 3 个视角。若 Agent 推荐超过 3 个 → 取 priority 最高的 3 个。
**失败降级**: Agent 失败 → 回退为默认 2 视角（💻 开发者 + 👤 用户），⚠️ 降级通知。

---

## Round 1: 合并透镜审计

### Step 1: 双合并透镜 + 视角透镜（两阶段）🆕

**阶段 1 — 技术透镜（2 个并行）**:

同时发起 2 个 Agent 调用（单次消息中多 tool use，均 `run_in_background: true`）。

编排者构造合并 prompt（从对应 agent 文件提取清单合并），使用 inline prompt + model 参数：

| Agent | model | 覆盖维度 | prompt 构造 | 输出文件 |
|-------|-------|----------|------------|----------|
| Agent A (S+A) | **sonnet** | 安全+架构 | `agents/lens-security.md` 安全清单 + `agents/lens-architecture.md` 架构清单合并 | `lens-sa-simple.json` |
| Agent B (Q+P) | **haiku** | 质量+性能 | `agents/lens-quality.md` 质量清单 + `agents/lens-performance.md` 性能清单合并 | `lens-qp-simple.json` |

> **模型选择理由**：
> - 安全+架构用 sonnet：大上下文窗口模型，兼顾注入链分析深度和跨文件耦合分析广度。仅用 1 个重量模型控制耗时。
> - 质量+性能用 haiku：轻量代码特化模型。全部模式匹配+指标检查，并行时瓶颈在 sonnet，速度快 3-5x。
> - 2 个 Agent 并行，瓶颈在 sonnet（预计 5-8min），haiku 预计 2-3min 先完成。总等待 ~5-8min。2 种模型参与提供基本对抗性审查多样性。

将以下占位符替换为实际值后 spawn Agent（输入安全规则与全面审计相同——白名单+黑名单+NFKC+反引号替换）：

- `{审计范围}` → Step 0 确认的文件范围
- `{输出路径}` → `.claude/cache/audit-context/{instance_id}/lens-{name}-simple.json`

**阶段 2 — 视角透镜（0-1 个，条件触发）**:

> ⚠️ **前置条件**: 阶段 1 的 2 个技术透镜全部完成。仅在用户启用视角时执行。

若启用视角:
- 1 个 Agent (haiku)，从 `agents/lens-perspective.md` 提取 prompt
- **批量视角注入**: 将所有启用视角的 name/icon/focus_areas 作为 JSON 列表注入
- 读阶段 1 的技术透镜 JSON 输出 → 一次性输出所有视角评估结果
- 输出: `lens-perspective-merged.json`

若未启用视角 → 跳过阶段 2。

**超时与失败处理**：

> 🚨 **禁止直接跳过**: Agent 失败时先按降级链重试（规则见 `guardrails.md`「模型降级链」节）。所有降级档位均失败后才标记 incomplete。

- 单个 Agent 超时 300s/崩溃/模型不可用 → 按降级链重试:
  - S+A 透镜（sonnet）: sonnet(300s) → haiku(300s) → 全部失败 → 编排者自行执行安全+架构检查 + 🔴 关键降级
  - Q+P 透镜（haiku）: haiku(300s) → 超时 → 编排者在验证阶段补充检查 + ⚠️ 降级
- 条件深度验证 Agent（sonnet）失败: sonnet(300s) → haiku(300s) → 全部失败 → 编排者自行验证 + 🟡 降级
- 2/2 全部失败（含降级后） → 🔴 终止，建议用户使用全面审计（4 独立透镜容错性更好）
- 网关限流 → 指数退避重试 1 次（15s），仍失败 → 标记 incomplete

**2 透镜并行 spawn 后，等待全部返回后再进入 Step 2**。

### Step 2: 编排者机械去重

> 简单审计**不 spawn 合并审查官 Agent**。编排者（主 Claude）直接执行机械去重，节省一次 Agent spawn（省 ~5-7min）。

编排者读取 `lens-sa-simple.json` 和 `lens-qp-simple.json`，执行：

1. **同文件+同行号重叠+同严重度** → 保留描述更完整条目，合并 `lens_sources`
2. **同 root cause 不同视角**（如 S+A 报注入漏洞、Q+P 报错误处理缺失指向同一代码）→ 保留为独立条目，交叉引用
3. **分配全局 ID**：C-/H-/M-/S-，安全优先编号
4. **生成 checklist**：写入 `.claude/cache/audit-context/{instance_id}/checklist-round-1.json`（格式与全面审计相同，供后续验证轮次使用）

**去重后输出完整问题清单**：

```
| ID | 严重度 | 文件 | 描述 |
|----|--------|------|------|
| C-1 | Critical | src/auth.ts:42 | 硬编码数据库密码 |
| H-1 | High | src/api.ts:88 | 用户输入未校验直接拼接SQL |
| H-2 | High | src/config.ts:15 | 循环依赖：config→db→config |
| M-1 | Medium | src/utils.ts:30 | 缺少空值检查 |
```

列出所有 Critical 和 High（含 ID+文件+描述），Medium 和 Suggestion 可仅列数量。

---

### 用户确认（Round 1 后暂停）

> ⏸️ 编排者输出问题清单后暂停，询问用户选择。与全面审计使用相同的询问模板（详见 SKILL.md「用户确认」节）。
> 用户选择「继续修复」→ 进入下方修复阶段。选择「停止」→ 跳过修复+验证，直接生成企业报告。

---

## 修复阶段

> ⏸️ 此阶段仅在用户选择「继续修复」后执行。若用户选择「停止」，跳过此阶段和后续 Round 2/3。
> 修复阶段的优先级、约束、错误处理、进度追踪规则与全面审计完全相同，详见 `round-details.md`「修复阶段: Round 1 与 Round 2 之间」节。
> 简言之：按 C→H→M 优先级修复 → 仅修改审计范围内文件 → 无法修复标记 requires_human → 每项修复后标记 fix_attempted。

---

## Round 2/3: 验证 + 条件深度审计

> 简单审计的验证采用**分层策略**：编排者先做轻量验证，仅在必要时 spawn Agent 深度验证。

### 前置检查

读取 `checklist-round-1.json`。如果 issues 中无 Critical 或 High → 🟢 绿灯，直接输出报告，结束。

### 阶段 A: 编排者轻量验证

编排者（主 Claude）直接逐项检查每个 fix_attempted 的 issue：

1. 读取修复涉及的文件，确认修复已应用（代码中存在修复内容）
2. 检查修复是否覆盖了 issue 描述的 root cause
3. 对修复涉及的文件做手动检查：`grep` 常见漏洞模式（硬编码密钥/未参数化SQL/危险函数）
4. 判定：`resolved` / `persisting` / `regressed`
5. 置信度标注：`high`（可静态验证）/ `medium`（需判断）/ `low`（需运行时验证）

**轻量验证的范围**：
- 仅检查 fix_attempted 的 issue
- 简化 Blast-Radius：检查变更文件 + 同目录配置文件（`**/*.{yaml,yml,json,toml,env}`），不扫描上游调用者。此范围定义为本文件的权威描述

### 阶段 B: 条件深度验证（Agent spawn）

**触发条件**（满足任一即触发）：
- 阶段 A 后 **总 Critical > 0**（修复未解决 Critical）
- 阶段 A 后 **总 C+H 较上一轮无减少或增加**（修复无效或引入回归）
- 阶段 A 中置信度为 `low` 的 issue 超过 2 个

**不触发条件**：阶段 A 后 C+H = 0 → 🟢 绿灯，跳过阶段 B。

**Agent 调用**：

```
Agent(model="sonnet",
  prompt="<从 agents/verifier.md 提取的 prompt，{instance_dir} 已替换>")

> 🔴 对抗性审查: 你正在验证的修复由编排者（主 Claude）执行。假设修复可能不彻底——独立验证每个修复。

阶段 A — Checklist 验证 (Mode C):
1. 读取 .claude/cache/audit-context/{instance_id}/checklist-round-1.json，逐项验证
2. 每项: 检查是否仍存在 → verdict: resolved/persisting/regressed
   + confidence: high/medium/low + evidence
3. 简化 Blast-Radius: git diff 找变更文件 → grep 关键漏洞模式
   （不扫描上游调用者——简化版仅检查变更文件本身）
4. 生成差异对比: Resolved / New / Persisting / Regressed

阶段 B — 终裁 (Mode D, 条件触发):
仅当阶段 A 后 总 C+H > 0 时执行。
1. 对每个 persisting C/H: 确认(Confirm) / 降级(C→H→M) / 撤销(Dismiss)
2. **标记 overridable（关键）**: 裁决时若判定某问题可被编排者自动修复（机械性修复，无需设计决策），设置 `status: "overridable"` 并在 `fix_instruction` 字段中提供具体修复步骤（含文件路径、行号、修复内容）。判断标准：修复为确定性机械操作（替换文本/创建文件/添加行），无需权衡取舍。反例：需要架构决策、需要实证测量、需要跨文件重构的 → 标记 `requires_human`
3. 不可发现新问题
4. 裁决后重算 C+H，套用退出条件表判定最终状态 🟢🟡🔵🔴

阶段间 checkpoint: 阶段 A 完成后写 verification-round-2.json。
阶段 B 执行后写 verification-round-3.json（仅裁决结果）。
```

### 差异对比与报告

编排者按以下算法生成差异表（与全面审计相同）：

1. **匹配键**: 以 `issue.id` 为主键跨轮匹配
2. **状态分类**: Resolved / Persisting / Regressed / New
3. **边缘情况**: ID 不同但 file+line_range 相同 → 人工归类

**输出模板**:

```
# 🔍 简单审计报告: {项目名}

## 状态: {🟢SHIP / 🟡CAUTION / 🔵HOLD / 🔴BLOCK} | 轮次: {N} | 风险分: {avg}/100

## 差异对比
| 状态 | 数量 | ID + 描述 |
|------|------|-----------|
| ✅ Resolved | N | C-5: 修复阶段已移除硬编码密钥 |
| 🆕 New | N | H-X: 修复引入的新XSS漏洞 |
| 🔁 Persisting | N | H-4: 注入防御（白名单+6类黑名单+NFKC+反引号替换） |
| ⚠️ Regressed | N | H-Y: 之前修复的问题因新变更而复现 |

## 问题清单（按风险分降序）
| ID | 严重度 | CWE | CVSS | 风险分 | 文件 | 描述 | SLA |
|----|--------|-----|------|--------|------|------|-----|
| C-1 | Critical | CWE-798 | 9.8 | 66 | settings.json:5 | 明文API token暴露 | 24h |
| H-4 | High | CWE-77 | 7.5 | 45 | lens-config.md:127 | 注入防御可被突破 | 7d |

## 审计模式说明
- 本报告由 🔍 简单审计生成（2 合并透镜覆盖 4 维度 + 编排者验证）
- 企业标准映射: OWASP ASVS 5.0 / CVSS 4.0 / CWE 4.16 / NIST SSDF 1.1
- 相比全面审计：盲区分析和 Blast-Radius 全量扫描未执行

## 审计健康度（如有降级触发）
| 降级事件 | 影响评估 |
|----------|---------|
| ⚠️ S+A透镜超时→编排者覆盖安全+架构 | 安全+架构由编排者替代审计,深度降低 |

## 门控裁决: {SHIP/CAUTION/HOLD/BLOCK} (exit {0/1/2})

## 下一步建议
(SHIP: 通过 / CAUTION: 关注High问题 / HOLD: 修复后重新审计 / BLOCK: 立即阻断)
```

> 企业级多角色报告（dev/exec/compliance）、SARIF JSON、工单生成模板见 `references/enterprise-output.md`。简单审计模式输出时标注 `审计模式: simple`。

---

## 退出判断（企业级门控裁决）

**与全面审计使用完全相同的门控裁决决策树**。详见 `SKILL.md`「退出判断」节和 `references/standards-map.md`「门控策略规则」节。

| 条件 | 裁决 | 退出码 | CI 行为 |
|------|------|--------|---------|
| 任何 CVSS ≥ 9.0 或 CISA KEV | 🔴 **BLOCK** | 2 | 阻断 |
| 总 C+H = 0 | 🟢 **SHIP** | 0 | 继续 |
| 总 C+H 较上一轮无减少 | 🔴 **BLOCK** | 2 | 阻断 |
| C+H 有减少 且 Critical = 0 | 🟡 **CAUTION** | 0 | 继续（先检查 overridable） |
| C+H 有减少 但 Critical > 0 | 🔵 **HOLD** | 1 | 阻断部署，自动继续 |

---

## 自动推进规则

与全面审计相同：一次触发后自动执行完整循环——Step 0 → Round 1 → 修复 → Round 2/3 → 退出判断。

**仅在以下情况暂停**：
- Step 0 审计范围不明确，需要用户确认范围
- **Round 1 问题清单输出后**：等待用户选择「继续修复」或「停止（仅报告）」。用户选择「继续修复」后全自动推进至退出判断
- 退出判断为 🔴 红灯（无改善），需用户决定是否强制继续
- C-1/C-2 等环境配置问题无法自动修复，需用户手动处理

🔵 蓝灯不暂停——自动进入下一轮。

---

## Token 守卫（简单审计版）

> Token 守卫阈值权威来源为 `references/guardrails.md`。运行时由 `select-token-tier.sh` 自动选择档位。

- 单轮超阈值 → 跳过后续循环，输出当前报告 + ⚠️
- 累计超阈值 → 强制终止
- Round 1 即超累计 → 降级为单次审计（放弃循环）
