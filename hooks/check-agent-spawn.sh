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

# P1-3: 递归守卫，防 Hook 在子 Agent 内部循环触发（Dich01 生产案例模式）
_GUARD="/tmp/audit-loop-hook-$$-$(basename "$0")"
[ -f "$_GUARD" ] && exit 0
touch "$_GUARD"
trap 'rm -f "$_GUARD"' EXIT

# P1-2: JSON 字段读取 helper（jq 优先，python sys.argv 回退，无 shell 插值消除注入风险 M-6/S-1）
_jf() {
    local file="$1" key="$2" default="${3:-}"
    if command -v jq >/dev/null 2>&1; then
        local v
        v=$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null) || v=""
        if [ -n "$v" ] && [ "$v" != "null" ]; then printf '%s' "$v"; else printf '%s' "$default"; fi
    else
        python -c "import json,sys; d=json.load(open(sys.argv[1],'r',encoding='utf-8')); v=d.get(sys.argv[2],sys.argv[3]); print(v if v is not None else sys.argv[3])" "$file" "$key" "$default" 2>/dev/null || printf '%s' "$default"
    fi
}

# 读取 stdin（PreToolUse Hook 传入的 JSON）
STDIN_DATA=$(cat)

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ===== 1. 判断是否 audit-loop Agent =====
# PreToolUse Hook 的 stdin 包含 tool_name 和 tool_input
TOOL_NAME=$(echo "$STDIN_DATA" | python -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")

if [ "$TOOL_NAME" != "Agent" ] && [ "$TOOL_NAME" != "Task" ]; then
    exit 0  # 不是 Agent spawn，放行
fi

# 提取 Agent prompt 和 subagent_type（双信号判断）
AGENT_PROMPT=$(echo "$STDIN_DATA" | python -c "import json,sys; d=json.load(sys.stdin); ti=d.get('tool_input',{}); print(ti.get('prompt',''))" 2>/dev/null || echo "")
if command -v jq >/dev/null 2>&1; then
    SUBAGENT_TYPE=$(echo "$STDIN_DATA" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
else
    SUBAGENT_TYPE=$(echo "$STDIN_DATA" | python -c "import json,sys; ti=json.load(sys.stdin).get('tool_input',{}); print(ti.get('subagent_type',''))" 2>/dev/null || echo "")
fi

# 判断是否 audit-loop（双信号：subagent_type 前缀 + prompt 特征）
IS_BY_TYPE=false
IS_BY_PROMPT=false
case "$SUBAGENT_TYPE" in audit-loop:*) IS_BY_TYPE=true ;; esac
if echo "$AGENT_PROMPT" | grep -qE '(audit-loop|INSTANCE_DIR=.*audit-|你是 audit-loop 的|lens-security|lens-architecture|lens-quality|lens-performance)' 2>/dev/null; then
    IS_BY_PROMPT=true
fi

# ===== AP-12 fix: prompt 含 audit-loop 特征但未用 subagent_type → 违规 =====
# Why: 不带 subagent_type 会走 general-purpose 继承全部 Tools:*（C-3 真实根因）
if [ "$IS_BY_PROMPT" = true ] && [ "$IS_BY_TYPE" = false ]; then
    printf '%s\n' "🚨 audit-loop PreToolUse Hook: AP-12 违规" >&2
    printf '%s\n' "检测到 audit-loop 审计意图，但未使用 subagent_type 调用" >&2
    printf '%s\n' "必须用 Agent(subagent_type=\"audit-loop:lens-security\", ...) 等具名类型" >&2
    printf '%s\n' "禁止用 Agent(model=..., prompt=...) 通用调用（会继承全部 Tools:* 绕过工具限制）" >&2
    exit 2
fi

# 非 audit-loop（双信号都为 false）→ 放行
if [ "$IS_BY_TYPE" = false ]; then
    exit 0
fi

# 校验 subagent_type 在白名单内
case "$SUBAGENT_TYPE" in
    audit-loop:lens-security|audit-loop:lens-architecture|audit-loop:lens-quality|\
    audit-loop:lens-performance|audit-loop:lens-perspective|audit-loop:merge-reviewer|\
    audit-loop:verifier|audit-loop:perspective-recommender|audit-loop:code-auditor) ;;
    *)
        printf '%s\n' "🚨 audit-loop PreToolUse Hook: 未知 subagent_type: $SUBAGENT_TYPE" >&2
        printf '%s\n' "允许的类型: audit-loop:lens-{security,architecture,quality,performance,perspective}," >&2
        printf '%s\n' "          audit-loop:{merge-reviewer,verifier,perspective-recommender,code-auditor}" >&2
        exit 2
        ;;
esac

# ===== 2. 提取 instance_dir =====
# 注意: grep 无匹配返回 exit 1，在 set -euo pipefail 下会触发脚本退出，需 || true
INSTANCE_DIR=$( (echo "$AGENT_PROMPT" | grep -oE 'audit-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}' 2>/dev/null || true) | head -1)
if [ -z "$INSTANCE_DIR" ]; then
    # 尝试从状态文件获取（P1-2: 用 _jf helper 替代 python -c）
    STATE_FILE="${PLUGIN_ROOT}/.audit-state.json"
    if [ -f "$STATE_FILE" ]; then
        INSTANCE_DIR=$(_jf "$STATE_FILE" instance_dir "")
    fi
fi

# 尝试找到完整路径（CLAUDE_PROJECT_DIR 可能未设置，用 :- 防 set -u 报错）
if [ -n "$INSTANCE_DIR" ]; then
    if [ -d "${CLAUDE_PROJECT_DIR:-}/.claude/cache/audit-context/${INSTANCE_DIR}" ]; then
        INSTANCE_DIR="${CLAUDE_PROJECT_DIR:-}/.claude/cache/audit-context/${INSTANCE_DIR}"
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
        # 透镜名 → 输出文件名映射（与 round-details.md 一致）
        for lens_file in lens-security.json lens-arch.json lens-quality.json lens-perf.json; do
            if [ ! -f "${INSTANCE_DIR}/${lens_file}" ]; then
                MISSING="${MISSING} ${lens_file}"
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
