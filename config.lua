local M = {}

-- 配网热点窗口配置。
M.AP_WINDOW_MS = 5 * 60 * 1000
M.AP_IP = "192.168.4.1"
M.AP_NETMASK = "255.255.255.0"
M.AP_GATEWAY = "192.168.4.1"
M.AP_CHANNEL = 6
M.AP_PASS = "12345678"
M.CONFIG_REBOOT_DELAY_MS = 1500

-- GNSS 串口配置，按实际硬件连线修改。
M.GNSS_UART_ID = 2
M.GNSS_BAUD = 115200
M.GNSS_FIX_TIMEOUT_MS = 240 * 1000
M.GNSS_DEBUG_LOG_INTERVAL_MS = 5 * 1000

-- 蜂窝网络和 MQTT 超时配置。
M.NET_TIMEOUT_MS = 60 * 1000
M.MQTT_TIMEOUT_MS = 45 * 1000
M.MQTT_QOS = 1
M.MQTT_CONNECT_RETRY_COUNT = 2
M.MQTT_CONNECT_RETRY_DELAY_MS = 5 * 1000
M.PUBLISH_RETRY_COUNT = 3
M.PUBLISH_RETRY_DELAY_MS = 15 * 1000
-- 固定后台 MQTT 连接，不在 WiFi 热点页面配置；普通 TCP MQTT，不使用 TLS。
M.MQTT_HOST = ""
M.MQTT_PORT = 1883
M.MQTT_USER = ""
M.MQTT_PASS = ""
-- MQTT 上报成功后保持在线一小段时间，方便服务器立刻下发配置。
M.POST_PUBLISH_DOWNLINK_WAIT_MS = 2 * 1000
-- 第二路 TCP 上报通道，由 WiFi 热点或 MQTT 下发配置。
M.TCP_CONNECT_TIMEOUT_MS = 20 * 1000
M.TCP_TX_WAIT_MS = 3 * 1000
M.TCP_CLOSE_DELAY_MS = 200
-- TCP 服务器按行读取时保留换行；如服务器使用定长/自定义协议，可改这里。
M.TCP_PAYLOAD_SUFFIX = "\n"

-- 电池电压采样：VBAT+ -- R21(170K) -- ADC0 -- R27(10K) -- GND。
M.BATTERY_ADC_ID = 0
M.BATTERY_ADC_RANGE = "MIN"
M.BATTERY_ADC_SAMPLE_COUNT = 10
M.BATTERY_ADC_SCAN_ON_ZERO = false
M.BATTERY_DIVIDER_TOP_KOHM = 170
M.BATTERY_DIVIDER_BOTTOM_KOHM = 10

-- 机箱温度采样：+4V -- R16(100K) -- TEMP_AD1 -- NTC(10K) -- GND。
-- TEMP_AD1 接 ADC1；按 4V 参考电压和 10K NTC 阻值表换算 tcase。
M.TCASE_ADC_ID = 1
M.TCASE_ADC_RANGE = "MAX"
M.TCASE_ADC_SAMPLE_COUNT = 10
M.TCASE_PULLUP_OHM = 100000
M.TCASE_VREF_MV = 4000
M.TCASE_TABLE_START_C = -40

-- 上报周期和低功耗配置。
M.REPORT_INTERVAL_MS = 10 * 60 * 1000
M.MIN_REPORT_INTERVAL_MS = 60 * 1000
M.MAX_REPORT_INTERVAL_MS = 24 * 60 * 60 * 1000
M.NO_CONFIG_RETRY_MS = 30 * 60 * 1000

-- 是否启用低功耗；false 时只等待下一周期，不会发布 DRV_SET_PSM。
M.LOW_POWER_ENABLE = true

-- 进入低功耗前是否打开飞行模式，用来关闭 4G 射频；GNSS 恢复前先关闭，避免影响定位。
M.CELLULAR_SLEEP_FLIGHT_MODE = false

-- 退出飞行模式后稍等一下，再开始 GNSS/MQTT 流程。
M.CELLULAR_WAKE_DELAY_MS = 1000

-- GNSS 定位期间是否保持 4G 关闭；部分固件进入飞行模式后会影响 GNSS 输出，默认保持 4G 打开。
M.CELLULAR_OFF_DURING_GNSS = false

-- 已配置设备普通上电是否仍打开配网热点。
-- false 表示第一次上电也先定位上报，然后进入低功耗。
M.SETUP_ON_NORMAL_BOOT = false

-- 启动后短暂停留，便于串口看到启动日志。
M.BOOT_LOG_DELAY_MS = 3000

-- 进入低功耗前等待日志输出完整。
M.PRE_SLEEP_LOG_DELAY_MS = 5000

-- 深睡唤醒定时器 ID；官方 PSM+ demo 使用 0 号定时器。
M.SLEEP_TIMER_ID = 0

-- 是否用“上报周期 - 本轮业务耗时”作为 PSM 睡眠时间。
-- true 表示唤醒后先记录本轮开始时间，定位/上报完成后只睡剩余时间，避免周期越跑越长。
M.PSM_DEDUCT_WORK_TIME = true

-- PSM+ 深睡定时器至少保留这段时间，避免 dtimer 太短导致还没稳定进入 PSM+ 就超时。
M.MIN_PSM_SLEEP_MS = 180 * 1000

-- Air8000 PSM+ 入口：业务层发布 DRV_SET_PSM，由 drv_psm.lua 执行 WORK_MODE=3。
M.USE_PSM_PLUS_SLEEP = true

-- drv_psm.lua 设置 PSM+ 后最多等待 80 秒；官方 demo 说明内核最长约 75 秒会进入。
M.PSM_ENTRY_TIMEOUT_MS = 80 * 1000

-- 默认只做定时器唤醒，不启用 GSensor/震动唤醒，避免睡前打开 exvib/I2C。
M.PSM_ENABLE_GSENSOR_WAKEUP = false

-- Air8000 内部 GPIO24 是 GNSS 备电/Gsensor 电源开关；默认保持高电平，避免睡醒后 GNSS 丢数据。
M.PSM_KEEP_GNSS_BACKUP = true

-- 开机阶段需要 WiFi 配网，因此不要在 drv_psm 加载时立刻关闭 WiFi 芯片。
M.PSM_BOOT_DISABLE_WIFI_CHIP = false

-- 不在定位前关闭 WiFi/airlink 芯片；部分硬件/固件关闭后会影响 GNSS 数据输出。
-- 真正进入 PSM+ 前 drv_psm.lua 仍会关闭 WiFi 芯片以降低休眠功耗。
M.PSM_DISABLE_WIFI_AFTER_SETUP = false

-- 外部 12V 传感器电源控制脚；先不在低功耗流程里拉低，避免误断 GNSS 相关电源。
M.PSM_DISABLE_SENSOR_POWER = false
M.PSM_SENSOR_POWER_GPIO = 16
M.PSM_SENSOR_POWER_ON_LEVEL = 1
M.PSM_SENSOR_POWER_OFF_LEVEL = 0
M.SENSOR_POWER_WAKE_DELAY_MS = 500

-- 纯低功耗诊断模式：不跑 GNSS/MQTT/配网，上电后直接进 PSM+。
M.PSM_ONLY_TEST_MODE = false
M.PSM_ONLY_TEST_SLEEP_MS = 10 * 60 * 1000

-- MQTT 测试模式：跳过热点和低功耗，按短间隔循环，方便联调。
M.MQTT_TEST_MODE = false
M.MQTT_TEST_LOOP_MS = 30 * 1000
M.MQTT_TEST_SUB_EXTRA = false
M.MQTT_TEST_FAKE_GNSS = false
M.MQTT_TEST_LOCATION = {
    lat = 39.908823,
    lng = 116.397470,
    speed = 0,
    course = 0,
    sats = 10,
    hdop = 0.8,
    altitude = 50,
}

return M
