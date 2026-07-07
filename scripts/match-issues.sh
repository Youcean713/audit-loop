#!/usr/bin/env bash
# audit-loop 跨轮 issue 相似度匹配脚本
# 用途: 当重审（Mode A）产生新 issue 时，与上轮 checklist 匹配，分类为 Matched/New
# 用法: bash scripts/match-issues.sh <instance_dir> <old_checklist> <new_findings_json>
# 输出: <instance_dir>/match-result.json
# 匹配算法:
#   1. 精确匹配: file + line_range 完全相同
#   2. 模糊匹配: file 相同 + line_range 重叠 + description 关键词重叠 ≥ 60%
#   3. 未匹配 → New（首轮遗漏或修复引入）
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 脚本错误

set -euo pipefail

INSTANCE_DIR="${1:-}"
OLD_CHECKLIST="${2:-}"
NEW_FINDINGS="${3:-}"

if [ -z "$INSTANCE_DIR" ] || [ -z "$OLD_CHECKLIST" ] || [ -z "$NEW_FINDINGS" ]; then
    printf '%s\n' "用法: bash scripts/match-issues.sh <instance_dir> <old_checklist> <new_findings_json>"
    exit 1
fi

echo "=== audit-loop 跨轮 issue 匹配 ==="
echo ""

set +e
python -c "
import json, os, sys, re
from difflib import SequenceMatcher

instance_dir = sys.argv[1]
old_path = os.path.join(instance_dir, sys.argv[2])
new_path = os.path.join(instance_dir, sys.argv[3])

# 读取上轮 checklist
with open(old_path, 'r', encoding='utf-8') as f:
    old_data = json.load(f)
old_issues = old_data.get('issues', [])

# 读取新发现（可能是 lens JSON 或 checklist）
with open(new_path, 'r', encoding='utf-8') as f:
    new_data = json.load(f)
if 'issues' in new_data:
    new_issues = new_data['issues']
elif 'findings' in new_data:
    new_issues = new_data['findings']
else:
    new_issues = new_data if isinstance(new_data, list) else []

def parse_line_range(lr):
    \"\"\"解析 line_range 字符串，返回 (start, end) 或 None\"\"\"
    if not lr:
        return None
    s = str(lr)
    parts = re.split(r'[-,\s]+', s)
    try:
        nums = [int(p) for p in parts if p.isdigit()]
        if nums:
            return (min(nums), max(nums))
    except ValueError:
        pass
    return None

def ranges_overlap(r1, r2):
    \"\"\"两个行号范围是否重叠\"\"\"
    if not r1 or not r2:
        return False
    return not (r1[1] < r2[0] or r2[1] < r1[0])

def description_similarity(d1, d2):
    \"\"\"描述文本相似度（关键词重叠 + 序列相似）\"\"\"
    if not d1 or not d2:
        return 0.0
    # 关键词集合（去标点，取小写词）
    words1 = set(re.findall(r'[a-zA-Z0-9_一-鿿]+', d1.lower()))
    words2 = set(re.findall(r'[a-zA-Z0-9_一-鿿]+', d2.lower()))
    if not words1 or not words2:
        return 0.0
    overlap = len(words1 & words2)
    union = len(words1 | words2)
    jaccard = overlap / union if union > 0 else 0.0
    # 序列相似度
    seq_ratio = SequenceMatcher(None, d1.lower(), d2.lower()).ratio()
    # 综合（Jaccard 权重 0.6 + 序列 0.4）
    return 0.6 * jaccard + 0.4 * seq_ratio

def match_issue(new_issue, old_issues):
    \"\"\"尝试将新 issue 与上轮 issue 匹配\"\"\"
    new_file = new_issue.get('file', '')
    new_lr = parse_line_range(new_issue.get('line_range'))
    new_desc = new_issue.get('description', '')

    best_match = None
    best_score = 0.0

    for old in old_issues:
        old_file = old.get('file', '')
        old_lr = parse_line_range(old.get('line_range'))
        old_desc = old.get('description', '')

        # 精确匹配: file + line_range 完全相同
        if new_file and old_file and new_file == old_file:
            if new_lr and old_lr and new_lr == old_lr:
                return {'match_type': 'exact', 'old_id': old.get('id'), 'score': 1.0, 'old_issue': old}

            # 模糊匹配: file 相同 + line_range 重叠 + description 相似
            if new_lr and old_lr and ranges_overlap(new_lr, old_lr):
                sim = description_similarity(new_desc, old_desc)
                if sim >= 0.6 and sim > best_score:
                    best_score = sim
                    best_match = {'match_type': 'fuzzy', 'old_id': old.get('id'), 'score': round(sim, 3), 'old_issue': old}

            # file 相同但行号不重叠——仍可能同根因，检查描述高相似
            elif not new_lr or not old_lr or not ranges_overlap(new_lr, old_lr):
                sim = description_similarity(new_desc, old_desc)
                if sim >= 0.75 and sim > best_score:
                    best_score = sim
                    best_match = {'match_type': 'fuzzy_high_desc', 'old_id': old.get('id'), 'score': round(sim, 3), 'old_issue': old}

    return best_match

# 执行匹配
matched = []
new_findings = []

for new_issue in new_issues:
    match = match_issue(new_issue, old_issues)
    if match:
        matched.append({
            'new_issue_id': new_issue.get('id', '?'),
            'old_issue_id': match['old_id'],
            'match_type': match['match_type'],
            'score': match['score'],
            'file': new_issue.get('file', ''),
            'description': new_issue.get('description', '')[:100]
        })
    else:
        new_findings.append({
            'id': new_issue.get('id', '?'),
            'file': new_issue.get('file', ''),
            'line_range': new_issue.get('line_range', ''),
            'severity': new_issue.get('severity', 'medium'),
            'description': new_issue.get('description', '')[:100]
        })

# 统计
result = {
    'instance_id': os.path.basename(instance_dir),
    'matched_count': len(matched),
    'new_count': len(new_findings),
    'matched': matched,
    'new_findings': new_findings,
    'summary': {
        'total_new_audit_findings': len(new_issues),
        'matched_to_previous': len(matched),
        'genuinely_new': len(new_findings),
        'match_rate': round(len(matched) / len(new_issues), 2) if new_issues else 0
    }
}

output_path = os.path.join(instance_dir, 'match-result.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(result, f, ensure_ascii=False, indent=2)

print(f'新审计发现: {len(new_issues)} 个')
print(f'匹配上轮: {len(matched)} 个')
print(f'  - 精确匹配: {sum(1 for m in matched if m[\"match_type\"]==\"exact\")}')
print(f'  - 模糊匹配: {sum(1 for m in matched if m[\"match_type\"] in (\"fuzzy\",\"fuzzy_high_desc\"))}')
print(f'全新发现: {len(new_findings)} 个')
print(f'匹配率: {result[\"summary\"][\"match_rate\"]}')
if new_findings:
    print(f'')
    print(f'🆕 全新发现（首轮遗漏或修复引入）:')
    for nf in new_findings[:5]:
        print(f'  [{nf[\"severity\"]}] {nf[\"file\"]}:{nf[\"line_range\"]} - {nf[\"description\"]}')
    if len(new_findings) > 5:
        print(f'  ... 及其他 {len(new_findings)-5} 个')
print(f'输出: {output_path}')
sys.exit(0)
" "$INSTANCE_DIR" "$OLD_CHECKLIST" "$NEW_FINDINGS"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
