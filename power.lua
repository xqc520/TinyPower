local config = require("config")

local M = {}
local modeReady = false

-- Return current epoch seconds for logs.
local function now()
    return os and os.time and os.time() or 0
end

-- Put the module into the configured power work mode.
function M.init()
    if modeReady then
        return true
    end
    if pm and pm.power and pm.WORK_MODE then
        log.info("power", "mode set", 3)
        pm.power(pm.WORK_MODE, 3)
        modeReady = true
        return true
    end
    log.warn("power", "mode api missing")
    return false
end

-- Return the deep-sleep timer id that woke this boot, if any.
function M.timerWakeId()
    return pm and pm.dtimerWkId and pm.dtimerWkId() or nil
end

-- Detect whether this boot came from a deep-sleep timer wake.
function M.isTimerWake()
    local id = M.timerWakeId()
    return id and id >= 0
end

-- Stop radios, arm the wake timer, and enter low-power sleep.
function M.sleep(ms)
    local sec = math.floor((ms or 0) / 1000)
    log.info("power", "sleep start", sec, "s", "time", now())
    if wlan and wlan.stopAP then
        wlan.stopAP()
    end
    if pm and pm.power and pm.GPS then
        pm.power(pm.GPS, false)
    end
    if pm and pm.dtimerStart then
        local ok = pm.dtimerStart(config.SLEEP_TIMER_ID, ms)
        log.info("power", "wake timer", "id", config.SLEEP_TIMER_ID, sec, "s", "ret", tostring(ok))
    else
        log.warn("power", "wake timer missing")
    end
    if config.PRE_SLEEP_LOG_DELAY_MS and config.PRE_SLEEP_LOG_DELAY_MS > 0 then
        log.info("power", "log flush", config.PRE_SLEEP_LOG_DELAY_MS, "ms")
        sys.wait(config.PRE_SLEEP_LOG_DELAY_MS)
    end
    if config.USE_HIB_SLEEP and pm and pm.force and pm.HIB then
        log.info("power", "enter hib", "time", now())
        if config.HIB_LOG_DELAY_MS and config.HIB_LOG_DELAY_MS > 0 then
            sys.wait(config.HIB_LOG_DELAY_MS)
        end
        local ok = pm.force(pm.HIB)
        log.warn("power", "hib return", tostring(ok), "time", now())
    elseif pm and pm.request and pm.LIGHT then
        M.init()
        log.info("power", "enter light", "time", now())
        pm.request(pm.LIGHT)
    else
        log.warn("power", "sleep api missing")
    end
    sys.wait(ms)
    log.info("power", "sleep return", "time", now())
end

return M
