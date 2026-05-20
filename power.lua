local config = require("config")

local M = {}

function M.init()
    -- WORK_MODE=3 偏低功耗；不同固件不支持时直接跳过
    if pm and pm.power and pm.WORK_MODE then
        pm.power(pm.WORK_MODE, 3)
    end
end

function M.isTimerWake()
    -- 定时器唤醒时不再重复打开 5 分钟热点
    local id = pm and pm.dtimerWkId and pm.dtimerWkId()
    return id and id >= 0
end

function M.sleep(ms)
    -- 睡前关掉高耗电外设，再启动底层定时器
    if wlan and wlan.stopAP then
        wlan.stopAP()
    end
    if pm and pm.power and pm.GPS then
        pm.power(pm.GPS, false)
    end
    if pm and pm.dtimerStart then
        pm.dtimerStart(config.SLEEP_TIMER_ID, ms)
    end
    if config.USE_HIB_SLEEP and pm and pm.force and pm.HIB then
        -- HIB 唤醒会从 main.lua 重新跑，功耗最低
        pm.force(pm.HIB)
    elseif pm and pm.request and pm.LIGHT then
        pm.request(pm.LIGHT)
    end
    sys.wait(ms)
end

return M
