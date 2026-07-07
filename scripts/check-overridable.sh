#!/usr/bin/env bash
# audit-loop overridable 残留检查脚本
# 用途: 🟡 CAUTION 判定后检查 verification JSON 中是否有可自动修复的残留
# 用法: bash scripts/check-overridable.sh <instance_dir>
# 退出码: 0 = 无 overridable 残留(正常结束), 1 = 存在 overridable(需修复), 2 = 检查失败(脚本错误)

set -euo pipefail

INSTANCE_DIR="${1:-}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/check-overridable.sh <instance_dir>"
    printf '%s\n' "示例: bash scripts/check-overridable.sh .claude/cache/audit-context/audit-20260706-151714-7b41"
    exit 2
fi

printf '%s\n' "=== overridable 残留检查 ==="

# 查找最新的 verification-round-*.json
# M-13 fix: sort -V 是 GNU 扩展（macOS/BSD 不可用，set -euo pipefail 下脚本终止），改用 python 字典序排序取最新轮次
VERIFICATION_FILE=$(python -c "
import glob, sys
files = sorted(glob.glob(sys.argv[1] + '/verification-round-*.json'))
print(files[-1] if files else '')
" "$INSTANCE_DIR" 2>/dev/null || echo "")

if [ -z "$VERIFICATION_FILE" ]; then
    printf '%s\n' "未找到 verification JSON 文件"
    exit 0
fi

printf '%s\n' "检查文件: $VERIFICATION_FILE"
printf '%s\n' ""

# 🆕 H-1 修复: 通过 sys.argv 传递文件路径，避免 bash 字符串插值注入 Python 代码
# 🆕 H-4 修复: 区分 Python 执行失败 (exit 2) 和 overridable 检查结果 (exit 1)
PYTHON_OUTPUT=$(python -c "
import json, sys

if len(sys.argv) < 2:
    print('USAGE_ERROR: missing file path argument')
    sys.exit(2)

try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
except FileNotFoundError:
    print('FILE_NOT_FOUND')
    sys.exit(2)
except json.JSONDecodeError as e:
    print(f'JSON_PARSE_ERROR: {e}')
    sys.exit(2)
except Exception as e:
    print(f'UNEXPECTED_ERROR: {e}')
    sys.exit(2)

# 查找 overridable: true 的 issues
overridable = []
if 'adjudications' in data:
    for adj in data['adjudications']:
        if adj.get('overridable') == True:
            overridable.append(adj)

if overridable:
    print(f'FOUND:{len(overridable)}')
    for item in overridable:
        print(f'ID: {item[\"id\"]}')
        print(f'Decision: {item.get(\"decision\", \"?\")}')
        print(f'Fix: {item.get(\"fix_instruction\", \"无修复指令\")}')
        print('---')
    sys.exit(1)
else:
    print('CLEAN')
    sys.exit(0)
" -- "$VERIFICATION_FILE" 2>/dev/null)

EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 2 ]; then
    printf '\n'
    printf '%s\n' "🔴 检查脚本执行失败——overridable 检查不可用（fail-closed）"
    printf '%s\n' "  错误: $PYTHON_OUTPUT"
    exit 2
elif [ "$EXIT_CODE" -eq 1 ]; then
    printf '%s\n' "$PYTHON_OUTPUT"
    printf '\n'
    printf '%s\n' "🔴 存在 overridable 残留——必须修复后再进入下一轮（上限 2 轮）"
    exit 1
elif [ "$EXIT_CODE" -eq 0 ]; then
    printf '%s\n' "🟢 无 overridable 残留——正常结束"
    exit 0
else
    printf '%s\n' "⚠️  未知错误 (exit=$EXIT_CODE)，跳过 overridable 检查（fail-closed）"
    exit 2
fi
