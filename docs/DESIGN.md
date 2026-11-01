# Design notes

Inspiration: *Marvel's Spider-Man 2*'s traversal feel (wall run, wall jump, web-swing), reskinned
onto Cyberpunk 2077's V and Mantis Blades instead of web-shooters.

## Mechanics

### Wall climb
- Trigger: Mantis Blades equipped, melee-stance input held while facing a wall within grab range.
- While climbing: disable normal gravity/fall damage, allow directional movement along the
  surface, allow a climb-jump off the wall.
- Needs a way to tell "climbable" surfaces from the game's existing wall tags/collision data —
  open question for the first implementation ticket.

### Wall run
- Trigger: approach a wall at or above a minimum lateral speed, airborne, facing within some
  angle tolerance of the wall normal.
- While running: redirect horizontal velocity to follow the wall surface, apply reduced gravity,
  cap duration (stamina-style or hard timer) before falling off.

### Wall jump
- Trigger: jump input while wall-climbing or wall-running.
- Effect: impulse away from the wall normal plus upward boost; chainable between two walls
  (classic corridor wall-jump) if timed within a short window.

### Web-sling
- Trigger: aimed input at a valid anchor point (building edge, structure) within range and line
  of sight.
- Effect: pulls V toward the anchor with a pendulum/swing arc rather than CP77's existing direct
  grapple-hook pull; release re-enters normal fall/glide physics with retained momentum.
- CP77 already ships a grapple hook (`PlayerPuppet` traversal states) — first implementation pass
  should check how much of that state machine can be reused vs. needs a parallel custom state.

## Wall detection (C2WS-T4)

`WebSlinger.ExecuteSmartRaycast(origin, direction, maxDistance)` in `init.lua` is the one source
of truth for "is there a wall here, which way does it face". It uses CET's exposed
`Game.GetSpatialQueriesSystem():SyncRaycastByCollisionGroup(from, to, group, staticOnly, dynamic)`
against the `Static` and `Terrain` collision groups, keeps the nearest hit, and returns
`(hit, hitPos, hitNormal)`. The normal is normalized and flipped if needed so it always points out
of the wall toward the caster. No RED4ext plugin was needed for this query.

The probe runs at most once per `onUpdate` tick (only while the mod is enabled or the debug
overlay is on); `onDraw` only reads the stored result. The "Debug: show wall raycast" checkbox draws
the ray (red on miss, green to the hit point), the hit point, and a yellow 0.5 m normal line,
projected with `Game.GetCameraSystem():ProjectPoint`. The panel also shows a smoothed frame time
and raycast cost so the per-tick cost can be compared against the baseline in-game.

## Implementation approach (open question)

CET's Lua layer can hook input, read/write exposed RTTI properties, and draw debug UI, but V's
movement is driven by native animation/physics state machines. Whether wall-run/wall-jump/sling
feel achievable purely through CET property pokes + TweakDB, or need a RED4ext native plugin for
direct hooks into the movement component, is the first thing to spike before committing to a full
implementation plan.
