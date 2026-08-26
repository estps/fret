------------------------------------------------------------------------------
-- CC CINEMA - cloud video player for CC:Tweaked + CC:Graphics
--
-- Plays movies produced by prepare.py (render mode 3 = GFX pixel stream).
--
-- SERVER SETUP (on your PC, inside the movie folder):
--   python3 -m http.server 8080
--   cloudflared tunnel --url http://localhost:8080
--   copy the https://xxxx.trycloudflare.com URL it prints
--
-- IN GAME:
--   cinema        first run asks for the tunnel URL (saved to /cinema.cfg)
--
-- CONTROLS:
--   menu : UP/DOWN select | ENTER play | U url | R refresh | ESC quit
--   play : SPACE pause | LEFT/RIGHT +-10s | UP/DOWN volume | M mute | Q quit
--   touch: left third -10s | middle pause | right third +10s
--          progress bar scrubs | bottom-right corner stops
------------------------------------------------------------------------------

local CFG_PATH = "/cinema.cfg"

local CHUNK           = 65000     -- must match prepare.py
local AUDIO_REC_SEC   = 0.25      -- one type-4 record = 0.25 s
local VIDEO_CAP       = 1400000   -- ram budget: buffered video frames
local AUDIO_CAP       = 720000    -- ram budget: buffered audio (~2 min)
local SPK_PENDING_MAX = 64000     -- bytes queued in the speaker at once
local READ_BLOCK      = 32768

-- ui palette slots (video uses 0..215, the 6x6x6 cube)
local BG      = 240
local PANEL   = 241
local PANEL2  = 242
local GREY    = 243
local LIGHT   = 244
local WHITE   = 245
local ACCENT  = 246
local ACCENT2 = 247
local RED     = 248
local DEEP    = 250
local BLACK   = 0

local CFG = { BASE_URL = "", VOLUME = 1.0, TEXT_SCALE = 0.5, AUTO_ZOOM = true }

--------------------------------------------------------------------------
-- tiny helpers
--------------------------------------------------------------------------

local sleep = os.sleep

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end
local function round(v) return math.floor(v + 0.5) end
local function now() return os.epoch("utc") / 1000 end

local function urlenc(s)
    return (s:gsub("[^%w%-%_%.%~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function fmtTime(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

--------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------

local function loadCfg()
    if fs.exists(CFG_PATH) then
        local f = io.open(CFG_PATH, "r")
        local data = f:read("*a")
        f:close()
        local t = textutils.unserialise(data)
        if type(t) == "table" then
            for k, v in pairs(t) do CFG[k] = v end
        end
    end
end

local function saveCfg()
    local f = io.open(CFG_PATH, "w")
    f:write(textutils.serialise(CFG))
    f:close()
end

local function promptUrl()
    term.setTextColor(colors.yellow)
    print("CC CINEMA needs the URL of your video server.")
    print("On your PC run:")
    print("  python3 -m http.server 8080")
    print("  cloudflared tunnel --url http://localhost:8080")
    print()
    term.setTextColor(colors.white)
    write("Paste URL (https://xxxx.trycloudflare.com): ")
    term.setCursorBlink(true)
    local u = read()
    term.setCursorBlink(false)
    u = (u or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if not u:match("^https?://") then
        term.setTextColor(colors.red)
        print("That does not look like a URL.")
        sleep(2)
        return false
    end
    CFG.BASE_URL = u
    saveCfg()
    print("Saved to " .. CFG_PATH)
    return true
end

--------------------------------------------------------------------------
-- http
--------------------------------------------------------------------------

local function httpGetText(url)
    local r = http.get(url, nil, true)
    if not r then return nil, "could not connect" end
    local s = r.readAll()
    r.close()
    if not s then return nil, "empty response" end
    return s
end

--------------------------------------------------------------------------
-- 3x5 pixel font
--------------------------------------------------------------------------

local FONT_SRC = {
    ["0"]="###|#.#|#.#|#.#|###", ["1"]=".#.|##.|.#.|.#.|###",
    ["2"]="###|..#|###|#..|###", ["3"]="###|..#|###|..#|###",
    ["4"]="#.#|#.#|###|..#|..#", ["5"]="###|#..|###|..#|###",
    ["6"]="###|#..|###|#.#|###", ["7"]="###|..#|..#|..#|..#",
    ["8"]="###|#.#|###|#.#|###", ["9"]="###|#.#|###|..#|###",
    A="###|#.#|###|#.#|#.#", B="##.|#.#|##.|#.#|##.",
    C="###|#..|#..|#..|###", D="##.|#.#|#.#|#.#|##.",
    E="###|#..|###|#..|###", F="###|#..|###|#..|#..",
    G="###|#..|#.#|#.#|###", H="#.#|#.#|###|#.#|#.#",
    I="###|.#.|.#.|.#.|###", J="..#|..#|..#|#.#|###",
    K="#.#|#.#|##.|#.#|#.#", L="#..|#..|#..|#..|###",
    M="#.#|###|#.#|#.#|#.#", N="###|#.#|#.#|#.#|#.#",
    O="###|#.#|#.#|#.#|###", P="###|#.#|###|#..|#..",
    Q="###|#.#|###|..#|..#", R="###|#.#|##.|#.#|#.#",
    S="###|#..|###|..#|###", T="###|.#.|.#.|.#.|.#.",
    U="#.#|#.#|#.#|#.#|###", V="#.#|#.#|#.#|#.#|.#.",
    W="#.#|#.#|#.#|###|#.#", X="#.#|#.#|.#.|#.#|#.#",
    Y="#.#|#.#|###|.#.|.#.", Z="###|..#|.#.|#..|###",
    [" "]="...|...|...|...|...",
    [":"]="...|.#.|...|.#.|...", ["."]="_._|...|...|...|._.",
    [","]="_._|...|...|._.|#..", ["-"]="_._|_._|###|_._|_._",
    ["+"]="_._|.#.|###|.#.|_._", ["/"]="_._|..#|..#|.#.|#..",
    ["%"]="#.#|..#|.#.|#..|#.#", ["("]=".#.|#..|#..|#..|.#.",
    [")"]=".#.|..#|..#|..#|.#.", ["'"]="#..|#..|_._|_._|_._",
    ["!"]=".#.|.#.|.#.|_._|.#.", ["?"]="###|..#|.#.|_._|.#.",
    ["_"]="_._|_._|_._|_._|###", ["<"]="..#|.#.|#..|.#.|..#",
    [">"]="#..|.#.|..#|.#.|#..", ["="]="_._|###|_._|###|_._",
    ['"']="#.#|#.#|_._|_._|_._", ["*"]="_._|#.#|.#.|#.#|_._",
    ["&"]="##.|#..|###|#.#|###", ["#"]="#.#|###|#.#|###|#.#",
    ["^"]=".#.|#.#|_._|_._|_._", ["~"]="_._|#.#|.#.|_._|_._",
}

local FONT = {}
for ch, def in pairs(FONT_SRC) do
    local rows = {}
    for r in def:gmatch("[^|]+") do
        rows[#rows + 1] = r:gsub("_", ".")
    end
    FONT[ch] = rows
end

local function textWidth(s, scale) return #s * 4 * scale - scale end

local function fitText(s, maxPx, scale)
    if textWidth(s, scale) <= maxPx then return s end
    local n = math.floor((maxPx + scale) / (4 * scale)) - 1
    if n < 1 then n = 1 end
    if n >= #s then return s end
    return s:sub(1, n) .. "~"
end

-- draws text with a solid baked background (fast path)
local function drawText(x, y, s, fg, bg, scale)
    scale = scale or 1
    for r = 0, 4 do
        local seg = {}
        for i = 1, #s do
            local g = FONT[s:sub(i, i):upper()] or FONT["?"]
            local gr = g[r + 1]
            for cx = 1, 3 do
                local b = gr:sub(cx, cx) == "#" and fg or bg
                seg[#seg + 1] = string.rep(string.char(b), scale)
            end
        end
        local rowStr = table.concat(seg)
        for v = 0, scale - 1 do
            term.drawPixels(x, y + r * scale + v, rowStr)
        end
    end
    return textWidth(s, scale)
end

--------------------------------------------------------------------------
-- screen helpers
--------------------------------------------------------------------------

local SW, SH = 0, 0

local function fill(x, y, w, h, c)
    if x < 0 then w = w + x x = 0 end
    if y < 0 then h = h + y y = 0 end
    if x + w > SW then w = SW - x end
    if y + h > SH then h = SH - y end
    if w <= 0 or h <= 0 then return end
    term.drawPixels(x, y, c, w, h)
end

local function setupPalette()
    for i = 0, 215 do
        term.setPaletteColor(i,
            math.floor(i / 36) * 51 / 255,
            (math.floor(i / 6) % 6) * 51 / 255,
            (i % 6) * 51 / 255)
    end
    term.setPaletteColor(BG,      0.043, 0.043, 0.063)
    term.setPaletteColor(PANEL,   0.098, 0.098, 0.125)
    term.setPaletteColor(PANEL2,  0.180, 0.184, 0.220)
    term.setPaletteColor(GREY,    0.470, 0.480, 0.520)
    term.setPaletteColor(LIGHT,   0.700, 0.710, 0.750)
    term.setPaletteColor(WHITE,   0.940, 0.945, 0.960)
    term.setPaletteColor(ACCENT,  0.150, 0.780, 0.950)
    term.setPaletteColor(ACCENT2, 1.000, 0.620, 0.180)
    term.setPaletteColor(RED,     0.930, 0.290, 0.290)
    term.setPaletteColor(DEEP,    0.020, 0.020, 0.031)
end

local function drawSpinner(cx, cy, label)
    local t = math.floor(os.epoch("utc") / 130) % 8
    fill(cx - 12, cy - 12, 25, 25, BG)
    for i = 0, 7 do
        local a = (i / 8) * 2 * math.pi - t * 0.785
        local dx = round(cx + math.cos(a) * 7) - 1
        local dy = round(cy + math.sin(a) * 7) - 1
        fill(dx, dy, 2, 2, i == t and ACCENT or PANEL2)
    end
    if label then
        local s = fitText(label, 260, 1)
        drawText(round(cx - textWidth(s, 1) / 2), cy + 15, s, LIGHT, BG, 1)
    end
end

--------------------------------------------------------------------------
-- frame scaling
--------------------------------------------------------------------------

local REPMAP = {}

local function expandRow(row, z)
    if z == 1 then return row end
    local m = REPMAP[z]
    if not m then
        m = {}
        for i = 0, 255 do m[string.char(i)] = string.char(i):rep(z) end
        REPMAP[z] = m
    end
    return (row:gsub(".", m))
end

local function makeFrame(S, data)
    local geo = S.geo
    local vw = S.vw
    local rows = {}
    if geo.dz >= 2 then
        local z = geo.dz
        for y = 1, S.vh do
            local er = expandRow(data:sub((y - 1) * vw + 1, y * vw), z)
            for k = 1, z do rows[#rows + 1] = er end
        end
    elseif geo.ds >= 2 then
        local d = geo.ds
        local half = math.ceil(d / 2)
        for y = half, S.vh, d do
            local src = data:sub((y - 1) * vw + 1, y * vw)
            local acc = {}
            for x = half, vw, d do acc[#acc + 1] = src:sub(x, x) end
            rows[#rows + 1] = table.concat(acc)
        end
    else
        for y = 1, S.vh do
            rows[#rows + 1] = data:sub((y - 1) * vw + 1, y * vw)
        end
    end
    return rows
end

--------------------------------------------------------------------------
-- shared player state + streaming downloader
--------------------------------------------------------------------------

local function newState(base, name, parts, fps, dur, metaW, metaH)
    return {
        base = base, name = name, parts = parts, fps = fps, dur = dur,
        metaW = metaW, metaH = metaH,
        videoQ = {}, videoBytes = 0, audioQ = {}, audioBytes = 0,
        partStartFrame = {}, partStartAudio = {},
        partNo = 0, resp = nil, rbuf = "",
        frameNo = 0, audioNo = 0,
        curOpen = false, curParts = nil,
        scanOnly = false, resumeF = nil, resumeA = nil,
        seekReq = nil, seeking = false,
        eof = false, err = nil, stop = false,
        needRecover = nil,
        vw = nil, vh = nil, geo = nil,
    }
end

local function partURL(S, p)
    local e = urlenc(S.name)
    return S.base .. "/" .. e .. "/" .. e .. ".ccm." .. p
end

local function closeResp(S)
    if S.resp then
        pcall(function() S.resp.close() end)
        S.resp = nil
    end
    S.rbuf = ""
end

local function readExact(S, n)
    local buf = S.rbuf
    while #buf < n do
        if not S.resp then S.rbuf = buf return nil end
        local need = n - #buf
        local c = S.resp.read(math.min(READ_BLOCK, math.max(4096, need)))
        if not c or c == "" then
            S.rbuf = buf
            return nil
        end
        buf = buf .. c
    end
    S.rbuf = buf:sub(n + 1)
    return buf:sub(1, n)
end

local function initDims(S, size)
    local ratio = 16 / 9
    if S.metaW and S.metaH and S.metaW > 0 and S.metaH > 0 then
        ratio = S.metaW / S.metaH
    end
    local bestW, bestDiff = math.floor(math.sqrt(size)), math.huge
    for w = 1, math.floor(math.sqrt(size)) do
        if size % w == 0 then
            for _, cand in ipairs({ w, size / w }) do
                local d = math.abs(cand / (size / cand) - ratio)
                if d < bestDiff then bestDiff, bestW = d, cand end
            end
        end
    end
    S.vw = bestW
    S.vh = size / bestW
    local z = math.min(math.floor(SW / S.vw), math.floor(SH / S.vh))
    local dz, ds = 1, 1
    if z >= 2 then
        if CFG.AUTO_ZOOM then dz = math.min(z, 4) end
    elseif z < 1 then
        ds = math.max(math.ceil(S.vw / SW), math.ceil(S.vh / SH))
    end
    local dw = (dz >= 2) and S.vw * dz or round(S.vw / ds)
    local dh = (dz >= 2) and S.vh * dz or round(S.vh / ds)
    S.geo = {
        dz = dz, ds = ds,
        vx = math.floor((SW - dw) / 2),
        vy = math.floor((SH - dh) / 2),
    }
end

local function completeFrame(S)
    if not S.curOpen then return end
    S.curOpen = false
    local cp = S.curParts
    S.curParts = nil
    if S.scanOnly then
        S.frameNo = S.frameNo + 1
        return
    end
    local maxn = -1
    for k in pairs(cp) do if k > maxn then maxn = k end end
    local t = {}
    for i = 0, maxn do t[#t + 1] = cp[i] or "" end
    local data = table.concat(t)
    if #data == 0 then return end
    S.frameNo = S.frameNo + 1
    if not S.vw then initDims(S, #data) end
    if not S.vw or not S.geo then return end
    local rows = makeFrame(S, data)
    S.videoQ[#S.videoQ + 1] = { i = S.frameNo - 1, rows = rows, sz = #data }
    S.videoBytes = S.videoBytes + #data
end

local function dispatch(S, typ, payload)
    if typ == 4 then
        S.audioNo = S.audioNo + 1
        if not S.scanOnly then
            S.audioQ[#S.audioQ + 1] = payload
            S.audioBytes = S.audioBytes + #payload
        end
    elseif typ == 6 and #payload >= 1 then
        local b = payload:byte(1)
        local ci = b % 16
        if ci == 0 and S.curOpen then completeFrame(S) end
        if not S.curOpen then S.curOpen = true S.curParts = {} end
        local dat = payload:sub(2)
        S.curParts[ci] = dat
        if #dat < CHUNK then completeFrame(S) end
    end
end

local function catchUpCheck(S)
    if not S.scanOnly then return end
    local fOk = (S.resumeF == nil) or (S.frameNo >= S.resumeF)
    local aOk = (S.resumeA == nil) or (S.audioNo >= S.resumeA)
    if fOk and aOk then
        S.scanOnly = false
        S.resumeF = nil
        S.resumeA = nil
        S.seeking = false
    end
end

local function endOfPart(S)
    completeFrame(S)
    closeResp(S)
    if S.partNo + 1 >= S.parts then
        S.eof = true
        S.seeking = false
    else
        S.partNo = S.partNo + 1
    end
end

local function openPart(S, p, retries)
    for _ = 1, (retries or 5) do
        if S.stop or S.seekReq or S.err then return false end
        local r, e = http.get(partURL(S, p), nil, true)
        if r then
            S.resp = r
            S.rbuf = ""
            S.partNo = p
            S.partStartFrame[p] = S.frameNo
            S.partStartAudio[p] = S.audioNo
            return true
        end
        local es = tostring(e)
        if p > 0 and (es:find("404") or es:find("Not Found")) then
            S.eof = true
            S.seeking = false
            return false
        end
        sleep(math.min(6, retries or 5))
    end
    S.err = "cannot reach server (is the tunnel up?)"
    return false
end

-- reopen `part`, rewind counters to its start and fast-scan forward to
-- where we were (or to a seek target). no payloads are kept while scanning.
local function recover(S, savedF, savedA, part)
    for attempt = 1, 6 do
        if S.stop or S.seekReq then return false end
        sleep(math.min(10, attempt * 2))
        local r = http.get(partURL(S, part), nil, true)
        if r then
            S.resp = r
            S.rbuf = ""
            S.partNo = part
            S.frameNo = S.partStartFrame[part] or 0
            S.audioNo = S.partStartAudio[part] or 0
            S.curOpen = false
            S.curParts = nil
            S.scanOnly = true
            S.resumeF = savedF
            S.resumeA = savedA
            return true
        end
    end
    S.err = "lost connection to server"
    return false
end

local function readOneRecord(S)
    local hdr = readExact(S, 3)
    if not hdr or #hdr < 3 then endOfPart(S) return end
    local typ = hdr:byte(1)
    local len = hdr:byte(2) * 256 + hdr:byte(3)
    if len == 0 then return end
    local payload = readExact(S, len)
    if not payload or #payload < len then
        completeFrame(S)
        closeResp(S)
        return "net"
    end
    dispatch(S, typ, payload)
    catchUpCheck(S)
end

local function doSeek(S, t)
    S.seeking = true
    S.seekReq = nil
    S.eof = false
    local targetA = math.max(0, math.floor(t / AUDIO_REC_SEC) + 1)
    local p = 0
    for i = S.parts - 1, 0, -1 do
        local sa = S.partStartAudio[i]
        if sa and sa < targetA then p = i break end
    end
    if not S.partStartAudio[p] then
        S.partStartAudio[p] = 0
        S.partStartFrame[p] = 0
    end
    closeResp(S)
    S.curOpen = false
    S.curParts = nil
    S.frameNo = S.partStartFrame[p]
    S.audioNo = S.partStartAudio[p]
    S.scanOnly = true
    S.resumeF = nil
    S.resumeA = targetA
    if not openPart(S, p, 3) then
        S.seeking = false
    end
end

local function downloader(S)
    while not S.stop do
        if S.err then
            sleep(0.3)
        elseif S.needRecover then
            local nr = S.needRecover
            S.needRecover = nil
            if not recover(S, nr.f, nr.a, nr.part) then
                S.needRecover = nr
                sleep(0.5)
            end
        elseif S.seekReq then
            doSeek(S, S.seekReq)
        else
            while ((S.videoBytes >= VIDEO_CAP and #S.videoQ > 0)
                or S.audioBytes >= AUDIO_CAP) do
                if S.seekReq or S.stop or S.err or S.needRecover then break end
                sleep(0.1)
            end
            if not S.seekReq and not S.stop and not S.err and not S.eof then
                if not S.resp then
                    openPart(S, S.partNo, 5)
                else
                    local ok, err = pcall(readOneRecord, S)
                    if not ok or err == "net" then
                        closeResp(S)
                        if not S.eof and not S.stop then
                            if not recover(S, S.frameNo, S.audioNo, S.partNo) then
                                -- keep err; user can press R after fixing
                            end
                        end
                    end
                end
            else
                sleep(0.05)
            end
        end
    end
    closeResp(S)
end

--------------------------------------------------------------------------
-- player screen
--------------------------------------------------------------------------

local function player(spk, movie)
    local S = newState(CFG.BASE_URL, movie.name, movie.parts, movie.fps,
                       movie.dur, movie.metaW, movie.metaH)
    local C = {
        pos = 0, t0 = now(), paused = false, muted = false,
        vol = CFG.VOLUME or 1,
        feedAmt = 0, feedMark = now(),
        finished = false, seekPending = nil,
        toast = nil, toastExp = 0,
    }

    local ditherA, ditherB
    local function buildDither(w)
        local a, b = {}, {}
        for i = 1, w do
            a[i] = string.char(((i % 2) == 1) and DEEP or BLACK)
            b[i] = string.char(((i % 2) == 1) and BLACK or DEEP)
        end
        ditherA = table.concat(a)
        ditherB = table.concat(b)
    end

    local function toast(msg)
        C.toast = msg
        C.toastExp = now() + 1.2
        C.hudNext = 0
    end

    local function apendingCalc()
        return math.max(0, C.feedAmt - (now() - C.feedMark) * 6000)
    end

    local function feedAudio()
        if not spk or C.paused or C.finished or C.muted or S.seeking then return end
        while #S.audioQ > 0 and apendingCalc() < SPK_PENDING_MAX do
            local taken, n = {}, 0
            while #S.audioQ > 0 and n < 32000 do
                local c = table.remove(S.audioQ, 1)
                S.audioBytes = S.audioBytes - #c
                taken[#taken + 1] = c
                n = n + #c
                if n >= 16000 then break end
            end
            local piece = table.concat(taken)
            local ok = spk.playAudio(piece, C.vol)
            if ok then
                C.feedAmt = apendingCalc() + n
                C.feedMark = now()
            else
                for i = #taken, 1, -1 do
                    table.insert(S.audioQ, 1, taken[i])
                    S.audioBytes = S.audioBytes + #taken[i]
                end
                break
            end
        end
    end

    local function seekTo(t, label)
        t = clamp(t, 0, math.max(0, S.dur - 0.5))
        if spk then spk.stop() end
        C.feedAmt = 0
        C.feedMark = now()
        S.videoQ = {} S.videoBytes = 0
        S.audioQ = {} S.audioBytes = 0
        S.seekReq = t
        S.seeking = true
        C.pos = math.floor(t * S.fps)
        C.seekPending = t
        C.finished = false
        collectgarbage("collect")
        toast(label or "SEEK")
    end

    local function togglePause()
        if C.finished then return end
        C.paused = not C.paused
        C.hudNext = 0
        if C.paused then
            if spk then spk.stop() end
            C.feedAmt = 0
        else
            C.t0 = now() - C.pos / S.fps
        end
    end

    local function drawHud(elapsed)
        local bw = SH - 30
        fill(0, bw, SW, 30, PANEL)
        fill(0, bw, SW, 1, PANEL2)
        drawText(6, bw + 4, fitText(movie.name:upper(), SW * 0.55, 1), LIGHT, PANEL, 1)
        local tstr = fmtTime(elapsed) .. " / " .. fmtTime(S.dur)
        drawText(SW - textWidth(tstr, 1) - 6, bw + 4, tstr, GREY, PANEL, 1)

        local tx, tw, ty = 6, SW - 12, bw + 14
        fill(tx, ty, tw, 5, DEEP)
        local buffered = clamp((elapsed + (#S.videoQ / S.fps)
            + S.audioBytes / 6000) / math.max(S.dur, 1), 0, 1)
        fill(tx, ty, round(tw * buffered), 5, PANEL2)
        local played = clamp(elapsed / math.max(S.dur, 1), 0, 1)
        fill(tx, ty, round(tw * played), 5, ACCENT)
        fill(clamp(tx + round(tw * played) - 2, tx, tx + tw - 5), ty - 2, 5, 9, WHITE)

        drawText(6, SH - 8, fitText("SPC PAUSE  <> SEEK  ^V VOL  M MUTE  Q QUIT",
            SW - 12, 1), GREY, PANEL, 1)
        if C.muted then
            drawText(SW - textWidth("MUTED", 1) - 6, SH - 8, "MUTED", ACCENT2, PANEL, 1)
        end

        if C.paused and not C.finished then
            if not ditherA or #ditherA ~= SW then buildDither(SW) end
            for y = 0, SH - 31 do
                term.drawPixels(0, y, (y % 2 == 0) and ditherA or ditherB)
            end
            local pw = textWidth("PAUSED", 4)
            fill(round(SW / 2 - pw / 2) - 16, round(SH / 2) - 26, pw + 32, 44, DEEP)
            drawText(round(SW / 2 - pw / 2), round(SH / 2) - 19, "PAUSED", WHITE, DEEP, 4)
            local sub = "SPACE OR TAP TO RESUME"
            drawText(round(SW / 2 - textWidth(sub, 1) / 2), round(SH / 2) + 10,
                sub, GREY, DEEP, 1)
        end

        if C.finished then
            fill(0, 0, SW, SH - 30, DEEP)
            local msgs = {
                { "PLAYBACK FINISHED", 3, WHITE },
                { fitText(movie.name:upper(), SW - 40, 2), 2, LIGHT },
                { "PRESS ANY KEY", 1, GREY },
            }
            local tot = 0
            for _, m in ipairs(msgs) do tot = tot + m[2] * 5 + 12 end
            local y = round((SH - 30 - tot) / 2)
            for _, m in ipairs(msgs) do
                drawText(round(SW / 2 - textWidth(m[1], m[2]) / 2), y, m[1], m[3], DEEP, m[2])
                y = y + m[2] * 5 + 12
            end
        end

        if S.err then
            fill(0, SH - 52, SW, 20, RED)
            local msg = fitText("ERR: " .. S.err:upper() .. "  [R RETRY]", SW - 12, 1)
            drawText(6, SH - 49, msg, WHITE, RED, 1)
        elseif S.seeking then
            drawSpinner(SW - 30, SH - 50, "SEEKING")
        elseif #S.videoQ == 0 and not S.eof and not C.finished and not C.paused then
            drawSpinner(SW - 30, SH - 50, "BUFFERING")
        end

        if C.toast and now() < C.toastExp then
            local m = C.toast
            local mw = textWidth(m, 2)
            fill(round(SW / 2 - mw / 2) - 10, 8, mw + 20, 20, DEEP)
            drawText(round(SW / 2 - mw / 2), 13, m, ACCENT, DEEP, 2)
        end
    end

    local function tick()
        local t = now()
        if S.eof and #S.videoQ == 0 and not C.finished then
            C.finished = true
            C.hudNext = 0
            if spk then spk.stop() end
        end
        if not C.paused and not C.finished and not S.seeking then
            local due = math.floor((t - C.t0) * S.fps)
            local drew = nil
            while C.pos < due and #S.videoQ > 0 do
                local fr = table.remove(S.videoQ, 1)
                S.videoBytes = S.videoBytes - fr.sz
                drew = fr
                C.pos = C.pos + 1
            end
            if drew then term.drawPixels(S.geo.vx, S.geo.vy, drew.rows) end
            if C.pos < due and #S.videoQ == 0 and not S.eof then
                C.t0 = t - C.pos / S.fps
            end
        end
        if C.seekPending and not S.seeking then
            C.t0 = now() - C.seekPending
            C.seekPending = nil
        end
        feedAudio()
        if t >= (C.hudNext or 0) then
            C.hudNext = t + 0.1
            drawHud(C.pos / S.fps)
        end
        if C.toast and now() >= C.toastExp then C.toast = nil end
    end

    fill(0, 0, SW, SH, BLACK)
    drawSpinner(round(SW / 2), round(SH / 2), "LOADING " .. movie.name:upper())

    local timer = os.startTimer(0.05)
    C.running = true

    local function control()
    while C.running do
        local ev, p1, p2, p3 = os.pullEventRaw()
        if ev == "timer" and p1 == timer then
            tick()
            timer = os.startTimer(0.04)
        elseif ev == "key" then
            local k = p1
            if C.finished then
                C.running = false S.stop = true
            elseif k == keys.q or k == keys.x or k == keys.escape
               or k == keys.backspace then
                C.running = false S.stop = true
            elseif k == keys.space or k == keys.p or k == keys.enter then
                togglePause()
            elseif k == keys.left then
                seekTo(C.pos / S.fps - 10, "-10S")
            elseif k == keys.right then
                seekTo(C.pos / S.fps + 10, "+10S")
            elseif k == keys.up then
                C.vol = clamp(C.vol + 0.25, 0, 3)
                CFG.VOLUME = C.vol saveCfg()
                toast("VOL " .. round(C.vol * 100) .. "%")
            elseif k == keys.down then
                C.vol = clamp(C.vol - 0.25, 0, 3)
                CFG.VOLUME = C.vol saveCfg()
                toast("VOL " .. round(C.vol * 100) .. "%")
            elseif k == keys.m then
                C.muted = not C.muted
                if C.muted and spk then spk.stop() C.feedAmt = 0 end
                toast(C.muted and "MUTED" or "SOUND ON")
            elseif k == keys.r and S.err then
                S.err = nil
            end
        elseif ev == "monitor_touch" then
            local px = (tonumber(p2) or 1) * 6 - 3
            local py = (tonumber(p3) or 1) * 9 - 4
            if C.finished then
                C.running = false S.stop = true
            elseif S.err then
                S.err = nil
            elseif py > SH - 30 then
                if px >= 4 and px <= SW - 4 then
                    seekTo(((px - 6) / (SW - 12)) * S.dur, "SCRUB")
                else
                    C.running = false S.stop = true
                end
            elseif px > SW - 22 and py > SH - 42 then
                C.running = false S.stop = true
            else
                if px < SW / 3 then
                    seekTo(C.pos / S.fps - 10, "-10S")
                elseif px > 2 * SW / 3 then
                    seekTo(C.pos / S.fps + 10, "+10S")
                else
                    togglePause()
                end
            end
        elseif ev == "speaker_audio_empty" then
            C.feedAmt = 0
            C.feedMark = now()
        elseif ev == "terminate" then
            C.running = false S.stop = true
            C.terminated = true
        end
    end
    end

    parallel.waitForAny(function() downloader(S) end, control)

    S.stop = true
    if spk then pcall(function() spk.stop() end) end
    return C.terminated == true
end

--------------------------------------------------------------------------
-- movie list / meta
--------------------------------------------------------------------------

local function fetchList()
    local txt, err = httpGetText(CFG.BASE_URL .. "/movies.txt")
    if not txt then return nil, err end
    local items = {}
    for rawline in txt:gmatch("[^\r\n]+") do
        local line = (rawline:gsub("^%s+", "")):gsub("%s+$", "")
        if #line > 0 then
            local name, secs = line:match("^(.-)%s+(%d+%.?%d*)$")
            if name then
                items[#items + 1] = { name = name, dur = tonumber(secs) }
            else
                items[#items + 1] = { name = line, dur = nil }
            end
        end
    end
    table.sort(items, function(a, b) return a.name:lower() < b.name:lower() end)
    return items
end

local function fetchMeta(name)
    local e = urlenc(name)
    local txt, err = httpGetText(CFG.BASE_URL .. "/" .. e .. "/" .. e .. ".meta")
    if not txt then return nil, err end
    local vals = {}
    for v in txt:gmatch("%S+") do vals[#vals + 1] = v end
    return {
        w = tonumber(vals[1]), h = tonumber(vals[2]),
        fps = tonumber(vals[3]) or 30,
        parts = tonumber(vals[4]) or 1,
        blk = tonumber(vals[5]) or 1,
        mode = tonumber(vals[6]) or 0,
    }
end

--------------------------------------------------------------------------
-- menu screen
--------------------------------------------------------------------------

local ITEM_H = 46

local function centerText(y, s, fg, bg, scale)
    drawText(round(SW / 2 - textWidth(s, scale) / 2), y, s, fg, bg, scale)
end

local function messageScreen(lines)
    fill(0, 0, SW, SH, BG)
    local tot = 0
    for _, l in ipairs(lines) do tot = tot + l[2] * 5 + 14 end
    local y = round((SH - tot) / 2)
    for _, l in ipairs(lines) do
        centerText(y, fitText(l[1], SW - 40, l[2]), l[3], BG, l[2])
        y = y + l[2] * 5 + 14
    end
end

local function drawMenuItem(y, item, selected, w)
    local bgc = selected and DEEP or BG
    if selected then
        fill(0, y, w, ITEM_H - 6, DEEP)
        fill(0, y, 4, ITEM_H - 6, ACCENT)
    end
    local fg = selected and ACCENT or PANEL2
    local rows = { "#....", "##...", "###..", "##...", "#...." }
    for r = 1, 5 do
        local seg = {}
        for c = 1, 5 do
            seg[#seg + 1] = string.rep(string.char(
                rows[r]:sub(c, c) == "#" and fg or bgc), 2)
        end
        term.drawPixels(16, y + 12 + (r - 1) * 2, table.concat(seg))
    end
    drawText(38, y + 8, fitText(item.name:upper(), w - 150, 2),
        selected and WHITE or LIGHT, bgc, 2)
    drawText(38, y + 24, item.dur and (fmtTime(item.dur)) or "MOVIE",
        GREY, bgc, 1)
end

local function menuScreen()
    local items, listErr = nil, nil
    local sel, scroll = 1, 0
    local loading = true
    local visible = math.max(1, math.floor((SH - 100) / ITEM_H))

    local function startFetch()
        loading = true
        items = nil
        listErr = nil
        parallel.waitForAny(
            function()
                local ok, it, e = pcall(fetchList)
                if ok then items, listErr = it, e else listErr = it end
                loading = false
            end,
            function()
                while loading do
                    drawSpinner(round(SW / 2), round(SH / 2), "FETCHING LIST")
                    sleep(0.08)
                end
            end)
    end

    local function render()
        fill(0, 0, SW, SH, BG)
        fill(0, 0, SW, 42, PANEL)
        fill(0, 42, SW, 1, PANEL2)
        drawText(10, 8, "CC CINEMA", WHITE, PANEL, 3)
        drawText(10 + textWidth("CC CINEMA", 3) + 12, 18, "CLOUD STREAM",
            ACCENT, PANEL, 1)
        for x = 0, SW - 1 do
            term.drawPixels(x, 40, string.char(36 * (1 + math.floor(
                4 * x / math.max(SW - 1, 1))) + 30))
        end

        if loading then return end
        if listErr then
            messageScreen({
                { "FAILED TO LOAD MOVIES", 2, RED },
                { fitText(tostring(listErr):upper(), SW - 60, 1), 1, GREY },
                { "[R] RETRY      [U] CHANGE URL", 1, ACCENT },
            })
            return
        end
        if #items == 0 then
            messageScreen({
                { "NO MOVIES YET", 2, ACCENT2 },
                { "RUN: PYTHON PREPARE.PY <VIDEO.MP4>  (MODE 3)", 1, GREY },
            })
            return
        end

        if sel < scroll + 1 then scroll = sel end
        if sel > scroll + visible - 1 then scroll = sel - visible + 1 end
        scroll = clamp(scroll, 1, math.max(1, #items - visible + 1))

        for idx = scroll, math.min(#items, scroll + visible - 1) do
            local y = 54 + (idx - scroll) * ITEM_H
            drawMenuItem(y, items[idx], idx == sel, SW)
        end
        if scroll > 1 then centerText(SH - 34, "^ MORE", GREY, BG, 1) end
        if scroll + visible <= #items then centerText(SH - 26, "v MORE", GREY, BG, 1) end

        fill(0, SH - 16, SW, 16, PANEL)
        fill(0, SH - 16, SW, 1, PANEL2)
        local hint = "^V SELECT   ENTER PLAY   U URL   R REFRESH   ESC QUIT"
        centerText(SH - 11, fitText(hint, SW - 20, 1), GREY, PANEL, 1)
        local posStr = tostring(sel) .. "/" .. tostring(#items)
        drawText(SW - textWidth(posStr, 1) - 8, SH - 11, posStr, LIGHT, PANEL, 1)
    end

    local function play(item)
        local m = fetchMeta(item.name)
        if not m then
            messageScreen({
                { "META MISSING", 2, RED },
                { fitText(tostring(item.name):upper(), SW - 40, 1), 1, GREY },
                { "WAS IT ENCODED WITH PREPARE.PY?", 1, GREY },
            })
            sleep(2.5)
            return
        end
        if m.mode ~= 3 then
            messageScreen({
                { "NOT A GFX ENCODE", 2, RED },
                { "RE-RUN PREPARE.PY AND PICK MODE 3 (PIXEL/GFX)", 1, GREY },
            })
            sleep(2.5)
            return
        end
        local terminated = player(peripheral.find("speaker"), {
            name = item.name,
            dur = item.dur or 0,
            parts = m.parts,
            fps = m.fps,
            metaW = m.w,
            metaH = m.h,
        })
        return terminated
    end

    startFetch()
    render()
    while true do
        local ev, p1, p2, p3 = os.pullEventRaw()
        if ev == "key" then
            local k = p1
            if k == keys.up or k == keys.w then
                if items and #items > 0 then
                    sel = clamp(sel - 1, 1, #items)
                    render()
                end
            elseif k == keys.down or k == keys.s then
                if items and #items > 0 then
                    sel = clamp(sel + 1, 1, #items)
                    render()
                end
            elseif k == keys.enter or k == keys.space then
                if items and items[sel] then
                    if play(items[sel]) then return true end
                    render()
                end
            elseif k == keys.r then
                startFetch()
                render()
            elseif k == keys.u then
                promptUrl()
                startFetch()
                render()
            elseif k == keys.q or k == keys.escape then
                return false
            end
        elseif ev == "monitor_touch" then
            local px = (tonumber(p2) or 1) * 6 - 3
            local py = (tonumber(p3) or 1) * 9 - 4
            if px >= 0 and py >= 54 and py < 54 + visible * ITEM_H
               and items and #items > 0 then
                local idx = scroll + math.floor((py - 54) / ITEM_H)
                if idx >= 1 and idx <= #items then
                    if idx == sel then
                        if play(items[idx]) then return true end
                    else
                        sel = idx
                    end
                    render()
                end
            end
        elseif ev == "mouse_scroll" then
            if items and #items > 0 then
                sel = clamp(sel + p1, 1, #items)
                render()
            end
        elseif ev == "terminate" then
            return false
        end
    end
end

--------------------------------------------------------------------------
-- main
--------------------------------------------------------------------------

local function findMonitor()
    local best = nil
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local p = peripheral.wrap(name)
            local w, h = p.getSize()
            if not best or w * h > best.w * best.h then
                best = { p = p, name = name, w = w, h = h }
            end
        end
    end
    return best
end

local oldScale = nil

local function cleanup(mon)
    pcall(function()
        term.setGraphicsMode(false)
        if mon and oldScale then mon.setTextScale(oldScale) end
        term.clear()
    end)
    pcall(function() term.restore() end)
end

local function main()
    loadCfg()
    while not CFG.BASE_URL or CFG.BASE_URL == "" do
        if not promptUrl() then sleep(1) end
    end

    local mon = findMonitor()
    if not mon then
        error("No monitor attached - place one next to the computer.", 0)
    end

    print("[cinema] monitor: " .. mon.name)
    print("[cinema] server : " .. CFG.BASE_URL)

    pcall(function() oldScale = mon.getTextScale() end)
    pcall(function() mon.setTextScale(CFG.TEXT_SCALE or 0.5) end)
    term.redirect(mon)

    if not term.setGraphicsMode then
        term.restore()
        error("CC:Graphics not detected (term.setGraphicsMode missing).", 0)
    end
    term.setGraphicsMode(2)

    local tw, th = term.getSize()
    local ok2, pw, ph = pcall(term.getSize, 2)
    if ok2 and pw and pw ~= tw then
        SW, SH = pw, ph
    else
        SW, SH = tw * 6, th * 9
    end

    setupPalette()
    fill(0, 0, SW, SH, BG)
    centerText(round(SH / 2) - 10, "CC CINEMA", WHITE, BG, 3)
    centerText(round(SH / 2) + 14, "CONNECTING...", GREY, BG, 1)

    local quit = menuScreen()
    cleanup(mon)
    if quit then return end
end

local ok, err = pcall(main)
cleanup(findMonitor())
if not ok then
    term.setTextColor(colors.red)
    print("\n[cinema] crashed: " .. tostring(err))
end
