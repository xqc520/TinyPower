# TinyPower 代码流程说明

最后更新：2026-06-15

## 1. 模块分工

| 文件 | 作用 | 维护重点 |
| --- | --- | --- |
| `main.lua` | 程序入口，加载调度器和应用状态机 | 一般不改，业务从 `app.lua` 开始 |
| `config.lua` | 固件固定参数和默认参数 | 固定 MQTT、超时、低功耗、ADC、GNSS 参数都在这里改 |
| `app.lua` | 主流程状态机 | 控制配网、采集、定位、双路上报、休眠 |
| `storage.lua` | 配置读写和字段归一化 | 只维护唯一字段：`sn`、`tcp_host`、`tcp_port`、`sendFrequency` |
| `wifi_config.lua` | 本地 WiFi 热点配置页 | 只允许配置 SN 和第二路 TCP |
| `mqtt_app.lua` | 固定 MQTT 上报和远程配置 | 普通 TCP MQTT，不使用 TLS；接收 `set_report_interval`、`set_config` |
| `tcp_app.lua` | 第二路 TCP 上报 | 使用 WiFi 或 MQTT 下发的 `tcp_host/tcp_port` |
| `report_payload.lua` | 上报 JSON 统一构造 | MQTT 和 TCP 必须共用这里，避免字段不一致 |
| `net.lua` | 蜂窝网络就绪等待和日志 | 统一等待 `IP_READY`，打印网络诊断 |
| `gnss_app.lua` | GNSS 打开、定位、关闭 | 定位失败原因主要看这里的日志 |
| `device.lua` | 设备 ID、电池电压、机箱温度 | ADC 采样、电压换算、NTC 温度换算 |
| `power.lua` | 业务层低功耗入口 | 设置唤醒定时器，关闭高功耗外设，进入 PSM+ |
| `drv_psm.lua` | Air8000 PSM+ 驱动配置 | 模组低功耗细节，谨慎修改 |

## 2. 启动流程

1. `main.lua` 加载 `sys`。
2. `main.lua` 加载 `drv_psm`，提前注册 PSM+ 相关能力。
3. `main.lua` 调用 `require("app").start()`。
4. `app.start()` 初始化 `storage`，读取当前配置。
5. `app.start()` 判断本次启动来源：
   - 低功耗定时唤醒：跳过配网，直接进入上报流程。
   - 普通上电且未配置：打开 WiFi 配网热点。
   - 普通上电且已配置：按 `SETUP_ON_NORMAL_BOOT` 决定是否打开配网热点。
6. `sys.run()` 接管 LuatOS 调度。

## 3. 配置流程

配置入口统一在 `storage.lua`。

设备最终使用的配置字段只有：

| 字段 | 来源 | 说明 |
| --- | --- | --- |
| `sn` | WiFi 热点或 MQTT 下发 | 设备 SN，也是 MQTT Topic 中的 `{SN}` |
| `tcp_host` | WiFi 热点或 MQTT 下发 | 第二路 TCP 服务器 IP 或域名 |
| `tcp_port` | WiFi 热点或 MQTT 下发 | 第二路 TCP 服务器端口 |
| `sendFrequency` | MQTT 下发或默认值 | 上报频度，单位分钟 |
| `mqtt_host` | `config.lua` | 固定 MQTT 地址 |
| `mqtt_port` | `config.lua` | 固定 MQTT 端口 |
| `mqtt_user` | `config.lua` | 固定 MQTT 用户名 |
| `mqtt_pass` | `config.lua` | 固定 MQTT 密码 |

维护原则：

- 固定 MQTT 参数只改 `config.lua`，不通过 WiFi 或远程命令修改。
- WiFi 热点只保存 `sn/tcp_host/tcp_port`。
- MQTT 远程配置只识别 `set_report_interval` 和 `set_config`。
- 上报频度对外只使用 `sendFrequency`，内部需要低功耗定时时再换算成毫秒。

## 4. 一轮上报流程

主流程在 `app.lua` 的 `workOnce()`。

1. 读取配置：`storage.get()`。
2. 计算本轮周期：`storage.reportIntervalMs(cfg)`。
3. 检查固定 MQTT 是否可用：`storage.ready(cfg)`。
4. 读取电池电压：`device.batteryVoltage()`。
5. 读取机箱温度：`device.tcaseTemperature()`。
6. 等待蜂窝网络：`net.waitReady()`。
7. 打开 GNSS 并等待定位：`gnss_app.fix()`。
8. 关闭 GNSS：`gnss_app.close()`。
9. 固定 MQTT 先上报：`mqtt_app.publishLocation()`。
10. MQTT 成功后保持在线约 2 秒，等待服务器下发配置。
11. 重新读取最新配置：`storage.get()`。
12. 第二路 TCP 上报：`tcp_app.publishLocation()`。
13. 根据最新 `sendFrequency` 返回下一轮间隔。

## 5. MQTT 流程

`mqtt_app.lua` 负责固定 MQTT。

1. 等待网络就绪。
2. 使用 `config.lua` 中的固定 MQTT 地址和端口创建普通 TCP MQTT 连接。
3. 使用设备 IMEI 或 SN 生成 client id。
4. 订阅 `sys/{SN}/json/down/cmd`。
5. 调用 `report_payload.location()` 构建明文 JSON。
6. 发布到 `sys/{SN}/json/up/realTime`。
7. 上报成功后等待 `POST_PUBLISH_DOWNLINK_WAIT_MS`，默认约 2 秒。
8. 收到下行命令时：
   - `set_report_interval`：只修改 `sendFrequency`。
   - `set_config`：只修改 `config` 子对象中的 `sn/tcp_host/tcp_port/sendFrequency`。
9. 命令处理结果发布到 `sys/{SN}/json/up/resp`。
10. 断开 MQTT。

## 6. 第二路 TCP 流程

`tcp_app.lua` 负责第二路 TCP。

1. 调用 `storage.tcpReady(cfg)` 判断 `tcp_host/tcp_port` 是否完整。
2. 未配置时直接跳过，并返回成功，不影响固定 MQTT。
3. 已配置时等待网络就绪。
4. 连接 `tcp_host:tcp_port`。
5. 调用 `report_payload.location()` 构建与 MQTT 相同的明文 JSON。
6. 追加 `config.TCP_PAYLOAD_SUFFIX`，默认是换行。
7. 发送后短暂等待发送完成事件。
8. 关闭 socket。

## 7. 上报载荷流程

`report_payload.lua` 是唯一的实时上报 JSON 构造入口。

当前字段：

| 字段 | 来源 |
| --- | --- |
| `SN` | `cfg.sn` |
| `timeStamp` | 当前 epoch 秒 |
| `sendFrequency` | `cfg.sendFrequency` |
| `tcase` | `device.tcaseTemperature()` 或上层传入值 |
| `batteryVoltage` | `device.batteryVoltage()` 或上层传入值 |
| `latitude` | GNSS 定位结果 |
| `longitude` | GNSS 定位结果 |

维护原则：

- 新增上报字段时只改 `report_payload.lua` 和 `SERVER_API.md`。
- MQTT 和 TCP 不要各自拼 JSON。
- 电池电压保留两位小数的逻辑在 `report_payload.lua`，不要移到发送模块里。

## 8. GNSS 和传感器流程

定位由 `gnss_app.lua` 管理。

1. `gnss_app.open()` 打开 GNSS 电源，配置 UART，绑定 `libgnss`。
2. `gnss_app.fix(timeout)` 周期读取 RMC/GGA/GSA/GSV。
3. 只有 RMC 有效且经纬度存在时才返回定位结果。
4. 等待期间持续打印诊断日志，区分无串口数据、无卫星、有星未定位等情况。
5. 上报完成或定位失败后调用 `gnss_app.close()`。

电池和温度由 `device.lua` 管理。

1. 电池电压读取 ADC0，按外部分压比例换算为 V。
2. 机箱温度读取 ADC1，按 10K NTC 阻值表换算为摄氏度。
3. 读取失败时上层使用 `-1` 或 `-1.00` 上报，避免整轮流程中断。

## 9. 低功耗流程

低功耗入口在 `app.lua`，执行动作在 `power.lua` 和 `drv_psm.lua`。

1. 每轮开始时记录 `cycleStartMs`。
2. `workOnce()` 返回下一轮周期毫秒数。
3. `remainingDelay()` 扣除本轮业务耗时，只睡剩余时间。
4. 测试模式下使用普通 `sys.wait()`。
5. 低功耗关闭时使用普通 `sys.wait()`。
6. 低功耗开启时：
   - 剩余时间太短则普通等待。
   - 剩余时间足够则调用 `power.sleep()`。
7. `power.sleep()` 关闭 AP/GNSS/可选 4G/可选外部电源。
8. `power.sleep()` 设置 `pm.dtimerStart()` 唤醒定时器。
9. `drv_psm.enter()` 执行 Air8000 PSM+ 配置，并进入 `WORK_MODE 3`。
10. PSM+ 唤醒后脚本重新启动，再从 `main.lua` 开始执行。

## 10. 常见维护入口

| 需求 | 优先修改文件 | 注意事项 |
| --- | --- | --- |
| 修改固定 MQTT 地址 | `config.lua` | 只改 `MQTT_HOST/MQTT_PORT/MQTT_USER/MQTT_PASS` |
| 修改第二路 TCP 规则 | `tcp_app.lua`、`config.lua` | 报文内容仍从 `report_payload.lua` 来 |
| 修改上报字段 | `report_payload.lua`、`SERVER_API.md` | 两路连接共用同一份 JSON |
| 修改远程配置字段 | `storage.lua`、`mqtt_app.lua`、`SERVER_API.md` | 保持唯一字段，不增加别名 |
| 修改上报周期规则 | `storage.lua`、`config.lua` | 对外单位分钟，对内低功耗使用毫秒 |
| 修改配网页面 | `wifi_config.lua` | 不要把固定 MQTT 放到页面上 |
| 修改定位超时 | `config.lua` | `GNSS_FIX_TIMEOUT_MS` 影响功耗和定位成功率 |
| 修改低功耗策略 | `config.lua`、`power.lua`、`drv_psm.lua` | 先确认硬件唤醒方式和实测功耗 |
| 排查网络问题 | `net.lua`、串口日志 | 关注 `IP_READY`、CSQ、SIM 状态 |
| 排查定位问题 | `gnss_app.lua`、串口日志 | 关注 `diag reason` 和卫星数 |

## 11. 日志定位

| 日志前缀 | 模块 | 用途 |
| --- | --- | --- |
| `app` | `app.lua` | 主流程、周期、重试、休眠 |
| `setup` | `wifi_config.lua` | WiFi 热点和保存配置 |
| `mqtt` | `mqtt_app.lua` | MQTT 连接、订阅、上报、下发 |
| `tcp` | `tcp_app.lua` | 第二路 TCP 连接和发送 |
| `payload` | `report_payload.lua` | 上报 JSON 构造异常 |
| `net` | `net.lua` | 蜂窝网络状态 |
| `gnss` | `gnss_app.lua` | 定位状态和失败原因 |
| `device` | `device.lua` | ADC、电池、温度 |
| `power` | `power.lua` | 休眠准备和唤醒定时 |
| `drv_psm`、`psm` | `drv_psm.lua` | PSM+ 底层配置 |

## 12. 维护约定

1. 先改 `config.lua` 能解决的问题，不要改业务流程。
2. 远程协议字段保持唯一，新增字段必须同步 `SERVER_API.md`。
3. 上报 JSON 只能在 `report_payload.lua` 统一维护。
4. MQTT 是固定后台连接，第二路 TCP 是可配置业务连接，两者不要混在一起。
5. 低功耗相关改动必须关注唤醒定时器是否设置成功。
6. 串口日志是现场排查主入口，新增关键流程时同步加简洁日志。
