<#
  GameBoost · 游戏前暂停非系统进程
  机制：NtSuspendProcess 冻结全部线程 + EmptyWorkingSet 回收工作集；-Mode Idle 则只降 QoS（零风险可逆）
  安全：四层保护 = IsProcessCritical(查询) + 名字黑名单(反作弊/杀软/系统件,参数不可覆盖) + 自身进程链 + 前台全屏兜底
  恢复：必须用 resume-non-system-processes.ps1（指纹与原始状态记录在 state\current.json）
  注意：本文件须以 UTF-8 with BOM 保存，否则 PowerShell 5.1 会把中文按 ANSI 解析并报语法错误。
#>
[CmdletBinding()]
param(
  [ValidateSet('Safe','Broad','All')][string]$Scope = 'Safe',
  [ValidateSet('Suspend','Idle')][string]$Mode  = 'Suspend',
  [string[]]$Only, [string[]]$Exclude, [string]$Game, [string]$BoostGame,
  [switch]$IncludeAgent, [switch]$IncludeShell, [switch]$SkipVisible,
  [switch]$NoChildren, [switch]$NoTrim, [switch]$ReSuspend,
  [int]$AutoResumeMinutes = 0, [string]$ResumeWhenProcessExits,
  [switch]$DryRun, [switch]$Yes, [switch]$Quiet, [switch]$DefenderHint,
  [switch]$EmitJson, [string]$JsonOut, [string]$NamesFile
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------- 1. 原生 API
# 常量来源：Windows SDK 10.0.16299 processthreadsapi.h + 本机实测
#   ProcessMemoryPriority = 0, ProcessPowerThrottling = 4
#   PROCESS_POWER_THROTTLING_CURRENT_VERSION = 1, PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x1
#   MEMORY_PRIORITY_VERY_LOW = 1 ... MEMORY_PRIORITY_NORMAL = 5
#   PROCESS_SUSPEND_RESUME=0x0800 QUERY_INFORMATION=0x0400 SET_INFORMATION=0x0200 SET_QUOTA=0x0100 QUERY_LIMITED_INFORMATION=0x1000
if (-not ('GB' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class GB {
  const uint M_FULL = 0x0F00;  // SUSPEND_RESUME|QUERY_INFORMATION|SET_INFORMATION|SET_QUOTA（冻结+回收工作集所需）
  const uint M_SUSP = 0x1800;  // SUSPEND_RESUME|QUERY_LIMITED_INFORMATION（受保护进程只能给这些）
  const int  CLS_MEMPRIO = 0;
  const int  CLS_POWER   = 4;
  const uint PRIO_IDLE   = 0x40, PRIO_HIGH = 0x80;

  [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
  [DllImport("psapi.dll", SetLastError=true)] static extern bool EmptyWorkingSet(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessCritical(IntPtr h, out bool c);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr h, int c, IntPtr b, int s);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetProcessInformation(IntPtr h, int c, IntPtr b, int s);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetPriorityClass(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetPriorityClass(IntPtr h, uint c);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w, out uint p);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr w, out RECT r);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
  delegate bool EnumProc(IntPtr w, IntPtr l);
  public struct RECT { public int L; public int T; public int R; public int B; }

  static IntPtr Open(int pid, out uint used, out int err) {
    IntPtr h = OpenProcess(M_FULL, false, pid); used = M_FULL; err = 0;
    if (h == IntPtr.Zero) { err = Marshal.GetLastWin32Error(); h = OpenProcess(M_SUSP, false, pid); used = M_SUSP; }
    if (h == IntPtr.Zero) err = Marshal.GetLastWin32Error();
    return h;
  }
  static int GetMem(IntPtr h) { IntPtr b = Marshal.AllocHGlobal(4); try { Marshal.WriteInt32(b, -1);
      if (GetProcessInformation(h, CLS_MEMPRIO, b, 4)) return Marshal.ReadInt32(b); return -1; } finally { Marshal.FreeHGlobal(b); } }
  static bool SetMem(IntPtr h, int v) { IntPtr b = Marshal.AllocHGlobal(4); try { Marshal.WriteInt32(b, v);
      return SetProcessInformation(h, CLS_MEMPRIO, b, 4); } finally { Marshal.FreeHGlobal(b); } }
  static int GetEco(IntPtr h) { IntPtr b = Marshal.AllocHGlobal(12); try { Marshal.WriteInt32(b, 1); Marshal.WriteInt32(b, 4, 0); Marshal.WriteInt32(b, 8, 0);
      if (GetProcessInformation(h, CLS_POWER, b, 12)) return (Marshal.ReadInt32(b, 8) & 1); return -1; } finally { Marshal.FreeHGlobal(b); } }
  static bool SetEco(IntPtr h, bool on) { IntPtr b = Marshal.AllocHGlobal(12); try { Marshal.WriteInt32(b, 1); Marshal.WriteInt32(b, 4, 1); Marshal.WriteInt32(b, 8, on ? 1 : 0);
      return SetProcessInformation(h, CLS_POWER, b, 12); } finally { Marshal.FreeHGlobal(b); } }

  // 返回 "OK|origPrio|origMem|origEco|suspendCount|trimmed|mask" 或 "E<win32err>" / "NT<ntstatus>"
  public static string Suspend(int pid, bool trim, bool eco, int memPrio) {
    uint used; int err; IntPtr h = Open(pid, out used, out err);
    if (h == IntPtr.Zero) return "E" + err;
    try {
      int op = (int)GetPriorityClass(h), om = GetMem(h), oe = GetEco(h);
      SetMem(h, memPrio);
      if (eco) SetEco(h, true);
      int st = NtSuspendProcess(h);
      if (st != 0) return "NT" + st.ToString("X8");
      bool trimmed = false;
      if (trim && used == M_FULL) trimmed = EmptyWorkingSet(h);
      return "OK|" + op + "|" + om + "|" + oe + "|1|" + (trimmed ? 1 : 0) + "|" + (used == M_FULL ? "full" : "susp");
    } finally { CloseHandle(h); }
  }
  // 只降 QoS，不冻结
  public static string Idle(int pid, bool eco, int memPrio) {
    uint used; int err; IntPtr h = Open(pid, out used, out err);
    if (h == IntPtr.Zero) return "E" + err;
    try {
      int op = (int)GetPriorityClass(h), om = GetMem(h), oe = GetEco(h);
      SetPriorityClass(h, PRIO_IDLE); SetMem(h, memPrio); if (eco) SetEco(h, true);
      return "OK|" + op + "|" + om + "|" + oe + "|0|0|" + (used == M_FULL ? "full" : "susp");
    } finally { CloseHandle(h); }
  }
  public static string Query(int pid) {
    uint used; int err; IntPtr h = Open(pid, out used, out err);
    if (h == IntPtr.Zero) return "E" + err;
    try { return ((int)GetPriorityClass(h)) + "|" + GetMem(h) + "|" + GetEco(h); } finally { CloseHandle(h); }
  }
  public static string Critical(int pid) {
    uint used; int err; IntPtr h = Open(pid, out used, out err);
    if (h == IntPtr.Zero) return "E" + err;
    try { bool c; if (!IsProcessCritical(h, out c)) return "E" + Marshal.GetLastWin32Error(); return c ? "T" : "F"; }
    finally { CloseHandle(h); }
  }
  public static void Boost(int pid) {
    uint used; int err; IntPtr h = Open(pid, out used, out err);
    if (h == IntPtr.Zero) return;
    try { SetPriorityClass(h, PRIO_HIGH); SetEco(h, false); } finally { CloseHandle(h); }
  }
  public static int FgFullscreenPid() {
    IntPtr w = GetForegroundWindow(); if (w == IntPtr.Zero) return 0;
    RECT r; if (!GetWindowRect(w, out r)) return 0;
    int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
    if ((r.R - r.L) >= sw && (r.B - r.T) >= sh && r.L <= 0 && r.T <= 0) { uint p; GetWindowThreadProcessId(w, out p); return (int)p; }
    return 0;
  }
  public static string VisiblePids() {
    StringBuilder sb = new StringBuilder();
    EnumWindows(delegate(IntPtr w, IntPtr l) {
      if (IsWindowVisible(w)) { RECT r; if (GetWindowRect(w, out r) && (r.R - r.L) > 8 && (r.B - r.T) > 8) {
        uint p; GetWindowThreadProcessId(w, out p); if (p != 0) sb.Append(p).Append(","); } }
      return true;
    }, IntPtr.Zero);
    return sb.ToString();
  }
}
'@
}

# ---------------------------------------------------------------- 2. 路径与日志
$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateDir = Join-Path $Root 'state'; $LogDir = Join-Path $Root 'logs'; $HistDir = Join-Path $Root 'history'
foreach ($d in @($StateDir, $LogDir, $HistDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null } }
$StateFile = Join-Path $StateDir 'current.json'
$LogFile   = Join-Path $LogDir ('pause-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
function Log([string]$m, [string]$c = 'Gray') { if (-not $Quiet) { Write-Host $m -ForegroundColor $c }; Add-Content -Path $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) -Encoding UTF8 }
function Fail([string]$m) { Log $m 'Red'; exit 1 }
# 高频路径用的缓冲写日志：逐条 Add-Content 每次都要开关文件，批量冻结时是主要开销之一
$script:fastBuf = New-Object System.Collections.Generic.List[string]
function LogFast([string]$m, [string]$c = 'Gray') {
  if (-not $Quiet) { Write-Host $m -ForegroundColor $c }
  $script:fastBuf.Add((Get-Date -Format 'HH:mm:ss') + '  ' + $m)
  if ($script:fastBuf.Count -ge 40) { Add-Content -Path $LogFile -Value $script:fastBuf.ToArray() -Encoding UTF8; $script:fastBuf.Clear() }
}
function FlushFast { if ($script:fastBuf.Count -gt 0) { Add-Content -Path $LogFile -Value $script:fastBuf.ToArray() -Encoding UTF8; $script:fastBuf.Clear() } }

$cfg = @{ protectShells = $true; safeTargets = @(); idleByDefault = @() }
$cfgPath = Join-Path $Root 'config.json'
if (Test-Path $cfgPath) { try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Fail ('config.json 解析失败: ' + $_.Exception.Message) } }
# 从文件读取目标名单（避开 PS 5.1 向原生进程传数组时的引号转义坑：GUI 多选会因此失败）
if ($NamesFile) {
  if (-not (Test-Path $NamesFile)) { Fail ('名单文件不存在: ' + $NamesFile) }
  $fromFile = @(Get-Content $NamesFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
  if ($Only) { $Only += $fromFile } else { $Only = $fromFile }
  Log ('从名单文件读入 ' + $fromFile.Count + ' 个目标名: ' + ($fromFile -join ', ')) 'Cyan'
}

# ---------------------------------------------------------------- 3. 保护名单
# 反作弊/杀软/系统件为硬编码，任何参数都无法解除
$Protected = @(
  'System','Idle','Registry','Secure System','Memory Compression','smss','csrss','wininit','winlogon','services',
  'lsass','lsaiso','dwm','audiodg','fontdrvhost','svchost','WmiPrvSE','WmiApSrv','unsecapp','Locator',
  'vmms','vmcompute','vmnat','vmnetdhcp','wslservice','WUDFHost','WUDFCompanionHost',
  'taskhostw','sihost','ShellHost','ShellExperienceHost','StartMenuExperienceHost','SearchHost','TextInputHost',
  'RuntimeBroker','ctfmon','ChsIME','TabTip','AppActions','CrossDeviceResume',
  'nvcontainer','NVDisplay.Container','RtkAudUService64','RtkBtManServ','amdfendrsr','amdpmfservice','amdpmfserviceuser',
  'AmdPpkgSvc','atieclxx','atiesrxx','FnHotkeyCapsLKNumLK','FnHotkeyUtility','LnvSvcFdn','LenovoUtilityService',
  'MsMpEng','NisSrv','SecurityHealthService','SecurityHealthSystray','MpDefenderCoreService','DefenderSessionHelper',
  'ACE-Tray','ACE-Guard','SGuard','SGuard64','EACefSubProcess','EABackgroundService','EasyAntiCheat','BEService',
  'vgc','vgtray','LAVService','usysdiag','wsctrl11'
)
if ($cfg.protectShells -and -not $IncludeShell) { $Protected += @('conhost','OpenConsole','WindowsTerminal','cmd','powershell','pwsh','wscript','cscript') }
if (-not $IncludeShell) { $Protected += @('explorer') }
if ($Exclude) { $Protected += $Exclude }
if ($Game)    { $Protected += $Game }
if (-not $IncludeAgent -and $cfg.hostProtected) { $Protected += @($cfg.hostProtected) }   # 宿主/编辑器名单由 config.json 的 hostProtected 提供

# 自身进程链：祖先链（终端/宿主）+ 真正的自家后代，绝不触碰
# 关键：不能把「祖先的所有后代」都算进来——explorer 之下是整个用户会话，那样会漏掉浏览器等内存大头
$selfSet = New-Object 'System.Collections.Generic.HashSet[int]'
$map = @{}
try {
  $allProc = Get-CimInstance -ClassName Win32_Process -Filter 'ProcessId > 0' -Property ProcessId, ParentProcessId
  foreach ($p in $allProc) { $map[[int]$p.ProcessId] = [int]$p.ParentProcessId }
  $cur = [int]$PID
  while ($cur -gt 0 -and $selfSet.Add($cur)) { $cur = [int]$map[$cur] }
  foreach ($k in @($map.Keys)) {
    $c = [int]$k; $hops = 0
    while ($c -gt 0 -and $hops -lt 64) {
      if ($c -eq [int]$PID) { [void]$selfSet.Add([int]$k); break }
      $c = [int]$map[$c]; $hops++
    }
  }
} catch { Log ('警告：无法构建进程树(' + $_.Exception.Message + ')，退回仅按名字保护') 'Yellow' }

# ---------------------------------------------------------------- 4. 候选筛选
$fgPid = [GB]::FgFullscreenPid()
if ($fgPid -gt 0) { Log ('兜底：前台全屏窗口属 pid ' + $fgPid + '，强制排除') 'Yellow' }
$visPids = @()
if ($SkipVisible) { $visPids = @(([GB]::VisiblePids() -split ',') | Where-Object { $_ } | ForEach-Object { [int]$_ }) }

$isProtected = {
  param($p)
  if ($Protected -contains $p.ProcessName) { return $true }
  if ($selfSet.Contains([int]$p.Id)) { return $true }
  if ($p.Id -le 4) { return $true }
  if ($cfg.skipSession0 -ne $false -and $p.SessionId -eq 0) { return $true }   # 默认不碰会话0(服务)；可在 config.json 改 skipSession0
  if ($fgPid -gt 0 -and $p.Id -eq $fgPid) { return $true }
  if ($visPids -contains [int]$p.Id) { return $true }
  return $false
}
$matchesScope = {
  param($p)
  if ($Only) { return ($Only -contains $p.ProcessName) }
  if ($Scope -eq 'Safe') { foreach ($pat in $cfg.safeTargets) { if ($p.ProcessName -like $pat) { return $true } } return $false }
  return ($p.SessionId -gt 0)   # Broad/All：只取用户会话，绝不碰会话 0 的服务
}

$allProc = @(Get-Process -ErrorAction SilentlyContinue)
$roots   = @($allProc | Where-Object { (& $matchesScope $_) -and -not (& $isProtected $_) })
$targets = $roots

if (-not $NoChildren -and $map.Count -gt 0) {
  try {
    $kids = @{}
    foreach ($kv in $map.GetEnumerator()) {
      if (-not $kids.ContainsKey([int]$kv.Value)) { $kids[[int]$kv.Value] = New-Object 'System.Collections.Generic.List[int]' }
      $kids[[int]$kv.Value].Add([int]$kv.Key)
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($r in $roots) { [void]$seen.Add([int]$r.Id) }
    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    foreach ($r in $roots) { $queue.Enqueue([int]$r.Id) }
    $extra = New-Object 'System.Collections.Generic.List[object]'
    while ($queue.Count -gt 0) {
      $id = [int]$queue.Dequeue()
      if (-not $kids.ContainsKey($id)) { continue }
      foreach ($cidRaw in $kids[$id]) {
        $cid = [int]$cidRaw
        if ($seen.Contains($cid)) { continue }
        [void]$seen.Add($cid)
        $cp = @($allProc | Where-Object { $_.Id -eq $cid })
        if ($cp.Count -gt 0 -and -not (& $isProtected $cp[0])) { $extra.Add($cp[0]); $queue.Enqueue($cid) }
      }
    }
    $targets = [object[]]($roots) + [object[]]($extra.ToArray())
  } catch { Log ('警告：子进程展开失败，仅处理匹配进程(' + $_.Exception.Message + ' | line=' + [string]$_.InvocationInfo.ScriptLineNumber + ')') 'Yellow' }
}
$targets = @($targets | Sort-Object ProcessName, Id -Unique)
if ($targets.Count -eq 0) { Log ('没有匹配到可暂停的进程（Scope=' + $Scope + '）') 'Yellow'; exit 0 }

$useIdle = { param($name) ($Mode -eq 'Idle') -or (($Mode -eq 'Suspend') -and ($cfg.idleByDefault -contains $name)) }

# ---------------------------------------------------------------- 5. 预览
$grouped = @($targets | Group-Object ProcessName | ForEach-Object {
  $ws = 0.0; foreach ($p in $_.Group) { $ws += $p.WorkingSet64 }
  [pscustomobject]@{ Name = $_.Name; N = $_.Count; WS = [math]::Round($ws / 1MB, 0) }
} | Sort-Object WS -Descending)
$totalWS = ($grouped | Measure-Object WS -Sum).Sum
# ---- GUI 用：输出候选清单 JSON（复用同一套保护/范围判定，避免两份名单漂移） ----
if ($EmitJson) {
  if (-not $JsonOut) { $JsonOut = Join-Path $StateDir 'scan.json' }
  $rows = @()
  foreach ($g in ($allProc | Group-Object ProcessName)) {
    $ws = 0.0; $np = 0; $protCount = 0; $selCount = 0; $sessList = @()
    foreach ($p in $g.Group) {
      $np++
      try { $ws += $p.WorkingSet64 } catch { }
      $sessList += [int]$p.SessionId
      if (& $isProtected $p) { $protCount++ } elseif (& $matchesScope $p) { $selCount++ }
    }
    $state = 'out-of-scope'
    if ($selCount -gt 0) { $state = 'candidate' } elseif ($protCount -gt 0) { $state = 'protected' }
    $rows += [pscustomobject]@{ name = $g.Name; n = $np; wsMB = [math]::Round($ws / 1MB, 0); sessions = @($sessList | Sort-Object -Unique); state = $state; targetCount = $selCount; protectedCount = $protCount }
  }
  $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $payload = [pscustomobject]@{
    schema = 1; scope = $Scope; mode = $Mode; admin = $adm
    totalProcs = $allProc.Count; candidateProcs = $targets.Count; candidateMB = [int]$totalWS
    hasSession = (Test-Path $StateFile); stateFile = $StateFile
    processes = $rows
  }
  [IO.File]::WriteAllText($JsonOut, ($payload | ConvertTo-Json -Depth 5 -Compress), (New-Object Text.UTF8Encoding($false)))
  Write-Output $JsonOut
  exit 0
}
Log ('计划处理 ' + $targets.Count + ' 个进程 / ' + $grouped.Count + ' 个名字，预计回收工作集 ' + $totalWS + ' MB  [Scope=' + $Scope + ' Mode=' + $Mode + ']') 'Cyan'
foreach ($g in $grouped) { Log ('   {0,-28} {1,3}p  {2,6} MB' -f $g.Name, $g.N, $g.WS) }
if ($DefenderHint) { Log '提示：MsMpEng(Defender) 常占最多 CPU，但不可挂起（篡改防护+PPL）。正解是给游戏目录加排除项。' 'Yellow' }
if ($DryRun) { Log 'DRY-RUN 结束，未做任何改动。' 'Green'; exit 0 }
if (-not $Yes) {
  $a = Read-Host '确认执行？被冻结应用的窗口会假死（恢复即正常）。输入 Y 继续'
  if ($a -notmatch '^[Yy]') { Log '已取消。'; exit 0 }
}

# ---------------------------------------------------------------- 6. 合并既有会话
$entries = @()
if (Test-Path $StateFile) {
  try {
    $j = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j -and $j.entries) { $entries = @($j.entries) }
  } catch { Log '旧日志损坏，忽略' 'Yellow' }
}
$liveMap = @{}
foreach ($e in $entries) { if ($e.mode -eq 'Suspend' -and [int]$e.suspendCount -gt 0) { $liveMap[[int]$e.pid] = $true } }
if ($liveMap.Count -gt 0) { Log ('发现既有会话：' + $liveMap.Count + ' 个进程仍处冻结态，本次合并（不重复挂起）') 'Yellow' }

# ---------------------------------------------------------------- 7. 执行（流水线：批量下发 → 单次等待 → 单次快照校验）
# 性能关键：原实现每个目标都 Start-Sleep 400ms 做校验，N 个目标就要 N×0.4 秒（146 进程≈70 秒）。
# 现在改为「读快照 → 批量冻结 → 只等一次 → 只快照一次」，N 个目标仍只付一次等待成本。
$ok = 0; $skip = 0; $fail = 0; $wsSum = 0; $needResuspend = @()
$plan = New-Object System.Collections.Generic.List[object]
foreach ($p in $targets) {
  $name = $p.ProcessName
  if ($liveMap.ContainsKey([int]$p.Id)) { Log ('   跳过(已在本次会话冻结) {0} pid {1}' -f $name, $p.Id) 'DarkGray'; $skip++; continue }
  $crit = [GB]::Critical($p.Id)
  if ($crit -eq 'T') { Log ('   跳过(系统关键进程) {0} pid {1}' -f $name, $p.Id) 'DarkGray'; $skip++; continue }
  $start = 0; $path = ''; $ws = 0; $cpu0 = -1.0
  try { $start = $p.StartTime.ToUniversalTime().Ticks } catch { }
  try { $path = $p.Path } catch { }
  try { $ws = $p.WorkingSet64 } catch { }
  try { $cpu0 = $p.TotalProcessorTime.TotalSeconds } catch { }
  [void]$plan.Add([pscustomobject]@{ P = $p; Name = $name; Start = $start; Path = $path; Ws = $ws; Cpu0 = $cpu0 })
}

$applied = New-Object System.Collections.Generic.List[object]
foreach ($it in $plan) {
  $r = if (& $useIdle $it.Name) { [GB]::Idle([int]$it.P.Id, $true, 1) } else { [GB]::Suspend([int]$it.P.Id, (-not $NoTrim), $true, 1) }
  [void]$applied.Add([pscustomobject]@{ It = $it; R = $r })
}

$anySuspend = 0
foreach ($a in $applied) { if ($a.R -like 'OK|*' -and $a.R.Split('|')[4] -ne '0') { $anySuspend++ } }
$snap = @{}
if ($anySuspend -gt 0) {
  Start-Sleep -Milliseconds 400
  foreach ($q in @(Get-Process -ErrorAction SilentlyContinue)) { $snap[[int]$q.Id] = $q }
}

foreach ($a in $applied) {
  $it = $a.It; $r = $a.R; $p = $it.P
  if ($r -like 'OK|*') {
    $f = $r.Split('|')
    $modeUsed = 'Suspend'; if ($f[4] -eq '0') { $modeUsed = 'Idle' }
    $note = 'trim=' + $f[5]
    if ($modeUsed -eq 'Suspend' -and $snap.ContainsKey([int]$p.Id)) {
      $cp = $snap[[int]$p.Id]
      $cpu1 = -1.0; try { $cpu1 = $cp.TotalProcessorTime.TotalSeconds } catch { }
      $susp = 0; $tot = 0
      try { $tot = @($cp.Threads).Count; $susp = @($cp.Threads | Where-Object { $_.ThreadState -eq 'Wait' -and $_.WaitReason -eq 'Suspended' }).Count } catch { }
      if ($it.Cpu0 -ge 0 -and $cpu1 -ge 0 -and (($cpu1 - $it.Cpu0) -gt 0.02)) {
        $needResuspend += [int]$p.Id
        $note += (' cpu+' + [math]::Round(($cpu1 - $it.Cpu0) * 1000, 0) + 'ms!')
      } else { $note += (' susp=' + $susp + '/' + $tot) }
    }
    $entries += [pscustomobject]@{
      pid = [int]$p.Id; name = $it.Name; startUtcTicks = $it.Start; path = $it.Path; wsMB = [math]::Round($it.Ws / 1MB, 0)
      mode = $modeUsed; suspendCount = [int]$f[4]; origPrio = [int]$f[1]; origMem = [int]$f[2]; origEco = [int]$f[3]; mask = $f[6]
    }
    $wsSum += $it.Ws
    LogFast ('   OK  {0,-26} pid {1,-7} {2,-8} {3,6} MB  {4}' -f $it.Name, $p.Id, $modeUsed, [math]::Round($it.Ws / 1MB, 0), $note) 'Green'
    $ok++
  }
  elseif ($r -eq 'E5') { LogFast ('   跳过(拒绝访问/受保护) {0} pid {1}' -f $it.Name, $p.Id) 'DarkGray'; $skip++ }
  elseif ($r -eq 'E87') { LogFast ('   跳过(参数不被支持) {0} pid {1}' -f $it.Name, $p.Id) 'DarkGray'; $skip++ }
  else { LogFast ('   失败 {0} pid {1} -> {2}' -f $it.Name, $p.Id, $r) 'Red'; $fail++ }
}
FlushFast

# ---------------------------------------------------------------- 8. 校验 / 二重挂起
if ($needResuspend.Count -gt 0) {
  Log ('校验发现 ' + $needResuspend.Count + ' 个进程仍有活动线程(BYPASS_PROCESS_FREEZE 线程): ' + ($needResuspend -join ',')) 'Yellow'
  if ($ReSuspend) {
    foreach ($id in $needResuspend) {
      $rr = [GB]::Suspend($id, $false, $true, 1)
      if ($rr -like 'OK|*') {
        foreach ($e in $entries) { if ([int]$e.pid -eq $id) { $e.suspendCount = [int]$e.suspendCount + 1 } }
        Log ('   已二重挂起 pid ' + $id + '（日志记 suspendCount=2，恢复时会调用两次）') 'Yellow'
      }
    }
  } else { Log '   未二重挂起（需 -ReSuspend 显式开启）；这些进程可能仍占用部分 CPU。' 'Yellow' }
}

# ---------------------------------------------------------------- 9. 游戏提优先级（可选）
if ($BoostGame) {
  $gp = @(Get-Process $BoostGame -ErrorAction SilentlyContinue)
  if ($gp.Count -eq 0) { Log ('未找到游戏进程 ' + $BoostGame) 'Yellow' }
  else {
    foreach ($g in $gp) {
      $op = -1
      $q = [GB]::Query($g.Id)
      if ($q -notlike 'E*') { $op = [int]($q.Split('|')[0]) }
      $gStart = 0; try { $gStart = $g.StartTime.ToUniversalTime().Ticks } catch { }
      [GB]::Boost($g.Id)
      $entries += [pscustomobject]@{
        pid = [int]$g.Id; name = $g.ProcessName; startUtcTicks = $gStart; path = ''; wsMB = 0
        mode = 'Boost'; suspendCount = 0; origPrio = $op; origMem = -1; origEco = -1; mask = 'full'
      }
      Log ('   已提升游戏优先级 {0} pid {1}' -f $g.ProcessName, $g.Id) 'Green'
    }
  }
}

# ---------------------------------------------------------------- 10. 写日志
$doc = [pscustomobject]@{
  schema = 1; startedUtc = (Get-Date).ToUniversalTime().ToString('o'); host = 'local'   # 不写入计算机名，避免用户粘贴日志时带出主机信息
  scope = $Scope; mode = $Mode; toolPid = $PID; protectedCount = $Protected.Count; entries = $entries
}
[IO.File]::WriteAllText($StateFile, ($doc | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- 11. 自动恢复守护
if ($AutoResumeMinutes -gt 0 -or $ResumeWhenProcessExits) {
  $resume = Join-Path $Root 'resume-non-system-processes.ps1'
  $psArgs = @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', $resume, '-Yes','-Quiet')
  if ($AutoResumeMinutes -gt 0) { $psArgs += @('-MaxMinutes', $AutoResumeMinutes) }
  if ($ResumeWhenProcessExits) {
    $psArgs += @('-WaitProcessExit', $ResumeWhenProcessExits)
    # 把挂起时刻已观察到的 PID 一并交给守护进程：避免守护进程启动的 1-2 秒内目标就退出导致的竞态
    $seedPids = @(Get-Process -Name $ResumeWhenProcessExits -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
    if ($seedPids.Count -gt 0) { $psArgs += @('-WaitProcessIds', ($seedPids -join ',')) }
  }
  Start-Process powershell -ArgumentList $psArgs -WindowStyle Hidden | Out-Null
  $parts = @()
  if ($AutoResumeMinutes -gt 0) { $parts += ($AutoResumeMinutes.ToString() + ' 分钟到期') }
  if ($ResumeWhenProcessExits) { $parts += ($ResumeWhenProcessExits + ' 全部退出') }
  Log ('已派发隐藏守护进程：' + ($parts -join ' 或 ') + ' 时自动恢复') 'Cyan'
}

Log ('完成：成功 ' + $ok + ' / 跳过 ' + $skip + ' / 失败 ' + $fail + '；共回收工作集 ' + [math]::Round($wsSum / 1MB, 0) + ' MB') 'Cyan'
Log ('日志：' + $LogFile + '   会话文件：' + $StateFile) 'Cyan'
Log '恢复请运行 resume-non-system-processes.ps1（或双击 GameBoost.resume.cmd / 热键 Ctrl+Alt+R）' 'Cyan'
