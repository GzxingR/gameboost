<#
  GameBoost 自测套件（headless / 可 CI）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GameBoost.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GameBoost.ps1 -SkipSlow   # 跳过守护进程等慢用例

  退出码：0 = 全部通过；1 = 存在失败
  安全：只冻结本套件自己启动的合成进程（gbmemballoon / ping），绝不触碰用户正在使用的应用。
        每个用例结束后都会恢复现场，最终清场（resume 全部 + 杀合成进程 + 删除会话文件）。
#>
[CmdletBinding()]
param(
  [string]$Root = '',
  [switch]$SkipSlow,
  [int]$BalloonMB = 512
)

if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$PausePs1  = Join-Path $Root 'pause-non-system-processes.ps1'
$ResumePs1 = Join-Path $Root 'resume-non-system-processes.ps1'
$GuiPs1    = Join-Path $Root 'GameBoost.GUI.ps1'
$StateDir  = Join-Path $Root 'state'
$StateFile = Join-Path $StateDir 'current.json'
$SelFile   = Join-Path $StateDir 'ci-selection.txt'
$BalloonExe = Join-Path $Root 'tools\gbmemballoon.exe'
$BalloonSrc = Join-Path $Root 'tools\MemBalloon.cs'

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir -Force | Out-Null }

$script:pass = 0
$script:fail = 0
$script:failures = New-Object System.Collections.Generic.List[string]

function Section([string]$t) { Write-Host ''; Write-Host ('=== ' + $t + ' ===') -ForegroundColor Cyan }
function Ok([string]$m)   { $script:pass++; Write-Host ('  [PASS] ' + $m) -ForegroundColor Green }
function Bad([string]$m)  { $script:fail++; $script:failures.Add($m); Write-Host ('  [FAIL] ' + $m) -ForegroundColor Red }
function Info([string]$m) { Write-Host ('         ' + $m) -ForegroundColor DarkGray }
function Check([bool]$cond, [string]$name, [string]$detail = '') {
  if ($cond) { Ok $name } else { Bad ($name + $(if ($detail) { ' -> ' + $detail } else { '' })) }
}

function Run-Engine([string]$scriptPath, [string[]]$extraArgs) {
  $all = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $scriptPath) + $extraArgs
  $out = & powershell @all 2>&1
  return @{ Text = (($out | ForEach-Object { $_.ToString() }) -join "`n"); Code = $LASTEXITCODE }
}
function Read-Journal {
  if (-not (Test-Path $StateFile)) { return $null }
  try { return (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function SuspendedCount([int]$processId) {
  $p = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if (-not $p) { return -1 }
  try { return @($p.Threads | Where-Object { $_.ThreadState -eq 'Wait' -and $_.WaitReason -eq 'Suspended' }).Count } catch { return -1 }
}
function Cleanup {
  try { if (Test-Path $StateFile) { [void](Run-Engine $ResumePs1 @('-Yes','-Quiet')) } } catch { }
  foreach ($n in @('gbmemballoon','ping')) { Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
  Remove-Item $SelFile -Force -ErrorAction SilentlyContinue
}

# GetProcessInformation 探针：用于验证 QoS 快照/还原
if (-not ('GBProbe' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class GBProbe {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr h, int c, IntPtr b, int s);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetPriorityClass(IntPtr h);
  static IntPtr O(int pid) { IntPtr h = OpenProcess(0x0F00, false, pid); if (h == IntPtr.Zero) { h = OpenProcess(0x1800, false, pid); } return h; }
  public static string State(int pid) {
    IntPtr h = O(pid); if (h == IntPtr.Zero) { return "open-fail"; }
    try {
      int prio = (int)GetPriorityClass(h);
      IntPtr b1 = Marshal.AllocHGlobal(4); int mem = -1;
      try { Marshal.WriteInt32(b1, -1); if (GetProcessInformation(h, 0, b1, 4)) { mem = Marshal.ReadInt32(b1); } } finally { Marshal.FreeHGlobal(b1); }
      IntPtr b2 = Marshal.AllocHGlobal(12); int eco = -1;
      try { Marshal.WriteInt32(b2, 1); Marshal.WriteInt32(b2, 4, 0); Marshal.WriteInt32(b2, 8, 0);
            if (GetProcessInformation(h, 4, b2, 12)) { eco = (Marshal.ReadInt32(b2, 8) & 1); } } finally { Marshal.FreeHGlobal(b2); }
      return prio + "|" + mem + "|" + eco;
    } finally { CloseHandle(h); }
  }
}
'@
}

Write-Host 'GameBoost 自测套件' -ForegroundColor White
Info ('仓库根目录: ' + $Root)
Info ('管理员: ' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

try {
  # ---------------------------------------------------------------- T1 语法与配置
  Section 'T1 语法与配置'
  foreach ($f in @($PausePs1, $ResumePs1, $GuiPs1)) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
    Check (($errs.Count -eq 0)) ('脚本语法 OK: ' + (Split-Path $f -Leaf)) $(if ($errs.Count -gt 0) { $errs[0].Message })
  }
  $cfg = $null
  try { $cfg = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  Check ($null -ne $cfg) 'config.json 可解析'
  if ($cfg) {
    Check (@($cfg.safeTargets).Count -gt 0) 'config.safeTargets 非空' ('count=' + @($cfg.safeTargets).Count)
    Check (@($cfg.hostProtected).Count -gt 0) 'config.hostProtected 非空' ('count=' + @($cfg.hostProtected).Count)
  }

  # ---------------------------------------------------------------- T2 保护名单
  Section 'T2 保护名单与范围判定（-EmitJson）'
  $jsonOut = Join-Path $StateDir 'ci-scan.json'
  $r = Run-Engine $PausePs1 @('-EmitJson','-JsonOut',$jsonOut,'-Scope','Broad','-Quiet')
  Check (Test-Path $jsonOut) '扫描清单已生成'
  $scan = Get-Content $jsonOut -Raw -Encoding UTF8 | ConvertFrom-Json
  $byName = @{}
  foreach ($row in $scan.processes) { $byName[$row.name.ToLower()] = $row }
  $hardBlocked = @('MsMpEng','NisSrv','SecurityHealthService','svchost','csrss','lsass','winlogon','services','dwm','explorer','audiodg','ACE-Tray','SGuard','EACefSubProcess','BEService')
  $leaked = @()
  foreach ($n in $hardBlocked) { $row = $byName[$n.ToLower()]; if ($row -and $row.state -eq 'candidate') { $leaked += $n } }
  Check ($leaked.Count -eq 0) '反作弊/杀毒/系统关键进程全部不可冻结' ($leaked -join ',')
  $hostLeaked = @()
  foreach ($n in @($cfg.hostProtected)) { $row = $byName[$n.ToLower()]; if ($row -and $row.state -eq 'candidate') { $hostLeaked += $n } }
  Check ($hostLeaked.Count -eq 0) 'hostProtected 名单内的进程全部受保护' ($hostLeaked -join ',')
  # 说明：清单按「进程名」聚合，同名进程可能同时存在于会话 0（服务）与会话 1（用户）。
  # 引擎是逐进程过滤的，所以正确断言是：会话 0 的实例必须被计入 protectedCount，绝不出现在 targetCount 里。
  $mixed = @()
  $badRows = @()
  foreach ($row in ($scan.processes | Where-Object { $_.state -eq 'candidate' })) {
    $p = @(Get-Process -Name $row.name -ErrorAction SilentlyContinue)
    $c0 = @($p | Where-Object { $_.SessionId -eq 0 }).Count
    $c1 = @($p | Where-Object { $_.SessionId -ne 0 }).Count
    if ($c0 -gt 0) {
      $mixed += $row.name
      if ([int]$row.targetCount -gt $c1 -or [int]$row.protectedCount -lt $c0) {
        $badRows += ($row.name + '(sess0=' + $c0 + ' target=' + $row.targetCount + ' protected=' + $row.protectedCount + ')')
      }
    }
  }
  Check ($badRows.Count -eq 0) '会话 0 实例被计入受保护、未计入可冻结目标' ($badRows -join ',')
  if ($mixed.Count -gt 0) {
    $probe = $mixed[0]
    Info ('发现跨会话同名进程，直接实测过滤是否逐进程生效: ' + $probe)
    [IO.File]::WriteAllLines($SelFile, [string[]]@($probe), (New-Object Text.UTF8Encoding($false)))
    [void](Run-Engine $PausePs1 @('-NamesFile', $SelFile, '-Yes'))
    $susp0 = 0; $susp1 = 0
    foreach ($x in @(Get-Process -Name $probe -ErrorAction SilentlyContinue)) {
      $s = SuspendedCount $x.Id
      if ($x.SessionId -eq 0) { $susp0 += $s } else { $susp1 += $s }
    }
    Check ($susp0 -eq 0) '实测：会话 0 的同名进程未被挂起' ('suspendedInSession0=' + $susp0)
    Check ($susp1 -gt 0) '实测：会话 1 的同名进程已被挂起' ('suspendedInSession1=' + $susp1)
    [void](Run-Engine $ResumePs1 @('-Yes'))
    $after = 0
    foreach ($x in @(Get-Process -Name $probe -ErrorAction SilentlyContinue)) { $after += (SuspendedCount $x.Id) }
    Check ($after -eq 0) '实测：恢复后同名进程全部解除挂起' ('leftSuspended=' + $after)
  } else { Info '本机没有跨会话同名的候选进程，跳过直接验证' }
  Check ($scan.candidateProcs -gt 0) '存在可冻结的候选进程' ('candidateProcs=' + $scan.candidateProcs)

  # ---------------------------------------------------------------- T3 冻结/恢复往返
  Section 'T3 冻结 → 校验 → 恢复 往返'
  if (-not (Test-Path $BalloonExe)) {
    if (Test-Path $BalloonSrc) {
      $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
      if (Test-Path $csc) { & $csc /nologo /platform:x64 /optimize+ "/out:$BalloonExe" $BalloonSrc | Out-Null }
    }
  }
  if (-not (Test-Path $BalloonExe)) {
    Bad '合成基准进程编译失败（找不到 csc 或源码）'
  } else {
    $boOut = Join-Path $StateDir 'ci-balloon.out'
    Remove-Item $boOut -Force -ErrorAction SilentlyContinue
    $balloon = Start-Process $BalloonExe -ArgumentList @($BalloonMB, '600') -PassThru -NoNewWindow -RedirectStandardOutput $boOut
    # 基线取合成进程自己上报的工作集：Windows 会自行回收空闲进程的工作集，
    # 若等待数秒后再读 WorkingSet64，读到的可能已经是系统回收后的值（早期版本因此误判"未分配内存"）。
    $reportedMB = 0
    for ($w = 0; $w -lt 40; $w++) {
      Start-Sleep -Milliseconds 500
      if (Test-Path $boOut) {
        $btxt = Get-Content $boOut -Raw -ErrorAction SilentlyContinue
        if ($btxt -match 'WS_MB=(\d+)') { $reportedMB = [int]$Matches[1]; break }
      }
    }
    $wsBefore = $reportedMB * 1MB
    Check ($reportedMB -ge [int]($BalloonMB * 0.5)) '合成进程已分配并触碰内存' ('进程自报工作集=' + $reportedMB + 'MB')
    [IO.File]::WriteAllLines($SelFile, [string[]]@('gbmemballoon'), (New-Object Text.UTF8Encoding($false)))
    $r = Run-Engine $PausePs1 @('-NamesFile', $SelFile, '-Yes')
    $j = Read-Journal
    Check ($null -ne $j -and @($j.entries).Count -ge 1) '会话文件已写入' $r.Text.Substring(0, [Math]::Min(120, $r.Text.Length))
    if ($j) {
      $e = @($j.entries)[0]
      Check ($e.mode -eq 'Suspend') 'journal.mode = Suspend'
      Check ([int]$e.suspendCount -eq 1) 'journal.suspendCount = 1'
      Check ($e.mask -eq 'full') 'journal.mask = full（拿到了完整权限掩码）'
      Check ([long]$e.startUtcTicks -gt 0) 'journal 记录了启动时间戳指纹'
      Check ($j.host -eq 'local') 'journal 不写入计算机名（host=local）'
    }
    Start-Sleep -Seconds 1
    $balloon.Refresh()
    $wsAfter = $balloon.WorkingSet64
    Check (($wsAfter -lt ($reportedMB * 1MB * 0.25))) ('工作集被回收') ('自报=' + $reportedMB + 'MB 冻结后=' + [math]::Round($wsAfter / 1MB, 0) + 'MB')
    Check ((SuspendedCount $balloon.Id) -gt 0) ('线程处于挂起态') ('suspended=' + (SuspendedCount $balloon.Id))
    $r = Run-Engine $ResumePs1 @('-Yes')
    Check (-not (Test-Path $StateFile)) '恢复后会话文件已归档（current.json 不存在）'
    Check ((SuspendedCount $balloon.Id) -eq 0) '恢复后无残留挂起线程'
    Check ($null -ne (Get-Process -Id $balloon.Id -ErrorAction SilentlyContinue)) '进程恢复后仍存活（数据未丢失）'
  }

  # ---------------------------------------------------------------- T4 幂等性
  Section 'T4 幂等性（重复冻结不得双重挂起）'
  if (Test-Path $BalloonExe) {
    $balloon = Start-Process $BalloonExe -ArgumentList @('256', '600') -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 8
    [IO.File]::WriteAllLines($SelFile, [string[]]@('gbmemballoon'), (New-Object Text.UTF8Encoding($false)))
    [void](Run-Engine $PausePs1 @('-NamesFile', $SelFile, '-Yes'))
    $r2 = Run-Engine $PausePs1 @('-NamesFile', $SelFile, '-Yes')
    Check ($r2.Text -match '跳过\(已在本次会话冻结\)') '第二次冻结被跳过' $r2.Text.Substring(0, [Math]::Min(140, $r2.Text.Length))
    $j = Read-Journal
    if ($j) { Check ([int](@($j.entries)[0].suspendCount) -eq 1) 'suspendCount 仍为 1（未被重复挂起）' ('actual=' + @($j.entries)[0].suspendCount) }
    # 恢复必须只调用一次即解除
    [void](Run-Engine $ResumePs1 @('-Yes'))
    Check ((SuspendedCount $balloon.Id) -eq 0) '单次恢复即完全解除挂起'
  }

  # ---------------------------------------------------------------- T5 Idle 模式与 QoS 还原
  Section 'T5 Idle 软模式：QoS 设置与精确还原'
  if (Test-Path $BalloonExe) {
    $balloon = Start-Process $BalloonExe -ArgumentList @('128', '600') -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 6
    $base = [GBProbe]::State($balloon.Id)
    Info ('baseline prio|memPrio|ecoQoS = ' + $base)
    [IO.File]::WriteAllLines($SelFile, [string[]]@('gbmemballoon'), (New-Object Text.UTF8Encoding($false)))
    $r = Run-Engine $PausePs1 @('-NamesFile', $SelFile, '-Mode', 'Idle', '-Yes')
    $idle = [GBProbe]::State($balloon.Id)
    Info ('after Idle = ' + $idle)
    $f = $idle.Split('|')
    Check ($f[0] -eq '64') '优先级被设为 IDLE (0x40)' ('actual=' + $f[0])
    Check ($f[1] -eq '1') '内存优先级被设为 VERY_LOW (1)' ('actual=' + $f[1])
    Check ($f[2] -eq '1') 'EcoQoS 已开启' ('actual=' + $f[2])
    Check ((SuspendedCount $balloon.Id) -eq 0) 'Idle 模式不冻结进程（挂起线程数为 0）'
    [void](Run-Engine $ResumePs1 @('-Yes'))
    $restored = [GBProbe]::State($balloon.Id)
    Info ('after resume = ' + $restored)
    Check ($restored -eq $base) '恢复后 QoS 精确回到基线值' ('expected=' + $base + ' actual=' + $restored)
  }

  # ---------------------------------------------------------------- T6 防误恢复
  Section 'T6 指纹校验：拒绝误恢复（PID 复用 / 进程已退出）'
  if (Test-Path $BalloonExe) {
    $balloon = Start-Process $BalloonExe -ArgumentList @('128', '600') -PassThru -WindowStyle Hidden
    $decoy = Start-Process 'ping' -ArgumentList @('-n','600','127.0.0.1') -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 6
    [IO.File]::WriteAllLines($SelFile, [string[]]@('gbmemballoon'), (New-Object Text.UTF8Encoding($false)))
    [void](Run-Engine $PausePs1 @('-NamesFile', $SelFile, '-Yes'))
    # 把会话条目改指向诱饵进程（名字不同 -> 应判定 PidReused 并跳过）
    $j = Read-Journal
    if ($j) {
      $j.entries[0].pid = [int]$decoy.Id
      $j.entries[0].startUtcTicks = 0
      [IO.File]::WriteAllText($StateFile, ($j | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
      $r = Run-Engine $ResumePs1 @('-Yes')
      Check ($r.Text -match 'PidReused') 'PID 复用被识别并跳过' $r.Text.Substring(0, [Math]::Min(140, $r.Text.Length))
      Check ((SuspendedCount $decoy.Id) -eq 0) '诱饵进程未被误动（未挂起）'
    }
    # 进程已退出 -> NotRunning
    Start-Process $BalloonExe -ArgumentList @('128','600') -PassThru -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 6
    [void](Run-Engine $PausePs1 @('-NamesFile', $SelFile, '-Yes'))
    Get-Process -Name gbmemballoon -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $r = Run-Engine $ResumePs1 @('-Yes')
    Check ($r.Text -match 'NotRunning') '目标已退出时报告 NotRunning' $r.Text.Substring(0, [Math]::Min(140, $r.Text.Length))
  }

  # ---------------------------------------------------------------- T7 守护进程自动恢复
  if (-not $SkipSlow) {
    Section 'T7 守护进程：目标进程全部退出后自动恢复'
    if (Test-Path $BalloonExe) {
      $balloon = Start-Process $BalloonExe -ArgumentList @('128', '600') -PassThru -WindowStyle Hidden
      Start-Sleep -Seconds 6
      [IO.File]::WriteAllLines($SelFile, [string[]]@('gbmemballoon'), (New-Object Text.UTF8Encoding($false)))
      [void](Run-Engine $PausePs1 @('-NamesFile', $SelFile, '-Yes', '-ResumeWhenProcessExits', 'gbmemballoon'))
      Check ((SuspendedCount $balloon.Id) -gt 0) '冻结成功，等待守护进程'
      Stop-Process -Id $balloon.Id -Force -ErrorAction SilentlyContinue
      $resumed = $false
      for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 3
        if (-not (Test-Path $StateFile)) { $resumed = $true; break }
      }
      Check $resumed '目标退出后守护进程自动完成恢复并归档'
    }
  } else { Section 'T7 已跳过（-SkipSlow）' }

  # ---------------------------------------------------------------- T8 GUI 自检
  Section 'T8 图形界面自检（-SelfTest）'
  $target = $null
  $ping = Start-Process 'ping' -ArgumentList @('-n','300','127.0.0.1') -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 2
  if ($ping) { $target = 'PING' }
  if ($target -and (Test-Path $GuiPs1)) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $GuiPs1 -SelfTest -SelfTestTarget $target -NoElevate 2>&1
    $txt = (($out | ForEach-Object { $_.ToString() }) -join "`n")
    Check ($LASTEXITCODE -eq 0) 'GUI 自检退出码为 0' ('code=' + $LASTEXITCODE)
    Check ($txt -match 'suspendedThreadsObserved=\d+') 'GUI 自检完成了冻结校验'
    Check ($txt -match 'suspendedThreadsAfterResume=0') 'GUI 自检确认恢复后无残留挂起'
    Check ($txt -match 'protected-check guard') 'GUI 受保护行拦截逻辑被执行'
  } else { Bad 'GUI 自检无法运行（缺少 ping 或 GUI 脚本）' }
}
catch {
  Bad ('套件异常中断: ' + $_.Exception.Message + ' @ line ' + $_.InvocationInfo.ScriptLineNumber + ' — 后续用例未执行')
  Info ('异常类型: ' + $_.Exception.GetType().FullName)
}
finally {
  Section '清场'
  Cleanup
  $left = Test-Path $StateFile
  Check (-not $left) '现场已清理：无遗留冻结会话'
  Write-Host ''
  Write-Host ('结果：通过 ' + $script:pass + ' / 失败 ' + $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
  if ($script:fail -gt 0) {
    Write-Host '失败项：' -ForegroundColor Red
    foreach ($x in $script:failures) { Write-Host ('  - ' + $x) -ForegroundColor Red }
  }
  exit $(if ($script:fail -eq 0) { 0 } else { 1 })
}
