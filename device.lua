local storage = require("storage")

local M = {}

-- Read a mobile module value without letting missing APIs break boot.
local function mobileValue(name)
    if mobile and mobile[name] then
        local ok, v = pcall(mobile[name])
        if ok and v and #tostring(v) > 0 then
            return tostring(v):gsub("%z", "")
        end
    end
end

-- Return configured SN first, then fallback hardware IDs for naming.
function M.id(cfg)
    cfg = cfg or storage.get()
    if cfg.sn and #cfg.sn > 0 then
        return cfg.sn
    end
    return mobileValue("imei") or mobileValue("muid") or "tinynav"
end

-- Return the modem IMEI when the firmware exposes it.
function M.imei()
    return mobileValue("imei")
end

-- Build the AP SSID from the last characters of the device ID.
function M.apSsid(cfg)
    local id = M.id(cfg)
    local tail = id:match("([%w_%-]+)$") or id
    if #tail > 6 then
        tail = tail:sub(-6)
    end
    return "TinyNav-" .. tail
end

return M
