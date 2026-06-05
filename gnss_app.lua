local config = require("config")

local M = { opened = false }

local function value(v)
    if v == nil then
        return "nil"
    end
    return tostring(v)
end

local function safeCall(obj, name, ...)
    local fn = obj and obj[name]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, ret = pcall(fn, ...)
    if ok then
        return ret
    end
    log.warn("gnss", name, "err", tostring(ret))
    return nil
end

-- libgnss 在不同固件版本里可能返回数字、字符串或 table，这里统一转成数字便于日志判断。
local function numberValue(v)
    if type(v) == "number" then
        return v
    end
    if type(v) == "string" then
        return tonumber(v)
    end
    if type(v) == "table" then
        return tonumber(v.sats or v.satellites or v.num or v[1])
    end
    return nil
end

-- 打开 GNSS 电源并绑定 UART。只在未打开时执行，避免重复 setup 影响串口接收。
function M.open()
    if M.opened then
        return
    end
    if pm and pm.power and pm.GPS then
        local ok = pm.power(pm.GPS, true)
        log.info("gnss", "power on", tostring(ok))
    end
    local uartRet = uart.setup(config.GNSS_UART_ID, config.GNSS_BAUD)
    log.info("gnss", "uart setup", config.GNSS_UART_ID, config.GNSS_BAUD, tostring(uartRet))
    if libgnss.clear then
        safeCall(libgnss, "clear")
    end
    local bindRet = safeCall(libgnss, "bind", config.GNSS_UART_ID)
    M.opened = true
    log.info("gnss", "opened", config.GNSS_UART_ID, config.GNSS_BAUD, "bind", tostring(bindRet))
end

-- 本轮定位结束后关闭 GNSS 串口和电源，用于降低平均功耗。
function M.close()
    if not M.opened then
        return
    end
    if uart.close then
        uart.close(config.GNSS_UART_ID)
    end
    if pm and pm.power and pm.GPS then
        local ok = pm.power(pm.GPS, false)
        log.info("gnss", "power off", tostring(ok))
    end
    M.opened = false
    log.info("gnss", "closed")
end

-- 一次性读取 RMC/GGA/GSA/GSV 状态，后续日志和定位快照都基于同一份数据。
local function readStatus()
    return {
        rmc = safeCall(libgnss, "getRmc", 2),
        gga = safeCall(libgnss, "getGga", 2) or {},
        gsa = safeCall(libgnss, "getGsa", 2) or {},
        gsv = safeCall(libgnss, "getGsv", 2) or {},
    }
end

-- 优先从 GGA 取已跟踪卫星数，取不到再尝试 GSV 可见卫星数。
local function satellites(gga, gsv)
    return numberValue(gga and (gga.satellites_tracked or gga.sats or gga.satellites))
        or numberValue(gsv and (gsv.satellites_view or gsv.sats or gsv.satellites))
        or 0
end

-- UTC 时间不是 0，说明至少解析到过 RMC 时间字段。
local function hasTime(rmc)
    return rmc and (
        tonumber(rmc.hour or 0) ~= 0
        or tonumber(rmc.min or 0) ~= 0
        or tonumber(rmc.sec or 0) ~= 0
    )
end

-- 经纬度不是 0，说明 GNSS 已经输出过坐标字段，但还不一定代表定位有效。
local function hasCoord(rmc)
    return rmc and tonumber(rmc.lat or 0) ~= 0 and tonumber(rmc.lng or 0) ~= 0
end

-- 累计本轮定位过程里的诊断信息，用来区分“完全没数据”和“有数据但没定位”。
local function updateDiag(diag, status, hasEvent)
    local rmc = status and status.rmc or {}
    local gga = status and status.gga or {}
    local gsv = status and status.gsv or {}
    local sats = satellites(gga, gsv)
    diag.events = diag.events + (hasEvent and 1 or 0)
    diag.maxSats = math.max(diag.maxSats, sats)
    diag.seenTime = diag.seenTime or hasTime(rmc)
    diag.seenCoord = diag.seenCoord or hasCoord(rmc)
    diag.seenValid = diag.seenValid or (rmc and rmc.valid and true or false)
end

-- 根据本轮累计状态给出诊断原因：
-- no_nmea_or_uart     ：全是 0，通常是 GNSS 没输出、UART 没收到或解析层没有数据。
-- nmea_no_satellite   ：有 GNSS 事件/数据，但卫星数一直是 0，优先检查天线、环境和模块冷启动。
-- satellite_no_fix    ：已经看到卫星，但 RMC valid 仍无效，通常是信号弱或定位时间不够。
-- coord_not_valid     ：有坐标字段但未标记有效，需要继续看 RMC valid 和天线环境。
local function diagReason(diag)
    if diag.seenValid then
        return "fixed"
    end
    if diag.events == 0 and not diag.seenTime and not diag.seenCoord and diag.maxSats == 0 then
        return "no_nmea_or_uart"
    end
    if diag.events > 0 and diag.maxSats == 0 and not diag.seenCoord then
        return "nmea_no_satellite"
    end
    if diag.maxSats > 0 and not diag.seenValid then
        return "satellite_no_fix"
    end
    if diag.seenCoord and not diag.seenValid then
        return "coord_not_valid"
    end
    return "unknown"
end

-- 周期性输出诊断摘要；final=true 时表示本轮定位结束前的最终结论。
local function logDiag(diag, waited, final)
    log.info("gnss", final and "diag final" or "diag",
        "wait", math.floor((waited or 0) / 1000), "s",
        "reason", diagReason(diag),
        "events", diag.events,
        "max_sats", diag.maxSats,
        "seen_time", diag.seenTime and 1 or 0,
        "seen_coord", diag.seenCoord and 1 or 0,
        "seen_valid", diag.seenValid and 1 or 0)
end

-- 打印当前 libgnss 解析到的原始状态，方便现场判断是无数据、无星还是有星未定位。
local function logStatus(waited, status, reason)
    status = status or readStatus()
    local rmc = status.rmc or {}
    local gga = status.gga or {}
    local gsa = status.gsa or {}
    local gsv = status.gsv or {}
    log.info("gnss", "status",
        "wait", math.floor((waited or 0) / 1000), "s",
        "reason", reason or "poll",
        "valid", rmc.valid and 1 or 0,
        "lat", value(rmc.lat),
        "lng", value(rmc.lng),
        "sats", value(satellites(gga, gsv)),
        "hdop", value(gga.hdop or gsa.hdop),
        "alt", value(gga.altitude or gga.height),
        "utc", value(rmc.hour) .. ":" .. value(rmc.min) .. ":" .. value(rmc.sec))
end

-- 只在 RMC valid 且经纬度存在时生成上报位置，避免把 0 坐标误上报成有效定位。
local function snapshot(status)
    status = status or readStatus()
    local rmc = status.rmc
    if not (rmc and rmc.valid and rmc.lat and rmc.lng) then
        return nil
    end
    local gga = status.gga or {}
    return {
        lat = rmc.lat,
        lng = rmc.lng,
        speed = rmc.speed or 0,
        course = rmc.course or rmc.variation or 0,
        year = rmc.year,
        month = rmc.month,
        day = rmc.day,
        hour = rmc.hour,
        min = rmc.min,
        sec = rmc.sec,
        sats = satellites(gga, status.gsv),
        hdop = gga and gga.hdop or 0,
        altitude = gga and (gga.altitude or gga.height) or 0,
    }
end

-- 等待 GNSS 定位成功或超时；等待过程中持续打印状态和诊断原因。
function M.fix(timeout)
    M.open()
    timeout = timeout or config.GNSS_FIX_TIMEOUT_MS
    log.info("gnss", "fix start", "timeout", math.floor(timeout / 1000), "s")
    local waited = 0
    local logInterval = config.GNSS_DEBUG_LOG_INTERVAL_MS or 5000
    local diag = {
        events = 0,
        maxSats = 0,
        seenTime = false,
        seenCoord = false,
        seenValid = false,
    }
    while waited < timeout do
        local status = readStatus()
        local loc = snapshot(status)
        if loc then
            updateDiag(diag, status, false)
            log.info("gnss", "fix ok",
                "wait", math.floor(waited / 1000), "s",
                "lat", loc.lat,
                "lng", loc.lng,
                "sats", loc.sats,
                "hdop", loc.hdop,
                "alt", loc.altitude)
            logDiag(diag, waited, true)
            return loc
        end
        logStatus(waited, status, "no_fix")
        local step = math.min(logInterval, timeout - waited)
        local ok, a, b, c = sys.waitUntil("GNSS_STATE", step)
        waited = waited + step
        -- 有 GNSS_STATE 事件说明解析层至少收到过 GNSS 相关更新，可和全 0 场景区分。
        updateDiag(diag, status, ok)
        if ok then
            log.info("gnss", "event", "GNSS_STATE", value(a), value(b), value(c))
        end
        logDiag(diag, waited, false)
    end
    local status = readStatus()
    updateDiag(diag, status, false)
    logStatus(waited, status, "timeout")
    logDiag(diag, waited, true)
    log.warn("gnss", "fix timeout", math.floor(timeout / 1000), "s", "reason", diagReason(diag))
end

return M
