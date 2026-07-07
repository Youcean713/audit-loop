#!/usr/bin/env bash
# audit-loop 收敛分支判定脚本（AP-12 fix）
# 用途: Round 2/3 验证后，强制判定 Case A/B/C 分支
# 用法: bash scripts/determine-convergence.sh <instance_dir> [prev_c_plus_h]
# 输出: CASE=A|B|C (一行)
# 退出码: 0 = Case A 或 B 或 C 已判定, 1 = 参数错误, 2 = 数据缺失

set -euo pipefail

INSTANCE_DIR="${1:-}"
PREV_C_PLUS_H="${2:-}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/determine-convergence.sh <instance_dir> [prev_c_plus_h]"
    exit 1
fi

if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR" >&2
    exit 1
fi

export INSTANCE_DIR_ABS="$INSTANCE_DIR"
export PREV_C_PLUS_H

python << 'PYEOF'
import json, os, sys

instance_dir = os.environ['INSTANCE_DIR_ABS']
prev_c_plus_h_str = os.environ.get('PREV_C_PLUS_H', '')

# 读取 verification JSON
verification = None
for fname in ['verification-round-3.json', 'verification-round-2.json']:
    vpath = os.path.join(instance_dir, fname)
    if os.path.exists(vpath):
        with open(vpath, 'r', encoding='utf-8') as f:
            verification = json.load(f)
        break

# 统计当前 C+H
current_c, current_h = 0, 0
if verification:
    summary = verification.get('summary', {})
    c_raw = summary.get('c_count', 0)
    h_raw = summary.get('h_count', 0)
    if isinstance(c_raw, dict):
        c_raw = c_raw.get('persisting', c_raw.get('total', 0))
    if isinstance(h_raw, dict):
        h_raw = h_raw.get('persisting', h_raw.get('total', 0))
    current_c = c_raw or 0
    current_h = h_raw or 0
else:
    # 兜底从 checklist 读
    checklist_path = os.path.join(instance_dir, 'checklist-round-1.json')
    if os.path.exists(checklist_path):
        with open(checklist_path, 'r', encoding='utf-8') as f:
            cl = json.load(f)
        for issue in cl.get('issues', cl.get('findings', [])):
            sev = issue.get('severity', '').lower()
            if sev == 'critical' and issue.get('status') == 'fix_attempted':
                current_c += 1
            elif sev == 'high' and issue.get('status') == 'fix_attempted':
                current_h += 1

current_c_plus_h = current_c + current_h

# 解析上一轮 C+H
prev_c_plus_h = None
if prev_c_plus_h_str:
    try:
        prev_c_plus_h = int(prev_c_plus_h_str)
    except ValueError:
        pass

# 收敛分支判定
if current_c_plus_h == 0:
    case = 'A'
    reason = '快收敛（C+H=0）→ 触发 Case A 全量重审+模型洗牌'
elif prev_c_plus_h is not None and current_c_plus_h >= prev_c_plus_h:
    case = 'C'
    reason = f'不收敛（C+H={current_c_plus_h} ≥ 上一轮={prev_c_plus_h}）→ 触发 Case C 聚焦重审'
elif prev_c_plus_h is not None and current_c_plus_h < prev_c_plus_h:
    case = 'B'
    reason = f'正常收敛（C+H={current_c_plus_h} < 上一轮={prev_c_plus_h}）→ 触发 Case B blast-radius 重审'
else:
    # 无上一轮数据：视为正常收敛（首轮）
    case = 'B'
    reason = f'首轮验证（C+H={current_c_plus_h}）→ Case B blast-radius 重审'

print(f'CASE={case}')
print(f'C+H={current_c_plus_h} (C={current_c}, H={current_h})')
if prev_c_plus_h is not None:
    print(f'PREV_C+H={prev_c_plus_h}')
print(f'REASON={reason}')

# 同时输出到 verdict 文件供后续步骤使用
verdict_path = os.path.join(instance_dir, 'convergence-verdict.json')
with open(verdict_path, 'w', encoding='utf-8') as f:
    json.dump({
        'case': case,
        'current_c': current_c,
        'current_h': current_h,
        'current_c_plus_h': current_c_plus_h,
        'prev_c_plus_h': prev_c_plus_h,
        'reason': reason
    }, f, ensure_ascii=False, indent=2)
PYEOF
