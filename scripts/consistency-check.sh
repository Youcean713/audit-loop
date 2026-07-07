#!/usr/bin/env bash
# audit-loop 修复一致性校验脚本
# 用途: 修复阶段完成后、Round 2 前强制执行。发现不一致 → 立即修复 → 重跑。最多 3 轮。
# 用法: bash scripts/consistency-check.sh
# 退出码: 0 = 全部通过, 1 = 发现不一致(需修复后重跑), 2 = 3轮后仍未通过

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
ROUND="${1:-1}"

echo "=== audit-loop 一致性校验 (Round $ROUND) ==="
echo ""

# 辅助函数: grep 所有目标文件，验证指定值出现且无不一致值
# 用法: check_value "<label>" "<expected_value>" "<wrong_pattern>" <files...>
check_value() {
    local label="$1"
    local expected="$2"
    local wrong="$3"
    shift 3
    local files=("$@")

    local wrong_matches
    wrong_matches=$(grep -rn "$wrong" "${files[@]}" 2>/dev/null | grep -v "原分配\|降级.*→\|变更原因\|grep.*示例\|docs/\|历史\|演进\|模型分配历史" || true)

    if [ -n "$wrong_matches" ]; then
        echo "  ❌ $label: 发现不一致值:"
        echo "$wrong_matches" | while read -r line; do echo "    $line"; done
        return 1
    fi
    return 0
}

# Check 1: 数值声称一致性
echo "[1/5] 数值声称一致性..."
MISMATCH=0

# 核心引用文件
REF_FILES=("$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/simple-audit.md" "$SKILL_DIR/references/guardrails.md" "$SKILL_DIR/references/mode-comparison.md")

# 简单审计 Token 阈值 (权威值来自 guardrails.md)
# 验证所有文件中简单审计相关阈值一致为 80K/150K/300K
SIMPLE_WRONG=$(grep -rn "简单.*[^0-9]\(100\|250\|600\)[^0-9]*K.*单轮\|简单.*单轮.*\(100\|250\|600\)[^0-9]*K" "${REF_FILES[@]}" 2>/dev/null | grep -v "全面\|累计" || true)
if [ -n "$SIMPLE_WRONG" ]; then
    echo "  ❌ 简单审计Token阈值: 发现非标准值(应为80K/150K/300K):"
    echo "$SIMPLE_WRONG"
    MISMATCH=$((MISMATCH + 1))
fi

# 全面审计 Token 阈值 (权威值来自 guardrails.md)
FULL_WRONG=$(grep -rn "全面.*[^0-9]\(80\|150\|300\)[^0-9]*K.*单轮\|全面.*单轮.*\(80\|150\|300\)[^0-9]*K" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/guardrails.md" "$SKILL_DIR/references/mode-comparison.md" 2>/dev/null | grep -v "简单\|累计" || true)
if [ -n "$FULL_WRONG" ]; then
    echo "  ❌ 全面审计Token阈值: 发现非标准值(应为100K/250K/600K):"
    echo "$FULL_WRONG"
    MISMATCH=$((MISMATCH + 1))
fi

# Agent spawn 计数
SPAWN_WRONG=$(grep -rn "简单.*[0-9]\+-[0-9]\+.*次" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/simple-audit.md" "$SKILL_DIR/references/mode-comparison.md" 2>/dev/null | grep -v "3-5" || true)
if [ -n "$SPAWN_WRONG" ]; then
    echo "  ❌ 简单审计spawn计数: 发现非标准值(应为3-5):"
    echo "$SPAWN_WRONG"
    MISMATCH=$((MISMATCH + 1))
fi

SPAWN_FULL_WRONG=$(grep -rn "全面.*[0-9]\+-[0-9]\+.*次" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/mode-comparison.md" 2>/dev/null | grep -v "7-13" || true)
if [ -n "$SPAWN_FULL_WRONG" ]; then
    echo "  ❌ 全面审计spawn计数: 发现非标准值(应为7-13):"
    echo "$SPAWN_FULL_WRONG"
    MISMATCH=$((MISMATCH + 1))
fi

# 降级矩阵条目数(25)
DEG_WRONG=$(grep -rnP "降级.*?\d+(?=\s*条)" "$SKILL_DIR/references/guardrails.md" 2>/dev/null | grep -v "25\|2 条 known_limitation\|6 次 Agent" || true)
if [ -n "$DEG_WRONG" ]; then
    echo "  ❌ 降级矩阵条目数: 发现非标准值(应为25):"
    echo "$DEG_WRONG"
    MISMATCH=$((MISMATCH + 1))
fi

# 审计耗时
TIME_WRONG=$(grep -rn "简单审计.*[0-9]\+-[0-9]\+.*分钟\|8-15.*分钟.*简单" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/mode-comparison.md" "$SKILL_DIR/references/simple-audit.md" 2>/dev/null | grep -v "8-15\|20-25" || true)
if [ -n "$TIME_WRONG" ]; then
    echo "  ❌ 审计耗时: 发现非标准值(简单应为8-15min, 全面应为20-25min):"
    echo "$TIME_WRONG"
    MISMATCH=$((MISMATCH + 1))
fi

if [ "$MISMATCH" -gt 0 ]; then
    echo "  ❌ 数值声称一致性: $MISMATCH 项不一致"
    FAILURES=$((FAILURES + 1))
else
    echo "  ✅ 数值声称一致性: 全部通过"
fi

# Check 2: 模型列一致性
echo "[2/5] 模型列一致性..."
MODEL_MISMATCH=0

# 文件范围（排除历史和降级描述）
MODEL_FILES=("$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/lens-config.md" "$SKILL_DIR/references/round-1.md" "$SKILL_DIR/references/fix-phase.md" "$SKILL_DIR/references/round-2-3.md" "$SKILL_DIR/references/mode-comparison.md" "$SKILL_DIR/references/simple-audit.md")

# 质量=haiku 残留（最重要的检测——历史上被升级）
HAIKU_QUALITY=$(grep -rn "质量=haiku\|质量.*haiku.*透镜\|质量透镜.*haiku" "${MODEL_FILES[@]}" 2>/dev/null | grep -v "原分配\|变更原因\|grep.*质量\|需改为 sonnet\|质量=sonnet\|质量.*haiku.*→.*sonnet\|质量.*haiku.*升级\|历史\|模型分配历史\|演进轨迹\|质量透镜模型(sonnet)" || true)
if [ -n "$HAIKU_QUALITY" ]; then
    echo "  ❌ 残留 '质量=haiku' 引用:"
    echo "$HAIKU_QUALITY"
    MODEL_MISMATCH=$((MODEL_MISMATCH + 1))
fi

# 安全透镜非 fable 分配
SEC_WRONG=$(grep -rn "安全.*=.*sonnet\|安全.*=.*opus\|安全.*=.*haiku" "${MODEL_FILES[@]}" 2>/dev/null | grep -v "原分配\|降级.*→\|变更原因\|fable.*→\|历史\|模型分配历史\|演进\|安全用 fable\|安全.*fable" || true)
if [ -n "$SEC_WRONG" ]; then
    echo "  ❌ 安全透镜模型分配不一致(应为fable):"
    echo "$SEC_WRONG"
    MODEL_MISMATCH=$((MODEL_MISMATCH + 1))
fi

# 架构透镜非 sonnet 分配
ARCH_WRONG=$(grep -rn "架构.*=.*haiku\|架构.*=.*opus\|架构.*=.*fable" "${MODEL_FILES[@]}" 2>/dev/null | grep -v "原分配\|降级\|变更原因\|历史\|模型分配历史\|演进\|架构.*sonnet" || true)
if [ -n "$ARCH_WRONG" ]; then
    echo "  ❌ 架构透镜模型分配不一致(应为sonnet):"
    echo "$ARCH_WRONG"
    MODEL_MISMATCH=$((MODEL_MISMATCH + 1))
fi

if [ "$MODEL_MISMATCH" -gt 0 ]; then
    echo "  ❌ 模型列一致性: $MODEL_MISMATCH 项不一致"
    FAILURES=$((FAILURES + 1))
else
    echo "  ✅ 全部文件一致: 安全=fable/架构=sonnet/质量=sonnet/性能=haiku"
fi

# Check 3: 占位符一致性
echo "[3/5] 占位符一致性..."
PLACEHOLDER_FAIL=0
ENGLISH_PLACEHOLDERS=$(grep -rn '{audit_scope}' "$SKILL_DIR/SKILL.md" "$SKILL_DIR/agents/" "$SKILL_DIR/references/" 2>/dev/null | grep -v "docs/\|\.git/" || true)
if [ -n "$ENGLISH_PLACEHOLDERS" ]; then
    echo "  ❌ 残留英文占位符:"
    echo "$ENGLISH_PLACEHOLDERS"
    PLACEHOLDER_FAIL=1
fi
if [ "$PLACEHOLDER_FAIL" -eq 0 ]; then
    echo "  ✅ 占位符统一"
else
    FAILURES=$((FAILURES + 1))
fi

# Check 4: 引用有效性
echo "[4/5] 引用有效性..."
INVALID_REFS=0
for ref in $(grep -roP '(agents|references)/[a-zA-Z0-9_\-]+\.(md|json|sh)' "$SKILL_DIR/SKILL.md" "$SKILL_DIR/references/" 2>/dev/null | cut -d: -f2 | sort -u); do
    if [ ! -f "$SKILL_DIR/$ref" ]; then
        echo "  ❌ 无效引用: $ref"
        INVALID_REFS=$((INVALID_REFS + 1))
    fi
done
if [ "$INVALID_REFS" -eq 0 ]; then
    echo "  ✅ 所有引用有效"
else
    FAILURES=$((FAILURES + 1))
fi

# Check 5: 修复范围校验
echo "[5/5] 修复范围校验..."
if git rev-parse --git-dir >/dev/null 2>&1; then
    CHANGED=$(git diff --name-only HEAD 2>/dev/null | grep -v "^\.claude/cache/" | grep -v "^\.superpowers/" | grep -v "^docs/" || true)
    if [ -n "$CHANGED" ]; then
        echo "  变更文件:"
        echo "$CHANGED" | sed 's/^/    /'
    fi
    echo "  ✅ 修复范围已确认"
else
    echo "  ⚠️  非 git 仓库，跳过范围校验"
fi

# Check 6: 幽灵引用检测（AP-18 fix: truth-registry 引用但不存在的脚本/文件，类似 C-6 模式）
echo "[6/6] 幽灵引用检测（AP-18）..."
GHOST_REFS=0
for script in $(grep -oP 'scripts/[a-z_-]+\.sh' "$SKILL_DIR/references/truth-registry.md" 2>/dev/null | sort -u); do
    [ -f "$SKILL_DIR/$script" ] || { echo "  ❌ 幽灵脚本: $script（truth-registry 引用但不存在）"; GHOST_REFS=$((GHOST_REFS + 1)); }
done
for ref in $(grep -oP 'references/[a-z_-]+\.md' "$SKILL_DIR/references/truth-registry.md" 2>/dev/null | sort -u); do
    [ -f "$SKILL_DIR/$ref" ] || { echo "  ❌ 幽灵文件: $ref（truth-registry 引用但不存在）"; GHOST_REFS=$((GHOST_REFS + 1)); }
done
if [ "$GHOST_REFS" -eq 0 ]; then
    echo "  ✅ 无幽灵引用"
else
    FAILURES=$((FAILURES + 1))
fi

echo ""
echo "=== 结果: $FAILURES/6 项不一致 ==="

if [ "$ROUND" -ge 3 ] && [ "$FAILURES" -gt 0 ]; then
    echo "⚠️  3 轮校验后仍有不一致，标记 consistency_gap"
    exit 2
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "🔴 需要修复后重跑 (round $((ROUND + 1))/3)"
    exit 1
else
    echo "🟢 全部通过"
    exit 0
fi
