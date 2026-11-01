# Design notes

Inspiration: *Marvel's Spider-Man 2*'s traversal feel (wall run, wall jump, web-swing), reskinned
onto Cyberpunk 2077's V and Mantis Blades instead of web-shooters.

## Mechanics

### Wall climb
- Trigger: a head-on (or too slow to wall-run) wall impact during a swing (C2WS-T7). "Mantis
  Blade climb" is flavour only: the climb is a built-in ability with no cyberware check.
- While climbing: disable normal gravity/fall damage, allow directional movement along the
  surface, allow a climb-jump off the wall. Implemented in C2WS-T8 (see below).

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

## Wall impact during a swing (C2WS-T7)

`CheckWallCollisionDuringSwing()` runs every `onUpdate` tick while `IsGrappling`, before
`UpdateGrapplePhysics` (whose collision step would otherwise slide V along the wall and erase the
impact). It casts `ExecuteSmartRaycast` from chest height (`impact.probeHeight`) along V's flat swing
velocity, out to `WallCheckDistance` (2 m). Hits whose normal is mostly vertical (floors, ledges;
flat normal length below `minWallNormal2D`) are ignored, as is a swing with almost no horizontal
speed (`minMoveSpeed2D`), since it has no travel direction to test.

On a wall hit, `impactAngle = movementDir . wallNormal2D` (both flattened to z = 0):

| Condition | Result |
|---|---|
| `abs(impactAngle) > WallLatchAngleThreshold` (0.75) | `StopGrapple()`, `TriggerWallLatch()` -> `CLIMBING` |
| otherwise, 3D speed `>= MinimumWallRunSpeed` (8 m/s) | `StopGrapple()`, `InitiateWallRun(wallNormal2D, velocity)` -> `WALLRUNNING` |
| otherwise (glancing but slow) | `StopGrapple()`, `TriggerWallLatch()` -> `CLIMBING` |

`StopGrapple()` releases the rope with no momentum carry, so the state log always reads
`SLINGING -> NONE -> (CLIMBING|WALLRUNNING)` within the same tick. The wall normal, impact point and
entry velocity are left in `WebSlinger.wall` for the climb (C2WS-T8) and wall-run (C2WS-T9)
mechanics. Each decision is printed as `[WebSlinger] wall impact #n: angle a speed s -> branch` and
shown as "Last wall impact" in the debug panel, which also has sliders for the three tunables.

Not yet verified in-game. Outstanding checks: (1) swing straight into a flat wall face -> latch;
(2) swing past a wall at a shallow angle above 8 m/s -> wall-run; (3) the same shallow angle below
8 m/s -> latch (fallback). Until C2WS-T9 lands, `WALLRUNNING` has no movement or exit of its own,
so after a wall-run impact use the debug panel's `NONE` button to return.

## Wall-latch and wall-climb (C2WS-T8)

### No equipment gate

`TriggerWallLatch()` and the `CLIMBING` hooks never query Mantis Blades, Monowire or any other
cyberware slot. The climb is a permanent ability the mod grants; "Mantis Blade climb" survives only
as flavour in comments and docs.

### Entering `CLIMBING`: gravity, fall damage, residual velocity

The `CLIMBING` `onEnter` hook re-probes into the wall along `-wall.normal` (or, if entered from the
debug panel with no impact recorded, along V's facing) and fails back to `NONE` if no wall-like
surface is there. On success:

- **Gravity:** there is no native "disable gravity" flag CET can poke on V's character controller,
  so, like the web-sling, `CLIMBING` owns V's feet position (`WebSlinger.climbing.pos`) and writes
  it back every tick with `Game.GetTeleportationFacility():Teleport(...)`. Pinning the position each
  tick is what suspends gravity.
- **Fall damage:** the exact flag toggled is god mode **`gameGodModeType.Invulnerable`**, added via
  `Game.GetGodModeSystem():AddGodMode(player:GetEntityID(), gameGodModeType.Invulnerable,
  "WebSlinger.Climb")` on enter and removed with `RemoveGodMode(...)` with the same reason name on
  exit (any exit, including the debug buttons and disabling the mod). Using WebSlinger's own reason
  name means removing it never clears god mode from any other source. Side effect: V is also immune
  to combat damage while on a wall. `climbing.invulnerable` mirrors the flag and is shown in the panel.
- **Residual velocity:** the swing velocity, its carry, the position-delta velocity estimate and
  `wall.velocity` are all zeroed, and V is snapped to `climb.standoff` (0.45 m) out from the surface.

### Movement in the wall plane

Input comes from the game's own `MoveX` / `MoveY` / `Jump` actions (observed on
`PlayerPuppet:OnAction`), so climbing uses the player's normal move/jump binds on keyboard or
gamepad. Each tick, `MoveY` moves V up (`speedUp`, 3 m/s) or down (`speedDown`, 4 m/s) and `MoveX`
strafes along the wall's tangent (`speedStrafe`, 3 m/s). Before moving:

1. A ray along the step checks for something solid in the way (overhang, inside corner); if blocked,
   V stays put that tick.
2. Moving down onto walkable ground ends the climb (`NONE`).
3. A stick probe from chest height at the new position casts into the wall (`standoff +
   stickDistance`). A hit refreshes the wall normal (so curved or faceted walls are followed) and
   V is held at the standoff. **A miss means the wall's edge:** V is never moved there; over the top
   she is placed on the ledge if a downward probe finds walkable ground (mantle), otherwise she
   lets go where she is (`NONE`, native physics). This is what stops her clipping past an edge.

### Climb-jump

Jump while `CLIMBING` exits to `NONE` and hands V to the web-sling momentum carry with velocity
`wallNormal * jumpOutSpeed (6) + up * jumpUpSpeed (7)`, so she arcs off the wall under the mod's
gravity and then falls normally. From `NONE` she can fire a new web-sling or (C2WS-T11) latch onto
the next wall.

### Verification status

Not yet verified in-game; the agent that implemented this could not run the game. Outstanding
check from the ticket, with nothing in V's cyberware slots: climb at least 10 m up a building face
("Climb: x m above entry" in the panel), strafe both ways without sliding off, then climb-jump off
into a normal fall. Also confirm `AddGodMode`/`RemoveGodMode` succeed (a failed toggle prints
`climb: god-mode toggle failed`) and that the `MoveX`/`MoveY` sign conventions give up = forward
and right = right; flip in `UpdateClimb` if not.

## 'Peter Parker' intro text (C2WS-T17)

The debug panel's **Send Peter Parker intro text** button sends a short in-character text from
'Peter Parker' (the contact name and signature both read 'Peter Parker') explaining what the mod
does and how to bind the swing key. It is manual only, never sent automatically on load.

### Gap: no CET API for a real in-game text message

CP77's phone messages are not runtime data a script can append to. Each contact and message
thread is a `gameJournalContact` / `gameJournalPhoneConversation` / `gameJournalPhoneMessage`
entry baked into the `.journal` resources, with its strings in localization `onscreens` files.
CET's Lua layer can reach `JournalManager` (via `Game.GetJournalManager()`) and change the
*state* of journal entries that already exist (`ChangeEntryState`, tracking), but it cannot create
a new contact or a new message entry, so there is no way to make 'Peter Parker' appear in V's
phone from CET alone.

What a real in-game text would need:

- **ArchiveXL** (a RED4ext plugin) to merge a new `.journal` resource adding a 'Peter Parker'
  contact and a one-message conversation, plus a localization `onscreens` entry for the
  contact name and message text (shipped in a packed `.archive` built with WolvenKit).
- Then either CET (`Game.GetJournalManager():ChangeEntryState(...)` on the new entry's path) or
  a small redscript/Codeware call from the button to activate the message, which fires the
  game's own phone notification.

That turns the mod from "copy one CET folder" into an archive + RED4ext dependency, so it is left
as a follow-up. **Interim fallback:** a CET ImGui overlay styled as a phone text bubble (dark card
with a red border, 'Peter Parker' header with a timestamp, blue bubble with the message, Close
button), drawn top-right in `onDraw` by `drawPeterText()` and shown by
`WebSlinger.SendPeterParkerIntroText()`. Same pattern as C2WS-T4: spike what CET exposes,
document the gap, ship the CET-only version.

### Verified quotes (keep word for word)

- "With great power comes great responsibility." (Uncle Ben, *Spider-Man*, 2002)
- "You know who I am." ... "Your friendly neighborhood Spider-Man." (Spider-Man to Mary Jane,
  Moondance Diner, *Spider-Man*, 2002; punctuation per transcripts, no shooting script checked)

Both appear unaltered in `PeterText.body` in `init.lua`; the overlay shows a one-line credit under
the bubble. Not yet verified in-game: open the overlay and confirm the whole message is readable
without clipping at 1080p and 4K, the header reads 'Peter Parker', and both quotes appear as above.

## Implementation approach (open question)

CET's Lua layer can hook input, read/write exposed RTTI properties, and draw debug UI, but V's
movement is driven by native animation/physics state machines. Whether wall-run/wall-jump/sling
feel achievable purely through CET property pokes + TweakDB, or need a RED4ext native plugin for
direct hooks into the movement component, is the first thing to spike before committing to a full
implementation plan.
