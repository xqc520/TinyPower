local config = require("config")
local device = require("device")
local net = require("net")
local sm4 = require("sm4_app")
local storage = require("storage")

local M = {}

-- 本项目只接入一个 MQTT 服务器，对应服务器文档里的 MQTT1
local function now()
    return os and os.time and os.time() or 0
end

local function realTimeTopic(cfg)
    -- 默认按服务器协议上报，手动配置 topic 时仍支持 {SN}/{sn}
    if cfg.mqtt_topic and #cfg.mqtt_topic > 0 then
        return (cfg.mqtt_topic:gsub("{SN}", cfg.sn):gsub("{sn}", cfg.sn))
    end
    return "sys/" .. cfg.sn .. "/json/up/realTime"
end

local function upRespTopic(cfg)
    return "sys/" .. cfg.sn .. "/json/up/resp"
end

local function downCmdTopic(cfg)
    return "sys/" .. cfg.sn .. "/json/down/cmd"
end

local function waitEvent(tag, want, timeout, expect)
    -- MQTT 是异步回调，这里用 sys 消息等连接/发送结果
    local waited = 0
    while waited < timeout do
        local step = math.min(5000, timeout - waited)
        local ok, ev, data = sys.waitUntil(tag, step)
        if ok and ev == want and (not expect or data == expect) then
            return true
        end
        if ok and ev == "disconnect" then
            return false
        end
        waited = waited + step
    end
    return false
end

local function tlsConfig(cfg)
    if not cfg.mqtt_ssl then
        return nil
    end
    local ca
    if io and io.readFile then
        local ok, data = pcall(io.readFile, config.CA_FILE)
        ca = ok and data or nil
    end
    if ca and #ca > 0 then
        return { server_cert = ca, verify = 2 }
    end
    log.warn("mqtt", "rootCA missing, use simple TLS")
    return true
end

local function clientId(cfg)
    return (device.imei() or cfg.sn) .. "mqtts1"
end

local function decodeJson(payload)
    local ok, t = pcall(json.decode, payload or "")
    return ok and type(t) == "table" and t or nil
end

local function resp(c, cfg, cmd, requestId, result, reason)
    c:publish(upRespTopic(cfg), json.encode({
        cmd = cmd,
        request_id = requestId,
        result = result,
        reason = reason,
        sn = cfg.sn,
        time = now(),
    }), 0, 0)
end

local function intervalMs(msg)
    -- 推荐：set_report_interval + interval/interval_sec，单位秒
    local src = msg.config or msg
    if src.report_interval_ms then
        return tonumber(src.report_interval_ms)
    end
    local sec = tonumber(src.interval_sec or src.report_interval_sec or src.upload_interval_sec or src.interval)
    if sec then
        return sec * 1000
    end
    -- 兼容状态报文里的 sendFrequency，单位分钟
    local min = tonumber(src.sendFrequency or src.frequency or src.freq)
    return min and min * 60 * 1000 or nil
end

local function handleDown(c, cfg, tag, payload)
    local msg = decodeJson(payload)
    if not msg then
        return
    end

    if msg.cmd == "set_sm4" then
        if sm4.ready({ key = msg.key, iv = msg.iv }) then
            storage.saveSm4(msg.key, msg.iv)
            resp(c, cfg, "set_sm4", msg.request_id, 0, "ok")
            sys.publish(tag, "sm4")
        else
            resp(c, cfg, "set_sm4", msg.request_id, -1, "bad_sm4")
        end
    elseif msg.cmd == "set_report_interval" or msg.cmd == "set_upload_frequency" or msg.cmd == "set_config" then
        local ms = intervalMs(msg)
        if ms and storage.saveReportInterval(ms) then
            resp(c, cfg, msg.cmd, msg.request_id, 0, "ok")
            sys.publish("REPORT_INTERVAL_UPDATED")
        else
            resp(c, cfg, msg.cmd, msg.request_id, -1, "bad_interval")
        end
    end
end

local function requestSm4(c, cfg)
    local t = now()
    c:publish(upRespTopic(cfg), json.encode({
        cmd = "request_sm4",
        request_id = "sm4req-1-" .. tostring(t),
        sn = cfg.sn,
        has_local = sm4.ready(storage.getSm4()) and true or false,
        time = t,
    }), 0, 0)
end

local function locationPayload(cfg, loc)
    -- 明文先按状态报文风格组织，再统一 SM4 加密
    return json.encode({
        SN = cfg.sn,
        timeStamp = tostring(now()),
        sendFrequency = math.max(1, math.floor(cfg.report_interval_ms / 60000)),
        latitude = loc.lat,
        longitude = loc.lng,
        speed = loc.speed,
        course = loc.course,
        sats = loc.sats,
        hdop = loc.hdop,
        altitude = loc.altitude,
    })
end

function M.publishLocation(cfg, loc)
    -- 只建立一条 MQTT1 短连接，发完就断开，适合低功耗
    if not net.waitReady(config.NET_TIMEOUT_MS) then
        log.warn("mqtt", "network timeout")
        return false
    end

    local c = mqtt.create(nil, cfg.mqtt_host, cfg.mqtt_port, tlsConfig(cfg))
    if not c then
        return false
    end

    local tag = "MQTT_" .. tostring(c)
    c:auth(clientId(cfg), #cfg.mqtt_user > 0 and cfg.mqtt_user or nil, #cfg.mqtt_pass > 0 and cfg.mqtt_pass or nil, false)
    c:keepalive(30)
    c:autoreconn(false)
    c:on(function(client, event, data, payload)
        -- 只关心四类事件：连上、下发、发完、断开
        if event == "conack" then
            sys.publish(tag, "ready")
        elseif event == "recv" then
            handleDown(client, cfg, tag, payload)
        elseif event == "sent" then
            sys.publish(tag, "sent", data)
        elseif event == "disconnect" then
            sys.publish(tag, "disconnect")
        end
    end)

    if not c:connect() or not waitEvent(tag, "ready", config.MQTT_TIMEOUT_MS) then
        c:close()
        return false
    end
    c:subscribe(downCmdTopic(cfg), 1)

    if not sm4.ready(storage.getSm4()) then
        requestSm4(c, cfg)
        waitEvent(tag, "sm4", config.SM4_TIMEOUT_MS)
    end

    local payload = sm4.encryptHex(locationPayload(cfg, loc), storage.getSm4())
    if not payload then
        log.warn("mqtt", "no sm4")
        c:disconnect()
        c:close()
        return false
    end

    local mid = c:publish(realTimeTopic(cfg), payload, config.MQTT_QOS, 0)
    if config.MQTT_QOS > 0 and not mid then
        c:disconnect()
        c:close()
        return false
    end
    local ok = config.MQTT_QOS == 0 or waitEvent(tag, "sent", config.MQTT_TIMEOUT_MS, mid)
    c:disconnect()
    c:close()
    return ok
end

return M
