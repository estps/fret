
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

local THEME = {
    { colours.grey,      22, 24, 29 },
    { colours.lightGrey, 54, 58, 68 },
    { colours.blue,      30, 42, 78 },
    { colours.lightBlue, 146, 158, 176 },
    { colours.lime,      96, 218, 108 },
    { colours.cyan,      62, 198, 216 },
    { colours.yellow,    255, 194, 64 },
    { colours.orange,    255, 138, 44 },
    { colours.purple,    128, 98, 232 },
    { colours.red,       236, 66, 56 },
}
local function applyTheme()
    for _, t in ipairs(THEME) do
        mon.setPaletteColour(t[1], t[2] / 255, t[3] / 255, t[4] / 255)
    end
end
resetPalette()
applyTheme()

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

local function chip(x, y, s, bg, fg)
    mon.setBackgroundColour(bg)
    mon.setTextColour(fg)
    mon.setCursorPos(x, y)
    mon.write(s)
end

local function segments(y, x0, parts, bg)
    mon.setBackgroundColour(bg or colours.black)
    local x = x0
    for _, p in ipairs(parts) do
        if x > MW then break end
        local t = p.t
        if x + #t - 1 > MW then t = t:sub(1, MW - x + 1) end
        mon.setTextColour(p.c)
        mon.setCursorPos(x, y)
        mon.write(t)
        x = x + #t
    end
end

local function centre(y, s, c)
    mon.setTextColour(c)
    mon.setCursorPos(math.max(1, math.floor((MW - #s) / 2) + 1), y)
    mon.write(s)
end

local function box(x0, y0, w, h, borderColour)
    mon.setTextColour(borderColour or colours.lightGrey)
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

local CARD_W, CARD_H, GAP = 17, 8, 2
local HEADER_ROWS = 4
local ACCENTS = { colours.lime, colours.cyan, colours.purple, colours.orange,
                  colours.lightBlue, colours.pink }

local function drawCard(it, idx, cx, cy, selected)
    mon.setBackgroundColour(selected and colours.blue or colours.grey)
    for r = 0, CARD_H - 1 do
        mon.setCursorPos(cx, cy + r)
        mon.write(string.rep(" ", CARD_W))
    end
    local acc = it.kind == "settings" and colours.orange or ACCENTS[((idx - 1) % #ACCENTS) + 1]
    local ini = it.label:match("%a")
    ini = ini and ini:upper() or "#"
    chip(cx + 1, cy + 1, "     ", acc, colours.black)
    chip(cx + 1, cy + 2, "  " .. ini .. "  ", acc, colours.black)
    chip(cx + 1, cy + 3, "     ", acc, colours.black)
    mon.setTextColour(selected and colours.white or colours.lightBlue)
    local t1 = it.label:sub(1, CARD_W - 2)
    local t2 = #it.label > CARD_W - 2 and it.label:sub(CARD_W - 1, CARD_W * 2 - 4) or (it.sub or "")
    mon.setCursorPos(cx + 1, cy + 5)
    mon.write(t1)
    if t2 ~= "" then
        mon.setTextColour(selected and colours.white or colours.lightGrey)
        mon.setCursorPos(cx + 1, cy + 6)
        mon.write(t2:sub(1, CARD_W - 2))
    end
    if selected then
        chip(cx + 1, cy + CARD_H - 1, string.rep(" ", CARD_W - 2), colours.yellow, colours.black)
    end
    mon.setBackgroundColour(colours.black)
end

local function homeMenu(movies)
    local items = {}
    for _, m in ipairs(movies) do items[#items + 1] = { label = m } end
    items[#items + 1] = { label = "Settings", kind = "settings", sub = "audio sync" }
    local fit = math.max(1, math.floor((MW - 2) / (CARD_W + GAP)))
    local sel, scroll = 1, 1
    local cardsY = HEADER_ROWS + 1

    local function drawChrome()
        mon.setBackgroundColour(colours.black)
        mon.clear()
        mon.setTextColour(colours.lime)
        mon.setCursorPos(2, 1)
        mon.write("\127")
        mon.setTextColour(colours.white)
        mon.write(" CC TV")
        mon.setTextColour(colours.lightGrey)
        mon.write("  v3")
        local c = clockStr()
        if c ~= "" then
            mon.setTextColour(colours.lightBlue)
            mon.setCursorPos(math.max(1, MW - #c + 1), 1)
            mon.write(c)
        end
        mon.setTextColour(colours.lightGrey)
        mon.setCursorPos(2, 2)
        mon.write(string.rep("\127", MW - 2))
        mon.setTextColour(colours.white)
        mon.setCursorPos(2, 3)
        mon.write("YOUR MOVIES")
        mon.setTextColour(colours.lightGrey)
        mon.write("  " .. tostring(#movies))
        segments(MH, 1, {
            { t = " <>", c = colours.lime },
            { t = " browse", c = colours.lightBlue },
            { t = "   Enter", c = colours.lime },
            { t = " open", c = colours.lightBlue },
            { t = "   tap", c = colours.cyan },
            { t = " card", c = colours.lightBlue },
        }, colours.grey)
        mon.setTextColour(colours.lightGrey)
        mon.setCursorPos(math.max(1, MW - 9), MH)
        mon.write(tostring(#items) .. " items ")
    end

    local function drawRow()
        mon.setBackgroundColour(colours.black)
        for r = 0, CARD_H - 1 do
            mon.setCursorPos(1, cardsY + r)
            mon.write(string.rep(" ", MW))
        end
        for k = 0, fit - 1 do
            local idx = scroll + k
            local it = items[idx]
            if not it then break end
            drawCard(it, idx, 2 + k * (CARD_W + GAP), cardsY, idx == sel)
        end
        if #movies == 0 then
            mon.setTextColour(colours.lightGrey)
            mon.setCursorPos(2, cardsY + CARD_H + 1)
            mon.write("(no movies yet - transcode one with prepare.py)")
        end
    end

    drawChrome()
    drawRow()
    while true do
        local ev, a, b, c = os.pullEvent()
        local prev = sel
        if ev == "key" then
            local key = a
            if key == keys.right then sel = sel < #items and sel + 1 or 1 end
            if key == keys.left then sel = sel > 1 and sel - 1 or #items end
            if (key == keys.enter or key == keys.space) and items[sel] then
                return items[sel]
            end
        elseif ev == "monitor_touch" then
            local x, y = b, c
            if y >= cardsY and y < cardsY + CARD_H then
                local k = math.floor((x - 2) / (CARD_W + GAP))
                local idx = scroll + k
                local cx = 2 + k * (CARD_W + GAP)
                if idx >= 1 and idx <= #items and x >= cx and x < cx + CARD_W then
                    return items[idx]
                end
            end
        end
        if sel ~= prev then
            local oldScroll = scroll
            if sel < scroll then scroll = sel end
            if sel > scroll + fit - 1 then scroll = sel - fit + 1 end
            if scroll ~= oldScroll then
                drawRow()
            else
                for k = 0, fit - 1 do
                    local idx = scroll + k
                    if idx == sel or idx == prev then
                        drawCard(items[idx], idx, 2 + k * (CARD_W + GAP), cardsY, idx == sel)
                    end
                end
            end
        end
    end
end

local function settingsScreen()
    local PERIOD = 1.0
    local pw = math.min(MW - 4, 60)
    local ph = 13
    local px = math.max(2, math.floor((MW - pw) / 2))
    local py = math.max(2, math.floor((MH - ph) / 2))

    mon.setBackgroundColour(colours.black)
    mon.clear()
    box(px, py, pw, ph, colours.lightGrey)
    chip(px + 2, py, " AUDIO SYNC ", colours.yellow, colours.black)
    mon.setBackgroundColour(colours.black)

    local valueY, railY, noteY = py + 3, py + 6, py + 8

    local function drawValue()
        local dv = ("delay  %+.1f s"):format(DELAY_MS / 1000)
        mon.setTextColour(colours.white)
        mon.setCursorPos(px + math.floor((pw - #dv) / 2), valueY)
        mon.write(dv .. string.rep(" ", 4))
        centre(noteY, "align the click with each bounce", colours.lightBlue)
        mon.setBackgroundColour(colours.black)
    end

    local rw = pw - 12

    local function drawRail(frac)
        mon.setBackgroundColour(colours.lightGrey)
        mon.setCursorPos(px + 4, railY)
        mon.write(string.rep(" ", rw))
        local bx2 = px + 4 + math.min(rw - 1, math.floor(rw * frac))
        chip(bx2, railY, " ", colours.yellow, colours.black)
        mon.setBackgroundColour(colours.black)
    end

    local btnY = py + ph - 3
    local btnW = 7
    local totalW = btnW * 2 + 6 + 4
    local bx0 = px + math.floor((pw - totalW) / 2)
    local minusRect = { x = bx0, y = btnY, w = btnW }
    local backRect = { x = bx0 + btnW + 2, y = btnY, w = 6 }
    local plusRect = { x = bx0 + btnW + 10, y = btnY, w = btnW }

    local function drawButtons()
        chip(minusRect.x, btnY, " -0.1s ", colours.lightGrey, colours.white)
        chip(backRect.x, btnY, " BACK ", colours.grey, colours.lightBlue)
        chip(plusRect.x, btnY, " +0.1s ", colours.lightGrey, colours.white)
        mon.setBackgroundColour(colours.black)
    end

    drawValue()
    drawRail(0)
    drawButtons()

    local function hit(r, x, y)
        return x >= r.x and x < r.x + r.w and y == r.y
    end

    local t0 = os.clock()
    local hitK = 1
    while true do
        drawRail((os.clock() - t0) % PERIOD / PERIOD)
        while os.clock() >= t0 + hitK * PERIOD + DELAY_MS / 1000 do
            if sp then sp.playNote("pling", 20, 1) end
            hitK = hitK + 1
        end
        local id = os.startTimer(0.04)
        local ev, p, tx, ty = os.pullEvent()
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
        elseif ev == "monitor_touch" then
            if hit(minusRect, tx, ty) then
                DELAY_MS = math.max(-5000, DELAY_MS - 100)
                saveDelay()
                drawValue()
            elseif hit(plusRect, tx, ty) then
                DELAY_MS = math.min(5000, DELAY_MS + 100)
                saveDelay()
                drawValue()
            elseif hit(backRect, tx, ty) then
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
    local enc = urlencode(NAME)

    print("Fetching " .. NAME .. "...")
    local res, err = http.get(BASE .. "/" .. enc .. "/" .. enc .. ".meta", nil, true)
    if not res then error("Meta download failed: " .. tostring(err), 0) end
    local body = res.readAll()
    res.close()
    local mf = fs.open(NAME .. ".meta", "wb")
    mf.write(body)
    mf.close()

    mf = fs.open(NAME .. ".meta", "r")
    local hdr = mf.readLine()
    mf.close()
    local w, h, fps, partCount, blk = hdr:match("^(%d+) (%d+) (%d+) (%d+) (%d*)")
    w, h, fps, partCount = tonumber(w), tonumber(h), tonumber(fps), tonumber(partCount)
    if not w then error("Corrupt meta file", 0) end
    local n = tonumber(blk) or 1
    local cw, ch = w * n, h * n
    local lastPart = partCount - 1

    local win = window.create(mon, 1, 1, cw, ch, false)

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

    local start = nil
    local fi, ai = 0, 0
    local frameDur = 1000 / fps
    local pendingAudio = {}
    local cachedFrame
    local curPart = 0
    local hnd = nil
    local paused = false
    local pausedAt = nil
    local abortPlay = false

    local function closeDl()
        if dl then
            pcall(function() dl.fh.close() end)
            pcall(function() dl.res.close() end)
            pcall(fs.delete, pname(dl.idx))
            dl = nil
        end
    end

    local lastUiDraw = 0
    local uiEnabled = true
    local uiBuilt = false
    local SPIN = { "|", "/", "-", "\\" }
    local speedT0 = os.clock()
    local speedB0 = 0
    local LW = math.min(MW - 4, 56)
    local LH = 13
    local LX = math.max(2, math.floor((MW - LW) / 2))
    local LY = math.max(2, math.floor((MH - LH) / 2))
    local LBX, LBW = LX + 3, LW - 6

    local function buildLoading()
        mon.setBackgroundColour(colours.black)
        mon.clear()
        box(LX, LY, LW, LH, colours.lightGrey)
        chip(LX + 2, LY, " NOW LOADING ", colours.lime, colours.black)
        mon.setBackgroundColour(colours.black)
        local title = #NAME > LBW and NAME:sub(1, LBW) or NAME
        mon.setTextColour(colours.white)
        mon.setCursorPos(LBX, LY + 2)
        mon.write(title)
        mon.setBackgroundColour(colours.lightGrey)
        mon.setCursorPos(LBX + 1, LY + 5)
        mon.write(string.rep(" ", LBW - 2))
        mon.setBackgroundColour(colours.black)
        mon.setTextColour(colours.lightGrey)
        mon.setCursorPos(LBX + 1, LY + 5)
        mon.write("[")
        mon.setCursorPos(LBX + LBW - 2, LY + 5)
        mon.write("]")
        segments(LY + LH - 2, LBX + 1, {
            { t = " Q", c = colours.yellow },
            { t = " cancel", c = colours.lightBlue },
        }, colours.grey)
        uiBuilt = true
    end

    local function uiStatus(sub)
        if not uiEnabled then return end
        local ok = pcall(function()
            if not uiBuilt then buildLoading() end
            local b = bufferedAhead()
            local frac = math.min(1, b / PREFILL)
            local pctStr = tostring(math.floor(frac * 100 + 0.5)) .. "%"
            mon.setTextColour(colours.lime)
            mon.setBackgroundColour(colours.black)
            mon.setCursorPos(LBX, LY + 4)
            mon.write(pctStr .. string.rep(" ", 8 - #pctStr))
            mon.setBackgroundColour(colours.lightGrey)
            mon.setCursorPos(LBX + 1, LY + 5)
            mon.write(string.rep(" ", LBW - 2))
            local fill = math.min(LBW - 4, math.floor((LBW - 4) * frac + 0.5))
            if fill > 0 then
                mon.setBackgroundColour(colours.lime)
                mon.setCursorPos(LBX + 2, LY + 5)
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
            if #stats > LBW - 2 then stats = stats:sub(1, LBW - 2) end
            mon.setTextColour(colours.lightBlue)
            mon.setCursorPos(LBX + 1, LY + 7)
            mon.write(stats .. string.rep(" ", LBW - 1 - #stats))
            local line = ((sub or "loading") .. " " .. SPIN[math.floor(os.clock() * 2) % 4 + 1])
            if #line > LBW - 2 then line = line:sub(1, LBW - 2) end
            mon.setTextColour(colours.cyan)
            mon.setCursorPos(LBX + 1, LY + 9)
            mon.write(line .. string.rep(" ", LBW - 1 - #line))
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
            local res, err = http.get(BASE .. "/" .. enc .. "/" .. urlencode(pname(dlCur)), nil, true)
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

    local function render(frame)
        local y = 1
        for r0 in string.gmatch(frame, "[^;]+") do
            if y > ch then break end
            win.setCursorPos(1, y)
            local r = r0
            local n2 = #r
            if n2 >= cw then
                r = r:sub(1, cw)
                win.blit(string.rep(" ", cw), r, r)
            elseif n2 > 0 then
                local pad = r:sub(-1):rep(cw - n2)
                win.blit(string.rep(" ", cw), r .. pad, r .. pad)
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
        for _ = 1, ch do
            rows[#rows + 1] = table.concat(cells, "", pos, pos + cw - 1)
            pos = pos + cw
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

    local resumeRect, menuRect

    local function inRect(r, x, y)
        return r ~= nil and y == r.y and x >= r.x and x < r.x + r.w
    end

    local function drawPauseBar(on)
        if on then
            mon.setBackgroundColour(colours.grey)
            mon.clearLine()
            mon.setCursorPos(1, MH)
            mon.write(string.rep(" ", MW))
            chip(1, MH, " II PAUSED ", colours.yellow, colours.black)
            mon.setBackgroundColour(colours.grey)
            mon.setTextColour(colours.lightBlue)
            mon.setCursorPos(13, MH)
            if MW >= 44 then
                local menuW, resumeW = 8, 10
                local menuX = MW - menuW + 1
                local resumeX = menuX - resumeW - 1
                mon.write("SPACE / tap")
                chip(resumeX, MH, "  RESUME  ", colours.lime, colours.black)
                chip(menuX, MH, "  MENU  ", colours.orange, colours.black)
                resumeRect = { x = resumeX, y = MH, w = resumeW }
                menuRect = { x = menuX, y = MH, w = menuW }
            else
                mon.write("SPACE resume   Q menu")
                resumeRect, menuRect = nil, nil
            end
            mon.setBackgroundColour(colours.black)
        else
            resumeRect, menuRect = nil, nil
            mon.setBackgroundColour(colours.black)
            mon.setCursorPos(1, MH)
            mon.write(string.rep(" ", MW))
        end
    end

    local function setPaused(v)
        if v == paused or not start then return end
        paused = v
        if paused then
            pausedAt = os.epoch("utc")
            drawPauseBar(true)
        else
            start = start + (os.epoch("utc") - pausedAt)
            drawPauseBar(false)
            if cachedFrame then render(cachedFrame) end
        end
    end

    local function handlePlayKey(p1)
        if p1 == keys.space or p1 == keys.p then
            setPaused(not paused)
        elseif p1 == keys.q or p1 == keys.backspace then
            abortPlay = true
        end
    end

    local function handleTouch(x, y)
        if not start then return end
        if paused then
            if inRect(menuRect, x, y) then
                abortPlay = true
            else
                setPaused(false)
            end
        else
            setPaused(true)
        end
    end

    local function waitEvents(t)
        local id = os.startTimer(t)
        local ev, a, b, c = os.pullEvent()
        if ev == "key" then
            handlePlayKey(a)
        elseif ev == "monitor_touch" then
            handleTouch(b, c)
        end
    end

    local function cleanup()
        closeDl()
        if hnd then pcall(function() hnd.close() end) hnd = nil end
        if sp then pcall(sp.stop) end
    end

    local lastB, lastT = -1, os.clock()
    while not abortPlay and dlCur <= lastPart and bufferedAhead() < PREFILL do
        pump(PREFILL)
        local b = bufferedAhead()
        if b ~= lastB then lastB, lastT = b, os.clock() end
        uiStatusThrottled("buffering")
        if (os.clock() - lastT > 5 or fs.getFreeSpace("") < 1500000) and b >= PART_LOW then
            break
        end
        waitEvents(0.05)
    end
    speedT0 = os.clock()
    speedB0 = bufferedAhead()
    if abortPlay then
        cleanup()
        mon.setBackgroundColour(colours.black)
        mon.clear()
        return
    end

    local function nextRecord()
        while true do
            if not hnd then
                while not abortPlay and not fs.exists(pname(curPart)) do
                    pump(PART_LOW)
                    uiStatusThrottled("rebuffering")
                    waitEvents(0.05)
                end
                if abortPlay then return nil end
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

    local lastIter = os.clock()
    while not abortPlay do
        local t, payload = nextRecord()
        if abortPlay or not t then break end

        if t == 1 then
            applyPalette(payload)
        elseif t == 4 then
            if sp then pendingAudio[#pendingAudio + 1] = payload end
        elseif t == 0 or t == 2 or t == 3 then
            if t ~= 0 then
                cachedFrame = (t == 3) and decodeRLE(payload) or decodePacked(payload)
            end
            if not start then start = os.epoch("utc") + 150 end
            while not abortPlay do
                if not paused and os.epoch("utc") >= start + fi * frameDur then break end
                pump(PART_LOW)
                waitEvents(paused and 0.15 or 0.02)
            end
            if abortPlay then break end
            if not paused then
                render(cachedFrame)
                fi = fi + 1
            end
        end

        while #pendingAudio > 0 and sp and start and not paused do
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

    if not abortPlay then
        while #pendingAudio > 0 and sp do
            playAudioChunk(table.remove(pendingAudio, 1))
        end
    end

    cleanup()
    win.setVisible(false)
    mon.setBackgroundColour(colours.black)
    mon.clear()
end

local argName = ...
if argName and #argName > 0 then
    play(argName)
    resetPalette()
    applyTheme()
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
        applyTheme()
        movies = fetchMovies()
    end
end
