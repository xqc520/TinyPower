# TinyNav 服务器对接文档

最后更新：2026-06-15

本文档只保留服务器对接当前固件所需的必要内容。

## 1. MQTT 连接

设备有两路连接：

- MQTT：固件里的固定后台连接，使用普通 TCP MQTT，不启用 TLS/MQTTS，也不在 WiFi 热点页面配置。服务器地址、端口和账号密码由 `config.lua` 中的固定常量决定。
- TCP：另一路可配置连接，IP/域名和端口可通过 WiFi 热点配置，也可通过 MQTT 下发配置。

本地 AP 只配置设备 SN 和另一路 TCP 参数：

| 字段 | 说明 |
| --- | --- |
| `sn` | 设备 SN，也是 Topic 里的 `{SN}` |
| `tcp_host` | 另一路 TCP 服务器 IP 或域名，可为空 |
| `tcp_port` | 另一路 TCP 服务器端口，可为空 |

连接参数：

| 项 | 值 |
| --- | --- |
| Host/Port | 固件固定：`config.MQTT_HOST` / `config.MQTT_PORT`，默认端口 `1883` |
| TLS/MQTTS | 关闭，固定普通 TCP MQTT |
| Client ID | `<IMEI>mqtts1`，读不到 IMEI 时为 `<SN>mqtts1` |
| Clean Session | `false` |
| Keepalive | 30 秒 |
| 实时上报 QoS | `1` |
| 命令响应 QoS | `0` |

## 2. 第二路 TCP 连接

第二路 TCP 使用 `tcp_host` / `tcp_port`。如果未配置，设备会跳过该路连接；如果已配置，设备每轮会在 MQTT 上报和等待下发配置后，连接该 TCP 服务器并发送同一份实时上报 JSON。

TCP 报文格式：

```text
JSON + \n
```

其中 JSON 内容与 `sys/{SN}/json/up/realTime` 的明文 JSON 完全一致。

## 3. MQTT Topic

| 方向 | 功能 | Topic | Payload |
| --- | --- | --- | --- |
| 设备上行 | 实时定位上报 | `sys/{SN}/json/up/realTime` | 明文 JSON |
| 设备上行 | 设备响应 / 主动请求 | `sys/{SN}/json/up/resp` | 明文 JSON |
| 服务器下行 | 设备命令 | `sys/{SN}/json/down/cmd` | 明文 JSON |

服务器建议订阅：

```text
sys/+/json/up/realTime
sys/+/json/up/resp
```

## 4. 对接流程

1. 设备连接 MQTT，并订阅 `sys/{SN}/json/down/cmd`。
2. 设备定位成功后，向 `sys/{SN}/json/up/realTime` 上报明文 JSON 定位数据。
3. MQTT 上报成功后，设备会继续保持 MQTT 在线 2 秒，用来等待服务器下发上传频率或第二路 TCP 配置。
4. 设备读取最新配置；如果 `tcp_host/tcp_port` 已配置，则连接第二路 TCP 并发送同一份明文 JSON。
5. 设备断开 MQTT/TCP，进入等待或低功耗。

## 5. 实时上报

Topic：

```text
sys/{SN}/json/up/realTime
```

Payload 为明文 JSON：

```json
{
  "SN": "TN000001",
  "timeStamp": "1770000000",
  "sendFrequency": 10,
  "tcase": 32.1,
  "batteryVoltage": 12.10,
  "latitude": 39.908823,
  "longitude": 116.39747
}
```

字段说明：

| 字段 | 说明 |
| --- | --- |
| `SN` | 设备 SN |
| `timeStamp` | 设备当前 epoch 秒 |
| `sendFrequency` | 当前上传频率，单位分钟 |
| `tcase` | 机箱温度，单位摄氏度 |
| `batteryVoltage` | 电池电压，单位 V |
| `latitude` | 纬度 |
| `longitude` | 经度 |

## 6. 下发上传频率

服务器只需要按分钟下发。

Topic：

```text
sys/{SN}/json/down/cmd
```

Payload：

```json
{
  "cmd": "set_report_interval",
  "request_id": "interval-001",
  "sendFrequency": 10
}
```

说明：

- `sendFrequency=10` 表示每 10 分钟上报一次。
- 设备会把周期限制在 1 分钟到 24 小时之间。
- 服务器建议在收到 `realTime` 后立即下发，设备上报成功后会等待 2 秒再休眠。

设备回包：

```json
{
  "cmd": "set_report_interval",
  "request_id": "interval-001",
  "result": 0,
  "reason": "ok",
  "sn": "TN000001",
  "time": 1770000100
}
```

### 6.1 远程修改设备配置

设备支持通过同一个下行 Topic 远程修改设备 ID、另一路 TCP 服务器 IP/域名、TCP 端口和上报频度。MQTT 连接保持固定，远程配置不会修改 MQTT 服务器参数。服务器可以只下发需要修改的字段，未下发的字段会保持原值。

Topic：

```text
sys/{SN}/json/down/cmd
```

Payload：

```json
{
  "cmd": "set_config",
  "request_id": "cfg-001",
  "config": {
    "device_id": "TN000002",
    "tcp_host": "tcp.example.com",
    "tcp_port": 9000,
    "sendFrequency": 10
  }
}
```

说明：

- `device_id` 也可使用 `sn`、`SN`、`deviceId`、`devId`。
- `tcp_host` 可填写 IP 或域名，也可使用 `tcp_server`、`tcp_domain`、`tcp_ip`、`host`、`server`、`domain`、`ip`。
- `tcp_port` 也可使用 `tcp_server_port`、`config_port`、`port`，范围为 `1` 到 `65535`。
- `sendFrequency` 单位为分钟；也支持 `report_interval_ms`、`interval_sec` 等上传频率字段。
- 设备收到命令后会先用旧 SN 对应的 `up/resp` Topic 回包，再保存新配置；新设备 ID 会在下一次 MQTT 连接时生效，新的 TCP 地址和端口会在下一次使用该 TCP 通道时生效。
- 上报成功后设备默认继续保持 MQTT 在线 2 秒，服务器应在收到 `realTime` 后尽快下发远程配置。

设备回包：

```json
{
  "cmd": "set_config",
  "request_id": "cfg-001",
  "result": 0,
  "reason": "ok",
  "sn": "TN000001",
  "time": 1770000100
}
```

也可以按功能使用更窄的命令名：`set_device_config`、`set_tcp_config`、`set_device_id`、`set_tcp_server`。

## 7. mosquitto 示例

订阅：

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -t "sys/+/json/up/resp" -v
mosquitto_sub -h 127.0.0.1 -p 1883 -t "sys/+/json/up/realTime" -v
```

下发 10 分钟上传频率：

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -t "sys/TN000001/json/down/cmd" -m "{\"cmd\":\"set_report_interval\",\"request_id\":\"interval-001\",\"sendFrequency\":10}"
```

远程修改设备 ID、TCP 服务器域名和端口：

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -t "sys/TN000001/json/down/cmd" -m "{\"cmd\":\"set_config\",\"request_id\":\"cfg-001\",\"config\":{\"device_id\":\"TN000002\",\"tcp_host\":\"tcp.example.com\",\"tcp_port\":9000,\"sendFrequency\":10}}"
```
