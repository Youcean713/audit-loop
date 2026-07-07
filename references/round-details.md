# 审计循环详细步骤（索引）

> P2-1 fix: 本文件已按阶段拆分为 3 个子文件，编排者按需 Read 对应阶段。
> 本索引保留以兼容旧引用。拆分目的：简单审计不再加载 Round 2/3 内容（省 ~60% token）。

## 按阶段读取

| 阶段 | 文件 | 何时读 |
|------|------|--------|
| Round 1 | [round-1.md](round-1.md) | 进入 Round 1 前**立即 Read** |
| 修复阶段 | [fix-phase.md](fix-phase.md) | 修复阶段开始时**立即 Read** |
| Round 2/3 + 报告 | [round-2-3.md](round-2-3.md) | 进入验证阶段前**立即 Read** |

## 简单审计模式

简单审计读取 [simple-audit.md](simple-audit.md)（不使用合并审查官/收敛自适应策略，无需读 round-2-3.md）。

## 透镜配置

透镜模型分配和 Agent prompt 模板见 [lens-config.md](lens-config.md)。
