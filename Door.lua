-- ComputerCraft door controller
-- Connects to the python voice server through your cloudflare tunnel.
-- Edit TUNNEL_URL to the https://...xxx.trycloudflare.com URL cloudflared prints.
-- Set SIDES to the sides THIS computer controls (comma-separated).
--
-- Computer 1: SIDES = "back,top,left,right"
-- Computer 2: SIDES = "bottom"

local TUNNEL_URL = "wss://thread-spoke-ratings-phpbb.trycloudflare.com"
local SIDES = "bottom"         -- comma-separated sides this computer controls
local PULSE_TIME = 2.0

local function parse_sides(s)
    local t = {}
    for side in s:gmatch("[^,]+") do
        t[side:match("^%s*(.-)%s*$")] = true
    end
    return t
end

local my_sides = parse_sides(SIDES)

local function connect()
    while true do
        local ok, ws = pcall(http.websocket, TUNNEL_URL)
        if ok and ws then
            return ws
        end
        print("connect failed, retrying in 5s...")
        sleep(5)
    end
end

print("door controller starting (sides: " .. SIDES .. ")")

while true do
    local ws = connect()
    print("connected to server")

    ws.send('{"hello":"' .. SIDES .. '"}')

    while true do
        local msg = ws.receive()
        if not msg then break end

        local data = textutils.unserialiseJSON(msg)
        if data and data.action == "pulse" and my_sides[data.side] then
            print("pulsing " .. data.side .. "!")
            redstone.setOutput(data.side, true)
            sleep(data.duration or PULSE_TIME)
            redstone.setOutput(data.side, false)
            ws.send('{"status":"done","side":"' .. data.side .. '"}')
        end
    end

    ws.close()
    print("lost connection, reconnecting...")
end
