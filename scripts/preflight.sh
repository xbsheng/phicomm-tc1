#!/usr/bin/env bash
# 刷机前自检：只读，不修改任何系统或设备配置。
# 用法：bash scripts/preflight.sh [固件目录]
set -eu

DIR="${1:-$HOME/tc1-flash}"
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

echo "== 1. 工具链"
if curl --version | grep -q ' tftp'; then ok "curl 支持 tftp"; else bad "curl 不支持 tftp（换系统 curl 或装 tftp 客户端）"; fi
if [ -x /usr/libexec/tftpd ]; then ok "系统 tftpd 存在"; else bad "找不到 /usr/libexec/tftpd"; fi
if [ -f /System/Library/LaunchDaemons/tftp.plist ]; then
  ok "tftp.plist 存在（需 sudo launchctl load -w 启用）"
else
  bad "找不到 tftp.plist，改用 dnsmasq / Tftpd64"
fi

echo "== 2. 网卡"
echo "  硬件端口："
networksetup -listallhardwareports | grep -E 'Hardware Port|Device' | paste - - | sed 's/^/    /'
echo "  已激活且有 IPv4 的接口："
for i in $(ifconfig -l); do
  s=$(ifconfig "$i" 2>/dev/null | sed -n 's/.*status: //p')
  a=$(ifconfig "$i" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\) netmask.*/\1/p' | head -1)
  [ "$s" = active ] && [ -n "$a" ] && echo "    $i  status=$s  inet=$a"
done
ifconfig en0 2>/dev/null | grep -q '10\.10\.10\.' \
  && ok "无线已在 10.10.10.x（已连插排配网热点）" \
  || warn "无线不在 10.10.10.x（还没连插排热点，或 DHCP 失败）"

echo "== 3. 有线地址 10.0.0.2/8"
if ifconfig | grep -q 'inet 10\.0\.0\.2 .*netmask 0xff000000'; then
  ok "10.0.0.2/8 已配置"
else
  warn "未配置，执行：sudo ifconfig <有线_if> inet 10.0.0.2 netmask 255.0.0.0 alias"
fi
netstat -rn -f inet | grep -q '^10\.10\.10' && warn "路由表里已有 10.10.10/24（确认它指向 Wi-Fi）" || true

echo "== 4. TFTP 服务与防火墙"
if launchctl print system/com.apple.tftpd >/dev/null 2>&1; then
  ok "tftpd 已加载"
else
  warn "tftpd 未加载：sudo launchctl load -w /System/Library/LaunchDaemons/tftp.plist"
fi
[ -f /private/tftpboot/mico_ota.bin ] && ok "/private/tftpboot/mico_ota.bin 就位" || warn "/private/tftpboot 里没有 mico_ota.bin"
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | sed 's/^/  /'
/usr/libexec/ApplicationFirewall/socketfilterfw --getappblocked /usr/libexec/tftpd 2>/dev/null | sed 's/^/  /' || true

echo "== 5. 代理（会把 10.10.10.1 劫走）"
env | grep -iE '^(http|https|all|no)_proxy=' | sed 's/^/  /' || echo "  无代理环境变量"
warn "所有发往设备的 curl 都要带 --noproxy '*'"

echo "== 6. 固件文件校验 (${DIR})"
if [ -d "$DIR" ]; then
  ( cd "$DIR"
    for f in mico_ota.bin tftp-trigger.bin tftp-trigger-1.0.0.24.bin tftp-trigger-1.0.0.21.bin \
             phicomm_tc1_a1.ota.bin.signed; do
      [ -f "$f" ] && printf '  %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
    done
    [ -f mico_ota.bin ] && [ "$(wc -c < mico_ota.bin | tr -d ' ')" = 649344 ] \
      && echo "  mico_ota.bin 大小正确 (649344)" || true
  )
else
  warn "目录不存在：$DIR"
fi

echo
echo "对照 README 里的 SHA-256；全部 OK 后再开始刷机。"
