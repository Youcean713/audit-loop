#!/usr/bin/env bash
# audit-loop 盲区收割脚本（变异审计 v2 - 自生长盲区库）
# 用途: 从 Case A 全量重审 + verifier 的 New/Missed 发现中收割盲区 → 持久化库
# 核心原则: 只收割"透镜漏掉过的"，不收割"透镜找到过的"——这样 MSI 才有意义
# 用法: bash scripts/harvest-blindspots.sh <instance_dir>
# 输出: skills/audit-loop/mutation-library/library.json (持久化，跨实例)
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 脚本错误

set -euo pipefail

INSTANCE_DIR="${1:-}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/harvest-blindspots.sh <instance_dir>"
    exit 1
fi

if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR"
    exit 2
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIBRARY_DIR="$SKILL_DIR/mutation-library"
INSTANCE_ID=$(basename "$INSTANCE_DIR")

mkdir -p "$LIBRARY_DIR/security" "$LIBRARY_DIR/architecture" "$LIBRARY_DIR/quality" "$LIBRARY_DIR/performance"

echo "=== audit-loop 盲区收割 ==="
echo "实例: $INSTANCE_ID"
echo "库目录: $LIBRARY_DIR"
echo ""

# 使用临时文件传递 Python 代码，避免 bash 转义问题
# Cross-platform temp file (mktemp not available on Windows Git Bash)
PYTHON_SCRIPT="${TMPDIR:-/tmp}/audit-loop-py-$$-$(date +%s).tmp"
cat > "$PYTHON_SCRIPT" << 'PYEOF'
import json, os, sys, hashlib
from datetime import datetime, timezone

instance_dir = sys.argv[1]
library_dir = sys.argv[2]
instance_id = os.path.basename(instance_dir)

# === Step 1: 识别盲区来源 ===
blindspots = []

# 来源 A: Case A 全量重审的 match-result.json 中未匹配的 New
match_result_path = os.path.join(instance_dir, 'match-result.json')
if os.path.exists(match_result_path):
    with open(match_result_path, 'r', encoding='utf-8') as f:
        match_data = json.load(f)
    for nf in match_data.get('new_findings', []):
        blindspots.append({
            'source': 'case_a_missed',
            'id': nf.get('id', '?'),
            'file': nf.get('file', ''),
            'line_range': nf.get('line_range', ''),
            'severity': nf.get('severity', 'medium'),
            'description': nf.get('description', ''),
            'code_excerpt': nf.get('code_excerpt', ''),
            'dimension': nf.get('dimension', 'unknown'),
            'cwe_id': nf.get('cwe_id', ''),
            'trigger_condition': nf.get('trigger_condition', '')
        })

# 来源 B: verifier 验证中的 New（blast-radius 发现的修复引入回归）
for vfile in ['verification-round-2.json', 'verification-round-3.json']:
    vpath = os.path.join(instance_dir, vfile)
    if os.path.exists(vpath):
        with open(vpath, 'r', encoding='utf-8') as f:
            vdata = json.load(f)
        blast = vdata.get('blast_radius', {})
        for nf in blast.get('new_findings', []):
            blindspots.append({
                'source': 'verifier_blast_radius_new',
                'id': nf.get('id', '?'),
                'file': nf.get('file', ''),
                'line_range': nf.get('line_range', ''),
                'severity': nf.get('severity', 'medium'),
                'description': nf.get('description', ''),
                'code_excerpt': nf.get('code_excerpt', ''),
                'dimension': nf.get('dimension', nf.get('lens', 'unknown')),
                'cwe_id': nf.get('cwe_id', ''),
                'trigger_condition': nf.get('trigger_condition', '')
            })

# 来源 C: 编排者手工标记的盲区
manual_path = os.path.join(instance_dir, 'manual-blindspots.json')
if os.path.exists(manual_path):
    with open(manual_path, 'r', encoding='utf-8') as f:
        mdata = json.load(f)
    for mb in mdata.get('blindspots', []):
        blindspots.append({'source': 'manual_report', **mb})

if not blindspots:
    print('本次审计无盲区可收割（Case A 未发现 Round 1 遗漏，verifier 无 New）')
    print('这是好结果——透镜覆盖完整。库不变更。')
    sys.exit(0)

# === Step 2: 维度归类 ===
def classify_dimension(bs):
    dim = bs.get('dimension', '').lower()
    desc = bs.get('description', '').lower()
    src = bs.get('source', '')
    if dim in ('security', 'architecture', 'quality', 'performance'):
        return dim
    if 'security' in src or 'sec' in dim:
        return 'security'
    if 'arch' in src or 'arch' in dim:
        return 'architecture'
    if 'qual' in src or 'qual' in dim:
        return 'quality'
    if 'perf' in src or 'perf' in dim:
        return 'performance'
    sec_kw = ['注入', 'injection', 'xss', 'sql', '认证', 'auth', '密钥', 'key', 'cwe']
    arch_kw = ['耦合', 'coupling', '依赖', 'dependency', '分层', '架构', 'arch']
    qual_kw = ['错误处理', 'error', '边界', 'boundary', '一致性', 'consisten']
    perf_kw = ['性能', 'performance', 'token', '冗余', 'redundant', '缓存', 'cache']
    for kw in sec_kw:
        if kw in desc:
            return 'security'
    for kw in arch_kw:
        if kw in desc:
            return 'architecture'
    for kw in qual_kw:
        if kw in desc:
            return 'quality'
    for kw in perf_kw:
        if kw in desc:
            return 'performance'
    return 'quality'

for bs in blindspots:
    bs['dimension'] = classify_dimension(bs)

# === Step 3: 读取现有库索引 ===
library_index_path = os.path.join(library_dir, 'library.json')
if os.path.exists(library_index_path):
    with open(library_index_path, 'r', encoding='utf-8') as f:
        library_index = json.load(f)
else:
    library_index = {
        'created_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'total_entries': 0,
        'max_entries': 200,
        'entries': []
    }

def fingerprint(bs):
    content = bs.get('dimension','') + '|' + bs.get('file','') + '|' + bs.get('line_range','') + '|' + bs.get('description','')[:50]
    return hashlib.sha256(content.encode()).hexdigest()[:16]

existing_fps = {e.get('fingerprint') for e in library_index.get('entries', [])}

# === Step 4: 去重 + 追加（含安全验证——H-12 fix） ===
new_entries = []
duplicates = 0
rejected_unsafe = 0
now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

# H-12 fix: 盲区条目安全验证——防止注入载荷持久化到盲区库
INJECTION_PATTERNS = ['system:', 'assistant:', '[INST]', '<|im_start|>', 'ignore previous',
                      '```', '<script', 'sudo ', 'rm -rf', 'curl ', 'wget ']
def is_safe(bs):
    desc = bs.get('description', '')
    excerpt = bs.get('code_excerpt', '')
    combined = (desc + ' ' + excerpt).lower()
    for pattern in INJECTION_PATTERNS:
        if pattern.lower() in combined:
            return False
    # 拒绝含 URL 的条目
    if 'http://' in combined or 'https://' in combined:
        return False
    return True

for bs in blindspots:
    if not is_safe(bs):
        rejected_unsafe += 1
        continue
    fp = fingerprint(bs)
    if fp in existing_fps:
        for e in library_index['entries']:
            if e.get('fingerprint') == fp:
                e['seen_count'] = e.get('seen_count', 1) + 1
                e['last_seen'] = now_str
                duplicates += 1
                break
    else:
        entry = {
            'id': 'ML-' + bs['dimension'][:3] + '-' + str(len(library_index['entries']) + len(new_entries) + 1).zfill(3),
            'fingerprint': fp,
            'dimension': bs['dimension'],
            'source': bs.get('source', ''),
            'file': bs.get('file', ''),
            'line_range': bs.get('line_range', ''),
            'severity': bs.get('severity', 'medium'),
            'description': bs.get('description', ''),
            'code_excerpt': bs.get('code_excerpt', ''),
            'trigger_condition': bs.get('trigger_condition', ''),
            'cwe_id': bs.get('cwe_id', ''),
            'harvested_from': instance_id,
            'harvested_at': now_str,
            'seen_count': 1,
            'last_seen': now_str,
            'validation_history': []
        }
        new_entries.append(entry)
        existing_fps.add(fp)

# === Step 5: 容量管理（LRU 淘汰） ===
max_entries = library_index.get('max_entries', 200)
library_index['entries'].extend(new_entries)
evicted_count = 0
if len(library_index['entries']) > max_entries:
    library_index['entries'].sort(key=lambda e: (e.get('seen_count', 1), e.get('last_seen', '')))
    evicted_count = len(library_index['entries']) - max_entries
    library_index['entries'] = library_index['entries'][evicted_count:]

library_index['total_entries'] = len(library_index['entries'])
library_index['last_updated'] = now_str

# === Step 6: 写入 ===
with open(library_index_path, 'w', encoding='utf-8') as f:
    json.dump(library_index, f, ensure_ascii=False, indent=2)

# 按维度统计
dim_counts = {'security': 0, 'architecture': 0, 'quality': 0, 'performance': 0}
for e in library_index['entries']:
    dim_counts[e['dimension']] = dim_counts.get(e['dimension'], 0) + 1

# 输出摘要
src_counts = {}
for b in blindspots:
    src_counts[b['source']] = src_counts.get(b['source'], 0) + 1

print('盲区来源:')
for src, cnt in src_counts.items():
    print('  - ' + src + ': ' + str(cnt))
print('')
print('收割结果:')
print('  新增盲区: ' + str(len(new_entries)) + ' 条')
print('  重复盲区（seen_count++）: ' + str(duplicates) + ' 条')
if evicted_count > 0:
    print('  LRU 淘汰: ' + str(evicted_count) + ' 条')
print('  库总量: ' + str(library_index['total_entries']) + ' / ' + str(max_entries))
print('  维度分布: ' + ' / '.join(k + '=' + str(v) for k, v in dim_counts.items()))
print('输出: ' + library_index_path)
sys.exit(0)
PYEOF

set +e
python "$PYTHON_SCRIPT" "$INSTANCE_DIR" "$LIBRARY_DIR"
EXIT_CODE=$?
set -e
rm -f "$PYTHON_SCRIPT"
exit $EXIT_CODE
