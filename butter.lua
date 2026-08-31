
--[[ 
	butter.lua  —  Autonomous "butter the landing" navigator
	=========================================================
	Target:  Create: Aeronautics plane, driven from a CC:Tweaked computer
	NOTE: Make sure you've connected the thrusters/sensors with WIRED modems
	      and right-clicked each modem to activate them first.
--]]

local CONFIG = {
	-- PERIPHERAL NAMES
	left     = "liquid_vector_thruster_1",
	right    = "liquid_vector_thruster_2",
	altitude  = "altitude_sensor_0",
	imu       = "gimbal_sensor_1",
	nav       = "navigation_table_1",
	velocity  = "velocity_sensor_0",

	-- Navigation -------------------------------------------------------
	cruiseAlt   = 60,     -- blocks of cruising altitude (world Y) -- EDIT: match your real cruise height
	descendTo   = -58,    -- target floor altitude
	landGate    = 15,     -- distance (blocks) to target that starts descent

	-- Pitch Control (PID) --------------------------------------------------
	pitchP = 0.06,     -- proportional gain (per block of error)
	pitchI = 0.002,    -- integral gain (slow drift removal)
	pitchD = 0.25,     -- derivative gain (damps oscillation - raise if still wobbles)
	altBand = 1.5,     -- deadband: ignore altitude error (blocks) below this
	integralLimit = 2.0,   -- max accumulated integral (avoid windup)

	-- Pitch & Roll Limits ------------------------------------------------
	maxPitchDeg  = 10,     -- HARD PITCH LIMIT (+/-10 degrees, no more loops)
	maxBankDeg   = 30,     -- MAX ROLL: prevents rolling over
	maxVecSignal = 10,     -- HARD CAP: thruster vector X/Y never sends more than +/-10 redstone power
	turnGain     = 1.8,    -- how aggressively to bank toward the target
	bankRate     = 60,     -- max bank change speed (degrees/sec)

	-- Speed Control ------------------------------------------------------
	targetSpeed = 12,     -- Target cruise speed in m/s
	speedGain   = 0.1,     -- thrust adjustment aggression
	thrustMin   = 8,       -- lowest cruise thrust (power)
	thrustMax   = 11,      -- highest cruise thrust (power)  -- keeps it in the 8-11 range you asked for

	-- Landing Flare ---------------------------------------------------------
	flareHeight = 8,       -- blocks AGL where the auto-flare starts
	flareMax    = 6,       -- max nose-up pitch (signal points)
	onRails     = 3.5,     -- descent rate (m/s) that triggers stronger flare

	rate = 10,             -- loop rate in Hz
	neutral = 7,           -- analog signal for nozzle straight (0..15)
	deflect = 7,           -- max signal deflection from neutral
}

local function findOne(match)
	if not match then return nil end
	return peripheral.wrap(match) or peripheral.find(match)
end

local leftAct  = findOne(CONFIG.left)
local rightAct = findOne(CONFIG.right)
local alt      = findOne(CONFIG.altitude)
local imu      = findOne(CONFIG.imu)
local nav      = findOne(CONFIG.nav)
local vel      = findOne(CONFIG.velocity)

if not (leftAct and rightAct and alt and imu and nav and vel) then
	error("Missing peripheral! Check names.\n" ..
		"L: " .. tostring(leftAct) .. " | R: " .. tostring(rightAct) .. "\n" ..
		"Alt: " .. tostring(alt) .. " | IMU: " .. tostring(imu) .. "\n" ..
		"Nav: " .. tostring(nav) .. " | Vel: " .. tostring(vel))
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local currentBank = 0.0
local currentThrust = 0.0

-- PID state for altitude hold
local altIntegral = 0.0

local function updateBank(bearingRad)
	local target = clamp(bearingRad * CONFIG.turnGain * (180 / math.pi), -CONFIG.maxBankDeg, CONFIG.maxBankDeg)
	local step = CONFIG.bankRate / CONFIG.rate
	if target > currentBank then currentBank = math.min(target, currentBank + step)
	else                     currentBank = math.max(target, currentBank - step) end
	return clamp(currentBank, -CONFIG.maxBankDeg, CONFIG.maxBankDeg)
end

local testMode = (arg and arg[1] == "test")
if testMode then print("TEST MODE: No drive.") end

while true do
	local bearingRad = nav.getBearingRad() or 0
	local dist       = nav.getDistanceToTarget() or 100
	local height    = alt.getHeight() or 0
	local sink      = alt.getVerticalSpeed() or 0
	local p_raw, r_raw = imu.getAngles()
	local rollDeg = r_raw or 0
	local currentVel = vel.getVelocity() or 0

	local cruising = dist > CONFIG.landGate
	local activeBank = cruising and updateBank(bearingRad) or updateBank(0)

	if math.abs(rollDeg) > CONFIG.maxBankDeg then
		currentBank = currentBank * 0.5
		activeBank = currentBank
	end

	-- SPEED CONTROL (cruise power 8-11)
	local speedErr = CONFIG.targetSpeed - currentVel
	currentThrust = currentThrust + (speedErr * CONFIG.speedGain)
	currentThrust = clamp(currentThrust, CONFIG.thrustMin, CONFIG.thrustMax)

	-- PITCH / FLARE  (uses a real PID for stable altitude hold)
	local flare = 0
	local pitchCmd = 0

	if cruising then
		-- PITCH ALTITUDE HOLD (PID)
		local altErr = CONFIG.cruiseAlt - height
		if math.abs(altErr) <= CONFIG.altBand then
			altErr = 0
		end

		local p = altErr * CONFIG.pitchP

		altIntegral = altIntegral + altErr
		altIntegral = clamp(altIntegral, -CONFIG.integralLimit, CONFIG.integralLimit)
		local i = altIntegral * CONFIG.pitchI

		local d = -sink * CONFIG.pitchD

		pitchCmd = p + i + d
	else
		local altErr = CONFIG.descendTo - height
		altIntegral = 0
		pitchCmd = (altErr * CONFIG.pitchP) - (sink * CONFIG.pitchD)

		if height <= CONFIG.flareHeight then
			local hf = 1 - clamp(height / CONFIG.flareHeight, 0, 1)
			local sf = clamp(-sink / CONFIG.onRails, 0, 1)
			flare = clamp(hf * 0.6 + sf * 0.4, 0, 1)
			pitchCmd = pitchCmd * (1 - flare) + flare * 0.5
		end
	end
	pitchCmd = clamp(pitchCmd, -1, 1)

	-- PITCH LIMITER (Hard Clamp to CONFIG.maxPitchDeg)
	local finalPitchDeg = pitchCmd * CONFIG.maxPitchDeg
	finalPitchDeg = clamp(finalPitchDeg, -CONFIG.maxPitchDeg, CONFIG.maxPitchDeg)
	local normalizedPitch = finalPitchDeg / CONFIG.maxPitchDeg

	-- MIX SIGNALS
	local bankSig = (activeBank / CONFIG.maxBankDeg) * CONFIG.deflect
	local pitchSig = normalizedPitch * CONFIG.deflect

	local lX, lY = -bankSig, pitchSig
	local rX, rY = bankSig, pitchSig

	-- HARD CAP: every vector signal to +/- maxVecSignal (10 redstone power)
	local vmax = CONFIG.maxVecSignal
	lX = clamp(lX, -vmax, vmax)
	lY = clamp(lY, -vmax, vmax)
	rX = clamp(rX, -vmax, vmax)
	rY = clamp(rY, -vmax, vmax)

	local finalThrust = cruising and currentThrust or (currentThrust * (1 - flare))

	if testMode then
		print(string.format("V:%.1f B:%.2f D:%.1f H:%.1f Bnk:%.1f Fl:%.2f L:%d R:%d", currentVel, bearingRad, dist, height, activeBank, flare, math.floor(lY), math.floor(rY)))
	else
		parallel.waitForAll(
			function()
				leftAct.setVectorX(lX)
				leftAct.setVectorY(lY)
				leftAct.setThrust(finalThrust)
			end,
			function()
				rightAct.setVectorX(rX)
				rightAct.setVectorY(rY)
				rightAct.setThrust(finalThrust)
			end
		)
		sleep(1 / CONFIG.rate)
	end
