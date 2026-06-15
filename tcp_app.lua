local config = require("config")
local net = require("net")
local reportPayload = require("report_payload")
local storage = require("storage")

local M = {}

local function valueLen(v)
    return v and #tostring(v) or 0
end

local function eventText(event)
    return tostring(event)
end

local function isEvent(event, name)
    local v = socket and socket[name]
    return v ~= nil and event == v
end

local function isReadyEvent(event)
    local text = eventText(event)
    return isEvent(event, "LINK")
        or isEvent(event, "ON_LINE")
        or text == "LINK"
        or text == "ON_LINE"
        or text == "connect"
        or text == "connected"
end

local function isClosedEvent(event)
    local text = eventText(event)
    return isEvent(event, "CLOSED")
        or isEvent(event, "ERROR")
        or text == "CLOSED"
        or text == "closed"
        or text == "disconnect"
        or text == "error"
end

local function closeSocket(sc)
    if not sc or not socket then
        return
    end
    pcall(socket.close, sc)
    if socket.release then
        pcall(socket.release, sc)
    end
end

local function waitReady(tag, timeout)
    local waited = 0
    timeout = timeout or 0
    while waited < timeout do
        local step = math.min(1000, timeout - waited)
        local ok, ev = sys.waitUntil(tag, step)
        if ok and ev == "ready" then
            return true
        elseif ok and ev == "closed" then
            return false
        end
        if not ok then
            waited = waited + step
        end
    end
    return false
end

local function waitSent(tag, timeout)
    local waited = 0
    timeout = timeout or 0
    while waited < timeout do
        local step = math.min(500, timeout - waited)
        local ok, ev = sys.waitUntil(tag, step)
        if ok and ev == "sent" then
            return true
        elseif ok and ev == "closed" then
            return false
        end
        if not ok then
            waited = waited + step
        end
    end
    return true
end

local function drainRx(sc)
    if not (socket and socket.rx and zbuff and zbuff.create) then
        return
    end
    local rxBuff = zbuff.create(512)
    while true do
        rxBuff:seek(0)
        local succ, dataLen = socket.rx(sc, rxBuff)
        if not succ or not dataLen or dataLen <= 0 then
            break
        end
        local data = rxBuff:toStr(0, dataLen)
        rxBuff:del()
        log.info("tcp", "rx", dataLen, tostring(data):sub(1, 120))
    end
end

function M.publishLocation(cfg, loc, batteryVoltage, tcase)
    cfg = cfg or storage.get()
    if not storage.tcpReady(cfg) then
        log.info("tcp", "skip", "not configured")
        return true
    end
    if not (socket and socket.create and socket.connect and socket.tx) then
        log.warn("tcp", "socket api missing")
        return false
    end
    if not net.waitReady(config.NET_TIMEOUT_MS) then
        log.warn("tcp", "network timeout")
        return false
    end

    local tag = "TCP_" .. tostring(mcu and mcu.ticks and mcu.ticks() or os.time())
    local sc
    local function onEvent(sock, event)
        log.info("tcp", "event", eventText(event))
        if isEvent(event, "EVENT") then
            drainRx(sock)
        elseif isReadyEvent(event) then
            sys.publish(tag, "ready")
        elseif isEvent(event, "TX_OK") then
            sys.publish(tag, "sent")
        elseif isClosedEvent(event) then
            sys.publish(tag, "closed")
        else
            sys.publish(tag, "ready")
        end
    end

    sc = socket.create(nil, onEvent)
    if not sc then
        log.warn("tcp", "create failed")
        return false
    end

    local ok, ready = socket.connect(sc, cfg.tcp_host, cfg.tcp_port)
    log.info("tcp", "connect", cfg.tcp_host, cfg.tcp_port, tostring(ok), tostring(ready))
    if not ok then
        closeSocket(sc)
        return false
    end
    if not ready and not waitReady(tag, config.TCP_CONNECT_TIMEOUT_MS or 20000) then
        log.warn("tcp", "connect timeout", cfg.tcp_host, cfg.tcp_port)
        closeSocket(sc)
        return false
    end

    local payload = reportPayload.location(cfg, loc, batteryVoltage, tcase) .. (config.TCP_PAYLOAD_SUFFIX or "\n")
    log.info("tcp", "send start", "plain", valueLen(payload))
    local txOk, full, result = socket.tx(sc, payload)
    log.info("tcp", "send queued", tostring(txOk), tostring(full), tostring(result))
    if not txOk then
        closeSocket(sc)
        return false
    end
    waitSent(tag, config.TCP_TX_WAIT_MS or 3000)
    if config.TCP_CLOSE_DELAY_MS and config.TCP_CLOSE_DELAY_MS > 0 then
        sys.wait(config.TCP_CLOSE_DELAY_MS)
    end
    closeSocket(sc)
    return true
end

return M
