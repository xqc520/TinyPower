# TinyNav 服务器对接文档

最后更新：2026-06-15

## 1. 连接概览

设备有两路连接。

| 通道 | 用途 | 配置来源 | 说明 |
| --- | --- | --- | --- |
| 固定 MQTT | 后台上报、接收远程配置 | `config.lua` 写死 | 普通 TCP MQTT，默认端口 `1883`，不使用 TLS/MQTTS |
| 第二路 TCP | 向可配置服务器发送同一份实时数据 | WiFi 热点或 MQTT 下发 | 未配置时跳过，不影响 MQTT |

WiFi 热点只配置：

| 字段 | 说明 |
| --- | --- |
| `sn` | 设备 SN，也是 MQTT Topic 中的 `{SN}` |
| `tcp_host` | 第二路 TCP 服务器 IP 或域名 |
| `tcp_port` | 第二路 TCP 服务器端口，范围 `1` 到 `65535` |

## 2. MQTT Topic

| 方向 | 功能 | Topic | Payload |
| --- | --- | --- | --- |
| 设备上行 | 实时定位上报 | `sys/{SN}/json/up/realTime` | 明文 JSON |
| 设备上行 | 命令响应 | `sys/{SN}/json/up/resp` | 明文 JSON |
| 服务器下行 | 设备命令 | `sys/{SN}/json/down/cmd` | 明文 JSON |

服务器建议订阅：

```text
sys/+/json/up/realTime
sys/+/json/up/resp
```

## 3. 上报流程

1. 设备连接固定 MQTT，并订阅 `sys/{SN}/json/down/cmd`。
2. 设备定位成功后，向 `sys/{SN}/json/up/realTime` 上报明文 JSON。
3. MQTT 上报成功后，设备保持在线约 2 秒，用于接收服务器下发的频度或 TCP 配置。
4. 设备读取最新配置；若 `tcp_host/tcp_port` 已配置，则连接第二路 TCP，并发送同一份明文 JSON。
5. 设备断开连接，进入等待或低功耗。

第二路 TCP 报文格式：

```text
JSON + \n
```

## 4. 实时上报 JSON

MQTT `realTime` 与第二路 TCP 使用相同 JSON。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `SN` | string | 设备 SN |
| `timeStamp` | string | 设备当前 epoch 秒 |
| `sendFrequency` | number | 当前上报频度，单位分钟 |
| `tcase` | number | 机箱温度，单位摄氏度；读取失败为 `-1` |
| `batteryVoltage` | number | 电池电压，单位 V；保留两位小数，读取失败为 `-1.00` |
| `latitude` | number | 纬度 |
| `longitude` | number | 经度 |

## 5. 下发上报频度

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

- `sendFrequency` 单位为分钟。
- 设备会将频度限制在 1 分钟到 24 小时之间。
- 也兼容 `report_interval_ms`、`interval_sec`、`report_interval_sec`、`upload_interval_sec`、`frequency`、`freq`。

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

## 6. 远程修改设备配置

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

- 只更新下发中出现的字段，未出现字段保持原值。
- `device_id` 也兼容 `sn`、`SN`、`deviceId`、`devId`。
- `tcp_host` 也兼容 `tcp_server`、`tcp_domain`、`tcp_ip`、`host`、`server`、`domain`、`ip`。
- `tcp_port` 也兼容 `tcp_server_port`、`config_port`、`port`。
- `sendFrequency` 规则同“下发上报频度”。
- MQTT 服务器参数固定在固件中，远程配置不会修改 MQTT 地址、端口或认证信息。
- 设备会先用旧 SN 回包，再保存新配置；新 SN 在下一次 MQTT 连接时生效。

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

等价命令名：`set_device_config`、`set_tcp_config`、`set_device_id`、`set_tcp_server`。

## 7. 错误回包

命令失败时 `result=-1`，`reason` 为失败原因。

常见原因：

| reason | 含义 |
| --- | --- |
| `bad_interval` | 上报频度字段不存在或无法解析 |
| `bad_sn` | 设备 ID 为空 |
| `bad_tcp_host` | TCP 地址为空 |
| `bad_tcp_port` | TCP 端口非法 |
| `empty_config` | 没有可更新字段 |
| `bad_config` | 配置对象格式错误 |
