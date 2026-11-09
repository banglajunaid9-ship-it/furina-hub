# Furina Hub

Roblox Luau script hubs. Main script: **Furina Hub** for Silent Assassins (`furina_hub.luau`, Luna UI).

## Run

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/banglajunaid9-ship-it/furina-hub/main/furina_hub.luau"))()
```

Running it again replaces the previous copy instead of stacking a second one.

## Features

- **ESP tab:** corner or full boxes, health bar and number, name, distance, held weapon, skeleton, head dot, look direction, chams with adjustable fill, tracers (bottom / center / mouse), off-screen arrows with distance, line-of-sight colors, "ATTACKING" warning, closest-target tag, radar, gacha chest ESP, rainbow, four color pickers, toggle key (Z)
- **Combat:** Kill Aura (range, delay, hit-all or closest, low-HP first, ignore list, toggle key), No Attack Cooldown, face/stick to target
- **Hitbox:** bigger swing hitbox, optional visual, optional size spoof (riskier)
- **Power:** aimlock with FOV circle, auto dodge (experimental), proximity alert, anti slow, anti knockback, always hold weapon, panic key (Delete), spectate and teleport by name
- **Luck:** auto roll gacha chests and stop at a chosen rarity (rolls are server-side, odds cannot be changed)
- **Movement:** speed, jump, infinite jump, noclip, fly
- **Misc:** named config profiles, FPS boost, anti AFK, unload, rejoin

## Configs

Settings save automatically about a second after any change, to `FurinaHub/<name>.json` in your executor's workspace folder, and load on start. The Misc tab can save, load, list and delete named configs. Auto-save reports a notification if your executor cannot write files.

## Notes

- Combat, hitbox, no-cooldown, dodge and anti-slow depend on server checks that cannot be seen from the client, so results may vary.
- Other scripts in this repo: `RockFruitHub.luau`, `doors_hub.luau`, `overpower_hub.luau`.
