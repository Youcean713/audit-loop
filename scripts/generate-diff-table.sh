#!/usr/bin/env bash
# audit-loop 差异对比表生成脚本
# 用途: 跨轮次匹配 issue ID → Resolved/New/Persisting/Regressed
# 用法: bash scripts/generate-diff-table.sh <instance_dir> <prev_checklist> <curr_verification>
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 脚本错误

set -euo pipefail

INSTANCE_DIR="${1:-}"
PREV_CHECKLIST="${2:-}"
CURR_VERIFICATION="${3:-}"

if [ -z "$INSTANCE_DIR" ] || [ -z "$PREV_CHECKLIST" ] || [ -z "$CURR_VERIFICATION" ]; then
    printf '%s\n' "用法: bash scripts/generate-diff-table.sh <instance_dir> <prev_checklist> <curr_verification>"
    printf '%s\n' "示例: bash scripts/generate-diff-table.sh .claude/.../audit-xxx checklist-round-1.json verification-round-2.json"
    exit 1
fi

echo "=== audit-loop 差异对比表生成 ==="
echo ""

set +e
python -c "
import json, os, sys

instance_dir = sys.argv[1]
prev_path = sys.argv[2]
curr_path = sys.argv[3]

# 读取上一轮 checklist
with open(os.path.join(instance_dir, prev_path), 'r', encoding='utf-8') as f:
    prev = json.load(f)
prev_issues = {i['id']: i for i in prev.get('issues', []) if 'id' in i}

# 读取本轮 verification
with open(os.path.join(instance_dir, curr_path), 'r', encoding='utf-8') as f:
    curr = json.load(f)

# 从 verification_results 提取 verdict
verdicts = {}
for vr in curr.get('verification_results', []):
    vid = vr.get('id')
    if vid:
        verdicts[vid] = {
            'verdict': vr.get('verdict', 'unknown'),
            'confidence': vr.get('confidence', 'medium'),
            'evidence': vr.get('evidence', '')
        }

# 从 blast_radius new_findings 提取新发现
new_findings = curr.get('blast_radius', {}).get('new_findings', [])

# 分类
resolved = []
persisting = []
regressed = []
new_issues = []

# 处理上轮存在的 issues
for issue_id, prev_issue in prev_issues.items():
    if issue_id in verdicts:
        v = verdicts[issue_id]['verdict']
        if v == 'resolved':
            resolved.append(issue_id)
        elif v == 'persisting':
            persisting.append(issue_id)
        elif v == 'regressed':
            regressed.append(issue_id)
    else:
        # 未在本轮验证中——假设 persisting
        persisting.append(issue_id)

# 处理新发现
for nf in new_findings:
    nid = nf.get('id', 'NEW-?')
    new_issues.append(nid)

# 从 adjudications 处理终裁后的新 ID（降级/撤销）
adjudications = curr.get('adjudications', [])
for adj in adjudications:
    adj_id = adj.get('id', '')
    decision = adj.get('decision', '')
    if adj_id and adj_id not in prev_issues and decision == 'confirm':
        if adj_id not in new_issues:
            new_issues.append(adj_id)

# 输出差异表
print('## 差异对比')
print('')
print('| 状态 | 数量 | ID + 描述 |')
print('|------|------|-----------|')

if resolved:
    desc_list = []
    for rid in resolved:
        desc = prev_issues.get(rid, {}).get('description', '')[:60]
        desc_list.append(f'{rid}: {desc}')
    print(f'| ✅ Resolved | {len(resolved)} | {\" | \".join(desc_list[:3])}{\" ...\" if len(desc_list)>3 else \"\"} |')
else:
    print('| ✅ Resolved | 0 | — |')

if new_issues:
    desc_list = [str(n) for n in new_issues[:3]]
    print(f'| 🆕 New | {len(new_issues)} | {\" | \".join(desc_list)} |')
else:
    print('| 🆕 New | 0 | — |')

if persisting:
    desc_list = []
    for pid in persisting:
        desc = prev_issues.get(pid, {}).get('description', '')[:60]
        desc_list.append(f'{pid}: {desc}')
    print(f'| 🔁 Persisting | {len(persisting)} | {\" | \".join(desc_list[:3])}{\" ...\" if len(desc_list)>3 else \"\"} |')
else:
    print('| 🔁 Persisting | 0 | — |')

if regressed:
    desc_list = [str(r) for r in regressed[:3]]
    print(f'| ⚠️ Regressed | {len(regressed)} | {\" | \".join(desc_list)} |')
else:
    print('| ⚠️ Regressed | 0 | — |')

# 写入 diff JSON
diff_data = {
    'resolved': resolved,
    'new': new_issues,
    'persisting': persisting,
    'regressed': regressed,
    'summary': {
        'resolved_count': len(resolved),
        'new_count': len(new_issues),
        'persisting_count': len(persisting),
        'regressed_count': len(regressed)
    }
}
diff_path = os.path.join(instance_dir, 'diff-table.json')
with open(diff_path, 'w', encoding='utf-8') as f:
    json.dump(diff_data, f, ensure_ascii=False, indent=2)

print('')
print(f'统计: Resolved={len(resolved)} New={len(new_issues)} Persisting={len(persisting)} Regressed={len(regressed)}')
print(f'输出: diff-table.json')
sys.exit(0)
" "$INSTANCE_DIR" "$PREV_CHECKLIST" "$CURR_VERIFICATION"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
