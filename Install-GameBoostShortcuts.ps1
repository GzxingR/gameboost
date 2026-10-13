<#
  GameBoost · 生成桌面快捷方式并绑定热键
    Ctrl+Alt+P = 暂停（先跑 -DryRun 更安全：把 -DryRun 加到 pause 的 Arguments 里即可）
    Ctrl+Alt+R = 恢复   ← 当终端与宿主进程也被冻结时，这是唯一的恢复入口
  注意：本文件须以 UTF-8 with BOM 保存。
#>
[CmdletBinding()]
param([switch]$SkipHotkeys)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell

$defs = @(
  @{ Name = 'GameBoost 暂停非系统进程.lnk'; Target = (Join-Path $Root 'GameBoost.pause.cmd');  Desc = '冻结非系统进程，释放内存与 CPU（游戏前）'; Key = 'CTRL+ALT+P' },
  @{ Name = 'GameBoost 恢复非系统进程.lnk'; Target = (Join-Path $Root 'GameBoost.resume.cmd'); Desc = '恢复被 GameBoost 冻结的进程'; Key = 'CTRL+ALT+R' }
)
foreach ($d in $defs) {
  $lnkPath = Join-Path $Desktop $d.Name
  $lnk = $shell.CreateShortcut($lnkPath)
  $lnk.TargetPath = $d.Target
  $lnk.WorkingDirectory = $Root
  $lnk.Description = $d.Desc
  $lnk.IconLocation = '%SystemRoot%\System32\shell32.dll,137'
  $lnk.WindowStyle = 1
  if (-not $SkipHotkeys) { try { $lnk.Hotkey = $d.Key } catch { Write-Host ('热键设置失败: ' + $d.Key) -ForegroundColor Yellow } }
  $lnk.Save()
  Write-Host ('已创建: ' + $lnkPath) -ForegroundColor Green
}
Write-Host '完成。若热键与其他软件冲突，请改 $defs 里的组合键后重跑本脚本。' -ForegroundColor Cyan
