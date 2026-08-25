-- ComputerCraft door controller
-- Connects to the python voice server through your cloudflare tunnel.
-- Edit TUNNEL_URL to the https://...xxx.trycloudflare.com URL cloudflared prints.
-- Set PC_NUMBER to this computer's number (1 or 2).

local TUNNEL_URL = "wss://thread-spoke-ratings-phpbb.trycloudflare.com"
local PC_NUMBER = 1           -- THIS IS THE ONLY THING YOU CHANGE
local PULSE_TIME = 2.0

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

print("PC " .. PC_NUMBER .. " starting")

while true do
    local ws = connect()
    print("connected to server")

    -- tell the server which PC we are
    ws.send('{"pc":' .. PC_NUMBER .. '}')

    while true do
        local msg = ws.receive()
        if not msg then break end

        local data = textutils.unserialiseJSON(msg)
        if data and data.action == "pulse" then
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
