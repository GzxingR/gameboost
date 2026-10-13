# 技术细节 / Technical Notes

本文记录实现依据、验证方法与开发中踩到的坑，供审查与二次开发使用。

## 1. 冻结与恢复

| 用途 | API | 说明 |
|---|---|---|
| 冻结 | `ntdll!NtSuspendProcess(handle)` | 原生 NT API，按线程逐个挂起；需句柄具备 `PROCESS_SUSPEND_RESUME (0x0800)` |
| 恢复 | `ntdll!NtResumeProcess(handle)` | 与挂起**成对使用**，日志记录挂起计数（挂 2 次必须恢复 2 次） |
| 回收工作集 | `psapi!EmptyWorkingSet(handle)` | 需 `PROCESS_QUERY_INFORMATION (0x0400)` + `PROCESS_SET_QUOTA (0x0100)` |
| 关键进程判定 | `kernel32!IsProcessCritical(handle, &bool)` | 需 `PROCESS_QUERY_LIMITED_INFORMATION (0x1000)` |
| 读取状态 | `kernel32!GetProcessInformation` | `ProcessMemoryPriority = 0`、`ProcessPowerThrottling = 4` |
| 写入状态 | `kernel32!SetProcessInformation` | 需 `PROCESS_SET_INFORMATION (0x0200)` |
| 优先级 | `GetPriorityClass` / `SetPriorityClass` | IDLE `0x40`、NORMAL `0x20`、HIGH `0x80` |

**句柄权限掩码**：一次拿到 `0x0800|0x0400|0x0200|0x0100`（0x0F00）；失败时降级为 `0x0800|0x1000`（0x1800）。
实测受保护进程（例如装有篡改防护的杀毒主进程）在前者返回 **err=5**、后者却可成功 —— 所以必须做降级重试，
**并且在降级后跳过需要写权限的操作（如工作集回收），否则会得到"假成功"。**

### 常量来源（避免抄错）

```
Windows SDK 10.0.16299 processthreadsapi.h:
    typedef enum _PROCESS_INFORMATION_CLASS {
        ProcessMemoryPriority,        // 0
        ProcessMemoryExhaustionInfo,  // 1
        ProcessAppMemoryInfo,         // 2
        ProcessInPrivateInfo,         // 3
        ProcessPowerThrottling,       // 4
        ProcessReservedValue1, ProcessTelemetryCoverageInfo, ProcessProtectionLevelInfo, ...
    } PROCESS_INFORMATION_CLASS;
    #define PROCESS_POWER_THROTTLING_CURRENT_VERSION 1
    #define PROCESS_POWER_THROTTLING_EXECUTION_SPEED 0x1
    typedef struct _PROCESS_POWER_THROTTLING_STATE { ULONG Version; ULONG ControlMask; ULONG StateMask; }
    typedef struct _MEMORY_PRIORITY_INFORMATION   { ULONG MemoryPriority; }
```

`MEMORY_PRIORITY_*`（微软文档）：`VERY_LOW=1, LOW=2, MEDIUM=3, BELOW_NORMAL=4, NORMAL=5`。
文档明确：内存优先级是**内存管理器回收工作集时的提示**，其它条件相同时优先级低的页先被回收 —— 这正是 `-Mode Idle` 的理论依据。

## 2. 为什么"冻结后立刻回收工作集"

被冻结的进程不会再触碰自己的页面，此时 `EmptyWorkingSet` 把它们移出工作集后，
内存管理器可以把这些物理页交出来（脏匿名页需先写回页文件）。
若不冻结就直接回收，进程会立刻把页重新读回，几乎白做。

### 但释放是异步的（实测）

| 观测 | 数值 |
|---|---|
| 合成进程工作集 | 2067 MB |
| 冻结 + `EmptyWorkingSet` 后工作集 | 0 MB |
| 5 秒后可用物理内存净增 | +1017 MB（约 50%） |
| 15 / 30 / 60 / 90 秒后 | +887 / +877 / +572 / +1268 MB（被系统自身活动淹没，有波动） |
| 页文件使用量 | +3.6 GB（脏页写回的直接证据） |

**结论**：工作集清零是确定的；物理内存释放约一半即时可见，其余取决于页文件写入速度与系统负载。
因此文档与界面统一表述为"工作集估算"，不承诺"立刻腾出 N GB"。

## 3. 校验方法（工具自己怎么知道冻住了）

1. **线程状态**：挂起后统计 `ThreadState = Wait` 且 `WaitReason = Suspended` 的线程数，报告为 `susp=N/M`。
2. **CPU 增量**：冻结前后各取一次 `TotalProcessorTime`，若 400 ms 内增量超过 20 ms，则判定"仍有活动线程"。
   这是针对 `THREAD_CREATE_FLAGS_BYPASS_PROCESS_FREEZE` 线程的必要检查 —— phnt/NtDoc 明确说明
   `NtSuspendProcess` **会忽略**这类线程。

## 4. 性能：从"逐个等待"到"流水线"

原实现每冻结一个进程就 `Start-Sleep 400ms` 做校验，N 个目标付 N 次等待；日志每条 `Add-Content` 都要开关文件。

改为：**读快照 → 批量下发 → 只等一次 → 只快照一次 → 批量写日志**；恢复端同样去掉逐条 120 ms 等待。

| 指标 | 优化前 | 优化后 |
|---|---|---|
| 冻结 18 个目标 | 8.63 秒 | 1.60 秒 |
| 恢复 18 个目标 | 3.30 秒 | 1.08 秒 |
| 单进程成本 | 0.48 秒 | 0.097 秒 |

## 5. 开发中踩到的坑（都已在代码里修掉）

1. **`@($array) + @($genericList)` 会抛 `Argument types do not match`**（PS 5.1），连带冻结子进程时整体失效。
   修法：`[object[]]($a) + [object[]]($b.ToArray())`。
2. **把 `"a","b"` 作为参数传给子进程时，PS 5.1 会转义内层引号**，子进程收到的是一整条带引号字符串，
   导致 `-Only` 匹配不到任何名字（GUI 多选静默失效）。修法：新增 `-NamesFile`，用文件传名单。
3. **`ItemCheck` 事件在控件句柄未创建时不会触发**，受保护行可被程序化勾选。
   修法：加确定性取消逻辑 + 引擎侧 `Get-CheckedNames` 二次过滤（双保险）。
4. **把"祖先的所有后代"当作自家进程**会导致 explorer 之下整个用户会话被保护，
   浏览器这类内存大户被漏掉。修法：只保护「祖先链」与「祖先链经过本进程」的真正后代。
5. **守护进程按进程名判断目标是否退出**会被同名常驻进程卡死（例如系统里常有多个 `cmd.exe`）。
   修法：先等目标出现 → 锁定当时那批 PID → 全部退出才恢复。
6. **PowerShell 5.1 读取无 BOM 的 UTF-8 脚本会把中文按 ANSI 解析并报语法错**。
   本项目所有 `.ps1` / `.json` 一律 **UTF-8 with BOM**。
7. **`Add-Type` 在 PS 5.1 上使用 C# 5 编译器**：不能用 `$"..."`、表达式体成员、`nameof` 等新语法
   （源码已按 C# 5 编写）。
8. **用 powershell 进程做基准会静默失败**：脚本默认保护终端家族，基准目标被正确拦下但看起来"什么都没发生"。
   修法：基准工具命名为 `gbmemballoon`（见 `tools/MemBalloon.cs`）。

## 6. 未做 / 不打算做的事

- **不碰服务**：会话 0 服务进程默认整体排除。停服务属于另一类风险操作，且实测多数优化教程里的服务项目
  在现代 Windows 上已被系统自身管理，收益存疑。
- **不碰电源计划与注册表**：收益与风险不成比例，且不可解释、不好回滚。
- **不碰杀毒设置**：给游戏目录加排除项应当由用户自己决定（文档给出命令，工具不代劳）。
- **不做 CPU 亲和性收拢**：在多 CCD/多 CCX 的机器上收益与风险都很依赖具体硬件与游戏，暂不纳入默认行为。
