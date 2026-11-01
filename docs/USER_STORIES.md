---
codex: 1
project: Mods.Cyberpunk2077.WebSlinger
code: C2WS
layer: stories
status: living
updated: 2026-11-01
---
<!-- GENERATED from MindAttic.Tickets/data/Tickets.db by `tickets db render`. Do not edit: this file is rewritten from the database; change stories and tickets with the tickets CLI. -->

# Mods.Cyberpunk2077.WebSlinger — User Stories
> ✅ done (shipped & tested) · 🟡 partial · ⬜ planned. Every ✅ cites the test.

## Priority backlog
_Nothing recorded yet._


## Epic T — Spider-Man 2 style traversal: wall-climb, wall-run, wall-jump, web-sling
- **C2WS-US-T1 ⬜** As V, I want a reliable way to detect nearby wall surfaces and their normals, so that every other traversal mechanic has one source of truth for wall detection.
- **C2WS-US-T2 ⬜** As V, I want the mod's state machine to show my current traversal state at all times, so that every mechanic can be built and debugged against one known current state.
- **C2WS-US-T3 ⬜** As V, I want to fire a monowire/cable anchor at a nearby structure and pull toward it in an arc, so that I can start web-slinging instead of walking.
- **C2WS-US-T4 ⬜** As V, I want the game to automatically tell whether I'm slamming head-on into a wall or glancing off it diagonally while swinging, so I latch or wall-run without extra input.
- **C2WS-US-T5 ⬜** As V, I want to grab on and climb a wall with my Mantis Blades on a head-on hit, so I'm not just bounced off every flat surface.
- **C2WS-US-T6 ⬜** As V, I want to keep running when I glance off a wall at an angle while moving fast enough, so traversal feels like Spider-Man 2's wall-runs.
- **C2WS-US-T7 ⬜** As V, I want a wall-run to naturally end after a few seconds or when I slow down, so it feels like a timed parkour move, not an infinite glide.
- **C2WS-US-T8 ⬜** As V, I want to jump off a wall-climb or wall-run in a chosen direction, so I can chain between two facing walls or launch into open air.
- **C2WS-US-T9 ⬜** As V, I want to fire a new web-sling while airborne off a wall-jump or wall-run, so a single run can chain climb -> run -> jump -> swing with no ground touch.
- **C2WS-US-T10 ⬜** As V, I want visual/camera feedback during these moves, so traversal reads as deliberate parkour rather than a glitch.

## Tickets
> Permanent log of every change and fix — this repo's ticket system. Rows are append-only: never
> delete or reword one; only move its Status (open → closed / wont-do) and fill in Ref. Status is
> a word, not a glyph, so tickets don't count toward the story index. Keep this section last.

| ID | Date | Type | Status | Summary | Ref |
|---|---|---|---|---|---|
| C2WS-T1 | 2026-11-01 | docs | closed | Start the permanent ticket log in the ticket database | — |
| C2WS-T2 | 2026-11-01 | feature | closed | Scaffold new repo: Cyberpunk 2077 mod for Mantis Blade wall-climb, wall-run/jump, and Spider-Man 2 style webslinging | 7aad643ac7c88e810331b43e6e85a40b41323aaf |
| C2WS-T3 | 2026-11-01 | chore | closed | Rename repo to Mods.Cyberpunk2077.WebSlinger for mod organization (GitHub + folder + refs) | 36d0a7610a8d43186a58b5ea925f2190e04bf613 |
| C2WS-T4 | 2026-11-01 | feature | open | Wall-detection raycast utility + debug overlay | C2WS-US-T1 |
| C2WS-T5 | 2026-11-01 | feature | open | Formalize traversal state machine (NONE/CLIMBING/WALLRUNNING/SLINGING) | C2WS-US-T2 |
| C2WS-T6 | 2026-11-01 | feature | open | Web-sling (grapple) base: aim, fire, swing-arc physics, release | C2WS-US-T3 |
| C2WS-T7 | 2026-11-01 | feature | open | Wall-impact angle check during swing: latch vs. wall-run transition | C2WS-US-T4 |
| C2WS-T8 | 2026-11-01 | feature | open | Wall-latch (Mantis Blade climb) + wall-climb movement | C2WS-US-T5 |
| C2WS-T9 | 2026-11-01 | feature | open | Wall-run physics + sticky force + camera tilt | C2WS-US-T6 |
| C2WS-T10 | 2026-11-01 | feature | open | Wall-run duration/stamina drop-off | C2WS-US-T7 |
| C2WS-T11 | 2026-11-01 | feature | open | Wall-jump (from climb or wall-run), chainable between facing walls | C2WS-US-T8 |
| C2WS-T12 | 2026-11-01 | feature | open | End-to-end re-sling loop: swing -> run -> jump -> swing with no ground touch | C2WS-US-T9 |
| C2WS-T13 | 2026-11-01 | feature | open | Polish pass: camera tilt easing, impact feedback (stretch, do last) | C2WS-US-T10 |
| C2WS-T14 | 2026-11-01 | docs | closed | Write up ordered traversal feature breakdown: epic T, 10 stories, 10 linked tickets with explicit acceptance criteria | — |
