# TinyNav 服务器对接文档

最后更新：2026-06-04

本文档只保留服务器对接当前固件所需的必要内容。

## 1. MQTT 连接

设备通过本地 AP 配置 MQTT 参数：

| 字段 | 说明 |
| --- | --- |
| `sn` | 设备 SN，也是 Topic 里的 `{SN}` |
| `mqtt_host` | MQTT 服务器地址 |
| `mqtt_port` | MQTT 服务器端口，默认 `8883` |
| `mqtt_user` | MQTT 用户名，可为空 |
| `mqtt_pass` | MQTT 密码，可为空 |
| `mqtt_ssl` | 是否启用 TLS/MQTTS，默认启用 |

连接参数：

| 项 | 值 |
| --- | --- |
| Client ID | `<IMEI>mqtts1`，读不到 IMEI 时为 `<SN>mqtts1` |
| Clean Session | `false` |
| Keepalive | 30 秒 |
| 实时上报 QoS | `1` |
| 命令响应 QoS | `0` |

## 2. Topic

| 方向 | 功能 | Topic | Payload |
| --- | --- | --- | --- |
| 设备上行 | 实时定位上报 | `sys/{SN}/json/up/realTime` | SM4 加密后的 HEX 文本 |
| 设备上行 | 设备响应 / 主动请求 | `sys/{SN}/json/up/resp` | 明文 JSON |
| 服务器下行 | 设备命令 | `sys/{SN}/json/down/cmd` | 明文 JSON |

服务器建议订阅：

```text
sys/+/json/up/realTime
sys/+/json/up/resp
```

## 3. 对接流程

1. 设备连接 MQTT，并订阅 `sys/{SN}/json/down/cmd`。
2. 如果设备没有本地 SM4 参数，会向 `sys/{SN}/json/up/resp` 发送 `request_sm4`。
3. 服务器向 `sys/{SN}/json/down/cmd` 下发 `set_sm4`。
4. 设备定位成功后，向 `sys/{SN}/json/up/realTime` 上报加密定位数据。
5. 上报成功后，设备会继续保持 MQTT 在线 2 秒，用来等待服务器下发上传频率。
6. 设备断开 MQTT，进入等待或低功耗。

## 4. SM4 下发

设备请求 SM4：

```json
{
  "cmd": "request_sm4",
  "request_id": "sm4req-1-1770000000",
  "sn": "TN000001",
  "has_local": false,
  "time": 1770000000
}
```

服务器下发 SM4：

Topic：

```text
sys/{SN}/json/down/cmd
```

Payload：

```json
{
  "cmd": "set_sm4",
  "request_id": "sm4-001",
  "key": "1234567890123456",
  "iv": "1234567890666666"
}
```

说明：

- `key` 和 `iv` 支持 16 个普通字符，或 32 位 HEX。
- 加密方式固定为 `SM4-CBC + PKCS7`。
- 设备上报密文时会转成大写 HEX 文本。

设备回包：

```json
{
  "cmd": "set_sm4",
  "request_id": "sm4-001",
  "result": 0,
  "reason": "ok",
  "sn": "TN000001",
  "time": 1770000001
}
```

## 5. 实时上报

Topic：

```text
sys/{SN}/json/up/realTime
```

Payload 格式：

```text
HEX(SM4-CBC-PKCS7(明文JSON))
```

服务器收到后需要：

1. 将 HEX 转为密文字节。
2. 使用该 SN 对应的 SM4 `key` 和 `iv` 解密。
3. 去除 PKCS7 padding。
4. 按 JSON 解析明文。

明文 JSON 示例：

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

## 7. mosquitto 示例

订阅：

```bash
mosquitto_sub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/+/json/up/resp" -v
mosquitto_sub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/+/json/up/realTime" -v
```

下发 SM4：

```bash
mosquitto_pub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/TN000001/json/down/cmd" -m "{\"cmd\":\"set_sm4\",\"request_id\":\"sm4-001\",\"key\":\"1234567890123456\",\"iv\":\"1234567890666666\"}"
```

下发 10 分钟上传频率：

```bash
mosquitto_pub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/TN000001/json/down/cmd" -m "{\"cmd\":\"set_report_interval\",\"request_id\":\"interval-001\",\"sendFrequency\":10}"
```
