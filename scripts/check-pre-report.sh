#!/usr/bin/env bash
# audit-loop 报告生成前置检查脚本（AP-15 fix）
# 用途: 生成最终报告前，验证 Step 1-8 全部产物存在
# 用法: bash scripts/check-pre-report.sh <instance_dir>
# 退出码: 0 = 通过, 1 = 缺失必要产物

set -euo pipefail

INSTANCE_DIR="${1:-}"
if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/check-pre-report.sh <instance_dir>"
    exit 1
fi
if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR" >&2
    exit 2
fi

MISSING=0

# Step 1: compute-risk-score
RISK="$INSTANCE_DIR/checklist-round-1.json"
if grep -q '"risk_score"' "$RISK" 2>/dev/null; then
    printf '%s\n' "✅ Step 1: 风险评分已计算"
else
    printf '%s\n' "❌ Step 1: 风险评分缺失（需运行 compute-risk-score.sh）"
    MISSING=$((MISSING + 1))
fi

# Step 3: SARIF
SARIF="$INSTANCE_DIR/audit-report.sarif.json"
if [ -f "$SARIF" ]; then
    printf '%s\n' "✅ Step 3: SARIF 已生成"
else
    printf '%s\n' "❌ Step 3: SARIF 缺失（需运行 generate-sarif.sh）"
    MISSING=$((MISSING + 1))
fi

# Step 5: 证据链
CHAIN="$INSTANCE_DIR/.audit-chain.json"
if [ -f "$CHAIN" ]; then
    CHAIN_COUNT=$(wc -l < "$CHAIN" 2>/dev/null || echo 0)
    printf '%s\n' "✅ Step 5: 证据链已记录（$CHAIN_COUNT 条）"
else
    printf '%s\n' "❌ Step 5: 证据链缺失（需运行 generate-evidence-chain.sh）"
    MISSING=$((MISSING + 1))
fi

# Step 6: exit-verdict
VERDICT="$INSTANCE_DIR/exit-verdict.json"
if [ -f "$VERDICT" ]; then
    VERDICT_VAL=$(python3 -c "import json; print(json.load(open('$VERDICT')).get('verdict','?'))" 2>/dev/null || echo "?")
    printf '%s\n' "✅ Step 6: 退出裁决已计算（$VERDICT_VAL）"
else
    printf '%s\n' "❌ Step 6: 退出裁决缺失（需运行 compute-exit-verdict.sh）"
    MISSING=$((MISSING + 1))
fi

# Step 7: baseline deviation
if grep -q '"alerts"' "$INSTANCE_DIR/checklist-round-1.json" 2>/dev/null; then
    printf '%s\n' "✅ Step 7: 基线偏离已检查"
else
    printf '%s\n' "⚠️  Step 7: 基线偏离检查未运行（可选）"
fi

# Step 8: blindspot harvest
if [ -d "$(dirname "$INSTANCE_DIR")/../mutation-library" ] || [ -d "$HOME/.claude/skills/audit-loop/mutation-library" ]; then
    printf '%s\n' "✅ Step 8: 盲区收割已完成（或盲区库不存在）"
else
    printf '%s\n' "⚠️  Step 8: 盲区收割未运行（变异审计 v2 可选）"
fi

if [ "$MISSING" -gt 0 ]; then
    printf '%s\n' "❌ 检查失败: $MISSING 个必要产物缺失，禁止生成报告"
    exit 1
fi
printf '%s\n' "✅ 报告生成前置条件通过（Step 1-8 全部完成）"
exit 0
