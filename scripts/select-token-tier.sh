#!/usr/bin/env bash
# audit-loop Token 档位选择脚本
# 用途: 根据文件数量选择 Token 守卫档位（L-6 fix: 此脚本为运行时唯一真实值来源，修改阈值需同步更新 guardrails.md/SKILL.md/simple-audit.md）
# 用法: bash scripts/select-token-tier.sh <file_count> <mode>
# mode: simple | comprehensive
# 退出码: 0 = 成功, 1 = 参数错误
# 输出: TIER=small|medium|large + SINGLE_ROUND_THRESHOLD + CUMULATIVE_THRESHOLD

set -euo pipefail

FILE_COUNT="${1:-}"
MODE="${2:-comprehensive}"

if [ -z "$FILE_COUNT" ]; then
    printf '%s\n' "用法: bash scripts/select-token-tier.sh <file_count> [simple|comprehensive]"
    printf '%s\n' "示例: bash scripts/select-token-tier.sh 15 comprehensive"
    exit 1
fi

# 验证 file_count 是数字
if ! [[ "$FILE_COUNT" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "错误: file_count 必须是数字"
    exit 1
fi

# 档位判定
if [ "$FILE_COUNT" -le 10 ]; then
    TIER="small"
elif [ "$FILE_COUNT" -le 50 ]; then
    TIER="medium"
else
    TIER="large"
fi

# 阈值表（与 guardrails.md 同步）
if [ "$MODE" = "simple" ]; then
    case "$TIER" in
        small)  SINGLE=80;  CUMULATIVE=200 ;;
        medium) SINGLE=150; CUMULATIVE=400 ;;
        large)  SINGLE=300; CUMULATIVE=800 ;;
    esac
else  # comprehensive
    case "$TIER" in
        small)  SINGLE=100; CUMULATIVE=250 ;;
        medium) SINGLE=250; CUMULATIVE=600 ;;
        large)  SINGLE=600; CUMULATIVE=1500 ;;
    esac
fi

echo "=== audit-loop Token 档位选择 ==="
echo "文件数: $FILE_COUNT"
echo "模式: $MODE"
echo "档位: $TIER"
echo ""
echo "单轮阈值: ${SINGLE}K"
echo "累计阈值: ${CUMULATIVE}K"
echo ""
# 输出供编排者 capture 的环境变量格式
echo "TIER=$TIER"
echo "SINGLE_ROUND_THRESHOLD=${SINGLE}K"
echo "CUMULATIVE_THRESHOLD=${CUMULATIVE}K"
exit 0
