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
	-- PERIPHERAL NAMES (from peripheral.getNames())
	left      = "liquid_vector_thruster_1",
	right     = "liquid_vector_thruster_2",
	altitude  = "altitude_sensor_0",
	imu       = "gimbal_sensor_1",
	nav       = "navigation_table_1",
	velocity  = "velocity_sensor_0",

	-- =================  SIGNS  =================
	-- Each is 1 or -1. If thrusters push the WRONG way, flip the matching
	-- sign below to -1. Use `butter check` to find out which is wrong.
	--   pitchSign: nose UP   when the script says "pitch up"
	--   rollSign : rolls the right way when banking
	--   heightSign: +1 if altitude rising = "going up" (leave -1 if reversed)
	pitchSign  = 1,
	rollSign   = 1,
	dampSign   = 1,

	-- =================  TARGETS  =================
	cruiseAlt   = 60,      -- EDIT: your real cruising altitude (world Y)
	descendTo   = -58,     -- landing altitude
	landGate    = 15,      -- distance to target that starts the descent

	-- =================  CONTROL  =================
	-- Small numbers = gentle. Increase P a little if it flies too sluggishly.
	pGain    = 0.05,   -- pitch per block of altitude error
	dGain    = 0.30,   -- damps vertical speed (kills oscillation)
	deadband = 1.5,    -- ignore altitude errors under this many blocks

	-- =================  LIMITS / PHYSICS  =================
	maxPitch   = 10,   -- hard ceiling: never command more than 10 (redstone power)
	maxBank    = 25,   -- hard ceiling for roll signal
	slewRate   = 2.0,  -- how fast a vector may change per second (0.5=very slow,
	                   --   3=snappy). Raise a LITTLE if too sluggish.
	thrust     = 9,    -- cruise thrust power (the 8-11 range)
	rate       = 10,   -- loop rate Hz
	bearingGain= 1.5,  -- bank demand per radian of heading error
	cruiseSpeed= 32,   -- target cruise speed m/s

	-- Phase thresholds (one task at a time)
	altBand     = 2,   -- blocks of cruise-alt error considered "reached"
	flareHeight = 10,  -- below this on descent, flare the landing
	touchdown   = 0.5, -- below this altitude, consider it landed
}

-- =========================================================
--  peripheral setup
-- =========================================================
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

-- slewed (rate-limited) outputs so nothing ever slams to max
local lY, rYv = 0, 0
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
	return bankOut
end

-- =========================================================
--  check mode: prove every direction before flying
-- =========================================================
if arg and arg[1] == "check" then
	print("CHECK MODE: moving thrusters one at a time.")
	print("When the RIGHT side lifts (right thruster Y positive), signs are right.")
	local function wait() os.sleep(1.5) end
	print("1) PITCH UP both (Y +maxPitch) ..."); L.setVectorY(CFG.maxPitch); R.setVectorY(CFG.maxPitch); wait()
	print("   both nose up? if NOT, flip pitchSign. relaxing."); L.setVectorY(0); R.setVectorY(0); wait()
	print("2) ROLL (differential Y): left up / right down ..."); L.setVectorY(CFG.maxPitch); R.setVectorY(-CFG.maxPitch); wait()
	print("   rolls right? if NOT flip rollSign. relaxing."); L.setVectorY(0); R.setVectorY(0); wait()
	print("3) THRUST ", CFG.thrust); L.setThrust(CFG.thrust); R.setThrust(CFG.thrust); wait()
	L.setThrust(0); R.setThrust(0)
	print("check done. fix the signs in CFG and re-run.")
	return
end

-- =========================================================
--  test mode: show values, move nothing
-- =========================================================
local testMode = (arg and arg[1] == "test")

print("autopilot online. cruiseAlt=" .. CFG.cruiseAlt .. " thrust=" .. CFG.thrust)

local dt = 1 / CFG.rate

-- Phase state machine: one task at a time.
--   "climb"   -> climb to cruise altitude first (on its own)
--   "cruise"  -> hold cruise altitude while flying to the target
--   "descend" -> descend to landing altitude, aligned with target
--   "flare"   -> raise the nose to butter the touchdown
--   "land"    -> touchdown, cut thrust
local phase = "climb"

while true do
	-- read sensors (nil-safe)
	local height  = alt.getHeight() or 0
	local sink    = alt.getVerticalSpeed() or 0
	local bearing = nav.getBearingRad() or 0
	local dist    = nav.getDistanceToTarget() or 100

	updateBank(bearing, dt)

	-- climb straight, then cruise (bank), then descend, then flare, then land
	if phase == "climb" then
		-- TASK 1: get to cruise altitude (straight up, no roll)
		local altErr = CFG.cruiseAlt - height
		local pitch = (altErr * CFG.pGain) - (sink * CFG.dampSign * CFG.dGain)
		local pitchCmd = clamp(pitch, -1, 1) * (CFG.maxPitch * 0.5) * CFG.pitchSign
		lY  = slew(lY,  pitchCmd, dt)
		rYv = slew(rYv, pitchCmd, dt)
		if not testMode then
			parallel.waitForAll(
				function() L.setVectorY(lY)  L.setThrust(CFG.thrust) end,
				function() R.setVectorY(rYv) R.setThrust(CFG.thrust) end
			)
		end
		if math.abs(altErr) <= CFG.altBand then
			phase = "cruise"
			print("phase: cruise  (cruise altitude reached)")
		end

	elseif phase == "cruise" then
		-- TASK 2: hold cruise altitude AND bank toward the target
		local altErr = CFG.cruiseAlt - height
		local pitch = (altErr * CFG.pGain) - (sink * CFG.dampSign * CFG.dGain)
		local pitchCmd = clamp(pitch, -1, 1) * (CFG.maxPitch * 0.5) * CFG.pitchSign
		local rollCmd  = updateBank(bearing, dt) * CFG.rollSign
		local tLy = clamp(pitchCmd + rollCmd, -CFG.maxPitch, CFG.maxPitch)
		local tRy = clamp(pitchCmd - rollCmd, -CFG.maxPitch, CFG.maxPitch)
		lY  = slew(lY,  tLy, dt)
		rYv = slew(rYv, tRy, dt)
		if not testMode then
			parallel.waitForAll(
				function() L.setVectorY(lY)  L.setThrust(CFG.thrust) end,
				function() R.setVectorY(rYv) R.setThrust(CFG.thrust) end
			)
		end
		if dist <= CFG.landGate then
			phase = "descend"
			print("phase: descend  (target reached, descending to land)")
		end

	elseif phase == "descend" then
		-- TASK 3: descend to the landing altitude, staying aligned
		local altErr = CFG.descendTo - height
		local pitch = (altErr * CFG.pGain) - (sink * CFG.dampSign * CFG.dGain)
		local pitchCmd = clamp(pitch, -1, 1) * (CFG.maxPitch * 0.5) * CFG.pitchSign
		local rollCmd  = updateBank(bearing, dt) * CFG.rollSign
		local tLy = clamp(pitchCmd + rollCmd, -CFG.maxPitch, CFG.maxPitch)
		local tRy = clamp(pitchCmd - rollCmd, -CFG.maxPitch, CFG.maxPitch)
		lY  = slew(lY,  tLy, dt)
		rYv = slew(rYv, tRy, dt)
		if not testMode then
			parallel.waitForAll(
				function() L.setVectorY(lY)  L.setThrust(CFG.thrust - 2) end,
				function() R.setVectorY(rYv) R.setThrust(CFG.thrust - 2) end
			)
		end
		if height <= CFG.flareHeight then
			phase = "flare"
			print("phase: flare  (buttering the landing)")
		end

	elseif phase == "flare" then
		-- TASK 4: raise the nose to butter the touchdown
		local fl = clamp((CFG.flareHeight - height) / CFG.flareHeight, 0, 1)
		local base = CFG.dampSign * fl * CFG.maxPitch
		lY  = slew(lY,  base, dt)
		rYv = slew(rYv, base, dt)
		if not testMode then
			parallel.waitForAll(
				function() L.setVectorY(lY)  L.setThrust(CFG.thrust - 3) end,
				function() R.setVectorY(rYv) R.setThrust(CFG.thrust - 3) end
			)
		end
		if height <= CFG.touchdown then
			phase = "land"
			print("phase: land  (touchdown)")
		end

	elseif phase == "land" then
		-- TASK 5 (done): cut thrust, hold level
		lY  = slew(lY,  0, dt)
		rYv = slew(rYv, 0, dt)
		if not testMode then
			parallel.waitForAll(
				function() L.setVectorY(lY)  L.setThrust(0) end,
				function() R.setVectorY(rYv) R.setThrust(0) end
			)
		end
	end
	os.sleep(dt)
end
