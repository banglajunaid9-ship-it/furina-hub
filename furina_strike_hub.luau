--[[
	Furina Hub | Strike (CS-style bomb defusal shooter, placeId 114234929420007)
	UI: FurinaUI (furina_ui.luau in this repo); falls back to Luna Interface Suite if it cannot load

	Run with loadstring, or through live-reload (STATE). Running it again replaces the old copy.

	Game notes (found by reading the game's own scripts)
	- Characters are Models in workspace.Characters (rooted in HumanoidRootPart, no Humanoid). Health, MaxHealth and
	  Dead live as ATTRIBUTES on the model. The server hides far enemies by moving their model into
	  ReplicatedStorage._PVS_CulledCharacters (the rest of the model is a stale copy there).
	- Team is the Player attribute "Team" ("Terrorists" / "Counter-Terrorists"). Workspace attribute "Gamemode" =
	  "Deathmatch" means everyone is an enemy. Bots are models with attribute Bot = true.
	- The mouse is locked to the centre while playing, so aim assist moves the mouse (mousemoverel) instead of
	  fighting the game's camera code.
	- ReplicatedStorage.Remotes.BAC is the game's anti-cheat remote. This hub never touches remotes or hooks anything:
	  it only reads the world, draws overlays and moves the mouse.

	Layout
	 1. Bootstrap        4. Config files          7. Aimbot, triggerbot, crosshair
	 2. Services         5. Enemy cache, scheduler 8. World, HUD, misc
	 3. Settings (Cfg)   6. ESP, chams, radar      9. UI
]]


------------------------------------------------------------------------------------------------------
-- 1. Bootstrap: standalone teardown when STATE (live-reload) is not provided
------------------------------------------------------------------------------------------------------
local STATE = STATE
if not STATE then
	if getgenv().FurinaStrikeUnload then pcall(getgenv().FurinaStrikeUnload) end
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
	getgenv().FurinaStrikeUnload = function()
		running = false
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
		getgenv().FurinaStrikeUnload = nil
	end
end

local unloaded = false
local function alive() return not unloaded and STATE.alive() end
local function cleanup(fn) STATE.onCleanup(fn) end
local function connect(sig, fn) return STATE.connect(sig, fn) end

------------------------------------------------------------------------------------------------------
-- 2. Services and shared locals
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

-- UI library: FurinaUI. A copy in the workspace (FurinaHub/furina_ui.luau) wins so edits can be tested without pushing;
-- otherwise it comes from this repo. If it fails to load, Luna takes over so the hub still works.
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
		warn("[Furina Strike] FurinaUI failed to load, using Luna instead: " .. tostring(lib))
	end
	getgenv().ConfirmLuna = true
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/master/source.lua"))()
end)()
local FURINA = UI.IsFurinaUI == true
local function notify(title, text, icon)
	UI:Notification({ Title = title, Content = text, Icon = icon or "info", ImageSource = "Material" })
end

------------------------------------------------------------------------------------------------------
-- 3. Settings
------------------------------------------------------------------------------------------------------
local Cfg = {
	-- ESP
	ESP = true, ESPKey = Enum.KeyCode.F1, ESPMax = 2000, ShowTeam = false, ShowCulled = false,
	Box = true, BoxStyle = "Corners", BoxThick = 1, BoxFill = false,
	Name = true, Health = true, HPText = true, Distance = true, Bots = true,
	TextSize = 13, Skeleton = true, SkelDist = 250, HeadDot = false,
	Chams = true, ChamsFill = 70, VisCheck = true, Rainbow = false,
	Tracers = false, TracerOrigin = "Bottom", Arrows = true,
	Radar = true, RadarRange = 120, RadarSize = 75, RadarX = 100, RadarY = 190,
	ESPColor = Color3.fromRGB(255, 80, 80), VisColor = Color3.fromRGB(90, 255, 120),
	TeamColor = Color3.fromRGB(90, 170, 255), CulledColor = Color3.fromRGB(170, 170, 190),
	-- aimbot
	Aim = false, AimKeyToggle = Enum.KeyCode.F2, AimKey = "Left Mouse", AimLead = 60, AimFOV = 250, ShowFOV = true,
	AimSmooth = 2, AimPart = "Auto", AimVis = true, AimSticky = true, AimPriority = "Crosshair",
	AimSpeed = 100, AutoCal = true, AimTeam = true,
	-- triggerbot
	Trigger = false, TrigKey = Enum.KeyCode.F3, TrigDelay = 40, TrigRate = 70, TrigHead = false,
	-- crosshair
	Cross = false, CrossSize = 8, CrossGap = 4, CrossThick = 1, CrossDot = true, CrossColor = Color3.fromRGB(255, 255, 255),
	-- world
	HUD = true, Fullbright = false, FOVOn = false, FOV = 90, AntiAFK = true,
	FPSBoost = false, FPSCapOn = false, FPSCap = 144,
	-- general
	PanicKey = Enum.KeyCode.Delete, AutoSave = true,
}
getgenv().FurinaStrikeCfg = Cfg -- live settings table, handy for debugging from an executor console

------------------------------------------------------------------------------------------------------
-- 4. Config files: <workspace>/FurinaHub/<profile>.json, active profile name in FurinaHub/_profile_strike.txt.
-- Every file call is guarded because executors differ (some throw if a folder exists, some lack listfiles).
------------------------------------------------------------------------------------------------------
local CFG_DIR = "FurinaHub"
local PROFILE_FILE = CFG_DIR .. "/_profile_strike.txt"
local cfgProfile = "strike"
local NOSAVE = { Fullbright = true, FPSBoost = true } -- need setup code that only runs when toggled

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
			end
		end
	end
	return HttpService:JSONEncode(t)
end

-- order-independent fingerprint used to notice that something changed
local function signature()
	local parts = {}
	for k, v in pairs(Cfg) do
		if not NOSAVE[k] then
			parts[#parts + 1] = k .. "=" .. (typeof(v) == "Color3" and v:ToHex() or tostring(v))
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
	if not isfile(cfgPath(name)) then return false, "wrote the file but it is not there afterwards" end
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
-- 5. Enemy cache and scheduler
-- One cached list (rebuilt 10x a second) feeds ESP, aimbot, triggerbot and radar. Health and position are
-- read live from the model every frame.
------------------------------------------------------------------------------------------------------
local frameJobs, renderJobs, timers = {}, {}, {}
local function run(job, ...)
	local ok, err = pcall(job.fn, ...)
	if not ok and not job.failed then
		job.failed = true
		warn("[FurinaStrike] " .. job.name .. ": " .. tostring(err))
	end
end
local function onFrame(name, fn) frameJobs[#frameJobs + 1] = { name = name, fn = fn } end
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

-- UI registries: let keybinds, panic and Load Config move the visible switches
local Toggles, Sliders = {}, {}
local function setToggle(key, v)
	Cfg[key] = v
	local t = Toggles[key]
	if t then pcall(function() t:Set(v) end) end
end

local TEAM_T, TEAM_CT = "Terrorists", "Counter-Terrorists"
local function charsFolder() return workspace:FindFirstChild("Characters") end
local function culledFolder() return RS:FindFirstChild("_PVS_CulledCharacters") end
local function isContainer(inst) -- Characters or one of its team folders
	if not inst then return false end
	local ch = charsFolder()
	return inst == ch or (inst.Parent == ch and (inst.Name == TEAM_T or inst.Name == TEAM_CT))
end

local function modelAlive(m)
	if m:GetAttribute("Dead") == true then return false end
	local hp = m:GetAttribute("Health")
	return type(hp) ~= "number" or hp > 0
end

local function gamemode() return workspace:GetAttribute("Gamemode") end
local function isEnemyTeam(team)
	if gamemode() == "Deathmatch" then return true end
	local mine = LP:GetAttribute("Team")
	if team == nil or mine == nil then return true end
	return team ~= mine
end

-- true when this client is actually in the round and able to act (not dead, not spectating)
local function meAlive()
	local c = LP.Character
	return c ~= nil and c.Parent ~= nil and modelAlive(c) and LP:GetAttribute("IsSpectating") ~= true
end

local cache = { list = {}, by = {} }
local function rebuildCache()
	local list, by = {}, {}
	local byName = {}
	for _, p in ipairs(Players:GetPlayers()) do byName[p.Name] = p end
	local myChar = LP.Character

	local function add(m, culled)
		if not m:IsA("Model") or m == myChar or m.Name == LP.Name then return end
		local root, head = m:FindFirstChild("HumanoidRootPart"), m:FindFirstChild("Head")
		if not (root and head) then return end
		local plr = byName[m.Name]
		local bot = plr == nil
		if bot and m:GetAttribute("Bot") ~= true then return end -- hostages, props
		local team = plr and plr:GetAttribute("Team") or m:GetAttribute("Team")
		if not team and isContainer(m.Parent) and m.Parent.Name ~= "Characters" then team = m.Parent.Name end
		local e = {
			m = m, plr = plr, bot = bot, team = team, root = root, head = head, culled = culled,
			enemy = isEnemyTeam(team),
			name = plr and plr.DisplayName or tostring(m:GetAttribute("DisplayName") or m.Name),
		}
		list[#list + 1] = e
		by[m] = e
	end

	local ch = charsFolder()
	if ch then
		for _, c in ipairs(ch:GetChildren()) do
			if c:IsA("Folder") then
				if c.Name == TEAM_T or c.Name == TEAM_CT then
					for _, m in ipairs(c:GetChildren()) do add(m, false) end
				end
			else
				add(c, false)
			end
		end
	end
	if Cfg.ShowCulled then
		local cf = culledFolder()
		if cf then
			for _, m in ipairs(cf:GetChildren()) do
				if not by[m] then add(m, true) end
			end
		end
	end
	cache.list, cache.by = list, by
end
every("cache", 0.1, rebuildCache)
rebuildCache()

-- line of sight: rays ignore every character, debris and the invisible map helpers
local rayVis, rayTrig = RaycastParams.new(), RaycastParams.new()
for _, rp in ipairs({ rayVis, rayTrig }) do
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.IgnoreWater = true
end
local function refreshRayFilters()
	local base = { Camera }
	local function add(inst) if inst then base[#base + 1] = inst end end
	add(workspace:FindFirstChild("Debris"))
	add(workspace:FindFirstChild("ThirdPersonWeaponStash"))
	local map = workspace:FindFirstChild("Map")
	if map then
		for _, n in ipairs({ "Barriers", "DeathBarriers", "Zones", "Cameras", "ReplicationFocus", "Reference", "EndScreen" }) do
			add(map:FindFirstChild(n))
		end
	end
	-- trigger rays must hit enemy characters, so only your own character is excluded there
	local trig = table.clone(base)
	if LP.Character then trig[#trig + 1] = LP.Character end
	-- visibility rays ignore every character so only walls can block them
	if charsFolder() then base[#base + 1] = charsFolder() end
	rayVis.FilterDescendantsInstances = base
	rayTrig.FilterDescendantsInstances = trig
end
every("rayfilter", 1, refreshRayFilters)
refreshRayFilters()

local function visibleFrom(origin, part)
	local to = part.Position
	return workspace:Raycast(origin, to - origin, rayVis) == nil
end

local visCache = setmetatable({}, { __mode = "k" }) -- [model] = visible at 10 Hz, for ESP colours
every("vis", 0.1, function()
	if not Cfg.ESP or not Cfg.VisCheck then return end
	local origin = Camera.CFrame.Position
	for _, e in ipairs(cache.list) do
		if not e.culled then visCache[e.m] = visibleFrom(origin, e.head) end
	end
end)

------------------------------------------------------------------------------------------------------
-- 6. ESP (Drawing): boxes, health, names, skeleton, tracers, arrows, radar, chams
------------------------------------------------------------------------------------------------------
local allDrawings = {}
local shadow = setmetatable({}, { __mode = "k" }) -- last value written to each Drawing property
local FONT = (Drawing.Fonts and (Drawing.Fonts.Plex or Drawing.Fonts.UI)) or 2

local function newDraw(kind, props)
	local d = Drawing.new(kind)
	for k, v in pairs(props) do d[k] = v end
	allDrawings[#allDrawings + 1] = d
	return d
end
-- write a Drawing property only when it changed (cuts redundant renderer calls)
local function P(d, k, v)
	local s = shadow[d]
	if not s then s = {} shadow[d] = s end
	if s[k] ~= v then
		s[k] = v
		d[k] = v
	end
end

local BONES = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}

local hlFolder = Instance.new("Folder")
hlFolder.Name = "FurinaChams"
pcall(function() hlFolder.Parent = (gethui and gethui()) or CoreGui end)
if not hlFolder.Parent then hlFolder.Parent = CoreGui end
cleanup(function() hlFolder:Destroy() end)

local esp = {} -- [model] = pool of drawings + cached state
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
	o.fill = mk("Square", { Thickness = 1, Filled = true, Transparency = 0.12, Visible = false })
	for i = 1, 8 do o.corners[i] = mk("Line", { Thickness = 1, Visible = false }) end
	o.hpBg = mk("Square", { Thickness = 1, Filled = true, Color = BLACK, Transparency = 0.6, Visible = false })
	o.hpFill = mk("Square", { Thickness = 1, Filled = true, Visible = false })
	o.name = mk("Text", { Size = 13, Center = true, Outline = true, Font = FONT, Visible = false })
	o.info = mk("Text", { Size = 13, Center = true, Outline = true, Font = FONT, Visible = false })
	o.hpText = mk("Text", { Size = 11, Center = false, Outline = true, Font = FONT, Visible = false })
	for i = 1, #BONES do o.bones[i] = mk("Line", { Thickness = 1, Visible = false }) end
	o.head = mk("Circle", { Thickness = 1, Filled = false, Radius = 3, Visible = false })
	o.tracer = mk("Line", { Thickness = 1, Visible = false })
	o.arrow = mk("Triangle", { Thickness = 1, Filled = true, Visible = false })
	o.dot = mk("Circle", { Thickness = 1, Filled = true, Radius = 3, Visible = false })
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
	for _, d in ipairs(o.all) do
		pcall(function() d:Remove() end)
		shadow[d] = nil
	end
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

local function espColor(e)
	if Cfg.Rainbow then return Color3.fromHSV((os.clock() * 0.25) % 1, 1, 1) end
	if e.culled then return Cfg.CulledColor end
	if not e.enemy then return Cfg.TeamColor end
	if Cfg.VisCheck and visCache[e.m] then return Cfg.VisColor end
	return Cfg.ESPColor
end

local radarBg, radarRim, radarMe
local function ensureRadar()
	if radarBg then return end
	radarBg = newDraw("Circle", { Filled = true, Color = Color3.fromRGB(12, 14, 22), Transparency = 0.55, Thickness = 1, Visible = false })
	radarRim = newDraw("Circle", { Filled = false, Color = Color3.fromRGB(150, 170, 255), Transparency = 1, Thickness = 1, Visible = false })
	radarMe = newDraw("Triangle", { Filled = true, Color = WHITE, Visible = false })
end

local function drawESP()
	espFrame += 1
	local cam = Camera
	local cf = cam.CFrame
	local camPos = cf.Position
	local vp = cam.ViewportSize
	local center = V2(vp.X / 2, vp.Y / 2)
	local flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local yawCF = flatLook.Magnitude > 0.01 and CFrame.lookAt(camPos, camPos + flatLook) or cf
	local fontSize = Cfg.TextSize

	local radarOn = Cfg.Radar
	if radarOn then
		ensureRadar()
		local c, r = V2(Cfg.RadarX, Cfg.RadarY), Cfg.RadarSize
		P(radarBg, "Position", c) P(radarBg, "Radius", r) P(radarBg, "Visible", true)
		P(radarRim, "Position", c) P(radarRim, "Radius", r) P(radarRim, "Visible", true)
		P(radarMe, "PointA", c + V2(0, -6)) P(radarMe, "PointB", c + V2(-4, 4)) P(radarMe, "PointC", c + V2(4, 4)) P(radarMe, "Visible", true)
	elseif radarBg then
		P(radarBg, "Visible", false) P(radarRim, "Visible", false) P(radarMe, "Visible", false)
	end

	for _, e in ipairs(cache.list) do
		local o = getESP(e.m)
		o.seen = espFrame
		local m, root, head = e.m, e.root, e.head
		local show = root.Parent ~= nil and head.Parent ~= nil and modelAlive(m)
			and (e.enemy or Cfg.ShowTeam) and (Cfg.Bots or not e.bot)
		local rp = show and root.Position
		local dist = show and (rp - camPos).Magnitude
		if not show or dist > Cfg.ESPMax then
			hideESP(o)
			continue
		end
		local col = espColor(e)

		-- chams
		if Cfg.Chams and not e.culled then
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

		-- radar dot
		if radarOn then
			local rel = yawCF:PointToObjectSpace(rp)
			local v = V2(rel.X, rel.Z) * (Cfg.RadarSize / Cfg.RadarRange)
			local lim = Cfg.RadarSize - 4
			if v.Magnitude > lim then v = v.Unit * lim end
			P(o.dot, "Position", V2(Cfg.RadarX, Cfg.RadarY) + v)
			P(o.dot, "Color", col)
			P(o.dot, "Visible", true)
		else
			P(o.dot, "Visible", false)
		end

		-- projection of the body: top of head to the soles of the feet
		local lf, rf = part(o, m, "LeftFoot"), part(o, m, "RightFoot")
		local footY = rp.Y - 3
		if lf and rf then footY = math.min(lf.Position.Y, rf.Position.Y) - 0.25 end
		local top3 = Vector3.new(rp.X, head.Position.Y + 0.75, rp.Z)
		local bot3 = Vector3.new(rp.X, footY, rp.Z)
		local t2, tIn = cam:WorldToViewportPoint(top3)
		local b2, bIn = cam:WorldToViewportPoint(bot3)
		local onScreen = tIn and bIn and t2.Z > 0 and b2.Z > 0

		if not onScreen then
			-- every on-screen element off, optional off-screen arrow instead
			for i = 1, #o.all do
				local d = o.all[i]
				if d ~= o.dot then P(d, "Visible", false) end
			end
			if Cfg.Arrows then
				local rel = cf:PointToObjectSpace(rp)
				local dir = V2(rel.X, -rel.Y)
				if dir.Magnitude < 1e-3 then dir = V2(0, 1) end
				dir = dir.Unit
				local radius = math.min(vp.X, vp.Y) * 0.42
				local pos = center + dir * radius
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
		local w = h * 0.52
		local x0, y0 = t2.X - w / 2, t2.Y
		local thick = Cfg.BoxThick

		-- box
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
			if Cfg.BoxFill then
				P(o.fill, "Position", V2(x0, y0)) P(o.fill, "Size", V2(w, h)) P(o.fill, "Color", col) P(o.fill, "Visible", true)
			else
				P(o.fill, "Visible", false)
			end
		else
			P(o.boxOut, "Visible", false) P(o.box, "Visible", false) P(o.fill, "Visible", false)
			for i = 1, 8 do P(o.corners[i], "Visible", false) end
		end

		-- health bar + number
		local hp = tonumber(m:GetAttribute("Health")) or 100
		local maxHp = math.max(tonumber(m:GetAttribute("MaxHealth")) or 100, 1)
		local frac = math.clamp(hp / maxHp, 0, 1)
		if Cfg.Health then
			local bx = x0 - 5
			P(o.hpBg, "Position", V2(bx - 1, y0 - 1)) P(o.hpBg, "Size", V2(4, h + 2)) P(o.hpBg, "Visible", true)
			P(o.hpFill, "Position", V2(bx, y0 + h * (1 - frac))) P(o.hpFill, "Size", V2(2, h * frac))
			P(o.hpFill, "Color", Color3.fromHSV(frac * 0.33, 0.9, 1)) P(o.hpFill, "Visible", true)
		else
			P(o.hpBg, "Visible", false) P(o.hpFill, "Visible", false)
		end
		if Cfg.HPText then
			P(o.hpText, "Text", tostring(math.floor(hp + 0.5)))
			P(o.hpText, "Size", math.max(fontSize - 2, 8))
			P(o.hpText, "Position", V2(x0 - 7 - o.hpText.TextBounds.X, y0 + h * (1 - frac) - 5))
			P(o.hpText, "Color", WHITE) P(o.hpText, "Visible", true)
		else
			P(o.hpText, "Visible", false)
		end

		-- name and info
		if Cfg.Name then
			local label = e.name .. (e.bot and " [BOT]" or "") .. (e.culled and " [HIDDEN]" or "")
			P(o.name, "Text", label) P(o.name, "Size", fontSize)
			P(o.name, "Position", V2(t2.X, y0 - fontSize - 3)) P(o.name, "Color", col) P(o.name, "Visible", true)
		else
			P(o.name, "Visible", false)
		end
		if Cfg.Distance then
			P(o.info, "Text", string.format("[%dm]", math.floor(dist * 0.28)))
			P(o.info, "Size", math.max(fontSize - 1, 8))
			P(o.info, "Position", V2(t2.X, y0 + h + 2)) P(o.info, "Color", WHITE) P(o.info, "Visible", true)
		else
			P(o.info, "Visible", false)
		end

		-- skeleton
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

		-- head dot
		if Cfg.HeadDot then
			local h2, hIn = cam:WorldToViewportPoint(head.Position)
			if hIn and h2.Z > 0 then
				P(o.head, "Position", V2(h2.X, h2.Y)) P(o.head, "Radius", math.clamp(h * 0.07, 2, 9)) P(o.head, "Color", col) P(o.head, "Visible", true)
			else
				P(o.head, "Visible", false)
			end
		else
			P(o.head, "Visible", false)
		end

		-- tracer
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

	-- models that left the cache this frame are hidden until the gc timer removes them
	for m, o in pairs(esp) do
		if o.seen ~= espFrame then hideESP(o) end
	end
end

local espWasOn = false
onRender("esp", function()
	if Cfg.ESP then
		espWasOn = true
		drawESP()
	elseif espWasOn then
		espWasOn = false
		hideAllESP()
		if radarBg then P(radarBg, "Visible", false) P(radarRim, "Visible", false) P(radarMe, "Visible", false) end
	end
end)
cleanup(function()
	removeAllESP()
	for _, d in ipairs(allDrawings) do pcall(function() d:Remove() end) end
end)

------------------------------------------------------------------------------------------------------
-- 7. Aimbot (mouse movement), triggerbot, FOV circle, crosshair
------------------------------------------------------------------------------------------------------
local function mouseLocked() return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter end
local function typing() return UserInputService:GetFocusedTextBox() ~= nil end

local AIM_KEYS = {
	["Right Mouse"] = function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) end,
	["Left Mouse"] = function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end,
	["Mouse 4"] = function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton4) end,
	["Left Shift"] = function() return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) end,
	["Left Alt"] = function() return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) end,
	["Q"] = function() return UserInputService:IsKeyDown(Enum.KeyCode.Q) end,
	["E"] = function() return UserInputService:IsKeyDown(Enum.KeyCode.E) end,
	["Always On"] = function() return true end,
}
local AIM_PARTS = {
	Head = { "Head" },
	Chest = { "UpperTorso" },
	Pelvis = { "LowerTorso" },
	Nearest = { "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg" },
	Auto = { "Head", "UpperTorso", "LowerTorso", "LeftUpperLeg", "RightUpperLeg" }, -- first visible one wins
}

local fovCircle = newDraw("Circle", { Filled = false, Thickness = 1, Color = WHITE, Transparency = 1, Visible = false })
local aim = { target = nil, est = 0.15, remX = 0, remY = 0, prevLook = nil, sentX = 0, sentY = 0, status = "idle" }

-- per-enemy velocity from position changes (characters here have no useful physics velocity), used to lead moving targets
local velTrack = setmetatable({}, { __mode = "k" }) -- [model] = { pos, vel }
onRender("velocity", function(dt)
	if not Cfg.Aim or dt <= 0 then return end
	for _, e in ipairs(cache.list) do
		if not e.culled and e.root.Parent then
			local pos = e.root.Position
			local t = velTrack[e.m]
			if t then
				local v = (pos - t.pos) / dt
				if v.Magnitude > 60 then v = Vector3.zero end -- teleport / respawn, not movement
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

-- best aim part of one enemy: the screen point nearest the crosshair that passes the visibility check
local function pickPart(e, origin, center, maxPx)
	local best, bestPx, bestPos
	for _, name in ipairs(AIM_PARTS[Cfg.AimPart] or AIM_PARTS.Head) do
		local p = e.m:FindFirstChild(name)
		if p then
			local sp, vis = Camera:WorldToViewportPoint(leadPos(e, p))
			if vis and sp.Z > 0 then
				local px = (V2(sp.X, sp.Y) - center).Magnitude
				if px <= maxPx and (not best or px < bestPx) and (not Cfg.AimVis or visibleFrom(origin, p)) then
					best, bestPx, bestPos = p, px, V2(sp.X, sp.Y)
					if Cfg.AimPart == "Auto" then break end -- priority order: head first, then body
				end
			end
		end
	end
	return best, bestPx, bestPos
end

local function findTarget(origin, center)
	local best, bestScore, bestPart
	for _, e in ipairs(cache.list) do
		if not e.culled and e.root.Parent and modelAlive(e.m) and (e.enemy or not Cfg.AimTeam) then
			local p, px = pickPart(e, origin, center, Cfg.AimFOV)
			if p then
				local score = px
				if Cfg.AimPriority == "Distance" then
					score = (e.root.Position - origin).Magnitude
				elseif Cfg.AimPriority == "Lowest HP" then
					score = tonumber(e.m:GetAttribute("Health")) or 100
				end
				if not best or score < bestScore then best, bestScore, bestPart = e, score, p end
			end
		end
	end
	return best, bestPart
end

local function yawPitch(look) return math.atan2(look.X, look.Z), math.asin(math.clamp(look.Y, -1, 1)) end
local function wrapPi(a) return (a + math.pi) % (2 * math.pi) - math.pi end

onRender("aimbot", function()
	local vp = Camera.ViewportSize
	local center = V2(vp.X / 2, vp.Y / 2)
	local active = Cfg.Aim and meAlive() and mouseLocked() and not typing()
	-- FOV circle
	if Cfg.Aim and Cfg.ShowFOV then
		P(fovCircle, "Position", center) P(fovCircle, "Radius", Cfg.AimFOV) P(fovCircle, "Visible", true)
		P(fovCircle, "Color", aim.target and Cfg.VisColor or WHITE)
	else
		P(fovCircle, "Visible", false)
	end
	if not active or not (AIM_KEYS[Cfg.AimKey] or AIM_KEYS["Right Mouse"])() then
		aim.target, aim.prevLook, aim.sentX, aim.sentY, aim.remX, aim.remY = nil, nil, 0, 0, 0, 0
		return
	end

	local look = Camera.CFrame.LookVector
	-- learn how many degrees one mouse count turns the camera (sensitivity differs per game and per setting)
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
	-- keep the current target while it stays reachable, otherwise pick a new one
	local tgt, tpart
	if Cfg.AimSticky and aim.target and aim.target.root.Parent and modelAlive(aim.target.m) then
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
	-- fraction of the error closed per frame; capped so a mis-learned sensitivity can never make it oscillate
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

-- triggerbot: fires when the crosshair is on a visible enemy
local trig = { since = nil, lastShot = 0 }
onRender("trigger", function()
	if not Cfg.Trigger or not meAlive() or not mouseLocked() or typing() then
		trig.since = nil
		return
	end
	local cf = Camera.CFrame
	local hit = workspace:Raycast(cf.Position, cf.LookVector * 1500, rayTrig)
	local e
	if hit then
		local inst = hit.Instance
		local m = inst
		while m and m.Parent and not isContainer(m.Parent) do m = m.Parent end
		e = m and cache.by[m]
		if e and (not e.enemy or e.culled or not modelAlive(e.m)) then e = nil end
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

-- custom crosshair overlay
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

------------------------------------------------------------------------------------------------------
-- 8. World, HUD, misc
------------------------------------------------------------------------------------------------------
-- custom FOV (skipped while the aim-down-sights button is held so scopes still zoom)
onRender("fov", function()
	if Cfg.FOVOn and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		Camera.FieldOfView = Cfg.FOV
	end
end)

-- fullbright
local lightSaved
local function applyLight(on)
	if on then
		if not lightSaved then
			lightSaved = {
				Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
				GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
			}
		end
		Lighting.Brightness, Lighting.GlobalShadows, Lighting.FogEnd = 2, false, 1e6
		Lighting.Ambient, Lighting.OutdoorAmbient = Color3.fromRGB(190, 190, 190), Color3.fromRGB(190, 190, 190)
	elseif lightSaved then
		for k, v in pairs(lightSaved) do Lighting[k] = v end
		lightSaved = nil
	end
end
cleanup(function() applyLight(false) end)
every("light", 1, function() if Cfg.Fullbright and lightSaved then applyLight(true) end end)

-- FPS boost and FPS cap, both restorable
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
cleanup(function() if setfpscap then pcall(setfpscap, 60) end end)

-- HUD: FPS, ping, spectators watching you, round info
local hud = newDraw("Text", { Size = 14, Outline = true, Font = FONT, Color = WHITE, Position = V2(12, 10), Visible = false })
local hudRound = newDraw("Text", { Size = 13, Outline = true, Font = FONT, Color = Color3.fromRGB(190, 200, 255), Position = V2(12, 28), Visible = false })
local fpsAvg = 60
onRender("hud", function(dt)
	fpsAvg = fpsAvg + (1 / math.max(dt, 1e-3) - fpsAvg) * 0.05
	if not Cfg.HUD then
		P(hud, "Visible", false) P(hudRound, "Visible", false)
		return
	end
	local specs = tonumber(LP:GetAttribute("Spectators")) or 0
	P(hud, "Text", string.format("Furina Strike  |  %d FPS  |  %d ms  |  Spectators: %d", math.floor(fpsAvg + 0.5), tonumber(LP:GetAttribute("Ping")) or 0, specs))
	P(hud, "Color", specs > 0 and Color3.fromRGB(255, 190, 90) or WHITE)
	P(hud, "Visible", true)
	local en = 0
	for _, e in ipairs(cache.list) do if e.enemy and not e.culled and modelAlive(e.m) then en += 1 end end
	P(hudRound, "Text", string.format("%s  |  %s  |  T %s - CT %s  |  enemies in view: %d",
		tostring(workspace:GetAttribute("Map") or "?"), tostring(workspace:GetAttribute("GameState") or "?"),
		tostring(workspace:GetAttribute("TScore") or 0), tostring(workspace:GetAttribute("CTScore") or 0), en))
	P(hudRound, "Visible", true)
end)

-- anti AFK
connect(LP.Idled, function()
	if Cfg.AntiAFK then
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end
end)

-- panic: everything off at once
local function panic()
	for _, k in ipairs({ "ESP", "Aim", "Trigger", "Cross", "HUD", "FOVOn", "Fullbright" }) do setToggle(k, false) end
	applyLight(false)
	hideAllESP()
	if radarBg then P(radarBg, "Visible", false) P(radarRim, "Visible", false) P(radarMe, "Visible", false) end
	notify("Panic", "Every feature is off.", "warning")
end

-- hotkeys
connect(UserInputService.InputBegan, function(input)
	if not alive() or typing() or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local k = input.KeyCode
	if k == Cfg.PanicKey then panic()
	elseif k == Cfg.ESPKey then setToggle("ESP", not Cfg.ESP)
	elseif k == Cfg.AimKeyToggle then setToggle("Aim", not Cfg.Aim)
	elseif k == Cfg.TrigKey then setToggle("Trigger", not Cfg.Trigger) end
end)

local function serverHop()
	local ok, res = pcall(function()
		return HttpService:JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"))
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

-- auto-save: write when something changed (checked every 1.5s) and at least every 30s
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

------------------------------------------------------------------------------------------------------
-- 9. UI
------------------------------------------------------------------------------------------------------
local Window = UI:CreateWindow({
	Name = "Furina Hub",
	Subtitle = "Strike | Bomb Defusal",
	LogoID = "6031097225",
	LoadingEnabled = false,
	ConfigSettings = { ConfigFolder = "FurinaHub" },
	KeySystem = false,
})
cleanup(function() pcall(function() UI:Destroy() end) end)

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
-- scale lets a slider show whole numbers for a decimal setting (shown value = Cfg[key] * scale)
local function sld(t, name, key, lo, hi, scale, cb)
	scale = scale or 1
	Sliders[key] = {
		scale = scale,
		obj = t:CreateSlider({
			Name = name, Range = { lo, hi }, Increment = 1,
			CurrentValue = math.clamp(math.floor(Cfg[key] * scale + 0.5), lo, hi),
			Callback = function(v) Cfg[key] = v / scale if cb then cb(v) end end,
		}),
	}
end
local function dd(t, name, key, options, desc)
	t:CreateDropdown({
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
local function refreshUI() -- push Cfg back into the visible toggles and sliders
	for key, t in pairs(Toggles) do pcall(function() t:Set(Cfg[key]) end) end
	for key, s in pairs(Sliders) do pcall(function() s.obj:Set(math.floor(Cfg[key] * s.scale + 0.5)) end) end
end

-- Aimbot ---------------------------------------------------------------------------------------------
local AimTab = tab("Aimbot", "my_location")
head(AimTab, "Aimbot")
tog(AimTab, "Aimbot", "Aim", "Moves your mouse toward the nearest enemy while the aim key is held (needs the mouse locked in game)")
dd(AimTab, "Aim Key", "AimKey", { "Right Mouse", "Left Mouse", "Mouse 4", "Left Shift", "Left Alt", "Q", "E", "Always On" })
dd(AimTab, "Aim At", "AimPart", { "Auto", "Head", "Chest", "Pelvis", "Nearest" }, "Auto = head, falling back to body when the head is hidden. Nearest = visible part closest to your crosshair")
dd(AimTab, "Target Priority", "AimPriority", { "Crosshair", "Distance", "Lowest HP" })
sld(AimTab, "FOV (px)", "AimFOV", 20, 800)
tog(AimTab, "Show FOV Circle", "ShowFOV")
sld(AimTab, "Smoothness", "AimSmooth", 1, 30)
sld(AimTab, "Aim Speed %", "AimSpeed", 10, 300)
sld(AimTab, "Prediction (ms)", "AimLead", 0, 200, 1)
tog(AimTab, "Visible Only", "AimVis", "Ignores enemies behind walls")
tog(AimTab, "Sticky Target", "AimSticky", "Stays on the same enemy until they die or leave the circle")
tog(AimTab, "Skip Teammates", "AimTeam", "Off = also aims at your team (free for all)")
tog(AimTab, "Auto Calibrate", "AutoCal", "Learns your mouse sensitivity as you aim so the speed matches. Turn off and use Aim Speed % if it misbehaves")
bind(AimTab, "Aimbot Toggle Key", "Press to switch the aimbot on or off", "AimKeyToggle")
AimTab:CreateButton({ Name = "Aim Status", Description = "Shows what the aimbot is doing", Callback = function()
	notify("Aimbot", string.format("%s | target: %s | %.3f deg per mouse count", aim.status, aim.target and aim.target.name or "none", aim.est))
end })
head(AimTab, "Triggerbot")
tog(AimTab, "Triggerbot", "Trigger", "Clicks for you when your crosshair is on a visible enemy")
sld(AimTab, "Reaction Delay (ms)", "TrigDelay", 0, 400)
sld(AimTab, "Time Between Shots (ms)", "TrigRate", 20, 500)
tog(AimTab, "Head Only", "TrigHead", "Only shoots when the crosshair is on the head")
bind(AimTab, "Triggerbot Toggle Key", "Press to switch the triggerbot on or off", "TrigKey")
head(AimTab, "Crosshair")
tog(AimTab, "Custom Crosshair", "Cross")
sld(AimTab, "Size", "CrossSize", 2, 30)
sld(AimTab, "Gap", "CrossGap", 0, 20)
sld(AimTab, "Thickness", "CrossThick", 1, 4)
tog(AimTab, "Center Dot", "CrossDot")
picker(AimTab, "Crosshair Color", "CrossColor")

-- ESP -------------------------------------------------------------------------------------------------
local ESPTab = tab("ESP", "visibility")
head(ESPTab, "Master")
tog(ESPTab, "Player ESP", "ESP", "Master switch for everything below")
bind(ESPTab, "ESP Key", "Press to toggle ESP", "ESPKey")
sld(ESPTab, "Max Distance", "ESPMax", 100, 5000)
tog(ESPTab, "Show Teammates", "ShowTeam", "Also draws your team in the team color")
tog(ESPTab, "Show Bots", "Bots")
tog(ESPTab, "Show Hidden Enemies", "ShowCulled", "The server hides far enemies. This shows their stale last-known copy in grey. Position may be wrong")
head(ESPTab, "Boxes")
tog(ESPTab, "Boxes", "Box")
dd(ESPTab, "Box Style", "BoxStyle", { "Corners", "Full" })
sld(ESPTab, "Box Thickness", "BoxThick", 1, 4)
tog(ESPTab, "Box Fill", "BoxFill")
head(ESPTab, "Info")
tog(ESPTab, "Names", "Name")
tog(ESPTab, "Health Bar", "Health")
tog(ESPTab, "Health Number", "HPText")
tog(ESPTab, "Distance", "Distance")
sld(ESPTab, "Text Size", "TextSize", 9, 20)
head(ESPTab, "Body")
tog(ESPTab, "Skeleton", "Skeleton")
sld(ESPTab, "Skeleton Range", "SkelDist", 50, 800)
tog(ESPTab, "Head Dot", "HeadDot")
tog(ESPTab, "Chams", "Chams", "Highlights enemies through walls")
sld(ESPTab, "Chams Fill (% see-through)", "ChamsFill", 0, 100)
head(ESPTab, "Lines and radar")
tog(ESPTab, "Tracers", "Tracers")
dd(ESPTab, "Tracer Origin", "TracerOrigin", { "Bottom", "Center", "Mouse" })
tog(ESPTab, "Off-Screen Arrows", "Arrows", "Pointers toward enemies outside your view")
tog(ESPTab, "Radar", "Radar", "Top-down map of nearby enemies")
sld(ESPTab, "Radar Range (studs)", "RadarRange", 30, 400)
sld(ESPTab, "Radar Size", "RadarSize", 40, 140)
head(ESPTab, "Colors")
tog(ESPTab, "Rainbow", "Rainbow")
tog(ESPTab, "Visible Color", "VisCheck", "Enemies in line of sight use the visible color")
picker(ESPTab, "Enemy Color", "ESPColor")
picker(ESPTab, "Visible Color", "VisColor")
picker(ESPTab, "Team Color", "TeamColor")
picker(ESPTab, "Hidden Color", "CulledColor")

-- Visuals ----------------------------------------------------------------------------------------------
local Visuals = tab("Visuals", "palette")
tog(Visuals, "HUD", "HUD", "Top-left line with FPS, ping, spectators watching you and the round state")
tog(Visuals, "Fullbright", "Fullbright", nil, applyLight)
tog(Visuals, "Custom FOV", "FOVOn", "Not applied while you aim down sights", function(v) if not v then Camera.FieldOfView = 70 end end)
sld(Visuals, "FOV", "FOV", 50, 120)

-- Misc ---------------------------------------------------------------------------------------------------
local Misc = tab("Misc", "settings")
head(Misc, "Performance")
tog(Misc, "FPS Boost", "FPSBoost", "Shadows, post effects and lowest quality. Restored when you turn it off", setBoost)
tog(Misc, "Custom FPS Cap", "FPSCapOn", "Off puts the cap back to 60", applyFPSCap)
sld(Misc, "FPS Cap", "FPSCap", 30, 360, 1, function() if Cfg.FPSCapOn then applyFPSCap() end end)
head(Misc, "General")
tog(Misc, "Anti AFK", "AntiAFK")
bind(Misc, "Panic Key", "Turns every feature off at once", "PanicKey")
Misc:CreateButton({ Name = "Panic Now", Description = "Turns every feature off at once", Danger = true, Callback = panic })

head(Misc, "Config")
tog(Misc, "Auto Save Config", "AutoSave", "Saves a moment after any setting changes, and loads on start")
local cfgInput = cfgProfile
Misc:CreateInput({
	Name = "Config Name", Description = "Letters, numbers, - and _ only. Active: " .. cfgProfile,
	PlaceholderText = cfgProfile, CurrentValue = cfgProfile, RemoveTextAfterFocusLost = false,
	Callback = function(t) cfgInput = cleanName(t) or cfgProfile end,
})
Misc:CreateButton({ Name = "Save Config", Description = "Saves under the name above and makes it the active config", Callback = function()
	local ok, err = saveCfg(cfgInput)
	if ok then setProfile(cfgInput) end
	notify("Config", ok and ("Saved as " .. cfgInput) or ("Save failed: " .. tostring(err)), ok and "save" or "warning")
end })
Misc:CreateButton({ Name = "Load Config", Description = "Loads the name above and updates the menu", Callback = function()
	if loadCfg(cfgInput) then
		setProfile(cfgInput)
		refreshUI()
		notify("Config", "Loaded " .. cfgInput .. ". Colors and keybinds apply after the next launch.", "check_circle")
	else
		notify("Config", "No saved config called " .. cfgInput, "warning")
	end
end })
Misc:CreateButton({ Name = "List Configs", Callback = function()
	local names = {}
	if listfiles and isfolder and isfolder(CFG_DIR) then
		local okl, files = pcall(listfiles, CFG_DIR)
		if okl then
			for _, f in ipairs(files) do
				local n = tostring(f):match("([^/\\]+)%.json$")
				if n then names[#names + 1] = n end
			end
		end
	end
	notify("Configs", #names > 0 and table.concat(names, ", ") or "none found (or this executor cannot list files)")
end })
Misc:CreateButton({ Name = "Delete Config", Description = "Deletes the config named above", Danger = true, Callback = function()
	local okd = pcall(function() if delfile and isfile(cfgPath(cfgInput)) then delfile(cfgPath(cfgInput)) end end)
	notify("Config", okd and ("Deleted " .. cfgInput) or "Could not delete", okd and "delete" or "warning")
end })

head(Misc, "Session")
Misc:CreateButton({ Name = "Unload Hub", Description = "Turns everything off and removes the menu", Danger = true, Callback = function()
	panic()
	if getgenv().FurinaStrikeUnload then
		getgenv().FurinaStrikeUnload()
	else
		unloaded = true
		pcall(function() UI:Destroy() end)
		pcall(removeAllESP)
	end
end })
Misc:CreateButton({ Name = "Server Hop", Description = "Joins another public server of this game", Callback = serverHop })
Misc:CreateButton({ Name = "Rejoin Server", Callback = function()
	TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
end })
Misc:CreateLabel({ Text = "Furina Hub - Strike. Aimbot only moves the mouse, ESP only draws; nothing here fires remotes.", Style = 2 })

-- debugging handles for an executor console
getgenv().FurinaStrikeDebug = {
	cache = cache, aim = aim, panic = panic, refreshUI = refreshUI, rebuildCache = rebuildCache,
	enemies = function() local r = {} for _, e in ipairs(cache.list) do r[#r + 1] = e.name .. " " .. tostring(e.team) .. (e.enemy and " ENEMY" or "") .. (e.culled and " culled" or "") end return r end,
}
cleanup(function() getgenv().FurinaStrikeDebug = nil end)

-- apply saved performance settings (toggles do not fire their callbacks at creation)
if Cfg.FPSCapOn then applyFPSCap() end

if Window.Ready then Window:Ready() end -- FurinaUI: finish the loading screen now that every tab is built
notify("Furina Hub", "Strike loaded. RightShift toggles the menu.", "check_circle")
