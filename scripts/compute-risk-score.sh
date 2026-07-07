#!/usr/bin/env bash
# audit-loop 风险评分计算脚本
# 用途: 对 checklist 中每个 issue 计算 risk_score（公式见 risk-scoring.md）
# 公式: risk_score = (severity_weight × 3) + (exposure × 2) + (asset_criticality × 2)
# 用法: bash scripts/compute-risk-score.sh <instance_dir>
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 脚本错误

set -euo pipefail

INSTANCE_DIR="${1:-}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/compute-risk-score.sh <instance_dir>"
    exit 1
fi

if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR"
    exit 2
fi

echo "=== audit-loop 风险评分计算 ==="
echo "实例目录: $INSTANCE_DIR"
echo ""

set +e
python -c "
import json, os, sys

instance_dir = sys.argv[1]

# 评分权重表（risk-scoring.md）
SEVERITY_WEIGHT = {'critical': 10, 'high': 7, 'medium': 4, 'low': 1, 'suggestion': 1}
EXPOSURE_WEIGHT = {'internet-facing': 10, 'internal-api': 7, 'authenticated': 4, 'internal-only': 1}
ASSET_CRITICALITY = {
    'PCI': 10, 'PII': 10, 'PHI': 10, 'AUTH': 7, 'ADMIN': 7,
    'API': 5, 'CONFIG': 5, 'BIZ': 3, 'DOC': 1, 'GENERIC': 1
}

# SLA 矩阵（risk-scoring.md 第六节）
def compute_sla(verdict, risk_score):
    if verdict == 'BLOCK':
        return 1  # 24 小时
    elif verdict == 'HOLD':
        return 3 if risk_score >= 50 else 7  # 72小时 或 7天
    elif verdict == 'CAUTION':
        return 30 if risk_score >= 30 else 90
    else:  # SHIP
        return None

# 读取 asset-inventory.json 建立路径→criticality 映射
asset_map = {}
asset_path = os.path.join(instance_dir, 'asset-inventory.json')
if os.path.exists(asset_path):
    with open(asset_path, 'r', encoding='utf-8') as f:
        inventory = json.load(f)
    for asset in inventory.get('assets', []):
        asset_map[asset['path']] = (asset['classification'], asset['criticality'])

# 读取 checklist
checklist_path = os.path.join(instance_dir, 'checklist-round-1.json')
if not os.path.exists(checklist_path):
    print('错误: checklist-round-1.json 不存在')
    sys.exit(2)

with open(checklist_path, 'r', encoding='utf-8') as f:
    checklist = json.load(f)

issues = checklist.get('issues', [])
scored = 0
defaulted = 0

for issue in issues:
    severity = issue.get('severity', 'medium').lower()
    exposure = issue.get('exposure', 'internal-only')
    asset_cls = issue.get('asset_classification', 'GENERIC')

    # 从 asset-inventory 查找更精确的 criticality
    file_path = issue.get('file', '')
    if file_path in asset_map:
        asset_cls = asset_map[file_path][0]
        asset_crit = asset_map[file_path][1]
    else:
        asset_crit = ASSET_CRITICALITY.get(asset_cls, 1)

    sev_w = SEVERITY_WEIGHT.get(severity, 4)
    exp_w = EXPOSURE_WEIGHT.get(exposure, 1)

    # 公式
    risk_score = (sev_w * 3) + (exp_w * 2) + (asset_crit * 2)

    issue['risk_score'] = risk_score
    issue['asset_classification'] = asset_cls
    if 'asset_criticality' not in issue:
        issue['asset_criticality'] = asset_crit

    scored += 1
    if exposure == 'internal-only' and 'exposure' not in issue:
        defaulted += 1

# 按 risk_score 降序排序
issues.sort(key=lambda x: x.get('risk_score', 0), reverse=True)
checklist['issues'] = issues

# 计算统计
total_score = sum(i.get('risk_score', 0) for i in issues)
avg_score = round(total_score / len(issues), 1) if issues else 0
checklist['risk_summary'] = {
    'total_issues': len(issues),
    'avg_risk_score': avg_score,
    'max_risk_score': max((i.get('risk_score', 0) for i in issues), default=0),
    'scored_by_script': scored
}

# 写回 checklist
with open(checklist_path, 'w', encoding='utf-8') as f:
    json.dump(checklist, f, ensure_ascii=False, indent=2)

print(f'已计算 {scored} 个 issue 的 risk_score')
print(f'平均风险分: {avg_score}')
print(f'最高风险分: {checklist[\"risk_summary\"][\"max_risk_score\"]}')
print(f'输出: checklist-round-1.json (已更新 risk_score 字段)')
sys.exit(0)
" "$INSTANCE_DIR"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
