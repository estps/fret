local BASE = "https://simple-greene-freight-back.trycloudflare.com"

local NAME = ...
if not NAME then
    local found = {}
    local res = http.get(BASE .. "/movies.txt", nil, true)
    if res then
        local body = res.readAll()
        res.close()
        for line in body:gmatch("[^\r\n]+") do
            found[#found + 1] = line
        end
    end
    if #found == 0 then
        for _, f in ipairs(fs.list("")) do
            local n = f:match("^(.+)%.meta$")
            if n and #n > 0 then found[#found + 1] = n end
        end
    end
    if #found > 0 then
        print("Movies:")
        for i, n in ipairs(found) do
            print("  [" .. i .. "] " .. n)
        end
        write("[#] pick, or type name: ")
    else
        write("Movie name: ")
    end
    local input = read()
    local pick = tonumber(input)
    if pick and found[pick] then
        NAME = found[pick]
    elseif input and #input > 0 then
        NAME = input
    else
        error("No movie selected", 0)
    end
end

for _, f in ipairs(fs.list("")) do
    if f:match("%.ccm%.%d+$") then fs.delete(f) end
end

local PART_LOW = 4000000
local PREFILL = 7500000

local function urlencode(s)
    return s:gsub("[^%w%-_%.~]", function(c)
        return ("%%%02X"):format(string.byte(c))
    end)
end

local function pname(i) return NAME .. ".ccm." .. i end

term.clear()
term.setCursorPos(1, 1)

do
    print("Fetching meta...")
    local res, err = http.get(BASE .. "/" .. urlencode(NAME) .. ".meta", nil, true)
    if not res then error("Meta download failed: " .. tostring(err), 0) end
    local body = res.readAll()
    res.close()
    local f = fs.open(NAME .. ".meta", "wb")
    f.write(body)
    f.close()
end

local mf = fs.open(NAME .. ".meta", "r")
local hdr = mf.readLine()
mf.close()
local w, h, fps, partCount = hdr:match("(%d+) (%d+) (%d+) (%d+)")
w, h, fps, partCount = tonumber(w), tonumber(h), tonumber(fps), tonumber(partCount)
local lastPart = partCount - 1

local mon = peripheral.find("monitor")
if not mon then error("No monitor attached", 0) end
mon.setTextScale(0.5)
mon.setBackgroundColour(colours.black)
mon.setTextColour(colours.white)
mon.clear()
local sp = peripheral.find("speaker")
local win = window.create(mon, 1, 1, w, h, false)

print(("%dx%d @ %dfps, %d parts"):format(w, h, fps, partCount))

local function toHex(v)
    if v < 10 then return string.char(48 + v) end
    return string.char(87 + v)
end

local dlCur = 0
local dl = nil

local function bufferedAhead()
    local total = 0
    for i = 0, dlCur - 1 do
        if fs.exists(pname(i)) then total = total + fs.getSize(pname(i)) end
    end
    return total
end

local lastUiDraw = 0
local uiEnabled = true
local SPIN = { "|", "/", "-", "\\" }
local function uiStatus(sub)
    if not uiEnabled then return end
    local ok = pcall(function()
        local mw, mh = mon.getSize()
        if not mw or not mh or mw < 16 or mh < 7 then return end
        local b = bufferedAhead()
        local frac = math.min(1, b / PREFILL)
        local pct = math.floor(frac * 100 + 0.5)

        mon.setBackgroundColour(colours.black)
        mon.setTextColour(colours.white)
        mon.clear()

        local cy = math.floor(mh / 2)
        local title = #NAME > mw - 2 and NAME:sub(1, mw - 2) or NAME
        mon.setTextColour(colours.yellow)
        mon.setCursorPos(math.max(1, math.floor((mw - #title) / 2) + 1), cy - 2)
        mon.write(title)

        local bw = mw - 14
        if bw % 2 == 1 then bw = bw + 1 end
        local bx = math.max(2, math.floor((mw - bw) / 2) + 1)
        mon.setTextColour(colours.lightGrey)
        mon.setBackgroundColour(colours.black)
        mon.setCursorPos(bx - 1, cy)
        mon.write("[")
        mon.setCursorPos(bx + bw, cy)
        mon.write("]")
        mon.setBackgroundColour(colours.gray)
        mon.setCursorPos(bx, cy)
        mon.write(string.rep(" ", bw))
        local fill = math.min(bw, math.floor(bw * frac + 0.5))
        if fill > 0 then
            mon.setBackgroundColour(colours.lime)
            mon.setCursorPos(bx, cy)
            mon.write(string.rep(" ", fill))
        end
        mon.setBackgroundColour(colours.black)

        local stats = ("%d%%  %.1f/%.1fMB"):format(pct, b / 1000000, PREFILL / 1000000)
        mon.setTextColour(colours.white)
        mon.setCursorPos(math.max(1, math.floor((mw - #stats) / 2) + 1), cy + 1)
        mon.write(stats)

        local line = (sub or "loading") .. " " .. SPIN[math.floor(os.clock() * 2) % 4 + 1]
        mon.setTextColour(colours.lightBlue)
        mon.setCursorPos(math.max(1, math.floor((mw - #line) / 2) + 1), cy + 2)
        mon.write(line)
        mon.setTextColour(colours.white)
    end)
    if not ok then uiEnabled = false end
end

local function uiStatusThrottled(sub)
    local now = os.clock()
    if now - lastUiDraw >= 0.25 then
        lastUiDraw = now
        uiStatus(sub)
    end
end

local function pump(target)
    if dl then
        local piece = dl.res.read(16384)
        if piece then
            dl.fh.write(piece)
        else
            dl.fh.close()
            dl.res.close()
            dl = nil
        end
        return
    end
    if dlCur <= lastPart and bufferedAhead() < target and fs.getFreeSpace("") > 1500000 then
        local res, err = http.get(BASE .. "/" .. urlencode(pname(dlCur)), nil, true)
        if not res then
            print("part dl failed: " .. tostring(err) .. ", retrying")
            sleep(2)
            return
        end
        local fh = fs.open(pname(dlCur), "wb")
        dl = { idx = dlCur, res = res, fh = fh }
        dlCur = dlCur + 1
    end
end

local lastB, lastT = -1, os.clock()
while dlCur <= lastPart and bufferedAhead() < PREFILL do
    pump(PREFILL)
    local b = bufferedAhead()
    if b ~= lastB then lastB, lastT = b, os.clock() end
    uiStatusThrottled("buffering...")
    if (os.clock() - lastT > 5 or fs.getFreeSpace("") < 1500000) and b >= PART_LOW then
        break
    end
    sleep(0.05)
end

local function readLineBin(hnd)
    local buf = {}
    while true do
        local c = hnd.read()
        if not c or c == 10 then return table.concat(buf) end
        if c ~= 13 then buf[#buf + 1] = string.char(c) end
    end
end

local function render(frame)
    local y = 1
    for r0 in string.gmatch(frame, "[^;]+") do
        if y > h then break end
        win.setCursorPos(1, y)
        local r = r0
        local n = #r
        if n >= w then
            r = r:sub(1, w)
            win.blit(string.rep(" ", w), r, r)
        elseif n > 0 then
            local pad = r:sub(-1):rep(w - n)
            win.blit(string.rep(" ", w), r .. pad, r .. pad)
        end
        y = y + 1
    end
    win.setVisible(true)
end

local function applyPalette(p)
    if not p then return end
    local i = 0
    for entry in p:gmatch("[^;]+") do
        local r, g, b = entry:match("(%d+),(%d+),(%d+)")
        if r and i < 16 then
            mon.setPaletteColour(2 ^ i, r / 255, g / 255, b / 255)
            i = i + 1
        end
    end
end

local function assemble(cells)
    local rows = {}
    local pos = 1
    for _ = 1, h do
        rows[#rows + 1] = table.concat(cells, "", pos, pos + w - 1)
        pos = pos + w
    end
    return table.concat(rows, ";")
end

local function decodePacked(p)
    local cells = {}
    local ci = 0
    for i = 1, #p do
        local b = string.byte(p, i)
        ci = ci + 1; cells[ci] = toHex(math.floor(b / 16))
        ci = ci + 1; cells[ci] = toHex(b % 16)
    end
    return assemble(cells)
end

local function decodeRLE(p)
    local cells = {}
    local ci = 0
    for i = 1, #p, 2 do
        local cnt = string.byte(p, i)
        local v = toHex(string.byte(p, i + 1))
        for _ = 1, cnt do
            ci = ci + 1
            cells[ci] = v
        end
    end
    return assemble(cells)
end

local function playAudioChunk(p)
    if not sp then return end
    local tt = {}
    local idx = 0
    for i = 1, #p do
        local b = string.byte(p, i)
        for j = 7, 0, -1 do
            idx = idx + 1
            tt[idx] = (b % (2 ^ (j + 1)) >= 2 ^ j) and 127 or -128
        end
    end
    while not sp.playAudio(tt) do
        os.pullEvent("speaker_audio_empty")
    end
end

local curPart = 0
local hnd = nil

local function nextRecord()
    while true do
        if not hnd then
            while not fs.exists(pname(curPart)) do
                pump(PART_LOW)
                uiStatusThrottled("rebuffering...")
                sleep(0.05)
            end
            hnd = fs.open(pname(curPart), "rb")
            if curPart > 0 and fs.exists(pname(curPart - 1)) then
                fs.delete(pname(curPart - 1))
            end
        end
        local t = hnd.read()
        if t then
            local b2, b3 = hnd.read(), hnd.read()
            local len = b2 * 256 + b3
            local payload = ""
            if len > 0 then
                payload = hnd.read(len)
                if not payload then error("truncated part " .. curPart, 0) end
            end
            return t, payload
        end
        hnd.close()
        hnd = nil
        if curPart >= lastPart then return nil end
        curPart = curPart + 1
    end
end

local start = nil
local fi, ai = 0, 0
local frameDur = 1000 / fps
local framesPlayed = 0
local pendingAudio = {}
local lastIter = os.clock()

while true do
    local t, payload = nextRecord()
    if not t then break end

    if t == 1 then
        applyPalette(payload)
    elseif t == 4 then
        if sp then pendingAudio[#pendingAudio + 1] = payload end
    elseif t == 0 or t == 2 or t == 3 then
        if t ~= 0 then
            cachedFrame = (t == 3) and decodeRLE(payload) or decodePacked(payload)
        end
        if not start then start = os.epoch("utc") + 150 end
        render(cachedFrame)
        fi = fi + 1
        framesPlayed = framesPlayed + 1
    end

    while #pendingAudio > 0 and sp and start do
        if os.epoch("utc") < start + ai * 250 - 120 then break end
        if ai * 250 > fi * frameDur then break end
        playAudioChunk(table.remove(pendingAudio, 1))
        ai = ai + 1
    end

    pump(PART_LOW)
    local nowC = os.clock()
    if nowC - lastIter < 0.004 then sleep(0.005) end
    lastIter = nowC
end

while #pendingAudio > 0 and sp do
    playAudioChunk(table.remove(pendingAudio, 1))
end

if sp then sp.stop() end
term.setCursorPos(1, 3)
term.clearLine()
print("Finished (" .. framesPlayed .. " frames).")
