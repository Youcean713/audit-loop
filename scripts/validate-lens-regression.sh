#!/usr/bin/env bash
# audit-loop 透镜回归验证脚本（变异审计 v2 - MSI 计算）
# 用途: 遍历盲区库，对每条盲区构造最小审计范围 → 运行对应维度透镜 → 计算捕获率 MSI
# 触发: lens prompt 文件变化时 / 手动触发 / 每 N 次审计
# 用法: bash scripts/validate-lens-regression.sh [dimension]
#   dimension: all(默认) | security | architecture | quality | performance
# 退出码: 0 = MSI ≥ 70% (合格), 1 = MSI < 70% (透镜退化), 2 = 脚本错误

set -euo pipefail

DIMENSION="${1:-all}"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIBRARY_DIR="$SKILL_DIR/mutation-library"
LIBRARY_INDEX="$LIBRARY_DIR/library.json"

if [ ! -f "$LIBRARY_INDEX" ]; then
    printf '%s\n' "盲区库不存在: $LIBRARY_INDEX"
    printf '%s\n' "请先在审计中触发 Case A 全量重审以收割盲区。"
    exit 0
fi

echo "=== audit-loop 透镜回归验证（变异审计 MSI）==="
echo "维度: $DIMENSION"
echo ""

# 使用临时文件传递 Python 代码
# Cross-platform temp file (mktemp not available on Windows Git Bash)
PYTHON_SCRIPT="${TMPDIR:-/tmp}/audit-loop-py-$$-$(date +%s).tmp"
cat > "$PYTHON_SCRIPT" << 'PYEOF'
import json, os, sys, hashlib, subprocess, tempfile
from datetime import datetime, timezone

skill_dir = sys.argv[1]
library_dir = sys.argv[2]
dimension_filter = sys.argv[3] if len(sys.argv) > 3 else 'all'

library_index_path = os.path.join(library_dir, 'library.json')
with open(library_index_path, 'r', encoding='utf-8') as f:
    library = json.load(f)

entries = library.get('entries', [])
if not entries:
    print('盲区库为空，无内容可验证。')
    print('提示: 透镜尚未发现过盲区，或盲区已被清理。')
    sys.exit(0)

# 按维度筛选
if dimension_filter != 'all':
    entries = [e for e in entries if e['dimension'] == dimension_filter]
    if not entries:
        print('维度 ' + dimension_filter + ' 无盲区条目。')
        sys.exit(0)

print('验证 ' + str(len(entries)) + ' 条盲区')
print('')

# 透镜模型映射
LENS_MODELS = {
    'security': 'fable',
    'architecture': 'sonnet',
    'quality': 'sonnet',
    'performance': 'haiku'
}
LENS_FILES = {
    'security': 'lens-security.md',
    'architecture': 'lens-architecture.md',
    'quality': 'lens-quality.md',
    'performance': 'lens-performance.md'
}

# 对每条盲区，构造最小审计范围（含 code_excerpt 的临时文件），
# 然后说明：此脚本不实际 spawn Agent（成本高），而是准备验证输入并记录 MSI 框架。
# 实际 spawn 由编排者根据本脚本输出决定。
#
# 设计决策: validate 脚本负责"准备 + 统计"，编排者负责"spawn + 比对"。
# 这样脚本可重复运行不产生 LLM 费用，编排者按需触发实际验证。

# 准备验证输入
validation_inputs = []
for entry in entries:
    dim = entry['dimension']
    excerpt = entry.get('code_excerpt', '')
    if not excerpt:
        # 无代码片段——跳过（无法构造验证输入）
        continue

    # 构造最小审计范围文件（把 code_excerpt 包成可审计的上下文）
    # 注: 实际透镜审计文件，所以我们把 excerpt 放进一个 markdown 文件
    # 作为"待审计代码片段"
    min_scope = '# 待审计代码片段（盲区库回归验证）\n\n'
    min_scope += '## 来源盲区: ' + entry['id'] + '\n'
    min_scope += '## 维度: ' + dim + '\n'
    min_scope += '## 原始描述: ' + entry.get('description', '') + '\n\n'
    min_scope += '```\n' + excerpt + '\n```\n'

    validation_inputs.append({
        'entry_id': entry['id'],
        'dimension': dim,
        'severity': entry.get('severity', 'medium'),
        'description': entry.get('description', ''),
        'min_scope': min_scope,
        'lens_file': LENS_FILES.get(dim, 'lens-quality.md'),
        'lens_model': LENS_MODELS.get(dim, 'sonnet')
    })

# 按维度分组统计
dim_groups = {}
for vi in validation_inputs:
    dim_groups.setdefault(vi['dimension'], []).append(vi)

print('=== 验证输入准备完成 ===')
print('')
for dim, vis in dim_groups.items():
    print('维度 ' + dim + ': ' + str(len(vis)) + ' 条盲区待验证 (透镜: ' + LENS_FILES.get(dim, '?') + ', 模型: ' + LENS_MODELS.get(dim, '?') + ')')

print('')
print('=== 编排者执行指引 ===')
print('')
print('对每个维度的盲区，编排者:')
print('1. 从 agents/' + '<对应lens>' + '.md 提取 prompt')
print('2. 将 min_scope 作为审计范围注入')
print('3. spawn Agent(model=<对应模型>, prompt=<lens prompt + min_scope>)')
print('4. 检查 Agent 输出是否报告了匹配的 issue')
print('5. 用 match-issues.sh 比对 Agent 发现 vs 库中盲区')
print('')

# 写入验证任务清单（供编排者执行）
validation_tasks_path = os.path.join(library_dir, 'validation-tasks.json')
tasks = {
    'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'total_tasks': len(validation_inputs),
    'dimension_filter': dimension_filter,
    'tasks': validation_inputs
}
with open(validation_tasks_path, 'w', encoding='utf-8') as f:
    json.dump(tasks, f, ensure_ascii=False, indent=2)

print('验证任务清单: ' + validation_tasks_path)
print('')

# === MSI 框架（基于 validation_history） ===
# 读取历史验证结果计算当前 MSI
print('=== 历史 MSI（基于 validation_history）===')
print('')
msi_by_dim = {}
for dim, vis in dim_groups.items():
    total = len(vis)
    caught = 0
    validated = 0
    for vi in vis:
        # 查找对应 entry 的 validation_history
        for e in entries:
            if e['id'] == vi['entry_id']:
                hist = e.get('validation_history', [])
                if hist:
                    validated += 1
                    if hist[-1].get('caught'):
                        caught += 1
                break
    if validated > 0:
        msi = round(caught / validated * 100, 1)
    else:
        msi = None
    msi_by_dim[dim] = {'msi': msi, 'caught': caught, 'validated': validated, 'total': total}
    msi_str = str(msi) + '%' if msi is not None else '未验证'
    print('  ' + dim + ': MSI=' + msi_str + ' (' + str(caught) + '/' + str(validated) + ' 已验证, 共 ' + str(total) + ' 条)')

print('')

# 整体 MSI
total_caught = sum(d['caught'] for d in msi_by_dim.values())
total_validated = sum(d['validated'] for d in msi_by_dim.values())
overall_msi = round(total_caught / total_validated * 100, 1) if total_validated > 0 else None
overall_str = str(overall_msi) + '%' if overall_msi is not None else '未验证'
print('整体 MSI: ' + overall_str + ' (' + str(total_caught) + '/' + str(total_validated) + ' 已验证)')

# 退出码判定（仅在有验证数据时）
if overall_msi is not None:
    if overall_msi >= 70:
        print('✅ MSI ≥ 70% — 透镜回归合格')
        sys.exit(0)
    else:
        print('🔴 MSI < 70% — 透镜可能退化，需检查最近 lens prompt 修改')
        sys.exit(1)
else:
    print('⚠️  无历史验证数据——请编排者执行验证任务后重跑本脚本计算 MSI')
    sys.exit(0)
PYEOF

set +e
python "$PYTHON_SCRIPT" "$SKILL_DIR" "$LIBRARY_DIR" "$DIMENSION"
EXIT_CODE=$?
set -e
rm -f "$PYTHON_SCRIPT"
exit $EXIT_CODE
