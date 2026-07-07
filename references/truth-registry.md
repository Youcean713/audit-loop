# 单一权威来源注册表 (Single Source of Truth Registry)

> 此文件记录 audit-loop skill 中所有关键声明的权威来源文件。
> 任何修改触及这些声明时，必须同步更新权威来源文件，再传播到引用文件。
> 合并审查官的「阶段 B: 跨文件一致性扫描」使用此表作为对照基准。

## 数值声明

| 声明 | 权威来源 | 引用文件 |
|------|---------|---------|
| 全面审计 Token 阈值（100K/250K/600K） | `references/guardrails.md`「全面审计」表 | SKILL.md Step 0 |
| 简单审计 Token 阈值（80K/150K/300K） | `references/guardrails.md`「简单审计」表 | SKILL.md Step 0, simple-audit.md |
| Agent spawn 计数（简单 3-5 / 全面 7-13） | `references/mode-comparison.md` | SKILL.md 对比表, simple-audit.md |
| 降级矩阵条目数（25） | `references/guardrails.md` 故障降级矩阵 | guardrails.md（自引用） |
| Agent token 预估值 | `references/lens-config.md`「全面审计 Agent 配置」 | — |

## 模型分配

| 声明 | 权威来源 | 引用文件 |
|------|---------|---------|
| 阶段 1 透镜模型（fable/sonnet/sonnet/haiku） | `references/lens-config.md`「全面审计 Agent 配置」表 | round-1.md |
| 全流程参与模型（fable/opus/sonnet/haiku） | `references/lens-config.md`「全面审计 Agent 配置」表 | SKILL.md 简单审计约束, merge-reviewer.md |
| 视角透镜模型分配 | `references/lens-config.md`「视角透镜配置」表 | mode-comparison.md |

## 术语定义

| 术语 | 权威来源 | 说明 |
|------|---------|------|
| "简单审计" / "全面审计" | `references/mode-comparison.md` | 模式对比的完整定义 |
| "技术透镜" / "视角透镜" | `references/round-1.md` Round 1 Step 1 | 两阶段并行的概念定义 |
| "阶段 1" / "阶段 2" | `references/round-1.md` Round 1 Step 1 | Round 1 内部的两阶段划分 |

## 流程规则

| 规则 | 权威来源 | 引用文件 |
|------|---------|---------|
| 自动推进暂停点（4 个） | `SKILL.md`「自动推进规则」 | simple-audit.md |
| 修复优先级（C→H→M→Low） | `SKILL.md`「修复阶段」 | fix-phase.md |
| 退出判断决策树 | `scripts/compute-exit-verdict.sh`（脚本强制执行） | SKILL.md「退出判断」, guardrails.md |
| 视角推荐失败回退 | `references/lens-config.md`「视角推荐 Agent 配置」 | SKILL.md Step 0b |
| 视角输出安全验证 | `scripts/validate-perspective-output.sh` | SKILL.md Step 0b |
| 资产分类规则 | `scripts/classify-assets.sh`（9 类模式匹配） | SKILL.md Step 0, risk-scoring.md |
| 风险评分公式 | `scripts/compute-risk-score.sh`（公式强制执行） | risk-scoring.md |
| Token 档位阈值 | `scripts/select-token-tier.sh` | SKILL.md Step 0, guardrails.md |
| 供应链检测 | `scripts/detect-supply-chain.sh` | SKILL.md Step 0 |
| SARIF 生成 | `scripts/generate-sarif.sh` | enterprise-output.md |
| 证据链 | `scripts/generate-evidence-chain.sh` | guardrails.md |
| 差异对比表 | `scripts/generate-diff-table.sh` | round-2-3.md |
| 基线偏离检查 | `scripts/check-baseline-deviation.sh` | SKILL.md「企业级多角色输出」 |

## 脚本注册表（🆕 AI + 脚本架构）

> 核心原则: 确定性逻辑强制脚本化，AI 只做语义判断。prose 规则会被编排者跳过，脚本不会。

| 脚本 | 阶段 | 替代的 prose | 退出码语义 |
|------|------|-------------|----------|
| `validate-input.sh` | Step 0 | 输入安全 7 层 | 0=PASS, 1=拒绝 |
| `setup-instance.sh` | Step 0 | instance_id + lockfile | 0=成功 |
| `classify-assets.sh` | Step 0 | 资产分类模式匹配 | 0=成功 |
| `detect-supply-chain.sh` | Step 0 | 依赖清单检测+SBOM | 0=成功 |
| `select-token-tier.sh` | Step 0 | Token 档位选择 | 0=成功 |
| `validate-perspective-output.sh` | Step 0b | 视角输出安全验证（C-4） | 0=PASS, 1=拒绝 |
| `mechanical-dedup.sh` | Step 2 降级 | 合并审查官降级去重 | 0=成功 |
| `pre-fix-impact.sh` | 修复前 | grep 影响分析 | 0=找到 |
| `consistency-check.sh` | 修复后 | 6 项一致性校验（含 Check 6 幽灵引用检测） | 0=通过, 1=不一致 |
| `compute-risk-score.sh` | 去重后 | 风险评分公式 | 0=成功 |
| `generate-diff-table.sh` | Round 2/3 | 差异对比表 | 0=成功 |
| `check-overridable.sh` | 🟡后 | overridable 残留检查 | 0=无残留, 1=有残留 |
| `enforce-medium-handled.sh` | 退出裁决前 | AP-14 Medium 处理强制检查 | 0=全部处理, 1=有未处理 |
| `compute-blast-radius.sh` | Round 2 前 | 变更文件+import链+配置文件 | 0=成功 |
| `match-issues.sh` | 重审后 | 跨轮 issue 相似度匹配 | 0=成功 |
| `compute-exit-verdict.sh` | 退出 | 门控决策树（最关键） | 0=SHIP/CAUTION, 1=HOLD, 2=BLOCK |
| `generate-sarif.sh` | 输出 | SARIF v2.1.0 生成 | 0=成功 |
| `generate-evidence-chain.sh` | 输出 | SHA-256 证据链 | 0=成功, 2=链断裂 |
| `check-baseline-deviation.sh` | 输出 | 基线偏离告警 | 0=无告警, 1=有告警 |
| `harvest-blindspots.sh` | 输出后（每次审计） | 盲区收割→自生长库（变异审计 v2） | 0=成功 |
| `generate-final-report.sh` | 输出 | 标准化中文报告生成（调用 generate_final_report.py） | 0=成功 |
| `generate_final_report.py` | 输出 | 中文报告生成器（固定七段结构，全部中文） | 0=成功 |
| `determine-convergence.sh` | Round 2/3 | 收敛分支判定（A/B/C） | 0=成功 |
| `check-pre-merge.sh` | Round 1 Step 2 | 合并审查官前置检查 | 0=通过, 1=缺失 |
| `check-pre-verify.sh` | Round 2 | 验证 Agent 前置检查 | 0=通过, 1=未修复 |
| `check-pre-report.sh` | 输出 Step 9 | 报告生成前置检查 | 0=通过, 1=缺失 |
| `check-pre-lens.sh` | Round 2+ | 透镜 Spawn 前置检查（上轮未修复 issue 注入） | 0=通过 |
| `validate-lens-regression.sh` | lens 改动时（按需） | 透镜回归 MSI 计算 | 0=MSI≥70%, 1=退化, 2=错误 |
| `cleanup-instance.sh` | 结束 | 临时文件清理 | 0=完成 |
| `check-agent-spawn.sh` | 🆕 Hook (PreToolUse) | Agent spawn 前置条件验证（AP-13 强制执行） | 0=允许, 2=阻止 |
| `check-agent-output.sh` | 🆕 Hook (SubagentStop) | Agent 输出产品验证（JSON 有效性检查） | 0=有效, 2=无效 |
| `check-audit-complete.sh` | 🆕 Hook (Stop) | 审计完整性门控（防未完成退出） | 0=可退出, 2=阻止 |
| `save-audit-context.sh` | 🆕 Hook (PreCompact) | 压缩前快照保存（防上下文丢失） | 0=放行 |

## Plugin 架构（🆕 v2.0.0）

| 规则 | 权威来源 | 说明 |
|------|---------|------|
| 收敛分支判定（Case A/B/C） | `SKILL.md`「Round 2/3」+ `round-2-3.md` | 快收敛→全量重审+模型洗牌；正常→blast-radius重审；不收敛→聚焦重审 |
| 模型洗牌映射（第二审计员效应） | `agents/verifier.md` Mode A FULL_REAUDIT_SHUFFLED | 安全fable→opus / 架构sonnet→fable / 质量sonnet→opus / 性能haiku→sonnet |
| 跨轮 issue 匹配算法 | `scripts/match-issues.sh` | 精确匹配(file+line) → 模糊匹配(file+重叠+描述相似度≥0.6) → 未匹配=New |
| 变异审计（v2 方向） | `references/THREAT-MODEL.md`「未来增强」 | 注入已知 issue 模板验证透镜捕获率（类比 PITest MSI） |

## 占位符

| 占位符 | 权威形式 | 使用场景 |
|--------|---------|---------|
| 审计范围 | `{审计范围}` | 所有透镜 Agent prompt、编排者调用 |
| 输出路径 | `{输出路径}` | 单个文件输出（技术透镜） |
| 实例目录 | `{instance_dir}` | 多文件读写（视角透镜、合并审查官、验证 Agent） |
| 项目根目录 | `{project_root}` | 视角推荐 Agent |

## 维护规则

1. **修改权威来源时**：必须同步更新「引用文件」列中的全部文件。
2. **新增声明时**：在此表中注册权威来源。
3. **合并审查官校验时**：以本表作为对照基准——若某声明在引用文件中的表述与权威来源不一致，标记为 `consistency_gap`。
4. **本表自身修改**：视为对 skill 架构的变更，需同步更新受影响的引用文件。
5. **C-6 fix**: 移除了对不存在的 `AUDIT-ARCHITECTURE.md` 的全部引用（原 6 处），权威来源改为实际存在的文件（lens-config.md/round-1.md/guardrails.md）。
