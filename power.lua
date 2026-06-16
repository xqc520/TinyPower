-- 低功耗业务入口：关闭外设、设置唤醒定时器，并进入 PSM+。
local config = require("config")

local M = {}

-- 获取当前时间戳，只用于低功耗日志定位。
local function now()
    return os and os.time and os.time() or 0
end

-- 统一封装 WORK_MODE 切换，避免各处直接调用 pm.power 后日志不一致。
local function setWorkMode(mode, label)
    if pm and pm.power and pm.WORK_MODE then
        local ok = pm.power(pm.WORK_MODE, mode)
        log.info("power", label or "mode", mode, tostring(ok))
        return ok
    end
    log.warn("power", "mode api missing")
    return false
end

-- 切回常规模式，唤醒后准备 GNSS/MQTT 前调用。
function M.normalMode()
    return setWorkMode(0, "mode normal")
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

-- 退出飞行模式，允许 4G 重新注册网络。
function M.cellularOn()
    if not config.CELLULAR_SLEEP_FLIGHT_MODE then
        return
    end
    M.normalMode()
    if mobile and mobile.flymode then
        local ok, ret = pcall(mobile.flymode, 0, false)
        log.info("power", "4g on", tostring(ok), tostring(ret))
    else
        log.warn("power", "4g api missing")
    end
end

-- 进入飞行模式，睡前关闭 4G 射频，避免没睡进去时 4G 继续耗电。
function M.cellularOff()
    if not config.CELLULAR_SLEEP_FLIGHT_MODE then
        return
    end
    if sys and sys.publish then
        sys.publish("IP_LOSE", nil, nil, "flight_mode")
    end
    if mobile and mobile.flymode then
        local ok, ret = pcall(mobile.flymode, 0, true)
        log.info("power", "4g off", tostring(ok), tostring(ret))
    else
        log.warn("power", "4g api missing")
    end
end

local function stopAp()
    -- 睡前优先调用 wifi_config.stop，让 HTTP/DNS/DHCP 都能一起关闭。
    local loaded = package and package.loaded
    local wifiConfig = loaded and loaded["wifi_config"] or nil
    if wifiConfig and wifiConfig.stop then
        pcall(wifiConfig.stop)
        return
    end
    if wlan and wlan.stopAP then
        pcall(wlan.stopAP)
    end
end

local function setSensorPower(enabled)
    if not config.PSM_DISABLE_SENSOR_POWER then
        return
    end
    -- 外部传感器电源默认不动；只有硬件确认需要省电时才打开此开关。
    local pin = config.PSM_SENSOR_POWER_GPIO
    if pin and gpio and gpio.setup then
        local level = enabled and (config.PSM_SENSOR_POWER_ON_LEVEL or 1) or (config.PSM_SENSOR_POWER_OFF_LEVEL or 0)
        gpio.setup(pin, level, gpio.PULLDOWN)
        if gpio.set then
            pcall(gpio.set, pin, level)
        end
        log.info("power", "sensor power", enabled and "on" or "off", pin, level)
    end
end

-- 业务开始前恢复外部传感器/GNSS 相关电源，避免睡前拉低后醒来没有信号。
function M.sensorPowerOn()
    setSensorPower(true)
end

local function stopSensorPower()
    -- 进入低功耗前关闭外部传感器电源，和 sensorPowerOn 成对使用。
    setSensorPower(false)
end

-- 进入低功耗主流程：
-- 1. 关闭 AP/GNSS/4G 等高功耗外设。
-- 2. 设置深睡唤醒定时器。
-- 3. 发布 DRV_SET_PSM，由 drv_psm.lua 完成 Air8000 PSM+ 配置和进入。
function M.sleep(ms)
    local sleepMs = ms or config.REPORT_INTERVAL_MS
    local sec = math.floor(sleepMs / 1000)
    log.info("power", "sleep start", sec, "s", "time", now())
    local timerOk = false

    if config.PSM_ONLY_TEST_MODE then
        stopSensorPower()
        if pm and pm.dtimerStart then
            timerOk = pm.dtimerStart(config.SLEEP_TIMER_ID, sleepMs) and true or false
            log.info("power", "minimal wake timer", "id", config.SLEEP_TIMER_ID, sec, "s", "ret", tostring(timerOk))
        else
            log.warn("power", "wake timer missing")
        end
        if not timerOk then
            log.warn("power", "skip psm, wake timer failed")
            sys.wait(sleepMs)
            return
        end
        log.info("power", "minimal DRV_SET_PSM", "time", now())
        require("drv_psm").enter()
        return
    end

    stopAp()

    if pm and pm.power and pm.GPS then
        pm.power(pm.GPS, false)
    end

    stopSensorPower()
    M.cellularOff()

    if pm and pm.dtimerStart then
        timerOk = pm.dtimerStart(config.SLEEP_TIMER_ID, sleepMs) and true or false
        log.info("power", "wake timer", "id", config.SLEEP_TIMER_ID, sec, "s", "ret", tostring(timerOk))
    else
        log.warn("power", "wake timer missing")
    end

    if not timerOk then
        log.warn("power", "skip psm, wake timer failed")
        sys.wait(sleepMs)
        return
    end

    if config.PRE_SLEEP_LOG_DELAY_MS and config.PRE_SLEEP_LOG_DELAY_MS > 0 then
        log.info("power", "log flush", config.PRE_SLEEP_LOG_DELAY_MS, "ms")
        sys.wait(config.PRE_SLEEP_LOG_DELAY_MS)
    end

    if config.USE_PSM_PLUS_SLEEP then
        log.info("power", "direct DRV_SET_PSM", "time", now())
        local drvPsm = require("drv_psm")
        if drvPsm and drvPsm.enter then
            drvPsm.enter()
            return
        end
        log.warn("power", "drv_psm enter missing")
    end

    log.warn("power", "psm disabled")
    sys.wait(sleepMs)
end

return M
