local config = require("config")
local storage = require("storage")
local power = require("power")

local M = {}

-- 获取当前时间戳，用于上报和启动/休眠日志。
local function now()
    return os and os.time and os.time() or 0
end

-- 获取当前运行毫秒数，用来计算本轮定位和上报已经消耗的时间。
-- 优先使用 mcu.ticks()，避免 RTC 校时变化影响周期计算。
local function nowMs()
    if mcu and type(mcu.ticks) == "function" and type(mcu.hz) == "function" then
        local hz = tonumber(mcu.hz()) or 0
        if hz > 0 then
            return math.floor((tonumber(mcu.ticks()) or 0) * 1000 / hz)
        end
    end
    return now() * 1000
end

-- 计算从本轮开始到当前已经过去的毫秒数；tick 异常回绕时按 0 处理。
local function elapsedMsSince(startMs)
    local current = nowMs()
    if not startMs or current < startMs then
        return 0
    end
    return current - startMs
end

-- 上报周期从本轮开始计时，业务完成后只睡剩余时间。
-- 例如周期 10 分钟、定位和 MQTT 花 3 分钟，则睡眠定时器设置约 7 分钟。
local function remainingDelay(nextMs, cycleStartMs)
    local elapsedMs = elapsedMsSince(cycleStartMs)
    local remainMs = (nextMs or 0) - elapsedMs
    if remainMs < 0 then
        remainMs = 0
    end
    log.info(
        "app",
        "cycle elapsed",
        math.floor(elapsedMs / 1000),
        "s",
        "remain",
        math.floor(remainMs / 1000),
        "s"
    )
    return remainMs
end

-- PSM+ 深睡定时器不宜设置得太短。
-- 剩余时间太短时改为普通等待，优先保证上报周期；业务已经超过周期时才睡最短 PSM，避免连续空转耗电。
local function psmSleepDelay(remainingMs)
    local minMs = config.MIN_PSM_SLEEP_MS or (90 * 1000)
    if remainingMs <= 0 then
        log.warn("app", "cycle overrun", "psm min", math.floor(minMs / 1000), "s")
        return minMs, true
    end
    if remainingMs < minMs then
        log.warn("app", "psm short wait", math.floor(remainingMs / 1000), "s")
        return remainingMs, false
    end
    return remainingMs, true
end

-- 每轮业务一开始就读取电池电压，避免 GNSS/MQTT 失败时完全看不到 battery 日志。
local function readBatteryVoltage()
    local device = require("device")
    local ok, voltage = pcall(device.batteryVoltage)
    if not ok then
        log.warn("app", "battery read error", tostring(voltage))
        return -1
    end
    if not voltage then
        log.warn("app", "battery unavailable")
        return -1
    end
    log.info("app", "battery voltage", voltage)
    return voltage
end

-- 每轮业务一开始读取机箱温度，和电池电压一起带到实时上报。
local function readTcase()
    local device = require("device")
    local ok, temp = pcall(device.tcaseTemperature)
    if not ok then
        log.warn("app", "tcase read error", tostring(temp))
        return -1
    end
    if not temp then
        log.warn("app", "tcase unavailable")
        return -1
    end
    log.info("app", "tcase", temp)
    return temp
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

local function stopSetupWifi()
    local loaded = package and package.loaded
    local wifiConfig = loaded and loaded["wifi_config"] or nil
    if wifiConfig and wifiConfig.stop then
        pcall(wifiConfig.stop)
    end
    if config.LOW_POWER_ENABLE and config.PSM_DISABLE_WIFI_AFTER_SETUP then
        local drvPsm = require("drv_psm")
        if drvPsm and drvPsm.disableWifiChip then
            drvPsm.disableWifiChip("setup done wifi chip off")
        end
    end
end

-- 执行一轮业务：读取配置 -> 采集状态 -> 等 4G 联网 -> GNSS 定位 -> MQTT 上报 -> 返回下一次间隔。
local function workOnce()
    local cfg = storage.get()
    if not storage.ready(cfg) then
        log.warn("app", "not configured")
        return nextDelay("no_config", config.NO_CONFIG_RETRY_MS)
    end
    log.info("app", "time now", now())
    log.info("app", "cycle start", "report_s", math.floor((cfg.report_interval_ms or 0) / 1000))

    -- 唤醒后先获取本轮要上报的状态信息。
    local batteryVoltage = readBatteryVoltage()
    local tcase = readTcase()

    -- 先等 4G 联网成功，再开始 GNSS；便于现场确认链路顺序，也避免发包阶段再长时间等网。
    local net = require("net")
    log.info("app", "net start", math.floor(config.NET_TIMEOUT_MS / 1000), "s")
    if not net.waitReady(config.NET_TIMEOUT_MS) then
        log.warn("app", "net timeout")
        return nextDelay("net_timeout", cfg.report_interval_ms)
    end
    log.info("app", "net ok")

    local loc
    if config.MQTT_TEST_MODE and config.MQTT_TEST_FAKE_GNSS then
        loc = config.MQTT_TEST_LOCATION
        log.info("app", "mqtt test loc", loc.lat, loc.lng)
    else
        local gnss = require("gnss_app")
        log.info("app", "gnss start", math.floor(config.GNSS_FIX_TIMEOUT_MS / 1000), "s")
        loc = gnss.fix(config.GNSS_FIX_TIMEOUT_MS)
        gnss.close()
        if not loc then
            log.warn("app", "gnss timeout")
            return nextDelay("gnss_timeout", cfg.report_interval_ms)
        end
        log.info("app", "gnss ok", "lat", loc.lat, "lng", loc.lng)
    end

    local mqttApp = require("mqtt_app")
    local tcpApp = require("tcp_app")
    local retryCount = tonumber(config.PUBLISH_RETRY_COUNT) or 1
    if retryCount < 1 then
        retryCount = 1
    end
    local ok = false
    local mqttDone = false
    local tcpDone = false
    for attempt = 1, retryCount do
        log.info("app", "send attempt", attempt, retryCount, "time", now())
        -- 固定 MQTT 先发，成功后会短暂在线等待服务器下发新的 TCP/SN/频度配置。
        if not mqttDone then
            mqttDone = mqttApp.publishLocation(cfg, loc, batteryVoltage, tcase)
        end
        -- TCP 走最新配置：如果 MQTT 刚下发了 tcp_host/tcp_port，本轮即可使用。
        if not tcpDone then
            local tcpCfg = storage.get()
            tcpDone = tcpApp.publishLocation(tcpCfg, loc, batteryVoltage, tcase)
        end
        ok = mqttDone and tcpDone
        log.info("app", "send result", "mqtt", mqttDone and 1 or 0, "tcp", tcpDone and 1 or 0)
        if ok then
            break
        end
        if attempt < retryCount then
            local delay = config.PUBLISH_RETRY_DELAY_MS or 15000
            log.warn("app", "send retry wait", math.floor(delay / 1000), "s", "time", now())
            sys.wait(delay)
        end
    end
    log.info("app", "send", ok and "ok" or "fail", "time", now())
    return nextDelay(ok and "publish_ok" or "publish_fail", storage.get().report_interval_ms)
end

-- 应用入口：初始化存储，判断启动来源，然后循环执行上报和低功耗。
function M.start()
    if config.PSM_ONLY_TEST_MODE then
        log.info("app", "psm only test")
        sys.taskInit(function()
            if config.BOOT_LOG_DELAY_MS and config.BOOT_LOG_DELAY_MS > 0 then
                sys.wait(config.BOOT_LOG_DELAY_MS)
            end
            power.sleep(config.PSM_ONLY_TEST_SLEEP_MS)
        end)
        return
    end

    storage.init()
    local bootCfg = storage.get()
    log.info("app", "cfg check",
        "sn_len", bootCfg.sn and #bootCfg.sn or 0,
        "host_len", bootCfg.mqtt_host and #bootCfg.mqtt_host or 0,
        "port", tostring(bootCfg.mqtt_port),
        "tcp_host_len", bootCfg.tcp_host and #bootCfg.tcp_host or 0,
        "tcp_port", tostring(bootCfg.tcp_port),
        "tcp_ready", storage.tcpReady(bootCfg) and 1 or 0,
        "ready", storage.ready(bootCfg) and 1 or 0
    )

    if config.LOW_POWER_ENABLE then
        log.info("app", "lowpower armed")
    else
        log.info("app", "lowpower disabled")
    end

    sys.taskInit(function()
        local timerWake = power.isTimerWake()
        local wakeId = power.timerWakeId and power.timerWakeId() or nil

        log.info("app", "boot",
            timerWake and "lowpower_wake" or "normal",
            "time", now(),
            "id", tostring(wakeId),
            "cfg", storage.ready() and 1 or 0
        )

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
            local wifiConfig = require("wifi_config")
            wifiConfig.startWindow()
            sys.waitUntil("CONFIG_UPDATED", config.AP_WINDOW_MS + 1000)
        else
            log.info("app", "configured, skip setup")
        end
        stopSetupWifi()

        while true do
            -- 唤醒后先记录本轮开始时间；dtimer 仍在 sleep 前启动，只传入扣除业务耗时后的剩余时间。
            local cycleStartMs = nowMs()
            local nextMs = workOnce()
            local remainMs = remainingDelay(nextMs, cycleStartMs)

            if config.MQTT_TEST_MODE then
                local testWait = config.MQTT_TEST_LOOP_MS or remainMs
                local waitMs = math.min(remainMs, testWait)
                log.info("app", "test wait", math.floor(waitMs / 1000), "s", "time", now())
                sys.wait(waitMs)

            elseif not config.LOW_POWER_ENABLE then
                log.info("app", "sleep disabled", math.floor(remainMs / 1000), "s", "time", now())
                sys.wait(remainMs)

            else
                local targetMs = config.PSM_DEDUCT_WORK_TIME and remainMs or nextMs
                local sleepMs, usePsm = psmSleepDelay(targetMs)
                log.info("app", usePsm and "sleep next" or "wait short", math.floor(sleepMs / 1000), "s", "time", now())
                if usePsm then
                    power.sleep(sleepMs)
                else
                    sys.wait(sleepMs)
                end
            end
        end
    end)
end
return M
