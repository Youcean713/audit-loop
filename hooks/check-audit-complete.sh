#!/usr/bin/env bash
# audit-loop Stop Hook — 防止审计未完成时退出主会话
# 触发: 主 Agent (编排者) 完成响应后
# 退出码: 0 = 可以停止, 2 = 阻止停止（审计未完成）
#
# 验证逻辑:
#   1. 无活跃审计 → 放行
#   2. 有活跃审计但未完成 → 阻止 Stop，强制编排者继续
#      - 检查 checklist 是否存在
#      - 检查最终报告是否已生成
#      - 检查退出裁决是否已执行

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_FILE="${PLUGIN_ROOT}/.audit-state.json"

# ===== 1. 判断是否有活跃审计 =====
if [ ! -f "$STATE_FILE" ]; then
    exit 0  # 无审计状态文件，放行
fi

# 检查状态文件是否在有效期内
MTIME=$(stat -c %Y "$STATE_FILE" 2>/dev/null || stat -f %m "$STATE_FILE" 2>/dev/null || echo 0)
NOW=$(date +%s 2>/dev/null || echo 0)
if [ "$NOW" -gt 0 ] && [ "$MTIME" -gt 0 ] && [ $((NOW - MTIME)) -gt 7200 ]; then
    exit 0  # 超过 2 小时，视为已过期，放行
fi

# ===== 2. 读取审计状态 =====
ACTIVE=$(python -c "import json; d=json.load(open('$STATE_FILE','r',encoding='utf-8')); print(d.get('active',False))" 2>/dev/null || echo "False")
if [ "$ACTIVE" != "True" ] && [ "$ACTIVE" != "true" ]; then
    exit 0  # 审计已标记为非活跃，放行
fi

INSTANCE_DIR=$(python -c "import json; d=json.load(open('$STATE_FILE','r',encoding='utf-8')); print(d.get('instance_dir',''))" 2>/dev/null || echo "")
PHASE=$(python -c "import json; d=json.load(open('$STATE_FILE','r',encoding='utf-8')); print(d.get('phase',''))" 2>/dev/null || echo "")

if [ -z "$INSTANCE_DIR" ] || [ ! -d "$INSTANCE_DIR" ]; then
    exit 0  # 实例目录无效，放行
fi

# ===== 3. 检查审计完成度 =====

# 审计完成的标志（任一满足即可）:
COMPLETE=false

# 标志 1: 最终报告已生成
if [ -f "${INSTANCE_DIR}/audit-final-report.md" ]; then
    COMPLETE=true
fi

# 标志 2: 退出裁决已执行
if [ -f "${INSTANCE_DIR}/exit-verdict.json" ]; then
    VERDICT=$(python -c "import json; d=json.load(open('${INSTANCE_DIR}/exit-verdict.json','r',encoding='utf-8')); print(d.get('verdict',''))" 2>/dev/null || echo "")
    if [ -n "$VERDICT" ]; then
        COMPLETE=true
    fi
fi

# 标志 3: 用户已选择「停止（仅报告）」— checklist 存在但无 fix_attempted
if [ -f "${INSTANCE_DIR}/checklist-round-1.json" ]; then
    USER_STOPPED=$(python -c "
import json
d=json.load(open('${INSTANCE_DIR}/checklist-round-1.json','r',encoding='utf-8'))
issues = d.get('issues', d.get('findings', []))
# 如果有任何 fix_attempted，说明用户选择了继续修复
has_fix = any(i.get('status') in ('fix_attempted','fixed') for i in issues)
print('stopped' if not has_fix and len(issues) > 0 else 'fixing')
" 2>/dev/null || echo "unknown")
    if [ "$USER_STOPPED" = "stopped" ]; then
        COMPLETE=true  # 用户选择停止仅报告，允许退出
    fi
fi

# ===== 4. 决定 =====
if [ "$COMPLETE" = true ]; then
    # 审计已完成，清理状态文件
    rm -f "$STATE_FILE"
    exit 0
fi

# 审计未完成，阻止 Stop
printf '%s\n' "🚨 audit-loop Stop Hook: 审计未完成，阻止会话退出" >&2
printf '%s\n' "当前阶段: ${PHASE:-未知}" >&2
printf '%s\n' "实例目录: ${INSTANCE_DIR}" >&2
printf '%s\n' "" >&2
printf '%s\n' "以下审计步骤尚未完成:" >&2

if [ ! -f "${INSTANCE_DIR}/checklist-round-1.json" ]; then
    printf '%s\n' "  ❌ Round 1 未完成（checklist 不存在）" >&2
fi
if [ ! -f "${INSTANCE_DIR}/exit-verdict.json" ]; then
    printf '%s\n' "  ❌ 退出裁决未执行" >&2
fi
if [ ! -f "${INSTANCE_DIR}/audit-final-report.md" ]; then
    printf '%s\n' "  ❌ 最终报告未生成" >&2
fi

printf '%s\n' "" >&2
printf '%s\n' "请继续执行审计流程，完成所有步骤后会话将自动放行。" >&2
exit 2
