# 免拆刷机（macOS 实测）

不需要拆机、焊接、J-Link。原理是**利用原厂固件自带的漏洞**，让设备跳转到它自己的工厂 OTA 流程，从局域网 TFTP 拉取社区固件。

## 1. 原理

原厂配网模式下：

1. 设备开热点 `Phicomm_TC1_XXXX`，在 `10.10.10.1:8000` 提供配置服务
2. 其中 `/OTA` 接口**无认证**，且对请求体存在栈溢出
3. 发送 392 字节填充 + 覆盖返回地址的 payload，让执行流跳到固件内置的工厂 OTA 线程体
4. 该线程去连开放热点 `PHICOMM_OTA_AP`，从 `10.0.0.2` 用 TFTP 下载 `mico_ota.bin`
5. 设备校验镜像尾部的 16 字节 MD5 → 写入非活动应用槽 → 切换 → 重启进入社区固件

因此刷机需要**两条网络**：无线连插排热点（发 payload），有线连路由器（供 TFTP）。

### payload 结构

```
392 × 'A' + <4 字节小端返回地址> + 1 字节 NUL  = 397 字节
```

| 原厂版本 | 返回地址 | payload 文件 |
|---|---|---|
| 1.0.0.26 | `0x1F073D9F` | `tftp-trigger.bin` |
| 1.0.0.24 | `0x1F073D63` | `tftp-trigger-1.0.0.24.bin` |
| 1.0.0.21 | `0x1F073D2F` | `tftp-trigger-1.0.0.21.bin` |

三个版本的帧内偏移相同，只有地址不同。**用错版本只会让设备崩溃重启，但不要连发。**

## 2. 准备路由器

在路由器 / AP 上设置：

| 项 | 值 |
|---|---|
| 频段 | 2.4 GHz（双频合一先关掉 5 GHz 或改名） |
| SSID | `PHICOMM_OTA_AP`（大小写精确，无空格） |
| 加密 | 无 / 开放（不能是 WPA 空密码） |
| 隐藏 SSID | 关 |
| AP 隔离 / 客户端隔离 / 访客模式 | **关** |

LAN 网段不能是 `10.x`（电脑要用 `10.0.0.2/8`，设备用 `10.<MAC>/8`）。若是，改成 `192.168.x.x`。

## 3. 下载文件

```bash
mkdir -p ~/tc1-flash && cd ~/tc1-flash
base=https://phicomm-io.github.io/guides/assets/tools/tc1-no-disassembly
curl -LO $base/mico_ota.bin
curl -LO $base/tftp-trigger.bin
curl -LO $base/tftp-trigger-1.0.0.24.bin
curl -LO $base/tftp-trigger-1.0.0.21.bin
shasum -a 256 mico_ota.bin          # 对照 README 的校验值
```

`mico_ota.bin` = 649,328 字节 `MRVL` 应用槽镜像 + 16 字节 MD5（`137bbe25d40f0a45b2b3129f035ea4c3`），文件名必须保持原样。

## 4. 有线网卡加地址

```bash
networksetup -listallhardwareports            # 找有线网卡
ifconfig | grep -A3 '^en[0-9]'                # 找 status: active 的那个
sudo ifconfig enX inet 10.0.0.2 netmask 255.0.0.0 alias
ifconfig enX | grep 'inet 10.0.0.2'           # 必须看到 10.0.0.2 netmask 0xff000000
```

注意 `/8` 掩码会把整个 `10/8` 当成直连路由。插排配网热点给的是 `10.10.10.x/24`，比 `/8` 更精确，所以能正常分流；但 VPN、公司内网若用 `10.x` 会冲突，刷机期间先断开。

## 5. 启动系统自带 TFTP

```bash
cd ~/tc1-flash
sudo mkdir -p /private/tftpboot
sudo cp mico_ota.bin /private/tftpboot/mico_ota.bin
sudo chmod 644 /private/tftpboot/mico_ota.bin
sudo launchctl load -w /System/Library/LaunchDaemons/tftp.plist
launchctl print system/com.apple.tftpd | head -3   # 有输出即已加载
```

`tftp.plist` 里默认 `Disabled=true`，所以必须 `load -w`。`state = not running` 是正常的（inetd 模式，请求到来才拉起进程）。

macOS 自带的 `tftpd` 支持 `tsize / blksize / OACK`，与固件的 TFTP 客户端兼容。

### 防火墙

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getappblocked /usr/libexec/tftpd
# 若被拦：
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/libexec/tftpd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/libexec/tftpd
```

### 自测服务（本机）

```bash
curl --noproxy '*' --fail --max-time 30 -o /tmp/check.bin tftp://10.0.0.2/mico_ota.bin
shasum -a 256 /tmp/check.bin     # 应与 mico_ota.bin 一致
```

这只是验证服务端，**不能**证明"无线能到有线"——那一步要靠后面从另一台设备 ping 通 `10.0.0.2`。

## 6. 进入配网模式并确认版本

```
拔电 → 等 5 秒 → 插电 → 3 秒内双击配网键 → 等 10~20 秒
```

判据是 **LED 慢闪（约 0.5 秒一次）**，并出现开放热点 `Phicomm_TC1_XXXX`。

备用方法：长按配网键到 LED 快闪、再保持一会松手，随后快速短按两次。

> 已配过网的设备**不会**开配网热点。二手设备先按住配网键 5~10 秒重置网络（≥10 秒是恢复出厂）。

电脑无线连上该热点后：

```bash
ifconfig en0 | grep 'inet '          # 必须拿到 10.10.10.x/24
curl --noproxy '*' -s -m 5 http://10.10.10.1:8000/read-domain
```

核对 `VERSION` 与 `COMPILE_TIME`：

| 版本 | COMPILE_TIME |
|---|---|
| 1.0.0.26 / 1.0.0.24 | `Apr 13 2018 10:09:06` |
| 1.0.0.21 | `Oct 29 2017 11:09:21` |

版本不符就停，payload 必须与版本一一对应。

## 7. 发 payload（只发一次）

```bash
cd ~/tc1-flash
curl --noproxy '*' --max-time 30 -v \
  --header 'Content-Type: application/json' \
  --data-binary '@tftp-trigger.bin' \
  http://10.10.10.1:8000/OTA
```

按版本替换文件名。**必须带 `--noproxy '*'`**：系统或环境变量里的 HTTP 代理（如 `http_proxy=127.0.0.1:7890`）会把 `10.10.10.1` 劫走。

另开一个终端盯日志：

```bash
sudo log stream --predicate 'process == "tftpd"' --style compact
```

## 8. 等待下载与重启

| 现象 | 含义 |
|---|---|
| 返回 `OTA` 或一串 `A`，随后无线断开 | 正常，设备正去连 `PHICOMM_OTA_AP` |
| TFTP 日志出现请求与完整传输 | 正在拉 649,344 B 固件 |
| curl 超时但 TFTP 有传输 | 正常，**不要重发** |
| 无任何 TFTP 记录 | 检查路由器 SSID / 加密 / 客户端隔离、有线地址、防火墙 |

下载 → 校验 MD5 → 切换应用槽 → 重启。全程保持供电、网线、TFTP 服务。

成功后会出现新的**开放**热点 `TC1_A1-AP-<MAC 后六位大写>`，见 [setup.md](setup.md)。

## 9. 收尾

```bash
sudo launchctl unload -w /System/Library/LaunchDaemons/tftp.plist
sudo ifconfig enX inet 10.0.0.2 -alias
sudo rm -f /private/tftpboot/mico_ota.bin
```

## Windows / Linux 差异

| 系统 | TFTP | 有线地址 |
|---|---|---|
| Windows | Tftpd64，服务接口选 `10.0.0.2` | `netsh interface ipv4 add address name="Ethernet" address=10.0.0.2 mask=255.0.0.0` |
| Linux | `dnsmasq --enable-tftp --tftp-root=... --listen-address=10.0.0.2 --bind-interfaces` | `sudo ip addr add 10.0.0.2/8 dev enp3s0` |
| macOS | 系统 `tftpd`（如上） | `sudo ifconfig enX inet 10.0.0.2 netmask 255.0.0.0 alias` |
