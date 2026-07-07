#!/usr/bin/env bash
# audit-loop PreCompact Hook — 上下文压缩前保存审计进度快照
# 触发: 主会话上下文压缩前（PreCompact 事件）
# 用途: 防止 /compact 导致审计上下文丢失（AP-13 技术根因）
#       将当前 phase/round/pending_user_confirmation + checklist 摘要写入状态文件
#       压缩后编排者可读取 pre_compact_snapshot 恢复上下文
# 退出码: 始终 0（不阻塞压缩，仅做快照）

set -euo pipefail

# P1-3: 递归守卫
_GUARD="/tmp/audit-loop-hook-$$-$(basename "$0")"
[ -f "$_GUARD" ] && exit 0
touch "$_GUARD"
trap 'rm -f "$_GUARD"' EXIT

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_FILE="${PLUGIN_ROOT}/.audit-state.json"

# 无状态文件 → 非审计场景，放行
if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi

# 读取 instance_dir
if command -v jq >/dev/null 2>&1; then
    INSTANCE_DIR=$(jq -r '.instance_dir // ""' "$STATE_FILE" 2>/dev/null || echo "")
else
    INSTANCE_DIR=$(python -c "import json; d=json.load(open('$STATE_FILE','r',encoding='utf-8')); print(d.get('instance_dir',''))" 2>/dev/null || echo "")
fi

if [ -z "$INSTANCE_DIR" ] || [ ! -d "$INSTANCE_DIR" ]; then
    exit 0  # 无有效实例，放行
fi

# 构造快照：当前状态 + checklist 摘要
CHECKLIST="${INSTANCE_DIR}/checklist-round-1.json"
SNAPSHOT_FILE="${INSTANCE_DIR}/pre-compact-snapshot.json"

if [ -f "$CHECKLIST" ]; then
    if command -v jq >/dev/null 2>&1; then
        # 用 jq 合并状态文件关键字段 + checklist 摘要
        jq -n \
            --argfile state "$STATE_FILE" \
            --argfile checklist "$CHECKLIST" \
            '{
                snapshot_at: now | todate,
                phase: $state.phase,
                round: $state.round,
                pending_user_confirmation: $state.pending_user_confirmation,
                instance_dir: $state.instance_dir,
                checklist_summary: {
                    total: ($checklist.issues // $checklist.findings // []) | length,
                    critical: [$checklist.issues[]? | select(.severity == "critical")] | length,
                    high: [$checklist.issues[]? | select(.severity == "high")] | length,
                    medium: [$checklist.issues[]? | select(.severity == "medium")] | length,
                    low: [$checklist.issues[]? | select(.severity == "low")] | length,
                    fix_attempted: [$checklist.issues[]? | select(.status == "fix_attempted" or .status == "fixed")] | length
                }
            }' > "$SNAPSHOT_FILE" 2>/dev/null || true
    else
        # python 回退
        python - "$STATE_FILE" "$CHECKLIST" "$SNAPSHOT_FILE" << 'PYEOF' 2>/dev/null || true
import json, sys
from datetime import datetime, timezone
state = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
checklist = json.load(open(sys.argv[2], 'r', encoding='utf-8'))
issues = checklist.get('issues', checklist.get('findings', []))
def count(sev): return sum(1 for i in issues if i.get('severity') == sev)
snapshot = {
    'snapshot_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'phase': state.get('phase'),
    'round': state.get('round'),
    'pending_user_confirmation': state.get('pending_user_confirmation'),
    'instance_dir': state.get('instance_dir'),
    'checklist_summary': {
        'total': len(issues),
        'critical': count('critical'),
        'high': count('high'),
        'medium': count('medium'),
        'low': count('low'),
        'fix_attempted': sum(1 for i in issues if i.get('status') in ('fix_attempted', 'fixed')),
    }
}
json.dump(snapshot, open(sys.argv[3], 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
PYEOF
    fi
    echo "📸 audit-loop: 已保存压缩前快照到 ${SNAPSHOT_FILE}" >&2
fi

# 始终放行压缩
exit 0
