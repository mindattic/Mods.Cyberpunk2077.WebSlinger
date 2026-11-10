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
| C2WS-T4 | 2026-11-01 | feature | closed | Wall-detection raycast utility + debug overlay | 32372669d39915e408ae2f851854bf7cb1969b8c |
| C2WS-T5 | 2026-11-01 | feature | closed | Formalize traversal state machine (NONE/CLIMBING/WALLRUNNING/SLINGING) | 962a87358d466ca3cf918944329753fd42ef93b2 |
| C2WS-T6 | 2026-11-01 | feature | closed | Web-sling (grapple) base: aim, fire, swing-arc physics, release | 8586367 |
| C2WS-T7 | 2026-11-01 | feature | closed | Wall-impact angle check during swing: latch vs. wall-run transition | 8c107f2240cd9067c7add4fe6a7edcf1a54cb63e |
| C2WS-T8 | 2026-11-01 | feature | closed | Wall-latch (Mantis Blade climb) + wall-climb movement | 4a2cefc9e5bedf3ba7029d8028a13d9fd824d4f3 |
| C2WS-T9 | 2026-11-01 | feature | closed | Wall-run physics + sticky force + camera tilt | fe4286d |
| C2WS-T10 | 2026-11-01 | feature | closed | Wall-run duration/stamina drop-off | 38e68fb |
| C2WS-T11 | 2026-11-01 | feature | closed | Wall-jump (from climb or wall-run), chainable between facing walls | da0c4396fcd79ca0907236c11d0ea4ec9975fe85 |
| C2WS-T12 | 2026-11-01 | feature | closed | End-to-end re-sling loop: swing -> run -> jump -> swing with no ground touch | 2fd3ff6e5c2c3d8042ab2fd99d7ec4cffbbe9524 |
| C2WS-T13 | 2026-11-01 | feature | closed | Polish pass: camera tilt easing, impact feedback (stretch, do last) | 74753b3a038386620340d09a758dda780c28e3f4 |
| C2WS-T14 | 2026-11-01 | docs | closed | Write up ordered traversal feature breakdown: epic T, 10 stories, 10 linked tickets with explicit acceptance criteria | — |
| C2WS-T15 | 2026-11-01 | chore | closed | Bug hunt pass: run /bughunt across the repo and file fix tickets for any confirmed bugs | — |
| C2WS-T16 | 2026-11-01 | chore | closed | Make the mod Vortex-deployable: correct relative folder layout, a packaging script producing an install-ready zip, and Vortex install docs | bdd89dff24049fc5b295e3645666fd8b6d9e7373 |
| C2WS-T17 | 2026-11-01 | feature | closed | In-game text message from 'Peter Parker' explaining the WebSlinger mod, in friendly-neighborhood-Spider-Man voice with verified quotes | 7131285bb032be6e35b2a9fcec8ec652e49ec367 |
| C2WS-T18 | 2026-11-01 | fix | closed | README Status section still says 'no gameplay is implemented yet' after wall-climb/wall-run/web-sling landed | c11b31a |
| C2WS-T19 | 2026-11-01 | chore | closed | /bughunt pass (user-invoked): exhaustive search + direct fixes across init.lua, left uncommitted for review | 618c920 |
| C2WS-T20 | 2026-11-01 | chore | closed | Un-ignore dist/ so built mod zips are tracked in git, not gitignored | c21a16e |
| C2WS-T21 | 2026-11-01 | feature | closed | Jump directly into a wall head-on starts CLIMBING, no swing required first | 6d47017 |
| C2WS-T22 | 2026-11-01 | feature | closed | Mid-air double-jump auto-fires a web-sling toward where V is looking | 988cacf |
| C2WS-T23 | 2026-11-01 | feature | closed | Bottom-of-swing boost leap: jump near arc bottom launches V toward her look direction | 618c920 |
| C2WS-T24 | 2026-11-01 | chore | closed | Rebuild dist zip with T21-T23 jump-to-climb/wall-run/sling/boost-leap chain | c63a36c |
| C2WS-T25 | 2026-11-01 | feature | closed | Make the swing's hand-to-anchor rope line actually visible and cable-like in play | 328faf7 |
| C2WS-T26 | 2026-11-01 | feature | closed | Visual Monowire deploy on V's hand during a swing (cosmetic only, research RED4ext-free feasibility first) | 9dd04f7 |
| C2WS-T27 | 2026-11-01 | fix | open | Jump-into-wall head-on latch (C2WS-T21) reported not working in-game at all | — |
| C2WS-T28 | 2026-11-01 | chore | closed | Rebuild dist zip with T25-T27 visible rope line, Monowire hand anchor, latch diagnostics | 1f82054 |
| C2WS-T29 | 2026-11-01 | fix | closed | Hide the swing cable's near end: push its start point low/center instead of lower-right in view | 80bd06f |
| C2WS-T30 | 2026-11-01 | feature | closed | Direct-aim web attach, propel-then-elastic physics, tap-only shoot/break controls | 76d79f4 |
| C2WS-T31 | 2026-11-01 | chore | closed | Review whole mod against Marvel's Spider-Man 2 web-swinging and file alignment tickets | — |
| C2WS-T32 | 2026-11-01 | feature | closed | Swing feel: near-fixed-length pendulum that keeps speed through the bottom, no reel-in to the anchor (SM2 alignment) | 390495b |
| C2WS-T33 | 2026-11-01 | feature | closed | Low swings skim the ground instead of landing dead: shorten the web near the street (SM2 alignment) | a0bea9f3a4645e8114c0bf98883bd915094c16a3 |
| C2WS-T34 | 2026-11-01 | feature | closed | Auto-anchor fallback: crosshair on open sky attaches above and ahead along travel direction (SM2 alignment) | 2e8d6c1 |
| C2WS-T35 | 2026-11-01 | feature | closed | Timed swing boost: tap near the bottom of the arc launches forward faster, else plain release (SM2 alignment) | 94b6dd8 |
| C2WS-T36 | 2026-11-01 | feature | closed | Speed-scaled camera FOV while swinging, eased and always restored (SM2 alignment) | bbe4edb |
| C2WS-T37 | 2026-11-01 | feature | open | Web zip: mid-air dash forward on a quick double web for sharp turns between swings (SM2, future) | — |
| C2WS-T38 | 2026-11-01 | feature | open | Dive: point down to dive and gain speed, then turn it into a faster swing (SM2, future) | — |
| C2WS-T39 | 2026-11-01 | feature | open | Web wings: glide while slowly losing height, swing to regain it (SM2, future) | — |
| C2WS-T40 | 2026-11-01 | feature | open | Corner whip: web wraps a building corner to swing sharply around it (SM2, future) | — |
| C2WS-T41 | 2026-11-01 | fix | closed | lastShotPath default landed outside the swing table in C2WS-T34; move it into swing | 7a58ba5 |
| C2WS-T42 | 2026-11-01 | chore | closed | Rebuild dist zip after the Spider-Man 2 alignment batch (T30, T32-T36, T41, T27) | b92e59d |
| C2WS-T43 | 2026-11-02 | chore | closed | Release v1.0.0: bump WebSlinger.version to 1.0.0, rebuild dist/WebSlinger-1.0.0.zip replacing the 0.1.0 zip, tag v1.0.0 | c0f74e7 |
| C2WS-T44 | 2026-11-02 | docs | open | Adopt MindAttic.Agency docs-site pipeline, publish README to GitHub Pages (HOUSE-LAW-14) | — |
| C2WS-T45 | 2026-11-02 | fix | closed | Bughunt sweep, two passes: find and fix real bugs across tracked source (user request 2026-11-02) | — |
| C2WS-T46 | 2026-11-02 | fix | closed | Fix the open items the 2026-11-02 bughunt left for decision (debug window only with CET overlay open, rebuild dist zip) | — |
| C2WS-T47 | 2026-11-03 | fix | closed | Debug window stays hidden after 'Reload all mods' with the CET overlay open: overlayOpen starts false and onOverlayOpen never fires; seed it from the live overlay state (as ShootDodge C2SD-T33) | — |
| C2WS-T48 | 2026-11-10 | chore | closed | Crash recovery: commit the command-catalog sync (.agent/commands/*.md) and regenerated docs/USER_STORIES.md left uncommitted by the session crash | — |
