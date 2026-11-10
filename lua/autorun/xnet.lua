-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 exliipso
-- Originally developed by exliipso

--[[
    XNet: send Lua values between the server and clients, any size.

        XNet.Receive(name, callback [, options])
        XNet.Send(target, name, ...)   server: target is a player, a list of
                                       players, or nil for everyone
        XNet.Send(name, ...)           client, to the server
        XNet.Broadcast(name, ...)      server

        XNet.Encode(...) -> string     the wire format on its own
        XNet.Decode(string) -> ...
        XNet.Queued([ply]) -> bytes    still waiting to go out

    Server callbacks get (ply, ...), client callbacks get (...). Arguments
    arrive exactly as sent, trailing nils included. Messages to one player
    arrive in the order they were sent.

    Values: nil, booleans, numbers (exact; integers packed small), strings
    (any bytes), tables (array and hash parts, nested), Vector, Angle, Color,
    Entity / Player. The one exception to exact numbers: subnormals (below
    2.2e-308) can arrive as zero, because the server's CPU treats them as zero
    in compiled code anyway.

    Why it is fast:
      - Values are written as bytes into a number array and turned into
        strings in large blocks, never one string per value. The decoder reads
        bytes in place.
      - A string seen before in the same message (a table key, a repeated
        value) is sent as a short reference, so arrays of records shrink a lot
        before any compression.
      - The small messages a player gets during a frame are joined into one
        net message, written in the Tick hook of that same frame, so the
        engine's per-message cost is paid once. Nothing waits a frame. A
        broadcast is encoded once and sent to everyone with one net.Send.
      - With the native module installed (gmsv_xnet), the server encodes in
        Rust straight into each player's batch. Clients always use Lua.
      - LZMA compression only for payloads big enough to win the time back.

    Big messages: GMod sends anything bigger than a packet as split packets,
    no faster than net_splitpacket_maxrate (45 KB/s by default). Whatever
    goes beyond that waits in the engine's reliable buffer, and overflowing
    that buffer disconnects the player. So messages are cut into chunks, the
    receiver confirms each one, and only a window of about 0.2 s of that rate
    (32-192 KB) is ever unconfirmed per receiver: transfers run as fast as the
    link drains and can never overflow it. The channel is reliable and
    ordered, so there are no checksums or resends on top.

    Safety, for what clients send to the server:
      - Only names with a Receive are accepted; anything else is dropped
        before it is buffered.
      - Each name has a size limit (default 64 KB; the decompressed size is
        enforced inside the decompressor) and a per-player rate limit.
      - One transfer in flight per player; a stalled one is dropped.
      - The decoder checks every length and count against the bytes actually
        present, limits nesting, and never trusts a declared size.
      - A handler error is reported and does not affect other messages.
    Rejections fire hook "XNet.Rejected" (ply, name, reason).

    Receive options (server only): maxBytes, rate (messages per second, per
    player, 0 for no limit), burst.
]]

if SERVER then AddCSLuaFile() end

XNet = XNet or {}
XNet.Version = "0.4.1"

local XNet = XNet

XNet.Config = XNet.Config or {}
XNet.Handlers = XNet.Handlers or {}

local Config = XNet.Config
local Handlers = XNet.Handlers

local function default(key, value)
    if Config[key] == nil then Config[key] = value end
end

-- Window: unconfirmed bytes allowed per receiver. nil sizes it to the link:
-- 0.2 s of net_splitpacket_maxrate, 32-192 KB. Chunks are a quarter of it.
default("StallTimeout", 10)         -- seconds without a confirmation before the window reopens
default("MaxQueued", 33554432)      -- bytes waiting per receiver before Send refuses
default("CompressAt", 32768)        -- encoded size from which LZMA is tried
default("MaxDepth", 64)             -- table nesting
default("ClientMaxBytes", 65536)    -- per message, unless a Receive says otherwise
default("ClientRate", 30)           -- messages per second per name, per player
default("ClientBurst", 60)
default("Timeout", 30)              -- seconds a stalled incoming transfer is kept
default("Batch", true)              -- server: join a player's small messages each frame

local CHANNEL = "XNet"
local FORMAT = 1

if SERVER then util.AddNetworkString(CHANNEL) end

local byte, char, sub = string.byte, string.char, string.sub
local concat, unpack = table.concat, unpack
local floor, ldexp, huge = math.floor, math.ldexp, math.huge
local band, rshift = bit.band, bit.rshift
local type, next, select, error, getmetatable, setmetatable = type, next, select, error, getmetatable, setmetatable
local pcall, xpcall, IsValid, Entity, Vector, Angle = pcall, xpcall, IsValid, Entity, Vector, Angle
local SysTime = SysTime

local COLOR = FindMetaTable("Color")

--------------------------------------------------------------------------------
-- Format
--
--     0..127     integer 0..127
--     128..159   string of 0..31 bytes, bytes follow
--     160..191   table with 0..31 array values; the values follow, then any
--                other key/value pairs, then NIL
--     192 nil    193 false    194 true
--     195..198   integer 0..2^53 in 1, 2, 4, 7 bytes
--     199..202   integer -1-n for n in 1, 2, 4, 7 bytes
--     203        double, 8 bytes
--     204..206   string, length in 1, 2, 4 bytes
--     207..209   reference to the n-th string of 4+ bytes seen so far, n in
--                1, 2, 4 bytes
--     210        table, array count as a varint, then as 160..191
--     211 Vector, 212 Angle: three float32 (engine precision, so exact)
--     213        Color, 4 bytes
--     214        Entity, index + 1 in 2 bytes (0 is NULL)
--     224..255   integer -32..-1
--
--     Multi-byte numbers are little-endian. A payload is the format byte, the
--     argument count as a varint, then the arguments.
--------------------------------------------------------------------------------

local T_NIL, T_FALSE, T_TRUE = 192, 193, 194
local T_U8, T_U16, T_U32, T_U53 = 195, 196, 197, 198
local T_N8, T_N16, T_N32, T_N53 = 199, 200, 201, 202
local T_F64 = 203
local T_S8, T_S16, T_S32 = 204, 205, 206
local T_R8, T_R16, T_R32 = 207, 208, 209
local T_TAB = 210
local T_VEC, T_ANG, T_COL, T_ENT = 211, 212, 213, 214

local MIN_INTERN = 4                -- shorter strings cost no more than a reference
local SHORT_STRING = 48             -- copied into the byte array; longer ones are kept as is
local FLUSH_BLOCK = 4096            -- bytes per string.char call

local ENTITY_TYPES = {Entity = true, Player = true, Weapon = true, NPC = true, Vehicle = true, NextBot = true, CSEnt = true}

-- Exponents come from log and a table of powers of two: math.frexp cannot be
-- compiled by the server's LuaJIT 2.0 and would drop every float to the
-- interpreter.
local log = math.log
local INV_LN2 = 1 / log(2)
local POW2 = {}

for e = -1074, 1024 do POW2[e] = 2 ^ e end

local MIN_NORMAL64 = 2 ^ -1022
local MIN_NORMAL32 = 2 ^ -126
local TWO_1022, TWO_149 = 2 ^ 1022, 2 ^ 149

-- floor(log2(v)) for a positive finite v.
local function exponent(v)
    local x = floor(log(v) * INV_LN2)

    if POW2[x] > v then
        x = x - 1
    elseif POW2[x + 1] <= v then
        x = x + 1
    end

    return x
end

--------------------------------------------------------------------------------
-- Encoder. State lives in upvalues so the hot paths touch no tables but the
-- byte array.
--------------------------------------------------------------------------------

local B, nb = {}, 0                 -- pending bytes
local P, np = {}, 0                 -- finished pieces
local strings, nstrings = {}, 0     -- string -> reference number, this message
local SL, LISTED = {}, 16           -- the first LISTED strings of this message
local seen = {}                     -- tables being written, for cycles
local depth = 0
local busy = false

local function flush()
    if nb == 0 then return end

    local i = 1

    while i <= nb do
        local j = i + FLUSH_BLOCK - 1
        if j > nb then j = nb end

        np = np + 1
        P[np] = char(unpack(B, i, j))
        i = j + 1
    end

    nb = 0
end

local function wvar(x)
    while x >= 128 do
        nb = nb + 1
        B[nb] = x % 128 + 128
        x = floor(x / 128)
    end

    nb = nb + 1
    B[nb] = x
end

-- 1, 2, 4 or 7 little-endian bytes of a non-negative integer, after a tag.
local function wuint(v, t8)
    local n = nb

    if v < 256 then
        B[n + 1] = t8
        B[n + 2] = v
        nb = n + 2
    elseif v < 65536 then
        B[n + 1] = t8 + 1
        B[n + 2] = band(v, 255)
        B[n + 3] = rshift(v, 8)
        nb = n + 3
    elseif v < 4294967296 then
        B[n + 1] = t8 + 2
        B[n + 2] = band(v, 255)
        B[n + 3] = band(rshift(v, 8), 255)
        B[n + 4] = band(rshift(v, 16), 255)
        B[n + 5] = rshift(v, 24)
        nb = n + 5
    else
        -- Split as a fraction: the server's LuaJIT 2.0 miscompiles % and
        -- floor on numbers this large once the code is hot.
        local f = v / 4294967296
        local hi = floor(f)
        local lo = (f - hi) * 4294967296

        B[n + 1] = t8 + 3
        B[n + 2] = band(lo, 255)
        B[n + 3] = band(rshift(lo, 8), 255)
        B[n + 4] = band(rshift(lo, 16), 255)
        B[n + 5] = rshift(lo, 24)
        B[n + 6] = band(hi, 255)
        B[n + 7] = band(rshift(hi, 8), 255)
        B[n + 8] = rshift(hi, 16)
        nb = n + 8
    end
end

local function wdouble(v)
    local sign = 0

    if v < 0 or (v == 0 and 1 / v < 0) then
        sign = 128
        v = -v
    end

    local e, hi, lo

    if v ~= v then
        e, hi, lo = 2047, 524288, 0
    elseif v == huge then
        e, hi, lo = 2047, 0, 0
    elseif v == 0 then
        e, hi, lo = 0, 0, 0
    else
        -- The 52-bit mantissa as hi (20 bits) and lo (32 bits), split as a
        -- fraction so no intermediate is large: the server's LuaJIT 2.0
        -- miscompiles % and floor on 52-bit values once the code is hot.
        local f

        if v < MIN_NORMAL64 then
            e = 0
            f = v * TWO_1022 * 1048576          -- exact: scaling by powers of two
        else
            local x = exponent(v)

            e = x + 1023
            f = (v / POW2[x] - 1) * 1048576
        end

        hi = floor(f)
        lo = (f - hi) * 4294967296
    end

    local n = nb

    B[n + 1] = T_F64
    B[n + 2] = band(lo, 255)
    B[n + 3] = band(rshift(lo, 8), 255)
    B[n + 4] = band(rshift(lo, 16), 255)
    B[n + 5] = rshift(lo, 24)
    B[n + 6] = band(hi, 255)
    B[n + 7] = band(rshift(hi, 8), 255)
    B[n + 8] = band(e, 15) * 16 + rshift(hi, 16)
    B[n + 9] = sign + rshift(e, 4)
    nb = n + 9
end

local function wnumber(v)
    if v == floor(v) and v > -9007199254740992 and v < 9007199254740992 and (v ~= 0 or 1 / v > 0) then
        if v >= 0 then
            if v < 128 then
                nb = nb + 1
                B[nb] = v
            else
                wuint(v, T_U8)
            end
        elseif v >= -32 then
            -- band: the server runs with denormals-are-zero, so in compiled
            -- code a tiny negative number can land here as if it were -0.
            nb = nb + 1
            B[nb] = band(256 + v, 255)
        else
            wuint(-1 - v, T_N8)
        end
    else
        wdouble(v)
    end
end

local function wfloat(v)
    local sign = 0

    if v < 0 or (v == 0 and 1 / v < 0) then
        sign = 128
        v = -v
    end

    local e, mantissa

    if v ~= v then
        e, mantissa = 255, 4194304
    elseif v == huge then
        e, mantissa = 255, 0
    elseif v == 0 then
        e, mantissa = 0, 0
    elseif v < MIN_NORMAL32 then
        mantissa = floor(v * TWO_149 + 0.5)
        e = 0

        if mantissa >= 8388608 then
            mantissa = mantissa - 8388608
            e = 1
        end
    else
        local x = exponent(v)

        e = x + 127

        if e >= 255 then
            e, mantissa = 255, 0
        else
            mantissa = floor((v / POW2[x] - 1) * 8388608 + 0.5)

            if mantissa >= 8388608 then
                mantissa = 0
                e = e + 1
                if e >= 255 then e, mantissa = 255, 0 end
            end
        end
    end

    local n = nb

    B[n + 1] = band(mantissa, 255)
    B[n + 2] = band(rshift(mantissa, 8), 255)
    B[n + 3] = band(e, 1) * 128 + rshift(mantissa, 16)
    B[n + 4] = sign + rshift(e, 1)
    nb = n + 4
end

local function wstring(s)
    local len = #s

    if len >= MIN_INTERN then
        local ref = strings[s]

        if ref then
            wuint(ref, T_R8)
            return
        end

        strings[s] = nstrings
        nstrings = nstrings + 1

        -- The first few are listed so a small message can clear them
        -- instead of replacing the table.
        if nstrings <= LISTED then SL[nstrings] = s end
    end

    if len < 32 then
        nb = nb + 1
        B[nb] = 128 + len
    else
        wuint(len, T_S8)
    end

    if len <= SHORT_STRING then
        local n = nb

        for i = 1, len do B[n + i] = byte(s, i) end

        nb = n + len
    else
        flush()
        np = np + 1
        P[np] = s
    end
end

local wvalue

local function wtable(t)
    if getmetatable(t) == COLOR then
        -- Raw reads, as the native edition does: no metamethod runs.
        local r, g, b, a = rawget(t, "r"), rawget(t, "g"), rawget(t, "b"), rawget(t, "a")

        if r and g and b and a and r % 1 == 0 and g % 1 == 0 and b % 1 == 0 and a % 1 == 0
            and r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255 and a >= 0 and a <= 255 then
            local n = nb

            B[n + 1] = T_COL
            B[n + 2] = r
            B[n + 3] = g
            B[n + 4] = b
            B[n + 5] = a
            nb = n + 5

            return
        end
    end

    if seen[t] then error("XNet: a table contains itself", 0) end
    if depth >= Config.MaxDepth then error("XNet: tables nested too deeply", 0) end

    seen[t] = true
    depth = depth + 1

    local na = #t

    if na < 32 then
        nb = nb + 1
        B[nb] = 160 + na
    else
        nb = nb + 1
        B[nb] = T_TAB
        wvar(na)
    end

    for i = 1, na do wvalue(t[i]) end

    for k, v in next, t do
        if type(k) ~= "number" or k < 1 or k > na or k % 1 ~= 0 then
            wvalue(k)
            wvalue(v)
        end
    end

    nb = nb + 1
    B[nb] = T_NIL

    depth = depth - 1
    seen[t] = nil
end

wvalue = function(v)
    local kind = type(v)

    if kind == "number" then
        wnumber(v)
    elseif kind == "string" then
        wstring(v)
    elseif kind == "table" then
        wtable(v)
    elseif kind == "boolean" then
        nb = nb + 1
        B[nb] = v and T_TRUE or T_FALSE
    elseif kind == "nil" then
        nb = nb + 1
        B[nb] = T_NIL
    elseif kind == "Vector" then
        -- One engine call for all three components instead of three.
        local x, y, z = v:Unpack()

        nb = nb + 1
        B[nb] = T_VEC
        wfloat(x)
        wfloat(y)
        wfloat(z)
    elseif kind == "Angle" then
        local p, y, r = v:Unpack()

        nb = nb + 1
        B[nb] = T_ANG
        wfloat(p)
        wfloat(y)
        wfloat(r)
    elseif ENTITY_TYPES[kind] then
        -- IsValid is false for the world, which is still a real entity.
        local index = 0

        if IsValid(v) then
            index = v:EntIndex() + 1
        elseif v == game.GetWorld() then
            index = 1
        end

        if index < 0 or index > 65535 then index = 0 end

        local n = nb

        B[n + 1] = T_ENT
        B[n + 2] = band(index, 255)
        B[n + 3] = rshift(index, 8)
        nb = n + 3
    else
        error("XNet: cannot send a " .. kind, 0)
    end
end

-- Arguments past the fourth. Kept apart: select() with a variable index
-- can't be compiled by LuaJIT 2.0, and most messages never get here.
local function wrest(count, ...)
    for i = 1, count do wvalue((select(i, ...))) end
end

-- Encodes count arguments. With h0 and h1, those two bytes (a message
-- header) come first, so a small message is one string and one net write.
local function encode(h0, h1, count, a, b, c, d, ...)
    if busy then
        -- A previous encode errored part way (an unsendable value); start clean.
        seen = {}
        strings, nstrings = {}, 0
        SL = {}
        P = {}
    end

    busy = true
    np, depth = 0, 0

    if h0 then
        B[1], B[2], B[3] = h0, h1, FORMAT
        nb = 3
    else
        B[1] = FORMAT
        nb = 1
    end

    if count < 128 then
        nb = nb + 1
        B[nb] = count
    else
        wvar(count)
    end

    if count > 0 then
        wvalue(a)

        if count > 1 then
            wvalue(b)

            if count > 2 then
                wvalue(c)

                if count > 3 then
                    wvalue(d)

                    if count > 4 then wrest(count - 4, ...) end
                end
            end
        end
    end

    flush()

    local out = np == 1 and P[1] or concat(P, "", 1, np)

    for i = 1, np do P[i] = nil end

    if nstrings > 0 then
        if nstrings <= LISTED then
            for i = 1, nstrings do
                strings[SL[i]] = nil
                SL[i] = nil
            end
        else
            strings = {}

            for i = 1, LISTED do SL[i] = nil end
        end

        nstrings = 0
    end

    busy = false

    return out
end

--------------------------------------------------------------------------------
-- Decoder. Every length and count is checked against the bytes left, so a
-- hostile payload can make it fail, never allocate beyond its own size.
--------------------------------------------------------------------------------

local S, pos, slen = "", 1, 0
local R, nrefs = {}, 0
local ddepth = 0

local function fail(why)
    error("XNet: bad payload (" .. why .. ")", 0)
end

local function ruint(size)
    local p = pos

    if size == 1 then
        pos = p + 1
        return byte(S, p) + 0
    elseif size == 2 then
        local b1, b2 = byte(S, p, p + 1)
        pos = p + 2
        return b2 * 256 + b1
    elseif size == 4 then
        local b1, b2, b3, b4 = byte(S, p, p + 3)
        pos = p + 4
        return ((b4 * 256 + b3) * 256 + b2) * 256 + b1
    end

    local b1, b2, b3, b4, b5, b6, b7 = byte(S, p, p + 6)
    pos = p + 7

    return (((b7 * 256 + b6) * 256 + b5) * 4294967296) + ((b4 * 256 + b3) * 256 + b2) * 256 + b1
end

local function rvar()
    local x, mul = 0, 1

    while true do
        local b = byte(S, pos)
        pos = pos + 1

        if b < 128 then return x + b * mul end

        x = x + (b - 128) * mul
        mul = mul * 128

        if mul > 72057594037927936 then fail("long count") end
    end
end

local function rdouble()
    local b1, b2, b3, b4, b5, b6, b7, b8 = byte(S, pos, pos + 7)
    pos = pos + 8

    local e = band(b8, 127) * 16 + rshift(b7, 4)
    local mantissa = (band(b7, 15) * 65536 + b6 * 256 + b5) * 4294967296 + ((b4 * 256 + b3) * 256 + b2) * 256 + b1
    local v

    if e == 0 then
        v = ldexp(mantissa, -1074)
    elseif e == 2047 then
        v = mantissa == 0 and huge or 0 / 0
    else
        v = ldexp(mantissa + 4503599627370496, e - 1075)
    end

    if b8 >= 128 then v = -v end

    return v
end

local function rfloat()
    local b1, b2, b3, b4 = byte(S, pos, pos + 3)
    pos = pos + 4

    local e = band(b4, 127) * 2 + rshift(b3, 7)
    local mantissa = band(b3, 127) * 65536 + b2 * 256 + b1
    local v

    if e == 0 then
        v = ldexp(mantissa, -149)
    elseif e == 255 then
        v = mantissa == 0 and huge or 0 / 0
    else
        v = ldexp(mantissa + 8388608, e - 150)
    end

    if b4 >= 128 then v = -v end

    return v
end

local function rstring(len)
    local last = pos + len - 1
    if last > slen then fail("string past the end") end

    local s = sub(S, pos, last)
    pos = last + 1

    if len >= MIN_INTERN then
        nrefs = nrefs + 1
        R[nrefs] = s
    end

    return s
end

local rvalue

-- A key of a key/value pair: anything but nil and NaN.
local function rkey()
    local k = rvalue()
    if k == nil or k ~= k then fail("key") end

    return k
end

-- The key/value pairs after the array part, until NIL.
local function rpairs(t)
    while true do
        local b = byte(S, pos)

        if b == T_NIL then
            pos = pos + 1
            return t
        end

        if not b then fail("table past the end") end

        local k = rkey()
        t[k] = rvalue()
    end
end

-- Small tables are read into locals first and built with a constructor:
-- it allocates the table at its final size, where filling an empty one
-- reallocates as it grows. Constructors assign in order, so a repeated key
-- ends as it would one assignment at a time.
local function rtable(na)
    -- Every value takes at least a byte, and the table ends with one.
    if na >= slen - pos + 1 then fail("table count") end

    ddepth = ddepth + 1
    if ddepth > Config.MaxDepth then fail("nesting") end

    local t

    if na == 0 then
        if byte(S, pos) == T_NIL then
            t = {}
            pos = pos + 1
        else
            local k1 = rkey()
            local v1 = rvalue()

            if byte(S, pos) == T_NIL then
                t = {[k1] = v1}
                pos = pos + 1
            else
                local k2 = rkey()
                local v2 = rvalue()

                if byte(S, pos) == T_NIL then
                    t = {[k1] = v1, [k2] = v2}
                    pos = pos + 1
                else
                    local k3 = rkey()
                    local v3 = rvalue()

                    if byte(S, pos) == T_NIL then
                        t = {[k1] = v1, [k2] = v2, [k3] = v3}
                        pos = pos + 1
                    else
                        local k4 = rkey()
                        local v4 = rvalue()

                        t = rpairs({[k1] = v1, [k2] = v2, [k3] = v3, [k4] = v4})
                    end
                end
            end
        end
    elseif na <= 4 then
        local v1 = rvalue()

        if na == 1 then
            t = {v1}
        else
            local v2 = rvalue()

            if na == 2 then
                t = {v1, v2}
            else
                local v3 = rvalue()

                if na == 3 then
                    t = {v1, v2, v3}
                else
                    local v4 = rvalue()

                    t = {v1, v2, v3, v4}
                end
            end
        end

        t = rpairs(t)
    else
        t = {}

        for i = 1, na do t[i] = rvalue() end

        t = rpairs(t)
    end

    ddepth = ddepth - 1

    return t
end

local DECODE = {}

DECODE[T_NIL] = function() return nil end
DECODE[T_FALSE] = function() return false end
DECODE[T_TRUE] = function() return true end
DECODE[T_U8] = function() return ruint(1) end
DECODE[T_U16] = function() return ruint(2) end
DECODE[T_U32] = function() return ruint(4) end
DECODE[T_U53] = function() return ruint(7) end
DECODE[T_N8] = function() return -1 - ruint(1) end
DECODE[T_N16] = function() return -1 - ruint(2) end
DECODE[T_N32] = function() return -1 - ruint(4) end
DECODE[T_N53] = function() return -1 - ruint(7) end
DECODE[T_F64] = rdouble
DECODE[T_S8] = function() return rstring(ruint(1)) end
DECODE[T_S16] = function() return rstring(ruint(2)) end
DECODE[T_S32] = function() return rstring(ruint(4)) end

local function reference(index)
    local s = R[index + 1]
    if not s then fail("reference") end

    return s
end

DECODE[T_R8] = function() return reference(ruint(1)) end
DECODE[T_R16] = function() return reference(ruint(2)) end
DECODE[T_R32] = function() return reference(ruint(4)) end
DECODE[T_TAB] = function() return rtable(rvar()) end
DECODE[T_VEC] = function() return Vector(rfloat(), rfloat(), rfloat()) end
DECODE[T_ANG] = function() return Angle(rfloat(), rfloat(), rfloat()) end

DECODE[T_COL] = function()
    local r, g, b, a = byte(S, pos, pos + 3)
    pos = pos + 4

    return setmetatable({r = r + 0, g = g + 0, b = b + 0, a = a + 0}, COLOR)
end

DECODE[T_ENT] = function()
    local index = ruint(2)

    return index == 0 and NULL or Entity(index - 1)
end

rvalue = function()
    local b = byte(S, pos)
    pos = pos + 1

    if b < 128 then return b end
    if b < 160 then return rstring(b - 128) end
    if b < 192 then return rtable(b - 160) end
    if b >= 224 then return b - 256 end
    if b == T_TRUE then return true end
    if b == T_FALSE then return false end

    local read = DECODE[b]
    if not read then fail("tag " .. b) end

    return read()
end

-- Returns the arguments as a table and their count.
local function decode(data)
    S, pos, slen = data, 1, #data
    nrefs, ddepth = 0, 0

    if byte(S, 1) ~= FORMAT then fail("format") end

    pos = 2

    local count = rvar()
    if count > slen then fail("argument count") end

    local args = {}

    for i = 1, count do args[i] = rvalue() end

    if pos <= slen then fail("trailing bytes") end

    -- Let the payload and its strings be collected.
    S = ""
    for i = 1, nrefs do R[i] = nil end

    return args, count
end

-- The native edition: on a server with gmsv_xnet installed, encoding runs in
-- Rust. It writes the same bytes, so clients keep decoding in Lua.
if SERVER and not XNetNative and util.IsBinaryModuleInstalled and util.IsBinaryModuleInstalled("xnet") then
    pcall(require, "xnet")
end

-- TryPack (0.4 and later) returns nil and the error instead of raising
-- one; every call is followed by `checked`. An older module's Pack raises
-- by itself.
local nativePack = SERVER and XNetNative and XNetNative.Format == FORMAT and (XNetNative.TryPack or XNetNative.Pack) or nil

local function checked(s, err)
    if s == nil then error(err, 0) end

    return s
end

-- Batch buffers kept by the module (0.3 and later): messages are encoded
-- into them directly, with no string per message.
local nativeBatch = nativePack and XNetNative.Batch or nil
local nativeTake = nativeBatch and XNetNative.Take or nil
local nativeDrop = nativeBatch and XNetNative.Drop or nil

XNet.Native = nativePack and true or false

function XNet.Encode(...)
    if nativePack then return checked(nativePack(-1, 0, Config.MaxDepth, ...)) end

    return encode(nil, nil, select("#", ...), ...)
end

function XNet.Decode(data)
    local args, count = decode(data)

    return unpack(args, 1, count)
end

--------------------------------------------------------------------------------
-- Transport
--
--     One net message is a run of whole bytes:
--
--     byte 1   kind in bits 0-1: 0 whole message, 1 first chunk, 2 next
--              chunk, 3 confirm; compressed flag in bit 2; "confirm now" in
--              bit 3; the high 4 bits of the name id in bits 4-7
--     whole    byte 2: low 8 bits of the name id (a pooled network string;
--              id 0 means a length byte and the name follow), then the payload
--     first    as whole, then the total size (4 bytes), then a chunk
--     next     a chunk
--     confirm  bytes received since the last confirm (3 bytes)
--
--     A small message is therefore one string, written with one net.WriteData
--     and read with one net.ReadData.
--
--     Every message but a confirm counts toward the sender's window. The
--     receiver confirms what it has received when a message asks it to (bit
--     3, or any chunk); the sender asks every REQUEST_EVERY bytes. So a flood
--     of small messages is paced to the link like a big one, instead of
--     overflowing the player's reliable buffer, and costs one 4-byte reply per
--     8 KB.
--
--     Chunks of one message are sent back to back with nothing in between,
--     and the channel is reliable and ordered, so the receiver needs only one
--     transfer per sender and no ids.
--------------------------------------------------------------------------------

local KIND_WHOLE, KIND_FIRST, KIND_MORE, KIND_CONFIRM = 0, 1, 2, 3
local COMPRESSED, ASK = 4, 8
local REQUEST_EVERY = 8192
local MORE_HEADER = char(KIND_MORE)

-- net is indexed at call time, so anything that wraps net.Start or net.Send
-- (loggers, monitors) still sees XNet's messages.
local net = net

local nameIds = {}                  -- name -> pooled id, once it is known
local head0, head1 = {}, {}         -- name -> the two header bytes of a whole message

-- Clients learn a newly pooled string a moment after the server does, so
-- for a few seconds after XNet pools a name its messages carry the name
-- itself (id 0) instead of an id the client can't resolve yet.
local FRESH_FOR = 5
local fresh = {}                    -- name -> when this server pooled it

local function nameId(name)
    local id = nameIds[name]
    if id then return id end

    if SERVER and util.NetworkStringToID(name) == 0 then
        util.AddNetworkString(name)
        fresh[name] = SysTime()
    end

    local pooledAt = fresh[name]

    if pooledAt then
        if SysTime() - pooledAt < FRESH_FOR then return 0 end
        fresh[name] = nil
    end

    id = util.NetworkStringToID(name)

    -- Clients only learn new pooled strings with a delay; don't cache a miss.
    if id ~= 0 then
        nameIds[name] = id
        head0[name] = rshift(id, 8) * 16
        head1[name] = band(id, 255)
    end

    return id
end

local function header(kind, name, compressed, ask)
    local id = nameId(name)
    local b0 = kind + (compressed and COMPRESSED or 0) + (ask and ASK or 0) + rshift(id, 8) * 16

    if id ~= 0 then return char(b0, band(id, 255)) end

    return char(b0, 0, #name) .. name
end

local function uint32(v)
    return char(band(v, 255), band(rshift(v, 8), 255), band(rshift(v, 16), 255), rshift(v, 24))
end

-- Compresses a payload when that pays off; the result is shared by every
-- recipient.
local function pack(name, data)
    local compressed = false
    local size = #data
    local worth = size >= Config.CompressAt

    -- LZMA costs milliseconds on the server even for small inputs, and a
    -- message under 32 KB crosses the link in one burst anyway, so only
    -- bigger ones are compressed, and only when a 4 KB sample from the
    -- middle shrinks by at least 15%: random floats, already compressed or
    -- binary data skip the pass.
    if worth then
        local mid = floor(size / 2)
        local sample = sub(data, mid - 2047, mid + 2048)
        local packedSample = util.Compress(sample)

        worth = packedSample ~= nil and #packedSample < #sample * 0.85
    end

    if worth then
        local packed = util.Compress(data)

        if packed and #packed < #data * 0.9 then
            data = packed
            compressed = true
        end
    end

    return {name = name, data = data, compressed = compressed}
end

local function finish(target)
    if SERVER then net.Send(target) else net.SendToServer() end
end

-- The window follows how fast this side may send split packets: big enough
-- to keep the link busy, small enough not to queue seconds of data in the
-- engine (which delays every other addon's messages behind it). Both are
-- cached and refreshed when the cvar changes (and whenever a message is
-- queued), so a send never pays for a convar read.
local splitRate = GetConVar("net_splitpacket_maxrate")
local window, chunk = 65536, 16384

local function resize()
    local w = Config.Window

    if not w then
        local rate = splitRate and splitRate:GetFloat() or 0
        w = rate > 0 and math.Clamp(floor(rate * 0.2), 32768, 196608) or 65536
    end

    window = w
    chunk = Config.ChunkSize or math.Clamp(floor(w / 4), 8192, 32768)
end

resize()
cvars.AddChangeCallback("net_splitpacket_maxrate", function() resize() end, "XNet")

-- Outgoing state per receiver: messages waiting their turn, how many bytes
-- are sent but not yet confirmed, and how many since the last request.
local peers = {}
local SERVER_PEER = "server"

-- Native batch slots: one per player, reused after they leave.
local freeSlots, nextSlot = {}, 0

local function takeSlot()
    local n = #freeSlots
    local slot

    if n > 0 then
        slot = freeSlots[n]
        freeSlots[n] = nil
    else
        nextSlot = nextSlot + 1
        slot = nextSlot
    end

    -- Whatever an earlier load of this file left there is not ours.
    nativeDrop(slot)

    return slot
end

local function peerState(peer)
    local st = peers[peer]

    if not st then
        st = {peer = peer, queue = {}, head = 1, tail = 0, queued = 0, unconfirmed = 0, since = 0, progress = SysTime(),
            parts = {}, nparts = 0, batched = 0, slot = nativeBatch and peer ~= SERVER_PEER and takeSlot() or nil}
        peers[peer] = st
    end

    return st
end

-- Records a message of `size` bytes going to a peer. `ask` is whether it
-- carries the confirm request.
local function sent(st, size, ask)
    if st.unconfirmed == 0 then st.progress = SysTime() end

    st.unconfirmed = st.unconfirmed + size
    st.since = ask and 0 or st.since + size
end

-- Sends the next piece of the message at the head of a peer's queue.
local function sendNext(st)
    local msg = st.queue[st.head]
    local data = msg.data
    local total = #data
    local offset = msg.offset or 0
    local size, bytes, ask

    net.Start(CHANNEL)

    if offset == 0 and total <= chunk then
        size = total
        ask = st.since + total >= REQUEST_EVERY

        local h = header(KIND_WHOLE, msg.name, msg.compressed, ask)

        bytes = #h + total
        net.WriteData(h, #h)
        net.WriteData(data, total)
    else
        size = total - offset
        if size > chunk then size = chunk end

        ask = true

        if offset == 0 then
            local h = header(KIND_FIRST, msg.name, msg.compressed) .. uint32(total)

            bytes = #h + size
            net.WriteData(h, #h)
        else
            bytes = 1 + size
            net.WriteData(MORE_HEADER, 1)
        end

        net.WriteData(sub(data, offset + 1, offset + size), size)
    end

    finish(st.peer)

    offset = offset + size

    if offset >= total then
        st.queue[st.head] = nil
        st.head = st.head + 1
    else
        msg.offset = offset
    end

    st.queued = st.queued - size

    sent(st, bytes, ask)
end

local stallTimer = false
local checkStalls

-- Sends from the head of the queue for as long as the window allows.
local function pump(st)
    while st.head <= st.tail and st.unconfirmed < window do sendNext(st) end

    if st.head <= st.tail and not stallTimer then
        stallTimer = true
        timer.Create("XNet.Stall", 2, 0, checkStalls)
    end
end

-- A receiver that stops confirming (it left, or never loaded XNet) would
-- hold its queue forever; after StallTimeout without progress the window
-- reopens.
checkStalls = function()
    local now = SysTime()
    local waiting = false

    for peer, st in next, peers do
        if SERVER and not IsValid(peer) then
            peers[peer] = nil
        elseif st.head <= st.tail then
            if st.unconfirmed > 0 and now - st.progress > Config.StallTimeout then
                st.unconfirmed = 0
                pump(st)
            end

            if st.head <= st.tail then waiting = true end
        end
    end

    if not waiting then
        stallTimer = false
        timer.Remove("XNet.Stall")
    end
end

local function enqueue(peer, msg)
    local st = peerState(peer)
    local size = #msg.data

    if st.queued + size > Config.MaxQueued then
        ErrorNoHaltWithStack("[XNet] " .. tostring(peer) .. " has " .. st.queued .. " bytes waiting; '" .. msg.name .. "' was dropped\n")
        return
    end

    resize()

    -- Each receiver keeps its own place in a message (the data is shared).
    st.tail = st.tail + 1
    st.queue[st.tail] = {name = msg.name, data = msg.data, compressed = msg.compressed}
    st.queued = st.queued + size

    if st.head == st.tail then pump(st) end
end

local function confirmed(peer, bytes)
    local st = peers[peer]
    if not st then return end

    local left = st.unconfirmed - bytes
    st.unconfirmed = left > 0 and left or 0
    st.progress = SysTime()

    if st.head <= st.tail then pump(st) end
end

-- Writes a message that fits in one net message, for any number of receivers.
local function sendWhole(msg, ask, target)
    local h = header(KIND_WHOLE, msg.name, msg.compressed, ask)
    local data = msg.data

    net.Start(CHANNEL)
    net.WriteData(h, #h)
    net.WriteData(data, #data)

    if SERVER then net.Send(target) else net.SendToServer() end

    return #h + #data
end

-- One receiver.
local function dispatchOne(peer, msg)
    local size = #msg.data

    if size <= chunk then
        local st = peers[peer] or peerState(peer)

        if st.head > st.tail and st.unconfirmed < window then
            local ask = st.since + size >= REQUEST_EVERY

            sent(st, sendWhole(msg, ask, peer), ask)

            return
        end
    end

    enqueue(peer, msg)
end

-- A message that fits in one net message goes to every receiver with nothing
-- queued and room in its window in a single net.Send; the rest get it queued
-- behind what they have.
local function dispatch(targets, msg)
    local size = #msg.data

    if size > chunk then
        for i = 1, #targets do enqueue(targets[i], msg) end
        return
    end

    local direct, nd, ask = {}, 0, false

    for i = 1, #targets do
        local peer = targets[i]
        local st = peers[peer] or peerState(peer)

        if st.head > st.tail and st.unconfirmed < window then
            nd = nd + 1
            direct[nd] = st

            if st.since + size >= REQUEST_EVERY then ask = true end
        else
            enqueue(peer, msg)
        end
    end

    if nd == 0 then return end

    -- One write for all of them. A receiver that didn't need to be asked
    -- just confirms early.
    for i = 1, nd do direct[i] = direct[i].peer end

    local bytes = sendWhole(msg, ask, direct)

    for i = 1, nd do sent(peers[direct[i]], bytes, ask) end
end

-- Tells the sender these bytes arrived, so it can send more.
local function confirm(peer, bytes)
    net.Start(CHANNEL)
    net.WriteData(char(KIND_CONFIRM, band(bytes, 255), band(rshift(bytes, 8), 255), band(rshift(bytes, 16), 255)), 4)
    finish(peer)
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

local incoming = {}                 -- peer -> transfer being assembled
local received = {}                 -- peer -> bytes since the last confirm
local limits = {}                   -- ply -> name -> {tokens, last}
local byId = {}                     -- pooled id -> handler

local function reject(ply, name, reason)
    if SERVER then hook.Run("XNet.Rejected", ply, name, reason) end
end

local function reportError(err)
    ErrorNoHaltWithStack("[XNet] " .. tostring(err) .. "\n")
end

-- Server: is this player allowed another message under this name now?
local function allowed(ply, name, handler)
    local rate = handler.rate
    if rate == 0 then return true end

    rate = rate or Config.ClientRate

    local burst = handler.burst or Config.ClientBurst
    local byName = limits[ply]

    if not byName then
        byName = {}
        limits[ply] = byName
    end

    local bucket = byName[name]
    local now = SysTime()

    if not bucket then
        bucket = {tokens = burst, last = now}
        byName[name] = bucket
    end

    local tokens = bucket.tokens + (now - bucket.last) * rate
    if tokens > burst then tokens = burst end

    bucket.last = now

    if tokens < 1 then
        bucket.tokens = tokens
        return false
    end

    bucket.tokens = tokens - 1

    return true
end

-- Server: checks a new message from a client before anything is buffered.
local function accept(ply, handler, name, size)
    if not handler then
        reject(ply, name, "unknown name")
        return false
    end

    if size > (handler.maxBytes or Config.ClientMaxBytes) then
        reject(ply, name, "too big")
        return false
    end

    if not allowed(ply, name, handler) then
        reject(ply, name, "rate limit")
        return false
    end

    return true
end

-- Decoding and the handler run under one xpcall. `stage` tells the error
-- handler which of the two failed: a bad payload is the sender's fault, an
-- error in the handler is reported with its stack.
local runHandler, runPeer, stage, decodeError

-- A batch (several messages in one net message) is read message by message:
-- bS/bLen are the batch, bPos where the next message starts.
local batching, bS, bPos, bLen = false, "", 1, 0

local function onError(err)
    if stage == 0 then
        decodeError = err
    else
        reportError(err)
    end
end

-- Decodes the arguments at S[pos..] and calls the handler with them. Up to
-- four arguments go straight from the decoder into the call.
-- The end of a message's arguments: alone, nothing may follow them; in a
-- batch, the next message starts there. Then the payload is let go before
-- the handler runs (it may decode something of its own).
local function done()
    if batching then
        bPos = pos
    elseif pos <= slen then
        fail("trailing bytes")
    end

    S, stage = "", 1
    for i = 1, nrefs do R[i] = nil end
end

local function run()
    if byte(S, pos) ~= FORMAT then fail("format") end

    local count = byte(S, pos + 1)

    if count < 128 then
        pos = pos + 2
    else
        pos = pos + 1
        count = rvar()

        if count > slen then fail("argument count") end
    end

    local callback, peer = runHandler.callback, runPeer

    if count == 0 then
        done()

        if SERVER then return callback(peer) end
        return callback()
    elseif count == 1 then
        local a = rvalue()

        done()

        if SERVER then return callback(peer, a) end
        return callback(a)
    elseif count == 2 then
        local a = rvalue()
        local b = rvalue()

        done()

        if SERVER then return callback(peer, a, b) end
        return callback(a, b)
    elseif count == 3 then
        local a = rvalue()
        local b = rvalue()
        local c = rvalue()

        done()

        if SERVER then return callback(peer, a, b, c) end
        return callback(a, b, c)
    elseif count == 4 then
        local a = rvalue()
        local b = rvalue()
        local c = rvalue()
        local d = rvalue()

        done()

        if SERVER then return callback(peer, a, b, c, d) end
        return callback(a, b, c, d)
    end

    local args = {}

    for i = 1, count do args[i] = rvalue() end

    done()

    if SERVER then return callback(peer, unpack(args, 1, count)) end
    return callback(unpack(args, 1, count))
end

-- Decodes the payload that starts at data[start] and hands it to the handler.
local function deliver(handler, peer, data, start)
    S, pos, slen = data, start, #data
    nrefs, ddepth = 0, 0
    runHandler, runPeer, stage = handler, peer, 0

    if xpcall(run, onError) or stage ~= 0 then return end

    -- The payload was bad. Let it and its strings be collected.
    S = ""
    for i = 1, nrefs do R[i] = nil end

    if SERVER then
        reject(peer, handler.name, decodeError)
    else
        reportError(decodeError)
    end
end

-- The handler for a pooled name id, and the name.
local function handlerFor(id)
    local handler = byId[id]
    if handler then return handler, handler.name end

    local name = util.NetworkIDToString(id)

    handler = name and Handlers[name]
    if handler then byId[id] = handler end

    return handler, name or "?"
end

-- Messages without a handler here are still decoded, to find the next one.
local IGNORE = {callback = function() end}

-- Reads the messages of a batch in order. Each one is its two header bytes
-- (a pooled name id, nothing else set) and its payload.
local function runBatch()
    while bPos <= bLen do
        S, pos, slen = bS, bPos, bLen
        nrefs, ddepth, stage = 0, 0, 0

        local h0, h1 = byte(S, pos, pos + 1)
        if not h1 or band(h0, 15) ~= 0 then fail("batch") end

        local id = rshift(h0, 4) * 256 + h1
        if id == 0 then fail("batch") end

        pos = pos + 2
        runHandler = handlerFor(id) or IGNORE

        run()
    end
end

-- Runs a batch. An error in one handler is reported and the next message
-- still runs; a bad payload ends the batch, as nothing after it can be
-- found.
local function deliverBatch(peer, data, start)
    bS, bPos, bLen = data, start, #data
    runPeer, batching = peer, true

    while not xpcall(runBatch, onError) do
        if stage == 0 then
            reportError(decodeError)
            break
        end
    end

    batching, bS, S = false, "", ""
    for i = 1, nrefs do R[i] = nil end
end

local function decompress(handler, peer, data)
    local out = util.Decompress(data, SERVER and (handler.maxBytes or Config.ClientMaxBytes) or nil)

    if not out then reject(peer, handler.name, "decompress") end

    return out
end

-- The handler and name of a whole or first message, and where its body
-- starts.
local function resolve(s, b0)
    local id = rshift(b0, 4) * 256 + (byte(s, 2) or 0)

    if id ~= 0 then
        local handler, name = handlerFor(id)

        return handler, name, 3
    end

    local n = byte(s, 3) or 0
    local name = sub(s, 4, 3 + n)

    return Handlers[name], name, 4 + n
end

net.Receive(CHANNEL, function(len, ply)
    local peer = SERVER and ply or SERVER_PEER
    if SERVER and not IsValid(ply) then return end

    local s = net.ReadData(len / 8)
    local b0 = byte(s, 1)
    if not b0 then return end

    local kind = band(b0, 3)

    if kind == KIND_CONFIRM then
        local b1, b2, b3 = byte(s, 2, 4)

        if b3 then confirmed(peer, b1 + b2 * 256 + b3 * 65536) end

        return
    end

    -- Everything else counts toward the sender's window, and is confirmed
    -- (with whatever came before it) when the sender asks.
    local got = (received[peer] or 0) + #s

    if kind ~= KIND_WHOLE or band(b0, ASK) ~= 0 then
        confirm(peer, got)
        got = 0
    end

    received[peer] = got

    if kind == KIND_WHOLE then
        -- Name id 0 with an empty name: a batch.
        if b0 < 16 and byte(s, 2) == 0 and byte(s, 3) == 0 then
            if incoming[peer] then incoming[peer] = nil end

            -- Only the server batches.
            if SERVER then
                reject(ply, "?", "batch")
            else
                deliverBatch(peer, s, 4)
            end

            return
        end

        local handler, name, start = resolve(s, b0)
        local size = #s - start + 1

        -- A new message while a transfer is unfinished: the old one is over.
        if incoming[peer] then
            if SERVER then reject(ply, incoming[peer].name, "interrupted") end
            incoming[peer] = nil
        end

        if SERVER then
            if not accept(ply, handler, name, size) then return end
        elseif not handler then
            return
        end

        if band(b0, COMPRESSED) ~= 0 then
            local data = decompress(handler, peer, sub(s, start))

            if data then deliver(handler, peer, data, 1) end
        else
            deliver(handler, peer, s, start)
        end

        return
    end

    if kind == KIND_MORE then
        local transfer = incoming[peer]
        local size = #s - 1

        if not transfer then return end

        local total = transfer.got + size

        if total > transfer.total then
            incoming[peer] = nil
            reject(ply, transfer.name, "chunk overrun")
            return
        end

        transfer.got = total
        transfer.at = SysTime()

        if transfer.parts then
            transfer.n = transfer.n + 1
            transfer.parts[transfer.n] = sub(s, 2)
        end

        if total == transfer.total then
            incoming[peer] = nil

            local handler = transfer.parts and Handlers[transfer.name]

            if handler then
                local data = concat(transfer.parts, "", 1, transfer.n)

                if transfer.compressed then data = decompress(handler, peer, data) end
                if data then deliver(handler, peer, data, 1) end
            end
        end

        return
    end

    -- The first chunk of a bigger message.
    local handler, name, start = resolve(s, b0)
    local t1, t2, t3, t4 = byte(s, start, start + 3)
    if not t4 then return end

    local total = t1 + t2 * 256 + t3 * 65536 + t4 * 16777216
    local size = #s - start - 3

    if incoming[peer] then
        if SERVER then reject(ply, incoming[peer].name, "interrupted") end
        incoming[peer] = nil
    end

    if size > total then return end

    -- A refused transfer is still followed through, without keeping its
    -- bytes, so its remaining chunks are recognised and dropped.
    local keep

    if SERVER then
        keep = accept(ply, handler, name, total)
    else
        keep = handler ~= nil
    end

    local transfer = {name = name, compressed = band(b0, COMPRESSED) ~= 0, total = total, got = size, at = SysTime(), n = 0}

    if keep then
        transfer.parts = {sub(s, start + 4)}
        transfer.n = 1
    end

    if size == total then
        if keep then
            local data = transfer.parts[1]

            if transfer.compressed then data = decompress(handler, peer, data) end
            if data then deliver(handler, peer, data, 1) end
        end

        return
    end

    incoming[peer] = transfer
end)

if SERVER then
    hook.Add("PlayerDisconnected", "XNet", function(ply)
        local st = peers[ply]

        if st then
            -- A pending batch for them is dropped.
            st.nparts, st.batched = 0, 0

            if st.slot then
                nativeDrop(st.slot)
                freeSlots[#freeSlots + 1] = st.slot
                st.slot = nil
            end
        end

        peers[ply] = nil
        incoming[ply] = nil
        received[ply] = nil
        limits[ply] = nil
    end)

    -- Drop transfers that stopped arriving.
    timer.Create("XNet.Stale", 5, 0, function()
        local cutoff = SysTime() - Config.Timeout

        for peer, transfer in next, incoming do
            if transfer.at < cutoff then
                incoming[peer] = nil
                reject(peer, transfer.name, "timed out")
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

function XNet.Receive(name, callback, options)
    if #name > 255 or name == "" then error("XNet: a message name must be 1 to 255 characters", 2) end

    options = options or {}

    Handlers[name] = {
        name = name,
        callback = callback,
        maxBytes = options.maxBytes,
        rate = options.rate,
        burst = options.burst,
    }

    for id in next, byId do byId[id] = nil end

    -- Pool the name so it travels as a 12-bit id.
    if SERVER then nameId(name) end
end

-- The payload alone, for the paths that compress, chunk or queue it.
local function payload(...)
    if nativePack then return checked(nativePack(-1, 0, Config.MaxDepth, ...)) end

    return encode(nil, nil, select("#", ...), ...)
end

-- A message that is ready to send as it is: its two header bytes and the
-- payload in one string. Only for names with a pooled id.
local function message(h0, h1, ...)
    if nativePack then return checked(nativePack(h0, h1, Config.MaxDepth, ...)) end

    return encode(h0, h1, select("#", ...), ...)
end

-- The usual case: one receiver with nothing queued and room in its window,
-- a pooled name, and a message small enough to go out as it is. One encode
-- straight into the finished message, then three net calls. Returns false
-- to take the general path.
local function sendDirect(st, name, target, ...)
    local h0 = head0[name]
    if not h0 or st.head <= st.tail or st.unconfirmed >= window then return false end

    local ask = st.since >= REQUEST_EVERY
    local s = message(ask and h0 + ASK or h0, head1[name], ...)
    local size = #s

    if size > chunk then
        dispatchOne(st.peer, pack(name, sub(s, 3)))
        return true
    end

    net.Start(CHANNEL)
    net.WriteData(s, size)

    if SERVER then net.Send(target) else net.SendToServer() end

    sent(st, size, ask)

    return true
end

if SERVER then
    local player_GetHumans = player.GetHumans

    ----------------------------------------------------------------------------
    -- Batching
    --
    --     The engine charges for every net message: net.Start and net.Send
    --     cost more than encoding a small message, and each one carries its
    --     own header on the wire. So the small messages one player gets
    --     during a frame are joined into one net message:
    --
    --         byte 1   0, or ASK      bytes 2-3   0 0 (no name: a batch)
    --         then each message as its two header bytes and payload
    --
    --     A server frame runs: incoming messages, Think, timers, Tick,
    --     entity and player thinks, then the engine sends packets. Batches
    --     are written in the Tick hook, so what was sent before it leaves in
    --     the same packets it would have anyway. After Tick, until the next
    --     frame (FrameNumber moves on before incoming messages), sends go
    --     out directly. Nothing waits a frame.
    --
    --     Order is kept with every other net message: anything that starts
    --     one (net.Start, from any addon) writes the pending batches first.
    ----------------------------------------------------------------------------

    local FrameNumber = FrameNumber
    local pending, npending = {}, 0     -- peers with a batch, in order
    local closed, closedFrame = false, -1
    local BATCH, BATCH_ASK = char(0, 0, 0), char(ASK, 0, 0)

    -- Writes a player's batch. Its bytes count toward the window from here,
    -- as if its messages had been sent one by one.
    local function writeBatch(st)
        local n = st.nparts
        local parts = st.parts
        local bytes = st.batched
        local since = st.since + bytes
        local ask = since >= REQUEST_EVERY
        local data

        local alone = n == 1 and not ask

        -- Alone, a message goes as a plain message, without the batch bytes.
        if alone then
            bytes = bytes - 3
            since = since - 3
        end

        if st.slot then
            data = nativeTake(st.slot, alone and -1 or ask and ASK or 0)
        else
            if alone then
                data = parts[1]
            else
                data = (ask and BATCH_ASK or BATCH) .. concat(parts, "", 1, n)
            end

            for i = 1, n do parts[i] = nil end
        end

        st.nparts, st.batched = 0, 0

        local peer = st.peer
        if not IsValid(peer) then return end

        if st.unconfirmed == 0 then st.progress = SysTime() end

        st.unconfirmed = st.unconfirmed + bytes
        st.since = ask and 0 or since

        net.Start(CHANNEL)
        net.WriteData(data, #data)
        net.Send(peer)
    end

    local function flushBatches()
        XNet.FlushPending = nil

        for i = 1, npending do
            local st = pending[i]
            pending[i] = nil

            if st.nparts > 0 then writeBatch(st) end
        end

        npending = 0
    end

    -- Every net.Start, XNet's own included, first writes what is pending.
    -- Installed once; the hook looks the flush up each call, so a reloaded
    -- XNet keeps working through the same wrapper.
    if not XNet.StartWrapper then
        local start = net.Start

        XNet.StartWrapper = function(...)
            local flush = XNet.FlushPending
            if flush then flush() end

            return start(...)
        end

        net.Start = XNet.StartWrapper
    end

    hook.Add("Tick", "XNet.Batch", function()
        if npending > 0 then flushBatches() end

        closed, closedFrame = true, FrameNumber()
    end)

    -- If a Tick hook before this one ends the chain, batches still leave a
    -- frame later instead of never.
    timer.Create("XNet.Batch", 0, 0, function()
        if npending > 0 then flushBatches() end
    end)

    -- After the Tick hook, a send goes out at once until the frame is over.
    local function reopened()
        if FrameNumber() == closedFrame then return false end

        closed = false

        return true
    end

    -- The batched path is written out in full here: it runs for nearly every
    -- message, and each extra vararg call costs about as much as the rest.
    function XNet.Send(target, name, ...)
        local st = peers[target]

        if st then
            local h0 = head0[name]

            -- Same conditions as sendDirect: a pooled name, nothing queued,
            -- room in the window (counting what is batched).
            if h0 and st.head > st.tail and Config.Batch ~= false then
                local batched = st.batched

                if st.unconfirmed + batched < window and (not closed or reopened()) then
                    local n = st.nparts
                    local slot = st.slot
                    local size, s, err

                    if slot then
                        -- Straight into the player's buffer, if it fits.
                        size, err = nativeBatch(slot, h0, head1[name], Config.MaxDepth, n > 0 and chunk - batched or chunk - 3, ...)
                        if size == nil then error(err, 0) end

                        if size < 0 then
                            if n == 0 or -size > chunk - 3 then
                                -- Too big for any batch.
                                dispatchOne(target, pack(name, checked(nativePack(-1, 0, Config.MaxDepth, ...))))
                                return
                            end

                            -- The batch is full: it goes now, with everything
                            -- pending before it, and this starts the next.
                            flushBatches()
                            n = 0
                            size = checked(nativeBatch(slot, h0, head1[name], Config.MaxDepth, chunk - 3, ...))

                            if size < 0 then
                                dispatchOne(target, pack(name, checked(nativePack(-1, 0, Config.MaxDepth, ...))))
                                return
                            end
                        end
                    else
                        if nativePack then
                            s, err = nativePack(h0, head1[name], Config.MaxDepth, ...)
                            if s == nil then error(err, 0) end
                        else
                            s = encode(h0, head1[name], select("#", ...), ...)
                        end

                        size = #s

                        if n > 0 and batched + size > chunk then
                            flushBatches()
                            n = 0
                        end

                        if n == 0 and size > chunk - 3 then
                            dispatchOne(target, pack(name, sub(s, 3)))
                            return
                        end

                        st.parts[n + 1] = s
                    end

                    if n == 0 then
                        npending = npending + 1
                        pending[npending] = st
                        XNet.FlushPending = flushBatches
                        batched = 3
                    end

                    st.nparts = n + 1
                    st.batched = batched + size

                    return
                end
            end

            if sendDirect(st, name, target, ...) then return end
        end

        local targets

        if target == nil then
            targets = player_GetHumans()
        elseif type(target) == "table" then
            targets = {}

            for i = 1, #target do
                if IsValid(target[i]) then targets[#targets + 1] = target[i] end
            end
        elseif IsValid(target) then
            nameId(name)

            return dispatchOne(target, pack(name, payload(...)))
        else
            return
        end

        nameId(name)

        local msg = pack(name, payload(...))

        if #targets > 0 then dispatch(targets, msg) end
    end

    function XNet.Broadcast(name, ...)
        nameId(name)

        local targets = player_GetHumans()

        if #targets > 0 then dispatch(targets, pack(name, payload(...))) end
    end
else
    local st = peerState(SERVER_PEER)

    function XNet.Send(name, ...)
        if not head0[name] then nameId(name) end
        if sendDirect(st, name, nil, ...) then return end

        dispatchOne(SERVER_PEER, pack(name, payload(...)))
    end
end

function XNet.Queued(ply)
    local st = peers[SERVER and ply or SERVER_PEER]

    return st and st.queued or 0
end
