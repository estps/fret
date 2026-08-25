

local BASE = "https://relates-exclude-legend-strand.trycloudflare.com"

local PART_LOW = 4000000
local PREFILL = 5500000
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

local GFX = (mon.setGraphicsMode ~= nil)

local sp = peripheral.find("speaker")

-- Buffer storage: the computer's own root plus every mounted floppy/drive
-- reachable on the network. Parts are striped across all of them round-robin.
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

local function sweepBuffers()
    -- remove buffered parts from every disk (startup hygiene / end of play)
    for _, d in ipairs(DISKS) do
        for _, f in ipairs(fs.list(d)) do
            if f:match("%.ccm%.%d+$") or f:match("%.ccm%.%d+%.part$") then
                fs.delete(fs.combine(d, f))
            end
        end
    end
end

print(("Buffer storage: %d disk(s), %.1f MB free")
    :format(#DISKS, totalFree() / 1000000))

-- throttled debug log for the PC terminal: repeats of the same message are
-- suppressed for 2s so the console stays readable
local lastDbgMsg, lastDbgT = "", 0
local function dbg(msg)
    local now = os.clock()
    if msg == lastDbgMsg and now - lastDbgT < 2 then return end
    lastDbgMsg, lastDbgT = msg, now
    print("[dbg] " .. msg)
end

local savedPal = {}
for i = 0, 15 do
    local ok, c1, c2, c3 = pcall(mon.getPaletteColour, 2 ^ i)
    if ok then savedPal[i + 1] = { c1, c2, c3 } end
end
local function resetPalette()
    for i = 0, 15 do
        if savedPal[i + 1] then
            pcall(mon.setPaletteColour, 2 ^ i, unpack(savedPal[i + 1]))
        end
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
        pcall(mon.setPaletteColour, t[1], t[2] / 255, t[3] / 255, t[4] / 255)
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

local function parseMovieLines(body)
    local found = {}
    for line in body:gmatch("[^\r\n]+") do
        local lab, dur = line:match("^(.-)%s+(%-?%d+%.?%d*)$")
        if lab and #lab > 0 then
            found[#found + 1] = { label = lab, dur = tonumber(dur) }
        elseif #line > 0 then
            found[#found + 1] = { label = line }
        end
    end
    return found
end

local function fetchMovies()
    local found, ok = {}, false
    local res = http.get(BASE .. "/movies.txt", nil, true)
    if res then
        ok = true
        local body = res.readAll()
        res.close()
        found = parseMovieLines(body)
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
    B = { "#### ", "#   #", "#### ", "#   #", "#### " },
    F = { "#####", "#    ", "#### ", "#    ", "#    " },
    G = { " ### ", "#    ", "#  ##", "#   #", " ### " },
    H = { "#   #", "#   #", "#####", "#   #", "#   #" },
    I = { "#####", "  #  ", "  #  ", "  #  ", "#####" },
    J = { "    #", "    #", "    #", "#   #", " ### " },
    K = { "#   #", "#  # ", "###  ", "#  # ", "#   #" },
    L = { "#    ", "#    ", "#    ", "#    ", "#####" },
    M = { "#   #", "## ##", "# # #", "#   #", "#   #" },
    N = { "#   #", "##  #", "# # #", "#  ##", "#   #" },
    O = { " ### ", "#   #", "#   #", "#   #", " ### " },
    Q = { " ### ", "#   #", "# # #", "#  # ", " ## #" },
    R = { "#### ", "#   #", "#### ", "#  # ", "#   #" },
    W = { "#   #", "#   #", "# # #", "## ##", "#   #" },
    X = { "#   #", " # # ", "  #  ", " # # ", "#   #" },
    Y = { "#   #", "#   #", " ### ", "  #  ", "  #  " },
    Z = { "#####", "   # ", "  #  ", " #   ", "#####" },
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
    local v = math.min(1.5, 0.35 * VOL)
    pcall(function()
        if kind == "move" then sp.playNote("bit", v, 16)
        elseif kind == "open" then
            sp.playNote("bit", v, 16)
            sp.playNote("bit", v * 0.8, 21)
        elseif kind == "back" then sp.playNote("bit", v, 9)
        elseif kind == "toggle" then sp.playNote("bit", v, 19)
        elseif kind == "error" then sp.playNote("bit", v, 5)
        elseif kind == "boot" then
            sp.playNote("bit", v * 0.7, 12)
            sp.playNote("bit", v * 0.7, 19)
        elseif kind == "jingle" then
            sp.playNote("pling", v * 0.6, 12)
            sp.playNote("pling", v * 0.6, 16)
            sp.playNote("pling", v * 0.6, 19)
        else sp.playNote("bit", v, 12) end
    end)
end

local function blinds()
    local sw = 8
    local colsN = math.ceil(MW / sw)
    for step = 1, 4 do
        for ci = 0, colsN - 1 do
            if (ci % 4) + 1 == step then
                local x = ci * sw + 1
                local wpart = math.min(sw, MW - x + 1)
                local h = math.ceil(step * MH / 4)
                mon.setBackgroundColour(colours.blue)
                for r = 1, h do
                    mon.setCursorPos(x, r)
                    mon.write(string.rep(" ", wpart))
                end
            end
        end
        sleep(0.05)
    end
    mon.setBackgroundColour(colours.black)
end

local CARD_W, CARD_H = 17, 9
local GAPX, GAPY = 2, 1
local HEADER_ROWS = 8

local TOAST_MSG, TOAST_UNTIL = nil, 0
local function showToast(m)
    TOAST_MSG, TOAST_UNTIL = m, os.clock() + 1.8
end

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
    local rows = math.max(1, math.min(4, math.floor((MH - HEADER_ROWS - 3) / (CARD_H + GAPY))))
    local totalCols = math.ceil(n / rows)
    local pages = math.max(1, math.ceil(totalCols / cols))
    local cardsY = HEADER_ROWS + 1

    local sel = 1
    local c0 = 0
    local anim = nil
    local tick = 0
    local comet = nil
    local onlineNow = online
    local lastFetch = os.clock()
    local refreshInflight = false

    local function recalc()
        n = #items
        totalCols = math.ceil(n / rows)
        pages = math.max(1, math.ceil(totalCols / cols))
        if sel > n then sel = n end
    end

    local function applyMovieList(list)
        movies = list
        local keep = items[sel]
        for i = #items, 1, -1 do items[i] = nil end
        for _, m in ipairs(list) do
            items[#items + 1] = {
                label = m.label, dur = m.dur,
                kind = "movie",
                isNew = not seen[m.label],
            }
        end
        items[#items + 1] = { label = "Settings", kind = "settings", sub = "audio sync" }
        recalc()
        if keep then
            for i = 1, n do
                if items[i].label == keep.label then sel = i break end
            end
        end
    end

    local function drawStatusChip()
        segments(5, MW - 17, {
            { t = onlineNow and " ONLINE " or " OFFLINE", c = colours.black },
        }, onlineNow and colours.green or colours.red)
    end

    local function selCol() return math.floor((sel - 1) / rows) end
    local function selColOf(i) return math.floor((i - 1) / rows) end
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

    local function drawCardReal(it, idx, x, y, selected, pressed)
        local vw = math.min(CARD_W, MW - x + 1)
        if vw < 6 then return end
        local acc = it.kind == "settings" and colours.orange or ACCENTS[((idx - 1) % #ACCENTS) + 1]
        -- border ring: bright for the focused card, quiet otherwise
        local ring = pressed and colours.white or (selected and colours.white or colours.grey)
        mon.setBackgroundColour(ring)
        for c = 0, CARD_W - 3 do
            mon.setCursorPos(x + 1 + c, y)
            mon.write(" ")
            mon.setCursorPos(x + 1 + c, y + CARD_H - 1)
            mon.write(" ")
        end
        for r = 1, CARD_H - 2 do
            mon.setCursorPos(x + 1, y + r)
            mon.write(" ")
            mon.setCursorPos(x + CARD_W - 2, y + r)
            mon.write(" ")
        end
        -- poster body
        mon.setBackgroundColour(acc)
        for r = 2, CARD_H - 3 do
            mon.setCursorPos(x + 2, y + r)
            mon.write(string.rep(" ", math.min(CARD_W - 4, MW - x - 3)))
        end
        -- giant initial centred in the poster zone (glyphs are 5 rows tall,
        -- the interior is exactly CARD_H-4 rows: made to measure)
        local ch = it.label:sub(1, 1):upper()
        if GLYPH[ch] then
            local gx = x + 2 + math.floor((CARD_W - 4 - 5) / 2)
            if gx + 5 <= MW + 1 then
                drawGlyph(ch, gx, y + 2,
                    selected and colours.black or colours.grey)
            end
        end
        -- title strip along the bottom of the card
        local maxT = math.min(CARD_W - 4, MW - (x + 2) + 1)
        if maxT > 0 then
            mon.setBackgroundColour(pressed and colours.white or colours.black)
            mon.setTextColour(selected and colours.yellow or colours.lightGrey)
            mon.setCursorPos(x + 2, y + CARD_H - 2)
            mon.write(it.label:sub(1, maxT))
        end
        if it.isNew and it.kind ~= "settings" then
            chip(math.min(x + CARD_W - 5, MW - 3), y, "NEW", colours.yellow, colours.black)
        end
        mon.setBackgroundColour(colours.black)
    end

    local function drawGrid(stagger)
        local vx = viewX()
        local cA = math.max(0, vx)
        local cB = vx + cols
        mon.setBackgroundColour(colours.black)
        local bandH = rows * (CARD_H + GAPY) - GAPY
        for r = 0, bandH - 1 do
            mon.setCursorPos(1, cardsY + r)
            mon.write(string.rep(" ", MW))
        end
        local drawn = 0
        for c = cA, cB do
            for r = 0, rows - 1 do
                local idx = c * rows + r + 1
                local it = items[idx]
                if it then
                    local x = 2 + (c - vx) * (CARD_W + GAPX)
                    local y = cardsY + r * (CARD_H + GAPY)
                    drawCardReal(it, idx, x, y, idx == sel)
                    if stagger then
                        drawn = drawn + 1
                        if drawn % 4 == 0 then sleep(0.03) end
                    end
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

    local function metaW() return MW >= 44 and 13 or 0 end

    local function drawHero()
        -- rows 2-6: selected title in big glyphs + meta column on the right
        local it = items[sel]
        mon.setBackgroundColour(colours.black)
        for r = 2, 6 do
            mon.setCursorPos(1, r)
            mon.write(string.rep(" ", MW))
        end
        if not it then return end
        local metaW = MW >= 44 and 13 or 0
        local metaX = MW - metaW + 1
        local maxW = math.max(8, (metaW > 0 and metaX - 4 or MW - 3))
        local label = it.label:upper()
        local line1 = ""
        for w in label:gmatch("%S+") do
            local cand = line1 == "" and w or (line1 .. " " .. w)
            if wordWidth(cand) <= maxW then line1 = cand end
        end
        if #line1 > 0 and wordWidth(line1) <= maxW then
            drawWord(line1, 2, 2, colours.white)
        elseif #label > 0 then
            mon.setTextColour(colours.white)
            mon.setCursorPos(2, 4)
            mon.write(label:sub(1, math.min(#label, maxW)))
        end
        if metaW > 0 then
            chip(metaX, 2, string.rep(" ", metaW - 1), colours.grey, colours.black)
            mon.setTextColour(colours.black)
            mon.setCursorPos(metaX + 1, 2)
            mon.write(fmtDur(it.dur) or it.sub or "VIDEO")
            if it.isNew and it.kind == "movie" then
                chip(metaX, 3, " NEW ", colours.yellow, colours.black)
            else
                chip(metaX, 3, string.rep(" ", metaW - 1), colours.black, colours.black)
            end
            mon.setTextColour(colours.lightGrey)
            mon.setBackgroundColour(colours.black)
            mon.setCursorPos(metaX, 4)
            mon.write((("%d/%d"):format(sel, n)):sub(1, metaW - 1))
            chip(metaX, 5, " PLAY \7 ", colours.lime, colours.black)
        end
    end

    local function drawInfoLine()
        mon.setBackgroundColour(colours.black)
        mon.setCursorPos(2, HEADER_ROWS)
        mon.write(string.rep(" ", MW - 2))
        local it = items[sel]
        if it and it.kind == "movie" and metaW() == 0 then
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
        -- slim marquee strip across the very top
        mon.setBackgroundColour(colours.red)
        mon.setCursorPos(1, 1)
        mon.write(string.rep(" ", MW))
        mon.setBackgroundColour(colours.black)
        local cs = clockStr()
        if cs ~= "" then
            mon.setTextColour(colours.white)
            mon.setCursorPos(math.max(1, MW - #cs + 1), 7)
            mon.write(cs)
        end
        segments(7, MW - 17, {
            { t = online and " ONLINE " or " OFFLINE", c = colours.black },
        }, online and colours.green or colours.red)
        drawHero()
        -- divider (left segment only; status chip + clock own the right)
        mon.setBackgroundColour(colours.grey)
        mon.setCursorPos(1, 7)
        mon.write(string.rep(" ", math.max(0, MW - 18)))
        mon.setBackgroundColour(colours.black)
        drawInfoLine()
        segments(MH, 1, {
            { t = " <>", c = colours.red },
            { t = " browse", c = colours.white },
            { t = "   Enter", c = colours.red },
            { t = " play", c = colours.white },
            { t = "   tap", c = colours.orange },
            { t = " card", c = colours.white },
            { t = "   H", c = colours.red },
            { t = " help", c = colours.white },
        }, colours.black)
        mon.setBackgroundColour(colours.grey)
        mon.setCursorPos(math.max(1, MW - 9), MH)
        mon.setTextColour(colours.black)
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
    drawGrid(true)
    while true do
        local id = os.startTimer(0.1)
        local ev, a, b, cc = os.pullEvent()

        if os.clock() - lastEvent > IDLE_SAVER then
            saverLoop()
            drawChrome()
            drawGrid(true)
            lastEvent = os.clock()
        end

        if ev == "timer" and a == id then
            tick = tick + 1
            if not refreshInflight and os.clock() - lastFetch >= 5 then
                lastFetch = os.clock()
                refreshInflight = true
                http.request(BASE .. "/movies.txt")
            end
            if tick % 5 == 0 then
                local cs = clockStr()
                local cpos = cs:find(":", 1, true)
                if cs ~= "" and cpos then
                    mon.setBackgroundColour(colours.black)
                    mon.setTextColour(tick % 10 < 5 and colours.lightBlue or colours.grey)
                    mon.setCursorPos(math.max(1, MW - #cs + 1) + cpos - 1, 7)
                    mon.write(tick % 10 < 5 and ":" or " ")
                end
            end
            if tick % 3 == 0 then
                local sx2 = ((math.floor(tick / 3) * 7) % (MW - 8)) + 2
                mon.setTextColour(colours.lightGrey)
                mon.setBackgroundColour(colours.black)
                mon.setCursorPos(2, 6)
                mon.write(string.rep("\127", MW - 2))
                mon.setBackgroundColour(colours.cyan)
                mon.setCursorPos(sx2, 6)
                mon.write("    ")
                mon.setBackgroundColour(colours.black)
            end
            if TOAST_MSG then
                if os.clock() > TOAST_UNTIL then
                    mon.setBackgroundColour(colours.black)
                    mon.setCursorPos(MW - #TOAST_MSG - 3, MH - 1)
                    mon.write(string.rep(" ", #TOAST_MSG + 2))
                    TOAST_MSG = nil
                else
                    chip(MW - #TOAST_MSG - 3, MH - 1,
                         " " .. TOAST_MSG .. " ", colours.lime, colours.black)
                    mon.setBackgroundColour(colours.black)
                end
            end
            if comet then
                comet.t = comet.t + 0.4
                local gx = math.floor(comet.fx + (comet.tx - comet.fx) * math.min(1, comet.t))
                mon.setBackgroundColour(colours.yellow)
                mon.setCursorPos(gx, comet.y)
                mon.write("#####")
                mon.setBackgroundColour(colours.black)
                if comet.t >= 1 then
                    comet = nil
                    drawGrid()
                end
            elseif anim then
                anim.t = anim.t + 0.34
                if anim.t >= 1 then
                    c0 = anim.to
                    anim = nil
                end
                drawGrid()
            else
                local it = items[sel]
                if it and tick % 6 == 0 and it.kind ~= nil then
                    local c = selCol()
                    local r = selRow()
                    if c >= c0 and c < c0 + cols and not anim then
                        local x = 2 + (c - c0) * (CARD_W + GAPX)
                        local y = cardsY + r * (CARD_H + GAPY) + CARD_H - 1
                        if x + CARD_W <= MW + 1 then
                            -- pulse the focused card's ring, not a fat bar
                            mon.setBackgroundColour(tick % 12 < 6 and colours.red
                                or colours.white)
                            mon.setCursorPos(x + 1, y)
                            mon.write(string.rep(" ", CARD_W - 2))
                            mon.setCursorPos(x + 1, y - CARD_H + 1)
                            mon.write(string.rep(" ", CARD_W - 2))
                            mon.setBackgroundColour(colours.black)
                        end
                    end
                end
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
                local prow, nrow = (prev - 1) % rows, (sel - 1) % rows
                local pcol, ncol = selColOf(prev), selCol()
                if not anim and prow == nrow and math.abs(ncol - pcol) == 1
                    and pcol >= c0 and pcol < c0 + cols
                    and ncol >= c0 and ncol < c0 + cols then
                    comet = {
                        fx = 2 + (pcol - c0) * (CARD_W + GAPX),
                        tx = 2 + (ncol - c0) * (CARD_W + GAPX),
                        y = cardsY + prow * (CARD_H + GAPY) + CARD_H - 1,
                        t = 0,
                    }
                else
                    ensureVisible()
                    drawGrid()
                end
                drawHero()
                drawInfoLine()
            end
            if a == keys.enter or a == keys.space then
                if items[sel] then
                    blip("open")
                    return items[sel]
                end
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
                            drawCardReal(items[idx], idx, cx,
                                         cardsY + r * (CARD_H + GAPY), true, true)
                            sleep(0.09)
                            return items[idx]
                        end
                    end
                end
            end
        elseif ev == "http_success" or ev == "http_failure" then
            if refreshInflight and tostring(a):find("movies%.txt") then
                refreshInflight = false
                local wasOnline = onlineNow
                if ev == "http_success" then
                    local body = b.readAll()
                    b.close()
                    local list = parseMovieLines(body)
                    if #list > 0 then
                        applyMovieList(list)
                        onlineNow = true
                        drawStatusChip()
                        drawGrid()
                        drawHero()
                        drawInfoLine()
                    else
                        onlineNow = false
                        drawStatusChip()
                    end
                else
                    onlineNow = false
                    drawStatusChip()
                end
            end
        end
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
        if bx2 - 2 >= railX then
            chip(bx2 - 2, railY, " ", colours.lightGrey, colours.black)
        end
        if bx2 - 1 >= railX then
            chip(bx2 - 1, railY, " ", colours.grey, colours.black)
        end
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
    -- parts are placed by feader.lua; locate each one wherever it landed
    local function pname(i)
        local leaf = NAME .. ".ccm." .. i
        for _, d in ipairs(DISKS) do
            local full = fs.combine(d, leaf)
            if fs.exists(full) then return full end
        end
        return fs.combine(DISKS[1], leaf)
    end
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
    local w, h, fps, partCount, blk, md = hdr:match("^(%d+) (%d+) (%d+) (%d+) (%d*) (%d*)")
    w, h, fps, partCount = tonumber(w), tonumber(h), tonumber(fps), tonumber(partCount)
    if not w then error("Corrupt meta file", 0) end
    local nb = tonumber(blk) or 1
    local MODE = tonumber(md) or 0
    if MODE > 3 then
        error("movie needs render mode " .. MODE .. ", this player supports 0-3", 0)
    end
    local HALF = MODE == 1
    local PIXEL = MODE == 3 and GFX
    local cw, chh
    if MODE == 3 then
        cw, chh = w, h
    else
        cw, chh = w * nb, h * nb
    end
    local lastPart = partCount - 1

    mon.setTextScale(0.5)
    MW, MH = mon.getSize()

    -- UI progress target: 60% of all free storage across every disk
    PREFILL = math.max(PART_LOW, math.floor((totalFree() - 3000000) * 0.6))

    if PIXEL then
        GFX_W, GFX_H = cw * 6, chh * 9
    else
        if GFX then pcall(mon.setGraphicsMode, 0) end
        if math.floor(MW + 0.5) < cw or math.floor(MH + 0.5) < chh then
            print(("monitor %dx%d too small for %dx%d grid"):format(MW, MH, cw, chh))
        end
    end

    local win = PIXEL and nil or window.create(mon, 1, 1, cw, chh, false)

    local pixelBuf = PIXEL and {} or nil
    local pixelExpected = PIXEL and (cw * chh) or 0
    local pixelFc = -1
    local gfxActive = false
    local gfxOx, gfxOy = 0, 0
    local rgbToIdx = nil
    local function initGfx()
        if gfxActive then return end
        mon.setGraphicsMode(2)
        gfxActive = true
        -- the monitor's true pixel size can differ slightly from the
        -- transcoded grid: centre the frame so it doesn't hug the top-left
        gfxOx, gfxOy = 0, 0
        local okS, spw, sph = pcall(mon.getSize, 2)
        if okS and type(spw) == "number" and spw > 0 and type(sph) == "number" and sph > 0 then
            gfxOx = math.max(0, math.floor((spw - cw) / 2))
            gfxOy = math.max(0, math.floor((sph - chh) / 2))
        end
        for ri = 0, 5 do
            for gi = 0, 5 do
                for bi = 0, 5 do
                    local idx = ri * 36 + gi * 6 + bi
                    pcall(mon.setPaletteColour, idx, ri / 5, gi / 5, bi / 5)
                end
            end
        end
        for i = 0, 39 do
            local v = i / 39
            pcall(mon.setPaletteColour, 216 + i, v, v, v)
        end
    end

    local function toHex(v)
        if v < 10 then return string.char(48 + v) end
        return string.char(87 + v)
    end

    local bufCache, bufAt = 0, 0
    local function bufferedAhead()
        -- walking every part with fs.getSize is expensive on long movies,
        -- so serve a quarter-second-stale cached value instead
        local now = os.clock()
        if now - bufAt < 0.25 then return bufCache end
        local total = 0
        for i = curPart, lastPart do
            local f = pname(i)
            if fs.exists(f) then
                total = total + fs.getSize(f)
            else
                break
            end
        end
        bufCache, bufAt = total, now
        return total
    end

    local start = nil
    local fi, ai = 0, 0
    local frameDur = 1000 / fps
    local pendingAudio = {}
    local cachedFrame
    local cachedGlyphs
    local curPart = 0
    local hnd = nil
    local paused = false
    local pausedAt = nil
    local abortPlay = false

    -- tell feader.lua how far playback has progressed so it can free space
    local function writeHead()
        local fh = fs.open(".ccm_head", "wb")
        if fh then
            fh.write(tostring(curPart))
            fh.close()
        end
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
            local pctCol = math.floor(os.clock() * 3) % 2 == 0 and colours.lime or colours.cyan
            mon.setTextColour(pctCol)
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
                local shineX = LBX + 2 + (math.floor(os.clock() * 8) % math.max(1, fill))
                if shineX + 1 <= LBX + LBW - 3 then
                    mon.setBackgroundColour(colours.green)
                    mon.setCursorPos(shineX, LY + 5)
                    mon.write("  ")
                end
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
            local meta = ("buffer %.1fMB   disks %dMB free")
                :format(b / 1000000, math.floor(totalFree() / 1000000))
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

    local SHADE_CHARS = {}
    do
        local set = " /(\219\177\127@"
        for i = 1, #set do SHADE_CHARS[tostring(i - 1)] = set:sub(i, i) end
    end

    local function render(frame, glyphs)
        if PIXEL then
            initGfx()
            -- frames arrive pre-quantised (1 palette index per pixel):
            -- slicing into rows is all that's left to do per frame
            local rows = {}
            if type(frame) == "string" then
                for y = 1, chh do
                    rows[y] = frame:sub((y - 1) * cw + 1, y * cw)
                end
            end
            mon.drawPixels(gfxOx, gfxOy, rows)
            return
        end
        local y = 1
        for r0 in string.gmatch(frame, "[^;]+") do
            if y > chh then break end
            win.setCursorPos(1, y)
            local r = r0
            if MODE == 2 then
                local n3 = #r
                if n3 >= cw * 3 then
                    r = r:sub(1, cw * 3)
                elseif n3 > 0 then
                    r = r .. r:sub(-1):rep(cw * 3 - n3)
                else
                    r = string.rep("ff0", cw)
                end
                local colours = r:sub(1, cw * 2)
                local gdig = glyphs and glyphs:sub((y - 1) * cw + 1, y * cw)
                if not gdig or #gdig < cw then
                    gdig = string.rep("0", cw)
                end
                local fg = (colours:gsub("(.)(.)", "%1"))
                local bg = (colours:gsub("(.)(.)", "%2"))
                local txt = (gdig:gsub("%x", SHADE_CHARS))
                win.blit(txt, fg, bg)
            elseif HALF then
                local n2 = #r
                if n2 >= cw * 2 then
                    r = r:sub(1, cw * 2)
                elseif n2 > 0 then
                    r = r .. r:sub(-1):rep(cw * 2 - n2)
                else
                    r = string.rep("f", cw * 2)
                end
                local top = r:sub(1, cw)
                local bot = r:sub(cw + 1, cw * 2)
                if not halfRowText then halfRowText = HALF_GLYPH:rep(cw) end
                win.blit(halfRowText, top, bot)
            else
                local n2 = #r
                if n2 >= cw then
                    r = r:sub(1, cw)
                    win.blit(string.rep(" ", cw), r, r)
                elseif n2 > 0 then
                    local pad = r:sub(-1):rep(cw - n2)
                    win.blit(string.rep(" ", cw), r .. pad, r .. pad)
                end
            end
            y = y + 1
        end
        win.setVisible(true)
    end

    local palCur, palTgt = {}, {}
    local function applyPalette(p)
        if not p then return end
        local i = 0
        for entry in p:gmatch("[^;]+") do
            local r, g, b = entry:match("(%d+),(%d+),(%d+)")
            if r and i < 16 then
                i = i + 1
                palTgt[i] = { r / 255, g / 255, b / 255 }
                -- first palette snaps instantly; later ones ease in so a
                -- palette change repaints as a smooth shift instead of a
                -- one-frame full-screen colour flash
                if not palCur[i] then palCur[i] = { r / 255, g / 255, b / 255 } end
            end
        end
    end

    local PAL_EASE = 0.7
    local function stepPalette()
        local dirty = false
        for i = 1, 16 do
            local c, t = palCur[i], palTgt[i]
            if c and t then
                for ch = 1, 3 do
                    local d = t[ch] - c[ch]
                    if d > 0.004 or d < -0.004 then
                        c[ch] = c[ch] + d * PAL_EASE
                        dirty = true
                    else
                        c[ch] = t[ch]
                    end
                end
            end
        end
        if dirty then
            for i = 1, 16 do
                local c = palCur[i]
                if c then pcall(mon.setPaletteColour, 2 ^ (i - 1), c[1], c[2], c[3]) end
            end
        end
    end

    local function assemble(digits)
        local rowW = cw * (MODE >= 1 and 2 or 1)
        local rows = {}
        local pos = 1
        for _ = 1, chh do
            rows[#rows + 1] = digits:sub(pos, pos + rowW - 1)
            pos = pos + rowW
        end
        return table.concat(rows, ";")
    end

    local function assembleGlyphs(digits)
        if not digits then return nil end
        local rows = {}
        local pos = 1
        for _ = 1, chh do
            rows[#rows + 1] = digits:sub(pos, pos + cw - 1)
            pos = pos + cw
        end
        return table.concat(rows, ";")
    end

    local function unpackDigits(p, rle)
        local cells = {}
        local ci = 0
        if rle then
            for i = 1, #p, 2 do
                local cnt = string.byte(p, i)
                local v = toHex(string.byte(p, i + 1))
                for _ = 1, cnt do
                    ci = ci + 1
                    cells[ci] = v
                end
            end
        else
            for i = 1, #p do
                local b = string.byte(p, i)
                ci = ci + 1; cells[ci] = toHex(math.floor(b / 16))
                ci = ci + 1; cells[ci] = toHex(b % 16)
            end
        end
        return table.concat(cells)
    end

    local function decodePacked(p)
        return assemble(unpackDigits(p, false))
    end

    local function decodeRLE(p)
        return assemble(unpackDigits(p, true))
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
    local eqRect = nil
    local eqTick = 0

    local function drawEQ(k)
        if not eqRect then return end
        local hs = { 1, 3, 5, 4, 2 }
        for i = 0, 2 do
            local hgt = hs[((k + i * 2) % 5) + 1]
            for r = 0, 4 do
                mon.setBackgroundColour(r < hgt and colours.lime or colours.grey)
                mon.setCursorPos(eqRect.x + i * 2, eqRect.y + 4 - r)
                mon.write(" ")
            end
        end
        mon.setBackgroundColour(colours.black)
    end

    local function inRect(r, x, y)
        return r ~= nil and y == r.y and x >= r.x and x < r.x + r.w
    end

    local function drawPauseBar(on)
        if on then
            mon.setBackgroundColour(colours.grey)
            mon.clearLine()
            mon.setCursorPos(1, MH)
            mon.write(string.rep(" ", MW))
            chip(1, MH, " II PAUSED ", colours.red, colours.white)
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
                drawWord("PAUSED", bx + 4, by + 1, colours.red)
                centre(by + 6, "tap anywhere to resume", colours.lightBlue)
                if bw >= ww + 12 then
                    eqRect = { x = bx + bw - 7, y = by + 1 }
                    drawEQ(0)
                else
                    eqRect = nil
                end
            end
            local frac = curPart / (lastPart + 1)
            mon.setBackgroundColour(colours.lightGrey)
            mon.setCursorPos(1, MH - 1)
            mon.write(string.rep(" ", MW))
            local pf = math.floor(MW * frac + 0.5)
            if pf > 0 then
                mon.setBackgroundColour(colours.red)
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
            if cachedFrame then render(cachedFrame, cachedGlyphs) end
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
        if hnd then pcall(function() hnd.close() end) hnd = nil end
        if sp then pcall(sp.stop) end
        writeHead()
    end

    -- wait for feader.lua to deliver the first parts before starting
    local lastB, lastT = -1, os.clock()
    while not abortPlay and not fs.exists(pname(curPart)) do
        local b = bufferedAhead()
        if b ~= lastB then lastB, lastT = b, os.clock() end
        uiStatusThrottled("waiting for feeder")
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
                    uiStatusThrottled("rebuffering")
                    waitEvents(0.05)
                end
                if abortPlay then return nil end
                hnd = fs.open(pname(curPart), "rb")
                writeHead()
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
        elseif t == 6 then
            if PIXEL then
                local header = string.byte(payload, 1) or 0
                local fc = math.floor(header / 16) % 16
                local chunk_idx = header % 16
                if fc ~= pixelFc then
                    pixelBuf = {}
                    pixelFc = fc
                end
                pixelBuf[chunk_idx + 1] = payload:sub(2)
                local total = 0
                for i = 1, #pixelBuf do total = total + #pixelBuf[i] end
                if total >= pixelExpected then
                    cachedFrame = table.concat(pixelBuf)
                    pixelBuf = {}
                    if not start then start = os.epoch("utc") + 150 end
                    while not abortPlay do
                        if not paused and os.epoch("utc") >= start + fi * frameDur then break end
                        waitEvents(paused and 0.15 or 0.02)
                        if paused then
                            eqTick = eqTick + 1
                            drawEQ(eqTick)
                        end
                    end
                    if abortPlay then break end
                    if not paused then
                        stepPalette()
                        render(cachedFrame, nil)
                        fi = fi + 1
                    else
                        stepPalette()
                    end
                end
            end
        elseif t == 0 or t == 2 or t == 3 then
            if t ~= 0 then
                cachedFrame = (t == 3) and decodeRLE(payload) or decodePacked(payload)
                if MODE == 2 then
                    local g5, g5payload = nextRecord()
                    if g5 == 5 and not abortPlay then
                        local sub = g5payload:byte(1)
                        local body = g5payload:sub(2)
                        cachedGlyphs = assembleGlyphs(
                            unpackDigits(body, sub == 3))
                    end
                end
            end
            if not start then start = os.epoch("utc") + 150 end
            while not abortPlay do
                if not paused and os.epoch("utc") >= start + fi * frameDur then break end
                waitEvents(paused and 0.15 or 0.02)
                if paused then
                    eqTick = eqTick + 1
                    drawEQ(eqTick)
                end
            end
            if abortPlay then break end
            if not paused then
                stepPalette()
                render(cachedFrame, cachedGlyphs)
                fi = fi + 1
            else
                stepPalette()
            end
        end

        while #pendingAudio > 0 and sp and start and not paused do
            local due = start + ai * 250 + DELAY_MS
            if os.epoch("utc") < due - 120 then break end
            if due > start + fi * frameDur + 120 then break end
            playAudioChunk(table.remove(pendingAudio, 1))
            ai = ai + 1
        end

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
    if PIXEL then
        pcall(mon.setGraphicsMode, 0)
    elseif win then
        win.setVisible(false)
    end
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
    blip("jingle")
    local ly = math.floor(MH / 2) - 2
    for _, x in ipairs({ 30, 22, 15, 9, 4, 2 }) do
        mon.setBackgroundColour(colours.black)
        mon.clear()
        drawLogo(math.max(2, math.floor(x)), ly)
        local sh = math.floor((x * 7) % (MW - 8)) + 2
        mon.setBackgroundColour(colours.cyan)
        mon.setCursorPos(sh, ly + 6)
        mon.write("      ")
        mon.setBackgroundColour(colours.black)
        sleep(0.06)
    end
    sleep(0.25)
end

local bootScale = 0.5
pcall(function() bootScale = mon.getTextScale() end)
local movies, online = fetchMovies()
while true do
    local it = homeMenu(movies, online)
    while it.kind == "_refresh" do
        blinds()
        movies, online = fetchMovies()
        showToast(online and "Library refreshed" or "Offline - cached list")
        it = homeMenu(movies, online)
    end
    if it.kind == "settings" then
        blinds()
        settingsScreen()
        movies, online = fetchMovies()
    else
        markSeen(it.label)
        blinds()
        play(it.label)
        resetPalette()
        applyTheme()
        pcall(function() mon.setTextScale(bootScale) end)
        MW, MH = mon.getSize()
        movies, online = fetchMovies()
    end
end
