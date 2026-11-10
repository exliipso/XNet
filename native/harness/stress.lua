-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 exliipso
-- Originally developed by exliipso

-- The native encoder must agree with the Lua encoder on everything: the same
-- bytes when a value can be sent, the same error when it can't.

math.randomseed(1234)

local function randValue(depth)
    local r = math.random(1, 10)

    if depth > 0 and r <= 4 then
        local t = {}

        for i = 1, math.random(0, 5) do t[i] = randValue(depth - 1) end
        for i = 1, math.random(0, 4) do t["k" .. math.random(1, 9) .. string.rep("x", math.random(0, 6))] = randValue(depth - 1) end

        return t
    elseif r == 5 then return math.random() * 1e6 - 5e5
    elseif r == 6 then return math.random(-100000, 100000)
    elseif r == 7 then return string.rep(string.char(math.random(65, 90)), math.random(0, 40))
    elseif r == 8 then return math.random() < 0.5
    elseif r == 9 then return Vector(math.random(-100, 100), 0.5, -2)
    else return "str" .. math.random(1, 20) end
end

local function chain(n, key)
    local d = {}
    local c = d

    for i = 1, n do
        c[key] = {}
        c = c[key]
    end

    return d
end

local runs, disagree, examples = 0, 0, {}
local trips, tripFails = 0, 0

-- Deep equality, for checking that decoding gives back what was encoded.
local function same(x, y)
    if type(x) ~= type(y) then return false end

    if type(x) == "number" then return x == y or (x ~= x and y ~= y) end
    if type(x) ~= "table" and type(x) ~= "string" and type(x) ~= "boolean" then return XNL.Encode(x) == XNL.Encode(y) end
    if type(x) ~= "table" then return x == y end

    for k, v in pairs(x) do if not same(v, y[k]) then return false end end
    for k in pairs(y) do if x[k] == nil then return false end end

    return true
end

local function check(desc, ...)
    local okN, a = pcall(XNet.Encode, ...)
    local okL, b = pcall(XNL.Encode, ...)

    runs = runs + 1

    if okN ~= okL or a ~= b then
        disagree = disagree + 1

        if #examples < 8 then
            examples[#examples + 1] = desc .. ": native " .. tostring(okN) .. " " .. tostring(not okN and a or "") .. " / lua " .. tostring(okL) .. " " .. tostring(not okL and b or "")
        end
    end

    -- And the decoder gives back the arguments.
    if okL then
        local n = select("#", ...)
        local back = {pcall(XNL.Decode, b)}
        local ok = back[1] and #back - 1 >= 0

        for i = 1, n do
            if not same((select(i, ...)), back[i + 1]) then ok = false break end
        end

        trips = trips + 1

        if not ok then
            tripFails = tripFails + 1

            if #examples < 8 then
                local function show(v, d)
                    d = d or 0
                    if type(v) ~= "table" or d > 3 then return type(v) .. ":" .. tostring(v) end
                    local o = {}
                    for k, x in pairs(v) do o[#o + 1] = show(k, d + 1) .. "=" .. show(x, d + 1) end
                    return "{" .. table.concat(o, ",") .. "}"
                end
                local w = {}
                for i = 1, n do w[#w + 1] = show((select(i, ...))) .. " => " .. show(back[i + 1]) end
                examples[#examples + 1] = desc .. ": round trip " .. tostring(back[1]) .. " " .. table.concat(w, " ;; ")
            end
        end
    end
end

for i = 1, 6000 do
    local kind = i % 6

    if kind == 0 then
        local n, k = math.random(1, 63), math.random() < 0.5 and "next" or 1
        check("chain " .. n .. " " .. tostring(k), chain(n, k))
    elseif kind == 1 then
        local n = math.random(64, 80)
        check("deep " .. n, chain(n, "n"))
    elseif kind == 2 then
        local v = {inner = randValue(4)}
        v.self = v
        check("cyclic", v)
    else
        check("random", randValue(math.random(1, 6)), randValue(3))
    end
end

-- Fixed values and edges.
for _, v in ipairs({0, 1, 127, 128, 255, 256, 65535, 65536, 2^31 - 1, 2^31, 2^32 - 1, 2^32, 2^53 - 1, 2^53, 2^60, -1, -32, -33, -256, -257,
    -65536, -65537, -2^31, -2^32, -2^53 + 1, -2^53, 0.5, 0.1, -0.1, math.pi, 1e300, -1e300, math.huge, -math.huge, -0.0, 4.9e-324, 123456.789}) do
    check("number " .. tostring(v), v)
end

for i = 1, 3000 do
    check("float", (math.random() - 0.5) * 10 ^ math.random(-30, 30))
    check("int", math.floor((math.random() - 0.5) * 2 ^ math.random(1, 53)))
end

check("no args")
check("nils", nil, nil)
check("trailing nil", 1, nil)
check("strings", "", "abc", "abcd", "abcd", "\0\1\2\255", string.rep("x", 31), string.rep("y", 32), string.rep("z", 300), string.rep("w", 70000))
check("mixed", {1, 2, 3, x = "y", [10] = 10, [-1] = "neg", [1.5] = "float", [true] = "bool"})
check("holes", {1, nil, 3, nil, 5})
check("vector", Vector(1.5, -2.25, 1000.125))
check("angle", Angle(90, -180, 45.5))
check("color", Color(255, 0, 128, 64), Color(1, 2, 3))
check("odd color", Color(1.5, 2, 3))
check("world", Entity(0))
check("entity", Entity(5))
check("null", NULL)
check("function", {f = print})

local big = {}
for i = 1, 300 do big[i] = {id = i, class = "weapon_ak47", name = "AK-47 | Redline", wear = i / 301, stattrak = i % 2 == 0, price = i * 7} end
check("records", big)

-- Tables of every small shape the decoder builds with a constructor, with
-- holes, and with keys of every kind.
for i = 1, 3000 do
    local t = {}
    for j = 1, math.random(0, 6) do if math.random() < 0.8 then t[j] = randValue(1) end end
    for j = 1, math.random(0, 6) do
        local r = math.random(1, 4)
        local k = r == 1 and ("k" .. math.random(1, 5)) or r == 2 and math.random(-3, 12) + (math.random() < 0.2 and 0.5 or 0) or r == 3 and (math.random() < 0.5) or math.random() * 100
        t[k] = randValue(1)
    end
    check("small table", t)
end

return string.format("stress: %d runs, %d disagreements, %d/%d round trips failed%s", runs, disagree, tripFails, trips, #examples > 0 and "\n  " .. table.concat(examples, "\n  ") or "")
