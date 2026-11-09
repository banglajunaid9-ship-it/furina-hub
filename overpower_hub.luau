-- Overpower Hub v2 | universal: Overpower + Troll + Utility
-- UI: Rayfield Gen2
-- Run via live-reload (STATE) or plain loadstring (builds its own teardown).
-- Debug: getgenv().OverpowerCfg exposes every setting.

local STATE = STATE
if not STATE then
	if getgenv().OverpowerHubUnload then pcall(getgenv().OverpowerHubUnload) end
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
	getgenv().OverpowerHubUnload = function()
		running = false
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
		getgenv().OverpowerHubUnload = nil
	end
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()

-- ───────── config ─────────
local Cfg = {
	Speed = false, SpeedValue = 40, SpeedMode = "Auto",
	Jump = false, JumpValue = 90,
	InfJump = false, Noclip = false,
	Fly = false, FlySpeed = 70,
	God = false, AntiVoid = false, ClickTP = false, AntiRagdoll = false,
	Aim = false, AimFOV = 160, AimSmooth = 5, AimTeamCheck = true, AimPart = "Head", AimWall = true,
	ESP = false, ESPTeamCheck = false, ESPNames = true,
	FullBright = false, NoFog = false, FOVOn = false, FOV = 90,
	AntiAFK = true,
	-- troll
	Target = nil,
	TouchFling = false, FlingPower = 1e5, HeavyFling = true,
	Orbit = false, OrbitSpeed = 3, OrbitRadius = 8, OrbitHeight = 0,
	Follow = false, Headsit = false, Backpack = false,
	Spin = false, SpinSpeed = 40, FakeLag = false,
	ChatSpam = false, ChatMsg = "Overpower Hub on top", ChatDelay = 2,
	FlingBusy = false,
}
getgenv().OverpowerCfg = Cfg

-- ───────── helpers ─────────
local function char() return LP.Character end
local function hum()
	local c = LP.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function root()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function rootOf(p)
	local c = p and p.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function target()
	return Cfg.Target and Players:FindFirstChild(Cfg.Target)
end
local function playerNames()
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then t[#t + 1] = p.Name end
	end
	table.sort(t)
	return t
end

-- ───────── window ─────────
local window = Rayfield:CreateWindow({
	name = "Overpower Hub",
	subtitle = "Overpower • Troll • Utility",
	sidebarLayout = true,
	configuration = { autoSave = false, autoLoad = false, fileName = "OverpowerHub" },
})
STATE.onCleanup(function()
	local done = false
	for _, m in ipairs({ "Destroy", "Unload", "Close" }) do
		local ok, f = pcall(function() return window[m] end)
		if ok and type(f) == "function" then
			done = pcall(f, window) or done
			if done then break end
		end
	end
	if not done then pcall(function() Rayfield:Destroy() end) end
end)

local function notify(t, c) pcall(function() window:Notify({ title = t, content = c }) end) end

local tabPower = window:CreateTab({ name = "Overpower" })
local tabCombat = window:CreateTab({ name = "Combat/Visual" })
local tabTroll = window:CreateTab({ name = "Troll" })
local tabUtil = window:CreateTab({ name = "Utility" })

-- ───────── overpower tab ─────────
tabPower:CreateToggle({ name = "Speed Hack", callback = function(v) Cfg.Speed = v end })
tabPower:CreateDropdown({
	name = "Speed Method", options = { "Auto", "WalkSpeed", "CFrame" }, value = "Auto",
	description = "Auto sets WalkSpeed and tops up with CFrame if the game resets it.",
	callback = function(v) Cfg.SpeedMode = v end,
})
tabPower:CreateSlider({ name = "Speed Value", range = { 16, 300 }, value = 40, callback = function(v) Cfg.SpeedValue = v end })
tabPower:CreateToggle({ name = "Jump Power", callback = function(v) Cfg.Jump = v end })
tabPower:CreateSlider({ name = "Jump Value", range = { 50, 400 }, value = 90, callback = function(v) Cfg.JumpValue = v end })
tabPower:CreateToggle({ name = "Infinite Jump", callback = function(v) Cfg.InfJump = v end })
tabPower:CreateToggle({ name = "Noclip", callback = function(v) Cfg.Noclip = v end })
tabPower:CreateToggle({ name = "Fly (WASD / Space / Ctrl)", callback = function(v) Cfg.Fly = v end })
tabPower:CreateSlider({ name = "Fly Speed", range = { 20, 400 }, value = 70, callback = function(v) Cfg.FlySpeed = v end })
tabPower:CreateToggle({ name = "God-ish (health lock, client only)", callback = function(v) Cfg.God = v end })
tabPower:CreateToggle({ name = "Anti-Ragdoll / Anti-Fall-Damage", callback = function(v) Cfg.AntiRagdoll = v end })
tabPower:CreateToggle({ name = "Anti-Void", callback = function(v) Cfg.AntiVoid = v end })
tabPower:CreateToggle({ name = "Ctrl + Click Teleport", callback = function(v) Cfg.ClickTP = v end })

-- ───────── combat / visual ─────────
tabCombat:CreateToggle({ name = "Aimbot (hold right mouse)", callback = function(v) Cfg.Aim = v end })
tabCombat:CreateSlider({ name = "Aim FOV", range = { 30, 600 }, value = 160, callback = function(v) Cfg.AimFOV = v end })
tabCombat:CreateSlider({ name = "Aim Smoothing", range = { 1, 20 }, value = 5, callback = function(v) Cfg.AimSmooth = v end })
tabCombat:CreateToggle({ name = "Aim Team Check", value = true, callback = function(v) Cfg.AimTeamCheck = v end })
tabCombat:CreateToggle({ name = "Aim Visible Only", value = true, callback = function(v) Cfg.AimWall = v end })
tabCombat:CreateDropdown({
	name = "Aim Part", options = { "Head", "HumanoidRootPart" }, value = "Head",
	callback = function(v) Cfg.AimPart = v end,
})
tabCombat:CreateDivider({ text = "visuals" })
tabCombat:CreateToggle({ name = "Player ESP", callback = function(v) Cfg.ESP = v end })
tabCombat:CreateToggle({ name = "ESP Names + Distance", value = true, callback = function(v) Cfg.ESPNames = v end })
tabCombat:CreateToggle({ name = "ESP Team Check (hide teammates)", callback = function(v) Cfg.ESPTeamCheck = v end })
tabCombat:CreateToggle({ name = "Fullbright", callback = function(v) Cfg.FullBright = v end })
tabCombat:CreateToggle({ name = "Remove Fog", callback = function(v) Cfg.NoFog = v end })
tabCombat:CreateToggle({ name = "Custom FOV", callback = function(v) Cfg.FOVOn = v end })
tabCombat:CreateSlider({ name = "Field of View", range = { 40, 120 }, value = 90, callback = function(v) Cfg.FOV = v end })

-- ───────── troll ─────────
local targetDD
targetDD = tabTroll:CreateDropdown({
	name = "Target Player", options = playerNames(), placeholder = "pick a player",
	callback = function(v) Cfg.Target = v end,
})
tabTroll:CreateButton({
	name = "Refresh Player List",
	callback = function() pcall(function() targetDD:Refresh(playerNames()) end) end,
})

-- fling engine ---------------------------------------------------
local savedPhys
local function heavy(on)
	local r = root()
	if not r then return end
	if on then
		if savedPhys == nil then savedPhys = r.CustomPhysicalProperties or false end
		r.CustomPhysicalProperties = PhysicalProperties.new(100, 0.3, 0.5, 1, 1)
	elseif savedPhys ~= nil then
		r.CustomPhysicalProperties = savedPhys or nil
		savedPhys = nil
	end
end

-- Many games put characters in a group that ignores other players, which makes flinging
-- impossible. Move our body to a collision group that DOES collide with the victim's.
local PhysicsService = game:GetService("PhysicsService")
local savedColl = {}
local function collideWith(victimRoot)
	local c = LP.Character
	if not c then return end
	local vg = victimRoot.CollisionGroup
	local pick
	local ok, groups = pcall(function() return PhysicsService:GetRegisteredCollisionGroups() end)
	local order = { "Default" }
	if ok then for _, g in ipairs(groups) do order[#order + 1] = g.name end end
	for _, name in ipairs(order) do
		local ok2, can = pcall(function() return PhysicsService:CollisionGroupsAreCollidable(name, vg) end)
		if ok2 and can then pick = name break end
	end
	for _, p in ipairs(c:GetDescendants()) do
		if p:IsA("BasePart") then
			if not savedColl[p] then savedColl[p] = { p.CollisionGroup, p.CanCollide } end
			if pick then pcall(function() p.CollisionGroup = pick end) end
			if p.Name == "HumanoidRootPart" or p.Name:find("Torso") then p.CanCollide = true end
		end
	end
end
local function restoreCollideGroups()
	for p, s in pairs(savedColl) do
		if p.Parent then
			pcall(function() p.CollisionGroup = s[1] end)
			p.CanCollide = s[2]
		end
		savedColl[p] = nil
	end
end

-- Hit one player hard. Returns true if the victim actually moved fast.
-- super = keep hitting, aimed outward + up, until the victim is out of the map (or dead).
local function flingOne(p, maxTime, super)
	local r, tr = root(), rootOf(p)
	local h = hum()
	if not (r and tr and h and h.Health > 0) then return false end
	local th = p.Character:FindFirstChildOfClass("Humanoid")
	if th and th.Health <= 0 then return false end
	heavy(Cfg.HeavyFling)
	collideWith(tr)
	local t0, hit = tick(), false
	local angle = 0
	local startPos = tr.Position
	local flat = Vector3.new(startPos.X, 0, startPos.Z)
	local outward = flat.Magnitude > 5 and flat.Unit or Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
	local void = workspace.FallenPartsDestroyHeight
	while STATE.alive() and tick() - t0 < (maxTime or 2.5) do
		r, tr = root(), rootOf(p)
		if not (r and tr and tr.Parent) then break end
		angle += 1.7
		local vel = tr.AssemblyLinearVelocity
		-- predict where they will be and sweep through them
		local pos = tr.Position + vel * 0.12 + Vector3.new(math.sin(angle) * 1.2, 0, math.cos(angle) * 1.2)
		r.CFrame = CFrame.new(pos) * CFrame.Angles(angle, angle * 2, 0)
		r.AssemblyAngularVelocity = Vector3.new(Cfg.FlingPower, Cfg.FlingPower, Cfg.FlingPower)
		if super then
			local P = Cfg.FlingPower * 3
			r.AssemblyLinearVelocity = outward * P + Vector3.new(0, P * 0.6, 0)
			local ph = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
			local away = (tr.Position - startPos).Magnitude
			if away > 1500 or tr.Position.Y > 4000 or tr.Position.Y < void + 20 or (ph and ph.Health <= 0) then
				hit = true
				break
			end
		else
			r.AssemblyLinearVelocity = Vector3.new(Cfg.FlingPower, Cfg.FlingPower, Cfg.FlingPower)
			if tr.AssemblyLinearVelocity.Magnitude > 250 or tr.Position.Y > 1e4 then hit = true break end
		end
		RunService.Heartbeat:Wait()
	end
	return hit
end

local function settleAt(cf)
	local r = root()
	if not r then return end
	for _ = 1, 8 do
		r.AssemblyLinearVelocity = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
		r.CFrame = cf
		RunService.Heartbeat:Wait()
	end
	heavy(false)
	restoreCollideGroups()
end

local function runFling(list, super)
	if Cfg.FlingBusy then notify("Fling", "Already running.") return end
	local r = root()
	if not r then return end
	Cfg.FlingBusy = true
	local origin = r.CFrame
	local hits, tried = 0, 0
	for _, p in ipairs(list) do
		if not STATE.alive() then break end
		tried += 1
		if flingOne(p, super and 8 or 2.5, super) then hits += 1 end
		settleAt(origin)
		task.wait(0.1)
	end
	settleAt(origin)
	Cfg.FlingBusy = false
	notify(super and "Super Fling" or "Fling", ("%s %d / %d."):format(super and "Launched out of map:" or "Flung", hits, tried))
end

Cfg.RunFling = runFling -- exposed for debugging/tests
tabTroll:CreateButton({
	name = "FLING Target",
	description = "Teleports through the target at huge velocity, then returns you.",
	callback = function()
		local p = target()
		if not p then notify("Fling", "Pick a target first.") return end
		task.spawn(runFling, { p })
	end,
})
tabTroll:CreateButton({
	name = "FLING ALL",
	description = "Flings every other player in turn, then returns you.",
	callback = function()
		local list = {}
		for _, p in ipairs(Players:GetPlayers()) do if p ~= LP then list[#list + 1] = p end end
		task.spawn(runFling, list)
	end,
})
tabTroll:CreateButton({
	name = "SUPER FLING Target",
	description = "Keeps hitting, aimed outward and up, until they're out of the map or dead.",
	callback = function()
		local p = target()
		if not p then notify("Super Fling", "Pick a target first.") return end
		task.spawn(runFling, { p }, true)
	end,
})
tabTroll:CreateButton({
	name = "SUPER FLING ALL",
	description = "Super fling on every other player in turn, then returns you.",
	callback = function()
		local list = {}
		for _, p in ipairs(Players:GetPlayers()) do if p ~= LP then list[#list + 1] = p end end
		task.spawn(runFling, list, true)
	end,
})
tabTroll:CreateToggle({
	name = "Touch Fling (walk into players)",
	description = "Every part of you becomes a launcher. Pair with Speed / Fly / Noclip.",
	callback = function(v)
		Cfg.TouchFling = v
		heavy(v and Cfg.HeavyFling)
	end,
})
tabTroll:CreateSlider({
	name = "Fling Power", range = { 1e3, 5e5 }, increment = 1000, value = 1e5,
	callback = function(v) Cfg.FlingPower = v end,
})
tabTroll:CreateToggle({ name = "Heavy Body (more launch force)", value = true, callback = function(v) Cfg.HeavyFling = v end })

tabTroll:CreateDivider({ text = "stick to target" })
tabTroll:CreateToggle({ name = "Orbit Target", callback = function(v) Cfg.Orbit = v end })
tabTroll:CreateSlider({ name = "Orbit Speed", range = { 1, 20 }, value = 3, callback = function(v) Cfg.OrbitSpeed = v end })
tabTroll:CreateSlider({ name = "Orbit Radius", range = { 3, 40 }, value = 8, callback = function(v) Cfg.OrbitRadius = v end })
tabTroll:CreateSlider({ name = "Orbit Height", range = { -10, 20 }, value = 0, callback = function(v) Cfg.OrbitHeight = v end })
tabTroll:CreateToggle({ name = "Stick Behind Target", callback = function(v) Cfg.Follow = v end })
tabTroll:CreateToggle({ name = "Headsit", callback = function(v) Cfg.Headsit = v end })
tabTroll:CreateToggle({ name = "Backpack (ride on back)", callback = function(v) Cfg.Backpack = v end })
tabTroll:CreateButton({
	name = "Teleport To Target",
	callback = function()
		local tr, r = rootOf(target()), root()
		if tr and r then r.CFrame = tr.CFrame * CFrame.new(0, 0, 3) end
	end,
})
tabTroll:CreateButton({
	name = "Spectate Target (toggle)",
	callback = function()
		local h = hum()
		if Camera.CameraSubject ~= h then
			Camera.CameraSubject = h
		else
			local p = target()
			local th = p and p.Character and p.Character:FindFirstChildOfClass("Humanoid")
			if th then Camera.CameraSubject = th else notify("Spectate", "Pick a target first.") end
		end
	end,
})

tabTroll:CreateDivider({ text = "self" })
tabTroll:CreateToggle({ name = "Spin (helicopter)", callback = function(v) Cfg.Spin = v end })
tabTroll:CreateSlider({ name = "Spin Speed", range = { 5, 200 }, value = 40, callback = function(v) Cfg.SpinSpeed = v end })
tabTroll:CreateToggle({ name = "Fake Lag (rubberband)", callback = function(v) Cfg.FakeLag = v end })
tabTroll:CreateDivider({ text = "chat" })
tabTroll:CreateInput({ name = "Spam Message", value = Cfg.ChatMsg, callback = function(v) Cfg.ChatMsg = v end })
tabTroll:CreateSlider({ name = "Spam Delay (s)", range = { 1, 10 }, value = 2, callback = function(v) Cfg.ChatDelay = v end })
tabTroll:CreateToggle({ name = "Chat Spam", callback = function(v) Cfg.ChatSpam = v end })

-- ───────── utility ─────────
local waypoints = {}
local wpDD
wpDD = tabUtil:CreateDropdown({ name = "Waypoints", options = {}, placeholder = "none saved" })
local wpCount = 0
tabUtil:CreateButton({
	name = "Save Waypoint Here",
	callback = function()
		local r = root()
		if not r then return end
		wpCount += 1
		local n = "Waypoint " .. wpCount
		waypoints[n] = r.CFrame
		pcall(function() wpDD:Add(n) end)
		notify("Waypoint", n .. " saved.")
	end,
})
tabUtil:CreateButton({
	name = "Teleport To Selected Waypoint",
	callback = function()
		local sel = wpDD.value and wpDD.value[1]
		local r = root()
		if sel and waypoints[sel] and r then r.CFrame = waypoints[sel] end
	end,
})
tabUtil:CreateDivider({ text = "misc" })
tabUtil:CreateToggle({ name = "Anti-AFK", value = true, callback = function(v) Cfg.AntiAFK = v end })
tabUtil:CreateButton({ name = "Rejoin Server", callback = function() TeleportService:Teleport(game.PlaceId, LP) end })
tabUtil:CreateButton({
	name = "Server Hop",
	callback = function()
		local ok, res = pcall(function()
			return HttpService:JSONDecode(game:HttpGet(
				("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)))
		end)
		if ok and res and res.data then
			for _, s in ipairs(res.data) do
				if s.playing < s.maxPlayers and s.id ~= game.JobId then
					TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LP)
					return
				end
			end
		end
		notify("Server Hop", "No other server found.")
	end,
})
tabUtil:CreateButton({
	name = "FPS Boost (low quality)",
	callback = function()
		pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
		for _, v in ipairs(workspace:GetDescendants()) do
			if v:IsA("BasePart") then v.Material = Enum.Material.Plastic v.CastShadow = false
			elseif v:IsA("Decal") or v:IsA("Texture") then v.Transparency = 1
			elseif v:IsA("ParticleEmitter") or v:IsA("Trail") then v.Enabled = false end
		end
		Lighting.GlobalShadows = false
		notify("FPS Boost", "Applied.")
	end,
})
tabUtil:CreateSlider({
	name = "FPS Cap", range = { 30, 360 }, value = 144,
	callback = function(v) if setfpscap then pcall(setfpscap, v) end end,
})
tabUtil:CreateButton({
	name = "Copy Place / Job ID",
	callback = function()
		if setclipboard then
			setclipboard(("PlaceId %d | JobId %s"):format(game.PlaceId, game.JobId))
			notify("Copied", "Place and Job ID on clipboard.")
		end
	end,
})
tabUtil:CreateButton({
	name = "Unload Hub (or press Delete)",
	callback = function()
		if getgenv().OverpowerHubUnload then getgenv().OverpowerHubUnload() end
		if STATE.unload then STATE.unload() end
	end,
})

-- ───────── core loops ─────────
local flyBV, flyBG
local lastSafe
local touched = {}
local orbitAngle, spinAngle, lagTick = 0, 0, 0
local appliedSpeed, appliedJump, spinning = false, false, false

local function stopFly()
	if flyBV then flyBV:Destroy() flyBV = nil end
	if flyBG then flyBG:Destroy() flyBG = nil end
	local h = hum()
	if h then h.PlatformStand = false end
end

local function restoreCollide()
	for p in pairs(touched) do
		if p.Parent then p.CanCollide = true end
		touched[p] = nil
	end
end

STATE.connect(RunService.Stepped, function()
	local c = LP.Character
	if not c then return end
	-- never noclip while flinging: the launch needs real collisions
	if (Cfg.Noclip or Cfg.Fly or Cfg.Headsit or Cfg.Backpack) and not (Cfg.FlingBusy or Cfg.TouchFling) then
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") and p.CanCollide then
				p.CanCollide = false
				touched[p] = true
			end
		end
	elseif next(touched) then
		restoreCollide()
	end
end)

-- touch fling: spike velocity on Heartbeat (physics sees it), restore on RenderStepped
local savedVel
STATE.connect(RunService.Heartbeat, function(dt)
	local h, r = hum(), root()
	if not (h and r) then return end

	-- speed
	if Cfg.Speed then
		local cur = h.WalkSpeed -- read first: shows whether the game reset our value
		if Cfg.SpeedMode ~= "CFrame" then
			h.WalkSpeed = Cfg.SpeedValue
			appliedSpeed = true
		end
		-- Auto: top up with CFrame movement when the game keeps resetting WalkSpeed
		local base = Cfg.SpeedMode == "CFrame" and 16 or cur
		if Cfg.SpeedMode ~= "WalkSpeed" and h.MoveDirection.Magnitude > 0 and base < Cfg.SpeedValue then
			r.CFrame += h.MoveDirection * (Cfg.SpeedValue - base) * dt
		end
	elseif appliedSpeed then
		h.WalkSpeed = 16
		appliedSpeed = false
	end
	if Cfg.Jump then
		h.UseJumpPower = true
		h.JumpPower = Cfg.JumpValue
		appliedJump = true
	elseif appliedJump then
		h.JumpPower = 50
		appliedJump = false
	end

	if Cfg.God and h.Health > 0 and h.Health < h.MaxHealth then h.Health = h.MaxHealth end
	if Cfg.AntiRagdoll then
		pcall(function()
			h:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			h:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		end)
	end

	-- anti void
	if Cfg.AntiVoid then
		if r.Position.Y > workspace.FallenPartsDestroyHeight + 50 then
			if h.FloorMaterial ~= Enum.Material.Air then lastSafe = r.CFrame end
		elseif lastSafe then
			r.AssemblyLinearVelocity = Vector3.zero
			r.CFrame = lastSafe + Vector3.new(0, 5, 0)
		end
	end

	-- fly
	if Cfg.Fly then
		if not flyBV then
			flyBV = Instance.new("BodyVelocity")
			flyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
			flyBV.Velocity = Vector3.zero
			flyBV.Parent = r
			flyBG = Instance.new("BodyGyro")
			flyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
			flyBG.P = 9e4
			flyBG.Parent = r
		end
		h.PlatformStand = true
		local d, cf = Vector3.zero, Camera.CFrame
		if UIS:IsKeyDown(Enum.KeyCode.W) then d += cf.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.S) then d -= cf.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.D) then d += cf.RightVector end
		if UIS:IsKeyDown(Enum.KeyCode.A) then d -= cf.RightVector end
		if UIS:IsKeyDown(Enum.KeyCode.Space) then d += Vector3.yAxis end
		if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then d -= Vector3.yAxis end
		flyBV.Velocity = d.Magnitude > 0 and d.Unit * Cfg.FlySpeed or Vector3.zero
		flyBG.CFrame = cf
	elseif flyBV then
		stopFly()
	end

	-- touch fling
	if Cfg.TouchFling and not Cfg.FlingBusy then
		savedVel = r.AssemblyLinearVelocity
		r.AssemblyLinearVelocity = savedVel * 1e3 + Vector3.new(Cfg.FlingPower, Cfg.FlingPower, Cfg.FlingPower)
		r.AssemblyAngularVelocity = Vector3.new(0, Cfg.FlingPower, 0)
	end

	-- stick-to-target modes (not while flinging)
	if not Cfg.FlingBusy then
		local tr = rootOf(target())
		if tr then
			if Cfg.Headsit then
				r.CFrame = tr.CFrame * CFrame.new(0, 2.6, 0)
				r.AssemblyLinearVelocity = Vector3.zero
			elseif Cfg.Backpack then
				r.CFrame = tr.CFrame * CFrame.new(0, 0, 1.2) * CFrame.Angles(math.rad(90), 0, 0)
				r.AssemblyLinearVelocity = Vector3.zero
			elseif Cfg.Orbit then
				orbitAngle += dt * Cfg.OrbitSpeed
				local o = Vector3.new(math.cos(orbitAngle) * Cfg.OrbitRadius, Cfg.OrbitHeight, math.sin(orbitAngle) * Cfg.OrbitRadius)
				r.CFrame = CFrame.lookAt(tr.Position + o, tr.Position)
				r.AssemblyLinearVelocity = Vector3.zero
			elseif Cfg.Follow then
				r.CFrame = tr.CFrame * CFrame.new(0, 0, 3)
				r.AssemblyLinearVelocity = Vector3.zero
			end
		end
		if Cfg.Spin and not Cfg.TouchFling and not (Cfg.Headsit or Cfg.Backpack or Cfg.Orbit or Cfg.Follow) then
			h.AutoRotate = false
			spinAngle += dt * Cfg.SpinSpeed
			r.CFrame = CFrame.new(r.Position) * CFrame.Angles(0, spinAngle, 0)
			r.AssemblyAngularVelocity = Vector3.new(0, Cfg.SpinSpeed, 0)
			spinning = true
		elseif spinning then
			h.AutoRotate = true
			r.AssemblyAngularVelocity = Vector3.zero
			spinning = false
		end
	end

	if Cfg.FakeLag then
		lagTick += dt
		if lagTick > 0.4 then
			lagTick = 0
			r.Anchored = true
			task.delay(0.2, function() if r.Parent then r.Anchored = false end end)
		end
	end
end)

STATE.connect(RunService.RenderStepped, function()
	local r = root()
	if Cfg.TouchFling and not Cfg.FlingBusy and r and savedVel then
		r.AssemblyLinearVelocity = savedVel
		r.AssemblyAngularVelocity = Vector3.zero
		savedVel = nil
	end
	Camera = workspace.CurrentCamera
	if Cfg.FOVOn then Camera.FieldOfView = Cfg.FOV end
end)

STATE.connect(UIS.JumpRequest, function()
	if Cfg.InfJump then
		local h = hum()
		if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
	end
end)

STATE.connect(UIS.InputBegan, function(i, gpe)
	if gpe then return end
	if i.KeyCode == Enum.KeyCode.Delete then
		if getgenv().OverpowerHubUnload then getgenv().OverpowerHubUnload() end
		if STATE.unload then STATE.unload() end
		return
	end
	if Cfg.ClickTP and i.UserInputType == Enum.UserInputType.MouseButton1
		and UIS:IsKeyDown(Enum.KeyCode.LeftControl) then
		local m = UIS:GetMouseLocation()
		local ray = Camera:ViewportPointToRay(m.X, m.Y)
		local rp = RaycastParams.new()
		rp.FilterDescendantsInstances = { LP.Character }
		rp.FilterType = Enum.RaycastFilterType.Exclude
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 5000, rp)
		local r = root()
		if hit and r then r.CFrame = CFrame.new(hit.Position + Vector3.new(0, 4, 0)) end
	end
end)

-- ───────── aimbot ─────────
local fovCircle
if Drawing then
	fovCircle = Drawing.new("Circle")
	fovCircle.Thickness = 1
	fovCircle.Color = Color3.new(1, 1, 1)
	fovCircle.Filled = false
	fovCircle.Visible = false
	STATE.onCleanup(function() fovCircle:Remove() end)
end

local function visible(part)
	local origin = Camera.CFrame.Position
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { LP.Character, part.Parent }
	return workspace:Raycast(origin, part.Position - origin, rp) == nil
end

STATE.connect(RunService.RenderStepped, function()
	local m = UIS:GetMouseLocation()
	if fovCircle then
		fovCircle.Visible = Cfg.Aim
		fovCircle.Position = m
		fovCircle.Radius = Cfg.AimFOV
	end
	if not (Cfg.Aim and UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)) then return end
	local best, bestD
	for _, p in ipairs(Players:GetPlayers()) do
		local c = p.Character
		if p ~= LP and c and not (Cfg.AimTeamCheck and p.Team and p.Team == LP.Team) then
			local part = c:FindFirstChild(Cfg.AimPart)
			local ph = c:FindFirstChildOfClass("Humanoid")
			if part and ph and ph.Health > 0 then
				local sp, on = Camera:WorldToViewportPoint(part.Position)
				if on then
					local d = (Vector2.new(sp.X, sp.Y) - m).Magnitude
					if d < Cfg.AimFOV and (not bestD or d < bestD) and (not Cfg.AimWall or visible(part)) then
						best, bestD = part, d
					end
				end
			end
		end
	end
	if best then
		Camera.CFrame = Camera.CFrame:Lerp(CFrame.lookAt(Camera.CFrame.Position, best.Position), 1 / Cfg.AimSmooth)
	end
end)

-- ───────── ESP (Highlight + billboard) ─────────
local esp = {}
local function clearESP(p)
	local e = esp[p]
	if e then
		if e.hl then e.hl:Destroy() end
		if e.bb then e.bb:Destroy() end
		esp[p] = nil
	end
end
STATE.onCleanup(function() for p in pairs(esp) do clearESP(p) end end)

local function updateESP()
	local myr = root()
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local c = p.Character
			local r = rootOf(p)
			local show = Cfg.ESP and c and r and not (Cfg.ESPTeamCheck and p.Team and p.Team == LP.Team)
			if show then
				local e = esp[p]
				if not e or e.char ~= c or not e.hl.Parent then
					clearESP(p)
					local hl = Instance.new("Highlight")
					hl.FillTransparency = 0.6
					hl.OutlineColor = Color3.new(1, 1, 1)
					hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					hl.Parent = c
					local bb = Instance.new("BillboardGui")
					bb.Size = UDim2.fromOffset(160, 36)
					bb.StudsOffset = Vector3.new(0, 3.2, 0)
					bb.AlwaysOnTop = true
					bb.Adornee = r
					bb.Parent = c
					local tl = Instance.new("TextLabel")
					tl.BackgroundTransparency = 1
					tl.Size = UDim2.fromScale(1, 1)
					tl.TextColor3 = Color3.new(1, 1, 1)
					tl.TextStrokeTransparency = 0.4
					tl.TextSize = 13
					tl.Font = Enum.Font.GothamBold
					tl.Parent = bb
					e = { char = c, hl = hl, bb = bb, tl = tl }
					esp[p] = e
				end
				e.hl.FillColor = (p.Team and p.TeamColor.Color) or Color3.fromRGB(255, 70, 70)
				e.bb.Enabled = Cfg.ESPNames
				if Cfg.ESPNames then
					local ph = c:FindFirstChildOfClass("Humanoid")
					local dist = myr and math.floor((myr.Position - r.Position).Magnitude) or 0
					e.tl.Text = ("%s\n%dm  %d hp"):format(p.DisplayName, dist, ph and math.floor(ph.Health) or 0)
				end
			else
				clearESP(p)
			end
		end
	end
end
task.spawn(function()
	while STATE.alive() do
		pcall(updateESP)
		task.wait(0.25)
	end
end)
STATE.connect(Players.PlayerRemoving, clearESP)

-- ───────── lighting ─────────
local origLight = {
	Brightness = Lighting.Brightness, Ambient = Lighting.Ambient, ClockTime = Lighting.ClockTime,
	FogEnd = Lighting.FogEnd, FogStart = Lighting.FogStart, GlobalShadows = Lighting.GlobalShadows,
}
local origFOV = Camera.FieldOfView
STATE.connect(RunService.Heartbeat, function()
	if Cfg.FullBright then
		Lighting.Brightness = 2
		Lighting.Ambient = Color3.new(1, 1, 1)
		Lighting.ClockTime = 14
		Lighting.GlobalShadows = false
	end
	if Cfg.NoFog then Lighting.FogEnd = 1e9 Lighting.FogStart = 1e9 end
end)

STATE.onCleanup(function()
	for k, v in pairs(origLight) do pcall(function() Lighting[k] = v end) end
	pcall(function() workspace.CurrentCamera.FieldOfView = origFOV end)
	pcall(stopFly)
	pcall(restoreCollide)
	local h, r = hum(), root()
	if h then
		h.WalkSpeed = 16
		h.JumpPower = 50
		h.PlatformStand = false
		pcall(function() Camera.CameraSubject = h end)
	end
	pcall(restoreCollideGroups)
	if r then r.Anchored = false pcall(heavy, false) end
	for k, v in pairs(Cfg) do if type(v) == "boolean" then Cfg[k] = false end end
	getgenv().OverpowerCfg = nil
end)

-- ───────── misc ─────────
STATE.connect(LP.Idled, function()
	if Cfg.AntiAFK then
		local VU = game:GetService("VirtualUser")
		VU:CaptureController()
		VU:ClickButton2(Vector2.new())
	end
end)

task.spawn(function()
	while STATE.alive() do
		if Cfg.ChatSpam and Cfg.ChatMsg ~= "" then
			pcall(function()
				if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
					TextChatService.TextChannels.RBXGeneral:SendAsync(Cfg.ChatMsg)
				else
					RS.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(Cfg.ChatMsg, "All")
				end
			end)
		end
		task.wait(Cfg.ChatDelay)
	end
end)

local function refreshList() pcall(function() targetDD:Refresh(playerNames()) end) end
STATE.connect(Players.PlayerAdded, refreshList)
STATE.connect(Players.PlayerRemoving, function() task.defer(refreshList) end)

notify("Overpower Hub", "Loaded. Delete key unloads.")
