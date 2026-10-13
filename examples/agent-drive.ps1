<#
  GameBoost · 可编程驱动示例（给脚本 / AI 代理 / 自动化用）
  ---------------------------------------------------------------
  它做四件事：
    1) 调 pause.ps1 -EmitJson 拿到「清单 + 每行规则判定」（只读，不改动任何进程）
    2) 按规则挑出要处理的进程名（默认只挑 action=suspend；-IncludeIdle 连软模式项一起挑）
    3) 把名单写成文件，并打印"将会执行什么"
    4) 只有显式加 -Execute 才真正冻结；-Resume 只恢复这份名单里的名字（其余继续冻结）

  安全：本脚本自己不做任何保护判定——全部复用引擎（硬保护、指纹校验都在引擎里）。
        除此之外它什么都不动系统。默认（不加 -Execute/-Resume）是纯只读的。
  依赖：PowerShell 5.1；脚本须与 pause/resume 脚本位于同一项目目录（默认自动推断仓库根）。

  用法：
    .\examples\agent-drive.ps1                          # 只看计划（安全，推荐先跑）
    .\examples\agent-drive.ps1 -IncludeIdle             # 软模式项也算进来
    .\examples\agent-drive.ps1 -Profile '游戏前'         # 按档案决策
    .\examples\agent-drive.ps1 -Execute                 # 真正冻结（等价于 GUI 的「暂停所选」）
    .\examples\agent-drive.ps1 -Resume                  # 只恢复上次这份名单，其余继续冻结
    .\examples\agent-drive.ps1 -Names 'chrome','Weixin' # 不用扫描，直接处理指定名字
#>
[CmdletBinding()]
param(
  [string[]]$Names,
  [string]$Profile,
  [ValidateSet('Safe','Broad','All')][string]$Scope = 'Broad',
  [switch]$IncludeIdle,
  [switch]$Execute,
  [switch]$Resume,
  [string]$SelectionFile,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$PausePs1  = Join-Path $Root 'pause-non-system-processes.ps1'
$ResumePs1 = Join-Path $Root 'resume-non-system-processes.ps1'
$StateDir  = Join-Path $Root 'state'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir -Force | Out-Null }
if (-not $SelectionFile) { $SelectionFile = Join-Path $StateDir 'agent-selection.txt' }
foreach ($f in @($PausePs1, $ResumePs1)) { if (-not (Test-Path $f)) { throw ('找不到引擎脚本: ' + $f + '（用 -Root 指定项目根目录）') } }

function Write-Head([string]$t) { Write-Host ''; Write-Host ('=== ' + $t + ' ===') -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1) 取名单
$wanted = @()
if ($Names) {
  $wanted = @($Names | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
  Write-Head '使用命令里显式给出的名字'
  Write-Host ('  ' + ($wanted -join ', '))
} else {
  $scanPath = Join-Path $StateDir 'agent-scan.json'
  $engArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PausePs1, '-EmitJson', '-JsonOut', $scanPath, '-Scope', $Scope, '-Quiet')
  if ($Profile) { $engArgs += @('-Profile', $Profile) }
  Write-Head '扫描（只读：只生成清单，不动任何进程）'
  Write-Host ('  Scope=' + $Scope + $(if ($Profile) { '  档案=' + $Profile } else { '  档案=默认规则表' })) -ForegroundColor DarkGray
  & powershell @engArgs | Out-Null
  if (-not (Test-Path $scanPath)) { throw '扫描失败：未生成清单文件（检查 -Scope/-Profile 是否正确）' }
  $scan = Get-Content $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $take = @('suspend'); if ($IncludeIdle) { $take += 'idle' }
  $rows = @($scan.processes | Where-Object {
      $_.state -eq 'candidate' -and (
        (($_.action -eq '' -or $null -eq $_.action) -and ($take -contains 'suspend')) -or
        ($take -contains [string]$_.action)
      )
    } | Sort-Object -Property @{ Expression = { [int]$_.wsMB }; Descending = $true })
  Write-Host ('  规则条数=' + $scan.ruleCount + '  候选名字=' + @($scan.processes | Where-Object { $_.state -eq 'candidate' }).Count + '  本次将处理=' + $rows.Count) -ForegroundColor DarkGray
  Write-Host ''
  Write-Host ('  {0,-28} {1,8}  {2,-8} {3}' -f '名称', '内存MB', '动作', '命中的规则') -ForegroundColor DarkGray
  foreach ($r in $rows) {
    Write-Host ('  {0,-28} {1,8}  {2,-8} {3}' -f $r.name, $r.wsMB, $(if ($r.action) { $r.action } else { 'suspend' }), $(if ($r.rule) { $r.rule } else { '(默认)' }))
  }
  $wanted = @($rows | ForEach-Object { [string]$_.name })
}

if ($wanted.Count -eq 0) { Write-Host '没有需要处理的进程名，结束。' -ForegroundColor Yellow; exit 0 }

# ---------------------------------------------------------------- 2) 写名单
[IO.File]::WriteAllLines($SelectionFile, [string[]]$wanted, (New-Object Text.UTF8Encoding($false)))
Write-Head '名单已写入（引擎按进程名整组处理）'
Write-Host ('  ' + $SelectionFile + '  (' + $wanted.Count + ' 个名字)') -ForegroundColor DarkGray

# ---------------------------------------------------------------- 3) 执行 / 打印计划
if ($Resume) {
  $engArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ResumePs1, '-Yes')
  foreach ($n in $wanted) { $engArgs += @('-Only', $n) }
  Write-Head '选择性恢复（只恢复这份名单，其余继续保持冻结）'
  & powershell @engArgs
  Write-Host ('  退出码=' + $LASTEXITCODE) -ForegroundColor DarkGray
  exit $LASTEXITCODE
}

if ($Execute) {
  $engArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PausePs1, '-Scope', $Scope, '-NamesFile', $SelectionFile, '-Yes')
  Write-Head '执行冻结（显式名单优先于规则表；硬保护与档案 exclude 仍然生效）'
  & powershell @engArgs
  Write-Host ('  退出码=' + $LASTEXITCODE) -ForegroundColor DarkGray
  Write-Host '  玩完恢复：.\resume-non-system-processes.ps1 -Yes   或本脚本 -Resume' -ForegroundColor DarkGray
  exit $LASTEXITCODE
}

Write-Head '计划（未执行）'
Write-Host '  冻结这次名单：' -ForegroundColor DarkGray
Write-Host ('    .\pause-non-system-processes.ps1 -Scope ' + $Scope + ' -NamesFile "' + $SelectionFile + '" -Yes')
Write-Host '  只恢复这份名单（其余继续冻结）：' -ForegroundColor DarkGray
Write-Host ('    .\resume-non-system-processes.ps1' + (($wanted | ForEach-Object { ' -Only "' + $_ + '"' }) -join '') + ' -Yes')
Write-Host '  想直接执行：给本脚本加 -Execute（冻结）或 -Resume（恢复）' -ForegroundColor DarkGray
exit 0
