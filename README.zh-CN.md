[English](README.md) | **简体中文**

# GameBoost 游戏加速 · 后台进程冻结与内存回收

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: Windows 10/11](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4.svg)](#环境要求)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](#环境要求)
[![Version](https://img.shields.io/badge/version-0.1.0--beta-orange.svg)](CHANGELOG.md)
[![Status: BETA](https://img.shields.io/badge/status-BETA%20%E6%B5%8B%E8%AF%95%E7%89%88-ffb454.svg)](#-这是测试版)
[![Zero dependency](https://img.shields.io/badge/dependencies-none-success.svg)](#环境要求)
[![Issues welcome](https://img.shields.io/badge/issues-welcome-blue.svg)](../../issues/new/choose)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](../../pulls)

[![GameBoost](docs/social-preview.png)](https://gzxingr.github.io/gameboost/)

**中文简介** · **English below** — [项目主页 / Landing page](https://gzxingr.github.io/gameboost/) · [完整技术细节](docs/TECHNICAL.md)

> **在开游戏前，把后台应用「冻结」起来；玩完一键原样还原。**
> 浏览器、聊天工具、同步盘、厂商控制台会在你打游戏时继续占用 CPU、内存与磁盘 I/O。
> GameBoost 用 Windows 原生机制把它们**冻结**（不是杀掉——标签页、会话、文档状态全部保留），
> 同时回收其占用的物理内存；结束后按**精确快照**还原优先级、内存优先级与能效（EcoQoS）状态。
>
> **GameBoost** is an open-source, zero-dependency **game booster / process freezer** for Windows 10 & 11.
> It **freezes (suspends) background apps** before you launch a game and **restores them exactly** afterwards —
> reclaiming their working set, then putting back priority, memory priority and EcoQoS state unchanged.
> Written in pure PowerShell 5.1 with a WinForms GUI. It never touches anti-cheat or antivirus processes.

**适用关键词 / Keywords**：游戏加速、游戏加速器、后台进程冻结、挂起进程、内存回收、工作集回收、游戏优化、帧数优化、进程优先级、EcoQoS 效率模式、Windows 11 优化、PowerShell 脚本 ·
game booster, suspend / freeze background processes, process suspension, RAM cleaner, memory optimization, working set trim, efficiency mode, Process Lasso alternative, SceneShift alternative, NtSuspendProcess, EmptyWorkingSet.

<details>
<summary>目录 / Table of contents</summary>

- [⚠️ 这是测试版](#-这是测试版)
- [为什么需要它](#为什么需要它)
- [核心特性](#核心特性--features)
- [环境要求](#环境要求--requirements)
- [快速开始](#快速开始--quick-start)
- [图形界面](#图形界面--gui)
- [命令行参数](#命令行参数--cli)
- [安全模型](#安全模型--safety-model)
- [与同类工具的差异](#与同类工具的差异--comparison)
- [实测数据](#实测数据--benchmarks)
- [已知限制](#已知限制--known-limitations)
- [常见问题 FAQ](#常见问题-faq)
- [参与贡献](#参与贡献--contributing)
- [第三方与致谢](#第三方与致谢--credits)
- [License](#license)

</details>

## ⚠️ 这是测试版

**BETA**：早期版本，**很可能还有问题**。它会真实地挂起你的进程，请在**自己承担风险**的前提下使用，并先读文档、用 `-DryRun` 试跑。
遇到「误冻结了不该冻的进程 / 该冻的没冻 / 恢复不完整 / 在非 Win11+PS5.1 环境下的异常」，**非常欢迎开 Issue** —— 对这个项目来说，真实反馈比任何赞美都有价值。

## 为什么需要它

- 游戏要的是 **CPU 时间片 + 物理内存 + 磁盘 I/O**，而后台应用总在偷偷抢这三样。
- 常见的"游戏加速器"多靠改注册表 / 停服务 / 清缓存，收益含糊且**不可逆**；
  本项目的做法是**完全可逆**：冻结 → 恢复，且全程留日志（`state\`、`logs\`、`history\`）。
- 与同类工具相比，本项目把重点放在 **「不要冻错东西」** 上（见[安全模型](#安全模型--safety-model)）。

## 核心特性 / Features

| 特性 | 说明 |
|---|---|
| 🧊 **真冻结** | `NtSuspendProcess` 挂起进程全部线程，CPU 占用归零；状态全部保留 |
| 💾 **回收内存** | 冻结后 `EmptyWorkingSet` 把工作集交给系统（脏页写回页文件） |
| ♻️ **精确还原** | 冻结前读取优先级 / 内存优先级 / EcoQoS 原值，恢复时按原值写回（实测可精确回到 `0x20/5/0`） |
| 🔒 **四层保护** | 关键进程判定 + 反作弊/杀毒硬编码黑名单 + 自身进程链 + 前台全屏兜底 |
| 🎯 **只恢复自己冻过的进程** | `pid + 进程名 + 启动时间戳` 指纹校验，PID 被系统回收则跳过，绝不误恢复 |
| 🖥️ **图形界面** | WinForms 控制台（扫描/勾选/暂停/恢复/状态/日志），自带 `-SelfTest` 自检 |
| ⏱️ **自动兜底** | 游戏进程全部退出即自动恢复，或 N 分钟后自动恢复（隐藏守护进程，不依赖 GUI 存活） |
| 🪶 **零依赖** | 纯 PowerShell 5.1 + 系统自带 .NET Framework；不需要 Python / Node / 安装器 |
| 📉 **流水线批量执行** | 18 个目标冻结 1.60 秒、恢复 1.08 秒；单进程成本 0.097 秒 |
| 🧪 **可复现基准** | 附带 `tools/MemBalloon.cs` 用于实测"冻结到底腾出多少内存" |

## 环境要求 / Requirements

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 x64（**完整实测仅在 Windows 11 + PowerShell 5.1**，其它组合未验证） |
| PowerShell | 5.1（系统自带）或 7.x |
| 权限 | 建议**管理员**（跨会话/高权限进程需要；非管理员也能冻结同用户进程） |
| 依赖 | **无**。GUI 使用系统自带 .NET Framework 4.x 的 WinForms |

## 快速开始 / Quick start

```powershell
git clone https://github.com/GzxingR/gameboost.git
cd gameboost

# 1) 先看它打算动谁（不改任何东西）
.\pause-non-system-processes.ps1 -DryRun

# 2) 冻结（默认 Safe 白名单）
.\pause-non-system-processes.ps1 -Yes

# 3) 玩完恢复
.\resume-non-system-processes.ps1 -Yes
```

> 若被组策略限制执行脚本，本仓库自带 `.cmd` 入口已使用 `-ExecutionPolicy Bypass`。

## 图形界面 / GUI

双击 `GameBoost.GUI.cmd`，或运行 `Install-GameBoostShortcuts.ps1` 生成桌面快捷方式与热键：
**Ctrl+Alt+G** 打开控制台 · **Ctrl+Alt+P** 暂停 · **Ctrl+Alt+R** 恢复。

```
  ┌─ GameBoost 控制台 ─────────────────────────────────────────────┐
  │ 状态：没有冻结会话　[管理员]                                    │
  │ 模式 [Suspend 真冻结 ▼]  范围 [Safe 白名单 ▼]                   │
  │      □ 包含宿主与编辑器进程   □ 跳过有可见窗口的进程            │
  │ 自动恢复   □ 游戏进程名 [__________]  或 □ [120] 分钟后          │
  │ [扫描进程 F5][暂停所选 F9][恢复全部 F10][查看冻结状态][打开目录] │
  │ ┌───────────────────────────────────────────────────────────┐  │
  │ │ 名称            进程数   内存 MB   会话   状态              │  │
  │ │ chrome             51     4778      1     可冻结            │  │
  │ │ MsMpEng             1      473      0     受保护（杀毒）    │  │
  │ │ ACE-Tray            1      —        1     受保护（反作弊）  │  │
  │ └───────────────────────────────────────────────────────────┘  │
  └────────────────────────────────────────────────────────────────┘
```

扫描进程 → 勾选目标 → `暂停所选 (F9)`；玩完 `恢复全部 (F10)`。
受保护的行会灰显且**无法勾选**（反作弊、杀毒、系统关键进程、会话 0 服务、宿主/编辑器）。

## 命令行参数 / CLI

| 参数 | 说明 |
|---|---|
| `-Scope Safe`（默认） | 只冻 `config.json` 里 `safeTargets` 白名单命中的进程 |
| `-Scope Broad` | 冻结所有**用户会话**进程（会话 0 服务一律不碰） |
| `-Mode Suspend`（默认） | 真冻结：`NtSuspendProcess` + 回收工作集 |
| `-Mode Idle` | 零风险软模式：只设 Idle 优先级 + 内存优先级 VERY_LOW + EcoQoS，不冻结 |
| `-Only <名[]>` / `-NamesFile <路径>` | 只处理指定进程名（后者供 GUI/脚本调用，避开命令行引号转义） |
| `-Exclude <名[]>` / `-Game <名>` | 追加保护 |
| `-BoostGame <名>` | 把游戏设为 HIGH 优先级（恢复时还原原值） |
| `-IncludeAgent` / `-IncludeShell` | 允许冻结宿主/编辑器名单 / 终端家族与 explorer（**不推荐**） |
| `-SkipVisible` | 跳过拥有可见窗口的进程（避免窗口"假死"） |
| `-NoChildren` / `-NoTrim` | 不连带子进程 / 不回收工作集 |
| `-ReSuspend` | 对"仍有活动线程"的进程做二重挂起（日志记 `suspendCount=2`，恢复时对应调用两次） |
| `-AutoResumeMinutes <n>` / `-ResumeWhenProcessExits <名>` | 派发守护进程：N 分钟后 / 目标进程全部退出后自动恢复 |
| `-DryRun` / `-Yes` / `-Quiet` / `-DefenderHint` | 干跑 / 免确认 / 静默 / 打印 Defender 提示 |
| `-EmitJson` / `-JsonOut <路径>` | 输出候选清单 JSON（供 GUI 或你自己的脚本复用同一套判定） |

恢复脚本：`-Status`（看当前冻结了什么）、`-DryRun`、`-Force`（忽略指纹校验）、`-KeepJournal`（保留会话文件）。

## 安全模型 / Safety model

1. **`IsProcessCritical`** 判定系统关键进程后跳过。
   *已知局限*：该 API 对 `csrss/services/wininit` 返回 True，但对 `System`、`lsass` 返回 **False**，所以不能只靠它。
2. **名字黑名单（硬编码）**：系统组件 + **反作弊与杀毒**（Windows Defender、腾讯 ACE、EasyAntiCheat、BattlEye、Vanguard、各类安全组件……），
   `config.json` 与命令行参数**都无法解除**。理由：挂起反作弊会导致游戏崩溃或封号；挂起杀毒属于 EDR 明确监控的恶意行为特征。
3. **自身进程链**：脚本的祖先链与自身后代绝不冻结；**终端家族**（cmd/powershell/conhost/WindowsTerminal 等）与 `explorer.exe` 默认也在保护名单内。
4. **冻结瞬间的前台全屏兜底**：拥有前台全屏窗口的进程强制排除，避免把正在跑的游戏冻住。

另外：**只恢复自己冻结过的进程**（指纹校验）、**默认不碰会话 0 服务**（`skipSession0`）、
**不写注册表 / 不改服务 / 不改电源计划 / 不改杀毒设置 / 不联网**。

## 与同类工具的差异 / Comparison

| 工具 | 定位 | 与本项目的关系 |
|---|---|---|
| **Process Lasso**（闭源） | 长期优先级与亲和性调节（ProBalance） | 不做冻结；可并存 |
| **Mem Reduct** / **WinMemoryCleaner**（开源） | 内存回收（工作集 / 待机列表 / 系统缓存） | 只回收不冻结；本项目是**先冻结再回收**，效果更实在 |
| **SceneShift**（开源，TUI） | 终端界面挂起/结束后台应用 | 同类思路。本项目侧重：反作弊/杀毒保护、指纹校验、QoS 精确快照还原、双阶段自动恢复 |
| **System Informer**（开源，GUI） | 全能系统监视/调试 | 能力覆盖，但需手动逐个操作，没有"开局一键冻结"工作流 |
| **任务管理器「效率模式」**（系统自带） | 单进程降 EcoQoS | 本项目可批量做，并额外冻结 + 回收内存 |
| 各类"游戏加速器"（闭源） | 改注册表 / 停服务 / 清缓存 | 本项目操作**完全可逆**且全程留日志 |

## 实测数据 / Benchmarks

测试机：Windows 11、16 逻辑处理器、15.3 GB 内存、NVMe SSD、PowerShell 5.1。

| 项目 | 结果 |
|---|---|
| `-Scope Safe` 干跑 | 146 进程 / 31 名字，工作集合计约 8–10 GB |
| 冻结 18 个目标 | **1.60 秒**（优化前 8.63 秒） |
| 恢复 18 个目标 | **1.08 秒**（优化前 3.30 秒） |
| 单进程成本 | **0.097 秒** |
| 冻结校验 | 线程挂起数 `susp=N/N`，3 秒 CPU 增量 0 ms |
| 内存基准（`tools/MemBalloon.cs`，2048 MB 脏页） | 工作集 2067 MB → **0 MB**；5 秒后可用物理内存 +1017 MB（约 50%），其余随系统空闲逐步回吐；页文件使用量 +3.6 GB |

**重要预期管理**：界面与日志里的"预计回收 N MB"是**工作集估算**，不等于立刻腾出 N MB 物理内存 ——
脏页必须先写回页文件，释放是**异步、约一半即时可见**的。建议**在启动游戏之前**执行冻结，否则写回流量会和游戏加载抢磁盘。

## 已知限制 / Known limitations

- **被冻结的可见窗口会假死/变灰**，恢复即正常；介意就用 `-Mode Idle` 或 `-SkipVisible`。
- **微信/同步盘**冻结期间不收消息、不同步（默认已放进 `idleByDefault` 只降 QoS 不冻结）。
- **Office/WPS** 冻结在自动保存中途可能丢最近编辑（同样默认走软模式）。
- **UWP / 商店应用**无法被挂起（Windows 限制）。
- 少数进程带有 `BYPASS_PROCESS_FREEZE` 线程，冻结后仍可能消耗少量 CPU —— 工具会**实测校验并如实报告**，必要时用 `-ReSuspend`。
- `NtSuspendProcess` 是原生 NT API（未在 Win32 层公开），按线程逐个挂起，**理论上有竞态**；恢复必须用同一族 API，不要与 `SuspendThread` 混用。
- 杀毒软件可能对"批量挂起进程"这种行为提高关注度（该手法历史上被恶意软件滥用过）。脚本明文、不碰安全组件、全程日志，如被拦截请自行加白。
- 冻结会占用页文件空间（脏页写回），磁盘可用空间过小时不建议大批量冻结。

## 常见问题 FAQ

<details><summary><b>会不会把游戏或反作弊软件冻住？</b></summary>

不会。保护分四层，见[安全模型](#安全模型--safety-model)。反作弊与杀毒进程在硬编码黑名单里，配置文件与参数都无法解除。
</details>

<details><summary><b>冻结和「结束进程」有什么区别？</b></summary>

冻结（挂起）保留进程全部内存与状态，只是不让它获得 CPU 时间；恢复后浏览器标签页、聊天记录都还在。
结束进程会丢失状态。本项目默认**只冻结，不结束**任何进程。
</details>

<details><summary><b>冻结后能腾出多少内存？会不会拖慢游戏？</b></summary>

实测 2070 MB 脏页工作集可以被清零，但脏页要先写回页文件，可用物理内存约在 5 秒内增加一半左右，其余随系统空闲逐步回吐。
所以在**启动游戏之前**执行更好；如果游戏已经在跑，建议用 `-Mode Idle`（不写盘、只降 QoS）。
</details>

<details><summary><b>为什么冻结之后窗口卡住 / 变灰？</b></summary>

这是冻结的固有现象：被挂起的进程无法响应窗口消息，Windows 会把它显示为无响应。恢复即可，不会丢数据。
介意的话用 `-SkipVisible` 跳过有可见窗口的进程。
</details>

<details><summary><b>需要装什么依赖？可以在 Windows 10 / PowerShell 7 上用吗？</b></summary>

不需要任何依赖（GUI 用系统自带 WinForms）。仅在 Windows 11 + PowerShell 5.1 完整实测过；
Windows 10 / PS 7 / ARM64 理论上可用但未验证，欢迎反馈。
</details>

<details><summary><b>恢复失败或忘了恢复怎么办？</b></summary>

`resume-non-system-processes.ps1 -Force` 再恢复一次；或直接重启 —— **挂起状态不跨重启持久化**。
也可以一开始就加 `-AutoResumeMinutes 120` 或 `-ResumeWhenProcessExits <游戏进程名>`，让守护进程自动收拾。
</details>

<details><summary><b>它和 Process Lasso / Mem Reduct / SceneShift 有什么不同？</b></summary>

见[与同类工具的差异](#与同类工具的差异--comparison)。简单说：本项目专注"游戏前冻结 → 玩完精确还原"这一工作流，
并把重点放在"不要冻错东西"上。可以与其他工具并存。
</details>

<details><summary><b>会不会被反作弊判定为作弊？</b></summary>

不会：本项目不读写游戏内存、不注入、不改游戏文件，只是挂起你自己指定的进程；反作弊进程本身永远不被挂起。
</details>

## 参与贡献 / Contributing

这就是个**测试版**，最缺真实反馈：

- 🐞 **遇到 bug**：请开 Issue 并附上 `-DryRun` 输出、`state\current.json`（可脱敏）、系统与 PowerShell 版本。
- 💡 **想要功能**：说明你的使用场景（例如某游戏/某软件被误冻结、某类进程漏冻）。
- 🔧 **提交 PR**：请保持"纯 PowerShell + 零依赖"这一约束，并在描述里附上你实测过的输出。
- ⭐ 觉得有用就点个 Star，能让更多被后台进程拖慢的人搜到它。

特别欢迎的报告类型：**误冻结了不该冻的进程**、**该冻的没冻**、**恢复不完整**、**在 Windows 10 / ARM64 / PowerShell 7 上的表现**。

## 第三方与致谢 / Credits

- 本项目**不打包**任何第三方二进制。文档中提到的同类工具（System Informer、Mem Reduct、SceneShift 等）请到各自官方仓库获取。
- 实现依据：Microsoft Learn（`SetProcessInformation`、`PROCESS_POWER_THROTTLING_STATE`、`MEMORY_PRIORITY_INFORMATION`、`EmptyWorkingSet`、进程访问权限）、
  Windows SDK 头文件（`processthreadsapi.h`）、以及 System Informer 的 phnt 原生 API 文档（NtDoc）。
- `NtSuspendProcess` 的注意事项（逐线程挂起竞态、忽略 `BYPASS_PROCESS_FREEZE` 线程）来自 phnt/NtDoc 的注释。

## License

MIT（见 [LICENSE](LICENSE)）。使用风险自负 —— 它会真实地挂起你的进程。

工程手记：[为了打游戏时不被后台抢资源，我用 PowerShell 做了个"冻结"工具 —— 以及 5 个代价不小的坑](docs/articles/01-engineering-notes.md).
