#!/usr/bin/env bash
# 斐讯 TC1（社区固件）HTTP API 小工具。0.9.27 的 HTTP 是 JSON。
#
#   export TC1_IP=192.0.2.10 TC1_PASS='<网页密码>'
#   ./scripts/tc1.sh status
#   ./scripts/tc1.sh config
#   ./scripts/tc1.sh mqtt <broker> [port] [user] [pass]
#   ./scripts/tc1.sh bemfa <appid> <secret> <topic1,topic2,...>
#   ./scripts/tc1.sh raw '{"action":"status.get","params":{}}'
#
set -eu

: "${TC1_IP:?set TC1_IP}"
: "${TC1_PASS:?set TC1_PASS}"

say() { curl --noproxy '*' -s -m 15 -u "admin:$TC1_PASS" "$@"; }
cmd() { say -H 'Content-Type: application/json' -d "$1" "http://$TC1_IP/api/v1/command"; }

wrap() { # $1 = section, $2 = values json
  printf '{"action":"config.set","params":{"section":"%s","values":%s},"request_id":"%s"}' \
    "$1" "$2" "$(date +%s)"
}

case "${1:-}" in
  status) say "http://$TC1_IP/api/v1/status" ;;
  config) say "http://$TC1_IP/api/v1/config" ;;
  mqtt)
    host="${2:?broker host}"; port="${3:-1883}"; user="${4:-}"; pass="${5:-}"
    cmd "$(wrap mqtt "$(printf '{"host":"%s","port":%s,"user":"%s","password":"%s","protocol":"tmcp"}' \
      "$host" "$port" "$user" "$pass")")"
    ;;
  bemfa)
    appid="${2:?appid}"; secret="${3:?secret}"; topics="${4:?topics, comma separated}"
    [ "$(printf '%s' "$topics" | tr -cd ',' | wc -c | tr -d ' ')" -eq 5 ] || {
      echo "bemfa 需要正好 6 个主题（六路）" >&2; exit 1; }
    list=""; IFS=','; for t in $topics; do list="$list\"$t\","; done; unset IFS
    list="{${list%,}}"
    cmd "$(wrap bemfa "$(printf '{"enabled":true,"app_id":"%s","secret_key":"%s","topics":%s}' \
      "$appid" "$secret" "$list")")"
    ;;
  raw) cmd "${2:?json}" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
echo
