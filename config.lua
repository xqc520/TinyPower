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
M.GNSS_FIX_TIMEOUT_MS = 120 * 1000

-- 蜂窝网络和 MQTT 超时配置。
M.NET_TIMEOUT_MS = 60 * 1000
M.MQTT_TIMEOUT_MS = 45 * 1000
M.MQTT_QOS = 1
M.SM4_TIMEOUT_MS = 20 * 1000
M.CA_FILE = "/luadb/rootCA.crt"

-- 上报周期和低功耗配置。
M.REPORT_INTERVAL_MS = 10 * 60 * 1000
M.MIN_REPORT_INTERVAL_MS = 60 * 1000
M.MAX_REPORT_INTERVAL_MS = 24 * 60 * 60 * 1000
M.NO_CONFIG_RETRY_MS = 30 * 60 * 1000

-- 是否启用低功耗；false 时只等待下一周期，不会进入 HIB/LIGHT。
M.LOW_POWER_ENABLE = true

-- 已配置设备普通上电是否仍打开配网热点。
-- false 表示第一次上电也先定位上报，然后进入低功耗。
M.SETUP_ON_NORMAL_BOOT = false

-- 启动后短暂停留，便于串口看到启动日志。
M.BOOT_LOG_DELAY_MS = 3000

-- 进入低功耗前等待日志输出完整。
M.PRE_SLEEP_LOG_DELAY_MS = 5000

-- 打印 enter hib 后再等一小段时间，避免最后一行日志丢失。
M.HIB_LOG_DELAY_MS = 300

-- 深睡唤醒定时器 ID；唤醒后可通过 pm.dtimerWkId() 判断来源。
M.SLEEP_TIMER_ID = 2

-- true 时优先使用 HIB 深睡；false 或不支持时可走 LIGHT 兜底。
M.USE_HIB_SLEEP = true

-- MQTT 测试模式：跳过热点和低功耗，按短间隔循环，方便联调。
M.MQTT_TEST_MODE = false
M.MQTT_TEST_LOOP_MS = 30 * 1000
M.MQTT_TEST_SUB_EXTRA = false
M.MQTT_TEST_FORCE_SM4 = false
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
