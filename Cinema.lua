
local CFG_PATH = "/cinema.cfg"

local CHUNK           = 65000
local AUDIO_REC_SEC   = 0.25
local VIDEO_CAP       = 1400000
local AUDIO_CAP       = 720000
local SPK_PENDING_MAX = 64000
local READ_BLOCK      = 32768

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


local CFG = { BASE_URL = "", VOLUME = 1.0, TEXT_SCALE = 0.5, AUTO_ZOOM = true, AUDIO_OFFSET = 0, AUDIO_LAG_MS = 300 }


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


local function httpGetText(url)
    local r = http.get(url, nil, true)
    if not r then return nil, "could not connect" end
    local s = r.readAll()
    r.close()
    if not s then return nil, "empty response" end
    return s
end

local ROW_STRINGS = true

local function probePixelFormat()
    local ok = pcall(term.drawPixels, 0, 0, "\1\1\1")
    if not ok then
        ROW_STRINGS = false
        ok = pcall(term.drawPixels, 0, 0, { 1, 1, 1 })
        if not ok then
            error("CC:Graphics drawPixels accepts neither strings nor tables.", 0)
        end
    end
end

local function drawRow(x, y, s)
    if ROW_STRINGS then
        term.drawPixels(x, y, s)
    else
        term.drawPixels(x, y, { { s:byte(1, #s) } })
    end
end

local function drawRows(x, y, rows)
    if ROW_STRINGS then
        term.drawPixels(x, y, rows)
    else
        local t = {}
        for i = 1, #rows do t[i] = { rows[i]:byte(1, #rows[i]) } end
        term.drawPixels(x, y, t)
    end
end


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

local function textWidth(s, scale) return #s * 5 * scale end

local function fitText(s, maxPx, scale)
    if textWidth(s, scale) <= maxPx then return s end
    local n = math.floor(maxPx / (5 * scale)) - 1
    if n < 1 then n = 1 end
    if n >= #s then return s end
    return s:sub(1, n) .. "~"
end

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
            seg[#seg + 1] = string.rep(string.char(bg), 2 * scale)
        end
        local rowStr = table.concat(seg)
        for v = 0, scale - 1 do
            drawRow(x, y + r * scale + v, rowStr)
        end
    end
    return textWidth(s, scale)
end


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
    if geo.kind == "zoom" and geo.z >= 2 then
        local z, x0, y0 = geo.z, geo.x0, geo.y0
        local want = x0 + geo.w
        local emitted, skip = 0, y0
        for y = 1, S.vh do
            if emitted >= geo.h then break end
            local er = expandRow(data:sub((y - 1) * vw + 1, y * vw), z)
            if #er > want then er = er:sub(x0 + 1, want) end
            for k = 1, z do
                if skip > 0 then
                    skip = skip - 1
                elseif emitted < geo.h then
                    rows[#rows + 1] = er
                    emitted = emitted + 1
                end
            end
        end
    elseif geo.kind == "down" then
        local d = geo.ds
        local half = math.ceil(d / 2)
        for y = half, S.vh, d do
            if #rows >= geo.h then break end
            local sr = data:sub((y - 1) * vw + 1, y * vw)
            local acc = {}
            for x = half, vw, d do acc[#acc + 1] = sr:sub(x, x) end
            rows[#rows + 1] = table.concat(acc)
        end
    else
        for y = 1, S.vh do
            rows[#rows + 1] = data:sub((y - 1) * vw + 1, y * vw)
        end
    end
    return rows
end


local function newState(base, name, parts, fps, dur, metaW, metaH,
                        sepAudio, pcmAudio)
    return {
        base = base, name = name, parts = parts, fps = fps, dur = dur,
        sepAudio = sepAudio and true or false,
        pcmAudio = pcmAudio and true or false,
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
    local vh2 = SH
    local f = math.min(SW / S.vw, vh2 / S.vh)
    local geo
    if f < 0.75 then
        local ds = math.max(math.ceil(1 / f), 1)
        local dw, dh = round(S.vw / ds), round(S.vh / ds)
        geo = { kind = "down", ds = ds,
                vx = math.floor((SW - dw) / 2), vy = math.floor((vh2 - dh) / 2),
                w = dw, h = dh, z = 1 }
    else
        local z = 1
        if CFG.AUTO_ZOOM ~= false then z = math.max(1, math.floor(f + 0.5)) end
        local dw, dh = S.vw * z, S.vh * z
        local x0 = math.floor((dw - SW) / 2)
        if x0 < 0 then x0 = 0 end
        local y0 = math.floor((dh - vh2) / 2)
        if y0 < 0 then y0 = 0 end
        local wv = math.min(dw - x0, SW)
        local hv = math.min(dh - y0, vh2)
        geo = { kind = "zoom", z = z,
                x0 = x0, y0 = y0, w = wv, h = hv,
                vx = math.floor((SW - wv) / 2),
                vy = math.floor((vh2 - hv) / 2) }
    end
    geo.scaleLabel = (geo.kind == "zoom")
        and (tostring(geo.z) .. "x" .. ((geo.x0 > 0 or geo.y0 > 0) and " crop" or ""))
        or ("1/" .. tostring(geo.ds))
    S.geo = geo
end

-- PackBits inverse: restores the exact vw*vh pixel string of a frame that
-- prepare.py compressed (saves ~3-10x on the Cloudflare tunnel's bandwidth).
local function unpackBits(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        i = i + 1
        if c <= 127 then
            local m = c + 1
            out[#out + 1] = s:sub(i, i + m - 1)
            i = i + m
        elseif c >= 129 then
            out[#out + 1] = s:sub(i, i):rep(257 - c)
            i = i + 1
        else
            break -- c == 128 is never produced; defensive no-op
        end
    end
    return table.concat(out)
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
    local data = unpackBits(table.concat(t))
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
    local p = 0
    local resumeF, resumeA
    if S.sepAudio then
        local targetF = math.max(0, math.floor(t * S.fps))
        for i = S.parts - 1, 0, -1 do
            local sf = S.partStartFrame[i]
            if sf and sf <= targetF then p = i break end
        end
        if not S.partStartFrame[p] then
            S.partStartFrame[p] = 0
            S.partStartAudio[p] = 0
        end
        resumeF, resumeA = targetF, nil
    else
        local targetA = math.max(0, math.floor(t / AUDIO_REC_SEC) + 1)
        for i = S.parts - 1, 0, -1 do
            local sa = S.partStartAudio[i]
            if sa and sa < targetA then p = i break end
        end
        if not S.partStartAudio[p] then
            S.partStartAudio[p] = 0
            S.partStartFrame[p] = 0
        end
        resumeF, resumeA = nil, targetA
    end
    closeResp(S)
    S.curOpen = false
    S.curParts = nil
    S.frameNo = S.partStartFrame[p]
    S.audioNo = S.partStartAudio[p]
    S.scanOnly = true
    S.resumeF = resumeF
    S.resumeA = resumeA
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


local function audioURL(S)
    local e = urlenc(S.name)
    return S.base .. "/" .. e .. "/" .. e .. ".audio.dfpwm"
end

local function audioStreamer(S)
    local resp = nil
    local apos = 0
    local function close()
        if resp then pcall(function() resp.close() end) end
        resp = nil
        apos = 0
    end
    while not S.stop do
        if S.audioSeekByte then
            local target = S.audioSeekByte
            S.audioSeekByte = nil
            if target < apos then close() end
            S.audioDiscardTo = target
        end
        local discarding = S.audioDiscardTo ~= nil and apos < S.audioDiscardTo
        if not resp and not S.audioFileDead then
            local opened = false
            for attempt = 1, 5 do
                if S.stop or S.audioSeekByte then break end
                local r, e = http.get(audioURL(S), nil, true)
                if r then resp = r opened = true break end
                local es = tostring(e)
                if es:find("404") or es:find("Not Found") then
                    S.audioFileDead = true
                    break
                end
                sleep(math.min(6, attempt))
            end
            if not opened and not resp then
                if not S.audioFileDead then S.audioFileDead = true end
            end
        end
        if resp then
            if not discarding and S.audioBytes >= AUDIO_CAP then
                sleep(0.1)
            else
                local c = resp.read(16384)
                if not c then
                    close()
                    while not S.stop and not S.audioSeekByte do sleep(0.2) end
                else
                    if discarding then
                        local before = S.audioDiscardTo - apos
                        apos = apos + #c
                        if #c > before then
                            local keep = c:sub(before + 1)
                            S.audioQ[#S.audioQ + 1] = keep
                            S.audioBytes = S.audioBytes + #keep
                            S.audioDiscardTo = nil
                        end
                    else
                        apos = apos + #c
                        S.audioQ[#S.audioQ + 1] = c
                        S.audioBytes = S.audioBytes + #c
                    end
                end
            end
        else
            sleep(0.2)
        end
    end
    close()
end


local audioDecoder = nil
pcall(function()
    local lib = require("cc.audio.dfpwm")
    if type(lib) == "table" and type(lib.make_decoder) == "function" then
        audioDecoder = lib.make_decoder()
    end
end)
local SPK_MODE = 0

local function spkStop(spk)
    if spk then pcall(function() spk.stop() end) end
end

local function player(spk, movie)
    local S = newState(CFG.BASE_URL, movie.name, movie.parts, movie.fps,
                       movie.dur, movie.metaW, movie.metaH,
                       movie.sepAudio, movie.pcmAudio)
    local C = {
        pos = 0, t0 = now(), paused = false, muted = false,
        vol = CFG.VOLUME or 1,
        feedAmt = 0, feedMark = now(),
        finished = false, seekPending = nil,
        toast = nil, toastExp = 0,
        audioSec = 0, dbg = false, audioDeadShown = false,
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
        if not spk then
            if not C.audioDeadShown then
                C.audioDeadShown = true
                C.muted = true
                toast("NO SPEAKER ATTACHED")
            end
            return
        end
        if not C.spkVerified then
            C.spkVerified = true
            C.spkMethods = ""
            for k2 in pairs(spk) do C.spkMethods = C.spkMethods .. tostring(k2) .. "," end
        end
        if C.paused or C.finished or C.muted or S.seeking then return end
        if SPK_MODE >= 2 then return end
        local target = (now() - C.t0) + (CFG.AUDIO_OFFSET or 0) / 1000
            - (CFG.AUDIO_LAG_MS or 300) / 1000

        if not C.sawEmpty and not C.legacyPacing then
            C.feedOk = (C.feedOk or 0) + 1
            if C.feedOk >= 15 then C.legacyPacing = true end
        end
        local legacy = C.legacyPacing
        local capMax = ((SPK_MODE == 1 or S.pcmAudio) and
            (legacy and 4000 or 16000)) or (legacy and 8000 or 32000)
        local capMin = ((SPK_MODE == 1 or S.pcmAudio) and
            (legacy and 2000 or 8000)) or (legacy and 4000 or 16000)

        local pieces = 0
        while #S.audioQ > 0
            and (legacy or apendingCalc() < SPK_PENDING_MAX)
            and C.audioSec < target
            and pieces < (legacy and 6 or 64) do
            local taken, n = {}, 0
            while #S.audioQ > 0 and n < capMax do
                local c = table.remove(S.audioQ, 1)
                S.audioBytes = S.audioBytes - #c
                taken[#taken + 1] = c
                n = n + #c
                if n >= capMin then break end
            end
            local piece = table.concat(taken)
            local payload = piece
            if S.pcmAudio then
                payload = {}
                for i = 1, #piece do
                    local b2 = piece:byte(i)
                    payload[i] = b2 < 128 and b2 or b2 - 256
                end
            elseif SPK_MODE == 1 then
                if not audioDecoder then SPK_MODE = 2 end
            end
            if SPK_MODE == 1 and audioDecoder then
                local decOk, pcm = pcall(audioDecoder, piece)
                if not decOk or pcm == nil then
                    SPK_MODE = 2
                elseif type(pcm) == "string" then
                    payload = {}
                    for i = 1, #pcm do
                        local b = pcm:byte(i)
                        payload[i] = b < 128 and b or b - 256
                    end
                elseif type(pcm) == "table" then
                    payload = pcm
                else
                    SPK_MODE = 2
                end
            end
            local ok = false
            if S.pcmAudio then
                local callOk = pcall(spk.playAudio, payload, C.vol)
                if not callOk then
                    callOk = pcall(spk.playAudio, payload)
                end
                if callOk then
                    ok = true
                    C.lastSpkErr = nil
                elseif not C.audioDeadShown then
                    C.audioDeadShown = true
                    C.muted = true
                    toast("NO AUDIO SUPPORT")
                end
            elseif SPK_MODE < 2 then
                local callOk, callErr = pcall(spk.playAudio, payload, C.vol)
                if not callOk then
                    callOk = pcall(spk.playAudio, payload)
                end
                if callOk then
                    ok = true
                    C.lastSpkErr = nil
                elseif SPK_MODE == 0 and audioDecoder then
                    SPK_MODE = 1
                elseif SPK_MODE == 1 then
                    local retryOk = pcall(spk.playAudio, payload)
                    if retryOk then
                        ok = true
                    else
                        SPK_MODE = 2
                        C.lastSpkErr = tostring(callErr)
                    end
                else
                    SPK_MODE = 2
                    C.lastSpkErr = tostring(callErr)
                end
            end
            if SPK_MODE >= 2 and not C.audioDeadShown then
                C.audioDeadShown = true
                C.muted = true
                toast("NO AUDIO SUPPORT")
            end
            if ok then
                pieces = pieces + 1
                if S.pcmAudio then
                    C.audioSec = C.audioSec + n / 48000
                else
                    C.audioSec = C.audioSec + n / 6000
                    C.feedAmt = apendingCalc() + n
                    C.feedMark = now()
                end
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
        spkStop(spk)
        C.feedAmt = 0
        C.feedMark = now()
        S.videoQ = {} S.videoBytes = 0
        S.audioQ = {} S.audioBytes = 0
        C.audioSec = t
        if S.sepAudio then
            S.audioSeekByte = math.max(0, math.floor(t * 6000))
        end
        S.seekReq = t
        S.seeking = true
        C.pos = math.floor(t * S.fps)
        C.seekPending = t
        C.finished = false
                toast(label or "SEEK")
    end

    local function togglePause()
        if C.finished then return end
        C.paused = not C.paused
        C.hudNext = 0
        if C.paused then
            spkStop(spk)
            C.feedAmt = 0
        else
            C.t0 = now() - C.pos / S.fps
        end
    end

    local function drawHud(elapsed)
        if C.paused and not C.finished then
            if not ditherA or #ditherA ~= SW then buildDither(SW) end
            for y = 0, SH - 1 do
                drawRow(0, y, (y % 2 == 0) and ditherA or ditherB)
            end
            local pw = textWidth("PAUSED", 4)
            fill(round(SW / 2 - pw / 2) - 16, round(SH / 2) - 26, pw + 32, 44, DEEP)
            drawText(round(SW / 2 - pw / 2), round(SH / 2) - 19, "PAUSED", WHITE, DEEP, 4)
            local sub = "SPACE OR TAP TO RESUME"
            drawText(round(SW / 2 - textWidth(sub, 1) / 2), round(SH / 2) + 10,
                sub, GREY, DEEP, 1)
        end

        if C.finished then
            fill(0, 0, SW, SH, DEEP)
            local msgs = {
                { "PLAYBACK FINISHED", 3, WHITE },
                { fitText(movie.name:upper(), SW - 40, 2), 2, LIGHT },
                { "PRESS ANY KEY", 1, GREY },
            }
            local tot = 0
            for _, m in ipairs(msgs) do tot = tot + m[2] * 5 + 12 end
            local y = round((SH - tot) / 2)
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

        if C.dbg and S.geo then
            local info = string.format(
                "GFX %dx%d VID %dx%d %s Q v=%d a=%ds(%s%s) SYNC %+.1fs DELAY %.1fs SPK m%d %s",
                SW, SH, S.vw, S.vh, S.geo.scaleLabel,
                S.videoBytes, S.audioBytes / (S.pcmAudio and 48000 or 6000),
                tostring(S.sepAudio), tostring(S.audioFileDead == true),
                (CFG.AUDIO_OFFSET or 0) / 1000,
                (CFG.AUDIO_LAG_MS or 300) / 1000,
                SPK_MODE,
                spk and (C.lastSpkErr and ("ERR " .. C.lastSpkErr) or "ok")
                   or "NO SPEAKER")
            fill(0, SH - 62, SW, 12, DEEP)
            drawText(4, SH - 60, info, GREEN or ACCENT, DEEP, 1)
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
            spkStop(spk)
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
            if drew then drawRows(S.geo.vx, S.geo.vy, drew.rows) end
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
            elseif k == keys.f then
                C.dbg = not C.dbg
                C.hudNext = 0
            elseif k == keys.comma or p1 == keys.comma then
                CFG.AUDIO_OFFSET = clamp((CFG.AUDIO_OFFSET or 0) - 100, -5000, 5000)
                saveCfg()
                C.hudNext = 0
                toast(string.format("SYNC %.1fs", (CFG.AUDIO_OFFSET or 0) / 1000))
            elseif k == keys.period or p1 == keys.period then
                CFG.AUDIO_OFFSET = clamp((CFG.AUDIO_OFFSET or 0) + 100, -5000, 5000)
                saveCfg()
                C.hudNext = 0
                toast(string.format("SYNC %.1fs", (CFG.AUDIO_OFFSET or 0) / 1000))
            elseif k == keys.m then
                C.muted = not C.muted
                if C.muted then spkStop(spk) C.feedAmt = 0 end
                toast(C.muted and "MUTED" or "SOUND ON")
            elseif k == keys.r then
                S.err = nil
                S.audioFileDead = nil
                SPK_MODE = (audioDecoder or SPK_MODE ~= 0) and SPK_MODE or 0
                C.audioDeadShown = false
                C.hudNext = 0
            end
        elseif ev == "monitor_touch" then
            local cx = tonumber(p2) or 0
            local cy = tonumber(p3) or 0
            local pts = {
                { cx * 6 - 3, cy * 9 - 4 },
                { cx * 6 + 3, cy * 9 + 4 },
                { cx, cy },
            }
            local action = nil
            for _, pt in ipairs(pts) do
                if C.finished then action = "quit"
                elseif S.err then action = "retry"
                elseif pt[1] > SW - 22 and pt[2] > SH - 42 then
                    action = "quit"
                elseif pt[2] <= SH then
                    if pt[1] < SW / 3 then action = "back"
                    elseif pt[1] > 2 * SW / 3 then action = "fwd"
                    else action = "toggle" end
                end
                if action then break end
            end
            if action == "quit" then
                C.running = false S.stop = true
            elseif action == "retry" then
                S.err = nil C.hudNext = 0
            elseif action == "toggle" then
                togglePause()
            elseif action == "back" then
                seekTo(C.pos / S.fps - 10, "-10S")
            elseif action == "fwd" then
                seekTo(C.pos / S.fps + 10, "+10S")
            end
        elseif ev == "speaker_audio_empty" then
            C.sawEmpty = true
            C.feedAmt = 0
            C.feedMark = now()
        elseif ev == "terminate" then
            C.running = false S.stop = true
            C.terminated = true
        end
    end
    end

    local threads = { function() downloader(S) end }
    if S.sepAudio and not S.audioFileDead then
        threads[#threads + 1] = function() audioStreamer(S) end
    end
    threads[#threads + 1] = control
    parallel.waitForAny(table.unpack(threads))

    S.stop = true
    spkStop(spk)
    return C.terminated == true
end


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
        hasAudio = tonumber(vals[7]) or 0,
        pcm = (tonumber(vals[7]) or 0) == 2,
    }
end


local function fetchExtras(name)
    local e = urlenc(name)
    local dir = CFG.BASE_URL .. "/" .. e
    local desc = httpGetText(dir .. "/" .. e .. ".desc.txt")
    if desc then desc = desc:gsub("\r", "") end
    local thumb = nil
    local mt = httpGetText(dir .. "/" .. e .. ".thumb.meta")
    if mt then
        local dims = {}
        for v in mt:gmatch("%d+") do dims[#dims + 1] = tonumber(v) end
        local tw, th = dims[1] or 128, dims[2] or 72
        local r = http.get(dir .. "/" .. e .. ".thumb", nil, true)
        if r then
            local data = r.readAll()
            pcall(function() r.close() end)
            if data and #data >= tw * th then
                thumb = { w = tw, h = th, data = data:sub(1, tw * th) }
            end
        end
    end
    return desc, thumb
end

local function wrapText(s, maxChars)
    local out = {}
    for para in (s .. "\n"):gmatch("([^\n]*)\n") do
        if para == "" then
            out[#out + 1] = ""
        else
            local line = ""
            for word0 in para:gmatch("%S+") do
                local word = word0
                while #word > maxChars do
                    if line ~= "" then
                        out[#out + 1] = line
                        line = ""
                    end
                    out[#out + 1] = word:sub(1, maxChars)
                    word = word:sub(maxChars + 1)
                end
                if #line == 0 then line = word
                elseif #line + 1 + #word <= maxChars then
                    line = line .. " " .. word
                else
                    out[#out + 1] = line
                    line = word
                end
            end
            out[#out + 1] = line
        end
    end
    return out
end


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
        drawRow(16, y + 12 + (r - 1) * 2, table.concat(seg))
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
        drawText(10 + textWidth("CC CINEMA", 3) + 12, 18, "CLOUD STREAM V4",
            ACCENT, PANEL, 1)
        for x = 0, SW - 1 do
            drawRow(x, 40, string.char(36 * (1 + math.floor(
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

    local function infoScreen(item, m, desc, thumb)
        local lines = {}
        if desc and #desc > 0 then
            lines = wrapText(desc:upper(), math.floor((SW - 48) / 10))
        end
        local view = 0

        local trows, tw2, th2
        if thumb then
            tw2, th2 = thumb.w, thumb.h
            local z = math.max(1, math.floor(math.min((SW - 100) / tw2,
                84 / th2)))
            tw2, th2 = tw2 * z, th2 * z
            trows = {}
            for y = 1, thumb.h do
                local row = thumb.data:sub((y - 1) * thumb.w + 1,
                                           y * thumb.w)
                row = expandRow(row, z)
                for k = 1, z do trows[#trows + 1] = row end
            end
        end

        local irender = function()
            fill(0, 0, SW, SH, BG)
            drawText(12, 6, fitText(item.name:upper(), SW - 24, 2),
                WHITE, BG, 2)
            drawText(12, 22, fmtTime(item.dur or 0) .. "   "
                .. tostring(m.parts) .. " PARTS   " .. tostring(m.fps) .. " FPS",
                GREY, BG, 1)
            fill(0, 32, SW, 1, PANEL2)

            local ty = 40
            if trows then
                fill(10, ty - 3, tw2 + 6, th2 + 6, PANEL)
                term.drawPixels(13, ty, trows)
                ty = ty + th2 + 16
            end
            local availH = SH - 42 - ty
            local maxVis = math.max(1, math.floor(availH / 14))
            view = clamp(view, 0, math.max(0, #lines - maxVis))
            for i = 1, maxVis do
                local ln = lines[view + i]
                if not ln then break end
                drawText(12, ty + (i - 1) * 14, fitText(ln, SW - 44, 2),
                    LIGHT, BG, 2)
            end
            if #lines > maxVis then
                local barH = math.max(12, math.floor(availH *
                    maxVis / #lines))
                local barY = ty + math.floor((availH - barH) *
                    (view / math.max(1, #lines - maxVis)))
                fill(SW - 10, ty, 5, availH, PANEL)
                fill(SW - 10, barY, 5, barH, ACCENT)
            end
            fill(0, SH - 30, SW, 30, PANEL)
            fill(0, SH - 30, SW, 1, PANEL2)
            centerText(SH - 15,
                fitText("ENTER PLAY     UP/DOWN SCROLL     ESC BACK",
                    SW - 20, 2), GREY, PANEL, 2)
        end

        irender()
        while true do
            local ev, p1 = os.pullEventRaw()
            if ev == "key" then
                if p1 == keys.enter or p1 == keys.space then
                    return true
                elseif p1 == keys.escape or p1 == keys.q
                    or p1 == keys.backspace then
                    return false
                elseif p1 == keys.up and view > 0 then
                    view = view - 3
                    irender()
                elseif p1 == keys.down and view < math.max(0, #lines - 1) then
                    view = view + 3
                    irender()
                end
            elseif ev == "mouse_scroll" then
                view = clamp(view + p1 * 3, 0, math.max(0, #lines))
                irender()
            elseif ev == "monitor_touch" then
                local py = (tonumber(p2) or 1) * 9
                if py > SH - 30 then
                    return true
                end
                view = clamp(view + 3, 0, math.max(0, #lines))
                irender()
            elseif ev == "terminate" then
                return false
            end
        end
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

                local okD, desc, thumb = pcall(fetchExtras, item.name)
        if okD and ((desc and #desc > 0) or thumb) then
            render()
            if not infoScreen(item, m, desc, thumb) then
                render()
                return
            end
        end
        local terminated = player(peripheral.find("speaker"), {
            name = item.name,
            dur = item.dur or 0,
            parts = m.parts,
            fps = m.fps,
            metaW = m.w,
            metaH = m.h,
            sepAudio = m.hasAudio == 1,
            pcmAudio = m.pcm,
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
        if mon and mon.p and oldScale then mon.p.setTextScale(oldScale) end
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

    pcall(function() oldScale = mon.p.getTextScale() end)
    pcall(function() mon.p.setTextScale(CFG.TEXT_SCALE or 0.5) end)
    term.redirect(mon.p)

    if not term.setGraphicsMode then
        term.restore()
        error("CC:Graphics not detected (term.setGraphicsMode missing).", 0)
    end
    term.setGraphicsMode(2)
    probePixelFormat()

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

local function crashCard(err)
    local mon = findMonitor()
    cleanup(mon)
    term.setTextColor(colors.red)
    print("\n[cinema] crashed: " .. tostring(err))
    pcall(function()
        if not mon then return end
        term.redirect(mon.p)
        term.setBackgroundColour(colors.black)
        term.setTextColour(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        print("CC CINEMA CRASHED\n")
        local msg = tostring(err)
        local w = select(1, term.getSize())
        while #msg > 0 do
            print(msg:sub(1, w))
            msg = msg:sub(w + 1)
        end
    end)
end

local ok, err = pcall(main)
if not ok then
    crashCard(err)
end
