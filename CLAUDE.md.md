# Project: MapSingularity: Seamless Workshop Roulette (Garry's Mod)

## 1. Workspace Layout
You are working across two directories on Windows:
1. **Docs & Drafts**: `C:\Project-work\garry_roulette` (Store `CLAUDE.md`, Steam API filter notes, BSP lump structure references, and `NEXT-SESSION.md` here).
2. **Live Addon**: `C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\addons\map_singularity` (Write ALL production `.lua` and config files here for live hot-reloading).

## 2. Core Mechanics & The Seamless Illusion (Black Mesa Xen-Style Transition)
Source Engine 1 cannot hold two `.bsp` maps in memory simultaneously. We create a seamless portal jump by pre-fetching/pre-caching in the background and temporarily hijacking `sv_loadingurl` ONLY during portal transit:
- **Stage 1: Background Fetch & Mount (`ms_init.lua`)**
  - Asynchronously query the Steam Workshop Web API (`ISteamRemoteStorage/GetPublishedFileDetails`) with tag `Map`, filtering out 0-rating or broken entries.
  - Download the `.gma` via `steamworks.DownloadUGC` and mount it using `game.MountGMA`.
  - Scan the mounted `maps/` directory to extract the exact `.bsp` filename.
- **Stage 2: Binary `.bsp` Entity Lump Precaching (`sv_precache.lua`)**
  - Open the downloaded `.bsp` in binary mode (`file.Open("maps/" .. mapName .. ".bsp", "rb", "GAME")`), parse the BSP header to locate Lump 0 (Entities) offset and length.
  - Extract `models/*.mdl` and `materials/*.vmt` paths via pattern matching (`string.gmatch`) and amortize `util.PrecacheModel` / `Material()` calls over timers to warm the engine cache without server tick spikes.
- **Stage 3: Portal Jump & Temporary `sv_loadingurl` Hijack (`sv_inventory.lua` & `cl_visuals.lua`)**
  - Once cached, spawn `roulette_portal` in the world.
  - On player touch: trigger client-side FOV stretch, radial motion blur, DSP audio muffle, and a smooth `1.5s` fade to solid black (`surface.DrawRect`).
  - Server serializes all players' state keyed by `SteamID64` (HP, armor, active weapon class, full weapon list, and ammo counts) alongside the current `GetConVar("sv_loadingurl"):GetString()` into `map_singularity_state.json`.
  - Server overrides `sv_loadingurl` to `MS_LOADING_URL` (matching the black portal screen) and calls `RunConsoleCommand("changelevel", mapName)`.
- **Stage 4: Seamless Awakening (`InitPostEntity`)**
  - Clients immediately hold a black screen on spawn to mask entity popping.
  - Server reads `map_singularity_state.json`, immediately restores the original `sv_loadingurl` so regular map changes remain untouched, restores player loadouts/HP, and deletes the JSON file.
  - Clients smoothly fade out the black overlay over `2.0s`.

## 3. File Structure
- `addon.json`
- `lua/autorun/ms_init.lua` — Entry point (`AddCSLuaFile`), Workshop API fetcher, `DownloadUGC`, `MountGMA`, `ms_force_fetch` concommand.
- `lua/map_singularity/sv_precache.lua` — Pure GLua binary `.bsp` Lump 0 parser and amortized asset precacher.
- `lua/map_singularity/sv_inventory.lua` — `SteamID64` JSON state serializer/restorer and `sv_loadingurl` hijack/rollback controller.
- `lua/map_singularity/cl_visuals.lua` — Portal FOV warp, motion blur, DSP filter, black fade-in/fade-out state machine.
- `lua/entities/roulette_portal/` — Physical portal entity with trigger bounds and visual vortex effects.

## 4. Strict Coding Rules
- **Pure GLua**: Zero external binaries or `.dll`s.
- **No Stubs / TODOs**: Write complete, production-ready code with graceful fallbacks if a Workshop download fails.