# AGENTS.md — 给 AI 编码代理的项目指南 / Guide for AI coding agents

> 这份文件是给"用 AI 来扩展或维护 GameBoost"的人和代理看的：**先读它，再改代码**。
> This file is for humans and agents extending GameBoost with AI. Read it before editing anything.

## 0. 一句话 / One-liner

GameBoost = 纯 PowerShell 5.1 + WinForms 的 Windows 游戏加速工具：开游戏前用 `ntdll!NtSuspendProcess` 冻结后台应用、
`psapi!EmptyWorkingSet` 回收工作集，玩完按指纹精确还原优先级与 QoS。零外部依赖、可完全回滚、全程留日志。

## 1. 目录地图 / Map

| 路径 | 作用 | 改动风险 |
|---|---|---|
| `pause-non-system-processes.ps1` | 冻结引擎：保护判定 → 范围 → 档案/规则表 → 冻结 → 日志 → 写会话文件 | 谨慎：安全层不可放宽 |
| `resume-non-system-processes.ps1` | 恢复引擎：指纹校验 → 恢复 → 选择性恢复 → 归档 | 谨慎 |
| `GameBoost.GUI.ps1` | WinForms 界面。**只调用上面两个脚本**，不重复实现安全判定 | 视觉/交互随意改；控件名与 `-SelfTest` 输出必须保留 |
| `config.json` | 默认配置：`safeTargets` / `hostProtected` / `idleByDefault` / `selectRules` / `profiles` / `rememberSelection` | 可加规则与档案 |
| `profiles/*.json` | 独立档案模板（`-Profile <路径>` 加载） | 随意加 |
| `tests/Test-GameBoost.ps1` | 自测套件（headless；只冻结自建合成进程） | **必须同步维护** |
| `tools/MemBalloon.cs` | 内存基准合成进程（`gbmemballoon.exe`），C# 5 | 少改 |
| `docs/` | `TECHNICAL.md`、`AI-EXTENDING.md`、`llms.txt`、落地页、技术文章 | 随意改 |
| `schemas/` `examples/` | JSON Schema 与可直接加载的示例 | 随意加 |

## 2. 红线 / Hard rules（任何改动都不能违反）

1. **反作弊（ACE / EasyAntiCheat / BattlEye / Vanguard…）、杀毒（`MsMpEng` 等）、系统关键进程、会话 0 服务、
   本项目自身进程链、冻结瞬间的前台全屏窗口 —— 永远不可冻结。**
   任何配置项、规则表、档案、`-Only` / `-NamesFile`、GUI 勾选都**不能**解除。这条不是"默认值"，是硬编码。
2. 冻结是**挂起**，不是结束：不要引入 `Stop-Process` / `taskkill` 作为"优化"手段。
3. 不写注册表、不停服务、不改电源计划、不注入、不读写游戏内存、不碰杀毒设置。
4. 只恢复"自己冻结过的"进程（`pid + 进程名 + 启动时间戳` 指纹）；不要为了"更省事"去掉指纹校验。
5. 不要在仓库里写入本机信息：主机名、用户名、`C:\Users\<name>\...` 路径、代理端口、真实进程清单快照。
6. 运行产物 `state/` `logs/` `history/` 不入库（`.gitignore` 已覆盖）。

## 3. 代码约定 / Conventions

- **PowerShell 5.1 兼容**：不要用 PS 7 语法（`??`、`-AsArray`、`ForEach-Object -Parallel`、`::new()` 等）。
- **所有 `.ps1` / `.json` 必须 UTF-8 with BOM**：PS 5.1 读无 BOM 的 UTF-8 会把中文按 ANSI 解析并报语法错误。
  写入用：`[IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))`。
- **`Add-Type` 走 C# 5 编译器**：不能用 `$"..."` 插值、表达式体成员（`=>`）、`nameof`、`?.`。
- **零外部依赖**：只用系统自带的 .NET Framework / WinForms。
- **中文注释**，写"为什么"而不是"做了什么"；危险动作要可解释、可回滚。
- 新增行为默认靠"更保守"的一侧：宁可漏冻，不可误冻。

## 4. 扩展点速查 / Where to add what

| 想做的事 | 改哪里 | 要点 |
|---|---|---|
| 给某软件加规则 | `config.json` → `selectRules`（或用 `-RuleFile` 传自己的规则表） | 按顺序匹配、**首个命中生效**；`match` 匹配**进程名**通配；门槛**按进程名聚合**；`minMemoryMB` 是下限、`maxMemoryMB` 是上限 |
| 新建一套策略 | `config.json` → `profiles`，或 `profiles/*.json` | 字段：`scope / mode / minMemoryMB / include / exclude / skipVisible / rules`；`exclude` 优先级高于规则表 |
| 加一个新动作（例如 `throttle`） | `pause` 的 4b 判定段 + `$useIdle` 决策 + `resume` 的还原分支 + `-EmitJson` 的 `action` + GUI 状态列 + 自测断言 | 必须同时给出"恢复时怎么还原"和"自测怎么验证" |
| 扩展 `-EmitJson` | `pause` 的 EmitJson 段（+ `schemas/scan.schema.json`） | 只**追加**字段；`schema` 版本号是稳定契约，破坏性变更必须升版本 |
| GUI 加控件/改样式 | `GameBoost.GUI.ps1` 控件区 + 事件区 | 不要在 GUI 里复制安全判定；用 `-EmitJson` 的结果；保留 `-SelfTest` 的 Note 名称（自测依赖它们） |
| 加一条自测 | `tests/Test-GameBoost.ps1` | 只冻结自建的 `gbmemballoon` / `ping`；用临时档案（`include`）把范围收窄 |

## 5. 验证 / Verify before claiming done

```powershell
# 1) 语法 + BOM（所有 .ps1 必须 ef bb bf）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GameBoost.ps1      # T1 会做语法检查
# 2) 全量自测（安全：只冻结自建合成进程）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GameBoost.ps1
# 3) 只看清单与规则判定（不改任何东西）
.\pause-non-system-processes.ps1 -EmitJson -JsonOut .\state\scan.json -Scope Broad -NoRules
# 4) GUI 自检（退出码 0；输出 GUI-* 报告行）
powershell -NoProfile -ExecutionPolicy Bypass -File .\GameBoost.GUI.ps1 -SelfTest
```

判定标准：自测全绿、GUI 自检退出码 0、`-EmitJson` 输出符合 `schemas/scan.schema.json`。
**没有跑过自测，不要说"完成"或"已验证"。**

## 6. 提交 / Commits

- Conventional Commits：`feat:` / `fix:` / `docs:` / `style:` / `test:` / `chore:`（中文正文可以）。
- 一个提交只做一件事，`feat` 与 `style` 分开提交。
- 正文写清"为什么"，以及验证方式与结果。

## 7. 现成任务 / Ready-made AI tasks

见 `docs/AI-EXTENDING.md`：5 个高频扩展任务 + 可直接复制的提示词 + 每个任务的不变量与验证方式。
机器可读入口见 `docs/llms.txt`（摘要）与 `docs/llms-full.txt`（可整篇喂入）。
