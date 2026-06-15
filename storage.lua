local config = require("config")

local M = {}
local KEY = "cfg"

-- Trim user input before saving or comparing it.
local function trim(v)
    v = tostring(v or "")
    return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function boundedReportInterval(ms)
    ms = tonumber(ms)
    if not ms then
        return nil
    end
    if ms < config.MIN_REPORT_INTERVAL_MS then
        return config.MIN_REPORT_INTERVAL_MS
    elseif ms > config.MAX_REPORT_INTERVAL_MS then
        return config.MAX_REPORT_INTERVAL_MS
    end
    return math.floor(ms)
end

local function findField(t, names)
    for _, name in ipairs(names) do
        if t[name] ~= nil then
            return true, t[name]
        end
    end
    return false, nil
end

local function validPort(v)
    local port = tonumber(v)
    if not port then
        return nil
    end
    port = math.floor(port)
    if port < 1 or port > 65535 then
        return nil
    end
    return port
end

local INTERVAL_FIELDS = {
    "report_interval_ms",
    "upload_interval_ms",
    "interval_sec",
    "report_interval_sec",
    "upload_interval_sec",
    "interval",
    "sendFrequency",
    "frequency",
    "freq",
}

local function cleanTcpHost(c)
    return trim(c.tcp_host or c.tcp_server or c.tcp_domain or c.tcp_ip)
end

local function cleanTcpPort(c)
    return validPort(c.tcp_port or c.tcp_server_port or c.config_port) or 0
end

local function fixedMqttHost(c)
    local host = trim(config.MQTT_HOST)
    if #host > 0 then
        return host
    end
    return trim(c.mqtt_host or c.host)
end

local function fixedMqttPort(c)
    return validPort(config.MQTT_PORT) or validPort(c.mqtt_port or c.port) or 1883
end

local function fixedMqttUser(c)
    local user = config.MQTT_USER
    if user ~= nil then
        return trim(user)
    end
    return trim(c.mqtt_user or c.user)
end

local function fixedMqttPass(c)
    local pass = config.MQTT_PASS
    if pass ~= nil then
        return trim(pass)
    end
    return trim(c.mqtt_pass or c.pass)
end

-- Normalize config from old/new field names into one stable shape.
function M.clean(c)
    c = c or {}
    local interval = boundedReportInterval(c.report_interval_ms or c.interval) or config.REPORT_INTERVAL_MS
    return {
        sn = trim(c.sn),
        mqtt_host = fixedMqttHost(c),
        mqtt_port = fixedMqttPort(c),
        mqtt_user = fixedMqttUser(c),
        mqtt_pass = fixedMqttPass(c),
        mqtt_ssl = false,
        report_interval_ms = interval,
        tcp_host = cleanTcpHost(c),
        tcp_port = cleanTcpPort(c),
    }
end

-- Extract a report interval from supported server command shapes.
function M.reportIntervalMs(c)
    c = c or {}
    if c.report_interval_ms or c.upload_interval_ms then
        return tonumber(c.report_interval_ms or c.upload_interval_ms)
    end
    local sec = tonumber(c.interval_sec or c.report_interval_sec or c.upload_interval_sec or c.interval)
    if sec then
        return sec * 1000
    end
    local min = tonumber(c.sendFrequency or c.frequency or c.freq)
    return min and min * 60 * 1000 or nil
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
    ms = boundedReportInterval(ms)
    if not ms then
        return false
    end
    local c = M.get()
    c.report_interval_ms = ms
    return M.save(c), c
end

-- Merge remote configuration fields into the saved device configuration.
function M.saveRemoteConfig(update)
    update = update or {}
    if type(update) ~= "table" then
        return false, M.get(), "bad_config"
    end

    local c = M.get()
    local changed = false

    local present, value = findField(update, { "sn", "SN", "device_id", "deviceId", "devId" })
    if present then
        local sn = trim(value)
        if #sn == 0 then
            return false, c, "bad_sn"
        end
        c.sn = sn
        changed = true
    end

    present, value = findField(update, { "tcp_host", "tcp_server", "tcp_domain", "tcp_ip", "config_host", "config_server", "host", "server", "domain", "ip" })
    if present then
        local host = trim(value)
        if #host == 0 then
            return false, c, "bad_tcp_host"
        end
        c.tcp_host = host
        changed = true
    end

    present, value = findField(update, { "tcp_port", "tcp_server_port", "config_port", "port" })
    if present then
        local port = validPort(value)
        if not port then
            return false, c, "bad_tcp_port"
        end
        c.tcp_port = port
        changed = true
    end

    present = findField(update, INTERVAL_FIELDS)
    if present then
        local ms = boundedReportInterval(M.reportIntervalMs(update))
        if not ms then
            return false, c, "bad_interval"
        end
        c.report_interval_ms = ms
        changed = true
    end

    if not changed then
        return false, c, "empty_config"
    end
    return M.save(c), c, "ok"
end

-- Check whether minimum MQTT config is present.
function M.ready(c)
    c = c or M.get()
    return #c.sn > 0 and #c.mqtt_host > 0 and c.mqtt_port > 0
end

-- Check whether the independent TCP server config is present.
function M.tcpReady(c)
    c = c or M.get()
    return #c.tcp_host > 0 and c.tcp_port > 0
end

return M
