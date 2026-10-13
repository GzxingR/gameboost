<#
  GameBoost 控制台 · Windows GUI（WinForms，零外部依赖）
  设计原则：GUI 不重复实现任何安全逻辑，全部通过调用已实测的 pause/resume 脚本完成，
            进程清单来自 pause.ps1 -EmitJson（同一套保护名单/范围判定），避免两份名单漂移。
  自检：GameBoost.GUI.ps1 -SelfTest   会自动走完 扫描 → 勾选 → 暂停 → 恢复 并写报告
  注意：本文件须以 UTF-8 with BOM 保存。
#>
[CmdletBinding()]
param([switch]$NoElevate, [switch]$SelfTest, [string]$SelfTestTarget = '')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$PausePs1  = Join-Path $Root 'pause-non-system-processes.ps1'
$ResumePs1 = Join-Path $Root 'resume-non-system-processes.ps1'
$StateFile = Join-Path (Join-Path $Root 'state') 'current.json'
$ScanFile  = Join-Path (Join-Path $Root 'state') 'scan.json'
$LogDir    = Join-Path $Root 'logs'
foreach ($d in @((Split-Path $StateFile -Parent), $LogDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null } }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate -and -not $SelfTest) {
  try { Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $MyInvocation.MyCommand.Path); exit 0 } catch { }
}

$script:busy = $false
$script:Report = New-Object System.Collections.Generic.List[string]
function Note([string]$m) { $script:Report.Add($m); if ($SelfTest) { Write-Output $m } }

# ---------------------------------------------------------------- 状态
function Get-SessionInfo {
  if (-not (Test-Path $StateFile)) { return [pscustomobject]@{ active = $false; n = 0; idle = 0; mb = 0; started = ''; scope = ''; mode = '' } }
  try {
    $j = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $sus  = @($j.entries | Where-Object { $_.mode -eq 'Suspend' -and [int]$_.suspendCount -gt 0 })
    $idle = @($j.entries | Where-Object { $_.mode -eq 'Idle' })
    $mb = 0; foreach ($e in @($j.entries)) { $mb += [int]$e.wsMB }
    return [pscustomobject]@{ active = $true; n = $sus.Count; idle = $idle.Count; mb = $mb; started = $j.startedUtc; scope = $j.scope; mode = $j.mode }
  } catch { return [pscustomobject]@{ active = $false; n = 0; idle = 0; mb = 0; started = ''; scope = ''; mode = '' } }
}

# ---------------------------------------------------------------- 控件
$font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'GameBoost 控制台 — 游戏前冻结后台进程'
$form.Size = New-Object System.Drawing.Size(1000, 720)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(880, 620)
$form.Font = $font
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
$form.ForeColor = [System.Drawing.Color]::Gainsboro

function New-Label($text, $x, $y, $w, $h) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, $h)
  $l.ForeColor = [System.Drawing.Color]::Gainsboro
  return $l
}
function New-Button($text, $x, $y, $w) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 32)
  $b.FlatStyle = 'Flat'; $b.BackColor = [System.Drawing.Color]::FromArgb(58, 58, 64); $b.ForeColor = [System.Drawing.Color]::White
  $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
  return $b
}

$lblStatus = New-Label '状态：读取中…' 14 12 950 22
$lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblStatus)

$form.Controls.Add((New-Label '模式' 14 46 34 20))
$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.DropDownStyle = 'DropDownList'; $cmbMode.Location = New-Object System.Drawing.Point(50, 43); $cmbMode.Size = New-Object System.Drawing.Size(116, 22)
[void]$cmbMode.Items.AddRange(@('Suspend 真冻结', 'Idle 软模式')); $cmbMode.SelectedIndex = 0
$form.Controls.Add($cmbMode)

$form.Controls.Add((New-Label '范围' 178 46 34 20))
$cmbScope = New-Object System.Windows.Forms.ComboBox
$cmbScope.DropDownStyle = 'DropDownList'; $cmbScope.Location = New-Object System.Drawing.Point(214, 43); $cmbScope.Size = New-Object System.Drawing.Size(150, 22)
[void]$cmbScope.Items.AddRange(@('Safe 白名单（稳妥）', 'Broad 全部用户进程')); $cmbScope.SelectedIndex = 0
$form.Controls.Add($cmbScope)

$chkAgent = New-Object System.Windows.Forms.CheckBox
$chkAgent.Text = '包含宿主与编辑器进程（默认保护，冻结后需热键恢复）'; $chkAgent.Location = New-Object System.Drawing.Point(376, 45); $chkAgent.Size = New-Object System.Drawing.Size(330, 20)
$chkAgent.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($chkAgent)

$chkVisible = New-Object System.Windows.Forms.CheckBox
$chkVisible.Text = '跳过有可见窗口的进程（避免窗口假死）'; $chkVisible.Location = New-Object System.Drawing.Point(712, 45); $chkVisible.Size = New-Object System.Drawing.Size(270, 20)
$chkVisible.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($chkVisible)

$form.Controls.Add((New-Label '自动恢复' 14 76 60 20))
$chkAutoExe = New-Object System.Windows.Forms.CheckBox
$chkAutoExe.Text = '游戏进程名'; $chkAutoExe.Location = New-Object System.Drawing.Point(76, 75); $chkAutoExe.Size = New-Object System.Drawing.Size(92, 20)
$chkAutoExe.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($chkAutoExe)
$txtAutoExe = New-Object System.Windows.Forms.TextBox
$txtAutoExe.Location = New-Object System.Drawing.Point(170, 73); $txtAutoExe.Size = New-Object System.Drawing.Size(150, 22)
$txtAutoExe.BackColor = [System.Drawing.Color]::FromArgb(48, 48, 54); $txtAutoExe.ForeColor = [System.Drawing.Color]::White; $txtAutoExe.BorderStyle = 'FixedSingle'
$form.Controls.Add($txtAutoExe)
$chkAutoMin = New-Object System.Windows.Forms.CheckBox
$chkAutoMin.Text = '或'; $chkAutoMin.Location = New-Object System.Drawing.Point(332, 75); $chkAutoMin.Size = New-Object System.Drawing.Size(34, 20)
$chkAutoMin.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($chkAutoMin)
$numAutoMin = New-Object System.Windows.Forms.NumericUpDown
$numAutoMin.Location = New-Object System.Drawing.Point(368, 73); $numAutoMin.Size = New-Object System.Drawing.Size(66, 22)
$numAutoMin.Minimum = 1; $numAutoMin.Maximum = 1440; $numAutoMin.Value = 120
$numAutoMin.BackColor = [System.Drawing.Color]::FromArgb(48, 48, 54); $numAutoMin.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($numAutoMin)
$form.Controls.Add((New-Label '分钟后自动恢复' 440 76 130 20))

$btnScan   = New-Button '扫描进程 (F5)' 14 104 132
$btnApply  = New-Button '暂停所选 (F9)' 152 104 132
$btnResume = New-Button '恢复全部 (F10)' 290 104 132
$btnStatus = New-Button '查看冻结状态' 428 104 122
$btnOpen   = New-Button '打开目录' 556 104 96
foreach ($b in @($btnScan, $btnApply, $btnResume, $btnStatus, $btnOpen)) { $form.Controls.Add($b) }
$lblSel = New-Label '未选择' 664 112 320 20
$form.Controls.Add($lblSel)

$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(14, 144); $lv.Size = New-Object System.Drawing.Size(960, 380)
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true
$lv.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28); $lv.ForeColor = [System.Drawing.Color]::Gainsboro
$lv.BorderStyle = 'FixedSingle'; $lv.HideSelection = $false
$lv.Anchor = 'Top,Left,Right,Bottom'
[void]$lv.Columns.Add('名称', 300)
[void]$lv.Columns.Add('进程数', 70, 'Center')
[void]$lv.Columns.Add('内存 MB', 90, 'Right')
[void]$lv.Columns.Add('会话', 60, 'Center')
[void]$lv.Columns.Add('状态', 210)
$form.Controls.Add($lv)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(14, 532); $txtLog.Size = New-Object System.Drawing.Size(960, 130)
$txtLog.ReadOnly = $true; $txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 24); $txtLog.ForeColor = [System.Drawing.Color]::Silver
$txtLog.BorderStyle = 'FixedSingle'; $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($txtLog)

function Log([string]$m, [string]$c = 'Silver') {
  $txtLog.SelectionStart = $txtLog.TextLength
  $txtLog.SelectionColor = [System.Drawing.Color]::FromName($c)
  $txtLog.AppendText(((Get-Date -Format 'HH:mm:ss') + '  ' + $m + [Environment]::NewLine))
  $txtLog.SelectionStart = $txtLog.TextLength
  $txtLog.ScrollToCaret()
  if ($SelfTest) { Note $m }
}

function Refresh-Status {
  $s = Get-SessionInfo
  if ($s.active -and ($s.n -gt 0 -or $s.idle -gt 0)) {
    $lblStatus.Text = ('状态：有冻结会话 — 已冻结 {0} 个进程 / 软模式 {1} 个；累计工作集 {2} MB；Scope={3} Mode={4}' -f $s.n, $s.idle, $s.mb, $s.scope, $s.mode)
    $lblStatus.ForeColor = [System.Drawing.Color]::Orange
  } else {
    if ($isAdmin) { $lblStatus.Text = '状态：当前没有冻结会话（一切正常）　[管理员]' } else { $lblStatus.Text = '状态：当前没有冻结会话　[非管理员：部分进程可能无法操作]' }
    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
  }
}

function Get-NewLogFiles($after) {
  if (-not (Test-Path $LogDir)) { return @() }
  return @(Get-ChildItem $LogDir -Filter '*.log' | Where-Object { $_.LastWriteTime -ge $after } | Sort-Object LastWriteTime)
}
function Get-ScopeArg { if ($cmbScope.SelectedIndex -eq 1) { return 'Broad' } else { return 'Safe' } }
function Get-ModeArg  { if ($cmbMode.SelectedIndex -eq 1)  { return 'Idle' }  else { return 'Suspend' } }
function Get-CheckedNames {
  $names = @()
  foreach ($it in $lv.CheckedItems) { if ($it.Tag -and $it.Tag.state -eq 'candidate') { $names += $it.Tag.name } }
  return $names
}
function Pump([int]$ms) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds $ms }

function Do-Scan {
  if ($script:busy) { Log '正在忙，稍后再扫描。' 'OrangeRed'; return }
  $script:busy = $true; $btnScan.Enabled = $false
  Log ('▶ 扫描进程（Scope=' + (Get-ScopeArg) + '）') 'DeepSkyBlue'
  try {
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PausePs1, '-EmitJson', '-JsonOut', $ScanFile, '-Scope', (Get-ScopeArg), '-Quiet')
    if ($chkAgent.Checked) { $args += '-IncludeAgent' }
    if ($chkVisible.Checked) { $args += '-SkipVisible' }
    $p = Start-Process powershell -ArgumentList $args -NoNewWindow -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt 120) { Pump 60 }
    if (-not (Test-Path $ScanFile)) { Log '扫描失败：未生成清单文件。' 'Red'; $script:busy = $false; $btnScan.Enabled = $true; return }
    $j = Get-Content $ScanFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $lv.BeginUpdate(); $lv.Items.Clear()
    foreach ($r in @($j.processes | Sort-Object -Property @{ Expression = { [int]$_.wsMB }; Descending = $true })) {
      $it = New-Object System.Windows.Forms.ListViewItem([string]$r.name)
      [void]$it.SubItems.Add([string]$r.n)
      [void]$it.SubItems.Add([string]$r.wsMB)
      [void]$it.SubItems.Add((($r.sessions) -join '/'))
      if ($r.state -eq 'candidate') { [void]$it.SubItems.Add('可冻结'); $it.ForeColor = [System.Drawing.Color]::Gainsboro }
      elseif ($r.state -eq 'protected') { [void]$it.SubItems.Add('受保护（系统/反作弊）'); $it.ForeColor = [System.Drawing.Color]::Gray }
      else { [void]$it.SubItems.Add('不在当前范围'); $it.ForeColor = [System.Drawing.Color]::DimGray }
      $it.Tag = $r
      [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    $candRows = @($j.processes | Where-Object { $_.state -eq 'candidate' })
    $candMB = 0; foreach ($c in $candRows) { $candMB += [int]$c.wsMB }
    Log ('扫描完成：进程总数 {0}，可冻结 {1} 个进程 / {2} 个名字，预计回收 {3} MB' -f $j.totalProcs, $j.candidateProcs, $candRows.Count, $candMB) 'LightGreen'
    Note ('SCAN rows=' + $lv.Items.Count + ' candidates=' + $candRows.Count + ' candidateMB=' + $candMB + ' protected=' + @($j.processes | Where-Object { $_.state -eq 'protected' }).Count)
  } catch { Log ('扫描出错：' + $_.Exception.Message) 'Red' }
  $script:busy = $false; $btnScan.Enabled = $true
  Refresh-Status
}

# 确定性拦截：任何受保护/超范围项只要被勾上就立刻取消（不依赖 ItemCheck 事件是否触发）
$script:repairing = $false
function Repair-Checks {
  if ($script:repairing) { return 0 }
  $script:repairing = $true
  $fixed = 0
  try {
    foreach ($it in $lv.Items) { if ($it.Checked -and (-not $it.Tag -or $it.Tag.state -ne 'candidate')) { $it.Checked = $false; $fixed++ } }
  } finally { $script:repairing = $false }
  if ($fixed -gt 0) { Log ('已自动取消 ' + $fixed + ' 个受保护/超范围项的勾选（反作弊、杀软、系统件不可冻结）') 'Orange' }
  return $fixed
}

function Do-Apply {
  [void](Repair-Checks)
  $names = Get-CheckedNames
  if ($names.Count -eq 0) { Log '没有勾选任何可冻结项（受保护项无法勾选）。' 'OrangeRed'; return }
  $selFile = Join-Path (Split-Path $StateFile -Parent) 'selection.txt'
  [IO.File]::WriteAllLines($selFile, [string[]]$names, (New-Object Text.UTF8Encoding($false)))
  $args = @('-Scope', (Get-ScopeArg), '-Mode', (Get-ModeArg), '-Yes', '-NamesFile', $selFile)
  if ($chkAgent.Checked) { $args += '-IncludeAgent' }
  if ($chkVisible.Checked) { $args += '-SkipVisible' }
  if ($chkAutoExe.Checked -and $txtAutoExe.Text.Trim()) { $args += @('-ResumeWhenProcessExits', $txtAutoExe.Text.Trim()) }
  if ($chkAutoMin.Checked) { $args += @('-AutoResumeMinutes', [string][int]$numAutoMin.Value) }
  Invoke-Engine $args ('冻结 ' + $names.Count + ' 个应用：' + ($names -join ', '))
}

function Invoke-Engine([string[]]$scriptArgs, [string]$title) {
  if ($script:busy) { Log '已有任务在运行，请等待完成。' 'OrangeRed'; return }
  $script:busy = $true
  foreach ($b in @($btnScan, $btnApply, $btnResume, $btnStatus)) { $b.Enabled = $false }
  $last = @(Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1)
  $beforeTime = Get-Date
  Log ('▶ ' + $title) 'DeepSkyBlue'
  try {
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PausePs1) + $scriptArgs
    $p = Start-Process powershell -ArgumentList $args -NoNewWindow -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt 180) { Pump 80 }
    if (-not $p.HasExited) { Log '超时（180 秒）。' 'OrangeRed' }
    foreach ($f in (Get-NewLogFiles $beforeTime)) { foreach ($line in (Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) { Log ('  ' + $line) 'Silver' } }
  } catch { Log ('执行出错：' + $_.Exception.Message) 'Red' }
  $script:busy = $false
  foreach ($b in @($btnScan, $btnApply, $btnResume, $btnStatus)) { $b.Enabled = $true }
  Refresh-Status
}

function Do-Resume {
  $s = Get-SessionInfo
  if (-not $s.active) { Log '没有待恢复的会话。' 'Orange'; return }
  if ($script:busy) { Log '正在忙，稍后再试。' 'OrangeRed'; return }
  $script:busy = $true
  Log ('▶ 恢复全部（冻结 {0} 个 / 软模式 {1} 个，只恢复本工具冻结过的进程）' -f $s.n, $s.idle) 'DeepSkyBlue'
  try {
    $p = Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $ResumePs1, '-Yes') -NoNewWindow -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt 180) { Pump 80 }
    $lg = @(Get-ChildItem $LogDir -Filter 'resume-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1)
    if ($lg.Count -gt 0) { foreach ($line in (Get-Content $lg[0].FullName -Encoding UTF8)) { Log ('  ' + $line) } }
  } catch { Log ('恢复出错：' + $_.Exception.Message) 'Red' }
  $script:busy = $false
  Refresh-Status
}

function Do-Status {
  $s = Get-SessionInfo
  if (-not $s.active) { Log '当前没有冻结会话。' 'LightGreen'; return }
  Log ('冻结会话：Scope=' + $s.scope + ' Mode=' + $s.mode + ' 开始于 ' + $s.started + '；Suspend ' + $s.n + ' / Idle ' + $s.idle + '；累计 ' + $s.mb + ' MB') 'LightGreen'
  $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $ResumePs1 -Status -Quiet 2>&1
  foreach ($line in $o) { Log ('  ' + $line.ToString().TrimEnd([char]13)) }
}

$btnScan.Add_Click({ Do-Scan })
$btnApply.Add_Click({ Do-Apply })
$btnResume.Add_Click({ Do-Resume })
$btnStatus.Add_Click({ Do-Status })
$btnOpen.Add_Click({ Start-Process explorer.exe $Root })
$lv.Add_ItemCheck({ param($sender, $e) $it = $lv.Items[$e.Index]; if (-not $it.Tag -or $it.Tag.state -ne 'candidate') { $e.NewValue = $e.CurrentValue } })
$lv.Add_ItemChecked({
  if (-not $script:repairing) { [void](Repair-Checks) }
  $n = @(Get-CheckedNames)
  if ($n.Count -eq 0) { $lblSel.Text = '未选择' } else {
    $mb = 0; foreach ($it in $lv.CheckedItems) { if ($it.Tag.state -eq 'candidate') { $mb += [int]$it.Tag.wsMB } }
    $lblSel.Text = ('已选 ' + $n.Count + ' 个应用，预计回收 ' + $mb + ' MB')
  }
})
$form.KeyPreview = $true
$form.Add_KeyDown({
  param($sender, $e)
  if ($e.KeyCode -eq 'F5') { Do-Scan; $e.Handled = $true }
  elseif ($e.KeyCode -eq 'F9') { Do-Apply; $e.Handled = $true }
  elseif ($e.KeyCode -eq 'F10') { Do-Resume; $e.Handled = $true }
})
$form.Add_Shown({
  Log 'GameBoost 控制台就绪。引擎：pause/resume 脚本（四层保护：IsProcessCritical / 名字黑名单含反作弊 / 自身进程链 / 前台全屏兜底）' 'LightGreen'
  if (-not $isAdmin) { Log '未以管理员运行：部分进程可能无法操作。' 'Orange' }
  Refresh-Status
  Do-Scan
})

# ---------------------------------------------------------------- 自检模式
if ($SelfTest) {
  $target = $SelfTestTarget
  if (-not $target) { $target = 'PING' }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [void]$form.Handle
  Note ('GUI-SELFTEST start target=' + $target + ' admin=' + $isAdmin)
  Note ('form.Text=[' + $form.Text + '] controls=' + $form.Controls.Count + ' listRows(before scan)=' + $lv.Items.Count)
  $cmbScope.SelectedIndex = 1        # Broad，让测试进程成为候选
  Do-Scan
  Note ('listRows(after scan)=' + $lv.Items.Count + ' candidateDesc=' + $lblSel.Text)
  $hit = $null
  foreach ($it in $lv.Items) { if ($it.Tag -and $it.Tag.name -ieq $target) { $hit = $it; break } }
  if (-not $hit) { Note ('FAIL 清单里找不到 ' + $target); $form.Dispose(); exit 2 }
  Note ('found target row: name=' + $hit.Tag.name + ' n=' + $hit.Tag.n + ' wsMB=' + $hit.Tag.wsMB + ' state=' + $hit.Tag.state)
  # 受保护项不可勾选：先验证拦截
  $protRow = $null
  foreach ($it in $lv.Items) { if ($it.Tag -and $it.Tag.state -eq 'protected') { $protRow = $it; break } }
  if ($protRow) {
    $protRow.Checked = $true
    $checkedNow = @($lv.CheckedItems | ForEach-Object { $_.Tag.name })
    [void](Repair-Checks)
    $checkedAfter = @($lv.CheckedItems | ForEach-Object { $_.Tag.name })
    Note ('protected-check guard: row=' + $protRow.Tag.name + ' checkedFlag=' + $protRow.Checked + ' checkedItems(after repair)=[' + ($checkedAfter -join ',') + ']')
    $protRow.Checked = $false
  }
  $hit.Checked = $true
  Note ('selected=' + ((Get-CheckedNames) -join ',') + ' label=[' + $lblSel.Text + ']')
  Do-Apply
  $j = $null
  if (Test-Path $StateFile) { $j = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
  if ($j) {
    foreach ($e in @($j.entries)) { Note ('journal: ' + $e.name + ' pid=' + $e.pid + ' mode=' + $e.mode + ' suspendCount=' + $e.suspendCount + ' origPrio=' + $e.origPrio + ' mask=' + $e.mask) }
    $susp = 0
    foreach ($e in @($j.entries)) {
      if ($e.mode -eq 'Suspend') {
        $pp = Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue
        if ($pp) { $susp += @($pp.Threads | Where-Object { $_.ThreadState -eq 'Wait' -and $_.WaitReason -eq 'Suspended' }).Count }
      }
    }
    Note ('suspendedThreadsObserved=' + $susp)
  } else { Note 'FAIL 未生成会话文件' }
  Note ('statusLabelAfterApply=[' + $lblStatus.Text + ']')
  Do-Resume
  Note ('stateFileExistsAfterResume=' + (Test-Path $StateFile))
  $rest = 0
  foreach ($e in @($j.entries)) {
    $pp = Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue
    if ($pp) { $rest += @($pp.Threads | Where-Object { $_.ThreadState -eq 'Wait' -and $_.WaitReason -eq 'Suspended' }).Count }
  }
  Note ('suspendedThreadsAfterResume=' + $rest)
  Note ('statusLabelAfterResume=[' + $lblStatus.Text + ']')
  Note ('logLinesCaptured=' + $script:Report.Count)
  Note ('elapsedSeconds=' + [math]::Round($sw.Elapsed.TotalSeconds, 1))
  $out = Join-Path (Split-Path $StateFile -Parent) 'gui-selftest.txt'
  [IO.File]::WriteAllLines($out, $script:Report.ToArray(), (New-Object Text.UTF8Encoding($false)))
  Note ('reportSaved=' + $out)
  $form.Dispose()
  exit 0
}

[void]$form.ShowDialog()
