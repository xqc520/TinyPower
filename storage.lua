-- 持久化配置层：统一清洗和保存 SN、第二路 TCP、上报频度。
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

-- 协议字段 sendFrequency 使用分钟；内部定时需要时再换算成毫秒。
local function boundedSendFrequency(min)
    min = tonumber(min)
    if not min then
        return nil
    end
    local ms = boundedReportInterval(min * 60 * 1000)
    return ms and math.max(1, math.floor(ms / 60000)) or nil
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

-- 第二路 TCP 只使用唯一字段 tcp_host/tcp_port。
local function cleanTcpHost(c)
    return trim(c.tcp_host)
end

local function cleanTcpPort(c)
    return validPort(c.tcp_port) or 0
end

-- MQTT 是固件固定后台连接，只使用 config.lua 写死的地址。
local function fixedMqttHost()
    local host = trim(config.MQTT_HOST)
    return host
end

-- MQTT 默认普通 1883；不会从 WiFi 热点页面修改。
local function fixedMqttPort()
    return validPort(config.MQTT_PORT) or 1883
end

-- 用户名/密码同样来自固件常量；为空字符串表示无认证。
local function fixedMqttUser()
    return trim(config.MQTT_USER)
end

-- 新版本不再通过 WiFi 或远程命令修改 MQTT 密码。
local function fixedMqttPass()
    return trim(config.MQTT_PASS)
end

-- 归一化后的配置结构是全项目唯一入口：
-- 固定 MQTT 参数来自 config.lua；SN/TCP/上报周期来自持久化配置。
function M.clean(c)
    c = c or {}
    local sendFrequency = boundedSendFrequency(c.sendFrequency)
        or boundedSendFrequency((config.REPORT_INTERVAL_MS or 600000) / 60000)
        or 10
    return {
        sn = trim(c.sn),
        mqtt_host = fixedMqttHost(),
        mqtt_port = fixedMqttPort(),
        mqtt_user = fixedMqttUser(),
        mqtt_pass = fixedMqttPass(),
        mqtt_ssl = false,
        sendFrequency = sendFrequency,
        tcp_host = cleanTcpHost(c),
        tcp_port = cleanTcpPort(c),
    }
end

-- 将配置里的 sendFrequency 换算成毫秒，用于调度和低功耗定时。
function M.reportIntervalMs(c)
    c = c or {}
    local min = boundedSendFrequency(c.sendFrequency)
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
    c.sendFrequency = math.max(1, math.floor(ms / 60000))
    return M.save(c), c
end

-- 合并服务器远程配置。
-- 只识别唯一字段 sn/tcp_host/tcp_port/sendFrequency，未下发字段保持原值。
function M.saveRemoteConfig(update)
    if type(update) ~= "table" then
        return false, M.get(), "bad_config"
    end

    local c = M.get()
    local changed = false

    if update.sn ~= nil then
        local sn = trim(update.sn)
        if #sn == 0 then
            return false, c, "bad_sn"
        end
        c.sn = sn
        changed = true
    end

    if update.tcp_host ~= nil then
        local host = trim(update.tcp_host)
        if #host == 0 then
            return false, c, "bad_tcp_host"
        end
        c.tcp_host = host
        changed = true
    end

    if update.tcp_port ~= nil then
        local port = validPort(update.tcp_port)
        if not port then
            return false, c, "bad_tcp_port"
        end
        c.tcp_port = port
        changed = true
    end

    if update.sendFrequency ~= nil then
        local ms = boundedReportInterval(M.reportIntervalMs(update))
        if not ms then
            return false, c, "bad_interval"
        end
        c.sendFrequency = math.max(1, math.floor(ms / 60000))
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
