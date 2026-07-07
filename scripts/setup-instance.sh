#!/usr/bin/env bash
# audit-loop 实例初始化脚本
# 用途: Step 0 生成 instance_id、创建输出目录、管理 lockfile
# 用法: bash scripts/setup-instance.sh [--force]
# 输出: INSTANCE_ID 和 INSTANCE_DIR（stdout），其他信息 stderr

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$SKILL_DIR/.claude/cache/audit-context"
LOCKFILE="$CACHE_DIR/.audit-lock"
FORCE="${1:-}"

# 生成 instance_id
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
# 🆕 M-8 修复: 跨平台回退——优先 openssl，其次 /dev/urandom+od，最后 $RANDOM
if command -v openssl >/dev/null 2>&1; then
    RANDOM_HEX=$(openssl rand -hex 2 2>/dev/null)
elif [ -c /dev/urandom ]; then
    RANDOM_HEX=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%04x' "$RANDOM")
else
    RANDOM_HEX=$(printf '%04x' "$RANDOM")
fi
INSTANCE_ID="audit-${TIMESTAMP}-${RANDOM_HEX}"
INSTANCE_DIR="$CACHE_DIR/$INSTANCE_ID"

>&2 echo "=== audit-loop 实例初始化 ==="
>&2 echo "Instance ID: $INSTANCE_ID"

# 确保缓存目录存在
mkdir -p "$CACHE_DIR"

# lockfile 并发检测
if [ -f "$LOCKFILE" ]; then
    # 检查孤儿残留（mtime > 90min）
    if [ "$(uname)" = "Darwin" ]; then
        MTIME=$(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        AGE=$((NOW - MTIME))
    else
        MTIME=$(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        AGE=$((NOW - MTIME))
    fi

    if [ "$AGE" -gt 5400 ]; then  # 90min = 5400s
        >&2 echo "⚠️  检测到孤儿 lockfile（mtime > 90min），删除并重建"
        rm -f "$LOCKFILE"
    elif [ "$FORCE" != "--force" ]; then
        EXISTING_ID=$(head -1 "$LOCKFILE" 2>/dev/null | grep -oP 'instance_id=\K[^ ]+' || echo "unknown")
        >&2 echo "❌ 已有审计实例运行中（$EXISTING_ID），拒绝并发执行"
        >&2 echo "   如需强制启动: bash scripts/setup-instance.sh --force"
        exit 1
    fi
fi

# 创建 lockfile
echo "instance_id=$INSTANCE_ID start=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCKFILE"
>&2 echo "Lockfile: 已创建"

# 创建输出目录
mkdir -p "$INSTANCE_DIR"
>&2 echo "输出目录: $INSTANCE_DIR"

# 输出 instance_id 和目录路径（供编排者 capture）
echo "INSTANCE_ID=$INSTANCE_ID"
echo "INSTANCE_DIR=$INSTANCE_DIR"

>&2 echo "✅ 实例初始化完成"
exit 0
