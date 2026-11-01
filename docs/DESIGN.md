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
- Decided in C2WS-T6: a fully custom parallel state, not the native grapple (see below).

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

## Web-sling base (C2WS-T6)

### Decision: custom parallel state, not the native `PlayerPuppet` grapple

The `PlayerPuppet` "grapple" in CP77's player state machine is the NPC grab/human-shield
takedown (V grabs an enemy and holds them), not a traversal grappling hook. Vanilla CP77 has no
player cable or anchor state at all: there is no notion of an anchor point, a rope length, or a
swing, and the grab state moves V only through canned takedown animations. Nothing in it can
produce a pendulum arc around a world point, and re-purposing it would also drag in the
weapon/combat blackboard side effects of grabbing a target. So web-sling is its own `SLINGING`
state in WebSlinger's state machine (C2WS-T5) with the swing integrated in Lua: V's feet position
and velocity are simulated as a point mass on a rope, and the result is written back each
`onUpdate` tick with `Game.GetTeleportationFacility():Teleport(player, pos, yaw)` (yaw is V's
current yaw, so mouse look is never fought). This needs no RED4ext plugin.

### Control: one player-configurable hold-to-swing input

The swing control is a CET input registered with `registerInput("webslinger_swing", ...)`, not a
hardcoded native button. Both triggers/bumpers and the obvious mouse buttons are already bound in
CP77's default scheme (aim, fire, cyberware quickslot, ...), so the mod never claims one. CET
inputs report press (`true`) and release (`false`); the callback only stores the held state and the
`onUpdate` tick polls it, so one bind covers both fire/attach (press) and let go (release). The
player binds or rebinds it in the CET overlay's Bindings tab, no code edits.

CET inputs have no built-in default key, so the player picks one the first time. **Suggested
default: Mouse Button 4 (thumb/back)**, which is not part of CP77's default keyboard+mouse
scheme as far as the default control list goes. **Conflict check status: not yet done live.** The
agent that wrote this could not open the game; before this suggestion is presented as the
default in any user-facing doc, open Settings > Controls in-game and confirm Mouse 4 is unbound
(and check Mouse 5 as the fallback). Record the result here.

### Anchor search: effortless, not precision aiming

`WebSlinger.FindAnchor(player)` casts a cone of sample rays from V's eye height: 5 yaw offsets
(-45 to +45 degrees) x 4 elevations (20 to 65 degrees above horizontal) = 20 rays, each through
`ExecuteSmartRaycast` (C2WS-T4) out to `sling.AnchorMaxDistance` (default 45 m, slider in the
panel). Each ray returns the first surface it touches, so every candidate is in line of sight by
construction. The cone is centred on the camera's look heading, blended toward V's horizontal
travel direction when she is moving faster than 4 m/s, so "roughly facing the skyline" is enough.
A hit qualifies if it is at least `minAnchorHeight` (3 m) above V's feet and `minAnchorHorizontal`
(1.5 m) away horizontally; the best is scored on alignment with the heading, height, and
horizontal reach. No qualifying hit is a soft fail: no state change, V keeps falling or running,
and the panel shows the miss. The search runs only on the press edge and then every
`retryInterval` (0.15 s) while the key stays held, never every tick.

### Swing physics: `UpdateGrapplePhysics(deltaTime)`

On attach, `IsGrappling` becomes true, the state enters `SLINGING`, the rope length is set to the
current hand-to-anchor distance, and the swing is seeded with V's current velocity (estimated from
position deltas, or the carry velocity mid-air). Firing from the ground adds a 5 m/s hop. Each tick
while grappling (`deltaTime` clamped to 50 ms):

1. Gravity (`sling.gravity`, 1.6 g by default for a snappier arc).
2. Steering: a small push along the camera heading with its rope-parallel component removed, so
   it only swings V around the anchor.
3. Light damping and a speed clamp.
4. Reel-in: the rope shortens at `reelSpeed` down to `minRopeLength`. This is what pulls V toward
   the anchor, and it does so along the arc.
5. Rope constraint: if the hand point ends up beyond rope length it is put back on the sphere
   around the anchor and the outward radial velocity is removed. That is the pendulum: gravity
   plus a taut rope gives an arc, never a straight pull to the point.
6. Collision via `ExecuteSmartRaycast` along the step: a walkable surface (normal z > 0.6) lands V;
   a wall slides her along it.

### Release and momentum

The swing ends (back to `NONE`) on key release, on reaching within `anchorReachDistance` (2.5 m)
of the anchor, on landing, or after `maxSwingTime` (8 s). Leaving `SLINGING` any way, including a
direct `SetState`, runs the `SLINGING` `onExit` hook, which clears the rope and `IsGrappling`.
Except on landing, V's velocity at release is kept and integrated under gravity (momentum carry)
until she lands, re-attaches, or `carryMaxTime` (4 s) passes, after which native physics takes
over. The release speed is never zeroed.

Chaining: while the key stays held, the swing auto-releases at the chain point (on the upswing,
past the bottom of the arc in the direction of travel by `chainReleaseAngleDeg`, after at least
`chainMinSwingTime`), then re-searches every 0.15 s and attaches to the next anchor ahead, seeding
the new swing with the carried velocity. Holding the key through a run of buildings chains swing
after swing with no re-aiming.

### Verification status

Not yet verified in-game; the agent that implemented this could not run the game. Outstanding
checks from the ticket: (1) fire at a building corner from three different approach angles and
speeds and confirm an arc each time; (2) hold the key and swing continuously through at least five
consecutive buildings without a failed anchor search while roughly facing a qualifying skyline;
(3) the Mouse 4 conflict check above. Open risk: whether the native character controller keeps
accumulating its own fall velocity while V is being teleported each tick (it could cause fall
damage when the carry hands back to native physics). If it does, the hand-back needs a
velocity reset or a fall-damage suppression step.

## Implementation approach (open question)

CET's Lua layer can hook input, read/write exposed RTTI properties, and draw debug UI, but V's
movement is driven by native animation/physics state machines. Whether wall-run/wall-jump/sling
feel achievable purely through CET property pokes + TweakDB, or need a RED4ext native plugin for
direct hooks into the movement component, is the first thing to spike before committing to a full
implementation plan.
