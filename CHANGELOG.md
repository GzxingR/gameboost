# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的格式，版本号遵循语义化版本。

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
