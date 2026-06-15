local device = require("device")

local M = {}

local function now()
    return os and os.time and os.time() or 0
end

local function fixedDecimalText(value, decimals)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    return string.format("%." .. tostring(decimals or 0) .. "f", n)
end

-- Build the plaintext realtime JSON used by both MQTT and TCP uploads.
function M.location(cfg, loc, batteryVoltage, tcase)
    if batteryVoltage == nil then
        batteryVoltage = device.batteryVoltage()
    end
    if not batteryVoltage then
        batteryVoltage = -1
    end
    local batteryVoltageText = fixedDecimalText(batteryVoltage, 2) or "-1.00"
    if tcase == nil and device.tcaseTemperature then
        tcase = device.tcaseTemperature()
    end
    if not tcase then
        tcase = -1
    end

    local timestamp = tostring(now())
    local sendFrequency = math.max(1, math.floor(cfg.report_interval_ms / 60000))
    local batteryVoltagePlaceholder = "__BATTERY_VOLTAGE_FIXED_2__"
    local payload = json.encode({
        SN = cfg.sn,
        timeStamp = timestamp,
        sendFrequency = sendFrequency,
        tcase = tcase,
        batteryVoltage = batteryVoltagePlaceholder,
        latitude = loc.lat,
        longitude = loc.lng,
    })
    local fixedPayload, replaced = payload:gsub(
        '("batteryVoltage"%s*:%s*)"' .. batteryVoltagePlaceholder .. '"',
        "%1" .. batteryVoltageText,
        1
    )
    if replaced == 0 then
        log.warn("payload", "battery format patch failed")
        return json.encode({
            SN = cfg.sn,
            timeStamp = timestamp,
            sendFrequency = sendFrequency,
            tcase = tcase,
            batteryVoltage = tonumber(batteryVoltageText) or -1,
            latitude = loc.lat,
            longitude = loc.lng,
        })
    end
    return fixedPayload
end

return M
