<#
  Xboard-Node �键安装脚� (Windows / 隐蔽运行)
  ============================================
  用法:
    后台隐藏运行(关闭终端不�出, 无窗口):
      .\install.ps1 -PanelUrl "https://panel.example.com" -Token "�信密钥" -SID 1

    ��自启 + 隐蔽运行:
      .\install.ps1 -PanelUrl "https://panel.example.com" -Token "�信密钥" -SID 1 -AutoStart -Hidden -TaskName svcnet -Alias svcnet

    卸载(�止并移除):
      .\install.ps1 -Uninstall -TaskName svcnet -Alias svcnet

  参数说明:
    -PanelUrl   ����(必填, 安装时)
    -Token      �信密钥(必填, 安装时)
    -SID        �器ID machine_id(必填, 安装时)
    -AutoStart  注册计划任务, ��自启(SYSTEM 身份, 无�登录, 无窗口)
    -Hidden     计划任务�任务计划程序中隐藏(配合 -AutoStart)
    -TaskName   计划任务名称(默认 XboardNode), 可改成任意不显�的名字
    -Alias      进程别名: 复制 exe 为 <Alias>.exe 并运行,
                任务管理器进程列表显示为别名, �� xboard-node
    -Uninstall  �止并移除计划任务/进程
#>
param(
  [string]$PanelUrl = "",
  [string]$Token = "",
  [int]$SID = 0,
  [switch]$AutoStart,
  [switch]$Hidden,
  [string]$TaskName = "XboardNode",
  [string]$Alias = "",
  [switch]$Uninstall
)
$ErrorActionPreference = "Stop"

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseExe = Join-Path $root "xboard-node.exe"

# 计算实际运行的进程名/路径
$procName = "xboard-node"
$runExe   = $baseExe
if ($Alias) {
  $Alias = ($Alias -replace '[\\/:*?"<>|\s]', '').Trim()
  if ($Alias) {
    if (-not $Alias.ToLower().EndsWith(".exe")) { $Alias += ".exe" }
    $runExe   = Join-Path $root $Alias
    $procName = [System.IO.Path]::GetFileNameWithoutExtension($Alias)
  }
}

# ---------------- 卸载 ----------------
if ($Uninstall) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[OK] 已移除计划任务: $TaskName"
  }
  foreach ($n in @($procName, "xboard-node") | Select-Object -Unique) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
  Remove-Item (Join-Path $root "xboard-node.pid") -Force -ErrorAction SilentlyContinue
  Write-Host "[OK] 已�止进程"
  exit 0
}

if (-not $PanelUrl -or -not $Token -or $SID -lt 1) {
  throw "缺少参数: 请提供 -PanelUrl / -Token / -SID"
}
if (-not (Test-Path -LiteralPath $baseExe)) {
  throw "�找到 $baseExe, 请将�脚�与 xboard-node.exe 放�同�目录"
}

# ---------------- 生成配置 ----------------
$logFile   = Join-Path $root "xboard-node.log"
$logOutput = "info"
if ($AutoStart) { $logOutput = $logFile }

$config = @"
machine:
  machine_id: $SID
  token: "$Token"
panel:
  url: "$PanelUrl"
kernel:
  type: singbox
log:
  level: info
  output: $($logOutput -replace '\\', '/')
health_port: 65530
"@
$configPath = Join-Path $root "config.yml"
Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8
Write-Host "[OK] 已写入配置: $configPath"

# ---------------- �止旧的实例/任务 ----------------
$pidFile = Join-Path $root "xboard-node.pid"
if (Test-Path -LiteralPath $pidFile) {
  $oldPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue
  if ($oldPid) {
    $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($oldProc) { Stop-Process -Id $oldPid -Force; Write-Host "[OK] 已�止旧实例 pid=$oldPid" }
  }
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "[OK] 已移除旧计划任务"
}
foreach ($n in @($procName, "xboard-node") | Select-Object -Unique) {
  Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# 生成进程别名副�
if ($runExe -ne $baseExe) {
  Copy-Item -LiteralPath $baseExe -Destination $runExe -Force
  Write-Host "[OK] 已生成进程别名: $(Split-Path -Leaf $runExe)"
}

if ($AutoStart) {
  # ---------------- ��自启(计划任务) ----------------
  if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "-AutoStart �要管理员�限, 请用管理员身份打� PowerShell"
  }

  $action  = New-ScheduledTaskAction -Execute $runExe -Argument "-c config.yml" -WorkingDirectory $root
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $sargs = @{
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable         = $true
    ExecutionTimeLimit         = [TimeSpan]::Zero
  }
  if ($Hidden) { $sargs["Hidden"] = $true }
  $settings  = New-ScheduledTaskSettingsSet @sargs
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Write-Host "[OK] 已注册��自启计划任务: $TaskName (Hidden=$([bool]$Hidden), 进程名=$procName)"
  Start-Sleep -Seconds 5

  $proc = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) {
    Write-Host "[FAIL] 任务已注册但进程��测到, 请查�日志: $logFile" -ForegroundColor Red
    exit 1
  }
  Write-Host "[OK] Xboard-Node 已隐蔽运行 pid=$($proc.Id) (进程名: $procName)"
  Write-Host "     日志:     $logFile"
  Write-Host "     健康�查: http://<��IP>:65530/healthz"
  Write-Host "     �止:     Stop-ScheduledTask -TaskName $TaskName"
  Write-Host "     卸载:     .\install.ps1 -Uninstall -TaskName $TaskName -Alias $Alias"
} else {
  # ---------------- 手动后台运行(隐藏窗口) ----------------
  $errLog = Join-Path $root "xboard-node.err.log"
  $p = Start-Process -FilePath $runExe -ArgumentList "-c config.yml" `
    -WorkingDirectory $root -WindowStyle Hidden `
    -RedirectStandardOutput $logFile -RedirectStandardError $errLog -PassThru
  $p.Id | Set-Content -LiteralPath $pidFile

  Start-Sleep -Seconds 5
  if ($p.HasExited) {
    Write-Host "[FAIL] 启动失败, �出码=$($p.ExitCode), 查�日志: $errLog" -ForegroundColor Red
    exit 1
  }
  Write-Host "[OK] Xboard-Node 已�后台隐藏运行 pid=$($p.Id) (进程名: $procName)"
  Write-Host "     日志:     $logFile"
  Write-Host "     健康�查: http://<��IP>:65530/healthz"
  Write-Host "     �止:     Stop-Process -Id $($p.Id)"
  Write-Host "     提示: �要��自启, 请加 -AutoStart 参数(管理员�限)"
}
