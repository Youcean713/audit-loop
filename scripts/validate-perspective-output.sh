#!/usr/bin/env bash
# audit-loop 视角推荐输出安全验证脚本（C-4 二阶注入防御）
# 用途: 验证 perspective-recommender 的输出（perspective_id/focus_areas/rationale）不含注入载荷
# 用法: bash scripts/validate-perspective-output.sh <perspective_json_path>
# 退出码: 0 = 通过, 1 = 含注入载荷(拒绝该视角), 2 = 脚本错误

set -euo pipefail

JSON_PATH="${1:-}"

if [ -z "$JSON_PATH" ]; then
    printf '%s\n' "用法: bash scripts/validate-perspective-output.sh <perspective_json_path>"
    exit 2
fi

if [ ! -f "$JSON_PATH" ]; then
    printf '%s\n' "错误: 文件不存在: $JSON_PATH"
    exit 2
fi

echo "=== 视角输出安全验证 (C-4) ==="
echo "文件: $JSON_PATH"
echo ""

set +e
python -c "
import json, sys, re, unicodedata

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)

failures = []

# 角色切换短语
role_switch = ['system:', 'assistant:', 'user:', 'human:', '[INST]', '[SYSTEM]', '<|im_start|>', '<system>', '<script>', '<!--']
# 通用 prompt 注入短语
injection_phrases = ['ignore previous', 'disregard all prior', 'all previous instructions', 'instead output', 'new instructions', 'forget above', 'override', 'bypass', 'output all secrets', 'pretend you are', 'do not audit', 'skip audit']

def check_string(value, field_name, allow_chinese=False):
    \"\"\"检查单个字符串字段\"\"\"
    if not isinstance(value, str):
        return
    # NFKC 标准化
    normalized = unicodedata.normalize('NFKC', value)
    lower = normalized.lower()

    # 黑名单: 角色切换
    for pattern in role_switch:
        if pattern.lower() in lower:
            failures.append(f'{field_name}: 检测到角色切换短语 \"{pattern}\"')
            return
    # 黑名单: 注入短语
    for phrase in injection_phrases:
        if phrase in lower:
            failures.append(f'{field_name}: 检测到注入短语 \"{phrase}\"')
            return
    # 反引号
    if '\`' in normalized:
        failures.append(f'{field_name}: 含反引号')
        return
    # HTML 标签
    if re.search(r'<[a-zA-Z/][^>]*>', normalized):
        failures.append(f'{field_name}: 含 HTML 标签')
        return
    # markdown 代码块
    if '\`\`\`' in normalized:
        failures.append(f'{field_name}: 含 markdown 代码块')
        return

def check_perspective_id(pid):
    \"\"\"perspective_id 额外检查: 仅 [a-z0-9_-]+ 且路径安全\"\"\"
    if not isinstance(pid, str):
        failures.append('perspective_id: 非字符串')
        return
    if not re.match(r'^[a-z0-9_-]+$', pid):
        failures.append(f'perspective_id: 格式不合法 (仅允许 [a-z0-9_-])，实际: \"{pid}\"')
        return
    # 路径穿越
    if '..' in pid or '/' in pid or '\\\\' in pid:
        failures.append(f'perspective_id: 含路径穿越字符: \"{pid}\"')

# 🛡️ Fail-closed (C-4 fix): 结构验证——JSON 必须含 recommended_perspectives 非空数组
# 若 perspective-recommender 被注入返回非标准结构，必须拒绝而非静默通过
if 'recommended_perspectives' not in data:
    print('❌ 拒绝: JSON 缺少 recommended_perspectives 字段（可能为注入篡改或结构异常）')
    sys.exit(1)

perspectives = data['recommended_perspectives']

if not isinstance(perspectives, list):
    print(f'❌ 拒绝: recommended_perspectives 应为数组，实际为 {type(perspectives).__name__}')
    sys.exit(1)

if len(perspectives) == 0:
    print('❌ 拒绝: recommended_perspectives 为空数组（perspective-recommender 可能被注入操纵或返回异常结构）')
    sys.exit(1)

# 额外结构检查: 验证预期顶层字段存在 (C-4 fail-closed)
required_top_fields = ['project_type', 'detected_signals', 'recommended_perspectives']
missing_fields = [field for field in required_top_fields if field not in data]
if missing_fields:
    print(f'❌ 拒绝: 顶层字段缺失: {missing_fields}')
    sys.exit(1)

print(f'检查 {len(perspectives)} 个推荐视角')

for i, p in enumerate(perspectives):
    pid = p.get('id', '')
    name = p.get('name', '')
    rationale = p.get('rationale', '')
    focus_areas = p.get('focus_areas', [])

    print(f'  [{i+1}] {pid}: ', end='')

    # perspective_id 严格检查
    check_perspective_id(pid)

    # name 检查（允许中文）
    check_string(name, f'{pid}.name', allow_chinese=True)

    # rationale 检查（允许中文描述）
    check_string(rationale, f'{pid}.rationale', allow_chinese=True)

    # focus_areas 各项检查
    for j, fa in enumerate(focus_areas):
        check_string(fa, f'{pid}.focus_areas[{j}]', allow_chinese=True)

    if not failures:
        print('✅ 通过')
    else:
        print('❌ 拒绝')

# 输出结果
print()
if failures:
    print(f'❌ 验证失败: {len(failures)} 项问题')
    for f_msg in failures:
        print(f'  - {f_msg}')
    sys.exit(1)
else:
    print('✅ 全部视角输出通过安全验证')
    sys.exit(0)
" "$JSON_PATH"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
