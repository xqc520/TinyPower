local config = require("config")
local device = require("device")
local net = require("net")
local reportPayload = require("report_payload")
local storage = require("storage")

local M = {}

-- Return current epoch seconds, or zero if RTC is unavailable.
local function now()
    return os and os.time and os.time() or 0
end

-- Topic for plaintext realtime location/status uploads.
local function realTimeTopic(cfg)
    return "sys/" .. cfg.sn .. "/json/up/realTime"
end

-- Topic for device responses and active requests.
local function upRespTopic(cfg)
    return "sys/" .. cfg.sn .. "/json/up/resp"
end

-- Main downlink command topic for the configured SN.
local function downCmdTopic(cfg)
    return "sys/" .. cfg.sn .. "/json/down/cmd"
end

-- Alternate downlink response topic used only during diagnostics.
local function downRespTopic(sn)
    return "sys/" .. sn .. "/json/down/resp"
end

-- Build a command topic for an explicit SN or IMEI.
local function downCmdTopicBySn(sn)
    return "sys/" .. sn .. "/json/down/cmd"
end

-- Add a topic once while preserving subscription order.
local function addTopic(list, seen, topic)
    if topic and not seen[topic] then
        seen[topic] = true
        list[#list + 1] = topic
    end
end

-- Return command topics to subscribe; test mode widens the net.
local function downTopics(cfg)
    local list, seen = {}, {}
    addTopic(list, seen, downCmdTopic(cfg))
    if config.MQTT_TEST_MODE and config.MQTT_TEST_SUB_EXTRA then
        addTopic(list, seen, downRespTopic(cfg.sn))
        local imei = device.imei()
        if imei and imei ~= cfg.sn then
            addTopic(list, seen, downCmdTopicBySn(imei))
            addTopic(list, seen, downRespTopic(imei))
        end
    end
    return list
end

-- Wait for a specific MQTT callback event published by this module.
local function waitEvent(tag, want, timeout, expect)
    local waited = 0
    while waited < timeout do
        local step = math.min(5000, timeout - waited)
        local ok, ev, data = sys.waitUntil(tag, step)
        if ok then
            log.info("mqtt", "wait event", ev, tostring(data))
        end
        if ok and ev == want and (not expect or data == expect) then
            return true
        end
        if ok and ev == "disconnect" then
            return false
        end
        if not ok then
            waited = waited + step
        end
    end
    return false
end

-- Follow the protocol client ID rule for MQTT1.
local function clientId(cfg)
    return (device.imei() or cfg.sn) .. "mqtts1"
end

-- Decode JSON defensively and return a reason on failure.
local function decodeJson(payload)
    local ok, t = pcall(json.decode, payload or "")
    if ok and type(t) == "table" then
        return t
    end
    return nil, ok and "not_table" or tostring(t)
end

-- Return text length without failing on nil values.
local function valueLen(v)
    return v and #tostring(v) or 0
end

-- Publish a command response back to the server.
local function resp(c, cfg, cmd, requestId, result, reason)
    local topic = upRespTopic(cfg)
    local payload = json.encode({
        cmd = cmd,
        request_id = requestId,
        result = result,
        reason = reason,
        sn = cfg.sn,
        time = now()
    })
    log.info("mqtt", "up resp", payload)
    local mid = c:publish(topic, payload, 0, 0)
    log.info("mqtt", "resp", topic, cmd, tostring(result), tostring(mid))
end

-- Extract a report interval from supported server command shapes.
local function intervalMs(msg)
    return storage.reportIntervalMs(msg.config or msg)
end

local function configPayload(msg)
    return type(msg.config) == "table" and msg.config or msg
end

local function logSavedConfig(saved)
    log.info("mqtt", "config saved",
        "sn_len", saved.sn and #saved.sn or 0,
        "tcp_host", saved.tcp_host,
        "tcp_port", tostring(saved.tcp_port),
        "report_s", math.floor((saved.report_interval_ms or 0) / 1000)
    )
end

-- Handle one downlink JSON message from the server.
local function handleDown(c, cfg, payload, topic)
    log.info("mqtt", "down topic", tostring(topic), "len", valueLen(payload))
    local msg, err = decodeJson(payload)
    if not msg then
        log.warn("mqtt", "down bad json", tostring(err), tostring(payload):sub(1, 120))
        return
    end

    log.info("mqtt", "down cmd", tostring(msg.cmd), tostring(msg.request_id))
    if msg.cmd == "set_report_interval" or msg.cmd == "set_upload_frequency" then
        local ms = intervalMs(msg)
        if ms and storage.saveReportInterval(ms) then
            resp(c, cfg, msg.cmd, msg.request_id, 0, "ok")
            log.info("mqtt", "interval saved", ms)
            sys.publish("REPORT_INTERVAL_UPDATED")
        else
            log.warn("mqtt", "bad interval", tostring(ms))
            resp(c, cfg, msg.cmd, msg.request_id, -1, "bad_interval")
        end
    elseif msg.cmd == "set_config" or msg.cmd == "set_device_config" or msg.cmd == "set_tcp_config" or msg.cmd == "set_device_id" or msg.cmd == "set_tcp_server" then
        local ok, saved, reason = storage.saveRemoteConfig(configPayload(msg))
        if ok then
            resp(c, cfg, msg.cmd, msg.request_id, 0, reason or "ok")
            logSavedConfig(saved)
            sys.publish("CONFIG_UPDATED")
            sys.publish("REPORT_INTERVAL_UPDATED")
        else
            log.warn("mqtt", "bad config", tostring(reason))
            resp(c, cfg, msg.cmd, msg.request_id, -1, reason or "bad_config")
        end
    else
        log.warn("mqtt", "unknown cmd", tostring(msg.cmd))
    end
end

-- Connect, handle downlink, publish plaintext location, then disconnect.
function M.publishLocation(cfg, loc, batteryVoltage, tcase)
    if not net.waitReady(config.NET_TIMEOUT_MS) then
        log.warn("mqtt", "network timeout")
        return false
    end

    local c, tag
    local retryCount = tonumber(config.MQTT_CONNECT_RETRY_COUNT) or 1
    if retryCount < 1 then
        retryCount = 1
    end
    for attempt = 1, retryCount do
        log.info("mqtt", "connect", cfg.mqtt_host, cfg.mqtt_port, "tcp", "attempt", attempt, retryCount)
        c = mqtt.create(nil, cfg.mqtt_host, cfg.mqtt_port)
        if not c then
            log.warn("mqtt", "create failed")
        else
            local thisTag = "MQTT_" .. tostring(c)
            tag = thisTag
            c:auth(clientId(cfg), #cfg.mqtt_user > 0 and cfg.mqtt_user or nil, #cfg.mqtt_pass > 0 and cfg.mqtt_pass or nil, false)
            c:keepalive(30)
            c:autoreconn(false)
            c:on(function(client, event, data, payload)
                log.info("mqtt", "event", event, tostring(data))
                if event == "conack" then
                    sys.publish(thisTag, "ready")
                elseif event == "suback" then
                    sys.publish(thisTag, "suback", data)
                elseif event == "recv" then
                    handleDown(client, cfg, payload, data)
                elseif event == "sent" then
                    sys.publish(thisTag, "sent", data)
                elseif event == "disconnect" then
                    sys.publish(thisTag, "disconnect")
                end
            end)

            local connectOk = c:connect()
            log.info("mqtt", "connect start", connectOk and 1 or 0)
            if connectOk and waitEvent(tag, "ready", config.MQTT_TIMEOUT_MS) then
                log.info("mqtt", "connected")
                break
            end
            log.warn("mqtt", "connect failed", cfg.mqtt_host, cfg.mqtt_port, "attempt", attempt)
            c:close()
            c = nil
            tag = nil
        end
        if attempt < retryCount then
            sys.wait(config.MQTT_CONNECT_RETRY_DELAY_MS or 5000)
        end
    end
    if not c then
        return false
    end

    for _, topic in ipairs(downTopics(cfg)) do
        local subOk = c:subscribe(topic, 1)
        log.info("mqtt", "subscribe", topic, tostring(subOk))
        if not subOk then
            log.warn("mqtt", "subscribe failed", topic)
        elseif not waitEvent(tag, "suback", config.MQTT_TIMEOUT_MS) then
            log.warn("mqtt", "suback timeout", topic)
        end
    end

    local payload = reportPayload.location(cfg, loc, batteryVoltage, tcase)
    local topic = realTimeTopic(cfg)
    log.info("mqtt", "up realTime", payload)
    log.info("mqtt", "send start", topic, "plain", valueLen(payload))
    local mid = c:publish(topic, payload, config.MQTT_QOS, 0)
    if config.MQTT_QOS > 0 and not mid then
        log.warn("mqtt", "publish start failed")
        c:disconnect()
        c:close()
        return false
    end
    local ok = config.MQTT_QOS == 0 or waitEvent(tag, "sent", config.MQTT_TIMEOUT_MS, mid)
    if not ok then
        log.warn("mqtt", "publish ack timeout", tostring(mid))
    end
    log.info("mqtt", "send", ok and "ok" or "fail", "topic", topic, "mid", tostring(mid), "time", now())
    if ok then
        local downlinkWait = tonumber(config.POST_PUBLISH_DOWNLINK_WAIT_MS) or 0
        if downlinkWait > 0 then
            log.info("mqtt", "post publish downlink wait", downlinkWait, "ms")
            sys.wait(downlinkWait)
        end
    end
    c:disconnect()
    c:close()
    return ok
end

return M
