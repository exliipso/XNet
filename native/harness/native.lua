-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 exliipso
-- Originally developed by exliipso

-- The native module's own contract: errors, batch buffers, re-entrancy and
-- number bit patterns.

local N = XNetNative
local passed, failed = 0, {}

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed[#failed + 1] = name .. (detail ~= nil and (": " .. tostring(detail)) or "")
    end
end

local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- Errors come back from Try*, and are raised (with the same message) by
-- Pack and Encode.
local s, err = N.TryPack(1, 2, 64, {f = print})
check("TryPack returns the error", s == nil and err == "XNet: cannot send a function", err)

local ok, raised = pcall(N.Pack, 1, 2, 64, {f = print})
check("Pack raises it", not ok and raised == "XNet: cannot send a function", raised)

ok, raised = pcall(N.Encode, 64, coroutine.create(print))
check("Encode raises it", not ok and raised == "XNet: cannot send a thread", raised)

s, err = N.TryPack("x", 2, 64, 1)
check("bad arguments are an error, not a crash", s == nil and err:find("takes numbers", 1, true) ~= nil, err)

local cyclic = {}
cyclic.self = cyclic
s, err = N.TryEncode(64, cyclic)
check("a cycle is an error", s == nil and err == "XNet: a table contains itself", err)

-- An error leaves nothing behind: the next message encodes as if alone.
check("clean after an error", N.Pack(1, 2, 64, "after") == XNL.Encode("after"):gsub("^", "\1\2"), hex(N.Pack(1, 2, 64, "after")))

-- Batch buffers.
N.Drop(7)
check("Batch appends", N.Batch(7, 1, 2, 64, 1e6, "a") == #N.Pack(1, 2, 64, "a"))
N.Batch(7, 1, 2, 64, 1e6, "b")
check("Take with a marker", N.Take(7, 8) == "\8\0\0" .. N.Pack(1, 2, 64, "a") .. N.Pack(1, 2, 64, "b"))
check("Take empties", N.Take(7, 0) == "")

local size
size, err = N.Batch(7, 1, 2, 64, 1e6, {f = print})
check("Batch returns the error", size == nil and err == "XNet: cannot send a function", err)
check("and keeps nothing", N.Take(7, -1) == "")

check("room is respected", N.Batch(7, 1, 2, 64, 3, "too long") < 0 and N.Take(7, -1) == "")

size, err = N.Batch(0, 1, 2, 64, 1e6, 1)
check("slot 0 is refused", size == nil, err)
size, err = N.Batch(65536, 1, 2, 64, 1e6, 1)
check("slot 65536 is refused", size == nil, err)

-- A Batch from Lua the encoder runs (an entity check) is refused, and the
-- outer batch is intact.
N.Batch(7, 1, 2, 64, 1e6, "first")

local inner
local realIsValid = IsValid
IsValid = function(v)
    inner = {N.Batch(7, 1, 2, 64, 1e6, "inner")}
    return realIsValid(v)
end

size = N.Batch(7, 1, 2, 64, 1e6, Entity(3))
IsValid = realIsValid

check("re-entrant Batch is refused", inner and inner[1] == nil and tostring(inner[2]):find("while a batch", 1, true) ~= nil, inner and inner[2])
check("outer batch intact", size and size > 0 and N.Take(7, -1) == N.Pack(1, 2, 64, "first") .. N.Pack(1, 2, 64, Entity(3)))

-- An entity check that raises is an error, not a crash.
IsValid = function() error("broken IsValid") end
s, err = N.TryEncode(64, Entity(3))
IsValid = realIsValid
check("a raising entity check", s == nil and err == "XNet: could not read an entity", err)

-- Number bit patterns survive exactly.
local function bits(x)
    local e = N.Encode(64, x)
    return hex(e)
end

local negzero = XNL.Decode(N.Encode(64, -0.0))
check("-0 keeps its sign", negzero == 0 and 1 / negzero == -math.huge, bits(-0.0))
check("+0 is one byte", bits(0) == "010100")

local nan = XNL.Decode(N.Encode(64, 0 / 0))
check("NaN", nan ~= nan)
check("inf", XNL.Decode(N.Encode(64, math.huge)) == math.huge and XNL.Decode(N.Encode(64, -math.huge)) == -math.huge)

for _, v in ipairs({4.9e-324, 2.2250738585072009e-308, 2.2250738585072014e-308, 1.7976931348623157e308, 2^53 - 1, 2^53, -2^53, 2^53 + 2, 0.1, -1 / 3}) do
    check("exact " .. v, XNL.Decode(N.Encode(64, v)) == v and N.Encode(64, v) == XNL.Encode(v), bits(v))
end

check("2^53 - 1 is an integer", bits(2^53 - 1):sub(1, 6) == "0101c6")
check("2^53 is a double", bits(2^53):sub(1, 6) == "0101cb")

return string.format("native: %d passed, %d failed%s", passed, #failed, #failed > 0 and "\n  " .. table.concat(failed, "\n  ") or "")
