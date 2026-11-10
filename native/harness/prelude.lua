-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 exliipso
-- Originally developed by exliipso

-- Enough of Garry's Mod for xnet.lua to run in a bare Lua state: the engine
-- types, and a fake `net` that carries messages between one server-side copy
-- of XNet and any number of client-side copies.
--
--   World.server            the server side: .XNet, .env
--   World.newClient()       a client side: .XNet, .env, .ply (its Player on the server)
--   World.pump()            delivers queued net messages until none are left
--   World.sent              every net message sent, oldest first
--   XNet, XNL               server-side encoders: native, and pure Lua

local sub, concat = string.sub, table.concat

NULL = newproxy(true)
getmetatable(NULL).MetaName = "Entity"
getmetatable(NULL).__index = {IsValid = function() return false end, EntIndex = function() return -1 end}

function AddCSLuaFile() end
function IsValid(v) return v ~= nil and v.IsValid ~= nil and v:IsValid() end

SysTime = os.clock
math.Clamp = function(v, lo, hi) return v < lo and lo or v > hi and hi or v end

local registry = {}

-- Color: a table whose metatable is the registry's "Color".
local COLOR = {}
COLOR.__index = COLOR
registry.Color = COLOR
SET_REGISTRY("Color", COLOR)

function Color(r, g, b, a) return setmetatable({r = r, g = g, b = b, a = a or 255}, COLOR) end
function FindMetaTable(name) return registry[name] end

-- Vector, Angle, Entity, Player: userdata with MetaName and methods, like
-- the engine's (but not the engine's memory layout, so the native module
-- reads these through Lua, its fallback path).
local function userdataType(name, methods)
    return function(...)
        local u = newproxy(true)
        local mt = getmetatable(u)
        local fields = {...}

        mt.MetaName = name
        mt.fields = fields
        mt.__index = function(_, k)
            if methods[k] then return methods[k] end
            return fields[methods.__names[k]]
        end
        mt.__eq = function(a, b)
            local fa, fb = getmetatable(a).fields, getmetatable(b).fields
            return fa[1] == fb[1] and fa[2] == fb[2] and fa[3] == fb[3]
        end

        return u
    end
end

local function fieldsOf(u) return getmetatable(u).fields end
local function unpack3(u) local f = fieldsOf(u) return f[1], f[2], f[3] end

Vector = userdataType("Vector", {__names = {x = 1, y = 2, z = 3}, Unpack = unpack3})
Angle = userdataType("Angle", {__names = {p = 1, y = 2, r = 3}, Unpack = unpack3})

local entities = {}

local function entity(index, kind)
    if entities[index] then return entities[index] end

    local valid = {index > 0}
    local make = userdataType(kind or "Entity", {
        __names = {},
        IsValid = function() return valid[1] end,
        EntIndex = function() return index end,
        Nick = function() return "player" .. index end,
        Remove = function() valid[1] = false end,
    })

    entities[index] = make(index)

    return entities[index]
end

function Entity(index) return entity(index) end

local world = Entity(0)

game = {GetWorld = function() return world end}

-- type() names engine userdata by its MetaName, as Garry's Mod does.
local rawtype = type

function type(v)
    local t = rawtype(v)

    if t == "userdata" then
        local mt = getmetatable(v)
        return mt and mt.MetaName or t
    end

    return t
end

--------------------------------------------------------------------------------
-- The fake network
--------------------------------------------------------------------------------

World = {sent = {}, errors = {}, rejected = {}, splitRate = 45000}

local pooled, pooledNames = {}, {}      -- name -> id, id -> name
local queue, qhead, qtail = {}, 1, 0
local humans = {}

-- A stand-in for LZMA: run-length encoding, 5 bytes per run. "R" + byte +
-- length is a single run, used to build a zip bomb by hand.
local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216)) end

local function compress(s)
    local out, i, n = {"L"}, 1, #s

    while i <= n do
        local c = sub(s, i, i)
        local j = i

        while j < n and sub(s, j + 1, j + 1) == c do j = j + 1 end

        out[#out + 1] = c .. u32(j - i + 1)
        i = j + 1
    end

    return concat(out)
end

local function decompress(s, limit)
    local kind = sub(s, 1, 1)

    if kind == "R" then
        local n = tonumber(sub(s, 3))
        if not n or (limit and n > limit) then return nil end
        return string.rep(sub(s, 2, 2), n)
    end

    if kind ~= "L" or (#s - 1) % 5 ~= 0 then return nil end

    local out, total = {}, 0

    for i = 2, #s, 5 do
        local b1, b2, b3, b4 = string.byte(s, i + 1, i + 4)
        local count = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216

        total = total + count
        if limit and total > limit then return nil end

        out[#out + 1] = string.rep(sub(s, i, i), count)
    end

    return concat(out)
end

local function newSide(isServer, native, ply)
    local side = {ply = ply, isServer = isServer}
    local current                        -- the message being read
    local writing

    local net = {Receivers = {}}

    function net.Start(name) writing = {name = name, parts = {}} end
    function net.WriteData(s, n) writing.parts[#writing.parts + 1] = sub(s, 1, n) end
    function net.Receive(name, fn) net.Receivers[string.lower(name)] = fn end
    function net.ReadData(n) return sub(current, 1, n) end

    local function post(to)
        local message = {name = writing.name, data = concat(writing.parts), to = to, from = side}

        World.sent[#World.sent + 1] = message
        qtail = qtail + 1
        queue[qtail] = message
    end

    function net.Send(target)
        if type(target) == "table" then
            for _, p in ipairs(target) do post(World.byPlayer[p]) end
        else
            post(World.byPlayer[target])
        end
    end

    function net.Broadcast()
        for _, p in ipairs(humans) do post(World.byPlayer[p]) end
    end

    function net.SendToServer() post(World.server) end

    function side.receive(message)
        local fn = net.Receivers[string.lower(message.name)]
        if not fn then return end

        current = message.data
        fn(#message.data * 8, isServer and message.from.ply or nil)
    end

    local hooks = {}

    local env = setmetatable({
        SERVER = isServer,
        CLIENT = not isServer,
        XNet = {},
        XNetNative = native and XNetNative or false,
        net = net,
        util = {
            AddNetworkString = function(name)
                if not pooled[name] then
                    pooledNames[#pooledNames + 1] = name
                    pooled[name] = #pooledNames + 300

                    -- Clients learn a new pooled string a moment later, with
                    -- a string table update; World.lagNames holds it back.
                    if World.lagNames then World.unseen[name] = true end
                end
            end,
            NetworkStringToID = function(name)
                if not isServer and (World.hideNames or World.unseen[name]) then return 0 end
                return pooled[name] or 0
            end,
            NetworkIDToString = function(id)
                local name = pooledNames[id - 300]
                if not isServer and name and World.unseen[name] then return nil end
                return name
            end,
            IsBinaryModuleInstalled = function() return false end,
            Compress = compress,
            Decompress = decompress,
        },
        hook = {
            Add = function(event, name, fn) hooks[event] = fn end,
            Remove = function() end,
            Run = function(event, ...)
                if event == "XNet.Rejected" then
                    local ply, name, reason = ...
                    World.rejected[#World.rejected + 1] = tostring(name) .. ": " .. tostring(reason)
                end
            end,
        },
        timer = {Create = function() end, Remove = function() end},
        cvars = {AddChangeCallback = function() end},
        player = {GetHumans = function()
            local list = {}
            for i, p in ipairs(humans) do list[i] = p end
            return list
        end},
        GetConVar = function(name)
            if name ~= "net_splitpacket_maxrate" then return nil end
            return {GetFloat = function() return World.splitRate end}
        end,
        ErrorNoHaltWithStack = function(msg) World.errors[#World.errors + 1] = tostring(msg) end,
        FrameNumber = function() return World.frame end,
        SysTime = function() return os.clock() + World.timeShift end,
    }, {__index = _G})

    local chunk = XNET_CHUNK()

    setfenv(chunk, env)
    chunk()

    side.env, side.XNet, side.net, side.hooks = env, env.XNet, net, hooks

    return side
end

World.byPlayer = {}
World.unseen = {}

-- Added to every side's SysTime, to skip ahead (past a newly pooled name's
-- grace period, for one).
World.timeShift = 0

function World.later(seconds) World.timeShift = World.timeShift + seconds end
-- XNET_LUA_SERVER=1 (see run.sh) runs the server side without the native module.
World.luaServer = XNET_LUA_SERVER == true
World.server = newSide(true, not World.luaServer)

local nextIndex = 0

function World.newClient()
    nextIndex = nextIndex + 1

    local ply = entity(nextIndex, "Player")
    local side = newSide(false, false, ply)

    humans[#humans + 1] = ply
    World.byPlayer[ply] = side

    return side
end

function World.disconnect(side)
    for i, p in ipairs(humans) do
        if p == side.ply then table.remove(humans, i) break end
    end

    World.server.hooks.PlayerDisconnected(side.ply)
    World.byPlayer[side.ply] = nil
end

-- The server's frame: what was sent so far is followed by the Tick hook
-- (which writes batches), then the next frame starts.
World.frame = 1

function World.tick()
    local tick = World.server.hooks.Tick
    if tick then tick() end
end

-- Ends the frame (Tick), then delivers queued messages in order until the
-- network is quiet, then starts a new frame. Returns how many were
-- delivered.
function World.pump(limit)
    local delivered = 0

    World.tick()

    while qhead <= qtail and (not limit or delivered < limit) do
        local message = queue[qhead]

        queue[qhead] = nil
        qhead = qhead + 1
        delivered = delivered + 1

        if message.to then message.to.receive(message) end
    end

    World.frame = World.frame + 1

    return delivered
end

function World.pending() return qtail - qhead + 1 end

-- Puts raw bytes on the wire as if `from` had sent them.
function World.inject(from, to, data)
    qtail = qtail + 1
    queue[qtail] = {name = "XNet", data = data, to = to, from = from}
end

-- Encoders to compare: the server side uses the native module; XNL is a
-- separate pure-Lua copy.
XNet = World.server.XNet
XNL = newSide(true, false).XNet

assert(World.luaServer or XNet.Native == true, "the native module did not attach: XNetNative = " .. tostring(XNetNative))
assert(XNL.Native == false)

return "prelude ok, native " .. tostring(XNetNative.Version) .. (World.luaServer and " (server in Lua)" or "") .. ", " .. jit.version .. " " .. jit.arch
