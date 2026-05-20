local config = require("config")

local M = {}
local ipReady = false
local lastIp = nil

-- Convert nil values to readable log text.
local function text(v)
    if v == nil then
        return "nil"
    end
    return tostring(v)
end

-- Safely call optional modem/SIM diagnostic APIs for logs.
local function call(lib, name)
    local fn = lib and lib[name]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b, c = pcall(fn)
    if ok then
        return text(a), text(b), text(c)
    end
    return "err:" .. text(a)
end

-- Return network-ready state using IP_READY fallback for older firmware.
local function ready()
    if ipReady then
        return true
    end
    if type(socket and socket.ready) ~= "function" then
        return false
    end
    local ok, r = pcall(socket.ready)
    if not ok then
        log.warn("net", "socket.ready err", r)
        return false
    end
    return r and true or false
end

-- Cache IP_READY events so later MQTT waits do not miss early network events.
local function markReady(reason, ip, adapter, extra)
    ipReady = true
    lastIp = ip or lastIp
    log.info("net", reason, "ip", text(lastIp), "adapter", text(adapter), "extra", text(extra))
end

-- Cache IP loss as well, so reconnect cycles wait again.
local function markLost(reason, ip, adapter, extra)
    ipReady = false
    lastIp = nil
    log.warn("net", reason, "ip", text(ip), "adapter", text(adapter), "extra", text(extra))
end

if sys and sys.subscribe then
    sys.subscribe("IP_READY", function(ip, adapter, extra)
        markReady("IP_READY subscribe", ip, adapter, extra)
    end)
    sys.subscribe("IP_LOSE", function(ip, adapter, extra)
        markLost("IP_LOSE subscribe", ip, adapter, extra)
    end)
end

-- Print current network and radio state for troubleshooting.
function M.dump(reason)
    log.info("net", reason or "state",
        "ready", ready() and 1 or 0,
        "ip", text(lastIp),
        "mobile", call(mobile, "status"),
        "csq", call(mobile, "csq"),
        "rsrp", call(mobile, "rsrp"),
        "rsrq", call(mobile, "rsrq"),
        "snr", call(mobile, "snr"),
        "sim", call(sim, "status"))
end

-- Wait for cellular IP before MQTT operations.
function M.waitReady(timeout)
    timeout = timeout or config.NET_TIMEOUT_MS
    log.info("net", "wait ready", timeout)
    M.dump("before wait")

    if ready() then
        log.info("net", "already ready")
        return true
    end

    local waited = 0
    while waited < timeout do
        local step = math.min(5000, timeout - waited)
        local ok, a, b, c = sys.waitUntil("IP_READY", step)
        if ok then
            log.info("net", "IP_READY event", text(a), text(b), text(c))
            markReady("IP_READY wait", a, b, c)
            M.dump("after ready")
            return true
        end
        waited = waited + step
    end

    M.dump("timeout")
    return false
end

return M
