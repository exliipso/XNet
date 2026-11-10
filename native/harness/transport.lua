-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 exliipso
-- Originally developed by exliipso

-- End-to-end over the fake network: one server-side XNet (native encoder)
-- and client-side copies (pure Lua).

local server = World.server
local S = server.XNet
local a, b = World.newClient(), World.newClient()
local passed, failed = 0, {}

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed[#failed + 1] = name .. (detail and (": " .. tostring(detail)) or "")
    end
end

local function same(x, y)
    if type(x) ~= type(y) then return false end
    if type(x) ~= "table" then return x == y or (x ~= x and y ~= y) end

    for k, v in pairs(x) do if not same(v, y[k]) then return false end end
    for k in pairs(y) do if x[k] == nil then return false end end

    return true
end

-- The handlers record what they get.
local got = {}

local function recorder(tag)
    return function(...)
        got[#got + 1] = {tag = tag, n = select("#", ...), ...}
    end
end

for _, side in ipairs({a, b}) do
    side.XNet.Receive("t.msg", recorder(side == a and "a" or "b"))
    side.XNet.Receive("t.big", recorder(side == a and "a" or "b"))
end

S.Receive("t.up", recorder("server"))
S.Receive("t.small", recorder("server"), {maxBytes = 64, rate = 5, burst = 5})
S.Receive("t.msg", function() end)
S.Receive("t.big", function() end)

-- Past the grace period of the names pooled above.
World.later(10)

local function take()
    local out = got
    got = {}
    return out
end

-- 1. Small messages, every argument count, to one player.
for count = 0, 7 do
    local args = {}
    for i = 1, count do args[i] = (i % 3 == 0) and {i, name = "x" .. i} or (i % 2 == 0 and "str" .. i or i * 1.5) end

    S.Send(a.ply, "t.msg", unpack(args, 1, count))
    World.pump()

    local r = take()
    check("small " .. count .. " args", #r == 1 and r[1].tag == "a" and r[1].n == count and same({unpack(r[1], 1, count)}, args))
end

-- Trailing and embedded nils survive.
S.Send(a.ply, "t.msg", nil, 2, nil)
World.pump()

local r = take()
check("nil arguments", #r == 1 and r[1].n == 3 and r[1][1] == nil and r[1][2] == 2 and r[1][3] == nil)

-- One net message each, and a small one is tiny.
local before = #World.sent
S.Send(a.ply, "t.msg", 42, "hello world", true, {x = 1, y = 2})
World.pump()
take()
check("small is one net message", #World.sent - before == 1)
check("small message size", #World.sent[#World.sent].data <= 28, #World.sent[#World.sent].data)

-- 2. Broadcast and lists.
S.Broadcast("t.msg", "everyone")
World.pump()
r = take()
check("broadcast", #r == 2 and r[1][1] == "everyone" and r[2][1] == "everyone")

S.Send({a.ply, b.ply}, "t.msg", "list")
World.pump()
r = take()
check("list of players", #r == 2)

S.Send(nil, "t.msg", "nil target")
World.pump()
r = take()
check("nil target is everyone", #r == 2)

-- 3. Client to server, pooled and unpooled names.
a.XNet.Send("t.up", "from a", {1, 2, 3})
World.pump()
r = take()
check("client to server", #r == 1 and r[1].tag == "server" and r[1][1] == a.ply and r[1][2] == "from a" and same(r[1][3], {1, 2, 3}))

World.hideNames = true
local late = World.newClient()
late.XNet.Send("t.up", "name not pooled yet")
World.pump()
r = take()
check("unpooled name", #r == 1 and r[1][2] == "name not pooled yet")
World.hideNames = false
World.disconnect(late)

-- 4. Big messages: chunked, confirmed, in order, never past the window.
math.randomseed(7)

local parts = {}
for i = 1, 300000 do parts[i] = string.char(math.random(0, 255)) end
local blob = table.concat(parts)

local window = 32768        -- 0.2 s of the fake 45 KB/s link, at least 32 KB
local sentBefore = #World.sent

S.Send(a.ply, "t.big", blob, "after the blob")
S.Send(a.ply, "t.msg", "queued behind it")

-- Deliver one message at a time and watch what the server has in flight.
local worst, inFlight = 0, 0
local seen = sentBefore

while World.pending() > 0 do
    World.pump(1)

    for i = seen + 1, #World.sent do
        local m = World.sent[i]
        local kind = string.byte(m.data, 1) % 4

        if m.from == server and m.to == a and kind ~= 3 then
            inFlight = inFlight + #m.data
            if inFlight > worst then worst = inFlight end
        elseif m.from == a and kind == 3 then
            local b1, b2, b3 = string.byte(m.data, 2, 4)
            inFlight = inFlight - (b1 + b2 * 256 + b3 * 65536)
        end
    end

    seen = #World.sent
end

r = take()
check("big message arrives", #r == 2 and r[1][1] == blob and r[1][2] == "after the blob", #r)
check("order is kept", #r == 2 and r[2][1] == "queued behind it")
check("window is respected", worst > 0 and worst <= window + 8192 + 16, worst)
check("nothing left queued", S.Queued(a.ply) == 0, S.Queued(a.ply))

-- A compressible big message (the fake compressor shrinks runs).
local run = string.rep("z", 200000)
sentBefore = #World.sent
S.Send(a.ply, "t.big", run)
World.pump()
r = take()

local bytes = 0
for i = sentBefore + 1, #World.sent do if World.sent[i].from == server then bytes = bytes + #World.sent[i].data end end

check("compressed message arrives", #r == 1 and r[1][1] == run)
check("compressed message is small on the wire", bytes < 200, bytes)

-- Big broadcast: every receiver gets all of it.
S.Broadcast("t.big", blob)
World.pump()
r = take()
check("big broadcast", #r == 2 and r[1][1] == blob and r[2][1] == blob)

-- Big upload, with a name that allows it.
S.Receive("t.upbig", recorder("server"), {maxBytes = 1000000, rate = 0})
a.XNet.Send("t.upbig", blob)
World.pump()
r = take()
check("big upload", #r == 1 and r[1][2] == blob)

-- A flood of small messages is paced by the same window instead of piling
-- into the engine, and every one arrives, in order.
take()

local count, flood = 5000, {}
sentBefore = #World.sent

for i = 1, count do S.Send(a.ply, "t.msg", i, "flood message number " .. i) end

worst, inFlight, seen = 0, 0, sentBefore

-- The first burst goes out inside the Send calls, before anything is
-- delivered.
for i = seen + 1, #World.sent do
    local m = World.sent[i]
    if m.from == server and m.to == a then inFlight = inFlight + #m.data end
end

worst, seen = inFlight, #World.sent

while World.pending() > 0 do
    World.pump(1)

    for i = seen + 1, #World.sent do
        local m = World.sent[i]
        local kind = string.byte(m.data, 1) % 4

        if m.from == server and m.to == a and kind ~= 3 then
            inFlight = inFlight + #m.data
            if inFlight > worst then worst = inFlight end
        elseif m.from == a and kind == 3 then
            local b1, b2, b3 = string.byte(m.data, 2, 4)
            inFlight = inFlight - (b1 + b2 * 256 + b3 * 65536)
        end
    end

    seen = #World.sent
end

r = take()

local inOrder = #r == count
for i = 1, #r do if r[i][1] ~= i then inOrder = false break end end

local confirms = 0
for i = sentBefore + 1, #World.sent do if World.sent[i].from == a then confirms = confirms + 1 end end

check("flood of small messages all arrive in order", inOrder, #r)
check("flood stays within the window", worst <= window + 64, worst)
check("flood costs few confirms", confirms < count / 50, confirms)

-- 5. What the server refuses.
World.rejected = {}

a.XNet.Send("t.nope", 1)
a.XNet.Send("t.small", string.rep("x", 100))
World.pump()
r = take()
check("unknown name and too big are refused", #r == 0 and #World.rejected == 2, table.concat(World.rejected, " | "))

World.rejected = {}
for i = 1, 12 do a.XNet.Send("t.small", i) end
World.pump()
r = take()
check("rate limit", #r == 5 and #World.rejected == 7, #r .. " handled, " .. #World.rejected .. " rejected")

-- An upload over the default limit is refused before it is buffered, and
-- its chunks are still followed so the next message is read correctly.
World.rejected = {}
a.XNet.Send("t.up", blob)
a.XNet.Send("t.up", "still works")
World.pump()
r = take()
check("oversized upload refused, stream stays in step", #r == 1 and r[1][2] == "still works" and World.rejected[1] == "t.up: too big", table.concat(World.rejected, " | "))

-- A zip bomb: small on the wire, huge once decompressed.
World.rejected = {}
S.Receive("t.bomb", recorder("server"), {maxBytes = 1000, rate = 0})

local id = 0
for i = 1, 20 do if World.server.env.util.NetworkIDToString(300 + i) == "t.bomb" then id = 300 + i end end

World.inject(a, server, string.char(4 + math.floor(id / 256) * 16, id % 256) .. "Rz5000000")
World.pump()
r = take()
check("zip bomb refused", #r == 0 and World.rejected[1] == "t.bomb: decompress", table.concat(World.rejected, " | "))

-- 6. Garbage on the wire never escapes the receiver.
World.rejected, World.errors = {}, {}

local escaped = 0

for i = 1, 20000 do
    local n = math.random(0, 40)
    local raw = {}

    for j = 1, n do raw[j] = string.char(math.random(0, 255)) end

    World.inject(a, server, table.concat(raw))

    local ok = pcall(World.pump)
    if not ok then escaped = escaped + 1 end
end

take()
check("random bytes to the server", escaped == 0, escaped .. " escaped")

-- Mutations of a real message, to the server and to a client.
a.XNet.Send("t.up", {1, 2, "three", {four = 4}}, "abcdefgh", "abcdefgh", 1.5)
local real = World.sent[#World.sent].data
World.pump()
take()

for i = 1, 20000 do
    local p = math.random(1, #real)
    local mutated = string.sub(real, 1, p - 1) .. string.char(math.random(0, 255)) .. string.sub(real, p + 1)

    World.inject(a, server, mutated)
    World.inject(server, a, mutated)

    if not pcall(World.pump) then escaped = escaped + 1 end
end

take()
check("mutated messages", escaped == 0, escaped .. " escaped")

for i = 0, #real do
    World.inject(a, server, string.sub(real, 1, i))
    if not pcall(World.pump) then escaped = escaped + 1 end
end

take()
check("truncated messages", escaped == 0, escaped .. " escaped")

-- After all that, the stream still works both ways.
World.pump()
S.Send(a.ply, "t.msg", "alive")
a.XNet.Send("t.upbig", "alive")
World.pump()
r = take()
check("still working after the fuzz", #r == 2)

-- 7. A handler that errors is reported and nothing else breaks.
World.errors = {}
a.XNet.Receive("t.bad", function() error("boom") end)
S.Receive("t.bad", function() end)
S.Send(a.ply, "t.bad", 1)
S.Send(a.ply, "t.msg", "after the error")
World.pump()
r = take()
check("handler error is contained", #r == 1 and r[1][1] == "after the error" and #World.errors == 1 and string.find(World.errors[1], "boom", 1, true) ~= nil, World.errors[1])

-- 8. A player who leaves mid-transfer is forgotten.
local leaver = World.newClient()
leaver.XNet.Receive("t.big", function() end)
S.Send(leaver.ply, "t.big", blob)
World.pump(2)
World.disconnect(leaver)
World.pump()
check("disconnect mid-transfer", S.Queued(leaver.ply) == 0)

S.Broadcast("t.msg", "after a disconnect")
World.pump()
r = take()
check("broadcast after a disconnect", #r == 2)

-- 9. Batching: the small messages one player gets in a frame share a net
-- message, nothing is reordered against other net messages, and nothing
-- waits for a later frame.
take()

local function peerOf(fn, ply)
    for i = 1, 20 do
        local name, value = debug.getupvalue(fn, i)
        if name == "peers" then return value[ply] end
        if not name then return nil end
    end
end

local stA = peerOf(S.Queued, a.ply)

local function sentSince(n, to)
    local out = {}
    for i = n + 1, #World.sent do
        local m = World.sent[i]
        if m.from == server and (not to or m.to == to) then out[#out + 1] = m end
    end
    return out
end

sentBefore = #World.sent
for i = 1, 100 do S.Send(a.ply, "t.msg", i, "batched " .. i, {i}) end
check("batch waits for Tick", #sentSince(sentBefore) == 0, #sentSince(sentBefore))
World.pump()
r = take()

local okBatch = #r == 100
for i = 1, #r do if r[i][1] ~= i or r[i][2] ~= "batched " .. i or r[i][3][1] ~= i then okBatch = false end end
check("100 messages arrive in order", okBatch, #r)
check("as one net message", #sentSince(sentBefore, a) == 1, #sentSince(sentBefore, a))

-- Another addon's message in between keeps its place.
sentBefore = #World.sent
S.Send(a.ply, "t.msg", "first")
server.net.Start("Other")
server.net.Send(a.ply)
S.Send(a.ply, "t.msg", "third")
World.pump()
r = take()

local order = sentSince(sentBefore, a)
check("other net messages keep their place", #order == 3 and order[1].name == "XNet" and order[2].name == "Other" and order[3].name == "XNet", #order)
check("and arrive in order", #r == 2 and r[1][1] == "first" and r[2][1] == "third")

-- After the Tick hook, sends go out at once; the next frame batches again.
World.tick()
sentBefore = #World.sent
S.Send(a.ply, "t.msg", "late")
check("after Tick, sent at once", #sentSince(sentBefore, a) == 1)
World.pump()
S.Send(a.ply, "t.msg", "next frame")
check("next frame batches again", #sentSince(sentBefore, a) == 1)
World.pump()
r = take()
check("both arrive", #r == 2 and r[1][1] == "late" and r[2][1] == "next frame")

-- A batch, then a message too big for one, in order.
S.Send(a.ply, "t.msg", "small")
S.Send(a.ply, "t.msg", blob)
S.Send(a.ply, "t.msg", "small after")
World.pump()
r = take()
check("batch then big then batch", #r == 3 and r[1][1] == "small" and r[2][1] == blob and r[3][1] == "small after")

-- A name the client doesn't handle is skipped; the rest still run.
S.Receive("t.nobody", function() end)
World.later(10)
S.Send(a.ply, "t.msg", 1)
S.Send(a.ply, "t.nobody", {1, 2, 3}, "x")
S.Send(a.ply, "t.msg", 2)
World.pump()
r = take()
check("unknown name in a batch is skipped", #r == 2 and r[1][1] == 1 and r[2][1] == 2)

-- Bad batches: reported on a client, refused from a client.
World.errors, World.rejected = {}, {}
escaped = 0
for i = 1, 3000 do
    local junk = {string.char(math.random(0, 1) * 8, 0, 0)}
    for j = 1, math.random(0, 12) do junk[#junk + 1] = string.char(math.random(0, 255)) end
    World.inject(server, a, table.concat(junk))
    if not pcall(World.pump) then escaped = escaped + 1 end
end
take()
check("random batches to a client", escaped == 0, escaped)
World.inject(a, server, string.char(0, 0, 0, 0x10 * 0 + 1, 45, 1, 0))
World.pump()
check("a client can't send a batch", World.rejected[#World.rejected] == "?: batch", World.rejected[#World.rejected])

-- The window is counted exactly: after many frames of every batch shape,
-- with everything delivered, nothing is left unconfirmed beyond what the
-- client hasn't been asked to confirm yet.
World.errors = {}
for frame = 1, 2000 do
    for i = 1, frame % 4 do S.Send(a.ply, "t.msg", frame, i) end
    if frame % 97 == 0 then S.Send(a.ply, "t.msg", blob) end
    World.pump()
end
r = take()
check("2000 frames all arrive", #r == 2000 / 4 * 6 + math.floor(2000 / 97), #r)
local function upvalue(fn, want)
    for i = 1, 40 do
        local name, value = debug.getupvalue(fn, i)
        if name == want then return value end
        if not name then return nil end
    end
end

local clientGot = upvalue(a.net.Receivers.xnet, "received").server or 0
check("window accounting is exact", stA.unconfirmed == clientGot, stA.unconfirmed .. " counted, client has " .. clientGot .. " unconfirmed")
S.Send(a.ply, "t.msg", "ping")
World.pump()
check("still flowing", #take() == 1 and S.Queued(a.ply) == 0)

-- A player who leaves with a batch pending: nothing breaks, and whoever gets
-- their slot next starts clean.
local gone = World.newClient()
gone.XNet.Receive("t.msg", recorder("gone"))
S.Send(gone.ply, "t.msg", "never sent")
S.Send(gone.ply, "t.msg", "never sent either")
World.disconnect(gone)
World.errors = {}

local fresh = World.newClient()
fresh.XNet.Receive("t.msg", recorder("fresh"))
S.Send(fresh.ply, "t.msg", "hello")
S.Send(fresh.ply, "t.msg", "again")
local okPump = pcall(World.pump)
r = {}
for _, m in ipairs(take()) do if m.tag == "fresh" then r[#r + 1] = m end end
check("leaving with a batch pending", okPump and #World.errors == 0 and #r == 2 and r[1][1] == "hello" and r[2][1] == "again", #r .. " " .. tostring(World.errors[1]))

-- A name the server pools on its first send reaches clients a moment later.
-- Messages under it, sent right away, must still arrive.
World.lagNames = true
for _, name in ipairs({"t.fresh1", "t.fresh2", "t.fresh3"}) do a.XNet.Receive(name, recorder(name)) end
S.Send(a.ply, "t.fresh1", "small")
S.Send(a.ply, "t.fresh2", blob)
for i = 1, 3 do S.Send(a.ply, "t.fresh3", i) end
World.pump()
r = take()
World.lagNames, World.unseen = false, {}
check("first messages under a new name", #r == 5 and r[1].tag == "t.fresh1" and r[2][1] == blob and r[5][1] == 3, #r)

return string.format("transport: %d passed, %d failed%s", passed, #failed, #failed > 0 and "\n  " .. table.concat(failed, "\n  ") or "")
