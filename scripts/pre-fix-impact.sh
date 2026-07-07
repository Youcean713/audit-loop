#!/usr/bin/env bash
# audit-loop 修复前影响分析脚本
# 用途: 修改前 grep 全项目定位所有受影响位置，防止"改一处忘同步"
# 用法: bash scripts/pre-fix-impact.sh "<搜索模式>" [--type model|number|placeholder]
# 退出码: 0 = 找到匹配, 1 = 无匹配(可能模式有误)

set -euo pipefail

PATTERN="${1:-}"
TYPE="${2:-}"

if [ -z "$PATTERN" ]; then
    echo "用法: bash scripts/pre-fix-impact.sh '<grep模式>' [--type model|number|placeholder]"
    echo ""
    echo "示例:"
    echo "  bash scripts/pre-fix-impact.sh '质量=haiku' --type model"
    echo "  bash scripts/pre-fix-impact.sh '3-4.*次' --type number"
    echo "  bash scripts/pre-fix-impact.sh '{audit_scope}' --type placeholder"
    exit 1
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 修复前影响分析 ==="
echo "搜索模式: $PATTERN"
echo "搜索范围: $SKILL_DIR"
echo ""

# 排除 docs/ 和 .git/ 目录
RESULTS=$(grep -rn -- "$PATTERN" "$SKILL_DIR" \
    --include="*.md" \
    --include="*.json" \
    --exclude-dir=".git" \
    --exclude-dir="docs" \
    --exclude-dir=".superpowers" \
    --exclude-dir=".claude" \
    2>/dev/null || true)

if [ -z "$RESULTS" ]; then
    echo "未找到匹配项。可能模式有误或该术语已不存在。"
    exit 1
fi

# 按文件分组统计
echo "命中文件:"
echo "$RESULTS" | cut -d: -f1 | sort -u | while read f; do
    count=$(echo "$RESULTS" | grep -c "^$f:" || true)
    rel="${f#$SKILL_DIR/}"
    echo "  $rel ($count 处)"
done

echo ""
echo "=== 详细命中 ==="
echo "$RESULTS" | while IFS=: read -r file line content; do
    rel="${file#$SKILL_DIR/}"
    echo "  $rel:$line: $content"
done

echo ""
echo "=== 影响范围: $(echo "$RESULTS" | cut -d: -f1 | sort -u | wc -l) 个文件, $(echo "$RESULTS" | wc -l) 处命中 ==="
echo ""
echo "⚠️  以上全部位置必须在修改后保持一致性。"
echo "修复顺序建议: 按文件列表从上到下逐个修改，每改完一个标记完成。"

exit 0
