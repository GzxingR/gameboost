# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的格式，版本号遵循语义化版本。

## [0.2.0-beta] - 2026-10-13

「表单化自动选择 + 选择性恢复」：把每次手点几十个进程变成一套可复用的档案/规则表，恢复也不再一刀切。

### Added

- **档案（profiles）**：`config.json` 的 `profiles` 段内置 4 套策略（游戏前 / 极简 / 只降QoS / 办公放宽），
  CLI 用 `-Profile <名|路径>` 加载，GUI 用「档案」下拉框选择；档案可带 `scope / mode / minMemoryMB / include / exclude / skipVisible / rules`
  - `profiles\游戏前.json`：可直接复制修改的独立档案模板
  - 未知档案名会报错并列出可用档案
- **规则表（selectRules）**：`pause.ps1 -RuleFile <路径>` / `-NoRules`
  - 按顺序匹配、首个命中生效；`action: suspend | idle | skip`
  - 门槛按**进程名聚合**判定：`minMemoryMB`（下限）/ `maxMemoryMB`（上限，本次新增）
  - 默认规则表把**游戏启动器/商店**（steam / Epic / Battle.net / EA Desktop / Ubisoft / Riot / WeGame / GOG）判为 `skip`
  - `-EmitJson` 每行新增 `action` / `rule`，顶层新增 `profile` / `ruleCount`（GUI 与脚本共用同一份决策，不产生第二份名单）
  - 硬保护（反作弊 / 杀毒 / 系统关键 / 会话 0 / 自身进程链 / 前台全屏）**不因规则表而放宽**
- **选择性恢复**：`resume.ps1 -Only <名[]>` / `-NamesFile <路径>`
  - 只恢复指定进程名；未处理条目保留在 `state\current.json`，全部处理完才归档到 `history\`
- **GUI 效率三件套**：筛选框（F6）、🪄 自动选择（F7）、勾选记忆（`state\selection.json`，`rememberSelection` 开关）、
  「恢复所选…」面板（按名字分组，勾几条恢复几条）；扫描前删除旧 `scan.json`，避免读到陈旧名单

### Changed

- 显式名单（`-Only` / `-NamesFile`）**优先于规则表**：明确点名不再被规则的 `skip` 拦掉，`-Mode Idle` 等命令行语义照常生效
- `-EmitJson` 不再在「无可冻结目标」时提前退出，保证清单一定是本次扫描的产物
- 档案 `游戏前` 的规则顺序修正为「聊天/同步软模式」优先于通配冻结（否则微信会被真冻结）

### Fixed

- 规则表内存门槛语义：`minMemoryMB` 是「达到才命中」，新增 `maxMemoryMB` 表达「低于才命中」；
  默认规则表原先用 `minMemoryMB` 表达「小工具不处理」，实际会把大进程全部跳过
- GUI 自检：无窗口环境下 `ItemChecked` 事件不触发导致勾选集合不同步（改为动手前从列表同步）
- GUI 受保护行拦截自检的回归（`$protRow` 查找行曾被覆盖）

### Tests

- 自测套件 44 → 86 项断言：新增 T9（规则表 / 档案 / 门槛 / 名字聚合）、T10（选择性恢复 + 显式名单优先）、
  T11（GUI 筛选 / 自动选择 / 勾选记忆 / 恢复所选）

### Docs

- 落地页 `docs/index.html`：新增「表单化自动选择：档案 + 规则表」章节、核心特性 2 条、快速开始示例、FAQ 2 条
  （启动器会不会被冻、还要不要手点），并更新技术文章入口与 meta/og 描述
- `docs/TECHNICAL.md`：新增 §6 档案与规则表（判定顺序、规则/档案字段、显式名单优先、`-EmitJson` 增量字段）、
  §7 选择性恢复（会话文件保留与归档语义），§5 补记坑 9–12
- 技术文章：标题改为"7 个代价不小的坑"，新增「后来补的『表单』：规则表与选择性恢复」章节，重渲染 HTML
- README（EN/ZH）特性表、`docs/sitemap.xml`（lastmod）同步更新

## [0.1.0-beta] - 2026-10-13

首个公开测试版。**可能有未知缺陷，欢迎 Issue。**

### Added

- `pause-non-system-processes.ps1`：冻结非系统进程并回收工作集
  - `-Scope Safe|Broad`：白名单模式 / 全部用户会话进程
  - `-Mode Suspend|Idle`：真冻结 / 只降 QoS 的软模式（零风险可逆）
  - `-NamesFile`：从文件读取目标名单（规避 PowerShell 5.1 向子进程传数组时的引号转义问题）
  - `-DryRun` / `-Yes` / `-Quiet` / `-DefenderHint`
  - `-BoostGame <name>`：给游戏进程提升优先级（恢复时还原）
  - `-AutoResumeMinutes` / `-ResumeWhenProcessExits`：派发隐藏守护进程自动恢复
  - `-ReSuspend`：对仍有活动线程的进程做二重挂起（日志记录挂起计数）
  - `-EmitJson`：输出候选清单 JSON，供 GUI 复用同一套保护判定
- `resume-non-system-processes.ps1`：只恢复本工具冻结过的进程
  - 指纹校验（pid + 进程名 + 启动时间戳），PID 复用则跳过
  - `-Status` / `-DryRun` / `-Force` / `-KeepJournal`
  - 自动归档到 `history\`
- `GameBoost.GUI.ps1`：WinForms 图形界面（零外部依赖，自带 `-SelfTest` 自检）
- `Install-GameBoostShortcuts.ps1`：桌面快捷方式 + 热键（Ctrl+Alt+G / P / R）
- `tools/MemBalloon.cs`：内存回收基准工具（用于验证「冻结到底腾出多少内存」）
- 四层进程保护：`IsProcessCritical` + 名字黑名单（含反作弊/杀毒）+ 自身进程链 + 前台全屏兜底
- 会话日志与归档：`state\current.json`、`logs\`、`history\`

### Performance

- 冻结/恢复改为流水线批量执行：N 个目标只付一次等待与一次快照成本
  - 实测 18 个目标：冻结 8.63 秒 → **1.60 秒**（-81%），恢复 3.30 秒 → **1.08 秒**（-67%）
  - 单进程成本 0.48 秒 → **0.097 秒**
- 高频日志改为批量写入，减少文件开关次数

### Fixed

- GUI 多选「暂停所选」曾静默失效：把 `"a","b"` 传给子进程时 PS 5.1 会转义内层引号，
  子进程收到的是一整条字符串导致 `-Only` 匹配不到任何名字（已改为 `-NamesFile`）
- 受保护行可被程序化勾选（已加确定性取消逻辑，并在引擎侧做二次过滤）
- 子进程连带冻结曾因 `List[object]` 与数组相加抛 `Argument types do not match` 而整体失效
- 守护进程曾按进程名判断目标退出，遇到同名常驻进程会永不恢复（已改为「先等出现 → 锁定当时那批 PID → 全部退出才恢复」）
- 日志面板曾把历史日志全量回显（已改为按时间取增量）
- 自身进程链保护曾把「祖先的所有后代」都算作自家进程，导致浏览器等内存大户被漏掉

### Docs

- 新增项目主页 `docs/index.html`（GitHub Pages 落地页，含 `SoftwareApplication` 与 `FAQPage` 结构化数据、Open Graph / Twitter 卡片）
- 新增 `docs/social-preview.png`（1280×640 社交预览图，GDI+ 绘制保证文字清晰）、`docs/robots.txt`、`docs/sitemap.xml`
- README 重构：徽章、中英双语标题、同类工具对比表、FAQ、关键词段落；面向搜索引擎与海外读者
