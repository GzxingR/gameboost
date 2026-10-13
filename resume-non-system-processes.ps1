<#
  GameBoost · 恢复被暂停的非系统进程
  原则：只恢复「本工具冻结过的进程」。按 pid + 名字 + 启动时间戳(UtcTicks) 核对指纹；
        PID 被系统回收给别的进程时跳过（除非 -Force），绝不误恢复、绝不乱改别人的 QoS。
  注意：本文件须以 UTF-8 with BOM 保存。
#>
[CmdletBinding()]
param(
  [string]$StateFile,
  [switch]$Status, [switch]$DryRun, [switch]$Force, [switch]$Quiet, [switch]$KeepJournal, [switch]$Yes,
  [int]$MaxMinutes = 0, [string]$WaitProcessExit
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

if (-not ('GB2' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class GB2 {
  const uint M_FULL = 0x0F00, M_SUSP = 0x1800;
  [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetProcessInformation(IntPtr h, int c, IntPtr b, int s);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr h, int c, IntPtr b, int s);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetPriorityClass(IntPtr h, uint c);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetPriorityClass(IntPtr h);
  static IntPtr Open(int pid) { IntPtr h = OpenProcess(M_FULL, false, pid); if (h == IntPtr.Zero) h = OpenProcess(M_SUSP, false, pid); return h; }
  static bool SetMem(IntPtr h, int v) { IntPtr b = Marshal.AllocHGlobal(4); try { Marshal.WriteInt32(b, v); return SetProcessInformation(h, 0, b, 4); } finally { Marshal.FreeHGlobal(b); } }
  static bool SetEco(IntPtr h, bool on) { IntPtr b = Marshal.AllocHGlobal(12); try { Marshal.WriteInt32(b, 1); Marshal.WriteInt32(b, 4, 1); Marshal.WriteInt32(b, 8, on ? 1 : 0); return SetProcessInformation(h, 4, b, 12); } finally { Marshal.FreeHGlobal(b); } }
  public static string Resume(int pid, int count) {
    IntPtr h = Open(pid); if (h == IntPtr.Zero) return "E" + Marshal.GetLastWin32Error();
    try { int last = 0; for (int i = 0; i < count; i++) last = NtResumeProcess(h); return last == 0 ? "OK" : "NT" + last.ToString("X8"); }
    finally { CloseHandle(h); }
  }
  public static string Restore(int pid, int prio, int mem, int eco) {
    IntPtr h = Open(pid); if (h == IntPtr.Zero) return "E" + Marshal.GetLastWin32Error();
    try { if (prio > 0) SetPriorityClass(h, (uint)prio); if (mem > 0) SetMem(h, mem); if (eco >= 0) SetEco(h, eco == 1); return "OK"; }
    finally { CloseHandle(h); }
  }
  public static string Query(int pid) {
    IntPtr h = Open(pid); if (h == IntPtr.Zero) return "E" + Marshal.GetLastWin32Error();
    try { return ((int)GetPriorityClass(h)) + "|" + (GetEco(h)); } finally { CloseHandle(h); }
  }
  static int GetEco(IntPtr h) { IntPtr b = Marshal.AllocHGlobal(12); try { Marshal.WriteInt32(b, 1); Marshal.WriteInt32(b, 4, 0); Marshal.WriteInt32(b, 8, 0);
      if (GetProcessInformation(h, 4, b, 12)) return (Marshal.ReadInt32(b, 8) & 1); return -1; } finally { Marshal.FreeHGlobal(b); } }
}
'@
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $StateFile) { $StateFile = Join-Path (Join-Path $Root 'state') 'current.json' }
$HistDir = Join-Path $Root 'history'
if (-not (Test-Path $HistDir)) { New-Item -ItemType Directory $HistDir -Force | Out-Null }
$LogDir = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir ('resume-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
function Log([string]$m, [string]$c = 'Gray') {
  if (-not $Quiet -or $c -eq 'Red' -or $c -eq 'Yellow') { Write-Host $m -ForegroundColor $c }
  try { Add-Content -Path $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) -Encoding UTF8 } catch { }
}
$script:fastBuf = New-Object System.Collections.Generic.List[string]
function LogFast([string]$m, [string]$c = 'Gray') {
  if (-not $Quiet -or $c -eq 'Red' -or $c -eq 'Yellow') { Write-Host $m -ForegroundColor $c }
  $script:fastBuf.Add((Get-Date -Format 'HH:mm:ss') + '  ' + $m)
  if ($script:fastBuf.Count -ge 40) { try { Add-Content -Path $LogFile -Value $script:fastBuf.ToArray() -Encoding UTF8 } catch { }; $script:fastBuf.Clear() }
}
function FlushFast { if ($script:fastBuf.Count -gt 0) { try { Add-Content -Path $LogFile -Value $script:fastBuf.ToArray() -Encoding UTF8 } catch { }; $script:fastBuf.Clear() } }

# ---------------------------------------------------- 自动恢复等待（由 pause 以隐藏进程派发）
if ($MaxMinutes -gt 0 -or $WaitProcessExit) {
  $deadline = $null
  if ($MaxMinutes -gt 0) { $deadline = (Get-Date).AddMinutes($MaxMinutes) }
  if ($WaitProcessExit) {
    # 阶段1：等目标出现（最多 60 分钟）——支持“先挂起，之后才启动游戏”的用法
    $appearDeadline = (Get-Date).AddMinutes(60)
    while (-not (Get-Process -Name $WaitProcessExit -ErrorAction SilentlyContinue)) {
      if ((Get-Date) -ge $appearDeadline) { break }
      if ($deadline -and (Get-Date) -ge $deadline) { break }
      Start-Sleep -Seconds 5
    }
    # 阶段2：锁定此刻存在的那批 PID，等它们全部退出
    # （按名字判断会被同名无关进程卡死——实测机器上常驻 6 个 cmd.exe 就会永不恢复）
    $watchPids = @(Get-Process -Name $WaitProcessExit -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
    Log ('守护：监控 ' + $WaitProcessExit + ' 的 PID [' + ($watchPids -join ',') + ']，全部退出后恢复') 'Cyan'
    while ($true) {
      if ($watchPids.Count -eq 0) { Log ('守护：60 分钟内未见 ' + $WaitProcessExit + '，改为按超时恢复') 'Yellow'; break }
      $alive = @($watchPids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
      if ($alive.Count -eq 0) { Log ('目标进程 ' + $WaitProcessExit + ' 已退出，开始恢复') 'Cyan'; break }
      if ($deadline -and (Get-Date) -ge $deadline) { Log ($MaxMinutes.ToString() + ' 分钟已到，开始恢复') 'Cyan'; break }
      Start-Sleep -Seconds 5
    }
  } else {
    while ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    Log ($MaxMinutes.ToString() + ' 分钟已到，开始恢复') 'Cyan'
  }
}

if (-not (Test-Path $StateFile)) { Log ('没有待恢复的会话（' + $StateFile + ' 不存在）') 'Yellow'; exit 0 }
try { $doc = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Log ('会话文件损坏，未做任何改动：' + $_.Exception.Message) 'Red'; exit 1 }
$entries = @($doc.entries)
if ($entries.Count -eq 0) { Log '会话文件为空，无可恢复项。' 'Yellow'; exit 0 }

# ---------------------------------------------------- 指纹校验
$plan = @()
foreach ($e in $entries) {
  $live = Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue
  $state = 'OK'; $target = $live
  if (-not $live) {
    $cand = @()
    try { $cand = @(Get-Process -Name $e.name -ErrorAction SilentlyContinue | Where-Object { $_.StartTime.ToUniversalTime().Ticks -eq [long]$e.startUtcTicks }) } catch { }
    if ($cand.Count -eq 1) { $target = $cand[0]; $state = 'Relocated' } else { $state = 'NotRunning'; $target = $null }
  }
  elseif ([string]$live.ProcessName -ne [string]$e.name) { if ($Force) { $state = 'Forced' } else { $state = 'PidReused'; $target = $null } }
  elseif ([long]$e.startUtcTicks -gt 0) {
    $same = $false
    try { $same = ($live.StartTime.ToUniversalTime().Ticks -eq [long]$e.startUtcTicks) } catch { $same = $true }
    if (-not $same) { if ($Force) { $state = 'Forced' } else { $state = 'PidReused'; $target = $null } }
  }
  $susp = 0; $tot = 0; $ws = 0
  if ($target) {
    try { $tot = @($target.Threads).Count; $susp = @($target.Threads | Where-Object { $_.ThreadState -eq 'Wait' -and $_.WaitReason -eq 'Suspended' }).Count } catch { }
    try { $ws = [math]::Round($target.WorkingSet64 / 1MB, 0) } catch { }
  }
  $plan += [pscustomobject]@{ E = $e; T = $target; S = $state; Susp = $susp; Tot = $tot; Ws = $ws }
}

# ---------------------------------------------------- 状态 / 干跑
if ($Status) {
  Log ('会话 ' + $doc.startedUtc + '  [Scope=' + $doc.scope + ' Mode=' + $doc.mode + ']  共 ' + $plan.Count + ' 条') 'Cyan'
  foreach ($i in $plan) {
    $frozen = '否'
    if ($i.Susp -gt 0) { $frozen = ('是(' + $i.Susp + '/' + $i.Tot + ')') }
    Log ('{0,-11} {1,-26} pid {2,-7} 已冻结 {3,-10} 模式 {4,-8} {5} MB' -f $i.S, $i.E.name, $i.E.pid, $frozen, $i.E.mode, $i.Ws)
  }
  exit 0
}
if ($DryRun) { foreach ($i in $plan) { Log ('将要恢复 {0} pid {1}（{2}，mode={3}）' -f $i.E.name, $i.E.pid, $i.S, $i.E.mode) }; exit 0 }
if (-not $Yes) {
  $a = Read-Host ('将恢复 ' + $plan.Count + ' 条记录，确认？输入 Y 继续')
  if ($a -notmatch '^[Yy]') { Log '已取消。'; exit 0 }
}

# ---------------------------------------------------- 执行恢复
$ok = 0; $skip = 0; $fail = 0; $stuck = @()
$res = New-Object System.Collections.Generic.List[object]
foreach ($i in $plan) {
  $e = $i.E
  if ($i.S -eq 'NotRunning' -or $i.S -eq 'PidReused' -or -not $i.T) { LogFast ('   跳过 {0}（{1}）' -f $e.name, $i.S) 'DarkGray'; $skip++; continue }
  $r = 'OK'
  if ($e.mode -eq 'Suspend' -and [int]$e.suspendCount -gt 0) {
    $r = [GB2]::Resume([int]$i.T.Id, [int]$e.suspendCount)
    if ($r -eq 'OK') {
      $rc = [GB2]::Restore([int]$i.T.Id, [int]$e.origPrio, [int]$e.origMem, [int]$e.origEco)
      if ($rc -notlike 'OK') { LogFast ('   还原 QoS 失败 {0} -> {1}' -f $e.name, $rc) 'Yellow' }
    }
  }
  elseif ($e.mode -eq 'Boost') {
    if ([int]$e.origPrio -gt 0) { $r = [GB2]::Restore([int]$i.T.Id, [int]$e.origPrio, -1, -1) }
  }
  else { $r = [GB2]::Restore([int]$i.T.Id, [int]$e.origPrio, [int]$e.origMem, [int]$e.origEco) }
  [void]$res.Add([pscustomobject]@{ E = $e; T = $i.T; R = $r })
}
# 性能关键：原实现每条都 Start-Sleep 120ms + 每条 Get-Process，N 条就要 N×0.12 秒；
# 现在改为「全部恢复 → 只等一次 150ms → 只快照一次」。
$snap = @{}
if ($res.Count -gt 0) {
  Start-Sleep -Milliseconds 150
  foreach ($q in @(Get-Process -ErrorAction SilentlyContinue)) { $snap[[int]$q.Id] = $q }
}
foreach ($x in $res) {
  $e = $x.E; $tid = [int]$x.T.Id
  if ($x.R -eq 'OK') {
    $still = 0
    if ($snap.ContainsKey($tid)) { try { $still = @($snap[$tid].Threads | Where-Object { $_.ThreadState -eq 'Wait' -and $_.WaitReason -eq 'Suspended' }).Count } catch { } }
    if ($still -gt 0) { $stuck += ($e.name + '(pid ' + $tid + ')'); LogFast ('   警告 {0} pid {1} 仍有 {2} 个线程处于 Suspended，请手动确认' -f $e.name, $tid, $still) 'Yellow' }
    else { LogFast ('   已恢复 {0,-26} pid {1}' -f $e.name, $tid) 'Green' }
    $ok++
  } else { LogFast ('   失败 {0} pid {1} -> {2}' -f $e.name, $tid, $x.R) 'Red'; $fail++ }
}
FlushFast

# ---------------------------------------------------- 归档
if (-not $KeepJournal) {
  $arch = Join-Path $HistDir ('resumed-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
  Copy-Item $StateFile $arch -Force
  Remove-Item $StateFile -Force
  Log ('会话日志已归档：' + $arch) 'Cyan'
}
$tail = ''
if ($stuck.Count -gt 0) { $tail = '；仍有挂起线程：' + ($stuck -join ', ') }
Log ('完成：恢复 ' + $ok + ' / 跳过 ' + $skip + ' / 失败 ' + $fail + $tail) 'Cyan'
