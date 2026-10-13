# GameBoost

> ⚠️ **BETA / 测试版**：早期版本，**很可能还有问题**。欢迎提 Issue 一起把它做扎实 —— 见 [Issues](https://github.com/GzxingR/gameboost/issues)。
> ⚠️ **BETA**: Early build. Expect rough edges. Bug reports and ideas are very welcome.

**在开游戏前，把后台应用「冻结」起来；玩完一键原样还原。**

Freeze background apps before gaming, then restore them exactly as they were.

Windows 上的后台应用（浏览器、聊天工具、同步盘、厂商控制台）会在你打游戏时继续吃 CPU 与内存。
GameBoost 用 Windows 原生机制把它们**冻结**（不是杀掉，状态全部保留），同时回收它们占用的物理内存；
结束后按精确快照还原优先级、内存优先级与能效状态，**绝不会误恢复你没让工具冻结的进程**。

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
  │ │ Code               13     2244      1     可冻结            │  │
  │ │ MsMpEng             1      473      0     受保护（杀毒）    │  │
  │ │ ACE-Tray            1      —        1     受保护（反作弊）  │  │
  │ └───────────────────────────────────────────────────────────┘  │
  │ 08:56:31   计划处理 146 个进程 / 31 个名字，预计回收 9658 MB    │
  │ 08:56:32   OK  chrome   pid 1228   Suspend   4246 MB  susp=…    │
  └────────────────────────────────────────────────────────────────┘
```

---

## 为什么需要它

- 游戏要的是 **CPU 时间片 + 物理内存 + 磁盘 I/O**，而后台应用总在偷偷抢这三样。
- 常见的「游戏加速器」很多是改注册表 / 停服务 / 清缓存，收益含糊且不可逆；
  本项目的做法是**可完全逆**：冻结 → 恢复，日志全程留痕。
- 与同类工具相比，本项目把重点放在**「不要冻错东西」**上（见下方安全模型）。

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 x64（**仅在 Windows 11 + PowerShell 5.1 上实测过**，10 未验证） |
| PowerShell | 5.1（系统自带）或 7.x |
| 权限 | 建议**管理员**（跨会话/高权限进程需要；非管理员也能冻结同用户进程） |
| 依赖 | 无。图形界面用系统自带 .NET Framework 4.x 的 WinForms |

**不需要**：Python / Node / .NET SDK / 编译步骤（全部是纯 PowerShell + 少量内嵌 C# 通过 `Add-Type` 现场编译）。

## 快速开始

```powershell
# 1) 放到任意目录，例如 %USERPROFILE%\GameBoost
# 2) 先看它打算动谁（不改任何东西）
.\pause-non-system-processes.ps1 -DryRun

# 3) 冻结（默认 Safe 白名单）
.\pause-non-system-processes.ps1 -Yes

# 4) 玩完恢复
.\resume-non-system-processes.ps1 -Yes
```

或者直接用图形界面（推荐）：双击 `GameBoost.GUI.cmd`，或运行 `Install-GameBoostShortcuts.ps1`
生成桌面快捷方式与热键：**Ctrl+Alt+G** 打开控制台、**Ctrl+Alt+P** 暂停、**Ctrl+Alt+R** 恢复。

> 热键的意义：如果把终端/宿主进程也一起冻结了，热键是你唯一的恢复入口。

## 用法

### 图形界面

扫描进程 → 勾选要冻结的应用 → `暂停所选 (F9)`；玩完 `恢复全部 (F10)`。
受保护的行会灰显且**无法勾选**（反作弊、杀毒、系统关键进程、会话 0 服务、宿主/编辑器）。

### 命令行

| 参数 | 说明 |
|---|---|
| `-Scope Safe`（默认） | 只冻 `config.json` 里 `safeTargets` 白名单命中的进程 |
| `-Scope Broad` | 冻结所有**用户会话**进程（会话 0 服务一律不碰） |
| `-Mode Suspend`（默认） | 真冻结：`NtSuspendProcess` + 回收工作集 |
| `-Mode Idle` | 零风险软模式：只设 Idle 优先级 + 内存优先级 VERY_LOW + EcoQoS，不冻结 |
| `-Only <名[]>` / `-NamesFile <路径>` | 只处理指定进程名（后者供 GUI/脚本调用，避开引号转义） |
| `-Exclude <名[]>` / `-Game <名>` | 追加保护 |
| `-BoostGame <名>` | 把游戏设为 HIGH 优先级（恢复时还原原值） |
| `-IncludeAgent` | 允许冻结宿主/编辑器名单里的进程（默认保护） |
| `-IncludeShell` | 允许冻结终端家族与 explorer（**不推荐**：任务栏会假死） |
| `-SkipVisible` | 跳过拥有可见窗口的进程（避免窗口"假死"） |
| `-NoChildren` / `-NoTrim` | 不连带子进程 / 不回收工作集 |
| `-ReSuspend` | 对"仍有活动线程"的进程做二重挂起（日志记 `suspendCount=2`，恢复时对应调用两次） |
| `-AutoResumeMinutes <n>` | 派发隐藏守护进程，n 分钟后自动恢复 |
| `-ResumeWhenProcessExits <名>` | 守护进程：等该进程出现 → 等它**全部**退出 → 自动恢复 |
| `-DryRun` / `-Yes` / `-Quiet` | 干跑 / 免确认 / 静默 |
| `-EmitJson` / `-JsonOut <路径>` | 输出候选清单 JSON（供 GUI 或你自己的脚本复用同一套判定） |

恢复脚本：`-Status` 看当前冻结了什么，`-DryRun` 干跑，`-Force` 忽略指纹校验，`-KeepJournal` 保留会话文件。

## 安全模型（四层保护 + 精确还原）

1. **`IsProcessCritical`** 判定系统关键进程后跳过。
   *已知局限*：该 API 对 `csrss/services/wininit` 返回 True，但对 `System`、`lsass` 返回 **False**，所以不能只靠它。
2. **名字黑名单**（硬编码，`config.json` 与参数**都无法解除**）：系统件 + **反作弊与杀毒**
   （Defender、腾讯 ACE、EAC、BattlEye、Vanguard、各类安全组件……）。
   挂起反作弊会导致游戏崩溃或封号；挂起杀毒属于 EDR 明确监控的恶意行为特征。
3. **自身进程链**：脚本的祖先链与自身后代绝不冻结。**终端家族**（cmd/powershell/conhost/WindowsTerminal 等）
   与 `explorer.exe` 默认也在保护名单内。
4. **冻结瞬间的前台全屏兜底**：拥有前台全屏窗口的进程强制排除，避免把正在跑的游戏冻住。

另外：

- **只恢复自己冻结过的进程**：`pid + 进程名 + 启动时间戳` 指纹校验，PID 被系统回收给别的进程时跳过。
- **精确快照**：冻结前读取优先级、内存优先级、EcoQoS 原值，恢复时按原值写回（实测可精确回到 `0x20/5/0`）。
- **默认不碰会话 0 的服务进程**（`skipSession0`）。
- 不写注册表、不改服务、不改电源计划、不改杀毒设置、**不联网**。

## 实测数据（示例机器）

测试机：Windows 11（build 26xxx）、16 逻辑处理器、15.3 GB 内存、NVMe SSD、PowerShell 5.1。

| 项目 | 结果 |
|---|---|
| `-Scope Safe` 干跑 | 146 进程 / 31 名字，工作集合计约 8–10 GB |
| 冻结 18 个目标 | **1.60 秒**（优化前 8.63 秒） |
| 恢复 18 个目标 | **1.08 秒**（优化前 3.30 秒） |
| 单进程成本 | **0.097 秒** |
| 冻结校验 | 线程挂起数 `susp=N/N`，3 秒 CPU 增量 0 ms |
| 内存基准（`tools/MemBalloon.cs`，2048 MB 脏页） | 工作集 2067 MB → **0 MB**；5 秒后可用物理内存 +1017 MB（约 50%），其余随系统空闲逐步回吐；页文件使用量 3.6 GB → 7.2 GB |

**重要预期管理**：界面与日志里的"预计回收 N MB"是**工作集估算**，不等于立刻腾出 N MB 物理内存 ——
脏页必须先写回页文件，释放是**异步、约一半即时可见**的。建议**在启动游戏之前**就执行冻结，
否则写回流量会和游戏加载抢磁盘。

## 已知限制

- **被冻结的可见窗口会假死/变灰**，恢复即正常；介意就用 `-Mode Idle` 或 `-SkipVisible`。
- **微信/同步盘**冻结期间不收消息、不同步（默认已放进 `idleByDefault` 只降 QoS 不冻结）。
- **Office/WPS** 冻结在自动保存中途可能丢最近编辑（同样默认走软模式）。
- **UWP / 商店应用**无法被挂起（Windows 限制）。
- 少数进程带有 `BYPASS_PROCESS_FREEZE` 线程，冻结后仍可能消耗少量 CPU —— 工具会**实测校验并如实报告**，必要时用 `-ReSuspend`。
- `NtSuspendProcess` 是原生 NT API（未在 Win32 层公开），按线程逐个挂起，**理论上有竞态**；恢复必须用同一族 API，不要与 `SuspendThread` 混用。
- 杀毒软件可能对"批量挂起进程"这种行为提高关注度（该手法历史上被恶意软件滥用过）。脚本明文、不碰安全组件、全程日志，如被拦截请自行加白。
- 冻结会占用页文件空间（脏页写回），磁盘可用空间过小时不建议大批量冻结。

## 排错

| 现象 | 处理 |
|---|---|
| 什么都不冻 | 先看 `-DryRun` 输出；Safe 范围只认白名单，改用 `-Scope Broad` 或把进程名加进 `config.json` |
| 提示"没有匹配到可暂停的进程" | 目标被保护（反作弊/杀毒/终端/宿主/会话 0）或名字写错 |
| 恢复后仍有挂起线程 | 用 `-Force` 再恢复一次；或直接重启（挂起状态不跨重启） |
| GUI 打不开 | 直接用 `.cmd`；确认 PowerShell 执行策略未被组策略限制（`-ExecutionPolicy Bypass` 已内置） |
| 想全部重来 | 删掉整个目录与桌面快捷方式即可，工具不留注册表痕迹 |

## 参与 / Contributing

这就是个**测试版**，最缺的就是真实反馈：

- 🐞 遇到 bug：请开 Issue，并附上 `-DryRun` 输出、`state\current.json`（可脱敏）与复现步骤。
- 💡 想要功能：也欢迎开 Issue，说明你的使用场景（例如某游戏/某软件被误冻结、某类进程漏冻）。
- 🔧 提交 PR：请保持"纯 PowerShell + 零依赖"这一约束，并在描述里附上你实测过的输出。

特别欢迎的报告类型：**误冻结了不该冻的进程**、**该冻的没冻**、**恢复不完整**、**在 Windows 10 / ARM64 / PS 7 上的表现**。

## 第三方与致谢

- 本项目**不打包**任何第三方二进制。文档中提到的同类工具（System Informer、Mem Reduct、SceneShift 等）请到各自官方仓库获取。
- API 常量与行为参考：Microsoft Learn（`SetProcessInformation`、`PROCESS_POWER_THROTTLING_STATE`、`MEMORY_PRIORITY_INFORMATION`、`EmptyWorkingSet`、进程访问权限）、
  Windows SDK 头文件（`processthreadsapi.h`）、以及 System Informer 的 phnt 原生 API 文档（NtDoc）。
- 感谢上述开源项目与文档作者；`NtSuspendProcess` 的注意事项（逐线程挂起竞态、忽略 `BYPASS_PROCESS_FREEZE` 线程）来自 phnt/NtDoc 的注释。

## License

MIT（见 [LICENSE](LICENSE)）。使用风险自负 —— 它会真实地挂起你的进程。
