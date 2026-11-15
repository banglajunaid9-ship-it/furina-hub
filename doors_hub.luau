--[[
    VOID HUB - DOORS (Hotel+)
    UI: Maclib  |  Toggle menu: RightControl
    Works standalone (loadstring/execute) or under Real's live-reload (uses STATE when present).
]]

---------------------------------------------------------------------------
-- lifecycle (reload-safe)
---------------------------------------------------------------------------
local ENV = getgenv and getgenv() or _G
if ENV.__VoidHubUnload then pcall(ENV.__VoidHubUnload) end

local conns, cleanups, alive = {}, {}, true
local function connect(sig, fn) local c = sig:Connect(fn); table.insert(conns, c); return c end
local function onCleanup(fn) table.insert(cleanups, fn) end
local function unload()
    if not alive then return end
    alive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
    table.clear(conns); table.clear(cleanups)
end
ENV.__VoidHubUnload = unload
if STATE and STATE.onCleanup then STATE.onCleanup(unload) end

---------------------------------------------------------------------------
-- services
---------------------------------------------------------------------------
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local Lighting     = game:GetService("Lighting")
local RS           = game:GetService("ReplicatedStorage")
local PFS          = game:GetService("PathfindingService")
local LP           = Players.LocalPlayer
local Rooms        = workspace:WaitForChild("CurrentRooms")
local GameData     = RS:WaitForChild("GameData")

local function char() return LP.Character end
local function hrp() local c = char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function hum() local c = char(); return c and c:FindFirstChildOfClass("Humanoid") end

local GuiRoot = (gethui and gethui()) or game:GetService("CoreGui")

---------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------
local S = {
    -- esp
    EntityESP = true, DoorESP = true, KeyESP = true, ItemESP = false,
    GoldESP = false, HideESP = false, ShowDistance = true,
    -- alerts
    EntityAlerts = true, AlertSound = true,
    -- player
    SpeedBoost = 0, Fullbright = false, NoFog = false, FOV = 70,
    -- qol
    InstantPrompts = true, PromptReach = 1,
    AutoLoot = false, LootDrawers = true, LootGold = true, LootItems = true, LootKeys = true,
    AntiScreech = true, AntiHalt = true, AutoHide = false,
    -- farm
    AutoWalk = false, AutoOpenDoors = true, FarmSpeed = 6, FarmNoclip = false, PhaseProps = false, NoCamShake = false,
}

ENV.VoidHubSettings = S
-- these always rubber-band on DOORS' server: permanently disabled (even if an old saved config turns them on)
task.spawn(function()
    while alive do
        S.FarmNoclip, S.PhaseProps = false, false
        S.FarmSpeed = math.clamp(S.FarmSpeed or 6, 0, 6)
        S.SpeedBoost = math.clamp(S.SpeedBoost or 0, 0, 6)
        task.wait(0.5)
    end
end)

local COLORS = {
    Entity = Color3.fromRGB(255, 60, 60),
    Door   = Color3.fromRGB(80, 200, 255),
    Locked = Color3.fromRGB(255, 160, 40),
    Key    = Color3.fromRGB(255, 230, 60),
    Item   = Color3.fromRGB(120, 255, 140),
    Gold   = Color3.fromRGB(255, 200, 0),
    Hide   = Color3.fromRGB(190, 120, 255),
}

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()

local Window = MacLib:Window({
    Title = "VOID HUB",
    Subtitle = "DOORS | v1.0",
    Size = UDim2.fromOffset(868, 600),
    DragStyle = 1,
    DisabledWindowControls = {},
    ShowUserInfo = true,
    Keybind = Enum.KeyCode.RightControl,
    AcrylicBlur = true,
})
onCleanup(function() pcall(function() Window:Unload() end) end)

local function notify(title, desc, life)
    pcall(function() Window:Notify({ Title = title, Description = desc, Lifetime = life or 4 }) end)
end

---------------------------------------------------------------------------
-- ESP
---------------------------------------------------------------------------
local espFolder = Instance.new("Folder")
espFolder.Name = "VH_" .. tostring(math.random(1e6))
espFolder.Parent = GuiRoot
onCleanup(function() espFolder:Destroy() end)

local tracked = {} -- [inst] = {cat, label, hl, bb, txt, part}

local ENTITY_NAMES = {
    RushMoving = "Rush", AmbushMoving = "Ambush", Eyes = "Eyes", BackdoorRush = "Blitz",
    BackdoorLookman = "Lookman", A60 = "A-60", A120 = "A-120", GlitchRush = "Glitch Rush",
    GlitchAmbush = "Glitch Ambush", SeekMovingNewClone = "Seek", SeekMoving = "Seek",
    FigureRig = "Figure", FigureRagdoll = "Figure", GiggleCeiling = "Giggle", GrumbleRig = "Grumble",
    Snare = "Snare", JeffTheKiller = "Jeff", Halt = "Halt", Dupe = "Dupe", Lookman = "Lookman",
    MonumentEntity = "Monument", SallyMoving = "Sally", Sally = "Sally", Groundskeeper = "Groundskeeper", Surge = "Surge",
}
local KEY_NAMES = {
    KeyObtain = "Key", ElectricalKeyObtain = "Electrical Key", LeverForGate = "Lever",
    LiveHintBook = "Book", LiveBreakerPolePickup = "Breaker", FuseObtain = "Fuse",
}
local HIDE_NAMES = { Wardrobe = true, Bed = true, Locker_Large = true, Backdoor_Wardrobe = true, Toolshed = true, Rooms_Locker = true }

local function primaryPart(inst)
    if inst:IsA("BasePart") then return inst end
    if inst:IsA("Model") then
        return inst.PrimaryPart or inst:FindFirstChild("Door") or inst:FindFirstChild("Main")
            or inst:FindFirstChild("Root") or inst:FindFirstChildWhichIsA("BasePart", true)
    end
end

local function catEnabled(cat)
    return (cat == "Entity" and S.EntityESP) or (cat == "Door" and S.DoorESP) or (cat == "Key" and S.KeyESP)
        or (cat == "Item" and S.ItemESP) or (cat == "Gold" and S.GoldESP) or (cat == "Hide" and S.HideESP)
end

local function untrack(inst)
    local t = tracked[inst]; if not t then return end
    if t.hl then t.hl:Destroy() end
    if t.bb then t.bb:Destroy() end
    if t.ac then t.ac:Disconnect() end
    tracked[inst] = nil
end

local function applyVisual(inst)
    local t = tracked[inst]; if not t then return end
    local on = catEnabled(t.cat)
    if not on then
        if t.hl then t.hl:Destroy(); t.hl = nil end
        if t.bb then t.bb:Destroy(); t.bb = nil end
        return
    end
    local part = t.part or primaryPart(inst)
    if not part then return end
    t.part = part
    local col = t.color or COLORS[t.cat]
    if not t.hl then
        local hl = Instance.new("Highlight")
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.FillTransparency = t.cat == "Entity" and 0.45 or 0.75
        hl.OutlineTransparency = 0
        hl.Adornee = inst
        hl.Parent = espFolder
        t.hl = hl
    end
    t.hl.FillColor, t.hl.OutlineColor = col, col
    if not t.bb then
        local bb = Instance.new("BillboardGui")
        bb.AlwaysOnTop = true
        bb.Size = UDim2.fromOffset(200, 34)
        bb.StudsOffset = Vector3.new(0, 2.5, 0)
        bb.Adornee = part
        bb.MaxDistance = t.cat == "Entity" and 1e5 or 400
        local txt = Instance.new("TextLabel")
        txt.BackgroundTransparency = 1
        txt.Size = UDim2.fromScale(1, 1)
        txt.Font = Enum.Font.GothamBold
        txt.TextSize = t.cat == "Entity" and 16 or 13
        txt.TextStrokeTransparency = 0.3
        txt.Parent = bb
        bb.Parent = espFolder
        t.bb, t.txt = bb, txt
    end
    t.txt.TextColor3 = col
    t.txt.Text = t.label
end

local function track(inst, cat, label, color)
    if tracked[inst] then return end
    tracked[inst] = { cat = cat, label = label, color = color }
    tracked[inst].ac = inst.AncestryChanged:Connect(function(_, parent)
        if not parent then untrack(inst) end
    end)
    applyVisual(inst)
end

local function refreshAll() for inst in pairs(tracked) do applyVisual(inst) end end
onCleanup(function() for inst in pairs(tracked) do untrack(inst) end end)

-- distance labels (10 Hz)
task.spawn(function()
    while alive do
        local root = hrp()
        for inst, t in pairs(tracked) do
            if t.txt and t.part then
                if S.ShowDistance and root then
                    t.txt.Text = string.format("%s\n[%dm]", t.label, (root.Position - t.part.Position).Magnitude // 1)
                else
                    t.txt.Text = t.label
                end
            end
        end
        task.wait(0.1)
    end
end)

---------------------------------------------------------------------------
-- entity alerts
---------------------------------------------------------------------------
local lastAlert = {}
local function alertEntity(name)
    if not S.EntityAlerts then return end
    if lastAlert[name] and os.clock() - lastAlert[name] < 6 then return end
    lastAlert[name] = os.clock()
    local tips = {
        Rush = "HIDE NOW!", Ambush = "Hide - it rebounds several times!", Blitz = "HIDE NOW!",
        Eyes = "Don't look at it.", Halt = "Turn around when told.", ["A-60"] = "HIDE NOW!",
        ["A-120"] = "HIDE NOW!", Figure = "Crouch, move slowly.", Seek = "RUN!",
        Lookman = "Don't look at it.", Snare = "Watch your step.", Giggle = "Look up.",
    }
    notify("⚠ " .. name .. " spawned", tips[name] or "Be careful.", 6)
    if S.AlertSound then
        local s = Instance.new("Sound")
        s.SoundId = "rbxassetid://4590657391"
        s.Volume = 2
        s.Parent = espFolder
        s:Play()
        game:GetService("Debris"):AddItem(s, 3)
    end
end

---------------------------------------------------------------------------
-- prompt registry (for instant prompts / reach / auto-loot)
---------------------------------------------------------------------------
local prompts = {} -- [prompt] = {kind, origHold, origDist}
local LOOT_PROMPT_NAMES = { ModulePrompt = "item", LootPrompt = "item", ActivateEventPrompt = "drawer" }

local function setupPrompt(p)
    if prompts[p] then return end
    local kind = LOOT_PROMPT_NAMES[p.Name]
    local par = p.Parent
    if p.Name == "ActivateEventPrompt" and par and par.Name ~= "Knobs" and not (par.Parent and par.Parent.Name:find("Chest")) and not par.Name:find("Chest") then
        kind = nil
    end
    local model = p:FindFirstAncestorOfClass("Model")
    if model and model.Name == "GoldPile" then kind = "gold" end
    if model and KEY_NAMES[model.Name] then kind = "key" end
    prompts[p] = { kind = kind, hold = p.HoldDuration, dist = p.MaxActivationDistance, model = model }
    if S.InstantPrompts then p.HoldDuration = 0 end
    p.MaxActivationDistance = prompts[p].dist * S.PromptReach
end

local function refreshPrompts()
    for p, info in pairs(prompts) do
        if p.Parent then
            p.HoldDuration = S.InstantPrompts and 0 or info.hold
            p.MaxActivationDistance = info.dist * S.PromptReach
        else
            prompts[p] = nil
        end
    end
end
onCleanup(function()
    for p, info in pairs(prompts) do
        if p.Parent then p.HoldDuration = info.hold; p.MaxActivationDistance = info.dist end
    end
end)

---------------------------------------------------------------------------
-- classification
---------------------------------------------------------------------------
local function roomOf(inst)
    local cur = inst
    while cur and cur.Parent ~= Rooms do cur = cur.Parent end
    return cur
end

-- hinged/side/main doors are walls to the navmesh; mark them pass-through so paths go through doorways
local passMods = {}
local function markPassThrough(model)
    task.defer(function()
        for _, part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") and not passMods[part] then
                local m = Instance.new("PathfindingModifier")
                m.PassThrough = true
                m.Parent = part
                passMods[part] = m
            end
        end
    end)
end
onCleanup(function() for _, m in pairs(passMods) do pcall(function() m:Destroy() end) end end)

local roomNodes = {} -- [roomNumber] = { Vector3 ... } entrance -> exit, captured before the game removes them
local function cacheNodes(folder)
    task.delay(0.3, function()
        local room = roomOf(folder)
        if not room or not folder.Parent then return end
        local list = {}
        for _, n in ipairs(folder:GetChildren()) do
            if n:IsA("BasePart") and tonumber(n.Name) then table.insert(list, { tonumber(n.Name), n.Position }) end
        end
        table.sort(list, function(a, b) return a[1] < b[1] end)
        local pts = {}
        for _, e in ipairs(list) do table.insert(pts, e[2]) end
        if #pts > 0 then roomNodes[tonumber(room.Name)] = pts end
    end)
end

local function classify(inst)
    if inst:IsA("ProximityPrompt") then setupPrompt(inst); return end
    if inst:IsA("Folder") and inst.Name == "PathfindNodes" then cacheNodes(inst); return end
    if inst:IsA("Model") and (inst:GetAttribute("LoadModule") == "DoorNormal" or inst:GetAttribute("LoadModule") == "Door") then
        markPassThrough(inst)
    end
    if not inst:IsA("Model") then return end
    local n = inst.Name
    if ENTITY_NAMES[n] then
        track(inst, "Entity", ENTITY_NAMES[n])
        alertEntity(ENTITY_NAMES[n])
        return
    end
    if KEY_NAMES[n] then track(inst, "Key", KEY_NAMES[n]); return end
    if n == "GoldPile" then
        task.defer(function()
            local amt = inst:GetAttribute("GoldValue")
            track(inst, "Gold", amt and ("Gold " .. amt) or "Gold")
        end)
        return
    end
    if n == "Door" and inst.Parent and inst.Parent.Parent == Rooms then
        local locked = inst:FindFirstChild("Lock") ~= nil
        local id = inst:GetAttribute("RoomID") or "?"
        track(inst, "Door", (locked and "🔒 Door " or "Door ") .. tostring(id), locked and COLORS.Locked or nil)
        return
    end
    if HIDE_NAMES[n] then track(inst, "Hide", n); return end
    -- generic loot item: a model owning a ModulePrompt/LootPrompt directly
    local mp = inst:FindFirstChild("ModulePrompt") or inst:FindFirstChild("LootPrompt")
    if mp and mp:IsA("ProximityPrompt") and roomOf(inst) then
        track(inst, "Item", n)
    end
end

-- initial scan (spread across frames so a big map doesn't hitch)
task.spawn(function()
    local list = Rooms:GetDescendants()
    for i, d in ipairs(list) do
        if not alive then return end
        classify(d)
        if i % 400 == 0 then task.wait() end
    end
    for _, d in ipairs(workspace:GetChildren()) do classify(d) end
    for _, d in ipairs(workspace:WaitForChild("LiveEntities"):GetChildren()) do classify(d) end
end)
connect(Rooms.DescendantAdded, function(d) task.defer(classify, d) end)
connect(workspace.ChildAdded, function(d) task.defer(classify, d) end)
connect(workspace:WaitForChild("LiveEntities").ChildAdded, function(d) task.defer(classify, d) end)

---------------------------------------------------------------------------
-- anti-screech (client-side model parented to camera)
---------------------------------------------------------------------------
connect(workspace.CurrentCamera.ChildAdded, function(c)
    if S.AntiScreech and c.Name == "Screech" then
        task.defer(function()
            -- tell the server we "looked" at it (what the game sends on success), so it doesn't hit us
            pcall(function() RS.RemotesFolder.Screech:FireServer(true) end)
            pcall(function() c:Destroy() end)
        end)
        notify("Screech", "Blocked Screech.", 2)
    end
end)

---------------------------------------------------------------------------
-- anti-Halt: Halt ("Shade") lives in the camera and only reports a hit when it gets within 6 studs.
-- Keep it parked far away every frame; leaving the room (what the farm does anyway) ends Halt.
---------------------------------------------------------------------------
local haltAlerted = false
connect(RunService.RenderStepped, function()
    local shade = workspace.CurrentCamera:FindFirstChild("Shade")
    if shade and shade:IsA("BasePart") then
        if not haltAlerted then haltAlerted = true; alertEntity("Halt") end
        if S.AntiHalt then shade.CFrame = CFrame.new(0, -10000, 0) end
    else
        haltAlerted = false
    end
end)

---------------------------------------------------------------------------
-- no camera shake (disable the game's own shake listeners)
---------------------------------------------------------------------------
local shakeRemotes = {}
for _, n in ipairs({ "CamShake", "CamShakeRelative" }) do
    local r = RS.RemotesFolder:FindFirstChild(n); if r then table.insert(shakeRemotes, r.OnClientEvent) end
end
for _, n in ipairs({ "CamShakeClient", "CamShakeRelativeClient" }) do
    local r = RS.RemotesFolder:FindFirstChild(n); if r then table.insert(shakeRemotes, r.Event) end
end
local function setShake(enabled)
    if not getconnections then return end
    for _, sig in ipairs(shakeRemotes) do
        for _, c in ipairs(getconnections(sig)) do pcall(function() if enabled then c:Enable() else c:Disable() end end) end
    end
end
onCleanup(function() setShake(true) end)

---------------------------------------------------------------------------
-- auto hide on Rush/Ambush/A-60/A-120/Blitz
---------------------------------------------------------------------------
local HIDE_FOR = { RushMoving = true, AmbushMoving = true, A60 = true, A120 = true, BackdoorRush = true, GlitchRush = true, GlitchAmbush = true }
local function promptPart(p)
    if p.Parent and p.Parent:IsA("BasePart") then return p.Parent end
    if p.Parent and p.Parent:IsA("Attachment") then return p.Parent.Parent end
    -- prompt sits on the model itself (wardrobes): use the model's pivot, which is what the prompt measures from
    local m = p:FindFirstAncestorOfClass("Model") or p.Parent
    if m and m:IsA("Model") then return { Position = m:GetPivot().Position } end
    return primaryPart(m)
end
local function nearestHidePrompt(maxDist)
    local root = hrp(); if not root then return end
    local best, bp, bd
    for p in pairs(prompts) do
        local room = p.Parent and roomOf(p)
        local reachable = room and (tonumber(room.Name) or math.huge) <= GameData.LatestRoom.Value
        if p.Parent and p.Name == "HidePrompt" and p.Enabled and reachable then
            local part = promptPart(p)
            local sally = workspace:FindFirstChild("SallyMoving")
            if part and sally and (sally:GetPivot().Position - part.Position).Magnitude < 25 then
                part = nil -- Sally's window is right there; she hits players hiding next to it
            end
            if part then
                local d = (part.Position - root.Position).Magnitude
                if d < maxDist and (not bd or d < bd) then best, bp, bd = p, part, d end
            end
        end
    end
    return best, bp, bd
end
local function dangerActive()
    for name in pairs(HIDE_FOR) do
        if workspace:FindFirstChild(name) then return name end
    end
end

---------------------------------------------------------------------------
-- auto loot
---------------------------------------------------------------------------
local looted = setmetatable({}, { __mode = "k" })
task.spawn(function()
    while alive do
        local chase = GameData:FindFirstChild("ChaseInSession")
        if S.AutoLoot and not (chase and chase.Value) then
            local root = hrp()
            local ch = char()
            if root and ch and not ch:GetAttribute("Hiding") then
                for p, info in pairs(prompts) do
                    if p.Parent and p.Enabled and info.kind and not looted[p] then
                        local want = (info.kind == "drawer" and S.LootDrawers) or (info.kind == "gold" and S.LootGold)
                            or (info.kind == "item" and S.LootItems) or (info.kind == "key" and S.LootKeys)
                        if want then
                            local part = p.Parent:IsA("BasePart") and p.Parent or (p.Parent:IsA("Attachment") and p.Parent.Parent)
                                or (info.model and primaryPart(info.model))
                            if part and part:IsA("BasePart") and (part.Position - root.Position).Magnitude <= math.min(p.MaxActivationDistance, 14) then
                                fireproximityprompt(p)
                                if info.kind == "drawer" then looted[p] = true end
                            end
                        end
                    end
                end
            end
        end
        task.wait(0.25)
    end
end)

---------------------------------------------------------------------------
-- speed boost via the game's own movement attribute (SpeedBoostExtra)
---------------------------------------------------------------------------
local function applySpeed()
    local ch = char(); if ch then ch:SetAttribute("SpeedBoostExtra", S.AutoWalk and math.max(S.FarmSpeed, S.SpeedBoost) or S.SpeedBoost) end
end
connect(LP.CharacterAdded, function() task.wait(1); applySpeed() end)
onCleanup(function() local ch = char(); if ch then ch:SetAttribute("SpeedBoostExtra", 0) end end)

---------------------------------------------------------------------------
-- fullbright / no fog / fov
---------------------------------------------------------------------------
local origLight = {
    Ambient = Lighting.Ambient, Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
    FogEnd = Lighting.FogEnd, FogStart = Lighting.FogStart, GlobalShadows = Lighting.GlobalShadows,
    OutdoorAmbient = Lighting.OutdoorAmbient,
}
local atmos = {}
connect(RunService.RenderStepped, function()
    if S.Fullbright then
        Lighting.Ambient = Color3.new(1, 1, 1)
        Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
        Lighting.Brightness = 2
        Lighting.GlobalShadows = false
    end
    if S.NoFog then
        Lighting.FogEnd = 1e6; Lighting.FogStart = 1e6
        for _, a in ipairs(Lighting:GetChildren()) do
            if a:IsA("Atmosphere") and a.Density > 0 then atmos[a] = atmos[a] or a.Density; a.Density = 0 end
        end
    end
    if S.FOV ~= 70 then workspace.CurrentCamera.FieldOfView = S.FOV end
end)
local function restoreLighting()
    for k, v in pairs(origLight) do pcall(function() Lighting[k] = v end) end
    for a, d in pairs(atmos) do if a.Parent then a.Density = d end end
    table.clear(atmos)
end
onCleanup(restoreLighting)

---------------------------------------------------------------------------
-- auto walk farm (pathfinding to key -> door, auto-open doors)
---------------------------------------------------------------------------
local farmStatus = "Idle"
ENV.VoidHubStatus = function() return farmStatus end
local function hasKeyTool()
    local ch = char()
    for _, c in ipairs((ch and ch:GetChildren()) or {}) do if c:IsA("Tool") and c.Name:find("Key") then return true end end
    for _, c in ipairs(LP.Backpack:GetChildren()) do if c:IsA("Tool") and c.Name:find("Key") then return true end end
    return false
end

local function doorFrame(door)
    -- the Door panel swings when opened; Collision/Hidden keep the frame's real orientation
    return door:FindFirstChild("Collision") or door:FindFirstChild("Hidden") or door:FindFirstChild("Door") or primaryPart(door)
end

local function currentTarget()
    local latest = GameData.LatestRoom.Value
    local cur = tonumber(LP:GetAttribute("CurrentRoom")) or latest
    if cur < latest then
        local curRoom = Rooms:FindFirstChild(tostring(cur))
        local cdoor = curRoom and curRoom:FindFirstChild("Door")
        if cdoor and not cdoor:FindFirstChild("Lock") then
            return doorFrame(cdoor), "cross", nil, cdoor
        end
    end
    local room = Rooms:FindFirstChild(tostring(latest))
    if not room then return end
    local door = room:FindFirstChild("Door")
    if not door then return end
    local lock = door:FindFirstChild("Lock")
    if lock and not hasKeyTool() then
        for _, d in ipairs(room:GetDescendants()) do
            if d.Name == "KeyObtain" or d.Name == "ElectricalKeyObtain" then
                return primaryPart(d), "key", d, door
            end
        end
    end
    return doorFrame(door), "door", nil, door
end

local function tryOpenDoor(door)
    local root = hrp(); if not root then return end
    local dp = door and (door:FindFirstChild("Door") or primaryPart(door))
    if not dp or (dp.Position - root.Position).Magnitude > 14 then return end
    local lock = door:FindFirstChild("Lock")
    local up = lock and lock:FindFirstChild("UnlockPrompt", true)
    if up and hasKeyTool() then
        -- equip key then unlock
        local key
        for _, c in ipairs(LP.Backpack:GetChildren()) do if c:IsA("Tool") and c.Name:find("Key") then key = c end end
        if key and hum() then hum():EquipTool(key); task.wait(0.15) end
        fireproximityprompt(up)
    end
    local ce = door:FindFirstChild("ClientOpen")
    if ce then ce:FireServer() end
end

local moveGoal -- Vector3 the render-step driver walks toward
local noclipActive = false -- farm turns this on only for stretches the pathfinder can't solve
local ncOrig = {}
connect(RunService.Stepped, function()
    local ch = char(); if not ch then return end
    if noclipActive and S.FarmNoclip and S.AutoWalk and not (S.AutoHide and dangerActive()) then
        for _, p in ipairs(ch:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then
                if ncOrig[p] == nil then ncOrig[p] = true end
                p.CanCollide = false
            end
        end
    elseif next(ncOrig) then
        for p in pairs(ncOrig) do if p.Parent then p.CanCollide = true end end
        table.clear(ncOrig)
    end
end)
onCleanup(function() for p in pairs(ncOrig) do if p.Parent then p.CanCollide = true end end end)
ENV.VoidHubDebug = function() return moveGoal end
local DRIVE = "VH_FarmDrive"
RunService:BindToRenderStep(DRIVE, Enum.RenderPriority.Character.Value + 5, function()
    if not (moveGoal and (S.AutoWalk or (S.AutoHide and dangerActive()))) then return end
    local root, h = hrp(), hum()
    if not (root and h) then return end
    local d = (moveGoal - root.Position) * Vector3.new(1, 0, 1)
    if d.Magnitude > 0.8 then h:Move(d.Unit, false) end
end)
onCleanup(function() RunService:UnbindFromRenderStep(DRIVE); local h = hum(); if h then h:Move(Vector3.zero) end end)

local PATH_COSTS = { VHBlock = math.huge }
local PATH_WIDE = { AgentRadius = 2.2, AgentHeight = 4.5, AgentCanJump = false, WaypointSpacing = 4, Costs = PATH_COSTS }
local PATH_THIN = { AgentRadius = 1.2, AgentHeight = 4.5, AgentCanJump = false, WaypointSpacing = 4, Costs = PATH_COSTS }
-- crouch-height agent: only used when standing paths fail (gaps under shelves/vents/obstructions)
local PATH_CROUCH = { AgentRadius = 1.0, AgentHeight = 2.4, AgentCanJump = false, WaypointSpacing = 3, Costs = PATH_COSTS }

-- the game's own crouch (same function the C key calls), so the server sees a normal crouch
local mainGame
local isCrouched = false
local function setCrouch(on)
    if isCrouched == on then return end
    if not mainGame then
        local ok, m = pcall(function() return require(LP.PlayerGui.MainUI.Initiator.Main_Game) end)
        if ok and type(m) == "table" then mainGame = m end
    end
    if mainGame and mainGame.crouch then
        pcall(mainGame.crouch, on)
        isCrouched = on
    end
end
onCleanup(function() setCrouch(false) end)

-- props the navmesh thinks are walkable but physics blocks: tag them so later paths avoid them
local blockMods = {}
local function tagBlocker(part)
    if blockMods[part] or not part:IsA("BasePart") or part.Size.Magnitude > 120 then return end
    local m = Instance.new("PathfindingModifier")
    m.Label = "VHBlock"
    m.Parent = part
    blockMods[part] = m
end
onCleanup(function() for _, m in pairs(blockMods) do pcall(function() m:Destroy() end) end end)
local function tryPath(opts, from, g)
    local path = PFS:CreatePath(opts)
    local ok = pcall(function() path:ComputeAsync(from, g) end)
    if ok and path.Status == Enum.PathStatus.Success then return path:GetWaypoints() end
end
local function findPath(from, goals)
    local deadline = os.clock() + 0.9 -- NoPath calls are slow; never stall the farm for long
    for _, opts in ipairs({ PATH_WIDE, PATH_THIN }) do
        for gi, g in ipairs(goals) do
            if gi > 4 or os.clock() > deadline then break end
            local w = tryPath(opts, from, g)
            if w then return w, g, false end
        end
    end
    -- standing can't get there: try it crouched
    for gi, g in ipairs(goals) do
        if gi > 2 or os.clock() > deadline then break end
        local w = tryPath(PATH_CROUCH, from, g)
        if w then return w, g, true end
    end
    -- our own spot is off the navmesh (rugs, corners): start from a nearby point instead
    local losParams = RaycastParams.new()
    losParams.FilterDescendantsInstances = { char() }
    for a = 0, 7 do
        if os.clock() > deadline then return end
        local start = from + Vector3.new(math.cos(a * math.pi / 4) * 3, 0, math.sin(a * math.pi / 4) * 3)
        if not workspace:Raycast(from, start - from, losParams) then -- don't "start" on the other side of a wall
            local w = tryPath(PATH_THIN, start, goals[1])
            if w then
                table.insert(w, 1, { Position = from })
                return w, goals[1]
            end
        end
    end
end

-- walk to one waypoint; returns false if we got wedged (and backs off so the next path starts clean)
local unstickParams = RaycastParams.new()
local function walkTo(goal, timeout, abort)
    local root = hrp(); if not root then return false end
    moveGoal = goal
    local t0, lastP, lastT = os.clock(), root.Position, os.clock()
    while alive do
        task.wait()
        if abort and abort() then return true end
        if ((root.Position - goal) * Vector3.new(1, 0, 1)).Magnitude < 2 then return true end
        if os.clock() - t0 > timeout then return false end
        if os.clock() - lastT > 0.4 then
            if (root.Position - lastP).Magnitude < 0.6 then
                -- wedged: tag what we ran into, then step back out along the clearest direction
                moveGoal = nil
                unstickParams.FilterDescendantsInstances = { char() }
                local fwd = (goal - root.Position) * Vector3.new(1, 0, 1)
                if fwd.Magnitude > 0.1 then
                    for _, ang in ipairs({ 0, 0.5, -0.5 }) do
                        local dir = CFrame.Angles(0, ang, 0):VectorToWorldSpace(fwd.Unit)
                        for _, yOff in ipairs({ 0, -1.5, 1.5 }) do
                            local hit = workspace:Raycast(root.Position + Vector3.new(0, yOff, 0), dir * 4, unstickParams)
                            if hit and hit.Normal.Y < 0.6 then tagBlocker(hit.Instance) end
                        end
                    end
                end
                local best, bestD = nil, -1
                for a = 0, 7 do
                    local dir = Vector3.new(math.cos(a * math.pi / 4), 0, math.sin(a * math.pi / 4))
                    local hit = workspace:Raycast(root.Position, dir * 6, unstickParams)
                    local d = hit and hit.Distance or 6
                    if d > bestD then best, bestD = dir, d end
                end
                if best then
                    -- back out by walking (no CFrame moves: the server snaps those back)
                    moveGoal = root.Position + best * math.min(3, math.max(bestD - 0.5, 1))
                    task.wait(0.35)
                    moveGoal = nil
                end
                return false
            end
            lastP, lastT = root.Position, os.clock()
        end
    end
    return false
end

-- a collision-free standing spot near `pos`, searching rings around it (prefers `towards` side)
local function clearSpotNear(pos, y, towards)
    local ov = OverlapParams.new()
    ov.FilterDescendantsInstances = { char() }
    ov.FilterType = Enum.RaycastFilterType.Exclude
    local base = towards and ((towards - pos) * Vector3.new(1, 0, 1)) or Vector3.new(1, 0, 0)
    base = base.Magnitude > 0.1 and base.Unit or Vector3.new(1, 0, 0)
    for _, r in ipairs({ 0, 2.5, 4, 6 }) do
        for i = 0, (r == 0 and 0 or 11) do
            local d = CFrame.Angles(0, (i % 2 == 0 and 1 or -1) * math.ceil(i / 2) * math.pi / 6, 0):VectorToWorldSpace(base)
            local c = Vector3.new(pos.X, y, pos.Z) + d * r
            local solid = false
            for _, hit in ipairs(workspace:GetPartBoundsInBox(CFrame.new(c), Vector3.new(2.2, 4.6, 2.2), ov)) do
                if hit.CanCollide then solid = true; break end
            end
            if not solid then
                -- must have real floor right under it (never hop over a drop / the void)
                local rp = RaycastParams.new()
                rp.FilterDescendantsInstances = { char() }
                local fl = workspace:Raycast(c, Vector3.new(0, -6, 0), rp)
                if fl and fl.Instance.CanCollide and fl.Normal.Y > 0.7 then return c end
            end
        end
    end
end

-- short vault over the obstacle between us and `goal` (counters, shelves): <= 12 studs, lands on real floor
local lastVault = 0
local NO_TELEPORTS = true -- the server rubber-bands every teleport, even 8 studs: farm only ever walks
local function vaultToward(goal)
    if NO_TELEPORTS then return false end
    local root = hrp(); if not root then return false end
    if os.clock() - lastVault < 1.5 then return false end
    local flat = (goal - root.Position) * Vector3.new(1, 0, 1)
    if flat.Magnitude < 2 then return false end
    local dir = flat.Unit
    local rp = RaycastParams.new()
    rp.FilterDescendantsInstances = { char() }
    local ov = OverlapParams.new()
    ov.FilterDescendantsInstances = { char() }
    ov.FilterType = Enum.RaycastFilterType.Exclude
    local passed = false
    for d = 1.5, math.min(12, flat.Magnitude + 2), 0.75 do
        local c = root.Position + dir * d
        local solid = false
        for _, hit in ipairs(workspace:GetPartBoundsInBox(CFrame.new(c), Vector3.new(2.2, 4.6, 2.2), ov)) do
            if hit.CanCollide then solid = true; break end
        end
        if solid then
            passed = true
        elseif passed then
            local fl = workspace:Raycast(c, Vector3.new(0, -6, 0), rp)
            if fl and fl.Instance.CanCollide and fl.Normal.Y > 0.7 then
                lastVault = os.clock()
                root.CFrame = CFrame.new(c, c + dir)
                root.AssemblyLinearVelocity = Vector3.zero
                return true
            end
        end
    end
    return false
end

-- whisker steering for rooms the navmesh can't resolve (cluttered offices etc.)
local steerParams = RaycastParams.new()
local function clearDir(root, dir, len)
    local right = dir:Cross(Vector3.yAxis)
    for _, side in ipairs({ -1, 0, 1 }) do
        for _, y in ipairs({ -1.6, 0, 1.2 }) do
            local o = root.Position + right * side * 0.9 + Vector3.new(0, y, 0)
            local hit = workspace:Raycast(o, dir * len, steerParams)
            if hit and hit.Normal.Y < 0.6 then return false end
        end
    end
    return true
end
local function steerTo(goal, timeout, abort)
    local root = hrp(); if not root then return false end
    steerParams.FilterDescendantsInstances = { char() }
    local t0, lastP, lastT, bias = os.clock(), root.Position, os.clock(), 1
    while alive and os.clock() - t0 < timeout do
        if abort and abort() then return false end
        local to = (goal - root.Position) * Vector3.new(1, 0, 1)
        if to.Magnitude < 2.5 then moveGoal = nil; return true end
        local base = to.Unit
        local chosen
        for _, deg in ipairs({ 0, 20, -20, 40, -40, 60, -60, 85, -85, 110, -110, 150, -150 }) do
            local d = CFrame.Angles(0, math.rad(deg * bias), 0):VectorToWorldSpace(base)
            if clearDir(root, d, 3.5) then chosen = d; break end
        end
        moveGoal = root.Position + (chosen or -base) * 4
        if os.clock() - lastT > 0.6 then
            if (root.Position - lastP).Magnitude < 1 then bias = -bias end -- flip preferred side when wedged
            lastP, lastT = root.Position, os.clock()
        end
        task.wait(0.08)
    end
    moveGoal = nil
    return false
end

-- follow the game's own entity route through the room (straight hops, pathfinding only around snags)
local function followRoute(points, abort)
    local root = hrp(); if not root or #points == 0 then return end
    local k, bd = 1, math.huge
    for i, p in ipairs(points) do
        local d = ((p - root.Position) * Vector3.new(1, 0, 1)).Magnitude
        if d < bd then k, bd = i, d end
    end
    if points[k + 1] and ((points[k + 1] - root.Position) * Vector3.new(1, 0, 1)).Magnitude
        < ((points[k + 1] - points[k]) * Vector3.new(1, 0, 1)).Magnitude then
        k += 1
    end
    for i = k, #points do
        if abort() then return end
        local pt = points[i]
        if not walkTo(pt, 4, abort) then
            local wps = findPath(root.Position, { pt })
            if wps then
                for j = 2, #wps do
                    if abort() or not walkTo(wps[j].Position, 1.5, abort) then break end
                end
            end
        end
    end
end

local floorParams = RaycastParams.new()
local function floorBelow(pos, fallback)
    floorParams.FilterDescendantsInstances = { char() }
    local hit = workspace:Raycast(pos + Vector3.new(0, 1, 0), Vector3.new(0, -14, 0), floorParams)
    return hit and hit.Position.Y or fallback
end

local function goalsFor(part, kind, root)
    -- aim at the floor under the target, not at our own height (downstairs rooms are 16 studs lower)
    local floorY = floorBelow(part.Position, root.Position.Y - 2.5)
    local goals = {}
    if kind == "door" or kind == "cross" then
        local lv = part.CFrame.LookVector * Vector3.new(1, 0, 1)
        if lv.Magnitude < 0.1 then lv = Vector3.new(1, 0, 0) end
        lv = lv.Unit
        local side = ((root.Position - part.Position):Dot(lv) >= 0) and 1 or -1
        for _, dist in ipairs({ 4, 6, 2.5 }) do
            local p = part.Position + lv * side * dist
            table.insert(goals, Vector3.new(p.X, floorY, p.Z))
        end
    else
        table.insert(goals, Vector3.new(part.Position.X, floorY, part.Position.Z))
        for i = 0, 7 do
            local a = i * math.pi / 4
            table.insert(goals, Vector3.new(part.Position.X + math.cos(a) * 3.5, floorY, part.Position.Z + math.sin(a) * 3.5))
        end
    end
    return goals
end

---------------------------------------------------------------------------
-- walk through furniture (client-side): props in Assets lose collision and become pass-through
-- for the pathfinder while farming. Walls/floors (Parts) are never touched, so no wall-noclip.
---------------------------------------------------------------------------
local phased = {} -- [part] = PathfindingModifier
local SKIP_PHASE = { "Floor", "Stair", "Step", "Ladder", "Bridge", "Plank", "Carpet", "Rug", "Ramp", "Platform" }
local function phaseable(p)
    if not p:IsA("BasePart") or not p.CanCollide then return false end
    local root = hrp()
    if root and (p.Position.Y - p.Size.Y / 2) < root.Position.Y - 3.6 then return false end -- reaches below the floor: a floor/slab, never phase it
    if p.Size.Y < 1.2 then return false end -- flat things you stand on
    for _, w in ipairs(SKIP_PHASE) do if p.Name:find(w) then return false end end
    local m = p:FindFirstAncestorOfClass("Model")
    if m then for _, w in ipairs(SKIP_PHASE) do if m.Name:find(w) then return false end end end
    return true
end
local function restorePhased()
    for p, mod in pairs(phased) do
        if p.Parent then p.CanCollide = true end
        pcall(function() mod:Destroy() end)
    end
    table.clear(phased)
end
onCleanup(restorePhased)
task.spawn(function()
    while alive do
        if S.AutoWalk and S.PhaseProps and not (S.AutoHide and dangerActive()) then
            local latest = GameData.LatestRoom.Value
            for _, room in ipairs(Rooms:GetChildren()) do
                local n = tonumber(room.Name)
                local assets = room:FindFirstChild("Assets")
                if n and assets and n >= latest - 2 and n <= latest + 1 then
                    for _, p in ipairs(assets:GetDescendants()) do
                        if not phased[p] and phaseable(p) then
                            p.CanCollide = false
                            local mod = Instance.new("PathfindingModifier")
                            mod.PassThrough = true
                            mod.Parent = p
                            phased[p] = mod
                        end
                    end
                end
            end
        elseif next(phased) then
            restorePhased()
        end
        task.wait(0.5)
    end
end)

-- Seek chase: run the entity route straight through, no pathfinding pauses, no looting
local function inChase()
    local v = GameData:FindFirstChild("ChaseInSession")
    return v and v.Value == true
end
local function chaseStep(root)
    local cur = tonumber(LP:GetAttribute("CurrentRoom")) or GameData.LatestRoom.Value
    local room = Rooms:FindFirstChild(tostring(cur))
    if not room then task.wait(0.1); return end
    local pts = {}
    local nodes = roomNodes[cur]
    if nodes then
        -- only nodes still ahead of us
        local k, bd = 1, math.huge
        for i, p in ipairs(nodes) do
            local d = ((p - root.Position) * Vector3.new(1, 0, 1)).Magnitude
            if d < bd then k, bd = i, d end
        end
        if nodes[k + 1] and ((nodes[k + 1] - root.Position) * Vector3.new(1, 0, 1)).Magnitude
            < ((nodes[k + 1] - nodes[k]) * Vector3.new(1, 0, 1)).Magnitude then k += 1 end
        for i = k, #nodes do table.insert(pts, nodes[i]) end
    end
    local door = room:FindFirstChild("Door")
    if door then
        local frame = doorFrame(door)
        local axis = (frame.CFrame.LookVector * Vector3.new(1, 0, 1))
        axis = axis.Magnitude > 0.1 and axis.Unit or Vector3.new(1, 0, 0)
        local side = ((root.Position - frame.Position):Dot(axis) >= 0) and 1 or -1
        table.insert(pts, frame.Position + axis * side * 2)
        table.insert(pts, frame.Position - axis * side * 5)
        tryOpenDoor(door)
    end
    farmStatus = "SEEK CHASE - running (room " .. cur .. ")"
    for _, p in ipairs(pts) do
        if not (S.AutoWalk and inChase()) then break end
        if not walkTo(p, 2.5) then
            -- wedged on something: quick path around it, never stop running
            local wps = findPath(root.Position, { p })
            if wps then for j = 2, math.min(#wps, 5) do if not walkTo(wps[j].Position, 1.2) then break end end end
        end
        if door and door.Parent then tryOpenDoor(door) end
    end
end

task.spawn(function()
    local stuckT, lastPos = 0, nil
    local weHid, lastDanger = false, 0
    local walkFails = 0
    local routeDone = {}
    local progRoom, progCur, progT, stuckNotified = -1, -1, os.clock(), false
    local farmWasOn = false
    local keyBlinked = {}
    local doorBlinked = {}
    local lastLatest = GameData.LatestRoom.Value
    while alive do
        -- new run (room counter went back down): forget everything learned about the old run's rooms
        local lt = GameData.LatestRoom.Value
        if lt < lastLatest then
            table.clear(keyBlinked); table.clear(doorBlinked); table.clear(routeDone); table.clear(roomNodes)
            walkFails, progRoom, stuckNotified, weHid = 0, -1, false, false
            for _, f in ipairs(Rooms:GetDescendants()) do
                if f:IsA("Folder") and f.Name == "PathfindNodes" then cacheNodes(f) end
            end
        end
        lastLatest = lt
        if S.AutoOpenDoors then
            local latest = GameData.LatestRoom.Value
            local room = Rooms:FindFirstChild(tostring(latest))
            if room then tryOpenDoor(room:FindFirstChild("Door")) end
        end
        local root, h, ch = hrp(), hum(), char()
        local danger = S.AutoHide and dangerActive()
        local hiding = ch and ch:GetAttribute("Hiding")
        if danger then lastDanger = os.clock() end
        -- leave the hiding spot once the entity is gone
        if hiding and weHid and not danger and os.clock() - lastDanger > 2 and h then
            farmStatus = "Leaving hiding spot"
            -- same remote the game's own "Unhide" button fires
            RS.RemotesFolder.CamLock:FireServer()
            local t0 = os.clock()
            while os.clock() - t0 < 1.5 and ch:GetAttribute("Hiding") do task.wait(0.1) end
            if not ch:GetAttribute("Hiding") then weHid = false; applySpeed() end
        end
        if danger and hiding then
            moveGoal = nil
            farmStatus = "Hiding from " .. (ENTITY_NAMES[danger] or danger)
        elseif danger and root and h and h.Health > 0 then
            local hp, hpart, hd = nearestHidePrompt(180)
            if hp then
                farmStatus = "Running to hide from " .. (ENTITY_NAMES[danger] or danger)
                if ch:GetAttribute("SpeedBoostExtra") ~= math.max(S.FarmSpeed, S.SpeedBoost) then
                    ch:SetAttribute("SpeedBoostExtra", math.max(S.FarmSpeed, S.SpeedBoost))
                end
                if hd <= hp.MaxActivationDistance - 0.5 then
                    moveGoal = nil
                    fireproximityprompt(hp)
                    weHid = true
                    task.wait(0.25)
                else
                    local inRange = function()
                        local p2 = nearestHidePrompt(180)
                        return p2 ~= nil and (promptPart(p2).Position - root.Position).Magnitude <= p2.MaxActivationDistance - 0.5
                    end
                    local wps, _, hideCrouch = findPath(root.Position, goalsFor(hpart, "hide", root))
                    setCrouch(hideCrouch == true)
                    if wps then
                        for i = 2, #wps do
                            if inRange() or not dangerActive() then break end
                            if not walkTo(wps[i].Position, 1.2, inRange) then break end -- wedged: repath next loop
                        end
                    else
                        steerTo(Vector3.new(hpart.Position.X, root.Position.Y, hpart.Position.Z), 1.5, inRange)
                    end
                end
            else
                farmStatus = "No hiding spot nearby!"
            end
        elseif S.AutoWalk and root and h and h.Health > 0 and ch and not hiding and inChase() then
            progT = os.clock() -- chase always progresses; don't trip the watchdog
            chaseStep(root)
        elseif S.AutoWalk and root and h and h.Health > 0 and ch and not hiding
            and (function()
                -- progress watchdog: if no room progress for 20s, hand control to the player until they get past it
                local lr = GameData.LatestRoom.Value
                if not farmWasOn then farmWasOn = true; progRoom = -1 end
                if lr ~= progRoom then
                    progRoom, progT, stuckNotified = lr, os.clock(), false
                end
                if os.clock() - progT > 20 then
                    if not stuckNotified then
                        stuckNotified = true
                        moveGoal = nil
                        notify("Auto Farm", "Can't path through this room - walk it yourself, farm resumes at the next room.", 8)
                    end
                    farmStatus = "Stuck - your turn (resumes next room)"
                    return false
                end
                return true
            end)() then
            local targetPart, kind, keyModel = currentTarget()
            if targetPart then
                farmStatus = kind == "key" and "Getting key" or kind == "cross" and "Going through door" or ("Heading to door " .. tostring(GameData.LatestRoom.Value + 1))
                local axis = (targetPart.CFrame.LookVector * Vector3.new(1, 0, 1))
                axis = axis.Magnitude > 0.1 and axis.Unit or Vector3.new(1, 0, 0)
                local side = ((root.Position - targetPart.Position):Dot(axis) >= 0) and 1 or -1
                local nearPt = Vector3.new(targetPart.Position.X, root.Position.Y, targetPart.Position.Z) + axis * side * 3
                if kind == "cross" and ((root.Position - nearPt) * Vector3.new(1, 0, 1)).Magnitude < 3.5 then
                    -- at the doorway: walk straight through (navmesh doesn't see open doors)
                    local farPt = Vector3.new(targetPart.Position.X, root.Position.Y, targetPart.Position.Z) - axis * side * 5
                    walkTo(Vector3.new(targetPart.Position.X, root.Position.Y, targetPart.Position.Z), 1.2)
                    walkTo(farPt, 1.5)
                    task.wait(0.1)
                    continue
                end
                if kind == "door" and roomNodes[GameData.LatestRoom.Value] and not routeDone[GameData.LatestRoom.Value] then
                    routeDone[GameData.LatestRoom.Value] = true
                    followRoute(roomNodes[GameData.LatestRoom.Value], function()
                        return (not S.AutoWalk) or (ch:GetAttribute("Hiding") == true) or (S.AutoHide and dangerActive() ~= nil)
                    end)
                end
                local wps, goal, needCrouch = findPath(root.Position, goalsFor(targetPart, kind, root))
                setCrouch(needCrouch == true)
                if needCrouch then farmStatus = farmStatus .. " (crouching)" end
                if not NO_TELEPORTS and wps and kind == "key" and walkFails >= 2 and (keyBlinked[GameData.LatestRoom.Value] or 0) < 3 then
                    wps = nil -- path exists on paper but we keep failing it: fall through to the key blink
                end
                if wps then
                    local abort = function() return not S.AutoWalk or ch:GetAttribute("Hiding") or (S.AutoHide and dangerActive()) end
                    local walked = true
                    for i = 2, math.min(#wps, 8) do
                        if abort() then break end
                        if not walkTo(wps[i].Position, 1.5, abort) then walked = false; break end
                    end
                    walkFails = walked and 0 or walkFails + 1
                    if not walked and S.FarmNoclip and walkFails >= 2 then
                        farmStatus = farmStatus .. " (noclip)"
                        noclipActive = true
                        local g = goal or goalsFor(targetPart, kind, root)[1]
                        if walkTo(Vector3.new(g.X, root.Position.Y, g.Z), 5, abort) then walkFails = 0 end
                        noclipActive = false
                    end
                else
                    -- navmesh can't solve this room: steer with whiskers instead
                    local g = goalsFor(targetPart, kind, root)[1]
                    -- no walkable route: vault the nearest counter/shelf toward the target, then walk again
                    if vaultToward(Vector3.new(targetPart.Position.X, root.Position.Y, targetPart.Position.Z)) then
                        farmStatus = farmStatus .. " (vault)"
                        if kind == "key" and keyModel then
                            local kp2 = keyModel:FindFirstChildWhichIsA("ProximityPrompt", true)
                            if kp2 and (targetPart.Position - root.Position).Magnitude < 9 then fireproximityprompt(kp2) end
                        end
                        task.wait(0.3)
                        continue
                    end
                    -- walled-off door pocket (bookshelves/couches): one short hop per room to the door's near side
                    if not NO_TELEPORTS and (kind == "door" or kind == "cross") and not doorBlinked[GameData.LatestRoom.Value]
                        and (targetPart.Position - root.Position).Magnitude < 45 and walkFails >= 1 then
                        doorBlinked[GameData.LatestRoom.Value] = true
                        local roomM = Rooms:FindFirstChild(tostring(GameData.LatestRoom.Value))
                        local ent = roomM and roomM:FindFirstChild("RoomEntrance")
                        local ax = (targetPart.CFrame.LookVector * Vector3.new(1, 0, 1))
                        ax = ax.Magnitude > 0.1 and ax.Unit or Vector3.new(1, 0, 0)
                        local sd = ent and (((ent.Position - targetPart.Position):Dot(ax) >= 0) and 1 or -1) or 1
                        local near = targetPart.Position + ax * sd * 3
                        local spot = clearSpotNear(near, root.Position.Y, root.Position)
                        if spot then
                            farmStatus = "Hopping walled-off door"
                            root.CFrame = CFrame.new(spot, Vector3.new(targetPart.Position.X, spot.Y, targetPart.Position.Z))
                            root.AssemblyLinearVelocity = Vector3.zero
                            task.wait(0.3)
                            if roomM and roomM:FindFirstChild("Door") then tryOpenDoor(roomM.Door) end
                            task.wait(0.4)
                            continue
                        end
                    end
                    if S.FarmNoclip then
                        -- pathfinder can't solve it: noclip straight to the goal (props/desks/obstructions)
                        farmStatus = farmStatus .. " (noclip)"
                        noclipActive = true
                        local ok = walkTo(Vector3.new(g.X, root.Position.Y, g.Z), 6, function()
                            return not S.AutoWalk or ch:GetAttribute("Hiding") or (S.AutoHide and dangerActive() ~= nil)
                        end)
                        if kind == "key" and keyModel and keyModel.Parent then
                            local kp = keyModel:FindFirstChildWhichIsA("ProximityPrompt", true)
                            if kp and (targetPart.Position - root.Position).Magnitude < 10 then fireproximityprompt(kp) end
                        end
                        if kind == "door" or kind == "cross" then
                            local d = Rooms:FindFirstChild(tostring(GameData.LatestRoom.Value))
                            if d and d:FindFirstChild("Door") then tryOpenDoor(d.Door) end
                        end
                        task.wait(0.2)
                        noclipActive = false
                        walkFails = ok and 0 or walkFails + 1
                        continue
                    end
                    farmStatus = farmStatus .. " (steering)"
                    -- keys behind counters/walls the navmesh can't reach: one short blink per room to grab it
                    if not NO_TELEPORTS and kind == "key" and (keyBlinked[GameData.LatestRoom.Value] or 0) < 3
                        and (targetPart.Position - root.Position).Magnitude < 45 then
                        keyBlinked[GameData.LatestRoom.Value] = (keyBlinked[GameData.LatestRoom.Value] or 0) + 1
                        local kp = targetPart.Position
                        local flat = ((root.Position - kp) * Vector3.new(1, 0, 1))
                        flat = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
                        local ov = OverlapParams.new()
                        ov.FilterDescendantsInstances = { char() }
                        ov.FilterType = Enum.RaycastFilterType.Exclude
                        local dest
                        for _, r in ipairs({ 3, 4.5 }) do
                            for i = 0, 7 do
                                -- start with the side facing us, then sweep around
                                local d = CFrame.Angles(0, (i % 2 == 0 and 1 or -1) * math.ceil(i / 2) * math.pi / 4, 0):VectorToWorldSpace(flat)
                                local c = Vector3.new(kp.X, root.Position.Y, kp.Z) + d * r
                                local solid = false
                                for _, hit in ipairs(workspace:GetPartBoundsInBox(CFrame.new(c), Vector3.new(2, 4.5, 1.5), ov)) do
                                    if hit.CanCollide then solid = true; break end
                                end
                                if not solid then dest = c; break end
                            end
                            if dest then break end
                        end
                        dest = dest or (Vector3.new(kp.X, root.Position.Y, kp.Z) + flat * 3)
                        local kprompt = keyModel and keyModel:FindFirstChildWhichIsA("ProximityPrompt", true)
                        root.CFrame = CFrame.new(dest, Vector3.new(kp.X, dest.Y, kp.Z))
                        root.AssemblyLinearVelocity = Vector3.zero
                        -- grab it before the server can reconcile the position
                        if kprompt then fireproximityprompt(kprompt) end
                        task.wait(0.1)
                        if kprompt and kprompt.Parent then fireproximityprompt(kprompt) end
                        task.wait(0.5)
                        continue
                    end
                    if steerTo(g, 6, function() return not S.AutoWalk or ch:GetAttribute("Hiding") or (S.AutoHide and dangerActive() ~= nil) end) then
                        walkFails = 0
                    else
                        walkFails += 1
                    end
                end
                -- navmesh lied twice in a row (thin walls): one short teleport past it
                if not NO_TELEPORTS and walkFails >= 6 then
                    local g = goal or (targetPart.Position - Vector3.new(0, 2.5, 0))
                    local off = g - root.Position
                    local dest = root.Position + off.Unit * math.min(off.Magnitude, 8)
                    root.CFrame = CFrame.new(dest + Vector3.new(0, 3, 0)) * root.CFrame.Rotation
                    root.AssemblyLinearVelocity = Vector3.zero
                    walkFails = 0
                    farmStatus = "Unstuck (blink)"
                    task.wait(0.4)
                end
                if kind == "key" and keyModel and keyModel.Parent then
                    local kp = keyModel:FindFirstChildWhichIsA("ProximityPrompt", true)
                    if kp and (targetPart.Position - root.Position).Magnitude < 12 then fireproximityprompt(kp) end
                end
                -- stuck detection
                if lastPos and (root.Position - lastPos).Magnitude < 0.5 then
                    stuckT += 1
                    if stuckT > 8 then
                        moveGoal = root.Position + Vector3.new(math.random(-6, 6), 0, math.random(-6, 6))
                        task.wait(0.6); stuckT = 0
                    end
                else stuckT = 0 end
                lastPos = root.Position
            else
                moveGoal = nil
                farmStatus = "Waiting for room"
            end
        else
            moveGoal = nil
            if not S.AutoWalk then farmStatus = "Idle"; farmWasOn = false; setCrouch(false) end
        end
        task.wait(0.05)
    end
end)

---------------------------------------------------------------------------
-- UI build
---------------------------------------------------------------------------
local G = Window:TabGroup()
local Tabs = {
    Main    = G:Tab({ Name = "Main",    Image = "rbxassetid://10734950309" }),
    Visuals = G:Tab({ Name = "Visuals", Image = "rbxassetid://10723346959" }),
    Player  = G:Tab({ Name = "Player",  Image = "rbxassetid://10747373176" }),
    Farm    = G:Tab({ Name = "Farm",    Image = "rbxassetid://10734923549" }),
    Config  = G:Tab({ Name = "Config",  Image = "rbxassetid://10734950020" }),
}

-- MAIN
do
    local L = Tabs.Main:Section({ Side = "Left" })
    L:Header({ Text = "Entities" })
    L:Toggle({ Name = "Entity Alerts", Default = S.EntityAlerts, Callback = function(v) S.EntityAlerts = v end }, "EntityAlerts")
    L:Toggle({ Name = "Alert Sound", Default = S.AlertSound, Callback = function(v) S.AlertSound = v end }, "AlertSound")
    L:Toggle({ Name = "Auto Hide (Rush/Ambush/A-60)", Default = S.AutoHide, Callback = function(v) S.AutoHide = v end }, "AutoHide")
    L:Toggle({ Name = "Anti-Screech", Default = S.AntiScreech, Callback = function(v) S.AntiScreech = v end }, "AntiScreech")
    L:Toggle({ Name = "Anti-Halt", Default = S.AntiHalt, Callback = function(v) S.AntiHalt = v end }, "AntiHalt")

    local R = Tabs.Main:Section({ Side = "Right" })
    R:Header({ Text = "Interaction" })
    R:Toggle({ Name = "Instant Prompts", Default = S.InstantPrompts, Callback = function(v) S.InstantPrompts = v; refreshPrompts() end }, "InstantPrompts")
    R:Slider({ Name = "Prompt Reach", Default = 1, Minimum = 1, Maximum = 2, DisplayMethod = "Value", Precision = 1,
        Callback = function(v) S.PromptReach = v; refreshPrompts() end }, "PromptReach")
    R:Divider()
    R:Header({ Text = "Auto Loot" })
    R:Toggle({ Name = "Auto Loot (nearby)", Default = S.AutoLoot, Callback = function(v) S.AutoLoot = v end }, "AutoLoot")
    R:Toggle({ Name = "Drawers & Chests", Default = S.LootDrawers, Callback = function(v) S.LootDrawers = v end }, "LootDrawers")
    R:Toggle({ Name = "Gold", Default = S.LootGold, Callback = function(v) S.LootGold = v end }, "LootGold")
    R:Toggle({ Name = "Items", Default = S.LootItems, Callback = function(v) S.LootItems = v end }, "LootItems")
    R:Toggle({ Name = "Keys / Levers / Books", Default = S.LootKeys, Callback = function(v) S.LootKeys = v end }, "LootKeys")
end

-- VISUALS
do
    local L = Tabs.Visuals:Section({ Side = "Left" })
    L:Header({ Text = "ESP" })
    local function espToggle(name, key)
        L:Toggle({ Name = name, Default = S[key], Callback = function(v) S[key] = v; refreshAll() end }, key)
    end
    espToggle("Entity ESP", "EntityESP")
    espToggle("Door ESP", "DoorESP")
    espToggle("Key / Lever / Book ESP", "KeyESP")
    espToggle("Item ESP", "ItemESP")
    espToggle("Gold ESP", "GoldESP")
    espToggle("Hiding Spot ESP", "HideESP")
    L:Toggle({ Name = "Show Distance", Default = S.ShowDistance, Callback = function(v) S.ShowDistance = v end }, "ShowDistance")

    local R = Tabs.Visuals:Section({ Side = "Right" })
    R:Header({ Text = "World" })
    R:Toggle({ Name = "Fullbright", Default = S.Fullbright, Callback = function(v) S.Fullbright = v; if not v then restoreLighting() end end }, "Fullbright")
    R:Toggle({ Name = "No Camera Shake", Default = S.NoCamShake, Callback = function(v) S.NoCamShake = v; setShake(not v) end }, "NoCamShake")
    R:Toggle({ Name = "No Fog", Default = S.NoFog, Callback = function(v) S.NoFog = v; if not v then restoreLighting() end end }, "NoFog")
    R:Slider({ Name = "Field of View", Default = 70, Minimum = 70, Maximum = 120, DisplayMethod = "Degrees", Precision = 0,
        Callback = function(v) S.FOV = v end }, "FOV")
    R:Divider()
    R:Header({ Text = "ESP Colors" })
    for cat, def in pairs(COLORS) do
        R:Colorpicker({ Name = cat, Default = def, Callback = function(c) COLORS[cat] = c; refreshAll() end }, "Color_" .. cat)
    end
end

-- PLAYER
do
    local L = Tabs.Player:Section({ Side = "Left" })
    L:Header({ Text = "Movement" })
    L:Slider({ Name = "Speed Boost", Default = 0, Minimum = 0, Maximum = 6, DisplayMethod = "Value", Precision = 0,
        Callback = function(v) S.SpeedBoost = v; applySpeed() end }, "SpeedBoost")
    L:SubLabel({ Text = "Adds to the game's own speed system (capped at +6: anything higher gets rubber-banded)." })

    local R = Tabs.Player:Section({ Side = "Right" })
    R:Header({ Text = "Info" })
    local roomLabel = R:Label({ Text = "Room: ?" })
    local statusLabel = R:Label({ Text = "Farm: Idle" })
    task.spawn(function()
        while alive do
            pcall(function()
                roomLabel:UpdateName("Room: " .. tostring(GameData.LatestRoom.Value) .. "  |  Floor: " .. tostring(GameData.Floor.Value))
                statusLabel:UpdateName("Farm: " .. farmStatus)
            end)
            task.wait(0.5)
        end
    end)
end

-- FARM
do
    local L = Tabs.Farm:Section({ Side = "Left" })
    L:Header({ Text = "Auto Farm" })
    L:Toggle({ Name = "Auto Walk (key → door)", Default = S.AutoWalk, Callback = function(v)
        S.AutoWalk = v
        applySpeed()
        if not v and hum() then hum():Move(Vector3.zero) end
    end }, "AutoWalk")
    L:Slider({ Name = "Farm Speed Boost", Default = S.FarmSpeed, Minimum = 0, Maximum = 6, DisplayMethod = "Value", Precision = 0,
        Callback = function(v) S.FarmSpeed = v; applySpeed() end }, "FarmSpeed")
    L:Toggle({ Name = "Auto Open Doors", Default = S.AutoOpenDoors, Callback = function(v) S.AutoOpenDoors = v end }, "AutoOpenDoors")
    L:Paragraph({ Header = "Best setup", Body = "Auto Walk + Auto Open Doors + Auto Loot + Auto Hide + Entity Alerts. Walks with pathfinding at Farm Speed (no teleports - the server rubber-bands those). If a room's layout beats the pathfinder for 20s you get a notification: walk that room yourself and the farm picks up again at the next one. Puzzle rooms (50 library, 100 breaker) are manual." })
end

-- CONFIG
do
    local L = Tabs.Config:Section({ Side = "Left" })
    L:Button({ Name = "Unload Hub", Callback = function() unload() end })
    MacLib:SetFolder("VoidHub_Doors")
    Tabs.Config:InsertConfigSection("Right")
end

Window.onUnloaded(function() task.defer(unload) end)
Tabs.Main:Select()
pcall(function() MacLib:LoadAutoLoadConfig() end)
notify("VOID HUB", "Loaded. RightControl toggles the menu.", 5)
