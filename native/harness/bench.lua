-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 exliipso
-- Originally developed by exliipso

-- Hot-path timings of the native module on Garry's Mod's LuaJIT (best of
-- several runs). For comparing builds, not for absolute numbers.

local N = native or XNetNative
local Pack, Batch, Take = N.TryPack or N.Pack, N.Batch, N.Take
local clock = os and os.clock or SysTime

local ply = Entity(3)
local small = {x = 1, y = 2}
local items = {}
for i = 1, 100 do items[i] = {id = i, class = "weapon_ak47", wear = i / 101, st = i % 2 == 0} end
local vec, ang = Vector(1.5, -2.25, 100), Angle(10, 20, 30)

local cases = {
    {"small mixed", function() return Pack(1, 2, 64, 42, "hello world", true, small) end},
    {"one int", function() return Pack(1, 2, 64, 7) end},
    {"entity", function() return Pack(1, 2, 64, ply, 5) end},
    {"vector+angle", function() return Pack(1, 2, 64, vec, ang) end},
    {"100 items", function() return Pack(1, 2, 64, items) end},
}

if Batch then
    cases[#cases + 1] = {"batch small mixed", function(i)
        Batch(9, 1, 2, 64, 1e6, 42, "hello world", true, small)
        if i % 150 == 0 then Take(9, 0) end
    end}
end

local out = {}

for _, case in ipairs(cases) do
    local name, f = case[1], case[2]
    local reps = name == "100 items" and 2000 or 100000
    local best = math.huge

    for run = 1, 7 do
        local t0 = clock()
        for i = 1, reps do f(i) end
        local t = (clock() - t0) / reps * 1e9
        if t < best then best = t end
    end

    out[#out + 1] = string.format("%-18s %8.1f ns", name, best)
end

return "bench (native " .. tostring(N.Version) .. ")\n  " .. table.concat(out, "\n  ")
