# Furina Hub

Roblox Luau script hubs. Main script: **Furina Hub** for Silent Assassins (`furina_hub.luau`), using its own **FurinaUI** (`furina_ui.luau`).

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
- **Misc:** named config profiles, FPS boost (effects, post effects, terrain grass, lowest quality, custom FPS cap, all restorable), anti AFK, unload, rejoin

## FurinaUI

`furina_ui.luau` is the hub's own interface, ported from the approved design in `ui_preview/furina_ui_v11.html` (open it in a browser to see the target look).

- Loading screen with real progress, Home (avatar, live FPS, ping, players, session, pinned switches, what is on), and a Settings tab (theme, accent, size, transparency, toggle key, sounds, calm motion, performance)
- Ousia (dark) and Pneuma (light) themes with a wave transition, 5 accent colours
- Glass tiles in two columns, foldable sections, search across every tab, pin any switch to Home with the star
- Motion: drifting glows and bubbles with mouse parallax, springy window drag with drips, liquid tab indicator, splashes, ripples, a real 3D crystal on Home
- Draggable launcher orb when the menu is hidden (default toggle key: RightShift)
- Performance: animation jobs sleep when idle, loops pause while hidden, and Auto switches to Lite under 28 FPS
- Images and sounds are embedded and loaded with `writefile` + `getcustomasset`; executors without those get plain shapes instead

The hub loads `FurinaHub/furina_ui.luau` from your executor workspace if it exists (handy for testing edits), otherwise from this repo. If FurinaUI fails to load, the hub falls back to Luna.

To rebuild the embedded images and sounds after changing `tools/gen_furina_assets.py`: `python tools/gen_furina_assets.py` (needs Pillow and NumPy).

## Configs

Settings save automatically about a second after any change, to `FurinaHub/<name>.json` in your executor's workspace folder, and load on start. The Misc tab can save, load, list and delete named configs. Auto-save reports a notification if your executor cannot write files.

## Notes

- Combat, hitbox, no-cooldown, dodge and anti-slow depend on server checks that cannot be seen from the client, so results may vary.
- Other scripts in this repo: `RockFruitHub.luau`, `doors_hub.luau`, `overpower_hub.luau`.
