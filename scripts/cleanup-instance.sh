#!/usr/bin/env bash
# audit-loop 实例清理脚本
# 用途: 审计结束后清理临时文件，保留企业产出物
# 用法: bash scripts/cleanup-instance.sh <instance_dir> [--keep-all]
# 退出码: 0 = 清理完成

set -euo pipefail

INSTANCE_DIR="${1:-}"
KEEP_ALL="${2:-}"

if [ -z "$INSTANCE_DIR" ]; then
    echo "用法: bash scripts/cleanup-instance.sh <instance_dir> [--keep-all]"
    exit 1
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCKFILE="$SKILL_DIR/.claude/cache/audit-context/.audit-lock"

echo "=== audit-loop 实例清理 ==="
echo "实例目录: $INSTANCE_DIR"

# 🆕 H-5 修复: 验证 INSTANCE_DIR 路径合法性，防止误删
# 必须包含 audit-context/audit- 子目录，拒绝诸如 / 或 home 目录等危险路径
case "$INSTANCE_DIR" in
    *"/.claude/cache/audit-context/audit-"*|*"\\.claude\\cache\\audit-context\\audit-"*)
        ;;
    *)
        echo "🔴 拒绝: INSTANCE_DIR 路径不合法（必须包含 .claude/cache/audit-context/audit-*）"
        echo "   传入路径: $INSTANCE_DIR"
        exit 1
        ;;
esac

if [ ! -d "$INSTANCE_DIR" ]; then
    echo "⚠️  目录不存在，跳过"
    rm -f "$LOCKFILE"
    exit 0
fi

if [ "$KEEP_ALL" = "--keep-all" ]; then
    echo "保留全部文件"
    rm -f "$LOCKFILE"
    exit 0
fi

# 企业产出物列表（保留至少 90 天）
KEEP_PATTERNS=(
    "audit-report-*.md"
    "audit-report-*.sarif.json"
    "trend.json"
    ".audit-chain.json"
)

# 清理临时文件（lens JSON + checklist JSON）
CLEANED=0
for f in "$INSTANCE_DIR"/lens-*.json "$INSTANCE_DIR"/checklist-*.json "$INSTANCE_DIR"/verification-*.json; do
    if [ -f "$f" ]; then
        # 检查是否为企业产出物
        basename=$(basename "$f")
        is_keep=0
        for pattern in "${KEEP_PATTERNS[@]}"; do
            if [[ "$basename" == $pattern ]]; then
                is_keep=1
                break
            fi
        done
        if [ "$is_keep" -eq 0 ]; then
            rm -f "$f"
            CLEANED=$((CLEANED + 1))
        fi
    fi
done

echo "已清理 $CLEANED 个临时文件"
echo "企业产出物已保留（报告/SARIF/趋势/证据链）"

# 删除 lockfile
rm -f "$LOCKFILE"
echo "✅ 清理完成"

exit 0
