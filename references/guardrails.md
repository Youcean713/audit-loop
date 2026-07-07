# Token 守卫 & 错误处理 & 非 Git 降级

## Token 守卫

### 分档阈值

### 全面审计

| 档位 | 审计范围 | 单轮阈值 | 累计阈值 |
|------|----------|---------|---------|
| 小型 | ≤10 文件 | 100K | 250K |
| 中型 | ≤50 文件 | 250K | 600K |
| 大型 | >50 文件 | 600K | 1.5M |

### 简单审计

| 档位 | 审计范围 | 单轮阈值 | 累计阈值 |
|------|----------|---------|---------|
| 小型 | ≤10 文件 | 80K | 200K |
| 中型 | ≤50 文件 | 150K | 400K |
| 大型 | >50 文件 | 300K | 800K |

> 阈值与 SKILL.md/simple-audit.md 保持同步。视角系统增加 ~25% Token 开销已计入。

### 守卫行为

- 单轮超阈值 → 跳过后续循环，输出当前报告 + ⚠️ "Token 超限，循环中断"
- 累计超累计阈值 → 强制终止，输出已完成内容 + 中断标记
- Round 1 即超累计 → 降级为单次审计模式（放弃循环）

累计统计方式：编排者侧跟踪。每次 Agent spawn 后记录估算 token 消耗（Agent prompt 长度 + 输出长度），累计与阈值比较。Agent 输出中不要求 `total_tokens` 字段（子代理无法获取自身 token 计数）。

---

## 错误处理降级矩阵

> **Why 需要降级矩阵**: 审计循环涉及 6 次 Agent 调用（全周期），任何一次失败都可能导致整个流程中断。预定义降级策略可以确保流程在部分故障时仍能产出有意义的结果，而不是静默失败。

### 模型降级链（Agent 故障时优先降级重试，禁止直接跳过）

> 🚨 **关键规则**: Agent 超时/崩溃/模型不可用时，**禁止直接标记 incomplete 跳过该透镜**。必须先按以下降级链重试，所有档位均失败后才标记 incomplete。

```
当前模型不可用时的降级路径:

  fable 不可用 → 降级为 sonnet，重试
  opus  不可用 → 降级为 sonnet，重试
  sonnet 不可用 → 降级为 haiku，重试
  haiku 不可用 → 标记 incomplete（已是最低档）

重试约束:
  - 每档仅重试 1 次，超时 300s
  - 降级后的 Agent 使用相同的 prompt 和输出路径
  - 编排者必须在审计健康度中记录降级事件
```

| 透镜 | 原始模型 | 第 1 降级 | 第 2 降级 | 全部失败后 |
|------|---------|----------|----------|----------|
| 🔒 安全 | fable | sonnet | haiku | 审查官优先覆盖安全维度 + 🔴 关键降级 |
| 🏗️ 架构 | sonnet | haiku | — | 审查官覆盖架构维度 + ⚠️ 降级 |
| 📋 质量 | sonnet | haiku | — | 审查官覆盖质量维度 + ⚠️ 降级 |
| ⚡ 性能 | haiku | — | — | 审查官覆盖性能维度 + ⚠️ 降级 |
| 🔍 合并审查官 | opus | sonnet | haiku | 编排者自行执行机械去重 + 🔴 关键降级 |
| ✅ 验证+终裁 | sonnet | haiku | — | 编排者自行验证 + 🟡 降级标记 |
| 🔄 Case A 全量重审（模型洗牌） | opus/fable/opus/sonnet（洗牌后） | 各维度按降级链降级 | — | Case A 降级为 blast-radius 重审（Tier 2）+ ⚠️ 降级通知 |
| 👁️ 视角透镜 | sonnet | haiku | — | 跳过该视角 + ⚠️ 降级通知 |
| 📡 视角推荐 | sonnet | haiku | — | 回退为默认视角（全面3/简单2）+ ⚠️ 降级通知 |

### 故障降级矩阵

| 故障场景 | 降级策略 |
|----------|----------|
| 单个透镜 Agent 超时(>300s)/崩溃/模型不可用 | **先按模型降级链重试**（见上表）。所有降级档位均失败后才标记 incomplete。审查官优先覆盖该透镜范围 + ⚠️ 降级通知 |
| 2/4 透镜失败(含安全透镜) | incomplete + 审查官优先覆盖安全维度 + 最终报告 🟡 降级标记 + ⚠️ 通知用户"安全透镜由次优模型替代" |
| 2/4 透镜失败(不含安全透镜) | incomplete + 审查官覆盖失败维度 + ⚠️ 降级通知 |
| 3/4 透镜失败 | 降级为单透镜模式（仅用成功透镜的维度）+ 🟡 + ⚠️"仅有1个维度被审计" |
| 全部透镜失败 | 🔴 红灯终止，通知用户"审计失败：所有透镜不可用" |
| 视角推荐 Agent 超时/崩溃 | 回退为默认视角（全面: 💻+👤+📊 3个 / 简单: 💻+👤 2个）+ ⚠️ 降级通知 |
| 视角推荐 Agent 返回不可解析 JSON | 同上，回退为默认视角 + ⚠️ 降级通知 |
| 单个视角透镜失败 | 跳过该视角，其他视角正常继续 + ⚠️ 降级通知 |
| 全部视角透镜失败 | 降级为纯技术审计（无视角维度），不影响技术透镜审计 + ⚠️ 降级通知 |
| 简单审计视角合并 Agent 失败 | 跳过视角，降级为纯技术审计 + ⚠️ 降级通知 |
| Checklist JSON 写入失败 | 降级为 prompt 内联传递（精简版，仅 Critical+High 条目） |
| 行号漂移（修复导致行号变化） | Agent 按 `file + description + trigger_condition` 三重定位（verifier Agent 内部处理） |
| 网关 API 限流 | 指数退避重试 2 次（15s, 30s），仍失败 → 降级为串行（顺序 spawn Agent，间隔 5s）。串行模式下再次限流 → 增加间隔至 10s → 30s → 仍失败则标记 incomplete |
| 编排者 token 上下文溢出 | 触发 early exit，输出已完成结果 + 溢出标记 |
| 快照文件损坏 | Agent 内部删除损坏文件，降级为完整 Phase 1（无需编排者干预） |
| 修复引入编译/lint 错误 | 先尝试修复编译错误；无法自动修复 → 回滚该修复并标记"需人工处理" |
| 非 git 项目 diff 失败 | 降级为 mtime 对比（<24h 的文件视为"变更"），精度降低但可用 |
| Agent 返回不可解析 JSON | JSON schema 校验失败 → 重试 1 次 → 仍失败则标记该 Agent 输出为 corrupt，降级为 prompt 内联传递 |
| 缓存目录不可写（磁盘满/权限） | 全部 Agent 输出降级为 prompt 内联传递，本轮不写任何文件 |
| Agent 配置的模型不可用 | 按模型降级链逐档重试（见上表），禁止直接跳过 |
| 并发 Agent 数达平台上限 | 降级为串行（顺序 spawn，间隔 5s） |
| Agent spawn 成功但永不返回 | 设置绝对截止时间（每轮 900s），超时视为该 Agent 崩溃，按单 Agent 超时处理 |
| 合并审查官(Step 2)超时 | 先按降级链重试（opus→sonnet→haiku），全部失败 → **强制执行 `bash scripts/mechanical-dedup.sh $INSTANCE_DIR`**（替代 prose 级"编排者自行去重"——脚本保证：两级去重 + 强制包含全部软性发现 + 覆盖摘要确认）。⚠️ 降级通知用户 |
| Agent 访问不可信 URL（WebFetch/WebSearch/web-reader） | **known_limitation** — 编排者应在 Step 0 剥离审计范围中所有 URL（替换为 `[URL REDACTED]`）。若绕过 → 属平台层 WebFetch URL 白名单缺失，skill 代码无法修复。建议在 settings.json 配置 WebFetch/WebSearch 的 allowedDomains 或通过 PreToolUse Hook 拦截 |
| inline prompt Agent 继承通用工具集（Tools:* 绕过 agent frontmatter 限制） | **AP-12 fix**: 根因是未用 `subagent_type` 调用。`tools`/`disallowedTools` 字段对插件 Agent 运行时强制（仅 hooks/mcpServers/permissionMode 被忽略）。PreToolUse Hook 强制 `subagent_type` + 三层缓解见下方「Agent 工具权限三层纵深」节。已知平台 bug（tools 可能被绕过）见 `references/known-issues.md` |

---

## Agent 工具权限三层纵深（C-3/AP-12 缓解）🆕

> AP-15 fix: `tools`/`disallowedTools` 字段对插件 Agent 运行时强制（需通过 `subagent_type` 调用生效）。
> 但存在 3 个未修复平台 bug（SDK #172、#63762、#31292，见 `references/known-issues.md`），需三层纵深缓解。
> 第一层 PreToolUse Hook 强制 `subagent_type`（AP-12），第二层 Agent frontmatter `tools`/`disallowedTools`，第三层 Hook 拦截审计范围内的 Write/Edit。

### 第一层: PreToolUse Hook（平台级强制）

在 `~/.claude/settings.json` 配置 PreToolUse Hook，拦截 lens Agent 对非白名单路径的 Write/Edit/Bash 操作：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "condition": "tool_input.file_path does not start with '.claude/cache/audit-context/'",
        "action": "deny",
        "reason": "Lens Agent 仅允许写入 audit-context 目录"
      },
      {
        "matcher": "Bash",
        "condition": "tool_input.command contains 'rm -rf' or 'sudo' or 'curl' or 'wget'",
        "action": "deny",
        "reason": "Lens Agent 禁止执行危险命令或网络请求"
      }
    ]
  }
}
```

> 完整 Hook 配置示例见 `settings.hook-example.json`。实际 Hook condition 语法取决于 Claude Code PreToolUse Hook 的具体实现。

### 第二层: Lens Agent stdout 输出（skill 级改进方向）

当前所有 lens Agent prompt 包含"写入 {输出路径}"指令。改为 Agent 通过 stdout 输出 JSON，由编排者负责写入文件：

1. Agent prompt 中将"写入 {输出路径}"替换为"将 JSON 输出到 stdout"
2. 编排者在收到 Agent 完成后，从返回文本中解析 JSON → 对 viewpoint_id 等字段执行安全检查 → 写入文件
3. 优势：Agent 不再需要 Write 权限；编排者获得输出内容的检查点

> 这是中期改进方向——需要更新所有 Agent prompt + 编排者工作流。当前版本通过第一层 PreToolUse Hook 兜底。

### 第三层: 平台工具白名单（feature request）

向 Claude Code 平台请求：inline prompt + model 参数调用的 Agent 应支持 `allowedTools` 参数，在 Agent() 调用时显式限制工具权限。

### 缓解有效性

| 攻击场景 | 仅 prompt 约束 | +Hook | +stdout | +平台白名单 |
|---------|:------------:|:-----:|:-------:|:--------:|
| Agent 被注入修改源文件 | ❌ | ✅ | ✅ | ✅ |
| Agent 被注入执行命令 | ❌ | ✅ | ✅ | ✅ |
| Agent 被注入网络请求 | ❌ | ⚠️ | ✅ | ✅ |
| Agent 写入错误路径 | ⚠️ | ✅ | ✅ | ✅ |

---

## 降级通知要求

| 降级矩阵当前共 25 条策略（含 2 条 known_limitation）。所有降级均强制通知用户——审计可信度依赖用户知情。

**强制规则**：
- 每条降级触发时 → 编排者输出 `⚠️ 降级: {原因}` 到用户可见输出
- 最终报告必须包含「审计健康度」节，列出本轮所有降级事件及影响评估
- 以下为关键降级，必须 🔴 显式警告：
  - 安全透镜失败 → 由审查官覆盖（安全维度由非专用模型审计）
  - 模型降级（fable→sonnet 或 opus→sonnet 降 1 档，fable/opus→haiku 降 2 档为实质性审计质量下降）。安全透镜和合并审查官降级时必须 🔴 显式警告
  - JSON 持久化失败 → 审计结果仅存于临时上下文，会话结束后丢失

---

## 并发检测（借鉴 AI Worker PID 锁模式）

> **Why 需要并发检测**: 多个 audit-loop 实例同时运行时，所有 Agent 写入相同的输出文件名（`lens-security.json`、`checklist-round-1.json` 等）。后写覆盖先写，导致合并审查官基于混合数据生成 checklist。instance_id 目录隔离从根本上解决此问题。

### instance_id 机制

编排者在 Step 0 生成 instance_id（格式 `audit-{YYYYMMDD-HHmmss}-{random_4_hex}`），所有输出写入 `.claude/cache/audit-context/{instance_id}/` 子目录。各实例输出完全隔离，不存在覆盖风险。

### lockfile 兜底

即使有 instance_id 隔离，lockfile 提供额外的并发感知：

- **lockfile 路径**: `.claude/cache/audit-context/.audit-lock`
- **内容格式**: `instance_id={id}\nstarted={ISO timestamp}`
- **启动检查**: 编排者 Step 0 检查 lockfile：
  - lockfile 不存在 → 创建 lockfile，写入当前 instance_id
  - lockfile 存在且 mtime > 90min → 认定为孤儿残留（进程崩溃未清理），删除并重新创建
  - lockfile 存在且 mtime ≤ 90min → 输出 `⚠️ 已有审计实例运行中（{instance_id}），拒绝并发执行`，终止
- **结束清理**: 审计结束后（无论 🟢🟡🔵🔴），编排者删除 lockfile 和 {instance_id}/ 子目录
- **孤儿恢复**: 借鉴 AI Worker 的 `>2x CLAUDE_TIMEOUT` 孤儿检测模式。90min = 2x 全面审计最大预估时间(45min)
- **TOCTOU 风险**: 检查与创建之间存在竞争窗口（check-then-create 非原子操作）。已知局限——单用户场景下概率极低，企业多用户场景建议在 settings.json 配置 PreToolUse Hook 做平台级互斥。

### 跨平台说明

不使用 POSIX `flock()`（Windows 不支持）。文件锁是跨平台最简并发控制方案。

---

## 证据链完整性（企业级）

> **Why 需要证据链**: 企业审计需要不可篡改的证据——谁审的、什么时候审的、审出了什么、修了什么。SHA-256 hash + append-only log 提供基础防篡改能力。

### .audit-chain.json 格式

Append-only 日志，每行一条 JSON 记录（NDJSON 格式）：

```json
{"timestamp":"2026-07-02T14:30:52Z","file":"lens-security.json","sha256":"a1b2c3...","action":"write","instance_id":"audit-20260702-143052-a3f2"}
{"timestamp":"2026-07-02T14:35:12Z","file":"checklist-round-1.json","sha256":"d4e5f6...","action":"write","instance_id":"audit-20260702-143052-a3f2"}
{"timestamp":"2026-07-02T14:45:00Z","file":"lens-security.json","sha256":"g7h8i9...","action":"verify","instance_id":"audit-20260702-143052-a3f2","verified":true}
```

### 编排者责任

1. **写入时**: 每写入一个 JSON 文件 → 立即计算 SHA-256 → 追加到 `.audit-chain.json`
2. **读取时**: 读取 JSON 文件后 → 计算 SHA-256 → 与链中最新 hash 对比 → 不匹配则标记 `chain_break: true`
3. **结束时**: 在链中追加 `action: "audit_end"` 记录，含最终门控裁决 + C+H 计数
4. **清理策略**: 临时文件（lens JSON / checklist JSON）在审计结束后随 instance_id 子目录清理。企业产出物（报告 / SARIF / trend.json / .audit-chain.json）在清理前已完成写入，保留至少 90 天。如需提前清理 → 复制到外部存储
5. **保留期**: 90 天（与 lockfile 孤儿恢复阈值一致）

### 证据链断裂处理

| 场景 | 判定 | 动作 |
|------|------|------|
| 文件 hash 不匹配 | **证据链断裂** | → 标记该轮审计为 `EVIDENCE_TAMPERED` → 🔴 BLOCK → 通知用户 |
| .audit-chain.json 自身被修改 | **证据链断裂** | → 同上 |
| 链中缺失某文件记录 | **证据链不完整** | → 🟡 CAUTION → 审计健康度标注 |

**已知局限**: SHA-256 哈希链仅能检测意外损坏和弱篡改（非恶意覆盖），不支持加密签名验证。企业环境如需防篡改审计轨迹，建议在 CI pipeline 中对该文件做外部签名（GPG/HMAC）或写入 append-only 外部存储。

---

## 非 Git 项目降级清单

以下功能在非 git 项目中降级（检测方法：`.git` 目录不存在）：

| 标准功能 | 降级替代 | 精度影响 |
|----------|----------|----------|
| `git commit` 缓存绑定 | 跳过，仅用 tree_hash + dep_graph_hash | 缓存命中率略降（无法快速 O(1) 检查） |
| `git diff` 变更检测 | 用 mtime < 24h 的文件作为"变更集" | 可能包含未实际修改的文件，或遗漏 24h 外的变更 |
| `git log` 上下文 | 不可用，跳过 | 无法追溯文件变更历史 |
| Worktree 隔离 | 不可用，Agent 均为只读模式（天然隔离） | 无影响 |

降级不影响审计功能本身，仅降低增量扫描精度和缓存命中率。在 Step 0 和最终报告中标注非 git 警告。
