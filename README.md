# Cyberpunk2077.WebSlinger

A Cyberpunk 2077 gameplay mod that gives V traversal borrowed from *Spider-Man 2*: climb walls
using the Mantis Blades, chain wall-runs and wall-jumps, and web-sling between buildings in
Night City.

## Status

Early scaffold. No gameplay is implemented yet — this repo currently holds the project shell and
design notes. See [`docs/DESIGN.md`](docs/DESIGN.md) for the planned mechanics and
[`docs/USER_STORIES.md`](docs/USER_STORIES.md) for the ticket log.

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

## Install (once there's something to install)

Drop the contents of `bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger/` into your game's
matching `bin/x64/plugins/cyber_engine_tweaks/mods/` folder.
