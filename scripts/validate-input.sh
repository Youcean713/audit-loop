#!/usr/bin/env bash
# audit-loop 输入安全校验脚本
# 用法: bash scripts/validate-input.sh "<审计范围>"
# 退出码: 0 = 通过, 1 = 含不安全字符(拒绝)

set -euo pipefail

INPUT="${1:-}"
if [ -z "$INPUT" ]; then
    printf '%s\n' "用法: bash scripts/validate-input.sh <审计范围>"
    exit 1
fi

# === Layer 1: NFKC 标准化（H-4 fix: python -c "..." → heredoc + os.environ）===
normalized=$(INPUT_VAL="$INPUT" python << 'PYEOF' 2>/dev/null
import unicodedata, os
s = os.environ['INPUT_VAL']
s = unicodedata.normalize('NFKC', s)
print(s)
PYEOF
) || {
    printf '%s\n' "FAIL: NFKC 标准化失败（Python 不可用）"
    exit 1
}

# === Layer 2: 剥离换行符（含 Windows \r\n）===
# H-4 fix: 同时剥离 \n 和 \r——Windows 环境下换行为 \r\n，仅剥离 \n 残留 \r
normalized=$(printf '%s' "$normalized" | tr -d '\n\r')

# === Layer 3: URL 剥离 ===
# 使用不含特殊字符的替换文本（原 [URL REDACTED] 含方括号不通过 Layer 5 白名单——M-7 修复）
normalized=$(printf '%s' "$normalized" | sed -E 's|https?://[^ ]+|URL-REMOVED|g')

# === Layer 4: 反引号替换 ===
normalized=$(printf '%s' "$normalized" | tr '`' "'")

# === Layer 5: 白名单正则 ===
# C-7 fix: 原白名单 ^[a-zA-Z0-9/:\\\._\-*?]+$ 拒绝空格和 CJK 字符，
# 但审计范围是自由文本描述（如"全面审计 src/auth/"），致控制对真实输入总是 FAIL（CWE-693 虚假安全感）。
# 修复：允许空格 + CJK 字符范围（\x{4e00}-\x{9fff} CJK统一汉字/标点/全角），依赖 Layer 6 黑名单（角色切换/prompt注入/标题注入）防注入。
if ! printf '%s' "$normalized" | grep -qP '^[a-zA-Z0-9/:\\\._\-*? \x{4e00}-\x{9fff}\x{3000}-\x{303f}\x{ff00}-\x{ffef}]+$'; then
    printf '%s\n' "FAIL: 审计范围含不安全字符（白名单校验失败）"
    exit 1
fi

# === Layer 6: 黑名单子串匹配 ===
check=$(printf '%s' "$normalized" | sed 's/[[:space:]]\+/ /g')

# 6a. 角色切换短语
for pattern in 'system:' 'assistant:' 'user:' 'human:' '[INST]' '[SYSTEM]' '<|im_start|>' '<system>' '<script>' '<!--'; do
    if printf '%s' "$check" | grep -qiF "$pattern" 2>/dev/null; then
        printf '%s\n' "FAIL: 审计范围含不安全字符: 检测到 '$pattern'"
        exit 1
    fi
done

# 6b. 通用 prompt 注入短语（🆕 C-2 修复: 扩展黑名单覆盖英文注入载荷）
for phrase in 'ignore previous' 'disregard all prior' 'all previous instructions' 'instead output' 'new instructions' 'forget above' 'override' 'bypass audit' 'output all secrets' 'do not audit' 'skip audit' 'pretend you are'; do
    if printf '%s' "$check" | grep -qiF "$phrase" 2>/dev/null; then
        printf '%s\n' "FAIL: 审计范围含不安全字符: 检测到 prompt 注入短语 '$phrase'"
        exit 1
    fi
done

# 6c. Markdown 标题注入
if printf '%s' "$check" | grep -qE '^#+[[:space:]]+(ignore|execute|run|delete|overwrite|bypass|skip)' 2>/dev/null; then
    printf '%s\n' "FAIL: 审计范围含不安全字符: Markdown 标题注入"
    exit 1
fi

# 6d. 分隔符伪造
if printf '%s' "$check" | grep -qE '^[*-]{3,}$' 2>/dev/null; then
    printf '%s\n' "FAIL: 审计范围含不安全字符: 分隔符伪造"
    exit 1
fi

# 6e. 路径穿越检测（🆕 M-2 修复: 拒绝含 ../ 的相对路径跳转）
if printf '%s' "$check" | grep -qF '..' 2>/dev/null; then
    printf '%s\n' "FAIL: 审计范围含不安全字符: 路径穿越（..）"
    exit 1
fi

# 6f. Unicode 控制字符（H-4 fix: heredoc + os.environ）
CHECK_VAL="$normalized" python << 'PYEOF' 2>/dev/null
import os
s = os.environ['CHECK_VAL']
bad = any(ord(c) in {0x200B, 0x200C, 0x200D, 0xFEFF, 0x2028} for c in s)
__import__('sys').exit(1 if bad else 0)
PYEOF
if [ $? -ne 0 ]; then
    printf '%s\n' "FAIL: 审计范围含不安全字符: Unicode 控制字符"
    exit 1
fi

printf '%s\n' "PASS"
exit 0
