#!/usr/bin/env bash
# audit-loop 最终报告生成脚本
# 用途: 审计结束后，从 checklist + verification JSON 生成标准化中文 Markdown 报告
# 用法: bash scripts/generate-final-report.sh <instance_dir> [output_path]
# 输出: 报告文本到 stdout，同时写入文件
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 数据缺失

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_DIR="${1:-}"
OUTPUT_PATH="${2:-}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/generate-final-report.sh <instance_dir> [output_path]"
    exit 1
fi

if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR"
    exit 1
fi

# H-3 fix: 调用报告前置门控，验证 Step 1-8 全部产物存在
if [ -x "$SCRIPT_DIR/check-pre-report.sh" ]; then
    if ! "$SCRIPT_DIR/check-pre-report.sh" "$INSTANCE_DIR"; then
        printf '%s\n' "❌ 报告生成前置门控失败（check-pre-report.sh）" >&2
        exit 3
    fi
fi

python "$SCRIPT_DIR/generate_final_report.py" "$INSTANCE_DIR" ${OUTPUT_PATH:+"$OUTPUT_PATH"}
