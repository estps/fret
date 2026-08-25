-- feader.lua - background bufferer for display.lua
--
-- usage: feader <movie>
--
-- Downloads the movie's .ccm parts from BASE, striping them across every
-- mounted disk (root + floppies), while display.lua plays them. The two
-- talk through files:
--   NAME.ccm.N   part payloads on whatever disk fit them
--   .ccm_head    display.lua writes its current part index here
--
-- Run it in a second multishell tab BEFORE (or alongside) display.lua:
--   multishell -> tab 1: feader mymovie
--                 tab 2: display mymovie
-- It exits by itself once every part is on disk.

local BASE = "https://relates-exclude-legend-strand.trycloudflare.com"
local MAXDL = 8                  -- parallel downloads
local RESERVE = 3000000          -- bytes of free space to always keep

local function urlencode(s)
    return s:gsub("[^%w%-_%.~]", function(c)
        return ("%%%02X"):format(string.byte(c))
    end)
end

local function dbg(msg)
    print("[feader] " .. msg)
end

-- discover every writable mount: root plus all floppy/drive mounts
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

dbg(("storage: %d disk(s), %.1f MB free")
    :format(#DISKS, totalFree() / 1e6))

local NAME = ...
if not NAME or #NAME == 0 then
    error("usage: feader <movie>", 0)
end

-- clear parts belonging to OTHER movies; keep ours so restarts resume
for _, d in ipairs(DISKS) do
    for _, f in ipairs(fs.list(d)) do
        if f:match("%.ccm%.%d+$") and not f:match("^" .. NAME .. "%.ccm%.%d+$") then
            fs.delete(fs.combine(d, f))
        elseif f:match("%.ccm%.%d+%.part$") then
            fs.delete(fs.combine(d, f))
        end
    end
end

-- meta: reuse if a previous run/display already fetched it
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

dbg(("movie '%s': %dx%d @%dfps, %d parts (~%.0f MB)")
    :format(NAME, w, h, fps, partCount, partCount * 0.95))

local function readHead()
    if fs.exists(".ccm_head") then
        local fh = fs.open(".ccm_head", "r")
        local v = tonumber(fh.readAll())
        fh.close()
        if v then return v end
    end
    return 0
end

-- pick the disk with the most free space that can hold a whole part
local function pickDisk(est)
    local best, bestFree, anyBest, anyFree = nil, -1, nil, -1
    for _, d in ipairs(DISKS) do
        local f = fs.getFreeSpace(d)
        if f > anyFree then anyBest, anyFree = d, f end
        if f >= est + 150000 and f > bestFree then best, bestFree = d, f end
    end
    return best, anyBest, anyFree
end

-- buffer ceiling: all storage minus a reserve, floored so tiny setups still run
local MAX_BUF = math.max(4000000, totalFree() - RESERVE)

local nextPart = readHead()      -- resume where previous runs left off
local dls = {}
local lastDlFail = 0
local lastPartSz = 0
local lastGc = 0

local bufCache, bufAt = 0, 0
local function bufferedAhead()
    -- exact when asked with force; cached otherwise (UI only)
    local now = os.clock()
    if now - bufAt < 0.25 then return bufCache end
    local total = 0
    for i = 0, nextPart - 1 do
        for _, d in ipairs(DISKS) do
            local p = fs.combine(d, string.format("%s.ccm.%d", NAME, i))
            if fs.exists(p) then total = total + fs.getSize(p) break end
        end
    end
    bufCache, bufAt = total, now
    return total
end

local function rname(i) return NAME .. ".ccm." .. i end

while nextPart <= lastPart or #dls > 0 do
    -- drain active downloads
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
                pcall(fs.delete, d.tmp)
                nextPart = math.min(nextPart, d.idx)
                lastDlFail = os.clock()
                table.remove(dls, k)
            end
        else
            d.fh.close()
            d.res.close()
            local done = false
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
                    done = true
                end
            end
            if not done then dbg(("part %d vanished?"):format(d.idx)) end
            table.remove(dls, k)
        end
    end

    -- gc: drop played-out parts using the playhead display.lua publishes
    local nowC = os.clock()
    if nowC - lastGc > 3 then
        lastGc = nowC
        local head = readHead()
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

    -- hard ceiling: abort newest in-flight downloads once over the cap
    bufAt = 0
    while #dls > 0 and bufferedAhead() >= MAX_BUF do
        local d = table.remove(dls)
        pcall(function() d.res.close() end)
        pcall(function() d.fh.close() end)
        pcall(fs.delete, fs.combine(d.disk, rname(d.idx) .. ".part"))
        nextPart = math.min(nextPart, d.idx)
    end

    -- start new downloads when there is room for a WHOLE part
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

    if #dls == 0 and nextPart > lastPart then break end
    sleep(0.05)
end

dbg(("done: %d parts buffered, %.1f MB free. You can close this tab.")
    :format(partCount, totalFree() / 1e6))
