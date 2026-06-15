local device = require("device")

local M = {}

-- 当前协议要求 timeStamp 使用 epoch 秒；RTC 不可用时返回 0，避免上报失败。
local function now()
    return os and os.time and os.time() or 0
end

-- JSON 数字本身不会保留末尾 0，这里专门生成两位小数文本给电池电压使用。
local function fixedDecimalText(value, decimals)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    return string.format("%." .. tostring(decimals or 0) .. "f", n)
end

-- 构建实时上报明文 JSON。
-- MQTT 固定后台连接和第二路 TCP 连接都调用这里，避免两路字段不一致。
function M.location(cfg, loc, batteryVoltage, tcase)
    -- 上层已提前读取电池/温度，失败或未传入时在这里兜底读取一次。
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
    local sendFrequency = math.max(1, math.floor(tonumber(cfg.sendFrequency) or 1))
    local batteryVoltagePlaceholder = "__BATTERY_VOLTAGE_FIXED_2__"
    -- 先用字符串占位，再替换成数字文本，保证 JSON 里 batteryVoltage 是数字而不是字符串。
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
        -- 极端情况下占位替换失败，退回普通 JSON 数字，优先保证上报不中断。
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
