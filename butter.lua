--[[
	butter.lua  —  clean, minimal autopilot for a Create: Aeronautics plane
	============================================================
	How to use:
	  1. Connect EVERY thruster + sensor to the computer through
	     WIRED modems + networking cable, and RIGHT-CLICK each modem.
	  2. Run `butter check` FIRST  -> it moves each thruster one at a
	     time so you can confirm every direction is correct.
	  3. Run `butter test`          -> prints values, moves nothing.
	  4. Run `butter`               -> full autopilot.
--]]

local CFG = {
	left      = "liquid_vector_thruster_1",
	right     = "liquid_vector_thruster_2",
	altitude  = "altitude_sensor_0",
	imu       = "gimbal_sensor_1",
	nav       = "navigation_table_1",
	velocity  = "velocity_sensor_0",

	pitchSign  = 1,
	rollSign   = 1,
	dampSign   = 1,

	cruiseAlt   = 60,      -- EDIT: your real cruising altitude (world Y)
	descendTo   = -58,     -- landing altitude
	landGate    = 15,      -- distance to target that starts the descent

	pGain    = 0.05,   -- pitch per block of altitude error
	dGain    = 0.30,   -- damps vertical speed (kills oscillation)
	deadband = 1.5,    -- ignore altitude errors under this many blocks

	maxPitch   = 10,   -- hard ceiling: never command more than 10
	maxBank    = 25,   -- hard ceiling for roll signal
	slewRate   = 2.0,  -- how fast a vector may change per second
	thrust     = 9,    -- cruise thrust power (the 8-11 range)
	rate       = 10,   -- loop rate Hz
	bearingGain= 1.5,  -- bank demand per radian of heading error
	speedTarget= 12,   -- cruise speed m/s
}

local function find(name)
	return peripheral.wrap(name) or peripheral.find(name)
end
local L   = find(CFG.left)
local R   = find(CFG.right)
local alt = find(CFG.altitude)
local imu = find(CFG.imu)
local nav = find(CFG.nav)
local vel = find(CFG.velocity)

if not (L and R and alt and imu and nav and vel) then
	local missing = {}
	if not L then missing[#missing+1]="left thruster" end
	if not R then missing[#missing+1]="right thruster" end
	if not alt then missing[#missing+1]="altitude sensor" end
	if not imu then missing[#missing+1]="gimbal sensor" end
	if not nav then missing[#missing+1]="navigation table" end
	if not vel then missing[#missing+1]="velocity sensor" end
	error("Missing peripherals: " .. table.concat(missing, ", ") ..
		"\nAre the thrusters/sensors wired to the computer? Did you right-click the modems?")
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local lX, lY, rX, rYv = 0, 0, 0, 0
local function slew(cur, target, dt)
	local step = CFG.slewRate * dt
	if target > cur then return math.min(target, cur + step) end
	return math.max(target, cur - step)
end

local bankOut = 0
local function updateBank(headingRad, dt)
	local want = clamp(headingRad * CFG.bearingGain * (180 / math.pi), -CFG.maxBank, CFG.maxBank)
	local step = 20 * dt
	if want > bankOut then bankOut = math.min(want, bankOut + step)
	else bankOut = math.max(want, bankOut - step) end
end

if arg and arg[1] == "check" then
	print("CHECK MODE: moving thrusters one at a time.")
	print("When the RIGHT side lifts (right thruster Y positive), signs are right.")
	local function wait() os.sleep(1.5) end
	print("1) PITCH UP both (Y +maxPitch) ..."); L.setVectorY(CFG.maxPitch); R.setVectorY(CFG.maxPitch); wait()
	print("   both nose up? if NOT, flip pitchSign. relaxing."); L.setVectorY(0); R.setVectorY(0); wait()
	print("2) ROLL: left-down/right-up ..."); L.setVectorX(-CFG.maxBank); R.setVectorX(CFG.maxBank); wait()
	print("   rolls right? if NOT flip rollSign. relaxing."); L.setVectorX(0); R.setVectorX(0); wait()
	print("3) THRUST ", CFG.thrust); L.setThrust(CFG.thrust); R.setThrust(CFG.thrust); wait()
	L.setThrust(0); R.setThrust(0)
	print("check done. fix the signs in CFG and re-run.")
	return
end

local testMode = (arg and arg[1] == "test")

print("autopilot online. cruiseAlt=" .. CFG.cruiseAlt .. " thrust=" .. CFG.thrust)

local dt = 1 / CFG.rate
while true do
	local height  = alt.getHeight() or 0
	local sink    = alt.getVerticalSpeed() or 0
	local bearing = nav.getBearingRad() or 0
	local dist    = nav.getDistanceToTarget() or 100
	local _, roll = imu.getAngles()
	roll  = roll or 0
	local spd = vel.getVelocity() or 0

	local cruising = dist > CFG.landGate

	updateBank(bearing, dt)

	local targetAlt = cruising and CFG.cruiseAlt or CFG.descendTo
	local altErr = targetAlt - height
	if math.abs(altErr) <= CFG.deadband then altErr = 0 end

	local pitch = (altErr * CFG.pGain) - (sink * CFG.dampSign * CFG.dGain)

	if not cruising and height <= 10 and height > 0 then
		local flare = clamp((10 - height) / 10, 0, 1)
		pitch = (pitch * (1 - flare)) + (CFG.dampSign * flare * 0.6)
	end

	local pitchCmd = clamp(pitch, -1, 1) * CFG.maxPitch * CFG.pitchSign
	local bankCmd  = updateBank(bearing, dt) * CFG.rollSign

	local tLx, tLy, tRx, tRy = -bankCmd, pitchCmd, bankCmd, pitchCmd

	lX  = slew(lX,  tLx, dt)
	lY  = slew(lY,  tLy, dt)
	rX  = slew(rX,  tRx, dt)
	rYv = slew(rYv, tRy, dt)

	local thrust = cruising and CFG.thrust or (CFG.thrust - 2)

	if testMode then
		print(string.format("H:%5.1f S:%+5.1f D:%5.1f Bnk:%+4.1f pitchCmd:%+4.1f lY:%+4.1f rY:%+4.1f",
			height, sink, dist, bankOut, pitchCmd, lY, rYv))
	else
		parallel.waitForAll(
			function() L.setVectorX(lX) L.setVectorY(lY)  L.setThrust(thrust) end,
			function() R.setVectorX(rX) R.setVectorY(rYv) R.setThrust(thrust) end
		)
	end
	os.sleep(dt)
end
