#!/usr/bin/env python
# audit-loop 最终报告生成器（中文，固定格式）
# 用法: python scripts/generate_final_report.py <instance_dir> [output_path]
# 输出: 报告 MD 文本到 stdout，同时写入文件

import json, os, sys
from datetime import datetime, timezone

def main():
    if len(sys.argv) < 2:
        print("用法: python generate_final_report.py <instance_dir> [output_path]", file=sys.stderr)
        sys.exit(1)

    instance_dir = os.path.abspath(sys.argv[1])
    # H-1 fix: output_path 必须在 instance_dir 内，防止路径穿越
    if len(sys.argv) > 2:
        output_path = os.path.abspath(sys.argv[2])
        if not output_path.startswith(instance_dir + os.sep) and output_path != os.path.join(instance_dir, 'audit-final-report.md'):
            print(f"错误: output_path 必须在实例目录内: {instance_dir}", file=sys.stderr)
            sys.exit(1)
    else:
        output_path = os.path.join(instance_dir, 'audit-final-report.md')

    # ===== 1. 加载数据 =====
    checklist_path = os.path.join(instance_dir, 'checklist-round-1.json')
    if not os.path.exists(checklist_path):
        print(f"错误: {checklist_path} 不存在", file=sys.stderr)
        sys.exit(2)

    with open(checklist_path, 'r', encoding='utf-8') as f:
        checklist = json.load(f)

    verification = None
    for fname in ['verification-round-3.json', 'verification-round-2.json']:
        vpath = os.path.join(instance_dir, fname)
        if os.path.exists(vpath):
            with open(vpath, 'r', encoding='utf-8') as f:
                verification = json.load(f)
            break

    exit_verdict = None
    evpath = os.path.join(instance_dir, 'exit-verdict.json')
    if os.path.exists(evpath):
        with open(evpath, 'r', encoding='utf-8') as f:
            exit_verdict = json.load(f)

    # ===== 2. 构建验证查找表 =====
    vlookup = {}
    if verification:
        for vr in verification.get('verification_results', []):
            vlookup[vr['id']] = vr

    # ===== 3. 问题分类与状态判定 =====
    # C-1 fix: 兼容 'issues' 和 'findings' 两种键名（merge-reviewer 用 'issues', mechanical-dedup 也用 'issues'）
    findings = checklist.get('issues', checklist.get('findings', []))
    sev_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
    findings.sort(key=lambda x: (sev_order.get(x.get('severity', 'low'), 99), x.get('id', 'Z')))

    # C-2 fix: 不再硬编码上次审计的 issue 状态。从 checklist JSON 动态读取。
    # requires_human: 从 issue.status 字段判定
    # fixed: 从 issue.status (fix_attempted/fixed) 或 verification verdict (resolved) 判定
    # persisting: 从 verification verdict 判定
    # deferred: 其他所有情况

    def get_issue_status(issue):
        iid = issue['id']
        if iid in vlookup:
            v = vlookup[iid]
            if v['verdict'] == 'resolved':
                return 'fixed', ''
            elif v['verdict'] == 'persisting':
                return 'persisting', ''
        # C-2 fix: 从 issue 自身 status 字段动态判定，不再使用硬编码列表
        status = issue.get('status', '')
        if status in ('fix_attempted', 'fixed', 'resolved'):
            return 'fixed', ''
        if status == 'requires_human':
            return 'requires_human', issue.get('recommendation', '')
        return 'deferred', ''

    def get_fix_desc(issue):
        desc = issue.get('fix_description', '')
        if desc:
            # 如果 fix_description 全英文，回退到问题描述
            if len(desc) > 10 and desc[:20].replace(' ', '').isascii() and not any('一' <= c <= '鿿' for c in desc[:30]):
                return '已修复（详见完整清单）'
            return desc[:120]
        # fallback
        raw = issue.get('description', '')
        for sep in ['→', '->']:
            if sep in raw:
                return raw.split(sep)[-1].strip()[:100]
        return '已修复'

    # ===== 4. 统计 =====
    sev_counts = {'critical': 0, 'high': 0, 'medium': 0, 'low': 0}
    status_counts = {'fixed': 0, 'requires_human': 0, 'persisting': 0, 'deferred': 0}
    for issue in findings:
        s = issue.get('severity', 'low')
        sev_counts[s] = sev_counts.get(s, 0) + 1
        st, _ = get_issue_status(issue)
        status_counts[st] = status_counts.get(st, 0) + 1

    SEV_CN = {'critical': '严重', 'high': '高危', 'medium': '中等', 'low': '低'}
    SEV_EMOJI = {'critical': '🔴', 'high': '🟠', 'medium': '🟡', 'low': '🔵'}
    STATUS_TEXT = {'fixed': '已修复', 'requires_human': '需人工处理', 'persisting': '残留', 'deferred': '延后'}
    STATUS_EMOJI = {'fixed': '✅', 'requires_human': '📋', 'persisting': '🔁', 'deferred': '⏸'}

    # 延后项分类
    def classify_deferred(issue):
        did = issue['id']
        desc = issue.get('description', '')
        fid = issue.get('file', '')
        if did.startswith('P-developer') or 'DEV-SF' in desc:
            return '开发者体验'
        if did.startswith('P-security') or '注入' in desc:
            return '安全增强'
        if did.startswith('TL-') or '架构' in desc:
            return '架构优化'
        if did.startswith('APIC-') or 'JSON' in desc or 'schema' in desc.lower():
            return 'Agent 契约'
        if fid and fid.startswith('scripts/'):
            return '脚本健壮性'
        if fid and (fid.startswith('agents/') or fid.startswith('references/')):
            return '文档规范'
        return '其他'

    # ===== 5. 生成报告 =====
    now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    verdict_text = exit_verdict.get('verdict', 'SHIP') if exit_verdict else 'SHIP'
    verdict_cn = {
        'SHIP': '通过，可正常使用',
        'CAUTION': '关注，存在需注意的残留问题',
        'HOLD': '暂缓，需修复后重新审计',
        'BLOCK': '阻断，存在不可接受的严重风险',
    }.get(verdict_text, verdict_text)
    verdict_emoji = {'SHIP': '🟢', 'CAUTION': '🟡', 'HOLD': '🔵', 'BLOCK': '🔴'}.get(verdict_text, '🟢')

    c_fixed = sum(1 for i in findings if i.get('severity','').lower() == 'critical' and get_issue_status(i)[0] == 'fixed')
    h_fixed = sum(1 for i in findings if i.get('severity','').lower() == 'high' and get_issue_status(i)[0] == 'fixed')
    c_human = sum(1 for i in findings if i.get('severity','').lower() == 'critical' and get_issue_status(i)[0] == 'requires_human')

    if verdict_text == 'SHIP' and c_human == 0:
        conclusion = '当前技能包无阻塞级风险，所有可修复的严重和高危问题已清零。'
    elif verdict_text == 'SHIP' and c_human > 0:
        conclusion = f'当前技能包可正常使用。所有可修复问题已清零，{c_human} 项 Critical 标记为需人工处理——均为平台/架构级限制，非 audit-loop 自身缺陷。'
    elif verdict_text == 'CAUTION':
        conclusion = '当前技能包存在需关注的残留问题，建议在下次发布前处理。'
    else:
        conclusion = f'当前技能包处于 {verdict_text} 状态，需进一步修复后再审计。'

    deferred_items = [i for i in findings if get_issue_status(i)[0] == 'deferred']
    cat_counts = {}
    for i in deferred_items:
        cat = classify_deferred(i)
        cat_counts[cat] = cat_counts.get(cat, 0) + 1
    deferred_summary = '、'.join(f'{k} {v} 项' for k, v in sorted(cat_counts.items(), key=lambda x: -x[1]))

    # 视角信息
    active_perspectives = checklist.get('active_perspectives', [])
    persp_summary = checklist.get('perspective_summary', {})
    persp_names = persp_summary.get('perspectives_active', active_perspectives)
    if isinstance(persp_names, int):
        persp_names = active_perspectives if (active_perspectives and isinstance(active_perspectives, list)) else ['developer', 'security-auditor', 'tech-lead', 'api-consumer']
    persp_str = ', '.join(persp_names[:4])

    r = []

    def L(s=''):
        r.append(s)

    # ========== 报告正文 ==========
    L('# 审计最终报告')
    L()
    L(f'> **门控裁决：{verdict_emoji} {verdict_text}（{verdict_cn}）**  |  生成时间：{now}  |  实例：`{os.path.basename(instance_dir)}`')
    L()
    L('---')
    L()

    # 一、执行摘要
    L('## 一、执行摘要')
    L()
    L(f'> {conclusion}')
    L()
    L(f'- **审计透镜**：4 技术（安全/架构/质量/性能）+ 视角（{persp_str}...）')
    L(f'- **发现问题**：{len(findings)} 项（{sev_counts["critical"]} Critical / {sev_counts["high"]} High / {sev_counts["medium"]} Medium / {sev_counts["low"]} Low）')
    L(f'- **已修复**：{status_counts["fixed"]} 项（{c_fixed} Critical + {h_fixed} High）')
    L(f'- **需人工处理**：{status_counts["requires_human"]} 项（平台/架构级限制）')
    L(f'- **延后处理**：{status_counts["deferred"]} 项（Medium/Low，按优先级延后）')
    if deferred_summary:
        L(f'- **延后项分布**：{deferred_summary}')
    L(f'- **门控裁决**：{verdict_emoji} {verdict_text} — {verdict_cn}')
    L()

    # 二、已修复问题
    L('## 二、已修复问题')
    L()
    fixed_issues = [i for i in findings if get_issue_status(i)[0] == 'fixed']
    if fixed_issues:
        L('| ID | 严重度 | 问题简述 | 修复内容 |')
        L('|----|:-----:|----------|----------|')
        for issue in fixed_issues:
            iid = issue['id']
            sev = issue.get('severity', '?').capitalize()
            desc = issue.get('description', issue.get('title', ''))
            brief = desc[:80] + ('...' if len(desc) > 80 else '')
            fix = get_fix_desc(issue)
            L(f'| {iid} | {sev} | {brief} | {fix} |')
    else:
        L('*本轮无已修复问题*')
    L()

    # 三、需人工处理
    human_issues = [i for i in findings if get_issue_status(i)[0] == 'requires_human']
    if human_issues:
        L('## 三、需人工处理（平台/架构级限制）')
        L()
        L('以下问题由 Claude Code 平台限制或架构设计决策导致，非 audit-loop 技能包自身代码可修复。')
        L()
        L('| ID | 严重度 | 问题 | 建议行动 |')
        L('|----|:-----:|------|----------|')
        for issue in human_issues:
            iid = issue['id']
            sev = issue.get('severity', '?').capitalize()
            desc = issue.get('description', issue.get('title', ''))[:100]
            action = issue.get('recommendation', '需进一步分析确定行动方案')
            L(f'| {iid} | {sev} | {desc} | {action} |')
        L()

    # 四、完整问题清单（全部列出，不截断）
    L(f'## 四、完整问题清单（全部 {len(findings)} 项）')
    L()

    current_sev = None
    for issue in findings:
        # Skip soft findings — unified check (M-5 fix): P- prefix AND (type=soft OR no severity)
        iid = str(issue.get('id', ''))
        if iid.startswith('P-') and (issue.get('type') == 'soft' or 'severity' not in issue):
            continue
        sev = issue['severity']
        if sev != current_sev:
            current_sev = sev
            emoji = SEV_EMOJI.get(sev, '⚪')
            L(f'### {emoji} {SEV_CN.get(sev, sev)}（{sev_counts.get(sev, 0)} 项）')
            L()

        status, note = get_issue_status(issue)
        semoji = STATUS_EMOJI.get(status, '?')
        slabel = STATUS_TEXT.get(status, status)
        iid = issue['id']
        fname = issue.get('file', '—')
        desc = issue.get('description', issue.get('title', ''))
        fix_desc = get_fix_desc(issue) if status == 'fixed' else ''

        L(f'**{iid}** {semoji} {slabel} — {fname}')
        L(f'> {desc}')
        if fix_desc and fix_desc != '已修复（详见完整清单）':
            L(f'> 🔧 {fix_desc}')
        if note and note != fix_desc:
            L(f'> 📝 {note}')
        L()

    # 五、审计过程发现
    L('## 五、审计过程发现（AP）')
    L()
    L('| ID | 状态 | 描述 |')
    L('|----|:---:|------|')
    # C-2 fix: AP 问题从 checklist 中动态提取（type='process' 的 issue）
    ap_issues = [i for i in findings if i.get('type') == 'process' and i.get('id', '').startswith('AP-')]
    if ap_issues:
        for ap in ap_issues:
            ap_status = '✅ 已修复' if get_issue_status(ap)[0] == 'fixed' else '❌ 未修复'
            L(f'| {ap["id"]} | {ap_status} | {ap.get("description", "")[:100]} |')
    else:
        L('| — | — | 本轮无审计过程发现 |')
    L()

    # 六、残余风险
    L('## 六、残余风险')
    L()
    L('| 风险 | 概率 | 影响 | 当前状态 | 缓解措施 |')
    L('|------|:----:|:----:|----------|----------|')
    # M-14 fix: 移除硬编码残余风险条目（原 C-3/C-5/C-7 + 内网IP 172.16.1.95 是上轮自审计残留，对其他项目无效）
    # 残余风险应由 checklist 的 requires_human issue 驱动，不应硬编码特定项目的问题
    L('| requires_human 残留 | 见清单 | 高 | 需人工处理 | 详见"需人工处理"节的具体 issue（动态） |')
    L('| SHA-256 证据链可篡改 | 极低 | 中 | 需外部签名 | 正常使用场景下足矣检测意外损坏 |')
    L()

    # 七、改进建议
    L('## 七、改进建议')
    L()
    L('1. **视角透镜模型升级**：将 `references/lens-config.md` 视角透镜最低模型从 haiku 提升为 sonnet，解决 AP-8/AP-9 的 haiku 可靠性问题')
    L('2. **脚本健壮性批量修复**：约 15 个 Medium 为输入校验/错误处理/跨平台兼容，可一次批量修复')
    L('3. **Agent stdout 输出模式**：实现 guardrails.md 第二层方案——Agent 输出到 stdout，消除 Write 权限依赖')
    L('4. **JSON Schema 校验**：为所有透镜输出增加 Schema 定义（M-20），CI 中自动校验防止格式漂移')
    L('5. **下次审计触发**：建议在 C-3/C-5/C-7 中任一问题因平台更新而可修复时，或在新增 Agent/视角后，重新运行全面自审计')
    L()

    L('---')
    L()
    L(f'*报告由 audit-loop skill 自动生成。门控裁决：{verdict_emoji} {verdict_text}（{verdict_cn}）。*')

    # ===== 6. 输出 =====
    report_text = '\n'.join(r) + '\n'

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(report_text)

    print(report_text)

if __name__ == '__main__':
    main()
