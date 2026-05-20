local config = require("config")
local storage = require("storage")
local wifiConfig = require("wifi_config")
local gnss = require("gnss_app")
local mqttApp = require("mqtt_app")
local power = require("power")

local M = {}

local function setupWindowNeeded()
    -- 普通上电开热点；定时唤醒且已配置时跳过热点
    return (not power.isTimerWake()) or (not storage.ready())
end

local function workOnce()
    -- 一轮业务：检查配置 -> 定位 -> MQTT 上报
    local cfg = storage.get()
    if not storage.ready(cfg) then
        log.warn("app", "not configured")
        return config.NO_CONFIG_RETRY_MS
    end

    local loc = gnss.fix(config.GNSS_FIX_TIMEOUT_MS)
    gnss.close()
    if not loc then
        log.warn("app", "gnss timeout")
        return cfg.report_interval_ms
    end

    local ok = mqttApp.publishLocation(cfg, loc)
    log.info("app", "publish", ok and "ok" or "fail")
    -- 服务器可能刚下发了新上传频率，这里重新读取一次
    return storage.get().report_interval_ms
end

function M.start()
    -- 主状态机只放在一个任务里，流程更容易看懂
    storage.init()
    --power.init()

    sys.taskInit(function()
        if setupWindowNeeded() then
            wifiConfig.startWindow()
            sys.wait(config.AP_WINDOW_MS + 1000)
        end

        while true do
            local nextMs = workOnce()
            --power.sleep(nextMs)
        end
    end)
end

return M
