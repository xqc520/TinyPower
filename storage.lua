local config = require("config")

local M = {}
local KEY = "cfg"

-- 去掉用户输入两端空白，避免 SN/域名保存后 topic 或连接地址异常。
local function trim(v)
    v = tostring(v or "")
    return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 上报周期统一在存储层限幅，WiFi 配置和 MQTT 下发走同一套规则。
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

-- 远程命令允许多个兼容字段名，这里按顺序取第一个存在的字段。
local function findField(t, names)
    for _, name in ipairs(names) do
        if t[name] ~= nil then
            return true, t[name]
        end
    end
    return false, nil
end

-- TCP/MQTT 端口都走同一个校验，避免 0 或超范围端口落盘。
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

-- 第二路 TCP 只保存 host/port，来源可以是 WiFi 热点或 MQTT 下发。
local function cleanTcpHost(c)
    return trim(c.tcp_host or c.tcp_server or c.tcp_domain or c.tcp_ip)
end

local function cleanTcpPort(c)
    return validPort(c.tcp_port or c.tcp_server_port or c.config_port) or 0
end

-- MQTT 是固件固定后台连接：优先使用 config.lua 写死的地址。
-- 兼容旧配置里的 mqtt_host，只是为了老设备升级后仍能启动。
local function fixedMqttHost(c)
    local host = trim(config.MQTT_HOST)
    if #host > 0 then
        return host
    end
    return trim(c.mqtt_host or c.host)
end

-- MQTT 默认普通 1883；不会从 WiFi 热点页面修改。
local function fixedMqttPort(c)
    return validPort(config.MQTT_PORT) or validPort(c.mqtt_port or c.port) or 1883
end

-- 用户名/密码同样来自固件常量；为空字符串表示无认证。
local function fixedMqttUser(c)
    local user = config.MQTT_USER
    if user ~= nil then
        return trim(user)
    end
    return trim(c.mqtt_user or c.user)
end

-- 保留旧配置兜底，便于旧版本升级；新版本不再通过 WiFi 修改 MQTT 密码。
local function fixedMqttPass(c)
    local pass = config.MQTT_PASS
    if pass ~= nil then
        return trim(pass)
    end
    return trim(c.mqtt_pass or c.pass)
end

-- 归一化后的配置结构是全项目唯一入口：
-- 固定 MQTT 参数来自 config.lua；SN/TCP/上报周期来自持久化配置。
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

-- 从服务器下发的多种字段格式里提取上报周期，返回毫秒。
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

-- 初始化 LuatOS 持久化 KV。
function M.init()
    return fskv and fskv.init()
end

-- 读取并归一化设备配置，调用方不直接使用原始 KV 表。
function M.get()
    local c = fskv and fskv.get(KEY)
    if type(c) ~= "table" then
        c = {}
    end
    return M.clean(c)
end

-- 保存前再次归一化，保证旧字段或表单字段不会原样污染配置。
function M.save(c)
    c = M.clean(c)
    return fskv and fskv.set(KEY, c), c
end

-- 保存服务器下发的上报周期。
function M.saveReportInterval(ms)
    ms = boundedReportInterval(ms)
    if not ms then
        return false
    end
    local c = M.get()
    c.report_interval_ms = ms
    return M.save(c), c
end

-- 合并服务器远程配置。
-- 只更新命令里明确出现的字段，未下发的 SN/TCP/周期保持原值。
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

-- 固定 MQTT 上报必须具备 SN 和固件内置 MQTT 地址。
function M.ready(c)
    c = c or M.get()
    return #c.sn > 0 and #c.mqtt_host > 0 and c.mqtt_port > 0
end

-- 第二路 TCP 是可选通道，配置完整才会尝试连接。
function M.tcpReady(c)
    c = c or M.get()
    return #c.tcp_host > 0 and c.tcp_port > 0
end

return M
