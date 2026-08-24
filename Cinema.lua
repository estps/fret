
local BASE = "https://simple-greene-freight-back.trycloudflare.com"

local PART_LOW = 4000000
local PREFILL = 7500000
local IDLE_SAVER = 75

local SETTINGS_FILE = ".cctv_settings"
local DELAY_MS = 0
local VOL = 1.0
local SFX = true
if fs.exists(SETTINGS_FILE) then
    local f = fs.open(SETTINGS_FILE, "r")
    local first = f.readLine() or ""
    if first:find("=") then
        f.seek("set", 0)
        while true do
            local ln = f.readLine()
            if not ln then break end
            local k, v = ln:match("^(%w+)=(.+)$")
            if k == "delay" then DELAY_MS = tonumber(v) or 0 end
            if k == "vol" then VOL = math.min(3, math.max(0, tonumber(v) or 1)) end
            if k == "sfx" then SFX = v == "1" end
        end
    else
        DELAY_MS = tonumber(first) or 0
    end
    f.close()
end
local function saveSettings()
    local f = fs.open(SETTINGS_FILE, "w")
    f.write(("delay=%d\nvol=%.2f\nsfx=%d\n"):format(DELAY_MS, VOL, SFX and 1 or 0))
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
    { colours.green,     60, 160, 70 },
    { colours.magenta,   214, 80, 200 },
    { colours.pink,      235, 120, 170 },
    { colours.brown,     130, 90, 55 },
    { colours.white,     236, 238, 242 },
    { colours.black,     5, 6, 9 },
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
    local found, ok = {}, false
    local res = http.get(BASE .. "/movies.txt", nil, true)
    if res then
        ok = true
        local body = res.readAll()
        res.close()
        for line in body:gmatch("[^\r\n]+") do
            local lab, dur = line:match("^(.-)%s+(%-?%d+%.?%d*)$")
            if lab and #lab > 0 then
                found[#found + 1] = { label = lab, dur = tonumber(dur) }
            elseif #line > 0 then
                found[#found + 1] = { label = line }
            end
        end
    end
    if #found == 0 then
        for _, f in ipairs(fs.list("")) do
            local n = f:match("^(.+)%.meta$")
            if n and #n > 0 then found[#found + 1] = { label = n } end
        end
    end
    return found, ok
end

local SEEN_FILE = ".cctv_seen"
local seen = {}
if fs.exists(SEEN_FILE) then
    local f = fs.open(SEEN_FILE, "r")
    while true do
        local ln = f.readLine()
        if not ln then break end
        seen[ln] = true
    end
    f.close()
end
local function markSeen(name)
    seen[name] = true
    local f = fs.open(SEEN_FILE, "w")
    for k in pairs(seen) do f.write(k .. "\n") end
    f.close()
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
    mon.setBackgroundColour(colours.black)
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

local GLYPH = {
    C = { " ### ", "#   #", "#    ", "#   #", " ### " },
    T = { "#####", "  #  ", "  #  ", "  #  ", "  #  " },
    V = { "#   #", "#   #", "#   #", " # # ", "  #  " },
    P = { "#### ", "#   #", "#### ", "#    ", "#    " },
    A = { " ### ", "#   #", "#####", "#   #", "#   #" },
    U = { "#   #", "#   #", "#   #", "#   #", " ### " },
    S = { " ####", "#    ", " ### ", "    #", "#### " },
    E = { "#####", "#    ", "###  ", "#    ", "#####" },
    D = { "#### ", "#   #", "#   #", "#   #", "#### " },
}

local function drawGlyph(ch, x, y, c)
    local g = GLYPH[ch]
    if not g then return end
    mon.setBackgroundColour(c)
    for r = 1, 5 do
        for i = 1, 5 do
            if g[r]:sub(i, i) == "#" then
                mon.setCursorPos(x + i - 1, y + r - 1)
                mon.write(" ")
            end
        end
    end
    mon.setBackgroundColour(colours.black)
end

local function wordWidth(w) return #w * 6 - 1 end

local function drawWord(w, x, y, c)
    for i = 1, #w do
        local ch = w:sub(i, i)
        if ch ~= " " then drawGlyph(ch, x + (i - 1) * 6, y, c) end
    end
    mon.setBackgroundColour(colours.black)
end

local function drawLogo(x, y)
    local cx = x
    drawGlyph("C", cx, y, colours.lime); cx = cx + 6
    drawGlyph("C", cx, y, colours.lime); cx = cx + 7
    drawGlyph("T", cx, y, colours.cyan); cx = cx + 6
    drawGlyph("V", cx, y, colours.cyan)
    mon.setBackgroundColour(colours.black)
end

local function fmtDur(sec)
    if not sec or sec <= 0 then return nil end
    sec = math.floor(sec + 0.5)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then return ("%dh%02dm"):format(h, m) end
    if m > 0 then return ("%dm"):format(m) end
    return ("%ds"):format(sec)
end

local function blip(kind)
    if not SFX or not sp then return end
    pcall(function()
        if kind == "move" then sp.playNote("bit", 0.25, 20)
        elseif kind == "open" then sp.playNote("bit", 0.3, 16)
        elseif kind == "back" then sp.playNote("bit", 0.22, 10)
        else sp.playNote("bit", 0.25, 12) end
    end)
end

local CARD_W, CARD_H = 17, 9
local GAPX, GAPY = 2, 1
local HEADER_ROWS = 8

local function homeMenu(movies, online)
    local items = {}
    for _, m in ipairs(movies) do
        items[#items + 1] = {
            label = m.label, dur = m.dur,
            kind = "movie",
            isNew = not seen[m.label],
        }
    end
    items[#items + 1] = { label = "Settings", kind = "settings", sub = "audio sync" }
    local n = #items

    local cols = math.max(1, math.floor((MW - 2) / (CARD_W + GAPX)))
    local rows = math.max(1, math.min(3, math.floor((MH - HEADER_ROWS - 3) / (CARD_H + GAPY))))
    local totalCols = math.ceil(n / rows)
    local pages = math.max(1, math.ceil(totalCols / cols))
    local cardsY = HEADER_ROWS + 1

    local sel = 1
    local c0 = 0
    local anim = nil
    local tick = 0
    local savedMsg = 0

    local function selCol() return math.floor((sel - 1) / rows) end
    local function selRow() return (sel - 1) % rows end

    local function ensureVisible()
        local c = selCol()
        if c < c0 or c >= c0 + cols then
            anim = { from = c0, to = c - math.floor(cols / 2) + (c < c0 and cols or 0) }
            anim.to = (c < c0) and c or (c - cols + 1)
            anim.t = 0
        end
    end

    local function viewX()
        if anim then
            local f = math.min(1, anim.t)
            return math.floor(anim.from + (anim.to - anim.from) * f + 0.5)
        end
        return c0
    end

    local ACCENTS = { colours.lime, colours.cyan, colours.purple, colours.orange,
                      colours.lightBlue, colours.pink, colours.magenta, colours.green }

    local function drawCardReal(it, idx, x, y, selected)
        local vw = math.min(CARD_W, MW - x + 1)
        if vw < 6 then return end
        local acc = it.kind == "settings" and colours.orange or ACCENTS[((idx - 1) % #ACCENTS) + 1]
        mon.setBackgroundColour(selected and colours.yellow or colours.lightGrey)
        mon.setCursorPos(math.max(1, x + 1), y)
        mon.write(string.rep(" ", math.min(CARD_W - 2, MW - x - 1)))
        mon.setCursorPos(math.max(1, x + 1), y + CARD_H - 1)
        mon.write(string.rep(" ", math.min(CARD_W - 2, MW - x - 1)))
        local bwid = math.min(CARD_W - 2, MW - (x + 1) + 1)
        mon.setBackgroundColour(selected and colours.blue or colours.grey)
        for r = 1, CARD_H - 2 do
            mon.setCursorPos(x + 1, y + r)
            mon.write(string.rep(" ", bwid))
        end
        mon.setBackgroundColour(acc)
        for r = 2, CARD_H - 3 do
            mon.setCursorPos(x + 1, y + r)
            mon.write("  ")
        end
        mon.setBackgroundColour(selected and colours.blue or colours.grey)
        for r = 3, CARD_H - 3, 2 do
            mon.setCursorPos(x + 1, y + r)
            mon.write(" ")
        end
        if selected and x + CARD_W - 2 <= MW then
            mon.setBackgroundColour(colours.yellow)
            for r = 2, CARD_H - 2 do
                mon.setCursorPos(x + CARD_W - 2, y + r)
                mon.write(" ")
            end
        end
        local maxT = math.min(CARD_W - 5, MW - (x + 4) + 1)
        if maxT > 0 then
            local title = it.label
            if selected and #title > CARD_W - 5 then
                local cyc = title .. "   "
                local pos = (math.floor(tick / 4) % (#title + 3)) + 1
                local ext = cyc .. cyc
                title = ext:sub(pos, pos + maxT - 1)
            else
                title = title:sub(1, maxT)
            end
            mon.setTextColour(selected and colours.white or colours.lightBlue)
            mon.setCursorPos(x + 4, y + 2)
            mon.write(title)
            local sub = it.sub or fmtDur(it.dur)
            mon.setTextColour(selected and colours.lightBlue or colours.lightGrey)
            mon.setCursorPos(x + 4, y + 3)
            mon.write(sub and sub:sub(1, maxT) or "")
        end
        local tag = it.kind == "settings" and "SYSTEM"
            or (it.isNew and "NEW!" or "MOVIE")
        local tagX = x + CARD_W - 2 - #tag
        if tagX + #tag <= MW + 1 then
            mon.setTextColour(it.isNew and it.kind ~= "settings" and colours.yellow
                or colours.lightGrey)
            mon.setCursorPos(tagX, y + CARD_H - 3)
            mon.write(tag)
        end
        mon.setBackgroundColour(colours.black)
    end

    local function drawGrid()
        local vx = viewX()
        local cA = math.max(0, vx)
        local cB = vx + cols
        mon.setBackgroundColour(colours.black)
        local bandH = rows * (CARD_H + GAPY) - GAPY
        for r = 0, bandH - 1 do
            mon.setCursorPos(1, cardsY + r)
            mon.write(string.rep(" ", MW))
        end
        for c = cA, cB do
            for r = 0, rows - 1 do
                local idx = c * rows + r + 1
                local it = items[idx]
                if it then
                    local x = 2 + (c - vx) * (CARD_W + GAPX)
                    local y = cardsY + r * (CARD_H + GAPY)
                    drawCardReal(it, idx, x, y, idx == sel)
                end
            end
        end
        if n <= 1 then
            mon.setTextColour(colours.lightGrey)
            mon.setCursorPos(2, cardsY + bandH + 1)
            mon.write("(no movies yet - transcode one with prepare.py)")
        end
        if pages > 1 then
            local page = math.floor(c0 / cols) + 1
            local dy = cardsY + rows * (CARD_H + GAPY) + (n <= 1 and 1 or 0)
            local dx = math.max(1, math.floor((MW - pages * 2) / 2) + 1)
            for p = 1, pages do
                mon.setTextColour(colours.black)
                mon.setBackgroundColour(p == page and colours.lime or colours.lightGrey)
                mon.setCursorPos(dx + (p - 1) * 2, dy)
                mon.write("\7")
            end
            mon.setBackgroundColour(colours.black)
        end
    end

    local function drawInfoLine()
        mon.setBackgroundColour(colours.black)
        mon.setCursorPos(2, HEADER_ROWS)
        mon.write(string.rep(" ", MW - 2))
        local it = items[sel]
        if it and it.kind == "movie" then
            mon.setTextColour(colours.lightGrey)
            mon.setCursorPos(2, HEADER_ROWS)
            mon.write(("%d/%d"):format(sel, n))
            if it.dur then
                mon.write("  " .. fmtDur(it.dur))
            end
            if it.isNew then
                chip(math.max(1, MW - 11), HEADER_ROWS, " UNWATCHED ", colours.yellow, colours.black)
            end
        end
    end

    local function drawChrome()
        mon.setBackgroundColour(colours.black)
        mon.clear()
        drawLogo(2, 1)
        local cs = clockStr()
        segments(5, MW - 17, {
            { t = online and " ONLINE " or " OFFLINE", c = colours.black },
        }, online and colours.green or colours.red)
        if cs ~= "" then
            mon.setTextColour(colours.lightBlue)
            mon.setBackgroundColour(colours.black)
            mon.setCursorPos(math.max(1, MW - #cs + 1), 5)
            mon.write(cs)
        end
        mon.setTextColour(colours.lightGrey)
        mon.setCursorPos(2, 6)
        mon.write(string.rep("\127", MW - 2))
        mon.setTextColour(colours.white)
        mon.setCursorPos(2, 7)
        mon.write("YOUR MOVIES")
        mon.setTextColour(colours.lightGrey)
        drawInfoLine()
        segments(MH, 1, {
            { t = " <>", c = colours.lime },
            { t = " browse", c = colours.lightBlue },
            { t = "   Enter", c = colours.lime },
            { t = " open", c = colours.lightBlue },
            { t = "   tap", c = colours.cyan },
            { t = " card", c = colours.lightBlue },
            { t = "   H", c = colours.lime },
            { t = " help", c = colours.lightBlue },
        }, colours.grey)
        mon.setTextColour(colours.lightGrey)
        mon.setCursorPos(math.max(1, MW - 9), MH)
        mon.write(tostring(n) .. " items ")
    end

    local function helpOverlay()
        box(4, 4, math.min(MW - 8, 44), 13, colours.cyan)
        chip(6, 4, " CONTROLS ", colours.cyan, colours.black)
        local lines = {
            { "<> / tap edges",   "browse pages" },
            { "up/down",          "switch row" },
            { "Enter / tap card", "play" },
            { "R / tap status",   "refresh list" },
            { "SPACE or tap",     "pause / resume" },
            { "Q / BACKSPACE",    "back to menu" },
            { "in player:",       "MENU chip exits" },
        }
        for i, l in ipairs(lines) do
            mon.setTextColour(colours.white)
            mon.setCursorPos(6, 4 + i)
            mon.write(l[1])
            mon.setTextColour(colours.lightBlue)
            mon.setCursorPos(6 + 16, 4 + i)
            mon.write(l[2])
        end
        centre(4 + 9, "press any key or tap to close", colours.lightGrey)
        os.pullEvent()
        blip("back")
    end

    local function saverLoop()
        local sx, sy = 3, 3
        local dx, dy = 1, 1
        while true do
            mon.setBackgroundColour(colours.black)
            mon.clear()
            drawLogo(sx, sy)
            centre(MH - 2, clockStr(), colours.lightBlue)
            local step = 0.12
            sx = sx + dx * 3
            sy = sy + dy
            if sx < 1 then sx = 1; dx = 1 end
            if sy < 1 then sy = 1; dy = 1 end
            if sx + 25 > MW then sx = MW - 25; dx = -1 end
            if sy + 5 > MH then sy = MH - 5; dy = -1 end
            local id = os.startTimer(step)
            local ev = os.pullEvent()
            if ev == "key" or ev == "monitor_touch" then
                blip("back")
                return
            end
        end
    end

    local lastEvent = os.clock()
    drawChrome()
    drawGrid()
    while true do
        local id = os.startTimer(0.1)
        local ev, a, b, cc = os.pullEvent()
        local needsRedraw = false

        if os.clock() - lastEvent > IDLE_SAVER then
            saverLoop()
            drawChrome()
            drawGrid()
            lastEvent = os.clock()
        end

        if ev == "timer" and a == id then
            tick = tick + 1
            if anim then
                anim.t = anim.t + 0.34
                if anim.t >= 1 then
                    c0 = anim.to
                    anim = nil
                end
                drawGrid()
            else
                local it = items[sel]
                if tick % 4 == 0 and it and it.kind == "movie"
                    and #it.label > CARD_W - 5 then
                    drawGrid()
                end
            end
        elseif ev == "key" then
            lastEvent = os.clock()
            local prev = sel
            if a == keys.right then sel = sel >= n and 1 or sel + 1 end
            if a == keys.left then sel = sel <= 1 and n or sel - 1 end
            if a == keys.up and sel - rows >= 1 then sel = sel - rows end
            if a == keys.down and sel + rows <= n then sel = sel + rows end
            if sel ~= prev then
                blip("move")
                ensureVisible()
                drawGrid()
                drawInfoLine()
            end
            if a == keys.enter or a == keys.space then
                if items[sel] then blip("open") return items[sel] end
            end
            if a == keys.h then helpOverlay(); drawChrome(); drawGrid() end
            if a == keys.r then return { kind = "_refresh" } end
        elseif ev == "monitor_touch" then
            lastEvent = os.clock()
            local x, y = b, cc
            if y == 5 and x >= MW - 18 then
                return { kind = "_refresh" }
            end
            if x <= 1 and pages > 1 then
                c0 = math.max(0, c0 - cols); anim = nil; blip("page"); drawGrid()
            elseif x >= MW and pages > 1 then
                c0 = math.min(totalCols - cols, c0 + cols); anim = nil; blip("page"); drawGrid()
            else
                local rel = y - cardsY
                if rel >= 0 then
                    local r = math.floor(rel / (CARD_H + GAPY))
                    local within = rel % (CARD_H + GAPY)
                    if r < rows and within < CARD_H then
                        local k = math.floor((x - 2) / (CARD_W + GAPX))
                        local c = c0 + k
                        local cx = 2 + k * (CARD_W + GAPX)
                        local idx = c * rows + r + 1
                        if idx >= 1 and idx <= n and x >= cx and x < cx + CARD_W and x < MW - 1 then
                            sel = idx
                            blip("open")
                            return items[idx]
                        end
                    end
                end
            end
        end
        if savedMsg > 0 and os.clock() > savedMsg then savedMsg = 0 end
    end
end

local function settingsScreen()
    local PERIOD = 1.0
    local pw = math.min(MW - 4, 60)
    local ph = 16
    local px = math.max(2, math.floor((MW - pw) / 2))
    local py = math.max(2, math.floor((MH - ph) / 2))

    mon.setBackgroundColour(colours.black)
    mon.clear()
    box(px, py, pw, ph, colours.lightGrey)
    chip(px + 2, py, " AUDIO SYNC ", colours.yellow, colours.black)
    mon.setBackgroundColour(colours.black)

    local valueY, railY, noteY, btnY, volY, sfxY, swY =
        py + 2, py + 4, py + 6, py + 8, py + 10, py + 12, py + 13
    local rw = pw - 12
    local railX = px + 4
    local pendingClick = nil
    local savedAt = 0

    local function drawValue()
        local dv = ("%+.1f s  (%+d ms)"):format(DELAY_MS / 1000, DELAY_MS)
        mon.setTextColour(colours.white)
        mon.setBackgroundColour(colours.black)
        mon.setCursorPos(px + math.floor((pw - #dv) / 2), valueY)
        mon.write(dv .. string.rep(" ", 6))
        if os.clock() - savedAt < 0.6 then
            chip(px + pw - 10, valueY, " SAVED ", colours.lime, colours.black)
        end
        centre(noteY, "align the click with each bounce", colours.lightBlue)
    end

    local function drawRail(frac)
        mon.setBackgroundColour(colours.lightGrey)
        mon.setCursorPos(railX, railY)
        mon.write(string.rep(" ", rw))
        chip(railX + math.floor(rw / 2), railY, " ", colours.black, colours.white)
        local bx2 = railX + math.min(rw - 1, math.floor(rw * frac))
        chip(bx2, railY, " ", colours.yellow, colours.black)
        mon.setBackgroundColour(colours.black)
    end

    local btnW, gapB = 7, 1
    local defs = {
        { id = "minus", t = " -0.1s ", bg = colours.lightGrey, fg = colours.white },
        { id = "plus",  t = " +0.1s ", bg = colours.lightGrey, fg = colours.white },
        { id = "test",  t = " TEST  ", bg = colours.lime,      fg = colours.black },
        { id = "reset", t = " RESET ", bg = colours.yellow,    fg = colours.black },
        { id = "back",  t = " BACK  ", bg = colours.orange,    fg = colours.black },
    }
    local rowW = #defs * btnW + (#defs - 1) * gapB
    local bx0 = px + math.floor((pw - rowW) / 2)
    for i, d in ipairs(defs) do
        d.x, d.y, d.w = bx0 + (i - 1) * (btnW + gapB), btnY, btnW
    end

    local function drawButtons()
        for _, d in ipairs(defs) do chip(d.x, d.y, d.t, d.bg, d.fg) end
        mon.setBackgroundColour(colours.black)
    end

    local vmX = px + 4
    local barW = 10
    local volMinus = { x = vmX, y = volY, w = 3 }
    local volBarX = vmX + 4
    local volPlus = { x = volBarX + barW + 1, y = volY, w = 3 }

    local function drawVolume()
        chip(volMinus.x, volY, " - ", colours.lightGrey, colours.white)
        mon.setTextColour(colours.lightBlue)
        mon.setCursorPos(volBarX, volY)
        local filled = math.floor(VOL / 3 * barW + 0.5)
        for i = 0, barW - 1 do
            mon.setBackgroundColour(i < filled and colours.cyan or colours.lightGrey)
            mon.setCursorPos(volBarX + i, volY)
            mon.write(" ")
        end
        chip(volPlus.x, volY, " + ", colours.lightGrey, colours.white)
        mon.setBackgroundColour(colours.black)
        mon.setTextColour(colours.lightGrey)
        mon.setCursorPos(volPlus.x + 4, volY)
        mon.write(("%3d%%"):format(math.floor(VOL / 3 * 100 + 0.5)))
        mon.setBackgroundColour(colours.black)
    end

    local sfxBtn = { x = px + 4, y = sfxY, w = 10 }

    local function drawSfx()
        chip(sfxBtn.x, sfxY, SFX and " SFX ON  " or " SFX OFF ", 
             SFX and colours.green or colours.lightGrey, colours.black)
        mon.setBackgroundColour(colours.black)
    end

    local function drawSwatches()
        for i = 1, 16 do
            mon.setBackgroundColour(THEME[i][1])
            mon.setCursorPos(px + 4 + (i - 1), swY)
            mon.write(" ")
        end
        mon.setBackgroundColour(colours.black)
    end

    local function changed()
        saveSettings()
        savedAt = os.clock()
        drawValue()
    end

    drawValue()
    drawRail(0)
    drawButtons()
    drawVolume()
    drawSfx()
    drawSwatches()

    local function hit(r, x, y)
        return x >= r.x and x < r.x + r.w and y == r.y
    end

    local function adjust(d)
        DELAY_MS = math.max(-5000, math.min(5000, DELAY_MS + d))
        changed()
        blip("move")
    end

    local t0 = os.clock()
    local hitK = 1
    while true do
        drawRail((os.clock() - t0) % PERIOD / PERIOD)
        while os.clock() >= t0 + hitK * PERIOD + DELAY_MS / 1000 do
            if sp then pcall(sp.playNote, "pling", 1.0, 20) end
            hitK = hitK + 1
        end
        if pendingClick and os.clock() >= pendingClick then
            if sp then pcall(sp.playNote, "bit", VOL, 16) end
            pendingClick = nil
        end
        drawValue()

        local id = os.startTimer(0.04)
        local ev, p, tx, ty = os.pullEvent()
        if ev == "key" then
            if p == keys.right then adjust(100)
            elseif p == keys.left then adjust(-100)
            elseif p == keys.up then VOL = math.min(3, VOL + 0.1); changed(); drawVolume()
            elseif p == keys.down then VOL = math.max(0, VOL - 0.1); changed(); drawVolume()
            elseif p == keys.t then pendingClick = os.clock() + DELAY_MS / 1000
            elseif p == keys.r then DELAY_MS = 0; changed()
            elseif p == keys.s then SFX = not SFX; changed(); drawSfx()
            elseif p == keys.enter or p == keys.q or p == keys.backspace then
                blip("back") return
            end
        elseif ev == "monitor_touch" then
            local hitBtn = nil
            for _, d in ipairs(defs) do
                if hit(d, tx, ty) then hitBtn = d.id break end
            end
            if hitBtn == "minus" then adjust(-100)
            elseif hitBtn == "plus" then adjust(100)
            elseif hitBtn == "test" then pendingClick = os.clock() + DELAY_MS / 1000
            elseif hitBtn == "reset" then DELAY_MS = 0; changed()
            elseif hitBtn == "back" then blip("back") return
            elseif hit(volMinus, tx, ty) then VOL = math.max(0, VOL - 0.1); changed(); drawVolume()
            elseif hit(volPlus, tx, ty) then VOL = math.min(3, VOL + 0.1); changed(); drawVolume()
            elseif hit(sfxBtn, tx, ty) then SFX = not SFX; changed(); drawSfx(); blip("move")
            elseif ty == railY and tx >= railX and tx < railX + rw then
                local frac = (tx - railX) / (rw - 1)
                DELAY_MS = math.floor((frac * 2 - 1) * 5000 / 100 + 0.5) * 100
                DELAY_MS = math.max(-5000, math.min(5000, DELAY_MS))
                changed()
            end
        end
    end
end

local function play(NAME)
    for _, f in ipairs(fs.list("")) do
        if f:match("%.ccm%.%d+$") or f:match("%.ccm%.%d+%.part$") then fs.delete(f) end
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
    local nb = tonumber(blk) or 1
    local cw, chh = w * nb, h * nb
    local lastPart = partCount - 1

    local win = window.create(mon, 1, 1, cw, chh, false)

    local function toHex(v)
        if v < 10 then return string.char(48 + v) end
        return string.char(87 + v)
    end

    local MAXDL = 2
    local nextPart = 0
    local dls = {}

    local function bufferedAhead()
        local total = 0
        for i = 0, nextPart - 1 do
            local f = pname(i)
            if fs.exists(f) then
                total = total + fs.getSize(f)
            else
                f = f .. ".part"
                if fs.exists(f) then total = total + fs.getSize(f) end
            end
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
        for _, d in ipairs(dls) do
            pcall(function() d.fh.close() end)
            pcall(function() d.res.close() end)
            pcall(fs.delete, d.tmp)
        end
        dls = {}
    end

    local lastUiDraw = 0
    local uiEnabled = true
    local uiBuilt = false
    local SPIN = { "|", "/", "-", "\\" }
    local speedT0 = os.clock()
    local speedB0 = 0
    local LW = math.min(MW - 4, 56)
    local LH = 15
    local LX = math.max(2, math.floor((MW - LW) / 2))
    local LY = math.max(2, math.floor((MH - LH) / 2))
    local LBX, LBW = LX + 3, LW - 6
    local cancelRect = { x = LX + LW - 9, y = LY, w = 8 }

    local function buildLoading()
        mon.setBackgroundColour(colours.black)
        mon.clear()
        box(LX, LY, LW, LH, colours.lightGrey)
        chip(LX + 2, LY, " NOW LOADING ", colours.lime, colours.black)
        chip(cancelRect.x, LY, " CANCEL ", colours.red, colours.white)
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
            if rate > 1 then
                local eta = math.min(999, math.ceil((PREFILL - b) / rate))
                stats = ("%.1f/%.1fMB  %.1fMB/s  ETA %ds")
                    :format(b / 1000000, PREFILL / 1000000, rate / 1000000, eta)
            else
                stats = ("%.1f/%.1fMB"):format(b / 1000000, PREFILL / 1000000)
            end
            if #stats > LBW - 2 then stats = stats:sub(1, LBW - 2) end
            mon.setTextColour(colours.lightBlue)
            mon.setCursorPos(LBX + 1, LY + 7)
            mon.write(stats .. string.rep(" ", LBW - 1 - #stats))
            local meta = ("part %d/%d   disk %dMB free")
                :format(math.min(nextPart, lastPart + 1), lastPart + 1,
                        math.floor(fs.getFreeSpace("") / 1000000))
            if #meta > LBW - 2 then meta = meta:sub(1, LBW - 2) end
            mon.setTextColour(colours.lightGrey)
            mon.setCursorPos(LBX + 1, LY + 9)
            mon.write(meta .. string.rep(" ", LBW - 1 - #meta))
            local line = ((sub or "loading") .. " " .. SPIN[math.floor(os.clock() * 2) % 4 + 1])
            if #line > LBW - 2 then line = line:sub(1, LBW - 2) end
            mon.setTextColour(colours.cyan)
            mon.setCursorPos(LBX + 1, LY + 11)
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
        local k = 1
        while k <= #dls do
            local d = dls[k]
            local piece = d.res.read(16384)
            if piece then
                d.fh.write(piece)
                k = k + 1
            else
                d.fh.close()
                d.res.close()
                if fs.exists(d.tmp) then
                    pcall(fs.move, d.tmp, pname(d.idx))
                end
                table.remove(dls, k)
            end
        end
        while #dls < MAXDL and nextPart <= lastPart
             and bufferedAhead() < target and fs.getFreeSpace("") > 1500000 do
            local res2, err2 = http.get(BASE .. "/" .. enc .. "/" .. urlencode(pname(nextPart)), nil, true)
            if not res2 then
                print("part dl failed: " .. tostring(err2) .. ", retrying")
                sleep(2)
                break
            end
            local tmp = pname(nextPart) .. ".part"
            local fh = fs.open(tmp, "wb")
            dls[#dls + 1] = { idx = nextPart, res = res2, fh = fh, tmp = tmp }
            nextPart = nextPart + 1
        end
    end

    local function render(frame)
        local y = 1
        for r0 in string.gmatch(frame, "[^;]+") do
            if y > chh then break end
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
        for _ = 1, chh do
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
        while not sp.playAudio(tt, VOL) do
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
            local ww = wordWidth("PAUSED")
            local bw = ww + 8
            if MW > bw + 2 then
                local bx = math.floor((MW - bw) / 2) + 1
                local by = math.floor(MH / 2) - 3
                mon.setBackgroundColour(colours.black)
                for r = 0, 6 do
                    mon.setCursorPos(bx, by + r)
                    mon.write(string.rep(" ", bw))
                end
                drawWord("PAUSED", bx + 4, by + 1, colours.yellow)
                centre(by + 6, "tap anywhere to resume", colours.lightBlue)
            end
            local frac = curPart / (lastPart + 1)
            mon.setBackgroundColour(colours.lightGrey)
            mon.setCursorPos(1, MH - 1)
            mon.write(string.rep(" ", MW))
            local pf = math.floor(MW * frac + 0.5)
            if pf > 0 then
                mon.setBackgroundColour(colours.lime)
                mon.setCursorPos(1, MH - 1)
                mon.write(string.rep(" ", pf))
            end
            mon.setBackgroundColour(colours.black)
            local secs = math.floor(bufferedAhead() / 36000)
            centre(MH - 3, ("buffered ~%ds ahead"):format(secs), colours.lightBlue)
        else
            resumeRect, menuRect = nil, nil
            mon.setBackgroundColour(colours.black)
            mon.setCursorPos(1, MH - 1)
            mon.write(string.rep(" ", MW))
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
        if not start then
            if inRect(cancelRect, x, y) then abortPlay = true end
            return
        end
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
    while not abortPlay and nextPart <= lastPart and bufferedAhead() < PREFILL do
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

if MW >= 32 then
    mon.setBackgroundColour(colours.black)
    mon.clear()
    for _, x in ipairs({ 26, 18, 11, 6, 2 }) do
        mon.setBackgroundColour(colours.black)
        mon.clear()
        drawLogo(math.max(2, math.floor(x)), math.floor(MH / 2) - 2)
        sleep(0.06)
    end
    sleep(0.15)
end

local movies, online = fetchMovies()
while true do
    local it = homeMenu(movies, online)
    if it.kind == "_refresh" then
        movies, online = fetchMovies()
    elseif it.kind == "settings" then
        settingsScreen()
    else
        markSeen(it.label)
        play(it.label)
        resetPalette()
        applyTheme()
        movies, online = fetchMovies()
    end
end
