# Furina Hub

Roblox Luau script hubs. Main script: **Furina Hub** for Silent Assassins (`furina_hub.luau`, Luna UI).

## Run

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/banglajunaid9-ship-it/furina-hub/main/furina_hub.luau"))()
```

Running it again replaces the previous copy instead of stacking a second one.

## Features

- **Combat:** Kill Aura (range, delay, hit-all or closest, low-HP first, ignore list, toggle key), No Attack Cooldown, face/stick to target
- **Hitbox:** bigger swing hitbox, optional visual, optional size spoof (riskier)
- **Power:** aimlock with FOV circle, auto dodge (experimental), proximity alert, anti slow, anti knockback, always hold weapon, panic key (Delete), spectate and teleport by name
- **Luck:** auto roll gacha chests and stop at a chosen rarity (rolls are server-side, odds cannot be changed)
- **Visuals:** Drawing ESP (boxes, names, health, distance, weapon, tracers, chams, off-screen arrows), fullbright, FOV, HUD
- **Movement:** speed, jump, infinite jump, noclip, fly
- **Misc:** config save/load (`FurinaHub/silent_assassins.json`), FPS boost, anti AFK, unload, rejoin

## Notes

- Combat, hitbox, no-cooldown, dodge and anti-slow depend on server checks that cannot be seen from the client, so results may vary.
- Other scripts in this repo: `RockFruitHub.luau`, `doors_hub.luau`.
