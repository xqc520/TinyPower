-- 蜂窝网络辅助模块：缓存 IP_READY/IP_LOSE，并提供统一等待入口。
local config = require("config")

local M = {}
local ipReady = false
local lastIp = nil

-- 把 nil 转成可读文本，避免网络诊断日志出现空洞。
local function text(v)
    if v == nil then
        return "nil"
    end
    return tostring(v)
end

-- 安全调用可选的 modem/SIM 诊断 API；不同固件可能缺少部分函数。
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

-- 判断蜂窝网络是否可用。优先使用缓存，兼容较早固件没有 socket.ready 的情况。
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

-- 缓存 IP_READY，避免网络先就绪、业务后等待时错过事件。
local function markReady(reason, ip, adapter, extra)
    ipReady = true
    lastIp = ip or lastIp
    log.info("net", reason, "ip", text(lastIp), "adapter", text(adapter), "extra", text(extra))
end

-- 缓存 IP_LOSE，后续重连周期会重新等待网络。
local function markLost(reason, ip, adapter, extra)
    ipReady = false
    lastIp = nil
    log.warn("net", reason, "ip", text(ip), "adapter", text(adapter), "extra", text(extra))
end

if sys and sys.subscribe then
    -- 全局订阅网络事件，让任意模块调用 waitReady 前都能读到最新状态。
    sys.subscribe("IP_READY", function(ip, adapter, extra)
        markReady("IP_READY subscribe", ip, adapter, extra)
    end)
    sys.subscribe("IP_LOSE", function(ip, adapter, extra)
        markLost("IP_LOSE subscribe", ip, adapter, extra)
    end)
end

-- 打印蜂窝网络、信号和 SIM 状态，现场排查网络问题时优先看这里。
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

-- 等待蜂窝网络拿到 IP。MQTT 和第二路 TCP 发送前都会走这里。
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
