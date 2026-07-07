---
name: audit
description: 启动 audit-loop 审计循环（自动询问简单/全面模式）
---

触发 audit-loop 技能，对指定范围执行审计-修复-验证全自动循环。

**用法**: `/audit-loop:audit [审计范围]`

**示例**:
- `/audit-loop:audit` — 审计当前项目，自动询问模式
- `/audit-loop:audit src/auth/` — 审计 src/auth/ 目录
- `/audit-loop:audit .claude/skills/audit-loop/` — 自审计

**流程**: 
1. 确认审计范围 → Token 档位选择
2. 视角推荐 → 用户选择视角
3. Round 1 4 透镜并行审计 → 输出问题清单
4. 用户选择「继续修复」或「停止（仅报告）」
5. 自动修复 → 验证 → 收敛自适应迭代
6. 门控裁决 → 企业级多角色输出
