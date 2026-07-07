# 企业标准映射表

> 本文件由 lens-config.md 的透镜 prompt 引用。Agent 审计时按此表将发现映射到国际标准。
> 基于 2025-2026 行业标准：OWASP ASVS 5.0、NIST SSDF SP 800-218、CVSS 4.0、CWE、ISO 27001:2022、SLSA v1.0。

---

## 使用说明

Agent 发现 issue 时，按以下步骤映射：
1. 从审计清单项找到对应的检查项
2. 从下表获取 `cwe_id` 和 `asvs_ref`（安全项）/ `nist_ssdf`（架构项）/ `iso_25010`（质量项）
3. 从 CVSS 模板表选择合适的向量模板，调整具体参数
4. 将标准字段填入 issue JSON 输出

---

## 一、安全审计清单 → 标准映射

| 审计清单项 | CWE | OWASP ASVS v5.0.0 | CVSS 4.0 模板 | NIST SSDF |
|-----------|-----|-------------------|---------------|-----------|
| SQL 注入 | CWE-89 | v5.0.0-2.1.3 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H | PW.2 |
| XSS / 跨站脚本 | CWE-79 | v5.0.0-1.4.1 | AV:N/AC:L/AT:N/PR:N/UI:R/VC:H/VI:H/VA:N | PW.2 |
| 命令注入 | CWE-78 | v5.0.0-2.1.4 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H | PW.2 |
| 路径遍历 | CWE-22 | v5.0.0-5.1.3 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:N/VA:N | PW.2 |
| 失效认证 | CWE-287 | v5.0.0-6.1.1 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:N | PW.2 |
| 会话固定 | CWE-384 | v5.0.0-7.1.1 | AV:N/AC:H/AT:N/PR:N/UI:R/VC:H/VI:H/VA:N | PW.2 |
| JWT 弱签名 | CWE-347 | v5.0.0-9.1.1 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:N | PW.2 |
| CSRF | CWE-352 | v5.0.0-6.3.1 | AV:N/AC:L/AT:N/PR:N/UI:R/VC:H/VI:H/VA:N | PW.2 |
| OAuth 配置错误 | CWE-285 | v5.0.0-10.2.1 | AV:N/AC:L/AT:N/PR:N/UI:R/VC:H/VI:H/VA:N | PW.2 |
| 硬编码密钥/密码 | CWE-798 | v5.0.0-11.1.3 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H | PW.2 |
| 弱哈希 (MD5/SHA1) | CWE-328 | v5.0.0-11.1.2 | AV:N/AC:H/AT:N/PR:N/UI:N/VC:H/VI:N/VA:N | PW.2 |
| 明文传输 | CWE-319 | v5.0.0-12.1.1 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:N/VA:N | PW.2 |
| 不安全随机数 | CWE-338 | v5.0.0-11.1.1 | AV:N/AC:H/AT:N/PR:N/UI:N/VC:H/VI:H/VA:N | PW.2 |
| 日志泄露敏感数据 | CWE-532 | v5.0.0-16.1.2 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:N/VA:N | PW.2 |
| 错误信息泄露 | CWE-209 | v5.0.0-16.2.1 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:L/VI:N/VA:N | PW.2 |
| 失效访问控制 | CWE-862 | v5.0.0-8.1.1 | AV:N/AC:L/AT:N/PR:L/UI:N/VC:H/VI:H/VA:H | PW.2 |
| 安全配置错误 | CWE-16 | v5.0.0-13.1.1 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H | PW.2 |
| 不安全反序列化 | CWE-502 | v5.0.0-2.1.5 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H | PW.2 |
| 已知漏洞组件 | CWE-1104 | v5.0.0-13.2.1 | — (component-specific) | PW.3 |
| XXE | CWE-611 | v5.0.0-5.1.2 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:N/VA:N | PW.2 |
| 日志不足 | CWE-778 | v5.0.0-16.1.1 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:N | PW.2 |
| 依赖已知 CVE | CWE-937 | v5.0.0-13.2.1 | — (CVE-specific) | PW.3 |
| GDPR 数据隐私 | — | v5.0.0-14.1.1 | — | PO.1 |
| PCI-DSS 支付加密 | — | v5.0.0-14.2.1 | — | PO.1 |
| SOC2 审计日志 | — | v5.0.0-16.1.1 | — | PO.1 |
| Prompt 注入（AI 特化） | CWE-77 | v5.0.0-2.1.6 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:N | PW.2 |
| Agent 工具权限越界 | CWE-269 | v5.0.0-8.1.2 | AV:L/AC:L/AT:N/PR:L/UI:N/VC:H/VI:H/VA:H | PW.2 |
| DNS 数据外泄 | CWE-200 | v5.0.0-12.2.1 | AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:N/VA:N | PW.2 |

---

## 二、架构审计清单 → 标准映射

| 审计清单项 | NIST SSDF | ISO 27001:2022 | SLSA |
|-----------|-----------|----------------|------|
| 文件分层不合理 | PW.1 | A.8.28 | — |
| Progressive Disclosure 失败 | PW.1 | A.8.28 | — |
| 紧耦合 / 循环依赖 | PW.1 | A.8.29 | — |
| 可扩展性差 | PW.1 | A.8.29 | — |
| 多轮信息流不自洽 | PW.1 | A.8.28 | — |
| 状态转换遗漏 | PW.1 | A.8.29 | — |
| 目录结构违规 | — | A.8.28 | — |
| Frontmatter/Description 不合规 | — | — | — |
| 占位符不统一 | PW.4 | A.8.29 | Build L2 |
| 数量声称与代码不匹配（实现忠实度） | PW.2 | A.8.28 | — |
| 审计范围约束缺失 | PW.2 | A.8.29 | — |
| Sub-agent 指令不完整 | PW.4 | A.8.29 | Build L2 |

---

## 三、质量审计清单 → 标准映射

| 审计清单项 | ISO 25010 | NIST SSDF |
|-----------|-----------|-----------|
| 指令不清晰/歧义 | Maintainability | PW.2 |
| 边界条件未定义 | Reliability | PW.2 |
| 正常流/异常流未覆盖 | Functional Suitability | PW.2 |
| 文件间引用不一致 | Maintainability | PW.2 |
| 占位符不匹配 | Compatibility | PW.4 |
| 命名不统一 | Maintainability | PW.2 |
| 降级策略缺失 | Reliability | PW.2 |
| Evals 覆盖不全 | Functional Suitability | PW.5 |
| 文件句柄泄露 | Performance Efficiency | PW.2 |
| 日志不可追溯 | Usability | PW.2 |
| 两阶段工作流被跳过 | Maintainability | PW.2 |
| 证据不足（无文件引用断言） | Maintainability | PW.2 |
| 建议不可操作 | Usability | PW.2 |
| 优先级不合理 | Functional Suitability | PW.2 |
| Sub-agent 歧义处理错误 | Reliability | PW.2 |
| 输出语言不一致 | Usability | PW.2 |

---

## 四、性能审计清单 → 标准映射

| 审计清单项 | ISO 25010 | NIST SSDF |
|-----------|-----------|-----------|
| 冗余内容/重复文本 | Performance Efficiency | PW.4 |
| Lazy-load 缺失 | Performance Efficiency | — |
| Description 过长 | Performance Efficiency | — |
| Token 阈值无依据 | Performance Efficiency | — |
| Agent spawn 过多 | Performance Efficiency | PW.4 |
| 缓存利用不足 | Performance Efficiency | PW.4 |
| Token 效率准则被违反 | Performance Efficiency | PW.2 |
| 不必要的文件读取 | Performance Efficiency | PW.2 |

---

## 五、Agent 行为合规 → 标准映射

| 行为准则 | CWE | OWASP ASVS | NIST SSDF |
|---------|-----|-----------|-----------|
| Guideline #6 只读约束违反 | CWE-269 | v5.0.0-8.1.2 | PW.4 |
| Guideline #10 网络安全违反 | CWE-200 | v5.0.0-12.2.1 | PW.4 |
| Guideline #5 范围越界 | CWE-862 | v5.0.0-8.1.1 | PW.2 |
| Guideline #9 Token 效率违反 | — | — | PW.4 |

---

## 六、CVSS 4.0 向量模板速查

| 场景 | CVSS 4.0 向量 | 基础分 |
|------|-------------|--------|
| 远程可利用 + 高影响 (Critical) | CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N | 9.8 |
| 远程可利用 + 需用户交互 (High) | CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:R/VC:H/VI:H/VA:N/SC:N/SI:N/SA:N | 8.1 |
| 本地可利用 + 高影响 (High) | CVSS:4.0/AV:L/AC:L/AT:N/PR:L/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N | 8.4 |
| 网络可利用 + 部分影响 (Medium) | CVSS:4.0/AV:N/AC:H/AT:N/PR:L/UI:R/VC:L/VI:L/VA:N/SC:N/SI:N/SA:N | 4.2 |
| 攻击复杂度高 + 低影响 (Low) | CVSS:4.0/AV:N/AC:H/AT:P/PR:H/UI:R/VC:L/VI:N/VA:N/SC:N/SI:N/SA:N | 2.3 |
| 无可用性影响 (信息泄露) | CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:N/VA:N/SC:N/SI:N/SA:N | 7.5 |

> **How to use**: Agent 根据发现的实际条件从模板中选择最接近的向量，调整 AV/AC/PR/UI/VC/VI/VA 参数。不确定时使用较保守（低）的分数。

---

## 七、门控策略规则

| 条件 | 裁决 | 退出码 |
|------|------|--------|
| 任何 CVSS ≥ 9.0 | BLOCK | 2 |
| 任何 CISA KEV 已知在野利用 CVE | BLOCK | 2 |
| C+H 较上轮无减少（持平或增加） | BLOCK | 2 |
| Critical > 0（第 3 轮后） | BLOCK | 2 |
| Critical > 0（第 1-3 轮） | HOLD | 1 |
| Critical = 0，High > 0（有 overridable 残留） | HOLD | 1 |
| Critical = 0，High > 0（无 overridable 残留） | CAUTION | 0 |
| C+H = 0 | SHIP | 0 |

> **SLA 建议**: BLOCK → 立即响应；HOLD → 72 小时内修复；CAUTION → 下一迭代修复。
