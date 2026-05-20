local config = require("config")

local M = {}
local KEY = "cfg"
local SM4_KEY = "sm4"

-- Trim user input before saving or comparing it.
local function trim(v)
    v = tostring(v or "")
    return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Normalize form checkbox values into booleans.
local function bool(v)
    return v == true or v == "1" or v == "on" or v == "true"
end

-- Normalize config from old/new field names into one stable shape.
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
        mqtt_ssl = bool(ssl),
        report_interval_ms = tonumber(c.report_interval_ms or c.interval) or config.REPORT_INTERVAL_MS,
    }
end

-- Initialize persistent key-value storage.
function M.init()
    return fskv and fskv.init()
end

-- Load and normalize saved device configuration.
function M.get()
    local c = fskv and fskv.get(KEY)
    if type(c) ~= "table" then
        c = {}
    end
    return M.clean(c)
end

-- Save normalized device configuration.
function M.save(c)
    c = M.clean(c)
    return fskv and fskv.set(KEY, c), c
end

-- Save a bounded report interval from server commands.
function M.saveReportInterval(ms)
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

-- Check whether minimum MQTT config is present.
function M.ready(c)
    c = c or M.get()
    return #c.sn > 0 and #c.mqtt_host > 0 and c.mqtt_port > 0
end

-- Load cached SM4 key and IV.
function M.getSm4()
    local c = fskv and fskv.get(SM4_KEY)
    return type(c) == "table" and c or {}
end

-- Save SM4 key and IV received from the server.
function M.saveSm4(key, iv)
    return fskv and fskv.set(SM4_KEY, { key = trim(key), iv = trim(iv) })
end

return M
