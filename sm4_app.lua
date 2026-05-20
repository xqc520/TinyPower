local M = {}

-- Normalize optional text fields before validating keys.
local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Convert a 32-char hex string into 16 raw bytes.
local function fromHex(s)
    return (s:gsub("(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Convert encrypted bytes to upper-case hex for MQTT payloads.
local function toHex(s)
    return (s:gsub(".", function(c)
        return string.format("%02X", c:byte())
    end))
end

-- Accept either 16 raw chars or 32 hex chars as SM4 material.
local function keyBytes(s)
    s = trim(s)
    if #s == 32 and s:match("^[0-9a-fA-F]+$") then
        s = fromHex(s)
    end
    return #s == 16 and s or nil
end

-- Check that both key and IV can become valid SM4 byte strings.
function M.ready(c)
    c = c or {}
    return keyBytes(c.key) ~= nil and keyBytes(c.iv) ~= nil
end

-- Encrypt plaintext as SM4-CBC/PKCS7 and return hex text.
function M.encryptHex(plain, c)
    local key, iv = keyBytes(c and c.key), keyBytes(c and c.iv)
    if not (gmssl and key and iv) then
        return nil
    end
    local enc = gmssl.sm4encrypt("CBC", "PKCS7", plain, key, iv)
    return enc and toHex(enc) or nil
end

return M
