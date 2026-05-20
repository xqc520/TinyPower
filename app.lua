local config = require("config")
local storage = require("storage")
local wifiConfig = require("wifi_config")
local gnss = require("gnss_app")
local mqttApp = require("mqtt_app")
local power = require("power")

local M = {}

-- 获取当前时间戳，用于上报和启动/休眠日志。
local function now()
    return os and os.time and os.time() or 0
end

-- 记录下一次执行间隔，所有异常路径也统一从这里返回。
local function nextDelay(reason, ms)
    log.info("app", "next", reason, math.floor((ms or 0) / 1000), "s", "time", now())
    return ms
end

-- 判断本次启动是否需要打开配网热点。
-- 未配置时必须开热点；已配置时默认直接上报，不再每次普通上电都开热点。
local function setupWindowNeeded()
    if config.MQTT_TEST_MODE and storage.ready() then
        return false
    end
    if not storage.ready() then
        return true
    end
    return config.SETUP_ON_NORMAL_BOOT and (not power.isTimerWake())
end

-- 执行一轮业务：读取配置 -> 获取经纬度 -> MQTT 上报 -> 返回下一次间隔。
local function workOnce()
    local cfg = storage.get()
    if not storage.ready(cfg) then
        log.warn("app", "not configured")
        return nextDelay("no_config", config.NO_CONFIG_RETRY_MS)
    end
    log.info("app", "time now", now())
    log.info("app", "cycle start", "report_s", math.floor((cfg.report_interval_ms or 0) / 1000))

    local loc
    if config.MQTT_TEST_MODE and config.MQTT_TEST_FAKE_GNSS then
        loc = config.MQTT_TEST_LOCATION
        log.info("app", "mqtt test loc", loc.lat, loc.lng)
    else
        log.info("app", "gnss start", math.floor(config.GNSS_FIX_TIMEOUT_MS / 1000), "s")
        loc = gnss.fix(config.GNSS_FIX_TIMEOUT_MS)
        gnss.close()
        if not loc then
            log.warn("app", "gnss timeout")
            return nextDelay("gnss_timeout", cfg.report_interval_ms)
        end
        log.info("app", "gnss ok", "lat", loc.lat, "lng", loc.lng)
    end

    local ok = mqttApp.publishLocation(cfg, loc)
    log.info("app", "send", ok and "ok" or "fail", "time", now())
    return nextDelay(ok and "publish_ok" or "publish_fail", storage.get().report_interval_ms)
end

-- 应用入口：初始化存储，判断启动来源，然后循环执行上报和低功耗。
function M.start()
    storage.init()
    if config.LOW_POWER_ENABLE then
        log.info("app", "lowpower armed")
    else
        log.info("app", "lowpower disabled")
    end

    sys.taskInit(function()
        local timerWake = power.isTimerWake()
        local wakeId = power.timerWakeId and power.timerWakeId() or nil

        -- 打印启动类型：normal 表示普通上电，lowpower_wake 表示深睡定时唤醒。
        log.info("app", "boot", timerWake and "lowpower_wake" or "normal", "time", now(), "id", tostring(wakeId), "cfg", storage.ready() and 1 or 0)
        if timerWake then
            log.info("app", "wake lowpower", "id", tostring(wakeId), "time", now())
        else
            log.info("app", "time now", now())
        end
        if config.BOOT_LOG_DELAY_MS and config.BOOT_LOG_DELAY_MS > 0 then
            log.info("app", "boot hold", config.BOOT_LOG_DELAY_MS, "ms")
            sys.wait(config.BOOT_LOG_DELAY_MS)
        end

        -- 只有未配置时才进入配网页面；已配置设备直接上报。
        if setupWindowNeeded() then
            log.info("app", "setup window")
            wifiConfig.startWindow()
            sys.waitUntil("CONFIG_UPDATED", config.AP_WINDOW_MS + 1000)
        else
            log.info("app", "configured, skip setup")
        end

        while true do
            local nextMs = workOnce()
            if config.MQTT_TEST_MODE then
                -- MQTT 测试模式不进低功耗，按短间隔循环，方便连续看日志。
                local testWait = config.MQTT_TEST_LOOP_MS or nextMs
                local waitMs = math.min(nextMs, testWait)
                log.info("app", "test wait", math.floor(waitMs / 1000), "s", "time", now())
                sys.wait(waitMs)
            elseif not config.LOW_POWER_ENABLE then
                -- 关闭低功耗时，只等待下一周期，不调用 power.sleep。
                log.info("app", "sleep disabled", math.floor(nextMs / 1000), "s", "time", now())
                sys.wait(nextMs)
            else
                -- 正常生产流程：上报完成后进入低功耗，等待定时器唤醒。
                log.info("app", "sleep next", math.floor(nextMs / 1000), "s", "time", now())
                power.sleep(nextMs)
            end
        end
    end)
end

return M
