# Cyberpunk2077.WebSlinger

A Cyberpunk 2077 gameplay mod that gives V traversal borrowed from *Spider-Man 2*: climb walls
using the Mantis Blades, chain wall-runs and wall-jumps, and web-sling between buildings in
Night City.

## Status

In progress. Wall-climb, wall-run, and a base web-sling are implemented and playable; wall-jump
and further polish are still open. See [`docs/DESIGN.md`](docs/DESIGN.md) for the planned
mechanics and [`docs/USER_STORIES.md`](docs/USER_STORIES.md) for the ticket log.

## Planned mechanics

- **Wall climb** — holding the Mantis Blades melee stance against a qualifying wall surface
  switches V into a climb state instead of bouncing off.
- **Wall run** — approaching a wall at speed with sufficient lateral velocity triggers a
  horizontal run along it instead of a climb.
- **Wall jump** — jumping off a wall-run or wall-climb state launches V with an outward+upward
  impulse, chainable between two facing walls.
- **Web-sling** — firing a cable anchor at a nearby structure and reeling in a swing arc,
  mirroring *Spider-Man 2*'s web-swing feel rather than CP77's existing grapple hook.

## Target platform

- Cyberpunk 2077 (patch/version TBD, pinned once implementation starts)
- [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks) (Lua) for input hooks,
  state machine, and debug UI
- [RED4ext](https://github.com/WopsS/RED4ext) native plugin, if CET's Lua hooks prove insufficient
  for the movement/physics work (TBD — see `docs/DESIGN.md`)

## Requirements

- Cyberpunk 2077 (PC).
- [Cyber Engine Tweaks](https://www.nexusmods.com/cyberpunk2077/mods/107) (CET): runs the whole mod.

Nothing else: no redscript, TweakXL, ArchiveXL, Codeware or RED4ext.

## Install

### With Vortex

1. Install Cyber Engine Tweaks (Vortex lists it as a requirement on the Nexus page).
2. Download `WebSlinger-<version>.zip` with **Mod Manager Download**, or drag the zip into Vortex's
   Mods page (**Install From File**). Enable and deploy it.
3. Vortex's Cyberpunk 2077 extension recognises the zip on its own (a CET mod in its standard
   folder), so there is no manual-install or "fallback installer" prompt.

### By hand

1. Install Cyber Engine Tweaks and start the game once so it creates its folders.
2. Extract `WebSlinger-<version>.zip` into the game folder (the one with `bin`), so that
   `<game>/bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger/init.lua` exists. From a clone of
   this repo, copy `bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger/` to the same path instead.

### First run

1. Start the game. The CET console and log should show `[WebSlinger] loaded`.
2. Open the CET overlay (its key is set in CET's first-run screen), find the **WebSlinger** window
   and tick **Enabled**. The mod starts disabled every session and does not remember the tick.
3. Bind the web-sling hold-to-swing control in the CET overlay's **Bindings** tab under
   **WebSlinger** (no default key; see `docs/DESIGN.md` for the suggested bind).

## Uninstall

Remove the mod in Vortex, or delete `<game>/bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger/`.
Nothing else is touched; the mod stores no save-game state.

## Building and packaging

There is no compile step: the mod is plain Lua. To build the release zip, run from the repo root:

```
powershell -ExecutionPolicy Bypass -File tools/package.ps1
```

It writes `dist/WebSlinger-<version>.zip`, with the version read from `version` in `init.lua`
(override with `-Version x.y.z`). The zip is rooted at the game folder:

```
bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger/init.lua
```

Only git-tracked `.lua` files under that folder go in (git-add a new file before building), so
docs, dev files and runtime state like CET's `db.sqlite3` never ship. The script checks the result
(forward-slash entry names, every entry under the mod folder, `init.lua` directly inside it) and
prints the file list. `dist/` is in `.gitignore`. A quick syntax check of the file is
`luac -p bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger/init.lua`.

## Repository layout

- `bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger/init.lua`: the whole mod — wall-detection
  raycast, traversal state machine, web-sling, wall-climb and wall-run, and the debug overlay.
- `tools/package.ps1`: builds the Vortex-ready release zip into `dist/`.
- `docs/`: design notes and the ticket log.
