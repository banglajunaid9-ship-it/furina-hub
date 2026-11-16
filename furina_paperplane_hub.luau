--[[
	Furina Hub | Paper To Plane (placeId 132583639194663, universe 10771096080)
	UI: FurinaUI (furina_ui.luau in this repo); falls back to Luna Interface Suite if it cannot load

	Run with loadstring, or through live-reload (STATE). Running it again replaces the old copy.

	Game notes (found by reading the game's own scripts and testing in game)
	- Loop: train Power on a TrainingGrounds pad -> throw the plane from the launch zone -> coins when it lands ->
	  Level comes from Power -> Rebirth at max level (multiplier, unlocks better training zones) -> worlds 1-5.
	- Remotes live in ReplicatedStorage.PaperPlaneRemotes. Most RemoteFunctions go through
	  require(ReplicatedStorage.PaperUI.BackendClient).CallOnce(name, ...), which returns { ok, msg, data, busy }.
	- Throw: the hub calls the game's own input handlers (onInputBegan / onInputEnded in PlaneClientController,
	  found with filtergc) with a fake MouseButton1 input, holding for the centre of the PERFECT window
	  (FlightConfig.PowerAt(t) >= 1, ~0.748 s). The game then fires PlaneFlight "ChargeBegin" / "ChargeRelease"
	  itself, so the server sees a normal perfect throw. Needs: not training, plane tool equipped, inside LaunchRegion.
	- Flight events arrive on PlaneFlight.OnClientEvent: Thrown, Launched {UserId, FlightId}, Landed, Reward,
	  Returning, Returned {FlightId}, Cancelled, Rejected.
	- Training: standing on a zone of World N.Gameplay.TrainingGrounds makes the game's TrainingClient start
	  training by itself. TrainingConfig.CanEnter(id, rebirths, hasPass, unlockedWorld) says which zones are open.
	  TrainingClient's local exitTraining() stops it cleanly.
	- The built-in Auto Throw needs the Auto Throw game pass (server-checked), so the hub never uses it.
	- Anti-cheat: none on the client (no Kick, no metatable hooks, 371 scripts). The server checks training zone
	  access, the 20 stud egg hatch range, charge timing, prices.
	- Never walk workspace:GetDescendants() here: the map is huge and it freezes the client.

	Layout
	 1. Bootstrap     5. Game access          9. Player, world, misc
	 2. Services      6. Throw / train       10. UI
	 3. Settings      7. Rewards / pets / planes / smart flight
	 4. Config files  8. Farm worker
]]

------------------------------------------------------------------------------------------------------
-- 1. Bootstrap: one copy at a time (a BindableEvent lock: a new copy fires the old one, which unloads itself)
------------------------------------------------------------------------------------------------------
local STATE = STATE -- set by live-reload; nil when run with loadstring
if type(STATE) ~= "table" or type(STATE.alive) ~= "function" then STATE = nil end
local cleanups, conns = {}, {}
local unloaded = false
local function alive() return not unloaded and (not STATE or STATE.alive()) end
local function cleanup(fn)
	if unloaded then
		pcall(fn)
		return
	end
	cleanups[#cleanups + 1] = fn
end
local function connect(sig, fn)
	local c = sig:Connect(fn)
	if unloaded then
		c:Disconnect()
		return c
	end
	conns[#conns + 1] = c
	return c
end
local function unloadHub()
	if unloaded then return end
	unloaded = true
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
end
if STATE then STATE.onCleanup(unloadHub) end

do
	local LOCK = "FurinaPaperPlaneHubLock"
	local holder = game:GetService("CoreGui")
	local okH = pcall(function() return holder.Name end)
	if not okH then holder = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end
	local old = holder:FindFirstChild(LOCK)
	if old then
		pcall(function() old:Fire() end)
		task.wait(0.5)
		pcall(function() old:Destroy() end)
	end
	local lock = Instance.new("BindableEvent")
	lock.Name = LOCK
	lock.Parent = holder
	connect(lock.Event, unloadHub)
	cleanup(function() pcall(function() lock:Destroy() end) end)
end
getgenv().FurinaPaperPlaneUnload = unloadHub

------------------------------------------------------------------------------------------------------
-- 2. Services
------------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer

local FURINA_UI_URL = "https://raw.githubusercontent.com/banglajunaid9-ship-it/furina-hub/main/furina_ui.luau"
local UI = (function()
	local src
	pcall(function()
		if isfile and readfile and isfile("FurinaHub/furina_ui.luau") then src = readfile("FurinaHub/furina_ui.luau") end
	end)
	if not src then pcall(function() src = game:HttpGet(FURINA_UI_URL) end) end
	if src then
		local ok, lib = pcall(function() return loadstring(src)() end)
		if ok and type(lib) == "table" and lib.CreateWindow then return lib end
		warn("[Furina Plane] FurinaUI failed to load, using Luna instead: " .. tostring(lib))
	end
	getgenv().ConfirmLuna = true
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/master/source.lua"))()
end)()
local FURINA = UI.IsFurinaUI == true
local noteLog = {}
local function notify(title, text, icon)
	table.insert(noteLog, 1, string.format("%.0f %s: %s", os.clock(), tostring(title), tostring(text)))
	if #noteLog > 20 then table.remove(noteLog) end
	pcall(function() UI:Notification({ Title = title, Content = text, Icon = icon or "info", ImageSource = "Material" }) end)
end

------------------------------------------------------------------------------------------------------
-- 3. Settings
------------------------------------------------------------------------------------------------------
local Cfg = {
	-- farm
	AutoThrow = false, AutoTrain = false, TrainSecs = 45, ResumeFarm = false,
	HumanRelease = true, Movement = "Teleport",
	AutoRebirth = false,
	-- rewards
	AutoPlaytime = true, AutoDaily = true, AutoCommunity = false,
	-- pets / planes
	AutoHatch = false, HatchEgg = "W1Uncommon", HatchKeepCoins = 0, AutoEquipPets = true,
	AutoFold = false, AutoBuyPaper = true, PaperChoice = "Best affordable", PaperKeepCoins = 0,
	AutoEquipPlane = true, EquipBy = "Training",
	-- events
	SmartFlight = false,
	-- player
	SpeedOn = false, Speed = 50, JumpOn = false, Jump = 80, InfJump = false, Noclip = false,
	-- misc
	AntiAFK = true, FPSBoost = false, AutoSave = true, ActivityNotify = true,
	StaffDetect = true, StaffAction = "Pause farming",
	PanicKey = Enum.KeyCode.Delete,
}
local MOVEMENTS = { "Teleport", "Walk" }
local EQUIP_BY = { "Training", "Coins" }
local STAFF_ACTIONS = { "Pause farming", "Server hop", "Notify only" }

local lastNoteAt, lastNoteKind = 0, {}
local function notifyAct(kind, cooldown, title, text, icon)
	if not Cfg.ActivityNotify then return end
	local now = os.clock()
	if lastNoteKind[kind] and now - lastNoteKind[kind] < (cooldown or 30) then return end
	if now - lastNoteAt < 4 then return end
	lastNoteKind[kind], lastNoteAt = now, now
	notify(title, text, icon)
	return true
end

------------------------------------------------------------------------------------------------------
-- 4. Config files: <workspace>/FurinaHub/<profile>.json, active profile in FurinaHub/_profile_plane.txt
------------------------------------------------------------------------------------------------------
local CFG_DIR = "FurinaHub"
local PROFILE_FILE = CFG_DIR .. "/_profile_plane.txt"
local cfgProfile = "paperplane"
local NOSAVE = { FPSBoost = true }

local fsOK = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local function cfgPath(name) return CFG_DIR .. "/" .. name .. ".json" end
local function cleanName(s)
	s = tostring(s or ""):gsub("[^%w_%-]", "")
	if s == "" then return nil end
	return s:sub(1, 32)
end
local function ensureDir()
	if makefolder and not (isfolder and isfolder(CFG_DIR)) then pcall(makefolder, CFG_DIR) end
end
local function encodeCfg()
	local t = {}
	for k, v in pairs(Cfg) do
		if not NOSAVE[k] then
			local ty = typeof(v)
			if ty == "EnumItem" then
				t[k] = { __k = v.Name }
			elseif ty == "number" then
				if v == v and v ~= math.huge and v ~= -math.huge then t[k] = v end
			elseif ty == "boolean" or ty == "string" then
				t[k] = v
			end
		end
	end
	return HttpService:JSONEncode(t)
end
local function signature()
	local parts = {}
	for k, v in pairs(Cfg) do
		if not NOSAVE[k] then parts[#parts + 1] = k .. "=" .. tostring(v) end
	end
	table.sort(parts)
	return table.concat(parts, ";")
end
local function saveCfg(name)
	if not fsOK then return false, "this executor has no file functions" end
	name = name or cfgProfile
	ensureDir()
	local ok, json = pcall(encodeCfg)
	if not ok then return false, "encode failed: " .. tostring(json) end
	local ok2, err = pcall(writefile, cfgPath(name), json)
	if not ok2 then return false, tostring(err) end
	return true
end
local function loadCfg(name)
	if not fsOK then return false end
	name = name or cfgProfile
	local okf, exists = pcall(isfile, cfgPath(name))
	if not okf or not exists then return false end
	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(cfgPath(name))) end)
	if not ok or type(data) ~= "table" then return false end
	for k, v in pairs(data) do
		local cur = Cfg[k]
		if cur ~= nil and not NOSAVE[k] then
			if type(v) == "table" and v.__k and typeof(cur) == "EnumItem" then
				local okk, en = pcall(function() return Enum.KeyCode[v.__k] end)
				if okk and en then Cfg[k] = en end
			elseif type(v) == type(cur) then
				Cfg[k] = v
			end
		end
	end
	if not table.find(MOVEMENTS, Cfg.Movement) then Cfg.Movement = MOVEMENTS[1] end
	if not table.find(STAFF_ACTIONS, Cfg.StaffAction) then Cfg.StaffAction = STAFF_ACTIONS[1] end
	if not table.find(EQUIP_BY, Cfg.EquipBy) then Cfg.EquipBy = EQUIP_BY[1] end
	if not table.find({ "Best affordable", "Uncommon", "Rare", "Epic", "Legendary", "Mythical" }, Cfg.PaperChoice) then
		Cfg.PaperChoice = "Best affordable"
	end
	Cfg.TrainSecs = math.clamp(tonumber(Cfg.TrainSecs) or 45, 0, 600)
	return true
end
local function setProfile(name)
	cfgProfile = name
	if fsOK then
		ensureDir()
		pcall(writefile, PROFILE_FILE, name)
	end
end
if fsOK then
	pcall(function()
		if isfile(PROFILE_FILE) then cfgProfile = cleanName(readfile(PROFILE_FILE)) or cfgProfile end
	end)
end
loadCfg()
-- farming never starts by itself on load unless the user asked for that
if not Cfg.ResumeFarm then
	Cfg.AutoThrow, Cfg.AutoTrain, Cfg.AutoHatch, Cfg.AutoFold = false, false, false, false
end

------------------------------------------------------------------------------------------------------
-- 5. Game access
------------------------------------------------------------------------------------------------------
local Remotes = RS:WaitForChild("PaperPlaneRemotes", 20)
assert(Remotes, "[Furina Plane] ReplicatedStorage.PaperPlaneRemotes not found - is this Paper To Plane?")
local Shared = RS:WaitForChild("PaperPlaneShared", 20)

local function safeRequire(inst)
	if not inst then return nil end
	local ok, mod = pcall(require, inst)
	return ok and mod or nil
end
local PaperUI = RS:FindFirstChild("PaperUI")
local BC = safeRequire(PaperUI and PaperUI:FindFirstChild("BackendClient"))
local FlightConfig = safeRequire(Shared and Shared:FindFirstChild("FlightConfig"))
local TrainingConfig = safeRequire(Shared and Shared:FindFirstChild("TrainingConfig"))
local WorldConfig = safeRequire(Shared and Shared:FindFirstChild("WorldConfig"))
local PetEggConfig = safeRequire(Shared and Shared:FindFirstChild("PetEggConfig"))
local PlaneConfig = safeRequire(Shared and Shared:FindFirstChild("PlaneConfig"))

local PlaneFlight = Remotes:WaitForChild("PlaneFlight", 10)

local function attr(name) return LP:GetAttribute(name) end
local function stat(name)
	local ls = LP:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return v and tonumber(v.Value) or 0
end
local function coins() return stat("Coins") end
local function rebirths() return stat("Rebirths") end
local function currentWorld() return tonumber(attr("CurrentWorld")) or tonumber(attr("WorldId")) or 1 end

-- every BackendClient call returns a table; a raw RemoteFunction is used when BackendClient is missing
local function call(name, ...)
	if BC and type(BC.CallOnce) == "function" then
		local ok, res = pcall(BC.CallOnce, name, ...)
		if ok and type(res) == "table" then return res end
		if not ok then return { ok = false, msg = tostring(res) } end
	end
	local r = Remotes:FindFirstChild(name)
	if not r or not r:IsA("RemoteFunction") then return { ok = false, msg = "no remote " .. name } end
	local ok, res = pcall(r.InvokeServer, r, ...)
	if not ok then return { ok = false, msg = tostring(res) } end
	if type(res) ~= "table" then return { ok = res ~= nil and res ~= false, data = res } end
	return res
end
local function invoke(name, ...)
	local r = Remotes:FindFirstChild(name)
	if not r or not r:IsA("RemoteFunction") then return { ok = false, msg = "no remote " .. name } end
	local ok, res = pcall(r.InvokeServer, r, ...)
	if not ok then return { ok = false, msg = tostring(res) } end
	if type(res) ~= "table" then return { ok = res ~= nil and res ~= false, data = res } end
	return res
end

local function fmtNum(n)
	n = tonumber(n) or 0
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while math.abs(n) >= 1000 and i < #units do
		n = n / 1000
		i += 1
	end
	if i == 1 then return tostring(math.floor(n)) end
	return string.format("%.2f%s", n, units[i])
end

local function root()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
	local c = LP.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function charAlive()
	local h = humanoid()
	return h ~= nil and h.Health > 0 and root() ~= nil
end

-- instance from a dotted path ("Workspace.World 2.Gameplay...") or a list of names
local function resolvePath(path)
	local node = game
	local parts = {}
	if type(path) == "table" then
		parts = path
		node = workspace
	else
		for p in tostring(path):gmatch("[^%.]+") do parts[#parts + 1] = p end
	end
	for i, p in ipairs(parts) do
		if i == 1 and node == game and p == "Workspace" then
			node = workspace
		else
			node = node and node:FindFirstChild(p)
		end
		if not node then return nil end
	end
	return node
end

local function tpTo(cf, settle)
	local hrp = root()
	if not hrp then return false end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = cf
	task.wait(settle or 0.3)
	return true
end
local PathfindingService = game:GetService("PathfindingService")
local function walkTo(target, timeout)
	local hum, hrp = humanoid(), root()
	if not hum or not hrp or hrp.Anchored then return false end
	local deadline = os.clock() + (timeout or 40)
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6 })
	local okC = pcall(function() path:ComputeAsync(hrp.Position, target) end)
	local wps = okC and path.Status == Enum.PathStatus.Success and path:GetWaypoints() or { { Position = target } }
	for _, wp in ipairs(wps) do
		if not alive() or os.clock() > deadline then return false end
		if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
		hum:MoveTo(wp.Position)
		local reached = false
		local c = hum.MoveToFinished:Connect(function() reached = true end)
		local t = os.clock()
		while not reached and os.clock() - t < 3 do task.wait() end
		c:Disconnect()
	end
	return (hrp.Position - target).Magnitude < 6
end
-- far trips always teleport (the map is several thousand studs long); Walk mode only walks short hops
local function goTo(cf, settle)
	local hrp = root()
	if not hrp then return false end
	if Cfg.Movement == "Walk" and (hrp.Position - cf.Position).Magnitude < 120 then
		if walkTo(cf.Position, 25) then
			task.wait(settle or 0.2)
			return true
		end
	end
	return tpTo(cf, settle)
end

-- staff detector: the game owner, or a high rank in the owning group
local staffHere = {}
local function isStaff(p)
	if p == LP then return false end
	if game.CreatorType == Enum.CreatorType.User then return p.UserId == game.CreatorId end
	local ok, rank = pcall(p.GetRankInGroup, p, game.CreatorId)
	return ok and type(rank) == "number" and rank >= 200
end
local function staffPresent() return Cfg.StaffDetect and next(staffHere) ~= nil end
local function staffNames()
	local n = {}
	for p in pairs(staffHere) do n[#n + 1] = p.Name end
	return table.concat(n, ", ")
end
local function farmPaused() return staffPresent() and Cfg.StaffAction ~= "Notify only" end

------------------------------------------------------------------------------------------------------
-- 6. Throw and train
------------------------------------------------------------------------------------------------------
local Stats = {
	start = os.clock(), throws = 0, landed = 0, failed = 0, earned = 0, lastMoney = nil, bestGain = 0,
	powerStart = tonumber(attr("TrainingPower")) or 0, rebirths = 0, hatched = 0, candy = 0, claimed = 0,
	planes = 0, papers = 0, status = "Idle", log = {}, lastReason = nil, cycleSum = 0, perfect = 0, bestDist = 0, rings = 0,
}
local function setStatus(s) Stats.status = s end
local function addLog(line)
	table.insert(Stats.log, 1, line)
	if #Stats.log > 6 then table.remove(Stats.log) end
end

-- the game's own local functions, found by name in the garbage collector and matched by script
local fnCache = {}
local function gameFn(name, scriptName)
	local key = scriptName .. "." .. name
	if fnCache[key] then return fnCache[key] end
	if type(filtergc) ~= "function" then return nil end
	local ok, list = pcall(filtergc, "function", { Name = name }, false)
	if not ok or type(list) ~= "table" then return nil end
	for _, f in ipairs(list) do
		local okI, info = pcall(debug.getinfo, f)
		if okI and info and tostring(info.source):find(scriptName, 1, true) then
			fnCache[key] = f
			return f
		end
	end
	return nil
end

-- centre of the PERFECT charge window, computed the same way the game's own auto throw does
local perfectHold = (function()
	if FlightConfig and FlightConfig.PowerAt then
		local a, b
		for i = 0, 3000 do
			local t = i / 1000
			local ok, p = pcall(FlightConfig.PowerAt, t)
			if ok and p >= 1 then
				a = a or t
				b = t
			elseif a then
				break
			end
		end
		if a then return (a + b) / 2 - 0.008 end
	end
	return 0.748
end)()
-- half width of the perfect window, so a human-style release stays inside it
local perfectHalf = (function()
	if FlightConfig and FlightConfig.PowerAt and FlightConfig.Charge then
		local minP = FlightConfig.Charge.PerfectMin or 0.95
		local lo, hi = perfectHold, perfectHold
		while lo > 0 and (FlightConfig.PowerAt(lo - 0.001) or 0) >= minP do lo -= 0.001 end
		while hi < 3 and (FlightConfig.PowerAt(hi + 0.001) or 0) >= minP do hi += 0.001 end
		return math.max(0, math.min(perfectHold - lo, hi - perfectHold) - 0.015)
	end
	return 0.02
end)()

-- flight state from the server's own PlaneFlight events
local flight = { id = nil, launchedAt = nil, returned = true, rejected = nil, thrownAt = nil, landedAt = nil }
if PlaneFlight then
	connect(PlaneFlight.OnClientEvent, function(kind, data)
		if type(data) ~= "table" then return end
		if kind ~= "SteeringState" and kind ~= "RingSpawn" and kind ~= "RingRemoved" then
			flight.events = flight.events or {}
			table.insert(flight.events, 1, string.format("%.1f %s fid=%s uid=%s", os.clock(), tostring(kind),
				tostring(data.FlightId and tostring(data.FlightId):sub(1, 8)), tostring(data.UserId)))
			if #flight.events > 25 then table.remove(flight.events) end
		end
		if kind == "Thrown" and (data.UserId == nil or data.UserId == LP.UserId) then
			flight.lastThrown = data
		elseif kind == "Reward" and (data.UserId == nil or data.UserId == LP.UserId or data.FlightId == flight.id) then
			flight.lastReward = data
		end
		if kind == "Launched" and data.UserId == LP.UserId then
			flight.id = data.FlightId
			flight.launchedAt = os.clock()
			flight.returned = false
		elseif kind == "Landed" and data.FlightId ~= nil and data.FlightId == flight.id then
			flight.landedAt = os.clock()
		elseif kind == "Returned" and data.FlightId ~= nil and data.FlightId == flight.id then
			flight.returned = true
		elseif kind == "Rejected" and (data.UserId == nil or data.UserId == LP.UserId) then
			-- the game resyncs its attempt counter from NextAttemptId by itself; a retry then goes through
			flight.rejected = tostring(data.Reason or data.Msg or data.msg or data.Code or "attempt out of sync")
		elseif kind == "Cancelled" and (data.FlightId == nil or data.FlightId == flight.id) and data.UserId == LP.UserId then
			flight.returned = true
		end
	end)
end

local function planeTool()
	local c = LP.Character
	if c then
		for _, v in ipairs(c:GetChildren()) do
			if v:IsA("Tool") and v:GetAttribute("PaperPlaneTool") then return v, true end
		end
	end
	local bp = LP:FindFirstChildOfClass("Backpack")
	if bp then
		for _, v in ipairs(bp:GetChildren()) do
			if v:IsA("Tool") and v:GetAttribute("PaperPlaneTool") then return v, false end
		end
	end
	return nil
end
local function equipPlane()
	local tool, held = planeTool()
	if not tool then return false end
	if held then return true end
	local hum = humanoid()
	if hum then pcall(hum.EquipTool, hum, tool) end
	task.wait(0.25)
	local _, h2 = planeTool()
	return h2 == true
end

local function launchRegion(world)
	if not WorldConfig then return nil end
	local ok, w = pcall(WorldConfig.Get, world or currentWorld())
	if not ok or type(w) ~= "table" or type(w.LaunchZone) ~= "string" then return nil end
	local zone = resolvePath(w.LaunchZone)
	return zone and zone:FindFirstChild("LaunchRegion")
end
-- strictly inside the launch region: the game's own client check pads the region by 1 stud, the server's does not,
-- and the training pad right next to it passes the padded check while the server answers "Stand in the Launch Zone"
local function inLaunch()
	local hrp = root()
	if not hrp then return false end
	local r = launchRegion()
	if not r or not r:IsA("BasePart") then
		if not WorldConfig then return false end
		local ok, found = pcall(WorldConfig.FindLaunch, hrp.Position)
		return ok and found ~= nil
	end
	local p = r.CFrame:PointToObjectSpace(hrp.Position)
	local h = r.Size / 2
	return math.abs(p.X) <= h.X - 2 and math.abs(p.Z) <= h.Z - 2 and math.abs(p.Y) <= h.Y + 6
end
local function launchCF()
	local r = launchRegion()
	if not r or not r:IsA("BasePart") then return nil end
	-- a little in from the front edge, standing on top of the region
	return r.CFrame * CFrame.new(0, -r.Size.Y / 2 + 3.2, 0)
end

-- training ----------------------------------------------------------------------------------------------
local function isTraining() return attr("IsTraining") == true end
local function passOwned(key) return LP:GetAttribute("Pass_" .. tostring(key)) == true end
local function zoneInfo(id)
	if not TrainingConfig then return nil end
	local ok, z = pcall(TrainingConfig.Get, id)
	return ok and z or nil
end
local function zoneMult(z)
	if type(z) ~= "table" then return 0 end
	return tonumber(z.PremiumMultiplier) or tonumber(z.TrainingMultiplier) or 0
end
local function canEnter(id)
	if not TrainingConfig or not TrainingConfig.CanEnter then return false end
	local ok, v = pcall(TrainingConfig.CanEnter, id, rebirths(), passOwned, tonumber(attr("UnlockedWorld")) or 1)
	return ok and v == true
end
-- best open zone in the world you are in
local function bestZone()
	if not TrainingConfig or not TrainingConfig.ZonesForWorld then return nil end
	local ok, list = pcall(TrainingConfig.ZonesForWorld, currentWorld())
	if not ok or type(list) ~= "table" then return nil end
	local best, bestM
	for _, z in pairs(list) do
		local info = type(z) == "table" and z or zoneInfo(z)
		local id = info and info.Id
		if id and canEnter(id) then
			local m = zoneMult(info)
			if not bestM or m > bestM then best, bestM = info, m end
		end
	end
	return best
end
local function zoneModel(id)
	if TrainingConfig and TrainingConfig.Model then
		local ok, m = pcall(TrainingConfig.Model, id)
		if ok and typeof(m) == "Instance" then return m end
	end
	local info = zoneInfo(id)
	if info and info.ModelPath then return resolvePath(info.ModelPath) end
	local area = TrainingConfig and TrainingConfig.AreaPath and resolvePath(TrainingConfig.AreaPath)
	return area and area:FindFirstChild("Zone" .. tostring(id))
end
local function zoneCF(id)
	local m = zoneModel(id)
	if not m then return nil end
	-- every zone has a TrainingPoint part where the game snaps you onto the pad
	local tp = m:FindFirstChild("TrainingPoint")
	if tp and tp:IsA("BasePart") then return tp.CFrame + Vector3.new(0, 3, 0) end
	local cf, size
	if m:IsA("Model") then
		cf, size = m:GetBoundingBox()
	elseif m:IsA("BasePart") then
		cf, size = m.CFrame, m.Size
	end
	if not cf then return nil end
	return CFrame.new(cf.Position.X, cf.Position.Y - size.Y / 2 + 4, cf.Position.Z)
end

local function stopTraining()
	if not isTraining() and attr("TrainingClientState") ~= "TRAINING" then return true end
	local ex = gameFn("exitTraining", "TrainingClient")
	if ex then pcall(ex) end
	local t = os.clock()
	while isTraining() and os.clock() - t < 4 do task.wait(0.1) end
	-- the game walks you off the pad after training ends; let that finish before moving anywhere
	while attr("TrainingClientState") ~= "OUTSIDE" and os.clock() - t < 6 do task.wait(0.1) end
	task.wait(0.2)
	return not isTraining()
end

local function startTraining(keepGoing)
	local z = bestZone()
	if isTraining() then
		-- a better zone opened up (new rebirth, new world): move there
		local cur = tonumber(attr("TrainingZone"))
		if not z or not cur or cur == z.Id or zoneMult(zoneInfo(cur)) >= zoneMult(z) then return true end
		stopTraining()
	end
	if not z then return false, "no open training zone" end
	local cf = zoneCF(z.Id)
	if not cf then return false, "zone " .. tostring(z.Id) .. " not loaded" end
	setStatus("Going to training: " .. tostring(z.Name or z.Id))
	goTo(cf, 0.4)
	-- the game's TrainingClient aligns you on the pad first (READY), which takes several seconds
	local t = os.clock()
	while not isTraining() and os.clock() - t < 15 do
		if keepGoing and not keepGoing() then return false, "stopped" end
		task.wait(0.15)
	end
	if not isTraining() then return false, "training did not start (zone " .. tostring(z.Id) .. ")" end
	return true
end

-- throwing ----------------------------------------------------------------------------------------------
local manualThrow = false
local function throwBlocked()
	if attr("WorldTransition") then return "world transition" end
	if attr("IsFolding") then return "folding paper" end
	if attr("CutscenePreviewing") then return "cutscene" end
	if not charAlive() then return "no character" end
	local pg = LP:FindFirstChildOfClass("PlayerGui")
	local hatch = pg and pg:FindFirstChild("HatchCinematicGui")
	if hatch and hatch.Enabled then return "egg hatching" end
	return nil
end

-- one throw: returns true once the server launched the plane
local function doThrowOnce()
	local why = throwBlocked()
	if why then return false, why end
	local began = gameFn("onInputBegan", "PlaneClientController")
	local ended = gameFn("onInputEnded", "PlaneClientController")
	if not began or not ended then return false, "throw handlers not found" end
	if isTraining() then
		setStatus("Leaving training")
		stopTraining()
		if isTraining() then return false, "could not leave training" end
	end
	if not inLaunch() then
		local cf = launchCF()
		if not cf then return false, "launch zone not found" end
		setStatus("Going to the launch zone")
		goTo(cf, 0.35)
		if not inLaunch() then
			tpTo(cf, 0.35)
			if not inLaunch() then return false, "not in the launch zone" end
		end
	end
	if not equipPlane() then return false, "no plane tool" end
	setStatus("Throwing")
	local hold = perfectHold
	if Cfg.HumanRelease and perfectHalf > 0 then
		hold = perfectHold + (math.random() * 2 - 1) * perfectHalf
	end
	local fake = { UserInputType = Enum.UserInputType.MouseButton1 }
	flight.rejected = nil
	local startId = flight.id
	local okB = pcall(began, fake, false)
	if not okB then return false, "throw start failed" end
	task.wait(hold)
	pcall(ended, fake)
	-- wait for the server to launch it
	local t = os.clock()
	while os.clock() - t < 8 do
		if flight.id ~= startId and not flight.returned then
			Stats.throws += 1
			return true
		end
		if flight.rejected then
		-- "Stand in the Launch Zone": go to the exact centre before the retry
		if flight.rejected:find("Launch Zone", 1, true) then
			local cf = launchCF()
			if cf then tpTo(cf, 0.4) end
		end
		return false, "rejected: " .. flight.rejected, true
	end
		task.wait(0.1)
	end
	return false, "no launch from the server"
end
local function doThrow()
	local ok, why, retry = doThrowOnce()
	if not ok and retry then
		task.wait(1.2)
		ok, why = doThrowOnce()
	end
	return ok, why
end

------------------------------------------------------------------------------------------------------
-- 7. Rewards, rebirth, pets, planes, smart flight
------------------------------------------------------------------------------------------------------
local function doRebirth()
	if attr("CanRebirth") ~= true then return false, "not ready" end
	local before = rebirths()
	local r = call("Rebirth")
	if r.busy then return false, "busy" end
	task.wait(1)
	if r.ok or rebirths() > before then
		Stats.rebirths += 1
		notifyAct("rebirth", 5, "Rebirth!", "Rebirths: " .. rebirths(), "autorenew")
		return true
	end
	return false, tostring(r.msg or "failed")
end

local function claimPlaytime()
	local st = invoke("GetPlaytimeRewards")
	if not st.state then
		task.wait(0.6)
		st = invoke("GetPlaytimeRewards")
	end
	local state = st and st.state
	if type(state) ~= "table" or type(state.Rewards) ~= "table" then return 0 end
	local n = 0
	for id, rw in pairs(state.Rewards) do
		-- (the game marks ready rewards Locked = true, so Locked is not a reason to skip)
		if type(rw) == "table" and rw.Ready and not rw.Claimed then
			local r = invoke("ClaimPlaytimeReward", tonumber(id) or rw.Id)
			if r.ok then
				n += 1
				Stats.claimed += 1
				notifyAct("playtime" .. tostring(id), 0, "Playtime reward", tostring(rw.Name or "reward") .. " claimed", "redeem")
			end
			task.wait(0.4)
		end
	end
	return n
end

local function claimDaily()
	local st = call("GetDailyRewards")
	local state = st and st.state
	if type(state) ~= "table" or not state.CanClaim or not state.ClaimToken then return false end
	local r = call("ClaimDailyReward", state.ClaimToken, nil)
	if not r.ok and state.HighestWorld then
		-- some days let you pick a world; pick the highest one you have
		r = call("ClaimDailyReward", state.ClaimToken, tonumber(state.HighestWorld))
	end
	if r.ok then
		Stats.claimed += 1
		notifyAct("daily", 0, "Daily reward", "Day " .. tostring(state.CurrentDayIndex or "?") .. " claimed", "today")
	end
	return r.ok == true
end

local communityDone = false
local function claimCommunity()
	if communityDone then return false end
	local r = invoke("CommunityReward", "Claim", { Favorited = true })
	if r.ok then
		Stats.claimed += 1
		notifyAct("community", 0, "Community chest", tostring(r.msg or "claimed"), "redeem")
	end
	if r.ok or attr("CommunityRewardClaimed") == true then communityDone = true end
	return r.ok == true, r.msg
end

local function redeemCode(code)
	code = tostring(code or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if code == "" then return false, "empty code" end
	local r
	if BC and type(BC.Call) == "function" then
		local ok, res = pcall(BC.Call, "RedeemCode", code)
		r = ok and type(res) == "table" and res or { ok = false, msg = tostring(res) }
	else
		r = invoke("RedeemCode", code)
	end
	return r.ok == true, tostring(r.msg or (r.ok and "redeemed" or "failed"))
end

-- pets --------------------------------------------------------------------------------------------------
local function equipBestPets()
	local r = call("EquipBestPets", nil)
	return r.ok == true
end

local eggList, eggNames = {}, {}
if PetEggConfig and type(PetEggConfig.Eggs) == "table" then
	local order = type(PetEggConfig.Order) == "table" and PetEggConfig.Order or {}
	local seen = {}
	local function add(id)
		local e = PetEggConfig.Eggs[id]
		if type(e) == "table" and not e.RobuxOnly and not seen[id] then
			seen[id] = true
			eggList[#eggList + 1] = id
			eggNames[id] = string.format("%s (W%s, %s)", tostring(e.Name or id), tostring(e.World or 1), fmtNum(e.Price or 0))
		end
	end
	for _, id in ipairs(order) do add(id) end
	for id in pairs(PetEggConfig.Eggs) do add(id) end
end
local eggLabels, eggByLabel = {}, {}
for _, id in ipairs(eggList) do
	eggLabels[#eggLabels + 1] = eggNames[id]
	eggByLabel[eggNames[id]] = id
end
local function eggWorld(id)
	local e = PetEggConfig and PetEggConfig.Eggs[id]
	return e and tonumber(e.World) or 1
end
local eggModelCache = {}
local function eggModel(id)
	local m = eggModelCache[id]
	if m and m.Parent then return m end
	local e = PetEggConfig and PetEggConfig.Eggs[id]
	if not e or not e.WorldModel then return nil end
	local w = workspace:FindFirstChild("World " .. eggWorld(id))
	-- FindFirstChild(name, true) is native and stops at the first match, unlike a Lua descendant walk
	m = w and w:FindFirstChild(e.WorldModel, true) or workspace:FindFirstChild(e.WorldModel, true)
	eggModelCache[id] = m
	return m
end
local function hatchCount()
	local best = 1
	if PetEggConfig and type(PetEggConfig.Counts) == "table" then
		for n, ok in pairs(PetEggConfig.Counts) do
			if ok == true and tonumber(n) and tonumber(n) > best then best = tonumber(n) end
		end
	end
	return best
end
local function hatchOnce(id)
	id = id or Cfg.HatchEgg
	local e = PetEggConfig and PetEggConfig.Eggs[id]
	if not e then return false, "unknown egg" end
	if e.RobuxOnly then return false, "Robux only" end
	if eggWorld(id) > (tonumber(attr("HighestUnlockedWorld")) or tonumber(attr("UnlockedWorld")) or 1) then
		return false, "world " .. eggWorld(id) .. " locked"
	end
	local count = hatchCount()
	local price = (tonumber(e.Price) or 0)
	if coins() - price * count < (Cfg.HatchKeepCoins or 0) then
		count = 1
		if coins() - price < (Cfg.HatchKeepCoins or 0) then return false, "not enough coins" end
	end
	local m = eggModel(id)
	if not m then return false, "egg not loaded" end
	local pos = m:IsA("Model") and m:GetPivot().Position or m.Position
	local hrp = root()
	if not hrp then return false, "no character" end
	if (hrp.Position - pos).Magnitude > 14 then
		if isTraining() then stopTraining() end
		goTo(CFrame.new(pos + Vector3.new(0, 3, 8), pos), 0.4)
	end
	local r = invoke("HatchEgg", id, count)
	if r.ok then
		Stats.hatched += count
		addLog("Hatched " .. count .. "x " .. tostring(e.Name))
		return true
	end
	return false, tostring(r.msg or r.err or "failed")
end

-- planes ------------------------------------------------------------------------------------------------
-- Planes are no longer sold for coins (BuyPlane answers "retired"): you buy PAPER from the Paper Seller and fold it
-- at a folding table. The fold is a timing minigame; the hub drives the game's own folding client and presses each
-- challenge at the PERFECT moment (the same maths as the game's own Studio auto-fold), so rarer planes roll more.
-- the server's copy of your save: GetProfile -> { ok, data = { Planes = { {Id, Uid, Equipped}, ... }, Potions = {Coin = 1}, ... } }
local function profile()
	-- the server rate-limits requests; a busy moment returns nothing, so try a couple of times
	for i = 1, 3 do
		local r = invoke("GetProfile")
		if type(r.data) == "table" then return r.data end
		task.wait(0.5 * i)
	end
	return nil
end
local PaperFoldingConfig = safeRequire(Shared and Shared:FindFirstChild("PaperFoldingConfig"))
local PAPER_KEYS = { "Uncommon", "Rare", "Epic", "Legendary", "Mythical" }
local PAPER_CHOICES = { "Best affordable", "Uncommon", "Rare", "Epic", "Legendary", "Mythical" }
local function fold(action, ...)
	if BC and type(BC.Call) == "function" then
		local ok, res = pcall(BC.Call, "PaperFolding", action, ...)
		if ok and type(res) == "table" then return res end
		return { ok = false, msg = tostring(res) }
	end
	return invoke("PaperFolding", action, ...)
end
local function paperId(key, world)
	world = world or currentWorld()
	if PaperFoldingConfig and PaperFoldingConfig.PaperId then
		local ok, id = pcall(PaperFoldingConfig.PaperId, world, key)
		if ok and id then return id end
	end
	return "W" .. world .. "_" .. key
end
local function ownedPapers()
	local st = fold("GetState")
	return type(st.Papers) == "table" and st.Papers or {}
end
-- best paper you own for this world (rarest first)
local function bestOwnedPaper()
	local papers = ownedPapers()
	for i = #PAPER_KEYS, 1, -1 do
		local k = PAPER_KEYS[i]
		if (tonumber(papers[paperId(k)]) or 0) > 0 then return k end
	end
	return nil
end
local function sellerCF()
	local npcs = workspace:FindFirstChild("AirplaneShopNPCs")
	local shop = npcs and npcs:FindFirstChild("Shop_W" .. currentWorld())
	if not shop then return nil end
	local piv = shop:GetPivot()
	return CFrame.new(piv.Position + piv.LookVector * 7 + Vector3.new(0, 3, 0), piv.Position)
end
-- buys one sheet of the chosen paper (needs you next to the Paper Seller); returns key or nil, reason
local function buyPaper()
	local cf = sellerCF()
	if not cf then return nil, "Paper Seller not found" end
	local hrp = root()
	if not hrp then return nil, "no character" end
	if isTraining() then stopTraining() end
	-- the server only counts a fresh approach to the seller ("Walk up to the Paper Seller." when you were already
	-- standing there), so always come in from a few studs away
	tpTo(cf * CFrame.new(0, 0, 30), 0.4)
	tpTo(cf, 0.8)
	local shop = fold("GetShopState", currentWorld())
	if not shop.ok then
		tpTo(cf * CFrame.new(0, 0, 30), 0.5)
		tpTo(cf, 1)
		shop = fold("GetShopState", currentWorld())
	end
	if not shop.ok or type(shop.Items) ~= "table" then return nil, tostring(shop.msg or "shop closed") end
	local money = tonumber(shop.Coins) or coins()
	local pick
	if Cfg.PaperChoice == "Best affordable" then
		for i = #PAPER_KEYS, 1, -1 do
			local it = shop.Items[PAPER_KEYS[i]]
			if type(it) == "table" and (it.Remaining or 0) > 0 and money - (it.Price or math.huge) >= (Cfg.PaperKeepCoins or 0) then
				pick = PAPER_KEYS[i]
				break
			end
		end
	else
		local it = shop.Items[Cfg.PaperChoice]
		if type(it) == "table" and (it.Remaining or 0) > 0 and money - (it.Price or math.huge) >= (Cfg.PaperKeepCoins or 0) then
			pick = Cfg.PaperChoice
		end
	end
	if not pick then return nil, "nothing affordable in stock" end
	local r = fold("BuyPaper", pick, 1, HttpService:GenerateGUID(false), shop.Cycle)
	if not r.ok then return nil, tostring(r.msg or "buy failed") end
	Stats.papers += 1
	addLog("Bought " .. pick .. " paper")
	return pick
end

-- the game's folding client: startFolding(key) and the hit function (found by its "Hit"/"Busy" constants)
local function foldHitFn()
	local f = fnCache.foldHit
	if f then return f end
	if type(filtergc) ~= "function" then return nil end
	local ok, list = pcall(filtergc, "function", { Constants = { "Hit", "Busy" } }, false)
	if not ok or type(list) ~= "table" then return nil end
	for _, fn in ipairs(list) do
		local okI, info = pcall(debug.getinfo, fn)
		if okI and info and tostring(info.source):find("PaperFoldingClient", 1, true) then
			fnCache.foldHit = fn
			return fn
		end
	end
	return nil
end
local FOLD_STATES = { Idle = true, Entering = true, Picking = true, Folding = true, Busy = true, Reveal = true, Gacha = true }
-- reads the folding state string and the live challenge table out of the hit function's upvalues
local function foldState(hit)
	local state, challenge
	for i = 1, 20 do
		local ok, v = pcall(debug.getupvalue, hit, i)
		if not ok then break end
		if state == nil and type(v) == "string" and FOLD_STATES[v] then state = v end
		if challenge == nil and type(v) == "table" and v.Kind ~= nil and v.Start ~= nil and v.Index ~= nil then challenge = v end
	end
	return state, challenge
end
-- server time at which this challenge reads PERFECT
local function perfectTime(ch)
	if ch.Kind == "Circle" then
		return ch.Start + (ch.StartRadius - ch.TargetRadius) * ch.Duration / ch.StartRadius
	end
	local t = math.max(workspace:GetServerTimeNow(), ch.Start) + 0.05
	if PaperFoldingConfig and PaperFoldingConfig.TimingPos then
		for _ = 1, 4000 do
			local ok, pos = pcall(PaperFoldingConfig.TimingPos, ch, t)
			if not ok or math.abs(pos - ch.Center) < 0.004 then break end
			t += 0.001
		end
	end
	return t
end

local function planeScore(id)
	local cfg = PlaneConfig and PlaneConfig.Planes and PlaneConfig.Planes[id]
	if type(cfg) ~= "table" then return -1 end
	if Cfg.EquipBy == "Coins" then
		return (tonumber(cfg.CoinsMultiplier) or 1) * 1000 + (tonumber(cfg.BasePlanePower) or 0) / 1000
	end
	return (tonumber(cfg.TrainingFactor) or 1) * 1000 + (tonumber(cfg.BasePlanePower) or 0) / 1000
end
local function equipBestPlane()
	local p = profile()
	if not p then return false end
	local best, bestS, cur
	for _, v in pairs(p.Planes or {}) do
		if type(v) == "table" and v.Id then
			local s = planeScore(v.Id)
			if v.Equipped then cur = v.Id end
			if not bestS or s > bestS then best, bestS = v.Id, s end
		end
	end
	if not best or best == cur then return false end
	local r = call("EquipPlaneId", best)
	if r.ok then
		addLog("Equipped plane " .. tostring(best))
		notifyAct("plane", 10, "New plane equipped", tostring(r.msg or best), "flight")
		return true
	end
	return false
end

-- one paper -> one plane. Returns true when a plane came out.
local folding = false
local function foldOnce()
	if folding then return false, "already folding" end
	local hit = foldHitFn()
	local startFolding = gameFn("startFolding", "PaperFoldingClient")
	local endFolding = gameFn("endFolding", "PaperFoldingClient")
	if not hit or not startFolding or not endFolding then return false, "folding client not found" end
	local key = bestOwnedPaper()
	if not key and Cfg.AutoBuyPaper then
		local why
		key, why = buyPaper()
		if not key then return false, why end
		task.wait(0.4)
		key = bestOwnedPaper() or key
	end
	if not key then return false, "no paper (turn on Auto Buy Paper)" end
	local tables = resolvePath({ "World " .. currentWorld(), "Gameplay", "PaperFoldingTables" })
	local tbl = tables and (tables:FindFirstChild("FoldingTable_W" .. currentWorld() .. "_1") or tables:FindFirstChildWhichIsA("Model"))
	local spot = tbl and tbl:FindFirstChild("FoldingPlayerPosition", true)
	if not spot then return false, "folding table not found" end
	folding = true
	local ok, res, why = pcall(function()
		if isTraining() then stopTraining() end
		setStatus("Folding " .. key .. " paper")
		-- standing on the table's spot opens the paper picker
		local state = foldState(hit)
		if state ~= "Picking" then
			tpTo(spot.CFrame + Vector3.new(0, 3, 0), 0.3)
			local t = os.clock()
			repeat
				task.wait(0.1)
				state = foldState(hit)
			until state == "Picking" or os.clock() - t > 6
			if state ~= "Picking" then return false, "paper picker did not open (" .. tostring(state) .. ")" end
		end
		task.spawn(startFolding, key)
		local t0, last, hits = os.clock(), nil, 0
		while alive() and os.clock() - t0 < 120 do
			local st, ch = foldState(hit)
			if st == "Reveal" then break end
			if st == "Picking" and os.clock() - t0 > 6 then return false, "fold did not start" end
			if st == "Folding" and ch and ch ~= last then
				last = ch
				task.wait(math.max(0, perfectTime(ch) - workspace:GetServerTimeNow()))
				pcall(hit)
				hits += 1
			end
			task.wait(0.03)
		end
		task.wait(2.5) -- let the reveal finish so the plane is granted
		pcall(endFolding)
		task.wait(0.8)
		return hits > 0
	end)
	folding = false
	if not ok then
		pcall(endFolding)
		return false, tostring(res)
	end
	if res then
		Stats.planes += 1
		addLog("Folded a " .. key .. " paper")
		if Cfg.AutoEquipPlane then pcall(equipBestPlane) end
		return true
	end
	return false, why
end

-- candy (Halloween "Candy Weather"): candy spawns ahead of planes in flight and is picked up by the PLANE inside the
-- ring radius (WeatherConfig.Candy.CollectRadius = "Ring"), so it cannot be collected by moving the character.
-- The hub only counts what you get.
local candyStart = tonumber(attr("HalloweenCandy")) or 0
local function candyGained() return math.max(0, (tonumber(attr("HalloweenCandy")) or 0) - candyStart) end

-- smart flight --------------------------------------------------------------------------------------------
-- The game ships an autopilot (SmartFlightController: looks ahead for hazards and barriers and steers around them),
-- but only runs it for Auto Throw pass owners. Steering is an ordinary player input on the server, so the hub runs
-- the same controller for your own plane: it feeds it the live flight each frame, and keeps the game's per-frame
-- "not a pass owner -> Stop()" from switching it off while the hub is driving.
local smart = { driving = false, frames = 0 }
do
	local fc = LP:FindFirstChild("PlayerScripts") and LP.PlayerScripts:FindFirstChild("PaperPlaneFlightClient")
	local SFC = safeRequire(fc and fc:FindFirstChild("SmartFlightController"))
	local updateFlights = gameFn("updateFlights", "PlaneClientController")
	if SFC and type(SFC.Update) == "function" and type(SFC.Stop) == "function" and updateFlights then
		local origStop = SFC.Stop
		SFC.Stop = function(...)
			if smart.driving and alive() then return end
			return origStop(...)
		end
		cleanup(function()
			SFC.Stop = origStop
			if smart.driving then
				smart.driving = false
				pcall(origStop)
			end
		end)
		-- updateFlights upvalues: the own flight id, the table of flights, the flight state ("FLYING" while airborne)
		local idIdx, flightsIdx, stateIdx
		local function findSlots()
			for i = 1, 12 do
				local ok, v = pcall(debug.getupvalue, updateFlights, i)
				if not ok then break end
				if stateIdx == nil and type(v) == "string" and (v == "IDLE" or v == "FLYING" or v == "CHARGING" or v == "THROWING" or v == "RETURNING") then
					stateIdx = i
				end
			end
			-- the decompiled order is u310 (own flight id), u309 (flights), u301 (state)
			if stateIdx and stateIdx >= 3 then idIdx, flightsIdx = stateIdx - 2, stateIdx - 1 end
		end
		local function ownFlight()
			if not stateIdx then findSlots() end
			if not stateIdx then return nil end
			local _, state = pcall(debug.getupvalue, updateFlights, stateIdx)
			if state ~= "FLYING" then return nil end
			local _, id = pcall(debug.getupvalue, updateFlights, idIdx)
			local _, flights = pcall(debug.getupvalue, updateFlights, flightsIdx)
			local f = id and type(flights) == "table" and flights[id]
			if type(f) ~= "table" or type(f.Sim) ~= "table" then return nil end
			local sim = f.Sim
			if sim.Landed or sim.Sliding or sim.Impact or f.ServerSteeringEnded then return nil end
			if not (type(sim.SteeringBounds) == "table" and #sim.SteeringBounds > 0) then return nil end
			return f
		end
		connect(RunService.Heartbeat, function(dt)
			if not alive() then return end
			local f = Cfg.SmartFlight and not farmPaused() and ownFlight() or nil
			if f then
				smart.driving = true
				local ok = pcall(SFC.Update, f, dt)
				if ok then smart.frames += 1 end
			elseif smart.driving then
				smart.driving = false
				pcall(origStop)
			end
		end)
		smart.available = true
		smart.stats = function() local ok, s = pcall(SFC.Stats) return ok and s or nil end
	end
end

------------------------------------------------------------------------------------------------------
-- 8. Farm worker
------------------------------------------------------------------------------------------------------
local trainUntil = 0
-- side jobs that move the character run while a plane is in the air or when the farm is idle
local function sideJobs()
	if Cfg.AutoHatch then
		local ok, why = hatchOnce()
		if not ok and why and why ~= "not enough coins" then
			notifyAct("hatch", 60, "Auto Hatch", "Skipped: " .. tostring(why), "warning")
		end
	end
	if Cfg.AutoFold and os.clock() >= (Stats.foldRetryAt or 0) then
		local ok, why = foldOnce()
		if not ok then
			-- nothing to fold right now (no paper, out of stock, too poor): look again in a minute
			Stats.foldRetryAt = os.clock() + 60
			if why and not tostring(why):find("affordable") and not tostring(why):find("no paper") then
				notifyAct("fold", 120, "Auto Fold", "Skipped: " .. tostring(why), "warning")
			end
		end
	end
end
local function sideJobsWanted()
	return Cfg.AutoHatch or (Cfg.AutoFold and os.clock() >= (Stats.foldRetryAt or 0))
end

-- While the plane flies the server refuses everything else ("Finish your current activity first.": eggs, paper,
-- folding) and the game will not start training, so the hub just waits; side jobs run right after it lands.
local function waitFlight()
	local t = os.clock()
	while alive() and not flight.returned and os.clock() - t < 240 do
		setStatus(string.format("Plane flying (%ds)", os.clock() - t))
		task.wait(0.3)
	end
	if not flight.returned then
		flight.returned = true
		return false
	end
	return true
end

local failStreak = 0
local function throwCycle()
	local c0 = coins()
	local t0 = os.clock()
	local ok, why = doThrow()
	if not ok then
		Stats.failed += 1
		Stats.lastReason = why
		failStreak += 1
		setStatus("Throw failed: " .. tostring(why))
		if failStreak == 3 then notifyAct("throwfail", 60, "Auto Throw", "Throws keep failing: " .. tostring(why), "warning") end
		task.wait(math.min(10, 1.5 * failStreak))
		return
	end
	failStreak = 0
	waitFlight()
	-- coins are paid as the plane lands; give the counter a moment to catch up
	local t = os.clock()
	while coins() == c0 and os.clock() - t < 3 do task.wait(0.2) end
	local gain = coins() - c0
	local rw = flight.lastReward
	local dist
	if type(rw) == "table" and rw.FlightId == flight.id then
		gain = tonumber(rw.Reward) or gain
		dist = tonumber(rw.Distance)
		Stats.rings += tonumber(rw.RingsCollected) or 0
	end
	local th = flight.lastThrown
	if type(th) == "table" and th.Perfect then Stats.perfect += 1 end
	Stats.landed += 1
	Stats.cycleSum += os.clock() - t0
	if gain > Stats.bestGain then Stats.bestGain = gain end
	if dist and dist > Stats.bestDist then Stats.bestDist = dist end
	addLog(string.format("Throw #%d: +%s coins, %s studs%s (%.0fs)", Stats.throws, fmtNum(gain), dist and fmtNum(dist) or "?",
		type(th) == "table" and th.Perfect and ", PERFECT" or "", os.clock() - t0))
	-- eggs and folding between throws (the server does not allow them mid-flight)
	if sideJobsWanted() then
		local okS, errS = pcall(sideJobs)
		if not okS then Stats.lastReason = tostring(errS) end
	end
	-- train between throws: training is what levels you up (about 28 power/s on the first zone)
	if Cfg.AutoTrain and Cfg.TrainSecs > 0 then
		trainUntil = os.clock() + Cfg.TrainSecs
	end
end

local lastSlow = 0
local function slowJobs()
	if os.clock() - lastSlow < 20 then return end
	lastSlow = os.clock()
	-- spaced out: the server rate-limits bursts of requests
	if Cfg.AutoPlaytime then pcall(claimPlaytime) task.wait(0.3) end
	if Cfg.AutoDaily then pcall(claimDaily) task.wait(0.3) end
	if Cfg.AutoCommunity then pcall(claimCommunity) task.wait(0.3) end
	if Cfg.AutoEquipPets then pcall(equipBestPets) task.wait(0.3) end
	if Cfg.AutoEquipPlane and not folding then pcall(equipBestPlane) end
end

task.spawn(function()
	while alive() do
		task.wait(0.25)
		if not alive() then break end
		pcall(slowJobs)
		if farmPaused() then
			setStatus("Paused: staff in server (" .. staffNames() .. ")")
			task.wait(1)
		elseif Cfg.AutoRebirth and attr("CanRebirth") == true and flight.returned then
			setStatus("Rebirthing")
			pcall(doRebirth)
		elseif Cfg.AutoThrow then
			if os.clock() < trainUntil and Cfg.AutoTrain then
				startTraining(function() return Cfg.AutoTrain and Cfg.AutoThrow end)
				setStatus(string.format("Training before next throw (%ds)", math.max(0, trainUntil - os.clock())))
				task.wait(0.5)
			else
				local ok, err = pcall(throwCycle)
				if not ok then
					Stats.lastReason = tostring(err)
					warn("[Furina Plane] throw cycle: " .. tostring(err))
					task.wait(2)
				end
			end
		elseif Cfg.AutoTrain then
			local ok, why = startTraining(function() return Cfg.AutoTrain end)
			if not ok then
				setStatus("Training failed: " .. tostring(why))
				task.wait(3)
			else
				setStatus("Training (" .. fmtNum(attr("TrainingPower")) .. " power)")
			end
			-- training-only farm: break off for eggs / folding now and then, then go back
			if (Cfg.AutoFold and os.clock() >= (Stats.foldRetryAt or 0))
				or (Cfg.AutoHatch and os.clock() >= (Stats.hatchAt or 0)) then
				Stats.hatchAt = os.clock() + 30
				pcall(sideJobs)
			end
			task.wait(0.5)
		elseif Cfg.AutoHatch or Cfg.AutoFold then
			if sideJobsWanted() then pcall(sideJobs) end
			setStatus("Idle (side jobs on)")
			task.wait(Cfg.AutoHatch and 0.7 or 1)
		else
			setStatus("Idle")
			task.wait(0.5)
		end
	end
end)

------------------------------------------------------------------------------------------------------
-- 9. Player, world, misc
------------------------------------------------------------------------------------------------------
local defaultSpeed, defaultJump = 16, 50
local function modsAllowed() return not staffPresent() end
local speedApplied, jumpApplied = false, false
connect(RunService.Heartbeat, function()
	if not alive() then return end
	local hum = humanoid()
	if not hum then return end
	local allowed = modsAllowed()
	-- the game sets WalkSpeed to 0 while charging and training; never fight that
	if Cfg.SpeedOn and allowed then
		if hum.WalkSpeed > 0 and hum.WalkSpeed ~= Cfg.Speed then hum.WalkSpeed = Cfg.Speed end
		speedApplied = true
	elseif speedApplied then
		speedApplied = false
		if hum.WalkSpeed > 0 then hum.WalkSpeed = defaultSpeed end
	end
	if Cfg.JumpOn and allowed then
		hum.UseJumpPower = true
		if hum.JumpPower > 0 and hum.JumpPower ~= Cfg.Jump then hum.JumpPower = Cfg.Jump end
		jumpApplied = true
	elseif jumpApplied then
		jumpApplied = false
		if hum.JumpPower > 0 then hum.JumpPower = defaultJump end
	end
end)
local function restoreMovement()
	local hum = humanoid()
	if not hum then return end
	if not Cfg.SpeedOn and hum.WalkSpeed > 0 then hum.WalkSpeed = defaultSpeed end
	if not Cfg.JumpOn and hum.JumpPower > 0 then hum.JumpPower = defaultJump end
end
cleanup(function()
	local hum = humanoid()
	if hum then
		if speedApplied and hum.WalkSpeed > 0 then hum.WalkSpeed = defaultSpeed end
		if jumpApplied and hum.JumpPower > 0 then hum.JumpPower = defaultJump end
	end
end)

connect(UserInputService.JumpRequest, function()
	if not alive() or not Cfg.InfJump or not modsAllowed() then return end
	local hum = humanoid()
	if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

local noclipped = {}
connect(RunService.Stepped, function()
	if not alive() then return end
	local c = LP.Character
	if not c then return end
	if Cfg.Noclip and modsAllowed() then
		for _, p in ipairs(c:GetChildren()) do
			if p:IsA("BasePart") and p.CanCollide then
				noclipped[p] = true
				p.CanCollide = false
			end
		end
	elseif next(noclipped) then
		for p in pairs(noclipped) do
			if p.Parent then p.CanCollide = true end
		end
		table.clear(noclipped)
	end
end)
cleanup(function()
	for p in pairs(noclipped) do
		if p.Parent then p.CanCollide = true end
	end
end)

connect(LP.Idled, function()
	if not alive() or not Cfg.AntiAFK then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end)

local boostSaved
local function setBoost(on)
	if on and not boostSaved then
		boostSaved = { shadows = Lighting.GlobalShadows, effects = {} }
		pcall(function() boostSaved.quality = settings().Rendering.QualityLevel end)
		Lighting.GlobalShadows = false
		for _, e in ipairs(Lighting:GetChildren()) do
			if e:IsA("PostEffect") and e.Enabled then
				boostSaved.effects[#boostSaved.effects + 1] = e
				e.Enabled = false
			end
		end
		pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
	elseif not on and boostSaved then
		Lighting.GlobalShadows = boostSaved.shadows
		for _, e in ipairs(boostSaved.effects) do
			if e.Parent then e.Enabled = true end
		end
		if boostSaved.quality then pcall(function() settings().Rendering.QualityLevel = boostSaved.quality end) end
		boostSaved = nil
	end
end
cleanup(function() setBoost(false) end)

local function serverHop()
	local ok, body = pcall(function()
		return game:HttpGet("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Desc&limit=100")
	end)
	if not ok then return notify("Server Hop", "Could not read the server list", "warning") end
	local okD, data = pcall(function() return HttpService:JSONDecode(body) end)
	if not okD then return notify("Server Hop", "Bad server list", "warning") end
	for _, s in ipairs(data.data or {}) do
		if s.id ~= game.JobId and (s.playing or 0) < (s.maxPlayers or 0) then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LP)
			return
		end
	end
	notify("Server Hop", "No other open server found", "warning")
end

local function onStaffJoined(p)
	if not Cfg.StaffDetect then return end
	notify("Staff joined", p.Name .. " owns or runs this game. " .. (Cfg.StaffAction == "Pause farming" and "Farming paused until they leave."
		or Cfg.StaffAction == "Server hop" and "Moving to another server..." or "Be careful."), "warning")
	restoreMovement()
	if Cfg.StaffAction == "Server hop" then
		task.delay(2, function() if alive() and staffHere[p] then serverHop() end end)
	end
end
local function checkPlayer(p)
	task.spawn(function()
		if isStaff(p) and p.Parent then
			staffHere[p] = true
			onStaffJoined(p)
		end
	end)
end
for _, p in ipairs(Players:GetPlayers()) do checkPlayer(p) end
connect(Players.PlayerAdded, checkPlayer)
connect(Players.PlayerRemoving, function(p)
	if staffHere[p] then
		staffHere[p] = nil
		if Cfg.StaffDetect and not next(staffHere) then notify("Staff left", "No staff in the server any more.", "check_circle") end
	end
end)

local lastSig = signature()
task.spawn(function()
	while alive() do
		task.wait(3)
		if Cfg.AutoSave then
			local sig = signature()
			if sig ~= lastSig then
				lastSig = sig
				saveCfg()
			end
		end
	end
end)
cleanup(function() if Cfg.AutoSave then saveCfg() end end)

------------------------------------------------------------------------------------------------------
-- 10. UI
------------------------------------------------------------------------------------------------------
if unloaded then return end
local Window = UI:CreateWindow({
	Name = "Furina Hub",
	Subtitle = "Paper To Plane",
	LogoID = "6031097225",
	LoadingEnabled = false,
	ConfigSettings = { ConfigFolder = "FurinaHub" },
	KeySystem = false,
})
cleanup(function() pcall(function() UI:Destroy() end) end)

local Toggles, Sliders, Dropdowns = {}, {}, {}
local function tab(name, icon) return Window:CreateTab({ Name = name, Icon = icon, ImageSource = "Material", ShowTitle = true }) end
local function head(t, text)
	if FURINA then t:CreateSection(text) else t:CreateLabel({ Text = text, Style = 2 }) end
end
local function tog(t, name, key, desc, cb)
	Toggles[key] = t:CreateToggle({
		Name = name, Description = desc, CurrentValue = Cfg[key],
		Callback = function(v) Cfg[key] = v if cb then cb(v) end end,
	})
end
local function sld(t, name, key, lo, hi, cb, inc)
	Sliders[key] = t:CreateSlider({
		Name = name, Range = { lo, hi }, Increment = inc or 1, CurrentValue = math.clamp(Cfg[key], lo, hi),
		Callback = function(v) Cfg[key] = v if cb then cb(v) end end,
	})
end
local function dd(t, name, key, options, desc, map)
	local cur = Cfg[key]
	if map then
		for label, v in pairs(map) do if v == cur then cur = label end end
	end
	Dropdowns[key] = t:CreateDropdown({
		Name = name, Description = desc, Options = options, CurrentOption = { cur }, MultipleOptions = false,
		Callback = function(o)
			o = type(o) == "table" and o[1] or o
			if o ~= nil then Cfg[key] = map and map[o] or o end
		end,
	})
end
local function button(t, name, desc, fn, danger)
	t:CreateButton({ Name = name, Description = desc, Danger = danger, Callback = function() task.spawn(fn) end })
end
local function refreshUI()
	for key, t in pairs(Toggles) do pcall(function() t:Set(Cfg[key]) end) end
	for key, s in pairs(Sliders) do pcall(function() s:Set(Cfg[key]) end) end
end
local function infoLabel(t, lines, style)
	return t:CreateLabel({ Text = string.rep("-\n", lines - 1) .. "-", Style = style or 2 })
end
local function setLabel(l, text) pcall(function() l:Set(text) end) end

local function panic()
	for _, k in ipairs({ "AutoThrow", "AutoTrain", "AutoHatch", "AutoFold", "SmartFlight", "AutoRebirth", "SpeedOn", "JumpOn", "InfJump", "Noclip" }) do
		Cfg[k] = false
		if Toggles[k] then pcall(function() Toggles[k]:Set(false) end) end
	end
	restoreMovement()
end

-- Farm ----------------------------------------------------------------------------------------------------
local Farm = tab("Farm", "bolt")
local statusLabel = infoLabel(Farm, 1, 1)
local statsLabel = infoLabel(Farm, 3)
local logLabel = infoLabel(Farm, 4)
local function farmNote()
	local what = Cfg.AutoThrow and Cfg.AutoTrain and "throwing and training" or Cfg.AutoThrow and "throwing"
		or Cfg.AutoTrain and "training" or nil
	lastNoteKind.farm = nil
	notifyAct("farm", 0, what and "Auto farm on" or "Auto farm off", what and ("Now " .. what .. ".") or "Throwing and training stopped.", what and "play_arrow" or "pause")
end
head(Farm, "Throwing")
tog(Farm, "Auto Throw", "AutoThrow", "PERFECT throws from the launch zone, one after another. Goes to the launch zone and equips the plane by itself", farmNote)
tog(Farm, "Human Release", "HumanRelease", "Releases at a slightly different moment each time, always inside the PERFECT window")
tog(Farm, "Smart Flight", "SmartFlight", "Runs the game's own autopilot (normally Auto Throw pass only) on your plane: it steers around hazards and barriers so flights go further. Works for your manual throws too")
dd(Farm, "Move By", "Movement", MOVEMENTS, "Teleport = instant. Walk = walks short trips (long trips across the map still teleport)")
head(Farm, "Training")
tog(Farm, "Auto Train", "AutoTrain", "Trains Power on the best training zone you have unlocked in this world (Power = level = rebirths). With Auto Throw on it trains between throws", farmNote)
sld(Farm, "Train Seconds Between Throws", "TrainSecs", 0, 600)
Farm:CreateLabel({ Text = "Training is what levels you up; throws earn coins for planes and eggs. While your plane is in the air the game blocks training, eggs and folding, so those run between throws.", Style = 2 })
head(Farm, "Rebirth")
tog(Farm, "Auto Rebirth", "AutoRebirth", "Rebirths the moment the game allows it (max level). Rebirth resets level and coins for a permanent multiplier")
button(Farm, "Rebirth Now", nil, function()
	local ok, why = doRebirth()
	notify("Rebirth", ok and "Done" or ("Not now: " .. tostring(why)), ok and "check_circle" or "info")
end)
head(Farm, "Session")
tog(Farm, "Resume Farming On Load", "ResumeFarm", "Off = Auto Throw, Auto Train, Auto Hatch and Auto Fold always start off when the hub loads")
tog(Farm, "Activity Notifications", "ActivityNotify")
button(Farm, "Throw Once", "One perfect throw right now", function()
	if Cfg.AutoThrow then return notify("Throw", "Auto Throw is already running", "info") end
	if manualThrow then return end
	manualThrow = true
	local ok, why = doThrow()
	manualThrow = false
	notify("Throw", ok and "Thrown!" or ("Failed: " .. tostring(why)), ok and "check_circle" or "warning")
end)

-- Rewards -------------------------------------------------------------------------------------------------
local Rew = tab("Rewards", FURINA and "star" or "redeem")
head(Rew, "Automatic")
tog(Rew, "Auto Claim Playtime Rewards", "AutoPlaytime", "Claims each playtime gift (coins, power, potions, eggs, aura spins) the moment it is ready")
tog(Rew, "Auto Claim Daily Reward", "AutoDaily")
tog(Rew, "Auto Claim Community Chest", "AutoCommunity", "The chest normally asks you to favorite the game first")
head(Rew, "Now")
button(Rew, "Claim Playtime Rewards", nil, function()
	local n = claimPlaytime()
	notify("Playtime", n > 0 and ("Claimed " .. n) or "Nothing ready yet", "info")
end)
button(Rew, "Claim Daily Reward", nil, function()
	notify("Daily", claimDaily() and "Claimed" or "Already claimed today", "info")
end)
button(Rew, "Claim Community Chest", nil, function()
	communityDone = false
	local ok, msg = claimCommunity()
	notify("Community chest", ok and "Claimed" or ("Not claimed: " .. tostring(msg)), "info")
end)
head(Rew, "Codes")
local codeText = ""
Rew:CreateInput({
	Name = "Code", PlaceholderText = "type a code", RemoveTextAfterFocusLost = false,
	Callback = function(t) codeText = t end,
})
button(Rew, "Redeem Code", nil, function()
	local ok, msg = redeemCode(codeText)
	notify("Code", (ok and "Redeemed: " or "Failed: ") .. msg, ok and "check_circle" or "warning")
end)

-- Pets & Planes -------------------------------------------------------------------------------------------
local Pets = tab("Pets", FURINA and "casino" or "pets")
head(Pets, "Eggs")
if #eggLabels > 0 then
	if not eggNames[Cfg.HatchEgg] then Cfg.HatchEgg = eggList[1] end
	dd(Pets, "Egg", "HatchEgg", eggLabels, "Coin eggs only (Robux eggs are skipped)", eggByLabel)
end
tog(Pets, "Auto Hatch", "AutoHatch", "Hatches the chosen egg whenever you can afford it. Goes to the egg (hatch range is 20 studs); when farming it hatches after each landing")
sld(Pets, "Keep At Least (coins)", "HatchKeepCoins", 0, 1000000, nil, 1000)
button(Pets, "Hatch Once", nil, function()
	local ok, why = hatchOnce()
	notify("Hatch", ok and "Hatched" or ("Failed: " .. tostring(why)), ok and "check_circle" or "warning")
end)
head(Pets, "Team")
tog(Pets, "Auto Equip Best Pets", "AutoEquipPets", "Uses the game's Equip Best every 20 s")
button(Pets, "Equip Best Pets Now", nil, function()
	notify("Pets", equipBestPets() and "Best pets equipped" or "Equip failed", "info")
end)
-- Planes ---------------------------------------------------------------------------------------------------
local Pl = tab("Planes", FURINA and "arrow" or "flight")
Pl:CreateLabel({ Text = "Planes now come from paper folding: buy paper at the Paper Seller, fold it at a table. The hub presses every fold at the PERFECT moment, which gives the best odds for rare planes.", Style = 2 })
head(Pl, "Folding")
tog(Pl, "Auto Fold Planes", "AutoFold", "Folds every paper you own (rarest first). When farming it folds after a landing, otherwise whenever it has paper")
tog(Pl, "Auto Buy Paper", "AutoBuyPaper", "When you are out of paper, buys one from the Paper Seller in your world (it restocks on a timer)")
dd(Pl, "Paper To Buy", "PaperChoice", PAPER_CHOICES, "Best affordable = the rarest paper in stock you can pay for")
sld(Pl, "Keep At Least (coins)", "PaperKeepCoins", 0, 1000000, nil, 1000)
button(Pl, "Fold One Now", nil, function()
	local ok, why = foldOnce()
	notify("Fold", ok and "Plane folded!" or ("Failed: " .. tostring(why)), ok and "check_circle" or "warning")
end)
button(Pl, "Buy One Paper Now", nil, function()
	local key, why = buyPaper()
	notify("Paper", key and ("Bought " .. key .. " paper") or ("Failed: " .. tostring(why)), key and "check_circle" or "warning")
end)
head(Pl, "Equip")
tog(Pl, "Auto Equip Best Plane", "AutoEquipPlane", "Checks your planes every 20 s and after each fold")
dd(Pl, "Best Plane By", "EquipBy", EQUIP_BY, "Training = highest training factor (levels you up faster). Coins = highest coin multiplier")
button(Pl, "Equip Best Plane Now", nil, function()
	notify("Planes", equipBestPlane() and "Equipped a better plane" or "Already using your best plane", "info")
end)

-- Events --------------------------------------------------------------------------------------------------
local Ev = tab("Events", FURINA and "palette" or "celebration")
local eventLabel = infoLabel(Ev, 2, 1)
head(Ev, "Candy Weather")
Ev:CreateLabel({ Text = "Candy spawns ahead of your plane during Candy Weather and is picked up by the PLANE when it flies through it, so it is collected by throwing (keep Auto Throw on). Smart Flight in the Farm tab keeps planes in the air longer.", Style = 2 })

-- Player --------------------------------------------------------------------------------------------------
local Plr = tab("Player", "directions_run")
head(Plr, "Movement")
tog(Plr, "Speed", "SpeedOn", nil, function(v) if not v then restoreMovement() end end)
sld(Plr, "Walk Speed", "Speed", 16, 200)
tog(Plr, "Jump Power", "JumpOn", nil, function(v) if not v then restoreMovement() end end)
sld(Plr, "Jump", "Jump", 50, 250)
tog(Plr, "Infinite Jump", "InfJump")
tog(Plr, "Noclip", "Noclip")
head(Plr, "Travel")
button(Plr, "Launch Zone", nil, function()
	local cf = launchCF()
	if cf then tpTo(cf, 0) else notify("Travel", "Launch zone not found", "warning") end
end)
button(Plr, "Best Training Zone", nil, function()
	local z = bestZone()
	local cf = z and zoneCF(z.Id)
	if cf then tpTo(cf, 0) else notify("Travel", "No open training zone found", "warning") end
end)
button(Plr, "Chosen Egg", nil, function()
	local m = eggModel(Cfg.HatchEgg)
	if not m then return notify("Travel", "Egg not loaded", "warning") end
	local pos = m:IsA("Model") and m:GetPivot().Position or m.Position
	tpTo(CFrame.new(pos + Vector3.new(0, 3, 8), pos), 0)
end)
button(Plr, "Plane Shop", nil, function()
	local npcs = workspace:FindFirstChild("AirplaneShopNPCs")
	local shop = npcs and npcs:FindFirstChild("Shop_W" .. currentWorld())
	if not shop then return notify("Travel", "Shop not found", "warning") end
	local pos = shop:GetPivot().Position
	tpTo(CFrame.new(pos + shop:GetPivot().LookVector * 8 + Vector3.new(0, 3, 0), pos), 0)
end)

-- Info ----------------------------------------------------------------------------------------------------
local Info = tab("Info", "visibility")
head(Info, "You")
local infoYou = infoLabel(Info, 4)
head(Info, "This session")
local infoSession = infoLabel(Info, 4)
head(Info, "Server")
local infoServer = infoLabel(Info, 1)

-- Misc ----------------------------------------------------------------------------------------------------
local Misc = tab("Misc", "settings")
head(Misc, "General")
tog(Misc, "Anti AFK", "AntiAFK")
tog(Misc, "FPS Boost", "FPSBoost", "No shadows, no post effects, lowest quality. Restored when turned off", setBoost)
tog(Misc, "Staff Detector", "StaffDetect", "Watches for the game's owner and high group ranks")
dd(Misc, "When Staff Joins", "StaffAction", STAFF_ACTIONS)
Misc:CreateBind({
	Name = "Panic Key", Description = "Turns every automation off at once", CurrentBind = Cfg.PanicKey.Name, Callback = function() end,
	OnChangedCallback = function(k) if typeof(k) == "EnumItem" then Cfg.PanicKey = k end end,
})
button(Misc, "Panic Now", "Turns every automation off at once", panic, true)
head(Misc, "Config")
tog(Misc, "Auto Save Config", "AutoSave", "Saves a moment after any setting changes, and loads on start")
local cfgInput = cfgProfile
Misc:CreateInput({
	Name = "Config Name", Description = "Letters, numbers, - and _ only. Active: " .. cfgProfile,
	PlaceholderText = cfgProfile, CurrentValue = cfgProfile, RemoveTextAfterFocusLost = false,
	Callback = function(t) cfgInput = cleanName(t) or cfgProfile end,
})
button(Misc, "Save Config", nil, function()
	local ok, err = saveCfg(cfgInput)
	if ok then setProfile(cfgInput) end
	notify("Config", ok and ("Saved as " .. cfgInput) or ("Save failed: " .. tostring(err)), ok and "save" or "warning")
end)
button(Misc, "Load Config", nil, function()
	if loadCfg(cfgInput) then
		setProfile(cfgInput)
		refreshUI()
		notify("Config", "Loaded " .. cfgInput, "check_circle")
	else
		notify("Config", "No saved config called " .. cfgInput, "warning")
	end
end)
head(Misc, "Session")
button(Misc, "Server Hop", "Joins another public server", serverHop)
button(Misc, "Rejoin", nil, function() TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP) end)
button(Misc, "Unload Hub", "Stops everything and removes the menu", function()
	panic()
	task.wait(0.2)
	unloadHub()
end, true)

connect(UserInputService.InputBegan, function(input, gpe)
	if gpe or not alive() then return end
	if input.KeyCode == Cfg.PanicKey then
		panic()
		notify("Panic", "Every automation is off", "warning")
	end
end)

-- live info -----------------------------------------------------------------------------------------------
local function fmtTime(sec)
	sec = math.max(0, math.floor(tonumber(sec) or 0))
	if sec >= 3600 then return string.format("%dh %dm", sec // 3600, (sec % 3600) // 60) end
	if sec >= 60 then return string.format("%dm %ds", sec // 60, sec % 60) end
	return sec .. "s"
end
local function youText()
	local z = bestZone()
	return string.format("Coins %s  |  Power %s  |  Level %s/%s (%.0f%%)\nRebirths %d%s  |  World %d (unlocked %s)\nBest training zone: %s (x%s)\nCoin multiplier x%.2f  |  training multiplier x%.2f",
		fmtNum(coins()), fmtNum(attr("TrainingPower")), tostring(attr("Level") or "?"), tostring(attr("MaxLevel") or "?"),
		(tonumber(attr("LevelProgress")) or 0) * 100, rebirths(), attr("CanRebirth") == true and " (READY)" or "",
		currentWorld(), tostring(attr("HighestUnlockedWorld") or attr("UnlockedWorld") or "?"),
		z and tostring(z.Name or z.Id) or "none", z and tostring(zoneMult(z)) or "?",
		tonumber(attr("TotalCoinsMultiplier")) or 1, tonumber(attr("TotalTrainingMultiplier")) or 1)
end
local function sessionText()
	local elapsed = math.max(1, os.clock() - Stats.start)
	local powerGain = math.max(0, (tonumber(attr("TrainingPower")) or 0) - Stats.powerStart)
	return string.format("Time %s  |  throws %d (%.0f/hour, %d perfect)  |  avg cycle %.0fs  |  failed %d\nEarned %s coins (%s/hour)  |  best throw +%s, %s studs\nPower +%s  |  rebirths %d  |  eggs %d  |  planes %d\nCandy %d  |  rings %d  |  rewards claimed %d%s",
		fmtTime(elapsed), Stats.throws, Stats.throws / elapsed * 3600, Stats.perfect, Stats.landed > 0 and Stats.cycleSum / Stats.landed or 0, Stats.failed,
		fmtNum(Stats.earned), fmtNum(Stats.earned / elapsed * 3600), fmtNum(Stats.bestGain), fmtNum(Stats.bestDist),
		fmtNum(powerGain), Stats.rebirths, Stats.hatched, Stats.planes, candyGained(), Stats.rings, Stats.claimed,
		Stats.lastReason and ("  |  last error: " .. Stats.lastReason) or "")
end
local function serverText()
	return string.format("Players %d/%d  |  staff: %s", #Players:GetPlayers(), Players.MaxPlayers, next(staffHere) and staffNames() or "none")
end

task.spawn(function()
	while alive() do
		local m = coins()
		if Stats.lastMoney and m > Stats.lastMoney then Stats.earned += m - Stats.lastMoney end
		Stats.lastMoney = m
		local elapsed = math.max(1, os.clock() - Stats.start)
		setLabel(statusLabel, "Status: " .. Stats.status)
		setLabel(statsLabel, string.format("Throws %d (%.0f/hour) | Earned %s (%s/hour)\nCoins %s | Power %s | Level %s\nRebirths %d%s",
			Stats.throws, Stats.throws / elapsed * 3600, fmtNum(Stats.earned), fmtNum(Stats.earned / elapsed * 3600),
			fmtNum(m), fmtNum(attr("TrainingPower")), tostring(attr("Level") or "?"), rebirths(), attr("CanRebirth") == true and " (rebirth ready)" or ""))
		local lines = { "Last actions:" }
		for i = 1, 3 do lines[#lines + 1] = Stats.log[i] or "-" end
		setLabel(logLabel, table.concat(lines, "\n"))
		local okI, err = pcall(function()
			setLabel(infoYou, youText())
			setLabel(infoSession, sessionText())
			setLabel(infoServer, serverText())
			setLabel(eventLabel, string.format("Your candy: %s\nThis session: +%d", tostring(attr("HalloweenCandy") or 0), candyGained()))
		end)
		if not okI then warn("[Furina Plane] info: " .. tostring(err)) task.wait(4) end
		task.wait(1)
	end
end)

-- handles for an executor console (and for testing)
local Debug = {
	Cfg = Cfg, Stats = Stats, flight = flight, smart = smart, doThrow = doThrow, startTraining = startTraining,
	stopTraining = stopTraining, bestZone = bestZone, zoneCF = zoneCF, launchCF = launchCF, inLaunch = inLaunch,
	hatchOnce = hatchOnce, eggModel = eggModel, foldOnce = foldOnce, buyPaper = buyPaper, equipBestPlane = equipBestPlane,
	bestOwnedPaper = bestOwnedPaper, profile = profile,
	claimPlaytime = claimPlaytime, claimDaily = claimDaily, claimCommunity = claimCommunity,
	doRebirth = doRebirth, perfectHold = perfectHold, perfectHalf = perfectHalf, panic = panic, unload = unloadHub,
	noteLog = noteLog, refreshUI = refreshUI,
	set = function(key, v)
		Cfg[key] = v
		local h = Toggles[key] or Sliders[key]
		if h then pcall(function() h:Set(v) end) end
	end,
	texts = function() return { you = youText(), session = sessionText(), server = serverText() } end,
	showTab = function(name)
		local tabs = { Farm = Farm, Rewards = Rew, Pets = Pets, Planes = Pl, Events = Ev, Player = Plr, Info = Info, Misc = Misc }
		if tabs[name] and Window.SelectTab then pcall(function() Window:SelectTab(tabs[name]) end) end
	end,
}
if not unloaded then getgenv().FurinaPlaneDebug = Debug end
cleanup(function()
	if getgenv().FurinaPlaneDebug == Debug then getgenv().FurinaPlaneDebug = nil end
end)

if Cfg.FPSBoost then setBoost(true) end
if Window.Ready then Window:Ready() end
notify("Furina Hub", "Paper To Plane loaded. Turn on Auto Throw in the Farm tab.", "check_circle")
