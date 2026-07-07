#!/usr/bin/env bash
# audit-loop 机械去重脚本（合并审查官降级时的强制执行替代）
# 用途: 读取所有 lens JSON + 视角 JSON，执行两级去重，输出 checklist
# 用法: bash scripts/mechanical-dedup.sh <instance_dir>
# 退出码: 0 = 成功生成 checklist, 1 = 参数错误, 2 = 脚本执行错误

set -euo pipefail

INSTANCE_DIR="${1:-}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/mechanical-dedup.sh <instance_dir>"
    printf '%s\n' "示例: bash scripts/mechanical-dedup.sh .claude/cache/audit-context/audit-20260706-151714-7b41"
    exit 1
fi

if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR"
    exit 1
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== audit-loop 机械去重 ==="
echo "实例目录: $INSTANCE_DIR"
echo ""

# Step 1: 统计输入文件
TECH_LENS_FILES=()
for name in security arch quality perf; do
    f="$INSTANCE_DIR/lens-$name.json"
    if [ -f "$f" ]; then
        TECH_LENS_FILES+=("$f")
    else
        echo "⚠️  缺失: lens-$name.json（标记 incomplete）"
    fi
done

PERSPECTIVE_FILES=()
for f in "$INSTANCE_DIR"/lens-perspective-*.json; do
    if [ -f "$f" ]; then
        PERSPECTIVE_FILES+=("$f")
    fi
done

echo "技术透镜: ${#TECH_LENS_FILES[@]}/4 个"
echo "视角透镜: ${#PERSPECTIVE_FILES[@]} 个"
echo ""

# Step 2: 使用 Python 执行去重合并（H-4 fix: python -c "..." → heredoc + os.environ）
export INSTANCE_DIR
python << 'PYEOF'
import json, os
from collections import defaultdict
from datetime import datetime, timezone

instance_dir = os.environ['INSTANCE_DIR']

# 读取所有透镜 JSON
all_findings = []
soft_findings = []
lens_count = {'technical': 0, 'perspective': 0}
missing_lenses = []

# 技术透镜
for name in ['security', 'arch', 'quality', 'perf']:
    path = os.path.join(instance_dir, f'lens-{name}.json')
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        findings = data.get('findings', [])
        # H-11 fix: 空 findings + 非 incomplete = 疑似异常（透镜可能未执行）
        incomplete = data.get('incomplete', False)
        if len(findings) == 0 and not incomplete:
            print(f'  ⚠️  lens-{name}.json: findings 为空但 incomplete=false（可能异常）')
        for finding in findings:
            finding['_source_file'] = f'lens-{name}.json'
            finding['_source_type'] = 'technical'
        all_findings.extend(findings)
        lens_count['technical'] += len(findings)
    else:
        missing_lenses.append(f'lens-{name}.json')

# 视角透镜
for fname in sorted(os.listdir(instance_dir)):
    if not fname.startswith('lens-perspective-') or not fname.endswith('.json'):
        continue
    path = os.path.join(instance_dir, fname)
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    # 软性发现
    soft = data.get('soft_findings', [])
    # 兼容不同 JSON 结构
    if not soft:
        phase_b = data.get('phase_b_soft_findings', [])
        soft = phase_b
    for s in soft:
        s['_source_file'] = fname
        s['_source_type'] = 'soft'
        pid = data.get('perspective_id', data.get('perspective', '?'))
        if 'lens_sources' not in s:
            s['lens_sources'] = [f'perspective:{pid}']
        if 'type' not in s:
            s['type'] = 'soft'
        if 'perspective_id' not in s:
            s['perspective_id'] = pid
    soft_findings.extend(soft)
    lens_count['perspective'] += len(soft)

# Level 1 去重: 同文件+同行号+同严重度 → 合并
dedup_map = {}
for f in all_findings:
    file_key = f.get('file', '?')
    line_key = f.get('line_range', '?')
    sev_key = f.get('severity', '?')
    dedup_key = f'{file_key}|{line_key}|{sev_key}'

    if dedup_key in dedup_map:
        existing = dedup_map[dedup_key]
        existing_sources = set(existing.get('lens_sources', []))
        new_sources = set(f.get('lens_sources', []))
        existing['lens_sources'] = list(existing_sources | new_sources)
        if len(f.get('description', '')) > len(existing.get('description', '')):
            existing['description'] = f['description']
            existing['recommendation'] = f.get('recommendation', '')
    else:
        dedup_map[dedup_key] = f

deduped_technical = list(dedup_map.values())
dup_removed = len(all_findings) - len(deduped_technical)

# 分配全局 ID
c_count = h_count = m_count = s_count = 0
final_issues = []
for f in deduped_technical:
    sev = f.get('severity', 'medium').lower()
    if sev == 'critical':
        c_count += 1
        f['id'] = f'C-{c_count}'
    elif sev == 'high':
        h_count += 1
        f['id'] = f'H-{h_count}'
    elif sev == 'medium':
        m_count += 1
        f['id'] = f'M-{m_count}'
    else:
        s_count += 1
        f['id'] = f'L-{s_count}'
    f['type'] = 'technical'
    # 清理内部字段
    f.pop('_source_file', None)
    f.pop('_source_type', None)
    final_issues.append(f)

# 强制包含所有软性发现（M-11 核心修复：不再遗漏）
soft_count = len(soft_findings)
for i, s in enumerate(soft_findings):
    if 'id' not in s or not s['id']:
        pid = s.get('perspective_id', 'unknown')
        s['id'] = f'P-{pid}-{i+1}'
    s.pop('_source_file', None)
    s.pop('_source_type', None)
final_issues.extend(soft_findings)

# 生成 checklist
checklist = {
    'round': 1,
    'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'instance_id': os.path.basename(instance_dir),
    'degradations': ['merge-reviewer unavailable — mechanical dedup performed by script'],
    'dedup_summary': {
        'total_raw': len(all_findings),
        'after_dedup': len(deduped_technical),
        'duplicates_removed': dup_removed,
        'soft_findings': soft_count,
        'total_issues': len(final_issues),
        'missing_lenses': missing_lenses
    },
    'coverage': {
        'technical_findings': len(deduped_technical),
        'soft_findings': soft_count,
        'technical_lenses_found': len([f for f in ['security','arch','quality','perf'] if f'lens-{f}.json' not in missing_lenses]),
        'perspective_lenses_found': len(set(s.get('perspective_id','?') for s in soft_findings))
    },
    'issues': final_issues,
    'checklist_status': 'complete'
}

output_path = os.path.join(instance_dir, 'checklist-round-1.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(checklist, f, ensure_ascii=False, indent=2)

# 打印摘要供编排者确认
print(f'去重完成: {len(all_findings)} 原始 → {len(deduped_technical)} 技术 + {soft_count} 软性 = {len(final_issues)} 总计')
print(f'严重度分布: C={c_count} H={h_count} M={m_count} L={s_count} 软性={soft_count}')
if missing_lenses:
    print(f'缺失透镜: {\", \".join(missing_lenses)}')
print(f'')
print(f'✅ 所有软性发现已强制包含（{soft_count} 项）——不再遗漏')
print(f'输出: {output_path}')
PYEOF

EXIT_CODE=$?
echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "✅ 机械去重完成"
else
    echo "🔴 机械去重脚本执行失败 (exit=$EXIT_CODE)"
    exit 2
fi
