--[[
	Furina Hub | San Diego Roleplay (placeId 136020512003847)
	UI: FurinaUI (furina_ui.luau in this repo); falls back to Luna Interface Suite if it cannot load

	Run with loadstring, or through live-reload (STATE). Running it again replaces the old copy.

	Game notes (found by reading the game's own scripts)
	- The server runs a strong movement anti-cheat (SharedModules.AntiCheatGeometry): teleports over 100 studs,
	  flying, noclip and walking faster than CharacterWalkSpeed + 10 (= sprint speed, 22) are rolled back.
	- ExploitWatchUtil flags money farming (teleporting box jobs, machine-timed loops, too-fast boat runs,
	  hitbox claim mismatches, vehicle speeding) and can lead to account resets.
	  So this hub has no teleports, no fly, no speed hack, no auto-farm and no silent aim.
	- Shots are client raycasts from the camera, checked by the server. The aimbot moves the mouse so every
	  shot is a normal shot. No recoil / no spread patch the gun config the game reads on every shot.
	- Stamina is client-side (ClientModules.MovementController). Sprinting is exactly the anti-cheat speed cap,
	  so infinite stamina is the fastest legal way to move on foot.
	- Player attributes: WantedLevel, CurrentRankName, IsDeveloper, HasModeratorGui, ShowModeratorTag.
	  Money is Player.ReplicatedStats.Money (a formatted string). Vehicles carry OwnerName, RealVehicle,
	  CurrentHealth, CurrentFuel, Locked and CarBomb. Robbery state lives on workspace.Gameplay.Bank
	  (BankRobberyActive, VaultOpen) and workspace.Gameplay.JewelleryStore (JewelleryRobberyActive, ReopenTime).

	Layout
	 1. Bootstrap         5. Scheduler, player cache   9. Intel: alerts, robberies, staff, HUD
	 2. Services, UI      6. Player ESP                10. World, performance, misc
	 3. Settings (Cfg)    7. World ESP                 11. UI
	 4. Config files      8. Aimbot, game mods
]]

------------------------------------------------------------------------------------------------------
-- 1. Bootstrap: standalone teardown when STATE (live-reload) is not provided
------------------------------------------------------------------------------------------------------
local STATE = STATE
if not STATE then
	if getgenv().FurinaSDUnload then pcall(getgenv().FurinaSDUnload) end
	local cleanups, conns, running = {}, {}, true
	STATE = {
		onCleanup = function(f) cleanups[#cleanups + 1] = f end,
		connect = function(sig, fn)
			local c = sig:Connect(fn)
			conns[#conns + 1] = c
			return c
		end,
		alive = function() return running end,
	}
	getgenv().FurinaSDUnload = function()
		running = false
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
		getgenv().FurinaSDUnload = nil
	end
end

local unloaded = false
local function alive() return not unloaded and STATE.alive() end
local function cleanup(fn) STATE.onCleanup(fn) end
local function connect(sig, fn) return STATE.connect(sig, fn) end

------------------------------------------------------------------------------------------------------
-- 2. Services and UI library
------------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local BLACK, WHITE = Color3.new(0, 0, 0), Color3.new(1, 1, 1)
local V2 = Vector2.new

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
		warn("[Furina SD] FurinaUI failed to load, using Luna instead: " .. tostring(lib))
	end
	getgenv().ConfirmLuna = true
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/master/source.lua"))()
end)()
local FURINA = UI.IsFurinaUI == true
local function notify(title, text, icon)
	pcall(function() UI:Notification({ Title = title, Content = text, Icon = icon or "info", ImageSource = "Material" }) end)
end

-- require a game module without ever blocking the hub: gives up after `timeout` seconds
local function safeRequire(inst, timeout)
	if not inst then return nil end
	local result, done = nil, false
	task.spawn(function()
		local ok, m = pcall(require, inst)
		if ok then result = m end
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < (timeout or 3) do task.wait() end
	return result
end

------------------------------------------------------------------------------------------------------
-- 3. Settings
------------------------------------------------------------------------------------------------------
local Cfg = {
	-- player ESP
	ESP = true, ESPKey = Enum.KeyCode.F1, ESPMax = 1500,
	ShowLaw = true, ShowCivs = true, WantedOnly = false, ShowTeam = true,
	Box = true, BoxStyle = "Corners", BoxThick = 1,
	Name = true, Rank = false, Health = true, Distance = true, Money = true, Wanted = true, Tool = true,
	TextSize = 13, Skeleton = false, SkelDist = 250, Chams = true, ChamsFill = 75,
	Tracers = false, TracerOrigin = "Bottom", Arrows = true, ColorMode = "Role",
	LawColor = Color3.fromRGB(80, 150, 255), CivColor = Color3.fromRGB(235, 235, 235),
	WantedColor = Color3.fromRGB(255, 70, 70), StaffColor = Color3.fromRGB(200, 90, 255),
	-- world ESP
	VehESP = false, VehMax = 800, VehOwners = true, VehMine = true, VehDetail = 300, HideInMenu = true,
	LocESP = false, LocMax = 20000, Locations = { "Bank", "JewelryStore", "GunStore", "BlackMarket", "SDPD", "ElCapo" },
	DropESP = false,
	-- aimbot
	Aim = false, AimKeyToggle = Enum.KeyCode.F2, AimKey = "Right Mouse", AimFOV = 180, ShowFOV = true,
	AimSmooth = 3, AimSpeed = 100, AimPart = "Auto", AimVis = true, AimSticky = true, AimPriority = "Crosshair",
	AimTargets = "Not My Team", AimLead = 40, AutoCal = true, AimMax = 600,
	Trigger = false, TrigKey = Enum.KeyCode.F3, TrigDelay = 60, TrigRate = 120, TrigHead = false,
	Cross = false, CrossSize = 7, CrossGap = 4, CrossThick = 1, CrossDot = true, CrossColor = Color3.fromRGB(255, 255, 255),
	-- game mods
	NoRecoil = false, NoSpread = false, InfStamina = false, InstantPrompt = false,
	-- intel
	HUD = true, StaffAlert = true, StaffLeave = false, PoliceAlert = true, AlertRange = 150,
	RobberyAlert = true, BombAlert = true, WantedAlert = true,
	-- world
	Fullbright = false, NoFog = false, FOVOn = false, FOV = 80, AntiAFK = true,
	FPSBoost = false, FPSCapOn = false, FPSCap = 144,
	-- farms
	FarmJob = "Box Delivery", FarmSprint = true, FarmTravel = true, FarmPace = "Human",
	FarmBreaks = true, FarmMaxMin = 60, FarmStaffStop = true, FarmCash = false, FarmCashRange = 60,
	AutoDaily = true,
	-- general
	PanicKey = Enum.KeyCode.Delete, AutoSave = true,
}
getgenv().FurinaSDCfg = Cfg

------------------------------------------------------------------------------------------------------
-- 4. Config files: <workspace>/FurinaHub/<profile>.json, active profile in FurinaHub/_profile_sandiego.txt
------------------------------------------------------------------------------------------------------
local CFG_DIR = "FurinaHub"
local PROFILE_FILE = CFG_DIR .. "/_profile_sandiego.txt"
local cfgProfile = "sandiego"
local NOSAVE = { Fullbright = true, FPSBoost = true }

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
			if ty == "Color3" then
				t[k] = { __c = { v.R, v.G, v.B } }
			elseif ty == "EnumItem" then
				t[k] = { __k = v.Name }
			elseif ty == "number" then
				if v == v and v ~= math.huge and v ~= -math.huge then t[k] = v end
			elseif ty == "boolean" or ty == "string" then
				t[k] = v
			elseif ty == "table" then
				t[k] = { __l = v }
			end
		end
	end
	return HttpService:JSONEncode(t)
end

local function signature()
	local parts = {}
	for k, v in pairs(Cfg) do
		if not NOSAVE[k] then
			local s
			if typeof(v) == "Color3" then s = v:ToHex()
			elseif type(v) == "table" then s = table.concat(v, ",")
			else s = tostring(v) end
			parts[#parts + 1] = k .. "=" .. s
		end
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

local function saveCfg(name)
	if not fsOK then return false, "this executor has no file functions (writefile/readfile/isfile)" end
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
	if not isfile(cfgPath(name)) then return false end
	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(cfgPath(name))) end)
	if not ok or type(data) ~= "table" then return false end
	for k, v in pairs(data) do
		local cur = Cfg[k]
		if cur ~= nil and not NOSAVE[k] then
			if type(v) == "table" and v.__c and typeof(cur) == "Color3" then
				Cfg[k] = Color3.new(v.__c[1], v.__c[2], v.__c[3])
			elseif type(v) == "table" and v.__k and typeof(cur) == "EnumItem" then
				local okk, en = pcall(function() return Enum.KeyCode[v.__k] end)
				if okk and en then Cfg[k] = en end
			elseif type(v) == "table" and type(v.__l) == "table" and type(cur) == "table" then
				Cfg[k] = v.__l
			elseif type(v) == type(cur) then
				Cfg[k] = v
			end
		end
	end
	return true
end

local function setProfile(name)
	cfgProfile = name
	if fsOK then
		ensureDir()
		pcall(writefile, PROFILE_FILE, name)
	end
end

if fsOK and isfile(PROFILE_FILE) then
	local okp, saved = pcall(readfile, PROFILE_FILE)
	if okp then cfgProfile = cleanName(saved) or cfgProfile end
end
loadCfg()

------------------------------------------------------------------------------------------------------
-- 5. Scheduler and player cache
------------------------------------------------------------------------------------------------------
local frameJobs, renderJobs, timers = {}, {}, {}
local function run(job, ...)
	local ok, err = pcall(job.fn, ...)
	if not ok and not job.failed then
		job.failed = true
		warn("[Furina SD] " .. job.name .. ": " .. tostring(err))
	end
end
local function onRender(name, fn) renderJobs[#renderJobs + 1] = { name = name, fn = fn } end
local function every(name, interval, fn) timers[#timers + 1] = { name = name, interval = interval, fn = fn, nextAt = 0 } end

connect(RunService.Heartbeat, function(dt)
	if not alive() then return end
	for i = 1, #frameJobs do run(frameJobs[i], dt) end
	local now = os.clock()
	for i = 1, #timers do
		local t = timers[i]
		if now >= t.nextAt then
			t.nextAt = now + t.interval
			run(t)
		end
	end
end)
connect(RunService.RenderStepped, function(dt)
	if not alive() then return end
	if workspace.CurrentCamera ~= Camera then Camera = workspace.CurrentCamera end
	for i = 1, #renderJobs do run(renderJobs[i], dt) end
end)

local hubRefs = {} -- functions defined later that earlier sections need (panic -> stop farm)
local Toggles, Sliders = {}, {}
local function setToggle(key, v)
	Cfg[key] = v
	local t = Toggles[key]
	if t then pcall(function() t:Set(v) end) end
end

-- teams that enforce the law; everyone else is a civilian
local LAW = { Police = true, FBI = true, SWAT = true, STRIKE = true, Army = true, ["Coast Guard"] = true, ["Checkpoint Authority"] = true }

local function isStaff(p)
	return p:GetAttribute("IsDeveloper") == true or p:GetAttribute("HasModeratorGui") == true or p:GetAttribute("ShowModeratorTag") == true
end
local function moneyOf(p)
	local rs = p:FindFirstChild("ReplicatedStats")
	local m = rs and rs:FindFirstChild("Money")
	return m and tostring(m.Value) or "?"
end
-- "16.9M" / "2,950" -> number, for sorting by wealth
local function moneyNum(s)
	s = tostring(s):gsub(",", ""):gsub("%$", "")
	local n, suf = s:match("^([%d%.]+)(%a?)")
	n = tonumber(n) or 0
	local mul = ({ K = 1e3, M = 1e6, B = 1e9, T = 1e12 })[suf and suf:upper() or ""] or 1
	return n * mul
end
local function teamName(p) return p.Team and p.Team.Name or "None" end

local cache = { list = {}, by = {}, byPlayer = {} }
local function rebuildCache()
	local list, by, byPlayer = {}, {}, {}
	local myTeam = LP.Team
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local m = p.Character
			local root = m and m:FindFirstChild("HumanoidRootPart")
			local head = m and m:FindFirstChild("Head")
			local hum = m and m:FindFirstChildOfClass("Humanoid")
			if root and head and hum then
				local team = teamName(p)
				local tool = m:FindFirstChildOfClass("Tool")
				local e = {
					plr = p, m = m, root = root, head = head, hum = hum, team = team,
					law = LAW[team] == true, mine = myTeam ~= nil and p.Team == myTeam,
					wanted = tonumber(p:GetAttribute("WantedLevel")) or 0,
					staff = isStaff(p), jailed = m:GetAttribute("IsJailed") == true,
					rank = tostring(p:GetAttribute("CurrentRankName") or ""),
					money = moneyOf(p), tool = tool and tool.Name or nil,
					name = p.DisplayName ~= p.Name and (p.DisplayName .. " (@" .. p.Name .. ")") or p.Name,
					teamColor = p.TeamColor.Color,
				}
				list[#list + 1] = e
				by[m] = e
				byPlayer[p] = e
			end
		end
	end
	cache.list, cache.by, cache.byPlayer = list, by, byPlayer
end
every("cache", 0.15, rebuildCache)
rebuildCache()

local function meAlive()
	local c = LP.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	return h ~= nil and h.Health > 0
end
local function myRoot()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

-- line of sight: visibility rays ignore every character and the game's effect folders
local rayVis, rayTrig = RaycastParams.new(), RaycastParams.new()
for _, rp in ipairs({ rayVis, rayTrig }) do
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.IgnoreWater = true
end
local function refreshRayFilters()
	local base = { Camera }
	for _, n in ipairs({ "Tracers", "ObjectCache", "_RayVisualizers", "SoundCache", "Drops" }) do
		local f = workspace:FindFirstChild(n)
		if f then base[#base + 1] = f end
	end
	local trig = table.clone(base)
	if LP.Character then
		trig[#trig + 1] = LP.Character
		base[#base + 1] = LP.Character
	end
	for _, e in ipairs(cache.list) do base[#base + 1] = e.m end
	rayVis.FilterDescendantsInstances = base
	rayTrig.FilterDescendantsInstances = trig
end
every("rayfilter", 0.5, refreshRayFilters)
refreshRayFilters()

local function visibleFrom(origin, part)
	return workspace:Raycast(origin, part.Position - origin, rayVis) == nil
end

------------------------------------------------------------------------------------------------------
-- 6. Player ESP (Drawing + Highlight chams)
------------------------------------------------------------------------------------------------------
local allDrawings = {}
local shadow = setmetatable({}, { __mode = "k" })
local FONT = (Drawing.Fonts and (Drawing.Fonts.Plex or Drawing.Fonts.UI)) or 2

local function newDraw(kind, props)
	local d = Drawing.new(kind)
	for k, v in pairs(props) do d[k] = v end
	allDrawings[#allDrawings + 1] = d
	return d
end
local function P(d, k, v)
	local s = shadow[d]
	if not s then s = {} shadow[d] = s end
	if s[k] ~= v then
		s[k] = v
		d[k] = v
	end
end
local function killDraw(d)
	pcall(function() d:Remove() end)
	shadow[d] = nil
	local i = table.find(allDrawings, d)
	if i then table.remove(allDrawings, i) end
end

local BONES = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}

local hlFolder = Instance.new("Folder")
hlFolder.Name = "FurinaSDChams"
pcall(function() hlFolder.Parent = (gethui and gethui()) or CoreGui end)
if not hlFolder.Parent then hlFolder.Parent = CoreGui end
cleanup(function() hlFolder:Destroy() end)

local esp = {}
local espFrame = 0

local function getESP(m)
	local o = esp[m]
	if o then return o end
	o = { all = {}, parts = {}, bones = {}, corners = {}, seen = 0 }
	local function mk(kind, props)
		local d = newDraw(kind, props)
		o.all[#o.all + 1] = d
		return d
	end
	o.boxOut = mk("Square", { Thickness = 3, Filled = false, Color = BLACK, Visible = false })
	o.box = mk("Square", { Thickness = 1, Filled = false, Visible = false })
	for i = 1, 8 do o.corners[i] = mk("Line", { Thickness = 1, Visible = false }) end
	o.hpBg = mk("Square", { Thickness = 1, Filled = true, Color = BLACK, Transparency = 0.6, Visible = false })
	o.hpFill = mk("Square", { Thickness = 1, Filled = true, Visible = false })
	o.name = mk("Text", { Size = 13, Center = true, Outline = true, Font = FONT, Visible = false })
	o.info = mk("Text", { Size = 13, Center = true, Outline = true, Font = FONT, Visible = false })
	for i = 1, #BONES do o.bones[i] = mk("Line", { Thickness = 1, Visible = false }) end
	o.tracer = mk("Line", { Thickness = 1, Visible = false })
	o.arrow = mk("Triangle", { Thickness = 1, Filled = true, Visible = false })
	o.hl = Instance.new("Highlight")
	o.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	o.hl.Enabled = false
	o.hl.Parent = hlFolder
	esp[m] = o
	return o
end

local function hideESP(o)
	for _, d in ipairs(o.all) do P(d, "Visible", false) end
	if o.hl.Enabled then o.hl.Enabled = false end
end
local function destroyESP(m)
	local o = esp[m]
	if not o then return end
	for _, d in ipairs(o.all) do killDraw(d) end
	pcall(function() o.hl:Destroy() end)
	esp[m] = nil
end
local function hideAllESP() for _, o in pairs(esp) do hideESP(o) end end
local function removeAllESP() for m in pairs(esp) do destroyESP(m) end end
every("espgc", 1, function()
	for m, o in pairs(esp) do
		if o.seen < espFrame - 120 or not m.Parent then destroyESP(m) end
	end
end)

local function part(o, m, name)
	local p = o.parts[name]
	if not p or p.Parent == nil then
		p = m:FindFirstChild(name)
		o.parts[name] = p
	end
	return p
end

local function espVisible(e)
	if e.mine and not Cfg.ShowTeam then return false end
	if e.staff then return true end -- staff are always worth seeing
	if e.law then return Cfg.ShowLaw end
	if not Cfg.ShowCivs then return false end
	if Cfg.WantedOnly and e.wanted <= 0 then return false end
	return true
end

local function espColor(e)
	if e.staff then return Cfg.StaffColor end
	if Cfg.ColorMode == "Team" then return e.teamColor end
	if e.law then return Cfg.LawColor end
	if e.wanted > 0 then return Cfg.WantedColor end
	return Cfg.CivColor
end

local function infoLine(e, dist)
	local bits = {}
	if Cfg.Distance then bits[#bits + 1] = string.format("%dm", math.floor(dist * 0.28)) end
	if Cfg.Money then bits[#bits + 1] = "$" .. e.money end
	if Cfg.Wanted and e.wanted > 0 then bits[#bits + 1] = string.rep("*", math.min(e.wanted, 5)) .. " WANTED " .. e.wanted end
	if e.jailed then bits[#bits + 1] = "JAILED" end
	if Cfg.Tool and e.tool then bits[#bits + 1] = e.tool end
	return table.concat(bits, "  ")
end

local function drawESP()
	espFrame += 1
	local cam = Camera
	local cf = cam.CFrame
	local camPos = cf.Position
	local vp = cam.ViewportSize
	local center = V2(vp.X / 2, vp.Y / 2)
	local fontSize = Cfg.TextSize

	for _, e in ipairs(cache.list) do
		local m, root, head = e.m, e.root, e.head
		local o = getESP(m)
		o.seen = espFrame
		local show = root.Parent ~= nil and head.Parent ~= nil and e.hum.Health > 0 and espVisible(e)
		local rp = show and root.Position
		local dist = show and (rp - camPos).Magnitude
		if not show or dist > Cfg.ESPMax then
			hideESP(o)
			continue
		end
		local col = espColor(e)

		if Cfg.Chams then
			local hl = o.hl
			if hl.Adornee ~= m then hl.Adornee = m end
			hl.FillColor = col
			hl.OutlineColor = col
			hl.FillTransparency = math.clamp(Cfg.ChamsFill / 100, 0, 1)
			hl.OutlineTransparency = 0.1
			hl.Enabled = true
		elseif o.hl.Enabled then
			o.hl.Enabled = false
		end

		local lf, rf = part(o, m, "LeftFoot"), part(o, m, "RightFoot")
		local footY = rp.Y - 3
		if lf and rf then footY = math.min(lf.Position.Y, rf.Position.Y) - 0.25 end
		local t2, tIn = cam:WorldToViewportPoint(Vector3.new(rp.X, head.Position.Y + 0.75, rp.Z))
		local b2, bIn = cam:WorldToViewportPoint(Vector3.new(rp.X, footY, rp.Z))

		if not (tIn and bIn and t2.Z > 0 and b2.Z > 0) then
			for i = 1, #o.all do P(o.all[i], "Visible", false) end
			if Cfg.Arrows then
				local rel = cf:PointToObjectSpace(rp)
				local dir = V2(rel.X, -rel.Y)
				if dir.Magnitude < 1e-3 then dir = V2(0, 1) end
				dir = dir.Unit
				local pos = center + dir * (math.min(vp.X, vp.Y) * 0.42)
				local perp = V2(-dir.Y, dir.X)
				P(o.arrow, "PointA", pos + dir * 13)
				P(o.arrow, "PointB", pos - dir * 7 + perp * 8)
				P(o.arrow, "PointC", pos - dir * 7 - perp * 8)
				P(o.arrow, "Color", col)
				P(o.arrow, "Visible", true)
			end
			continue
		end
		P(o.arrow, "Visible", false)

		local h = b2.Y - t2.Y
		local w = h * 0.55
		local x0, y0 = t2.X - w / 2, t2.Y
		local thick = Cfg.BoxThick

		if Cfg.Box then
			if Cfg.BoxStyle == "Full" then
				P(o.boxOut, "Position", V2(x0, y0)) P(o.boxOut, "Size", V2(w, h)) P(o.boxOut, "Visible", true)
				P(o.box, "Position", V2(x0, y0)) P(o.box, "Size", V2(w, h)) P(o.box, "Color", col) P(o.box, "Thickness", thick) P(o.box, "Visible", true)
				for i = 1, 8 do P(o.corners[i], "Visible", false) end
			else
				P(o.boxOut, "Visible", false) P(o.box, "Visible", false)
				local cl = math.max(4, math.min(w, h) * 0.28)
				local x1, y1 = x0 + w, y0 + h
				local pts = {
					{ V2(x0, y0), V2(x0 + cl, y0) }, { V2(x0, y0), V2(x0, y0 + cl) },
					{ V2(x1, y0), V2(x1 - cl, y0) }, { V2(x1, y0), V2(x1, y0 + cl) },
					{ V2(x0, y1), V2(x0 + cl, y1) }, { V2(x0, y1), V2(x0, y1 - cl) },
					{ V2(x1, y1), V2(x1 - cl, y1) }, { V2(x1, y1), V2(x1, y1 - cl) },
				}
				for i = 1, 8 do
					local ln = o.corners[i]
					P(ln, "From", pts[i][1]) P(ln, "To", pts[i][2]) P(ln, "Color", col) P(ln, "Thickness", thick) P(ln, "Visible", true)
				end
			end
		else
			P(o.boxOut, "Visible", false) P(o.box, "Visible", false)
			for i = 1, 8 do P(o.corners[i], "Visible", false) end
		end

		if Cfg.Health then
			local frac = math.clamp(e.hum.Health / math.max(e.hum.MaxHealth, 1), 0, 1)
			local bx = x0 - 5
			P(o.hpBg, "Position", V2(bx - 1, y0 - 1)) P(o.hpBg, "Size", V2(4, h + 2)) P(o.hpBg, "Visible", true)
			P(o.hpFill, "Position", V2(bx, y0 + h * (1 - frac))) P(o.hpFill, "Size", V2(2, h * frac))
			P(o.hpFill, "Color", Color3.fromHSV(frac * 0.33, 0.9, 1)) P(o.hpFill, "Visible", true)
		else
			P(o.hpBg, "Visible", false) P(o.hpFill, "Visible", false)
		end

		if Cfg.Name then
			local label = e.name
			if e.staff then label = "[STAFF] " .. label end
			if Cfg.Rank then label = label .. "  [" .. e.team .. (e.rank ~= "" and (" - " .. e.rank) or "") .. "]" end
			P(o.name, "Text", label) P(o.name, "Size", fontSize)
			P(o.name, "Position", V2(t2.X, y0 - fontSize - 3)) P(o.name, "Color", col) P(o.name, "Visible", true)
		else
			P(o.name, "Visible", false)
		end
		local info = infoLine(e, dist)
		if info ~= "" then
			P(o.info, "Text", info) P(o.info, "Size", math.max(fontSize - 1, 8))
			P(o.info, "Position", V2(t2.X, y0 + h + 2)) P(o.info, "Color", e.wanted > 0 and Cfg.WantedColor or WHITE) P(o.info, "Visible", true)
		else
			P(o.info, "Visible", false)
		end

		if Cfg.Skeleton and dist <= Cfg.SkelDist then
			for i, b in ipairs(BONES) do
				local ln = o.bones[i]
				local pa, pb = part(o, m, b[1]), part(o, m, b[2])
				if pa and pb then
					local a2, aIn = cam:WorldToViewportPoint(pa.Position)
					local b3, bIn2 = cam:WorldToViewportPoint(pb.Position)
					if a2.Z > 0 and b3.Z > 0 and (aIn or bIn2) then
						P(ln, "From", V2(a2.X, a2.Y)) P(ln, "To", V2(b3.X, b3.Y)) P(ln, "Color", col) P(ln, "Visible", true)
					else
						P(ln, "Visible", false)
					end
				else
					P(ln, "Visible", false)
				end
			end
		else
			for i = 1, #BONES do P(o.bones[i], "Visible", false) end
		end

		if Cfg.Tracers then
			local from = center
			if Cfg.TracerOrigin == "Bottom" then
				from = V2(vp.X / 2, vp.Y)
			elseif Cfg.TracerOrigin == "Mouse" then
				local mp = UserInputService:GetMouseLocation()
				from = V2(mp.X, mp.Y)
			end
			P(o.tracer, "From", from) P(o.tracer, "To", V2(t2.X, y0 + h)) P(o.tracer, "Color", col) P(o.tracer, "Visible", true)
		else
			P(o.tracer, "Visible", false)
		end
	end

	for _, o in pairs(esp) do
		if o.seen ~= espFrame then hideESP(o) end
	end
end

local espWasOn = false
local menuOpen -- defined with the world ESP below
onRender("esp", function()
	if Cfg.ESP and not (menuOpen and menuOpen()) then
		espWasOn = true
		drawESP()
	elseif espWasOn then
		espWasOn = false
		hideAllESP()
	end
end)

------------------------------------------------------------------------------------------------------
-- 7. World ESP: vehicles, map locations, drops (one text label per object, pooled by instance)
------------------------------------------------------------------------------------------------------
local labels = {} -- [instance] = { text = Drawing, dot = Drawing, seen = frame, group = string }
local labelFrame = 0
local function getLabel(inst, group)
	local l = labels[inst]
	if l then return l end
	l = {
		text = newDraw("Text", { Size = 13, Center = true, Outline = true, Font = FONT, Visible = false }),
		dot = newDraw("Circle", { Filled = true, Radius = 3, Thickness = 1, Visible = false }),
		seen = 0, group = group,
	}
	labels[inst] = l
	return l
end
local function hideLabel(l) P(l.text, "Visible", false) P(l.dot, "Visible", false) end
local function dropLabel(inst)
	local l = labels[inst]
	if not l then return end
	killDraw(l.text) killDraw(l.dot)
	labels[inst] = nil
end
local function placeLabel(inst, group, pos, text, color)
	local l = getLabel(inst, group)
	l.seen = labelFrame
	local sp, on = Camera:WorldToViewportPoint(pos)
	if not on or sp.Z <= 0 then hideLabel(l) return end
	P(l.text, "Text", text) P(l.text, "Size", math.max(Cfg.TextSize - 1, 9)) P(l.text, "Color", color)
	P(l.text, "Position", V2(sp.X, sp.Y - Cfg.TextSize - 4)) P(l.text, "Visible", true)
	P(l.dot, "Position", V2(sp.X, sp.Y)) P(l.dot, "Color", color) P(l.dot, "Visible", true)
end

-- map locations come from the minimap's own waypoint markers
local waypoints = {} -- { name, pos }
local waypointNames = {}
local function scanWaypoints()
	local folder = workspace:FindFirstChild("Nodes") and workspace.Nodes:FindFirstChild("Waypoints")
	if not folder then return end
	local list, names, seen = {}, {}, {}
	for _, c in ipairs(folder:GetChildren()) do
		local pos = c:IsA("BasePart") and c.Position or (c:IsA("Model") and c:GetPivot().Position)
		if pos then
			list[#list + 1] = { name = c.Name, pos = pos, inst = c }
			if not seen[c.Name] then
				seen[c.Name] = true
				names[#names + 1] = c.Name
			end
		end
	end
	table.sort(names)
	waypoints, waypointNames = list, names
end
scanWaypoints()
every("waypoints", 15, scanWaypoints)

local VEH_COLOR, MY_VEH_COLOR, BOMB_COLOR = Color3.fromRGB(255, 205, 90), Color3.fromRGB(90, 255, 150), Color3.fromRGB(255, 60, 60)
local LOC_COLOR, DROP_COLOR = Color3.fromRGB(120, 230, 255), Color3.fromRGB(120, 255, 120)

local function vehicleText(v, dist)
	local name = tostring(v:GetAttribute("RealVehicle") or v.Name)
	local bomb = v:GetAttribute("CarBomb") == true
	if dist > Cfg.VehDetail then -- far away: short label so a parking lot does not turn into a wall of text
		return string.format("%s  %dm%s", name, math.floor(dist * 0.28), bomb and "  CAR BOMB" or "")
	end
	local bits = { name }
	if Cfg.VehOwners then bits[#bits + 1] = tostring(v:GetAttribute("OwnerName") or "?") end
	local hp, mhp = tonumber(v:GetAttribute("CurrentHealth")), tonumber(v:GetAttribute("MaxHealth"))
	if hp and mhp and mhp > 0 then bits[#bits + 1] = string.format("%d%% hp", math.floor(hp / mhp * 100 + 0.5)) end
	local fuel, mf = tonumber(v:GetAttribute("CurrentFuel")), tonumber(v:GetAttribute("MaxFuel"))
	if fuel and mf and mf > 0 then bits[#bits + 1] = string.format("%d%% fuel", math.floor(fuel / mf * 100 + 0.5)) end
	bits[#bits + 1] = string.format("%dm", math.floor(dist * 0.28))
	if v:GetAttribute("Locked") == true then bits[#bits + 1] = "LOCKED" end
	if bomb then bits[#bits + 1] = "CAR BOMB" end
	return table.concat(bits, "  |  ")
end

-- the vehicle you are sitting in (driver or passenger), so its label does not cover the screen
local function myVehicle()
	local c = LP.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local seat = h and h.SeatPart
	local folder = workspace:FindFirstChild("Vehicles")
	if not (seat and folder) then return nil end
	local m = seat
	while m and m.Parent ~= folder do m = m.Parent end
	return m
end

-- FurinaUI exposes the window's visibility; ESP can step aside while you use the menu
local WindowRef = {}
menuOpen = function()
	local w = WindowRef.w
	return Cfg.HideInMenu and type(w) == "table" and w.visible == true
end

local worldWasOn = false
onRender("worldesp", function()
	local any = (Cfg.VehESP or Cfg.LocESP or Cfg.DropESP) and not menuOpen()
	if not any then
		if worldWasOn then
			worldWasOn = false
			for _, l in pairs(labels) do hideLabel(l) end
		end
		return
	end
	worldWasOn = true
	labelFrame += 1
	local camPos = Camera.CFrame.Position

	if Cfg.VehESP then
		local folder = workspace:FindFirstChild("Vehicles")
		local riding = myVehicle()
		if folder then
			for _, v in ipairs(folder:GetChildren()) do
				if v:IsA("Model") and v ~= riding then
					local mine = v:GetAttribute("OwnerUserId") == LP.UserId
					if mine and not Cfg.VehMine then continue end
					local root = v:FindFirstChild("Root") or v.PrimaryPart
					if root then
						local pos = root.Position + Vector3.new(0, 4, 0)
						local dist = (pos - camPos).Magnitude
						if dist <= Cfg.VehMax then
							local col = v:GetAttribute("CarBomb") == true and BOMB_COLOR or (mine and MY_VEH_COLOR or VEH_COLOR)
							placeLabel(v, "veh", pos, vehicleText(v, dist), col)
						end
					end
				end
			end
		end
	end

	if Cfg.LocESP then
		local want = {}
		for _, n in ipairs(Cfg.Locations) do want[n] = true end
		for _, w in ipairs(waypoints) do
			if want[w.name] then
				local dist = (w.pos - camPos).Magnitude
				if dist <= Cfg.LocMax then
					placeLabel(w.inst, "loc", w.pos, string.format("%s  %dm", w.name, math.floor(dist * 0.28)), LOC_COLOR)
				end
			end
		end
	end

	if Cfg.DropESP then
		local folder = workspace:FindFirstChild("Drops")
		if folder then
			for _, d in ipairs(folder:GetChildren()) do
				local pos = d:IsA("BasePart") and d.Position or (d:IsA("Model") and d:GetPivot().Position)
				if pos then
					local dist = (pos - camPos).Magnitude
					placeLabel(d, "drop", pos, string.format("%s  %dm", d.Name, math.floor(dist * 0.28)), DROP_COLOR)
				end
			end
		end
	end

	for inst, l in pairs(labels) do
		if l.seen ~= labelFrame then hideLabel(l) end
	end
end)
every("labelgc", 2, function()
	for inst, l in pairs(labels) do
		if not inst.Parent or l.seen < labelFrame - 300 then dropLabel(inst) end
	end
end)

cleanup(function()
	removeAllESP()
	for inst in pairs(labels) do dropLabel(inst) end
	for _, d in ipairs(allDrawings) do pcall(function() d:Remove() end) end
	table.clear(allDrawings)
end)

------------------------------------------------------------------------------------------------------
-- 8. Aimbot (moves the mouse, so every shot is a normal shot), triggerbot, crosshair, game mods
------------------------------------------------------------------------------------------------------
-- the game locks the mouse whenever the camera turns (LockCurrentPosition / LockCenter)
local function mouseLocked() return UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default end
local function typing() return UserInputService:GetFocusedTextBox() ~= nil end

local AIM_KEYS = {
	["Right Mouse"] = function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) end,
	["Left Mouse"] = function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end,
	["Mouse 4"] = function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton4) end,
	["Left Alt"] = function() return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) end,
	["Q"] = function() return UserInputService:IsKeyDown(Enum.KeyCode.Q) end,
	["Always On"] = function() return true end,
}
local AIM_PARTS = {
	Head = { "Head" },
	Chest = { "UpperTorso" },
	Pelvis = { "LowerTorso" },
	Nearest = { "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg" },
	Auto = { "Head", "UpperTorso", "LowerTorso", "LeftUpperLeg", "RightUpperLeg" },
}

local function isTarget(e)
	if e.hum.Health <= 0 or e.jailed then return false end
	local f = Cfg.AimTargets
	if f == "Everyone" then return true end
	if f == "Not My Team" then return not e.mine end
	if f == "Police & Gov" then return e.law end
	if f == "Civilians" then return not e.law end
	if f == "Wanted Only" then return e.wanted > 0 end
	return not e.mine
end

local fovCircle = newDraw("Circle", { Filled = false, Thickness = 1, Color = WHITE, Transparency = 1, Visible = false })
local aim = { target = nil, est = 0.15, remX = 0, remY = 0, prevLook = nil, sentX = 0, sentY = 0, status = "idle" }

local velTrack = setmetatable({}, { __mode = "k" })
onRender("velocity", function(dt)
	if not Cfg.Aim or dt <= 0 then return end
	for _, e in ipairs(cache.list) do
		if e.root.Parent then
			local pos = e.root.Position
			local t = velTrack[e.m]
			if t then
				local v = (pos - t.pos) / dt
				if v.Magnitude > 250 then v = Vector3.zero end -- respawn or rollback, not movement
				t.vel = t.vel:Lerp(v, 0.35)
				t.pos = pos
			else
				velTrack[e.m] = { pos = pos, vel = Vector3.zero }
			end
		end
	end
end)
local function leadPos(e, p)
	local t = velTrack[e.m]
	if t and Cfg.AimLead > 0 then return p.Position + t.vel * (Cfg.AimLead / 1000) end
	return p.Position
end
local function focalPx(vp) return (vp.Y / 2) / math.tan(math.rad(Camera.FieldOfView) / 2) end

local function pickPart(e, origin, center, maxPx)
	local best, bestPx
	for _, name in ipairs(AIM_PARTS[Cfg.AimPart] or AIM_PARTS.Head) do
		local p = e.m:FindFirstChild(name)
		if p then
			local sp, vis = Camera:WorldToViewportPoint(leadPos(e, p))
			if vis and sp.Z > 0 then
				local px = (V2(sp.X, sp.Y) - center).Magnitude
				if px <= maxPx and (not best or px < bestPx) and (not Cfg.AimVis or visibleFrom(origin, p)) then
					best, bestPx = p, px
					if Cfg.AimPart == "Auto" then break end
				end
			end
		end
	end
	return best, bestPx
end

local function findTarget(origin, center)
	local best, bestScore, bestPart
	for _, e in ipairs(cache.list) do
		if e.root.Parent and isTarget(e) and (e.root.Position - origin).Magnitude <= Cfg.AimMax then
			local p, px = pickPart(e, origin, center, Cfg.AimFOV)
			if p then
				local score = px
				if Cfg.AimPriority == "Distance" then
					score = (e.root.Position - origin).Magnitude
				elseif Cfg.AimPriority == "Lowest HP" then
					score = e.hum.Health
				end
				if not best or score < bestScore then best, bestScore, bestPart = e, score, p end
			end
		end
	end
	return best, bestPart
end

local function yawPitch(look) return math.atan2(look.X, look.Z), math.asin(math.clamp(look.Y, -1, 1)) end
local function wrapPi(a) return (a + math.pi) % (2 * math.pi) - math.pi end

-- aim point: where the crosshair is. Third person games often offset it, so read the game's reticle if it exists
local function aimCenter(vp)
	return V2(vp.X / 2, vp.Y / 2)
end

onRender("aimbot", function()
	local vp = Camera.ViewportSize
	local center = aimCenter(vp)
	local active = Cfg.Aim and meAlive() and mouseLocked() and not typing()
	if Cfg.Aim and Cfg.ShowFOV then
		P(fovCircle, "Position", center) P(fovCircle, "Radius", Cfg.AimFOV) P(fovCircle, "Visible", true)
		P(fovCircle, "Color", aim.target and Color3.fromRGB(90, 255, 120) or WHITE)
	else
		P(fovCircle, "Visible", false)
	end
	if not active or not (AIM_KEYS[Cfg.AimKey] or AIM_KEYS["Right Mouse"])() then
		aim.target, aim.prevLook, aim.sentX, aim.sentY, aim.remX, aim.remY = nil, nil, 0, 0, 0, 0
		aim.status = Cfg.Aim and (mouseLocked() and "waiting for aim key" or "mouse not locked") or "off"
		return
	end

	local look = Camera.CFrame.LookVector
	if Cfg.AutoCal and aim.prevLook then
		local mag = math.sqrt(aim.sentX ^ 2 + aim.sentY ^ 2)
		if mag >= 3 then
			local y0, p0 = yawPitch(aim.prevLook)
			local y1, p1 = yawPitch(look)
			local obs = math.deg(math.sqrt(wrapPi(y1 - y0) ^ 2 + (p1 - p0) ^ 2))
			local sample = obs / mag
			if sample > 0.005 and sample < 2 then aim.est = math.clamp(aim.est * 0.85 + sample * 0.15, 0.02, 1.5) end
		end
	end

	local origin = Camera.CFrame.Position
	local tgt, tpart
	if Cfg.AimSticky and aim.target and aim.target.root.Parent and isTarget(aim.target) then
		local p = pickPart(aim.target, origin, center, Cfg.AimFOV * 1.25)
		if p then tgt, tpart = aim.target, p end
	end
	if not tgt then tgt, tpart = findTarget(origin, center) end
	aim.target = tgt
	aim.prevLook = look
	if not tgt then
		aim.sentX, aim.sentY, aim.status = 0, 0, "no target"
		return
	end

	local sp = Camera:WorldToViewportPoint(leadPos(tgt, tpart))
	local dx, dy = sp.X - center.X, sp.Y - center.Y
	if math.abs(dx) < 1 and math.abs(dy) < 1 then
		aim.sentX, aim.sentY, aim.status = 0, 0, "locked"
		return
	end
	local f = focalPx(vp)
	local ax, ay = math.deg(math.atan(dx / f)), math.deg(math.atan(dy / f))
	local step = math.min((Cfg.AimSpeed / 100) / math.max(Cfg.AimSmooth, 1), 0.85)
	local cx = ax * step / aim.est + aim.remX
	local cy = ay * step / aim.est + aim.remY
	cx, cy = math.clamp(cx, -150, 150), math.clamp(cy, -150, 150)
	local ix = cx >= 0 and math.floor(cx) or math.ceil(cx)
	local iy = cy >= 0 and math.floor(cy) or math.ceil(cy)
	aim.remX, aim.remY = cx - ix, cy - iy
	aim.sentX, aim.sentY, aim.status = ix, iy, "aiming"
	if ix ~= 0 or iy ~= 0 then mousemoverel(ix, iy) end
end)
cleanup(function() aim.target = nil end)

-- triggerbot: clicks when the camera ray lands on a target player
local function holdingGun()
	local c = LP.Character
	local t = c and c:FindFirstChildOfClass("Tool")
	return t ~= nil and t.Name ~= "Fists" and t.Name ~= "Car Keys" and not t.Name:find("Phone")
end
local trig = { since = nil, lastShot = 0 }
onRender("trigger", function()
	if not Cfg.Trigger or not meAlive() or not mouseLocked() or typing() or not holdingGun() then
		trig.since = nil
		return
	end
	local cf = Camera.CFrame
	local hit = workspace:Raycast(cf.Position, cf.LookVector * 1200, rayTrig)
	local e
	if hit then
		local m = hit.Instance:FindFirstAncestorOfClass("Model")
		while m and not cache.by[m] and m.Parent ~= workspace do m = m.Parent:FindFirstAncestorOfClass("Model") end
		e = m and cache.by[m]
		if e and not isTarget(e) then e = nil end
		if e and Cfg.TrigHead and hit.Instance.Name ~= "Head" then e = nil end
	end
	local now = os.clock()
	if e then
		trig.since = trig.since or now
		if now - trig.since >= Cfg.TrigDelay / 1000 and now - trig.lastShot >= Cfg.TrigRate / 1000 then
			trig.lastShot = now
			mouse1click()
		end
	else
		trig.since = nil
	end
end)

local cross = {}
for i = 1, 4 do cross[i] = newDraw("Line", { Thickness = 1, Visible = false }) end
local crossDot = newDraw("Circle", { Filled = true, Radius = 1.5, Visible = false })
onRender("crosshair", function()
	if not Cfg.Cross then
		if cross[1].Visible then for i = 1, 4 do cross[i].Visible = false end crossDot.Visible = false end
		return
	end
	local vp = Camera.ViewportSize
	local c = V2(math.floor(vp.X / 2), math.floor(vp.Y / 2))
	local g, s = Cfg.CrossGap, Cfg.CrossSize
	local dirs = { V2(1, 0), V2(-1, 0), V2(0, 1), V2(0, -1) }
	for i = 1, 4 do
		local l = cross[i]
		P(l, "From", c + dirs[i] * g) P(l, "To", c + dirs[i] * (g + s))
		P(l, "Color", Cfg.CrossColor) P(l, "Thickness", Cfg.CrossThick) P(l, "Visible", true)
	end
	P(crossDot, "Position", c) P(crossDot, "Color", Cfg.CrossColor) P(crossDot, "Visible", Cfg.CrossDot)
end)

-- gun mods: the game reads Stats from SharedModules.Configs.GunConfig on every shot
local GunConfig = safeRequire(RS:FindFirstChild("SharedModules") and RS.SharedModules:FindFirstChild("Configs") and RS.SharedModules.Configs:FindFirstChild("GunConfig"))
local gunOrig = {}
local GUN_FIELDS = {
	spread = { "BulletSpreadDegrees", "ShotgunSpreadDegrees" },
	recoil = { "FirstPersonCameraRecoilFactor", "ThirdPersonCameraRecoilFactor" },
}
local function applyGunMods()
	if type(GunConfig) ~= "table" then return false end
	for gun, def in pairs(GunConfig) do
		if type(def) == "table" and type(def.Stats) == "table" then
			local st = def.Stats
			local orig = gunOrig[gun]
			if not orig then
				orig = {}
				for _, list in pairs(GUN_FIELDS) do
					for _, k in ipairs(list) do orig[k] = st[k] end
				end
				gunOrig[gun] = orig
			end
			for _, k in ipairs(GUN_FIELDS.spread) do
				if orig[k] ~= nil then st[k] = Cfg.NoSpread and 0 or orig[k] end
			end
			for _, k in ipairs(GUN_FIELDS.recoil) do
				if orig[k] ~= nil then st[k] = Cfg.NoRecoil and 0 or orig[k] end
			end
		end
	end
	return true
end
local function restoreGunMods()
	if type(GunConfig) ~= "table" then return end
	for gun, orig in pairs(gunOrig) do
		local def = GunConfig[gun]
		if def and def.Stats then
			for k, v in pairs(orig) do def.Stats[k] = v end
		end
	end
end
cleanup(restoreGunMods)
if Cfg.NoRecoil or Cfg.NoSpread then applyGunMods() end

-- infinite stamina: MovementController keeps stamina on the client, sprinting drains it through these two
local Movement = safeRequire(RS:FindFirstChild("ClientModules") and RS.ClientModules:FindFirstChild("MovementController"))
local staminaOrig
local function setInfStamina(on)
	if type(Movement) ~= "table" then return false end
	if on and not staminaOrig then
		staminaOrig = { Consume = Movement.ConsumeStamina, Drain = Movement.DrainStamina }
		Movement.ConsumeStamina = function() return true end
		Movement.DrainStamina = function() return 0 end
	elseif not on and staminaOrig then
		Movement.ConsumeStamina = staminaOrig.Consume
		Movement.DrainStamina = staminaOrig.Drain
		staminaOrig = nil
	end
	return true
end
cleanup(function() setInfStamina(false) end)
if Cfg.InfStamina then setInfStamina(true) end
-- sprinting and jumping drain the stamina upvalue inline (not through the functions above), so refill it every frame.
-- GetStamina's only upvalue is that stamina number; the max is 200
local staminaFn = type(Movement) == "table" and Movement.GetStamina
local canRefill = staminaFn and debug and debug.setupvalue and debug.getupvalue and pcall(function()
	assert(type(debug.getupvalue(staminaFn, 1)) == "number")
end)
frameJobs[#frameJobs + 1] = { name = "stamina", fn = function()
	if Cfg.InfStamina and canRefill and debug.getupvalue(staminaFn, 1) < 200 then
		debug.setupvalue(staminaFn, 1, Movement.GetMaxStamina and Movement:GetMaxStamina() or 200)
	end
end }

-- instant interact: hold-to-use prompts become instant (originals restored when turned off)
local promptOrig = setmetatable({}, { __mode = "k" })
local promptConn
local function patchPrompt(p)
	if p:IsA("ProximityPrompt") and p.HoldDuration > 0 then
		if promptOrig[p] == nil then promptOrig[p] = p.HoldDuration end
		p.HoldDuration = 0
	end
end
local function setInstantPrompt(on)
	if on then
		for _, d in ipairs(workspace:GetDescendants()) do patchPrompt(d) end
		if not promptConn then promptConn = workspace.DescendantAdded:Connect(function(d) if Cfg.InstantPrompt then patchPrompt(d) end end) end
	else
		if promptConn then promptConn:Disconnect() promptConn = nil end
		for p, v in pairs(promptOrig) do pcall(function() p.HoldDuration = v end) end
		table.clear(promptOrig)
	end
end
cleanup(function() setInstantPrompt(false) end)
if Cfg.InstantPrompt then task.spawn(setInstantPrompt, true) end

------------------------------------------------------------------------------------------------------
-- 9. Intel: robbery status, staff detector, police nearby, car bomb, wanted level, HUD
------------------------------------------------------------------------------------------------------
local function gameplay(name)
	local g = workspace:FindFirstChild("Gameplay")
	return g and g:FindFirstChild(name)
end
local function fmtTime(sec)
	sec = math.max(0, math.floor(sec))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

local function bankStatus()
	local b = gameplay("Bank")
	if not b then return "Bank: unknown", false end
	if b:GetAttribute("BankRobberyActive") == true then
		local bits = { "ROBBERY ACTIVE" }
		if b:GetAttribute("VaultOpen") == true then bits[#bits + 1] = "vault open" end
		if b:GetAttribute("BankVaultC4Armed") == true then bits[#bits + 1] = "C4 armed" end
		return "Bank: " .. table.concat(bits, ", "), true
	end
	return "Bank: " .. (b:GetAttribute("BankOpen") == true and "open" or "closed"), false
end
local function jewelStatus()
	local j = gameplay("JewelleryStore")
	if not j then return "Jewellery: unknown", false end
	if j:GetAttribute("JewelleryRobberyActive") == true then
		return "Jewellery: ROBBERY ACTIVE" .. (j:GetAttribute("JewelleryDoorsBlown") == true and ", doors blown" or ""), true
	end
	local reopen = tonumber(j:GetAttribute("JewelleryReopenTime"))
	local left = reopen and reopen - workspace:GetServerTimeNow()
	if left and left > 0 then return "Jewellery: closed, reopens in " .. fmtTime(left), false end
	return "Jewellery: open", false
end

local intel = { lawNear = 0, lawNearest = nil, staff = {}, lawCount = 0, wantedCount = 0 }

-- staff detector
local knownStaff = {}
local function serverHop() end -- defined in section 10, forward-declared for staff auto leave
local hopRef = { fn = nil }
every("staff", 2, function()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and isStaff(p) then
			list[#list + 1] = p.Name
			if not knownStaff[p] then
				knownStaff[p] = true
				if Cfg.StaffAlert then notify("Staff in server", p.Name .. " (" .. teamName(p) .. ") is staff.", "warning") end
				if Cfg.StaffLeave and hopRef.fn then
					notify("Staff in server", "Leaving to another server...", "warning")
					task.delay(1.5, function() if alive() and Cfg.StaffLeave then hopRef.fn() end end)
				end
			end
		end
	end
	for p in pairs(knownStaff) do if p.Parent ~= Players then knownStaff[p] = nil end end
	intel.staff = list
end)

-- police nearby, team counts
local wasNear, lastNearAlert = false, -math.huge
every("lawscan", 0.4, function()
	local root = myRoot()
	local near, nearest, law, wanted = 0, nil, 0, 0
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			if LAW[teamName(p)] then law += 1 end
			if (tonumber(p:GetAttribute("WantedLevel")) or 0) > 0 then wanted += 1 end
		end
	end
	if root then
		for _, e in ipairs(cache.list) do
			if e.law and e.hum.Health > 0 then
				local d = (e.root.Position - root.Position).Magnitude
				if d <= Cfg.AlertRange then
					near += 1
					if not nearest or d < nearest then nearest = d end
				end
			end
		end
	end
	intel.lawNear, intel.lawNearest, intel.lawCount, intel.wantedCount = near, nearest, law, wanted
	local myTeamLaw = LAW[teamName(LP)] == true
	if Cfg.PoliceAlert and not myTeamLaw then
		if near > 0 and not wasNear and os.clock() - lastNearAlert > 20 then -- at most one popup per 20s
			lastNearAlert = os.clock()
			notify("Police nearby", string.format("%d law player%s within %dm", near, near == 1 and "" or "s", math.floor(Cfg.AlertRange * 0.28)), "warning")
		end
	end
	wasNear = near > 0
end)

-- robbery start alerts
local lastBank, lastJewel = nil, nil
every("robbery", 1, function()
	local _, bankOn = bankStatus()
	local _, jewelOn = jewelStatus()
	if Cfg.RobberyAlert then
		if lastBank == false and bankOn then notify("Robbery", "The bank is being robbed!", "warning") end
		if lastJewel == false and jewelOn then notify("Robbery", "The jewellery store is being robbed!", "warning") end
	end
	lastBank, lastJewel = bankOn, jewelOn
end)

-- your own vehicles: warn about a planted car bomb
local bombWarned = setmetatable({}, { __mode = "k" })
every("carbomb", 1.5, function()
	if not Cfg.BombAlert then return end
	local folder = workspace:FindFirstChild("Vehicles")
	if not folder then return end
	for _, v in ipairs(folder:GetChildren()) do
		if v:GetAttribute("OwnerUserId") == LP.UserId then
			if v:GetAttribute("CarBomb") == true then
				if not bombWarned[v] then
					bombWarned[v] = true
					notify("CAR BOMB", "Your " .. tostring(v:GetAttribute("RealVehicle") or v.Name) .. " has a bomb on it. Do not get in.", "warning")
				end
			else
				bombWarned[v] = nil
			end
		end
	end
end)

-- your wanted level changing
local lastWanted = tonumber(LP:GetAttribute("WantedLevel")) or 0
connect(LP:GetAttributeChangedSignal("WantedLevel"), function()
	local w = tonumber(LP:GetAttribute("WantedLevel")) or 0
	if Cfg.WantedAlert and w ~= lastWanted then
		notify("Wanted level", w > 0 and ("You are now wanted: level " .. w) or "You are no longer wanted.", w > lastWanted and "warning" or "info")
	end
	lastWanted = w
end)

-- HUD (top left)
-- HUD: top centre (the top-left corner belongs to Roblox's own menu buttons), on a dark panel
local hudBg = newDraw("Square", { Filled = true, Color = Color3.fromRGB(10, 12, 20), Transparency = 0.55, Thickness = 1, Visible = false })
local hudLines = {}
for i = 1, 3 do hudLines[i] = newDraw("Text", { Size = 14, Center = true, Outline = true, Font = FONT, Color = WHITE, Visible = false }) end
local fpsAvg = 60
onRender("hud", function(dt)
	fpsAvg = fpsAvg + (1 / math.max(dt, 1e-3) - fpsAvg) * 0.05
	if not Cfg.HUD then
		for i = 1, 3 do P(hudLines[i], "Visible", false) end
		P(hudBg, "Visible", false)
		return
	end
	local cx = Camera.ViewportSize.X / 2
	for i = 1, 3 do P(hudLines[i], "Position", V2(cx, 6 + (i - 1) * 17)) end
	local ping = 0
	pcall(function() ping = math.floor(LP:GetNetworkPing() * 1000 + 0.5) end)
	local w = tonumber(LP:GetAttribute("WantedLevel")) or 0
	P(hudLines[1], "Text", string.format("Furina SD  |  %d FPS  |  %d ms  |  $%s  |  %s%s", math.floor(fpsAvg + 0.5), ping, moneyOf(LP),
		teamName(LP), w > 0 and ("  |  WANTED " .. w) or ""))
	P(hudLines[1], "Color", w > 0 and Cfg.WantedColor or WHITE)
	local b, bOn = bankStatus()
	local j, jOn = jewelStatus()
	P(hudLines[2], "Text", b .. "  |  " .. j)
	P(hudLines[2], "Color", (bOn or jOn) and Color3.fromRGB(255, 190, 90) or Color3.fromRGB(190, 200, 255))
	local alert = string.format("Law online: %d  |  Wanted: %d", intel.lawCount, intel.wantedCount)
	local col = Color3.fromRGB(190, 200, 255)
	if intel.lawNear > 0 then
		alert = string.format("POLICE NEARBY: %d (closest %dm)  |  ", intel.lawNear, math.floor((intel.lawNearest or 0) * 0.28)) .. alert
		col = Color3.fromRGB(255, 90, 90)
	end
	if #intel.staff > 0 then
		alert = "STAFF: " .. table.concat(intel.staff, ", ") .. "  |  " .. alert
		col = Cfg.StaffColor
	end
	P(hudLines[3], "Text", alert) P(hudLines[3], "Color", col)
	local wMax = 0
	for i = 1, 3 do
		P(hudLines[i], "Visible", true)
		wMax = math.max(wMax, hudLines[i].TextBounds.X)
	end
	P(hudBg, "Position", V2(math.floor(cx - wMax / 2 - 10), 3)) P(hudBg, "Size", V2(math.floor(wMax + 20), 56)) P(hudBg, "Visible", true)
end)

------------------------------------------------------------------------------------------------------
-- 10. World, performance, misc
------------------------------------------------------------------------------------------------------
onRender("fov", function()
	if Cfg.FOVOn and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		Camera.FieldOfView = Cfg.FOV
	end
end)

local lightSaved
local function applyLight(on)
	if on then
		if not lightSaved then
			lightSaved = { Brightness = Lighting.Brightness, GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient }
		end
		Lighting.Brightness, Lighting.GlobalShadows = 2, false
		Lighting.Ambient, Lighting.OutdoorAmbient = Color3.fromRGB(190, 190, 190), Color3.fromRGB(190, 190, 190)
	elseif lightSaved then
		for k, v in pairs(lightSaved) do Lighting[k] = v end
		lightSaved = nil
	end
end
cleanup(function() applyLight(false) end)
every("light", 1, function() if Cfg.Fullbright then applyLight(true) end end)

-- no fog: atmosphere density and fog end, restored when turned off
local fogSaved
local function applyNoFog(on)
	if on then
		if not fogSaved then
			fogSaved = { FogEnd = Lighting.FogEnd, atmos = {} }
			for _, a in ipairs(Lighting:GetChildren()) do
				if a:IsA("Atmosphere") then fogSaved.atmos[a] = { Density = a.Density, Haze = a.Haze } end
			end
		end
		Lighting.FogEnd = 1e6
		for a in pairs(fogSaved.atmos) do pcall(function() a.Density = 0 a.Haze = 0 end) end
	elseif fogSaved then
		Lighting.FogEnd = fogSaved.FogEnd
		for a, v in pairs(fogSaved.atmos) do pcall(function() a.Density = v.Density a.Haze = v.Haze end) end
		fogSaved = nil
	end
end
cleanup(function() applyNoFog(false) end)
every("fog", 1, function() if Cfg.NoFog then applyNoFog(true) end end)

local boostSaved
local function setBoost(on)
	if on and not boostSaved then
		boostSaved = { shadows = Lighting.GlobalShadows, post = {}, quality = nil }
		Lighting.GlobalShadows = false
		for _, v in ipairs(Lighting:GetChildren()) do
			if v:IsA("PostEffect") and v.Enabled then
				boostSaved.post[#boostSaved.post + 1] = v
				v.Enabled = false
			end
		end
		pcall(function()
			boostSaved.quality = settings().Rendering.QualityLevel
			settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		end)
	elseif not on and boostSaved then
		Lighting.GlobalShadows = boostSaved.shadows
		for _, v in ipairs(boostSaved.post) do pcall(function() v.Enabled = true end) end
		if boostSaved.quality then pcall(function() settings().Rendering.QualityLevel = boostSaved.quality end) end
		boostSaved = nil
	end
end
cleanup(function() setBoost(false) end)
local function applyFPSCap()
	if setfpscap then pcall(setfpscap, Cfg.FPSCapOn and Cfg.FPSCap or 60) end
end
cleanup(function() if setfpscap and Cfg.FPSCapOn then pcall(setfpscap, 60) end end)

-- anti AFK: the game's own activity report, plus Roblox's idle kick
local AfkRemote
task.spawn(function()
	local remotes = RS:FindFirstChild("SharedModules") and RS.SharedModules:FindFirstChild("Pronghorn") and RS.SharedModules.Pronghorn:FindFirstChild("Remotes")
	local mod = safeRequire(remotes, 5)
	if type(mod) == "table" and type(mod.Client) == "table" then AfkRemote = mod.Client.AfkService end
end)
local lastInput = os.clock()
connect(UserInputService.InputBegan, function() lastInput = os.clock() end)
every("antiafk", 30, function()
	if not Cfg.AntiAFK or os.clock() - lastInput < 120 then return end
	if AfkRemote then pcall(function() AfkRemote:ReportActivity() end) end
end)
connect(LP.Idled, function()
	if Cfg.AntiAFK then
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end
end)

-- spectate
local spectating
local function stopSpectate()
	spectating = nil
	local h = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	if h then Camera.CameraSubject = h end
end
local function spectate(p)
	local h = p and p.Character and p.Character:FindFirstChildOfClass("Humanoid")
	if not h then return false end
	spectating = p
	Camera.CameraSubject = h
	return true
end
every("spectate", 0.5, function()
	if spectating then
		local h = spectating.Character and spectating.Character:FindFirstChildOfClass("Humanoid")
		if spectating.Parent ~= Players then stopSpectate()
		elseif h and Camera.CameraSubject ~= h then Camera.CameraSubject = h end
	end
end)
cleanup(function() if spectating then stopSpectate() end end)

local function panic()
	for _, k in ipairs({ "ESP", "VehESP", "LocESP", "DropESP", "Aim", "Trigger", "Cross", "HUD", "FOVOn", "Fullbright", "NoFog",
		"NoRecoil", "NoSpread", "InfStamina", "InstantPrompt" }) do
		setToggle(k, false)
	end
	applyLight(false) applyNoFog(false)
	restoreGunMods() setInfStamina(false) setInstantPrompt(false)
	hideAllESP()
	for _, l in pairs(labels) do hideLabel(l) end
	if spectating then stopSpectate() end
	if hubRefs.stopFarm then hubRefs.stopFarm("Panic") end
	notify("Panic", "Every feature is off.", "warning")
end

connect(UserInputService.InputBegan, function(input)
	if not alive() or typing() or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local k = input.KeyCode
	if k == Cfg.PanicKey then panic()
	elseif k == Cfg.ESPKey then setToggle("ESP", not Cfg.ESP)
	elseif k == Cfg.AimKeyToggle then setToggle("Aim", not Cfg.Aim)
	elseif k == Cfg.TrigKey then setToggle("Trigger", not Cfg.Trigger) end
end)

serverHop = function()
	local ok, res = pcall(function()
		return HttpService:JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Desc&limit=100"))
	end)
	if not ok or type(res) ~= "table" or type(res.data) ~= "table" then
		notify("Server Hop", "Could not read the server list.", "warning")
		return
	end
	local pool = {}
	for _, s in ipairs(res.data) do
		if s.id ~= game.JobId and s.playing and s.maxPlayers and s.playing < s.maxPlayers - 1 then pool[#pool + 1] = s.id end
	end
	if #pool == 0 then
		notify("Server Hop", "No open server found.", "warning")
		return
	end
	TeleportService:TeleportToPlaceInstance(game.PlaceId, pool[math.random(#pool)], LP)
end
hopRef.fn = serverHop

local lastSig, sinceForce, saveFailedNotified = signature(), 0, false
every("autosave", 1.5, function()
	sinceForce += 1.5
	if not Cfg.AutoSave then return end
	local sig = signature()
	if sig ~= lastSig or sinceForce >= 30 then
		local ok, err = saveCfg()
		if ok then
			lastSig, sinceForce, saveFailedNotified = sig, 0, false
		elseif not saveFailedNotified then
			saveFailedNotified = true
			notify("Auto Save failed", tostring(err), "warning")
		end
	end
end)
cleanup(function() if Cfg.AutoSave then saveCfg() end end)

-- player lists for the Intel tab
local function playerNames()
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do if p ~= LP then t[#t + 1] = p.Name end end
	table.sort(t, function(a, b) return a:lower() < b:lower() end)
	if #t == 0 then t[1] = "(nobody)" end
	return t
end
local function findPlayer(name)
	if not name or name == "" then return nil end
	local exact = Players:FindFirstChild(name)
	if exact then return exact end
	name = name:lower()
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Name:lower():sub(1, #name) == name or p.DisplayName:lower():sub(1, #name) == name then return p end
	end
	return nil
end
local function describe(p)
	local e = cache.byPlayer[p]
	local root = myRoot()
	local dist = (e and root) and string.format("%dm away", math.floor((e.root.Position - root.Position).Magnitude * 0.28)) or "not streamed in (far away)"
	local w = tonumber(p:GetAttribute("WantedLevel")) or 0
	local tool = e and e.tool
	local hp = e and string.format("%d/%d hp", math.floor(e.hum.Health), math.floor(e.hum.MaxHealth)) or "? hp"
	return string.format("%s | %s - %s | $%s | wanted %d | %s | %s%s%s",
		p.DisplayName, teamName(p), tostring(p:GetAttribute("CurrentRankName") or "?"), moneyOf(p), w, hp, dist,
		tool and (" | holding " .. tool) or "", isStaff(p) and " | STAFF" or "")
end

------------------------------------------------------------------------------------------------------
-- 10b. Farms
-- Honest jobs only, done the way a player does them: the character really walks (sprint speed, the anti-cheat
-- cap) and each step calls the same remote the game's own prompt calls. Timing is randomised and the farm takes
-- breaks, because the server watches for teleporting job legs, machine-timed cycles and non-stop throughput.
------------------------------------------------------------------------------------------------------
local farm, startFarm, stopFarm, walkTo, exactMoney, purgeCount, fmtMoney, dailyQuestText
do
local CS = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local GameClient, PDC
task.spawn(function()
	local sm = RS:FindFirstChild("SharedModules")
	local remotes = sm and sm:FindFirstChild("Pronghorn") and sm.Pronghorn:FindFirstChild("Remotes")
	local mod = safeRequire(remotes, 6)
	if type(mod) == "table" then GameClient = mod.Client end
	local cm = RS:FindFirstChild("ClientModules")
	PDC = safeRequire(cm and cm:FindFirstChild("PlayerDataController"), 6)
end)

local function playerData()
	if type(PDC) ~= "table" then return nil end
	local ok, d = pcall(function() return PDC:GetPlayerData() end)
	return ok and type(d) == "table" and d or nil
end
exactMoney = function()
	local d = playerData()
	return d and d.Currency and tonumber(d.Currency.Money) or moneyNum(moneyOf(LP))
end
purgeCount = function()
	local d = playerData()
	return d and d.ExploitPurgeState and tonumber(d.ExploitPurgeState.Count) or 0
end
fmtMoney = function(n)
	n = math.floor((n or 0) + 0.5)
	local s = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (n < 0 and "-$" or "$") .. s
end

farm = { on = false, status = "Idle", cycles = 0, startMoney = 0, startAt = 0, nextBreak = 0, walking = false, gen = 0 }
local PACE = { -- seconds of "thinking" before each action: min, max
	Human = { 0.45, 1.6 }, Relaxed = { 0.9, 2.6 }, Quick = { 0.25, 0.8 },
}
local function think()
	local p = PACE[Cfg.FarmPace] or PACE.Human
	return p[1] + (p[2] - p[1]) * ((math.random() + math.random() + math.random()) / 3) -- bell-shaped, never a fixed beat
end
local function fwait(sec, gen)
	local t = os.clock() + sec
	while os.clock() < t do
		if not farm.on or farm.gen ~= gen or not alive() then return false end
		task.wait(0.05)
	end
	return true
end
local function setStatus(s) farm.status = s end

-- keep sprinting while the farm walks (MovementController.MoveTo stops sprint at the start of every leg)
frameJobs[#frameJobs + 1] = { name = "farmsprint", fn = function()
	if farm.walking and Cfg.FarmSprint and type(Movement) == "table" and not Movement:GetIsSprinting() then
		pcall(function() Movement:StartSprinting() end)
	end
end }

-- walk with the game's own scripted mover along a pathfinding route
walkTo = function(pos, arrive, gen, maxTime)
	local c = LP.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local root = c and c:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or type(Movement) ~= "table" then return false end
	arrive = arrive or 3
	local function flatDist() local d = pos - root.Position return Vector3.new(d.X, 0, d.Z).Magnitude end
	if flatDist() <= arrive then return true end
	if hum.SeatPart then hum.Sit = false task.wait(0.3) end

	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5.5, AgentCanJump = true, WaypointSpacing = 7 })
	local ok = pcall(function() path:ComputeAsync(root.Position, pos) end)
	local points = {}
	if ok and path.Status == Enum.PathStatus.Success then
		for i, wp in ipairs(path:GetWaypoints()) do if i > 1 then points[#points + 1] = wp end end
	end
	if #points == 0 then points = { { Position = pos, Action = Enum.PathWaypointAction.Walk } } end

	farm.walking = true
	local deadline = os.clock() + (maxTime or 60)
	for _, wp in ipairs(points) do
		if not farm.on or farm.gen ~= gen or os.clock() > deadline then break end
		if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
		pcall(function() Movement:MoveTo(CFrame.new(wp.Position), 4) end)
		if flatDist() <= arrive then break end
	end
	farm.walking = false
	return flatDist() <= arrive + 1
end

-- long trips are split into legs so pathfinding never has to plan across unloaded parts of the map
local function travelTo(pos, gen)
	local root = myRoot()
	if not root then return false end
	local tries = 0
	while farm.on and farm.gen == gen and tries < 60 do
		local d = pos - root.Position
		local flat = Vector3.new(d.X, 0, d.Z)
		if flat.Magnitude <= 40 then return true end
		local step = flat.Magnitude > 220 and (root.Position + flat.Unit * 200) or pos
		setStatus(string.format("Walking to the job (%dm left)", math.floor(flat.Magnitude * 0.28)))
		local before = root.Position
		walkTo(step, 6, gen, 25)
		if (root.Position - before).Magnitude < 4 then
			tries += 4 -- stuck: hop and try a slightly different line
			local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
			if hum then hum.Jump = true end
		else
			tries += 1
		end
	end
	return false
end

local function takeBreakIfDue(gen)
	if not Cfg.FarmBreaks then return true end
	if farm.cycles >= farm.nextBreak then
		local secs = math.random(25, 75)
		setStatus("Taking a short break (" .. secs .. "s)")
		if not fwait(secs, gen) then return false end
		farm.nextBreak = farm.cycles + math.random(12, 28)
	end
	return true
end

-- Box delivery (EZ Mart): grab a box, carry it to the drop-off 33 studs away, deliver
local BOX_SPOT = Vector3.new(400, 18, 312)
local function boxParts()
	return CS:GetTagged("BoxFetchPrompt")[1], CS:GetTagged("BoxDeliverPrompt")[1]
end
local function boxCycle(gen)
	local fetch, deliver = boxParts()
	local root = myRoot()
	if not (fetch and deliver) or not root or (root.Position - BOX_SPOT).Magnitude > 120 then
		if not Cfg.FarmTravel then
			setStatus("Go to the EZ Mart box job (the Job marker) or turn on Walk To Job")
			return fwait(3, gen)
		end
		if not travelTo(BOX_SPOT, gen) then return fwait(2, gen) end
		return true
	end
	setStatus("Fetching a box")
	if not walkTo(fetch.Position, 5, gen, 15) then return fwait(1, gen) end
	if not fwait(think(), gen) then return false end
	pcall(function() GameClient.BoxJobService:FetchBox(fetch) end)
	if not fwait(think() * 0.7, gen) then return false end
	setStatus("Delivering the box")
	if not walkTo(deliver.Position, 5, gen, 15) then return fwait(1, gen) end
	if not fwait(think(), gen) then return false end
	pcall(function() GameClient.BoxJobService:DeliverBox(deliver) end)
	farm.cycles += 1
	return fwait(think() * 0.5, gen)
end

-- Taco Hell: walk onto a free spill, start mopping, wait until the mop finishes
local TACO_SPOT = Vector3.new(0, 15, 268)
local mopUntil = 0
local mopConn
local skipPuddle = setmetatable({}, { __mode = "k" })
local function puddleAnchor(m)
	local a = m:FindFirstChild("PromptAttachment", true)
	if a and a:IsA("Attachment") then return a.WorldPosition end
	return m.PrimaryPart and m.PrimaryPart.Position or m:GetPivot().Position
end
local function tacoCycle(gen)
	if not mopConn and GameClient and GameClient.TacoHellService then
		pcall(function()
			mopConn = GameClient.TacoHellService.CleanPuddleStarted:Connect(function(dur)
				mopUntil = os.clock() + (tonumber(dur) or 5)
			end)
		end)
	end
	local root = myRoot()
	if not root then return fwait(1, gen) end
	if (root.Position - TACO_SPOT).Magnitude > 150 then
		if not Cfg.FarmTravel then
			setStatus("Go to Taco Hell or turn on Walk To Job")
			return fwait(3, gen)
		end
		if not travelTo(TACO_SPOT, gen) then return fwait(2, gen) end
		return true
	end
	local best, bestD
	for _, m in ipairs(CS:GetTagged("TacoHellPuddle")) do
		if m.Parent and m:IsA("Model") and m:GetAttribute("BeingCleaned") ~= true and (skipPuddle[m] or 0) < os.clock() then
			local d = (puddleAnchor(m) - root.Position).Magnitude
			if d < 200 and (not bestD or d < bestD) then best, bestD = m, d end
		end
	end
	if not best then
		setStatus("No spills right now, waiting for a new one")
		return fwait(2 + math.random() * 3, gen)
	end
	setStatus("Walking to a spill")
	if not walkTo(puddleAnchor(best), 2.5, gen, 20) then
		skipPuddle[best] = os.clock() + 8
		return fwait(0.5, gen)
	end
	if not fwait(think(), gen) then return false end
	mopUntil = 0
	local sent = os.clock()
	pcall(function() GameClient.TacoHellService:StartCleanPuddle(best) end)
	while mopUntil == 0 and os.clock() - sent < 2.5 do
		if not fwait(0.1, gen) then return false end
	end
	if mopUntil == 0 then -- the server did not start a mop (someone else took it, or out of range)
		skipPuddle[best] = os.clock() + 6
		return fwait(0.5, gen)
	end
	setStatus("Mopping")
	if not fwait(math.max(0, mopUntil - os.clock()) + 0.3, gen) then return false end
	farm.cycles += 1
	return fwait(think() * 0.6, gen)
end
cleanup(function() if mopConn then pcall(function() mopConn:Disconnect() end) end end)

local FARMS = { ["Box Delivery"] = boxCycle, ["Taco Hell Mopping"] = tacoCycle }

stopFarm = function(reason)
	if not farm.on then return end
	farm.on = false
	farm.gen += 1
	farm.walking = false
	setStatus(reason or "Stopped")
	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	if hum then pcall(function() hum:Move(Vector3.zero) end) end
	notify("Farm", (reason or "Stopped") .. string.format(" | earned %s in %d jobs", fmtMoney(exactMoney() - farm.startMoney), farm.cycles))
end

startFarm = function()
	if farm.on then return end
	if not GameClient or type(Movement) ~= "table" then
		notify("Farm", "Game modules are still loading, try again in a few seconds.", "warning")
		return
	end
	if teamName(LP) ~= "Civilian" then
		notify("Farm", "These jobs are for civilians. Switch to the Civilian team first.", "warning")
		return
	end
	farm.on = true
	farm.gen += 1
	local gen = farm.gen
	farm.cycles, farm.startMoney, farm.startAt = 0, exactMoney(), os.clock()
	farm.nextBreak = math.random(12, 28)
	if not Cfg.InfStamina and Cfg.FarmSprint then setToggle("InfStamina", true) end
	notify("Farm", "Started " .. Cfg.FarmJob .. ". Moving your mouse or keys will not stop it; use the switch or the panic key.")
	task.spawn(function()
		while farm.on and farm.gen == gen and alive() do
			if Cfg.FarmMaxMin > 0 and os.clock() - farm.startAt > Cfg.FarmMaxMin * 60 then
				stopFarm("Session limit reached")
				break
			end
			if Cfg.FarmStaffStop and #intel.staff > 0 then
				stopFarm("Staff joined the server")
				break
			end
			if teamName(LP) ~= "Civilian" then
				stopFarm("You are no longer a civilian")
				break
			end
			if not meAlive() then
				setStatus("Waiting to respawn")
				fwait(2, gen)
			else
				local fn = FARMS[Cfg.FarmJob] or boxCycle
				local ok, err = pcall(fn, gen)
				if not ok then
					warn("[Furina SD] farm: " .. tostring(err))
					fwait(2, gen)
				end
				if farm.on and farm.gen == gen and not takeBreakIfDue(gen) then break end
			end
		end
	end)
end
cleanup(function() farm.on = false farm.gen += 1 end)
hubRefs.stopFarm = stopFarm

-- cash magnet: when you are standing around, walk over to dropped cash nearby (the game collects it on contact)
every("cashmagnet", 1, function()
	if not Cfg.FarmCash or farm.on or not meAlive() then return end
	local root = myRoot()
	local drops = workspace:FindFirstChild("Drops")
	if not (root and drops) then return end
	local hum = LP.Character:FindFirstChildOfClass("Humanoid")
	if hum.SeatPart or hum.MoveDirection.Magnitude > 0.1 then return end -- never fight the player
	local best, bestD
	for _, d in ipairs(drops:GetChildren()) do
		if d.Name:lower():find("cash") then
			local pos = d:IsA("BasePart") and d.Position or (d:IsA("Model") and d:GetPivot().Position)
			local dist = pos and (pos - root.Position).Magnitude
			if dist and dist <= Cfg.FarmCashRange and (not bestD or dist < bestD) then best, bestD = pos, dist end
		end
	end
	if best and type(Movement) == "table" then
		task.spawn(function() pcall(function() Movement:MoveTo(CFrame.new(best), 6) end) end)
	end
end)

-- daily reward: claims it once it is ready (cash rewards; XP rewards still need you to pick a team in the game)
every("dailyreward", 300, function()
	if not Cfg.AutoDaily or not GameClient then return end
	task.spawn(function()
		local ok, got, reason = pcall(function() return GameClient.DailyRewardService:ClaimDailyReward() end)
		if ok and got == true then notify("Daily reward", "Claimed today's daily reward.", "check_circle") end
	end)
end)

dailyQuestText = function()
	if not GameClient then return "Daily tasks: loading" end
	local ok, q = pcall(function() return GameClient.DailyQuestService:GetDailyQuests() end)
	if not ok or type(q) ~= "table" or type(q.Slots) ~= "table" then return "Daily tasks: unavailable" end
	local bits = {}
	for _, s in ipairs(q.Slots) do
		bits[#bits + 1] = tostring(s.Id) .. (s.Completed and " (done)" or "")
	end
	local left = tonumber(q.ResetTimestamp) and (q.ResetTimestamp - workspace:GetServerTimeNow())
	return "Daily tasks: " .. table.concat(bits, ", ") .. (left and left > 0 and (" | reset in " .. fmtTime(left)) or "")
end
end

------------------------------------------------------------------------------------------------------
-- 11. UI
------------------------------------------------------------------------------------------------------
local Window = UI:CreateWindow({
	Name = "Furina Hub",
	Subtitle = "San Diego Roleplay",
	LogoID = "6031097225",
	LoadingEnabled = false,
	ConfigSettings = { ConfigFolder = "FurinaHub" },
	KeySystem = false,
})
cleanup(function() pcall(function() UI:Destroy() end) end)
WindowRef.w = Window

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
		Name = name, Range = { lo, hi }, Increment = 1,
		CurrentValue = math.clamp(math.floor(Cfg[key] + 0.5), lo, hi),
		Callback = function(v) Cfg[key] = v if cb then cb(v) end end,
	})
end
local function dd(t, name, key, options, desc)
	return t:CreateDropdown({
		Name = name, Description = desc, Options = options, CurrentOption = { Cfg[key] }, MultipleOptions = false,
		Callback = function(o) Cfg[key] = type(o) == "table" and o[1] or o end,
	})
end
local function bind(t, name, desc, key)
	t:CreateBind({
		Name = name, Description = desc, CurrentBind = Cfg[key].Name, Callback = function() end,
		OnChangedCallback = function(k) if typeof(k) == "EnumItem" then Cfg[key] = k end end,
	})
end
local function picker(t, name, key)
	t:CreateColorPicker({ Name = name, Color = Cfg[key], Callback = function(c) Cfg[key] = c end })
end
local function refreshUI()
	for key, t in pairs(Toggles) do pcall(function() t:Set(Cfg[key]) end) end
	for key, s in pairs(Sliders) do pcall(function() s:Set(Cfg[key]) end) end
end

local playerDD
do
-- Combat -----------------------------------------------------------------------------------------------
local CombatTab = tab("Combat", "combat")
head(CombatTab, "Aimbot")
tog(CombatTab, "Aimbot", "Aim", "Turns your camera onto the target while the aim key is held. Your gun fires normally, so the server sees a real shot")
dd(CombatTab, "Aim Key", "AimKey", { "Right Mouse", "Left Mouse", "Mouse 4", "Left Alt", "Q", "Always On" })
dd(CombatTab, "Targets", "AimTargets", { "Not My Team", "Everyone", "Police & Gov", "Civilians", "Wanted Only" }, "Who the aimbot and triggerbot will lock onto")
dd(CombatTab, "Aim At", "AimPart", { "Auto", "Head", "Chest", "Pelvis", "Nearest" }, "Auto = head, body when the head is hidden")
dd(CombatTab, "Target Priority", "AimPriority", { "Crosshair", "Distance", "Lowest HP" })
sld(CombatTab, "FOV (px)", "AimFOV", 20, 800)
tog(CombatTab, "Show FOV Circle", "ShowFOV")
sld(CombatTab, "Smoothness", "AimSmooth", 1, 30)
sld(CombatTab, "Aim Speed %", "AimSpeed", 10, 300)
sld(CombatTab, "Prediction (ms)", "AimLead", 0, 200)
sld(CombatTab, "Max Distance (studs)", "AimMax", 50, 2000)
tog(CombatTab, "Visible Only", "AimVis", "Ignores players behind walls")
tog(CombatTab, "Sticky Target", "AimSticky", "Stays on one player until they die or leave the circle")
tog(CombatTab, "Auto Calibrate", "AutoCal", "Learns your mouse sensitivity as you aim. Turn off and use Aim Speed % if it misbehaves")
bind(CombatTab, "Aimbot Toggle Key", "Press to switch the aimbot on or off", "AimKeyToggle")
CombatTab:CreateButton({ Name = "Aim Status", Description = "Shows what the aimbot is doing right now", Callback = function()
	notify("Aimbot", string.format("%s | target: %s | %.3f deg per mouse count", aim.status, aim.target and aim.target.name or "none", aim.est))
end })
head(CombatTab, "Gun Mods")
tog(CombatTab, "No Recoil", "NoRecoil", "Removes camera kick on every gun", applyGunMods)
tog(CombatTab, "No Spread", "NoSpread", "Every bullet goes exactly where you aim, shotgun pellets too", applyGunMods)
head(CombatTab, "Triggerbot")
tog(CombatTab, "Triggerbot", "Trigger", "Clicks for you when your crosshair is on a target (only while holding a gun)")
sld(CombatTab, "Reaction Delay (ms)", "TrigDelay", 0, 400)
sld(CombatTab, "Time Between Shots (ms)", "TrigRate", 30, 600)
tog(CombatTab, "Head Only", "TrigHead")
bind(CombatTab, "Triggerbot Toggle Key", "Press to switch the triggerbot on or off", "TrigKey")
head(CombatTab, "Crosshair")
tog(CombatTab, "Custom Crosshair", "Cross")
sld(CombatTab, "Size", "CrossSize", 2, 30)
sld(CombatTab, "Gap", "CrossGap", 0, 20)
sld(CombatTab, "Thickness", "CrossThick", 1, 4)
tog(CombatTab, "Center Dot", "CrossDot")
picker(CombatTab, "Crosshair Color", "CrossColor")
end

do
-- ESP --------------------------------------------------------------------------------------------------
local ESPTab = tab("ESP", "esp")
head(ESPTab, "Who to show")
tog(ESPTab, "Player ESP", "ESP", "Master switch for player ESP")
bind(ESPTab, "ESP Key", "Press to toggle player ESP", "ESPKey")
sld(ESPTab, "Max Distance (studs)", "ESPMax", 100, 5000)
tog(ESPTab, "Police & Government", "ShowLaw", "Police, FBI, SWAT, STRIKE, Army, Coast Guard and Checkpoint Authority")
tog(ESPTab, "Civilians", "ShowCivs")
tog(ESPTab, "Wanted Civilians Only", "WantedOnly", "Hides civilians with no wanted level")
tog(ESPTab, "My Team", "ShowTeam")
tog(ESPTab, "Hide ESP While Menu Is Open", "HideInMenu", "Keeps boxes and labels off the menu while you use it")
head(ESPTab, "Look")
tog(ESPTab, "Boxes", "Box")
dd(ESPTab, "Box Style", "BoxStyle", { "Corners", "Full" })
sld(ESPTab, "Box Thickness", "BoxThick", 1, 4)
tog(ESPTab, "Chams", "Chams", "Highlights players through walls")
sld(ESPTab, "Chams Fill (% see-through)", "ChamsFill", 0, 100)
tog(ESPTab, "Skeleton", "Skeleton")
sld(ESPTab, "Skeleton Range", "SkelDist", 50, 800)
tog(ESPTab, "Tracers", "Tracers")
dd(ESPTab, "Tracer Origin", "TracerOrigin", { "Bottom", "Center", "Mouse" })
tog(ESPTab, "Off-Screen Arrows", "Arrows")
head(ESPTab, "Info")
tog(ESPTab, "Names", "Name")
tog(ESPTab, "Team and Rank", "Rank", "Adds [Team - Rank] after the name")
tog(ESPTab, "Health Bar", "Health")
tog(ESPTab, "Distance", "Distance")
tog(ESPTab, "Money", "Money", "Their cash, read from the game's own stat")
tog(ESPTab, "Wanted Level", "Wanted")
tog(ESPTab, "Held Item", "Tool", "The gun or item in their hands")
sld(ESPTab, "Text Size", "TextSize", 9, 20)
head(ESPTab, "Colors")
dd(ESPTab, "Color Mode", "ColorMode", { "Role", "Team" }, "Role = law / civilian / wanted colors. Team = the game's team colors. Staff always use the staff color")
picker(ESPTab, "Law Color", "LawColor")
picker(ESPTab, "Civilian Color", "CivColor")
picker(ESPTab, "Wanted Color", "WantedColor")
picker(ESPTab, "Staff Color", "StaffColor")
end

do
-- World ------------------------------------------------------------------------------------------------
local WorldTab = tab("World", "visuals")
head(WorldTab, "Vehicles")
tog(WorldTab, "Vehicle ESP", "VehESP", "Model, owner, health, fuel, locked and car bombs")
tog(WorldTab, "Show Owners", "VehOwners")
tog(WorldTab, "Show My Vehicles", "VehMine", "Your own cars in green")
sld(WorldTab, "Vehicle Range (studs)", "VehMax", 100, 3000)
sld(WorldTab, "Full Details Within (studs)", "VehDetail", 50, 1500)
head(WorldTab, "Locations")
tog(WorldTab, "Location ESP", "LocESP", "Markers with distance for the places you pick below")
local locDD = WorldTab:CreateDropdown({
	Name = "Locations", Description = "Places from the game's own map", Options = #waypointNames > 0 and waypointNames or { "Bank" },
	CurrentOption = Cfg.Locations, MultipleOptions = true,
	Callback = function(o) Cfg.Locations = type(o) == "table" and o or { o } end,
})
head(WorldTab, "Pickups")
tog(WorldTab, "Drop ESP", "DropESP", "Collectibles and dropped items lying in the world")
head(WorldTab, "Lighting and camera")
tog(WorldTab, "Fullbright", "Fullbright", nil, applyLight)
tog(WorldTab, "No Fog", "NoFog", nil, applyNoFog)
tog(WorldTab, "Custom FOV", "FOVOn", "Not applied while you aim down sights", function(v) if not v then Camera.FieldOfView = 70 end end)
sld(WorldTab, "FOV", "FOV", 50, 120)
end

do
-- Intel ------------------------------------------------------------------------------------------------
local IntelTab = tab("Intel", "info")
head(IntelTab, "Live")
local liveServer = IntelTab:CreateLabel({ Text = "Server: ...", Style = 2 })
local liveRob = IntelTab:CreateLabel({ Text = "Robberies: ...", Style = 2 })
local liveMe = IntelTab:CreateLabel({ Text = "You: ...", Style = 2 })
every("intellabels", 1, function()
	local teams = {}
	for _, t in ipairs(game:GetService("Teams"):GetTeams()) do
		local n = #t:GetPlayers()
		if n > 0 then teams[#teams + 1] = t.Name .. " " .. n end
	end
	pcall(function() liveServer:Set("Server: " .. #Players:GetPlayers() .. " players | " .. table.concat(teams, ", ") .. (#intel.staff > 0 and (" | STAFF: " .. table.concat(intel.staff, ", ")) or "")) end)
	pcall(function() liveRob:Set(bankStatus() .. " | " .. jewelStatus()) end)
	local st = (type(Movement) == "table" and Movement.GetStamina) and math.floor(Movement:GetStamina()) or "?"
	pcall(function() liveMe:Set(string.format("You: %s | %s - %s | wanted %d | stamina %s | account resets: %d", fmtMoney(exactMoney()), teamName(LP),
		tostring(LP:GetAttribute("CurrentRankName") or "?"), tonumber(LP:GetAttribute("WantedLevel")) or 0, tostring(st), purgeCount())) end)
end)
head(IntelTab, "Alerts")
tog(IntelTab, "On-Screen HUD", "HUD", "Top-left: FPS, ping, money, robberies, police nearby and staff")
tog(IntelTab, "Staff Alert", "StaffAlert", "Notifies you when a developer or moderator is in the server")
tog(IntelTab, "Leave When Staff Joins", "StaffLeave", "Hops to another server as soon as staff is detected")
tog(IntelTab, "Police Nearby Alert", "PoliceAlert", "Warns when law players come close (not while you are law yourself)")
sld(IntelTab, "Alert Range (studs)", "AlertRange", 30, 600)
tog(IntelTab, "Robbery Alert", "RobberyAlert", "Bank or jewellery store robbery starting")
tog(IntelTab, "Car Bomb Alert", "BombAlert", "Someone planted a bomb on your car")
tog(IntelTab, "Wanted Level Alert", "WantedAlert")
head(IntelTab, "Players")
local selected = playerNames()[1]
playerDD = IntelTab:CreateDropdown({
	Name = "Player", Options = playerNames(), CurrentOption = { selected }, MultipleOptions = false,
	Callback = function(o) selected = type(o) == "table" and o[1] or o end,
})
local pendingRefresh = false
local function queuePlayerRefresh()
	if pendingRefresh then return end
	pendingRefresh = true
	task.delay(1, function()
		pendingRefresh = false
		if alive() and playerDD and playerDD.Refresh then pcall(function() playerDD:Refresh(playerNames()) end) end
	end)
end
connect(Players.PlayerAdded, queuePlayerRefresh)
connect(Players.PlayerRemoving, queuePlayerRefresh)
local typedName = ""
IntelTab:CreateInput({ Name = "Or Type a Name", Description = "Start of a username or display name", CurrentValue = "", PlaceholderText = "name",
	Callback = function(v) typedName = v end })
local function chosen()
	return findPlayer(typedName ~= "" and typedName or selected)
end
IntelTab:CreateButton({ Name = "Inspect", Description = "Team, rank, money, wanted level, health, distance and held item", Callback = function()
	local p = chosen()
	notify("Inspect", p and describe(p) or "Player not found", p and "info" or "warning")
end })
IntelTab:CreateButton({ Name = "Spectate", Callback = function()
	local p = chosen()
	if p and spectate(p) then notify("Spectate", "Watching " .. p.Name) else notify("Spectate", "Their character is not loaded near you", "warning") end
end })
IntelTab:CreateButton({ Name = "Stop Spectating", Callback = stopSpectate })
head(IntelTab, "Lists")
local function listBy(filter, fmt, sortFn)
	local rows = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and filter(p) then rows[#rows + 1] = p end
	end
	if sortFn then table.sort(rows, sortFn) end
	local out = {}
	for i, p in ipairs(rows) do
		if i > 12 then out[#out + 1] = "+" .. (#rows - 12) .. " more" break end
		out[#out + 1] = fmt(p)
	end
	return #out > 0 and table.concat(out, ", ") or "none"
end
IntelTab:CreateButton({ Name = "Wanted Players", Callback = function()
	notify("Wanted", listBy(function(p) return (tonumber(p:GetAttribute("WantedLevel")) or 0) > 0 end,
		function(p) return p.Name .. " (" .. tostring(p:GetAttribute("WantedLevel")) .. ")" end,
		function(a, b) return (a:GetAttribute("WantedLevel") or 0) > (b:GetAttribute("WantedLevel") or 0) end))
end })
IntelTab:CreateButton({ Name = "Police & Government", Callback = function()
	notify("Law", listBy(function(p) return LAW[teamName(p)] end, function(p) return p.Name .. " (" .. teamName(p) .. ")" end))
end })
IntelTab:CreateButton({ Name = "Richest Players", Callback = function()
	notify("Richest", listBy(function() return true end, function(p) return p.Name .. " $" .. moneyOf(p) end,
		function(a, b) return moneyNum(moneyOf(a)) > moneyNum(moneyOf(b)) end))
end })
IntelTab:CreateButton({ Name = "Staff In Server", Callback = function()
	notify("Staff", #intel.staff > 0 and table.concat(intel.staff, ", ") or "No staff detected (developer / moderator flags)")
end })
end

do
-- Player -----------------------------------------------------------------------------------------------
local PlayerTab = tab("Player", "move")
head(PlayerTab, "Movement")
tog(PlayerTab, "Infinite Stamina", "InfStamina", "Sprint forever. Sprint speed is the fastest the anti-cheat allows, so this is the safe speed boost",
	function(v) if not setInfStamina(v) then notify("Stamina", "Could not reach the game's movement module", "warning") end end)
PlayerTab:CreateLabel({ Text = "No speed, fly, noclip or teleport here on purpose: the server rolls those back and flags your account.", Style = 1 })
head(PlayerTab, "Interaction")
tog(PlayerTab, "Instant Interact", "InstantPrompt", "Hold-to-use prompts (shops, doors, ammo) fire instantly. The server may still time some actions",
	function(v) task.spawn(setInstantPrompt, v) end)
tog(PlayerTab, "Anti AFK", "AntiAFK", "Keeps you from being kicked or marked idle")
end

do
-- Farm -------------------------------------------------------------------------------------------------
local FarmTab = tab("Farm", "luck")
head(FarmTab, "Auto farm")
local farmLive = FarmTab:CreateLabel({ Text = "Farm: idle", Style = 2 })
local farmToggle = FarmTab:CreateToggle({
	Name = "Auto Farm", Description = "Runs the job below on its own. Your character really walks every step",
	CurrentValue = false,
	Callback = function(v) if v then startFarm() else stopFarm("Stopped") end end,
})
dd(FarmTab, "Job", "FarmJob", { "Box Delivery", "Taco Hell Mopping" }, "Box Delivery = EZ Mart (Job marker). Taco Hell Mopping = spills at Taco Hell. Civilian team only")
tog(FarmTab, "Walk To Job", "FarmTravel", "If you are far away the farm walks you there (driving there yourself is faster)")
tog(FarmTab, "Sprint", "FarmSprint", "Sprints between stops, with infinite stamina. Sprint speed is the anti-cheat's limit, so it is never faster than a player")
dd(FarmTab, "Pace", "FarmPace", { "Relaxed", "Human", "Quick" }, "Random pauses before each action. Quick earns more but looks less human")
head(FarmTab, "Safety")
tog(FarmTab, "Take Breaks", "FarmBreaks", "Pauses 25-75s every 12-28 jobs. The server flags sustained non-stop job throughput")
sld(FarmTab, "Stop After (minutes, 0 = never)", "FarmMaxMin", 0, 240)
tog(FarmTab, "Stop When Staff Joins", "FarmStaffStop")
FarmTab:CreateLabel({ Text = "The server watches farming (teleporting job legs, machine timing, non-stop runs) and can reset accounts. These farms walk, randomise and rest, but nothing can promise zero risk. Watch the account reset counter in Intel.", Style = 1 })
head(FarmTab, "Extras")
tog(FarmTab, "Cash Magnet", "FarmCash", "When you stand still, walks you to dropped cash nearby so the game picks it up")
sld(FarmTab, "Cash Magnet Range (studs)", "FarmCashRange", 15, 150)
tog(FarmTab, "Auto Claim Daily Reward", "AutoDaily", "Claims the daily reward when it is ready")
local dailyLabel = FarmTab:CreateLabel({ Text = "Daily tasks: ...", Style = 2 })
every("farmlabels", 1, function()
	local elapsed = farm.on and (os.clock() - farm.startAt) or 0
	local earned = farm.on and (exactMoney() - farm.startMoney) or 0
	local perHour = elapsed > 30 and earned / elapsed * 3600 or 0
	local text = farm.on
		and string.format("Farm: %s | %d jobs | earned %s | %s per hour | %s", farm.status, farm.cycles, fmtMoney(earned), fmtMoney(perHour), fmtTime(elapsed))
		or ("Farm: " .. farm.status)
	pcall(function() farmLive:Set(text) end)
	if farmToggle and farmToggle.Get and farmToggle:Get() ~= farm.on then pcall(function() farmToggle.Item.value = farm.on farmToggle.Item:refresh() end) end
end)
every("dailylabel", 20, function()
	task.spawn(function() local t = dailyQuestText() pcall(function() dailyLabel:Set(t) end) end)
end)
end

do
-- Misc -------------------------------------------------------------------------------------------------
local Misc = tab("Misc", "misc")
head(Misc, "Performance")
tog(Misc, "FPS Boost", "FPSBoost", "Shadows, post effects and lowest quality. Restored when you turn it off", setBoost)
tog(Misc, "Custom FPS Cap", "FPSCapOn", "Off puts the cap back to 60", applyFPSCap)
sld(Misc, "FPS Cap", "FPSCap", 30, 360, function() if Cfg.FPSCapOn then applyFPSCap() end end)
head(Misc, "General")
bind(Misc, "Panic Key", "Turns every feature off at once", "PanicKey")
Misc:CreateButton({ Name = "Panic Now", Description = "Turns every feature off at once", Danger = true, Callback = panic })

head(Misc, "Config")
tog(Misc, "Auto Save Config", "AutoSave", "Saves a moment after any setting changes, and loads on start")
local cfgInput = cfgProfile
Misc:CreateInput({
	Name = "Config Name", Description = "Letters, numbers, - and _", CurrentValue = cfgProfile, PlaceholderText = "sandiego",
	Callback = function(v) cfgInput = cleanName(v) or cfgProfile end,
})
Misc:CreateButton({ Name = "Save Config", Callback = function()
	local ok, err = saveCfg(cfgInput)
	if ok then setProfile(cfgInput) end
	notify("Config", ok and ("Saved as " .. cfgInput) or ("Save failed: " .. tostring(err)), ok and "save" or "warning")
end })
Misc:CreateButton({ Name = "Load Config", Description = "Loads the name above and updates the menu", Callback = function()
	if loadCfg(cfgInput) then
		setProfile(cfgInput)
		refreshUI()
		applyGunMods() setInfStamina(Cfg.InfStamina) task.spawn(setInstantPrompt, Cfg.InstantPrompt)
		notify("Config", "Loaded " .. cfgInput .. ". Colors, keybinds and locations apply after the next launch.", "check_circle")
	else
		notify("Config", "No saved config called " .. cfgInput, "warning")
	end
end })
Misc:CreateButton({ Name = "Delete Config", Description = "Deletes the config named above", Danger = true, Callback = function()
	local okd = pcall(function() if delfile and isfile(cfgPath(cfgInput)) then delfile(cfgPath(cfgInput)) end end)
	notify("Config", okd and ("Deleted " .. cfgInput) or "Could not delete", okd and "delete" or "warning")
end })

head(Misc, "Session")
Misc:CreateButton({ Name = "Unload Hub", Description = "Turns everything off and removes the menu", Danger = true, Callback = function()
	panic()
	if getgenv().FurinaSDUnload then
		getgenv().FurinaSDUnload()
	else
		unloaded = true
		pcall(function() UI:Destroy() end)
		pcall(removeAllESP)
	end
end })
Misc:CreateButton({ Name = "Server Hop", Description = "Joins another public server", Callback = serverHop })
Misc:CreateButton({ Name = "Rejoin Server", Callback = function()
	TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
end })
Misc:CreateLabel({ Text = "Furina Hub - San Diego. Built around the game's anti-cheat: nothing here teleports, flies, speeds or farms.", Style = 2 })
end

getgenv().FurinaSDDebug = {
	cache = cache, aim = aim, intel = intel, panic = panic, Movement = Movement, GunConfig = GunConfig, set = setToggle,
	playerDD = playerDD, playerNames = playerNames, window = Window,
	farm = farm, startFarm = startFarm, stopFarm = stopFarm, walkTo = walkTo, exactMoney = exactMoney, purgeCount = purgeCount,
	waypoints = function() return waypointNames end, labels = labels, esp = esp, describe = describe, findPlayer = findPlayer,
}
cleanup(function() getgenv().FurinaSDDebug = nil end)

if Cfg.FPSCapOn then applyFPSCap() end
if Window.Ready then Window:Ready() end
notify("Furina Hub", "San Diego loaded. RightShift toggles the menu.", "check_circle")
