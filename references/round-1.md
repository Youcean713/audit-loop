# Round 1: 全面审计

> 本文件从 round-details.md 拆分而来（P2-1: 按阶段拆分优化 token 消耗）。
> 编排者在对应阶段 **立即 Read** 此文件。

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

