#!/usr/bin/env bash
# audit-loop 退出裁决脚本（门控决策树强制执行）
# 用途: Round 2/3 终裁后，根据 verification JSON 计算最终门控裁决
# 用法: bash scripts/compute-exit-verdict.sh <instance_dir> [prev_c_plus_h] [round_num]
# 退出码: 0 = SHIP/CAUTION, 1 = HOLD, 2 = BLOCK, 3 = USAGE_ERROR, 4 = IO_ERROR
#   H-7 fix: USAGE_ERROR(3) 和 IO_ERROR(4) 从 BLOCK(2) 中分离, CI pipeline 可区分门控阻断和脚本错误
#
# 决策树（按优先级，首个匹配生效）:
#   0. round ≥ 3 且 C+H > 0 → BLOCK (H-5 fix, 防无限循环)
#   1. 任何 CVSS ≥ 9.0 的 Critical → BLOCK (exit 2)
#   2. 任何 CISA KEV 在野利用 CVE → BLOCK (exit 2)
#   3. 总 C+H = 0 → SHIP (exit 0)
#   4. C+H > 0 且 较上一轮无减少 → BLOCK (exit 2)
#   5. C+H > 0 且 有减少
#      - Critical = 0 → CAUTION (exit 0) [先检查 overridable 残留]
#      - Critical > 0 → HOLD (exit 1)
#   6. 无覆盖路径 → BLOCK (exit 2, 安全默认)

set -euo pipefail

INSTANCE_DIR="${1:-}"
PREV_C_PLUS_H="${2:-}"
ROUND_NUM="${3:-}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/compute-exit-verdict.sh <instance_dir> [prev_c_plus_h] [round_num]"
    printf '%s\n' "示例: bash scripts/compute-exit-verdict.sh .claude/cache/audit-context/audit-20260706-151714-7b41 3 2"
    exit 3  # H-7: USAGE_ERROR
fi

if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR"
    exit 4  # H-7: IO_ERROR
fi

# AP-14 fix: 退出裁决前强制检查所有 Medium 已处理（fix_attempted/requires_human/overridable）
# 防止编排者在 C+H=0 时直接产出报告而跳过 Medium 修复
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${INSTANCE_DIR}/checklist-round-1.json" ]; then
    if ! bash "${SCRIPT_DIR}/enforce-medium-handled.sh" "$INSTANCE_DIR"; then
        printf '%s\n' "❌ 退出裁决被阻止（AP-14）：请先处理上述 Medium 问题（修复或标记 requires_human），再重跑退出裁决" >&2
        exit 2
    fi
fi

echo "=== audit-loop 退出裁决 ==="
echo "实例目录: $INSTANCE_DIR"
echo ""

# 使用 Python 执行决策树（JSON 解析 + 规则匹配）
# 注意: set +e 避免 Python 的非零退出码（HOLD=1/BLOCK=2）被 set -e 中断
set +e
# H-2/Q-N1 fix: 改用 heredoc + os.environ 模式（与其他 4 个 check-pre 脚本统一），避免 python -c "..." 内双引号被 bash 干扰
export INSTANCE_DIR_ABS="$INSTANCE_DIR"
export PREV_C_PLUS_H
export ROUND_NUM
RESULT=$(python << 'PYEOF'
import json, os, sys

instance_dir = os.environ['INSTANCE_DIR_ABS']
# C-5 fix: heredoc 模式下 sys.argv 仅含 argv[0]，原 sys.argv[2]/[3] 恒空导致 Rule 0（3轮BLOCK）和 Rule 4（C+H无减少BLOCK）永不触发。改用 os.environ 读取（与上方 export PREV_C_PLUS_H/ROUND_NUM 对齐）
prev_c_plus_h_str = os.environ.get('PREV_C_PLUS_H', '')
round_str = os.environ.get('ROUND_NUM', '')

# 读取最新的 verification JSON（round-3 优先，否则 round-2）
verification = None
for fname in ['verification-round-3.json', 'verification-round-2.json']:
    path = os.path.join(instance_dir, fname)
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            verification = json.load(f)
            vfile = fname
            break

if verification is None:
    # 无 verification JSON，从 checklist 读取
    checklist_path = os.path.join(instance_dir, 'checklist-round-1.json')
    if os.path.exists(checklist_path):
        with open(checklist_path, 'r', encoding='utf-8') as f:
            checklist = json.load(f)
        issues = checklist.get('issues', [])
        c = sum(1 for i in issues if i.get('severity','').lower() == 'critical')
        h = sum(1 for i in issues if i.get('severity','').lower() == 'high')
        verification = {'_source': 'checklist', 'issues': issues}
        current_c = c
        current_h = h
        cvss_max = 0.0
        has_kev = False
        overridable_count = 0
    else:
        print('ERROR: 无 verification JSON 和 checklist JSON')
        sys.exit(2)
else:
    # 从 verification 提取
    # 阶段 B 终裁结果优先
    if 'adjudications' in verification:
        # 终裁后重算 C+H
        final_c = verification.get('final_c_count', None)
        final_h = verification.get('final_h_count', None)
        if final_c is not None and final_h is not None:
            current_c = final_c
            current_h = final_h
        else:
            # 从 adjudications 重新计数
            current_c = 0
            current_h = 0
            for adj in verification.get('adjudications', []):
                new_sev = adj.get('new_severity', '').lower()
                if new_sev == 'critical':
                    current_c += 1
                elif new_sev == 'high':
                    current_h += 1
            overridable_count = sum(1 for adj in verification.get('adjudications', []) if adj.get('overridable'))
    else:
        # 阶段 A 验证结果
        summary = verification.get('summary', {})
        current_c = summary.get('c_count', 0)
        current_h = summary.get('h_count', 0)
        # H-7 扩展: 兼容 c_count/h_count 为 dict 的格式 (含 total/resolved/persisting/ids)
        if isinstance(current_c, dict):
            current_c = current_c.get('persisting', current_c.get('total', 0))
        if isinstance(current_h, dict):
            current_h = current_h.get('persisting', current_h.get('total', 0))
        overridable_count = 0

    # 检查 CVSS ≥ 9.0 和 CISA KEV（从 verification 的 issues 或 blast_radius）
    cvss_max = 0.0
    has_kev = False

    # 从 verification_results 检查
    for vr in verification.get('verification_results', []):
        # persisting 的 issue 可能含 cvss
        pass

    # 从 blast_radius new_findings 检查
    blast = verification.get('blast_radius', {})
    for nf in blast.get('new_findings', []):
        cvss = nf.get('cvss_score', 0)
        if cvss > cvss_max:
            cvss_max = cvss
        if nf.get('cisa_kev'):
            has_kev = True

    # 从 adjudications 检查
    for adj in verification.get('adjudications', []):
        cvss = adj.get('cvss_score', 0)
        if cvss > cvss_max:
            cvss_max = cvss
        if adj.get('cisa_kev'):
            has_kev = True

# 从 checklist 读取所有 issues 检查 CVSS（兜底）
checklist_path = os.path.join(instance_dir, 'checklist-round-1.json')
# AP-14 fix: 统计 requires_human 的 Critical（防止含未修复 C 仍 SHIP）
requires_human_critical = 0
if os.path.exists(checklist_path):
    with open(checklist_path, 'r', encoding='utf-8') as f:
        checklist = json.load(f)
    # C-1 fix: 兼容 'findings' 和 'issues' 两种键名
    issues_list = checklist.get('issues', checklist.get('findings', []))
    for issue in issues_list:
        # 改进建议4: 软性发现（P-* 视角建议）不计入门控（避免视角建议阻塞技术 SHIP）
        if str(issue.get('id', '')).startswith('P-'):
            continue
        cvss = issue.get('cvss_score', 0)
        if isinstance(cvss, (int, float)) and cvss > cvss_max:
            cvss_max = cvss
        if issue.get('cisa_kev'):
            has_kev = True
        # 统计 requires_human 的 Critical
        if issue.get('status') == 'requires_human' and issue.get('severity', '').lower() == 'critical':
            requires_human_critical += 1

current_c_plus_h = current_c + current_h

# 解析上一轮 C+H
prev_c_plus_h = None
if prev_c_plus_h_str:
    try:
        prev_c_plus_h = int(prev_c_plus_h_str)
    except ValueError:
        pass

# 解析轮次 (H-5 fix)
round_num = None
if round_str:
    try:
        round_num = int(round_str)
    except ValueError:
        pass

# === 决策树（按优先级）===
verdict = None
exit_code = None
rule_triggered = None

# 规则 0 (H-5 fix): 3轮防护——已触发3轮且仍有 Critical/High → BLOCK 防无限循环
if round_num is not None and round_num >= 3 and current_c_plus_h > 0:
    verdict = 'BLOCK'
    exit_code = 2
    rule_triggered = 'round_limit_reached'

# 规则 1: CVSS ≥ 9.0
# H-6 fix: 使用 elif 防止覆盖 Rule 0 的 verdict/rule_triggered
elif cvss_max >= 9.0:
    verdict = 'BLOCK'
    exit_code = 2
    rule_triggered = f'规则1: CVSS {cvss_max} ≥ 9.0'

# 规则 2: CISA KEV
elif has_kev:
    verdict = 'BLOCK'
    exit_code = 2
    rule_triggered = '规则2: CISA KEV 在野利用 CVE'

# 规则 3: 总 C+H = 0
# AP-14 fix: 若存在 requires_human 的 Critical，CAUTION 而非 SHIP
elif current_c_plus_h == 0:
    if requires_human_critical > 0:
        verdict = 'CAUTION'
        exit_code = 0
        rule_triggered = '规则3-mod: 总 C+H = 0 但存在 requires_human Critical → CAUTION'
    else:
        verdict = 'SHIP'
        exit_code = 0
        rule_triggered = '规则3: 总 C+H = 0'

# 规则 4: C+H 较上一轮无减少
elif prev_c_plus_h is not None and current_c_plus_h >= prev_c_plus_h:
    verdict = 'BLOCK'
    exit_code = 2
    rule_triggered = f'规则4: C+H {current_c_plus_h} ≥ 上轮 {prev_c_plus_h}（修复无效）'

# 规则 5: C+H 有减少
elif prev_c_plus_h is not None and current_c_plus_h < prev_c_plus_h:
    if current_c == 0:
        # Critical = 0 → CAUTION（检查 overridable）
        if overridable_count > 0:
            verdict = 'CAUTION'
            exit_code = 0
            rule_triggered = f'规则5a: C+H 有减少, Critical=0, 但有 {overridable_count} overridable 残留（需修复后下一轮 HOLD）'
        else:
            verdict = 'CAUTION'
            exit_code = 0
            rule_triggered = '规则5a: C+H 有减少, Critical=0, 无 overridable 残留'
    else:
        verdict = 'HOLD'
        exit_code = 1
        rule_triggered = f'规则5b: C+H 有减少, 但 Critical={current_c} > 0'
else:
    # 无上一轮数据（首轮后）——用规则 5 逻辑
    if current_c == 0 and current_h > 0:
        if overridable_count > 0:
            verdict = 'CAUTION'
            exit_code = 0
            rule_triggered = f'首轮后: Critical=0, High={current_h}, 有 {overridable_count} overridable 残留'
        else:
            verdict = 'CAUTION'
            exit_code = 0
            rule_triggered = f'首轮后: Critical=0, High={current_h}, 无 overridable 残留'
    elif current_c > 0:
        verdict = 'HOLD'
        exit_code = 1
        rule_triggered = f'首轮后: Critical={current_c} > 0, 自动继续'
    else:
        # current_c_plus_h == 0 已在规则 3 处理，这里是兜底
        verdict = 'SHIP'
        exit_code = 0
        rule_triggered = '兜底: 无 C+H'

# 输出
print(f'当前 C+H: {current_c_plus_h} (C={current_c}, H={current_h})')
if prev_c_plus_h is not None:
    print(f'上一轮 C+H: {prev_c_plus_h}')
print(f'最高 CVSS: {cvss_max}')
print(f'CISA KEV: {"是" if has_kev else "否"}')
print(f'overridable 残留: {overridable_count}')
print(f'')
print(f'触发规则: {rule_triggered}')
print(f'门控裁决: {verdict}')
print(f'退出码: {exit_code}')
print(f'')

# 门控图标
icon = {'SHIP': '🟢', 'CAUTION': '🟡', 'HOLD': '🔵', 'BLOCK': '🔴'}[verdict]
print(f'最终状态: {icon} {verdict} (exit {exit_code})')

# 输出裁决 JSON 供编排者引用
verdict_json = {
    'verdict': verdict,
    'exit_code': exit_code,
    'rule_triggered': rule_triggered,
    'current_c': current_c,
    'current_h': current_h,
    'cvss_max': cvss_max,
    'has_kev': has_kev,
    'overridable_count': overridable_count,
    'prev_c_plus_h': prev_c_plus_h
}
verdict_path = os.path.join(instance_dir, 'exit-verdict.json')
with open(verdict_path, 'w', encoding='utf-8') as f:
    json.dump(verdict_json, f, ensure_ascii=False, indent=2)
print(f'裁决已写入: exit-verdict.json')

sys.exit(exit_code)
PYEOF
)

EXIT_CODE=$?
set -e
echo "$RESULT"
exit $EXIT_CODE
