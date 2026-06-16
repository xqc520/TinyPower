-- WiFi 配网门户：只开放 SN 和第二路 TCP 参数，固定 MQTT 不在页面配置。
local config = require("config")
local device = require("device")
local storage = require("storage")

-- 尝试加载可选固件模块，缺失时不影响主流程启动。
local function optionalRequire(name)
    local ok, mod = pcall(require, name)
    if not ok then
        return nil, mod
    end
    if mod == true then
        return _G and _G[name]
    end
    return mod
end

optionalRequire("sysplus")
optionalRequire("httpplus")

local dhcpsrvLib, dhcpsrvLoadErr = optionalRequire("dhcpsrv")
local dnsproxyLib, dnsproxyLoadErr = optionalRequire("dnsproxy")
local udpsrvLib, udpsrvLoadErr = optionalRequire("udpsrv")

local M = { running = false }
local apDhcp
local captiveDns
local restartScheduled = false

local PROBE_URIS = {
    ["/generate_204"] = true,
    ["/gen_204"] = true,
    ["/hotspot-detect.html"] = true,
    ["/library/test/success.html"] = true,
    ["/connecttest.txt"] = true,
    ["/ncsi.txt"] = true,
    ["/success.txt"] = true,
    ["/redirect"] = true,
    ["/canonical.html"] = true,
    ["/fwlink/"] = true
}

-- 解码配置页提交的 URL 表单文本。
local function urlDecode(s)
    s = (s or ""):gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- 将 application/x-www-form-urlencoded 请求体解析成 Lua 表。
local function readForm(body)
    local t = {}
    for pair in tostring(body or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        t[urlDecode(k)] = urlDecode(v)
    end
    return t
end

-- 写入 HTML 前转义用户输入，避免特殊字符破坏页面结构。
local function html(s)
    return tostring(s or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
end

-- 本地热点配置页 URL。
local function apUrl()
    return "http://" .. config.AP_IP .. "/"
end

-- 渲染本地热点配置页：只开放 SN 和第二路 TCP 参数，固定 MQTT 不在这里配置。
local function page(msg)
    local c = storage.get()
    local tcpPort = (c.tcp_port and c.tcp_port > 0) and c.tcp_port or ""
    return [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>TinyNav &#37197;&#32593;</title>
<style>body{font-family:Arial,sans-serif;margin:0;background:#f7f8fa;color:#222}
main{max-width:420px;margin:auto;padding:22px}label{display:block;margin:12px 0 6px}
input{box-sizing:border-box;width:100%;height:42px;padding:0 10px;border:1px solid #ccc;border-radius:6px;font-size:16px}
.row{display:flex;gap:10px}.row div{flex:1}
button{width:100%;height:44px;border:0;border-radius:6px;background:#1463ff;color:#fff;font-size:17px}p{color:#19723b}</style>
</head><body><main><h2>TinyNav &#37197;&#32593;</h2><p>]] .. html(msg) .. [[</p>
<form method="post" action="/save">
<label>&#35774;&#22791;SN</label><input name="sn" required value="]] .. html(c.sn) .. [[">
<label>TCP IP/&#22495;&#21517;</label><input name="tcp_host" value="]] .. html(c.tcp_host) .. [[">
<div class="row"><div><label>TCP&#31471;&#21475;</label><input name="tcp_port" inputmode="numeric" value="]] .. html(tcpPort) .. [["></div></div>
<button type="submit">&#20445;&#23384;</button></form></main></body></html>]]
end

-- 浏览器收到保存成功页后，设备再重启应用新配置。
local function savedPage()
    return [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>TinyNav &#37197;&#32593;</title>
<style>body{font-family:Arial,sans-serif;margin:0;background:#f7f8fa;color:#222}
main{max-width:420px;margin:auto;padding:28px 22px;text-align:center}
h2{margin-top:18px}.ok{font-size:44px;color:#19723b;margin:22px 0 8px}p{line-height:1.6;color:#444}</style>
</head><body><main><div class="ok">&#10003;</div><h2>&#20445;&#23384;&#25104;&#21151;</h2>
<p>&#35774;&#22791;&#27491;&#22312;&#37325;&#21551;&#65292;&#35831;&#31245;&#31561;&#21518;&#37325;&#26032;&#36830;&#25509;&#12290;</p>
</main></body></html>]]
end

-- 延迟重启，避免手机还没收到 HTTP 响应设备就重启。
local function scheduleRestart()
    if restartScheduled then
        return
    end
    restartScheduled = true
    sys.timerStart(function()
        if log and log.info then
            log.info("setup", "config saved, reboot")
        end
        if rtos and rtos.reboot then
            rtos.reboot()
        else
            M.stop()
            sys.publish("CONFIG_UPDATED")
        end
    end, config.CONFIG_REBOOT_DELAY_MS or 1500)
end

-- 保存热点提交的 SN 和第二路 TCP 参数。
-- 先读取旧配置再覆盖，避免 WiFi 重配时把 MQTT 下发的上报频度清掉。
local function save(body)
    local form = readForm(body)
    local c = storage.get()
    c.sn = form.sn
    c.tcp_host = form.tcp_host
    c.tcp_port = form.tcp_port
    local ok = storage.save(c)
    if ok then
        local saved = storage.get()
        logInfo("setup", "config saved",
            "sn_len", saved.sn and #saved.sn or 0,
            "tcp_host_len", saved.tcp_host and #saved.tcp_host or 0,
            "tcp_port", tostring(saved.tcp_port)
        )
        scheduleRestart()
        return savedPage()
    end
    return page("Save failed")
end

-- 统一 HTTP 响应三元组。
local function reply(code, headers, body)
    return code, headers or {}, body or ""
end

-- 将系统联网探测请求重定向到配置页，便于手机自动弹出门户。
local function captiveRedirect()
    return reply(302, {
        Location = apUrl(),
        ["Cache-Control"] = "no-store, no-cache, must-revalidate",
        Pragma = "no-cache",
        ["Content-Type"] = "text/html; charset=utf-8"
    }, '<html><head><meta http-equiv="refresh" content="0;url=' .. apUrl() .. '"></head><body>Redirecting...</body></html>')
end

-- HTTP 路由：配置页、保存接口和强制门户探测。
local function handler(client, method, uri, headers, body)
    uri = (uri or "/"):match("^[^?]*")
    if method == "GET" and PROBE_URIS[uri] then
        return captiveRedirect()
    end
    if method == "POST" and uri == "/save" then
        return reply(200, { ["Content-Type"] = "text/html; charset=utf-8" }, save(body))
    end
    if uri ~= "/" then
        return reply(302, { Location = "http://" .. config.AP_IP .. "/" })
    end
    return reply(200, { ["Content-Type"] = "text/html; charset=utf-8" }, page(""))
end

-- 获取 LuatOS AP 网卡适配器 ID。
local function apAdapter()
    return socket and socket.LWIP_AP
end

-- log.warn 安全包装，兼容日志模块未就绪的情况。
local function logWarn(...)
    if log and log.warn then
        log.warn(...)
    end
end

-- log.info 安全包装。
local function logInfo(...)
    if log and log.info then
        log.info(...)
    end
end

-- log.error 安全包装。
local function logError(...)
    if log and log.error then
        log.error(...)
    end
end

-- 将点分 IPv4 文本拆成数字数组。
local function ipParts(ip)
    local a, b, c, d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return { 192, 168, 4, 1 }
    end
    return { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
end

-- 将 IPv4 数字数组编码成 4 字节网络序。
local function ipBytes(ip)
    return string.char(ip[1], ip[2], ip[3], ip[4])
end

-- 按网络序编码 16 位整数。
local function toU16(n)
    return string.char((n >> 8) & 0xFF, n & 0xFF)
end

-- 按网络序编码 32 位整数。
local function toU32(n)
    return string.char(
        (n >> 24) & 0xFF,
        (n >> 16) & 0xFF,
        (n >> 8) & 0xFF,
        n & 0xFF
    )
end

-- 从原始字节串读取网络序 16 位整数。
local function readU16(s, pos)
    local a, b = s:byte(pos, pos + 1)
    if not a or not b then
        return nil
    end
    return a * 256 + b
end

-- 将 LuatOS 远端 IP 字节格式转为点分 IPv4 文本。
local function remoteIpToString(remoteIp)
    if remoteIp and #remoteIp == 5 then
        return string.format("%d.%d.%d.%d", remoteIp:byte(2), remoteIp:byte(3), remoteIp:byte(4), remoteIp:byte(5))
    end
    return nil
end

-- 构造 DNS 应答，把强制门户探测域名指向本机 AP IP。
local function buildDnsResponse(query)
    if not query or #query < 17 then
        return nil
    end

    local qdcount = readU16(query, 5)
    if not qdcount or qdcount < 1 then
        return nil
    end

    local pos = 13
    while pos <= #query do
        local labelLen = query:byte(pos)
        if not labelLen then
            return nil
        end
        pos = pos + 1
        if labelLen == 0 then
            break
        end
        pos = pos + labelLen
    end

    if pos + 3 > #query then
        return nil
    end

    local qtype = readU16(query, pos)
    local question = query:sub(13, pos + 3)
    local answer = ""
    local answerCount = 0

    if qtype == 1 or qtype == 255 then
        answerCount = 1
        answer =
            "\192\012" ..
            "\000\001" ..
            "\000\001" ..
            toU32(30) ..
            "\000\004" ..
            ipBytes(ipParts(config.AP_IP))
    end

    return query:sub(1, 2) ..
        "\129\128" ..
        query:sub(5, 6) ..
        toU16(answerCount) ..
        "\000\000" ..
        "\000\000" ..
        question ..
        answer
end

-- 启动 raw-socket DNS，用于手机强制门户自动弹出。
local function startCaptiveDns(adapter)
    if captiveDns then
        return true
    end
    if not (socket and socket.create and socket.config and socket.rx and socket.tx) then
        logWarn("setup", "socket dns unavailable")
        return false
    end

    local rxBuff = zbuff.create(1500)
    -- 接收 DNS 请求并回复 AP 地址。
    local function onDnsRequest(sc, event)
        if event ~= socket.EVENT then
            return
        end
        while true do
            rxBuff:seek(0)
            local succ, dataLen, remoteIp, remotePort = socket.rx(sc, rxBuff)
            if not succ or not dataLen or dataLen <= 0 then
                break
            end

            local query = rxBuff:toStr(0, dataLen)
            rxBuff:del()
            local response = buildDnsResponse(query)
            local clientIp = remoteIpToString(remoteIp)
            if response and clientIp and remotePort then
                socket.tx(sc, response, clientIp, remotePort)
            end
        end
    end

    captiveDns = socket.create(adapter, onDnsRequest)
    if not captiveDns then
        logWarn("setup", "captive dns create failed")
        return false
    end
    if not socket.config(captiveDns, 53, true) then
        logWarn("setup", "captive dns config failed")
        socket.close(captiveDns)
        captiveDns = nil
        return false
    end
    socket.connect(captiveDns, "255.255.255.255", 0)
    logInfo("setup", "captive dns started", config.AP_IP)
    return true
end

-- 关闭强制门户 DNS socket。
local function stopCaptiveDns()
    if not captiveDns then
        return
    end
    socket.close(captiveDns)
    if socket.release then
        socket.release(captiveDns)
    end
    captiveDns = nil
end

-- 将 zbuff 中的 DHCP 报文解析成 Lua 表。
local function dhcpDecode(buff)
    local pkg = {}
    pkg.op = buff[0]
    pkg.htype = buff[1]
    pkg.hlen = buff[2]
    pkg.hops = buff[3]

    buff:seek(4)
    pkg.xid = buff:read(4)
    _, pkg.secs = buff:unpack(">H")
    _, pkg.flags = buff:unpack(">H")
    pkg.ciaddr = buff:read(4)
    pkg.yiaddr = buff:read(4)
    pkg.siaddr = buff:read(4)
    pkg.giaddr = buff:read(4)
    pkg.chaddr = buff:read(16)
    buff:seek(192, zbuff.SEEK_CUR)
    _, pkg.magic = buff:unpack(">I")

    pkg.opts = {}
    while buff:len() > buff:used() do
        local tagRaw = buff:read(1)
        if not tagRaw or #tagRaw == 0 then
            break
        end
        local tag = tagRaw:byte()
        if tag == 0xFF then
            break
        elseif tag ~= 0 then
            local lenRaw = buff:read(1)
            if not lenRaw or #lenRaw == 0 then
                break
            end
            local len = lenRaw:byte()
            local data = buff:read(len)
            if not data or #data ~= len then
                break
            end
            if tag == 53 then
                pkg.msgtype = data:byte()
            end
            pkg.opts[#pkg.opts + 1] = { tag, data }
        end
    end

    if not pkg.msgtype then
        return nil
    end
    return pkg
end

-- 将 DHCP Lua 表重新编码进 zbuff。
local function dhcpEncode(pkg, buff)
    buff:seek(0)
    buff[0] = pkg.op
    buff[1] = pkg.htype
    buff[2] = pkg.hlen
    buff[3] = pkg.hops

    buff:seek(4)
    buff:write(pkg.xid)
    buff:pack(">H", pkg.secs)
    buff:pack(">H", pkg.flags)
    buff:write(pkg.ciaddr)
    buff:write(pkg.yiaddr)
    buff:write(pkg.siaddr)
    buff:write(pkg.giaddr)
    buff:write(pkg.chaddr)
    buff:seek(192, zbuff.SEEK_CUR)
    buff:pack(">I", pkg.magic)

    for _, opt in ipairs(pkg.opts) do
        buff:write(opt[1])
        buff:write(#opt[2])
        buff:write(opt[2])
    end
    buff:write(0xFF, 0x00)
end

-- 向客户端发送 DHCP offer/ack/nack。
local function dhcpSendReply(srv, pkg, client, msgtype)
    local buff = zbuff.create(300)
    local gw = srv.opts.gw
    local dns = srv.opts.dns or gw
    local msgName = msgtype == 2 and "offer" or (msgtype == 5 and "ack" or "nack")

    pkg.op = 2
    pkg.secs = 0
    pkg.ciaddr = "\0\0\0\0"
    pkg.yiaddr = string.char(gw[1], gw[2], gw[3], client.ip)
    pkg.siaddr = string.char(gw[1], gw[2], gw[3], gw[4])
    pkg.giaddr = "\0\0\0\0"
    pkg.opts = {
        { 53, string.char(msgtype) },
        { 1, ipBytes(srv.opts.mark) },
        { 3, ipBytes(gw) },
        { 51, "\x00\x00\x1E\x00" },
        { 54, ipBytes(gw) },
        { 6, ipBytes(dns) }
    }

    dhcpEncode(pkg, buff)
    if srv.udp and srv.udp.send then
        srv.udp:send(buff, "255.255.255.255", 68)
    elseif srv.ctrl then
        local ok, full, result = socket.tx(srv.ctrl, buff, "255.255.255.255", 68)
        logInfo("dhcp", msgName, string.format("%d.%d.%d.%d", gw[1], gw[2], gw[3], client.ip), ok, full, result)
    end
end

-- 为 DHCP discover 分配或复用 IP 地址。
local function dhcpHandleDiscover(srv, pkg)
    local mac = pkg.chaddr:sub(1, pkg.hlen)
    for _, client in pairs(srv.clients) do
        if client.mac == mac then
            dhcpSendReply(srv, pkg, client, 2)
            return
        end
    end

    local ipSuffix
    for i = srv.opts.ip_start, srv.opts.ip_end do
        if not srv.clients[i] then
            ipSuffix = i
            break
        end
    end
    if not ipSuffix then
        logWarn("dhcpsrv", "no free IP")
        return
    end

    local client = { mac = mac, ip = ipSuffix }
    srv.clients[ipSuffix] = client
    logInfo("dhcp", "discover", string.format("%02X:%02X:%02X:%02X:%02X:%02X", mac:byte(1, 6)), ipSuffix)
    dhcpSendReply(srv, pkg, client, 2)
end

-- 确认已知客户端的 DHCP 租约请求。
local function dhcpHandleRequest(srv, pkg)
    local mac = pkg.chaddr:sub(1, pkg.hlen)
    for _, client in pairs(srv.clients) do
        if client.mac == mac then
            logInfo("dhcp", "request", string.format("%02X:%02X:%02X:%02X:%02X:%02X", mac:byte(1, 6)), client.ip)
            dhcpSendReply(srv, pkg, client, 5)
            return
        end
    end
    logWarn("dhcp", "request unknown client", string.format("%02X:%02X:%02X:%02X:%02X:%02X", mac:byte(1, 6)))
    dhcpSendReply(srv, pkg, { ip = 0 }, 6)
end

-- 处理 udpsrv 后端收到的 DHCP 数据报。
local function dhcpTask(srv)
    while not srv.closed do
        local ok, data = sys.waitUntil(srv.udp_topic, 1000)
        if ok and data and not srv.closed then
            local pkg = dhcpDecode(zbuff.create(#data, data))
            if pkg and pkg.magic == 0x63825363 and pkg.op == 1 and pkg.htype == 1 and pkg.hlen == 6 then
                if pkg.msgtype == 1 then
                    dhcpHandleDiscover(srv, pkg)
                elseif pkg.msgtype == 3 then
                    dhcpHandleRequest(srv, pkg)
                end
            end
        end
    end
end

-- 创建 DHCP 服务：优先 udpsrv，缺失时退回 raw socket。
local function createInlineDhcp(opts)
    opts = opts or {}
    opts.mark = opts.mark or { 255, 255, 255, 0 }
    opts.gw = opts.gw or ipParts(config.AP_IP)
    opts.dns = opts.dns or { opts.gw[1], opts.gw[2], opts.gw[3], opts.gw[4] }
    opts.ip_start = opts.ip_start or 100
    opts.ip_end = opts.ip_end or 200

    if not udpsrvLib or not udpsrvLib.create then
        logWarn("setup", "udpsrv unavailable", udpsrvLoadErr)
        local srv = {
            opts = opts,
            clients = {},
            closed = false
        }
        local rxBuff = zbuff.create(1500)
        -- udpsrv 不可用时使用 raw socket 回调。
        local function onDhcpSocket(sc, event)
            logInfo("dhcp", "socket event", event)
            if event ~= socket.EVENT or srv.closed then
                return
            end
            while true do
                rxBuff:seek(0)
                local succ, dataLen, remoteIp, remotePort = socket.rx(sc, rxBuff)
                if not succ or not dataLen or dataLen <= 0 then
                    break
                end
                logInfo("dhcp", "rx", dataLen, remotePort)
                local data = rxBuff:toStr(0, dataLen)
                rxBuff:del()
                local pkg = dhcpDecode(zbuff.create(#data, data))
                if pkg and pkg.magic == 0x63825363 and pkg.op == 1 and pkg.htype == 1 and pkg.hlen == 6 then
                    if pkg.msgtype == 1 then
                        dhcpHandleDiscover(srv, pkg)
                    elseif pkg.msgtype == 3 then
                        dhcpHandleRequest(srv, pkg)
                    end
                end
            end
        end

        srv.ctrl = socket.create(opts.adapter, onDhcpSocket)
        if not srv.ctrl then
            logWarn("setup", "socket dhcp create failed")
            return nil
        end
        if not socket.config(srv.ctrl, 67, true) then
            logWarn("setup", "socket dhcp config failed")
            socket.close(srv.ctrl)
            return nil
        end
        local ok, ready = socket.connect(srv.ctrl, "255.255.255.255", 0)
        logInfo("setup", "socket dhcp connect", ok, ready)

        -- 关闭 raw-socket DHCP 后端。
        function srv:close()
            if self.closed then
                return
            end
            self.closed = true
            if self.ctrl then
                socket.close(self.ctrl)
                if socket.release then
                    socket.release(self.ctrl)
                end
            end
            self.ctrl = nil
        end

        return srv
    end

    local srv = {
        opts = opts,
        clients = {},
        closed = false,
        udp_topic = "dhcpd_inline_" .. tostring(opts.adapter or 0) .. "_" .. tostring(mcu.ticks())
    }
    srv.udp = udpsrvLib.create(67, srv.udp_topic, opts.adapter)
    if not srv.udp then
        return nil
    end

    sys.taskInit(dhcpTask, srv)
    -- 关闭 udpsrv DHCP 后端，并唤醒等待中的任务退出。
    function srv:close()
        if self.closed then
            return
        end
        self.closed = true
        if self.udp and self.udp.close then
            self.udp:close()
        end
        self.udp = nil
        sys.publish(self.udp_topic)
    end

    return srv
end

-- 配置 AP IP、DHCP 和强制门户 DNS。
local function setupApNetwork()
    local adapter = apAdapter()
    if not adapter then
        logWarn("setup", "socket.LWIP_AP missing")
        return false
    end

    local gateway = config.AP_GATEWAY or config.AP_IP
    if netdrv and netdrv.ipv4 then
        local ok, ip, mask, gw = pcall(netdrv.ipv4, adapter, config.AP_IP, config.AP_NETMASK, gateway)
        if ok then
            logInfo("setup", "ap ip configured", ip or config.AP_IP, mask or config.AP_NETMASK, gw or gateway)
        else
            logWarn("setup", "ap ip configure failed", ip)
            return false
        end
    else
        logWarn("setup", "netdrv.ipv4 unavailable")
        return false
    end

    if dhcpsrvLib and dhcpsrvLib.create then
        local serverIp = ipParts(config.AP_IP)
        local ok, ret = pcall(dhcpsrvLib.create, {
            adapter = adapter,
            gw = serverIp,
            dns = serverIp
        })
        if ok and ret then
            apDhcp = ret
            logInfo("setup", "dhcp server started")
        else
            logWarn("setup", "dhcp server start failed", ret)
            return false
        end
    else
        logWarn("setup", "dhcpsrv unavailable", dhcpsrvLoadErr)
        local serverIp = ipParts(config.AP_IP)
        apDhcp = createInlineDhcp({
            adapter = adapter,
            gw = serverIp,
            dns = serverIp
        })
        if not apDhcp then
            return false
        end
        logInfo("setup", "inline dhcp server started")
    end

    local dnsOk = startCaptiveDns(adapter)
    if not dnsOk and dnsproxyLib and dnsproxyLib.setup and socket and socket.LWIP_GP then
        local ok, err = pcall(dnsproxyLib.setup, adapter, socket.LWIP_GP)
        if not ok then
            logWarn("setup", "dns proxy setup failed", err)
        end
    elseif not dnsOk and dnsproxyLoadErr then
        logWarn("setup", "dnsproxy unavailable", dnsproxyLoadErr)
    end
    return true
end

-- 停止 HTTP、DNS、DHCP 和 AP 射频。
function M.stop()
    if not M.running then
        return
    end
    M.running = false

    local adapter = apAdapter()
    if httpsrv and httpsrv.stop then
        pcall(httpsrv.stop, 80)
    end
    stopCaptiveDns()
    if apDhcp and apDhcp.close then
        pcall(function()
            apDhcp:close()
        end)
        apDhcp = nil
    end
    if wlan and wlan.setMode and wlan.NONE then
        pcall(wlan.setMode, wlan.NONE)
    elseif wlan and wlan.stopAP then
        pcall(wlan.stopAP)
    end
    logInfo("setup", "ap stopped")
end

-- 启动 AP；有密码时优先尝试加密热点。
local function startAp(ssid, password)
    if wlan and wlan.createAP then
        local ok, ret, err = pcall(wlan.createAP, ssid, password)
        if not ok then
            return false, ret
        end
        return true, ret or err
    end
    return false, "wlan.createAP unavailable"
end

-- 打开配置门户，并在 AP_WINDOW_MS 时间窗口内保持可访问。
function M.startWindow()
    if M.running then
        return true
    end

    local ssid = device.apSsid(storage.get())
    if wlan and wlan.init then
        pcall(wlan.init)
    end
    if sys and sys.wait then
        sys.wait(100)
    end

    local ok, err = startAp(ssid, config.AP_PASS)
    if not ok then
        logWarn("setup", "ap start failed", err)
        local openOk, openErr = startAp(ssid)
        if not openOk then
            logError("setup", "ap start failed after retry", openErr)
            return false
        end
        logInfo("setup", "ap started open", ssid, config.AP_IP)
    else
        logInfo("setup", "ap started secure", ssid, config.AP_IP)
    end

    if sys and sys.wait then
        sys.wait(1000)
    end
    local netOk = setupApNetwork()
    if not netOk then
        logError("setup", "ap network setup failed, phone may stay obtaining ip")
    end

    if httpsrv and httpsrv.start then
        local adapter = apAdapter()
        local callOk, hsErr
        if adapter then
            callOk, hsErr = pcall(httpsrv.start, 80, handler, adapter)
        else
            callOk, hsErr = pcall(httpsrv.start, 80, handler)
        end
        if not callOk then
            logWarn("setup", "http server start failed", hsErr)
        else
            logInfo("setup", "http server started", 80)
        end
    end

    M.running = true
    sys.timerStart(M.stop, config.AP_WINDOW_MS)
    logInfo("setup", "ap", ssid, config.AP_IP)
    return true
end

return M
