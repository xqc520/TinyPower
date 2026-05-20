local config = require("config")

local M = { opened = false }

function M.open()
    -- 打开 GNSS 电源并把 NMEA 串口交给 libgnss 解析
    if M.opened then
        return
    end
    if pm and pm.power and pm.GPS then
        pm.power(pm.GPS, true)
    end
    uart.setup(config.GNSS_UART_ID, config.GNSS_BAUD)
    if libgnss.clear then
        libgnss.clear()
    end
    libgnss.bind(config.GNSS_UART_ID)
    M.opened = true
end

function M.close()
    -- 定位结束立刻关 GNSS，省电优先
    if not M.opened then
        return
    end
    if uart.close then
        uart.close(config.GNSS_UART_ID)
    end
    if pm and pm.power and pm.GPS then
        pm.power(pm.GPS, false)
    end
    M.opened = false
end

local function snapshot()
    -- 只在 RMC 有效时返回定位；坐标为 WGS84
    local rmc = libgnss.getRmc(2)
    if not (rmc and rmc.valid and rmc.lat and rmc.lng) then
        return nil
    end
    local gga = libgnss.getGga and libgnss.getGga(2) or {}
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
        sats = gga and gga.satellites_tracked or 0,
        hdop = gga and gga.hdop or 0,
        altitude = gga and (gga.altitude or gga.height) or 0,
    }
end

function M.fix(timeout)
    -- 最多等 timeout，成功就返回一次定位
    M.open()
    timeout = timeout or config.GNSS_FIX_TIMEOUT_MS
    local waited = 0
    while waited < timeout do
        local loc = snapshot()
        if loc then
            return loc
        end
        local step = math.min(5000, timeout - waited)
        sys.waitUntil("GNSS_STATE", step)
        waited = waited + step
    end
end

return M
