-- Furina Hub | Silent Assassins (placeId 103854444055060)
-- UI: Luna Interface Suite (discontinued upstream, still loads)
-- Run via live-reload (uses STATE for clean teardown on re-run)
--
-- Game notes: combat is client-detected. AttackController -> HitboxController ->
-- ResolverController builds hit data, then fires
--   ReplicatedStorage.Events.GameRemoteFunction:InvokeServer("AttemptWeaponHit", weaponData, hits)
-- Kill Aura replays that call for enemies in range.

getgenv().ConfirmLuna = true

-- Standalone mode: when run through loadstring (no live-reload STATE), provide our own
-- teardown so executing it twice replaces the old copy instead of stacking a second one.
local STATE = STATE
if not STATE then
	if getgenv().FurinaHubUnload then pcall(getgenv().FurinaHubUnload) end
	local cleanups, conns, running, hooks = {}, {}, true, {}
	STATE = {
		onCleanup = function(f) cleanups[#cleanups + 1] = f end,
		connect = function(sig, fn)
			local c = sig:Connect(fn)
			conns[#conns + 1] = c
			return c
		end,
		alive = function() return running end,
	}
	if hookmetamethod and getnamecallmethod and newcclosure then
		local old
		old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			if running then
				local m = getnamecallmethod()
				local fn = hooks[m]
				if fn then pcall(fn, self, m, ...) end
			end
			return old(self, ...)
		end))
		STATE.namecallHook = function(method, fn) hooks[method] = fn end
	end
	getgenv().FurinaHubUnload = function()
		running = false
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		for _, f in ipairs(cleanups) do pcall(f) end
		getgenv().FurinaHubUnload = nil
	end
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local Luna = loadstring(game:HttpGet("https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/master/source.lua"))()

local Cfg = {
	-- esp
	ESP = false, Box = true, BoxStyle = "Corners", BoxThick = 1, BoxFill = false,
	Name = true, Health = true, HPText = true, Distance = true, Weapon = true,
	TargetTag = true, Threat = true, TextSize = 13,
	Skeleton = true, SkelDist = 220, HeadDot = false, LookLine = false,
	Tracers = false, TracerOrigin = "Bottom", Chams = true, ChamsFill = 65,
	VisCheck = true, Rainbow = false, ESPMax = 1500, ChestESP = false,
	Radar = true, RadarRange = 120, RadarSize = 70, RadarX = 95, RadarY = 175,
	ESPColor = Color3.fromRGB(120, 170, 255), VisColor = Color3.fromRGB(90, 255, 120),
	TargetColor = Color3.fromRGB(255, 70, 70), ThreatColor = Color3.fromRGB(255, 170, 0),
	ESPKey = Enum.KeyCode.Z,
	-- combat
	Aura = false, AuraRange = 12, AuraDelay = 0.12, AuraAll = true, AutoEquip = true,
	FaceTarget = false, Stick = false, StickDist = 4, SkipFF = true,
	LowHPFirst = false, MaxTargets = 5, Ignore = {}, AuraKey = Enum.KeyCode.X,
	NoCD = false, NoCDDelay = 0.05,
	Hitbox = false, HitboxMult = 2, ShowHitbox = false, SpoofHitbox = false,
	-- luck / gacha
	Rolling = false, ChestType = "Divine", RollDelay = 1.2, StopRarity = 4, MaxRolls = 50,
	HUD = true, Arrows = true,
	-- power
	Aim = false, AimHold = true, AimSmooth = 4, AimFOV = 180, AimPart = "HumanoidRootPart", ShowFOV = true,
	Dodge = false, DodgeRange = 16, DodgeDist = 9, Alert = true, AlertRange = 40,
	FPSBoost = false, AntiSlow = false, AntiKB = false, AlwaysEquip = false, PanicKey = Enum.KeyCode.Delete,
	-- movement
	Speed = false, SpeedValue = 24, Jump = false, JumpValue = 60,
	InfJump = false, Noclip = false, Fly = false, FlySpeed = 60,
	-- world
	Fullbright = false, FOVOn = false, FOV = 70, AntiAFK = true,
}

getgenv().FurinaCfg = Cfg -- live settings table, handy for debugging from an executor console

-- Config save/load ---------------------------------------------------------------
-- Settings live in <workspace>/FurinaHub/<profile>.json and the active profile name in
-- FurinaHub/_profile.txt. Auto-save writes whenever a setting changes (checked every 1.5s), so
-- nothing is lost if the game closes. Every file call is guarded because executors differ:
-- some throw if a folder already exists, and some lack isfolder or listfiles.
local HttpService = game:GetService("HttpService")
local CFG_DIR = "FurinaHub"
local PROFILE_FILE = CFG_DIR .. "/_profile.txt"
local cfgProfile = "silent_assassins"
-- Not restored on launch: rolling spends currency; the others need setup code that only runs when toggled.
local NOSAVE = { Rolling = true, Fly = true, Fullbright = true, Stick = true }
Cfg.AutoSave = true

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
local function validNumber(v) return v == v and v ~= math.huge and v ~= -math.huge end

local function encodeCfg()
	local t = {}
	for k, v in pairs(Cfg) do
		if not NOSAVE[k] then
			local ty = typeof(v)
			if ty == "Color3" then t[k] = { __c = { v.R, v.G, v.B } }
			elseif ty == "EnumItem" then t[k] = { __k = v.Name }
			elseif k == "Ignore" then
				local names = {}
				for n in pairs(v) do names[#names + 1] = n end
				t[k] = { __ig = names }
			elseif ty == "number" then
				if validNumber(v) then t[k] = v end
			elseif ty == "boolean" or ty == "string" then
				t[k] = v
			end
		end
	end
	return HttpService:JSONEncode(t)
end

-- cheap, order-independent fingerprint used to notice that something changed
local function signature()
	local parts = {}
	for k, v in pairs(Cfg) do
		if not NOSAVE[k] then
			local ty = typeof(v)
			if ty == "table" then
				local names = {}
				for n in pairs(v) do names[#names + 1] = n end
				table.sort(names)
				parts[#parts + 1] = k .. "=" .. table.concat(names, ",")
			elseif ty == "Color3" then
				parts[#parts + 1] = k .. "=" .. v:ToHex()
			else
				parts[#parts + 1] = k .. "=" .. tostring(v)
			end
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
			elseif type(v) == "table" and v.__ig and k == "Ignore" then
				Cfg.Ignore = {}
				for _, n in ipairs(v.__ig) do Cfg.Ignore[n] = true end
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
local cfgLoaded = loadCfg()

local function cleanup(fn) if STATE and STATE.onCleanup then STATE.onCleanup(fn) end end
local function connect(sig, fn)
	if STATE and STATE.connect then return STATE.connect(sig, fn) end
	return sig:Connect(fn)
end
local unloaded = false
local function alive() return not unloaded and (not STATE or STATE.alive()) end

local function char() return LP.Character end
local function hum() local c = char() return c and c:FindFirstChildOfClass("Humanoid") end
local function root() local c = char() return c and c:FindFirstChild("HumanoidRootPart") end
local function toolOf(c) return c and c:FindFirstChildOfClass("Tool") end

-- Target helpers --------------------------------------------------------
local function validEnemy(plr)
	if plr == LP then return end
	local c = plr.Character
	if not c then return end
	local h = c:FindFirstChildOfClass("Humanoid")
	local r = c:FindFirstChild("HumanoidRootPart")
	if not h or not r or h.Health <= 0 then return end
	return c, h, r
end

local function closestEnemy(maxDist)
	local myRoot = root()
	if not myRoot then return end
	local best, bestD
	for _, plr in ipairs(Players:GetPlayers()) do
		local c, h, r = validEnemy(plr)
		if c then
			local d = (r.Position - myRoot.Position).Magnitude
			if d <= (maxDist or 1e9) and (not bestD or d < bestD) then best, bestD = plr, d end
		end
	end
	return best, bestD
end

-- true while this animator is playing a swing (this game stores swings in a folder named "Attack")
local function isAttacking(animator)
	for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
		local a = tr.Animation
		if a and a.Parent and a.Parent.Name == "Attack" and tr.TimePosition < 0.5 then return true end
	end
	return false
end

-- ESP (Drawing) -----------------------------------------------------------
-- Per-player pool: boxes (full or corner style), health bar + number, name, flags, info line,
-- skeleton, head dot, look direction, tracer, off-screen arrow, radar dot and chams.
local esp = {} -- [Player] = pool of drawings + cached state
local allDrawings = {}
local shadow = setmetatable({}, { __mode = "k" }) -- last value written to each Drawing property
local BLACK, WHITE = Color3.new(0, 0, 0), Color3.new(1, 1, 1)
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")

local function newDraw(kind, props)
	local d = Drawing.new(kind)
	for k, v in pairs(props) do d[k] = v end
	allDrawings[#allDrawings + 1] = d
	return d
end

-- write a Drawing property only when it actually changed (cuts redundant renderer calls)
local function P(d, k, v)
	local s = shadow[d]
	if not s then s = {} shadow[d] = s end
	if s[k] ~= v then
		s[k] = v
		d[k] = v
	end
end

local BONES_R6 = {
	{ "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
	{ "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}
local BONES_R15 = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}

local function getESP(plr)
	local o = esp[plr]
	if o then return o end
	o = { all = {}, cOut = {}, c = {}, bones = {}, vis = true, visT = 0, atk = false, atkT = 0 }
	local function mk(kind, props)
		local d = newDraw(kind, props)
		o.all[#o.all + 1] = d
		return d
	end
	o.boxOut = mk("Square", { Thickness = 3, Filled = false, Color = BLACK, Visible = false })
	o.box = mk("Square", { Thickness = 1, Filled = false, Visible = false })
	o.fill = mk("Square", { Filled = true, Transparency = 0.15, Visible = false })
	for i = 1, 8 do o.cOut[i] = mk("Line", { Thickness = 3, Color = BLACK, Visible = false }) end
	for i = 1, 8 do o.c[i] = mk("Line", { Thickness = 1, Visible = false }) end
	o.hpBack = mk("Line", { Thickness = 4, Color = BLACK, Visible = false })
	o.hp = mk("Line", { Thickness = 2, Visible = false })
	o.hpTxt = mk("Text", { Size = 11, Center = true, Outline = true, Color = WHITE, Visible = false })
	o.name = mk("Text", { Size = 14, Center = true, Outline = true, Visible = false })
	o.flag = mk("Text", { Size = 12, Center = true, Outline = true, Visible = false })
	o.info = mk("Text", { Size = 12, Center = true, Outline = true, Color = WHITE, Visible = false })
	o.tracer = mk("Line", { Thickness = 1, Visible = false })
	o.arrow = mk("Triangle", { Filled = true, Thickness = 1, Visible = false })
	o.arrowTxt = mk("Text", { Size = 12, Center = true, Outline = true, Visible = false })
	for i = 1, 14 do o.bones[i] = mk("Line", { Thickness = 1, Visible = false }) end
	o.headDot = mk("Circle", { Thickness = 1, Filled = false, Visible = false })
	o.look = mk("Line", { Thickness = 1, Visible = false })
	o.dot = mk("Circle", { Filled = true, Radius = 3, Visible = false })
	esp[plr] = o
	return o
end

local function hideAll(o)
	for _, d in ipairs(o.all) do P(d, "Visible", false) end
	if o.hl then o.hl.Enabled = false end
end

local function removeESP(plr)
	local o = esp[plr]
	if not o then return end
	if o.hl then o.hl:Destroy() end
	local drop = {}
	for _, d in ipairs(o.all) do
		pcall(d.Remove, d)
		drop[d] = true
	end
	local keep = {}
	for _, d in ipairs(allDrawings) do
		if not drop[d] then keep[#keep + 1] = d end -- don't hold dead handles forever
	end
	allDrawings = keep
	esp[plr] = nil
end

local function removeAllESP()
	for plr in pairs(esp) do removeESP(plr) end
	for _, d in ipairs(allDrawings) do pcall(d.Remove, d) end
	table.clear(allDrawings)
end

-- radar ---------------------------------------------------------------------------
local radar = {}
local RD = { on = false } -- per-frame radar state shared with radarDot
local function ensureRadar()
	if radar.bg then return end
	radar.bg = newDraw("Circle", { Filled = true, Color = Color3.fromRGB(12, 12, 16), Transparency = 0.55, Visible = false })
	radar.ring = newDraw("Circle", { Filled = false, Thickness = 1.5, Color = Color3.fromRGB(120, 170, 255), Visible = false })
	radar.h = newDraw("Line", { Thickness = 1, Color = Color3.fromRGB(70, 70, 85), Visible = false })
	radar.v = newDraw("Line", { Thickness = 1, Color = Color3.fromRGB(70, 70, 85), Visible = false })
	radar.me = newDraw("Triangle", { Filled = true, Color = WHITE, Visible = false })
end
local function hideRadar()
	for _, d in pairs(radar) do P(d, "Visible", false) end
	RD.on = false
end
local function radarFrame()
	ensureRadar()
	local R = Cfg.RadarSize
	local center = Vector2.new(Cfg.RadarX, Cfg.RadarY)
	local lv = Camera.CFrame.LookVector
	local look = Vector3.new(lv.X, 0, lv.Z)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
	RD.on, RD.center, RD.R, RD.look, RD.right = true, center, R, look, look:Cross(Vector3.yAxis)
	P(radar.bg, "Position", center) P(radar.bg, "Radius", R) P(radar.bg, "Visible", true)
	P(radar.ring, "Position", center) P(radar.ring, "Radius", R) P(radar.ring, "Visible", true)
	P(radar.h, "From", center - Vector2.new(R, 0)) P(radar.h, "To", center + Vector2.new(R, 0)) P(radar.h, "Visible", true)
	P(radar.v, "From", center - Vector2.new(0, R)) P(radar.v, "To", center + Vector2.new(0, R)) P(radar.v, "Visible", true)
	P(radar.me, "PointA", center + Vector2.new(0, -6))
	P(radar.me, "PointB", center + Vector2.new(-4, 4))
	P(radar.me, "PointC", center + Vector2.new(4, 4))
	P(radar.me, "Visible", true)
end
local function radarDot(o, r, myRoot, color)
	if not RD.on or not myRoot then P(o.dot, "Visible", false) return end
	local d = r.Position - myRoot.Position
	local v = Vector2.new(d:Dot(RD.right), -d:Dot(RD.look)) / Cfg.RadarRange * RD.R
	if v.Magnitude > RD.R - 3 then v = v.Unit * (RD.R - 3) end
	P(o.dot, "Position", RD.center + v)
	P(o.dot, "Color", color)
	P(o.dot, "Visible", true)
end

-- corner-style box -----------------------------------------------------------------
local function seg(o, i, ax, ay, bx, by, color, thick, show)
	local a, b = Vector2.new(ax, ay), Vector2.new(bx, by)
	local out, ln = o.cOut[i], o.c[i]
	P(out, "From", a) P(out, "To", b) P(out, "Thickness", thick + 2) P(out, "Visible", show)
	P(ln, "From", a) P(ln, "To", b) P(ln, "Color", color) P(ln, "Thickness", thick) P(ln, "Visible", show)
end
local function setCorners(o, x, y, w, h, color, thick, show)
	local L = math.clamp(math.min(w, h) * 0.28, 4, 20)
	local x2, y2 = x + w, y + h
	seg(o, 1, x, y, x + L, y, color, thick, show)
	seg(o, 2, x, y, x, y + L, color, thick, show)
	seg(o, 3, x2, y, x2 - L, y, color, thick, show)
	seg(o, 4, x2, y, x2, y + L, color, thick, show)
	seg(o, 5, x, y2, x + L, y2, color, thick, show)
	seg(o, 6, x, y2, x, y2 - L, color, thick, show)
	seg(o, 7, x2, y2, x2 - L, y2, color, thick, show)
	seg(o, 8, x2, y2, x2, y2 - L, color, thick, show)
end

-- visibility (line of sight from your camera) ------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local function canSee(c, r)
	local cam = Camera.CFrame.Position
	local mine = LP.Character
	rayParams.FilterDescendantsInstances = mine and { mine, Camera } or { Camera }
	local res = workspace:Raycast(cam, r.Position - cam, rayParams)
	if not res or res.Instance:IsDescendantOf(c) then return true end
	local head = c:FindFirstChild("Head")
	if head then
		res = workspace:Raycast(cam, head.Position - cam, rayParams)
		return not res or res.Instance:IsDescendantOf(c)
	end
	return false
end

-- main renderer -------------------------------------------------------------------------
local hlColors = setmetatable({}, { __mode = "k" }) -- last color / fill given to each Highlight
local hlFills = setmetatable({}, { __mode = "k" })
local cachedTarget, targetClock = nil, 0
local anyESP = false

local function renderESP()
	if not Cfg.ESP then
		if anyESP then
			for _, o in pairs(esp) do hideAll(o) end
			hideRadar()
			anyESP = false
		end
		return
	end
	anyESP = true

	local myRoot = root()
	local vp = Camera.ViewportSize
	local now = os.clock()
	if now - targetClock > 0.15 then
		targetClock = now
		cachedTarget = closestEnemy(1e9)
	end
	local target = cachedTarget
	local rainbow = Color3.fromHSV((now * 0.25) % 1, 0.8, 1)
	if Cfg.Radar then radarFrame() else hideRadar() end

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LP then
			local c, h, r = validEnemy(plr)
			local o = esp[plr]
			if not c then
				if o then hideAll(o) end
				continue
			end
			o = o or getESP(plr)

			local dist = myRoot and (myRoot.Position - r.Position).Magnitude or 0

			-- state that only needs refreshing a few times a second
			if Cfg.VisCheck and now - o.visT > 0.2 then
				o.visT = now
				o.vis = canSee(c, r)
			end
			if Cfg.Threat and dist < 60 then
				if now - o.atkT > 0.1 then
					o.atkT = now
					if not o.animator or o.animator.Parent == nil then
						o.animator = c:FindFirstChildWhichIsA("Animator", true)
					end
					o.atk = o.animator ~= nil and isAttacking(o.animator)
				end
			else
				o.atk = false
			end

			local color = Cfg.Rainbow and rainbow or Cfg.ESPColor
			if Cfg.VisCheck and o.vis and not Cfg.Rainbow then color = Cfg.VisColor end
			if plr == target then color = Cfg.TargetColor end
			if o.atk and Cfg.Threat then color = Cfg.ThreatColor end

			if dist > Cfg.ESPMax then
				hideAll(o)
				radarDot(o, r, myRoot, color)
				continue
			end

			-- chams
			if Cfg.Chams then
				if not o.hl or o.hl.Parent == nil or o.hl.Adornee ~= c then
					if o.hl then o.hl:Destroy() end
					local hl = Instance.new("Highlight")
					hl.Name = "FurinaChams"
					hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					hl.Adornee = c
					hl.Parent = c
					o.hl = hl
				end
				if hlColors[o.hl] ~= color then
					hlColors[o.hl] = color
					o.hl.FillColor = color
					o.hl.OutlineColor = color
				end
				local fill = Cfg.ChamsFill / 100
				if hlFills[o.hl] ~= fill then
					hlFills[o.hl] = fill
					o.hl.FillTransparency = fill
				end
				if not o.hl.Enabled then o.hl.Enabled = true end
			elseif o.hl then
				o.hl.Enabled = false
			end

			local top, topOn = Camera:WorldToViewportPoint(r.Position + Vector3.new(0, 2.9, 0))
			local bot = Camera:WorldToViewportPoint(r.Position - Vector3.new(0, 3.1, 0))
			local rp = Camera:WorldToViewportPoint(r.Position)

			if not topOn or top.Z <= 0 then
				hideAll(o)
				if o.hl and Cfg.Chams then o.hl.Enabled = true end
				if Cfg.Arrows then
					local center = vp / 2
					local v = Vector2.new(rp.X, rp.Y) - center
					if rp.Z < 0 then v = -v end
					if v.Magnitude < 1 then v = Vector2.new(0, 1) end
					local dir = v.Unit
					local perp = Vector2.new(-dir.Y, dir.X)
					local pos = center + dir * math.min(vp.X, vp.Y) * 0.38
					P(o.arrow, "PointA", pos + dir * 14)
					P(o.arrow, "PointB", pos - dir * 6 + perp * 9)
					P(o.arrow, "PointC", pos - dir * 6 - perp * 9)
					P(o.arrow, "Color", color)
					P(o.arrow, "Visible", true)
					P(o.arrowTxt, "Text", math.floor(dist) .. "m")
					P(o.arrowTxt, "Position", pos + dir * 28 - Vector2.new(0, 6))
					P(o.arrowTxt, "Color", color)
					P(o.arrowTxt, "Visible", true)
				end
			else
				P(o.arrow, "Visible", false)
				P(o.arrowTxt, "Visible", false)

				local height = math.abs(bot.Y - top.Y)
				local width = height * 0.55
				local x, y = top.X - width / 2, top.Y
				local pos, size = Vector2.new(x, y), Vector2.new(width, height)
				local thick = Cfg.BoxThick
				local full = Cfg.Box and Cfg.BoxStyle == "Full"
				local corners = Cfg.Box and Cfg.BoxStyle ~= "Full"

				P(o.boxOut, "Position", pos) P(o.boxOut, "Size", size) P(o.boxOut, "Thickness", thick + 2) P(o.boxOut, "Visible", full)
				P(o.box, "Position", pos) P(o.box, "Size", size) P(o.box, "Color", color) P(o.box, "Thickness", thick) P(o.box, "Visible", full)
				P(o.fill, "Position", pos) P(o.fill, "Size", size) P(o.fill, "Color", color) P(o.fill, "Visible", Cfg.BoxFill)
				setCorners(o, x, y, width, height, color, thick, corners)

				-- health bar and number
				local frac = math.clamp(h.Health / math.max(h.MaxHealth, 1), 0, 1)
				local bx = x - 5 - thick
				P(o.hpBack, "From", Vector2.new(bx, y + height + 1)) P(o.hpBack, "To", Vector2.new(bx, y - 1)) P(o.hpBack, "Visible", Cfg.Health)
				P(o.hp, "From", Vector2.new(bx, y + height)) P(o.hp, "To", Vector2.new(bx, y + height - height * frac))
				P(o.hp, "Color", Color3.fromHSV(frac * 0.33, 1, 1)) P(o.hp, "Visible", Cfg.Health)
				P(o.hpTxt, "Text", tostring(math.floor(h.Health)))
				P(o.hpTxt, "Position", Vector2.new(bx - 13, y + height - height * frac - 6))
				P(o.hpTxt, "Visible", Cfg.Health and Cfg.HPText)

				-- text, scaled down with distance
				local ts = math.clamp(Cfg.TextSize * (1.2 - dist / math.max(Cfg.ESPMax, 1) * 0.5), 9, 22)
				P(o.name, "Text", plr.DisplayName)
				P(o.name, "Size", ts)
				P(o.name, "Position", Vector2.new(top.X, y - ts - 4))
				P(o.name, "Color", color)
				P(o.name, "Visible", Cfg.Name)

				if o.atk and Cfg.Threat then
					P(o.flag, "Text", "!! ATTACKING !!") P(o.flag, "Color", Cfg.ThreatColor)
					P(o.flag, "Position", Vector2.new(top.X, y - ts * 2 - 8)) P(o.flag, "Size", ts) P(o.flag, "Visible", true)
				elseif plr == target and Cfg.TargetTag then
					P(o.flag, "Text", "TARGET") P(o.flag, "Color", Cfg.TargetColor)
					P(o.flag, "Position", Vector2.new(top.X, y - ts * 2 - 8)) P(o.flag, "Size", ts) P(o.flag, "Visible", true)
				else
					P(o.flag, "Visible", false)
				end

				local parts = {}
				if Cfg.Distance then parts[#parts + 1] = math.floor(dist) .. "m" end
				if Cfg.Weapon then
					local t = toolOf(c)
					if t then parts[#parts + 1] = t.Name end
				end
				P(o.info, "Text", table.concat(parts, " | "))
				P(o.info, "Size", math.max(ts - 1, 9))
				P(o.info, "Position", Vector2.new(top.X, y + height + 2))
				P(o.info, "Visible", #parts > 0)

				-- skeleton
				local nBones = 0
				if Cfg.Skeleton and dist <= Cfg.SkelDist then
					local bones = c:FindFirstChild("Torso") and BONES_R6 or BONES_R15
					nBones = #bones
					for i, pair in ipairs(bones) do
						local ln = o.bones[i]
						local a, b = c:FindFirstChild(pair[1]), c:FindFirstChild(pair[2])
						local shown = false
						if a and b then
							local pa = Camera:WorldToViewportPoint(a.Position)
							local pb = Camera:WorldToViewportPoint(b.Position)
							if pa.Z > 0 and pb.Z > 0 then
								P(ln, "From", Vector2.new(pa.X, pa.Y))
								P(ln, "To", Vector2.new(pb.X, pb.Y))
								P(ln, "Color", color)
								shown = true
							end
						end
						P(ln, "Visible", shown)
					end
				end
				for i = nBones + 1, 14 do P(o.bones[i], "Visible", false) end

				-- head dot and look direction
				local head = c:FindFirstChild("Head")
				if head and (Cfg.HeadDot or Cfg.LookLine) then
					local hp2, hOn = Camera:WorldToViewportPoint(head.Position)
					if hOn and hp2.Z > 0 then
						P(o.headDot, "Position", Vector2.new(hp2.X, hp2.Y))
						P(o.headDot, "Radius", math.clamp(height * 0.09, 2, 14))
						P(o.headDot, "Color", color)
						P(o.headDot, "Visible", Cfg.HeadDot)
						if Cfg.LookLine then
							local tip = Camera:WorldToViewportPoint(head.Position + head.CFrame.LookVector * 5)
							P(o.look, "From", Vector2.new(hp2.X, hp2.Y))
							P(o.look, "To", Vector2.new(tip.X, tip.Y))
							P(o.look, "Color", color)
							P(o.look, "Visible", tip.Z > 0)
						else
							P(o.look, "Visible", false)
						end
					else
						P(o.headDot, "Visible", false)
						P(o.look, "Visible", false)
					end
				else
					P(o.headDot, "Visible", false)
					P(o.look, "Visible", false)
				end
			end

			-- tracer
			if Cfg.Tracers and rp.Z > 0 then
				local from
				if Cfg.TracerOrigin == "Center" then
					from = vp / 2
				elseif Cfg.TracerOrigin == "Mouse" then
					from = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
				else
					from = Vector2.new(vp.X / 2, vp.Y)
				end
				P(o.tracer, "From", from)
				P(o.tracer, "To", Vector2.new(rp.X, rp.Y))
				P(o.tracer, "Color", color)
				P(o.tracer, "Visible", true)
			else
				P(o.tracer, "Visible", false)
			end

			radarDot(o, r, myRoot, color)
		end
	end
end

-- chest ESP (gacha chests carry the "GachaChest" tag) ---------------------------------------
local chestDraw = {} -- [Instance] = Text
local chestList, chestClock = {}, 0
local function hideChests()
	for _, t in pairs(chestDraw) do P(t, "Visible", false) end
end
local function renderChests()
	if not Cfg.ChestESP then hideChests() return end
	local now = os.clock()
	if now - chestClock > 3 then
		chestClock = now
		chestList = CollectionService:GetTagged("GachaChest")
		local keep = {}
		for _, m in ipairs(chestList) do keep[m] = true end
		for m, t in pairs(chestDraw) do
			if not keep[m] then
				pcall(t.Remove, t)
				chestDraw[m] = nil
			end
		end
	end
	local myRoot = root()
	for _, m in ipairs(chestList) do
		local part = m:IsA("BasePart") and m or (m:IsA("Model") and (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)))
		if part and part.Parent then
			local t = chestDraw[m]
			if not t then
				t = newDraw("Text", { Size = 13, Center = true, Outline = true, Color = Color3.fromRGB(255, 215, 90), Visible = false })
				chestDraw[m] = t
			end
			local sp, on = Camera:WorldToViewportPoint(part.Position + Vector3.new(0, 3, 0))
			if on and sp.Z > 0 then
				local d = myRoot and (myRoot.Position - part.Position).Magnitude or 0
				P(t, "Text", string.format("%s  %dm", tostring(m:GetAttribute("Chest_Display_Name") or m.Name), math.floor(d)))
				P(t, "Position", Vector2.new(sp.X, sp.Y))
				P(t, "Visible", true)
			else
				P(t, "Visible", false)
			end
		end
	end
end

connect(Players.PlayerRemoving, removeESP)
cleanup(removeAllESP)
cleanup(function()
	for _, plr in ipairs(Players:GetPlayers()) do
		local c = plr.Character
		local hl = c and c:FindFirstChild("FurinaChams")
		if hl then hl:Destroy() end
	end
end)

-- Combat: kill aura ---------------------------------------------------------
local Defs = RS:FindFirstChild("Modules") and RS.Modules.Data.Constants.WeaponData.WeaponDefinitions
local capturedData -- weaponData table seen from a real swing (best template)
local cycle = 0
local lastHit = "none yet"
local hitsSent = 0
local lastTargets = 0

local function buildWeaponData(tool)
	if not tool or not Defs then return end
	local defName = tool:GetAttribute("Weapon_Definition")
	local mod = defName and Defs:FindFirstChild(defName)
	if not mod then return end
	local ok, def = pcall(require, mod)
	if not ok or type(def) ~= "table" then return end

	local order = def.attackOrder or { "1" }
	cycle = cycle % #order + 1
	local v1 = def.attackCycle[tostring(cycle)] or def.attackCycle["1"]
	local zero = Vector3.zero
	local size = tool:GetAttribute("Base_Hitbox_Size") or Vector3.new(9, 14, 8)
	local off = tool:GetAttribute("Base_Hitbox_Offset") or zero
	local kb = tool:GetAttribute("Base_Knockback") or 50
	local lkb = tool:GetAttribute("Lunge_Knockback") or 0

	local d = {
		tool = tool,
		weaponDefinition = def,
		attackCycleData = v1,
		cycleIndex = cycle,
		hitboxSize = size + (v1.hitboxSizeAdd or zero),
		hitboxOffset = off + (v1.hitboxOffsetAdd or zero),
		attackCooldown = tool:GetAttribute("Base_Attack_Cooldown") or 0.1,
		damage = tool:GetAttribute("Base_Damage") or 100,
		knockback = v1.knockback or kb * (v1.knockbackMult or 1),
		lungeKnockback = v1.lungeKnockback or lkb * (v1.lungeMult or 1),
		shouldLunge = tool:GetAttribute("Should_Lunge"),
		shouldSlow = tool:GetAttribute("Should_Slow"),
		slowMult = v1.slowMult,
		slowTime = v1.slowTime,
		shouldLock = tool:GetAttribute("Should_Lock"),
		isCritical = false,
	}
	return d
end

local function weaponDataFor(tool)
	if capturedData and capturedData.tool == tool then
		local copy = table.clone(capturedData)
		copy.isCritical = false
		return copy
	end
	return buildWeaponData(tool)
end

if STATE and STATE.namecallHook then
	STATE.namecallHook("InvokeServer", function(self, method, ...)
		local a1, a2 = ...
		if a1 == "AttemptWeaponHit" and type(a2) == "table" and a2.tool then
			capturedData = table.clone(a2) -- keep the unmodified template
			if Cfg.Hitbox and Cfg.SpoofHitbox and typeof(a2.hitboxSize) == "Vector3" then
				pcall(function() a2.hitboxSize = a2.hitboxSize * Cfg.HitboxMult end)
			end
		end
	end)
end

local function attackOnce()
	local c, myRoot = char(), root()
	if not c or not myRoot then return end
	local h = hum()
	if not h or h.Health <= 0 then return end

	local tool = toolOf(c)
	if not tool then
		if Cfg.AutoEquip then
			tool = LP.Backpack:FindFirstChildOfClass("Tool")
			if tool then h:EquipTool(tool) end
		end
		return
	end
	if tool:GetAttribute("Tool_Type") ~= "Weapon" then return end

	-- gather targets
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local ec, _, er = validEnemy(plr)
		if ec and not (Cfg.SkipFF and ec:FindFirstChildOfClass("ForceField"))
			and not Cfg.Ignore[plr.Name:lower()] and not Cfg.Ignore[plr.DisplayName:lower()] then
			local d = (er.Position - myRoot.Position).Magnitude
			if d <= Cfg.AuraRange then
				local eh = ec:FindFirstChildOfClass("Humanoid")
				list[#list + 1] = { model = ec, root = er, dist = d, hp = eh and eh.Health or 100 }
			end
		end
	end
	if #list == 0 then return end
	if Cfg.LowHPFirst then
		table.sort(list, function(x, y) return x.hp < y.hp end)
	else
		table.sort(list, function(x, y) return x.dist < y.dist end)
	end
	if not Cfg.AuraAll then list = { list[1] } end
	while #list > Cfg.MaxTargets do table.remove(list) end
	lastTargets = #list

	if Cfg.FaceTarget then
		local p = list[1].root.Position
		myRoot.CFrame = CFrame.lookAt(myRoot.Position, Vector3.new(p.X, myRoot.Position.Y, p.Z))
	end

	local data = weaponDataFor(tool)
	if not data then return end

	local hits = {}
	for i, t in ipairs(list) do
		local v = t.root.Position - myRoot.Position
		hits[#hits + 1] = {
			enemyModel = t.model,
			isClosestEnemy = i == 1,
			origin = myRoot.Position,
			distance = t.dist,
			direction = t.dist > 0 and v.Unit or Vector3.zero,
			knockback = data.knockback,
		}
	end

	local ok, res = pcall(function()
		return RS.Events.GameRemoteFunction:InvokeServer("AttemptWeaponHit", data, hits)
	end)
	hitsSent += 1
	lastHit = ok and ("sent " .. #hits .. " target(s), reply " .. tostring(res)) or ("error " .. tostring(res))
end

task.spawn(function()
	while alive() do
		if Cfg.Aura then
			local ok, err = pcall(attackOnce)
			if not ok then lastHit = "error " .. tostring(err) end
			task.wait(math.max(Cfg.AuraDelay, 0.03))
		else
			task.wait(0.2)
		end
	end
end)

-- Stick behind nearest target
connect(RunService.Heartbeat, function()
	if not alive() or not Cfg.Stick then return end
	local myRoot = root()
	local plr = closestEnemy(Cfg.AuraRange + 40)
	if not myRoot or not plr then return end
	local r = plr.Character.HumanoidRootPart
	myRoot.CFrame = r.CFrame * CFrame.new(0, 0, Cfg.StickDist)
end)

-- UI toggle registry (so keybinds / auto-stop can flip the visible switch) ---
local Toggles = {}
local function setToggle(key, v)
	Cfg[key] = v
	local t = Toggles[key]
	if t then pcall(function() t:Set(v) end) end
end

-- Hitbox expander -------------------------------------------------------------
-- The game clones Assets.Parts.HitboxPart into HumanoidRootPart on each swing and
-- runs workspace:GetPartBoundsInBox on its CFrame/Size when the animation marker fires.
connect(RunService.Heartbeat, function()
	if not alive() then return end
	local r = root()
	local part = r and r:FindFirstChild("HitboxPart")
	if not part or not part:IsA("BasePart") then return end
	if Cfg.Hitbox and not part:GetAttribute("FurinaBoost") then
		part:SetAttribute("FurinaBoost", true)
		part.Size = part.Size * Cfg.HitboxMult
		if Cfg.ShowHitbox then
			part.Transparency = 0.75
			part.Color = Color3.fromRGB(255, 70, 70)
			part.Material = Enum.Material.Neon
		end
	end
end)

-- Gacha auto roll ---------------------------------------------------------------
local roll = { count = 0, last = "idle", best = 0 }
task.spawn(function()
	while alive() do
		if Cfg.Rolling then
			local ok, res = pcall(function()
				return RS.Events.GameRemoteFunction:InvokeServer("AttemptRollGachaChest", Cfg.ChestType)
			end)
			roll.count += 1
			if not ok then
				roll.last = "error: " .. tostring(res)
				setToggle("Rolling", false)
			elseif type(res) ~= "table" then
				roll.last = "unexpected reply: " .. tostring(res)
				setToggle("Rolling", false)
			elseif res.code == "NOT_ENOUGH_CURRENCY" then
				roll.last = "out of currency"
				setToggle("Rolling", false)
				Luna:Notification({ Title = "Auto Roll", Content = "Not enough currency. Stopped.", Icon = "warning", ImageSource = "Material" })
			else
				local rw = res.reward
				local rar = rw and rw.rarityInt
				roll.last = tostring(res.code) .. (rar and (" | rarity " .. rar) or "")
				if rar and rar > roll.best then roll.best = rar end
				if rar and rar >= Cfg.StopRarity then
					setToggle("Rolling", false)
					Luna:Notification({ Title = "Auto Roll", Content = "Hit rarity " .. rar .. ". Stopped.", Icon = "stars", ImageSource = "Material" })
				elseif roll.count >= Cfg.MaxRolls then
					setToggle("Rolling", false)
				end
			end
			task.wait(math.max(Cfg.RollDelay, 0.3))
		else
			task.wait(0.25)
		end
	end
end)

-- HUD ---------------------------------------------------------------------------
local hud = newDraw("Text", { Size = 14, Outline = true, Color = Color3.fromRGB(170, 200, 255), Position = Vector2.new(12, 12), Visible = false })
local fpsAcc, fpsN, fps = 0, 0, 60
connect(RunService.RenderStepped, function(dt)
	if not alive() then return end
	fpsAcc += dt fpsN += 1
	if fpsAcc >= 0.5 then fps = math.floor(fpsN / fpsAcc) fpsAcc, fpsN = 0, 0 end
	hud.Visible = Cfg.HUD
	if Cfg.HUD and fpsN == 0 then -- rebuild the string only when the fps counter ticks (2x/second)
		hud.Text = string.format("Furina Hub | %d fps | Aura %s (%d in range, %d sent) | Rolls %d",
			fps, Cfg.Aura and "ON" or "off", lastTargets, hitsSent, roll.count)
	end
end)

-- Proximity alert ---------------------------------------------------------------------
-- In a game about hidden players, a number on screen telling you who is close is the most useful ESP.
local alertText = newDraw("Text", { Size = 18, Center = true, Outline = true, Color = Color3.fromRGB(255, 90, 90), Visible = false })
local alertAcc = 0
connect(RunService.RenderStepped, function(dt)
	if not alive() then return end
	alertAcc += dt
	if alertAcc < 0.2 then return end
	alertAcc = 0
	if not Cfg.Alert then alertText.Visible = false return end
	local plr, d = closestEnemy(Cfg.AlertRange)
	if plr then
		local vp = Camera.ViewportSize
		alertText.Text = string.format("%s  %dm", plr.DisplayName, math.floor(d))
		alertText.Position = Vector2.new(vp.X / 2, vp.Y * 0.14)
		alertText.Visible = true
	else
		alertText.Visible = false
	end
end)

-- Auto dodge (experimental) --------------------------------------------------------------
-- Watches enemies inside DodgeRange. If one is playing an animation that lives in an "Attack"
-- folder (how this game's weapons store their swings) and is facing you, sidestep.
local lastDodge = 0
task.spawn(function()
	while alive() do
		task.wait(0.05)
		if Cfg.Dodge then
			local myRoot, h = root(), hum()
			if myRoot and h and h.Health > 0 and os.clock() - lastDodge > 0.6 then
				for _, plr in ipairs(Players:GetPlayers()) do
					local c, _, r = validEnemy(plr)
					if c and (r.Position - myRoot.Position).Magnitude <= Cfg.DodgeRange then
						local toMe = myRoot.Position - r.Position
						local facing = toMe.Magnitude > 0 and r.CFrame.LookVector:Dot(toMe.Unit) or 0
						local animator = c:FindFirstChildWhichIsA("Animator", true)
						local attacking = false
						if animator and facing > 0.3 then
							for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
								local a = tr.Animation
								if a and a.Parent and a.Parent.Name == "Attack" and tr.TimePosition < 0.4 then
									attacking = true
									break
								end
							end
						end
						if attacking then
							lastDodge = os.clock()
							local side = toMe.Unit:Cross(Vector3.yAxis)
							if math.random() < 0.5 then side = -side end
							pcall(function() myRoot.CFrame = myRoot.CFrame + side * Cfg.DodgeDist end)
							break
						end
					end
				end
			end
		end
	end
end)

-- Keybinds ----------------------------------------------------------------------
connect(UserInputService.InputBegan, function(input, gp)
	if gp or not alive() then return end
	if input.KeyCode == Cfg.AuraKey then
		setToggle("Aura", not Cfg.Aura)
		Luna:Notification({ Title = "Kill Aura", Content = Cfg.Aura and "Enabled" or "Disabled", Icon = "gavel", ImageSource = "Material" })
	elseif input.KeyCode == Cfg.ESPKey then
		setToggle("ESP", not Cfg.ESP)
	end
end)

-- No attack cooldown ------------------------------------------------------------
-- AttackController._onCooldown gates every swing (tick() < nextAttackTime). The class table
-- is shared by every instance, so wrapping it applies to the live controller too.
local patchedAC, origCooldown
do
	local ok, AC = pcall(function()
		return require(RS.Modules.ClientGameHandler.ClientCombatHandler.CombatControllers.AttackController)
	end)
	if ok and type(AC) == "table" and type(AC._onCooldown) == "function" then
		patchedAC, origCooldown = AC, AC._onCooldown
		AC._onCooldown = function(self)
			if Cfg.NoCD then
				return tick() < (self.lastAttackTime or 0) + Cfg.NoCDDelay
			end
			return origCooldown(self)
		end
	end
end
cleanup(function()
	if patchedAC and origCooldown then patchedAC._onCooldown = origCooldown end
end)

-- Anti slow -----------------------------------------------------------------------
-- SpeedController multiplies WalkSpeed by named modifiers (e.g. "AttackSlow"). While
-- AntiSlow is on, any modifier below 1 is stored as 1 so it has no effect.
local patchedSC, origAddMod
do
	local ok, SC = pcall(function()
		return require(RS.Modules.ClientGameHandler.ClientCombatHandler.CombatControllers.CharacterController.SpeedController)
	end)
	if ok and type(SC) == "table" and type(SC.addModifier) == "function" then
		patchedSC, origAddMod = SC, SC.addModifier
		SC.addModifier = function(self, name, mult)
			if Cfg.AntiSlow and type(mult) == "number" and mult < 1 then mult = 1 end
			return origAddMod(self, name, mult)
		end
	end
end
cleanup(function()
	if patchedSC and origAddMod then patchedSC.addModifier = origAddMod end
end)

-- Aimlock -------------------------------------------------------------------
local fovCircle = newDraw("Circle", { Thickness = 1, Filled = false, Color = Color3.new(1, 1, 1), Transparency = 0.8, Visible = false, Radius = 180 })
local function aimStep()
	if not alive() then return end
	local vp = Camera.ViewportSize
	local center = vp / 2
	fovCircle.Position = center
	fovCircle.Radius = Cfg.AimFOV
	fovCircle.Visible = Cfg.Aim and Cfg.ShowFOV
	if not Cfg.Aim then return end
	if Cfg.AimHold and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then return end

	local best, bestD
	for _, plr in ipairs(Players:GetPlayers()) do
		local c = validEnemy(plr)
		if c and not Cfg.Ignore[plr.Name:lower()] then
			local part = c:FindFirstChild(Cfg.AimPart) or c:FindFirstChild("HumanoidRootPart")
			if part then
				local sp, on = Camera:WorldToViewportPoint(part.Position)
				if on then
					local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
					if d <= Cfg.AimFOV and (not bestD or d < bestD) then best, bestD = part, d end
				end
			end
		end
	end
	if best then
		local goal = CFrame.lookAt(Camera.CFrame.Position, best.Position)
		Camera.CFrame = Camera.CFrame:Lerp(goal, 1 / math.max(Cfg.AimSmooth, 1))
	end
end
pcall(function() RunService:UnbindFromRenderStep("FurinaAim") end)
RunService:BindToRenderStep("FurinaAim", Enum.RenderPriority.Camera.Value + 1, aimStep)
cleanup(function() pcall(function() RunService:UnbindFromRenderStep("FurinaAim") end) end)

-- Anti knockback + always-equip -----------------------------------------------
connect(RunService.Heartbeat, function()
	if not alive() then return end
	local r, h = root(), hum()
	if not r or not h then return end
	if Cfg.AntiKB and not Cfg.Fly then
		local v = r.AssemblyLinearVelocity
		local horiz = Vector3.new(v.X, 0, v.Z)
		local limit = math.max(h.WalkSpeed * 1.6, 30)
		if horiz.Magnitude > limit then
			r.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0) + horiz.Unit * h.WalkSpeed
		end
	end
	if Cfg.AntiSlow and not Cfg.Speed and h.WalkSpeed < 16 and h.WalkSpeed > 0 then
		h.WalkSpeed = 16 -- catches slows applied outside the SpeedController
	end
	if Cfg.AlwaysEquip and h.Health > 0 and not toolOf(char()) then
		local t = LP.Backpack:FindFirstChildOfClass("Tool")
		if t then h:EquipTool(t) end
	end
end)

-- Spectate / teleport helpers ---------------------------------------------------
local function findPlayer(name)
	name = tostring(name or ""):lower()
	if name == "" then return end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and (p.Name:lower():find(name, 1, true) or p.DisplayName:lower():find(name, 1, true)) then return p end
	end
end
local function stopSpectate()
	local h = hum()
	if h then Camera.CameraSubject = h end
end
cleanup(stopSpectate)

-- FPS boost ------------------------------------------------------------------------
-- Turns off particle emitters, beams, trails, smoke and fire (including new ones as they
-- spawn) and drops shadows. Everything it disables is remembered and restored.
local boosted = {}
local boostConn
local FX = { ParticleEmitter = true, Beam = true, Trail = true, Smoke = true, Fire = true, Sparkles = true }
local function boostOne(d)
	if FX[d.ClassName] and d.Enabled then
		boosted[d] = true
		d.Enabled = false
	end
end
local function setBoost(on)
	if boostConn then boostConn:Disconnect() boostConn = nil end
	if on then
		task.spawn(function()
			local n = 0
			for _, d in ipairs(workspace:GetDescendants()) do
				if not (Cfg.FPSBoost and alive()) then return end
				boostOne(d)
				n += 1
				if n % 1500 == 0 then task.wait() end -- never block a frame
			end
		end)
		boostConn = workspace.DescendantAdded:Connect(function(d) if alive() then boostOne(d) end end)
		Lighting.GlobalShadows = false
	else
		for d in pairs(boosted) do pcall(function() d.Enabled = true end) end
		table.clear(boosted)
		Lighting.GlobalShadows = true
	end
end
cleanup(function() setBoost(false) end)

-- Fullbright ----------------------------------------------------------------
local origLight = {
	Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
	FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient,
}
local function applyLight(on)
	if on then
		Lighting.Brightness = 2
		Lighting.ClockTime = 14
		Lighting.FogEnd = 1e6
		Lighting.GlobalShadows = false
		Lighting.Ambient = Color3.fromRGB(178, 178, 178)
	else
		for k, v in pairs(origLight) do Lighting[k] = v end
	end
end
cleanup(function() applyLight(false) end)

-- Fly -----------------------------------------------------------------------
local flyBV, flyBG
local function stopFly()
	if flyBV then flyBV:Destroy() flyBV = nil end
	if flyBG then flyBG:Destroy() flyBG = nil end
	local h = hum()
	if h then h.PlatformStand = false end
end
local function startFly()
	local r, h = root(), hum()
	if not r or not h then return end
	stopFly()
	flyBV = Instance.new("BodyVelocity")
	flyBV.MaxForce = Vector3.new(1e9, 1e9, 1e9)
	flyBV.Velocity = Vector3.zero
	flyBV.Parent = r
	flyBG = Instance.new("BodyGyro")
	flyBG.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
	flyBG.P = 1e4
	flyBG.CFrame = r.CFrame
	flyBG.Parent = r
	h.PlatformStand = true
end
cleanup(stopFly)

-- Panic -----------------------------------------------------------------------
local function panic()
	for _, k in ipairs({ "Aura", "NoCD", "Aim", "Hitbox", "Stick", "FaceTarget", "Rolling", "ESP", "Fly", "Noclip", "Speed", "Jump", "Dodge", "AntiSlow", "AntiKB", "Fullbright", "FOVOn" }) do
		setToggle(k, false)
	end
	stopFly()
	applyLight(false)
	Camera.FieldOfView = 70
	local h = hum()
	if h then h.WalkSpeed = 16 h.JumpPower = 38 end
	Luna:Notification({ Title = "Panic", Content = "All features disabled.", Icon = "warning", ImageSource = "Material" })
end
connect(UserInputService.InputBegan, function(input, gp)
	if not gp and alive() and input.KeyCode == Cfg.PanicKey then panic() end
end)

-- Main loops -----------------------------------------------------------------
local espAcc = 0
connect(RunService.RenderStepped, function(dt)
	if not alive() then return end
	espAcc += dt
	if espAcc >= 1 / 60 then -- 60 ESP updates a second is plenty; skips the rest on fast machines
		espAcc = 0
		renderESP()
		renderChests()
	end
	if Cfg.FOVOn then Camera.FieldOfView = Cfg.FOV end
end)

connect(RunService.Heartbeat, function()
	if not alive() then return end
	local h, r = hum(), root()
	if h then
		if Cfg.Speed then h.WalkSpeed = Cfg.SpeedValue end
		if Cfg.Jump then h.UseJumpPower = true h.JumpPower = Cfg.JumpValue end
	end
	if Cfg.Fly and r and flyBV and flyBG then
		local dir, cf = Vector3.zero, Camera.CFrame
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cf.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cf.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cf.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cf.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then dir -= Vector3.yAxis end
		flyBV.Velocity = dir.Magnitude > 0 and dir.Unit * Cfg.FlySpeed or Vector3.zero
		flyBG.CFrame = cf
	end
end)

local ncParts, ncChar, ncClock = {}, nil, 0
connect(RunService.Stepped, function()
	if not alive() or not Cfg.Noclip then return end
	local c = char()
	if not c then return end
	local now = os.clock()
	if c ~= ncChar or now - ncClock > 1 then -- rescan parts once a second, not every frame
		ncChar, ncClock = c, now
		table.clear(ncParts)
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") then ncParts[#ncParts + 1] = p end
		end
	end
	for i = 1, #ncParts do
		local p = ncParts[i]
		if p.CanCollide then p.CanCollide = false end
	end
end)

connect(UserInputService.JumpRequest, function()
	if alive() and Cfg.InfJump then
		local h = hum()
		if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
	end
end)

connect(LP.Idled, function()
	if alive() and Cfg.AntiAFK then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.zero)
	end
end)

connect(LP.CharacterAdded, function()
	task.wait(0.5)
	capturedData = nil
	if Cfg.Fly then startFly() end
end)

-- UI ---------------------------------------------------------------------------
local Window = Luna:CreateWindow({
	Name = "Furina Hub",
	Subtitle = "Silent Assassins",
	LogoID = "6031097225",
	LoadingEnabled = false,
	ConfigSettings = { ConfigFolder = "FurinaHub" },
	KeySystem = false,
})
cleanup(function() pcall(function() Luna:Destroy() end) end)

local function tab(name, icon) return Window:CreateTab({ Name = name, Icon = icon, ImageSource = "Material", ShowTitle = true }) end
local function tog(t, name, key, desc, cb)
	Toggles[key] = t:CreateToggle({ Name = name, Description = desc, CurrentValue = Cfg[key], Callback = function(v) Cfg[key] = v if cb then cb(v) end end })
end
local Sliders = {} -- [key] = { obj, scale } so Load Config can move the sliders too
-- scale lets a slider show whole numbers for a decimal setting (shown value = Cfg[key] * scale)
local function sld(t, name, key, lo, hi, scale)
	scale = scale or 1
	Sliders[key] = {
		scale = scale,
		obj = t:CreateSlider({
			Name = name, Range = { lo, hi }, Increment = 1,
			CurrentValue = math.clamp(math.floor(Cfg[key] * scale + 0.5), lo, hi),
			Callback = function(v) Cfg[key] = v / scale end,
		}),
	}
end
local function refreshUI() -- push Cfg back into the visible toggles and sliders
	for key, t in pairs(Toggles) do pcall(function() t:Set(Cfg[key]) end) end
	for key, s in pairs(Sliders) do pcall(function() s.obj:Set(math.floor(Cfg[key] * s.scale + 0.5)) end) end
end

local Combat = tab("Combat", "gavel")
tog(Combat, "Kill Aura", "Aura", "Auto-hits every enemy in range with your equipped weapon")
sld(Combat, "Aura Range", "AuraRange", 5, 150)
sld(Combat, "Aura Delay (x0.01s)", "AuraDelay", 3, 100, 100)
tog(Combat, "No Attack Cooldown", "NoCD", "Swing as fast as the delay below allows (hold left click)")
sld(Combat, "Swing Delay (x0.01s)", "NoCDDelay", 0, 50, 100)
tog(Combat, "Hit All In Range", "AuraAll", "Off = only the closest enemy")
tog(Combat, "Auto Equip Weapon", "AutoEquip")
tog(Combat, "Skip Forcefielded", "SkipFF")
tog(Combat, "Lowest HP First", "LowHPFirst", "Prioritise weak targets instead of the nearest")
sld(Combat, "Max Targets Per Swing", "MaxTargets", 1, 10)
Combat:CreateBind({ Name = "Kill Aura Key", Description = "Press to toggle the aura", CurrentBind = Cfg.AuraKey.Name,
	Callback = function() end,
	OnChangedCallback = function(k) if typeof(k) == "EnumItem" then Cfg.AuraKey = k end end })
Combat:CreateInput({ Name = "Ignore Players", Description = "Comma separated names the aura will never hit",
	PlaceholderText = "friend1, friend2", RemoveTextAfterFocusLost = false,
	CurrentValue = (function() local n = {} for k in pairs(Cfg.Ignore) do n[#n + 1] = k end return table.concat(n, ", ") end)(),
	Callback = function(text)
		Cfg.Ignore = {}
		for n in tostring(text):gmatch("[^,%s]+") do Cfg.Ignore[n:lower()] = true end
	end })
tog(Combat, "Face Target", "FaceTarget", "Turns you toward the closest enemy while attacking")
tog(Combat, "Stick To Target", "Stick", "Teleports you behind the closest enemy every frame")
sld(Combat, "Stick Distance", "StickDist", 2, 10)
Combat:CreateButton({ Name = "Teleport To Nearest", Callback = function()
	local plr = closestEnemy()
	local myRoot = root()
	if plr and myRoot then myRoot.CFrame = plr.Character.HumanoidRootPart.CFrame * CFrame.new(0, 0, 4) end
end })
Combat:CreateButton({ Name = "Aura Status", Description = "Shows the last attack result in a notification", Callback = function()
	Luna:Notification({ Title = "Kill Aura", Content = "Sent " .. hitsSent .. " | last: " .. lastHit, Icon = "info", ImageSource = "Material" })
end })

local Power = tab("Power", "bolt")
tog(Power, "Aimlock", "Aim", "Smoothly turns the camera to the nearest enemy inside the circle")
tog(Power, "Hold Right Mouse To Aim", "AimHold")
tog(Power, "Show FOV Circle", "ShowFOV")
sld(Power, "Aim FOV (px)", "AimFOV", 30, 600)
sld(Power, "Aim Smoothness", "AimSmooth", 1, 20)
Power:CreateButton({ Name = "Aim At: Head / Body (toggle)", Callback = function()
	Cfg.AimPart = Cfg.AimPart == "Head" and "HumanoidRootPart" or "Head"
	Luna:Notification({ Title = "Aimlock", Content = "Aiming at " .. Cfg.AimPart, Icon = "my_location", ImageSource = "Material" })
end })
tog(Power, "Auto Dodge (experimental)", "Dodge", "Sidesteps when a nearby enemy starts a swing at you. May not beat the server's timing")
sld(Power, "Dodge Trigger Range", "DodgeRange", 6, 30)
sld(Power, "Dodge Distance", "DodgeDist", 4, 16)
tog(Power, "Proximity Alert", "Alert", "Shows the nearest enemy's name and distance near the top of the screen")
sld(Power, "Alert Range", "AlertRange", 10, 200)
tog(Power, "Anti Slow", "AntiSlow", "Stops swing and hit slowdowns from reducing your speed")
tog(Power, "Anti Knockback", "AntiKB", "Cancels most of the knockback you take")
tog(Power, "Always Hold Weapon", "AlwaysEquip", "Re-equips your weapon whenever it is put away")
Power:CreateBind({ Name = "Panic Key", Description = "Turns every feature off at once", CurrentBind = Cfg.PanicKey.Name,
	Callback = function() end,
	OnChangedCallback = function(k) if typeof(k) == "EnumItem" then Cfg.PanicKey = k end end })
Power:CreateButton({ Name = "Panic Now", Callback = function() panic() end })
Power:CreateInput({ Name = "Player Name", Description = "Part of a player's name for the buttons below",
	PlaceholderText = "name", CurrentValue = "", RemoveTextAfterFocusLost = false,
	Callback = function(t) Cfg.TargetName = t end })
Power:CreateButton({ Name = "Spectate Player", Callback = function()
	local p = findPlayer(Cfg.TargetName)
	local h = p and p.Character and p.Character:FindFirstChildOfClass("Humanoid")
	if h then Camera.CameraSubject = h end
end })
Power:CreateButton({ Name = "Stop Spectating", Callback = stopSpectate })
Power:CreateButton({ Name = "Teleport To Player", Callback = function()
	local p = findPlayer(Cfg.TargetName)
	local r, mine = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart"), root()
	if r and mine then mine.CFrame = r.CFrame * CFrame.new(0, 0, 4) end
end })

local Hit = tab("Hitbox", "crop_free")
tog(Hit, "Bigger Hitbox", "Hitbox", "Enlarges your weapon hitbox on every swing")
sld(Hit, "Hitbox Size (x)", "HitboxMult", 1, 10)
tog(Hit, "Show Hitbox", "ShowHitbox", "Draws the swing box in red neon")
tog(Hit, "Spoof Size To Server", "SpoofHitbox", "Also reports the bigger size in the hit packet. Riskier: the server sees a number that doesn't match your weapon")
Hit:CreateLabel({ Text = "Hit detection runs on your client, so the bigger box really catches more enemies. Whether the server accepts far hits is unverified.", Style = 2 })

local Luck = tab("Luck", "casino")
Luck:CreateLabel({ Text = "Rolls are decided on the server, so luck itself cannot be raised from here. This tab rolls for you and stops on a rarity you choose.", Style = 3 })
Luck:CreateLabel({ Text = "Odds by tier (common to best): Basic 76/18/5/1/0 %. Divine 0/70/25/4/1 %. Divine has far better odds per coin.", Style = 2 })
Luck:CreateDropdown({ Name = "Chest", Options = { "Basic", "Divine" }, CurrentOption = { Cfg.ChestType }, MultipleOptions = false,
	Callback = function(o) Cfg.ChestType = type(o) == "table" and o[1] or o end })
tog(Luck, "Auto Roll", "Rolling", "Rolls the chest repeatedly. Spends your currency.")
sld(Luck, "Stop At Rarity (1-5)", "StopRarity", 1, 5)
sld(Luck, "Max Rolls", "MaxRolls", 1, 200)
sld(Luck, "Roll Delay (x0.1s)", "RollDelay", 3, 40, 10)
Luck:CreateButton({ Name = "Roll Status", Callback = function()
	Luna:Notification({ Title = "Auto Roll", Content = "Rolls " .. roll.count .. " | best rarity " .. roll.best .. " | last: " .. roll.last, Icon = "info", ImageSource = "Material" })
end })
Luck:CreateButton({ Name = "Reset Roll Counter", Callback = function() roll.count = 0 roll.best = 0 end })

local function dd(t, name, key, options)
	t:CreateDropdown({ Name = name, Options = options, CurrentOption = { Cfg[key] }, MultipleOptions = false,
		Callback = function(o) Cfg[key] = type(o) == "table" and o[1] or o end })
end
local function head(t, text) t:CreateLabel({ Text = text, Style = 2 }) end

local ESPTab = tab("ESP", "visibility")
head(ESPTab, "Master")
tog(ESPTab, "Player ESP", "ESP", "Master switch for everything below (key: Z by default)")
ESPTab:CreateBind({ Name = "ESP Key", Description = "Press to toggle ESP", CurrentBind = Cfg.ESPKey.Name,
	Callback = function() end,
	OnChangedCallback = function(k) if typeof(k) == "EnumItem" then Cfg.ESPKey = k end end })
sld(ESPTab, "Max Distance", "ESPMax", 100, 5000)
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
tog(ESPTab, "Held Weapon", "Weapon")
tog(ESPTab, "Attack Warning", "Threat", "Flags enemies that are mid-swing and turns them orange")
tog(ESPTab, "Target Tag", "TargetTag", "Marks the closest enemy")
sld(ESPTab, "Text Size", "TextSize", 9, 20)
head(ESPTab, "Body")
tog(ESPTab, "Skeleton", "Skeleton")
sld(ESPTab, "Skeleton Range", "SkelDist", 50, 600)
tog(ESPTab, "Head Dot", "HeadDot")
tog(ESPTab, "Look Direction", "LookLine", "A line showing where each enemy is facing")
tog(ESPTab, "Chams", "Chams", "Highlight through walls")
sld(ESPTab, "Chams Fill (% see-through)", "ChamsFill", 0, 100)
head(ESPTab, "Lines and arrows")
tog(ESPTab, "Tracers", "Tracers")
dd(ESPTab, "Tracer Origin", "TracerOrigin", { "Bottom", "Center", "Mouse" })
tog(ESPTab, "Off-Screen Arrows", "Arrows", "Pointers with distance to enemies outside your view")
head(ESPTab, "Radar")
tog(ESPTab, "Radar", "Radar", "Top-down map of nearby enemies, top-left of the screen")
sld(ESPTab, "Radar Range (studs)", "RadarRange", 30, 400)
sld(ESPTab, "Radar Size", "RadarSize", 40, 120)
head(ESPTab, "World")
tog(ESPTab, "Chest ESP", "ChestESP", "Names and distances for gacha chests")
head(ESPTab, "Colors")
tog(ESPTab, "Rainbow", "Rainbow")
tog(ESPTab, "Visible Color", "VisCheck", "Enemies in line of sight use the visible color")
ESPTab:CreateColorPicker({ Name = "Base Color", Color = Cfg.ESPColor, Callback = function(c) Cfg.ESPColor = c end })
ESPTab:CreateColorPicker({ Name = "Visible Color", Color = Cfg.VisColor, Callback = function(c) Cfg.VisColor = c end })
ESPTab:CreateColorPicker({ Name = "Target Color", Color = Cfg.TargetColor, Callback = function(c) Cfg.TargetColor = c end })
ESPTab:CreateColorPicker({ Name = "Attacking Color", Color = Cfg.ThreatColor, Callback = function(c) Cfg.ThreatColor = c end })

local Visuals = tab("Visuals", "palette")
tog(Visuals, "HUD", "HUD", "Top-left status line")
tog(Visuals, "Fullbright", "Fullbright", nil, applyLight)
tog(Visuals, "Custom FOV", "FOVOn", nil, function(v) if not v then Camera.FieldOfView = 70 end end)
sld(Visuals, "FOV", "FOV", 30, 120)

local Move = tab("Movement", "directions_run")
tog(Move, "Speed", "Speed", nil, function(v) if not v then local h = hum() if h then h.WalkSpeed = 16 end end end)
sld(Move, "Walk Speed", "SpeedValue", 16, 120)
tog(Move, "Jump Power", "Jump", nil, function(v) if not v then local h = hum() if h then h.JumpPower = 38 end end end)
sld(Move, "Jump Value", "JumpValue", 38, 200)
tog(Move, "Infinite Jump", "InfJump")
tog(Move, "Noclip", "Noclip")
tog(Move, "Fly", "Fly", "WASD + Space / Shift", function(v) if v then startFly() else stopFly() end end)
sld(Move, "Fly Speed", "FlySpeed", 20, 200)

local Misc = tab("Misc", "settings")
tog(Misc, "FPS Boost", "FPSBoost", "Disables particles, beams, trails and shadows to raise fps. Turn off to restore", setBoost)
if Cfg.FPSBoost then setBoost(true) end
tog(Misc, "Anti AFK", "AntiAFK")
local function notify(title, text, icon)
	Luna:Notification({ Title = title, Content = text, Icon = icon or "info", ImageSource = "Material" })
end
tog(Misc, "Auto Save Config", "AutoSave", "Saves a moment after any setting changes, and loads on start")
local cfgInput = cfgProfile
Misc:CreateInput({ Name = "Config Name", Description = "Letters, numbers, - and _ only. Active: " .. cfgProfile,
	PlaceholderText = cfgProfile, CurrentValue = cfgProfile, RemoveTextAfterFocusLost = false,
	Callback = function(t) cfgInput = cleanName(t) or cfgProfile end })
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
				local n = tostring(f):match("([^/\]+)%.json$")
				if n then names[#names + 1] = n end
			end
		end
	end
	notify("Configs", #names > 0 and table.concat(names, ", ") or "none found (or this executor cannot list files)")
end })
Misc:CreateButton({ Name = "Delete Config", Description = "Deletes the config named above", Callback = function()
	local okd = pcall(function() if delfile and isfile(cfgPath(cfgInput)) then delfile(cfgPath(cfgInput)) end end)
	notify("Config", okd and ("Deleted " .. cfgInput) or "Could not delete", okd and "delete" or "warning")
end })

-- auto-save: write whenever something changed, and at least every 30 seconds
local lastSig = signature()
local saveFailedNotified = false
task.spawn(function()
	local sinceForce = 0
	while alive() do
		task.wait(1.5)
		sinceForce += 1.5
		if Cfg.AutoSave then
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
		end
	end
end)
cleanup(function() if Cfg.AutoSave then saveCfg() end end)
Misc:CreateButton({ Name = "Unload Hub", Description = "Turns everything off and removes the menu", Callback = function()
	panic()
	if getgenv().FurinaHubUnload then
		getgenv().FurinaHubUnload()
	else
		unloaded = true
		pcall(function() Luna:Destroy() end)
		pcall(removeAllESP)
	end
end })
Misc:CreateButton({ Name = "Rejoin Server", Callback = function()
	TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
end })
Misc:CreateLabel({ Text = "Furina Hub - Silent Assassins", Style = 2 })

Luna:Notification({ Title = "Furina Hub", Content = "Loaded. Combat + new ESP ready.", Icon = "check_circle", ImageSource = "Material" })
