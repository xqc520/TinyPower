local config = require("config")
local device = require("device")
local net = require("net")
local sm4 = require("sm4_app")
local storage = require("storage")

local M = {}

-- Return current epoch seconds, or zero if RTC is unavailable.
local function now()
    return os and os.time and os.time() or 0
end

local function waitValidTime(timeout)
    timeout = timeout or 0
    if now() >= 1600000000 then
        return true
    end

    local waited = 0
    while waited < timeout do
        sys.wait(1000)
        waited = waited + 1000
        if now() >= 1600000000 then
            log.info("mqtt", "time ready", now())
            return true
        end
    end
    log.warn("mqtt", "time not ready", now())
    return false
end

-- Topic for encrypted realtime location/status uploads.
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

-- Build TLS options, preferring rootCA when present.
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

-- JSON 数字本身没有“保留末尾 0”的概念，这里专门生成固定小数位的数字文本用于上报。
local function fixedDecimalText(value, decimals)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    return string.format("%." .. tostring(decimals or 0) .. "f", n)
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
    local src = msg.config or msg
    if src.report_interval_ms then
        return tonumber(src.report_interval_ms)
    end
    local sec = tonumber(src.interval_sec or src.report_interval_sec or src.upload_interval_sec or src.interval)
    if sec then
        return sec * 1000
    end
    local min = tonumber(src.sendFrequency or src.frequency or src.freq)
    return min and min * 60 * 1000 or nil
end

-- Handle one downlink JSON message from the server.
local function handleDown(c, cfg, tag, payload, topic)
    log.info("mqtt", "down topic", tostring(topic), "len", valueLen(payload))
    local msg, err = decodeJson(payload)
    if not msg then
        log.warn("mqtt", "down bad json", tostring(err), tostring(payload):sub(1, 120))
        return
    end

    log.info("mqtt", "down cmd", tostring(msg.cmd), tostring(msg.request_id))
    if msg.cmd == "set_sm4" then
        log.info("mqtt", "set_sm4 len", valueLen(msg.key), valueLen(msg.iv))
        if sm4.ready({ key = msg.key, iv = msg.iv }) then
            storage.saveSm4(msg.key, msg.iv)
            resp(c, cfg, "set_sm4", msg.request_id, 0, "ok")
            log.info("mqtt", "sm4 saved")
            sys.publish(tag, "sm4")
        else
            log.warn("mqtt", "bad sm4", valueLen(msg.key), valueLen(msg.iv))
            resp(c, cfg, "set_sm4", msg.request_id, -1, "bad_sm4")
        end
    elseif msg.cmd == "set_report_interval" or msg.cmd == "set_upload_frequency" or msg.cmd == "set_config" then
        local ms = intervalMs(msg)
        if ms and storage.saveReportInterval(ms) then
            resp(c, cfg, msg.cmd, msg.request_id, 0, "ok")
            log.info("mqtt", "interval saved", ms)
            sys.publish("REPORT_INTERVAL_UPDATED")
        else
            log.warn("mqtt", "bad interval", tostring(ms))
            resp(c, cfg, msg.cmd, msg.request_id, -1, "bad_interval")
        end
    else
        log.warn("mqtt", "unknown cmd", tostring(msg.cmd))
    end
end

-- Ask MQTT1 to send or refresh SM4 key/IV.
local function requestSm4(c, cfg)
    local t = now()
    local topic = upRespTopic(cfg)
    local requestId = "sm4req-1-" .. tostring(t)
    local payload = json.encode({
        cmd = "request_sm4",
        request_id = requestId,
        sn = cfg.sn,
        has_local = sm4.ready(storage.getSm4()) and true or false,
        time = t,
    })
    log.info("mqtt", "up request", payload)
    local mid = c:publish(topic, payload, 0, 0)
    log.info("mqtt", "sm4 request", topic, requestId, "sn", cfg.sn, "len", valueLen(payload), tostring(mid))
    return mid ~= false
end

-- Build the plaintext realtime JSON before SM4 encryption.
local function locationPayload(cfg, loc, batteryVoltage, tcase)
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
        log.warn("mqtt", "battery format patch failed")
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

-- Connect, handle downlink, encrypt location, publish, then disconnect.
function M.publishLocation(cfg, loc, batteryVoltage, tcase)
    if not net.waitReady(config.NET_TIMEOUT_MS) then
        log.warn("mqtt", "network timeout")
        return false
    end

    if cfg.mqtt_ssl then
        waitValidTime(config.MQTT_TLS_TIME_WAIT_MS)
    end

    local c, tag
    local retryCount = tonumber(config.MQTT_CONNECT_RETRY_COUNT) or 1
    if retryCount < 1 then
        retryCount = 1
    end
    for attempt = 1, retryCount do
        log.info("mqtt", "connect", cfg.mqtt_host, cfg.mqtt_port, cfg.mqtt_ssl and "ssl" or "tcp", "attempt", attempt, retryCount)
        c = mqtt.create(nil, cfg.mqtt_host, cfg.mqtt_port, tlsConfig(cfg))
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
                    handleDown(client, cfg, thisTag, payload, data)
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

    local localSm4Ready = sm4.ready(storage.getSm4())
    if config.MQTT_TEST_FORCE_SM4 or not localSm4Ready then
        log.info("mqtt", "sm4 request needed", "force", config.MQTT_TEST_FORCE_SM4 and 1 or 0, "local", localSm4Ready and 1 or 0)
        if not requestSm4(c, cfg) then
            log.warn("mqtt", "request sm4 send failed")
        end
        if not waitEvent(tag, "sm4", config.SM4_TIMEOUT_MS) then
            log.warn("mqtt", "sm4 wait timeout", config.SM4_TIMEOUT_MS, "down", downCmdTopic(cfg), "up", upRespTopic(cfg), "keep local", localSm4Ready and 1 or 0)
        end
    end

    local plain = locationPayload(cfg, loc, batteryVoltage, tcase)
    log.info("mqtt", "up realTime", plain)
    local payload = sm4.encryptHex(plain, storage.getSm4())
    if not payload then
        local sm4cfg = storage.getSm4()
        log.warn("mqtt", "no sm4", valueLen(sm4cfg.key), valueLen(sm4cfg.iv))
        c:disconnect()
        c:close()
        return false
    end

    local topic = realTimeTopic(cfg)
    log.info("mqtt", "send start", topic, "hex", valueLen(payload))
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
