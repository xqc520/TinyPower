local config = require("config")

local M = {}

function M.waitReady(timeout)
    -- 蜂窝网络拿到 IP 后 LuatOS 会发布 IP_READY
    timeout = timeout or config.NET_TIMEOUT_MS
    if socket and socket.ready and socket.ready() then
        return true
    end
    local ok = sys.waitUntil("IP_READY", timeout)
    return ok or (socket and socket.ready and socket.ready()) or false
end

return M
