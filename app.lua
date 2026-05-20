local config = require("config")
local storage = require("storage")
local wifiConfig = require("wifi_config")
local gnss = require("gnss_app")
local mqttApp = require("mqtt_app")
local power = require("power")

local M = {}

-- Return current epoch seconds for report and wake logs.
local function now()
    return os and os.time and os.time() or 0
end

-- Log and return the next interval so every exit path is visible.
local function nextDelay(reason, ms)
    log.info("app", "next", reason, math.floor((ms or 0) / 1000), "s", "time", now())
    return ms
end

-- Decide whether to open the AP config portal on this boot.
local function setupWindowNeeded()
    if config.MQTT_TEST_MODE and storage.ready() then
        return false
    end
    if not storage.ready() then
        return true
    end
    return config.SETUP_ON_NORMAL_BOOT and (not power.isTimerWake())
end

-- Run one report cycle: get location, publish it, then return next delay.
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

-- Initialize storage/power and run the main loop in one LuatOS task.
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
                local testWait = config.MQTT_TEST_LOOP_MS or nextMs
                local waitMs = math.min(nextMs, testWait)
                log.info("app", "test wait", math.floor(waitMs / 1000), "s", "time", now())
                sys.wait(waitMs)
            elseif not config.LOW_POWER_ENABLE then
                log.info("app", "sleep disabled", math.floor(nextMs / 1000), "s", "time", now())
                sys.wait(nextMs)
            else
                log.info("app", "sleep next", math.floor(nextMs / 1000), "s", "time", now())
                power.sleep(nextMs)
            end
        end
    end)
end

return M
