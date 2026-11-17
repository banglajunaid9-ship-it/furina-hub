--[[
	Furina Hub | one script for every game
	loadstring(game:HttpGet("https://raw.githubusercontent.com/banglajunaid9-ship-it/furina-hub/main/furina_loader.luau"))()

	Detects the game you are in (by PlaceId, or by universe id for games with several places) and runs the matching hub.
	Games with no hub of their own get the universal Overpower hub.
	To add a game: add a line to GAMES (name, file, placeIds, optional universeIds). Find the ids by running it in that
	game: it prints PlaceId and GameId when there is no match. Files in the workspace folder FurinaHub/ win over GitHub,
	so you can test an edited hub without pushing.
]]

local REPO = "https://raw.githubusercontent.com/banglajunaid9-ship-it/furina-hub/main/"
local FALLBACK = { name = "Overpower (universal)", file = "overpower_hub.luau" }

local GAMES = {
	{ name = "Silent Assassins",        file = "furina_hub.luau",            places = { 103854444055060 } },
	{ name = "Forsaken",                file = "forsaken_hub.luau",          places = { 83645629621104 } },
	{ name = "Throw Food For Animals",  file = "furina_animals_hub.luau",    places = { 120219252362013 } },
	{ name = "Paper To Plane",          file = "furina_paperplane_hub.luau", places = { 132583639194663 }, universes = { 10771096080 } },
	{ name = "San Diego Roleplay",      file = "furina_sandiego_hub.luau",   places = { 136020512003847 } },
	{ name = "Strike",                  file = "furina_strike_hub.luau",     places = { 114234929420007 } },
	{ name = "Doors",                   file = "doors_hub.luau",             places = { 6516141723, 6839171747 } },
	{ name = "Survive the Apocalypse",  file = "dist/furina_apocalypse_hub.lua", places = { 90148635862803, 116139828947259 }, universes = { 9098570654 } },
	-- { name = "Rock Fruit", file = "RockFruitHub.luau", places = { 0 } }, -- put the real PlaceId here
}

local function has(list, id)
	if list then
		for _, v in ipairs(list) do
			if v == id then return true end
		end
	end
	return false
end

local function find()
	for _, g in ipairs(GAMES) do
		if has(g.places, game.PlaceId) or has(g.universes, game.GameId) then return g end
	end
end

local function note(text)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", { Title = "Furina Hub", Text = text, Duration = 6 })
	end)
end

local function fetch(file)
	local src
	pcall(function()
		if isfile and readfile and isfile("FurinaHub/" .. file) then src = readfile("FurinaHub/" .. file) end
	end)
	if src then return src end
	local ok, res = pcall(function()
		-- a changing query string avoids stale copies from the raw.githubusercontent cache
		return game:HttpGet(REPO .. file .. "?t=" .. os.time())
	end)
	if ok and type(res) == "string" and #res > 0 then return res end
	return nil, tostring(res)
end

local hub = find()
if not hub then
	hub = FALLBACK
	print(("[Furina Hub] no hub for this game (PlaceId %d, GameId %d), loading %s"):format(game.PlaceId, game.GameId, hub.name))
	note("No hub for this game yet, loading " .. hub.name)
else
	print(("[Furina Hub] detected %s, loading %s"):format(hub.name, hub.file))
	note("Detected " .. hub.name)
end

local src, err = fetch(hub.file)
if not src then
	warn("[Furina Hub] could not download " .. hub.file .. ": " .. tostring(err))
	note("Could not download the hub, check your connection")
	return
end

local fn, cerr = loadstring(src, "=" .. hub.file)
if not fn then
	warn("[Furina Hub] " .. hub.file .. " failed to compile: " .. tostring(cerr))
	note("The hub failed to compile, see the console")
	return
end

return fn()
