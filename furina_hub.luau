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
	ESP = false, Box = true, BoxFill = false, Name = true, Health = true, Distance = true,
	Weapon = true, Tracers = false, Chams = true, Rainbow = false, ESPMax = 1500,
	ESPColor = Color3.fromRGB(120, 170, 255), TargetColor = Color3.fromRGB(255, 70, 70),
	TracerOrigin = "Bottom",
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
	AntiKB = false, AlwaysEquip = false, PanicKey = Enum.KeyCode.Delete,
	-- movement
	Speed = false, SpeedValue = 24, Jump = false, JumpValue = 60,
	InfJump = false, Noclip = false, Fly = false, FlySpeed = 60,
	-- world
	Fullbright = false, FOVOn = false, FOV = 70, AntiAFK = true,
}

-- Config save/load ---------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local CFG_FILE = "FurinaHub/silent_assassins.json"
-- Not restored on launch: rolling spends currency; the others need setup code that only runs when toggled.
local NOSAVE = { Rolling = true, Fly = true, Fullbright = true, Stick = true }
Cfg.AutoSave = true

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
			elseif ty == "boolean" or ty == "number" or ty == "string" then t[k] = v end
		end
	end
	return HttpService:JSONEncode(t)
end

local function saveCfg()
	local ok, err = pcall(function()
		makefolder("FurinaHub")
		writefile(CFG_FILE, encodeCfg())
	end)
	return ok, err
end

local function loadCfg()
	if not isfile or not isfile(CFG_FILE) then return false end
	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CFG_FILE)) end)
	if not ok or type(data) ~= "table" then return false end
	for k, v in pairs(data) do
		local cur = Cfg[k]
		if cur ~= nil and not NOSAVE[k] then
			if type(v) == "table" and v.__c and typeof(cur) == "Color3" then
				Cfg[k] = Color3.new(v.__c[1], v.__c[2], v.__c[3])
			elseif type(v) == "table" and v.__k and typeof(cur) == "EnumItem" then
				local en = pcall(function() return Enum.KeyCode[v.__k] end) and Enum.KeyCode[v.__k]
				if en then Cfg[k] = en end
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
local cfgLoaded = loadCfg()

local function cleanup(fn) if STATE and STATE.onCleanup then STATE.onCleanup(fn) end end
local function connect(sig, fn)
	if STATE and STATE.connect then return STATE.connect(sig, fn) end
	return sig:Connect(fn)
end
local function alive() return not STATE or STATE.alive() end

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

-- ESP (Drawing) -----------------------------------------------------------
local esp = {} -- [Player] = {drawings..., hl}
local allDrawings = {}

local function newDraw(kind, props)
	local d = Drawing.new(kind)
	for k, v in pairs(props) do d[k] = v end
	allDrawings[#allDrawings + 1] = d
	return d
end

local function getESP(plr)
	local o = esp[plr]
	if o then return o end
	o = {
		boxOut = newDraw("Square", { Thickness = 3, Filled = false, Color = Color3.new(0, 0, 0), Visible = false }),
		box = newDraw("Square", { Thickness = 1, Filled = false, Visible = false }),
		fill = newDraw("Square", { Filled = true, Transparency = 0.15, Visible = false }),
		hpOut = newDraw("Line", { Thickness = 4, Color = Color3.new(0, 0, 0), Visible = false }),
		hp = newDraw("Line", { Thickness = 2, Visible = false }),
		name = newDraw("Text", { Size = 14, Center = true, Outline = true, Visible = false }),
		info = newDraw("Text", { Size = 12, Center = true, Outline = true, Visible = false }),
		tracer = newDraw("Line", { Thickness = 1, Visible = false }),
		arrow = newDraw("Triangle", { Filled = true, Thickness = 1, Visible = false }),
	}
	esp[plr] = o
	return o
end

local function hideESP(o)
	for k, d in pairs(o) do
		if k ~= "hl" and typeof(d) ~= "Instance" then d.Visible = false end
	end
	if o.hl then o.hl.Enabled = false end
end

local function removeESP(plr)
	local o = esp[plr]
	if not o then return end
	for k, d in pairs(o) do
		if typeof(d) == "Instance" then d:Destroy() else pcall(function() d:Remove() end) end
	end
	esp[plr] = nil
end

local function removeAllESP()
	for plr in pairs(esp) do removeESP(plr) end
	for _, d in ipairs(allDrawings) do pcall(function() d:Remove() end) end
	table.clear(allDrawings)
end

local cachedTarget, targetClock = nil, 0
local anyESP = false
local function renderESP()
	if not Cfg.ESP and not anyESP then return end -- nothing drawn, nothing to hide
	local myRoot = root()
	local vp = Camera.ViewportSize
	local now = os.clock()
	if now - targetClock > 0.15 then
		targetClock = now
		cachedTarget = Cfg.ESP and closestEnemy(1e9) or nil
	end
	local target = cachedTarget
	anyESP = Cfg.ESP
	local rainbow = Color3.fromHSV((os.clock() * 0.25) % 1, 0.8, 1)

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LP then
			local c, h, r = validEnemy(plr)
			local o = esp[plr]
			if not (Cfg.ESP and c) then
				if o then hideESP(o) end
				continue
			end
			o = o or getESP(plr)

			local dist = myRoot and (myRoot.Position - r.Position).Magnitude or 0
			if dist > Cfg.ESPMax then hideESP(o) continue end

			local color = (plr == target) and Cfg.TargetColor or (Cfg.Rainbow and rainbow or Cfg.ESPColor)

			-- chams
			if Cfg.Chams then
				if not o.hl or o.hl.Parent == nil or o.hl.Adornee ~= c then
					if o.hl then o.hl:Destroy() end
					local hl = Instance.new("Highlight")
					hl.Name = "FurinaChams"
					hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					hl.FillTransparency = 0.65
					hl.Adornee = c
					hl.Parent = c
					o.hl = hl
				end
				o.hl.FillColor = color
				o.hl.OutlineColor = color
				o.hl.Enabled = true
			elseif o.hl then
				o.hl.Enabled = false
			end

			local top, topOn = Camera:WorldToViewportPoint(r.Position + Vector3.new(0, 2.9, 0))
			local bot = Camera:WorldToViewportPoint(r.Position - Vector3.new(0, 3.1, 0))
			if not topOn or top.Z <= 0 then
				for k, d in pairs(o) do if k ~= "hl" and typeof(d) ~= "Instance" and k ~= "tracer" then d.Visible = false end end
				if Cfg.Arrows then
					local rp = Camera:WorldToViewportPoint(r.Position)
					local center = vp / 2
					local v = Vector2.new(rp.X, rp.Y) - center
					if rp.Z < 0 then v = -v end
					if v.Magnitude < 1 then v = Vector2.new(0, 1) end
					local dir = v.Unit
					local perp = Vector2.new(-dir.Y, dir.X)
					local pos = center + dir * math.min(vp.X, vp.Y) * 0.38
					o.arrow.PointA = pos + dir * 14
					o.arrow.PointB = pos - dir * 6 + perp * 9
					o.arrow.PointC = pos - dir * 6 - perp * 9
					o.arrow.Color = color
					o.arrow.Visible = true
				end
			else
				o.arrow.Visible = false
				local height = math.abs(bot.Y - top.Y)
				local width = height * 0.55
				local x, y = top.X - width / 2, top.Y
				local pos, size = Vector2.new(x, y), Vector2.new(width, height)

				o.boxOut.Position, o.boxOut.Size, o.boxOut.Visible = pos, size, Cfg.Box
				o.box.Position, o.box.Size, o.box.Color, o.box.Visible = pos, size, color, Cfg.Box
				o.fill.Position, o.fill.Size, o.fill.Color, o.fill.Visible = pos, size, color, Cfg.BoxFill

				local frac = math.clamp(h.Health / math.max(h.MaxHealth, 1), 0, 1)
				local bx = x - 5
				o.hpOut.From, o.hpOut.To, o.hpOut.Visible = Vector2.new(bx, y + height + 1), Vector2.new(bx, y - 1), Cfg.Health
				o.hp.From = Vector2.new(bx, y + height)
				o.hp.To = Vector2.new(bx, y + height - height * frac)
				o.hp.Color = Color3.fromHSV(frac * 0.33, 1, 1)
				o.hp.Visible = Cfg.Health

				o.name.Text = plr.DisplayName
				o.name.Position = Vector2.new(top.X, y - 16)
				o.name.Color = color
				o.name.Visible = Cfg.Name

				local parts = {}
				if Cfg.Distance then parts[#parts + 1] = math.floor(dist) .. "m" end
				if Cfg.Weapon then
					local t = toolOf(c)
					if t then parts[#parts + 1] = t.Name end
				end
				o.info.Text = table.concat(parts, " | ")
				o.info.Position = Vector2.new(top.X, y + height + 2)
				o.info.Color = Color3.new(1, 1, 1)
				o.info.Visible = #parts > 0
			end

			if Cfg.Tracers then
				local rp, on = Camera:WorldToViewportPoint(r.Position)
				if on and rp.Z > 0 then
					local from = Cfg.TracerOrigin == "Center" and vp / 2 or Vector2.new(vp.X / 2, vp.Y)
					o.tracer.From, o.tracer.To = from, Vector2.new(rp.X, rp.Y)
					o.tracer.Color = color
					o.tracer.Visible = true
				else
					o.tracer.Visible = false
				end
			else
				o.tracer.Visible = false
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

-- Keybinds ----------------------------------------------------------------------
connect(UserInputService.InputBegan, function(input, gp)
	if gp or not alive() then return end
	if input.KeyCode == Cfg.AuraKey then
		setToggle("Aura", not Cfg.Aura)
		Luna:Notification({ Title = "Kill Aura", Content = Cfg.Aura and "Enabled" or "Disabled", Icon = "gavel", ImageSource = "Material" })
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
	for _, k in ipairs({ "Aura", "NoCD", "Aim", "Hitbox", "Stick", "FaceTarget", "Rolling", "ESP", "Fly", "Noclip", "Speed", "Jump", "AntiKB", "Fullbright", "FOVOn" }) do
		setToggle(k, false)
	end
	stopFly()
	applyLight(false)
	Camera.FieldOfView = 70
	local h = hum()
	if h then h.WalkSpeed = 16 h.JumpPower = 38 end
	for _, o in pairs(esp) do hideESP(o) end
	Luna:Notification({ Title = "Panic", Content = "All features disabled.", Icon = "warning", ImageSource = "Material" })
end
connect(UserInputService.InputBegan, function(input, gp)
	if not gp and alive() and input.KeyCode == Cfg.PanicKey then panic() end
end)

-- Main loops -----------------------------------------------------------------
connect(RunService.RenderStepped, function()
	if not alive() then return end
	renderESP()
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
local function sld(t, name, key, lo, hi)
	t:CreateSlider({ Name = name, Range = { lo, hi }, Increment = 1, CurrentValue = Cfg[key], Callback = function(v) Cfg[key] = v end })
end

local Combat = tab("Combat", "gavel")
tog(Combat, "Kill Aura", "Aura", "Auto-hits every enemy in range with your equipped weapon")
sld(Combat, "Aura Range", "AuraRange", 5, 150)
Combat:CreateSlider({ Name = "Aura Delay (x0.01s)", Range = { 3, 100 }, Increment = 1, CurrentValue = math.clamp(math.floor(Cfg.AuraDelay * 100 + 0.5), 3, 100),
	Callback = function(v) Cfg.AuraDelay = v / 100 end })
tog(Combat, "No Attack Cooldown", "NoCD", "Swing as fast as the delay below allows (hold left click)")
Combat:CreateSlider({ Name = "Swing Delay (x0.01s)", Range = { 0, 50 }, Increment = 1, CurrentValue = math.clamp(math.floor(Cfg.NoCDDelay * 100 + 0.5), 0, 50),
	Callback = function(v) Cfg.NoCDDelay = v / 100 end })
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
Power:CreateSlider({ Name = "Aim Smoothness", Range = { 1, 20 }, Increment = 1, CurrentValue = Cfg.AimSmooth, Callback = function(v) Cfg.AimSmooth = v end })
Power:CreateButton({ Name = "Aim At: Head / Body (toggle)", Callback = function()
	Cfg.AimPart = Cfg.AimPart == "Head" and "HumanoidRootPart" or "Head"
	Luna:Notification({ Title = "Aimlock", Content = "Aiming at " .. Cfg.AimPart, Icon = "my_location", ImageSource = "Material" })
end })
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
Hit:CreateSlider({ Name = "Hitbox Size (x)", Range = { 1, 10 }, Increment = 1, CurrentValue = Cfg.HitboxMult,
	Callback = function(v) Cfg.HitboxMult = v end })
tog(Hit, "Show Hitbox", "ShowHitbox", "Draws the swing box in red neon")
tog(Hit, "Spoof Size To Server", "SpoofHitbox", "Also reports the bigger size in the hit packet. Riskier: the server sees a number that doesn't match your weapon")
Hit:CreateLabel({ Text = "Hit detection runs on your client, so the bigger box really catches more enemies. Whether the server accepts far hits is unverified.", Style = 2 })

local Luck = tab("Luck", "casino")
Luck:CreateLabel({ Text = "Rolls are decided on the server, so luck itself cannot be raised from here. This tab rolls for you and stops on a rarity you choose.", Style = 3 })
Luck:CreateLabel({ Text = "Odds by tier (common to best): Basic 76/18/5/1/0 %. Divine 0/70/25/4/1 %. Divine has far better odds per coin.", Style = 2 })
Luck:CreateDropdown({ Name = "Chest", Options = { "Basic", "Divine" }, CurrentOption = { Cfg.ChestType }, MultipleOptions = false,
	Callback = function(o) Cfg.ChestType = type(o) == "table" and o[1] or o end })
tog(Luck, "Auto Roll", "Rolling", "Rolls the chest repeatedly. Spends your currency.")
Luck:CreateSlider({ Name = "Stop At Rarity (1-5)", Range = { 1, 5 }, Increment = 1, CurrentValue = Cfg.StopRarity,
	Callback = function(v) Cfg.StopRarity = v end })
Luck:CreateSlider({ Name = "Max Rolls", Range = { 1, 200 }, Increment = 1, CurrentValue = Cfg.MaxRolls,
	Callback = function(v) Cfg.MaxRolls = v end })
Luck:CreateSlider({ Name = "Roll Delay (x0.1s)", Range = { 3, 40 }, Increment = 1, CurrentValue = math.clamp(math.floor(Cfg.RollDelay * 10 + 0.5), 3, 40),
	Callback = function(v) Cfg.RollDelay = v / 10 end })
Luck:CreateButton({ Name = "Roll Status", Callback = function()
	Luna:Notification({ Title = "Auto Roll", Content = "Rolls " .. roll.count .. " | best rarity " .. roll.best .. " | last: " .. roll.last, Icon = "info", ImageSource = "Material" })
end })
Luck:CreateButton({ Name = "Reset Roll Counter", Callback = function() roll.count = 0 roll.best = 0 end })

local Visuals = tab("Visuals", "visibility")
tog(Visuals, "HUD", "HUD", "Top-left status line")
tog(Visuals, "Off-Screen Arrows", "Arrows", "Pointers to enemies outside your view")
tog(Visuals, "Player ESP", "ESP", "Master switch", function(v) if not v then for _, o in pairs(esp) do hideESP(o) end end end)
tog(Visuals, "Boxes", "Box")
tog(Visuals, "Box Fill", "BoxFill")
tog(Visuals, "Names", "Name")
tog(Visuals, "Health Bar", "Health")
tog(Visuals, "Distance", "Distance")
tog(Visuals, "Held Weapon", "Weapon")
tog(Visuals, "Tracers", "Tracers")
tog(Visuals, "Chams", "Chams", "Highlight through walls", function(v)
	if not v then for _, o in pairs(esp) do if o.hl then o.hl.Enabled = false end end end
end)
tog(Visuals, "Rainbow", "Rainbow")
sld(Visuals, "Max Distance", "ESPMax", 100, 5000)
Visuals:CreateColorPicker({ Name = "ESP Color", Color = Cfg.ESPColor, Callback = function(c) Cfg.ESPColor = c end })
Visuals:CreateColorPicker({ Name = "Closest Target Color", Color = Cfg.TargetColor, Callback = function(c) Cfg.TargetColor = c end })
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
tog(Misc, "Anti AFK", "AntiAFK")
tog(Misc, "Auto Save Config", "AutoSave", "Saves every 20 seconds and loads on start (FurinaHub folder in your workspace)")
Misc:CreateButton({ Name = "Save Config Now", Callback = function()
	local ok, err = saveCfg()
	Luna:Notification({ Title = "Config", Content = ok and "Saved." or ("Save failed: " .. tostring(err)), Icon = ok and "save" or "warning", ImageSource = "Material" })
end })
Misc:CreateButton({ Name = "Delete Saved Config", Callback = function()
	pcall(function() if delfile and isfile(CFG_FILE) then delfile(CFG_FILE) end end)
	Luna:Notification({ Title = "Config", Content = "Deleted. Defaults return next launch.", Icon = "delete", ImageSource = "Material" })
end })
task.spawn(function()
	while alive() do
		task.wait(20)
		if Cfg.AutoSave then saveCfg() end
	end
end)
cleanup(function() if Cfg.AutoSave then saveCfg() end end)
Misc:CreateButton({ Name = "Rejoin Server", Callback = function()
	TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
end })
Misc:CreateLabel({ Text = "Furina Hub - Silent Assassins", Style = 2 })

Luna:Notification({ Title = "Furina Hub", Content = "Loaded. Combat + new ESP ready.", Icon = "check_circle", ImageSource = "Material" })
