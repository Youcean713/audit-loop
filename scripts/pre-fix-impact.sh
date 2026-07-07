#!/usr/bin/env bash
# audit-loop 修复前影响分析脚本
# 用途: 修改前 grep 全项目定位所有受影响位置，防止"改一处忘同步"
# 用法: bash scripts/pre-fix-impact.sh "<搜索模式>" [--scope <file_list>] [--type model|number|placeholder]
#   --scope <file_list>: M-9 fix — 可选，指定影响范围文件列表（由 compute-blast-radius.sh 生成），限制扫描范围
# 退出码: 0 = 找到匹配, 1 = 无匹配(可能模式有误)

set -euo pipefail

PATTERN="${1:-}"
SCOPE_FILE=""
TYPE=""

shift
while [ $# -gt 0 ]; do
    case "$1" in
        --scope) SCOPE_FILE="$2"; shift 2 ;;
        --type) TYPE="$1 $2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$PATTERN" ]; then
    echo "用法: bash scripts/pre-fix-impact.sh '<grep模式>' [--scope <file_list>] [--type model|number|placeholder]"
    echo ""
    echo "示例:"
    echo "  bash scripts/pre-fix-impact.sh '质量=haiku' --type model"
    echo "  bash scripts/pre-fix-impact.sh '3-4.*次' --type number"
    echo "  bash scripts/pre-fix-impact.sh '{audit_scope}' --scope blast-radius.json"
    exit 1
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 修复前影响分析 ==="
echo "搜索模式: $PATTERN"
if [ -n "$SCOPE_FILE" ] && [ -f "$SCOPE_FILE" ]; then
    echo "搜索范围: --scope $SCOPE_FILE (限定范围)"
else
    echo "搜索范围: $SKILL_DIR (全量)"
fi
echo ""

# M-9 fix: 支持 --scope 限定搜索范围（从 blast-radius.json 读取变更文件列表）
if [ -n "$SCOPE_FILE" ] && [ -f "$SCOPE_FILE" ]; then
    # 从 scope 文件中提取文件路径（支持 JSON 数组和行分隔两种格式）
    if echo "$SCOPE_FILE" | grep -q '\.json$'; then
        # JSON 格式：从 jq 或 python 提取 scan_files 或 files 字段
        SCOPE_FILES=$(python -c "
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
files = data.get('scan_files', data.get('files', data.get('changed_files', [])))
for f_item in files:
    if isinstance(f_item, dict):
        print(f_item.get('path', f_item.get('file', '')))
    else:
        print(f_item)
" "$SCOPE_FILE" 2>/dev/null || echo "")
    else
        SCOPE_FILES=$(cat "$SCOPE_FILE" 2>/dev/null || echo "")
    fi
    if [ -n "$SCOPE_FILES" ]; then
        RESULTS=""
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            fpath="$SKILL_DIR/$f"
            [ -f "$fpath" ] || fpath="$f"
            [ -f "$fpath" ] || continue
            match=$(grep -n -- "$PATTERN" "$fpath" 2>/dev/null | sed "s|^|$fpath:|" || true)
            [ -n "$match" ] && RESULTS="${RESULTS}${match}"$'\n'
        done <<< "$SCOPE_FILES"
        RESULTS="${RESULTS%$'\n'}"
    else
        RESULTS=""
    fi
    if [ -z "$RESULTS" ]; then
        echo "指定范围内未找到匹配项。"
        exit 1
    fi
else
    # 默认全量扫描
    RESULTS=$(grep -rn -- "$PATTERN" "$SKILL_DIR" \
        --include="*.md" \
        --include="*.json" \
        --exclude-dir=".git" \
        --exclude-dir="docs" \
        --exclude-dir=".superpowers" \
        --exclude-dir=".claude" \
        2>/dev/null || true)
fi

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
