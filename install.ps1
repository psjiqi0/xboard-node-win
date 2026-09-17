<#
  Xboard-Node 一键部署脚本 (Windows / 机器模式)
  ==============================================
  用法:
    手动启动(关闭窗口即停止):
      .\install.ps1 -PanelUrl "https://panel.example.com" -Token "通信密钥" -SID 1

    开机自动启动(注册为计划任务,开机即运行,无需登录):
      .\install.ps1 -PanelUrl "https://panel.example.com" -Token "通信密钥" -SID 1 -AutoStart

  参数说明:
    -PanelUrl   面板访问地址(必填,如 https://panel.example.com)
    -Token      面板「系统设置 → 通信设置」里的 Communication Key(必填)
    -SID        服务器管理的机器ID machine_id(必填,面板「服务器管理」中添加)
    -AutoStart  开关:注册 Windows 开机计划任务,开机自动运行(需以管理员运行)

  脚本将自动:
    1. 校验 xboard-node.exe 与本脚本同目录
    2. 以机器模式生成 config.yml(面板 URL / Token / machine_id)
    3a. 默认:后台启动节点,写入 pid 文件
    3b. -AutoStart:注册「开机自启」任务并立即启动,日志写入 xboard-node.log

  停止 / 卸载:
    停止任务:   Stop-ScheduledTask -TaskName XboardNode
    启动任务:   Start-ScheduledTask -TaskName XboardNode
    移除自启:   Unregister-ScheduledTask -TaskName XboardNode -Confirm:$false
    查询状态:   Get-ScheduledTask -TaskName XboardNode
#>
param(
  [Parameter(Mandatory = $true)][string]$PanelUrl,
  [Parameter(Mandatory = $true)][string]$Token,
  [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$SID,
  [switch]$AutoStart
)
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $root "xboard-node.exe"
if (-not (Test-Path -LiteralPath $exe)) {
  throw "未找到 $exe,请将本脚本与 xboard-node.exe 放在同一目录"
}

# 1. 生成机器模式配置
$logFile = Join-Path $root "xboard-node.log"
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
Write-Host "[OK] 已生成配置: $configPath"

$taskName = "XboardNode"

# 2. 停止旧实例 / 旧任务
$pidFile = Join-Path $root "xboard-node.pid"
if (Test-Path -LiteralPath $pidFile) {
  $oldPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue
  if ($oldPid) {
    $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($oldProc) { Stop-Process -Id $oldPid -Force; Write-Host "[OK] 已停止旧实例 pid=$oldPid" }
  }
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  Write-Host "[OK] 已移除旧的定时任务"
}

if ($AutoStart) {
  # 3a. 开机自启:注册计划任务(SYSTEM 身份,开机启动,无时长限制)
  if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "-AutoStart 需要管理员权限,请用「管理员身份」重新运行 PowerShell"
  }
  $action = New-ScheduledTaskAction -Execute $exe -Argument "-c config.yml" -WorkingDirectory $root
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName
  Write-Host "[OK] 已注册开机自启任务: $taskName(开机免登录自动运行)"
  Start-Sleep -Seconds 5

  $proc = Get-Process -Name "xboard-node" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) {
    Write-Host "[FAIL] 任务已注册但进程未检测到,请检查日志: $logFile" -ForegroundColor Red
    exit 1
  }
  Write-Host "[OK] Xboard-Node 已开机自启并运行 pid=$($proc.Id)"
  Write-Host "     日志: $logFile"
  Write-Host "     健康检查: http://<本机IP>:65530/healthz"
  Write-Host "     停止: Stop-ScheduledTask -TaskName $taskName"
  Write-Host "     移除自启: Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
} else {
  # 3b. 手动后台启动
  $errLog = Join-Path $root "xboard-node.err.log"
  $p = Start-Process -FilePath $exe -ArgumentList "-c config.yml" `
    -WorkingDirectory $root -WindowStyle Hidden `
    -RedirectStandardOutput $logFile -RedirectStandardError $errLog -PassThru
  $p.Id | Set-Content -LiteralPath $pidFile

  Start-Sleep -Seconds 5
  if ($p.HasExited) {
    Write-Host "[FAIL] 启动失败,退出码=$($p.ExitCode),错误日志: $errLog" -ForegroundColor Red
    exit 1
  }
  Write-Host "[OK] Xboard-Node 已启动 pid=$($p.Id)"
  Write-Host "     日志: $logFile"
  Write-Host "     健康检查: http://<本机IP>:65530/healthz"
  Write-Host "     停止: Stop-Process -Id $($p.Id)"
  Write-Host "     提示: 如需开机自启,请改用 -AutoStart 参数(管理员运行)"
}