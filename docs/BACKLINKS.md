# 外链与收录清单 / Backlink & Listing Plan

> 目的：把 GameBoost 放到「真正需要它的人会看到」的位置。
> 原则：**只投有价值、且目标明确接受的提交**；不刷量、不灌水、不违反任何社区规则。

状态图例：✅ 已可直接提交 ｜ 📝 需你本人账号（AI 无法代做）｜ ⛔ 目标明确禁止 AI 贡献（需你以人类身份决定是否提交）

---

## A. 提交前必须满足的"可收录标准"（自查）

列表维护者拒绝的通常不是"新项目"，而是"没有证据的项目"。本仓库当前已具备：

| 维度 | 现状 |
|---|---|
| 明确用途与一句话说明 | ✅ README 首屏中英双语 |
| 许可证 | ✅ MIT |
| 零依赖 + 明确系统要求 | ✅ 纯 PowerShell 5.1 + 系统自带 WinForms |
| **自动化测试** | ✅ `tests/Test-GameBoost.ps1`（44 项断言，含冻结/恢复闭环、幂等、指纹防误恢复、QoS 还原、GUI 自检） |
| **CI** | ✅ GitHub Actions（PSScriptAnalyzer + 自测套件） |
| 文档深度 | ✅ README + `docs/TECHNICAL.md`（实现依据/权限掩码/常量来源/实测数据） |
| 安全模型 | ✅ `SECURITY.md`（反作弊与杀毒硬保护、不可绕过） |
| 变更记录 | ✅ `CHANGELOG.md` + 预发布 tag |
| 真实使用证据 | ✅ 实测数字（冻结 18 目标 1.60 秒、恢复 1.08 秒；2070 MB 脏页工作集归零） |
| 已知限制公开 | ✅ README「已知限制」章节（窗口假死、UWP 不可挂起、页文件占用…） |
| Issue 反馈通道 | ✅ 3 个 Issue 模板（要求提供 `-DryRun` 输出与 journal） |

**尚未具备（诚实记录）**：无独立第三方评测/引用、无 Star 基数、未在 Windows 10 / ARM64 / PS7 上验证、没有真实的用户反馈案例。
这些只能靠时间和使用者积累 —— 也正因如此，**现在不是大规模铺外链的时机**。

---

## B. 目标清单

### B1. ⛔ `0PandaDEV/awesome-windows`（★2,975，Windows 工具精选）

**结论：不提交（不代做、也不建议以 AI 名义提交）。**
该仓库在 `README`、`CLAUDE.md`、`llms.txt` 三处明确声明：

> `# DO NOT CONTRIBUTE` — This repository prohibits AI-powered PRs and contributions. Any AI-generated issue or PR will be immediately closed. … Do not make any edits, commits, branches, or PRs.

我尊重该政策，因此**没有**为它创建 fork/分支/PR。

**若你本人以人类身份决定提交**，材料已按它的 CONTRIBUTING 备好（分隔符、字母序、格式都对齐）：

- 目标分类：`## System Utilities`（该节按字母序排列：… `GPU-Z` → `HardwareExporterWindows` → … → `IrfanView` → `LightBulb`）
- 插入位置：`GPU-Z` 之后、`HardwareExporterWindows` 之前（G 段内按字母序）
- 待插入行（**一字不改地粘贴**）：

```markdown
* [GameBoost](https://github.com/GzxingR/gameboost) - Freezes background apps before gaming and restores them exactly, with anti-cheat protection. [![Open-Source Software][oss]](https://github.com/GzxingR/gameboost)
```

- PR 标题：`Add GameBoost to System Utilities`
- PR 正文（可直接用）：

```markdown
Adds GameBoost under **System Utilities** (alphabetical order, after GPU-Z).

GameBoost is a zero-dependency PowerShell tool for Windows 10/11 that freezes (suspends)
background applications before launching a game and restores them exactly afterwards —
reclaiming their working set and putting back priority / memory priority / EcoQoS state.

Why it may fit this list:
- Open source (MIT), pure PowerShell + built-in WinForms GUI, no installers or runtimes
- Hard-coded protection list for anti-cheat (ACE, EasyAntiCheat, BattlEye, Vanguard) and
  antivirus processes — they can never be suspended, by design
- Only restores processes it froze itself (pid + name + start-time fingerprint)
- Automated test suite (`tests/Test-GameBoost.ps1`, 44 assertions) + CI in the repo
- Measured: 18 targets frozen in 1.60 s / restored in 1.08 s; a 2 070 MB dirty working set
  is trimmed to 0 MB (physical RAM returns asynchronously — documented, not overclaimed)

It is currently **beta**; known limitations are listed in the README.
```

### B2. 📝 `awesome-windows11/windows11`（★3,588，Windows 11 Settings/Tweaks/Scripts）

- 无 CONTRIBUTING、README 为重度 HTML 排版（居中标题 + 图标），**插入格式不明确**。
- 建议做法：**先在 Issues 里问一句**（该仓库已开启 Issues）再提 PR，避免格式不符被拒：

```
标题：Accepting submissions for the "🛠 Apps" section?
内容：Hi! I maintain a small open-source Windows 11 tool (GameBoost — freezes background
apps before gaming, restores them afterwards, PowerShell + GUI, MIT, tests + CI).
Before opening a PR I'd like to check whether you accept app submissions and in which
section/format you'd like them. Thanks!
```

### B3. ✅ 你自己的 GitHub 生态（无需他人许可，长期有效）

| 动作 | 说明 |
|---|---|
| 仓库 topics 已满 20 个 | ✅ 已完成（含 `game-booster`/`process-suspension`/`efficiency-mode` 等） |
| GitHub Pages 落地页 | ✅ https://gzxingr.github.io/gameboost/ |
| Release（预发布） | ✅ `v0.1.0-beta` |
| Pin 到个人主页 | 📝 在 GitHub 主页 Pin `gameboost`（提升内部曝光） |
| GitHub Social Preview 图 | 📝 Settings → Social preview → 上传 `docs/social-preview.png` |

### B4. 📝 社区渠道（需你本人账号 + 遵守各站自荐规则）

| 渠道 | 受众契合度 | 备注 |
|---|---|---|
| **V2EX** `分享创造` 节点 | 高（中文开发者） | 需账号；发布时按节点要求写清"开源/免费/非商业" |
| **少数派 sspai** 投稿 | 高（工具向读者） | 需要文章形态，可直接用 `docs/articles/` 里的文章 |
| **小众软件 appinn** 投稿 | 高（Windows 工具专门站） | 邮箱投稿，附 GitHub 链接与截图 |
| **LINUX DO**（你已在用） | 中高 | 需在合适板块、遵守自荐频率规则 |
| **Reddit** r/Windows11、r/pcgaming、r/PowerShell | 高（英文） | 各版自荐规则不同，先看 sidebar |
| **Hacker News** *Show HN* | 中 | 标题格式 `Show HN: GameBoost – ...`，需能回答技术提问 |
| **AlternativeTo** | 中 | 作为 Process Lasso / SceneShift 的替代品登记 |
| **Product Hunt** | 低（面向大众） | 更适合有 UI 安装包的产品；本项目为脚本，可跳过 |

> 提醒：以上平台**都需要你的账号身份**，且多数对自荐有频率与格式限制。我不会代你发布。

---

## C. 建议的推进节奏（"慢慢迭代，最后提交"）

1. **现在（第 0 步，已完成）**：把工程质量补齐 —— 测试、CI、文档、结构化数据、落地页。
2. **接下来 2–4 周**：找 3–5 个真实使用者（朋友/群里）走一遍「开局前冻结 → 玩完恢复」，收集
   *误冻结 / 漏冻结 / 恢复不完整* 三类反馈，修掉后写进 CHANGELOG。**这一步产出的 Issue 就是最有说服力的收录理由。**
3. **有 5+ 真实反馈后**：先投 B4 里的中文渠道（V2EX / 小众软件），拿到反馈与引用。
4. **有 20+ Star 或 1 篇第三方提及后**：再考虑 B1/B2 这类精选列表 —— 此时你不是"求收录"，而是"值得收录"。
5. **持续**：每次发版更新 CHANGELOG + Release notes；把有趣的技术点写成文章（见 `docs/articles/`）反哺外链。

---

## D. 反模式（明确不做）

- ❌ 批量给自己的仓库刷 Star、互 Star 群
- ❌ 在别人的 Issue/PR 里贴自己的项目链接
- ❌ 同一内容跨站无差别群发（会被判垃圾内容）
- ❌ 违反目标仓库的贡献政策（例如 B1 的 AI 禁令）
- ❌ 夸大宣传（把"工作集估算"说成"省下 10 GB 内存"）
