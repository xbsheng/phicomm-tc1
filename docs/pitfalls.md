# 踩坑与排查

按"实际遇到 → 原因 → 怎么办"记录。命令都可直接复制，把 `<...>` 换成自己的值。

## 刷机阶段

### 有线网卡加了 `10.0.0.2/8` 后，访问 `10.10.10.1` 超时

`/8` 掩码把整个 `10/8` 变成直连路由，流量被送去有线网卡。插排配网热点给的是 `10.10.10.x/24`，**比 `/8` 更精确**，所以只要无线真的拿到了 `/24` 地址就会正确分流。

```bash
ifconfig en0 | grep 'inet '        # 必须是 10.10.10.x netmask 0xffffff00
netstat -rn -f inet | grep '^10'   # 10/8 -> 有线；10.10.10/24 -> Wi-Fi
```

如果无线是 `169.254.x.x`（DHCP 失败），`10.10.10.1` 就会走有线，必然超时。

### curl 无响应，但 ping 通

系统代理 / 环境变量代理。检查：

```bash
scutil --proxy | head
env | grep -i proxy
```

本次实测环境里 `http_proxy=http://127.0.0.1:7890`，而 `no_proxy` 不含 `10/8`，于是发往 `10.10.10.1` 的请求被代理吞掉。**每条 curl 都加 `--noproxy '*'`**。

### 局域网里出现 `10.10.10.1`，但 TCP 不通

先查 MAC 厂商再下结论：

```bash
arp -an | grep 10.10.10.1
curl -s "https://api.macvendors.com/<前 3 段 MAC>"
```

本次实测：`10.10.10.1` 的 MAC 属于路由器厂商（UTT），**不是插排**。插排的模块是 MXCHIP。判据用 OUI，不要用 IP 猜。

### `launchctl print system/com.apple.tftpd` 报 "Could not find service"

还没加载。`tftp.plist` 里是 `Disabled=true`，必须：

```bash
sudo launchctl load -w /System/Library/LaunchDaemons/tftp.plist
```

加载后 `state = not running` 是正常的（inetd 模式）。要确认服务在供文件，直接下：

```bash
curl --noproxy '*' --fail -o /tmp/check.bin tftp://10.0.0.2/mico_ota.bin
```

### 自测能下载，但插排没有来拉

按顺序查：路由器 SSID 是否精确 `PHICOMM_OTA_AP`、是否 2.4 GHz、是否真的"无密码"、**客户端隔离是否关**、有线地址是否仍是 `10.0.0.2`、防火墙是否放行 `tftpd`。

判据：从另一台连着该开放 SSID 的设备 `ping 10.0.0.2` 通 → 说明无线能到有线。

### 刷机中电脑睡眠，传输中断

macOS 电池供电时 `sleep` 默认 1 分钟。刷机全程**插电源**（插电时 `sleep 0`），并开一个 `caffeinate -dims` 的终端守到结束。

### 刷完没有新热点

保持供电观察 1~2 分钟；核对 TFTP 日志里是否完成了 649,344 字节。**不要连续重发 payload**。

## 运行阶段

### 网页要求先设密码 / API 返回 401

设置网页密码后所有接口都要 Basic 认证，用户名固定 `admin`。`401` 且带 `WWW-Authenticate: Basic realm="TC1"` 就说明设备活着、只是没认证。

### HA 里找不到设备

1. 设备状态 `mqtt_connected` / `mqtt_status`
2. Broker 上订阅发现主题：`mosquitto_sub -t 'homeassistant/#' -v`
3. 设备主题是否在发：`mosquitto_sub -t 'phicomm/v2/local/tc1/<mac>/sensor' -v`
4. 设备与 Broker 是否在同一网段、设备填的是 Broker 的**局域网 IP**

### 小米（米家）里改了巴法云昵称不生效

米家的云云对接只同步**绑定那一刻**的设备快照，"同步设备"按钮只增删、不改名。做法：**解绑 → 重新绑定 → 同步设备**，或直接在米家点设备改名。

### 六个设备都叫"插座"，语音分不清

昵称必须在巴法云逐个改，再让米家重拉。见 [xiaoai.md](xiaoai.md) 第 6 节。

## 安全权衡（必读）

| 风险 | 说明 | 建议 |
|---|---|---|
| 原厂固件的 `/OTA` | 无认证 + 栈溢出，进入配网模式后同网段可刷入任意固件 | 刷掉原厂应用槽即是修复 |
| 过渡包 0.9.6 | 仅用于迁移，缺后续修复 | 立刻升级签名稳定版 |
| 网页密码为空 | 局域网内任何人可开关六路 | 首次启动就设置 |
| mosquitto 匿名 | `allow_anonymous true` 时同网段任意设备可读写全部主题 | 改 `password_file` + ACL |
| 巴法云明文 | `bemfa.com:9501` 无 TLS，指令与凭据公网可见 | 只当语音入口，关键负载不走它 |
| 云端依赖 | 第三方云与平台政策都可能变 | 主控留在本地 HA |
| 密钥外泄 | 截图、聊天、仓库里出现连接密钥 | 立即在控制台重置并重写设备 |

## 仓库内不要提交的东西

- 连接密钥（AppID / SecretKey）、网页密码、Wi-Fi 密码
- 真实的内网 IP、SSID、设备 MAC（用 `<PLUG_IP>` / `<MAC>` 这类占位符）
- 固件二进制（`.bin`）、配置备份
- 私有 Broker 的账号密码
