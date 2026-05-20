local config = require("config")

local M = {}
local KEY = "cfg"
local SM4_KEY = "sm4"

-- 简单清洗网页输入，避免空格和 nil 影响判断
local function trim(v)
    v = tostring(v or "")
    return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function bool(v)
    return v == true or v == "1" or v == "on" or v == "true"
end

-- 统一配置格式；网页保存和读取都走这里
function M.clean(c)
    c = c or {}
    local ssl = c.mqtt_ssl
    if ssl == nil then
        ssl = c.ssl
    end
    if ssl == nil then
        ssl = true
    end
    return {
        sn = trim(c.sn),
        mqtt_host = trim(c.mqtt_host or c.host),
        mqtt_port = tonumber(c.mqtt_port or c.port) or 8883,
        mqtt_user = trim(c.mqtt_user or c.user),
        mqtt_pass = trim(c.mqtt_pass or c.pass),
        mqtt_topic = trim(c.mqtt_topic or c.topic),
        mqtt_ssl = bool(ssl),
        report_interval_ms = tonumber(c.report_interval_ms or c.interval) or config.REPORT_INTERVAL_MS,
    }
end

function M.init()
    -- fskv 是 LuatOS 掉电不丢的轻量 KV
    return fskv and fskv.init()
end

function M.get()
    local c = fskv and fskv.get(KEY)
    if type(c) ~= "table" then
        c = {}
    end
    return M.clean(c)
end

function M.save(c)
    c = M.clean(c)
    return fskv and fskv.set(KEY, c), c
end

function M.saveReportInterval(ms)
    -- 服务器下发上传频率时，只改上报间隔，不动 MQTT/SN 等配置
    ms = tonumber(ms)
    if not ms then
        return false
    end
    if ms < config.MIN_REPORT_INTERVAL_MS then
        ms = config.MIN_REPORT_INTERVAL_MS
    elseif ms > config.MAX_REPORT_INTERVAL_MS then
        ms = config.MAX_REPORT_INTERVAL_MS
    end
    local c = M.get()
    c.report_interval_ms = ms
    return M.save(c), c
end

function M.ready(c)
    -- 最小可工作配置：SN + MQTT 地址 + 端口
    c = c or M.get()
    return #c.sn > 0 and #c.mqtt_host > 0 and c.mqtt_port > 0
end

function M.getSm4()
    local c = fskv and fskv.get(SM4_KEY)
    return type(c) == "table" and c or {}
end

function M.saveSm4(key, iv)
    -- 保存服务器下发的 SM4 参数，断电不丢
    return fskv and fskv.set(SM4_KEY, { key = trim(key), iv = trim(iv) })
end

return M
