local config = require("config")
local net = require("net")
local reportPayload = require("report_payload")
local storage = require("storage")

local M = {}

-- 返回字符串长度，日志里只用于判断本次是否真的排队发送了数据。
local function valueLen(v)
    return v and #tostring(v) or 0
end

-- 不同 LuatOS 固件版本的 socket 事件可能是数字常量，也可能打印成文本。
-- 这里统一转成文本，便于日志排查现场连接过程。
local function eventText(event)
    return tostring(event)
end

-- 安全比较 socket 事件常量；固件缺少某个常量时直接返回 false。
local function isEvent(event, name)
    local v = socket and socket[name]
    return v ~= nil and event == v
end

-- TCP 连接成功事件在不同固件里命名不完全一致，集中兼容在这里。
local function isReadyEvent(event)
    local text = eventText(event)
    return isEvent(event, "LINK")
        or isEvent(event, "ON_LINE")
        or text == "LINK"
        or text == "ON_LINE"
        or text == "connect"
        or text == "connected"
end

-- 连接关闭或异常事件集中识别，避免发送流程一直等待。
local function isClosedEvent(event)
    local text = eventText(event)
    return isEvent(event, "CLOSED")
        or isEvent(event, "ERROR")
        or text == "CLOSED"
        or text == "closed"
        or text == "disconnect"
        or text == "error"
end

-- 关闭 socket 时同时 release，避免低功耗循环里句柄泄漏。
local function closeSocket(sc)
    if not sc or not socket then
        return
    end
    pcall(socket.close, sc)
    if socket.release then
        pcall(socket.release, sc)
    end
end

-- 等待 TCP 连接建立；socket.connect 立即返回 ready 时不会走到这里。
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

-- 部分固件没有 TX_OK 事件，超时后按已排队发送处理，避免无谓阻塞低功耗。
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

-- 服务器如果有回包，仅记录前 120 个字符用于排查，不参与业务判断。
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

-- 第二路 TCP 上报：
-- 1. tcp_host/tcp_port 未配置时直接跳过，不影响固定 MQTT 上报。
-- 2. 配置后连接服务器，发送与 MQTT realTime 完全相同的明文 JSON。
-- 3. 默认在 JSON 后追加换行，服务器可以按行读取。
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
            -- 未知但非关闭事件多半是连接进展事件，按 ready 处理以兼容不同固件。
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
