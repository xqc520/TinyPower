# TinyPower 服务器对接文档

最后更新：2026-06-16

## 1. 连接

| 通道 | 作用 | 配置方式 | 说明 |
| --- | --- | --- | --- |
| 固定 MQTT | 上报、接收命令 | 固件 `config.lua` 写死 | 普通 TCP MQTT，不使用 TLS |
| 第二路 TCP | 发送同一份实时数据 | WiFi 或 MQTT 下发 | 未配置时跳过 |

- WiFi 热点只配置 `sn`、`tcp_host`、`tcp_port`。
- 第二路 TCP 报文格式：`JSON + \n`。
- MQTT 地址、端口、账号、密码不能远程修改。

## 2. MQTT Topic

| 方向 | Topic | 说明 |
| --- | --- | --- |
| 设备上报 | `sys/{SN}/json/up/realTime` | 实时明文 JSON |
| 设备响应 | `sys/{SN}/json/up/resp` | 命令处理结果 |
| 服务器下发 | `sys/{SN}/json/down/cmd` | 远程命令 |

服务器订阅 `sys/+/json/up/realTime` 和 `sys/+/json/up/resp`。

## 3. 实时上报字段

MQTT 和第二路 TCP 使用相同 JSON。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `SN` | string | 设备 SN |
| `timeStamp` | string | epoch 秒 |
| `sendFrequency` | number | 上报频度，单位分钟 |
| `tcase` | number | 机箱温度，读取失败为 `-1` |
| `batteryVoltage` | number | 电池电压，单位 V，读取失败为 `-1.00` |
| `latitude` | number | 纬度 |
| `longitude` | number | 经度 |

## 4. 下发命令

下发 Topic：`sys/{SN}/json/down/cmd`。

只使用下列命令和字段，不兼容其它字段名。

| 命令 | 作用 | 字段 |
| --- | --- | --- |
| `set_report_interval` | 修改上报频度 | `cmd`、`request_id`、`sendFrequency` |
| `set_config` | 修改设备配置 | `cmd`、`request_id`、`config` |

`sendFrequency` 单位为分钟，范围为 `1` 到 `1440`。

`set_config.config` 字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `sn` | string | 设备 SN；下次 MQTT 连接生效 |
| `tcp_host` | string | 第二路 TCP IP 或域名 |
| `tcp_port` | number | 第二路 TCP 端口，`1` 到 `65535` |
| `sendFrequency` | number | 上报频度，单位分钟 |

未下发字段保持原值。

## 5. 命令响应

响应 Topic：`sys/{SN}/json/up/resp`。

修改 SN 时，设备先用旧 SN 回包，再保存新 SN。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `cmd` | string | 对应命令 |
| `request_id` | string | 请求 ID |
| `result` | number | `0` 成功，`-1` 失败 |
| `reason` | string | 结果说明 |
| `sn` | string | 当前回包 SN |
| `time` | number | epoch 秒 |

## 6. 交互示例

设备实时上报：

Topic：`sys/TN000001/json/up/realTime`

```json
{
  "SN": "TN000001",
  "timeStamp": "1781510400",
  "sendFrequency": 10,
  "tcase": 28.5,
  "batteryVoltage": 3.82,
  "latitude": 31.230416,
  "longitude": 121.473701
}
```

服务器修改上报频度：

Topic：`sys/TN000001/json/down/cmd`

```json
{
  "cmd": "set_report_interval",
  "request_id": "req-001",
  "sendFrequency": 5
}
```

服务器修改设备配置：

Topic：`sys/TN000001/json/down/cmd`

```json
{
  "cmd": "set_config",
  "request_id": "req-002",
  "config": {
    "sn": "TN000002",
    "tcp_host": "tcp.example.com",
    "tcp_port": 9000,
    "sendFrequency": 10
  }
}
```

设备命令响应：

Topic：`sys/TN000001/json/up/resp`

```json
{
  "cmd": "set_config",
  "request_id": "req-002",
  "result": 0,
  "reason": "ok",
  "sn": "TN000001",
  "time": 1781510402
}
```

## 7. 错误码

| reason | 说明 |
| --- | --- |
| `bad_interval` | `sendFrequency` 缺失或非法 |
| `bad_sn` | `sn` 为空 |
| `bad_tcp_host` | `tcp_host` 为空 |
| `bad_tcp_port` | `tcp_port` 非法 |
| `empty_config` | 没有可更新字段 |
| `bad_config` | `config` 不是对象 |
