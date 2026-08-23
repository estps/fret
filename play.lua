
local BASE = "https://simple-greene-freight-back.trycloudflare.com"

local PART_LOW = 4000000
local PREFILL = 7500000

local SETTINGS_FILE = ".cctv_settings"
local DELAY_MS = 0
if fs.exists(SETTINGS_FILE) then
    local f = fs.open(SETTINGS_FILE, "r")
    DELAY_MS = tonumber(f.readLine()) or 0
    f.close()
end
local function saveDelay()
    local f = fs.open(SETTINGS_FILE, "w")
    f.write(tostring(DELAY_MS))
    f.close()
end

local function urlencode(s)
    return s:gsub("[^%w%-_%.~]", function(c)
        return ("%%%02X"):format(string.byte(c))
    end)
end

local mon = peripheral.find("monitor")
if not mon then error("No monitor attached", 0) end
mon.setTextScale(0.5)

local sp = peripheral.find("speaker")

local savedPal = {}
for i = 0, 15 do savedPal[i + 1] = { mon.getPaletteColour(2 ^ i) } end
local function resetPalette()
    for i = 0, 15 do
        mon.setPaletteColour(2 ^ i, unpack(savedPal[i + 1]))
    end
end
resetPalette()

local MW, MH = mon.getSize()

local function clockStr()
    local ok, s = pcall(textutils.formatTime, os.time(), false)
    if ok and s then return s end
    return ""
end

local function fetchMovies()
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
    return found
end

local CARD_W, CARD_H, GAP = 19, 9, 2
local HEADER_ROWS = 4

local function drawCard(it, cx, cy, selected)
    mon.setBackgroundColour(selected and colours.blue or colours.grey)
    mon.setTextColour(selected and colours.white or colours.lightGrey)
    for r = 0, CARD_H - 1 do
        mon.setCursorPos(cx, cy + r)
        mon.write(string.rep(" ", CARD_W))
    end
    local isMovie = it.kind == "movie"
    mon.setBackgroundColour(selected and (isMovie and colours.lime or colours.orange) or colours.black)
    mon.setTextColour(selected and colours.black or (isMovie and colours.lime or colours.orange))
    for r = 0, 2 do
        mon.setCursorPos(cx + 1, cy + 1 + r)
        mon.write("   ")
    end
    mon.setCursorPos(cx + 1, cy + 1)
    mon.write(isMovie and "\\|" or "\\7/")

    mon.setTextColour(selected and colours.white or colours.lightGrey)
    local t1 = it.label:sub(1, CARD_W - 6)
    local t2 = #it.label > CARD_W - 6 and it.label:sub(CARD_W - 5, CARD_W * 2 - 11) or ""
    mon.setCursorPos(cx + 5, cy + 1)
    mon.write(t1)
    if t2 ~= "" then
        mon.setCursorPos(cx + 5, cy + 2)
        mon.write(t2)
    end

    if selected then
        mon.setBackgroundColour(colours.yellow)
        mon.setCursorPos(cx + 1, cy + CARD_H - 2)
        mon.write(string.rep(" ", CARD_W - 2))
    else
        mon.setTextColour(colours.lightGrey)
        mon.setCursorPos(cx + 1, cy + CARD_H - 3)
        mon.write(isMovie and "movie" or "settings")
    end
    mon.setBackgroundColour(colours.black)
end

local function homeMenu(movies)
    local items = {}
    for _, m in ipairs(movies) do items[#items + 1] = { label = m, kind = "movie" } end
    items[#items + 1] = { label = "Settings", kind = "settings" }
    local fit = math.max(1, math.floor((MW - 2) / (CARD_W + GAP)))
    local sel, scroll = 1, 1
    local cardsY = HEADER_ROWS + 1

    local function drawChrome()
        mon.setBackgroundColour(colours.black)
        mon.clear()
        mon.setTextColour(colours.lime)
        mon.setCursorPos(2, 1)
        mon.write("\\127")
        mon.setTextColour(colours.white)
        mon.write(" CC TV")
        mon.setTextColour(colours.lightGrey)
        local c = clockStr()
        mon.setCursorPos(math.max(1, MW - #c), 1)
        mon.write(c)
        mon.setTextColour(colours.grey)
        mon.setCursorPos(2, 2)
        mon.write(string.rep("\\127", MW - 2))
        mon.setTextColour(colours.lightGrey)
        mon.setCursorPos(2, 3)
        mon.write("YOUR MOVIES")
        mon.setBackgroundColour(colours.grey)
        mon.setTextColour(colours.white)
        mon.setCursorPos(1, MH)
        mon.write(string.rep(" ", MW))
        mon.setCursorPos(2, MH)
        mon.write("<> move   Enter open   " .. tostring(#items) .. " items")
        mon.setBackgroundColour(colours.black)
    end

    drawChrome()
    while true do
        if sel < scroll then scroll = sel end
        if sel > scroll + fit - 1 then scroll = sel - fit + 1 end
        for k = 0, fit - 1 do
            local idx = scroll + k
            local it = items[idx]
            if not it then break end
            drawCard(it, 2 + k * (CARD_W + GAP), cardsY, idx == sel)
        end
        local _, key = os.pullEvent("key")
        if key == keys.right and sel < #items then sel = sel + 1 end
        if key == keys.left and sel > 1 then sel = sel - 1 end
        if (key == keys.enter or key == keys.space) and items[sel] then
            return items[sel]
        end
    end
end

local function box(x0, y0, w, h, borderColour)
    mon.setTextColour(borderColour or colours.grey)
    mon.setBackgroundColour(colours.black)
    mon.setCursorPos(x0, y0)
    mon.write("+" .. string.rep("-", w - 2) .. "+")
    for r = 1, h - 2 do
        mon.setCursorPos(x0, y0 + r)
        mon.write("|" .. string.rep(" ", w - 2) .. "|")
    end
    mon.setCursorPos(x0, y0 + h - 1)
    mon.write("+" .. string.rep("-", w - 2) .. "+")
end

local function settingsScreen()
    local PERIOD = 1.0
    local pw = math.min(MW - 4, 64)
    local ph = 13
    local px = math.max(2, math.floor((MW - pw) / 2))
    local py = math.max(2, math.floor((MH - ph) / 2))

    mon.setBackgroundColour(colours.black)
    mon.clear()
    box(px, py, pw, ph, colours.blue)
    mon.setTextColour(colours.yellow)
    mon.setBackgroundColour(colours.black)
    mon.setCursorPos(px + 2, py)
    mon.write(" AUDIO SYNC ")

    local valueY, railY, noteY = py + 3, py + 6, py + 8

    local function drawValue()
        local dv = ("Audio delay: %+.1f s"):format(DELAY_MS / 1000)
        mon.setTextColour(colours.white)
        mon.setCursorPos(px + math.floor((pw - #dv) / 2), valueY)
        mon.write(dv .. string.rep(" ", 4))
        mon.setTextColour(colours.lightBlue)
        mon.setCursorPos(px + 2, noteY)
        mon.write("align the click with each bounce")
    end

    local function drawRail()
        local rw = pw - 12
        mon.setBackgroundColour(colours.black)
        mon.setCursorPos(px + 3, railY)
        mon.write(" ")
        mon.setBackgroundColour(colours.grey)
        mon.setCursorPos(px + 4, railY)
        mon.write(string.rep(" ", rw))
        mon.setBackgroundColour(colours.lightGrey)
        mon.setCursorPos(px + 3, railY)
        mon.write(" ")
        mon.setCursorPos(px + 3 + rw + 1, railY)
        mon.write(" ")
        mon.setBackgroundColour(colours.black)
    end

    local function drawBall(frac)
        local rw = pw - 12
        mon.setBackgroundColour(colours.grey)
        mon.setCursorPos(px + 5, railY)
        mon.write(string.rep(" ", rw - 2))
        mon.setBackgroundColour(colours.red)
        mon.setCursorPos(px + 5 + math.floor((rw - 2) * frac), railY)
        mon.write(" ")
        mon.setBackgroundColour(colours.black)
    end

    local footer = "<> delay 0.1s   [Enter] back"
    mon.setBackgroundColour(colours.grey)
    mon.setTextColour(colours.white)
    mon.setCursorPos(px + math.floor((pw - #footer) / 2), py + ph - 2)
    mon.write(footer)
    mon.setBackgroundColour(colours.black)

    drawValue()
    drawRail()

    local t0 = os.clock()
    local hitK = 1
    while true do
        drawBall((os.clock() - t0) % PERIOD / PERIOD)
        while os.clock() >= t0 + hitK * PERIOD + DELAY_MS / 1000 do
            if sp then sp.playNote("pling", 20, 1) end
            hitK = hitK + 1
        end
        local id = os.startTimer(0.04)
        local ev, p = os.pullEvent()
        if ev == "key" then
            if p == keys.right then
                DELAY_MS = math.min(5000, DELAY_MS + 100)
                saveDelay()
                drawValue()
            elseif p == keys.left then
                DELAY_MS = math.max(-5000, DELAY_MS - 100)
                saveDelay()
                drawValue()
            elseif p == keys.enter or p == keys.q or p == keys.backspace then
                return
            end
        end
    end
end

local function play(NAME)
    for _, f in ipairs(fs.list("")) do
        if f:match("%.ccm%.%d+$") then fs.delete(f) end
    end

    local function pname(i) return NAME .. ".ccm." .. i end

    print("Fetching " .. NAME .. "...")
    local res, err = http.get(BASE .. "/" .. urlencode(NAME) .. ".meta", nil, true)
    if not res then error("Meta download failed: " .. tostring(err), 0) end
    local body = res.readAll()
    res.close()
    local mf = fs.open(NAME .. ".meta", "wb")
    mf.write(body)
    mf.close()

    mf = fs.open(NAME .. ".meta", "r")
    local hdr = mf.readLine()
    mf.close()
    local w, h, fps, partCount = hdr:match("(%d+) (%d+) (%d+) (%d+)")
    w, h, fps, partCount = tonumber(w), tonumber(h), tonumber(fps), tonumber(partCount)
    if not w then error("Corrupt meta file", 0) end
    local lastPart = partCount - 1

    local win = window.create(mon, 1, 1, w, h, false)

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
    local speedT0 = os.clock()
    local speedB0 = 0

    local function uiStatus(sub)
        if not uiEnabled then return end
        local ok = pcall(function()
            local b = bufferedAhead()
            local frac = math.min(1, b / PREFILL)
            local pct = math.floor(frac * 100 + 0.5)

            mon.setBackgroundColour(colours.black)
            mon.clear()
            local pw = math.min(MW - 4, 56)
            local ph = 13
            local px = math.max(2, math.floor((MW - pw) / 2))
            local py = math.max(2, math.floor((MH - ph) / 2))

            box(px, py, pw, ph, colours.blue)
            mon.setTextColour(colours.yellow)
            mon.setBackgroundColour(colours.black)
            mon.setCursorPos(px + 2, py)
            mon.write(" NOW LOADING ")

            local title = #NAME > pw - 6 and NAME:sub(1, pw - 6) or NAME
            mon.setTextColour(colours.white)
            mon.setCursorPos(px + 3, py + 2)
            mon.write(title)

            local pctStr = pct .. "%"
            mon.setTextColour(colours.lime)
            mon.setCursorPos(px + 3, py + 4)
            mon.write(pctStr)

            local bx, bw = px + 3, pw - 6
            local barY = py + 5
            mon.setTextColour(colours.lightGrey)
            mon.setCursorPos(bx, barY)
            mon.write("[")
            mon.setCursorPos(bx + bw - 1, barY)
            mon.write("]")
            mon.setBackgroundColour(colours.grey)
            mon.setCursorPos(bx + 1, barY)
            mon.write(string.rep(" ", bw - 2))
            local fill = math.min(bw - 2, math.floor((bw - 2) * frac + 0.5))
            if fill > 0 then
                mon.setBackgroundColour(colours.lime)
                mon.setCursorPos(bx + 1, barY)
                mon.write(string.rep(" ", fill))
            end
            mon.setBackgroundColour(colours.black)

            local el = os.clock() - speedT0
            local rate = el > 0.5 and (b - speedB0) / el or 0
            local stats
            if rate > 0 then
                stats = ("%.1f/%.1fMB  %.1fMB/s"):format(b / 1000000, PREFILL / 1000000, rate / 1000000)
            else
                stats = ("%.1f/%.1fMB"):format(b / 1000000, PREFILL / 1000000)
            end
            mon.setTextColour(colours.lightGrey)
            mon.setCursorPos(bx + 1, py + 7)
            mon.write(stats)

            local line = (sub or "loading") .. " " .. SPIN[math.floor(os.clock() * 2) % 4 + 1]
            mon.setTextColour(colours.lightBlue)
            mon.setCursorPos(bx + 1, py + 9)
            mon.write(line)
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
        uiStatusThrottled("buffering")
        if (os.clock() - lastT > 5 or fs.getFreeSpace("") < 1500000) and b >= PART_LOW then
            break
        end
        sleep(0.05)
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
                    uiStatusThrottled("rebuffering")
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
    local cachedFrame

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
            while os.epoch("utc") < start + fi * frameDur do
                pump(PART_LOW)
                sleep(0.01)
            end
            render(cachedFrame)
            fi = fi + 1
            framesPlayed = framesPlayed + 1
        end

        while #pendingAudio > 0 and sp and start do
            local due = start + ai * 250 + DELAY_MS
            if os.epoch("utc") < due - 120 then break end
            if due > start + fi * frameDur + 120 then break end
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
    win.setVisible(false)
    mon.setBackgroundColour(colours.black)
    mon.clear()
end

local argName = ...
if argName and #argName > 0 then
    play(argName)
    resetPalette()
    term.clear()
    term.setCursorPos(1, 1)
    return
end

local movies = fetchMovies()
while true do
    local it = homeMenu(movies)
    if it.kind == "settings" then
        settingsScreen()
    else
        play(it.label)
        resetPalette()
        movies = fetchMovies()
    end
end
