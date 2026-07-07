#!/usr/bin/env bash
# audit-loop Medium 问题处理强制检查（AP-14 fix）
# 用途: 退出裁决前强制检查所有 Medium 已处理（fix_attempted/requires_human/overridable）
#       防止编排者在 C+H=0 时直接产出报告而跳过 Medium 修复
# 用法: bash scripts/enforce-medium-handled.sh <instance_dir>
# 退出码: 0 = 全部 Medium 已处理, 1 = 存在未处理 Medium（阻止裁决）

set -euo pipefail

INSTANCE_DIR="${1:-}"
if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/enforce-medium-handled.sh <instance_dir>" >&2
    exit 2
fi

CHECKLIST="${INSTANCE_DIR}/checklist-round-1.json"
if [ ! -f "$CHECKLIST" ]; then
    # checklist 不存在，不阻塞（由其他检查负责）
    exit 0
fi

python - "$CHECKLIST" << 'PYEOF'
import json, sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)

issues = data.get('issues', data.get('findings', []))

# 已处理状态：编排者已修复或明确标记需人工
HANDLED_STATUSES = {'fix_attempted', 'fixed', 'resolved', 'requires_human', 'overridable'}

unhandled = [
    i for i in issues
    if i.get('severity', '').lower() == 'medium'
    and i.get('status', 'open') not in HANDLED_STATUSES
]

if unhandled:
    print(f"🚨 AP-14: {len(unhandled)} 个 Medium 问题未处理", file=sys.stderr)
    print("退出裁决前必须修复（fix_attempted）或标记需人工（requires_human）：", file=sys.stderr)
    for m in unhandled[:5]:
        mid = m.get('id', '?')
        mfile = m.get('file', '?')
        mdesc = m.get('description', '?')[:80]
        print(f"  {mid} [{mfile}]: {mdesc}", file=sys.stderr)
    if len(unhandled) > 5:
        print(f"  ... 还有 {len(unhandled) - 5} 个", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
