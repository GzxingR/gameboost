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
  # -NoRules：T2 只验证保护名单/范围判定，不应受 selectRules 影响（否则在"进程普遍很小"的 CI runner 上会被规则表全部 skip）
  $r = Run-Engine $PausePs1 @('-EmitJson','-JsonOut',$jsonOut,'-Scope','Broad','-NoRules','-Quiet')
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

  # ---------------------------------------------------------------- T9 规则表驱动的自动选择
  Section 'T9 规则表 / 档案驱动的自动选择'
  $t9prof  = Join-Path $StateDir 't9-profile.json'
  $t9prof2 = Join-Path $StateDir 't9-profile-max.json'
  $t9scan  = Join-Path $StateDir 't9-scan.json'
  $t9profJson = @'
{ "name": "T9合成目标", "scope": "Broad", "mode": "Suspend", "include": ["gbmemballoon", "ping"],
  "rules": [ { "name": "测试-软模式", "match": "ping", "action": "idle" },
             { "name": "测试-冻结", "match": "gbmemballoon", "action": "suspend" } ] }
'@
  [IO.File]::WriteAllText($t9prof, $t9profJson, (New-Object Text.UTF8Encoding($true)))
  $balloon = Start-Process $BalloonExe -ArgumentList @('128', '600') -PassThru -WindowStyle Hidden
  $pingT9  = Start-Process 'ping' -ArgumentList @('-n', '600', '127.0.0.1') -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 900
  $r = Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $t9scan, '-Profile', $t9prof, '-Yes', '-Quiet')
  Check ($r.Code -eq 0) '按档案+规则表扫描成功（-EmitJson）' $r.Text
  $j9 = $null
  if (Test-Path $t9scan) { $j9 = Get-Content $t9scan -Raw -Encoding UTF8 | ConvertFrom-Json }
  Check ($null -ne $j9 -and [int]$j9.ruleCount -eq 2) '清单回显 ruleCount=2' ('ruleCount=' + $j9.ruleCount)
  Check ($null -ne $j9 -and $j9.profile -match 't9-profile\.json$') '清单回显档案名（文件档案带 文件: 前缀）' ('profile=' + $j9.profile)
  $rowPing = @($j9.processes | Where-Object { $_.name -ieq 'PING' })[0]
  $rowBal  = @($j9.processes | Where-Object { $_.name -ieq 'gbmemballoon' })[0]
  Check ($rowPing -and $rowPing.action -eq 'idle' -and $rowPing.rule -eq '测试-软模式') 'ping 被规则判定 idle（action/rule 字段）' ('action=' + $rowPing.action + ' rule=' + $rowPing.rule)
  Check ($rowBal -and $rowBal.action -eq 'suspend' -and $rowBal.rule -eq '测试-冻结') 'gbmemballoon 被规则判定 suspend' ('action=' + $rowBal.action + ' rule=' + $rowBal.rule)
  Check (@($j9.processes | Where-Object { $_.state -eq 'candidate' }).Count -eq 2) '档案 include 把范围收窄到 2 个合成名字' ('candidates=' + @($j9.processes | Where-Object { $_.state -eq 'candidate' }).Count)
  $r = Run-Engine $PausePs1 @('-Profile', $t9prof, '-Yes', '-Quiet')
  Check ($r.Code -eq 0) '按档案+规则表执行冻结成功' $r.Text
  Check ((SuspendedCount $balloon.Id) -gt 0) '规则表 suspend 项被真冻结' ('suspended=' + (SuspendedCount $balloon.Id))
  Check ((SuspendedCount $pingT9.Id) -eq 0) '规则表 idle 项只降 QoS 不被冻结' ('suspended=' + (SuspendedCount $pingT9.Id))
  $jt = Read-Journal
  $ePing = @($jt.entries | Where-Object { $_.name -ieq 'PING' })[0]
  $eBal  = @($jt.entries | Where-Object { $_.name -ieq 'gbmemballoon' })[0]
  Check ($ePing -and $ePing.mode -eq 'Idle') '会话里 ping 记为 Idle 模式' ('mode=' + $ePing.mode)
  Check ($eBal -and $eBal.mode -eq 'Suspend' -and [int]$eBal.suspendCount -eq 1) '会话里 balloon 记为 Suspend 且 suspendCount=1' ('mode=' + $eBal.mode)
  [void](Run-Engine $ResumePs1 @('-Yes', '-Quiet'))
  Check (-not (Test-Path $StateFile)) 'T9 冻结批次已完整恢复并归档'
  Stop-Process -Id $balloon.Id -Force -ErrorAction SilentlyContinue
  Get-Process -Name gbmemballoon -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
  $tiny = Start-Process $BalloonExe -ArgumentList @('12', '600') -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 900
  # 先用"无门槛"规则量出该名字的真实内存，再据此写门槛，避免依赖具体分配值
  [IO.File]::WriteAllText($t9prof2, '{ "name": "T9量测", "scope": "Broad", "mode": "Suspend", "include": ["gbmemballoon"], "rules": [ { "name": "测试-量测", "match": "*", "action": "suspend" } ] }', (New-Object Text.UTF8Encoding($true)))
  [void](Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $t9scan, '-Profile', $t9prof2, '-Quiet'))
  $j9c = Get-Content $t9scan -Raw -Encoding UTF8 | ConvertFrom-Json
  $rt0 = @($j9c.processes | Where-Object { $_.name -ieq 'gbmemballoon' })[0]
  $ws0 = [int]$rt0.wsMB
  Info ('合成进程实测内存 wsMB=' + $ws0)
  $maxHi = $ws0 + 30
  $maxLo = [math]::Max(1, $ws0 - 5)
  [IO.File]::WriteAllText($t9prof2, ('{ "name": "T9上限门槛", "scope": "Broad", "mode": "Suspend", "include": ["gbmemballoon"], "rules": [ { "name": "测试-小工具不处理", "match": "*", "action": "skip", "maxMemoryMB": ' + $maxHi + ' } ] }'), (New-Object Text.UTF8Encoding($true)))
  [void](Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $t9scan, '-Profile', $t9prof2, '-Quiet'))
  $rt1 = @((Get-Content $t9scan -Raw -Encoding UTF8 | ConvertFrom-Json).processes | Where-Object { $_.name -ieq 'gbmemballoon' })[0]
  Check ($rt1 -and $rt1.action -eq 'skip') '低于 maxMemoryMB 上限的名字命中 skip' ('action=' + $rt1.action + ' wsMB=' + $rt1.wsMB + ' max=' + $maxHi)
  [IO.File]::WriteAllText($t9prof2, ('{ "name": "T9上限门槛", "scope": "Broad", "mode": "Suspend", "include": ["gbmemballoon"], "rules": [ { "name": "测试-小工具不处理", "match": "*", "action": "skip", "maxMemoryMB": ' + $maxLo + ' } ] }'), (New-Object Text.UTF8Encoding($true)))
  [void](Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $t9scan, '-Profile', $t9prof2, '-Quiet'))
  $rt2 = @((Get-Content $t9scan -Raw -Encoding UTF8 | ConvertFrom-Json).processes | Where-Object { $_.name -ieq 'gbmemballoon' })[0]
  Check ($rt2 -and $rt2.action -ne 'skip') '高于 maxMemoryMB 上限的名字不再命中 skip' ('action=' + $rt2.action + ' wsMB=' + $rt2.wsMB + ' max=' + $maxLo)
  $tiny2 = Start-Process $BalloonExe -ArgumentList @('300', '600') -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 900
  [void](Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $t9scan, '-Profile', $t9prof2, '-Quiet'))
  $rt3 = @((Get-Content $t9scan -Raw -Encoding UTF8 | ConvertFrom-Json).processes | Where-Object { $_.name -ieq 'gbmemballoon' })[0]
  Check ($rt3 -and [int]$rt3.wsMB -gt [int]$rt2.wsMB) '同名内存按合计判定（新增同名字进程后合计变大）' ('ws=' + $rt3.wsMB + ' 之前=' + $rt2.wsMB)
  Get-Process -Name gbmemballoon -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  [void](Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $t9scan, '-Profile', '极简', '-Quiet'))
  $j9e = Get-Content $t9scan -Raw -Encoding UTF8 | ConvertFrom-Json
  Check ($j9e.profile -eq '极简') 'config 档案按名字可加载（回显 profile）' ('profile=' + $j9e.profile)
  Check ($j9e.scope -eq 'Broad') '档案里的 scope 覆盖命令行 Scope' ('scope=' + $j9e.scope)
  $r = Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $t9scan, '-Profile', '不存在的档案')
  Check ($r.Code -ne 0 -and $r.Text -match '可用档案') '未知档案名报错并列出可用档案' ('code=' + $r.Code)
  $cfgAll = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $rFirst = @($cfgAll.selectRules)[0]
  Check ($rFirst.action -eq 'skip' -and $rFirst.match -match 'steam' -and $rFirst.match -match 'EADesktop') '默认规则表首条：游戏启动器/商店不自动冻结' ('rule=' + $rFirst.name)
  $rMax = @($cfgAll.selectRules | Where-Object { $_.maxMemoryMB })
  Check ($rMax.Count -ge 1 -and [int]$rMax[0].maxMemoryMB -eq 60) '默认规则表含 maxMemoryMB 上限规则' ('max=' + $rMax[0].maxMemoryMB)
  $gprof = @($cfgAll.profiles.'游戏前'.rules)
  Check ($gprof[0].action -eq 'idle' -and $gprof[-1].match -eq '*') '档案 [游戏前] 规则顺序：软模式优先于通配冻结' ('first=' + $gprof[0].name)

  # ---------------------------------------------------------------- T10 选择性恢复
  Section 'T10 选择性恢复（只恢复指定进程名，其余保持冻结）'
  $t10sel   = Join-Path $StateDir 't10-selection.txt'
  $t10rules = Join-Path $StateDir 't10-rules-skipall.json'
  $t10prof  = Join-Path $StateDir 't10-profile.json'
  $t10profJson = @'
{ "name": "T10合成目标", "scope": "Broad", "mode": "Suspend", "include": ["gbmemballoon", "ping"] }
'@
  [IO.File]::WriteAllText($t10prof, $t10profJson, (New-Object Text.UTF8Encoding($true)))
  [IO.File]::WriteAllText($t10rules, '[ { "name": "测试-全部跳过", "match": "*", "action": "skip" } ]', (New-Object Text.UTF8Encoding($false)))
  Get-Process -Name gbmemballoon, PING -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
  $histBefore = @(Get-ChildItem (Join-Path $Root 'history') -Filter 'resumed-*.json' -ErrorAction SilentlyContinue).Count
  $balloon = Start-Process $BalloonExe -ArgumentList @('256', '600') -PassThru -WindowStyle Hidden
  $pingT10 = Start-Process 'ping' -ArgumentList @('-n', '600', '127.0.0.1') -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 900
  [IO.File]::WriteAllLines($t10sel, [string[]]@('gbmemballoon', 'ping'), (New-Object Text.UTF8Encoding($false)))
  $r = Run-Engine $PausePs1 @('-NamesFile', $t10sel, '-Profile', $t10prof, '-RuleFile', $t10rules, '-Yes', '-Quiet')
  Check ($r.Code -eq 0) '显式名单冻结成功' $r.Text
  $logNow = @(Get-ChildItem (Join-Path $Root 'logs') -Filter 'pause-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1)
  $logText = ''
  if ($logNow.Count -gt 0) { $logText = Get-Content $logNow[0].FullName -Raw -Encoding UTF8 }
  Check ($logText -match '显式名单优先') '显式名单优先于规则表（日志出现"显式名单优先"）'
  Check ((SuspendedCount $balloon.Id) -gt 0) 'balloon 已冻结（未被"全部跳过"规则表拦掉）' ('suspended=' + (SuspendedCount $balloon.Id))
  Check ((SuspendedCount $pingT10.Id) -gt 0) 'ping 已冻结（5MB 小进程也不被规则表拦掉）' ('suspended=' + (SuspendedCount $pingT10.Id))
  $j10 = Read-Journal
  Check ($null -ne $j10 -and @($j10.entries).Count -eq 2) '会话记录 2 条' ('n=' + @($j10.entries).Count)
  $r = Run-Engine $ResumePs1 @('-Only', 'ping', '-Yes', '-Quiet')
  Check ($r.Code -eq 0) '选择性恢复命令成功' $r.Text
  Start-Sleep -Milliseconds 300
  Check ((SuspendedCount $pingT10.Id) -eq 0) 'ping 已恢复（无残留挂起线程）' ('suspended=' + (SuspendedCount $pingT10.Id))
  Check ((SuspendedCount $balloon.Id) -gt 0) 'balloon 仍保持冻结（未被误恢复）' ('suspended=' + (SuspendedCount $balloon.Id))
  $j10b = Read-Journal
  Check ($null -ne $j10b -and @($j10b.entries).Count -eq 1) '未处理条目保留在 current.json（未提前归档）' ('n=' + @($j10b.entries).Count)
  Check (@($j10b.entries)[0].name -ieq 'gbmemballoon') '残留条目是 balloon' ('name=' + @($j10b.entries)[0].name)
  $r = Run-Engine $ResumePs1 @('-Yes', '-Quiet')
  Start-Sleep -Milliseconds 300
  Check ((SuspendedCount $balloon.Id) -eq 0) '剩余条目已恢复' ('suspended=' + (SuspendedCount $balloon.Id))
  Check (-not (Test-Path $StateFile)) 'current.json 已归档删除'
  $histAfter = @(Get-ChildItem (Join-Path $Root 'history') -Filter 'resumed-*.json' -ErrorAction SilentlyContinue).Count
  Check ($histAfter -eq $histBefore + 1) 'history 新增 1 个归档文件' ("before=$histBefore after=$histAfter")
  Get-Process -Name gbmemballoon, PING -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

  # ---------------------------------------------------------------- T11 GUI 效率三件套
  Section 'T11 GUI 效率三件套（筛选 / 自动选择 / 勾选记忆 / 恢复所选）'
  if ($txt) {
    $mFilter = [regex]::Match($txt, 'GUI-FILTER query=(\S+) rowsAll=(\d+) rowsFiltered=(\d+)')
    Check $mFilter.Success 'GUI 筛选框报告存在' '缺少 GUI-FILTER 行'
    if ($mFilter.Success) {
      Check ([int]$mFilter.Groups[3].Value -ge 1) '筛选命中目标行' ('filtered=' + $mFilter.Groups[3].Value)
      Check ([int]$mFilter.Groups[3].Value -lt [int]$mFilter.Groups[2].Value) '筛选确实收窄了列表' ('all=' + $mFilter.Groups[2].Value + ' filtered=' + $mFilter.Groups[3].Value)
    }
    Check ($txt -match 'GUI-FILTER resetRows=\d+') '清空筛选后列表恢复全量'
    $mAuto = [regex]::Match($txt, 'GUI-AUTOSEL checked=(\d+) rules=(\d+)')
    Check ($mAuto.Success -and [int]$mAuto.Groups[2].Value -ge 5) '🪄自动选择按规则表产生勾选集' ('rules=' + $mAuto.Groups[2].Value + ' checked=' + $mAuto.Groups[1].Value)
    Check ($txt -match 'GUI-SELMEM exists=True remember=True') '勾选记忆写入 state\selection.json'
    Check ($txt -match 'GUI-RESUME-SEL name=\S+ ') 'GUI"恢复所选"按名字选择性恢复完成'
    Check ($txt -match 'label=\[已选 \d+ 个应用') '勾选后状态标签同步更新'
  } else { Bad 'T11 未取得 GUI 自检报告（T8 未运行？）' }

  # ---------------------------------------------------------------- T12 AI 扩展入口（AGENTS / llms / schema / examples）
  Section 'T12 AI 扩展入口'
  foreach ($rel in @('AGENTS.md', 'docs\llms.txt', 'docs\llms-full.txt', 'docs\AI-EXTENDING.md',
                     'schemas\config.schema.json', 'schemas\scan.schema.json',
                     'examples\rules.example.json', 'examples\profile.example.json', 'examples\agent-drive.ps1')) {
    Check (Test-Path (Join-Path $Root $rel)) ('AI 入口存在：' + $rel)
  }
  $agentsTxt = ''
  if (Test-Path (Join-Path $Root 'AGENTS.md')) { $agentsTxt = Get-Content (Join-Path $Root 'AGENTS.md') -Raw -Encoding UTF8 }
  Check ($agentsTxt -match '反作弊' -and $agentsTxt -match 'UTF-8 with BOM' -and $agentsTxt -match 'Test-GameBoost') 'AGENTS.md 写明安全红线 / BOM 约定 / 验证命令'
  $extTxt = ''
  if (Test-Path (Join-Path $Root 'docs\AI-EXTENDING.md')) { $extTxt = Get-Content (Join-Path $Root 'docs\AI-EXTENDING.md') -Raw -Encoding UTF8 }
  Check ($extTxt -match '任务 1' -and $extTxt -match '绝对不能做的事') '扩展手册含任务清单与禁止清单'
  $llmsTxt = ''
  if (Test-Path (Join-Path $Root 'docs\llms.txt')) { $llmsTxt = Get-Content (Join-Path $Root 'docs\llms.txt') -Raw -Encoding UTF8 }
  Check ($llmsTxt -match 'EmitJson' -and $llmsTxt -match '硬保护') 'llms.txt 含机器接口与硬保护摘要'

  # schema 与真实 -EmitJson 产物对照（顶层字段 + 行字段 + 版本号）
  $t12scan = Join-Path $StateDir 't12-scan.json'
  [void](Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $t12scan, '-Scope', 'Broad', '-NoRules', '-Quiet'))
  $s12 = $null
  if (Test-Path $t12scan) { $s12 = Get-Content $t12scan -Raw -Encoding UTF8 | ConvertFrom-Json }
  $schScan = $null
  if (Test-Path (Join-Path $Root 'schemas\scan.schema.json')) { $schScan = Get-Content (Join-Path $Root 'schemas\scan.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
  Check ($null -ne $s12 -and $null -ne $schScan) 'scan.schema.json 与扫描产物都可解析'
  if ($s12 -and $schScan) {
    $missTop = @($schScan.required | Where-Object { $s12.PSObject.Properties.Name -notcontains $_ })
    Check ($missTop.Count -eq 0) 'scan.schema 顶层 required 字段全部真实存在' ($missTop -join ',')
    $row0 = @($s12.processes)[0]
    $missRow = @($schScan.definitions.row.required | Where-Object { $row0.PSObject.Properties.Name -notcontains $_ })
    Check ($missRow.Count -eq 0) 'scan.schema 行 required 字段全部真实存在' ($missRow -join ',')
    Check ([int]$s12.schema -eq 1) 'EmitJson schema 版本为 1（稳定契约）' ('schema=' + $s12.schema)
  }
  $cfgSchema = $null
  if (Test-Path (Join-Path $Root 'schemas\config.schema.json')) { $cfgSchema = Get-Content (Join-Path $Root 'schemas\config.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
  Check ($null -ne $cfgSchema -and (@($cfgSchema.definitions.rule.required) -contains 'action')) 'config.schema 定义了规则必填字段'
  $cfgReal = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $badRules = @()
  foreach ($r in @($cfgReal.selectRules)) {
    if (-not $r.name -or -not $r.match -or (@('suspend', 'idle', 'skip') -notcontains [string]$r.action)) { $badRules += [string]$r.name }
  }
  Check ($badRules.Count -eq 0) 'config.selectRules 全部符合 schema 约定' ($badRules -join ',')

  # examples：规则表/档案能被引擎真正加载；驱动脚本只读且不产生冻结会话
  $exScan = Join-Path $StateDir 't12-ex.json'
  $r = Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $exScan, '-Scope', 'Broad', '-RuleFile', (Join-Path $Root 'examples\rules.example.json'), '-Quiet')
  $exJ = $null
  if (Test-Path $exScan) { $exJ = Get-Content $exScan -Raw -Encoding UTF8 | ConvertFrom-Json }
  $rcEx = -1
  if ($null -ne $exJ) { $rcEx = [int]$exJ.ruleCount }
  Check ($r.Code -eq 0 -and $rcEx -eq 4) '示例规则表（4 条，含上下限门槛）可被 -RuleFile 加载' ('ruleCount=' + $rcEx + ' code=' + $r.Code)
  [void](Run-Engine $PausePs1 @('-EmitJson', '-JsonOut', $exScan, '-Profile', (Join-Path $Root 'examples\profile.example.json'), '-Quiet'))
  $exJ2 = Get-Content $exScan -Raw -Encoding UTF8 | ConvertFrom-Json
  Check ($exJ2.profile -match 'profile\.example\.json$' -and $exJ2.mode -eq 'Idle') '示例档案可被 -Profile 加载（mode=Idle）' ('profile=' + $exJ2.profile + ' mode=' + $exJ2.mode)
  $drive = Join-Path $Root 'examples\agent-drive.ps1'
  $errDrv = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($drive, [ref]$null, [ref]$errDrv)
  Check ($errDrv.Count -eq 0) 'agent-drive.ps1 语法通过' $(if ($errDrv.Count -gt 0) { $errDrv[0].Message } else { '' })
  $stateBeforeT12 = Test-Path $StateFile
  # 用 -Names 走确定性路径（CI runner 上绝大多数进程小于规则门槛，自动挑选可能为空，不该让用例受环境影响）
  $driveSel = Join-Path $StateDir 't12-drive-selection.txt'
  $driveOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $drive -Names gbmemballoon -SelectionFile $driveSel 2>&1
  $driveRc = $LASTEXITCODE
  $driveTxt = (($driveOut | ForEach-Object { $_.ToString() }) -join "`n")
  Check ($driveRc -eq 0 -and $driveTxt -match 'resume-non-system-processes\.ps1' -and $driveTxt -match 'NamesFile') 'agent-drive.ps1 默认只打印计划（只读；-Execute 才动手）' ('rc=' + $driveRc)
  Check (-not (Test-Path $StateFile) -or $stateBeforeT12) 'agent-drive.ps1 只读模式不产生冻结会话'
  $driveRaw = ''
  if (Test-Path $driveSel) { $driveRaw = Get-Content $driveSel -Raw -Encoding UTF8 }
  Check ($driveRaw -match 'gbmemballoon') 'agent-drive.ps1 写出名单文件（供引擎或人工复用）' ($driveRaw.Trim())
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
