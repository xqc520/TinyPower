# TinyPower 服务器对接文档

最后更新：2026-06-15

## 1. 连接

设备有两路连接。

| 通道 | 用途 | 配置来源 | 说明 |
| --- | --- | --- | --- |
| 固定 MQTT | 上报数据、接收远程配置 | `config.lua` 写死 | 普通 TCP MQTT，默认端口 `1883`，不使用 TLS/MQTTS |
| 第二路 TCP | 向业务服务器发送同一份实时数据 | WiFi 热点或 MQTT 下发 | 未配置时跳过，不影响 MQTT |

WiFi 热点只允许配置 `sn`、`tcp_host`、`tcp_port`。

## 2. MQTT Topic

| 方向 | 功能 | Topic | Payload |
| --- | --- | --- | --- |
| 设备上行 | 实时定位上报 | `sys/{SN}/json/up/realTime` | 明文 JSON |
| 设备上行 | 命令响应 | `sys/{SN}/json/up/resp` | 明文 JSON |
| 服务器下行 | 设备命令 | `sys/{SN}/json/down/cmd` | 明文 JSON |

服务器可订阅 `sys/+/json/up/realTime` 和 `sys/+/json/up/resp`。

## 3. 上报流程

1. 设备连接固定 MQTT，并订阅 `sys/{SN}/json/down/cmd`。
2. 定位成功后，设备向 MQTT 上报明文 JSON。
3. MQTT 上报成功后，设备保持在线约 2 秒，用于接收远程配置。
4. 设备读取最新配置；如果 `tcp_host/tcp_port` 已配置，则连接第二路 TCP，并发送同一份明文 JSON。
5. 设备断开连接，进入等待或低功耗。

第二路 TCP 报文格式为 `JSON + \n`。

## 4. 实时上报字段

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

## 5. 下发命令

下发 Topic 固定为 `sys/{SN}/json/down/cmd`。

只识别下列命令名和字段名，不兼容其它别名。

| 命令 | 用途 | 字段 |
| --- | --- | --- |
| `set_report_interval` | 修改上报频度 | `cmd`、`request_id`、`sendFrequency` |
| `set_config` | 修改设备配置 | `cmd`、`request_id`、`config` |

`sendFrequency` 单位为分钟，设备会限制在 1 分钟到 24 小时之间。

`set_config.config` 只识别下列字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `sn` | string | 设备 SN；新 SN 在下一次 MQTT 连接时生效 |
| `tcp_host` | string | 第二路 TCP 服务器 IP 或域名 |
| `tcp_port` | number | 第二路 TCP 服务器端口，范围 `1` 到 `65535` |
| `sendFrequency` | number | 上报频度，单位分钟 |

未下发的配置字段保持原值。MQTT 服务器地址、端口、账号、密码固定在固件中，不能通过 WiFi 或 MQTT 远程修改。

## 6. 命令响应

设备响应 Topic 为 `sys/{SN}/json/up/resp`。修改 SN 时，设备先使用旧 SN 回包，再保存新配置。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `cmd` | string | 对应下发命令 |
| `request_id` | string | 对应请求 ID |
| `result` | number | `0` 表示成功，`-1` 表示失败 |
| `reason` | string | 处理结果或失败原因 |
| `sn` | string | 当前回包使用的 SN |
| `time` | number | 设备当前 epoch 秒 |

## 7. 错误原因

| reason | 含义 |
| --- | --- |
| `bad_interval` | `sendFrequency` 不存在或无法解析 |
| `bad_sn` | `sn` 为空 |
| `bad_tcp_host` | `tcp_host` 为空 |
| `bad_tcp_port` | `tcp_port` 非法 |
| `empty_config` | 没有可更新字段 |
| `bad_config` | `config` 不是对象 |
