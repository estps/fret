-- storage.lua - distributed buffer worker for display.lua
--
-- Run this on every computer wired into the storage network (each with its
-- own disks/floppies). 8 computers x 8MB = ~64MB of shared buffer.
--
-- display.lua coordinates: it assigns each node specific parts to download,
-- so no two nodes ever fetch the same part. Nodes reply done/fail directly
-- to the display that assigned them.
--
-- Protocol "ccplayer":
--   node -> all : {cmd="node", free=bytes}          heartbeat every ~3s
--   display -> 1: {cmd="play", movie=NAME}          switch movie / wipe others
--   display -> 1: {cmd="head", n=INDEX}             playhead, gc old parts
--   display -> 1: {cmd="assign", movie=NAME, part=N}
--   node    -> 1: {cmd="done", movie=NAME, part=N} | {cmd="fail", part=N}

local BASE = "https://relates-exclude-legend-strand.trycloudflare.com"
local PROTO = "ccplayer"
local RESERVE = 2500000        -- keep this much space free per node
local MAX_CONC = 2             -- simultaneous downloads per node
local CHUNK_EST = 1000000      -- assumed part size before we learn better

local MYID = os.getComputerID()

local function urlencode(s)
    return s:gsub("[^%w%-_%.~]", function(c)
        return ("%%%02X"):format(string.byte(c))
    end)
end

local function dbg(msg)
    print("[node" .. MYID .. "] " .. msg)
end

for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" and not rednet.isOpen(name) then
        pcall(rednet.open, name)
    end
end

local DISKS = { "" }
local function scanDisks()
    DISKS = { "" }
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" then
            local drv = peripheral.wrap(name)
            local ok, mp = pcall(function() return drv.getMountPath() end)
            if ok and type(mp) == "string" and #mp > 0 and fs.isDir(mp) then
                DISKS[#DISKS + 1] = mp
            end
        end
    end
end

scanDisks()

local function totalFree()
    local t = 0
    for _, d in ipairs(DISKS) do t = t + fs.getFreeSpace(d) end
    return t
end

dbg(("boot: %d disk(s), %.1f MB free - wiping stale files")
    :format(#DISKS, totalFree() / 1e6))

-- boot wipe: every session starts clean
for _, d in ipairs(DISKS) do
    for _, f in ipairs(fs.list(d)) do
        if f:match("%.ccm%.%d+$") or f:match("%.ccm%.%d+%.part$") or f:match("%.meta$") then
            fs.delete(fs.combine(d, f))
        end
    end
end

local function sweepOtherMovies(keep)
    for _, d in ipairs(DISKS) do
        for _, f in ipairs(fs.list(d)) do
            if f:match("%.ccm%.%d+%.part$") then
                fs.delete(fs.combine(d, f))
            else
                local other = f:match("^(.+)%.ccm%.%d+$")
                if other and other ~= keep then
                    fs.delete(fs.combine(d, f))
                end
            end
        end
    end
end

local function partExists(movie, i)
    for _, d in ipairs(DISKS) do
        if fs.exists(fs.combine(d, string.format("%s.ccm.%d", movie, i))) then
            return true
        end
    end
    return false
end

local function pickDisk(est)
    scanDisks()                  -- catch newly mounted network drives
    local best, bestFree, anyBest, anyFree = nil, -1, nil, -1
    for _, d in ipairs(DISKS) do
        local f = fs.getFreeSpace(d)
        if f > anyFree then anyBest, anyFree = d, f end
        if f >= est + 150000 and f > bestFree then best, bestFree = d, f end
    end
    return best, anyBest, anyFree
end

-- ---------------------------------------------------------------- state
local curMovie = nil
local head = 0
local pending = {}              -- {movie=,part=,replyTo=}
local active = {}               -- in-flight downloads

local lastBeat, lastGc = 0, 0
local lastPartSz = CHUNK_EST

local function gc()
    scanDisks()
    local removed = 0
    for _, dsk in ipairs(DISKS) do
        for _, f in ipairs(fs.list(dsk)) do
            local num = f:match("%.ccm%.(%d+)$")
            if num and tonumber(num) < head then
                fs.delete(fs.combine(dsk, f))
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        dbg(("gc: freed %d played part(s) (playhead %d)"):format(removed, head))
    end
end

local function startJob(job)
    if partExists(job.movie, job.part) then
        pcall(rednet.send, job.replyTo,
            { cmd = "done", movie = job.movie, part = job.part }, PROTO)
        return
    end
    local est = lastPartSz + 150000
    local tgt = pickDisk(est)
    if not tgt then
        dbg(("no room for part %d (%.2f MB needed)")
            :format(job.part, est / 1e6))
        table.insert(pending, job)   -- retry later
        return false                 -- signal: no space right now
    end
    local rn = string.format("%s.ccm.%d", job.movie, job.part)
    local res, err = http.get(BASE .. "/" .. urlencode(job.movie) .. "/" ..
        urlencode(rn), nil, true)
    if not res then
        print("[node" .. MYID .. "] HTTP FAIL part " .. job.part .. ": " .. tostring(err))
        pcall(rednet.send, job.replyTo,
            { cmd = "fail", movie = job.movie, part = job.part }, PROTO)
        return
    end
    local tmp = fs.combine(tgt, rn .. ".part")
    local fh = fs.open(tmp, "wb")
    if not fh then
        pcall(function() res.close() end)
        pcall(rednet.send, job.replyTo,
            { cmd = "fail", movie = job.movie, part = job.part }, PROTO)
        return
    end
    active[#active + 1] = { movie = job.movie, part = job.part,
                            res = res, fh = fh, disk = tgt, replyTo = job.replyTo }
end

local function drainActive()
    local k = 1
    while k <= #active do
        local a = active[k]
        -- pull several chunks per pass: reading one 64KB chunk per main-loop
        -- iteration throttles a 1MB part to ~5s and makes display re-assign
        local done = false
        for _ = 1, 8 do
            local piece = a.res.read(65536)
            if not piece then
                done = true
                break
            end
            local okW, werr = pcall(a.fh.write, piece)
            if not okW then
                print("[node" .. MYID .. "] WRITE FAIL part " .. a.part
                    .. ": " .. tostring(werr))
                pcall(function() a.fh.close() end)
                pcall(function() a.res.close() end)
                pcall(fs.delete, fs.combine(a.disk,
                    string.format("%s.ccm.%d.part", a.movie, a.part)))
                pcall(rednet.send, a.replyTo,
                    { cmd = "fail", movie = a.movie, part = a.part }, PROTO)
                table.remove(active, k)
                done = nil               -- job removed; advance to next
                break
            end
        end
        if done == nil then
            -- handled above (write failure): move on to the next download
        elseif done then
            a.fh.close()
            a.res.close()
            -- move whichever temp file appeared to its final name
            for _, dd in ipairs(DISKS) do
                local tmp = fs.combine(dd,
                    string.format("%s.ccm.%d.part", a.movie, a.part))
                if fs.exists(tmp) then
                    local fin = fs.combine(dd,
                        string.format("%s.ccm.%d", a.movie, a.part))
                    if fs.exists(fin) then fs.delete(fin) end
                    pcall(fs.move, tmp, fin)
                    local okSz, sz = pcall(fs.getSize, fin)
                    if okSz and type(sz) == "number" then lastPartSz = sz end
                end
            end
            dbg(("part %d done"):format(a.part))
            pcall(rednet.send, a.replyTo,
                { cmd = "done", movie = a.movie, part = a.part }, PROTO)
            table.remove(active, k)
        else
            k = k + 1                     -- still streaming; next job
        end
    end
end

while true do
    local id, msg = rednet.receive(PROTO, 0.05)

    if type(msg) == "table" then
        if msg.cmd == "assign" and type(msg.movie) == "string" and tonumber(msg.part) then
            if msg.movie ~= curMovie then
                curMovie = msg.movie
                head = 0
                sweepOtherMovies(curMovie)
                dbg(("movie set to '%s'"):format(curMovie))
            end
            local dup = false
            for _, j in ipairs(pending) do
                if j.part == msg.part then dup = true break end
            end
            for _, a in ipairs(active) do
                if a.part == msg.part then dup = true break end
            end
            if not dup then
                pending[#pending + 1] = { movie = msg.movie, part = msg.part, replyTo = id }
            end
        elseif msg.cmd == "play" and type(msg.movie) == "string" then
            if msg.movie ~= curMovie then
                curMovie = msg.movie
                head = 0
                sweepOtherMovies(curMovie)
                dbg(("movie set to '%s'"):format(curMovie))
            end
        elseif msg.cmd == "head" and tonumber(msg.n) then
            local n = tonumber(msg.n)
            if n > head then
                head = n
                if os.clock() - lastGc > 3 then
                    lastGc = os.clock()
                    gc()
                end
            end
        end
    end

    local now = os.clock()
    if now - lastBeat > 3 then
        lastBeat = now
        scanDisks()
        pcall(rednet.broadcast, { cmd = "node", free = totalFree() }, PROTO)
    end
    if now - lastGc > 5 then
        lastGc = now
        gc()
    end

    drainActive()

    -- top up downloads
    while #active < MAX_CONC and #pending > 0 do
        local job = table.remove(pending, 1)
        if job.movie ~= curMovie then
            -- stale assignment from a previous movie: drop it
        else
            local started = startJob(job)
            if started == false then
                table.insert(pending, job)   -- no disk room; try again next loop
                break
            end
        end
    end
end
