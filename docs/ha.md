# 接入 Home Assistant（本地 MQTT）

推荐的主控方式：**纯内网、不经第三方云**，可用性最好。

## 1. 准备 Broker

任何 MQTT Broker 都行。以 Docker 跑 mosquitto 为例：

```yaml
# docker-compose.yml
services:
  mosquitto:
    image: eclipse-mosquitto:2
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./mosquitto/config:/mosquitto/config
      - ./mosquitto/data:/mosquitto/data
```

```conf
# mosquitto/config/mosquitto.conf
listener 1883
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
```

`allow_anonymous true` 只为跑通流程；收紧见文末。

## 2. HA 里加 MQTT 集成

设置 → 设备与服务 → 添加集成 → **MQTT**：

| 字段 | 值（HA 与 Broker 同机） |
|---|---|
| Broker | `127.0.0.1` |
| 端口 | `1883` |
| 用户名 / 密码 | 留空（对应 `allow_anonymous`） |
| TLS | 关 |
| 发现前缀 | `homeassistant` |

HA 与 Broker 不在同一主机时，HA 填 Broker 的局域网 IP。

## 3. 设备侧填 Broker

设备网页 → 网络 → MQTT / Home Assistant：

| 字段 | 值 |
|---|---|
| Broker / Host | **Broker 的局域网 IP**（不给协议前缀、不写 `https://`） |
| 端口 | `1883` |
| 用户名 / 密码 | 与 Broker 一致 |
| 主题模式 | **TMCP (v2)** |

保存后设备状态里 `mqtt_status` 应为 `ready`、`mqtt_connected = true`。

### 用 API 写（0.9.27 的 HTTP 是 JSON）

```bash
curl --noproxy '*' -u 'admin:<WEB_PASS>' \
  -H 'Content-Type: application/json' \
  -d '{"action":"config.set","params":{"section":"mqtt","values":{
        "host":"<BROKER_IP>","port":1883,"user":"","password":"","protocol":"tmcp"}},
      "request_id":"set-mqtt"}' \
  http://<PLUG_IP>/api/v1/command
```

回读：

```bash
curl --noproxy '*' -u 'admin:<WEB_PASS>' http://<PLUG_IP>/api/v1/status
```

## 4. 自动发现

设备会向 `homeassistant/<component>/local/tc1_<mac>/<entity>/config` 发布发现配置，HA 自动生成实体，**不需要写 YAML**。

实测得到 17 个实体：

| 类别 | 实体 |
|---|---|
| 开关 | 插座-1 … 插座-6、Master Switch、Child Lock、LED Indicator |
| 传感器 | Power(W)、Energy Total、Energy Today、Energy Yesterday、Energy Since Boot、Uptime |
| 按钮 | Reboot Device、Soft Reboot |

设备主题前缀为 `phicomm/v2/local/tc1/<mac>/`：

```
state / command / availability / sensor / socket_0..5 / total_socket / childLock / led
```

用户名留空时 scope 为 `local`；填了用户名则是 `u_<用户名 UTF-8 十六进制>`。

## 5. 验证

```bash
# 看发现配置是否在发
docker exec mosquitto mosquitto_sub -t 'homeassistant/#' -v -W 10 | head -5

# 看实时数据
docker exec mosquitto mosquitto_sub -t 'phicomm/v2/local/tc1/<mac>/sensor' -v -W 8
```

HA 侧确认实体已注册（容器内）：

```bash
python3 - <<'EOF'
import json
d=json.load(open('/config/.storage/core.entity_registry'))
print([e['entity_id'] for e in d['data']['entities'] if 'tc1' in (e.get('unique_id') or '').lower()])
EOF
```

> 发现配置不保留（`retain=false`）。HA 重启后设备会通过订阅 `homeassistant/status` 的 birth 消息重新发布，无需手动干预。

## 6. 收紧安全（建议）

```conf
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
```

```bash
docker exec -it mosquitto mosquitto_passwd -c -b /mosquitto/config/passwd tc1 '<STRONG_PASS>'
docker restart mosquitto
```

然后设备 MQTT 配置填同一个用户名/密码。注意：固件主题前缀**不构成权限隔离**，多设备共用 Broker 时要靠 Broker 的 ACL 区分。
