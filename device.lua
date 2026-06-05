local storage = require("storage")
local config = require("config")

local M = {}

-- 机箱温度 NTC 阻值表，单位为欧姆；第一个值对应 -40℃，之后每个值递增 1℃。
-- 表格来自硬件/旧版状态采集逻辑，用于替代 B 值公式，避免不同 NTC 型号带来的偏差。
local TCASE_NTC_BOX_10K_TAB = {
    190556, 183413, 175674, 167647, 159565, 151598, 143862, 136436, 129364, 122668,
    116352, 110410, 104827, 99585, 94661, 90033, 85678, 81575, 77703, 74044,
    70581, 67299, 64183, 61223, 58408, 55728, 53177, 50746, 48429, 46222,
    44120, 42118, 40212, 38399, 36675, 35036, 33480, 32004, 30603, 29275,
    28017, 26826, 25697, 24629, 23618, 22660, 21752, 20892, 20075, 19299,
    18560, 18482, 18149, 17632, 16992, 16280, 15535, 14787, 14055, 13354,
    12690, 12068, 11490, 10954, 10458, 10000, 9576, 9184, 8819, 8478,
    8160, 7861, 7578, 7311, 7056, 6813, 6581, 6357, 6142, 5934,
    5734, 5540, 5353, 5172, 4998, 4829, 4665, 4507, 4355, 4208,
    4065, 3927, 3794, 3664, 3538, 3415, 3294, 3175, 3058, 2941,
    2825, 2776, 2718, 2652, 2582, 2508, 2432, 2356, 2280, 2206,
    2135, 2066, 2000, 1938, 1878, 1822, 1770, 1720, 1673, 1628,
    1586, 1546, 1508, 1471, 1435, 1401, 1367, 1334, 1301, 1268,
    1236, 1204, 1171, 1139, 1107, 1074, 1042, 1010, 979, 948,
    918, 889, 861, 835, 810, 787, 766, 748, 733, 721,
    713
}

-- Read a mobile module value without letting missing APIs break boot.
local function mobileValue(name)
    if mobile and mobile[name] then
        local ok, v = pcall(mobile[name])
        if ok and v and #tostring(v) > 0 then
            return tostring(v):gsub("%z", "")
        end
    end
end

-- Return configured SN first, then fallback hardware IDs for naming.
function M.id(cfg)
    cfg = cfg or storage.get()
    if cfg.sn and #cfg.sn > 0 then
        return cfg.sn
    end
    return mobileValue("imei") or mobileValue("muid") or "tinynav"
end

-- Return the modem IMEI when the firmware exposes it.
function M.imei()
    return mobileValue("imei")
end

local function round(value, decimals)
    local scale = 10 ^ (decimals or 0)
    return math.floor(value * scale + 0.5) / scale
end

-- 多次 ADC 采样后去掉最大值和最小值，再取平均，减少瞬时抖动影响。
local function averageTrimmedSamples(samples)
    if type(samples) ~= "table" or #samples == 0 then
        return nil
    end

    table.sort(samples)

    local startIndex = 1
    local endIndex = #samples
    if #samples > 2 then
        startIndex = 2
        endIndex = #samples - 1
    end

    local sum = 0
    local count = 0
    for i = startIndex, endIndex do
        local value = tonumber(samples[i])
        if value and value >= 0 then
            sum = sum + value
            count = count + 1
        end
    end

    if count == 0 then
        return nil
    end

    return math.floor((sum / count) + 0.5)
end

-- 根据 NTC 阻值表查温度；相邻两个阻值之间做线性插值，得到 0.1℃ 级别的结果。
local function lookupTemperatureFromNtcOhm(ntcOhm)
    local resistanceOhm = tonumber(ntcOhm) or 0
    if resistanceOhm <= 0 then
        return nil
    end

    local tableSize = #TCASE_NTC_BOX_10K_TAB
    if tableSize == 0 then
        return nil
    end

    local startC = tonumber(config.TCASE_TABLE_START_C) or -40
    if resistanceOhm >= TCASE_NTC_BOX_10K_TAB[1] then
        return startC
    end

    if resistanceOhm <= TCASE_NTC_BOX_10K_TAB[tableSize] then
        return startC + tableSize - 1
    end

    for i = 1, tableSize - 1 do
        local highRes = TCASE_NTC_BOX_10K_TAB[i]
        local lowRes = TCASE_NTC_BOX_10K_TAB[i + 1]
        if resistanceOhm <= highRes and resistanceOhm >= lowRes then
            local span = highRes - lowRes
            local baseTemp = startC + i - 1
            if span <= 0 then
                return baseTemp
            end
            return baseTemp + (highRes - resistanceOhm) / span
        end
    end

    return nil
end

-- 设置 ADC 量程；电池使用 MIN，机箱温度使用 MAX。
local function setAdcRange(rangeName, logPrefix)
    if adc.setRange then
        local range = rangeName == "MAX" and adc.ADC_RANGE_MAX or adc.ADC_RANGE_MIN
        if range then
            pcall(adc.setRange, range)
            log.info("device", logPrefix or "adc", "range", rangeName, tostring(range))
        end
    end
end

-- 读取指定 ADC 通道的毫伏值；只使用 adc.get，保持和旧版稳定采集逻辑一致。
local function readAdcMv(ch, sampleCount, logPrefix)
    local okOpen, openRet = pcall(adc.open, ch)
    if not okOpen or openRet == false or openRet == nil or openRet == 0 then
        log.warn("device", logPrefix or "adc", "open fail", "ch", ch, tostring(openRet))
        return nil
    end

    local samples = {}
    for i = 1, sampleCount do
        local okGet, getMv = pcall(adc.get, ch)
        if okGet then
            local sampleMv = tonumber(getMv)
            if sampleMv and sampleMv >= 0 then
                samples[#samples + 1] = sampleMv
            end
        end
    end

    if adc.close then
        pcall(adc.close, ch)
    end
    local mv = averageTrimmedSamples(samples)
    log.info("device", logPrefix or "adc", "ch", ch, "mv", tostring(mv), "samples", #samples)
    return mv
end

local function scanBatteryAdcChannels(sampleCount)
    if not config.BATTERY_ADC_SCAN_ON_ZERO then
        return
    end
    log.warn("device", "battery adc scan start")
    for ch = 0, 3 do
        readAdcMv(ch, sampleCount, "battery adc scan")
    end
    log.warn("device", "battery adc scan end")
end

-- 从电池分压电路读取电池电压，返回单位为 V。
function M.batteryVoltage()
    if not adc or not adc.open or not adc.get then
        log.warn("device", "adc api missing")
        return nil
    end

    local ch = config.BATTERY_ADC_ID or 0
    local rangeName = config.BATTERY_ADC_RANGE or "MIN"
    local top = tonumber(config.BATTERY_DIVIDER_TOP_KOHM) or 0
    local bottom = tonumber(config.BATTERY_DIVIDER_BOTTOM_KOHM) or 0
    if bottom <= 0 then
        log.warn("device", "bad battery divider")
        return nil
    end

    -- BAT_VAL_AD0 已经有外部分压，ADC 量程优先用 MIN，避免再启用内部分压。
    setAdcRange(rangeName, "battery adc")

    local sampleCount = tonumber(config.BATTERY_ADC_SAMPLE_COUNT) or 3
    if sampleCount < 1 then
        sampleCount = 1
    end

    local mv = readAdcMv(ch, sampleCount, "battery adc")
    if not mv or mv <= 0 then
        log.warn("device", "battery adc zero", "ch", ch)
        scanBatteryAdcChannels(1)
        return nil
    end

    local volts = (mv / 1000) * ((top + bottom) / bottom)
    volts = round(volts, 2)
    log.info("device", "battery", "adc_mv", mv, "voltage", volts)
    return volts
end

-- 从 ADC1 读取机箱温度，返回单位为 ℃。
-- 硬件为：+4V -- R16(100K) -- TEMP_AD1 -- NTC(10K) -- GND。
function M.tcaseTemperature()
    if not adc or not adc.open or not adc.get then
        log.warn("device", "adc api missing")
        return nil
    end

    local ch = config.TCASE_ADC_ID or 1
    local sampleCount = tonumber(config.TCASE_ADC_SAMPLE_COUNT) or 3
    if sampleCount < 1 then
        sampleCount = 1
    end

    setAdcRange(config.TCASE_ADC_RANGE or "MAX", "tcase adc")
    local mv = readAdcMv(ch, sampleCount, "tcase adc")
    if not mv or mv <= 0 then
        log.warn("device", "tcase adc zero", "ch", ch)
        return nil
    end

    local vrefMv = tonumber(config.TCASE_VREF_MV) or 4000
    local pullupOhm = tonumber(config.TCASE_PULLUP_OHM) or 100000
    if mv >= vrefMv or pullupOhm <= 0 then
        log.warn("device", "bad tcase ntc params", "mv", mv, "vref", vrefMv)
        return nil
    end

    -- R16 为上拉电阻，NTC 接地：Rntc = Rpullup * Vadc / (Vref - Vadc)。
    -- 本项目 TEMP_AD1 的参考电压按 4V 计算，所以 Vref 默认使用 4000mV。
    local ntcOhm = pullupOhm * mv / (vrefMv - mv)
    if ntcOhm <= 0 then
        log.warn("device", "bad tcase ntc resistance", ntcOhm)
        return nil
    end

    local tempC = lookupTemperatureFromNtcOhm(ntcOhm)
    if not tempC then
        log.warn("device", "tcase lookup fail", "ntc_ohm", round(ntcOhm, 0))
        return nil
    end

    tempC = round(tempC, 1)
    log.info("device", "tcase", "adc_mv", mv, "ntc_ohm", round(ntcOhm, 0), "temp_c", tempC)
    return tempC
end

-- Build the AP SSID from the last characters of the device ID.
function M.apSsid(cfg)
    local id = M.id(cfg)
    local tail = id:match("([%w_%-]+)$") or id
    if #tail > 6 then
        tail = tail:sub(-6)
    end
    return "TinyNav-" .. tail
end

return M
