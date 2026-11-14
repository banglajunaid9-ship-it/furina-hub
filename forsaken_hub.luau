--[[
	Furina Hub v6.0 | Forsaken (placeId 83645629621104)
	UI: FurinaUI (furina_ui.luau in this repo). Menu: RightShift. Panic (unload): End.
	loadstring(game:HttpGet("https://raw.githubusercontent.com/banglajunaid9-ship-it/furina-hub/main/forsaken_hub.luau"))()
	Running it again replaces the old copy. Settings save to FurinaHub/forsaken.json.
]]
local genv = (getgenv and getgenv()) or _G
if genv.__FurinaHubUnload then pcall(genv.__FurinaHubUnload) end
local cleanups = {}
local alive = true
local function onCleanup(fn) table.insert(cleanups, fn) end
local function connect(sig, fn)
    local c = sig:Connect(fn)
    onCleanup(function() c:Disconnect() end)
    return c
end
local UI -- forward (FurinaUI)
local function unload()
    if not alive then return end
    alive = false
    for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
    table.clear(cleanups)
    if UI then pcall(function() UI:Destroy() end) end
    genv.__FurinaHubUnload = nil
end
genv.__FurinaHubUnload = unload
genv.__FurinaVersion = "6.0"
if STATE and STATE.onCleanup then STATE.onCleanup(unload) end
local Players      = game:GetService("Players")
local RS           = game:GetService("ReplicatedStorage")
local RunService   = game:GetService("RunService")
local Lighting     = game:GetService("Lighting")
local HttpService  = game:GetService("HttpService")
local TeleportSvc  = game:GetService("TeleportService")
local UIS          = game:GetService("UserInputService")
local GuiService   = game:GetService("GuiService")
local PathfindingService = game:GetService("PathfindingService")
while not Players.LocalPlayer do task.wait() end
local LP           = Players.LocalPlayer
local function try(fn, ...) local ok, r = pcall(fn, ...) if ok then return r end end
local IS_MOBILE = UIS.TouchEnabled and not UIS.KeyboardEnabled
local getconns = getconnections or get_signal_cons
local function connsOf(sig)
    if not getconns then return {} end
    local ok, r = pcall(getconns, sig)
    return (ok and type(r) == "table") and r or {}
end
local function hiddenUI()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and h then return h end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then return cg end
    return LP:WaitForChild("PlayerGui")
end
local function safeParent(inst)
    if not pcall(function() inst.Parent = hiddenUI() end) or not inst.Parent then
        inst.Parent = LP:WaitForChild("PlayerGui")
    end
end
local function firePrompt(p)
    if fireproximityprompt and pcall(fireproximityprompt, p) then return end
    pcall(function()
        p:InputHoldBegin()
        task.wait((p.HoldDuration or 0) + 0.05)
        p:InputHoldEnd()
    end)
end
if not game:IsLoaded() then game.Loaded:Wait() end
local function waitPath(root, path, timeout)
    local node = root
    for _, name in ipairs(path) do
        node = node and node:WaitForChild(name, timeout or 30)
    end
    return node
end
local function req(root, path)
    local m = waitPath(root, path)
    return m and try(require, m)
end
waitPath(RS, { "Systems", "Player", "Game", "Minigames" })
waitPath(RS, { "Modules", "Minigames" })
if not LP.Character then LP.CharacterAdded:Wait() end
local Sprinting          = req(RS, { "Systems", "Character", "Game", "Sprinting" })
local GearsClientHandler = req(RS, { "Systems", "Player", "Game", "Spawners", "GearsClientHandler" })
local LockBoard          = req(RS, { "Modules", "Minigames", "LockBoard" })
local Cfg = {
    SafeMode = true, AntiAFK = true,
    AttackSlot = 1,
    AutoGen = false, GenDelay = 1.5, AutoEnterGen = false, SolveSpeed = "Human",
    InfStamina = false, KillerWarn = false, WarnDist = 60,
    AutoPickup = false, PickupDist = 12,
    KillAura = false, AuraRange = 9, AuraDelay = 0.35, AutoChase = false,
    EspKillers = false, EspSurvivors = false, EspGens = false, EspItems = false,
    EspNames = true, EspDistance = true, EspHealth = true,
    KillerColor = Color3.fromRGB(255, 60, 60),
    SurvivorColor = Color3.fromRGB(120, 220, 255),
    GenColor = Color3.fromRGB(232, 199, 122),
    ItemColor = Color3.fromRGB(150, 255, 210),
    Fullbright = false, NoFog = false,
    FpsBoost = false, AutoRejoin = false, FloatingButtons = IS_MOBILE,
    LowHpAlert = true, PanicKey = "End", AutoUpdate = true,
    AutoGears = false, EspGears = false, GearColor = Color3.fromRGB(255, 170, 60),
    CandyCollect = false, EspCandy = false,
    CandyColor = Color3.fromRGB(255, 120, 200),
    AutoHeal = false, HealAt = 50,
    DangerVignette = false, VignetteDist = 50,
    TracerKillers = false, TracerSurvivors = false,
    FovOn = false, Fov = 90, ZoomUnlock = false,
    Overlay = false, GenAlerts = true, AutoSpectate = false,
    AutoBlock = false, BlockRange = 13, BlockFacing = true, BlockDelay = 0, AutoParry = false,
    SilentAim = false, CamLock = false, AimKey = "V", AimSmooth = 0.35, AimFov = 220, ShowFov = true,
    AimMaxDist = 150, AimPredict = 0.12, AimMode = "Crosshair", AimPart = "Torso",
    FaceTarget = false, FaceRange = 15,
}
local function myRole()
    local c = LP.Character
    return c and c.Parent and c.Parent.Name -- "Killers" | "Survivors" | "Spectating"
end
local function rootOf(m)
    if not m then return nil end
    if m:IsA("BasePart") then return m end
    return m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
end
local function myRoot() return rootOf(LP.Character) end
local function teamFolder(name)
    local p = workspace:FindFirstChild("Players")
    return p and p:FindFirstChild(name)
end
local function ingame()
    local m = workspace:FindFirstChild("Map")
    return m and m:FindFirstChild("Ingame")
end
local function dist(a, b) return (a - b).Magnitude end
local function setIf(o, k, v) if o[k] ~= v then o[k] = v end end
local function notify(title, desc, life)
    if UI then
        pcall(function() UI:Notification({ Title = title, Content = desc, Icon = "info", Duration = life or 4 }) end)
    end
end
local Stats = {
    startT = os.clock(), puzzles = 0, hits = 0,
    roundsSurvivor = 0, roundsKiller = 0, moneyStart = nil,
    wins = 0, streak = 0, bestStreak = 0, lastResult = nil,
}
local function money()
    local ls = LP:FindFirstChild("leaderstats")
    local m = ls and ls:FindFirstChild("Money")
    return m and m.Value
end
Stats.moneyStart = money()
local function autoSolveOn() return Cfg.AutoGen end
local function myHum()
    local c = LP.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local Generators, Items, Gears, Candies = {}, {}, {}, {}
local function isGenerator(d)
    return d:IsA("Model") and d.Name == "Generator" and d:FindFirstChild("Main") ~= nil
end
local function isItem(d)
    return d:IsA("Tool") -- map items (Medkit, BloxyCola) are Tools, not always with a Handle
end
local function track(d)
    if isGenerator(d) then Generators[d] = true
    elseif isItem(d) then Items[d] = true
    elseif d:IsA("Model") and d.Name == "Gear" then Gears[d] = true
    elseif d:IsA("Model") and d.Name == "C00lCandy" then Candies[d] = true end
end
local mapConns = {}
local function bindIngame(ig)
    for _, c in ipairs(mapConns) do c:Disconnect() end
    table.clear(mapConns); table.clear(Generators); table.clear(Items); table.clear(Gears); table.clear(Candies)
    if not ig then return end
    for _, d in ipairs(ig:GetDescendants()) do track(d) end
    table.insert(mapConns, ig.DescendantAdded:Connect(function(d)
        task.defer(track, d) -- children (Main/Handle) may arrive a frame later
    end))
    table.insert(mapConns, ig.DescendantRemoving:Connect(function(d)
        Generators[d] = nil; Items[d] = nil; Gears[d] = nil; Candies[d] = nil
    end))
end
onCleanup(function() for _, c in ipairs(mapConns) do c:Disconnect() end end)
do
    local map = workspace:WaitForChild("Map", 10)
    if map then
        bindIngame(map:FindFirstChild("Ingame"))
        connect(map.ChildAdded, function(c) if c.Name == "Ingame" then bindIngame(c) end end)
    end
end
local function genPrompt(gen)
    local main = gen:FindFirstChild("Main")
    return main and main:FindFirstChildOfClass("ProximityPrompt")
end
local function genDone(gen)
    local p = genPrompt(gen)
    return p == nil or not p.Enabled
end
local function nearestGen(maxD)
    local r = myRoot(); if not r then return end
    local best, bd
    for g in pairs(Generators) do
        if g.Parent and not genDone(g) then
            local d = dist(g:GetPivot().Position, r.Position)
            if (not maxD or d <= maxD) and (not bd or d < bd) then best, bd = g, d end
        end
    end
    return best, bd
end
-- how long a solve "takes" before it is submitted. Human: never under 2s plus time per cell/link.
-- Fast: about half, but never under 0.9s and always a little random (instant submits are what stands out)
local function human(work)
    work = work or 0
    if Cfg.SolveSpeed == "Fast" then
        local base = math.max(0.9, Cfg.GenDelay * 0.5) + work * 0.5
        task.wait(base + math.random() * 0.4)
        return
    end
    local base = math.max(0, Cfg.GenDelay)
    if Cfg.SafeMode then base = math.max(base, 2) + work end
    task.wait(base + math.random() * 0.6)
end
local function solveFlow(size, pairsT)
    local function rc(c) return (c - 1) // size + 1, (c - 1) % size + 1 end
    local used = {}
    for _, p in pairs(pairsT) do used[p[1]] = true; used[p[2]] = true end
    local order = {}
    for id in pairs(pairsT) do table.insert(order, id) end
    table.sort(order, function(a, b)
        local ar, ac = rc(pairsT[a][1]); local br, bc = rc(pairsT[a][2])
        local cr, cc = rc(pairsT[b][1]); local dr, dc = rc(pairsT[b][2])
        return math.abs(ar - br) + math.abs(ac - bc) < math.abs(cr - dr) + math.abs(cc - dc)
    end)
    local function neighbours(c, goal)
        local r, col = rc(c); local gr, gc = rc(goal)
        local out = {}
        if r > 1 then table.insert(out, c - size) end
        if r < size then table.insert(out, c + size) end
        if col > 1 then table.insert(out, c - 1) end
        if col < size then table.insert(out, c + 1) end
        table.sort(out, function(a, b)
            local ar, ac = rc(a); local br, bc = rc(b)
            return math.abs(ar - gr) + math.abs(ac - gc) < math.abs(br - gr) + math.abs(bc - gc)
        end)
        return out
    end
    local paths, budget = {}, 300000
    local route
    route = function(k)
        if k > #order then return true end
        local id = order[k]
        local a, b = pairsT[id][1], pairsT[id][2]
        local path = { a }
        local function dfs(c)
            budget -= 1
            if budget <= 0 then return false end
            -- big boards can take a while: yield now and then so the game never freezes
            if budget % 4000 == 0 and coroutine.isyieldable() then task.wait() end
            for _, n in ipairs(neighbours(c, b)) do
                if n == b then
                    path[#path + 1] = b
                    paths[id] = table.clone(path)
                    if route(k + 1) then return true end
                    paths[id] = nil
                    path[#path] = nil
                elseif not used[n] then
                    used[n] = true; path[#path + 1] = n
                    if dfs(n) then return true end
                    path[#path] = nil; used[n] = nil
                end
            end
            return false
        end
        return dfs(a)
    end
    if route(1) then return paths end
end
genv.__FurinaSolveFlow = solveFlow
local Solvers = {}
Solvers.FlowClientMinigame = function(s)
    local P = s.Network.Properties
    local paths = solveFlow(P:Get("GridSize"), P:Get("Pairs"))
    if not paths then notify("Auto Generator", "Flow puzzle: no solution found, solve it by hand.") return end
    local cells = 0
    for _, path in pairs(paths) do cells += #path end
    human(cells * 0.07)
    s.Network:FireServer("Submit", paths)
    Stats.puzzles += 1
end
Solvers.ConnectClientMinigame = function(s)
    local blobs = s.Network.Properties:Get("Blobs")
    local first, links = {}, {}
    for i, color in pairs(blobs) do
        local j = first[color]
        if j then table.insert(links, { math.min(i, j), math.max(i, j) }); first[color] = nil
        else first[color] = i end
    end
    human(#links * 0.35)
    s.Network:FireServer("Submit", links)
    Stats.puzzles += 1
end
Solvers.LockClientMinigame = function(s)
    if not LockBoard then return end
    local P = s.Network.Properties
    local cfg = P:Get("Config")
    if type(cfg) ~= "table" or type(cfg.Seed) ~= "number" then return end
    local board = LockBoard.new(cfg)
    local sync = try(function()
        return P:Connect("State", function(st)
            if type(st) == "table" and type(st.Presses) == "number" and board.State.Presses <= st.Presses then
                board:Apply(st)
            end
        end)
    end)
    task.wait(Cfg.SolveSpeed == "Fast" and (0.3 + math.random() * 0.3) or math.max(0, Cfg.GenDelay * 0.5))
    local deadline = os.clock() + 40
    while alive and autoSolveOn() and not board:IsBroken() and os.clock() < deadline do
        local now = workspace:GetServerTimeNow()
        if now >= cfg.StartTime then
            local d = (board:AngleAt(now) - board.State.Target) % 360
            d = math.min(d, 360 - d)
            if d <= (cfg.TargetSize or 20) / 4 + 1 then
                if board:Press(now) then s.Network:FireServer("Press", now) end
                task.wait(0.12 + math.random() * 0.08)
            end
        end
        RunService.Heartbeat:Wait()
    end
    if board:IsBroken() then Stats.puzzles += 1 end
    if sync and typeof(sync) == "RBXScriptConnection" then sync:Disconnect()
    elseif type(sync) == "table" and sync.Disconnect then pcall(sync.Disconnect, sync) end
end
Solvers.GearClientMinigame = function(s)
    if GearsClientHandler and (try(function() return GearsClientHandler:Get() end) or 0) < 1 then
        notify("Auto Generator", "You need a gear for this generator. Find one on the map.")
        return
    end
    local turns = math.max(1, s.Network.Properties:Get("Turns") or 6)
    task.wait(Cfg.SolveSpeed == "Fast" and math.max(0.9, turns * 0.15) + math.random() * 0.3 or math.max(Cfg.GenDelay, turns * 0.25))
    s.Network:FireServer("Screwed")
    Stats.puzzles += 1
end
local function classValues(cls)
    for k, v in next, cls do
        if type(v) == "table" and tostring(k) == "MinigameKey(ClassValues)" then return v end
    end
end
local hooked = {}
do
    local folder = RS:FindFirstChild("Systems") and RS.Systems.Player.Game:FindFirstChild("Minigames")
    for name, solver in pairs(Solvers) do
        local mod = folder and folder:FindFirstChild(name)
        local cls = mod and try(require, mod)
        local cv = cls and classValues(cls)
        if cv and type(cv.Start) == "function" then
            local orig = cv.Start
            cv.Start = function(session, ...)
                local res = table.pack(pcall(orig, session, ...))
                if alive and autoSolveOn() then
                    local ok = try(function() return session.Network.Properties:Get("FixerUserId") == LP.UserId end)
                    if ok then
                        task.spawn(function()
                            local good, err = pcall(solver, session)
                            if not good then warn("[FurinaHub] " .. name .. ": " .. tostring(err)) end
                        end)
                    end
                end
                if not res[1] then error(res[2], 0) end
                return table.unpack(res, 2, res.n)
            end
            hooked[name] = true
            onCleanup(function() cv.Start = orig end)
        else
            hooked[name] = false
        end
    end
end
genv.__FurinaHooked = hooked
local abCache, abT = nil, 0
local function abilityButtons(fresh)
    if not fresh and abCache and os.clock() - abT < 2 then
        local ok = true
        for _, b in ipairs(abCache) do if not b.Parent or not b.Visible then ok = false break end end
        if ok and #abCache > 0 then return abCache end
    end
    local list = (function()
    local mu = LP.PlayerGui:FindFirstChild("MainUI")
    local ac = mu and mu:FindFirstChild("AbilityContainer")
    if not ac then return {} end
    local list = {}
    for _, b in ipairs(ac:GetDescendants()) do
        if b:IsA("GuiButton") and b.Visible then
            local n = getconns and (#connsOf(b.MouseButton1Click) + #connsOf(b.MouseButton1Down)) or 1
            if n > 0 then table.insert(list, b) end
        end
    end
    table.sort(list, function(a, b)
        if a.LayoutOrder ~= b.LayoutOrder then return a.LayoutOrder < b.LayoutOrder end
        return a.AbsolutePosition.X < b.AbsolutePosition.X
    end)
    return list
    end)()
    abCache, abT = list, os.clock()
    return list
end
genv.__FurinaAbilityButtons = abilityButtons
local function useAbilitySlot(slot)
    local b = typeof(slot) == "Instance" and slot or abilityButtons()[slot or 1]
    if b then
        local fired = false
        for _, c in ipairs(connsOf(b.MouseButton1Click)) do
            if c.Function then task.spawn(c.Function); fired = true end
        end
        if not fired then
            for _, c in ipairs(connsOf(b.MouseButton1Down)) do
                if c.Function then task.spawn(c.Function); fired = true end
            end
            task.delay(0.06, function()
                for _, c in ipairs(connsOf(b.MouseButton1Up)) do
                    if c.Function then task.spawn(c.Function) end
                end
            end)
        end
        if fired then return true end
        local ok = pcall(function()
            local VIM = game:GetService("VirtualInputManager")
            local c = b.AbsolutePosition + b.AbsoluteSize / 2 + GuiService:GetGuiInset()
            VIM:SendMouseButtonEvent(c.X, c.Y, 0, true, game, 0)
            task.wait(0.03)
            VIM:SendMouseButtonEvent(c.X, c.Y, 0, false, game, 0)
        end)
        if ok then return true end
    end
    if typeof(slot) == "Instance" then return false end -- never fall back to M1 for a named button
    if mouse1click and (not isrbxactive or isrbxactive()) then mouse1click() return true end
    return false
end
local lastAttack = 0
local function auraRange() return Cfg.SafeMode and math.min(Cfg.AuraRange, 7.5) or Cfg.AuraRange end
local function attackInterval()
    local i = Cfg.SafeMode and math.max(Cfg.AuraDelay, 0.45) or Cfg.AuraDelay
    return i + (Cfg.SafeMode and math.random() * 0.15 or 0)
end
local nextAttackGap = 0.4
local function nearestSurvivorHum()
    local f = teamFolder("Survivors"); local r = myRoot()
    if not f or not r then return end
    local best, bd
    for _, m in ipairs(f:GetChildren()) do
        local h = m:FindFirstChildOfClass("Humanoid"); local tr = rootOf(m)
        if h and tr and h.Health > 0 then
            local d = (tr.Position - r.Position).Magnitude
            if not bd or d < bd then best, bd = h, d end
        end
    end
    return best, bd
end
local function tryAttack()
    local now = os.clock()
    if now - lastAttack < nextAttackGap then return end
    lastAttack = now
    nextAttackGap = attackInterval()
    local h, d = nearestSurvivorHum()
    local before = h and h.Health
    useAbilitySlot(Cfg.AttackSlot)
    if h and d and d < 12 then
        task.delay(0.8, function()
            if h.Parent and h.Health < before - 1 then Stats.hits += 1 end
        end)
    end
end
local function faceTowards(pos)
    local r = myRoot(); if not r then return end
    local flat = Vector3.new(pos.X, r.Position.Y, pos.Z)
    if (flat - r.Position).Magnitude < 0.1 then return end
    local want = CFrame.lookAt(r.Position, flat)
    r.CFrame = Cfg.SafeMode and r.CFrame:Lerp(want, 0.35) or want
end
local GenBinder = req(RS, { "Systems", "Player", "Game", "Generators", "GeneratorClientBinder" })
local genRunning
if GenBinder then
    for k, v in next, GenBinder do
        if tostring(k) == "BinderKey(Running)" then genRunning = v end
    end
end
local function liveGenerators()
    local list = {}
    if genRunning then
        for inst, obj in pairs(genRunning) do
            if typeof(inst) == "Instance" and inst.Parent and inst.Name == "Generator" then
                local P = obj.Network and obj.Network.Properties
                local ok, counter, maxc, done, occ = pcall(function()
                    return P:Get("Counter"), P:Get("MaxCounter"), P:Get("Completed"), P:Get("Occupants")
                end)
                local main = inst:FindFirstChild("Main")
                if ok and main and not done and (maxc or 0) > 0 then
                    table.insert(list, { inst = inst, main = main, pos = main.Position,
                        progress = (counter or 0) / maxc, occupants = occ or {} })
                end
            end
        end
    end
    if #list == 0 then
        for g in pairs(Generators) do
            if g.Parent and not genDone(g) and g:FindFirstChild("Main") then
                table.insert(list, { inst = g, main = g.Main, pos = g.Main.Position, progress = 0, occupants = {} })
            end
        end
    end
    return list
end
-- the generator we're currently sitting at (repairing), via the game's own binder objects
local function sittingGen()
    if not genRunning then return end
    for inst, obj in pairs(genRunning) do
        if typeof(inst) == "Instance" and type(obj) == "table" and obj.__sitting then return obj, inst end
    end
end
-- leave it the same way the puzzle's Leave button does (binder:__leave fires Network "Leave")
local function leaveGenerator()
    local obj = sittingGen()
    if obj and type(obj.__leave) == "function" then
        return pcall(obj.__leave, obj)
    end
    return false
end
genv.__FurinaLeaveGen = leaveGenerator
local function killersInfo()
    local out = {}
    local f = teamFolder("Killers")
    if not f then return out end
    for _, m in ipairs(f:GetChildren()) do
        local h = m:FindFirstChildOfClass("Humanoid"); local kr = rootOf(m)
        if m ~= LP.Character and kr and h and h.Health > 0 then
            local vel = kr.AssemblyLinearVelocity
            table.insert(out, { model = m, root = kr, pos = kr.Position, vel = Vector3.new(vel.X, 0, vel.Z) })
        end
    end
    return out
end
-- PuzzleUI can linger after a generator finishes; if the binder says we're not sitting at any
-- generator for 3s while it's still there, treat it as stale (the AI was freezing on it)
local puzzleStaleSince
local function inPuzzle()
    if not LP.PlayerGui:FindFirstChild("PuzzleUI") then puzzleStaleSince = nil return false end
    if not genRunning or sittingGen() then puzzleStaleSince = nil return true end
    puzzleStaleSince = puzzleStaleSince or os.clock()
    return os.clock() - puzzleStaleSince < 3
end
local function gearsHeld()
    return (GearsClientHandler and try(function() return GearsClientHandler:Get() end)) or 0
end
local function gearPrompt(gm)
    local p = gm:FindFirstChildWhichIsA("ProximityPrompt", true)
    return (p and p.Enabled) and p or nil
end
local lastGearFire = 0
local function grabGear(p)
    if os.clock() - lastGearFire < 1 then return end
    lastGearFire = os.clock()
    task.spawn(firePrompt, p)
end
local lastRole
-- round results: a survivor wins by leaving the round alive, a killer by leaving it with nobody alive
local Round = { died = false, survivorsAlive = nil }
local function recordResult(won, as)
    Stats.lastResult = (won and "Won" or "Lost") .. " as " .. as
    if won then
        Stats.wins += 1
        Stats.streak += 1
        Stats.bestStreak = math.max(Stats.bestStreak, Stats.streak)
    else
        Stats.streak = 0
    end
    notify("Round over", ("%s  |  win streak %d"):format(Stats.lastResult, Stats.streak), 5)
end
local function onRoleChanged(role, prev)
    if prev == "Survivors" then
        local h = myHum()
        local dead = Round.died or role ~= "Spectating" or not h or h.Health <= 0
        recordResult(not dead, "Survivor")
    elseif prev == "Killers" and Round.survivorsAlive ~= nil then
        -- everyone dead with time still on the clock = killer win (a timed-out round empties the folder too)
        recordResult(Round.survivorsAlive == 0 and (Round.timeLeft or 0) > 3, "Killer")
    end
    Round.died, Round.survivorsAlive = false, nil
    if role == "Survivors" then
        Stats.roundsSurvivor += 1
        local k = teamFolder("Killers")
        local km = k and k:GetChildren()[1]
        local kname = km and (km:GetAttribute("ActorDisplayName") or km.Name) or "unknown"
        notify("Round started", ("You're a Survivor. Killer: %s%s"):format(kname,
            ""), 5)
    elseif role == "Killers" then
        Stats.roundsKiller += 1
        local c = LP.Character
        notify("Round started", ("You're the Killer (%s)%s"):format(c and (c:GetAttribute("ActorDisplayName") or c.Name) or "?",
            ""), 5)
    end
end
connect(RunService.Heartbeat, function(dt)
    if not alive then return end
    local role = myRole()
    if role == "Survivors" then
        local h = myHum()
        if h and h.Health <= 0 then Round.died = true end
    elseif role == "Killers" then
        local n, f = 0, teamFolder("Survivors")
        for _, m in ipairs(f and f:GetChildren() or {}) do
            local h = m:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then n += 1 end
        end
        Round.survivorsAlive = n
        local rt = RS:FindFirstChild("RoundTimer")
        Round.timeLeft = rt and tonumber(rt:GetAttribute("TimeLeft")) or nil
    end
    if role ~= lastRole then
        local prev = lastRole
        lastRole = role
        if prev ~= nil then
            local ok, err = pcall(onRoleChanged, role, prev)
            if not ok then warn("[FurinaHub] role change: " .. tostring(err)) end
        end
    end
end)
genv.__FurinaCfg = Cfg
genv.__FurinaCandies = Candies
do
    local disabled = {}
    for _, c in ipairs(connsOf(LP.Idled)) do
        if pcall(function() c:Disable() end) then table.insert(disabled, c) end
    end
    onCleanup(function() for _, c in ipairs(disabled) do pcall(function() c:Enable() end) end end)
    local VirtualUser = game:GetService("VirtualUser")
    connect(LP.Idled, function()
        if Cfg.AntiAFK then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end
    end)
end
local Boost = { on = false, disabled = {}, conn = nil, savedQuality = nil, savedShadows = nil }
local FX = { ParticleEmitter = true, Trail = true, Smoke = true, Fire = true, Sparkles = true, Beam = true }
local POST = { BloomEffect = true, BlurEffect = true, SunRaysEffect = true, DepthOfFieldEffect = true }
local function boostOne(d)
    if (FX[d.ClassName] or POST[d.ClassName]) and d.Enabled then
        Boost.disabled[d] = true
        d.Enabled = false
    end
end
local function setFpsBoost(on)
    if on == Boost.on then return end
    Boost.on = on
    if on then
        Boost.savedShadows = Lighting.GlobalShadows
        Lighting.GlobalShadows = false
        pcall(function()
            Boost.savedQuality = settings().Rendering.QualityLevel
            settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        end)
        for _, d in ipairs(workspace:GetDescendants()) do boostOne(d) end
        for _, d in ipairs(Lighting:GetChildren()) do boostOne(d) end
        Boost.conn = workspace.DescendantAdded:Connect(function(d) task.defer(function() if Boost.on then boostOne(d) end end) end)
    else
        if Boost.conn then Boost.conn:Disconnect(); Boost.conn = nil end
        for d in pairs(Boost.disabled) do if d.Parent then pcall(function() d.Enabled = true end) end end
        table.clear(Boost.disabled)
        if Boost.savedShadows ~= nil then Lighting.GlobalShadows = Boost.savedShadows end
        pcall(function() settings().Rendering.QualityLevel = Boost.savedQuality or Enum.QualityLevel.Automatic end)
    end
end
onCleanup(function() setFpsBoost(false) end)
local rejoining = false
local function rejoin(reason)
    if rejoining then return end
    rejoining = true
    warn("[FurinaHub] rejoining: " .. tostring(reason))
    task.wait(3)
    pcall(function() TeleportSvc:Teleport(game.PlaceId, LP) end)
    task.delay(15, function() rejoining = false end)
end
pcall(function()
    connect(GuiService.ErrorMessageChanged, function(msg)
        if Cfg.AutoRejoin and msg and msg ~= "" then rejoin(msg) end
    end)
end)
pcall(function()
    local overlay = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
    overlay = overlay and overlay:FindFirstChild("promptOverlay")
    if overlay then
        connect(overlay.ChildAdded, function(c)
            if Cfg.AutoRejoin and c.Name == "ErrorPrompt" then rejoin("error prompt") end
        end)
    end
end)
local function serverHop(emptiest)
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if not ok then return false, "couldn't reach the server list" end
    local okj, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not okj or type(data) ~= "table" or type(data.data) ~= "table" then return false, "bad server list" end
    local list = {}
    for _, sv in ipairs(data.data) do
        if sv.id ~= game.JobId and (sv.playing or 0) < (sv.maxPlayers or 0) and (sv.playing or 0) > 0 then
            table.insert(list, sv)
        end
    end
    if #list == 0 then return false, "no other servers with space" end
    local pick
    if emptiest then
        table.sort(list, function(a, b) return a.playing < b.playing end)
        pick = list[1]
    else
        pick = list[math.random(1, #list)]
    end
    TeleportSvc:TeleportToPlaceInstance(game.PlaceId, pick.id, LP)
    return true, ("%d/%d players"):format(pick.playing, pick.maxPlayers)
end
local espRoot = Instance.new("Folder")
espRoot.Name = HttpService:GenerateGUID(false)
safeParent(espRoot)
onCleanup(function() espRoot:Destroy() end)
local Esp = {} -- [instance] = record
local function newEsp(target, anchor, labelOnly)
    -- Roblox renders at most 31 Highlights; spend them on rigs and generators, label the rest
    local hl
    if not labelOnly then
        hl = Instance.new("Highlight")
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.FillTransparency = 0.7
        hl.OutlineTransparency = 0
        hl.Adornee = target
        hl.Parent = espRoot
    end
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(220, 36)
    bb.StudsOffset = Vector3.new(0, 3.5, 0)
    bb.LightInfluence = 0
    bb.Adornee = anchor
    bb.Parent = espRoot
    local tl = Instance.new("TextLabel")
    tl.BackgroundTransparency = 1
    tl.Size = UDim2.fromScale(1, 1)
    tl.Font = Enum.Font.GothamBold
    tl.TextSize = 13
    tl.TextStrokeTransparency = 0.35
    tl.Parent = bb
    return { hl = hl, bb = bb, tl = tl, seen = 0 }
end
local function dropEsp(k)
    local r = Esp[k]
    if r then
        if r.hl then r.hl:Destroy() end
        r.bb:Destroy()
        Esp[k] = nil
    end
end
local tick_ = 0
local function espUpdate()
    tick_ += 1
    local me = myRoot()
    local myPos = me and me.Position
    local function show(target, color, text, labelOnly)
        local anchor = rootOf(target)
        if not anchor then return end
        local r = Esp[target]
        if not r then r = newEsp(target, anchor, labelOnly); Esp[target] = r end
        if r.bb.Adornee ~= anchor then r.bb.Adornee = anchor end
        if r.color ~= color then
            r.color = color
            r.tl.TextColor3 = color
            if r.hl then r.hl.FillColor, r.hl.OutlineColor = color, color end
        end
        local parts = {}
        if Cfg.EspNames then table.insert(parts, text) end
        if Cfg.EspDistance and myPos then table.insert(parts, ("[%dm]"):format(dist(anchor.Position, myPos) // 1)) end
        local txt = table.concat(parts, " ")
        if r.tl.Text ~= txt then r.tl.Text = txt end
        setIf(r.bb, "Enabled", #parts > 0)
        r.seen = tick_
    end
    local function rigText(m)
        local h = m:FindFirstChildOfClass("Humanoid")
        local user = m:GetAttribute("Username")
        local actor = m:GetAttribute("ActorDisplayName") or m.Name
        local s = user and ("%s (%s)"):format(user, actor) or actor
        if Cfg.EspHealth and h then s ..= (" | %d HP"):format(math.max(0, h.Health) // 1) end
        return s
    end
    if Cfg.EspKillers then
        local f = teamFolder("Killers")
        if f then for _, m in ipairs(f:GetChildren()) do
            if m:IsA("Model") and m ~= LP.Character then show(m, Cfg.KillerColor, rigText(m)) end
        end end
    end
    if Cfg.EspSurvivors then
        local f = teamFolder("Survivors")
        if f then for _, m in ipairs(f:GetChildren()) do
            if m:IsA("Model") and m ~= LP.Character then show(m, Cfg.SurvivorColor, rigText(m)) end
        end end
    end
    if Cfg.EspGens then
        for _, info in ipairs(liveGenerators()) do
            local g = info.inst
            local puzzle = tostring(g:GetAttribute("Puzzle") or ""):gsub("ServerMinigame", "")
            local label = ("Generator %d%%"):format(info.progress * 100)
            if puzzle ~= "" then label ..= " (" .. puzzle .. ")" end
            show(g, Cfg.GenColor, label)
        end
    end
    if Cfg.EspCandy then
        for c in pairs(Candies) do
            if c.Parent then show(c, Cfg.CandyColor, "Candy", true) end
        end
    end
    if Cfg.EspGears then
        for gm in pairs(Gears) do
            if gm.Parent and gearPrompt(gm) then show(gm, Cfg.GearColor, "Gear", true) end
        end
    end
    if Cfg.EspItems then
        local map = workspace:FindFirstChild("Map")
        for it in pairs(Items) do
            if it.Parent and map and it:IsDescendantOf(map) then show(it, Cfg.ItemColor, it.Name, true) end
        end
    end
    for k, r in pairs(Esp) do
        if r.seen ~= tick_ or not k.Parent then dropEsp(k) end
    end
end
-- Fullbright and No Fog each save and restore only their own properties, so turning one
-- off puts its settings back even while the other stays on (atmospheres included).
local LightSaved = { fb = nil, fog = nil, atmo = {} }
local FB_AMB = Color3.fromRGB(180, 180, 180)
local FB_KEYS = { "Brightness", "ClockTime", "GlobalShadows", "Ambient", "OutdoorAmbient" }
local function restoreFullbright()
    if not LightSaved.fb then return end
    for k, v in pairs(LightSaved.fb) do pcall(function() Lighting[k] = v end) end
    LightSaved.fb = nil
end
local function restoreFog()
    if LightSaved.fog then
        for k, v in pairs(LightSaved.fog) do pcall(function() Lighting[k] = v end) end
        LightSaved.fog = nil
    end
    for a, v in pairs(LightSaved.atmo) do
        if a.Parent then pcall(function() a.Density, a.Haze = v.Density, v.Haze end) end
    end
    table.clear(LightSaved.atmo)
end
local function applyLighting()
    if Cfg.Fullbright then
        if not LightSaved.fb then
            LightSaved.fb = {}
            for _, k in ipairs(FB_KEYS) do LightSaved.fb[k] = Lighting[k] end
        end
        setIf(Lighting, "Brightness", 2); setIf(Lighting, "ClockTime", 14); setIf(Lighting, "GlobalShadows", false)
        setIf(Lighting, "Ambient", FB_AMB); setIf(Lighting, "OutdoorAmbient", FB_AMB)
    else
        restoreFullbright()
    end
    if Cfg.NoFog then
        if not LightSaved.fog then LightSaved.fog = { FogEnd = Lighting.FogEnd, FogStart = Lighting.FogStart } end
        setIf(Lighting, "FogEnd", 1e6); setIf(Lighting, "FogStart", 1e6)
        for _, a in ipairs(Lighting:GetChildren()) do
            if a:IsA("Atmosphere") then
                if not LightSaved.atmo[a] then LightSaved.atmo[a] = { Density = a.Density, Haze = a.Haze } end
                setIf(a, "Density", 0); setIf(a, "Haze", 0)
            end
        end
    else
        restoreFog()
    end
end
local function restoreLighting()
    restoreFullbright()
    restoreFog()
end
onCleanup(restoreLighting)
local lastEnter, lastPickup, lastGearTry, warned = 0, 0, 0, false
connect(RunService.Heartbeat, function()
    if not alive then return end
    if Sprinting then
        if Cfg.InfStamina then
            Sprinting.StaminaLossDisabled = true
            if type(Sprinting.MaxStamina) == "number" then Sprinting.Stamina = Sprinting.MaxStamina end
        end
    end
    local role = myRole()
    local r = myRoot()
    if not r then return end
    local now = os.clock()
    if role == "Killers" and (Cfg.KillAura or Cfg.AutoChase) then
        local f = teamFolder("Survivors")
        local best, bd
        if f then for _, m in ipairs(f:GetChildren()) do
            local h = m:FindFirstChildOfClass("Humanoid"); local tr = rootOf(m)
            if tr and h and h.Health > 0 then
                local d = dist(tr.Position, r.Position)
                if not bd or d < bd then best, bd = tr, d end
            end
        end end
        if best then
            local hum = LP.Character:FindFirstChildOfClass("Humanoid")
            if Cfg.AutoChase and hum and bd > auraRange() * 0.7 then hum:MoveTo(best.Position) end
            -- only swing when the hit can land: check where both of you will be when the swing comes out,
            -- so a survivor running away doesn't make you whiff and lose your sprint
            if Cfg.KillAura and bd <= auraRange() + 4 then
                local lead = 0.3
                local mv, tv = r.AssemblyLinearVelocity, best.AssemblyLinearVelocity
                local me = r.Position + Vector3.new(mv.X, 0, mv.Z) * lead
                local them = best.Position + Vector3.new(tv.X, 0, tv.Z) * lead
                if (them - me).Magnitude <= auraRange() and bd <= auraRange() + 2 then
                    faceTowards(best.Position)
                    tryAttack()
                end
            end
        end
    end
    if role == "Survivors" and Cfg.AutoEnterGen and now - lastEnter > 1.5 then
        lastEnter = now
        local g = not inPuzzle() and nearestGen(12)
        local p = g and genPrompt(g)
        if p and p.Enabled and (p.Parent.Position - r.Position).Magnitude <= p.MaxActivationDistance - 0.5 then
            task.spawn(firePrompt, p)
        end
    end
    if role == "Survivors" and Cfg.AutoPickup and now - lastPickup > 0.5 then
        lastPickup = now
        for it in pairs(Items) do
            local h = it.Parent and rootOf(it)
            if h and dist(h.Position, r.Position) <= Cfg.PickupDist then
                local p = it:FindFirstChildWhichIsA("ProximityPrompt", true)
                local okRange = not Cfg.SafeMode or (p and dist(h.Position, r.Position) <= p.MaxActivationDistance - 0.5)
                if p and p.Enabled and okRange then task.spawn(firePrompt, p) end
            end
        end
    end
    if role == "Survivors" and Cfg.AutoGears and now - lastGearTry > 0.25 and gearsHeld() < 1 then
        lastGearTry = now
        for gm in pairs(Gears) do
            local root = gm.Parent and rootOf(gm)
            local p = root and gearPrompt(gm)
            if p and dist(root.Position, r.Position) <= p.MaxActivationDistance - 0.5 then grabGear(p) break end
        end
    end
    if role == "Survivors" and Cfg.KillerWarn then
        local f = teamFolder("Killers")
        local close
        if f then for _, m in ipairs(f:GetChildren()) do
            local kr = rootOf(m)
            if kr and dist(kr.Position, r.Position) <= Cfg.WarnDist then close = m:GetAttribute("ActorDisplayName") or m.Name break end
        end end
        if close and not warned then
            warned = true
            notify("⚠ Killer nearby", ("%s is within %d studs!"):format(close, Cfg.WarnDist), 3)
        elseif not close and warned then
            warned = false
        end
    end
end)
task.spawn(function()
    while alive do
        local anyEsp = Cfg.EspKillers or Cfg.EspSurvivors or Cfg.EspGens or Cfg.EspItems or Cfg.EspGears or Cfg.EspCandy
        if anyEsp or next(Esp) then pcall(espUpdate) end
        pcall(applyLighting) -- cheap; also handles switching off (restores what was changed)
        task.wait(anyEsp and 0.2 or 0.5)
    end
end)
onCleanup(function() for k in pairs(Esp) do dropEsp(k) end end)
onCleanup(function() if Sprinting then Sprinting.StaminaLossDisabled = false end end)
local Furina = {
    base   = Color3.fromRGB(11, 26, 51),    -- deep sapphire
    glass  = Color3.fromRGB(168, 220, 255), -- pale aqua overlay
    text   = Color3.fromRGB(234, 246, 255), -- soft white-blue
    gold   = Color3.fromRGB(232, 199, 122), -- gold trim
    accent = Color3.fromRGB(79, 179, 255),  -- hydro blue
}
local function roundInfo()
    local killers, survivorsAlive = {}, 0
    local kf, sf = teamFolder("Killers"), teamFolder("Survivors")
    for _, m in ipairs(kf and kf:GetChildren() or {}) do
        local user = m:GetAttribute("Username")
        table.insert(killers, (m:GetAttribute("ActorDisplayName") or m.Name) .. (user and (" (" .. user .. ")") or ""))
    end
    for _, m in ipairs(sf and sf:GetChildren() or {}) do
        local h = m:FindFirstChildOfClass("Humanoid")
        if h and h.Health > 0 then survivorsAlive += 1 end
    end
    local total, done = 0, 0
    if genRunning then
        for inst, obj in pairs(genRunning) do
            if typeof(inst) == "Instance" and inst.Name == "Generator" then
                local ok, maxc, comp = pcall(function()
                    return obj.Network.Properties:Get("MaxCounter"), obj.Network.Properties:Get("Completed")
                end)
                if ok and (maxc or 0) > 0 then
                    total += 1
                    if comp then done += 1 end
                end
            end
        end
    end
    local timer = RS:FindFirstChild("RoundTimer")
    return {
        killer = #killers > 0 and table.concat(killers, ", ") or "none (lobby)",
        survivors = survivorsAlive, gensDone = done, gensTotal = total,
        timer = timer and tostring(timer.Value) or "?",
    }
end
local Spectate = { idx = 0 }
local function spectateNext(killerOnly)
    local cam = workspace.CurrentCamera
    local list = {}
    for _, name in ipairs(killerOnly and { "Killers" } or { "Killers", "Survivors" }) do
        local f = teamFolder(name)
        for _, m in ipairs(f and f:GetChildren() or {}) do
            local h = m:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 and m ~= LP.Character then table.insert(list, { m = m, h = h }) end
        end
    end
    if #list == 0 then notify("Spectate", "Nobody to spectate right now.", 3) return end
    Spectate.idx = (Spectate.idx % #list) + 1
    local pick = list[Spectate.idx]
    cam.CameraSubject = pick.h
    notify("Spectate", ("Watching %s"):format(pick.m:GetAttribute("Username") or pick.m.Name), 2)
end
local function spectateSelf()
    local h = myHum()
    if h then workspace.CurrentCamera.CameraSubject = h end
end
onCleanup(spectateSelf)
do
    local lowWarned = false
    task.spawn(function()
        while alive do
            local h = myHum()
            if Cfg.LowHpAlert and h and myRole() == "Survivors" then
                local frac = h.Health / math.max(1, h.MaxHealth)
                if frac < 0.35 and h.Health > 0 and not lowWarned then
                    lowWarned = true
                    notify("Low health", ("You're at %d HP - play safe!"):format(h.Health), 4)
                elseif frac > 0.5 then
                    lowWarned = false
                end
            end
            task.wait(0.5)
        end
    end)
end
local function killerNearest(pos)
    local best
    for _, k in ipairs(killersInfo()) do
        local d = (k.pos - pos).Magnitude
        if not best or d < best then best = d end
    end
    return best
end
do
    local lastHeal = 0
    local function healTool()
        local function pick(c)
            if not c then return end
            for _, t in ipairs(c:GetChildren()) do
                if t:IsA("Tool") and t.Name:find("Medkit") and not t.Name:find("Fake") then return t end
            end
        end
        return pick(LP.Character) or pick(LP:FindFirstChildOfClass("Backpack"))
    end
    task.spawn(function()
        while alive do
            task.wait(0.5)
            local h, r = myHum(), myRoot()
            if Cfg.AutoHeal and h and r and myRole() == "Survivors" and h.Health > 0
                and h.Health / math.max(1, h.MaxHealth) * 100 < Cfg.HealAt
                and os.clock() - lastHeal > 8 and not inPuzzle() then
                local kd = killerNearest(r.Position)
                local safe = not kd or kd > 45
                local tool = safe and healTool()
                -- survivors that can't use Medkits (Veeronica) heal with an ability instead
                local healBtn
                if safe and not tool then
                    for i, b in ipairs(abilityButtons(true)) do
                        local n = b.Name:lower()
                        if n:find("battery") or n:find("heal") then healBtn = i break end
                    end
                end
                if healBtn then
                    lastHeal = os.clock()
                    useAbilitySlot(healBtn)
                    notify("Auto Heal", ("Using your heal ability at %d HP"):format(h.Health), 3)
                elseif tool then
                    lastHeal = os.clock()
                    pcall(function()
                        if tool.Parent ~= LP.Character then h:EquipTool(tool); task.wait(0.35) end
                        tool:Activate()
                    end)
                    notify("Auto Heal", ("Using %s at %d HP"):format(tool.Name, h.Health), 3)
                end
            end
        end
    end)
end
------------------------------------------------------------------------------------------------------
-- Forsakeween candy: C00lCandy models (Map.Ingame...CurrencySpawns) with a "Pick up" prompt
-- (8 studs, 0.5s hold). The server removes a candy for everyone once someone takes it.
------------------------------------------------------------------------------------------------------
local candyCounter
local function candyBalance()
    if not candyCounter or not candyCounter.Parent then
        local pd = LP:FindFirstChild("PlayerData")
        local ec = pd and pd:FindFirstChild("EventCurrency")
        candyCounter = ec and ec:FindFirstChild("Candy", true)
    end
    return candyCounter and tonumber(candyCounter.Value)
end
Stats.candyStart = candyBalance()
local function candyPrompt(c)
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("ProximityPrompt") and p.Enabled and p.MaxActivationDistance > 0 then return p end
    end
end
local lastCandyFire = setmetatable({}, { __mode = "k" })
task.spawn(function()
    while alive do
        task.wait(0.15)
        if Cfg.CandyCollect then
            local role = myRole()
            local r, h = myRoot(), myHum()
            if (role == "Survivors" or role == "Killers") and r and h and h.Health > 0 then
                for c in pairs(Candies) do
                    local p = c.Parent and candyPrompt(c)
                    if p and (c:GetPivot().Position - r.Position).Magnitude <= p.MaxActivationDistance - 0.5
                        and os.clock() - (lastCandyFire[c] or 0) > 1.2 then
                        lastCandyFire[c] = os.clock()
                        task.spawn(firePrompt, p)
                    end
                end
            end
        end
    end
end)

local vigGui = Instance.new("ScreenGui")
vigGui.Name = HttpService:GenerateGUID(false):sub(1, 8)
vigGui.IgnoreGuiInset = true
vigGui.ResetOnSpawn = false
vigGui.DisplayOrder = -5
safeParent(vigGui)
onCleanup(function() vigGui:Destroy() end)
local vigEdges = {}
for _, e in ipairs({
    { UDim2.fromScale(1, 0.16), UDim2.fromScale(0, 0), 90 },
    { UDim2.fromScale(1, 0.16), UDim2.fromScale(0, 0.84), -90 },
    { UDim2.fromScale(0.12, 1), UDim2.fromScale(0, 0), 0 },
    { UDim2.fromScale(0.12, 1), UDim2.fromScale(0.88, 0), 180 },
}) do
    local f = Instance.new("Frame")
    f.Size, f.Position = e[1], e[2]
    f.BorderSizePixel = 0
    f.BackgroundColor3 = Color3.fromRGB(220, 20, 40)
    f.BackgroundTransparency = 1
    f.Parent = vigGui
    local g = Instance.new("UIGradient")
    g.Rotation = e[3]
    g.Transparency = NumberSequence.new(0, 1)
    g.Parent = f
    table.insert(vigEdges, f)
end
task.spawn(function()
    local cur = 1
    while alive do
        task.wait(0.1)
        local want = 1
        local r = myRoot()
        if Cfg.DangerVignette and r and myRole() == "Survivors" then
            local kd = killerNearest(r.Position)
            if kd and kd < Cfg.VignetteDist then
                local k = 1 - math.clamp((kd - 12) / math.max(1, Cfg.VignetteDist - 12), 0, 1)
                want = 1 - 0.15 - k * 0.55
            end
        end
        want = math.floor(want * 20 + 0.5) / 20
        if want ~= cur then
            cur = want
            for _, f in ipairs(vigEdges) do f.BackgroundTransparency = cur end
        end
    end
end)
do
    local lines = {}
    local function drop(m) if lines[m] then pcall(function() lines[m]:Remove() end); lines[m] = nil end end
    onCleanup(function() for m in pairs(lines) do drop(m) end end)
    if Drawing and Drawing.new then
        connect(RunService.RenderStepped, function()
            if not (Cfg.TracerKillers or Cfg.TracerSurvivors) then
                if next(lines) then for m in pairs(lines) do drop(m) end end
                return
            end
            local cam = workspace.CurrentCamera
            local vp = cam.ViewportSize
            local from = Vector2.new(vp.X / 2, vp.Y - 4)
            local seen = {}
            for _, team in ipairs({ "Killers", "Survivors" }) do
                local on = (team == "Killers" and Cfg.TracerKillers) or (team == "Survivors" and Cfg.TracerSurvivors)
                local f = on and teamFolder(team)
                for _, m in ipairs(f and f:GetChildren() or {}) do
                    local rt = m ~= LP.Character and rootOf(m)
                    if rt then
                        local sp, vis = cam:WorldToViewportPoint(rt.Position)
                        local ln = lines[m]
                        if not ln then
                            local ok, l = pcall(Drawing.new, "Line")
                            if ok then ln = l; ln.Thickness = 1.5; ln.Transparency = 1; lines[m] = ln end
                        end
                        if ln then
                            seen[m] = true
                            ln.Visible = vis
                            if vis then
                                ln.From = from
                                ln.To = Vector2.new(sp.X, sp.Y)
                                ln.Color = team == "Killers" and Cfg.KillerColor or Cfg.SurvivorColor
                            end
                        end
                    end
                end
            end
            for m in pairs(lines) do if not seen[m] then drop(m) end end
        end)
    end
end
-- Combat: auto block + aimbot ----------------------------------------------------------------------------
local function abilityBtn(names)
    local mu = LP.PlayerGui:FindFirstChild("MainUI")
    local ac = mu and mu:FindFirstChild("AbilityContainer")
    if not ac then return nil end
    for _, n in ipairs(names) do
        local b = ac:FindFirstChild(n)
        if b and b:IsA("GuiButton") and b.Visible then return b end
    end
end
local function btnReady(b)
    if not b then return false end
    local cd = b:FindFirstChild("CooldownTime", true)
    if not cd or not cd:IsA("TextLabel") then return true end
    local t = cd.Text
    return t == "" or (tonumber(t) or 0) <= 0
end
local BLOCK_NAMES = { "Block", "Parry", "Counter", "Deflect" }
-- killer animation id -> animation name, built from every killer and killer skin Config
local attackAnims = {}
local ATTACK_WORDS = { "slash", "stab", "attack", "punch", "behead", "bite", "lunge", "dismantle", "uppercut",
    "combo", "swing", "strike", "gashingwound", "voidrush", "eviscerate", "hatchet", "claw", "smash" }
local NOT_ATTACK = { "idle", "walk", "run", "execution", "victory", "intro", "stunned", "cutscene", "victim", "emote",
    "unstable", "loop", "warning" }
local function isAttackName(n)
    n = n:lower()
    for _, w in ipairs(NOT_ATTACK) do if n:find(w, 1, true) then return false end end
    for _, w in ipairs(ATTACK_WORDS) do if n:find(w, 1, true) then return true end end
    return false
end
task.spawn(function()
    local assets = RS:WaitForChild("Assets", 30)
    local roots = {}
    if assets then
        table.insert(roots, assets:FindFirstChild("Killers"))
        local sk = assets:FindFirstChild("Skins")
        table.insert(roots, sk and sk:FindFirstChild("Killers"))
    end
    -- Animations entries can be an id string, an Animation, or a nested table of variants
    -- (Sixer: Slash = { Slash = id, Bite = id }), so walk them recursively
    local function addAnims(t, parentName, depth)
        if depth > 4 then return end
        for name, v in pairs(t) do
            local n = tostring(name)
            if type(v) == "table" then
                addAnims(v, isAttackName(n) and n or parentName, depth + 1)
            else
                local s = type(v) == "string" and v or (typeof(v) == "Instance" and v:IsA("Animation") and v.AnimationId)
                local num = s and s:match("%d+")
                if num and num ~= "0" then
                    if isAttackName(n) then attackAnims[num] = n
                    elseif parentName and type(name) == "number" then attackAnims[num] = parentName end
                end
            end
        end
    end
    for _, root in ipairs(roots) do
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("ModuleScript") and d.Name == "Config" then
                local cfg = try(require, d)
                local anims = type(cfg) == "table" and cfg.Animations
                if type(anims) == "table" then addAnims(anims, nil, 0) end
            elseif d:IsA("Animation") and isAttackName(d.Name) then
                local num = d.AnimationId:match("%d+")
                if num and num ~= "0" then attackAnims[num] = d.Name end
            end
        end
    end
end)
genv.__FurinaAttackAnims = attackAnims
local blockLog = {}
genv.__FurinaBlockLog = blockLog
local function logBlock(s)
    table.insert(blockLog, 1, ("%.1f %s"):format(os.clock(), s))
    if #blockLog > 30 then table.remove(blockLog) end
end
local lastBlockT = 0
local function tryParry(killer, hpBefore, punchWasReady)
    if not Cfg.AutoParry then return end
    local t0 = os.clock()
    while alive and os.clock() - t0 < 1.1 do
        task.wait(0.03)
        local punch = abilityBtn({ "Punch" })
        local hum = myHum()
        if not punch or not hum then return end
        -- a successful block resets Punch's cooldown; if it was already ready, "no damage taken" is the tell
        local success = (not punchWasReady and btnReady(punch)) or
            (punchWasReady and os.clock() - t0 > 0.35 and hum.Health >= hpBefore - 0.5)
        local kr = rootOf(killer); local r = myRoot()
        if success and kr and r and (kr.Position - r.Position).Magnitude <= 11 then
            faceTowards(kr.Position)
            useAbilitySlot(punch)
            logBlock("parry punch")
            return
        end
    end
end
local function onKillerAnim(killer, track)
    if not Cfg.AutoBlock or myRole() ~= "Survivors" then return end
    local anim = track.Animation
    local num = anim and anim.AnimationId:match("%d+")
    local name = num and attackAnims[num]
    if not name then return end
    local kr, r, hum = rootOf(killer), myRoot(), myHum()
    if not kr or not r or not hum or hum.Health <= 0 then return end
    local d = (kr.Position - r.Position).Magnitude
    if d > Cfg.BlockRange then return end
    if Cfg.BlockFacing and d > 4 then
        local to = (r.Position - kr.Position) * Vector3.new(1, 0, 1)
        if to.Magnitude > 0.1 and kr.CFrame.LookVector:Dot(to.Unit) < 0.2 then return end
    end
    local btn = abilityBtn(BLOCK_NAMES)
    if not btn or not btnReady(btn) or os.clock() - lastBlockT < 0.5 then return end
    lastBlockT = os.clock()
    local punch = abilityBtn({ "Punch" })
    local punchWasReady, hpBefore = btnReady(punch), hum.Health
    task.spawn(function()
        if Cfg.BlockDelay > 0 then task.wait(Cfg.BlockDelay) end
        useAbilitySlot(btn)
        logBlock(("block %s.%s at %.1f studs"):format(killer.Name, name, d))
        tryParry(killer, hpBefore, punchWasReady)
    end)
end
do
    local hooked = {}
    local function hookRig(m)
        if hooked[m] or m == LP.Character then return end
        hooked[m] = true
        task.spawn(function()
            local h = m:WaitForChild("Humanoid", 10)
            local an = h and h:WaitForChild("Animator", 10)
            if not an or not alive or not hooked[m] then return end
            local c = an.AnimationPlayed:Connect(function(tr) pcall(onKillerAnim, m, tr) end)
            hooked[m] = c
        end)
    end
    local function unhook(m)
        local c = hooked[m]
        if typeof(c) == "RBXScriptConnection" then c:Disconnect() end
        hooked[m] = nil
    end
    onCleanup(function() for m in pairs(hooked) do unhook(m) end end)
    task.spawn(function()
        local pf = workspace:WaitForChild("Players", 30)
        local kf = pf and pf:WaitForChild("Killers", 30)
        if not kf or not alive then return end
        for _, m in ipairs(kf:GetChildren()) do hookRig(m) end
        connect(kf.ChildAdded, hookRig)
        connect(kf.ChildRemoved, unhook)
    end)
end

-- Aimbot: silent aim answers the server's GetMousePosition / GetCameraCFrame requests with the target
local function enemyFolder()
    local role = myRole()
    if role == "Survivors" then return teamFolder("Killers") end
    if role == "Killers" then return teamFolder("Survivors") end
end
local function aimPoint(m)
    local part = Cfg.AimPart == "Head" and m:FindFirstChild("Head") or rootOf(m)
    if not part then return end
    local p = part.Position
    local rt = rootOf(m)
    if rt and Cfg.AimPredict > 0 then
        local v = rt.AssemblyLinearVelocity
        p = p + Vector3.new(v.X, math.clamp(v.Y, -20, 20) * 0.5, v.Z) * Cfg.AimPredict
    end
    return p
end
local function screenAim()
    if IS_MOBILE then
        local vp = workspace.CurrentCamera.ViewportSize
        return Vector2.new(vp.X / 2, vp.Y / 2)
    end
    return UIS:GetMouseLocation()
end
local aimTarget, aimT = nil, 0
local function findTarget()
    if os.clock() - aimT < 0.05 and aimTarget and aimTarget.Parent then return aimTarget end
    aimT = os.clock()
    local f, r = enemyFolder(), myRoot()
    local cam = workspace.CurrentCamera
    if not f or not r or not cam then aimTarget = nil return nil end
    local best, bestScore
    local from = screenAim()
    for _, m in ipairs(f:GetChildren()) do
        local h = m:FindFirstChildOfClass("Humanoid"); local rt = rootOf(m)
        if m ~= LP.Character and h and rt and h.Health > 0 then
            local d = (rt.Position - r.Position).Magnitude
            if d <= Cfg.AimMaxDist then
                local score
                if Cfg.AimMode == "Distance" then
                    score = d
                else
                    local sp, on = cam:WorldToViewportPoint(rt.Position)
                    local sd = (Vector2.new(sp.X, sp.Y) - from).Magnitude
                    if on and sd <= Cfg.AimFov then score = sd end
                end
                if score and (not bestScore or score < bestScore) then best, bestScore = m, score end
            end
        end
    end
    aimTarget = best
    return best
end
genv.__FurinaAimTarget = function() return findTarget() end
do
    local GPMP = try(function() return require(RS.Systems.Player.Miscellaneous.GetPlayerMousePosition) end)
    if type(GPMP) == "table" and type(GPMP.GetMousePos) == "function" then
        local origPos, origCam = GPMP.GetMousePos, GPMP.GetCameraCFrame
        GPMP.GetMousePos = function(self, ...)
            if alive and Cfg.SilentAim then
                local t = findTarget()
                local p = t and aimPoint(t)
                if p then return p end
            end
            return origPos(self, ...)
        end
        if type(origCam) == "function" then
            GPMP.GetCameraCFrame = function(self, ...)
                if alive and Cfg.SilentAim then
                    local t = findTarget()
                    local p = t and aimPoint(t)
                    local cam = workspace.CurrentCamera
                    if p and cam then return CFrame.lookAt(cam.CFrame.Position, p) end
                end
                return origCam(self, ...)
            end
        end
        onCleanup(function()
            GPMP.GetMousePos = origPos
            if origCam then GPMP.GetCameraCFrame = origCam end
        end)
    end
end
do
    local circle
    if Drawing and Drawing.new then
        local ok, c = pcall(Drawing.new, "Circle")
        if ok then
            circle = c
            circle.Thickness = 1.5; circle.NumSides = 64; circle.Filled = false
            circle.Transparency = 0.8; circle.Color = Color3.fromRGB(232, 199, 122)
            circle.Visible = false
            onCleanup(function() pcall(function() circle:Remove() end) end)
        end
    end
    local autoRotOff = false
    local function restoreRotate()
        if autoRotOff then
            autoRotOff = false
            local h = myHum(); if h then h.AutoRotate = true end
        end
    end
    onCleanup(function()
        pcall(function() RunService:UnbindFromRenderStep("FurinaAim") end)
        restoreRotate()
    end)
    RunService:BindToRenderStep("FurinaAim", Enum.RenderPriority.Camera.Value + 2, function(dt)
        if not alive then return end
        local cam = workspace.CurrentCamera
        local aiming = Cfg.SilentAim or Cfg.CamLock
        if circle then
            local show = aiming and Cfg.ShowFov and Cfg.AimMode ~= "Distance" and enemyFolder() ~= nil
            circle.Visible = show
            if show then circle.Position = screenAim(); circle.Radius = Cfg.AimFov end
        end
        local t = (aiming or Cfg.FaceTarget) and findTarget()
        local p = t and aimPoint(t)
        if Cfg.CamLock and p and cam then
            local want = CFrame.lookAt(cam.CFrame.Position, p)
            local a = math.clamp(Cfg.AimSmooth, 0.05, 1)
            cam.CFrame = cam.CFrame:Lerp(want, 1 - (1 - a) ^ (dt * 60))
        end
        local r, h = myRoot(), myHum()
        if Cfg.FaceTarget and p and r and h and (p - r.Position).Magnitude <= Cfg.FaceRange then
            if not autoRotOff then autoRotOff = true; h.AutoRotate = false end
            local flat = Vector3.new(p.X, r.Position.Y, p.Z)
            if (flat - r.Position).Magnitude > 0.5 then
                r.CFrame = CFrame.lookAt(r.Position, flat)
            end
        else
            restoreRotate()
        end
    end)
end
do
    local savedZoom = LP.CameraMaxZoomDistance
    local fovBound = false
    local function bindFov(on)
        if on and not fovBound then
            fovBound = true
            RunService:BindToRenderStep("FurinaFov", Enum.RenderPriority.Camera.Value + 1, function()
                local cam = workspace.CurrentCamera
                if cam and Cfg.FovOn then setIf(cam, "FieldOfView", Cfg.Fov) end
            end)
        elseif not on and fovBound then
            fovBound = false
            pcall(function() RunService:UnbindFromRenderStep("FurinaFov") end)
        end
    end
    onCleanup(function() bindFov(false); pcall(function() LP.CameraMaxZoomDistance = savedZoom end) end)
    task.spawn(function()
        local zoomWas = false
        while alive do
            bindFov(Cfg.FovOn)
            if Cfg.ZoomUnlock then
                if not zoomWas then savedZoom = LP.CameraMaxZoomDistance end
                setIf(LP, "CameraMaxZoomDistance", 60)
            elseif zoomWas then
                pcall(function() LP.CameraMaxZoomDistance = savedZoom end)
            end
            zoomWas = Cfg.ZoomUnlock
            task.wait(0.5)
        end
    end)
end
local ovGui = Instance.new("ScreenGui")
ovGui.Name = HttpService:GenerateGUID(false):sub(1, 8)
ovGui.ResetOnSpawn = false
ovGui.DisplayOrder = 50
safeParent(ovGui)
onCleanup(function() ovGui:Destroy() end)
local ovLabel = Instance.new("TextLabel")
ovLabel.AnchorPoint = Vector2.new(0.5, 0)
ovLabel.Position = UDim2.new(0.5, 0, 0, 4)
ovLabel.Size = UDim2.fromOffset(IS_MOBILE and 330 or 460, 22)
ovLabel.BackgroundColor3 = Color3.fromRGB(11, 26, 51)
ovLabel.BackgroundTransparency = 0.25
ovLabel.TextColor3 = Color3.fromRGB(234, 246, 255)
ovLabel.Font = Enum.Font.GothamBold
ovLabel.TextSize = IS_MOBILE and 11 or 13
ovLabel.Visible = false
ovLabel.Parent = ovGui
Instance.new("UICorner", ovLabel).CornerRadius = UDim.new(0, 6)
local ovStroke = Instance.new("UIStroke", ovLabel)
ovStroke.Color = Color3.fromRGB(232, 199, 122)
ovStroke.Transparency = 0.4
local frames = 0
connect(RunService.RenderStepped, function() frames += 1 end)
task.spawn(function()
    local lastT, lastDone, lastTotal = os.clock(), nil, 0
    while alive do
        task.wait(0.5)
        local now = os.clock()
        local fps = frames / math.max(0.01, now - lastT)
        frames, lastT = 0, now
        local info = roundInfo()
        if info.gensTotal > 0 then
            if lastDone and info.gensDone > lastDone and Cfg.GenAlerts then
                if info.gensDone >= info.gensTotal then
                    notify("Generators", "All generators done - head for the exits!", 5)
                else
                    notify("Generators", ("Generator finished (%d/%d)"):format(info.gensDone, info.gensTotal), 3)
                end
            end
            lastDone = info.gensDone
        else
            lastDone = nil
        end
        lastTotal = info.gensTotal
        ovLabel.Visible = Cfg.Overlay
        if Cfg.Overlay then
            local ping = (try(function() return LP:GetNetworkPing() end) or 0) * 1000
            local txt = ("FPS %d  |  Ping %dms  |  Gens %d/%d  |  Alive %d  |  %s"):format(
                fps + 0.5, ping, info.gensDone, info.gensTotal, info.survivors,
                info.gensTotal > 0 and ("Killer: " .. info.killer:sub(1, 26)) or "Lobby")
            if ovLabel.Text ~= txt then ovLabel.Text = txt end
        end
    end
end)
task.spawn(function()
    while alive do
        task.wait(1)
        if Cfg.AutoSpectate and myRole() == "Spectating" then
            local cam = workspace.CurrentCamera
            local subj = cam.CameraSubject
            local mine = myHum()
            local onKiller = false
            local kf = teamFolder("Killers")
            if subj and subj:IsA("Humanoid") and kf and subj.Parent and subj.Parent.Parent == kf and subj.Health > 0 then
                onKiller = true
            end
            if not onKiller and (subj == nil or subj == mine or (subj:IsA("Humanoid") and subj.Health <= 0)) then
                for _, m in ipairs(kf and kf:GetChildren() or {}) do
                    local h = m:FindFirstChildOfClass("Humanoid")
                    if h and h.Health > 0 then cam.CameraSubject = h break end
                end
            end
        end
    end
end)
------------------------------------------------------------------------------------------------------
-- Auto update: the GitHub copy is the source of truth. Every few minutes (and on demand) read its
-- version line; if it is newer, notify, and with Auto Update on install it between rounds.
------------------------------------------------------------------------------------------------------
local REPO = "banglajunaid9-ship-it/furina-hub"
local UPDATE_FILE = "forsaken_hub.luau"
-- raw.githubusercontent.com/<repo>/main/... can serve a stale copy for minutes after a push, so ask the
-- API for the newest commit and download that exact revision (falls back to main if the API is down)
local function fetchLatestSource()
    -- the time parameter matters: without it HttpGet can hand back a cached (old) answer
    local okApi, body = pcall(function()
        return game:HttpGet(("https://api.github.com/repos/%s/commits/main?per_page=1&_=%d"):format(REPO, os.time()))
    end)
    local sha = okApi and type(body) == "string" and body:match('"sha"%s*:%s*"(%x+)"')
    local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, sha or "main", UPDATE_FILE)
    return pcall(function() return game:HttpGet(url) end)
end
local function versionNumber(v)
    local major, minor = tostring(v or ""):match("(%d+)%.(%d+)")
    return major and (tonumber(major) * 1000 + tonumber(minor)) or 0
end
local checkForUpdate
local Update = { latest = nil, src = nil, lastCheck = 0, installing = false, notified = nil }
local updateLabel -- set once the Misc tab exists
local function setUpdateText(t) if updateLabel then pcall(function() updateLabel:Set(t) end) end end
local function installUpdate()
    if Update.installing or not Update.src then return end
    Update.installing = true
    local fn, err = loadstring(Update.src, "=FurinaHub")
    if not fn then
        Update.installing = false
        notify("Auto Update", "Downloaded update failed to load: " .. tostring(err), 6)
        return
    end
    notify("Auto Update", ("Installing v%s..."):format(Update.latest), 3)
    task.delay(1, function()
        -- the new copy unloads this one first (it calls __FurinaHubUnload), then rebuilds the menu
        local ok, e = pcall(fn)
        if not ok then warn("[FurinaHub] update failed: " .. tostring(e)) end
    end)
end
checkForUpdate = function(manual)
    Update.lastCheck = os.clock()
    local ok, src = fetchLatestSource()
    if not ok or type(src) ~= "string" then
        setUpdateText("Version " .. genv.__FurinaVersion .. " - could not reach GitHub")
        if manual then notify("Updates", "Could not reach GitHub.", 4) end
        return
    end
    local latest = src:match("Furina Hub v(%d+%.%d+)")
    Update.latest = latest
    if latest and versionNumber(latest) > versionNumber(genv.__FurinaVersion) then
        Update.src = src
        setUpdateText(("Version %s - update v%s available"):format(genv.__FurinaVersion, latest))
        if Update.notified ~= latest or manual then
            Update.notified = latest
            notify("Update available", ("Furina Hub v%s is out (you have v%s).%s"):format(latest, genv.__FurinaVersion,
                Cfg.AutoUpdate and " It installs at the end of the round." or " Turn on Auto Update or re-run the loader."), 6)
        end
    else
        Update.src = nil
        setUpdateText("Version " .. genv.__FurinaVersion .. " - up to date")
        if manual then notify("Updates", "You have the latest version (v" .. genv.__FurinaVersion .. ").", 4) end
    end
end
genv.__FurinaCheckUpdate = checkForUpdate
task.spawn(function()
    task.wait(8)
    while alive do
        if os.clock() - Update.lastCheck > 300 then pcall(checkForUpdate, false) end
        -- install only when it can't interrupt anything: not in a round, not repairing
        if Cfg.AutoUpdate and Update.src and myRole() ~= "Survivors" and myRole() ~= "Killers" then
            installUpdate()
            break
        end
        task.wait(5)
    end
end)

------------------------------------------------------------------------------------------------------
-- Settings file (FurinaHub/forsaken.json). On first run it migrates the old Maclib autosave.
------------------------------------------------------------------------------------------------------
local CFG_FILE = "FurinaHub/forsaken.json"
local function encodeVal(v)
    if typeof(v) == "Color3" then return { __c = { v.R, v.G, v.B } } end
    return v
end
local function decodeVal(v)
    if type(v) == "table" and type(v.__c) == "table" then return Color3.new(v.__c[1], v.__c[2], v.__c[3]) end
    return v
end
local function saveCfg()
    if not writefile then return false end
    local t = {}
    for k, v in pairs(Cfg) do t[k] = encodeVal(v) end
    return pcall(function()
        if makefolder and isfolder and not isfolder("FurinaHub") then makefolder("FurinaHub") end
        writefile(CFG_FILE, HttpService:JSONEncode(t))
    end)
end
local function loadCfg()
    if not (isfile and readfile) then return false end
    if isfile(CFG_FILE) then
        local ok, t = pcall(function() return HttpService:JSONDecode(readfile(CFG_FILE)) end)
        if ok and type(t) == "table" then
            for k, v in pairs(t) do
                local d = decodeVal(v)
                if Cfg[k] ~= nil and typeof(d) == typeof(Cfg[k]) then Cfg[k] = d end
            end
            return true
        end
    end
    -- one-time migration from the Maclib build's autosave
    for _, old in ipairs({ "FurinaHub/settings/autosave.json", "ForsakenHub/settings/autosave.json" }) do
        if isfile(old) then
            local ok, t = pcall(function() return HttpService:JSONDecode(readfile(old)) end)
            if ok and type(t) == "table" and type(t.objects) == "table" then
                for _, o in ipairs(t.objects) do
                    local k = o.flag
                    if k and Cfg[k] ~= nil then
                        if o.type == "Toggle" and type(o.state) == "boolean" then Cfg[k] = o.state
                        elseif o.type == "Slider" and tonumber(o.value) then Cfg[k] = tonumber(o.value)
                        elseif o.type == "Colorpicker" and type(o.color) == "string" then
                            pcall(function() Cfg[k] = Color3.fromHex(o.color) end)
                        end
                    end
                end
                return true, "migrated"
            end
        end
    end
    return false
end
local restored, how = loadCfg()

------------------------------------------------------------------------------------------------------
-- UI: FurinaUI (workspace copy wins so edits can be tested without pushing; repo copy otherwise)
------------------------------------------------------------------------------------------------------
local FURINA_UI_URL = "https://raw.githubusercontent.com/banglajunaid9-ship-it/furina-hub/main/furina_ui.luau"
UI = (function()
    local src
    pcall(function()
        if isfile and readfile and isfile("FurinaHub/furina_ui.luau") then src = readfile("FurinaHub/furina_ui.luau") end
    end)
    if not src then pcall(function() src = game:HttpGet(FURINA_UI_URL) end) end
    if not src then return nil end
    local ok, lib = pcall(function() return loadstring(src)() end)
    if ok and type(lib) == "table" and lib.CreateWindow then return lib end
    warn("[FurinaHub] FurinaUI failed to load: " .. tostring(lib))
end)()
assert(UI, "[FurinaHub] could not load FurinaUI (FurinaHub/furina_ui.luau or the repo URL)")
genv.__FurinaUI = UI

local Window = UI:CreateWindow({
    Name = "Furina Hub",
    Subtitle = "Forsaken",
    LogoID = "6031097225",
    LoadingEnabled = false,
    KeySystem = false,
})
genv.__FurinaWindow = Window

local Toggles, Sliders = {}, {}
local function tab(name, icon) return Window:CreateTab({ Name = name, Icon = icon, ShowTitle = true }) end
local function head(t, text) t:CreateSection(text) end
local function note(t, text) return t:CreateLabel({ Text = text, Style = 2 }) end
local function tog(t, name, key, desc, cb)
    Toggles[key] = t:CreateToggle({
        Name = name, Description = desc, CurrentValue = Cfg[key] == true,
        Callback = function(v) Cfg[key] = v if cb then cb(v) end end,
    })
    return Toggles[key]
end
-- scale lets a slider show whole numbers for a decimal setting (shown = Cfg[key] * scale)
local function sld(t, name, key, lo, hi, inc, suffix, scale, cb)
    scale = scale or 1
    Sliders[key] = {
        scale = scale,
        obj = t:CreateSlider({
            Name = name, Range = { lo, hi }, Increment = inc or 1, Suffix = suffix,
            CurrentValue = math.clamp(math.floor(Cfg[key] * scale + 0.5), lo, hi),
            Callback = function(v) Cfg[key] = v / scale if cb then cb(v / scale) end end,
        }),
    }
end
local function picker(t, name, key)
    t:CreateColorPicker({ Name = name, Color = Cfg[key], Callback = function(c) Cfg[key] = c end })
end
local function bind(t, name, key, desc)
    t:CreateBind({ Name = name, Description = desc, CurrentBind = Cfg[key],
        OnChangedCallback = function(kc) if typeof(kc) == "EnumItem" then Cfg[key] = kc.Name end end })
end

-- Main ------------------------------------------------------------------------------------------------
local MainTab = tab("Main", "power")
head(MainTab, "Safety")
tog(MainTab, "Safe Mode", "SafeMode", "No teleports, solves take 2s+ and look human, kill aura capped at 7.5 studs / 0.45s, prompts only in real range")
tog(MainTab, "Anti-AFK", "AntiAFK")
head(MainTab, "Keys")
bind(MainTab, "Panic Key", "PanicKey", "Unloads the whole hub")
note(MainTab, "RightShift opens and closes the menu (change it in the menu's Settings). Ability cooldowns are checked by the server, so they cannot be removed.")

-- Stats -------------------------------------------------------------------------------------------------
local StatsTab = tab("Stats", "info")
head(StatsTab, "This Round")
local roundLabel = note(StatsTab, "Round: ...")
tog(StatsTab, "Auto Spectate Killer When Out", "AutoSpectate")
StatsTab:CreateButton({ Name = "Spectate Next Player", Callback = function() spectateNext(false) end })
StatsTab:CreateButton({ Name = "Spectate Killer", Callback = function() spectateNext(true) end })
StatsTab:CreateButton({ Name = "Camera Back To Me", Callback = spectateSelf })
head(StatsTab, "This Session")
local statLabel = note(StatsTab, "Stats: ...")
StatsTab:CreateButton({ Name = "Reset Stats", Callback = function()
    Stats.startT, Stats.puzzles, Stats.hits = os.clock(), 0, 0
    Stats.roundsSurvivor, Stats.roundsKiller, Stats.moneyStart = 0, 0, money()
    Stats.wins, Stats.streak, Stats.bestStreak = 0, 0, 0
end })

-- Survivor ----------------------------------------------------------------------------------------------
local SurvTab = tab("Survivor", "move")
head(SurvTab, "Generators")
tog(SurvTab, "Auto Solve Puzzles", "AutoGen", "Solves Flow, Connect, Lock and Gear puzzles for you")
SurvTab:CreateDropdown({ Name = "Solve Speed", Description = "Human: 2s+ per puzzle (safest). Fast: about twice as quick, never under 0.9s",
    Options = { "Human", "Fast" }, CurrentOption = { Cfg.SolveSpeed }, MultipleOptions = false,
    Callback = function(o) Cfg.SolveSpeed = type(o) == "table" and o[1] or o end })
sld(SurvTab, "Solve Delay", "GenDelay", 0, 6000, 100, " ms", 1000)
tog(SurvTab, "Auto Enter Nearby Generator", "AutoEnterGen")
SurvTab:CreateButton({ Name = "Teleport To Nearest Generator", Description = "Only with Safe Mode off", Callback = function()
    if Cfg.SafeMode then notify("Safe Mode", "Teleport is blocked while Safe Mode is on.") return end
    local g = nearestGen()
    local r = myRoot()
    if not g or not r then notify("Generators", "No unfinished generator found.") return end
    local main = g:FindFirstChild("Main")
    local pos = (main and main.Position or g:GetPivot().Position)
    r.CFrame = CFrame.new(pos + (g:GetPivot().LookVector * 4) + Vector3.new(0, 3, 0), pos)
end })
head(SurvTab, "Survival")
tog(SurvTab, "Infinite Stamina", "InfStamina", nil, function(v) if not v and Sprinting then Sprinting.StaminaLossDisabled = false end end)
tog(SurvTab, "Killer Nearby Warning", "KillerWarn")
sld(SurvTab, "Warning Distance", "WarnDist", 20, 200, 5, " studs")
tog(SurvTab, "Auto Heal (Medkit when low)", "AutoHeal")
sld(SurvTab, "Heal Below", "HealAt", 15, 90, 5, "% HP")
tog(SurvTab, "Low Health Alert", "LowHpAlert")
tog(SurvTab, "Danger Vignette (red edges)", "DangerVignette")
sld(SurvTab, "Vignette Range", "VignetteDist", 20, 120, 5, " studs")
head(SurvTab, "Items")
tog(SurvTab, "Auto Collect Gears", "AutoGears")
tog(SurvTab, "Auto Pickup Items", "AutoPickup")
sld(SurvTab, "Pickup Range", "PickupDist", 5, 25, 1, " studs")

-- Event (Forsakeween) --------------------------------------------------------------------------------
local EventTab = tab("Event", "luck")
head(EventTab, "Candy")
local candyLabel = note(EventTab, "Candy: ...")
tog(EventTab, "Auto Collect Nearby Candy", "CandyCollect", "Picks up any candy you walk near (within 8 studs). It never moves you")
tog(EventTab, "Candy ESP", "EspCandy")
note(EventTab, "Candies are first come, first served: once anyone picks one up it is gone for everyone. Each one is a Trick (debuff) or a Treat (buff).")

-- Killer ------------------------------------------------------------------------------------------------
local KillTab = tab("Killer", "combat")
head(KillTab, "Killer")
tog(KillTab, "Kill Aura", "KillAura", "Swings your attack only when a survivor will still be in range as the swing lands")sld(KillTab, "Aura Range", "AuraRange", 4, 16, 1, " studs")
sld(KillTab, "Attack Interval", "AuraDelay", 100, 1500, 50, " ms", 1000)
tog(KillTab, "Auto Chase Nearest Survivor", "AutoChase")
sld(KillTab, "Attack Ability Slot", "AttackSlot", 1, 4, 1)
note(KillTab, "Safe Mode caps the aura at 7.5 studs and 450 ms. Slot 1 is your normal attack (M1).")

-- Combat ------------------------------------------------------------------------------------------------
local CombatTab = tab("Combat", "hitbox")
head(CombatTab, "Auto Block")
tog(CombatTab, "Perfect Auto Block", "AutoBlock", "Blocks the instant a killer starts an attack swing near you (Guest 1337's Block)")
sld(CombatTab, "Block Range", "BlockRange", 6, 25, 1, " studs")
tog(CombatTab, "Only When Killer Faces Me", "BlockFacing", "Saves your Block cooldown for attacks that can actually hit you")
sld(CombatTab, "Block Delay", "BlockDelay", 0, 300, 10, " ms", 1000)
tog(CombatTab, "Auto Parry Punch", "AutoParry", "Throws Punch right after a successful block, which turns it into a Parry")
note(CombatTab, "Block lasts 1s and has a long cooldown, so keep the delay at 0 unless you lag. Blocking a non-basic attack breaks the block but still cuts the damage.")
head(CombatTab, "Aimbot")
tog(CombatTab, "Silent Aim", "SilentAim", "Aimed abilities (guns, projectiles, Corrupt Energy, etc.) go to the target without moving your camera")
tog(CombatTab, "Camera Lock", "CamLock", "Turns your camera onto the target")
bind(CombatTab, "Camera Lock Key", "AimKey", "Turns Camera Lock on and off")
tog(CombatTab, "Face Target (melee)", "FaceTarget", "Turns your character toward the target when close, so swings and punches land")
sld(CombatTab, "Face Range", "FaceRange", 5, 40, 1, " studs")
CombatTab:CreateDropdown({ Name = "Target By", Description = "Crosshair: closest to your mouse (center of screen on mobile) inside the FOV circle. Distance: closest to you",
    Options = { "Crosshair", "Distance" }, CurrentOption = { Cfg.AimMode }, MultipleOptions = false,
    Callback = function(o) Cfg.AimMode = type(o) == "table" and o[1] or o end })
CombatTab:CreateDropdown({ Name = "Aim Part", Options = { "Torso", "Head" }, CurrentOption = { Cfg.AimPart }, MultipleOptions = false,
    Callback = function(o) Cfg.AimPart = type(o) == "table" and o[1] or o end })
sld(CombatTab, "FOV Radius", "AimFov", 40, 600, 10, " px")
tog(CombatTab, "Show FOV Circle" .. (Drawing and "" or " (PC only)"), "ShowFov")
sld(CombatTab, "Smoothness", "AimSmooth", 5, 100, 5, "%", 100)
sld(CombatTab, "Prediction", "AimPredict", 0, 400, 10, " ms", 1000)
sld(CombatTab, "Max Distance", "AimMaxDist", 20, 400, 10, " studs")
note(CombatTab, "Targets killers when you are a survivor and survivors when you are the killer. Smoothness 100% snaps instantly.")

-- ESP ---------------------------------------------------------------------------------------------------
local EspTab = tab("ESP", "esp")
head(EspTab, "Targets")
tog(EspTab, "Killers", "EspKillers")
tog(EspTab, "Survivors", "EspSurvivors")
tog(EspTab, "Generators", "EspGens", "Shows real repair progress and the puzzle type")
tog(EspTab, "Items", "EspItems")
tog(EspTab, "Gears", "EspGears")
tog(EspTab, "Candy", "EspCandy")
tog(EspTab, "Tracers: Killers" .. (Drawing and "" or " (PC only)"), "TracerKillers")
tog(EspTab, "Tracers: Survivors" .. (Drawing and "" or " (PC only)"), "TracerSurvivors")
head(EspTab, "Labels")
tog(EspTab, "Show Names", "EspNames")
tog(EspTab, "Show Distance", "EspDistance")
tog(EspTab, "Show Health", "EspHealth")
head(EspTab, "Colors")
picker(EspTab, "Killer", "KillerColor")
picker(EspTab, "Survivor", "SurvivorColor")
picker(EspTab, "Generator", "GenColor")
picker(EspTab, "Item", "ItemColor")
picker(EspTab, "Gear", "GearColor")
picker(EspTab, "Candy", "CandyColor")

-- Visuals -----------------------------------------------------------------------------------------------
local VisTab = tab("Visuals", "visuals")
head(VisTab, "World")
tog(VisTab, "Fullbright", "Fullbright", nil, function() pcall(applyLighting) end)
tog(VisTab, "No Fog", "NoFog", nil, function() pcall(applyLighting) end)
head(VisTab, "Camera")
tog(VisTab, "Custom FOV", "FovOn")
sld(VisTab, "Field Of View", "Fov", 60, 120, 1)
tog(VisTab, "Unlock Camera Zoom", "ZoomUnlock")
head(VisTab, "HUD")
tog(VisTab, "Stats Overlay (FPS / ping / gens)", "Overlay")
tog(VisTab, "Generator Alerts", "GenAlerts")

-- Misc --------------------------------------------------------------------------------------------------
local MiscTab = tab("Misc", "misc")
head(MiscTab, "Performance")
tog(MiscTab, "FPS Boost (low graphics)", "FpsBoost", "Shadows, effects and quality down. Restored when you turn it off", setFpsBoost)
MiscTab:CreateButton({ Name = "Unlock FPS", Callback = function()
    if setfpscap then setfpscap(999); notify("Misc", "FPS cap removed.") else notify("Misc", "Your executor has no setfpscap.") end
end })
head(MiscTab, "Server")
tog(MiscTab, "Auto Rejoin On Disconnect", "AutoRejoin")
MiscTab:CreateButton({ Name = "Server Hop (emptiest server)", Callback = function()
    local ok, info = serverHop(true)
    notify("Server Hop", ok and ("Joining a server with " .. info) or ("Failed: " .. tostring(info)), 4)
end })
MiscTab:CreateButton({ Name = "Server Hop (random server)", Callback = function()
    local ok, info = serverHop(false)
    notify("Server Hop", ok and ("Joining a server with " .. info) or ("Failed: " .. tostring(info)), 4)
end })
MiscTab:CreateButton({ Name = "Rejoin Server", Callback = function()
    TeleportSvc:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
end })
head(MiscTab, "Updates")
updateLabel = note(MiscTab, "Version " .. genv.__FurinaVersion .. " - checking GitHub...")
tog(MiscTab, "Auto Update", "AutoUpdate", "Installs new versions from GitHub by itself, only while you are in the lobby or spectating (never mid-round)")
MiscTab:CreateButton({ Name = "Check For Updates Now", Callback = function() task.spawn(checkForUpdate, true) end })
head(MiscTab, "Hub")
tog(MiscTab, "Floating Menu Button (mobile)", "FloatingButtons", "A menu button you can drag anywhere",
    function(v) if genv.__FurinaFloating then genv.__FurinaFloating.Enabled = v end end)
MiscTab:CreateButton({ Name = "Save Settings Now", Callback = function()
    local ok = saveCfg()
    notify("Settings", ok and "Saved to FurinaHub/forsaken.json" or "Could not save (no writefile)", 3)
end })
MiscTab:CreateButton({ Name = "Unload Hub", Description = "Turns everything off and removes the menu", Danger = true, Callback = function() unload() end })

-- live labels ------------------------------------------------------------------------------------------
local function fmtTime(t)
    t = math.floor(t)
    return ("%dh %02dm %02ds"):format(t // 3600, (t % 3600) // 60, t % 60)
end
task.spawn(function()
    local lastRound, lastStats, lastCandy
    local tick2 = 0
    while alive do
        tick2 += 1
        if tick2 % 3 == 0 then
            local ok, info = pcall(roundInfo)
            if ok then
                local r = ("Killer: %s  |  Survivors alive: %d  |  Generators: %d/%d  |  You: %s"):format(
                    info.killer, info.survivors, info.gensDone, info.gensTotal, tostring(myRole()))
                if r ~= lastRound then pcall(function() roundLabel:Set(r) end); lastRound = r end
            end
            local m = money()
            if m and not Stats.moneyStart then Stats.moneyStart = m end -- leaderstats can load late
            local earned = (m and Stats.moneyStart) and (m - Stats.moneyStart) or 0
            local s = ("Money +%d (now %s)  |  Rounds: %d survivor, %d killer  |  Won: %d (streak %d, best %d)  |  Puzzles solved: %d  |  Killer hits: %d  |  Session %s"):format(
                earned, m and tostring(m) or "?",
                Stats.roundsSurvivor, Stats.roundsKiller, Stats.wins or 0, Stats.streak or 0, Stats.bestStreak or 0,
                Stats.puzzles, Stats.hits, fmtTime(os.clock() - Stats.startT))
            if s ~= lastStats then pcall(function() statLabel:Set(s) end); lastStats = s end
            local cb = candyBalance()
            if cb and not Stats.candyStart then Stats.candyStart = cb end
            local onMap = 0
            for c in pairs(Candies) do if c.Parent then onMap += 1 end end
            local ct = ("Candy: %s  (+%d this session)  |  On this map: %d"):format(cb and tostring(cb) or "?",
                (cb and Stats.candyStart) and (cb - Stats.candyStart) or 0, onMap)
            if ct ~= lastCandy then pcall(function() candyLabel:Set(ct) end); lastCandy = ct end
        end
        task.wait(0.4)
    end
end)

-- keys (FurinaUI binds only record the key; the hub listens for them) -------------------------------
connect(UIS.InputBegan, function(input, gpe)
    if gpe or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local name = input.KeyCode.Name
    if name == Cfg.PanicKey then unload() end
    if name == Cfg.AimKey then
        Cfg.CamLock = not Cfg.CamLock
        if Toggles.CamLock then pcall(function() Toggles.CamLock:Set(Cfg.CamLock) end) end
        notify("Camera Lock", Cfg.CamLock and "On" or "Off", 2)
    end
end)

-- floating buttons (mobile) -------------------------------------------------------------------------
do
    local gui = Instance.new("ScreenGui")
    gui.Name = HttpService:GenerateGUID(false)
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999
    gui.Enabled = Cfg.FloatingButtons
    safeParent(gui)
    genv.__FurinaFloating = gui
    onCleanup(function() gui:Destroy(); genv.__FurinaFloating = nil end)
    local function makeButton(text, pos, color)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(IS_MOBILE and 56 or 44, IS_MOBILE and 56 or 44)
        b.AnchorPoint = Vector2.new(0.5, 0.5)
        b.Position = pos
        b.BackgroundColor3 = color
        b.BackgroundTransparency = 0.08
        b.Text = text
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.GothamBold
        b.TextSize = IS_MOBILE and 24 or 18
        b.AutoButtonColor = true
        b.Parent = gui
        Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
        local stroke = Instance.new("UIStroke", b)
        stroke.Color = Furina.gold
        stroke.Thickness = 2
        local dragging, moved, startIn, startPos = false, false, nil, nil
        connect(b.InputBegan, function(i)
            if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging, moved, startIn, startPos = true, false, i.Position, b.Position
            end
        end)
        connect(UIS.InputChanged, function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
                local d = i.Position - startIn
                if d.Magnitude > 10 then moved = true end
                if moved then
                    b.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
                end
            end
        end)
        connect(UIS.InputEnded, function(i)
            if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)
        return b, function() return moved end
    end
    local menuBtn, menuMoved = makeButton("F", UDim2.new(0, 60, 0.45, 0), Furina.base)
    menuBtn.TextColor3 = Furina.gold
    connect(menuBtn.Activated, function()
        if menuMoved() then return end
        pcall(function() UI:Toggle() end)
    end)
end

-- autosave: a moment after any setting changes, and once more on unload ------------------------------
local function cfgFingerprint()
    local parts = {}
    for k, v in pairs(Cfg) do
        if typeof(v) == "Color3" then v = v:ToHex() end
        table.insert(parts, k .. "=" .. tostring(v))
    end
    table.sort(parts)
    return table.concat(parts, ";")
end
task.spawn(function()
    local last = cfgFingerprint()
    local changedAt
    while alive do
        task.wait(0.5)
        local fp = cfgFingerprint()
        if fp ~= last then last = fp; changedAt = os.clock() end
        if changedAt and os.clock() - changedAt > 1 then
            changedAt = nil
            local ok, err = saveCfg()
            if not ok then warn("[FurinaHub] autosave failed: " .. tostring(err)) end
        end
    end
end)
table.insert(cleanups, 1, saveCfg) -- runs last on unload: final save

-- apply restored settings that need a side effect (toggles do not fire callbacks at creation)
if Cfg.FpsBoost then setFpsBoost(true) end
pcall(applyLighting)

genv.__FurinaStats = Stats
genv.__FurinaSaveCfg = saveCfg
if Window.Ready then Window:Ready() end
notify("Furina Hub", (IS_MOBILE and "Loaded. Tap F for the menu." or
    ("Loaded. RightShift = menu, %s = panic."):format(Cfg.PanicKey))
    .. (how == "migrated" and " Your old settings were carried over." or (restored and " Settings restored." or "")), 6)
