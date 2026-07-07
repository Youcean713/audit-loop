#!/usr/bin/env bash
# audit-loop PreToolUse Hook — Agent spawn 前置条件验证
# 触发: 每次主会话调用 Agent() 工具前
# 退出码: 0 = 允许 spawn, 2 = 阻止 spawn（stderr 会作为反馈传给编排者）
#
# 验证逻辑:
#   1. 如果不是 audit-loop Agent → 放行 (exit 0)
#   2. 如果是 audit-loop Agent → 检查前置条件
#      - spawn lens agent → 验证 instance_dir 存在 + asset-inventory 存在
#      - spawn verifier → 验证 checklist 含 fix_attempted (AP-13 强制执行)
#      - spawn merge-reviewer → 验证 4 个 lens JSON 存在

set -euo pipefail

# 读取 stdin（PreToolUse Hook 传入的 JSON）
STDIN_DATA=$(cat)

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ===== 1. 判断是否 audit-loop Agent =====
# PreToolUse Hook 的 stdin 包含 tool_name 和 tool_input
TOOL_NAME=$(echo "$STDIN_DATA" | python -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")

if [ "$TOOL_NAME" != "Agent" ] && [ "$TOOL_NAME" != "Task" ]; then
    exit 0  # 不是 Agent spawn，放行
fi

# 提取 Agent prompt 判断是否 audit-loop 相关
AGENT_PROMPT=$(echo "$STDIN_DATA" | python -c "import json,sys; d=json.load(sys.stdin); ti=d.get('tool_input',{}); print(ti.get('prompt',''))" 2>/dev/null || echo "")

if [ -z "$AGENT_PROMPT" ]; then
    exit 0  # 无法提取 prompt，放行
fi

# 检查提示词中是否包含 audit-loop 特征
if ! echo "$AGENT_PROMPT" | grep -qE '(audit-loop|INSTANCE_DIR=.*audit-|你是 audit-loop 的|lens-security|lens-architecture|lens-quality|lens-performance)' 2>/dev/null; then
    exit 0  # 不是 audit-loop Agent，放行
fi

# ===== 2. 提取 instance_dir =====
INSTANCE_DIR=$(echo "$AGENT_PROMPT" | grep -oE 'audit-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}' | head -1)
if [ -z "$INSTANCE_DIR" ]; then
    # 尝试从状态文件获取
    STATE_FILE="${PLUGIN_ROOT}/.audit-state.json"
    if [ -f "$STATE_FILE" ]; then
        INSTANCE_DIR=$(python -c "import json; d=json.load(open('$STATE_FILE','r',encoding='utf-8')); print(d.get('instance_dir',''))" 2>/dev/null || echo "")
    fi
fi

# 尝试找到完整路径
if [ -n "$INSTANCE_DIR" ]; then
    if [ -d "${CLAUDE_PROJECT_DIR}/.claude/cache/audit-context/${INSTANCE_DIR}" ]; then
        INSTANCE_DIR="${CLAUDE_PROJECT_DIR}/.claude/cache/audit-context/${INSTANCE_DIR}"
    elif [ -d "${HOME}/.claude/cache/audit-context/${INSTANCE_DIR}" ]; then
        INSTANCE_DIR="${HOME}/.claude/cache/audit-context/${INSTANCE_DIR}"
    fi
fi

# ===== 3. 按 Agent 类型执行前置条件检查 =====

# 检测 verifier spawn
if echo "$AGENT_PROMPT" | grep -qE '(verifier|验证 Agent|Mode C|终裁)' 2>/dev/null; then
    if [ -n "$INSTANCE_DIR" ] && [ -d "$INSTANCE_DIR" ]; then
        CHECKLIST="${INSTANCE_DIR}/checklist-round-1.json"
        if [ -f "$CHECKLIST" ]; then
            # AP-13 强制执行: 检查是否还有 open Medium（未标记 fix_attempted 或 requires_human）
            VIOLATION=$(python - "$CHECKLIST" << 'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    checklist = json.load(f)
issues = checklist.get('issues', checklist.get('findings', []))
m_open = [i for i in issues if i.get('severity','').lower() == 'medium'
          and i.get('status') not in ('fix_attempted','requires_human','fixed')]
if m_open:
    for m in m_open[:3]:
        print(f"  {m.get('id','?')}: {m.get('description','?')[:80]}")
    print(f"AP-13: {len(m_open)} 个 Medium 未修复，禁止 spawn verifier")
    sys.exit(1)
sys.exit(0)
PYEOF
            )
            if [ $? -ne 0 ]; then
                printf '%s\n' "🚨 audit-loop PreToolUse Hook: verifier spawn 被阻止" >&2
                printf '%s\n' "$VIOLATION" >&2
                printf '%s\n' "请先修复所有 Medium 问题（标记 fix_attempted 或 requires_human）后再进入验证阶段" >&2
                exit 2
            fi
        fi
    fi
fi

# 检测 merge-reviewer spawn
if echo "$AGENT_PROMPT" | grep -qE '(merge-reviewer|合并审查官)' 2>/dev/null; then
    if [ -n "$INSTANCE_DIR" ] && [ -d "$INSTANCE_DIR" ]; then
        MISSING=""
        for lens in lens-security lens-architecture lens-quality lens-performance; do
            if [ ! -f "${INSTANCE_DIR}/${lens}.json" ]; then
                MISSING="${MISSING} ${lens}"
            fi
        done
        if [ -n "$MISSING" ]; then
            printf '%s\n' "🚨 audit-loop PreToolUse Hook: merge-reviewer spawn 被阻止" >&2
            printf '%s\n' "缺少透镜输出:${MISSING}" >&2
            printf '%s\n' "请先确保 4 个技术透镜全部完成后再 spawn 合并审查官" >&2
            exit 2
        fi
    fi
fi

# 检测 lens agent spawn（技术透镜或视角透镜）
if echo "$AGENT_PROMPT" | grep -qE '(lens-security|lens-architecture|lens-quality|lens-performance|lens-perspective)' 2>/dev/null; then
    if [ -n "$INSTANCE_DIR" ] && [ -d "$INSTANCE_DIR" ]; then
        # 检查 asset-inventory 是否存在（Step 0 必须完成）
        if [ ! -f "${INSTANCE_DIR}/asset-inventory.json" ]; then
            printf '%s\n' "🚨 audit-loop PreToolUse Hook: lens agent spawn 被阻止" >&2
            printf '%s\n' "缺少 asset-inventory.json — Step 0 未完成或未运行 classify-assets.sh" >&2
            printf '%s\n' "请先完成 Step 0（setup-instance.sh + classify-assets.sh + detect-supply-chain.sh）" >&2
            exit 2
        fi
    fi
fi

# 所有检查通过
exit 0
