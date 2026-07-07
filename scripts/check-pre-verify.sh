#!/usr/bin/env bash
# audit-loop 验证 Agent 前置检查脚本（AP-13 fix）
# 用途: spawn verifier 前，验证 checklist 含 fix_attempted/requires_human 状态
# 用法: bash scripts/check-pre-verify.sh <instance_dir>
# 退出码: 0 = 通过, 1 = checklist 缺失或无修复

set -euo pipefail

INSTANCE_DIR="${1:-}"
if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/check-pre-verify.sh <instance_dir>"
    exit 1
fi
if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR" >&2
    exit 2
fi

CHECKLIST="$INSTANCE_DIR/checklist-round-1.json"
if [ ! -f "$CHECKLIST" ]; then
    printf '%s\n' "❌ checklist-round-1.json 不存在"
    exit 1
fi

export CHECKLIST
python << 'PYEOF'
import json, os, sys

with open(os.environ['CHECKLIST'], 'r', encoding='utf-8') as f:
    cl = json.load(f)

issues = cl.get('issues', cl.get('findings', []))

# 统计各状态
counts = {'fix_attempted': 0, 'requires_human': 0, 'open': 0, 'other': 0}
c_open, h_open, m_open = 0, 0, 0
c_total, h_total, m_total = 0, 0, 0

for issue in issues:
    # 改进建议4: 软性发现（P-* 视角建议）不计入 C/H/M 门控（需人工评估，非技术门禁）
    if str(issue.get('id', '')).startswith('P-'):
        continue
    sev = issue.get('severity', '').lower()
    status = issue.get('status', 'open')
    counts[status if status in counts else 'other'] += 1

    if sev == 'critical':
        c_total += 1
        if status not in ('fix_attempted', 'requires_human'):
            c_open += 1
    elif sev == 'high':
        h_total += 1
        if status not in ('fix_attempted', 'requires_human'):
            h_open += 1
    elif sev == 'medium':
        m_total += 1
        if status not in ('fix_attempted', 'requires_human'):
            m_open += 1

print(f'清单: {len(issues)} 项')
print(f'  C: {c_total} (待修: {c_open})')
print(f'  H: {h_total} (待修: {h_open})')
print(f'  M: {m_total} (待修: {m_open})')
print(f'状态: fix_attempted={counts["fix_attempted"]} / requires_human={counts["requires_human"]} / open={counts["open"]}')

# AP-13 强制: Medium 必须修复，除非 requires_human
if m_open > 0:
    print(f'❌ AP-13 违规: {m_open} 个 Medium 未修复（必须 fix_attempted 或 requires_human）')
    sys.exit(1)

# 检查 C/H 至少部分被处理
if c_total > 0 and counts['fix_attempted'] + counts['requires_human'] == 0:
    print('❌ Critical 全部未处理，验证 Agent 无事可做')
    sys.exit(1)

if h_total > 0 and counts['fix_attempted'] + counts['requires_human'] == 0:
    print('❌ High 全部未处理，验证 Agent 无事可做')
    sys.exit(1)

print('✅ verifier 前置条件通过')
PYEOF
exit $?
