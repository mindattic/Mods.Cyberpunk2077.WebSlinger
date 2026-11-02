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
  (classic corridor wall-jump) if timed within a short window. Implemented in C2WS-T11 (see below).

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

### Control: tap jump to shoot, tap jump to let go (C2WS-T30)

There is no dedicated swing bind any more. C2WS-T6's `registerInput("webslinger_swing", ...)`
hold-to-swing input (and its held/was-held/jump-fired bookkeeping: `swing.keyHeld`, `keyWasHeld`,
`auto`, `autoCount`, the `retryInterval` re-search) is gone, so nothing for this mod appears in
CET's Bindings tab. Every web action is one tap of the game's own Jump action, observed on
`PlayerPuppet:OnAction` and queued in `run.jumpQueued` like the wall triggers; `updateWallRun`
consumes it and does exactly one thing per tap:

| State when jump is tapped | Result |
|---|---|
| `SLINGING` | `releaseSling("tap released", true)`: let go with full momentum carry, anywhere in the arc |
| `NONE`, airborne | `TryManualWallRun()` (side wall), else `TryManualWallLatch()` (head-on, C2WS-T21), else `TryJumpSling()`: shoot a web at the crosshair |
| `NONE`, grounded | the wall-run / wall-latch probes as before, otherwise the plain game jump (no web) |
| `WALLRUNNING` | wall-jump (C2WS-T11), unchanged |

Wall-run and wall-latch keep priority over the web exactly as before C2WS-T30: a web only fires
when neither wall probe found a qualifying wall. A tap while `SLINGING` never does anything but a
plain release: no angle check and no special case anywhere in the arc (the C2WS-T23 boost leap and
the held-bind chain release are both removed, see below).

### Direct-aim anchor: the crosshair is the anchor (C2WS-T30)

`WebSlinger.FindAnchor(player)` casts **one** ray through `ExecuteSmartRaycast` (C2WS-T4) from the
camera (V's feet + `sling.eyeHeight`, 1.7 m, the first-person camera estimate) along the active
camera's exact forward (`GetActiveCameraForward()`, pitch included, not flattened and not blended
with V's velocity), out to `sling.AnchorMaxDistance` (45 m, slider). Whatever it hits is the
anchor, nudged 0.1 m out along the surface normal. There is no scoring and no search for a "better"
point: C2WS-T6's 20-ray cone search is gone, so the web always sticks where the player pointed.

The hit only has to be a sane attach point: at least `minAnchorHeight` (2 m) above V's feet (so the
ground right in front of her is never an anchor; lowered from 3 m because a pointed-at wall at eye
level is now a legitimate target), at least `minAnchorHorizontal` (1.5 m) away flat (not straight
overhead), and at least `minAnchorDistance` (5 m) from her hand (room to swing). **Tolerance:** only
when the centre ray misses or fails those checks, four more rays `aimToleranceDeg` (2 deg, slider;
0 turns it off) off-axis are tried in the order up, left, right, down, first usable hit wins, so a
thin edge just past the crosshair still catches. The off-axis basis is world-space (x east, y north,
z up): right = forward x up flattened (facing +y gives +x), camera-up = right x forward. 2 deg is
about 1.6 m of spread at 45 m, so the result still reads as the pointed-at spot. No usable hit is a
soft fail: no state change, the tap stays the game's own jump, and "Last shot" in the panel says
which ray hit what and why it was rejected (or that nothing was in range).

### Attach: propel, then the elastic swing (C2WS-T30)

On a successful attach (`tryAttach`), the rope length is the hand-to-anchor distance and the swing
is seeded with V's current velocity, as before. Then V gets the **propel impulse**: with
`u = (anchor - hand) / |anchor - hand|` (hand = feet + `handHeight`, world space, pointing from V
to the anchor), her velocity component along `u` is topped up to at least `sling.AttachPropelSpeed`
(18 m/s, slider): `v += u * max(0, AttachPropelSpeed - v.u)`. Her sideways momentum is kept, speed
she already had toward the anchor beyond that is kept, and speed away from the anchor is cancelled
by the same top-up. The result is speed-clamped to `maxSpeed`.

`swing.propelling` then stays on for the **propel phase**, inside the normal
`UpdateGrapplePhysics` step (gravity, steering, damping, reel-in and collision all still run). The
only difference is that the rope shortens to follow V in: whenever the integrated hand point is
closer to the anchor than the rope length, the rope length becomes that distance, so the rope never
goes slack while she is yanked inward. **Decision: a short timed phase, not "until the rope takes
hold".** With an inward impulse the rope never goes taut on its own, so "wait for the constraint"
would let V fly slack all the way to the anchor and end the swing on `anchorReachDistance`. The
phase ends after `sling.PropelDuration` (0.35 s, slider) or once the rope is down to
`minRopeLength` (6 m), whichever comes first. At that moment the leftover inward radial speed is
dropped (the web "catches") and the tangential part is kept, so the existing elastic pendulum takes
over on a taut rope from wherever the yank brought her, carrying her sideways speed. At the default
18 m/s for 0.35 s the yank covers roughly 6 m before the swing settles.

Tuning: raise `AttachPropelSpeed` for a harder yank, lengthen `PropelDuration` for a longer pull
(shorter swing radius); `PropelDuration` 0 keeps the impulse but skips the rope-follow phase, so V
flies in slack until gravity and the rope catch her at the original length. Reel-in now never
lengthens a rope that started shorter than `minRopeLength` (a close aimed anchor).

### Swing physics: `UpdateGrapplePhysics(deltaTime)`

On attach, `IsGrappling` becomes true, the state enters `SLINGING`, the rope length is set to the
current hand-to-anchor distance, and the swing is seeded with V's current velocity (estimated from
position deltas, or the carry velocity mid-air) plus the propel impulse above. Firing from the
ground (debug paths only; a tap only fires airborne) adds a 5 m/s hop. Each tick
while grappling (`deltaTime` clamped to 50 ms):

1. Gravity (`sling.gravity`, 1.6 g by default for a snappier arc).
2. Steering: a small push along the camera heading with its rope-parallel component removed, so
   it only swings V around the anchor.
3. Light damping and a speed clamp.
4. Reel-in: the rope shortens at `reelSpeed` down to `minRopeLength`. This is what pulls V toward
   the anchor, and it does so along the arc. During the propel phase the rope also shortens to
   follow V in (above).
5. Rope constraint: if the hand point ends up beyond rope length it is put back on the sphere
   around the anchor and the outward radial velocity is removed. That is the pendulum: gravity
   plus a taut rope gives an arc, never a straight pull to the point.
6. Collision via `ExecuteSmartRaycast` along the step: a walkable surface (normal z > 0.6) lands V;
   a wall slides her along it.

### Release and momentum

The swing ends (back to `NONE`) on a jump tap, on reaching within `anchorReachDistance` (2.5 m)
of the anchor, on landing, or after `maxSwingTime` (8 s). Leaving `SLINGING` any way, including a
direct `SetState`, runs the `SLINGING` `onExit` hook, which clears the rope and `IsGrappling`.
Except on landing, V's velocity at release is kept and integrated under gravity (momentum carry)
until she lands, re-attaches, or `carryMaxTime` (4 s) passes, after which native physics takes
over. The release speed is never zeroed.

Chaining is the player's own rhythm now: tap to let go wherever in the arc feels right, then tap
again mid-air to shoot the next web at wherever the crosshair is, seeded with the carried velocity.

**Removed in C2WS-T30.** C2WS-T6's held-bind auto chain release (`chainMinSwingTime`,
`chainReleaseAngleDeg`: let go automatically on the upswing while the bind stayed held, then
re-search every `retryInterval`), C2WS-T22's "jump-fired vs. held-bind" swing ownership (a
jump-fired swing also auto-released at the chain point; pressing the bind took it over), and
C2WS-T23's bottom-of-arc boost leap (`TryBoostLeap`, `leapBottomWindowDeg`, `leapBoostSpeed`,
`leapSpeedBonus`, `leapLift`, `leapCount`, and their panel lines) are all gone, by Ryan's
direction: a tap while swinging is always a plain release with momentum, with no special behavior
anywhere in the arc, and a swing never ends by itself except on landing, reaching the anchor,
`maxSwingTime`, or a wall impact. C2WS-T22's core idea (a mid-air jump fires a web) is what the
tap-to-shoot dispatch above grew from.

### Verification status

Not yet verified in-game; the agent that implemented C2WS-T30 could not run the game. Outstanding
checks from the ticket: (1) mid-air, point at a specific spot on a building, tap jump, and confirm
the web attaches exactly there (the panel's "Last shot" says "centre ray" when no tolerance ray was
needed) with an immediate visible pull toward it before the pendulum arc takes over; (2) tap jump at
the top, bottom and mid-arc of different swings and confirm a plain release with current momentum
every time ("Last release: tap released"); (3) tap again mid-air with no web and no wall nearby and
confirm a fresh web shoots at the new look direction; (4) near a side wall jump still wall-runs and
facing a wall head-on it still wall-latches; (5) CET's Bindings tab lists nothing for WebSlinger;
(6) the cable (C2WS-T25) and hand start point (C2WS-T26) still draw from attach to release,
including during the propel yank. Open risk: whether the native character controller keeps
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

### Manual head-on entry: jump into a wall (C2WS-T21)

Besides a head-on swing impact (C2WS-T7) and a wall-jump's in-flight catch (C2WS-T11), V can start
climbing from a plain jump: pressing the game's own Jump action while in `NONE` (standing, walking,
running, falling, or in post-swing carry) runs `TryManualWallLatch()` when the side wall-run probe
found nothing. It casts one `ExecuteSmartRaycast` from chest height straight along V's look/move
heading, out to `wallrun.ManualLatchDistance` (1.5 m; kept under the `CLIMBING` enter re-probe's
reach), and on a wall-like hit (`flat normal >= minWallNormal2D`) whose normal faces her head-on
(`abs(heading . normal) > impact.WallLatchAngleThreshold`, 0.75) calls
`TriggerWallLatch(normal, hitPos, velocity)` directly. There is no minimum approach speed (unlike the
swing-impact path, this is a deliberate press, not an incidental physics event) and no equipment check.

**Order of checks on a jump press in `NONE`** (`updateWallRun`): `TryManualWallRun()` (side walls)
first, then `TryManualWallLatch()` (head-on) only if no run started, so one press triggers at most
one of them. Both use the swing-impact check's latch-vs-run convention for an ambiguous wall: the
side probe accepts only `abs(heading . normal) <= min(ManualMaxFacingDot, WallLatchAngleThreshold)`,
and the head-on probe only `> WallLatchAngleThreshold`, so a wall near the boundary lands where a
swing into it would. Not yet verified in-game: from a standing or running start with no cyberware
equipped and no swing active, face a wall head-on, press jump, and confirm V enters `CLIMBING`.

**C2WS-T27 (instrumented, unconfirmed):** Ryan reported this did not work at all in-game. A static
read of the whole jump-dispatch chain (`observeWallRunJump` -> `updateWallRun` ->
`TryManualWallRun` -> `TryManualWallLatch` -> `TryJumpSling`) found no logic bug:

- The ticket's lead suspect -- `TryManualWallRun`'s forward-diagonal probe directions
  (`Vector4.new(rx + hx, ry + hy, ...)` etc.) not being unit length -- turns out not to matter:
  `ExecuteSmartRaycast` calls `normalized(direction)` on whatever it is given before casting, so
  those probes reach exactly `ManualTriggerDistance`, neither further nor shorter.
- For a flat wall straight ahead, every probe direction that reaches it (the two forward-diagonal
  ones; the pure side probes run parallel to such a wall and should not hit it) sees the same wall
  normal, so `TryManualWallRun`'s `abs(heading . normal) <= min(ManualMaxFacingDot,
  WallLatchAngleThreshold)` (0.75) correctly rejects a true head-on hit (`abs(...) ~= 1`) and leaves
  it for `TryManualWallLatch`, whose own `> WallLatchAngleThreshold` then correctly accepts it. The
  two thresholds share the same 0.75 value with no gap or overlap between them.
- The `CLIMBING` state's own re-probe on enter reaches `WallCheckDistance + standoff +
  stickDistance` = 2.0 + 0.45 + 1.0 = 3.45 m into the wall, comfortably past `ManualLatchDistance`
  (1.5 m), so a latch found by `TryManualWallLatch` should not then fail that re-probe and bounce
  back to `NONE`.
- `observeWallRunJump` and `TriggerWallLatch` have no equipment or other hidden gate.

None of this rules out a non-code cause (the mod's `enabled` checkbox not persisting across
sessions per the README is the standing suspect, since nothing in the T21-T23 chain has been run
in-game yet by anyone who could confirm it), nor a real-geometry case a flat test wall would not
show (e.g. a doorframe or other non-planar hit skewing one probe's normal). Rather than guess-fix
further without a repro, every decision point in the chain above now prints to the CET console on
every jump press in `NONE`/`WALLRUNNING`/`SLINGING` (which branch was tried, why it was rejected,
and the actual distance/angle/state values involved), so the next person who reproduces this with
the console open (`~` in-game) can read off exactly where the press stops rather than re-deriving
it from scratch. This ticket is left open pending that log.

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

Jump while `CLIMBING` is the wall-jump (C2WS-T11, below): it exits to `NONE` and hands V to the
web-sling momentum carry with velocity `wallNormal * OutwardForce (6) + up * UpwardForce (7)`, so
she arcs off the wall under the mod's gravity. From `NONE` she can fire a new web-sling, or the
wall-jump flight latches her onto the next wall she flies into. (The old climb-only
`climb.jumpOutSpeed` / `jumpUpSpeed` tunables were folded into `WebSlinger.walljump`.)

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
does and how to swing (since C2WS-T30: tap jump mid-air while looking at a wall to shoot a web, tap
again to let go). It is manual only, never sent automatically on load.

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

## Wall-run (C2WS-T9)

Two entry points into `WALLRUNNING`, neither gated by any equipment or cyberware check:

1. **Automatic:** a glancing swing impact at speed (C2WS-T7) calls
   `InitiateWallRun(wallNormal2D, velocity, hitPos)`.
2. **Manual (Titanfall-style):** pressing the game's own Jump action while in `NONE` (on foot, falling,
   or in post-swing carry) runs `TryManualWallRun()`. It casts `ExecuteSmartRaycast` from chest
   height to V's left and right and along both forward diagonals (relative to her look/move
   heading), out to `ManualTriggerDistance` (1.5 m), and takes the nearest wall whose normal is not
   facing her head-on (`abs(heading . normal) <= ManualMaxFacingDot`, 0.8, further capped at
   `impact.WallLatchAngleThreshold`, 0.75), so a wall straight ahead stays the climb's business
   (`TryManualWallLatch()`, C2WS-T21, runs next on the same press if no run started). Jump is read through `Observe("PlayerPuppet", "OnAction")`, so
   it is whatever the player has bound to jump.

`InitiateWallRun` follows the ticket's reference: `wallParallelDir` is the perpendicular of the
flat wall normal with the sign matching V's travel (her look heading if she is barely moving along
the wall), `wallRunSpeed = max(|velocity|, MinWallRunSpeed)` (15 m/s) for the manual trigger only;
a swing-impact entry keeps V's actual speed (already at least `impact.MinimumWallRunSpeed`, 8 m/s),
so the hand-off never injects velocity and momentum is conserved. The run velocity is
`wallParallelDir * wallRunSpeed + wallNormal * -StickyForce` (1.5) with Z pinned to `AntiGravityZ`
(+2.5). `UpdateWallHangPhysics(dt)` runs every `onUpdate` tick while `WALLRUNNING`: it re-probes the
wall along `-normal` (`WallProbeDistance`, 1.6 m), refreshes the normal and run direction (so gentle
curves are followed), and re-applies the velocity. The run ends (state -> `NONE`) when the probe
misses (end of the wall), a wall blocks the way ahead, or one of the drop-offs below fires.

**Duration / speed drop-off (C2WS-T10).** `InitiateWallRun` zeroes `run.time`; each tick of
`UpdateWallHangPhysics` adds `dt` and exits `WALLRUNNING` -> `NONE` (V falls, with no input needed)
once it reaches `WallRunMaxDuration` (3 s). Independently, the run ends immediately when V's speed
drops below `impact.MinimumWallRunSpeed` (8 m/s), the same threshold that routes a swing impact into
a run. "Speed" is the lower of the run speed and V's measured horizontal speed (the smoothed
position-delta estimate `swing.estVel`, checked only after `SpeedCheckGrace`, 0.25 s, so the estimate
can catch up with the entry speed). Holding back (`MoveY <= -BrakeInputThreshold`, 0.5) sheds run
speed at `BrakeDecel` (12 m/s^2), which is how V slows down mid-run on purpose; a run stalled by
geometry, or a velocity write the engine ignores, trips the measured-speed check. The debug panel
shows elapsed and remaining run time plus run and measured speed while `WALLRUNNING`, with sliders for
`WallRunMaxDuration` and `BrakeDecel`. Not yet verified in-game: (1) start a run and do nothing — V
drops off at 3 s ("duration elapsed"); (2) hold back mid-run — V drops off early ("too slow").

Velocity is written with `player:GetLocomotionComponent():SetLinearVelocity(...)` as the ticket
specifies. That call is not confirmed to exist in CET's RTTI, so it is `pcall`-guarded: if it errors
(or the debug panel's "Wall-run via SetLinearVelocity" box is cleared), the run switches to the
same teleport-per-tick approach the web-sling uses, integrating the position and holding V
`WallStandoff` (0.45 m) off the wall plane; on a natural end it hands the run velocity to the
web-sling momentum carry. Camera tilt: `Game.GetCameraSystem():SetCameraTilt(CameraTiltDeg * side,
CameraTiltTime)` (10 degrees, 0.3 s) on entry, signed by which side the wall is on, and
`SetCameraTilt(0, CameraTiltTime)` on exit; also `pcall`-guarded since the API is unverified, and the
sign convention needs checking in-game.

Jump while already wall-running is the wall-jump (C2WS-T11, below). All tunables live in
`WebSlinger.wallrun` and the main ones have debug-panel sliders.

Not yet verified in-game (the implementing agent could not run the game). Outstanding checks:
(1) wall-run along a straight building face for at least 3 s, entered from a swing impact, without
sliding off or clipping in; (2) approach a wall on foot and mid-air, look/move toward it to one
side, press jump, and confirm the same run starts; (3) whether `SetLinearVelocity` and
`SetCameraTilt` exist (watch the CET console for the "driving V by teleport" line).

## Wall-jump (C2WS-T11)

`WebSlinger.WallJump()` runs on the game's own Jump action (same `PlayerPuppet:OnAction` observers
as the climb and the manual wall-run trigger) while `CLIMBING` or `WALLRUNNING`. It exits that
state and launches V with `wallNormal * OutwardForce + Vector4(0, 0, UpwardForce, 0)` (6 and 7 m/s);
off a wall-run the run's along-wall speed (`dir * speed * RunCarry`, `RunCarry` 1.0) is added, so
the jump keeps the run's momentum. The flight is the web-sling momentum carry (teleport-driven,
the mod's swing gravity), so every jump from a standstill on a wall flies the same arc.

**Landing on the next wall.** While the flight lasts (`wj.flying`, until V lands on the ground,
re-slings, or the carry times out), `updateWallJump` runs before the web-sling tick and casts
`ExecuteSmartRaycast` (C2WS-T4) from chest height along V's horizontal velocity, `CatchDistance`
(0.9 m) plus this tick's travel. A wall-like hit she is flying into (`dir . n <= -MinApproachDot`,
0.3; not in the first `MinFlightTime`, 0.08 s, so the launch wall is never re-caught) latches her
onto it (`TriggerWallLatch` -> `CLIMBING`, which zeroes her velocity).

**Chain.** If that wall roughly faces the one she jumped off (`nLand . nLaunch <= -FacingDot`,
0.5), the landing opens a `ChainWindow` (0.6 s). A wall-jump inside the window is a chain: it is
never blocked by the `Cooldown` (0.35 s minimum between wall-jumps, which otherwise stops a
double-tap or a too-quick re-jump in a narrow gap). Outside the window it is just a normal
wall-jump. Times run on `wj.clock`, accumulated enabled `onUpdate` time, so pausing doesn't eat the
window. Because each landing zeroes velocity and each jump applies the same impulse, alternating
between two facing walls clears comparable height and distance every jump.

The debug panel shows flying state, chain count, the remaining chain window, the last jump and
landing (including height gained versus launch), with sliders for `OutwardForce`, `UpwardForce`,
`ChainWindow` and `Cooldown`; all tunables live in `WebSlinger.walljump`.

Not yet verified in-game (the implementing agent could not run the game). Outstanding check from
the ticket: in a corridor with two facing walls, alternate wall-jumping between them at least 3
times without touching the ground ("chain xN" in the CET console / panel), each jump clearing
comparable height and distance to the first. Also confirm jumping off a wall-run launches out and
forward, not back into the wall.

## Re-sling loop (C2WS-T12)

The web-sling tap fires whenever V is airborne in `NONE`, however `NONE` was entered (wall-jump,
wall-run drop-off, climb exit, swing release, or a plain fall): the jump dispatch only looks at the
current state, and every mechanic leaves through `SetState(NONE)`, so swing -> wall-run -> wall-jump
-> swing -> latch -> climb-jump -> swing needs no special-casing. A tap in `NONE` attaches at once
(the held-bind re-search of the original version was removed in C2WS-T30).

The end-to-end pass found and fixed three leaks between the mechanics:

1. **Stale velocity estimate after a swing.** `trackVelocity` does not run while `SLINGING`, so a
   release without carry (landed, wall impact) left the pre-swing `swing.estVel` behind; it then
   seeded the next swing and the wall-run's measured-speed drop-off. `UpdateGrapplePhysics` now keeps
   `estVel` equal to the swing velocity every tick.
2. **Teleport-mode wall-run always "too slow".** The teleport fallback of `applyRunVelocity` set
   `swing.lastPos` to the new position, so the next tick's `trackVelocity` measured ~0 m/s and the
   run ended right after `SpeedCheckGrace`. The write is gone; `trackVelocity` measures the real
   per-tick displacement.
3. **Wall-jump flight surviving a re-sling.** A swing that attached and released with carry inside
   one tick left `wj.flying` set, so the post-swing carry was treated as the old wall-jump's flight
   (wall catch and chain check against the stale launch wall). `SLINGING`'s `onEnter` now clears it.

**Verification aid.** `SetState` keeps the last 16 transitions in `WebSlinger.transitionLog` (shown
under "Transition log" in the debug panel, with a Clear button) and counts any `SLINGING` entry
whose previous state was not `NONE` (`slingWithoutNone`, also printed as a WARNING line). It must
stay 0; only the debug Force state buttons can raise it on purpose.

Not yet verified in-game (the implementing agent could not run the game). Outstanding check from
the ticket, in one continuous take: swing -> wall-run -> wall-jump -> swing again ->
wall-latch-climb -> climb-jump -> swing again, with no scripting error, no stuck state, and the
transition log showing a `NONE` between every two `SLINGING` entries (counter still 0).

## Polish: camera tilt easing, impact feedback (C2WS-T13)

**Eased tilt.** The wall-run no longer makes one flat `SetCameraTilt(target, CameraTiltTime)` call.
`setCameraTilt` now only records a target; `updatePolish` (every `onUpdate`, also while the mod is
disabled so an exit tilt still settles) eases the mod-owned roll from where it currently is toward
the target with a smoothstep over `CameraTiltTime` (0.3 s), writing it with a zero engine blend on
each tick it changes. Because the ease starts from the current roll, a run that ends mid-tilt eases
back from there instead of jumping.

**Impact feedback.** `PlayImpactFeedback(strength, label)` plays a decaying sine roll shake
(`ShakeAmplitudeDeg` 2, `ShakeDuration` 0.22 s, `ShakeFrequency` 18 Hz) added on top of the eased
tilt, plus an FOV punch through `player:GetFPPCameraComponent():GetFOV()/SetFOV()` (+`FovPunchDeg` 5,
linear rise over `FovPunchRise` 0.05 s, smoothstep fall over `FovPunchFall` 0.25 s, then the base FOV
is restored exactly). It fires at full strength when `CLIMBING` is entered successfully (wall-latch
impact) and at `JumpScale` (0.7) on every wall-jump launch. All engine calls are `pcall`-guarded; if
the FOV calls are unavailable the panel's last-feedback line says "[FOV unavailable]" and only the
shake plays.

**Input lag.** Idle ticks return immediately; an animating tick is a handful of arithmetic ops and
at most two engine writes, and nothing in the input path (key/jump observers, state changes) waits
on it. Its own cost is timed (`fx.costMs`) and shown in the panel next to the T1 frame-time counter;
the "Polish" checkbox turns it all off (back to the flat engine-blended tilt, no impulses) so the
"Frame" readout can be compared with polish on and off. Tunables live in `WebSlinger.polish`.

Not yet verified in-game (the implementing agent could not run the game). Outstanding checks: the
tilt eases in and out with no snap; the shake and FOV punch read on a latch and a wall-jump; the
"Frame" counter stays at its polish-off baseline with polish on.

## Monowire visual on V's hand (C2WS-T26)

Cosmetic only. Like the climb (see "No equipment gate"), nothing here checks or requires real
cyberware, and nothing may change what V actually has equipped or drawn.

### Gap: no Monowire model from CET

Spiked from CET Lua alone (no RED4ext, no redscript), the three candidates:

- **(a) Toggle a Monowire visual/appearance on V's arm.** In CP77 the Monowire is a weapon item
  that only renders when the equipment state machine draws it into the right-hand weapon slot.
  CET can reach `EquipmentSystem` / `TransactionSystem` (draw requests, `AddItemToSlot`,
  `GiveItem`), but every one of those changes real state: it holsters or replaces a drawn weapon,
  changes the active weapon selection, or adds an inventory item, and the swap persists unless
  restored exactly. There is no exposed "appearance only" path (`ItemsFactoryAppearance`
  changes need an item entity spawned in a slot, which is the same `TransactionSystem` mutation).
  It also only works when V has the Monowire installed. Rejected: violates "never alter V's
  equipped cyberware/weapon state".
- **(b) Play the Monowire deploy animation.** The deploy/whip animations are driven by the
  weapon state machine and animation features bound to the drawn item; there is no standalone
  animation request exposed to script that plays them on V's arms without that item drawn.
  Rejected for the same reason as (a).
- **(c) Anchor the line at V's hand.** Reachable read-only: `FindComponentByName` on the player
  plus `SlotComponent.GetSlotTransform` returns a slot's world transform without touching
  equipment. **Shipped.**

A genuine Monowire-model deploy would need a RED4ext-level hook (or redscript + Codeware) into the
equipment/animation systems to drive a visual-only item. That breaks the README's "CET and nothing
else" requirement, so it is left as a follow-up needing its own explicit go-ahead.

### What ships: hand-anchored swing line

`monowireHandPoint()` (init.lua, called by `drawRope()`) starts the swing line at V's right-hand
attachment slot. On each new swing it tries the `WebSlinger.monowire.components` x `slots`
candidates (`Item_Attachment_Slot` / `RightHand`, `WeaponRight`, ... ) once, caches the first that
returns a plausible transform (within `MaxSlotOffset` of the expected hand), and reads it every
draw frame. If none resolves, or a reading is implausible, the line falls back to an estimate:
shoulder height (`sling.handHeight`), `FallbackReach` metres toward the anchor. Swing physics are
unchanged; only where the line is drawn from moves. Every engine call is `pcall`-guarded.

Debug panel: **Monowire: swing line starts at V's hand** (off = the old fixed start point) and
**Hand anchor source** (the component/slot in use, or `estimate`).

### Verification status

Not yet verified in-game (the implementing agent could not run the game). Outstanding checks:
swing and confirm "Hand anchor source" names a slot (not `estimate`) and the line visibly leaves
V's hand in third person and in first person (the FPP arms are a separate rig, so the slot may sit
slightly off the visible FPP hand; tune or add a slot name if so); then with a weapon drawn and
with the Monowire equipped, swing and release and confirm the drawn weapon, the selected
cyberware and the inventory are exactly as before (the code makes no equipment calls, so this is
expected to hold).

## Implementation approach (open question)

CET's Lua layer can hook input, read/write exposed RTTI properties, and draw debug UI, but V's
movement is driven by native animation/physics state machines. Whether wall-run/wall-jump/sling
feel achievable purely through CET property pokes + TweakDB, or need a RED4ext native plugin for
direct hooks into the movement component, is the first thing to spike before committing to a full
implementation plan.
