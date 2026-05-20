local config = require("config")
local device = require("device")
local storage = require("storage")

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

local M = { running = false }
local apDhcp

local function urlDecode(s)
    s = (s or ""):gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function readForm(body)
    local t = {}
    for pair in tostring(body or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        t[urlDecode(k)] = urlDecode(v)
    end
    return t
end

local function html(s)
    return tostring(s or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
end

local function page(msg)
    local c = storage.get()
    local ssl = c.mqtt_ssl and " checked" or ""
    local interval = math.floor(c.report_interval_ms / 1000)
    return [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>TinyNav &#37197;&#32593;</title>
<style>body{font-family:Arial,sans-serif;margin:0;background:#f7f8fa;color:#222}
main{max-width:420px;margin:auto;padding:22px}label{display:block;margin:12px 0 6px}
input{box-sizing:border-box;width:100%;height:42px;padding:0 10px;border:1px solid #ccc;border-radius:6px;font-size:16px}
.row{display:flex;gap:10px}.row div{flex:1}.ck{display:flex;gap:8px;align-items:center;margin:14px 0}.ck input{width:auto;height:auto}
button{width:100%;height:44px;border:0;border-radius:6px;background:#1463ff;color:#fff;font-size:17px}p{color:#19723b}</style>
</head><body><main><h2>TinyNav &#37197;&#32593;</h2><p>]] .. html(msg) .. [[</p>
<form method="post" action="/save">
<label>&#35774;&#22791;SN</label><input name="sn" required value="]] .. html(c.sn) .. [[">
<label>MQTT&#22320;&#22336;</label><input name="mqtt_host" required value="]] .. html(c.mqtt_host) .. [[">
<div class="row"><div><label>&#31471;&#21475;</label><input name="mqtt_port" inputmode="numeric" value="]] .. html(c.mqtt_port) .. [["></div>
<div><label>&#38388;&#38548;(&#31186;)</label><input name="interval" inputmode="numeric" value="]] .. html(interval) .. [["></div></div>
<label>&#29992;&#25143;&#21517;</label><input name="mqtt_user" value="]] .. html(c.mqtt_user) .. [[">
<label>&#23494;&#30721;</label><input name="mqtt_pass" type="password" value="]] .. html(c.mqtt_pass) .. [[">
<label>&#20027;&#39064;</label><input name="mqtt_topic" placeholder="sys/{SN}/json/up/realTime" value="]] .. html(c.mqtt_topic) .. [[">
<label class="ck"><input type="checkbox" name="mqtt_ssl"]] .. ssl .. [[>&#21551;&#29992;MQTTS</label>
<label>SM4 Key(&#30041;&#31354;&#19981;&#25913;)</label><input name="sm4_key">
<label>SM4 IV(&#30041;&#31354;&#19981;&#25913;)</label><input name="sm4_iv">
<button type="submit">&#20445;&#23384;</button></form></main></body></html>]]
end

local function save(body)
    local c = readForm(body)
    c.mqtt_ssl = c.mqtt_ssl == "on"
    c.report_interval_ms = (tonumber(c.interval) or 600) * 1000
    local ok = storage.save(c)
    if c.sm4_key and #c.sm4_key > 0 and c.sm4_iv and #c.sm4_iv > 0 then
        storage.saveSm4(c.sm4_key, c.sm4_iv)
    end
    sys.publish("CONFIG_UPDATED")
    return page(ok and "Saved" or "Save failed")
end

local function reply(code, headers, body)
    return code, headers or {}, body or ""
end

local function handler(client, method, uri, headers, body)
    uri = (uri or "/"):match("^[^?]*")
    if method == "POST" and uri == "/save" then
        return reply(200, { ["Content-Type"] = "text/html; charset=utf-8" }, save(body))
    end
    if uri ~= "/" then
        return reply(302, { Location = "http://" .. config.AP_IP .. "/" })
    end
    return reply(200, { ["Content-Type"] = "text/html; charset=utf-8" }, page(""))
end

local function apAdapter()
    return socket and socket.LWIP_AP
end

local function logWarn(...)
    if log and log.warn then
        log.warn(...)
    end
end

local function logInfo(...)
    if log and log.info then
        log.info(...)
    end
end

local function logError(...)
    if log and log.error then
        log.error(...)
    end
end

local function ipParts(ip)
    local a, b, c, d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return { 192, 168, 4, 1 }
    end
    return { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
end

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
        return false
    end

    if dnsproxyLib and dnsproxyLib.setup and socket and socket.LWIP_GP then
        local ok, err = pcall(dnsproxyLib.setup, adapter, socket.LWIP_GP)
        if not ok then
            logWarn("setup", "dns proxy setup failed", err)
        end
    elseif dnsproxyLoadErr then
        logWarn("setup", "dnsproxy unavailable", dnsproxyLoadErr)
    end
    return true
end

function M.stop()
    if not M.running then
        return
    end
    M.running = false

    local adapter = apAdapter()
    if httpsrv and httpsrv.stop then
        pcall(httpsrv.stop, 80)
    end
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
