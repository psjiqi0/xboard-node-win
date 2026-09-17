<#
  Xboard-Node 一键部署脚本 (Windows / 机器模式)
  ==============================================
  用法:
    .\install.ps1 -PanelUrl "https://panel.example.com" -Token "通信密钥" -SID 1

  参数说明:
    -PanelUrl  面板访问地址(必填,如 https://panel.example.com)
    -Token     面板「系统设置 → 通信设置」里的 Communication Key(必填)
    -SID       服务器管理的机器ID machine_id(必填,面板「服务器管理」中添加)

  脚本将自动:
    1. 校验 xboard-node.exe 与本脚本同目录
    2. 以机器模式生成 config.yml(面板 URL / Token / machine_id)
    3. 后台启动节点,写入 pid 文件,便于停止 / 重启
#>
param(
  [Parameter(Mandatory = $true)][string]$PanelUrl,
  [Parameter(Mandatory = $true)][string]$Token,
  [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$SID
)
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $root "xboard-node.exe"
if (-not (Test-Path -LiteralPath $exe)) {
  throw "未找到 $exe,请将本脚本与 xboard-node.exe 放在同一目录"
}

# 1. 生成机器模式配置
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
health_port: 65530
"@
$configPath = Join-Path $root "config.yml"
Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8
Write-Host "[OK] 已生成配置: $configPath"

# 2. 停止旧实例(如果存在)
$pidFile = Join-Path $root "xboard-node.pid"
if (Test-Path -LiteralPath $pidFile) {
  $oldPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue
  if ($oldPid) {
    $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($oldProc) { Stop-Process -Id $oldPid -Force; Write-Host "[OK] 已停止旧实例 pid=$oldPid" }
  }
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

# 3. 后台启动
$outLog = Join-Path $root "xboard-node.log"
$errLog = Join-Path $root "xboard-node.err.log"
$p = Start-Process -FilePath $exe -ArgumentList "-c config.yml" `
  -WorkingDirectory $root -WindowStyle Hidden `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
$p.Id | Set-Content -LiteralPath $pidFile

Start-Sleep -Seconds 5
if ($p.HasExited) {
  Write-Host "[FAIL] 启动失败,退出码=$($p.ExitCode),错误日志: $errLog" -ForegroundColor Red
  exit 1
}

Write-Host "[OK] Xboard-Node 已启动 pid=$($p.Id)"
Write-Host "     日志: $outLog"
Write-Host "     健康检查: http://<本机IP>:65530/healthz"
Write-Host "     停止: Stop-Process -Id $($p.Id)"