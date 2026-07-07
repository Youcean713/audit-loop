# audit-loop — 多模型多维度代码审计循环

> Plugin v2.0.0 | Claude Code 代码审计插件
>
> 审计发现 → 修复 → 验证 → 自动迭代，直到真正通过。支持简单/全面双模式，四维度全覆盖，四层 Hook 强制执行。

[![version](https://img.shields.io/badge/version-2.0.0-blue)](.claude-plugin/plugin.json) [![license](https://img.shields.io/badge/license-MIT-green)](LICENSE) [![mode](https://img.shields.io/badge/Claude%20Code-Plugin%20v2-orange)](https://code.claude.com/docs/en/plugins)

---

## 目录

- [核心特性](#核心特性)
- [架构概览](#架构概览)
- [安装](#安装)
- [快速开始](#快速开始)
- [审计模式](#审计模式)
- [配置要求](#配置要求)
- [目录结构](#目录结构)
- [Hook 系统](#hook-系统)
- [Agent 列表](#agent-列表)
- [脚本能力](#脚本能力)
- [企业级输出](#企业级输出)
- [故障排查](#故障排查)
- [已知平台限制](#已知平台限制)
- [开发与贡献](#开发与贡献)
- [许可](#许可)

---

## 核心特性

- **四维度审计**：安全（OWASP/CVE/CWE）、架构（耦合/内聚/可扩展）、质量（错误处理/资源管理）、性能（Token 效率/缓存）
- **多模型覆盖**：fable（安全）/ sonnet（架构+质量）/ haiku（性能）/ opus（合并审查官）— 3 种模型覆盖 4 个技术透镜（+opus 合并审查官），最大化对抗性审查的模型多样性
- **双模式**：🔍 简单审计（8-15min，2 合并透镜）+ 🔬 全面审计（20-25min，4 独立透镜 + 视角透镜 + 专用合并审查官）
- **自动循环**：发现 → 修复 → 验证 → 收敛自适应迭代（🟢🟡🔵🔴 四灯决策）
- **四层 Hook 强制执行**：PreToolUse + SubagentStop + Stop + PreCompact — 防止编排者跳过步骤、Agent 输出残缺、上下文压缩丢失
- **AI + 脚本架构**：30+ 自动化脚本承担机械操作（输入校验、资产分类、一致性检查、退出裁决），编排者只做语义判断
- **企业级输出**：3 份角色报告（开发者/管理层/合规）+ SARIF v2.1.0 + SHA-256 证据链 + 趋势追踪
- **安全纵深**：7 层输入校验 + 二阶注入防御 + jq 优先 JSON 解析（消除 shell 插值注入）

---

## 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                    编排者（主 Claude / SKILL.md）             │
│   职责：派发 Agent → 收集结果 → 修复 → 判断是否继续           │
└──────────┬──────────────────────────────────┬───────────────┘
           │ spawn (subagent_type)             │ 调用脚本
           ▼                                  ▼
┌──────────────────────┐         ┌──────────────────────────┐
│  9 个具名 Agent      │         │  30+ 自动化脚本           │
│  (fable/sonnet/haiku │         │  (validate-input.sh       │
│   /opus 多模型)      │         │   consistency-check.sh    │
│  4 技术透镜 + 视角   │         │   compute-exit-verdict.sh │
│  + 合并/验证/推荐    │         │   ... 机械操作强制执行)   │
└──────────┬───────────┘         └──────────────────────────┘
           │ SubagentStop
           ▼
┌─────────────────────────────────────────────────────────────┐
│              四层 Hook 强制执行（hooks/hooks.json）          │
│  PreToolUse  → 强制 subagent_type + 前置条件检查             │
│  SubagentStop → agent_type 精确校验输出产品                  │
│  Stop        → decision:block 防止审计未完成退出             │
│  PreCompact  → 压缩前保存快照，防上下文丢失                  │
└─────────────────────────────────────────────────────────────┘
```

**设计哲学**：能用 Hook 强制的不靠 prose 规则，能用脚本机械执行的不靠编排者记忆。编排者只做语义判断（范围是否明确、修复是否合理），其余委托给 Agent 和脚本。

---

## 安装

### 为什么不用 marketplace？

Claude Code v2.1.202 不支持第三方 marketplace 插件源（[Issue #41653](https://github.com/anthropics/claude-code/issues/41653)）。因此 audit-loop 通过 **git clone 到 skills 目录** 安装，由 Claude Code 自动发现。

### 个人安装

```bash
# 方式 A：从 GitLab（内网，主仓库）
git clone git@gitlab.hopechart.com:wenxiang.you/audit-loop.git ~/.claude/skills/audit-loop

# 方式 B：从 GitHub（外网镜像）
git clone git@github.com:Youcean713/audit-loop.git ~/.claude/skills/audit-loop
```

安装后重启 Claude Code（或执行 `/reload-plugins`），插件自动生效。

### 团队分发

团队项目可通过 onboarding 脚本统一安装：

```bash
# 团队 deploy 脚本示例（可加入项目 onboarding）
if [ ! -d ~/.claude/skills/audit-loop ]; then
  git clone git@gitlab.hopechart.com:wenxiang.you/audit-loop.git ~/.claude/skills/audit-loop
  echo "✅ audit-loop 已安装，请重启 Claude Code"
fi
```

### 验证安装

```bash
# 1. 确认目录存在
ls ~/.claude/skills/audit-loop/SKILL.md

# 2. 在 Claude Code 中执行
/doctor
# 预期：4 plugins / 3 skills / 16 agents / 4 hooks / 0 errors
```

### 升级

```bash
cd ~/.claude/skills/audit-loop
git pull
/reload-plugins   # 在 Claude Code 中重载
```

---

## 快速开始

在 Claude Code 中直接输入斜杠命令：

```
/audit-loop:audit     → 启动审计（自动询问简单/全面模式）
/audit-loop:full      → 直接启动全面审计（20-25min）
/audit-loop:simple    → 直接启动简单审计（8-15min）
```

或用自然语言触发：

- "全面审计一下这个项目，有问题就修" → 🔬 全面审计
- "简单审计一下 src/auth/" → 🔍 简单审计
- "审计一下这个模块" → ❓ 询问模式

---

## 审计模式

| 维度 | 🔍 简单审计 | 🔬 全面审计 |
|------|-----------|-----------|
| 审计覆盖 | 4 维度全覆盖 | 4 维度全覆盖 |
| 透镜 Agent | 2 个合并（S+A sonnet / Q+P haiku） | 4 个独立（fable/sonnet/sonnet/haiku） |
| 视角透镜 | 0-1 个合并（haiku） | 0-5 个独立（sonnet/haiku） |
| 去重合并 | 编排者机械去重 | 专用合并审查官（四级审查） |
| 验证 | 编排者 + 条件深度验证 | 专用验证+终裁 Agent |
| Blast-Radius | 简化版 | git diff + grep import 全量 |
| Agent spawn | 3-5 次 | 7-13 次 |
| **耗时** | **8-15 分钟** | **20-25 分钟** |
| **适用** | 日常改动、PR 审查 | 关键模块上线、安全合规 |

> 两种模式覆盖相同审计清单，区别在 Agent 数量和审查深度。简单审计 ≠ 简陋审计。

---

## 配置要求

### 必需

- **Claude Code v2.1.202+**（支持 Plugin v2.0.0 的 hooks/agents/commands 目录）
- **Python 3.8+**（脚本依赖，用于 JSON 解析和决策树）

### 推荐

- **jq**（JSON 解析优先使用，缺失时自动回退 Python，但有 jq 性能更好且无注入风险）
- **git**（blast-radius 增量扫描、修复范围校验依赖）

### 模型映射

audit-loop 使用 4 个模型档位，通过 Claude Code 环境变量映射到实际模型：

| 档位 | 用途 | 环境变量 |
|------|------|---------|
| fable | 安全透镜（最高精度） | `ANTHROPIC_DEFAULT_FABLE_MODEL` |
| sonnet | 架构+质量透镜（大上下文） | `ANTHROPIC_DEFAULT_SONNET_MODEL` |
| haiku | 性能透镜 + 视角推荐（轻量） | `ANTHROPIC_DEFAULT_HAIKU_MODEL` |
| opus | 合并审查官（最高判断力） | `ANTHROPIC_DEFAULT_OPUS_MODEL` |

若使用自建 API 网关，在 `~/.claude/settings.json` 的 `env` 中配置映射。模型缺失时自动降级（见 `references/guardrails.md` 降级矩阵）。

---

## 目录结构

```
audit-loop/
├── .claude-plugin/
│   └── plugin.json              # 插件清单（注册 agents/commands/hooks）
├── SKILL.md                     # 编排技能（主流程）
├── commands/                    # 3 个斜杠命令入口
│   ├── audit.md                 # /audit-loop:audit（询问模式）
│   ├── full.md                  # /audit-loop:full（直接全面）
│   └── simple.md                # /audit-loop:simple（直接简单）
├── agents/                      # 9 个具名 Agent
│   ├── lens-security.md         # 安全透镜（fable）
│   ├── lens-architecture.md     # 架构透镜（sonnet）
│   ├── lens-quality.md          # 质量透镜（sonnet）
│   ├── lens-performance.md      # 性能透镜（haiku）
│   ├── lens-perspective.md      # 视角透镜（通用）
│   ├── merge-reviewer.md        # 合并审查官（opus）
│   ├── verifier.md              # 验证+终裁（sonnet）
│   ├── perspective-recommender.md # 视角推荐（sonnet）
│   └── code-auditor.md          # 独立单次审计（sonnet）
├── hooks/                       # 4 层 Hook + 共享状态读取器
│   ├── hooks.json               # Hook 事件配置
│   ├── check-agent-spawn.sh     # PreToolUse: 强制 subagent_type + 前置条件
│   ├── check-agent-output.sh    # SubagentStop: agent_type 校验输出
│   ├── check-audit-complete.sh  # Stop: 防止审计未完成退出
│   ├── save-audit-context.sh    # PreCompact: 压缩前保存快照
│   └── audit-state.sh           # 共享状态读取函数库
├── scripts/                     # 30+ 自动化脚本
│   ├── validate-input.sh        # 7 层输入安全校验
│   ├── setup-instance.sh        # 实例初始化 + 并发隔离
│   ├── classify-assets.sh       # 资产分类（PII/PCI/AUTH...）
│   ├── consistency-check.sh     # 5 项跨文件一致性校验
│   ├── compute-exit-verdict.sh  # 8 条决策树退出裁决
│   ├── enforce-medium-handled.sh # AP-14: Medium 处理强制检查
│   ├── generate_final_report.py # 最终报告生成器
│   ├── generate-sarif.sh        # SARIF v2.1.0 生成
│   └── ...
├── references/                  # 渐进式披露文档（按需 Read）
│   ├── round-1.md               # Round 1 透镜 spawn
│   ├── fix-phase.md             # 修复阶段
│   ├── round-2-3.md             # 收敛验证 + 终裁
│   ├── round-details.md         # Round 阶段索引（已拆分为 round-1/fix-phase/round-2-3）
│   ├── lens-config.md           # 透镜模型配置
│   ├── guardrails.md            # Token 守卫 + 降级矩阵
│   ├── known-issues.md          # 已知平台限制
│   ├── mode-comparison.md       # 模式对比
│   ├── risk-scoring.md          # 风险评分公式
│   ├── standards-map.md         # 企业标准映射
│   ├── truth-registry.md        # 权威值注册表
│   ├── enterprise-output.md     # 企业输出模板
│   ├── simple-audit.md          # 简单审计详细步骤
│   └── THREAT-MODEL.md          # 威胁模型
└── evals/evals.json             # 测试用例
```

---

## Hook 系统

四层 Hook 在编排者和 Agent 之间强制执行流程契约，不占用上下文 token（零成本扩展）：

| Hook 事件 | 触发时机 | 作用 | 修复的缺陷 |
|-----------|---------|------|-----------|
| **PreToolUse** | Agent spawn 前 | 强制 `subagent_type`（禁通用 Agent）+ 前置条件检查（verifier 要求 Medium 已处理、merge-reviewer 要求 4 透镜齐全） | AP-12, AP-14 |
| **SubagentStop** | Agent 完成后 | 用 stdin `agent_type` 字段精确校验输出产品（文件存在 + 有效 JSON + 必填字段） | C-1, M-1, M-4 |
| **Stop** | 编排者准备退出 | `decision:block` + exit 2 双保险，防止审计未完成退出；区分"等待用户确认"vs"步骤未完成" | AP-13, AP-16 |
| **PreCompact** | 上下文压缩前 | 保存当前 phase/round/checklist 摘要到快照，防 `/compact` 丢上下文 | AP-13 技术根因 |

**状态文件机制**：编排者通过 `~/.claude/skills/audit-loop/.audit-state.json` 与 Hook 共享上下文（instance_dir、phase、round、pending_user_confirmation）。该文件在 `.gitignore` 中排除（运行时产物）。

---

## Agent 列表

9 个具名 Agent，通过 `subagent_type="audit-loop:xxx"` 调用，各有专长模型和工具限制：

| Agent | 模型 | 工具限制 | 职责 |
|-------|------|---------|------|
| lens-security | fable | + Bash/Edit/Agent 禁用 | OWASP 注入链、认证、加密、合规 |
| lens-architecture | sonnet | + Bash/Edit/Agent 禁用 | 耦合、一致性、实现忠实度 |
| lens-quality | sonnet | + Bash/Edit/Agent 禁用 | 清晰度、完备性、错误处理 |
| lens-performance | haiku | + Edit/Agent 禁用 | Token 效率、缓存、懒加载 |
| lens-perspective | sonnet | + Bash/Edit/Agent 禁用 | 利益相关者视角重评估 |
| merge-reviewer | opus | + Bash/Edit/Agent 禁用 | 去重+跨文件一致性+盲区+补盲 |
| verifier | sonnet | + Edit/Agent 禁用 | 验证修复+终裁+收敛自适应重审 |
| perspective-recommender | sonnet | + Bash/Edit/Write/Agent 禁用 | 分析项目推荐审计视角 |
| code-auditor | sonnet | 保留 WebFetch/WebSearch | 独立单次审计（非循环） |

> 所有 Agent 加了 `maxTurns`（防 haiku 超时）和 `effort`（推理深度）。工具限制由 `tools`/`disallowedTools` 字段运行时强制，PreToolUse Hook 兜底（已知平台 bug 见 `references/known-issues.md`）。

---

## 脚本能力

30+ 脚本承担所有机械操作，编排者不可跳过：

| 类别 | 脚本 | 作用 |
|------|------|------|
| **输入安全** | validate-input.sh | 7 层校验（NFKC/换行/URL/反引号/白名单/黑名单/Unicode） |
| **实例管理** | setup-instance.sh, cleanup-instance.sh | instance_id 生成 + 并发 lockfile |
| **资产分析** | classify-assets.sh, detect-supply-chain.sh | 9 类资产分类 + SBOM 生成 |
| **审计执行** | check-pre-lens.sh, check-pre-merge.sh, check-pre-verify.sh | 阶段前置条件强制 |
| **修复校验** | pre-fix-impact.sh, consistency-check.sh, enforce-medium-handled.sh | 影响分析 + 5 项一致性 + Medium 处理 |
| **收敛判定** | compute-blast-radius.sh, determine-convergence.sh | 变更影响 + Case A/B/C 分支 |
| **退出裁决** | compute-exit-verdict.sh, check-overridable.sh | 8 条决策树 + overridable 残留 |
| **企业输出** | compute-risk-score.sh, generate-sarif.sh, generate-evidence-chain.sh, generate-final-report.sh | 风险分+SARIF+证据链+报告 |
| **自生长** | harvest-blindspots.sh, validate-lens-regression.sh | 盲区库收割 + 透镜回归验证 |

---

## 企业级输出

退出判断后自动生成：

- **3 份角色报告**：`audit-report-dev.md`（开发者修复清单）、`audit-report-exec.md`（管理层风险摘要）、`audit-report-compliance.md`（合规控制矩阵）
- **SARIF v2.1.0**：`audit-report.sarif.json`（CI/CD 可消费，含 `partialFingerprints` + `properties`）
- **证据链**：`.audit-chain.json`（所有输出文件 SHA-256 hash，append-only 防篡改）
- **趋势追踪**：`trend.json`（跨轮次 C+H/风险分/修复成功率/回归率）
- **工单**：`requires_human` 的 issue 生成 GitHub Issues 格式 body

输出目录：`~/.claude/skills/audit-loop/.claude/cache/audit-context/{instance_id}/`

---

## 故障排查

### Hook 不生效

```bash
# 1. 确认 hooks.json 有效
python -c "import json; json.load(open('~/.claude/skills/audit-loop/hooks/hooks.json'))"

# 2. 确认脚本存在
ls ~/.claude/skills/audit-loop/hooks/*.sh

# 3. /doctor 检查 hooks 数量（预期 4）
```

### Stop Hook 反复阻止退出

说明审计未完成。检查 `.audit-state.json` 的 `phase` 字段，完成对应步骤或手动清理：

```bash
rm ~/.claude/skills/audit-loop/.audit-state.json  # 强制清理（放弃当前审计）
```

### Agent 被误阻止（AP-12）

PreToolUse 要求 `subagent_type`。若编排者用 `Agent(model=..., prompt=...)` 通用调用会被 exit 2 阻止。正确方式：

```python
Agent(subagent_type="audit-loop:lens-security", model="fable", prompt="...")
```

### python/jq 不可用

脚本优先用 jq，缺失时回退 Python。两者都不可用时 Hook 静默放行（不阻塞非审计场景）。建议安装 jq：

```bash
# Windows (Git Bash)
choco install jq
# macOS
brew install jq
```

---

## 已知平台限制

详见 [`references/known-issues.md`](references/known-issues.md)。摘要：

- 插件 Agent 不支持 frontmatter 的 `hooks`/`mcpServers`/`permissionMode` 字段（平台限制）
- `tools`/`disallowedTools` 运行时强制，但有 3 个未修复 bug（SDK #172、#63762、#31292），由 PreToolUse Hook 兜底
- `${CLAUDE_PLUGIN_ROOT}` 在 Bash 工具调用中不可用（Issue #136），脚本用 `dirname "$0"` 推导
- Stop Hook 的 exit 2 经 marketplace 分发时可能失效（Issue #10412），用 `decision:block` 双保险
- 第三方 marketplace 不支持（Issue #41653），故用 git clone 安装

---

## 开发与贡献

### 本地开发

```bash
git clone git@gitlab.hopechart.com:wenxiang.you/audit-loop.git
cd audit-loop

# 修改后本地验证
bash scripts/consistency-check.sh             # 一致性校验
echo '{"agent_type":"audit-loop:lens-security"}' | bash hooks/check-agent-output.sh  # Hook 测试

# 重载插件
/reload-plugins
```

### 自审计

audit-loop 可以审计自身（狗食）：

```
/audit-loop:full
# 审计范围：~/.claude/skills/audit-loop/
```

### 仓库

- **GitLab（主）**：`git@gitlab.hopechart.com:wenxiang.you/audit-loop.git`
- **GitHub（镜像）**：`git@github.com:Youcean713/audit-loop.git`

提交规范：`<type>: <简短中文描述>`（如 `fix:`、`feat:`、`refactor:`）。审计类修复附根因分析。

---

## 许可

MIT
