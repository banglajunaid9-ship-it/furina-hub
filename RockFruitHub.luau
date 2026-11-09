--[[
    Rock Fruit Hub  (WindUI)
    Run through live-reload with a stable label so re-runs replace the old copy.
    Findings this is built on (verified in game):
      * Quests are chosen by Player attribute "Level": Workspace.NpcQuest.NPC_QuestN carries
        attributes Level (min level) and Name (mob to kill), plus a ProximityPrompt "Accept Quest".
      * Active quest is the Player attribute "Quest" (JSON: Title/Current/Max/...), "[]" when none.
      * Mobs are Models in Workspace.Mob (Humanoid + HumanoidRootPart).
      * Attacking = tool:Activate() on the equipped tool (the tool script then fires Remotes.Action).
      * Everything else goes through ReplicatedStorage.Modules.NetworkFramework.NetworkEvent:
            NetworkEvent:FireServer("fire", nil, <name>, ...)
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local Lighting = game:GetService("Lighting")
local LP = Players.LocalPlayer

-- STATE is provided by live-reload; fall back to a stub if run any other way.
local S = STATE
if not S then
    S = {
        onCleanup = function() end,
        connect = function(sig, fn) return sig:Connect(fn) end,
        alive = function() return true end,
    }
end

local dead = false
local notify -- assigned once the UI library is loaded
local function up() return S.alive() and not dead end

---------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------
local Remotes = RS:WaitForChild("Remotes")
local ActionRE = Remotes:WaitForChild("Action")
local InventoryRE = Remotes:WaitForChild("Inventory")
local SystemRE = Remotes:WaitForChild("System")
local NetEvent = RS:WaitForChild("Modules"):WaitForChild("NetworkFramework"):WaitForChild("NetworkEvent")

local function net(name, ...)
    NetEvent:FireServer("fire", nil, name, ...)
end

---------------------------------------------------------------------
-- Config
---------------------------------------------------------------------
local C = {
    farm = false,
    mode = "Quest Level", -- "Quest Level" | "Selected Mob" | "Nearest Any"
    selMob = nil,
    autoQuest = true,
    moveMode = "Teleport", -- "Teleport" | "Tween"
    tweenSpeed = 300,
    dist = 3,
    height = 0,
    atkDelay = 0.06,
    maxFight = 25,
    retreatPct = 60,    -- hide when health drops below this percent
    safeMode = true,    -- retreat / stuck-skip / void guard / skip mobs we cannot hurt
    jitter = true,      -- randomise swing timing a little
    cluster = true,     -- prefer mobs that have friends nearby
    stuckTime = 4,      -- skip a mob that has not lost health for this long
    fpsBoost = false,
    render3d = true,
    breaks = false,     -- periodic rest breaks while farming
    pauseNear = false,  -- pause farming when another player is close
    nearDist = 60,
    weaponType = "Melee",
    autoEquip = true,
    skills = { z = false, x = false, c = false, v = false },
    skillDelay = 1.5,
    autoBuso = false,
    autoStats = false,
    statPick = "Melee + Defense",
    statSplit = false,
    autoDaily = false,
    autoBoost = false,
    autoCraft = false,
    craftType = "All",
    noclip = false,
    speedOn = false,
    speed = 60,
    jumpOn = false,
    jump = 70,
    infJump = false,
    antiAfk = true,
    fullbright = false,
    espMob = false,
    espPlayer = false,
}

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function getHRP()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHum()
    local c = LP.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

-- weapon name -> category (Melee / Sword / Special / DevilFruit)
local weaponType = {}
for _, folder in ipairs(RS:WaitForChild("Weapon"):GetChildren()) do
    for _, w in ipairs(folder:GetChildren()) do
        weaponType[w.Name] = folder.Name
    end
end

local function currentTool()
    local c = LP.Character
    return c and c:FindFirstChildOfClass("Tool")
end

local function pickTool()
    local cur = currentTool()
    if cur and weaponType[cur.Name] == C.weaponType then return cur end
    for _, t in ipairs(LP.Backpack:GetChildren()) do
        if t:IsA("Tool") and weaponType[t.Name] == C.weaponType then return t end
    end
end

local function ensureTool()
    local hum = getHum()
    if not hum then return nil end
    local cur = currentTool()
    if not C.autoEquip then return cur end
    if cur and weaponType[cur.Name] == C.weaponType then return cur end
    local want = pickTool()
    if want and want.Parent ~= LP.Character then
        hum:EquipTool(want)
        task.wait(0.12)
        return currentTool()
    end
    if not cur then
        local any = LP.Backpack:FindFirstChildOfClass("Tool")
        if any then
            hum:EquipTool(any)
            task.wait(0.12)
        end
    end
    return currentTool()
end

local function travel(cf)
    local hrp = getHRP()
    if not hrp then return end
    local d = (hrp.Position - cf.Position).Magnitude
    if C.moveMode == "Tween" and d > 25 then
        local tw = TweenService:Create(hrp, TweenInfo.new(d / math.max(C.tweenSpeed, 30), Enum.EasingStyle.Linear), { CFrame = cf })
        tw:Play()
        while tw.PlaybackState == Enum.PlaybackState.Playing and up() and C.farm do
            hrp.AssemblyLinearVelocity = Vector3.zero
            task.wait()
        end
        tw:Cancel()
    else
        hrp.CFrame = cf
    end
end

local function pivotOf(inst)
    if inst:IsA("BasePart") then return inst.CFrame end
    if inst:IsA("Model") then return inst:GetPivot() end
    local p = inst:FindFirstChildWhichIsA("BasePart", true)
    return p and p.CFrame
end

---------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------
local questList = {}
local function buildQuestList()
    table.clear(questList)
    for _, n in ipairs(workspace:WaitForChild("NpcQuest"):GetChildren()) do
        local lv, nm = n:GetAttribute("Level"), n:GetAttribute("Name")
        if lv and nm then
            -- cache the NPC position now so we can still travel to it if it is streamed out later
            table.insert(questList, { npc = n, level = lv, mob = nm, cf = n:GetPivot() })
        end
    end
    table.sort(questList, function(a, b) return a.level < b.level end)
end
buildQuestList()

local function questForLevel(lv)
    local best
    for _, q in ipairs(questList) do
        if q.level <= lv then best = q else break end
    end
    return best
end

local function activeQuest()
    local raw = LP:GetAttribute("Quest")
    if type(raw) ~= "string" or raw == "" or raw == "[]" then return nil end
    local ok, d = pcall(HttpService.JSONDecode, HttpService, raw)
    if ok and type(d) == "table" and d.Title then return d end
    return nil
end

local lastAccept, lastCancel, acceptedFor = 0, 0, nil
local titleOf = {} -- quest mob name -> the Title the server actually gives that quest (learned)
local acceptFails = 0

-- Walks to the quest NPC, waits for its prompt to exist, fires it until the Quest attribute changes.
-- Returns true when the server accepted it.
local function acceptQuest(q)
    lastAccept = tick()
    local before = LP:GetAttribute("Quest")
    local root = q.npc.Parent and q.npc:FindFirstChild("HumanoidRootPart")
    local cf = root and root.CFrame or q.cf
    travel(cf * CFrame.new(0, 0, 4))

    local pr
    local t0 = tick()
    while up() and C.farm and tick() - t0 < 5 do
        root = q.npc.Parent and q.npc:FindFirstChild("HumanoidRootPart")
        pr = root and root:FindFirstChildOfClass("ProximityPrompt")
        if pr then break end
        -- stay on top of the NPC so it streams in
        local hrp = getHRP()
        if hrp then hrp.CFrame = cf * CFrame.new(0, 0, 4) end
        task.wait(0.2)
    end
    if not pr then
        acceptFails += 1
        return false
    end

    task.wait(0.3)
    pr.HoldDuration = 0
    pr.RequiresLineOfSight = false
    for _ = 1, 3 do
        if not (up() and C.farm) then return false end
        fireproximityprompt(pr)
        local t1 = tick()
        while tick() - t1 < 1.2 do
            if LP:GetAttribute("Quest") ~= before then
                local a = activeQuest()
                if a then titleOf[q.mob] = a.Title end
                acceptedFor = q.mob
                acceptFails = 0
                return true
            end
            task.wait(0.05)
        end
    end
    acceptFails += 1
    return false
end

-- Where to look when a quest's mobs are not in Workspace.Mob (they may only spawn when you are close).
local spawnPoints
local function nearbySpawnPoints(origin)
    if not spawnPoints then
        spawnPoints = {}
        local g = workspace:FindFirstChild("MobSpawnGroup")
        if g then
            for _, p in ipairs(g:GetChildren()) do
                if p:IsA("BasePart") then table.insert(spawnPoints, p.Position) end
            end
        end
    end
    local list = { origin }
    for _, p in ipairs(spawnPoints) do
        if (p - origin).Magnitude < 350 then table.insert(list, p) end
    end
    return list
end
local searchIdx, lastSearchMove = 0, 0

---------------------------------------------------------------------
-- Farming
---------------------------------------------------------------------
local statusText = "Idle"
local statusObj
local function setStatus(t)
    if t == statusText then return end
    statusText = t
    if statusObj then pcall(function() statusObj:SetDesc(t) end) end
end

local blacklist = {} -- mob model -> expiry time (stuck / unhittable)

local function usable(m, name)
    if name ~= nil and m.Name ~= name then return false end
    local bl = blacklist[m]
    if bl and bl > tick() then return false end
    -- logia mobs ignore normal hits unless Buso Haki is on
    if C.safeMode and m:GetAttribute("HitLogia") and not LP:GetAttribute("BusoHaki") then return false end
    local mh = m:FindFirstChildOfClass("Humanoid")
    return mh ~= nil and mh.Health > 0 and m:FindFirstChild("HumanoidRootPart") ~= nil
end

local function findTarget(name)
    local h0 = getHRP()
    if not h0 then return nil end
    local pool = {}
    for _, m in ipairs(workspace.Mob:GetChildren()) do
        if usable(m, name) then table.insert(pool, m) end
    end
    local best, bs = nil, -math.huge
    for _, m in ipairs(pool) do
        local p = m.HumanoidRootPart.Position
        local score = -(p - h0.Position).Magnitude / 40
        if C.cluster then
            local friends = 0
            for _, o in ipairs(pool) do
                if o ~= m and (o.HumanoidRootPart.Position - p).Magnitude < 18 then friends += 1 end
            end
            score += math.min(friends, 5) * 0.6
        end
        if score > bs then best, bs = m, score end
    end
    return best
end

local lastSafeCF
local nextBreak = tick() + math.random(480, 900)
local hubAnchored = false
-- Resting: health only regenerates (about 1% per second) while the character is on the ground and not anchored,
-- so we rest on the nearest SafeZone part instead of hovering in the sky. After a rest there is a cooldown so a
-- slowly-healing character cannot get stuck resting forever.
local noRetreatUntil = 0
local function lowHP(hum)
    local frac = hum.Health / hum.MaxHealth
    if frac < 0.15 then return true end
    return tick() > noRetreatUntil and frac * 100 < C.retreatPct
end

local function nearestSafeZone(pos)
    local best, bd
    local g = workspace:FindFirstChild("SafeZone")
    if g then
        for _, p in ipairs(g:GetChildren()) do
            if p:IsA("BasePart") and p.Position.Y < 1000 then
                local d = (p.Position - pos).Magnitude
                if not bd or d < bd then best, bd = p, d end
            end
        end
    end
    return best
end

local function hideUntilHealed()
    local hrp, hum = getHRP(), getHum()
    if not hrp or not hum then return end
    local zone = nearestSafeZone(hrp.Position)
    local dest = lastSafeCF
    if zone then
        -- zones are big invisible boxes: raycast down from their centre to find real ground to stand on
        local filter = { LP.Character, workspace:FindFirstChild("Mob"), workspace:FindFirstChild("SafeZone") }
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.FilterDescendantsInstances = filter
        local c = zone.Position
        local hit = workspace:Raycast(Vector3.new(c.X, c.Y + 300, c.Z), Vector3.new(0, -700, 0), rp)
        dest = CFrame.new(hit and (hit.Position + Vector3.new(0, 4, 0)) or (c + Vector3.new(0, zone.Size.Y / 2 + 4, 0)))
    end
    if dest then
        hrp.Anchored = false
        hrp.CFrame = dest
    end
    local t0 = tick()
    while up() and C.farm do
        hum, hrp = getHum(), getHRP()
        if not hum or not hrp or hum.Health <= 0 then return end
        local pct = math.floor(hum.Health / hum.MaxHealth * 100)
        setStatus(("Low HP - resting in safe zone (%d%%)"):format(pct))
        -- rest until clearly above the retreat line (at least 80%), but never longer than a minute
        local restTo = math.min(100, math.max(80, C.retreatPct + 15))
        if hum.Health >= hum.MaxHealth * restTo / 100 or tick() - t0 > 60 then break end
        task.wait(0.5)
    end
    noRetreatUntil = tick() + 30
end

local SKILL_KEYS = { "z", "x", "c", "v" }
local lastTargetPos

local function fightTarget(target)
    local mh = target:FindFirstChildOfClass("Humanoid")
    if not mh then return end
    local t0, lastHit, lastSkill = tick(), 0, 0
    local nextDelay = C.atkDelay
    local lastHP, lastHPChange = mh.Health, tick()
    while up() and C.farm and target.Parent and mh.Health > 0 and tick() - t0 < C.maxFight do
        local hrp, hum = getHRP(), getHum()
        if not hrp or not hum or hum.Health <= 0 then return end
        local tr = target:FindFirstChild("HumanoidRootPart")
        if not tr then return end
        lastTargetPos = tr.Position
        if C.safeMode then
            if lowHP(hum) then
                hideUntilHealed()
                return
            end
            if mh.Health < lastHP then
                lastHP, lastHPChange = mh.Health, tick()
            elseif tick() - lastHPChange > C.stuckTime then
                blacklist[target] = tick() + 20 -- cannot hurt it (logia/invulnerable/stuck): skip for a while
                return
            end
            if hrp.Position.Y < -100 and lastSafeCF then hrp.CFrame = lastSafeCF end
        end
        local pos = (tr.CFrame * CFrame.new(0, C.height, C.dist)).Position
        hrp.CFrame = CFrame.lookAt(pos, tr.Position)
        hrp.AssemblyLinearVelocity = Vector3.zero
        local tool = ensureTool()
        local now = tick()
        if tool and now - lastHit >= nextDelay then
            lastHit = now
            tool:Activate()
            nextDelay = C.jitter and C.atkDelay * (0.85 + math.random() * 0.4) or C.atkDelay
        end
        if tool and now - lastSkill >= C.skillDelay then
            lastSkill = now
            for _, k in ipairs(SKILL_KEYS) do
                if C.skills[k] then ActionRE:FireServer(tool.Name, k) end
            end
        end
        RunService.Heartbeat:Wait()
    end
end

local function farmStep()
    local hrp, hum = getHRP(), getHum()
    if not hrp or not hum or hum.Health <= 0 then
        setStatus("Waiting for respawn...")
        task.wait(0.5)
        return
    end

    if C.breaks and tick() > nextBreak then
        local rest = math.random(20, 60)
        local untilT = tick() + rest
        while up() and C.farm and tick() < untilT do
            setStatus(("Resting (%ds left)"):format(math.ceil(untilT - tick())))
            task.wait(0.5)
        end
        nextBreak = tick() + math.random(480, 900)
        return
    end
    if C.pauseNear then
        for _, p in ipairs(Players:GetPlayers()) do
            local ph = p ~= LP and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
            if ph and (ph.Position - hrp.Position).Magnitude < C.nearDist then
                setStatus("Paused: " .. p.Name .. " is nearby")
                task.wait(1)
                return
            end
        end
    end
    if C.safeMode then
        if hrp.Position.Y > -50 and not hrp.Anchored then lastSafeCF = hrp.CFrame end
        if lowHP(hum) then
            hideUntilHealed()
            return
        end
    end

    local mobName
    local curQ
    if C.mode == "Quest Level" then
        local q = questForLevel(LP:GetAttribute("Level") or 1)
        curQ = q
        local aq = activeQuest()
        if C.autoQuest and q then
            -- A quest for a lower-level mob is still active: take the right one. (Verified: the Cancel event
            -- does not clear a quest, but accepting a new NPC's quest replaces it.) Retries forever, 6s apart.
            local wantTitle = titleOf[q.mob] or q.mob
            if aq and aq.Title ~= wantTitle and tick() - lastAccept > 6 then
                setStatus("Level up - getting the quest for " .. q.mob)
                aq = nil -- fall through to the accept step below
            end
            local finished = aq and aq.Current and aq.Max and aq.Current >= aq.Max
            if (not aq or finished) and tick() - lastAccept > (acceptFails > 0 and 2 or 0.5) then
                setStatus("Accepting quest: " .. q.mob .. (acceptFails > 0 and (" (try " .. acceptFails + 1 .. ")") or ""))
                acceptQuest(q)
                return
            end
        end
        mobName = q and q.mob
        if not mobName then
            setStatus("No quest found for your level")
            task.wait(1)
            return
        end
    elseif C.mode == "Selected Mob" then
        mobName = C.selMob
        if not mobName then
            setStatus("Pick a mob in the dropdown")
            task.wait(1)
            return
        end
    end

    local target = findTarget(mobName)
    if not target then
        setStatus("Looking for " .. tostring(mobName or "mobs") .. "...")
        -- mobs for a far-away quest may only exist once you are close: sweep the area around the quest NPC
        local points = curQ and nearbySpawnPoints(curQ.cf.Position)
        if points and #points > 0 then
            if tick() - lastSearchMove > 2.5 then
                lastSearchMove = tick()
                searchIdx = searchIdx % #points + 1
                travel(CFrame.new(points[searchIdx] + Vector3.new(0, 6, 0)))
            end
        elseif lastTargetPos and (hrp.Position - lastTargetPos).Magnitude > 60 then
            travel(CFrame.new(lastTargetPos + Vector3.new(0, 4, 0)))
        end
        task.wait(0.3)
        return
    end

    local tr = target:FindFirstChild("HumanoidRootPart")
    if tr and (hrp.Position - tr.Position).Magnitude > 80 then
        setStatus("Travelling to " .. target.Name)
        travel(tr.CFrame * CFrame.new(0, C.height, C.dist))
    end
    local aq = activeQuest()
    setStatus(("Fighting %s%s | Lv %s"):format(
        target.Name,
        aq and (" | quest " .. tostring(aq.Current) .. "/" .. tostring(aq.Max)) or "",
        tostring(LP:GetAttribute("Level") or "?")))
    fightTarget(target)
end

task.spawn(function()
    while up() do
        if C.farm then
            local ok, err = pcall(farmStep)
            if not ok then
                warn("[RockFruitHub] farm error: " .. tostring(err))
                task.wait(1)
            end
        else
            setStatus("Idle")
            local hrp = getHRP()
            if hrp and hubAnchored then hrp.Anchored = false hubAnchored = false end
            task.wait(0.25)
        end
        RunService.Heartbeat:Wait()
    end
end)

---------------------------------------------------------------------
-- Background helpers: stats, daily, boosts, buso
---------------------------------------------------------------------
local STAT_NAMES = { "Melee", "Defense", "Sword", "Power" }
local BOOSTS = {
    ["X2 EXP 15min."] = "x2Exp",
    ["X2 Diamond 15min."] = "x2Diamond",
    ["X2 Lucky 15min."] = "x2Luck",
    ["X2 Rebirth 15min."] = "x2Rebirth",
    ["X2 Item 15min."] = "x2Item",
}

local function decodeAttr(name)
    local raw = LP:GetAttribute(name)
    if type(raw) ~= "string" then return nil end
    local ok, d = pcall(HttpService.JSONDecode, HttpService, raw)
    return ok and d or nil
end

-- Auto craft: recipes live in ReplicatedStorage.Modules.UseItems. Crafting is a plain
-- NetworkEvent fire ("Craft", name, type) and works from anywhere; the game equips the result itself.
local okRecipes, Recipes = pcall(function() return require(RS.Modules.UseItems) end)
if not okRecipes then Recipes = {} end

local function craftable(name, r, inv)
    if inv[name] then return false end -- already own it
    if C.craftType ~= "All" and r.Type ~= C.craftType then return false end
    if r.NeedClass then
        local uc = LP:GetAttribute("UseClass")
        if type(uc) ~= "string" or not uc:find(r.NeedClass, 1, true) then return false end
    end
    for item, n in pairs(r.Inventory or {}) do
        local e = inv[item]
        if not e or (e.amount or 1) < n then return false end
    end
    for attr, n in pairs(r.PlayerData or {}) do
        if (LP:GetAttribute(attr) or 0) < n then return false end
    end
    return true
end

local function craftAll()
    local crafted = {}
    local inv = decodeAttr("Inventory")
    if not inv then return crafted end
    -- cheapest first so prerequisites (e.g. Tanto -> Katana) are made in order
    local names = {}
    for name in pairs(Recipes) do table.insert(names, name) end
    table.sort(names, function(a, b)
        return ((Recipes[a].PlayerData or {}).Beli or 0) < ((Recipes[b].PlayerData or {}).Beli or 0)
    end)
    for _, name in ipairs(names) do
        local r = Recipes[name]
        if craftable(name, r, inv) then
            net("Craft", name, r.Type)
            table.insert(crafted, name)
            task.wait(1.2)
            inv = decodeAttr("Inventory") or inv
        end
    end
    return crafted
end

task.spawn(function()
    local tStats, tDaily, tBoost, tBuso, tCraft = 0, 0, 0, 0, 0
    while up() do
        local now = tick()

        if C.autoCraft and now - tCraft > 8 then
            tCraft = now
            local done = craftAll()
            if #done > 0 then notify("Auto Craft", "Crafted: " .. table.concat(done, ", ")) end
        end

        if C.autoStats and now - tStats > 2 then
            tStats = now
            local pts = LP:GetAttribute("Point") or 0
            if pts > 0 then
                if C.statPick == "Melee + Defense" then
                    local half = math.floor(pts / 2)
                    if half > 0 then
                        SystemRE:FireServer("UpStats", "Melee", half)
                        SystemRE:FireServer("UpStats", "Defense", pts - half)
                    else
                        SystemRE:FireServer("UpStats", "Defense", pts)
                    end
                elseif C.statSplit then
                    local each = math.floor(pts / #STAT_NAMES)
                    if each > 0 then
                        for _, s in ipairs(STAT_NAMES) do SystemRE:FireServer("UpStats", s, each) end
                    else
                        SystemRE:FireServer("UpStats", C.statPick, pts)
                    end
                else
                    SystemRE:FireServer("UpStats", C.statPick, pts)
                end
            end
        end

        if C.autoDaily and now - tDaily > 30 then
            tDaily = now
            local d = decodeAttr("Daily")
            if d then
                for i = 1, 7 do
                    local e = d[tostring(i)]
                    if e and not e.Claim and e.Time and os.time() - e.Time > 0 then
                        net("daily", tostring(i))
                        task.wait(1)
                    end
                end
            end
        end

        if C.autoBoost and now - tBoost > 20 then
            tBoost = now
            local inv = decodeAttr("Inventory")
            if inv then
                for item, multAttr in pairs(BOOSTS) do
                    local e = inv[item]
                    local mult = LP:GetAttribute(multAttr)
                    if e and (e.amount or 0) > 0 and (mult == nil or mult <= 1) then
                        InventoryRE:FireServer(item)
                        task.wait(1)
                    end
                end
            end
        end

        if C.autoBuso and now - tBuso > 5 then
            tBuso = now
            if LP:GetAttribute("BusoHaki") == false and getHum() and getHum().Health > 0 then
                ActionRE:FireServer("Misc", "buso")
            end
        end

        task.wait(0.5)
    end
end)

---------------------------------------------------------------------
-- Player tweaks
---------------------------------------------------------------------
S.connect(RunService.Stepped, function()
    if not (C.noclip or C.farm) then return end
    local c = LP.Character
    if not c then return end
    for _, p in ipairs(c:GetChildren()) do
        if p:IsA("BasePart") then p.CanCollide = false end
    end
end)

S.connect(RunService.Heartbeat, function()
    local hum = getHum()
    if not hum then return end
    if C.speedOn then hum.WalkSpeed = C.speed end
    if C.jumpOn then
        hum.UseJumpPower = true
        hum.JumpPower = C.jump
    end
end)

S.connect(UIS.JumpRequest, function()
    if C.infJump then
        local hum = getHum()
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)

S.connect(LP.Idled, function()
    if C.antiAfk then
        local vu = game:GetService("VirtualUser")
        vu:CaptureController()
        vu:ClickButton2(Vector2.new())
    end
end)

local lightBackup
local function setFullbright(on)
    if on then
        lightBackup = lightBackup or {
            Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
            GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient,
        }
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.FogEnd = 1e6
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
    elseif lightBackup then
        for k, v in pairs(lightBackup) do Lighting[k] = v end
    end
end

---------------------------------------------------------------------
-- Performance boosters
---------------------------------------------------------------------
local fpsDisabled = {}
local fpsConn
local origQuality, origShadows
local function isEffect(d)
    return d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Smoke") or d:IsA("Fire") or d:IsA("Sparkles")
end
local function setFpsBoost(on)
    if on then
        origShadows = Lighting.GlobalShadows
        pcall(function() origQuality = settings().Rendering.QualityLevel end)
        Lighting.GlobalShadows = false
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
        for _, d in ipairs(workspace:GetDescendants()) do
            if isEffect(d) and d.Enabled then fpsDisabled[d] = true d.Enabled = false end
        end
        if fpsConn then fpsConn:Disconnect() end
        fpsConn = workspace.DescendantAdded:Connect(function(d)
            if isEffect(d) then
                task.defer(function()
                    if d.Parent and d.Enabled then fpsDisabled[d] = true d.Enabled = false end
                end)
            end
        end)
    else
        if fpsConn then fpsConn:Disconnect() fpsConn = nil end
        for d in pairs(fpsDisabled) do if d.Parent then d.Enabled = true end end
        table.clear(fpsDisabled)
        if origShadows ~= nil then Lighting.GlobalShadows = origShadows end
        if origQuality then pcall(function() settings().Rendering.QualityLevel = origQuality end) end
    end
end
local function set3d(on)
    pcall(function() RunService:Set3dRenderingEnabled(on) end)
end
S.onCleanup(function()
    setFpsBoost(false)
    set3d(true)
    local hrp = getHRP()
    if hrp and hubAnchored then hrp.Anchored = false end
end)

---------------------------------------------------------------------
-- ESP (Highlights, removed on reload/unload)
---------------------------------------------------------------------
local espObjects = {}
local function clearESP()
    for inst in pairs(espObjects) do pcall(function() inst:Destroy() end) end
    table.clear(espObjects)
end
S.onCleanup(clearESP)
S.onCleanup(function() setFullbright(false) end)

local function espOn(model, color)
    if espObjects[model] and espObjects[model].Parent then return end
    local h = Instance.new("Highlight")
    h.Name = "HubESP"
    h.Adornee = model
    h.FillColor = color
    h.FillTransparency = 0.6
    h.OutlineColor = color
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.Parent = model
    espObjects[h] = true
    espObjects[model] = h
end

task.spawn(function()
    while up() do
        if C.espMob then
            for _, m in ipairs(workspace.Mob:GetChildren()) do
                local mh = m:FindFirstChildOfClass("Humanoid")
                if mh and mh.Health > 0 and not m:FindFirstChild("HubESP") then espOn(m, Color3.fromRGB(255, 80, 80)) end
            end
        end
        if C.espPlayer then
            for _, m in ipairs(workspace.Character:GetChildren()) do
                if m.Name ~= LP.Name and not m:FindFirstChild("HubESP") then espOn(m, Color3.fromRGB(80, 200, 255)) end
            end
        end
        task.wait(1)
    end
end)

local function removeESPOf(kind)
    for inst in pairs(espObjects) do
        if typeof(inst) == "Instance" and inst.Name == "HubESP" then
            local m = inst.Parent
            local isMob = m and m.Parent == workspace.Mob
            if (kind == "mob" and isMob) or (kind == "player" and not isMob) then
                inst:Destroy()
                espObjects[inst] = nil
                espObjects[m] = nil
            end
        end
    end
end

---------------------------------------------------------------------
-- Teleport data
---------------------------------------------------------------------
local tpQuestNames, tpQuestCF = {}, {}
for _, q in ipairs(questList) do
    local root = q.npc:FindFirstChild("HumanoidRootPart")
    if root then
        local label = ("[Lv %d] %s"):format(q.level, q.mob)
        table.insert(tpQuestNames, label)
        tpQuestCF[label] = root.CFrame * CFrame.new(0, 0, 4)
    end
end

local tpPlaceNames, tpPlaceCF = {}, {}
local function addPlaces(folder, prefix)
    if not folder then return end
    for _, x in ipairs(folder:GetChildren()) do
        local cf = pivotOf(x)
        if cf then
            local label = prefix .. x.Name
            if not tpPlaceCF[label] then
                table.insert(tpPlaceNames, label)
                tpPlaceCF[label] = cf * CFrame.new(0, 0, 4)
            end
        end
    end
end
addPlaces(workspace:FindFirstChild("NpcPrompt"), "NPC: ")
addPlaces(workspace:FindFirstChild("NpcRandomFruit"), "Fruit NPC: ")
addPlaces(workspace:FindFirstChild("NpcBoss"), "Boss NPC: ")
addPlaces(workspace:FindFirstChild("island"), "Island: ")
table.sort(tpPlaceNames)
if #tpPlaceNames == 0 then tpPlaceNames = { "(none found)" } end

local function tpTo(cf)
    local hrp = getHRP()
    if hrp and cf then hrp.CFrame = cf end
end

---------------------------------------------------------------------
-- UI (WindUI)
---------------------------------------------------------------------
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Window = WindUI:CreateWindow({
    Title = "Rock Fruit Hub",
    Icon = "swords",
    Author = "auto farm | quests | items | tools",
    Folder = "RockFruitHub",
    Size = UDim2.fromOffset(620, 480),
    Theme = "Dark",
    Resizable = true,
    HideSearchBar = true,
    ToggleKey = Enum.KeyCode.RightShift,
})
S.onCleanup(function() pcall(function() Window:Destroy() end) end)

notify = function(title, content)
    pcall(function() WindUI:Notify({ Title = title, Content = content, Duration = 4, Icon = "bell" }) end)
end

-- ===== Farm tab =====
local Farm = Window:Tab({ Title = "Auto Farm", Icon = "swords" })
statusObj = Farm:Paragraph({ Title = "Status", Desc = "Idle" })

Farm:Toggle({
    Title = "Auto Farm Level",
    Desc = "Accepts the quest for your level, kills its mobs, claims the reward and moves to the next quest as you level up.",
    Value = false,
    Callback = function(v) C.farm = v end,
})
Farm:Dropdown({
    Title = "Farm Mode",
    Desc = "Quest Level = follow quests. Selected Mob = hunt one type. Nearest Any = hit whatever is closest.",
    Values = { "Quest Level", "Selected Mob", "Nearest Any" },
    Value = "Quest Level",
    Callback = function(v) C.mode = v end,
})

-- mob names: every quest mob plus whatever is alive right now
local mobNames, seen = {}, {}
for _, q in ipairs(questList) do
    if not seen[q.mob] then seen[q.mob] = true table.insert(mobNames, q.mob) end
end
for _, m in ipairs(workspace.Mob:GetChildren()) do
    if not seen[m.Name] then seen[m.Name] = true table.insert(mobNames, m.Name) end
end
table.sort(mobNames)
Farm:Dropdown({
    Title = "Selected Mob",
    Desc = "Used when Farm Mode is Selected Mob (includes Kraken / DevilBoat when spawned).",
    Values = mobNames,
    Callback = function(v) C.selMob = v end,
})
Farm:Toggle({
    Title = "Auto Accept Quest",
    Value = true,
    Callback = function(v) C.autoQuest = v end,
})

Farm:Section({ Title = "Combat" })
Farm:Dropdown({
    Title = "Weapon Type",
    Desc = "Which kind of tool the hub equips and swings.",
    Values = { "Melee", "Sword", "Special", "DevilFruit" },
    Value = "Melee",
    Callback = function(v) C.weaponType = v end,
})
Farm:Toggle({
    Title = "Auto Equip Weapon",
    Value = true,
    Callback = function(v) C.autoEquip = v end,
})
Farm:Slider({
    Title = "Attack Delay (s)",
    Desc = "Lower = faster swings. The game still applies its own cooldown.",
    Value = { Min = 0.03, Max = 0.6, Default = 0.06 },
    Step = 0.01,
    Callback = function(v) C.atkDelay = v end,
})
Farm:Slider({
    Title = "Distance Behind Mob",
    Value = { Min = 0, Max = 12, Default = 3 },
    Step = 1,
    Callback = function(v) C.dist = v end,
})
Farm:Slider({
    Title = "Height Above Mob",
    Value = { Min = -5, Max = 20, Default = 0 },
    Step = 1,
    Callback = function(v) C.height = v end,
})
Farm:Dropdown({
    Title = "Movement",
    Desc = "Tween is slower but looks more natural on long trips.",
    Values = { "Teleport", "Tween" },
    Value = "Teleport",
    Callback = function(v) C.moveMode = v end,
})
Farm:Slider({
    Title = "Tween Speed",
    Value = { Min = 60, Max = 600, Default = 300 },
    Step = 10,
    Callback = function(v) C.tweenSpeed = v end,
})

local atkSlider, moveDrop
Farm:Dropdown({
    Title = "Farm Profile",
    Desc = "Legit = slow, tween movement, rest breaks, pauses near players (lowest profile). Balanced = default. Max = fastest swings.",
    Values = { "Legit", "Balanced", "Max" },
    Value = "Balanced",
    Callback = function(v)
        if v == "Legit" then
            C.atkDelay, C.moveMode, C.tweenSpeed, C.jitter, C.breaks, C.pauseNear = 0.14, "Tween", 250, true, true, true
        elseif v == "Max" then
            C.atkDelay, C.moveMode, C.jitter, C.breaks, C.pauseNear = 0.03, "Teleport", true, false, false
        else
            C.atkDelay, C.moveMode, C.jitter, C.breaks, C.pauseNear = 0.06, "Teleport", true, false, false
        end
        notify("Farm Profile", v .. " applied (sliders below show your manual values, the profile overrides them)")
    end,
})
Farm:Toggle({
    Title = "Rest Breaks",
    Desc = "Pauses 20-60s every 8-15 minutes so you do not farm non-stop.",
    Value = false,
    Callback = function(v) C.breaks = v end,
})
Farm:Toggle({
    Title = "Pause When Players Nearby",
    Desc = "Stops farming while another player is within the distance below (fewer witnesses and reports).",
    Value = false,
    Callback = function(v) C.pauseNear = v end,
})
Farm:Slider({
    Title = "Nearby Distance",
    Value = { Min = 20, Max = 200, Default = 60 },
    Step = 5,
    Callback = function(v) C.nearDist = v end,
})

Farm:Section({ Title = "Safety" })
Farm:Toggle({
    Title = "Safe Mode",
    Desc = "Rests in the nearest safe zone when low on health (then farms at least 30s before resting again), skips mobs you cannot hurt (logia mobs need Buso Haki), skips stuck mobs and recovers from falling into the void.",
    Value = true,
    Callback = function(v) C.safeMode = v end,
})
Farm:Slider({
    Title = "Retreat Below Health %",
    Value = { Min = 10, Max = 90, Default = 60 },
    Step = 5,
    Callback = function(v) C.retreatPct = v end,
})
Farm:Toggle({
    Title = "Human-like Swing Timing",
    Value = true,
    Callback = function(v) C.jitter = v end,
})
Farm:Toggle({
    Title = "Prefer Mob Clusters",
    Desc = "Picks targets with other mobs close by so area hits land on more of them.",
    Value = true,
    Callback = function(v) C.cluster = v end,
})

Farm:Section({ Title = "Skills (experimental)" })
for _, k in ipairs(SKILL_KEYS) do
    Farm:Toggle({
        Title = "Auto Skill " .. k:upper(),
        Value = false,
        Callback = function(v) C.skills[k] = v end,
    })
end
Farm:Slider({
    Title = "Skill Delay (s)",
    Value = { Min = 0.3, Max = 8, Default = 1.5 },
    Step = 0.1,
    Callback = function(v) C.skillDelay = v end,
})
Farm:Toggle({
    Title = "Auto Buso Haki",
    Desc = "Fires the buso toggle when it is off. Only does anything if you own it.",
    Value = false,
    Callback = function(v) C.autoBuso = v end,
})

-- ===== Items & Stats tab =====
local Items = Window:Tab({ Title = "Items & Stats", Icon = "package" })
Items:Toggle({
    Title = "Auto Claim Daily Rewards",
    Desc = "Claims each daily reward as soon as it unlocks.",
    Value = false,
    Callback = function(v) C.autoDaily = v end,
})
Items:Toggle({
    Title = "Auto Use X2 Boosts",
    Desc = "Uses X2 EXP/Diamond/Lucky/Rebirth/Item potions from your inventory when none is active. Consumes the items.",
    Value = false,
    Callback = function(v) C.autoBoost = v end,
})
Items:Section({ Title = "Tools & Weapons" })
Items:Toggle({
    Title = "Auto Get Tools (Auto Craft)",
    Desc = "Crafts every weapon you do not own yet as soon as you have its materials and Beli (cheapest first). Spends those materials and Beli.",
    Value = false,
    Callback = function(v) C.autoCraft = v end,
})
Items:Dropdown({
    Title = "Craft Type",
    Values = { "All", "Sword", "Melee" },
    Value = "All",
    Callback = function(v) C.craftType = v end,
})
Items:Button({
    Title = "Craft Everything Possible Now",
    Callback = function()
        task.spawn(function()
            local done = craftAll()
            notify("Craft", #done > 0 and ("Crafted: " .. table.concat(done, ", ")) or "Nothing craftable right now")
        end)
    end,
})
Items:Section({ Title = "Stat Points" })
Items:Toggle({
    Title = "Auto Spend Stat Points",
    Value = false,
    Callback = function(v) C.autoStats = v end,
})
Items:Dropdown({
    Title = "Stat",
    Desc = "Melee + Defense is the safer pick for farming: more damage and more health.",
    Values = { "Melee + Defense", "Melee", "Defense", "Sword", "Power" },
    Value = "Melee + Defense",
    Callback = function(v) C.statPick = v end,
})
Items:Toggle({
    Title = "Split Evenly Across All Stats",
    Value = false,
    Callback = function(v) C.statSplit = v end,
})
Items:Section({ Title = "Inventory" })
Items:Button({
    Title = "Print Inventory To Console",
    Callback = function()
        local inv = decodeAttr("Inventory")
        if not inv then return notify("Inventory", "Could not read inventory") end
        local n = 0
        for name, e in pairs(inv) do
            n += 1
            print(("[Inventory] %s x%s (%s)"):format(name, tostring(e.amount), tostring(e.rarity or e.type)))
        end
        notify("Inventory", n .. " item types printed to the console")
    end,
})

-- ===== Teleport tab =====
local TP = Window:Tab({ Title = "Teleport", Icon = "map-pin" })
local pickedQuestTP, pickedPlaceTP
TP:Dropdown({
    Title = "Quest NPC",
    Values = tpQuestNames,
    Callback = function(v) pickedQuestTP = v end,
})
TP:Button({
    Title = "Teleport To Quest NPC",
    Callback = function()
        if pickedQuestTP then tpTo(tpQuestCF[pickedQuestTP]) else notify("Teleport", "Pick a quest NPC first") end
    end,
})
TP:Dropdown({
    Title = "NPCs / Islands",
    Values = tpPlaceNames,
    Callback = function(v) pickedPlaceTP = v end,
})
TP:Button({
    Title = "Teleport There",
    Callback = function()
        if pickedPlaceTP and tpPlaceCF[pickedPlaceTP] then tpTo(tpPlaceCF[pickedPlaceTP]) else notify("Teleport", "Pick a place first") end
    end,
})
TP:Button({
    Title = "Teleport To Quest For My Level",
    Callback = function()
        local q = questForLevel(LP:GetAttribute("Level") or 1)
        local root = q and q.npc:FindFirstChild("HumanoidRootPart")
        if root then tpTo(root.CFrame * CFrame.new(0, 0, 4)) end
    end,
})

-- ===== Player tab =====
local Plr = Window:Tab({ Title = "Player", Icon = "user" })
Plr:Toggle({ Title = "Walk Speed", Value = false, Callback = function(v) C.speedOn = v end })
Plr:Slider({ Title = "Speed Value", Value = { Min = 16, Max = 250, Default = 60 }, Step = 1, Callback = function(v) C.speed = v end })
Plr:Toggle({ Title = "Jump Power", Value = false, Callback = function(v) C.jumpOn = v end })
Plr:Slider({ Title = "Jump Value", Value = { Min = 50, Max = 300, Default = 70 }, Step = 1, Callback = function(v) C.jump = v end })
Plr:Toggle({ Title = "Infinite Jump", Value = false, Callback = function(v) C.infJump = v end })
Plr:Toggle({ Title = "Noclip", Value = false, Callback = function(v) C.noclip = v end })
Plr:Toggle({ Title = "Anti AFK", Value = true, Callback = function(v) C.antiAfk = v end })
Plr:Toggle({ Title = "Fullbright", Value = false, Callback = function(v) C.fullbright = v setFullbright(v) end })

-- ===== Visuals tab =====
local Vis = Window:Tab({ Title = "Visuals", Icon = "eye" })
Vis:Toggle({
    Title = "Mob ESP",
    Value = false,
    Callback = function(v)
        C.espMob = v
        if not v then removeESPOf("mob") end
    end,
})
Vis:Toggle({
    Title = "Player ESP",
    Value = false,
    Callback = function(v)
        C.espPlayer = v
        if not v then removeESPOf("player") end
    end,
})

-- ===== Boost tab =====
local Boost = Window:Tab({ Title = "Boost", Icon = "zap" })
local boostToggles = {}
Boost:Button({
    Title = "Boost Everything",
    Desc = "Turns on auto stats, daily rewards, X2 potions, FPS boost, anti-AFK and the Safe Mode farm settings.",
    Callback = function()
        C.autoStats, C.autoDaily, C.autoBoost, C.antiAfk, C.safeMode, C.cluster, C.jitter = true, true, true, true, true, true, true
        C.fpsBoost = true
        setFpsBoost(true)
        pcall(function() setfpscap(240) end)
        notify("Boost", "Boosts on. Auto Farm Level is still yours to start.")
    end,
})
Boost:Toggle({
    Title = "FPS Boost",
    Desc = "Disables particles/trails/beams and shadows, lowers quality. Fully reverts when switched off.",
    Value = false,
    Callback = function(v) C.fpsBoost = v setFpsBoost(v) end,
})
Boost:Toggle({
    Title = "Disable 3D Rendering (AFK farm)",
    Desc = "Stops drawing the world to save GPU while farming. Screen goes black; turn off to see again.",
    Value = false,
    Callback = function(v) C.render3d = not v set3d(not v) end,
})
Boost:Slider({
    Title = "FPS Cap",
    Value = { Min = 30, Max = 360, Default = 60 },
    Step = 10,
    Callback = function(v) pcall(function() setfpscap(v) end) end,
})
Boost:Paragraph({
    Title = "What boosts what",
    Desc = "Attack Delay, Prefer Mob Clusters and Movement are on the Auto Farm tab. Daily rewards, X2 potions and stat points are on Items & Stats.",
})

-- ===== Misc / Settings tab =====
local Misc = Window:Tab({ Title = "Misc", Icon = "settings" })
local function panic()
    C.farm = false
    C.autoStats, C.autoBoost, C.autoDaily, C.autoBuso = false, false, false, false
    for k in pairs(C.skills) do C.skills[k] = false end
    local hrp = getHRP()
    if hrp and hubAnchored then hrp.Anchored = false hubAnchored = false end
    notify("PANIC", "Farm and all automation switched off")
end
Misc:Button({ Title = "Panic (stop all automation)", Callback = panic })
S.connect(UIS.InputBegan, function(input, gpe)
    if not gpe and input.KeyCode == Enum.KeyCode.RightControl then panic() end
end)
Misc:Button({
    Title = "Rejoin Server",
    Callback = function() TeleportService:Teleport(game.PlaceId, LP) end,
})
Misc:Button({
    Title = "Server Hop",
    Callback = function()
        local ok, res = pcall(function()
            return HttpService:JSONDecode(game:HttpGet(
                ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)))
        end)
        if ok and res and res.data then
            for _, s in ipairs(res.data) do
                if s.id ~= game.JobId and s.playing < s.maxPlayers then
                    notify("Server Hop", "Joining another server...")
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LP)
                    return
                end
            end
        end
        notify("Server Hop", "No other open server found")
    end,
})
Misc:Paragraph({
    Title = "Controls",
    Desc = "RightShift toggles this window, RightControl is the panic key. Farm needs the Combat tool (or the weapon type you pick) in your backpack.",
})
Misc:Button({
    Title = "Unload Hub",
    Callback = function()
        dead = true
        C.farm = false
        pcall(function() Window:Destroy() end)
        clearESP()
        setFullbright(false)
        setFpsBoost(false)
        set3d(true)
        local hrp = getHRP()
        if hrp and hubAnchored then hrp.Anchored = false end
    end,
})

-- expose config so it can be driven/inspected from outside the UI (cleared on reload/unload)
getgenv().RockFruitHubConfig = C
getgenv().RockFruitHubApi = {
    setFpsBoost = setFpsBoost, set3d = set3d, panic = panic, craftAll = craftAll,
    status = function() return statusText end,
    tpTo = tpTo, questCF = tpQuestCF, placeCF = tpPlaceCF, fpsDisabled = fpsDisabled,
}
S.onCleanup(function()
    getgenv().RockFruitHubConfig = nil
    getgenv().RockFruitHubApi = nil
end)

notify("Rock Fruit Hub", "Loaded. Turn on Auto Farm to start.")
