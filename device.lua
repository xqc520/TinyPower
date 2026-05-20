local storage = require("storage")

local M = {}

-- 读取模块信息；失败就返回 nil，不影响主流程
local function mobileValue(name)
    if mobile and mobile[name] then
        local ok, v = pcall(mobile[name])
        if ok and v and #tostring(v) > 0 then
            local s = tostring(v):gsub("%z", "")
            return s
        end
    end
end

function M.id(cfg)
    -- 优先用用户配置的 SN，没有就退回 IMEI/MUID
    cfg = cfg or storage.get()
    if cfg.sn and #cfg.sn > 0 then
        return cfg.sn
    end
    return mobileValue("imei") or mobileValue("muid") or "tinynav"
end

function M.imei()
    return mobileValue("imei")
end

function M.apSsid(cfg)
    -- 热点名短一点，手机列表里更容易识别
    local id = M.id(cfg)
    local tail = id:match("([%w_%-]+)$") or id
    if #tail > 6 then
        tail = tail:sub(-6)
    end
    return "TinyNav-" .. tail
end

return M
