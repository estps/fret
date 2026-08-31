--[[
	butter.lua  —  autonomous autopilot for a Create: Aeronautics plane
	============================================================
	How to use:
	  1. Wire EVERY thruster + sensor to the computer (wired modems +
	     networking cable), then RIGHT-CLICK each modem to activate it.
	  2. Run `butter check` FIRST — it moves each thruster so you can
	     confirm every direction and fix the SIGNS below.
	  3. Run `butter test` — prints sensor values, moves nothing.
	  4. Run `butter` — full autopilot.

	Flight is one task at a time:
	    climb  -> reach cruiseAlt (pitch clamped to climbPitch)
	    cruise -> hold cruiseAlt while banking toward the target
	    descend-> descend to landing
	    flare  -> raise the nose to butter the landing
	    land   -> cut thrust, done

	SAFETY: every loop reads the actual gimbal angle. If the nose is
	past maxAttPitch or the wings past maxAttRoll, it drops thrust and
	actively forces the plane back to level (evasive override). It can
	NOT keep pointing once over the limit.
--]]

local CFG = {
	-- PERIPHERAL NAMES (from peripheral.getNames())
	left      = "liquid_vector_thruster_1",
	right     = "liquid_vector_thruster_2",
	altitude  = "altitude_sensor_0",
	imu       = "gimbal_sensor_1",
	nav       = "navigation_table_1",
	velocity  = "velocity_sensor_0",

	-- ============  SIGNS  ============
	-- Turn these to -1 if the matching motion is backwards (use `check`).
	pitchSign = 1,   -- +1: positive setVectorY = nose up
	rollSign  = 1,   -- +1: left-up/right-down banks the right way

	-- ============  TARGETS  ============
	cruiseAlt   = 60,    -- EDIT: your real cruising altitude (world Y)
	descendTo   = -58,   -- landing altitude
	landGate    = 15,    -- distance to target that starts the descent

	-- ============  PITCH PID  ============
	-- pidP corrects altitude error, pidD damps vertical speed (stops
	-- oscillation), pidI removes slow drift.
	pidP = 0.05,
	pidI = 0.001,
	pidD = 0.30,
	pidILimit = 4,       -- cap on the integral term (anti-windup)

	-- pitch command during climb (degrees)
	climbPitch = 12,

	-- ============  LIMITS / PHYSICS  ============
	maxPitch  = 25,      -- HARD command ceiling (redstone power) on pitch
	maxBank   = 25,      -- HARD ceiling for the roll/obank signal
	slewRate  = 2.0,     -- how fast a vector may change per second
	thrust    = 9,       -- cruise thrust power
	rate      = 10,      -- loop rate Hz
	bearingGain = 1.5,   -- bank demand per radian of heading error
	cruiseSpeed = 32,    -- target speed (stored, not yet wired)

	-- ============  PHASES  ============
	altBand     = 2,     -- blocks of cruise-alt error considered "reached"
	flareHeight = 10,    -- below this on descent, flare
	touchdown   = 0.5,   -- below this altitude, considered landed

	-- ============  EVASIVE / SAFETY  ============
	maxAttPitch = 25,    -- if nose exceeds this (deg), force it back to level
	maxAttRoll  = 25,    -- if wings exceed this (deg), force wings level
	recoverGain = 1.0,   -- how hard the recovery pushes
}

-- =========================================================
--  peripheral setup
-- =========================================================
local function find(name)
	return peripheral.wrap(name) or peripheral.find(name)
end
local L, R     = find(CFG.left), find(CFG.right)
local alt, imu = find(CFG.altitude), find(CFG.imu)
local nav, vel = find(CFG.nav), find(CFG.velocity)

if not (L and R and alt and imu and nav and vel) then
	local missing = {}
	if not L then missing[#missing+1] = "left thruster" end
	if not R then missing[#missing+1] = "right thruster" end
	if not alt then missing[#missing+1] = "altitude sensor" end
	if not imu then missing[#missing+1] = "gimbal sensor" end
	if not nav then missing[#missing+1] = "navigation table" end
	if not vel then missing[#missing+1] = "velocity sensor" end
	error("Missing peripherals: " .. table.concat(missing, ", ") ..
		"\nAre they wired to the computer? Right-click the modems?")
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- rate-limited outputs so nothing slams to max
local lY, rYv = 0, 0
local function slew(cur, target, dt)
	local step = CFG.slewRate * dt
	if target > cur then return math.min(target, cur + step) end
	return math.max(target, cur - step)
end

-- PID state for pitch
local pidInt = 0

-- returns pitch command in SIGNAL power (already signed, clamped to +/-maxPitch)
local function pidPitch(targetAlt, height, sink, dt)
	local err = targetAlt - height
	if math.abs(err) <= CFG.altBand then err = 0 end

	local p = err * CFG.pidP

	pidInt = pidInt + err
	pidInt = clamp(pidInt, -CFG.pidILimit, CFG.pidILimit)
	local i = pidInt * CFG.pidI

	local d = -sink * CFG.pidD   -- damp vertical speed (ascent positive)

	local cmd = p + i + d
	cmd = clamp(cmd, -1, 1) * CFG.maxPitch * CFG.pitchSign
	return cmd
end

-- bank controller: returns signed bank signal, clamped to +/-maxBank
local bankOut = 0
local function pidBank(bearingRad, dt)
	local want = clamp(bearingRad * CFG.bearingGain * (180 / math.pi), -CFG.maxBank, CFG.maxBank)
	local step = 20 * dt
	if want > bankOut then bankOut = math.min(want, bankOut + step)
	else bankOut = math.max(want, bankOut - step) end
	return bankOut
end

-- =========================================================
--  check mode
-- =========================================================
if arg and arg[1] == "check" then
	print("CHECK MODE: moving thrusters one at a time.")
	local function wait() os.sleep(1.5) end
	print("1) PITCH UP both (Y +12) ..."); L.setVectorY(12); R.setVectorY(12); wait()
	print("   both nose up? if NOT flip pitchSign. relaxing."); L.setVectorY(0); R.setVectorY(0); wait()
	print("2) ROLL (differential Y): left up / right down ..."); L.setVectorY(12); R.setVectorY(-12); wait()
	print("   rolls right? if NOT flip rollSign. relaxing."); L.setVectorY(0); R.setVectorY(0); wait()
	print("3) THRUST " .. CFG.thrust); L.setThrust(CFG.thrust); R.setThrust(CFG.thrust); wait()
	L.setThrust(0); R.setThrust(0)
	print("check done. fix the signs and re-run.")
	return
end

local testMode = (arg and arg[1] == "test")

-- probe mode: dump the exact shape of every sensor return so we stop guessing
if arg and arg[1] == "probe" then
	local function dump(name, v)
		io.write(name .. " = ")
		if type(v) == "table" then
			write("{ ")
			for k, val in pairs(v) do write(tostring(k) .. "=" .. tostring(val) .. " ") end
			write("}\n")
		else
			print(tostring(v))
		end
	end
	dump("height", alt.getHeight())
	dump("vertSpeed", alt.getVerticalSpeed())
	dump("bearingRad", nav.getBearingRad())
	dump("dist", nav.getDistanceToTarget())
	local a = { imu.getAngles() }
	dump("angles[1]", a[1])
	dump("angles[2]", a[2])
	if type(a[1]) == "table" then
		dump("angles[1].pitch", a[1].pitch)
		dump("angles[1].roll", a[1].roll)
	end
	dump("vel", vel and vel.getVelocity and vel.getVelocity())
	return
end

print("autopilot online. cruiseAlt=" .. CFG.cruiseAlt .. " climbPitch=" .. CFG.climbPitch .. " maxPitch=" .. CFG.maxPitch)

local dt = 1 / CFG.rate
local phase = "climb"

while true do
	local height  = alt.getHeight() or 0
	local sink    = alt.getVerticalSpeed() or 0
	local bearing = nav.getBearingRad() or 0
	local dist    = nav.getDistanceToTarget() or 100
	local a = { imu.getAngles() }
	local pDeg = a[1] or a.pitch or a.x or 0
	local rDeg = a[2] or a.roll or a.z or 0
	if type(pDeg) == "table" then pDeg = pDeg.pitch or pDeg.x or pDeg[1] or 0 end
	if type(rDeg) == "table" then rDeg = rDeg.roll or rDeg.z or rDeg[1] or 0 end
	pDeg = tonumber(pDeg) or 0
	rDeg = tonumber(rDeg) or 0

	local thrust = CFG.thrust

	-- ============ EVASIVE / SAFETY OVERRIDE ============
	local evading = false
	if pDeg > CFG.maxAttPitch or pDeg < -CFG.maxAttPitch
	   or math.abs(rDeg) > CFG.maxAttRoll then
		evading = true
	end

	if evading then
		-- Actively force pitch and roll back to level, drop thrust.
		local pitchBack = -pDeg / CFG.maxAttPitch * CFG.maxPitch * CFG.recoverGain
		local rollBack  = -rDeg / CFG.maxAttRoll  * CFG.maxBank  * CFG.recoverGain
		local tLy = clamp(pitchBack + rollBack, -CFG.maxPitch, CFG.maxPitch)
		local tRy = clamp(pitchBack - rollBack, -CFG.maxPitch, CFG.maxPitch)
		lY  = slew(lY,  tLy, dt)
		rYv = slew(rYv, tRy, dt)
		if not testMode then
			parallel.waitForAll(
				function() L.setVectorY(lY)  L.setThrust(2) end,
				function() R.setVectorY(rYv) R.setThrust(2) end
			)
		end
		print(string.format("EVASIVE p:%+.1f r:%+.1f -> lY:%+.1f rY:%+.1f", pDeg, rDeg, lY, rYv))
		os.sleep(dt)

	else
		-- ============ NORMAL PHASE CONTROL ============
		pidBank(bearing, dt)

		if phase == "climb" then
			-- TASK 1: climb at climbPitch degrees until cruiseAlt reached
			local pitchCmd = CFG.climbPitch * CFG.pitchSign          -- fixed climb angle
			local rollCmd  = 0
			local tLy = clamp(pitchCmd + rollCmd, -CFG.maxPitch, CFG.maxPitch)
			local tRy = clamp(pitchCmd - rollCmd, -CFG.maxPitch, CFG.maxPitch)
			lY  = slew(lY,  tLy, dt)
			rYv = slew(rYv, tRy, dt)
			if not testMode then
				parallel.waitForAll(
					function() L.setVectorY(lY)  L.setThrust(thrust) end,
					function() R.setVectorY(rYv) R.setThrust(thrust) end
				)
			end
			if height >= CFG.cruiseAlt - CFG.altBand then
				phase = "cruise"
				print("phase: cruise")
			end

		elseif phase == "cruise" then
			-- TASK 2: hold cruise altitude (PID) + bank toward target
			local pitchCmd = pidPitch(CFG.cruiseAlt, height, sink, dt)
			local rollCmd  = pidBank(bearing, dt) * CFG.rollSign
			local tLy = clamp(pitchCmd + rollCmd, -CFG.maxPitch, CFG.maxPitch)
			local tRy = clamp(pitchCmd - rollCmd, -CFG.maxPitch, CFG.maxPitch)
			lY  = slew(lY,  tLy, dt)
			rYv = slew(rYv, tRy, dt)
			if not testMode then
				parallel.waitForAll(
					function() L.setVectorY(lY)  L.setThrust(thrust) end,
					function() R.setVectorY(rYv) R.setThrust(thrust) end
				)
			end
			if dist <= CFG.landGate then
				phase = "descend"
				print("phase: descend")
			end

		elseif phase == "descend" then
			-- TASK 3: descend to landing altitude (PID) + bank
			local pitchCmd = pidPitch(CFG.descendTo, height, sink, dt)
			local rollCmd  = pidBank(bearing, dt) * CFG.rollSign
			local tLy = clamp(pitchCmd + rollCmd, -CFG.maxPitch, CFG.maxPitch)
			local tRy = clamp(pitchCmd - rollCmd, -CFG.maxPitch, CFG.maxPitch)
			lY  = slew(lY,  tLy, dt)
			rYv = slew(rYv, tRy, dt)
			if not testMode then
				parallel.waitForAll(
					function() L.setVectorY(lY)  L.setThrust(thrust - 2) end,
					function() R.setVectorY(rYv) R.setThrust(thrust - 2) end
				)
			end
			if height <= CFG.flareHeight then
				phase = "flare"
				print("phase: flare")
			end

		elseif phase == "flare" then
			-- TASK 4: raise nose to butter the touchdown
			local fl = clamp((CFG.flareHeight - height) / CFG.flareHeight, 0, 1)
			local base = fl * CFG.climbPitch * CFG.pitchSign
			lY  = slew(lY,  base, dt)
			rYv = slew(rYv, base, dt)
			if not testMode then
				parallel.waitForAll(
					function() L.setVectorY(lY)  L.setThrust(thrust - 3) end,
					function() R.setVectorY(rYv) R.setThrust(thrust - 3) end
				)
			end
			if height <= CFG.touchdown then
				phase = "land"
				print("phase: land")
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
end
