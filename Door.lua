-- ComputerCraft door controller
-- Connects to the python voice server through your cloudflare tunnel.
-- Edit TUNNEL_URL to the https://...xxx.trycloudflare.com URL cloudflared prints.

local TUNNEL_URL = "wss://thread-spoke-ratings-phpbb.trycloudflare.com"
local SIDE = "back"      -- redstone output side (top/bottom/left/right/front/back)
local PULSE_TIME = 2.0   -- seconds door stays open

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

print("door controller starting")

while true do
    local ws = connect()
    print("connected to server")

    -- tell the server who we are
    ws.send('{"hello":"door-computer"}')

    while true do
        local msg = ws.receive()  -- blocks until a message arrives
        if not msg then break end -- connection dropped

        local data = textutils.unserialiseJSON(msg)
        if data and data.action == "pulse" then
            print("opening door!")
            redstone.setOutput(SIDE, true)
            sleep(data.duration or PULSE_TIME)
            redstone.setOutput(SIDE, false)
            ws.send('{"status":"done"}')
        end
    end

    ws.close()
    print("lost connection, reconnecting...")
end
