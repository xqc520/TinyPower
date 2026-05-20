local M = {}

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function fromHex(s)
    return (s:gsub("(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function toHex(s)
    return (s:gsub(".", function(c)
        return string.format("%02X", c:byte())
    end))
end

local function keyBytes(s)
    -- 协议支持 16 字符明文 key/iv，也支持 32 位 HEX
    s = trim(s)
    if #s == 32 and s:match("^[0-9a-fA-F]+$") then
        s = fromHex(s)
    end
    return #s == 16 and s or nil
end

function M.ready(c)
    c = c or {}
    return keyBytes(c.key) ~= nil and keyBytes(c.iv) ~= nil
end

function M.encryptHex(plain, c)
    -- 实时上报要求：SM4-CBC + PKCS7 + HEX
    local key, iv = keyBytes(c and c.key), keyBytes(c and c.iv)
    if not (gmssl and key and iv) then
        return nil
    end
    local enc = gmssl.sm4encrypt("CBC", "PKCS7", plain, key, iv)
    return enc and toHex(enc) or nil
end

return M
