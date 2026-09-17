# xboard-node-win

Xboard-Node 的 **Windows 版** 一键部署仓库。基于 [cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node)(双内核:sing-box / xray-core),附带编译好的 `xboard-node.exe`(已启用 `with_quic with_utls with_wireguard with_acme with_clash_api` 全部特性)和一键部署脚本。

## 特性

- 协议:v2ray 全家桶 / Trojan / Shadowsocks / Hysteria2 / TUIC / AnyTLS
- 同步:WebSocket 推送 + REST 轮询双通道
- 控制:限速、设备数限制、在线 IP 追踪、热更新
- 部署模式:节点模式(node)、机器模式(machine)、独立模式(standalone)
- 多实例:单进程绑定多面板 / 多节点(Win 使用多节点模式)

## 快速上手(机器模式一键部署)

> 前置:本机需先部署好 [Xboard](https://github.com/cedar2025/Xboard) 面板。

1. 下载本仓库,解压后进入目录。
2. 管理员 PowerShell 中执行一键命令,传入 3 个变量:

```powershell
# 开机自动启动(推荐,需管理员;注:-AutoStart 即注册开机自启计划任务)
.\install.ps1 -PanelUrl "https://panel.example.com" -Token "你的通信密钥" -SID 1 -AutoStart

# 仅本次手动运行(关闭即停止,无需管理员)
.\install.ps1 -PanelUrl "https://panel.example.com" -Token "你的通信密钥" -SID 1
```

| 变量 | 说明 | 在哪获取 |
|---|---|---|
| `-PanelUrl` | 面板访问地址 | 面板域名 / IP |
| `-Token` | Communication Key(通信密钥) | 面板「系统设置 → 通信设置」 |
| `-SID` | machine_id(机器ID) | 面板「服务器管理」中添加服务器后生成的 ID |

脚本自动完成:校验 exe → 生成 `config.yml`(机器模式)→ 注册开机自启任务并立即运行 → 输出健康检查地址、状态命令。开机后免登录自动运行,日志写入 `xboard-node.log`。

3. 面板「服务器管理」中即可看到该机器上线,绑定节点后由面板统一下发运行。

## 手动配置(机器模式)

```yaml
machine:
  machine_id: 1            # SID
  token: "通信密钥"         # Token
panel:
  url: "https://panel.example.com"
kernel:
  type: singbox             # singbox 或 xray
log:
  level: info
health_port: 65530
```

然后运行:

```powershell
.\xboard-node.exe -c config.yml
```

## 其他模式

- **节点模式 / 多节点**:手动配置 `config.yml`,见 `config.yml.example`(`panel:` 加 `node_id`,或用 `nodes:` 列表、`instances:` 多实例)。

## 常用命令

```powershell
# 开机自启任务:停止 / 启动 / 移除 / 查看状态
Stop-ScheduledTask -TaskName XboardNode
Start-ScheduledTask -TaskName XboardNode
Unregister-ScheduledTask -TaskName XboardNode -Confirm:$false
Get-ScheduledTask -TaskName XboardNode

# 手动启动的实例:停止
Stop-Process -Id (Get-Content xboard-node.pid)

# 查看日志
Get-Content xboard-node.log -Tail 50

# 健康检查
Invoke-RestMethod http://127.0.0.1:65530/healthz
```

## 防火墙

以节点端口为例(端口号以面板下发的协议端口为准,TLS/Reality 通常为 443):

```powershell
netsh advfirewall firewall add rule name="xboard-node" dir=in action=allow protocol=TCP localport=443
```

## 开机自启说明

- 一键脚本自带 `-AutoStart` 参数:以 SYSTEM 身份注册计划任务 `XboardNode`,**开机即自动运行、免登录**,无需任何第三方软件。
- 如需系统服务方式,可用 NSSM:

```powershell
nssm install xboard-node "C:\path\xboard-node.exe" "-c C:\path\config.yml"
nssm set xboard-node AppDirectory "C:\path"
nssm start xboard-node
```

## 说明

- `xboard-node.exe` 基于上游仓库 `dev` 分支源码、Go 1.27 编译,全特性 build tags 已开启。
- 多实例 CLI(`xbctl`)针对 Linux systemd 设计,Windows 下请直接用上方手动配置方式。

## 免责声明

本项目仅供学习与研究使用,请遵守当地法律法规。

## 致谢与许可

- 上游项目:[cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node)(MPL-2.0)
- 面板:[Xboard](https://github.com/cedar2025/Xboard)