-- feader.lua - background bufferer, talks to display.lua over rednet
--
-- usage: feader
--
-- Daemon on the computer with the disk drives. Waits for a rednet "play"
-- message from display.lua, then buffers that movie across all disks.
-- display.lua publishes its playhead via "head" messages so played-out
-- parts get deleted.
--
-- Protocol "ccplayer":
--   {cmd="play", movie=NAME}  from display: buffer this movie
--   {cmd="head", n=INDEX}     from display: playback reached part INDEX

local BASE = "https://relates-exclude-legend-strand.trycloudflare.com"
local MAXDL = 8
local RESERVE = 3000000
local REDNET_PROTO = "ccplayer"

local function urlencode(s)
    return s:gsub("[^%w%-_%.~]", function(c)
        return ("%%%02X"):format(string.byte(c))
    end)
end

local function dbg(msg)
    print("[feader] " .. msg)
end

for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" and not rednet.isOpen(name) then
        pcall(rednet.open, name)
    end
end

local DISKS = { "" }
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
        local drv = peripheral.wrap(name)
        local ok, mp = pcall(function() return drv.getMountPath() end)
        if ok and type(mp) == "string" and #mp > 0 and fs.isDir(mp) then
            DISKS[#DISKS + 1] = mp
        end
    end
end

local function totalFree()
    local t = 0
    for _, d in ipairs(DISKS) do t = t + fs.getFreeSpace(d) end
    return t
end

dbg(("storage: %d disk(s), %.1f MB free - waiting for display.lua")
    :format(#DISKS, totalFree() / 1e6))

local netHead = 0

local function readHeadFile()
    if fs.exists(".ccm_head") then
        local fh = fs.open(".ccm_head", "r")
        local v = tonumber(fh.readAll())
        fh.close()
        if v then return v end
    end
    return 0
end

local function partExists(name, i)
    for _, d in ipairs(DISKS) do
        if fs.exists(fs.combine(d, string.format("%s.ccm.%d", name, i))) then
            return true
        end
    end
    return false
end

local function pickDisk(est)
    local best, bestFree, anyBest, anyFree = nil, -1, nil, -1
    for _, d in ipairs(DISKS) do
        local f = fs.getFreeSpace(d)
        if f > anyFree then anyBest, anyFree = d, f end
        if f >= est + 150000 and f > bestFree then best, bestFree = d, f end
    end
    return best, anyBest, anyFree
end

local function sweepOtherMovies(name)
    for _, d in ipairs(DISKS) do
        for _, f in ipairs(fs.list(d)) do
            if f:match("%.ccm%.%d+%.part$") then
                fs.delete(fs.combine(d, f))
            else
                local other = f:match("^(.+)%.ccm%.%d+$")
                if other and other ~= name then
                    fs.delete(fs.combine(d, f))
                end
            end
        end
    end
end

local pendingSwitch = nil

local function handleMsg(msg)
    if type(msg) ~= "table" then return end
    if msg.cmd == "play" and type(msg.movie) == "string" then
        dbg(("display requested '%s'"):format(msg.movie))
        pendingSwitch = msg.movie
    elseif msg.cmd == "head" and tonumber(msg.n) then
        netHead = math.max(netHead, tonumber(msg.n))
    end
end

local function bufferMovie(NAME)
    sweepOtherMovies(NAME)

    if not fs.exists(NAME .. ".meta") then
        dbg("fetching meta...")
        local res, err = http.get(BASE .. "/" .. urlencode(NAME) .. "/" ..
            urlencode(NAME) .. ".meta", nil, true)
        if not res then error("Meta download failed: " .. tostring(err), 0) end
        local body = res.readAll()
        res.close()
        local mf = fs.open(NAME .. ".meta", "wb")
        mf.write(body)
        mf.close()
    end

    local mf = fs.open(NAME .. ".meta", "r")
    local hdr = mf.readLine()
    mf.close()
    local w, h, fps, partCount = hdr:match("^(%d+) (%d+) (%d+) (%d+)")
    w, h, fps, partCount = tonumber(w), tonumber(h), tonumber(fps), tonumber(partCount)
    if not w then error("Corrupt meta file", 0) end
    local lastPart = partCount - 1

    local nextPart = 0
    while nextPart <= lastPart and partExists(NAME, nextPart) do
        nextPart = nextPart + 1
    end
    if nextPart > lastPart then
        dbg(("'%s' already fully buffered"):format(NAME))
        return
    end

    dbg(("buffering '%s': %dx%d @%dfps, %d parts (~%.0f MB)")
        :format(NAME, w, h, fps, partCount, partCount * 0.95))

    local MAX_BUF = math.max(4000000, totalFree() - RESERVE)
    local dls = {}
    local lastDlFail = 0
    local lastPartSz = 0
    local lastGc = 0

    local function rname(i) return NAME .. ".ccm." .. i end

    local bufCache, bufAt = 0, 0
    local function bufferedAhead()
        local now = os.clock()
        if now - bufAt < 0.25 then return bufCache end
        local total = 0
        for i = 0, nextPart - 1 do
            for _, d in ipairs(DISKS) do
                local p = fs.combine(d, rname(i))
                if fs.exists(p) then
                    total = total + fs.getSize(p)
                    break
                end
            end
        end
        bufCache, bufAt = total, now
        return total
    end

    while nextPart <= lastPart or #dls > 0 do
        if pendingSwitch and pendingSwitch ~= NAME then
            for _, d in ipairs(dls) do
                pcall(function() d.res.close() end)
                pcall(function() d.fh.close() end)
                pcall(fs.delete, fs.combine(d.disk, rname(d.idx) .. ".part"))
            end
            dbg(("switching to '%s'"):format(pendingSwitch))
            return
        end

        local k = 1
        while k <= #dls do
            local d = dls[k]
            local piece = d.res.read(65536)
            if piece then
                local okW, werr = pcall(d.fh.write, piece)
                if okW then
                    k = k + 1
                else
                    print("[feader] WRITE FAIL part " .. d.idx .. ": " .. tostring(werr))
                    pcall(function() d.fh.close() end)
                    pcall(function() d.res.close() end)
                    pcall(fs.delete, fs.combine(d.disk, rname(d.idx) .. ".part"))
                    nextPart = math.min(nextPart, d.idx)
                    lastDlFail = os.clock()
                    table.remove(dls, k)
                end
            else
                d.fh.close()
                d.res.close()
                for _, dd in ipairs(DISKS) do
                    local tmp = fs.combine(dd, rname(d.idx) .. ".part")
                    if fs.exists(tmp) then
                        local fin = fs.combine(dd, rname(d.idx))
                        if fs.exists(fin) then fs.delete(fin) end
                        pcall(fs.move, tmp, fin)
                        local okSz, sz = pcall(fs.getSize, fin)
                        if okSz and type(sz) == "number" then
                            lastPartSz = sz
                            dbg(("part %d complete (%.2f MB on %s)")
                                :format(d.idx, sz / 1e6, dd == "" and "<root>" or dd))
                        end
                    end
                end
                table.remove(dls, k)
            end
        end

        local nowC = os.clock()
        if nowC - lastGc > 3 then
            lastGc = nowC
            local head = math.max(netHead, readHeadFile())
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
                bufAt = 0
                dbg(("gc: freed %d played part(s) (playhead %d)"):format(removed, head))
            end
        end

        bufAt = 0
        while #dls > 0 and bufferedAhead() >= MAX_BUF do
            local d = table.remove(dls)
            pcall(function() d.res.close() end)
            pcall(function() d.fh.close() end)
            pcall(fs.delete, fs.combine(d.disk, rname(d.idx) .. ".part"))
            nextPart = math.min(nextPart, d.idx)
        end

        local est = lastPartSz > 0 and lastPartSz or 1000000
        local b = bufferedAhead()
        if #dls < MAXDL and nextPart <= lastPart then
            local why
            if b + est > MAX_BUF then
                why = ("headroom wait: buf %.2f + est %.2f > cap %.2f MB")
                    :format(b / 1e6, est / 1e6, MAX_BUF / 1e6)
            else
                local tgt, anyBest, anyFree = pickDisk(est)
                if not tgt then
                    why = ("no disk room: need %.2f MB, fullest '%s' has %.2f MB")
                        :format((est + 150000) / 1e6,
                            anyBest == "" and "<root>" or anyBest, anyFree / 1e6)
                elseif os.clock() - lastDlFail <= 0.5 then
                    why = "retry cooldown"
                end
            end
            if why then dbg(why) end

            if not why then
                local tgt = pickDisk(est)
                dbg(("GET %s -> %s"):format(rname(nextPart), tgt == "" and "<root>" or tgt))
                local res2, err2 = http.get(BASE .. "/" .. urlencode(NAME) .. "/" ..
                    urlencode(rname(nextPart)), nil, true)
                if not res2 then
                    lastDlFail = os.clock()
                    print("[feader] HTTP FAIL part " .. nextPart .. ": " .. tostring(err2))
                else
                    local tmp = fs.combine(tgt, rname(nextPart) .. ".part")
                    local fh = fs.open(tmp, "wb")
                    if fh then
                        dls[#dls + 1] = { idx = nextPart, res = res2, fh = fh, disk = tgt }
                        nextPart = nextPart + 1
                    else
                        pcall(function() res2.close() end)
                        lastDlFail = os.clock()
                        dbg("cannot open " .. tmp)
                    end
                end
            end
        end

        rednet.receive(REDNET_PROTO, 0.05)
    end

    dbg(("'%s' fully buffered (%d parts)."):format(NAME, partCount))
end

while true do
    pendingSwitch = nil
    local id, msg = rednet.receive(REDNET_PROTO)
    handleMsg(msg)
    if type(msg) == "table" and msg.cmd == "play" and type(msg.movie) == "string" then
        netHead = 0
        local ok, err = pcall(bufferMovie, msg.movie)
        if not ok then
            print("[feader] error: " .. tostring(err))
        elseif not pendingSwitch then
            pcall(rednet.send, id, { cmd = "done", movie = msg.movie }, REDNET_PROTO)
            dbg("idle - waiting for display.lua")
        end
    end
end
