--[[
	Furina Hub | Throw Food For Animals (placeId 120219252362013)
	UI: FurinaUI (furina_ui.luau in this repo); falls back to Luna Interface Suite if it cannot load

	Run with loadstring, or through live-reload (STATE). Running it again replaces the old copy.

	Game notes (found by reading the game's own scripts and testing the remotes)
	- Every action is a RemoteFunction in ReplicatedStorage.Remotes that returns { Ok = bool, Reason = string, ... }.
	- Throw: Throw_Start (server checks you stand at the throw line: workspace.StarterArea.CrossLine, else "TooFar"),
	  then Throw_MeterStarted:FireServer(), then Throw_Resolve(meter 0..1). The server times the meter itself, so the
	  value only counts when Resolve arrives at the meter's peak (ThrowMeterMath.HalfPeriod after MeterStarted).
	  Throw_Complete then yields ~5 s server side and gives you the animal. ~1.5 s cooldown follows ("Cooldown").
	  You only need to be at the line for Throw_Start; you can walk away for Resolve and Complete.
	- The game's client starts its own throw when you cross Z < CrossLine.Z, so the hub parks just before the line.
	- Training: Training_Start works within ~14 studs of LocalPlotProps.TrainingArea.TrainingSpot, then keeps giving
	  XP on the server even after you walk away. Training_Bonus (event) offers a tap id; Training_TapBonus(id) doubles reps.
	  You cannot throw while training (Throw_Start returns "Training").
	- Throw Power comes from Level (LevelConfig.ThrowPowerForLevel); training and catches give XP.
	- Shop_Buy(i) / Shop_Equip(i), Stand_Upgrade(), Plot_EquipBest(), Plot_SellAnimal(id), Plot_SellAll(),
	  Offline_Claim(), Shop_ClaimFree() all work from anywhere. Plot_UpgradeFence() needs you near the plot sign.
	- Player data: require(PlayerScripts.Client.Controllers.DataController):Get(key) (Money, Level, Stand, Animals, ...).
	- Throw_Start moves you to the launch point (Z = -45, past the line). An interrupted throw can leave the server
	  answering "Busy"/"Throwing"; Throw_Cancel clears it. Right after Throw_Complete, Training_Start is refused for
	  ~0.5-1 s. While training the server anchors you on the bar (you are not the network owner).
	- Species rarity/income: require(ReplicatedStorage.Config.AnimalEconomy).Get(ModelName). Bought animals have
	  Entry.Bought = true and are never sold by the hub.
	- Two throwers at once (two hub copies, or the hub plus a test script) make the server end each other's sessions
	  ("NoSession"), so the hub keeps a single-copy lock (a BindableEvent in CoreGui).
	- Anti-cheat: none on the client (no kick/ban code in any of the 303 scripts, no metatable hooks). Everything is
	  validated on the server: distance to the line/stand/sign, cooldowns, prices, throw session state, and the meter
	  value must be possible for the time that passed (the server scores the VALUE sent, not the timing).
	  After a normal throw the game itself teleports you to plot.Position + GameConfig.Plot.EntranceOffset.
	  AFKRejoin moves you to a new server after GameConfig.AFKRejoin.IdleSeconds (1080) without input; the value is
	  read every second from a writable table. Admins: require(Config.AdminsConfig).GetIsAdmin(player).

	Layout
	 1. Bootstrap     4. Config files         7. Automation worker
	 2. Services      5. Game access          8. Player, world, misc
	 3. Settings      6. Throw / train / shop 9. UI
]]

------------------------------------------------------------------------------------------------------
-- 1. Bootstrap: one copy at a time.
-- getgenv() is not a reliable place for a "previous copy" handle on every executor (Real hands out views of it
-- that do not always see each other's writes), so the lock is a BindableEvent instance: a new copy fires the old
-- one's lock, the old copy unloads itself, then the new copy puts its own lock in place.
------------------------------------------------------------------------------------------------------
local STATE = STATE -- set by live-reload; nil when run with loadstring
if type(STATE) ~= "table" or type(STATE.alive) ~= "function" then STATE = nil end
local cleanups, conns = {}, {}
local unloaded = false
local function alive() return not unloaded and (not STATE or STATE.alive()) end
-- a copy can be told to unload while it is still starting up (the script run twice in a row); anything it sets up
-- after that moment is torn down straight away, so no orphan menu or listener is left behind
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
	local LOCK = "FurinaAnimalsHubLock"
	local holder = game:GetService("CoreGui")
	local okH = pcall(function() return holder.Name end)
	if not okH then holder = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end
	local old = holder:FindFirstChild(LOCK)
	if old then
		pcall(function() old:Fire() end) -- the running copy unloads itself
		task.wait(0.5)
		pcall(function() old:Destroy() end)
	end
	local lock = Instance.new("BindableEvent")
	lock.Name = LOCK
	lock.Parent = holder
	connect(lock.Event, unloadHub)
	cleanup(function() pcall(function() lock:Destroy() end) end)
end
getgenv().FurinaAnimalsUnload = unloadHub

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
		warn("[Furina Animals] FurinaUI failed to load, using Luna instead: " .. tostring(lib))
	end
	getgenv().ConfirmLuna = true
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/master/source.lua"))()
end)()
local FURINA = UI.IsFurinaUI == true
local noteLog = {} -- last notifications shown (for the debug handle)
local function notify(title, text, icon)
	table.insert(noteLog, 1, string.format("%.0f %s: %s", os.clock(), tostring(title), tostring(text)))
	if #noteLog > 20 then table.remove(noteLog) end
	pcall(function() UI:Notification({ Title = title, Content = text, Icon = icon or "info", ImageSource = "Material" }) end)
end

------------------------------------------------------------------------------------------------------
-- 3. Settings
------------------------------------------------------------------------------------------------------
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Divine", "Celestial", "Eternal", "Cosmic", "Supreme", "Sovereign" }
local RARITY_INDEX = {}
for i, n in ipairs(RARITIES) do RARITY_INDEX[n] = i end

local Cfg = {
	-- farm
	AutoThrow = false, AutoTrain = false, TrainSecs = 20, AutoTap = true, MeterLeadMs = 0,
	Movement = "Fly", FlySpeed = 160, StayAtLine = true,
	UseSuper = true, ResumeFarm = false,
	-- safety
	HumanMeter = true, HumanPace = false, BlockAFKMove = true,
	StaffDetect = true, StaffAction = "Pause farming",
	-- animals
	AutoEquipBest = true, AutoSell = false, SellScope = "Hub catches only", KeepRarity = "Rare", KeepMutated = true,
	NotifyRare = true, NotifyRarity = "Legendary", ActivityNotify = true, SummaryMins = 5,
	-- upgrades
	AutoFood = true, AutoStand = true, AutoFence = false, AutoOffline = true, AutoFree = true,
	-- player
	SpeedOn = false, Speed = 50, JumpOn = false, Jump = 80, InfJump = false, Noclip = false,
	-- misc
	AntiAFK = true, FPSBoost = false, AutoSave = true,
	PanicKey = Enum.KeyCode.Delete,
}
-- Activity notifications without spam: each kind of message has its own cooldown, and any two notifications are
-- at least 4 s apart (a message that would come too soon is dropped, never queued up).
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

local SELL_SCOPES = { "Hub catches only", "Whole backpack" }
local STAFF_ACTIONS = { "Pause farming", "Server hop", "Notify only" }
local MOVEMENTS = { "Fly", "Teleport", "Walk" }
getgenv().FurinaAnimalsCfg = Cfg

------------------------------------------------------------------------------------------------------
-- 4. Config files: <workspace>/FurinaHub/<profile>.json, active profile name in FurinaHub/_profile_animals.txt
------------------------------------------------------------------------------------------------------
local CFG_DIR = "FurinaHub"
local PROFILE_FILE = CFG_DIR .. "/_profile_animals.txt"
local cfgProfile = "animals"
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
	if not RARITY_INDEX[Cfg.KeepRarity] then Cfg.KeepRarity = "Rare" end
	if not RARITY_INDEX[Cfg.NotifyRarity] then Cfg.NotifyRarity = "Epic" end
	if not table.find(SELL_SCOPES, Cfg.SellScope) then Cfg.SellScope = SELL_SCOPES[1] end
	if not table.find(STAFF_ACTIONS, Cfg.StaffAction) then Cfg.StaffAction = STAFF_ACTIONS[1] end
	if not table.find(MOVEMENTS, Cfg.Movement) then Cfg.Movement = MOVEMENTS[1] end
	Cfg.FlySpeed = math.clamp(tonumber(Cfg.FlySpeed) or 160, 40, 400)
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
-- farming never starts by itself on load unless the user asked for that: a saved "on" from an earlier session
-- would otherwise start throwing the moment the script runs, before the user has even seen the menu
if not Cfg.ResumeFarm then
	Cfg.AutoThrow, Cfg.AutoTrain, Cfg.AutoSell = false, false, false
end

------------------------------------------------------------------------------------------------------
-- 5. Game access
------------------------------------------------------------------------------------------------------
local Remotes = RS:WaitForChild("Remotes", 20)
assert(Remotes, "[Furina Animals] ReplicatedStorage.Remotes not found - is this Throw Food For Animals?")

local function safeRequire(inst)
	if not inst then return nil end
	local ok, mod = pcall(require, inst)
	return ok and mod or nil
end

local Controllers = LP:WaitForChild("PlayerScripts"):WaitForChild("Client", 20)
Controllers = Controllers and Controllers:WaitForChild("Controllers", 20)
local DC = safeRequire(Controllers and Controllers:FindFirstChild("DataController"))
local Config = RS:FindFirstChild("Config")
local FoodsConfig = safeRequire(Config and Config:FindFirstChild("FoodsConfig"))
local StandsConfig = safeRequire(Config and Config:FindFirstChild("StandsConfig"))
local FenceConfig = safeRequire(Config and Config:FindFirstChild("FenceConfig"))
local GameConfig = safeRequire(Config and Config:FindFirstChild("GameConfig"))
local AnimalEconomy = safeRequire(Config and Config:FindFirstChild("AnimalEconomy"))
local AreasConfig = safeRequire(Config and Config:FindFirstChild("AreasConfig"))
local LevelConfig = safeRequire(Config and Config:FindFirstChild("LevelConfig"))
local Shared = RS:FindFirstChild("Shared")
local MeterMath = safeRequire(Shared and Shared:FindFirstChild("ThrowMeterMath"))
local ReleaseReach = safeRequire(Shared and Shared:FindFirstChild("ReleaseReach"))
local LuckOdds = safeRequire(Shared and Shared:FindFirstChild("LuckOdds"))
local ClientState = safeRequire(Controllers and Controllers:FindFirstChild("ClientState"))

-- rarity of a species from the game's own economy table (falls back to what a throw told us)
local learnedRarity = {}
local function rarityOf(modelName)
	if AnimalEconomy and AnimalEconomy.Get then
		local ok, e = pcall(AnimalEconomy.Get, modelName)
		if ok and type(e) == "table" and e.Rarity then return e.Rarity end
	end
	return learnedRarity[modelName]
end
-- true while the game's own scripts are busy (its own throw, training, an egg hatch). A flag stuck on for more than
-- 25 s is ignored so a game bug can never freeze the farm.
local busySince
local function gameBusy()
	local b = ClientState ~= nil and ClientState.Busy ~= nil and ClientState.Busy ~= false
	if not b then
		busySince = nil
		return false
	end
	busySince = busySince or os.clock()
	return os.clock() - busySince < 25
end

local function getData(key)
	if not DC then return nil end
	local ok, v = pcall(DC.Get, DC, key)
	if ok then return v end
	return nil
end
local function money() return tonumber(getData("Money")) or 0 end

-- time from Throw_MeterStarted until the meter reaches the top (value 1)
local function meterPeak()
	if MeterMath and MeterMath.HalfPeriod then
		local ok, v = pcall(MeterMath.HalfPeriod)
		if ok and type(v) == "number" and v > 0 and v < 10 then return v end
	end
	local t = GameConfig and GameConfig.Throw or {}
	local base, top = t.MeterBaseSpeed or 0.55, (t.MeterTopSpeedFactor or 2.6) - 1
	if top <= 0 then return 1 / base end
	return math.log(1 + top) / (base * top)
end

local function invoke(name, ...)
	local r = Remotes:FindFirstChild(name)
	if not r then return { Ok = false, Reason = "NoRemote" } end
	local ok, res = pcall(r.InvokeServer, r, ...)
	if not ok then return { Ok = false, Reason = "Error: " .. tostring(res) } end
	if type(res) ~= "table" then return { Ok = false, Reason = "BadResponse" } end
	return res
end
local function fire(name, ...)
	local r = Remotes:FindFirstChild(name)
	if r then pcall(r.FireServer, r, ...) end
end

local function fmtMoney(n)
	n = tonumber(n) or 0
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while math.abs(n) >= 1000 and i < #units do
		n = n / 1000
		i += 1
	end
	if i == 1 then return "$" .. tostring(math.floor(n)) end
	return string.format("$%.2f%s", n, units[i])
end

local function root()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
	local c = LP.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

-- teleport and give the server a moment to see the new position (remotes check distance on the server)
local function tpTo(cf, settle)
	local hrp = root()
	if not hrp then return false end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = cf
	task.wait(settle or 0.3)
	return true
end

local function throwSpot()
	local sa = workspace:FindFirstChild("StarterArea")
	local line = sa and sa:FindFirstChild("CrossLine")
	local z = line and line.Position.Z or (sa and sa.Position.Z + sa.Size.Z / 2) or -40
	local x = sa and sa.Position.X or 0
	local y = (line and line.Position.Y or (sa and sa.Position.Y or 2)) + 3
	-- just before the line: the game's own client only starts a throw once you are past it. Walking stops a little
	-- further back so a small overshoot never carries the character over the line.
	local back = Cfg.Movement == "Walk" and 2.5 or 0.7
	return CFrame.lookAt(Vector3.new(x, y, z + back), Vector3.new(x, y, z - 10))
end

local function myPlot()
	local idx = LP:GetAttribute("PlotIndex")
	local plots = workspace:FindFirstChild("Plots")
	return idx and plots and plots:FindFirstChild(tostring(idx))
end
local function plotCF()
	local p = myPlot()
	if not p then return nil end
	local pos = p:IsA("Model") and p:GetPivot().Position or p.Position
	return CFrame.new(pos + Vector3.new(0, 4, 0))
end
local function trainingSpot()
	local props = workspace:FindFirstChild("LocalPlotProps")
	local area = props and props:FindFirstChild("TrainingArea")
	return area and area:FindFirstChild("TrainingSpot")
end
local function fenceSign()
	local props = workspace:FindFirstChild("LocalPlotProps")
	return props and props:FindFirstChild("PlotUpgradeSign")
end
local function sellPlaceCF()
	local sp = workspace:FindFirstChild("SellPlace")
	if not sp then return nil end
	return CFrame.new(sp:GetPivot().Position + Vector3.new(0, 4, 0))
end
-- where the game itself puts you after every throw (ThrowController: plot.Position + Plot.EntranceOffset, facing +Z)
local function plotEntranceCF()
	local p = myPlot()
	if not p then return nil end
	local pos = (p:IsA("Model") and p:GetPivot().Position or p.Position)
		+ ((GameConfig and GameConfig.Plot and GameConfig.Plot.EntranceOffset) or Vector3.new(0, 3.5, -5))
	return CFrame.lookAt(pos, pos + Vector3.new(0, 0, 1))
end

-- walking (Safe Mode): pathfinding at normal walk speed, so the server only ever sees ordinary movement
local PathfindingService = game:GetService("PathfindingService")
local function walkTo(target, timeout, keepGoing)
	local hum, hrp = humanoid(), root()
	if not hum or not hrp then return false end
	if hrp.Anchored then return false end
	local deadline = os.clock() + (timeout or 40)
	for _ = 1, 3 do -- recompute the path if the character gets stuck
		local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6 })
		local okC = pcall(function() path:ComputeAsync(hrp.Position, target) end)
		local wps = okC and path.Status == Enum.PathStatus.Success and path:GetWaypoints() or { { Position = target } }
		local stuck = false
		for _, wp in ipairs(wps) do
			if not alive() or (keepGoing and not keepGoing()) or os.clock() > deadline then return false end
			if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
			hum:MoveTo(wp.Position)
			local reached = false
			local c = hum.MoveToFinished:Connect(function() reached = true end)
			local t = os.clock()
			while not reached and os.clock() - t < 3 do task.wait() end
			c:Disconnect()
			if not reached then
				stuck = true
				hum.Jump = true
				break
			end
		end
		if (hrp.Position - target).Magnitude < 5 then
			hum:MoveTo(hrp.Position) -- stop exactly here
			return true
		end
		if not stuck then break end
	end
	return (hrp.Position - target).Magnitude < 5
end

-- Fly: a smooth glide along an arc over fences and animals at FlySpeed studs/s. Much faster than walking (a trip
-- across the map takes well under a second) and, unlike an instant teleport, the character really travels there.
local flying = false
local function flyTo(cf, keepGoing)
	local hrp, char = root(), LP.Character
	if not hrp or not char or hrp.Anchored then return false end
	local a, b = hrp.Position, cf.Position
	local dist = (b - a).Magnitude
	if dist < 1 then
		hrp.CFrame = cf
		return true
	end
	local lift = math.clamp(dist * 0.15, 4, 25)
	local c = (a + b) / 2 + Vector3.new(0, lift, 0)
	local duration = math.max(0.12, dist * 1.08 / Cfg.FlySpeed)
	local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local look = flat.Magnitude > 0.1 and flat.Unit or cf.LookVector

	-- no collisions while flying, put back afterwards
	local parts = {}
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide then
			parts[#parts + 1] = p
			p.CanCollide = false
		end
	end
	flying = true
	local t0 = os.clock()
	local ok = true
	while true do
		local t = math.min(1, (os.clock() - t0) / duration)
		local u = 1 - t
		local pos = u * u * a + 2 * u * t * c + t * t * b
		if not hrp.Parent or hrp.Anchored or not alive() or (keepGoing and not keepGoing()) then
			ok = false
			break
		end
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		hrp.CFrame = CFrame.lookAt(pos, pos + look)
		if t >= 1 then break end
		RunService.Heartbeat:Wait()
	end
	if ok and hrp.Parent then
		hrp.CFrame = cf
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	for _, p in ipairs(parts) do
		if p.Parent then p.CanCollide = true end
	end
	flying = false
	return ok
end

-- go somewhere with the chosen movement (Fly / Teleport / Walk); walking falls back to flying if it gets stuck
local function goTo(cf, settle, keepGoing)
	local mode = Cfg.Movement
	if mode == "Walk" then
		if walkTo(cf.Position, 45, keepGoing) then
			task.wait(0.15)
			return true
		end
		if keepGoing and not keepGoing() then return false end
		mode = "Fly"
	end
	if mode == "Fly" then
		if flyTo(cf, keepGoing) then
			task.wait(settle or 0.25)
			return true
		end
		if keepGoing and not keepGoing() then return false end
	end
	return tpTo(cf, settle)
end

-- staff detector: the game's own admin list, the game owner, and high group ranks
local AdminsConfig = safeRequire(Config and Config:FindFirstChild("AdminsConfig"))
local staffHere = {}
local function isStaff(p)
	if p == LP then return false end
	if AdminsConfig and AdminsConfig.GetIsAdmin then
		local ok, v = pcall(AdminsConfig.GetIsAdmin, p)
		if ok and v then return true end
	end
	if game.CreatorType == Enum.CreatorType.User then
		return p.UserId == game.CreatorId
	end
	local ok, rank = pcall(p.GetRankInGroup, p, game.CreatorId)
	return ok and type(rank) == "number" and rank >= 200
end
local function staffPresent() return Cfg.StaffDetect and next(staffHere) ~= nil end
local function staffNames()
	local n = {}
	for p in pairs(staffHere) do n[#n + 1] = p.Name end
	return table.concat(n, ", ")
end

------------------------------------------------------------------------------------------------------
-- 6. Throw, train, shop
------------------------------------------------------------------------------------------------------
local Stats = {
	throws = 0, caught = 0, sold = 0, soldFor = 0, failed = 0, retried = 0, best = nil, bestIdx = 0,
	start = os.clock(), startLevel = tonumber(getData("Level")) or 0, foods = 0, stands = 0, fences = 0,
	status = "Idle", log = {}, byRarity = {}, mutations = 0, newSpecies = 0, supers = 0, lastReason = nil,
	earned = 0, lastMoney = nil, perfect = 0, accSum = 0, cycleSum = 0,
}
local tracked = {} -- AnimalId -> { r = rarity index, t = caught at }: animals the hub caught
local firstSeen = {} -- AnimalId -> when Auto Sell first saw it (whole-backpack mode waits for data to settle)
local inThrow, training = false, false

local function setStatus(s) Stats.status = s end

local function addLog(line)
	table.insert(Stats.log, 1, line)
	if #Stats.log > 6 then table.remove(Stats.log) end
end

local function stopTraining()
	if training or LP:GetAttribute("Training") then
		invoke("Training_Stop")
	end
	training = false
end

local function startTraining()
	if LP:GetAttribute("Training") then
		training = true
		return true
	end
	local spot = trainingSpot()
	if not spot then return false, "no training spot (plot not loaded)" end
	if (tonumber(getData("Stand")) or 0) < 1 then return false, "buy a pull-up stand first" end
	if not root() then return false, "no character" end
	local res
	-- right after a throw the server refuses training for ~0.5-1 s, so retry for a few seconds before giving up
	local offsets = { 8, 4, 8, 4, 8, 4, 8, 4 }
	for i, d in ipairs(offsets) do
		if not alive() then break end
		if i == 1 or (res and res.Reason == "TooFar") then
			setStatus("Going to the pull-up stand")
			goTo(CFrame.new(spot.Position + Vector3.new(d, 3, 0)), 0.3)
		end
		res = invoke("Training_Start")
		if res.Ok then break end
		if res.Reason == "NoStand" or res.Reason == "Stand" then break end
		task.wait(0.5)
	end
	-- (while training the server holds the character on the bar, so it stays there)
	if res and res.Ok then
		training = true
		return true
	end
	return false, res and res.Reason or "unknown"
end

local function onCatch(res, done)
	Stats.caught += 1
	local rIdx = RARITY_INDEX[res.Rarity] or 0
	local name = tostring(res.DisplayName or res.ModelName or "?")
	local id = done and done.AnimalId
	if res.ModelName and res.Rarity then learnedRarity[res.ModelName] = res.Rarity end
	if res.Rarity then Stats.byRarity[res.Rarity] = (Stats.byRarity[res.Rarity] or 0) + 1 end
	if res.Mutation then Stats.mutations += 1 end
	if res.IsNew then Stats.newSpecies += 1 end
	if res.SuperThrow then Stats.supers += 1 end
	if tonumber(res.Accuracy) then
		Stats.accSum += res.Accuracy
		if res.Accuracy >= 0.92 then Stats.perfect += 1 end
	end
	if rIdx > Stats.bestIdx then
		Stats.bestIdx = rIdx
		Stats.best = name .. " (" .. tostring(res.Rarity) .. ")"
	end
	local entry = string.format("%s (%s)%s %.0fm%s", name, tostring(res.Rarity), res.Mutation and (" [" .. tostring(res.Mutation) .. "]") or "",
		tonumber(res.Distance) or 0, res.IsNew and " NEW" or "")
	addLog(entry)
	if id then
		-- caught time lets Auto Sell wait until the animal's data (mutation, placed) has replicated
		tracked[id] = { r = rIdx, t = os.clock() }
	end
	local rareText = name .. " - " .. tostring(res.Rarity) .. (res.Mutation and (" [" .. tostring(res.Mutation) .. "]") or "")
		.. (res.IsNew and " (new)" or "")
	if Cfg.NotifyRare and rIdx >= (RARITY_INDEX[Cfg.NotifyRarity] or 99) then
		if rIdx > (Stats.alertBest or 0) then
			-- best rarity this session: always shown
			Stats.alertBest = rIdx
			notify("Best catch yet!", rareText, "star")
			lastNoteAt = os.clock()
			lastNoteKind["rare" .. rIdx] = os.clock()
		else
			-- the same rarity again: at most once every 45 s, so frequent Epics do not flood the screen
			lastNoteAt = math.min(lastNoteAt, os.clock() - 4)
			notifyAct("rare" .. rIdx, 45, "Rare catch!", rareText, "star")
		end
	elseif res.IsNew then
		notifyAct("newspecies", 10, "New species!", name .. " (" .. tostring(res.Rarity) .. ") added to your Index", "pets")
	end
end

-- one full throw; returns true on a catch
-- Server flow: Throw_Start (at the line) -> it moves you to the launch point -> Throw_MeterStarted -> wait for the
-- meter peak -> Throw_Resolve(1) -> Throw_Complete (yields ~5 s, gives the animal).
local manualThrow = false
local anchoredByHub = false
local function wantThrow() return Cfg.AutoThrow or manualThrow end
local function setAnchor(on)
	local hrp = root()
	if not hrp then return end
	if on then
		if not hrp.Anchored then
			hrp.Anchored = true
			anchoredByHub = true
		end
	elseif anchoredByHub then
		hrp.Anchored = false
		anchoredByHub = false
	end
end
cleanup(function() setAnchor(false) end)

-- Meter timing in seconds, added to the meter peak. Humanized: mostly PERFECT with a natural spread, now and then
-- a GREAT or a GOOD, the way a person actually taps. The meter moves ~1.4 per second near its peak.
local function meterOffset()
	local lead = (Cfg.MeterLeadMs or 0) / 1000
	if not Cfg.HumanMeter then return lead end
	local roll = math.random()
	local ms
	if roll < 0.85 then
		ms = (math.random() * 2 - 1) * 35 -- PERFECT (about 95-100%)
	elseif roll < 0.97 then
		ms = (math.random() < 0.5 and -1 or 1) * (70 + math.random() * 60) -- GREAT
	else
		ms = (math.random() < 0.5 and -1 or 1) * (170 + math.random() * 80) -- GOOD
	end
	return lead + ms / 1000
end

local function doThrow()
	local hrp = root()
	local hum = humanoid()
	if not hrp or not hum or hum.Health <= 0 then return false, "no character" end
	if gameBusy() then
		setStatus("Waiting for the game (" .. tostring(ClientState.Busy) .. ")")
		task.wait(0.5)
		return false, nil
	end
	if LP:GetAttribute("Training") or training then stopTraining() task.wait(0.2) end
	local t0 = os.clock()

	if (hrp.Position - throwSpot().Position).Magnitude > 4 then
		setStatus((Cfg.Movement == "Walk" and "Walking" or Cfg.Movement == "Fly" and "Flying" or "Teleporting") .. " to the throw line")
		goTo(throwSpot(), 0.25, wantThrow)
	end

	local st
	local tooFar = 0
	for _ = 1, 30 do
		if not (alive() and wantThrow()) then break end
		if root() and (root().Position - throwSpot().Position).Magnitude > 4 then
			goTo(throwSpot(), 0.25, wantThrow)
		end
		st = invoke("Throw_Start")
		if st.Ok then break end
		local why = tostring(st.Reason)
		if why == "TooFar" then
			-- the server still sees us somewhere else: usually a training session that has not fully let go of the
			-- character. Close anything left open and place the character again.
			tooFar += 1
			setStatus("Waiting: server position")
			-- usually the server just has not received our last position yet: send it again with a tiny nudge so it
			-- replicates, and only do the full reset below if that keeps failing
			local r0 = root()
			if r0 and not r0.Anchored then
				r0.AssemblyLinearVelocity = Vector3.zero
				r0.CFrame = throwSpot() * CFrame.new(0, 0, (tooFar % 2 == 0) and 0.15 or -0.15)
			end
			if tooFar == 6 or tooFar == 12 then
				Stats.retried += 1
				invoke("Training_Stop")
				training = false
				invoke("Throw_Cancel")
				local r = root()
				if r then
					if r.Anchored and not anchoredByHub then r.Anchored = false end
					r.AssemblyLinearVelocity = Vector3.zero
					r.CFrame = throwSpot() * CFrame.new(0, 0.5, 0)
				end
				task.wait(0.4)
			end
			task.wait(0.2)
		elseif why == "Cooldown" then
			setStatus("Waiting: cooldown")
			task.wait(0.2) -- check often so the next throw starts the moment the cooldown ends
		elseif why == "Training" then
			stopTraining()
			task.wait(0.3)
		elseif why == "Busy" or why == "Throwing" then
			-- a throw is still open on the server (an interrupted one, or the game's own): close it and go again
			Stats.retried += 1
			setStatus("Clearing a stuck throw")
			invoke("Throw_Cancel")
			task.wait(0.6)
		else
			Stats.lastReason = why
			task.wait(1)
			break
		end
	end
	if not (st and st.Ok) then
		if not wantThrow() then return false, nil end -- switched off while waiting: not a failure
		Stats.failed += 1
		Stats.lastReason = st and tostring(st.Reason) or "stopped"
		return false, Stats.lastReason
	end

	-- the server has put us on the launch point, past the line. Anchoring there stops the game's own line watcher
	-- from starting a second throw (it ignores anchored characters, like the real throw cutscene does).
	inThrow = true
	setAnchor(true) -- the real throw holds you still on the launch point too
	setStatus("Throwing")
	fire("Throw_MeterStarted")
	if Cfg.UseSuper and (tonumber(st.Saved) or 0) > 0 then
		local sr = invoke("Throw_UseSuper") -- spends one saved super throw, exactly like the game's button
		if not sr.Ok then Stats.lastReason = "super: " .. tostring(sr.Reason) end
	end
	local meterStart = os.clock()
	task.wait(math.max(0, meterPeak() + meterOffset()))
	-- The server scores the value we send (it only checks it is possible for the time that passed), so the human
	-- meter sends where the bar really is right now - exactly what a person tapping at this moment would send.
	local value = 1
	if Cfg.HumanMeter and MeterMath and MeterMath.Position then
		local okP, pos = pcall(MeterMath.Position, os.clock() - meterStart)
		if okP and type(pos) == "number" then value = math.clamp(pos, 0, 1) end
	end
	local res = invoke("Throw_Resolve", value)
	if not res.Ok then
		invoke("Throw_Cancel")
		inThrow = false
		setAnchor(false)
		Stats.failed += 1
		Stats.lastReason = "resolve: " .. tostring(res.Reason)
		return false, Stats.lastReason
	end
	setStatus("Catching " .. tostring(res.DisplayName or "?") .. " (" .. tostring(res.Rarity) .. ")")
	if not Cfg.StayAtLine then
		-- like the game: the throw ends with you put back at your plot entrance
		setAnchor(false)
		local cf = plotEntranceCF()
		if cf and LP.Character then pcall(function() LP.Character:PivotTo(cf) end) end
	end
	local done = invoke("Throw_Complete")
	inThrow = false
	Stats.throws += 1
	setAnchor(false)
	if Cfg.StayAtLine and root() then
		-- step back behind the line (7 studs) so the next throw can start the moment the cooldown ends
		root().AssemblyLinearVelocity = Vector3.zero
		root().CFrame = throwSpot()
	end
	if not done.Ok then
		invoke("Throw_Cancel")
		Stats.failed += 1
		Stats.lastReason = "complete: " .. tostring(done.Reason)
		return false, Stats.lastReason
	end
	Stats.cycleSum += os.clock() - t0
	onCatch(res, done)
	return true
end

-- economy -------------------------------------------------------------------------------------------
local function isOwned(tbl, i)
	return type(tbl) == "table" and (tbl[i] == true or tbl[tostring(i)] == true)
end

local function buyFoods()
	if not FoodsConfig then return 0 end
	local owned = getData("OwnedFoods") or {}
	local bought = 0
	local n = FoodsConfig.CountAll and FoodsConfig.CountAll() or 0
	for i = 1, n do
		if not isOwned(owned, i) then
			local locked = FoodsConfig.IsLocked and FoodsConfig.IsLocked(i)
			local f = FoodsConfig.GetAny and FoodsConfig.GetAny(i)
			if not locked and f and f.Price then
				if money() < f.Price then break end -- prices only go up
				local r = invoke("Shop_Buy", i)
				if not r.Ok then break end
				bought += 1
				Stats.foods += 1
				owned = getData("OwnedFoods") or owned
				task.wait(0.15)
			end
		end
	end
	-- equip the best food owned
	local best = 0
	owned = getData("OwnedFoods") or {}
	for i = n, 1, -1 do
		if isOwned(owned, i) then
			best = i
			break
		end
	end
	if best > 0 and tonumber(getData("EquippedFood")) ~= best then invoke("Shop_Equip", best) end
	if bought > 0 then
		local f = FoodsConfig.GetAny and FoodsConfig.GetAny(best)
		notifyAct("food", 5, "New food", "Bought and equipped " .. (f and tostring(f.Name) or ("food #" .. best))
			.. (bought > 1 and (" (+" .. (bought - 1) .. " more)") or "") .. ". Rarer animals from now on.", "restaurant")
	end
	return bought
end

local function upgradeStands()
	if not StandsConfig then return 0 end
	local done = 0
	for _ = 1, 10 do
		local cur = tonumber(getData("Stand")) or 0
		if cur >= StandsConfig.Count() then break end
		local nxt = StandsConfig.Get(cur + 1)
		if not nxt or not nxt.Price or money() < nxt.Price then break end
		local r = invoke("Stand_Upgrade")
		if not r.Ok then break end
		done += 1
		Stats.stands += 1
		task.wait(0.15)
	end
	if done > 0 then
		local s = StandsConfig.Get(tonumber(getData("Stand")) or 0)
		notifyAct("stand", 5, "Stand upgraded", "Now using " .. (s and tostring(s.Name) or "a better stand")
			.. (s and s.XpPerRep and (" (" .. tostring(s.XpPerRep) .. " XP per rep)") or ""), "fitness_center")
	end
	return done
end

local function upgradeFence()
	if not FenceConfig or not FenceConfig.Upgrades then return false end
	local lvl = tonumber(getData("FenceLevel")) or 0
	local up = FenceConfig.Upgrades[lvl + 1]
	if not up or not up.Price or money() < up.Price then return false end
	local r = invoke("Plot_UpgradeFence")
	if not r.Ok and r.Reason == "TooFar" then
		local sign = fenceSign()
		if not sign or not root() then return false end
		goTo(CFrame.new(sign:GetPivot().Position + Vector3.new(0, 2, 4)), 0.35)
		r = invoke("Plot_UpgradeFence")
	end
	if r.Ok then
		Stats.fences += 1
		notifyAct("fence", 5, "Fence upgraded", "Your plot now holds " .. tostring(up.Slots or "more") .. " animals", "fence")
	end
	return r.Ok == true
end

local function equipBest()
	return invoke("Plot_EquipBest")
end

-- Sells backpack animals (not on the plot) below the keep rarity. Never sells: animals on the plot, bought animals,
-- mutated ones (when Never Sell Mutated is on), species whose rarity is unknown, or anything seen less than 4 s ago
-- (its placement and mutation may not have replicated yet).
local function sellable(id, a, now)
	if type(a) ~= "table" or a.Placed or a.Bought then return false end
	if Cfg.KeepMutated and a.Mutation then return false end
	local info = tracked[id]
	if Cfg.SellScope ~= "Whole backpack" and not info then return false end
	local seen = info and info.t or firstSeen[id]
	if not seen then
		firstSeen[id] = now
		return false
	end
	if now - seen < 4 then return false end
	local r = info and info.r or RARITY_INDEX[rarityOf(a.ModelName) or ""]
	if not r or r == 0 then return false end
	return r < (RARITY_INDEX[Cfg.KeepRarity] or 3)
end

local function autoSell()
	local animals = getData("Animals") or {}
	local now = os.clock()
	for id in pairs(tracked) do
		if animals[id] == nil and now - tracked[id].t > 10 then tracked[id] = nil end
	end
	for id in pairs(firstSeen) do
		if animals[id] == nil then firstSeen[id] = nil end
	end
	local n = 0
	for id, a in pairs(animals) do
		if not alive() or n >= 25 then break end
		if sellable(id, a, now) then
			local r = invoke("Plot_SellAnimal", id)
			if r.Ok then
				Stats.sold += 1
				Stats.soldFor += tonumber(r.Money) or 0
				tracked[id] = nil
				firstSeen[id] = nil
			end
			n += 1
			task.wait(0.1)
		end
	end
	-- one combined "sold" message at most once a minute
	if Stats.sold > (Stats.soldNoted or 0) then
		local cnt, amt = Stats.sold - (Stats.soldNoted or 0), Stats.soldFor - (Stats.soldForNoted or 0)
		if notifyAct("sell", 60, "Auto Sell", string.format("Sold %d weak animal%s for %s", cnt, cnt == 1 and "" or "s", fmtMoney(amt)), "sell") then
			Stats.soldNoted, Stats.soldForNoted = Stats.sold, Stats.soldFor
		end
	end
	return n
end

-- what Auto Sell would sell right now (for the preview button)
local function sellPreview()
	local animals = getData("Animals") or {}
	local now = os.clock()
	local count, names = 0, {}
	for id, a in pairs(animals) do
		local info = tracked[id]
		local seenOk = (info and now - info.t >= 4) or (firstSeen[id] and now - firstSeen[id] >= 4) or (not info and Cfg.SellScope == "Whole backpack")
		if seenOk and type(a) == "table" and not a.Placed and not a.Bought and not (Cfg.KeepMutated and a.Mutation)
			and (Cfg.SellScope == "Whole backpack" or info) then
			local r = info and info.r or RARITY_INDEX[rarityOf(a.ModelName) or ""]
			if r and r > 0 and r < (RARITY_INDEX[Cfg.KeepRarity] or 3) then
				count += 1
				names[a.ModelName] = (names[a.ModelName] or 0) + 1
			end
		end
	end
	local parts = {}
	for k, v in pairs(names) do parts[#parts + 1] = k .. " x" .. v end
	table.sort(parts)
	return count, table.concat(parts, ", ")
end

------------------------------------------------------------------------------------------------------
-- 7. Automation worker: one thread runs every game action in order, so remotes never overlap
------------------------------------------------------------------------------------------------------
local lastEconomy, lastEquip, lastOffline = 0, 0, 0
local trainUntil = 0

-- Equip-best, selling and claims never touch the throw, so they run on their own thread and cost no throw time.
-- Buying/equipping food (changing food mid-throw ends the throw), the stand and the fence (it needs you at the sign)
-- run between throws instead; checking whether anything is affordable is local and instant.
local econBusy = false
local function backgroundEconomy(afterCatchToo)
	if econBusy then return end
	econBusy = true
	task.spawn(function()
		local now = os.clock()
		pcall(function()
			if afterCatchToo or (Cfg.AutoEquipBest and now - lastEquip > 20) then
				if Cfg.AutoEquipBest then
					lastEquip = now
					equipBest()
				end
			end
			if Cfg.AutoSell then autoSell() end
			if now - lastOffline > 60 then
				lastOffline = now
				if Cfg.AutoOffline then invoke("Offline_Claim") end
				if Cfg.AutoFree then invoke("Shop_ClaimFree") end
			end
		end)
		econBusy = false
	end)
end

local function economy(force)
	local now = os.clock()
	if not force and now - lastEconomy < 3 then return end
	lastEconomy = now
	backgroundEconomy(false)
	if inThrow then return end
	if Cfg.AutoFood then pcall(buyFoods) end
	if Cfg.AutoStand then pcall(upgradeStands) end
	if Cfg.AutoFence then pcall(upgradeFence) end
end

local function afterCatch()
	lastEconomy = os.clock()
	backgroundEconomy(true)
end

local failStreak = 0
local sinceBreak, nextBreak = 0, math.random(18, 35)
-- Human Pace: a short random pause after each throw and a longer break every 18-35 throws, so the throw log does
-- not look like a metronome. Returns early if farming is switched off.
local function humanPause()
	if not Cfg.HumanPace then return end
	local function wait(secs, label)
		local untilT = os.clock() + secs
		while alive() and Cfg.AutoThrow and os.clock() < untilT do
			if label then setStatus(string.format("%s (%ds)", label, math.ceil(untilT - os.clock()))) end
			task.wait(0.25)
		end
	end
	sinceBreak += 1
	if sinceBreak >= nextBreak then
		sinceBreak, nextBreak = 0, math.random(18, 35)
		local secs = 20 + math.random() * 55
		notifyAct("break", 30, "Short break", string.format("Human Pace: resting %ds, then throwing again", math.floor(secs)), "coffee")
		wait(secs, "Taking a short break")
	else
		wait(1 + math.random() * 2.5)
	end
end

local function throwStep()
	local caught, why = doThrow()
	if caught then
		failStreak = 0
		afterCatch()
		humanPause()
	elseif why then
		failStreak += 1
		setStatus("Throw failed: " .. tostring(why) .. (failStreak > 2 and " (backing off)" or ""))
		if failStreak == 3 then
			notifyAct("fail", 60, "Throws are failing", "Last reason: " .. tostring(why) .. ". The hub keeps retrying.", "warning")
		end
		task.wait(failStreak > 2 and math.min(10, failStreak) or 0.5)
	end
	return caught
end

task.spawn(function()
	while alive() do
		local ok, err = pcall(function()
			local hum = humanoid()
			if not hum or hum.Health <= 0 or not root() then
				setStatus("Waiting for character")
				task.wait(1)
				return
			end
			if manualThrow then -- a "Throw Once" press is running: leave the character alone until it finishes
				task.wait(0.3)
				return
			end
			if staffPresent() and Cfg.StaffAction == "Pause farming" and (Cfg.AutoThrow or Cfg.AutoTrain or Cfg.AutoSell) then
				if training or LP:GetAttribute("Training") then stopTraining() end
				setStatus("Paused: staff in server (" .. staffNames() .. ")")
				task.wait(1)
				return
			end
			economy(false)

			if Cfg.AutoThrow and Cfg.AutoTrain then
				-- alternate: train for TrainSecs, then one throw
				if os.clock() < trainUntil then
					if not LP:GetAttribute("Training") then
						local okT = startTraining()
						if not okT then trainUntil = 0 end
					end
					setStatus(string.format("Training (%ds left)", math.max(0, math.ceil(trainUntil - os.clock()))))
					task.wait(0.5)
				else
					throwStep()
					trainUntil = os.clock() + Cfg.TrainSecs
				end
			elseif Cfg.AutoThrow then
				throwStep()
			elseif Cfg.AutoTrain then
				if not LP:GetAttribute("Training") then
					setStatus("Starting training")
					local okT, why = startTraining()
					if not okT then
						setStatus("Training failed: " .. tostring(why))
						task.wait(2)
					end
				else
					setStatus("Training")
				end
				task.wait(0.5)
			else
				if training then stopTraining() end
				setStatus("Idle")
				task.wait(0.3)
			end
		end)
		if not ok then
			warn("[Furina Animals] worker: " .. tostring(err))
			if inThrow then invoke("Throw_Cancel") end
			inThrow = false
			setAnchor(false)
			task.wait(1)
		end
		task.wait()
	end
end)

-- training tap bonus (x2 reps): answer every offer the server sends
local bonusRemote = Remotes:FindFirstChild("Training_Bonus")
if bonusRemote then
	connect(bonusRemote.OnClientEvent, function(id)
		if not alive() or not Cfg.AutoTap then return end
		if not LP:GetAttribute("Training") then return end
		task.spawn(function()
			task.wait(0.1)
			invoke("Training_TapBonus", id)
		end)
	end)
end

cleanup(function()
	if inThrow then pcall(invoke, "Throw_Cancel") end
	if training then pcall(invoke, "Training_Stop") end
end)

------------------------------------------------------------------------------------------------------
-- 8. Player, world, misc
------------------------------------------------------------------------------------------------------
local defaultSpeed, defaultJump = 16, 50
-- speed, jump, infinite jump and noclip are the easiest things for a server or a watching admin to notice, so they
-- do nothing while staff are in the server
local function modsAllowed() return not staffPresent() end
local speedApplied, jumpApplied = false, false
connect(RunService.Heartbeat, function()
	if not alive() then return end
	local hum = humanoid()
	if not hum then return end
	local allowed = modsAllowed()
	if Cfg.SpeedOn and allowed then
		if hum.WalkSpeed > 0 and hum.WalkSpeed ~= Cfg.Speed then hum.WalkSpeed = Cfg.Speed end
		speedApplied = true
	elseif speedApplied then
		speedApplied = false
		if hum.WalkSpeed > 0 then hum.WalkSpeed = defaultSpeed end
	end
	if Cfg.JumpOn and allowed then
		hum.UseJumpPower = true
		if hum.JumpPower ~= Cfg.Jump then hum.JumpPower = Cfg.Jump end
		jumpApplied = true
	elseif jumpApplied then
		jumpApplied = false
		hum.JumpPower = defaultJump
	end
end)
local function restoreMovement()
	local hum = humanoid()
	if not hum then return end
	if not Cfg.SpeedOn then hum.WalkSpeed = defaultSpeed end
	if not Cfg.JumpOn then hum.JumpPower = defaultJump end
end
cleanup(function()
	local hum = humanoid()
	if hum then
		hum.WalkSpeed = defaultSpeed
		hum.JumpPower = defaultJump
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
		for _, p in ipairs(c:GetDescendants()) do
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

-- anti afk: answers Roblox's idle kick and the game's AFK rejoin timer
connect(LP.Idled, function()
	if not alive() or not Cfg.AntiAFK then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end)

-- fps boost (restored on turn off / unload)
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
	local data = HttpService:JSONDecode(body)
	for _, s in ipairs(data.data or {}) do
		if s.id ~= game.JobId and (s.playing or 0) < (s.maxPlayers or 0) then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LP)
			return
		end
	end
	notify("Server Hop", "No other open server found", "warning")
end

-- the game's own AFK system (AFKRejoin) moves you to a new server after 18 minutes without keyboard/mouse input,
-- which would end the farm. Its timer reads GameConfig.AFKRejoin.IdleSeconds every second, so raising it in memory
-- stops the move; the original value comes back when this is turned off or the hub unloads.
local afkCfg = GameConfig and GameConfig.AFKRejoin
local afkOriginal = afkCfg and afkCfg.IdleSeconds
local function applyAFKBlock()
	if not afkCfg or not afkOriginal then return end
	pcall(function() afkCfg.IdleSeconds = Cfg.BlockAFKMove and 1e9 or afkOriginal end)
end
applyAFKBlock()
cleanup(function()
	if afkCfg and afkOriginal then pcall(function() afkCfg.IdleSeconds = afkOriginal end) end
end)

-- staff watcher
local function onStaffJoined(p)
	if not Cfg.StaffDetect then return end
	notify("Staff joined", p.Name .. " is a game admin/owner. " .. (Cfg.StaffAction == "Pause farming" and "Farming paused until they leave."
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

-- auto save a moment after any setting changes
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
-- 9. UI
------------------------------------------------------------------------------------------------------
if unloaded then return end -- a newer copy already replaced this one while it was starting up
local Window = UI:CreateWindow({
	Name = "Furina Hub",
	Subtitle = "Throw Food For Animals",
	LogoID = "6031097225",
	LoadingEnabled = false,
	ConfigSettings = { ConfigFolder = "FurinaHub" },
	KeySystem = false,
})
cleanup(function() pcall(function() UI:Destroy() end) end)

local Toggles, Sliders = {}, {}
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
local function sld(t, name, key, lo, hi, cb)
	Sliders[key] = t:CreateSlider({
		Name = name, Range = { lo, hi }, Increment = 1, CurrentValue = math.clamp(Cfg[key], lo, hi),
		Callback = function(v) Cfg[key] = v if cb then cb(v) end end,
	})
end
local Dropdowns = {}
local function dd(t, name, key, options, desc)
	Dropdowns[key] = t:CreateDropdown({
		Name = name, Description = desc, Options = options, CurrentOption = { Cfg[key] }, MultipleOptions = false,
		Callback = function(o)
			o = type(o) == "table" and o[1] or o
			if o ~= nil then Cfg[key] = o end
		end,
	})
end
local function bind(t, name, desc, key)
	t:CreateBind({
		Name = name, Description = desc, CurrentBind = Cfg[key].Name, Callback = function() end,
		OnChangedCallback = function(k) if typeof(k) == "EnumItem" then Cfg[key] = k end end,
	})
end
local function button(t, name, desc, fn, danger)
	t:CreateButton({ Name = name, Description = desc, Danger = danger, Callback = function() task.spawn(fn) end })
end
local function refreshUI()
	for key, t in pairs(Toggles) do pcall(function() t:Set(Cfg[key]) end) end
	for key, s in pairs(Sliders) do pcall(function() s:Set(Cfg[key]) end) end
	for key, d in pairs(Dropdowns) do pcall(function() d:Set(Cfg[key]) end) end
end
-- a label keeps the height it was built with, so the placeholder gets as many lines as the live text
local function infoLabel(t, lines, style)
	return t:CreateLabel({ Text = string.rep("-\n", lines - 1) .. "-", Style = style or 2 })
end
local function setLabel(l, text) pcall(function() l:Set(text) end) end

local function panic()
	for _, k in ipairs({ "AutoThrow", "AutoTrain", "AutoSell", "AutoFence", "SpeedOn", "JumpOn", "InfJump", "Noclip" }) do
		Cfg[k] = false
		if Toggles[k] then pcall(function() Toggles[k]:Set(false) end) end
	end
	task.spawn(stopTraining)
	restoreMovement()
end

-- Farm ------------------------------------------------------------------------------------------------
local Farm = tab("Farm", "bolt")
local statusLabel = infoLabel(Farm, 1, 1)
local statsLabel = infoLabel(Farm, 3)
local logLabel = infoLabel(Farm, 4)
head(Farm, "Throwing")
local function farmNote()
	local what = Cfg.AutoThrow and Cfg.AutoTrain and ("throwing, with " .. Cfg.TrainSecs .. " s of training between throws")
		or Cfg.AutoThrow and "throwing" or Cfg.AutoTrain and "training" or nil
	lastNoteKind.farm = nil -- the user just pressed the switch, so always answer it
	notifyAct("farm", 0, what and "Auto farm on" or "Auto farm off", what and ("Now " .. what .. ".") or "Throwing and training stopped.", what and "play_arrow" or "pause")
end
tog(Farm, "Auto Throw", "AutoThrow", "Throws for you with a PERFECT meter and skips the whole cutscene. The server allows one throw every ~10-12 s (it waits for the food to land), and the hub starts the next one the moment it can", farmNote)
tog(Farm, "Stay At The Throw Line", "StayAtLine", "Fastest: waits at the line between throws. Off = goes back to your plot entrance after each throw, like the game does")
tog(Farm, "Use Saved Super Throws", "UseSuper", "If you own saved super throws, spends one on each throw like the in-game button does")
head(Farm, "Movement")
dd(Farm, "Move By", "Movement", MOVEMENTS, "Fly = fast smooth glide over everything (default). Teleport = instant. Walk = normal walking, slowest")
sld(Farm, "Fly Speed (studs/s)", "FlySpeed", 40, 400)
head(Farm, "Training")
tog(Farm, "Auto Train", "AutoTrain", "Starts pull-up training from anywhere (gains XP and Throw Power). With Auto Throw on, it trains between throws", farmNote)
sld(Farm, "Train Seconds Between Throws", "TrainSecs", 5, 120)
tog(Farm, "Auto Tap Bonus", "AutoTap", "Claims every x2 training bonus the moment it appears")
head(Farm, "Session")
tog(Farm, "Resume Farming On Load", "ResumeFarm", "Off = Auto Throw, Auto Train and Auto Sell always start switched off when the hub loads")
head(Farm, "Notifications")
tog(Farm, "Activity Notifications", "ActivityNotify", "Tells you what the farm is doing without spam: farm on/off, new food/stand/fence, new area, every 10 levels, auto-sell results (once a minute at most), failures and breaks")
sld(Farm, "Summary Every (minutes, 0 = off)", "SummaryMins", 0, 30)
button(Farm, "Throw Once", "One perfect throw right now", function()
	if Cfg.AutoThrow then return notify("Throw", "Auto Throw is already running", "info") end
	if manualThrow or inThrow then return end
	manualThrow = true
	local ok, why = doThrow()
	manualThrow = false
	if ok then afterCatch() elseif why then notify("Throw", "Failed: " .. tostring(why), "warning") end
end)

-- Animals -----------------------------------------------------------------------------------------------
local Animals = tab("Animals", "casino")
head(Animals, "Plot")
tog(Animals, "Auto Equip Best", "AutoEquipBest", "Puts your best animals on the plot after every catch")
button(Animals, "Equip Best Now", nil, function()
	local r = equipBest()
	notify("Plot", r.Ok and ("Placed " .. tostring(r.Placed or 0) .. " animal(s)") or ("Failed: " .. tostring(r.Reason)), r.Ok and "check_circle" or "warning")
end)
head(Animals, "Selling")
tog(Animals, "Auto Sell Weak Animals", "AutoSell", "Sells backpack animals (not on your plot) below the keep rarity. Plot animals, bought animals and (optionally) mutated ones are never sold")
dd(Animals, "Sell From", "SellScope", SELL_SCOPES, "Hub catches only = only animals the hub caught this session. Whole backpack = every animal in your backpack")
dd(Animals, "Keep Rarity And Above", "KeepRarity", RARITIES)
tog(Animals, "Never Sell Mutated", "KeepMutated", "Gold, Ruby, Diamond and other mutations are always kept")
button(Animals, "Preview Auto Sell", "Shows what Auto Sell would sell right now, without selling", function()
	local n, list = sellPreview()
	notify("Auto Sell preview", n == 0 and "Nothing would be sold" or (n .. " animal(s): " .. list), "info")
end)
button(Animals, "Sell Weak Animals Now", "Runs Auto Sell once with the settings above", function()
	local before, beforeMoney = Stats.sold, Stats.soldFor
	autoSell()
	local n = Stats.sold - before
	notify("Sell", n > 0 and ("Sold " .. n .. " for " .. fmtMoney(Stats.soldFor - beforeMoney)) or "Nothing to sell (new animals wait 4 s)", "check_circle")
end)
button(Animals, "Sell Entire Backpack", "Uses the game's SELL ALL: every animal not on your plot (bought animals are never sold)", function()
	local r = invoke("Plot_SellAll")
	if r.Ok then
		Stats.sold += tonumber(r.Count) or 0
		Stats.soldFor += tonumber(r.Money) or 0
		notify("Sell", "Sold " .. tostring(r.Count or "?") .. " animal(s) for " .. fmtMoney(r.Money or 0), "check_circle")
	else
		notify("Sell", "Nothing sold: " .. tostring(r.Reason), "info")
	end
end, true)
head(Animals, "Alerts")
tog(Animals, "Rare Catch Alert", "NotifyRare")
dd(Animals, "Alert From Rarity", "NotifyRarity", RARITIES)

-- Upgrades ----------------------------------------------------------------------------------------------
local Upg = tab("Upgrades", FURINA and "power" or "trending_up")
head(Upg, "Automatic")
tog(Upg, "Auto Buy Best Food", "AutoFood", "Buys every food you can afford, cheapest first, and equips the best one. Better food = rarer animals")
tog(Upg, "Auto Upgrade Stand", "AutoStand", "Upgrades the pull-up stand whenever you can afford it (more XP per rep)")
tog(Upg, "Auto Upgrade Fence", "AutoFence", "Buys plot fence upgrades (more slots). Teleports to the sign for a moment")
tog(Upg, "Auto Claim Offline Cash", "AutoOffline")
tog(Upg, "Auto Claim Free Reward", "AutoFree")
head(Upg, "Now")
button(Upg, "Buy Foods Now", nil, function()
	local n = buyFoods()
	notify("Food", n > 0 and ("Bought " .. n .. " food(s)") or "Nothing affordable", "check_circle")
end)
button(Upg, "Upgrade Stand Now", nil, function()
	local n = upgradeStands()
	notify("Stand", n > 0 and ("Upgraded " .. n .. " time(s)") or "Not enough money", "check_circle")
end)
button(Upg, "Upgrade Fence Now", nil, function()
	notify("Fence", upgradeFence() and "Upgraded" or "Not enough money (or max level)", "check_circle")
end)
button(Upg, "Claim Offline Cash", nil, function()
	local r = invoke("Offline_Claim")
	notify("Offline", r.Ok and "Claimed" or ("Nothing to claim (" .. tostring(r.Reason) .. ")"), "info")
end)

-- Safety -------------------------------------------------------------------------------------------------
local Safe = tab("Safety", FURINA and "hitbox" or "shield")
local safetyLabel = infoLabel(Safe, 3, 1)
head(Safe, "Look like a normal player")
tog(Safe, "Human Meter", "HumanMeter", "Mostly PERFECT with a natural spread instead of 99.8% every single throw. Costs nothing (under 1 stud of distance)")
tog(Safe, "Human Pace", "HumanPace", "Slower: short random pauses between throws and a 20-75 s break every 18-35 throws")
head(Safe, "Protection")
tog(Safe, "Block AFK Server Move", "BlockAFKMove", "The game moves you to a new server after 18 min without input, which would end the farm. This stops that", applyAFKBlock)
tog(Safe, "Staff Detector", "StaffDetect", "Watches for the game's admins (from the game's own admin list), the owner and high group ranks")
dd(Safe, "When Staff Joins", "StaffAction", STAFF_ACTIONS, "Pause farming resumes by itself when they leave")
Safe:CreateLabel({ Text = "This game has no client anti-cheat: every check is on the server (distance to the line, cooldowns, the meter value, prices). The hub stays inside all of them. For the least attention use Move By = Walk, Stay At The Throw Line off and Human Pace on. The real risks are admins watching, players reporting leaderboard stats, and Roblox's own executor detection, which no script can control.", Style = 2 })

-- Info ---------------------------------------------------------------------------------------------------
local Info = tab("Info", "visibility")
head(Info, "Progress")
local infoProgress = infoLabel(Info, 4)
head(Info, "Money")
local infoMoney = infoLabel(Info, 3)
head(Info, "Next upgrades")
local infoShop = infoLabel(Info, 3)
head(Info, "Animals")
local infoAnimals = infoLabel(Info, 3)
head(Info, "This session")
local infoSession = infoLabel(Info, 4)
head(Info, "Server")
local infoServer = infoLabel(Info, 1)

-- Player -------------------------------------------------------------------------------------------------
local Plr = tab("Player", "directions_run")
head(Plr, "Movement")
Plr:CreateLabel({ Text = "Speed, jump, infinite jump and noclip switch themselves off while staff are in the server.", Style = 2 })
tog(Plr, "Speed", "SpeedOn", nil, function(v) if not v then restoreMovement() end end)
sld(Plr, "Walk Speed", "Speed", 16, 200)
tog(Plr, "Jump Power", "JumpOn", nil, function(v) if not v then restoreMovement() end end)
sld(Plr, "Jump", "Jump", 50, 250)
tog(Plr, "Infinite Jump", "InfJump")
tog(Plr, "Noclip", "Noclip")
head(Plr, "Travel")
-- buttons always travel fast: fly (or teleport if that is the chosen movement), never walk
local function travel(cf)
	if not cf then return end
	if Cfg.Movement == "Teleport" or not flyTo(cf) then tpTo(cf, 0) end
end
button(Plr, "My Plot", nil, function() travel(plotEntranceCF() or plotCF()) end)
button(Plr, "Throw Line", nil, function() travel(throwSpot()) end)
button(Plr, "Pull-Up Stand", nil, function()
	local s = trainingSpot()
	if s then travel(CFrame.new(s.Position + Vector3.new(6, 3, 0))) end
end)
button(Plr, "Sell Place", nil, function() travel(sellPlaceCF()) end)

-- Misc ---------------------------------------------------------------------------------------------------
local Misc = tab("Misc", "settings")
head(Misc, "General")
tog(Misc, "Anti AFK", "AntiAFK")
tog(Misc, "FPS Boost", "FPSBoost", "No shadows, no post effects, lowest quality. Restored when turned off", setBoost)
bind(Misc, "Panic Key", "Turns every automation off at once", "PanicKey")
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

-- keybinds
connect(UserInputService.InputBegan, function(input, gpe)
	if gpe or not alive() then return end
	if input.KeyCode == Cfg.PanicKey then
		panic()
		notify("Panic", "Every automation is off", "warning")
	end
end)

-- live info ----------------------------------------------------------------------------------------------
local function fmtTime(sec)
	sec = math.max(0, math.floor(tonumber(sec) or 0))
	if sec >= 86400 then return string.format("%dd %dh", sec // 86400, (sec % 86400) // 3600) end
	if sec >= 3600 then return string.format("%dh %dm", sec // 3600, (sec % 3600) // 60) end
	if sec >= 60 then return string.format("%dm %ds", sec // 60, sec % 60) end
	return sec .. "s"
end
local function call(f, ...)
	if type(f) ~= "function" then return nil end
	local ok, a, b = pcall(f, ...)
	if ok then return a, b end
	return nil
end
local function income() return tonumber(LP:GetAttribute("IncomeRate")) or 0 end
local function eta(price)
	if not price then return "max" end
	local m = money()
	if m >= price then return "affordable now" end
	local inc = income()
	if inc <= 0 then return "needs " .. fmtMoney(price - m) end
	return "in " .. fmtTime((price - m) / inc)
end

local function progressText()
	local lvl = tonumber(getData("Level")) or 1
	local xp = tonumber(getData("Xp")) or 0
	local need = LevelConfig and call(LevelConfig.XpForLevel, lvl) or nil
	local reach = ReleaseReach and call(ReleaseReach.Distance, lvl) or nil
	local power = LevelConfig and call(LevelConfig.ThrowPowerForLevel, lvl) or nil
	local areaIdx = ReleaseReach and call(ReleaseReach.AreaForLevel, lvl) or nil
	local list = AreasConfig and AreasConfig.List or {}
	local area = areaIdx and list[areaIdx]
	local nextArea = areaIdx and list[areaIdx + 1]
	local nextLine = "Last area reached!"
	if nextArea and nextArea.StartDistance and ReleaseReach then
		local target = lvl
		while target < lvl + 5000 and (call(ReleaseReach.Distance, target) or math.huge) < nextArea.StartDistance + 1 do target += 1 end
		nextLine = string.format("Next area: %s at level %d (%d levels to go)", tostring(nextArea.Name), target, target - lvl)
	end
	local elapsed = math.max(1, os.clock() - Stats.start)
	return string.format("Level %d  |  XP %s / %s%s  |  +%d levels this session (%.0f/hour)\nThrow power %s  |  reach %s studs\nArea: %s (%s of %d)\n%s",
		lvl, tostring(xp), tostring(need or "?"), need and string.format(" (%.0f%%)", math.clamp(xp / need * 100, 0, 100)) or "",
		math.max(0, lvl - Stats.startLevel), math.max(0, lvl - Stats.startLevel) / elapsed * 3600,
		tostring(power or "?"), tostring(reach or "?"), area and tostring(area.Name) or "?", tostring(areaIdx or "?"), #list, nextLine)
end

local function moneyText()
	local elapsed = math.max(1, os.clock() - Stats.start)
	return string.format("Money %s  |  income %s/s (%s/hour)\nEarned this session %s (%s/hour)\nSold animals for %s (%d sold)",
		fmtMoney(money()), fmtMoney(income()), fmtMoney(income() * 3600),
		fmtMoney(Stats.earned), fmtMoney(Stats.earned / elapsed * 3600), fmtMoney(Stats.soldFor), Stats.sold)
end

local function shopText()
	local food, stand, fence = "Food: ?", "Stand: ?", "Fence: ?"
	if FoodsConfig then
		local eq = tonumber(getData("EquippedFood")) or 0
		local cur = call(FoodsConfig.GetAny, eq)
		local owned, nxt = getData("OwnedFoods") or {}, nil
		for i = 1, (call(FoodsConfig.CountAll) or 0) do
			if not isOwned(owned, i) and not call(FoodsConfig.IsLocked, i) then
				nxt = call(FoodsConfig.GetAny, i)
				break
			end
		end
		food = string.format("Food: %s (#%d)  ->  next %s", cur and tostring(cur.Name) or "?", eq,
			nxt and string.format("%s %s, %s", tostring(nxt.Name), fmtMoney(nxt.Price), eta(nxt.Price)) or "all bought")
	end
	if StandsConfig then
		local idx = tonumber(getData("Stand")) or 0
		local cur = idx > 0 and call(StandsConfig.Get, idx) or nil
		local nxt = idx < (call(StandsConfig.Count) or 0) and call(StandsConfig.Get, idx + 1) or nil
		stand = string.format("Stand: %s (#%d, %s XP/rep)  ->  next %s", cur and tostring(cur.Name) or "none", idx, cur and tostring(cur.XpPerRep) or "0",
			nxt and string.format("%s %s, %s", tostring(nxt.Name), fmtMoney(nxt.Price), eta(nxt.Price)) or "max")
	end
	if FenceConfig then
		local lvl = tonumber(getData("FenceLevel")) or 0
		local slots = call(FenceConfig.SlotsFor, lvl)
		local up = FenceConfig.Upgrades and FenceConfig.Upgrades[lvl + 1]
		fence = string.format("Fence: level %d, %s slots  ->  next %s", lvl, tostring(slots or "?"),
			up and string.format("%s slots %s, %s", tostring(up.Slots), fmtMoney(up.Price), eta(up.Price)) or "max")
	end
	return food .. "\n" .. stand .. "\n" .. fence
end

local function animalsText()
	local animals = getData("Animals") or {}
	local placed, pack, mutated, bought = 0, 0, 0, 0
	local packRar = {}
	for _, a in pairs(animals) do
		if type(a) == "table" then
			if a.Placed then placed += 1 else
				pack += 1
				local r = rarityOf(a.ModelName)
				if r then packRar[r] = (packRar[r] or 0) + 1 end
			end
			if a.Mutation then mutated += 1 end
			if a.Bought then bought += 1 end
		end
	end
	local slots = FenceConfig and call(FenceConfig.SlotsFor, tonumber(getData("FenceLevel")) or 0)
	local index = 0
	for _ in pairs(getData("Index") or {}) do index += 1 end
	local total = 0
	if AnimalEconomy and AnimalEconomy.List then
		for _, e in pairs(AnimalEconomy.List) do
			if type(e) == "table" and e.Area ~= "Shop" then total += 1 end
		end
	end
	local parts = {}
	for _, r in ipairs(RARITIES) do
		if packRar[r] then parts[#parts + 1] = packRar[r] .. " " .. r end
	end
	return string.format("Plot %d/%s  |  backpack %d  |  mutated %d  |  bought %d\nBackpack: %s\nIndex: %d / %s species found",
		placed, tostring(slots or "?"), pack, mutated, bought, #parts > 0 and table.concat(parts, ", ") or "empty", index, total > 0 and tostring(total) or "?")
end

local function sessionText()
	local elapsed = math.max(1, os.clock() - Stats.start)
	local parts = {}
	for i = #RARITIES, 1, -1 do
		local r = RARITIES[i]
		if Stats.byRarity[r] then parts[#parts + 1] = Stats.byRarity[r] .. " " .. r end
	end
	return string.format("Time %s  |  throws %d (%.0f/hour)  |  avg throw %.1fs\nPerfect %d/%d  |  avg accuracy %.1f%%  |  failed %d, auto-fixed %d\nCaught: %s\nNew species %d  |  mutations %d  |  super throws %d%s",
		fmtTime(elapsed), Stats.throws, Stats.throws / elapsed * 3600, Stats.caught > 0 and Stats.cycleSum / Stats.caught or 0,
		Stats.perfect, Stats.caught, Stats.caught > 0 and Stats.accSum / Stats.caught * 100 or 0, Stats.failed, Stats.retried,
		#parts > 0 and table.concat(parts, ", ") or "nothing yet", Stats.newSpecies, Stats.mutations, Stats.supers,
		Stats.lastReason and ("  |  last error: " .. Stats.lastReason) or "")
end

local function serverText()
	local luck = LuckOdds and call(LuckOdds.GetLuckNow)
	return string.format("Players %d/%d  |  server luck %sx  |  super throws owned %s  |  staff: %s",
		#Players:GetPlayers(), Players.MaxPlayers, tostring(luck or 1), tostring(getData("SuperThrows") or 0),
		next(staffHere) and staffNames() or "none")
end

local function safetyText()
	local mode = Cfg.Movement .. (Cfg.Movement == "Fly" and (" at " .. Cfg.FlySpeed .. " studs/s") or "")
		.. (Cfg.StayAtLine and ", waits at the line" or ", returns to plot like the game")
	local staff = next(staffHere) and ("STAFF HERE: " .. staffNames()) or "no staff in this server"
	local afk = (afkCfg and afkCfg.IdleSeconds or 0) >= 1e8 and "AFK server move blocked" or "AFK server move NOT blocked"
	return string.format("Mode: %s\n%s  |  %s\nMeter: %s  |  pace: %s", mode, staff, afk,
		Cfg.HumanMeter and "human" or "always perfect", Cfg.HumanPace and "human (breaks on)" or "max speed")
end

-- milestones and the periodic summary (activity notifications)
local lastArea, lastLevelMark
local snap = { t = os.clock(), throws = 0, earned = 0, level = tonumber(getData("Level")) or 0, rare = 0 }
local function rareCount()
	local n = 0
	for r, c in pairs(Stats.byRarity) do
		if (RARITY_INDEX[r] or 0) >= (RARITY_INDEX[Cfg.NotifyRarity] or 99) then n += c end
	end
	return n
end
local function milestones(lvl)
	local areaIdx = ReleaseReach and call(ReleaseReach.AreaForLevel, lvl)
	if areaIdx then
		if lastArea and areaIdx > lastArea then
			local a = AreasConfig and AreasConfig.List and AreasConfig.List[areaIdx]
			notifyAct("area", 5, "New area reached!", "Your throws now reach " .. (a and tostring(a.Name) or ("area " .. areaIdx)) .. ". New animals to catch.", "map")
		end
		lastArea = areaIdx
	end
	local mark = lvl // 10
	if lastLevelMark and mark > lastLevelMark then
		notifyAct("level", 20, "Level " .. lvl, "Throw power keeps going up.", "trending_up")
	end
	lastLevelMark = mark
	local every = (tonumber(Cfg.SummaryMins) or 0) * 60
	if every > 0 and os.clock() - snap.t >= every and (Cfg.AutoThrow or Cfg.AutoTrain) then
		local mins = math.floor((os.clock() - snap.t) / 60 + 0.5)
		local text = string.format("%d throws, %d %s+ catches, +%d levels, +%s earned", Stats.throws - snap.throws,
			rareCount() - snap.rare, tostring(Cfg.NotifyRarity), math.max(0, lvl - snap.level), fmtMoney(Stats.earned - snap.earned))
		if notifyAct("summary", 30, "Last " .. mins .. " min", text, "insights") then
			snap = { t = os.clock(), throws = Stats.throws, earned = Stats.earned, level = lvl, rare = rareCount() }
		end
	end
end

task.spawn(function()
	while alive() do
		-- session earnings: count only increases in money, so spending does not hide what came in
		local m = money()
		if Stats.lastMoney and m > Stats.lastMoney then Stats.earned += m - Stats.lastMoney end
		Stats.lastMoney = m

		local elapsed = math.max(1, os.clock() - Stats.start)
		local lvl = tonumber(getData("Level")) or 0
		pcall(milestones, lvl)
		setLabel(statusLabel, "Status: " .. Stats.status)
		setLabel(statsLabel, string.format("Throws %d (%.0f/hour) | Caught %d | Sold %d (%s)\nLevel %d (+%d) | Money %s | %s/s\nBest: %s",
			Stats.throws, Stats.throws / elapsed * 3600, Stats.caught, Stats.sold, fmtMoney(Stats.soldFor),
			lvl, math.max(0, lvl - Stats.startLevel), fmtMoney(m), fmtMoney(income()), Stats.best or "-"))
		local lines = { "Last catches:" }
		for i = 1, 3 do lines[#lines + 1] = Stats.log[i] or "-" end
		setLabel(logLabel, table.concat(lines, "\n"))

		local okI, err = pcall(function()
			setLabel(infoProgress, progressText())
			setLabel(infoMoney, moneyText())
			setLabel(infoShop, shopText())
			setLabel(infoAnimals, animalsText())
			setLabel(infoSession, sessionText())
			setLabel(infoServer, serverText())
			setLabel(safetyLabel, safetyText())
		end)
		if not okI then warn("[Furina Animals] info: " .. tostring(err)) task.wait(4) end
		task.wait(1)
	end
end)

-- handles for an executor console (and for testing)
local tabs = { Farm = Farm, Animals = Animals, Upgrades = Upg, Safety = Safe, Info = Info, Player = Plr, Misc = Misc }
local Debug = {
	Cfg = Cfg, Stats = Stats, tracked = tracked, doThrow = doThrow, startTraining = startTraining, stopTraining = stopTraining,
	buyFoods = buyFoods, upgradeStands = upgradeStands, upgradeFence = upgradeFence, autoSell = autoSell, sellPreview = sellPreview,
	meterPeak = meterPeak, panic = panic, unload = unloadHub, refreshUI = refreshUI,
	set = function(key, v)
		Cfg[key] = v
		local h = Toggles[key] or Sliders[key] or Dropdowns[key]
		if h then pcall(function() h:Set(v) end) end
	end,
	showTab = function(name) if tabs[name] and Window.SelectTab then Window:SelectTab(tabs[name]) end end,
	texts = function()
		return { progress = progressText(), money = moneyText(), shop = shopText(), animals = animalsText(), session = sessionText(),
			server = serverText(), safety = safetyText() }
	end,
	staffHere = staffHere, meterOffset = meterOffset, walkTo = walkTo, noteLog = noteLog,
}
if not unloaded then
	getgenv().FurinaAnimalsDebug = Debug
	getgenv().FurinaAnimalsCfg = Cfg
end
cleanup(function()
	if getgenv().FurinaAnimalsDebug == Debug then getgenv().FurinaAnimalsDebug = nil end
end)

if Cfg.FPSBoost then setBoost(true) end
if Window.Ready then Window:Ready() end
notify("Furina Hub", "Throw Food For Animals loaded. Turn on Auto Throw in the Farm tab.", "check_circle")
