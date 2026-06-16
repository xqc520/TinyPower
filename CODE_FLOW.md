# TinyPower 代码流程

最后更新：2026-06-16

## 1. 先看哪些文件

建议按这个顺序读代码：

1. `main.lua`：程序入口。
2. `app.lua`：主流程，负责配网、定位、上报、休眠。
3. `storage.lua`：配置读写，统一字段。
4. `mqtt_app.lua`：固定 MQTT 上报和远程配置。
5. `tcp_app.lua`：第二路 TCP 上报。
6. `report_payload.lua`：两路连接共用的上报 JSON。
7. `power.lua`、`drv_psm.lua`：低功耗和 PSM+。

## 2. 模块职责

| 文件 | 职责 |
| --- | --- |
| `config.lua` | 固件固定参数：MQTT、超时、GNSS、ADC、低功耗 |
| `app.lua` | 主状态机：配网、采集、定位、双路上报、进入低功耗 |
| `storage.lua` | 持久化配置，只使用 `sn/tcp_host/tcp_port/sendFrequency` |
| `wifi_config.lua` | WiFi 热点配置页，只配置 SN 和第二路 TCP |
| `mqtt_app.lua` | 固定普通 MQTT 连接，接收远程配置 |
| `tcp_app.lua` | 可配置 TCP 连接，发送同一份实时 JSON |
| `report_payload.lua` | 统一生成实时上报 JSON |
| `net.lua` | 等待蜂窝网络就绪，打印网络诊断 |
| `gnss_app.lua` | 打开 GNSS、等待定位、关闭 GNSS |
| `device.lua` | 读取电池电压、机箱温度、设备标识 |
| `power.lua` | 设置唤醒定时器，准备进入低功耗 |
| `drv_psm.lua` | Air8000 PSM+ 底层配置 |

## 3. 启动流程

1. `main.lua` 加载 `sys` 和 `drv_psm`。
2. `main.lua` 调用 `app.start()`。
3. `app.start()` 初始化 `storage` 并读取配置。
4. 未配置时打开 WiFi 热点；低功耗定时唤醒时跳过热点。
5. 进入循环：采集、定位、上报、休眠。

## 4. 配置流程

配置统一从 `storage.lua` 读写。

| 字段 | 来源 | 说明 |
| --- | --- | --- |
| `sn` | WiFi 或 MQTT | 设备 SN，也是 MQTT Topic 中的 `{SN}` |
| `tcp_host` | WiFi 或 MQTT | 第二路 TCP IP 或域名 |
| `tcp_port` | WiFi 或 MQTT | 第二路 TCP 端口 |
| `sendFrequency` | MQTT 或默认值 | 上报频度，单位分钟 |

固定 MQTT 地址、端口、账号、密码只在 `config.lua` 中修改，不通过 WiFi 或远程命令配置。

## 5. 一轮业务流程

主流程在 `app.lua` 的 `workOnce()`。

1. 读取配置，计算本轮上报周期。
2. 读取电池电压和机箱温度。
3. 等待蜂窝网络就绪。
4. 打开 GNSS，定位成功后同步系统时间，再关闭 GNSS。
5. 先走固定 MQTT 上报。
6. MQTT 上报成功后在线等待约 2 秒，接收远程配置。
7. 重新读取最新配置。
8. 如果第二路 TCP 已配置，则发送同一份实时 JSON。
9. 扣除本轮耗时，进入等待或低功耗。

## 6. 双路连接

| 通道 | 文件 | 特点 |
| --- | --- | --- |
| 固定 MQTT | `mqtt_app.lua` | 地址写死在 `config.lua`，普通 TCP MQTT，不使用 TLS |
| 第二路 TCP | `tcp_app.lua` | 地址由 WiFi 或 MQTT 配置，未配置时跳过 |

两路连接都调用 `report_payload.location()` 生成同一份明文 JSON。

## 7. 远程命令

MQTT 下行 Topic：`sys/{SN}/json/down/cmd`。

| 命令 | 作用 | 字段 |
| --- | --- | --- |
| `set_report_interval` | 修改上报频度 | `sendFrequency` |
| `set_config` | 修改设备配置 | `config.sn`、`config.tcp_host`、`config.tcp_port`、`config.sendFrequency` |

只识别上表字段，不兼容其它字段名。

## 8. 低功耗流程

1. `app.lua` 记录本轮开始时间。
2. 上报结束后计算剩余周期。
3. 剩余时间太短时普通等待。
4. 剩余时间足够时调用 `power.sleep()`。
5. `power.sleep()` 关闭高功耗外设，设置 `pm.dtimerStart()`。
6. `drv_psm.enter()` 进入 Air8000 PSM+。
7. PSM+ 唤醒后脚本重新从 `main.lua` 启动。

## 9. 常见修改入口

| 需求 | 修改文件 |
| --- | --- |
| 修改固定 MQTT | `config.lua` |
| 修改 WiFi 配网页面 | `wifi_config.lua` |
| 修改远程配置字段 | `storage.lua`、`mqtt_app.lua`、`SERVER_API.md` |
| 修改上报 JSON | `report_payload.lua`、`SERVER_API.md` |
| 修改第二路 TCP 行为 | `tcp_app.lua` |
| 修改定位超时 | `config.lua` |
| 修改低功耗策略 | `config.lua`、`power.lua`、`drv_psm.lua` |

## 10. 日志前缀

| 前缀 | 模块 |
| --- | --- |
| `app` | 主流程 |
| `setup` | WiFi 配网 |
| `mqtt` | 固定 MQTT |
| `tcp` | 第二路 TCP |
| `net` | 蜂窝网络 |
| `gnss` | GNSS 定位 |
| `device` | 电池和温度 |
| `power` | 休眠准备 |
| `drv_psm`、`psm` | PSM+ |

维护原则：固定 MQTT 和第二路 TCP 分开；上报 JSON 只在 `report_payload.lua` 维护；远程字段保持唯一。
