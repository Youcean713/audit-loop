#!/usr/bin/env bash
# audit-loop 证据链生成脚本
# 用途: 对实例目录下所有产出物计算 SHA-256 → 追加到 .audit-chain.json (NDJSON append-only)
# 用法: bash scripts/generate-evidence-chain.sh <instance_dir> [action]
# action: write (默认, 记录写入) | verify (验证链完整性) | audit_end (审计结束记录)
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 链断裂/脚本错误

set -euo pipefail

INSTANCE_DIR="${1:-}"
ACTION="${2:-write}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/generate-evidence-chain.sh <instance_dir> [write|verify|audit_end]"
    exit 1
fi

if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR"
    exit 2
fi

CHAIN_FILE="$INSTANCE_DIR/.audit-chain.json"
INSTANCE_ID=$(basename "$INSTANCE_DIR")

echo "=== audit-loop 证据链 ($ACTION) ==="
echo "实例: $INSTANCE_ID"
echo ""

set +e
python -c "
import json, os, sys, hashlib
from datetime import datetime, timezone

instance_dir = sys.argv[1]
action = sys.argv[2] if len(sys.argv) > 2 else 'write'
instance_id = os.path.basename(instance_dir)
chain_file = os.path.join(instance_dir, '.audit-chain.json')

def compute_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            h.update(chunk)
    return h.hexdigest()

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

if action == 'verify':
    # 验证模式: 重新计算所有文件 hash 并与链中记录对比
    if not os.path.exists(chain_file):
        print('⚠️  证据链文件不存在，无可验证内容')
        sys.exit(0)

    entries = []
    with open(chain_file, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))

    chain_broken = False
    # 只对 write 类型的记录做 hash 比对（audit_end 不对应文件，verify 是历史快照）
    seen_files = {}
    for entry in entries:
        if entry.get('action') == 'write':
            fname = entry.get('file', '')
            seen_files[fname] = entry  # 保留最新一条 write 记录

    for fname, entry in seen_files.items():
        fpath = os.path.join(instance_dir, fname)
        if os.path.exists(fpath):
            current_hash = compute_sha256(fpath)
            recorded_hash = entry.get('sha256', '')
            match = current_hash == recorded_hash
            status = '✅' if match else '❌ 链断裂'
            print(f'  {status} {fname}: {recorded_hash[:16]}...')
            if not match:
                chain_broken = True
        else:
            print(f'  ⚠️  文件缺失: {fname}')

    if chain_broken:
        print('')
        print('🔴 证据链断裂 — 标记 EVIDENCE_TAMPERED')
        sys.exit(2)
    else:
        print('')
        print(f'✅ 证据链完整 ({len(entries)} 条记录)')
        sys.exit(0)

elif action == 'audit_end':
    # 审计结束记录
    # 读取 exit-verdict
    verdict_path = os.path.join(instance_dir, 'exit-verdict.json')
    verdict = None
    if os.path.exists(verdict_path):
        with open(verdict_path, 'r', encoding='utf-8') as f:
            verdict = json.load(f)

    entry = {
        'timestamp': now,
        'action': 'audit_end',
        'instance_id': instance_id,
        'verdict': verdict.get('verdict') if verdict else 'UNKNOWN',
        'exit_code': verdict.get('exit_code') if verdict else 2,
        'final_c_count': verdict.get('current_c') if verdict else 0,
        'final_h_count': verdict.get('current_h') if verdict else 0
    }
    with open(chain_file, 'a', encoding='utf-8') as f:
        f.write(json.dumps(entry, ensure_ascii=False) + '\n')
    print(f'✅ 审计结束记录已追加: verdict={entry[\"verdict\"]}')
    sys.exit(0)

else:  # write
    # 写入模式: 对所有产出物计算 hash 并追加
    OUTPUT_FILES = [
        'lens-security.json', 'lens-arch.json', 'lens-quality.json', 'lens-perf.json',
        'checklist-round-1.json', 'verification-round-2.json', 'verification-round-3.json',
        'asset-inventory.json', 'exit-verdict.json', 'diff-table.json',
        'audit-report.sarif.json',
        'audit-report-dev.md', 'audit-report-exec.md', 'audit-report-compliance.md'
    ]
    # 加上所有视角透镜输出
    for fname in os.listdir(instance_dir):
        if fname.startswith('lens-perspective-') and fname.endswith('.json'):
            if fname not in OUTPUT_FILES:
                OUTPUT_FILES.append(fname)

    written = 0
    skipped = 0
    with open(chain_file, 'a', encoding='utf-8') as f:
        for fname in OUTPUT_FILES:
            fpath = os.path.join(instance_dir, fname)
            if os.path.exists(fpath):
                sha = compute_sha256(fpath)
                entry = {
                    'timestamp': now,
                    'file': fname,
                    'sha256': sha,
                    'action': 'write',
                    'instance_id': instance_id
                }
                f.write(json.dumps(entry, ensure_ascii=False) + '\n')
                written += 1
            else:
                skipped += 1

    print(f'已记录 {written} 个文件的 SHA-256')
    if skipped > 0:
        print(f'跳过 {skipped} 个不存在的文件')
    print(f'证据链: {chain_file}')
    sys.exit(0)
" "$INSTANCE_DIR" "$ACTION"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
