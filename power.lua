local config = require("config")

local M = {}
local modeReady = false

-- 获取当前时间戳，只用于低功耗日志定位。
local function now()
    return os and os.time and os.time() or 0
end

-- 设置模块工作模式。
-- 注意：WORK_MODE=3 只是切换省电工作模式，不等于真正休眠。
-- 当前只在 LIGHT 兜底路径里使用，HIB 路径直接调用 pm.force(pm.HIB)。
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

-- 读取本次启动是否由深睡定时器唤醒。
-- 返回值 >= 0 时，说明是 pm.dtimerStart 设置的定时器唤醒。
function M.timerWakeId()
    return pm and pm.dtimerWkId and pm.dtimerWkId() or nil
end

-- 判断本次启动是否为低功耗定时唤醒。
-- app.lua 用它决定是否跳过配网热点，直接定位上报。
function M.isTimerWake()
    local id = M.timerWakeId()
    return id and id >= 0
end

-- 进入低功耗主流程：
-- 1. 关闭 AP/GNSS 等高功耗外设。
-- 2. 设置深睡唤醒定时器。
-- 3. 等待一小段时间，让串口日志先输出完整。
-- 4. 优先进入 HIB；如果固件不支持 HIB，再尝试 LIGHT。
function M.sleep(ms)
    local sec = math.floor((ms or 0) / 1000)
    log.info("power", "sleep start", sec, "s", "time", now())

    -- 关闭热点，避免 WiFi AP 在休眠前继续耗电。
    if wlan and wlan.stopAP then
        wlan.stopAP()
    end

    -- 关闭 GNSS 电源；gnss_app.close() 已做过一次，这里再兜底。
    if pm and pm.power and pm.GPS then
        pm.power(pm.GPS, false)
    end

    -- 设置低功耗唤醒定时器，ms 到期后模块会重新从 main.lua 启动。
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

    -- HIB 是真正的深睡入口，正常情况下调用后不会继续往下执行。
    if config.USE_HIB_SLEEP and pm and pm.force and pm.HIB then
        log.info("power", "enter hib", "time", now())
        if config.HIB_LOG_DELAY_MS and config.HIB_LOG_DELAY_MS > 0 then
            sys.wait(config.HIB_LOG_DELAY_MS)
        end
        local ok = pm.force(pm.HIB)
        -- 如果还能打印到这里，说明 HIB 没有真正进入，需要继续查固件/API。
        log.warn("power", "hib return", tostring(ok), "time", now())
    elseif pm and pm.request and pm.LIGHT then
        -- LIGHT 是兜底浅睡，功耗通常高于 HIB。
        M.init()
        log.info("power", "enter light", "time", now())
        pm.request(pm.LIGHT)
    else
        log.warn("power", "sleep api missing")
    end

    -- 理论上 HIB 不会走到这里；走到这里说明没有进入深睡。
    sys.wait(ms)
    log.info("power", "sleep return", "time", now())
end

return M
