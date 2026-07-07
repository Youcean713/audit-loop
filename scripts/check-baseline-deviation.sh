#!/usr/bin/env bash
# audit-loop 基线偏离检查脚本
# 用途: 比较当前审计轮次与历史基线 → 触发 4 类告警
# 用法: bash scripts/check-baseline-deviation.sh <instance_dir> <trend_json_path>
# 告警规则:
#   1. C+H 连续 2 轮增加 → 代码质量恶化
#   2. 修复成功率 < 70% → 自动修复能力下降
#   3. 新增回归率 > 10% → 修复引入新问题
#   4. 审计耗时超过基线 2× → 性能退化
# 退出码: 0 = 无告警, 1 = 有告警, 2 = 脚本错误

set -euo pipefail

INSTANCE_DIR="${1:-}"
TREND_JSON="${2:-}"

if [ -z "$INSTANCE_DIR" ] || [ -z "$TREND_JSON" ]; then
    printf '%s\n' "用法: bash scripts/check-baseline-deviation.sh <instance_dir> <trend_json_path>"
    exit 1
fi

echo "=== audit-loop 基线偏离检查 ==="
echo ""

set +e
python -c "
import json, os, sys

instance_dir = sys.argv[1]
trend_path = sys.argv[2]

# 读取当前趋势
if not os.path.exists(trend_path):
    print('⚠️  趋势文件不存在，无历史基线可比较')
    sys.exit(0)

with open(trend_path, 'r', encoding='utf-8') as f:
    trend_history = json.load(f)

# trend_history 可能是列表（多次审计）或单次记录
if isinstance(trend_history, dict):
    history = [trend_history]
elif isinstance(trend_history, list):
    history = trend_history
else:
    print('⚠️  趋势文件格式异常')
    sys.exit(2)

if len(history) < 2:
    print(f'历史记录不足（{len(history)} 条），至少需要 2 条才能比较基线')
    sys.exit(0)

# 当前轮次 = 最后一条
current = history[-1]
# 上一轮 = 倒数第二条
previous = history[-2]

alerts = []

# 规则 1: C+H 连续 2 轮增加
curr_ch = current.get('c_count', 0) + current.get('h_count', 0)
prev_ch = previous.get('c_count', 0) + previous.get('h_count', 0)
if len(history) >= 3:
    prev_prev_ch = history[-3].get('c_count', 0) + history[-3].get('h_count', 0)
    if curr_ch > prev_ch > prev_prev_ch:
        alerts.append({
            'rule': 'C+H 连续 2 轮增加',
            'severity': 'high',
            'detail': f'C+H: {prev_prev_ch} → {prev_ch} → {curr_ch}',
            'recommendation': '代码质量恶化，需审查最近变更'
        })
elif curr_ch > prev_ch:
    alerts.append({
        'rule': 'C+H 较上轮增加',
        'severity': 'medium',
        'detail': f'C+H: {prev_ch} → {curr_ch}',
        'recommendation': '关注代码质量趋势'
    })

# 规则 2: 修复成功率 < 70%
curr_fix_rate = current.get('fix_success_rate')
if curr_fix_rate is not None and curr_fix_rate < 70:
    alerts.append({
        'rule': '修复成功率 < 70%',
        'severity': 'medium',
        'detail': f'当前修复成功率: {curr_fix_rate}%',
        'recommendation': '自动修复能力下降，需检查修复逻辑'
    })

# 规则 3: 新增回归率 > 10%
curr_regression = current.get('regression_rate', 0)
if curr_regression > 10:
    alerts.append({
        'rule': '新增回归率 > 10%',
        'severity': 'high',
        'detail': f'回归率: {curr_regression}%',
        'recommendation': '修复引入新问题，需加强 Blast-Radius 扫描'
    })

# 规则 4: 审计耗时超过基线 2×
curr_time = current.get('total_time_seconds', 0)
prev_time = previous.get('total_time_seconds', 0)
if prev_time > 0 and curr_time > prev_time * 2:
    alerts.append({
        'rule': '审计耗时超过基线 2×',
        'severity': 'medium',
        'detail': f'耗时: {prev_time}s → {curr_time}s ({curr_time/prev_time:.1f}×)',
        'recommendation': '性能退化，需检查 Agent spawn 数和 Token 消耗'
    })

# 输出
if alerts:
    print(f'🔴 触发 {len(alerts)} 条基线偏离告警:')
    print('')
    for a in alerts:
        icon = '🔴' if a['severity'] == 'high' else '🟡'
        print(f'{icon} {a[\"rule\"]}')
        print(f'   详情: {a[\"detail\"]}')
        print(f'   建议: {a[\"recommendation\"]}')
        print('')

    # 写入告警文件
    alert_path = os.path.join(instance_dir, 'baseline-alerts.json')
    with open(alert_path, 'w', encoding='utf-8') as f:
        json.dump({'alerts': alerts, 'current_trend': current}, f, ensure_ascii=False, indent=2)
    print(f'告警已写入: baseline-alerts.json')
    sys.exit(1)
else:
    print('✅ 无基线偏离告警')
    print(f'  当前 C+H: {curr_ch}, 修复成功率: {curr_fix_rate}%, 回归率: {curr_regression}%')
    sys.exit(0)
" "$INSTANCE_DIR" "$TREND_JSON"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
