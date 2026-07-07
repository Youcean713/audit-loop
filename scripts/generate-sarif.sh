#!/usr/bin/env bash
# audit-loop SARIF v2.1.0 生成脚本
# 用途: 从 checklist JSON + exit-verdict.json 生成 audit-report.sarif.json
# 用法: bash scripts/generate-sarif.sh <instance_dir> [mode]
# mode: comprehensive (默认) | simple
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 脚本错误

set -euo pipefail

INSTANCE_DIR="${1:-}"
MODE="${2:-comprehensive}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/generate-sarif.sh <instance_dir> [comprehensive|simple]"
    exit 1
fi

if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR"
    exit 2
fi

echo "=== audit-loop SARIF 生成 ==="
echo "实例目录: $INSTANCE_DIR"
echo "模式: $MODE"
echo ""

set +e
python -c "
import json, os, sys, hashlib
from datetime import datetime, timezone

instance_dir = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else 'comprehensive'

# 读取 checklist
checklist_path = os.path.join(instance_dir, 'checklist-round-1.json')
if not os.path.exists(checklist_path):
    print('错误: checklist-round-1.json 不存在')
    sys.exit(2)
with open(checklist_path, 'r', encoding='utf-8') as f:
    checklist = json.load(f)

# 读取 exit-verdict（可选）
verdict_path = os.path.join(instance_dir, 'exit-verdict.json')
verdict_data = {}
if os.path.exists(verdict_path):
    with open(verdict_path, 'r', encoding='utf-8') as f:
        verdict_data = json.load(f)

verdict = verdict_data.get('verdict', 'UNKNOWN')
exit_code = verdict_data.get('exit_code', 2)
instance_id = checklist.get('instance_id', os.path.basename(instance_dir))

# SARIF level 映射
def sarif_level(severity):
    s = severity.lower()
    if s in ('critical', 'high'):
        return 'error'
    elif s == 'medium':
        return 'warning'
    else:
        return 'note'

# 构建 results
results = []
for issue in checklist.get('issues', []):
    severity = issue.get('severity', 'medium')
    issue_id = issue.get('id', 'UNKNOWN')
    file_path = issue.get('file', '')
    line_range = issue.get('line_range', '')
    description = issue.get('description', '')

    # 解析 line_range（如 '45-67' 或 '45'）
    start_line = end_line = 1
    if line_range:
        parts = str(line_range).split('-')
        try:
            start_line = int(parts[0])
            end_line = int(parts[-1])
        except ValueError:
            start_line = end_line = 1

    # 指纹（SHA-256 of id+file+line）
    fingerprint_input = f'{issue_id}|{file_path}|{line_range}'
    fingerprint = hashlib.sha256(fingerprint_input.encode()).hexdigest()[:16]

    # properties
    properties = {
        'audit-loop:id': issue_id,
        'audit-loop:severity': severity,
        'audit-loop:type': issue.get('type', 'technical'),
        'audit-loop:risk_score': issue.get('risk_score', 0),
        'audit-loop:lens_sources': issue.get('lens_sources', [])
    }
    if 'cvss_score' in issue:
        properties['audit-loop:cvss_score'] = issue['cvss_score']
    if 'cwe_id' in issue:
        properties['audit-loop:cwe_id'] = issue['cwe_id']
    # H-6 fix: sla_days=0 is valid (urgent/Critical fix), use 'is not None' instead of truthiness check
    if 'sla_days' in issue and issue['sla_days'] is not None:
        properties['audit-loop:sla_days'] = issue['sla_days']
    if issue.get('perspective_id'):
        properties['audit-loop:perspective_id'] = issue['perspective_id']

    result = {
        'ruleId': issue.get('cwe_id', 'audit-loop-finding'),
        'level': sarif_level(severity),
        'message': {'text': description[:1000]},
        'locations': [{
            'physicalLocation': {
                'artifactLocation': {'uri': file_path},
                'region': {'startLine': start_line, 'endLine': end_line}
            }
        }],
        'partialFingerprints': {'audit-loop/v1': fingerprint},
        'properties': properties
    }
    results.append(result)

# 统计
c_count = sum(1 for i in checklist.get('issues', []) if i.get('severity','').lower() == 'critical')
h_count = sum(1 for i in checklist.get('issues', []) if i.get('severity','').lower() == 'high')
m_count = sum(1 for i in checklist.get('issues', []) if i.get('severity','').lower() == 'medium')
s_count = sum(1 for i in checklist.get('issues', []) if i.get('severity','').lower() in ('low', 'suggestion'))
soft_count = sum(1 for i in checklist.get('issues', []) if i.get('type') == 'soft')

# 视角信息
active_perspectives = checklist.get('active_perspectives', [])
perspective_soft = sum(1 for i in checklist.get('issues', []) if i.get('type') == 'soft')
perspective_conflicts = sum(1 for i in checklist.get('issues', []) if i.get('perspective_conflict'))

# SARIF 文档
now_utc = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
sarif = {
    '\$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
    'version': '2.1.0',
    'runs': [{
        'tool': {
            'driver': {
                'name': 'audit-loop',
                'version': '2.0-enterprise',
                'informationUri': 'https://github.com/anthropics/claude-code',
                'rules': [],
                'supportedTaxonomies': [
                    {'name': 'CWE', 'version': '4.16'},
                    {'name': 'OWASP ASVS', 'version': '5.0.0'}
                ]
            }
        },
        'invocations': [{
            'executionSuccessful': verdict in ('SHIP', 'CAUTION'),
            'startTimeUtc': now_utc,
            'endTimeUtc': now_utc
        }],
        'results': results,
        'properties': {
            'audit-loop:instance_id': instance_id,
            'audit-loop:verdict': verdict,
            'audit-loop:exit_code': exit_code,
            'audit-loop:mode': mode,
            'audit-loop:c_count': c_count,
            'audit-loop:h_count': h_count,
            'audit-loop:m_count': m_count,
            'audit-loop:s_count': s_count,
            'audit-loop:perspectives': active_perspectives,
            'audit-loop:perspective_soft_findings': perspective_soft,
            'audit-loop:perspective_conflicts': perspective_conflicts
        }
    }]
}

# 添加 fix_phase 标记（如果有降级）
degradations = checklist.get('degradations', [])
if any('skipped' in str(d).lower() or 'stop' in str(d).lower() for d in degradations):
    sarif['runs'][0]['properties']['audit-loop:fix_phase'] = 'skipped'

output_path = os.path.join(instance_dir, 'audit-report.sarif.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(sarif, f, ensure_ascii=False, indent=2)

print(f'生成 {len(results)} 个 SARIF results')
print(f'严重度分布: C={c_count} H={h_count} M={m_count} S={s_count} 软性={soft_count}')
print(f'门控裁决: {verdict} (exit {exit_code})')
print(f'视角: {len(active_perspectives)} 个, 软性发现 {perspective_soft}, 冲突 {perspective_conflicts}')
print(f'输出: {output_path}')
sys.exit(0)
" "$INSTANCE_DIR" "$MODE"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
