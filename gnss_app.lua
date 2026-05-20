local config = require("config")

local M = { opened = false }

-- Power and bind the GNSS UART once.
function M.open()
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
    log.info("gnss", "opened", config.GNSS_UART_ID, config.GNSS_BAUD)
end

-- Close GNSS UART and power to save energy after a fix attempt.
function M.close()
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
    log.info("gnss", "closed")
end

-- Read the latest valid RMC/GGA pair into the app location shape.
local function snapshot()
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

-- Wait until GNSS reports a valid fix or the timeout expires.
function M.fix(timeout)
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
        log.info("gnss", "waiting", waited)
    end
end

return M
