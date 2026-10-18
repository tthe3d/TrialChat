-- SHA-256 and HMAC-SHA256, for proving you know a group's password without
-- sending it (see "Joining without sending the password" in
-- TrialChatGroups.lua). WoW has no hashing of its own, so this is plain Lua
-- on the game's bit library. Every value is kept in 0 .. 2^32 - 1, whatever
-- sign the bit functions hand back.
TrialChatHash = {}
local Hash = TrialChatHash

local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift
local MOD = 4294967296

local function u32(value)
    return value % MOD
end

local function rotr(value, bits)
    return u32(bor(rshift(value, bits), lshift(value, 32 - bits)))
end

local function xor3(a, b, c)
    return u32(bxor(bxor(a, b), c))
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function wordBytes(word)
    return string.char(math.floor(word / 16777216) % 256, math.floor(word / 65536) % 256,
        math.floor(word / 256) % 256, word % 256)
end

-- The SHA-256 digest of a string, as 32 raw bytes.
function Hash.SHA256(message)
    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local bitLength = #message * 8
    message = message .. "\128" .. string.rep("\0", (55 - #message) % 64)
        .. wordBytes(math.floor(bitLength / MOD)) .. wordBytes(bitLength % MOD)

    local w = {}
    for chunkStart = 1, #message, 64 do
        for i = 0, 15 do
            local a, b, c, d = string.byte(message, chunkStart + i * 4, chunkStart + i * 4 + 3)
            w[i] = ((a * 256 + b) * 256 + c) * 256 + d
        end
        for i = 16, 63 do
            local s0 = xor3(rotr(w[i - 15], 7), rotr(w[i - 15], 18), u32(rshift(w[i - 15], 3)))
            local s1 = xor3(rotr(w[i - 2], 17), rotr(w[i - 2], 19), u32(rshift(w[i - 2], 10)))
            w[i] = u32(w[i - 16] + s0 + w[i - 7] + s1)
        end

        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 0, 63 do
            local s1 = xor3(rotr(e, 6), rotr(e, 11), rotr(e, 25))
            -- (e and f) xor ((not e) and g), with "not" done as subtraction.
            local choice = u32(bxor(band(e, f), band(MOD - 1 - e, g)))
            local temp1 = u32(hh + s1 + choice + K[i + 1] + w[i])
            local s0 = xor3(rotr(a, 2), rotr(a, 13), rotr(a, 22))
            local majority = xor3(u32(band(a, b)), u32(band(a, c)), u32(band(b, c)))
            local temp2 = u32(s0 + majority)
            hh, g, f, e, d, c, b, a = g, f, e, u32(d + temp1), c, b, a, u32(temp1 + temp2)
        end
        h[1], h[2], h[3], h[4] = u32(h[1] + a), u32(h[2] + b), u32(h[3] + c), u32(h[4] + d)
        h[5], h[6], h[7], h[8] = u32(h[5] + e), u32(h[6] + f), u32(h[7] + g), u32(h[8] + hh)
    end

    local digest = {}
    for i = 1, 8 do digest[i] = wordBytes(h[i]) end
    return table.concat(digest)
end

local function xorBytes(text, value)
    return (string.gsub(text, ".", function(char)
        return string.char(u32(bxor(string.byte(char), value)))
    end))
end

-- HMAC-SHA256 of a message under a key, as 32 raw bytes.
function Hash.HMAC(key, message)
    if #key > 64 then key = Hash.SHA256(key) end
    key = key .. string.rep("\0", 64 - #key)
    return Hash.SHA256(xorBytes(key, 0x5c) .. Hash.SHA256(xorBytes(key, 0x36) .. message))
end

function Hash.ToHex(bytes)
    return (string.gsub(bytes, ".", function(char)
        return string.format("%02x", string.byte(char))
    end))
end
