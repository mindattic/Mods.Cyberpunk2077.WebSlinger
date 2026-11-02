-- WebSlinger: Mantis Blade wall-climb, wall-run/jump, and web-sling traversal for Cyberpunk 2077.
-- This file provides the wall-detection raycast utility (C2WS-T4) every mechanic builds on, plus
-- its debug overlay, the traversal state machine (C2WS-T5: States + SetState with per-state
-- onEnter/onExit hooks), and the web-sling base (C2WS-T6: hold-to-swing hotkey, cone anchor
-- search, rope-constrained pendulum physics, release with momentum carry), and the wall-impact
-- angle check during a swing (C2WS-T7: latch vs. wall-run hand-off), and the wall-run itself
-- (C2WS-T9: wall-parallel run velocity, sticky force, camera tilt, manual jump-key trigger), and the
-- wall-jump off a climb or wall-run, chainable between facing walls (C2WS-T11), and the
-- end-to-end re-sling loop pass (C2WS-T12: state-leak fixes plus a transition log), and the polish
-- pass (C2WS-T13: eased wall-run camera tilt, impact shake + FOV punch on latch and wall-jump). See
-- docs/DESIGN.md in the repo root for the states, the raycast API notes, and the design decisions.

-- Traversal states (C2WS-T5). Every mechanic reads and changes the current state only through
-- WebSlinger.state and WebSlinger.SetState; never assign WebSlinger.state directly.
local States = {
  NONE = "NONE",
  CLIMBING = "CLIMBING",
  WALLRUNNING = "WALLRUNNING",
  SLINGING = "SLINGING",
}

-- Display/iteration order for the debug panel.
local STATE_ORDER = { States.NONE, States.CLIMBING, States.WALLRUNNING, States.SLINGING }

-- How many recent transitions the debug panel's transition log keeps (C2WS-T12).
local TRANSITION_LOG_SIZE = 16

local WebSlinger = {
  -- C2WS-T16: release version; tools/package.ps1 names dist/WebSlinger-<version>.zip from it.
  version = "0.1.0",
  enabled = false,
  States = States,
  state = States.NONE,
  lastTransition = nil, -- { from, to, clock, wallTime } of the most recent SetState, nil if none yet
  transitionCount = 0,
  transitionLog = {},    -- last TRANSITION_LOG_SIZE transitions, oldest first, for the debug panel (C2WS-T12)
  slingWithoutNone = 0,  -- SLINGING entries not coming from NONE; must stay 0 (C2WS-T12)

  debugRaycast = false,  -- "Debug: show wall raycast" checkbox
  probeDistance = 3.0,   -- metres the forward wall probe reaches
  probeHeight = 1.2,     -- metres above V's feet the probe starts (roughly chest height)

  -- Latest probe, written once per onUpdate tick and only read by onDraw.
  probe = {
    valid = false,
    origin = nil,
    target = nil,
    hit = false,
    hitPos = nil,
    hitNormal = nil,
  },

  -- Frame-time counters for the debug panel (milliseconds).
  timing = {
    frameMs = 0.0,    -- smoothed onUpdate deltaTime
    raycastMs = 0.0,  -- smoothed cost of the raycast itself
  },

  -- Web-sling (C2WS-T6). True exactly while a rope is attached and the state is SLINGING.
  IsGrappling = false,

  -- Web-sling tunables. All distances in metres, times in seconds, accelerations in m/s^2.
  sling = {
    AnchorMaxDistance = 45.0,   -- how far the anchor search reaches
    minAnchorHeight = 3.0,      -- anchor must sit at least this far above V's feet
    minAnchorHorizontal = 1.5,  -- reject anchors almost straight overhead (no swing room)
    searchYawDeg = { -45.0, -22.5, 0.0, 22.5, 45.0 },  -- cone of sample rays around the aim heading
    searchPitchDeg = { 20.0, 35.0, 50.0, 65.0 },       -- elevation of each sample ray above horizontal
    eyeHeight = 1.6,            -- sample rays start this far above V's feet
    handHeight = 1.5,           -- rope attaches to V this far above her feet
    gravity = 9.81 * 1.6,       -- swing gravity; a bit heavier than real for a snappier arc
    damping = 0.02,             -- fraction of velocity bled per second while swinging
    reelSpeed = 4.0,            -- rope shortens this fast, pulling V toward the anchor
    minRopeLength = 6.0,        -- reel never shortens the rope below this
    steerAccel = 6.0,           -- tangential push toward the camera's heading while swinging
    anchorReachDistance = 2.5,  -- reaching this close to the anchor ends the swing
    maxSwingTime = 8.0,         -- safety cap on a single swing
    maxSpeed = 40.0,            -- velocity clamp while swinging/carrying
    chainMinSwingTime = 0.45,   -- with the key held, auto-release only after this long on the rope
    chainReleaseAngleDeg = 35.0,-- ... and once V has swung this far past the bottom, rising
    -- Boost leap (C2WS-T23): jump near the bottom of the arc lets go toward the look heading.
    leapBottomWindowDeg = 25.0, -- jump counts as "at the bottom" within this angle of straight down
    leapBoostSpeed = 24.0,      -- horizontal launch speed floor along the look heading
    leapSpeedBonus = 6.0,       -- ... or current swing speed plus this, whichever is faster
    leapLift = 6.0,             -- vertical speed floor (m/s) at launch, so the leap clears the arc
    retryInterval = 0.15,       -- with the key held and no rope, re-search this often
    launchSpeed = 5.0,          -- upward hop (m/s) when firing from the ground
    carryMaxTime = 4.0,         -- momentum carry after release hands back to native physics after this
  },

  -- Live web-sling state. Written only by the onUpdate tick (and SetState hooks).
  swing = {
    keyHeld = false,      -- current state of the CET-bound swing input, polled each tick
    keyWasHeld = false,   -- keyHeld as of the previous tick, for edge detection
    auto = false,         -- current swing was auto-fired by a mid-air jump, not the held bind (C2WS-T22)
    autoCount = 0,        -- swings auto-fired by a mid-air jump, for the panel
    leapCount = 0,        -- bottom-of-swing boost leaps (C2WS-T23), for the panel
    anchor = nil,        -- Vector4 world anchor point while attached
    anchorNormal = nil,   -- surface normal at the anchor
    ropeLength = 0.0,
    pos = nil,            -- simulated feet position (Vector4) while attached or carrying
    vel = nil,            -- simulated velocity { x, y, z } while attached or carrying
    time = 0.0,           -- seconds on the current rope
    retryTimer = 0.0,
    carry = false,        -- true while post-release momentum is still being integrated
    carryTime = 0.0,
    lastPos = nil,        -- V's position last tick, for the velocity estimate below
    estVel = { x = 0.0, y = 0.0, z = 0.0 },  -- smoothed velocity of V from position deltas
    lastSearch = "(none yet)",  -- one-line result of the last anchor search, for the panel
    attachCount = 0,
  },

  -- Visible swing cable (C2WS-T25) tunables. In first person V's real hand point (her body centre)
  -- sits under the camera, so the cable is drawn from a point just ahead of the camera, offset to
  -- the lower right where V's right hand shows on screen. Distances in metres along the camera axes.
  rope = {
    thickness = 4.0,            -- core cable width in pixels (the old debug line was 2.0)
    color = { 0.10, 0.85, 1.00, 0.95 },  -- electric cyan; never the debug overlay's green/red/yellow
    glowScale = 3.0,            -- soft halo drawn under the core, this many times its width
    glowAlpha = 0.25,           -- halo opacity relative to the core colour
    anchorRadius = 5.0,         -- dot at the anchor end, pixels
    -- C2WS-T29: centred and dropped below the visible frame (reads as coming from around V's
    -- belly/belt line) instead of hovering as a visible dot in the lower-right of view.
    handForward = 0.5,          -- cable start: this far ahead of the camera
    handRight = 0.0,            -- ... this far to its right (centred)
    handDown = 1.0,             -- ... and this far below it (pushes it below the visible frame)
    cameraHeight = 1.7,         -- camera height above V's feet, for the start point and clipping
    nearClip = 0.1,             -- parts of the cable closer than this to the camera plane are cut
  },

  -- Wall-impact check during a swing (C2WS-T7) tunables.
  impact = {
    WallCheckDistance = 2.0,         -- metres ahead of V's velocity the impact probe reaches
    WallLatchAngleThreshold = 0.75,  -- |movementDir . wallNormal2D| above this = head-on -> latch
    MinimumWallRunSpeed = 8.0,       -- m/s; a diagonal hit slower than this latches instead
    probeHeight = 1.2,               -- metres above V's feet the impact probe starts
    minMoveSpeed2D = 1.0,            -- below this horizontal speed there is no travel direction to test
    minWallNormal2D = 0.5,           -- hit normals flatter than this (floors, ledges) are not walls
  },

  -- Hand-off from the impact check to the climb / wall-run mechanics (C2WS-T8 / C2WS-T9).
  -- Written by TriggerWallLatch / InitiateWallRun right before they enter their state.
  wall = {
    normal = nil,     -- Vector4 flat (z = 0) unit wall normal, pointing out of the wall
    hitPos = nil,     -- Vector4 impact point
    velocity = nil,   -- { x, y, z } V's velocity at impact
    lastImpact = "(none yet)",  -- one-line log of the last impact decision, for the panel
    impactCount = 0,
  },

  -- Wall-climb (C2WS-T8) tunables. Distances in metres, speeds in m/s.
  climb = {
    speedUp = 3.0,          -- climbing up the wall
    speedDown = 4.0,        -- climbing down the wall
    speedStrafe = 3.0,      -- sideways along the wall
    standoff = 0.45,        -- V's feet are held this far out from the wall surface
    probeHeight = 1.2,      -- the stick probe starts this far above V's feet (chest)
    stickDistance = 1.0,    -- probe reaches standoff + this into the wall; a miss means an edge
    minWallNormal2D = 0.5,  -- surfaces flatter than this (ledges, slopes) are not climbable walls
    -- (jump off the wall: see WebSlinger.walljump, C2WS-T11)
    mantleForward = 0.8,    -- top edge: how far over the ledge V is placed
    mantleReach = 2.5,      -- top edge: how far down from above the ledge the landing probe looks
  },

  -- Live wall-climb state. Written by the onUpdate tick, the CLIMBING hooks and the input observer.
  climbing = {
    pos = nil,          -- Vector4 V's feet position while climbing
    normal = nil,       -- Vector4 flat unit wall normal, pointing out of the wall
    moveX = 0.0,        -- latest MoveX axis (strafe, -1..1), from PlayerPuppet:OnAction
    moveY = 0.0,        -- latest MoveY axis (up/down, -1..1)
    jumpQueued = false, -- Jump pressed while CLIMBING; consumed by the next climb tick
    startZ = 0.0,       -- feet height on entering CLIMBING, for the "climbed" readout
    invulnerable = false,  -- true while WebSlinger holds the god-mode flag (see docs/DESIGN.md)
    lastExit = "(none yet)",
  },
}

-- Collision groups the probe tests against. Walls are static geometry; terrain covers rock faces.
local WALL_COLLISION_GROUPS = { "Static", "Terrain" }

-- Wall-run (C2WS-T9) tunables. Speeds in m/s, times in seconds, distances in metres.
WebSlinger.wallrun = {
  MinWallRunSpeed = 15.0,       -- speed floor for a manual (jump) wall-run; swing entries keep their speed
  StickyForce = 1.5,            -- velocity pushed into the wall every tick so V can't drift off it
  AntiGravityZ = 2.5,           -- vertical velocity pinned for the whole run (no sag, slight rise)
  CameraTiltDeg = 10.0,         -- camera roll on entry, away from the wall
  CameraTiltTime = 0.3,         -- blend time of the tilt in and back to neutral
  WallRunMaxDuration = 3.0,     -- seconds from InitiateWallRun until V drops off (C2WS-T10)
  SpeedCheckGrace = 0.25,       -- seconds after entry before the measured-speed drop-off is checked
  BrakeDecel = 12.0,            -- m/s^2 shed from the run speed while V holds back (MoveY < 0)
  BrakeInputThreshold = 0.5,    -- MoveY at or below -this counts as holding back
  WallProbeDistance = 1.6,      -- per-tick "still on the wall" probe reach, into the wall
  WallStandoff = 0.45,          -- teleport fallback keeps V's centre this far off the wall plane
  BlockedProbeDistance = 1.0,   -- an obstacle this close ahead along the run ends it
  probeHeight = 1.2,            -- metres above V's feet the wall probes start
  minWallNormal2D = 0.5,        -- hit normals flatter than this (floors, ledges) are not walls
  ManualTriggerDistance = 1.5,  -- jump-key side probes reach this far left/right of V
  ManualMaxFacingDot = 0.8,     -- |aim heading . wallNormal| above this = wall ahead, not to the side
  ManualLatchDistance = 1.5,    -- jump-key head-on probe reach straight ahead of V (C2WS-T21)
  UseLocomotionVelocity = true, -- false = drive V by teleport each tick instead of SetLinearVelocity
}

-- Live wall-run state. Written by InitiateWallRun, UpdateWallHangPhysics and the WALLRUNNING hooks.
WebSlinger.run = {
  normal = nil,         -- Vector4 flat unit wall normal (out of the wall), refreshed every tick
  dir = nil,            -- Vector4 flat unit run direction along the wall
  speed = 0.0,          -- run speed along the wall, fixed at entry
  side = 0,             -- +1 wall on V's right, -1 on her left
  time = 0.0,           -- seconds since InitiateWallRun; the run ends at WallRunMaxDuration
  measuredSpeed = 0.0,  -- V's measured horizontal speed this tick (C2WS-T10 drop-off check)
  pos = nil,            -- simulated feet position, teleport fallback only
  vel = nil,            -- last velocity applied { x, y, z }
  teleportMode = false, -- true when SetLinearVelocity is off or failed this run
  endReason = nil,      -- set by endWallRun right before leaving WALLRUNNING
  endCarry = nil,
  jumpQueued = false,   -- jump pressed since the last onUpdate tick
  lastEntry = "(none yet)",
  lastEnd = "(none yet)",
  count = 0,
}

-- Wall-jump (C2WS-T11) tunables. Speeds in m/s, times in seconds, distances in metres.
WebSlinger.walljump = {
  OutwardForce = 6.0,    -- launch speed along the wall normal (away from the wall)
  UpwardForce = 7.0,     -- launch speed straight up
  RunCarry = 1.0,        -- fraction of the wall-run's along-wall speed kept on a jump off a run
  ChainWindow = 0.6,     -- a jump this soon after landing a wall-jump on a facing wall is a chain
  Cooldown = 0.35,       -- minimum time between two wall-jumps; a chain is never blocked by it
  FacingDot = 0.5,       -- landing wall counts as facing the launch wall if nLand . nLaunch <= -this
  MinApproachDot = 0.3,  -- in flight, only walls V is moving into (dir . n <= -this) catch her
  CatchDistance = 0.9,   -- in-flight wall probe reach (plus this tick's travel)
  MinFlightTime = 0.08,  -- don't catch a wall this early in the flight (the launch wall)
  probeHeight = 1.2,     -- in-flight wall probe starts this far above V's feet
  minWallNormal2D = 0.5, -- hit normals flatter than this (floors, ledges) are not walls
}

-- Live wall-jump state. Written by WallJump, the in-flight landing check, and onUpdate.
WebSlinger.wj = {
  clock = 0.0,           -- seconds of enabled onUpdate time; the timeline for windows/cooldown
  flying = false,        -- true from a wall-jump until V lands on a wall, the ground, or anything else
  flightTime = 0.0,
  launchNormal = nil,    -- Vector4 flat normal of the wall jumped off
  launchZ = 0.0,         -- V's feet height at launch, for the per-jump height readout
  lastJumpAt = nil,      -- wj.clock of the last wall-jump
  landedAt = nil,        -- wj.clock when a wall-jump flight was caught by a wall
  landedFacing = false,  -- ... and whether that wall roughly faced the launch wall (chain-eligible)
  chainCount = 0,        -- consecutive chained wall-jumps (0 = the last jump was not a chain)
  jumpCount = 0,
  lastResult = "(none yet)",
  lastLanding = "(none yet)",
}

local function vec4(x, y, z)
  return Vector4.new(x, y, z, 1.0)
end

local function lengthOf(v)
  return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function normalized(v)
  local len = lengthOf(v)
  if len < 1e-6 then return nil end
  return Vector4.new(v.x / len, v.y / len, v.z / len, 0.0)
end

local function smooth(previous, sample)
  return previous + (sample - previous) * 0.1
end

--- Casts a ray against world collision and reports the first wall surface it touches.
-- origin: Vector4 world position the ray starts from.
-- direction: Vector4 direction (need not be normalized).
-- maxDistance: number, metres.
-- Returns hit (bool), hitPos (Vector4 or nil), hitNormal (Vector4 or nil). hitNormal is unit
-- length and always faces back toward the ray origin (away from the wall surface).
function WebSlinger.ExecuteSmartRaycast(origin, direction, maxDistance)
  local dir = normalized(direction)
  if dir == nil or maxDistance == nil or maxDistance <= 0 then
    return false, nil, nil
  end

  local target = vec4(
    origin.x + dir.x * maxDistance,
    origin.y + dir.y * maxDistance,
    origin.z + dir.z * maxDistance)

  local queries = Game.GetSpatialQueriesSystem()
  if queries == nil then return false, nil, nil end

  local bestHit, bestDist = nil, math.huge
  for _, group in ipairs(WALL_COLLISION_GROUPS) do
    local ok, trace = queries:SyncRaycastByCollisionGroup(origin, target, group, false, false)
    if ok and trace ~= nil then
      local pos = trace.position
      local dx, dy, dz = pos.x - origin.x, pos.y - origin.y, pos.z - origin.z
      local dist = dx * dx + dy * dy + dz * dz
      if dist < bestDist then
        bestDist, bestHit = dist, trace
      end
    end
  end

  if bestHit == nil then return false, nil, nil end

  local hitPos = vec4(bestHit.position.x, bestHit.position.y, bestHit.position.z)
  local hitNormal = normalized(bestHit.normal)
  if hitNormal == nil then
    -- Degenerate normal from the engine: fall back to facing straight back along the ray.
    hitNormal = Vector4.new(-dir.x, -dir.y, -dir.z, 0.0)
  elseif hitNormal.x * dir.x + hitNormal.y * dir.y + hitNormal.z * dir.z > 0 then
    -- Back-face hit: flip so the normal always points out of the wall, toward the caster.
    hitNormal = Vector4.new(-hitNormal.x, -hitNormal.y, -hitNormal.z, 0.0)
  end

  return true, hitPos, hitNormal
end

-- Per-state hook pair. onExit(oldState) runs on the state being left, then onEnter(newState) on
-- the state being entered. Stubs for now; later mechanics fill these in.
local function noop() end
local StateHooks = {}
for _, name in ipairs(STATE_ORDER) do
  StateHooks[name] = { onEnter = noop, onExit = noop }
end
WebSlinger.StateHooks = StateHooks

--- Moves the traversal state machine to newState.
-- Logs the transition and runs the old state's onExit then the new state's onEnter, each exactly
-- once. Setting the current state again is a no-op (no log, no hooks). Unknown states are
-- rejected with a log line. Returns true if a transition happened.
function WebSlinger.SetState(newState)
  if StateHooks[newState] == nil then
    print("[WebSlinger] SetState: unknown state '" .. tostring(newState) .. "' ignored")
    return false
  end

  local oldState = WebSlinger.state
  if newState == oldState then return false end

  -- Commit the new state before running hooks so a hook that reads WebSlinger.state (or calls
  -- SetState itself) sees the post-transition value.
  WebSlinger.state = newState
  WebSlinger.transitionCount = WebSlinger.transitionCount + 1
  WebSlinger.lastTransition = {
    from = oldState,
    to = newState,
    clock = os.clock(),
    wallTime = os.date("%H:%M:%S"),
  }
  print(string.format("[WebSlinger] state %s -> %s (#%d)", oldState, newState, WebSlinger.transitionCount))

  -- Re-sling loop check (C2WS-T12): every swing must start from NONE, so a SLINGING entry from
  -- any other state is state leakage (only the debug Force state buttons can do it on purpose).
  local log = WebSlinger.transitionLog
  log[#log + 1] = string.format("#%d %s %s -> %s", WebSlinger.transitionCount,
    WebSlinger.lastTransition.wallTime, oldState, newState)
  if #log > TRANSITION_LOG_SIZE then table.remove(log, 1) end
  if newState == States.SLINGING and oldState ~= States.NONE then
    WebSlinger.slingWithoutNone = WebSlinger.slingWithoutNone + 1
    print(string.format("[WebSlinger] WARNING: SLINGING entered from %s, not NONE (#%d)",
      oldState, WebSlinger.slingWithoutNone))
  end

  local exitHook = StateHooks[oldState] and StateHooks[oldState].onExit
  if exitHook then exitHook(oldState) end
  local enterHook = StateHooks[newState].onEnter
  if enterHook then enterHook(newState) end
  return true
end

-- ---------------------------------------------------------------------------------------------
-- Web-sling (C2WS-T6)
--
-- A fully custom parallel state, not the native PlayerPuppet grapple (see docs/DESIGN.md for why).
-- V's feet position and velocity are simulated here as a point mass on a rope that can only go
-- slack, never stretch (a pendulum), and written back with the teleportation facility each tick.
-- ---------------------------------------------------------------------------------------------

local atan2 = math.atan2 or math.atan

local function swingSpeed(v)
  return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function clampSpeed(v, maxSpeed)
  local speed = swingSpeed(v)
  if speed > maxSpeed then
    local k = maxSpeed / speed
    v.x, v.y, v.z = v.x * k, v.y * k, v.z * k
  end
end

-- Writes V's position. Keeps her current yaw so mouse look is never fought.
local function placeV(player, p)
  local facility = Game.GetTeleportationFacility()
  if facility == nil then return false end
  facility:Teleport(player, vec4(p.x, p.y, p.z), EulerAngles.new(0.0, 0.0, player:GetWorldYaw()))
  return true
end

-- Flat unit heading the player is "roughly aiming" along: the camera's look direction, nudged
-- toward V's horizontal travel direction when she is moving fast enough for that to mean anything.
local function aimHeading(player, blendWithVelocity)
  local look = nil
  local ok, camForward = pcall(function()
    return Game.GetCameraSystem():GetActiveCameraForward()
  end)
  if ok and camForward ~= nil then look = camForward else look = player:GetWorldForward() end

  local hx, hy = look.x, look.y
  local hlen = math.sqrt(hx * hx + hy * hy)
  if hlen < 1e-4 then
    local fwd = player:GetWorldForward()
    hx, hy, hlen = fwd.x, fwd.y, math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y)
    if hlen < 1e-4 then return 0.0, 1.0 end
  end
  hx, hy = hx / hlen, hy / hlen

  if blendWithVelocity then
    local v = WebSlinger.swing.carry and WebSlinger.swing.vel or WebSlinger.swing.estVel
    local vlen = math.sqrt(v.x * v.x + v.y * v.y)
    if vlen > 4.0 then
      local bx, by = hx + 0.5 * v.x / vlen, hy + 0.5 * v.y / vlen
      local blen = math.sqrt(bx * bx + by * by)
      if blen > 1e-4 then hx, hy = bx / blen, by / blen end
    end
  end
  return hx, hy
end

local function isGrounded(pos)
  local hit = WebSlinger.ExecuteSmartRaycast(vec4(pos.x, pos.y, pos.z + 0.3), Vector4.new(0.0, 0.0, -1.0, 0.0), 0.6)
  return hit
end

--- Generous anchor search: a cone of sample rays ahead of and above V, centred on where the
-- player is roughly looking/moving, out to sling.AnchorMaxDistance. Every ray is a line-of-sight
-- test by construction (ExecuteSmartRaycast returns the first surface it touches). Picks the best
-- qualifying high point. Returns anchor (Vector4) and normal (Vector4), or nil, nil; the third
-- return is a one-line summary for the debug panel.
function WebSlinger.FindAnchor(player)
  local cfg = WebSlinger.sling
  local pos = player:GetWorldPosition()
  local hx, hy = aimHeading(player, true)
  local baseYaw = atan2(hy, hx)
  local eye = vec4(pos.x, pos.y, pos.z + cfg.eyeHeight)

  local best, bestNormal, bestScore = nil, nil, -math.huge
  local rays, hits = 0, 0
  for _, yawOffset in ipairs(cfg.searchYawDeg) do
    local yaw = baseYaw + math.rad(yawOffset)
    local alignment = math.cos(math.rad(yawOffset))
    for _, pitchDeg in ipairs(cfg.searchPitchDeg) do
      local pitch = math.rad(pitchDeg)
      local dir = Vector4.new(math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch), 0.0)
      rays = rays + 1
      local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(eye, dir, cfg.AnchorMaxDistance)
      if hit then
        hits = hits + 1
        local height = hitPos.z - pos.z
        local dx, dy = hitPos.x - pos.x, hitPos.y - pos.y
        local horizontal = math.sqrt(dx * dx + dy * dy)
        if height >= cfg.minAnchorHeight and horizontal >= cfg.minAnchorHorizontal then
          -- Prefer anchors near the aim heading, high up, and far enough ahead to give a long arc.
          local score = alignment * 8.0 + height * 0.5 + math.min(horizontal, 25.0) * 0.4
          if score > bestScore then
            best, bestNormal, bestScore = hitPos, hitNormal, score
          end
        end
      end
    end
  end

  if best == nil then
    return nil, nil, string.format("no anchor (%d rays, %d hits, none qualified)", rays, hits)
  end
  -- Nudge the anchor out of the surface so the rope end never sits inside geometry.
  local anchor = vec4(best.x + bestNormal.x * 0.1, best.y + bestNormal.y * 0.1, best.z + bestNormal.z * 0.1)
  return anchor, bestNormal, string.format("anchor %.1fm up, %d/%d rays hit", anchor.z - pos.z, hits, rays)
end

-- Moves the simulated body from swing.pos to (nx, ny, nz) without passing through world geometry.
-- A walkable surface in the way lands V (returns true); a wall slides her along it and removes
-- the velocity component driving into it.
local function moveWithCollision(s, nx, ny, nz)
  local from = vec4(s.pos.x, s.pos.y, s.pos.z + 0.9)
  -- Direction matches V's real per-tick displacement (origin only is raised to chest height);
  -- deriving it from the raised origin toward the unraised target skewed the probe steeply
  -- downward on near-flat ticks, which could false-trigger a "landed" hit on sloped ground
  -- well below an actual mid-swing V.
  local dx, dy, dz = nx - s.pos.x, ny - s.pos.y, nz - s.pos.z
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len > 1e-3 then
    local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(from, Vector4.new(dx, dy, dz, 0.0), len + 0.1)
    if hit then
      if hitNormal.z > 0.6 and s.vel.z <= 0.0 then
        s.pos = vec4(hitPos.x, hitPos.y, hitPos.z)
        return true
      end
      local v = s.vel
      local into = v.x * hitNormal.x + v.y * hitNormal.y + v.z * hitNormal.z
      if into < 0.0 then
        v.x, v.y, v.z = v.x - into * hitNormal.x, v.y - into * hitNormal.y, v.z - into * hitNormal.z
      end
      nx, ny = hitPos.x + hitNormal.x * 0.45, hitPos.y + hitNormal.y * 0.45
    end
  end
  s.pos = vec4(nx, ny, nz)
  return false
end

-- Lets go of the rope. carry = true keeps V's swing velocity integrating after release (momentum
-- carry); false hands straight back to native physics (landed, disabled, no player).
local function releaseSling(reason, carry)
  local s = WebSlinger.swing
  s.releaseCarry = carry
  s.lastRelease = reason
  WebSlinger.SetState(States.NONE)
end

--- Advances the swing by deltaTime seconds: gravity, steering, damping, reel-in, the rope
-- constraint (pendulum), collision, then writes V's position. Runs every onUpdate tick while
-- WebSlinger.IsGrappling. Ends the swing (SetState NONE) on reaching the anchor, landing, the
-- safety time cap, or, with the key still held, the chain-release point on the upswing.
function WebSlinger.UpdateGrapplePhysics(deltaTime)
  local s, cfg = WebSlinger.swing, WebSlinger.sling
  local player = Game.GetPlayer()
  if player == nil or s.anchor == nil or s.pos == nil then
    releaseSling("lost player or anchor", false)
    return
  end

  local dt = deltaTime
  local v, a, hand = s.vel, s.anchor, cfg.handHeight
  s.time = s.time + dt

  -- Gravity.
  v.z = v.z - cfg.gravity * dt

  -- Steering: push along the camera heading, minus its component along the rope, so the push only
  -- ever swings V around the anchor and never stretches or slackens the rope by itself.
  local rx, ry, rz = a.x - s.pos.x, a.y - s.pos.y, a.z - (s.pos.z + hand)
  local rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
  if rlen > 1e-4 then
    local ux, uy, uz = rx / rlen, ry / rlen, rz / rlen
    local hx, hy = aimHeading(player, false)
    local along = hx * ux + hy * uy
    local tx, ty, tz = hx - along * ux, hy - along * uy, -along * uz
    v.x = v.x + tx * cfg.steerAccel * dt
    v.y = v.y + ty * cfg.steerAccel * dt
    v.z = v.z + tz * cfg.steerAccel * dt
  end

  local keep = math.max(0.0, 1.0 - cfg.damping * dt)
  v.x, v.y, v.z = v.x * keep, v.y * keep, v.z * keep
  clampSpeed(v, cfg.maxSpeed)

  -- Reel in: shortening the rope is what pulls V toward the anchor, along the arc.
  s.ropeLength = math.max(cfg.minRopeLength, s.ropeLength - cfg.reelSpeed * dt)

  -- Integrate, then enforce the rope: if the hand point ends up beyond rope length, put it back on
  -- the sphere around the anchor and drop the outward radial velocity. This is what turns a fall
  -- into a pendulum arc instead of a straight pull to the anchor.
  local nx, ny, nz = s.pos.x + v.x * dt, s.pos.y + v.y * dt, s.pos.z + v.z * dt
  local ox, oy, oz = nx - a.x, ny - a.y, (nz + hand) - a.z
  local dist = math.sqrt(ox * ox + oy * oy + oz * oz)
  if dist > s.ropeLength and dist > 1e-4 then
    local ex, ey, ez = ox / dist, oy / dist, oz / dist
    nx, ny, nz = a.x + ex * s.ropeLength, a.y + ey * s.ropeLength, a.z + ez * s.ropeLength - hand
    local radial = v.x * ex + v.y * ey + v.z * ez
    if radial > 0.0 then
      v.x, v.y, v.z = v.x - radial * ex, v.y - radial * ey, v.z - radial * ez
    end
    dist = s.ropeLength
  end

  local landed = moveWithCollision(s, nx, ny, nz)
  placeV(player, s.pos)
  s.lastPos = vec4(s.pos.x, s.pos.y, s.pos.z)
  -- Keep the velocity estimate current through the swing (C2WS-T12): trackVelocity does not run
  -- while SLINGING, so without this a no-carry release (landed, wall impact) left the pre-swing
  -- estimate behind to seed the next swing, or a wall-run's measured-speed drop-off check.
  s.estVel = { x = v.x, y = v.y, z = v.z }

  if landed then
    releaseSling("landed", false)
  elseif dist <= cfg.anchorReachDistance then
    releaseSling("reached anchor", true)
  elseif s.time >= cfg.maxSwingTime then
    releaseSling("swing time cap", true)
  elseif (s.keyHeld or s.auto) and s.time >= cfg.chainMinSwingTime and v.z > 0.0 then
    -- Chain point: V has swung past the bottom of the arc (in her direction of travel) by at least
    -- chainReleaseAngleDeg and is rising. Letting go here launches her forward into the next swing.
    -- A jump-fired swing (C2WS-T22) has no held key to let go of, so it always ends here too.
    local hx, hy, hz = s.pos.x - a.x, s.pos.y - a.y, (s.pos.z + hand) - a.z
    local hlen = math.sqrt(hx * hx + hy * hy + hz * hz)
    local ahead = hx * v.x + hy * v.y > 0.0
    if ahead and hlen > 1e-4 then
      local angleFromBottom = math.deg(math.acos(math.max(-1.0, math.min(1.0, -hz / hlen))))
      if angleFromBottom >= cfg.chainReleaseAngleDeg then
        releaseSling("chain release", true)
      end
    end
  end
end

-- Fires the rope if the anchor search finds a point. Soft-fails (returns false, no state change)
-- when nothing qualifies, so V just keeps falling/running normally.
local function tryAttach(player)
  local s, cfg = WebSlinger.swing, WebSlinger.sling
  local anchor, normal, info = WebSlinger.FindAnchor(player)
  s.lastSearch = info
  if anchor == nil then return false end

  local pos = player:GetWorldPosition()
  local seed = s.carry and s.vel or s.estVel
  s.vel = { x = seed.x, y = seed.y, z = seed.z }
  s.pos = vec4(pos.x, pos.y, pos.z)
  if isGrounded(pos) and s.vel.z < cfg.launchSpeed then
    -- Firing from the ground: hop off it so the swing starts instead of grinding along the floor.
    s.vel.z = cfg.launchSpeed
  end
  s.carry = false
  s.anchor, s.anchorNormal = anchor, normal
  local dx, dy, dz = anchor.x - pos.x, anchor.y - pos.y, anchor.z - (pos.z + cfg.handHeight)
  s.ropeLength = math.sqrt(dx * dx + dy * dy + dz * dz)
  s.time = 0.0
  s.attachCount = s.attachCount + 1
  WebSlinger.SetState(States.SLINGING)
  return true
end

-- Post-release momentum carry: keeps integrating V's release velocity under gravity (no rope) so
-- the swing's speed carries into the fall instead of being zeroed, until she lands, re-attaches,
-- or carryMaxTime passes and native physics takes over.
local function carryTick(player, dt)
  local s, cfg = WebSlinger.swing, WebSlinger.sling
  s.carryTime = s.carryTime + dt
  local v = s.vel
  v.z = v.z - cfg.gravity * dt
  local keep = math.max(0.0, 1.0 - cfg.damping * dt)
  v.x, v.y, v.z = v.x * keep, v.y * keep, v.z * keep
  clampSpeed(v, cfg.maxSpeed)

  local landed = moveWithCollision(s, s.pos.x + v.x * dt, s.pos.y + v.y * dt, s.pos.z + v.z * dt)
  placeV(player, s.pos)
  s.lastPos = vec4(s.pos.x, s.pos.y, s.pos.z)
  s.estVel = { x = v.x, y = v.y, z = v.z }
  if landed or s.carryTime >= cfg.carryMaxTime then
    s.carry = false
  end
end

-- Smoothed estimate of V's velocity from position deltas, used to seed a swing with the speed she
-- already has. Ignores jumps too large to be movement (fast travel, teleports, loading).
local function trackVelocity(player, dt)
  local s = WebSlinger.swing
  local pos = player:GetWorldPosition()
  if s.lastPos ~= nil and dt > 1e-4 then
    local vx = (pos.x - s.lastPos.x) / dt
    local vy = (pos.y - s.lastPos.y) / dt
    local vz = (pos.z - s.lastPos.z) / dt
    if vx * vx + vy * vy + vz * vz < 80.0 * 80.0 then
      local e = s.estVel
      e.x, e.y, e.z = e.x + (vx - e.x) * 0.3, e.y + (vy - e.y) * 0.3, e.z + (vz - e.z) * 0.3
    else
      s.estVel = { x = 0.0, y = 0.0, z = 0.0 }
    end
  end
  s.lastPos = vec4(pos.x, pos.y, pos.z)
end

-- ---------------------------------------------------------------------------------------------
-- Wall-impact angle check during a swing (C2WS-T7)
--
-- Each tick while IsGrappling, a flat probe runs ahead of V's swing velocity. If it touches a
-- wall, the angle between her horizontal travel direction and the wall's flat normal decides the
-- follow-up: head-on latches (Mantis Blade climb), a glancing hit at speed wall-runs, and a
-- glancing hit too slow to run falls back to latching. The rope is always released first, so the
-- transition log reads SLINGING -> NONE -> (CLIMBING|WALLRUNNING).
-- ---------------------------------------------------------------------------------------------

--- Lets go of the rope with no momentum carry (the next mechanic owns V's movement from here).
-- Leaves the state machine in NONE.
function WebSlinger.StopGrapple(reason)
  if WebSlinger.state == States.SLINGING then
    releaseSling(reason or "StopGrapple", false)
  end
  WebSlinger.swing.carry = false
end

--- Hands V to the wall-climb mechanic (C2WS-T8): records the wall, enters CLIMBING.
-- No equipment check of any kind: the climb is a permanent ability the mod grants, so this never
-- queries Mantis Blades, Monowire, or any other cyberware slot.
function WebSlinger.TriggerWallLatch(wallNormal2D, hitPos, velocity)
  local w = WebSlinger.wall
  w.normal, w.hitPos, w.velocity = wallNormal2D, hitPos, velocity
  WebSlinger.SetState(States.CLIMBING)
end

-- ---------------------------------------------------------------------------------------------
-- Wall-run (C2WS-T9)
--
-- Entered two ways, neither gated on any equipment: automatically from a glancing swing impact
-- (CheckWallCollisionDuringSwing below), or manually by pressing jump with a wall close to V's
-- left or right (TryManualWallRun). While WALLRUNNING, UpdateWallHangPhysics re-applies the run
-- velocity every tick: along the wall at a fixed speed, a small sticky push into the wall, and Z
-- pinned to AntiGravityZ. See docs/DESIGN.md.
-- ---------------------------------------------------------------------------------------------

-- Flattens v to z = 0 and normalizes it; nil if it has (almost) no horizontal extent.
local function flatUnit(v)
  local len = math.sqrt(v.x * v.x + v.y * v.y)
  if len < 1e-4 then return nil end
  return Vector4.new(v.x / len, v.y / len, 0.0, 0.0)
end

-- Writes V's velocity through her locomotion component. Returns false if the call is unavailable
-- or errors, so the caller can fall back to driving her position by teleport.
local function setLinearVelocity(player, v)
  local ok = pcall(function()
    player:GetLocomotionComponent():SetLinearVelocity(Vector4.new(v.x, v.y, v.z, 0.0))
  end)
  return ok
end

local function rawCameraTilt(degrees, blendTime)
  pcall(function()
    Game.GetCameraSystem():SetCameraTilt(degrees, blendTime)
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Polish (C2WS-T13): eased camera tilt and impact feedback
--
-- The wall-run tilt is no longer one flat SetCameraTilt(target, blend) call: the mod owns the roll
-- and eases it (smoothstep) from where it is toward the target over CameraTiltTime, writing it with
-- a zero engine blend each tick it changes. A wall-latch impact and a wall-jump launch add a short
-- decaying roll shake on top of that and a quick FOV punch (fast rise, eased return). The whole
-- step is a few arithmetic ops plus at most two pcall'd engine writes, and only while an effect is
-- live (idle ticks return at once); its own cost is timed for the debug panel next to the T1
-- frame-time counter. Polish off = the pre-T13 behaviour (flat engine-blended tilt, no impulses).
-- ---------------------------------------------------------------------------------------------

WebSlinger.polish = {
  Enabled = true,          -- master switch for everything below
  ShakeAmplitudeDeg = 2.0, -- peak roll of the impact shake (latch); a jump plays JumpScale of it
  ShakeDuration = 0.22,    -- seconds the shake takes to decay to nothing
  ShakeFrequency = 18.0,   -- shake oscillations per second
  FovPunchDeg = 5.0,       -- FOV added at the peak of the punch (latch); a jump plays JumpScale of it
  FovPunchRise = 0.05,     -- seconds to reach the peak
  FovPunchFall = 0.25,     -- seconds to ease back to the base FOV
  JumpScale = 0.7,         -- wall-jump launch strength relative to a wall-latch impact
}

-- Live polish state. Written only by setCameraTilt, PlayImpactFeedback and updatePolish.
WebSlinger.fx = {
  tilt = 0.0,           -- current eased roll (degrees), before shake
  tiltFrom = 0.0,
  tiltTo = 0.0,
  tiltTime = 0.0,
  tiltDuration = 0.0,
  applied = 0.0,        -- last roll written to the camera (tilt + shake)
  shakeTime = nil,      -- seconds since the shake started, nil when none
  shakeAmp = 0.0,
  fovBase = nil,        -- FOV before the punch, restored when it ends; nil when no punch is live
  fovTime = 0.0,
  fovPunch = 0.0,
  costMs = 0.0,         -- smoothed per-tick cost of updatePolish, for the frame-time check
  lastImpulse = "(none yet)",
  impulseCount = 0,
}

local function easeInOut(t)
  if t <= 0.0 then return 0.0 end
  if t >= 1.0 then return 1.0 end
  return t * t * (3.0 - 2.0 * t)
end

local function fppCamera()
  local player = Game.GetPlayer()
  if player == nil then return nil end
  local ok, cam = pcall(function() return player:GetFPPCameraComponent() end)
  if ok then return cam end
  return nil
end

local function setFov(value)
  local cam = fppCamera()
  if cam == nil then return false end
  return pcall(function() cam:SetFOV(value) end)
end

-- Ends any FOV punch at once, putting the base FOV back.
local function endFovPunch()
  local fx = WebSlinger.fx
  if fx.fovBase ~= nil then setFov(fx.fovBase) end
  fx.fovBase, fx.fovPunch = nil, 0.0
end

--- Sets the camera roll target. With polish on, the roll eases there over blendTime (the per-tick
-- write happens in updatePolish); with polish off it is the old flat engine-blended call.
local function setCameraTilt(degrees, blendTime)
  local fx = WebSlinger.fx
  if not WebSlinger.polish.Enabled then
    rawCameraTilt(degrees, blendTime)
    fx.tilt, fx.tiltFrom, fx.tiltTo, fx.applied = degrees, degrees, degrees, degrees
    fx.tiltTime, fx.tiltDuration = 0.0, 0.0
    return
  end
  fx.tiltFrom, fx.tiltTo = fx.tilt, degrees
  fx.tiltTime, fx.tiltDuration = 0.0, math.max(blendTime or 0.0, 0.0)
end

--- Impact feedback: a decaying roll shake plus an FOV punch. strength scales both (1 = a full
-- wall-latch impact). label names the event for the debug panel.
function WebSlinger.PlayImpactFeedback(strength, label)
  local p, fx = WebSlinger.polish, WebSlinger.fx
  if not p.Enabled then return end
  fx.shakeTime, fx.shakeAmp = 0.0, p.ShakeAmplitudeDeg * strength
  if p.FovPunchDeg * strength > 0.0 then
    if fx.fovBase == nil then
      local cam = fppCamera()
      local ok, base = false, nil
      if cam ~= nil then ok, base = pcall(function() return cam:GetFOV() end) end
      if ok and type(base) == "number" then fx.fovBase = base end
    end
    if fx.fovBase ~= nil then
      fx.fovTime, fx.fovPunch = 0.0, p.FovPunchDeg * strength
    end
  end
  fx.impulseCount = fx.impulseCount + 1
  fx.lastImpulse = string.format("#%d %s (x%.2f)%s", fx.impulseCount, label, strength,
    fx.fovBase == nil and "  [FOV unavailable]" or "")
end

--- One polish tick (every onUpdate, also while the mod is disabled so an exit tilt still eases
-- back). Returns immediately when nothing is animating.
local function updatePolish(dt)
  local p, fx = WebSlinger.polish, WebSlinger.fx
  if not p.Enabled then
    -- Switched off mid-effect: snap everything to its resting value once.
    if fx.shakeTime ~= nil or fx.fovBase ~= nil or fx.applied ~= fx.tiltTo then
      fx.shakeTime = nil
      endFovPunch()
      fx.tilt, fx.applied, fx.tiltDuration = fx.tiltTo, fx.tiltTo, 0.0
      rawCameraTilt(fx.tiltTo, 0.0)
    end
    return
  end
  local tiltBusy = fx.tilt ~= fx.tiltTo or fx.applied ~= fx.tiltTo
  if not tiltBusy and fx.shakeTime == nil and fx.fovBase == nil then return end
  local started = os.clock()

  -- Eased tilt.
  if fx.tilt ~= fx.tiltTo then
    fx.tiltTime = fx.tiltTime + dt
    if fx.tiltDuration <= 0.0 or fx.tiltTime >= fx.tiltDuration then
      fx.tilt = fx.tiltTo
    else
      fx.tilt = fx.tiltFrom + (fx.tiltTo - fx.tiltFrom) * easeInOut(fx.tiltTime / fx.tiltDuration)
    end
  end

  -- Shake: a sine roll under a linear decay envelope.
  local shake = 0.0
  if fx.shakeTime ~= nil then
    fx.shakeTime = fx.shakeTime + dt
    if p.ShakeDuration <= 0.0 or fx.shakeTime >= p.ShakeDuration then
      fx.shakeTime = nil
    else
      local decay = 1.0 - fx.shakeTime / p.ShakeDuration
      shake = fx.shakeAmp * decay * math.sin(fx.shakeTime * p.ShakeFrequency * 2.0 * math.pi)
    end
  end

  local roll = fx.tilt + shake
  if math.abs(roll - fx.applied) > 1e-3 or (shake == 0.0 and roll ~= fx.applied) then
    rawCameraTilt(roll, 0.0)
    fx.applied = roll
  end

  -- FOV punch: linear rise, smoothstep fall.
  if fx.fovBase ~= nil then
    fx.fovTime = fx.fovTime + dt
    local k
    if fx.fovTime < p.FovPunchRise then
      k = fx.fovTime / p.FovPunchRise
    else
      k = 1.0 - easeInOut((fx.fovTime - p.FovPunchRise) / math.max(p.FovPunchFall, 1e-3))
    end
    if k <= 0.0 then
      endFovPunch()
    elseif not setFov(fx.fovBase + fx.fovPunch * k) then
      fx.fovBase, fx.fovPunch = nil, 0.0
    end
  end

  fx.costMs = smooth(fx.costMs, (os.clock() - started) * 1000.0)
end

-- Probes from V's chest into the wall (along -normal). Returns the flat wall normal and hit point,
-- or nil if the wall is gone or what was hit is not a wall.
local function probeRunWall(pos, normal, distance)
  local cfg = WebSlinger.wallrun
  local origin = vec4(pos.x, pos.y, pos.z + cfg.probeHeight)
  local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(origin,
    Vector4.new(-normal.x, -normal.y, 0.0, 0.0), distance)
  if not hit then return nil end
  local n2 = math.sqrt(hitNormal.x * hitNormal.x + hitNormal.y * hitNormal.y)
  if n2 < cfg.minWallNormal2D then return nil end
  return Vector4.new(hitNormal.x / n2, hitNormal.y / n2, 0.0, 0.0), hitPos
end

-- The run velocity for the current wall: wallParallelDir * speed + wallNormal * -StickyForce,
-- with Z pinned to AntiGravityZ.
local function runVelocity(r, cfg)
  return {
    x = r.dir.x * r.speed - r.normal.x * cfg.StickyForce,
    y = r.dir.y * r.speed - r.normal.y * cfg.StickyForce,
    z = cfg.AntiGravityZ,
  }
end

-- Applies velocity v to V for this tick. Uses SetLinearVelocity when enabled and available;
-- otherwise integrates r.pos and teleports, holding V WallStandoff off the wall plane (the
-- teleport path's stand-in for the sticky force).
local function applyRunVelocity(player, r, v, dt, hitPos)
  local cfg = WebSlinger.wallrun
  r.vel = v
  if not r.teleportMode then
    if cfg.UseLocomotionVelocity and setLinearVelocity(player, v) then return end
    r.teleportMode = true
    local p = player:GetWorldPosition()
    r.pos = vec4(p.x, p.y, p.z)
    print("[WebSlinger] wall-run: SetLinearVelocity unavailable or off, driving V by teleport")
  end
  local p = r.pos
  local nx, ny, nz = p.x + v.x * dt, p.y + v.y * dt, p.z + v.z * dt
  if hitPos ~= nil then
    local d = (nx - hitPos.x) * r.normal.x + (ny - hitPos.y) * r.normal.y
    nx = nx + r.normal.x * (cfg.WallStandoff - d)
    ny = ny + r.normal.y * (cfg.WallStandoff - d)
  end
  r.pos = vec4(nx, ny, nz)
  placeV(player, r.pos)
  -- Deliberately no swing.lastPos write here (C2WS-T12): trackVelocity runs every WALLRUNNING tick
  -- before this, and pre-setting lastPos to the new position made it measure ~0 m/s, so a
  -- teleport-driven run always tripped the "too slow" drop-off right after SpeedCheckGrace.
end

--- Ends the wall-run (state -> NONE). carry = true hands V's run velocity to the web-sling
-- momentum carry when the run was teleport-driven (with SetLinearVelocity the engine keeps it).
local function endWallRun(reason, carry)
  local r = WebSlinger.run
  r.endReason, r.endCarry = reason, carry
  WebSlinger.SetState(States.NONE)
end
WebSlinger.EndWallRun = endWallRun

--- Hands V to the wall-run: computes the wall-parallel direction (the perpendicular of the wall
-- normal whose sign matches V's travel), the run speed max(|currentVelocity|, MinWallRunSpeed),
-- enters WALLRUNNING and applies the first tick of run velocity. The MinWallRunSpeed floor
-- applies only when manual is true (jump trigger); a swing-impact entry keeps its actual speed. Accepts either a Vector4 or a
-- { x, y, z } table for currentVelocity. No equipment check gates entry. Returns true if the run
-- started.
function WebSlinger.InitiateWallRun(wallNormal, currentVelocity, hitPos, manual)
  local w, r, cfg = WebSlinger.wall, WebSlinger.run, WebSlinger.wallrun
  local n = flatUnit(wallNormal)
  if n == nil then return false end
  local vel = currentVelocity or { x = 0.0, y = 0.0, z = 0.0 }
  w.normal, w.hitPos, w.velocity = n, hitPos, { x = vel.x, y = vel.y, z = vel.z }

  local player = Game.GetPlayer()
  local wallParallelDir = Vector4.new(-n.y, n.x, 0.0, 0.0)
  local along = vel.x * wallParallelDir.x + vel.y * wallParallelDir.y
  if math.abs(along) < 1.0 and player ~= nil then
    -- Barely moving along the wall (e.g. a standing manual trigger): run where V is looking.
    local hx, hy = aimHeading(player, false)
    along = hx * wallParallelDir.x + hy * wallParallelDir.y
  end
  if along < 0 then
    wallParallelDir = Vector4.new(n.y, -n.x, 0.0, 0.0)
  end

  r.normal, r.dir = n, wallParallelDir
  -- Lateral (2D) speed only: UpdateWallHangPhysics's ongoing check compares against
  -- measuredSpeed, which is horizontal-only, so entry speed must use the same measure or a
  -- fall with real vertical speed but little horizontal speed would qualify here and then
  -- immediately read as "too slow" once the grace period ends.
  local entrySpeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
  if manual then
    -- Manual trigger: no swing speed to preserve, so give the run its minimum speed.
    r.speed = math.max(entrySpeed, cfg.MinWallRunSpeed)
  else
    -- Swing impact: keep V's actual speed (momentum conservation). C2WS-T7 already requires
    -- impact.MinimumWallRunSpeed to route here, so no boost up to MinWallRunSpeed.
    r.speed = entrySpeed
  end
  -- The wall lies along -n from V; her right-hand side when facing the run direction is (dir.y, -dir.x).
  r.side = (-n.x * wallParallelDir.y + n.y * wallParallelDir.x) > 0 and 1 or -1
  r.time = 0.0  -- starts the WallRunMaxDuration timer (C2WS-T10)
  r.measuredSpeed = r.speed
  r.teleportMode = not cfg.UseLocomotionVelocity
  if player ~= nil then
    local p = player:GetWorldPosition()
    r.pos = vec4(p.x, p.y, p.z)
  end
  r.count = r.count + 1
  r.lastEntry = string.format("#%d  speed %.1f m/s  wall on %s", r.count, r.speed, r.side > 0 and "right" or "left")
  print("[WebSlinger] wall-run " .. r.lastEntry)

  WebSlinger.SetState(States.WALLRUNNING)
  if player ~= nil and WebSlinger.state == States.WALLRUNNING then
    applyRunVelocity(player, r, runVelocity(r, cfg), 0.0, hitPos)
  end
  return true
end

--- One wall-run tick (onUpdate, while WALLRUNNING): re-probes the wall, follows its normal round
-- gentle curves, and re-applies the run velocity so V can't slip off mid-run. Ends the run when
-- the wall runs out, something blocks the way ahead, WallRunMaxDuration passes, or V's speed drops
-- below impact.MinimumWallRunSpeed (C2WS-T10).
function WebSlinger.UpdateWallHangPhysics(deltaTime)
  local r, cfg = WebSlinger.run, WebSlinger.wallrun
  local player = Game.GetPlayer()
  if player == nil or r.normal == nil or r.dir == nil then
    endWallRun(player == nil and "no player" or "no wall (entered without InitiateWallRun)", false)
    return
  end

  -- Duration drop-off: no input needed, V just falls once the timer elapses.
  r.time = r.time + deltaTime
  if r.time >= cfg.WallRunMaxDuration then
    endWallRun("duration elapsed", true)
    return
  end

  -- Speed drop-off: holding back sheds run speed; the check also uses V's measured speed (from
  -- position deltas, after a short grace so the smoothed estimate can catch up with the entry
  -- speed), so a run stalled by geometry or a velocity write the engine ignores ends too.
  if WebSlinger.climbing.moveY <= -cfg.BrakeInputThreshold then
    r.speed = math.max(0.0, r.speed - cfg.BrakeDecel * deltaTime)
  end
  local speed = r.speed
  if r.time >= cfg.SpeedCheckGrace then
    local e = WebSlinger.swing.estVel
    r.measuredSpeed = math.sqrt(e.x * e.x + e.y * e.y)
    speed = math.min(speed, r.measuredSpeed)
  else
    r.measuredSpeed = speed
  end
  if speed < WebSlinger.impact.MinimumWallRunSpeed then
    endWallRun(string.format("too slow (%.1f m/s)", speed), true)
    return
  end

  local pos = r.teleportMode and r.pos or player:GetWorldPosition()
  local newNormal, hitPos = probeRunWall(pos, r.normal, cfg.WallProbeDistance)
  if newNormal == nil then
    endWallRun("ran off the wall", true)
    return
  end
  r.normal = newNormal
  local dir = Vector4.new(-newNormal.y, newNormal.x, 0.0, 0.0)
  if dir.x * r.dir.x + dir.y * r.dir.y < 0 then dir = Vector4.new(newNormal.y, -newNormal.x, 0.0, 0.0) end
  r.dir = dir

  local origin = vec4(pos.x, pos.y, pos.z + cfg.probeHeight)
  local blocked, _, blockNormal = WebSlinger.ExecuteSmartRaycast(origin, dir, cfg.BlockedProbeDistance)
  if blocked and (blockNormal.x * dir.x + blockNormal.y * dir.y) < -0.5 then
    endWallRun("blocked ahead", false)
    return
  end

  applyRunVelocity(player, r, runVelocity(r, cfg), deltaTime, hitPos)
end

--- Manual, Titanfall-style entry: called when jump is pressed. If V is not already in a traversal
-- state and a wall lies within ManualTriggerDistance to her left or right (side and forward-
-- diagonal probes; a wall straight ahead does not count), starts a wall-run on the nearest one.
-- Returns true if a run started.
function WebSlinger.TryManualWallRun()
  if WebSlinger.state ~= States.NONE then
    print(string.format("[WebSlinger] wall-run: manual probe skipped (state=%s, not NONE)", WebSlinger.state))
    return false
  end
  local player = Game.GetPlayer()
  if player == nil then
    print("[WebSlinger] wall-run: manual probe skipped (no player)")
    return false
  end
  local cfg, s = WebSlinger.wallrun, WebSlinger.swing

  local pos = player:GetWorldPosition()
  local origin = vec4(pos.x, pos.y, pos.z + cfg.probeHeight)
  local hx, hy = aimHeading(player, true)
  local rx, ry = hy, -hx  -- V's right
  local probes = {
    Vector4.new(rx, ry, 0.0, 0.0),
    Vector4.new(-rx, -ry, 0.0, 0.0),
    Vector4.new(rx + hx, ry + hy, 0.0, 0.0),
    Vector4.new(-rx + hx, -ry + hy, 0.0, 0.0),
  }

  -- A wall the swing-impact check would call head-on (above WallLatchAngleThreshold) is left to
  -- TryManualWallLatch, so the side/head-on split matches CheckWallCollisionDuringSwing (C2WS-T21).
  local maxFacing = math.min(cfg.ManualMaxFacingDot, WebSlinger.impact.WallLatchAngleThreshold)
  local bestNormal, bestPos, bestDist = nil, nil, math.huge
  local bestDot, sawAnyHit = nil, false
  for i, dir in ipairs(probes) do
    local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(origin, dir, cfg.ManualTriggerDistance)
    if hit then
      sawAnyHit = true
      local n = flatUnit(hitNormal)
      local n2 = math.sqrt(hitNormal.x * hitNormal.x + hitNormal.y * hitNormal.y)
      local dot = n ~= nil and math.abs(n.x * hx + n.y * hy) or nil
      -- C2WS-T27 diagnostic (always on; only runs on a jump press, so it never spams the log):
      -- ExecuteSmartRaycast normalizes `dir` internally (see its own definition), so the diagonal
      -- probes' non-unit-length Vector4s above do NOT extend or shrink the actual raycast distance
      -- -- this print confirms that per probe in the field rather than leaving it assumed.
      print(string.format(
        "[WebSlinger] wall-run: probe #%d hit, n2=%.2f dot=%s (maxFacing=%.2f, minWallNormal2D=%.2f)",
        i, n2, dot ~= nil and string.format("%.2f", dot) or "nil", maxFacing, cfg.minWallNormal2D))
      if n ~= nil and n2 >= cfg.minWallNormal2D and dot <= maxFacing then
        local dx, dy = hitPos.x - origin.x, hitPos.y - origin.y
        local dist = dx * dx + dy * dy
        if dist < bestDist then bestNormal, bestPos, bestDist, bestDot = n, hitPos, dist, dot end
      end
    end
  end
  if bestNormal == nil then
    print(string.format("[WebSlinger] wall-run: manual probe found no qualifying side wall (sawAnyHit=%s)",
      tostring(sawAnyHit)))
    return false
  end

  local seed = s.carry and s.vel or s.estVel
  local velocity = { x = seed.x, y = seed.y, z = seed.z }
  s.carry = false
  print("[WebSlinger] wall-run: manual trigger (jump)")
  return WebSlinger.InitiateWallRun(bestNormal, velocity, bestPos, true)
end

--- Manual head-on entry into CLIMBING (C2WS-T21): called when jump is pressed in NONE after
-- TryManualWallRun found no side wall. Probes straight ahead along V's look/move heading out to
-- ManualLatchDistance; a wall facing her head-on (|heading . normal| above the swing-impact
-- check's WallLatchAngleThreshold, the complement of TryManualWallRun's side filter) latches her
-- onto it immediately. No swing, no minimum approach speed (standing, walking, running or
-- falling all qualify: the press is the deliberate action), and no equipment check.
-- Returns true if V latched.
function WebSlinger.TryManualWallLatch()
  if WebSlinger.state ~= States.NONE then
    print(string.format("[WebSlinger] wall-latch: manual probe skipped (state=%s, not NONE)", WebSlinger.state))
    return false
  end
  local player = Game.GetPlayer()
  if player == nil then
    print("[WebSlinger] wall-latch: manual probe skipped (no player)")
    return false
  end
  local cfg, s = WebSlinger.wallrun, WebSlinger.swing

  local pos = player:GetWorldPosition()
  local origin = vec4(pos.x, pos.y, pos.z + cfg.probeHeight)
  local hx, hy = aimHeading(player, true)
  local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(
    origin, Vector4.new(hx, hy, 0.0, 0.0), cfg.ManualLatchDistance)
  -- C2WS-T27 diagnostic (always on; only runs on a jump press that TryManualWallRun already
  -- declined, so it never spams the log): names exactly which guard rejected the probe and with
  -- what value, so a live repro's CET console log pinpoints the failing check.
  if not hit then
    print(string.format("[WebSlinger] wall-latch: no hit within ManualLatchDistance (%.2f m, heading %.2f,%.2f)",
      cfg.ManualLatchDistance, hx, hy))
    return false
  end

  local n = flatUnit(hitNormal)
  local n2 = math.sqrt(hitNormal.x * hitNormal.x + hitNormal.y * hitNormal.y)
  if n == nil or n2 < cfg.minWallNormal2D then  -- floor/ledge, not a wall
    print(string.format("[WebSlinger] wall-latch: hit rejected, not a wall (n2=%.2f, minWallNormal2D=%.2f)",
      n2, cfg.minWallNormal2D))
    return false
  end
  local facing = math.abs(n.x * hx + n.y * hy)
  if facing <= WebSlinger.impact.WallLatchAngleThreshold then
    print(string.format("[WebSlinger] wall-latch: hit too glancing (facing=%.2f, need > %.2f)",
      facing, WebSlinger.impact.WallLatchAngleThreshold))
    return false
  end

  local seed = s.carry and s.vel or s.estVel
  local velocity = { x = seed.x, y = seed.y, z = seed.z }
  s.carry = false
  print(string.format("[WebSlinger] wall-latch: manual trigger (jump, facing %.2f)", facing))
  WebSlinger.TriggerWallLatch(n, hitPos, velocity)
  return true
end

-- Camera tilt plays on entry (rolled away from the wall) and blends back to neutral on exit.
StateHooks[States.WALLRUNNING].onEnter = function()
  local r, cfg = WebSlinger.run, WebSlinger.wallrun
  r.endReason, r.endCarry = nil, nil
  if r.normal ~= nil then
    setCameraTilt(cfg.CameraTiltDeg * r.side, cfg.CameraTiltTime)
  end
end

StateHooks[States.WALLRUNNING].onExit = function()
  local r, s = WebSlinger.run, WebSlinger.swing
  setCameraTilt(0.0, WebSlinger.wallrun.CameraTiltTime)
  local reason = r.endReason or "left WALLRUNNING via SetState"
  if r.endCarry and r.teleportMode and r.pos ~= nil and r.vel ~= nil then
    -- Teleport-driven run: keep its speed going through the web-sling momentum carry.
    s.pos = vec4(r.pos.x, r.pos.y, r.pos.z)
    s.vel = { x = r.vel.x, y = r.vel.y, z = r.vel.z }
    s.carry, s.carryTime = true, 0.0
  end
  r.lastEnd = string.format("%s after %.2f s", reason, r.time)
  print("[WebSlinger] wall-run ended: " .. r.lastEnd)
  r.normal, r.dir, r.pos, r.endReason, r.endCarry = nil, nil, nil, nil, nil
end

-- The manual trigger listens to the game's own Jump action, so it uses whatever the player has
-- bound to jump. Registered in onInit; only queues, the onUpdate tick does the work.
local function observeWallRunJump()
  Observe("PlayerPuppet", "OnAction", function(_, action)
    -- Check for a Jump press before the state gate below (not after): this action fires on every
    -- bound input, not just Jump, and the C2WS-T27 diagnostic print only fires on a real Jump
    -- BUTTON_PRESSED, confirming this hook sees the press at all regardless of state.
    local ok, isJump = pcall(function()
      return Game.NameToString(ListenerAction.GetName(action)) == "Jump"
        and ListenerAction.GetType(action).value == "BUTTON_PRESSED"
    end)
    if not ok or not isJump then return end

    -- NONE: manual wall-run trigger. WALLRUNNING: wall-jump off the run (C2WS-T11).
    -- SLINGING: boost leap near the arc bottom (C2WS-T23), else lets go of a jump-fired swing (C2WS-T22).
    if WebSlinger.state ~= States.NONE and WebSlinger.state ~= States.WALLRUNNING
      and WebSlinger.state ~= States.SLINGING then
      print(string.format("[WebSlinger] jump observed but ignored (state=%s)", WebSlinger.state))
      return
    end
    WebSlinger.run.jumpQueued = true
    print(string.format("[WebSlinger] jump observed, queued (state=%s)", WebSlinger.state))
  end)
end

--- Mid-air double-jump web-sling (C2WS-T22): called when jump is pressed in NONE and neither
-- manual wall probe found a wall. If V is airborne, runs the same anchor search and attach as the
-- held swing bind (tryAttach -> FindAnchor along her look heading) and enters SLINGING with no bind
-- held. Grounded presses are left alone (the plain game jump). No anchor is a soft fail: nothing
-- changes and the press stays the game's own jump. Returns true if a swing started.
function WebSlinger.TryJumpSling()
  if WebSlinger.state ~= States.NONE then return false end
  local player = Game.GetPlayer()
  if player == nil then return false end
  if isGrounded(player:GetWorldPosition()) then return false end
  local s = WebSlinger.swing
  if not tryAttach(player) then
    print("[WebSlinger] jump-sling: " .. tostring(s.lastSearch))
    return false
  end
  -- A held bind already owns the swing (hold to swing, release to let go); otherwise it is ours.
  s.auto = not s.keyHeld
  s.autoCount = s.autoCount + 1
  print("[WebSlinger] jump-sling: attached (" .. tostring(s.lastSearch) .. ")")
  return true
end

--- Bottom-of-swing boost leap (C2WS-T23): called when jump is pressed while SLINGING. If V's hand
-- point is within sling.leapBottomWindowDeg of straight below the anchor (the same angle-from-bottom
-- measure the chain release uses), overwrites the swing velocity with a boosted launch along her
-- look heading and lets go with momentum carry. The horizontal speed is the faster of
-- leapBoostSpeed and current swing speed + leapSpeedBonus (clamped to maxSpeed); vertical speed is
-- raised to at least leapLift. Outside the window nothing changes and it returns false.
function WebSlinger.TryBoostLeap()
  if WebSlinger.state ~= States.SLINGING then return false end
  local s, cfg = WebSlinger.swing, WebSlinger.sling
  local player = Game.GetPlayer()
  local a, v = s.anchor, s.vel
  if player == nil or a == nil or s.pos == nil or v == nil then return false end

  local hx, hy, hz = s.pos.x - a.x, s.pos.y - a.y, (s.pos.z + cfg.handHeight) - a.z
  local hlen = math.sqrt(hx * hx + hy * hy + hz * hz)
  if hlen < 1e-4 then return false end
  local angleFromBottom = math.deg(math.acos(math.max(-1.0, math.min(1.0, -hz / hlen))))
  if angleFromBottom > cfg.leapBottomWindowDeg then return false end

  local dx, dy = aimHeading(player, false)
  local before = swingSpeed(v)
  local speed = math.min(cfg.maxSpeed, math.max(cfg.leapBoostSpeed, before + cfg.leapSpeedBonus))
  s.vel = { x = dx * speed, y = dy * speed, z = math.max(v.z, cfg.leapLift) }
  clampSpeed(s.vel, cfg.maxSpeed)
  s.leapCount = s.leapCount + 1
  releaseSling(string.format("boost leap (%.0f deg from bottom, %.1f -> %.1f m/s)",
    angleFromBottom, before, swingSpeed(s.vel)), true)
  print("[WebSlinger] " .. s.lastRelease)
  return true
end

-- One wall-run tick: consumes a queued jump press (manual trigger from NONE, wall-jump while
-- running) and runs the wall-run physics. onUpdate only. From NONE the side wall-run probe runs
-- first, the head-on latch probe only if it found nothing, and, if V is airborne, the jump-fired
-- web-sling only if neither found a wall, so one press triggers at most one.
local function updateWallRun(dt)
  local r = WebSlinger.run
  local jump = r.jumpQueued
  r.jumpQueued = false
  if WebSlinger.state == States.WALLRUNNING then
    if jump and WebSlinger.WallJump() then return end
    WebSlinger.UpdateWallHangPhysics(dt)
  elseif jump and WebSlinger.state == States.SLINGING then
    -- Near the bottom of the arc, any swing's jump is a boost leap toward the look heading
    -- (C2WS-T23). Elsewhere, a jump during a jump-fired swing lets go with momentum carry
    -- (C2WS-T22) and a swing held on the dedicated bind ignores jump, as before.
    if not WebSlinger.TryBoostLeap() and WebSlinger.swing.auto then
      releaseSling("jump released auto-sling", true)
    end
  elseif jump and WebSlinger.state == States.NONE then
    print("[WebSlinger] jump dispatch: NONE, trying wall-run then wall-latch then jump-sling")
    if not WebSlinger.TryManualWallRun() and not WebSlinger.TryManualWallLatch()
      and not WebSlinger.TryJumpSling() then
      print("[WebSlinger] jump dispatch: all three probes declined, press falls through to the game's own jump")
    end
  end
end

--- Runs the impact probe ahead of V's swing velocity. Returns true if it hit a wall and handed V
-- to the latch or wall-run state (the caller must then skip this tick's swing physics).
function WebSlinger.CheckWallCollisionDuringSwing()
  if not WebSlinger.IsGrappling then return false end
  local s, cfg = WebSlinger.swing, WebSlinger.impact
  local v = s.vel
  if s.pos == nil or v == nil then return false end

  local speed2D = math.sqrt(v.x * v.x + v.y * v.y)
  if speed2D < cfg.minMoveSpeed2D then return false end
  local movementDir = Vector4.new(v.x / speed2D, v.y / speed2D, 0.0, 0.0)

  local origin = vec4(s.pos.x, s.pos.y, s.pos.z + cfg.probeHeight)
  local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(origin, movementDir, cfg.WallCheckDistance)
  if not hit then return false end

  local n2 = math.sqrt(hitNormal.x * hitNormal.x + hitNormal.y * hitNormal.y)
  if n2 < cfg.minWallNormal2D then return false end  -- floor/ceiling-ish surface, not a wall
  local wallNormal2D = Vector4.new(hitNormal.x / n2, hitNormal.y / n2, 0.0, 0.0)

  local impactAngle = movementDir.x * wallNormal2D.x + movementDir.y * wallNormal2D.y
  -- Lateral (2D) speed, matching the documented "minimum lateral speed" trigger and the
  -- horizontal-only measuredSpeed check wall-run uses once it's running (C2WS-T9/T10): a 3D
  -- magnitude here let a steep vertical fall alone satisfy the threshold, then immediately
  -- fail the horizontal-only ongoing check a fraction of a second into the run.
  local currentSpeed = speed2D
  local velocity = { x = v.x, y = v.y, z = v.z }

  local branch
  if math.abs(impactAngle) > cfg.WallLatchAngleThreshold then
    branch = "latch (head-on)"
  elseif currentSpeed >= cfg.MinimumWallRunSpeed then
    branch = "wall-run"
  else
    branch = "latch (slow fallback)"
  end

  local w = WebSlinger.wall
  w.impactCount = w.impactCount + 1
  w.lastImpact = string.format("angle %.2f  speed %.1f m/s -> %s", impactAngle, currentSpeed, branch)
  print(string.format("[WebSlinger] wall impact #%d: %s", w.impactCount, w.lastImpact))

  WebSlinger.StopGrapple("wall impact")
  if branch == "wall-run" then
    WebSlinger.InitiateWallRun(wallNormal2D, velocity, hitPos)
  else
    WebSlinger.TriggerWallLatch(wallNormal2D, hitPos, velocity)
  end
  return true
end

-- One web-sling tick: polls the swing key, fires/releases, and runs the physics. onUpdate only.
local function updateSling(dt)
  local s, cfg = WebSlinger.swing, WebSlinger.sling
  local player = Game.GetPlayer()
  if player == nil then
    if WebSlinger.state == States.SLINGING then releaseSling("no player", false) end
    s.carry, s.lastPos = false, nil
    return
  end

  local held, wasHeld = s.keyHeld, s.keyWasHeld
  s.keyWasHeld = held

  local state = WebSlinger.state
  if state == States.SLINGING then
    -- Pressing the swing bind during a jump-fired swing hands it over to the bind (C2WS-T22):
    -- from then on it is an ordinary held swing that ends when the bind is released.
    if s.auto and held then s.auto = false end
    if s.anchor == nil then
      -- Entered SLINGING without a rope (e.g. the debug Force state button): nothing to swing on.
      releaseSling("no anchor", false)
    elseif not held and not s.auto then
      releaseSling("key released", true)
    elseif not WebSlinger.CheckWallCollisionDuringSwing() then
      -- Impact check runs before the physics step, which would otherwise slide V along the wall.
      WebSlinger.UpdateGrapplePhysics(dt)
    end
    return
  end

  if state == States.NONE then
    if held then
      s.retryTimer = s.retryTimer - dt
      if (not wasHeld) or s.retryTimer <= 0.0 then
        s.retryTimer = cfg.retryInterval
        if tryAttach(player) then
          if not WebSlinger.CheckWallCollisionDuringSwing() then
            WebSlinger.UpdateGrapplePhysics(dt)
          end
          return
        end
      end
    else
      s.retryTimer = 0.0
    end
    if s.carry then
      carryTick(player, dt)
    else
      trackVelocity(player, dt)
    end
    return
  end

  -- CLIMBING / WALLRUNNING own V's movement; web-sling stays out of the way.
  s.carry = false
  trackVelocity(player, dt)
end

StateHooks[States.SLINGING].onEnter = function()
  WebSlinger.IsGrappling = WebSlinger.swing.anchor ~= nil
  -- A re-sling ends any wall-jump flight now (C2WS-T12). Otherwise a swing that attaches and
  -- releases with carry inside one tick left wj.flying set, and the post-swing carry was treated
  -- as the old wall-jump's flight (wall catch and chain check against the stale launch wall).
  WebSlinger.wj.flying = false
end

StateHooks[States.SLINGING].onExit = function()
  local s = WebSlinger.swing
  local carry = s.releaseCarry
  if carry == nil then
    -- Left SLINGING through a direct SetState call (debug button, another mechanic).
    carry = true
    s.lastRelease = "left SLINGING via SetState"
  end
  WebSlinger.IsGrappling = false
  s.auto = false
  s.carry = carry and s.anchor ~= nil and s.pos ~= nil and s.vel ~= nil
  s.carryTime = 0.0
  s.releaseCarry = nil
  s.anchor, s.anchorNormal = nil, nil
  s.retryTimer = WebSlinger.sling.retryInterval
end

-- Player-configurable swing control. CET lists it under Bindings in its overlay; registerInput
-- reports both press (true) and release (false), and the onUpdate tick polls the stored state so
-- one bind covers fire/attach (press) and let go (release). CET inputs have no default key: the
-- player picks one on first run (suggested default and conflict check in docs/DESIGN.md).
registerInput("webslinger_swing", "Web-sling (hold to swing, release to let go)", function(isDown)
  WebSlinger.swing.keyHeld = isDown and true or false
end)

-- ---------------------------------------------------------------------------------------------
-- Wall-climb (C2WS-T8), flavoured as a Mantis Blade climb.
--
-- A built-in ability of the mod: nothing here (or in TriggerWallLatch) ever checks V's equipped
-- cyberware. While CLIMBING, V's feet position is owned by this tick and written back with the
-- teleportation facility (the same mechanism the web-sling uses), which is what suspends native
-- gravity; fall damage is suppressed with a WebSlinger-owned god-mode flag for exactly the time
-- spent in CLIMBING. Directional input moves V in the wall's plane; a probe into the wall at the
-- new position decides whether there is still wall there (an edge exits to NONE instead of letting
-- V move past it). Jump is a wall-jump (C2WS-T11): outward + upward impulse handed to the momentum carry.
-- ---------------------------------------------------------------------------------------------

local CLIMB_GODMODE_REASON = "WebSlinger.Climb"

-- Toggles the fall-damage suppression flag. Invulnerable god mode is added under WebSlinger's own
-- reason name, so removing it never touches god mode from any other source (debug menus, quests).
local function setClimbInvulnerable(player, on)
  local c = WebSlinger.climbing
  if on == c.invulnerable then return end
  local ok = pcall(function()
    local gms = Game.GetGodModeSystem()
    local id = player:GetEntityID()
    if on then
      gms:AddGodMode(id, gameGodModeType.Invulnerable, CName.new(CLIMB_GODMODE_REASON))
    else
      gms:RemoveGodMode(id, gameGodModeType.Invulnerable, CName.new(CLIMB_GODMODE_REASON))
    end
  end)
  if ok then
    c.invulnerable = on
  else
    -- Leave c.invulnerable unchanged on failure: claiming success here would make the guard
    -- above short-circuit every later retry, stranding the engine's god-mode flag on forever.
    print("[WebSlinger] climb: god-mode toggle failed (" .. (on and "add" or "remove") .. ")")
  end
end

-- Flattens a surface normal to a unit wall normal (z = 0), or nil if the surface is not wall-like.
local function wallNormalFrom(hitNormal)
  local n2 = math.sqrt(hitNormal.x * hitNormal.x + hitNormal.y * hitNormal.y)
  if n2 < WebSlinger.climb.minWallNormal2D then return nil end
  return Vector4.new(hitNormal.x / n2, hitNormal.y / n2, 0.0, 0.0)
end

-- Probes into the wall (along -normal) from chest height above feet position p. Returns the hit
-- point and the refreshed flat wall normal, or nil, nil when there is no wall there (an edge).
local function probeWall(p, normal)
  local cfg = WebSlinger.climb
  local origin = vec4(p.x, p.y, p.z + cfg.probeHeight)
  local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(origin,
    Vector4.new(-normal.x, -normal.y, 0.0, 0.0), cfg.standoff + cfg.stickDistance)
  if not hit then return nil, nil end
  local n = wallNormalFrom(hitNormal)
  if n == nil then return nil, nil end
  return hitPos, n
end

-- Leaves CLIMBING. vel (optional) is handed to the web-sling momentum carry so a climb-jump flies
-- an arc under the mod's gravity; without it, native physics takes V from where she is.
local function exitClimb(reason, vel)
  local c, s = WebSlinger.climbing, WebSlinger.swing
  c.lastExit = reason
  print("[WebSlinger] climb exit: " .. reason)
  WebSlinger.SetState(States.NONE)
  if vel ~= nil and c.pos ~= nil then
    s.pos = vec4(c.pos.x, c.pos.y, c.pos.z)
    s.vel = { x = vel.x, y = vel.y, z = vel.z }
    s.estVel = { x = vel.x, y = vel.y, z = vel.z }
    s.carry, s.carryTime = true, 0.0
  end
end

-- Top edge: try to put V on top of the ledge she just climbed past. Returns true if placed.
local function tryMantle(player, c)
  local cfg = WebSlinger.climb
  local n = c.normal
  local over = vec4(c.pos.x - n.x * (cfg.standoff + cfg.mantleForward),
    c.pos.y - n.y * (cfg.standoff + cfg.mantleForward),
    c.pos.z + cfg.probeHeight + 1.0)
  local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(over, Vector4.new(0.0, 0.0, -1.0, 0.0), cfg.mantleReach)
  if not hit or hitNormal.z < 0.6 then return false end
  c.pos = vec4(hitPos.x, hitPos.y, hitPos.z)
  placeV(player, c.pos)
  return true
end

StateHooks[States.CLIMBING].onEnter = function()
  local c, s, cfg = WebSlinger.climbing, WebSlinger.swing, WebSlinger.climb
  local player = Game.GetPlayer()
  if player == nil then
    c.lastExit = "no player on enter"
    WebSlinger.SetState(States.NONE)
    return
  end

  local pos = player:GetWorldPosition()
  local normal = WebSlinger.wall.normal
  if normal == nil then
    -- Entered without an impact (e.g. the debug Force state button): use the wall V is facing.
    local fwd = player:GetWorldForward()
    local flat = normalized(Vector4.new(fwd.x, fwd.y, 0.0, 0.0)) or Vector4.new(0.0, 1.0, 0.0, 0.0)
    local hit, _, hitNormal = WebSlinger.ExecuteSmartRaycast(
      vec4(pos.x, pos.y, pos.z + cfg.probeHeight), flat, WebSlinger.probeDistance)
    normal = hit and wallNormalFrom(hitNormal) or nil
  end

  local hitPos, n = nil, nil
  if normal ~= nil then
    -- Allow a slightly longer reach on entry: the impact probe may have fired up to 2 m out.
    local origin = vec4(pos.x, pos.y, pos.z + cfg.probeHeight)
    local hit, hp, hn = WebSlinger.ExecuteSmartRaycast(origin, Vector4.new(-normal.x, -normal.y, 0.0, 0.0),
      WebSlinger.impact.WallCheckDistance + cfg.standoff + cfg.stickDistance)
    if hit then hitPos, n = hp, wallNormalFrom(hn) end
  end
  if hitPos == nil or n == nil then
    c.lastExit = "no climbable wall on enter"
    WebSlinger.SetState(States.NONE)
    return
  end

  c.normal = n
  c.pos = vec4(hitPos.x + n.x * cfg.standoff, hitPos.y + n.y * cfg.standoff, pos.z)
  c.startZ = pos.z
  c.jumpQueued = false
  -- Zero residual velocity into the wall: nothing carries over from the swing or the fall.
  s.carry, s.carryTime = false, 0.0
  s.vel = { x = 0.0, y = 0.0, z = 0.0 }
  s.estVel = { x = 0.0, y = 0.0, z = 0.0 }
  WebSlinger.wall.velocity = { x = 0.0, y = 0.0, z = 0.0 }
  setClimbInvulnerable(player, true)
  placeV(player, c.pos)
  WebSlinger.PlayImpactFeedback(1.0, "wall-latch impact")  -- C2WS-T13
end

StateHooks[States.CLIMBING].onExit = function()
  local c = WebSlinger.climbing
  c.jumpQueued = false
  local player = Game.GetPlayer()
  if player ~= nil then
    setClimbInvulnerable(player, false)
  else
    -- No player reference to call RemoveGodMode on: leave c.invulnerable as it was (true) so a
    -- later successful setClimbInvulnerable(player, false) still runs instead of being skipped
    -- by the already-off guard, which would otherwise strand the engine's flag on forever.
    print("[WebSlinger] climb: god-mode toggle skipped on exit (no player reference)")
  end
end

--- One wall-climb tick while CLIMBING: wall-jump, then directional movement in the wall plane
-- with edge detection, then writes V's position. onUpdate only.
function WebSlinger.UpdateClimb(dt)
  if WebSlinger.state ~= States.CLIMBING then return end
  local c, cfg = WebSlinger.climbing, WebSlinger.climb
  local player = Game.GetPlayer()
  if player == nil or c.pos == nil or c.normal == nil then
    exitClimb("lost player or wall", nil)
    return
  end
  local n = c.normal

  if c.jumpQueued then
    c.jumpQueued = false
    -- A jump blocked by the wall-jump cooldown leaves V on the wall.
    if WebSlinger.WallJump() then return end
  end

  -- Wall-plane axes: up is world up; right is to V's right while she faces into the wall.
  local rx, ry = -n.y, n.x
  local my = c.moveY
  local vertical = my * (my > 0 and cfg.speedUp or cfg.speedDown)
  local lateral = c.moveX * cfg.speedStrafe

  if math.abs(vertical) > 1e-3 or math.abs(lateral) > 1e-3 then
    local target = vec4(c.pos.x + rx * lateral * dt, c.pos.y + ry * lateral * dt, c.pos.z + vertical * dt)

    -- Something solid in the way along the wall (overhang, adjacent wall): stay put this tick.
    local from = vec4(c.pos.x, c.pos.y, c.pos.z + cfg.probeHeight)
    local dx, dy, dz = target.x - c.pos.x, target.y - c.pos.y, target.z - c.pos.z
    local step = math.sqrt(dx * dx + dy * dy + dz * dz)
    local blocked = WebSlinger.ExecuteSmartRaycast(from, Vector4.new(dx, dy, dz, 0.0), step + 0.3)

    if not blocked then
      if vertical < 0.0 and isGrounded(target) then
        exitClimb("reached the ground", nil)
        return
      end
      local hitPos, newNormal = probeWall(target, n)
      if hitPos == nil then
        -- Past the wall's edge. Never move V there: over the top she mantles onto the ledge if
        -- there is one, otherwise (and at side/bottom edges) she lets go where she is.
        if vertical > 0.0 and tryMantle(player, c) then
          exitClimb("mantled over the top", nil)
        else
          exitClimb("reached the wall's edge", nil)
        end
        return
      end
      -- Follow the surface: refresh the normal and keep V at the standoff distance from it.
      c.normal = newNormal
      c.pos = vec4(hitPos.x + newNormal.x * cfg.standoff, hitPos.y + newNormal.y * cfg.standoff, target.z)
    end
  end

  placeV(player, c.pos)
  WebSlinger.swing.lastPos = vec4(c.pos.x, c.pos.y, c.pos.z)
end

-- Movement axes and Jump come from the game's own input actions, so climbing uses whatever the
-- player has bound to move/jump (keyboard or gamepad). Registered in onInit.
local function observeClimbInput()
  Observe("PlayerPuppet", "OnAction", function(_, action)
    local c = WebSlinger.climbing
    local name = Game.NameToString(ListenerAction.GetName(action))
    if name == "MoveX" then
      c.moveX = ListenerAction.GetValue(action)
    elseif name == "MoveY" then
      c.moveY = ListenerAction.GetValue(action)
    elseif name == "Jump" and WebSlinger.state == States.CLIMBING then
      local ok, kind = pcall(function() return ListenerAction.GetType(action).value end)
      if ok and kind == "BUTTON_PRESSED" then c.jumpQueued = true end
    end
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Wall-jump (C2WS-T11)
--
-- Jump while CLIMBING or WALLRUNNING leaves that state and launches V with
-- wallNormal * OutwardForce + (0, 0, UpwardForce) (plus the run's along-wall speed when jumping off
-- a wall-run), flown by the web-sling momentum carry so every jump is the same deterministic arc.
-- While that flight lasts, a probe along V's horizontal velocity (ExecuteSmartRaycast, C2WS-T4)
-- catches the next wall she flies into and latches her onto it (CLIMBING). If that wall roughly
-- faces the one she jumped off, a jump within ChainWindow of the landing is a chain: the Cooldown
-- that otherwise spaces wall-jumps out never blocks it. See docs/DESIGN.md.
-- ---------------------------------------------------------------------------------------------

--- Wall-jumps off the current wall. Only acts while CLIMBING or WALLRUNNING. Returns true if V
-- jumped; false (V stays on the wall) when blocked by the cooldown or there is no wall to jump off.
function WebSlinger.WallJump()
  local state = WebSlinger.state
  if state ~= States.CLIMBING and state ~= States.WALLRUNNING then return false end
  local wj, cfg, s = WebSlinger.wj, WebSlinger.walljump, WebSlinger.swing
  local player = Game.GetPlayer()
  if player == nil then return false end

  local n, pos, bx, by
  if state == States.CLIMBING then
    local c = WebSlinger.climbing
    if c.pos == nil or c.normal == nil then return false end
    n, pos, bx, by = c.normal, c.pos, 0.0, 0.0
  else
    local r = WebSlinger.run
    if r.normal == nil or r.dir == nil then return false end
    n = r.normal
    pos = (r.teleportMode and r.pos) or player:GetWorldPosition()
    bx, by = r.dir.x * r.speed * cfg.RunCarry, r.dir.y * r.speed * cfg.RunCarry
  end

  local now = wj.clock
  local chain = wj.landedFacing and wj.landedAt ~= nil and (now - wj.landedAt) <= cfg.ChainWindow
  if not chain and wj.lastJumpAt ~= nil and (now - wj.lastJumpAt) < cfg.Cooldown then
    wj.lastResult = string.format("blocked by cooldown (%.2f s since last jump)", now - wj.lastJumpAt)
    return false
  end

  local vel = { x = bx + n.x * cfg.OutwardForce, y = by + n.y * cfg.OutwardForce, z = cfg.UpwardForce }
  local launchNormal = Vector4.new(n.x, n.y, 0.0, 0.0)
  local from = state == States.CLIMBING and "climb" or "wall-run"
  if state == States.CLIMBING then
    exitClimb("wall-jump", vel)
  else
    endWallRun("wall-jump", false)
    s.pos = vec4(pos.x, pos.y, pos.z)
    s.vel = { x = vel.x, y = vel.y, z = vel.z }
    s.estVel = { x = vel.x, y = vel.y, z = vel.z }
    s.carry, s.carryTime = true, 0.0
  end

  wj.chainCount = chain and wj.chainCount + 1 or 0
  wj.jumpCount = wj.jumpCount + 1
  wj.lastJumpAt = now
  wj.landedAt, wj.landedFacing = nil, false
  wj.flying, wj.flightTime = true, 0.0
  wj.launchNormal, wj.launchZ = launchNormal, pos.z
  wj.lastResult = string.format("#%d off %s%s", wj.jumpCount, from,
    chain and string.format(" (chain x%d)", wj.chainCount) or "")
  print("[WebSlinger] wall-jump " .. wj.lastResult)
  WebSlinger.PlayImpactFeedback(WebSlinger.polish.JumpScale, "wall-jump launch")  -- C2WS-T13
  return true
end

--- One wall-jump tick (onUpdate, before the web-sling tick so the catch probe runs before the
-- carry's collision would slide V along the wall): advances the wall-jump clock and, during a
-- wall-jump flight, catches the next wall V flies into and latches her onto it.
local function updateWallJump(dt)
  local wj, cfg, s = WebSlinger.wj, WebSlinger.walljump, WebSlinger.swing
  wj.clock = wj.clock + dt
  if not wj.flying then return end
  if WebSlinger.state ~= States.NONE or not s.carry or s.pos == nil or s.vel == nil then
    -- Landed on the ground, re-slung, carry timed out, or something else took over.
    wj.flying = false
    return
  end

  wj.flightTime = wj.flightTime + dt
  if wj.flightTime < cfg.MinFlightTime then return end
  local v = s.vel
  local dir = flatUnit(v)
  if dir == nil then return end
  local speed2D = math.sqrt(v.x * v.x + v.y * v.y)

  local origin = vec4(s.pos.x, s.pos.y, s.pos.z + cfg.probeHeight)
  local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(origin, dir, cfg.CatchDistance + speed2D * dt)
  if not hit then return end
  local n2 = math.sqrt(hitNormal.x * hitNormal.x + hitNormal.y * hitNormal.y)
  if n2 < cfg.minWallNormal2D then return end
  local n = Vector4.new(hitNormal.x / n2, hitNormal.y / n2, 0.0, 0.0)
  if dir.x * n.x + dir.y * n.y > -cfg.MinApproachDot then return end  -- grazing, not flying into it

  local ln = wj.launchNormal
  local facing = ln ~= nil and (n.x * ln.x + n.y * ln.y) <= -cfg.FacingDot
  wj.flying = false
  s.carry = false
  WebSlinger.TriggerWallLatch(n, hitPos, { x = v.x, y = v.y, z = v.z })
  if WebSlinger.state == States.CLIMBING then
    wj.landedAt, wj.landedFacing = wj.clock, facing
    wj.lastLanding = string.format("%s wall after %.2f s, %+.1f m vs launch%s",
      facing and "facing" or "other", wj.flightTime, s.pos.z - wj.launchZ,
      facing and string.format(" (chain window %.2f s)", cfg.ChainWindow) or "")
  else
    wj.lastLanding = "caught a wall but the latch failed"
  end
  print("[WebSlinger] wall-jump landing: " .. wj.lastLanding)
end

-- Runs the forward wall probe from V's chest along her horizontal facing. Called once per
-- onUpdate tick, never from onDraw.
local function updateWallProbe()
  local probe = WebSlinger.probe
  local player = Game.GetPlayer()
  if player == nil then
    probe.valid = false
    return
  end

  local pos = player:GetWorldPosition()
  local fwd = player:GetWorldForward()
  local flat = normalized(Vector4.new(fwd.x, fwd.y, 0.0, 0.0)) or Vector4.new(0.0, 1.0, 0.0, 0.0)
  local origin = vec4(pos.x, pos.y, pos.z + WebSlinger.probeHeight)

  local started = os.clock()
  local hit, hitPos, hitNormal = WebSlinger.ExecuteSmartRaycast(origin, flat, WebSlinger.probeDistance)
  local elapsedMs = (os.clock() - started) * 1000.0
  WebSlinger.timing.raycastMs = smooth(WebSlinger.timing.raycastMs, elapsedMs)

  probe.valid = true
  probe.origin = origin
  probe.target = vec4(
    origin.x + flat.x * WebSlinger.probeDistance,
    origin.y + flat.y * WebSlinger.probeDistance,
    origin.z)
  probe.hit = hit
  probe.hitPos = hitPos
  probe.hitNormal = hitNormal
end

-- ---------------------------------------------------------------------------------------------
-- Monowire hand anchor (C2WS-T26), cosmetic only.
--
-- Showing the real Monowire model deploying is not reachable from CET Lua alone without touching
-- V's real equipment (see docs/DESIGN.md, "Gap: no Monowire model from CET"), so this ships the
-- documented fallback: the swing line starts at V's right-hand attachment slot instead of a fixed
-- point above her feet, so the wire reads as fired from her hand. Read-only: it only queries a slot
-- transform, never equips, draws, holsters or spawns anything, so V's weapon/cyberware state is
-- untouched before, during and after a swing. Every engine call is pcall-guarded; if no candidate
-- slot resolves (or a reading is implausible) the line falls back to an estimated hand point.
-- ---------------------------------------------------------------------------------------------

WebSlinger.monowire = {
  HandAnchor = true,  -- false = old behaviour: the line starts handHeight above V's feet
  -- Player components and slot names tried in order; the first pair that returns a transform wins.
  components = { "Item_Attachment_Slot", "AttachmentSlots", "SlotComponent" },
  slots = { "RightHand", "WeaponRight", "r_hand", "RightArm" },
  MaxSlotOffset = 2.5,   -- a slot reading farther than this from the estimated hand is rejected
  FallbackReach = 0.35,  -- fallback: hand point this far from the shoulder toward the anchor
  -- Live state (written only by monowireHandPoint, read by the debug panel).
  resolvedFor = -1,      -- swing.attachCount the slot was resolved for (re-resolved each swing)
  component = nil,       -- cached slot component for the current swing
  slot = nil,            -- CName of the working slot for the current swing
  source = "(no swing yet)",
}

-- Reads a world position from a slot component's slot. CET hands an `out` parameter back as an
-- extra return value, but older builds fill the struct passed in, so both are accepted.
local function readSlotPosition(component, slotName)
  local ok, pos = pcall(function()
    local wt = WorldTransform.new()
    local found, outWt = component:GetSlotTransform(slotName, wt)
    if found == false then return nil end
    local t = (type(outWt) == "userdata") and outWt or wt
    return WorldPosition.ToVector4(WorldTransform.GetWorldPosition(t))
  end)
  if not ok or pos == nil or pos.x == nil then return nil end
  -- An unfilled transform reads as the world origin; never anchor the wire there.
  if pos.x == 0 and pos.y == 0 and pos.z == 0 then return nil end
  return pos
end

local function resolveHandSlot(player, estimate)
  local m = WebSlinger.monowire
  m.component, m.slot = nil, nil
  for _, compName in ipairs(m.components) do
    local okc, comp = pcall(function() return player:FindComponentByName(CName.new(compName)) end)
    if okc and comp ~= nil then
      for _, slotName in ipairs(m.slots) do
        local slot = CName.new(slotName)
        local p = readSlotPosition(comp, slot)
        if p ~= nil and lengthOf({ x = p.x - estimate.x, y = p.y - estimate.y, z = p.z - estimate.z })
            <= m.MaxSlotOffset then
          m.component, m.slot = comp, slot
          m.source = compName .. "/" .. slotName
          return p
        end
      end
    end
  end
  m.source = "estimate (no hand slot readable)"
  return nil
end

-- World point the swing line starts from: V's right-hand slot while it resolves, else an estimate
-- (shoulder height, reaching a little toward the anchor). Called from onDraw while grappling.
local function monowireHandPoint()
  local s, m = WebSlinger.swing, WebSlinger.monowire
  local shoulder = vec4(s.pos.x, s.pos.y, s.pos.z + WebSlinger.sling.handHeight)
  if not m.HandAnchor then return shoulder end

  local toAnchor = normalized(Vector4.new(s.anchor.x - shoulder.x, s.anchor.y - shoulder.y,
    s.anchor.z - shoulder.z, 0.0))
  local estimate = shoulder
  if toAnchor ~= nil then
    estimate = vec4(shoulder.x + toAnchor.x * m.FallbackReach, shoulder.y + toAnchor.y * m.FallbackReach,
      shoulder.z + toAnchor.z * m.FallbackReach)
  end

  local player = Game.GetPlayer()
  if player == nil then return estimate end
  local p = nil
  if m.resolvedFor ~= s.attachCount then
    m.resolvedFor = s.attachCount
    p = resolveHandSlot(player, estimate)
  elseif m.component ~= nil then
    p = readSlotPosition(m.component, m.slot)
    if p ~= nil and lengthOf({ x = p.x - estimate.x, y = p.y - estimate.y, z = p.z - estimate.z })
        > m.MaxSlotOffset then
      p = nil
    end
  end
  return p or estimate
end

-- Projects a world point to screen pixels. Returns nil when the point is behind the camera or
-- far off-screen.
local function worldToScreen(point)
  local camera = Game.GetCameraSystem()
  if camera == nil then return nil end
  local ndc = camera:ProjectPoint(point)
  if ndc == nil or ndc.z <= 0 or math.abs(ndc.x) > 1.5 or math.abs(ndc.y) > 1.5 then
    return nil
  end
  local width, height = GetDisplayResolution()
  return (ndc.x + 1.0) * 0.5 * width, (1.0 - ndc.y) * 0.5 * height
end

local function drawWorldLine(drawList, a, b, color, thickness)
  local ax, ay = worldToScreen(a)
  local bx, by = worldToScreen(b)
  if ax == nil or bx == nil then return end
  ImGui.ImDrawListAddLine(drawList, ax, ay, bx, by, color, thickness)
end

local function drawWorldPoint(drawList, p, color, radius)
  local x, y = worldToScreen(p)
  if x == nil then return end
  ImGui.ImDrawListAddCircleFilled(drawList, x, y, radius, color)
end

local function drawRaycastOverlay()
  local probe = WebSlinger.probe
  if not probe.valid then return end

  local drawList = ImGui.GetBackgroundDrawList()
  local green = ImGui.GetColorU32(0.2, 1.0, 0.2, 1.0)
  local red = ImGui.GetColorU32(1.0, 0.25, 0.25, 1.0)
  local yellow = ImGui.GetColorU32(1.0, 0.9, 0.1, 1.0)

  if probe.hit then
    drawWorldLine(drawList, probe.origin, probe.hitPos, green, 2.0)
    drawWorldPoint(drawList, probe.hitPos, green, 5.0)
    local n = probe.hitNormal
    local normalEnd = vec4(probe.hitPos.x + n.x * 0.5, probe.hitPos.y + n.y * 0.5, probe.hitPos.z + n.z * 0.5)
    drawWorldLine(drawList, probe.hitPos, normalEnd, yellow, 2.0)
  else
    drawWorldLine(drawList, probe.origin, probe.target, red, 2.0)
  end
end

-- Projects a world point that is known to be in front of the camera. Unlike worldToScreen it keeps
-- points far off-screen (ImGui clips the line to the display), so a long cable whose anchor sits
-- above the top edge of the view still draws its visible part instead of vanishing entirely.
local function projectInFront(point)
  local camera = Game.GetCameraSystem()
  if camera == nil then return nil end
  local ndc = camera:ProjectPoint(point)
  if ndc == nil or math.abs(ndc.x) > 100.0 or math.abs(ndc.y) > 100.0 then return nil end
  local width, height = GetDisplayResolution()
  return (ndc.x + 1.0) * 0.5 * width, (1.0 - ndc.y) * 0.5 * height
end

-- Camera position estimate and unit axes (forward, right, up) for the cable, or nil.
local function ropeCamera(s, rc)
  local ok, fwd = pcall(function() return Game.GetCameraSystem():GetActiveCameraForward() end)
  if not ok or fwd == nil then return nil end
  local flen = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
  if flen < 1e-4 then return nil end
  local f = { x = fwd.x / flen, y = fwd.y / flen, z = fwd.z / flen }
  -- Right = forward x world up (flat); up = right x forward.
  local rx, ry = f.y, -f.x
  local rlen = math.sqrt(rx * rx + ry * ry)
  if rlen < 1e-4 then rx, ry = 1.0, 0.0 else rx, ry = rx / rlen, ry / rlen end
  return {
    pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z + rc.cameraHeight },
    f = f,
    r = { x = rx, y = ry, z = 0.0 },
    u = { x = ry * f.z, y = -rx * f.z, z = rx * f.y - ry * f.x },
  }
end

-- Default cable start: just ahead of the camera, lower right, where V's right hand shows.
local function ropeCameraHandPoint(cam, rc)
  local c, f, r, u = cam.pos, cam.f, cam.r, cam.u
  return vec4(c.x + f.x * rc.handForward + r.x * rc.handRight - u.x * rc.handDown,
    c.y + f.y * rc.handForward + r.y * rc.handRight - u.y * rc.handDown,
    c.z + f.z * rc.handForward + r.z * rc.handRight - u.z * rc.handDown)
end

-- The visible cable while swinging (C2WS-T25): from V's hand to the anchor, rebuilt every frame
-- from the live swing state so both ends track the arc, and gone the frame IsGrappling drops. The
-- segment is clipped against the camera's near plane in world space first: the old version dropped
-- the whole line whenever either end was off screen or behind the camera, which is most of a swing
-- (the anchor sits high above the view and V's body-centre hand point is under the camera).
local function drawRope()
  local s = WebSlinger.swing
  if not WebSlinger.IsGrappling or s.anchor == nil or s.pos == nil then return end
  local rc = WebSlinger.rope
  local cam = ropeCamera(s, rc)
  if cam == nil then return end
  local hand = ropeCameraHandPoint(cam, rc)
  if WebSlinger.monowire.HandAnchor then
    -- V's right-hand slot (C2WS-T26) when one resolved; its body-centre estimate sits under the
    -- first-person camera, so without a slot the camera-relative start above is the better hand.
    local slotHand = monowireHandPoint()
    if WebSlinger.monowire.component ~= nil then hand = slotHand end
  end

  -- Near-plane clip: depth along the camera forward, keep only the part in front of nearClip.
  local c, f = cam.pos, cam.f
  local hx, hy, hz = hand.x, hand.y, hand.z
  local ax, ay, az = s.anchor.x, s.anchor.y, s.anchor.z
  local dh = (hx - c.x) * f.x + (hy - c.y) * f.y + (hz - c.z) * f.z
  local da = (ax - c.x) * f.x + (ay - c.y) * f.y + (az - c.z) * f.z
  if dh < rc.nearClip and da < rc.nearClip then return end
  if dh < rc.nearClip then
    local t = (rc.nearClip - dh) / (da - dh)
    hx, hy, hz = hx + (ax - hx) * t, hy + (ay - hy) * t, hz + (az - hz) * t
  elseif da < rc.nearClip then
    local t = (rc.nearClip - da) / (dh - da)
    ax, ay, az = ax + (hx - ax) * t, ay + (hy - ay) * t, az + (hz - az) * t
  end

  local sx, sy = projectInFront(vec4(hx, hy, hz))
  local ex, ey = projectInFront(vec4(ax, ay, az))
  if sx == nil or ex == nil then return end

  local drawList = ImGui.GetBackgroundDrawList()
  local col = rc.color
  local glow = ImGui.GetColorU32(col[1], col[2], col[3], col[4] * rc.glowAlpha)
  local core = ImGui.GetColorU32(col[1], col[2], col[3], col[4])
  -- Pale filament down the middle so it reads as a taut lit cable rather than a flat stroke.
  local hot = ImGui.GetColorU32(0.6 + 0.4 * col[1], 0.6 + 0.4 * col[2], 0.6 + 0.4 * col[3], col[4])
  ImGui.ImDrawListAddLine(drawList, sx, sy, ex, ey, glow, rc.thickness * rc.glowScale)
  ImGui.ImDrawListAddLine(drawList, sx, sy, ex, ey, core, rc.thickness)
  ImGui.ImDrawListAddLine(drawList, sx, sy, ex, ey, hot, math.max(1.0, rc.thickness * 0.35))
  if da >= rc.nearClip then
    drawWorldPoint(drawList, s.anchor, glow, rc.anchorRadius * 2.0)
    drawWorldPoint(drawList, s.anchor, core, rc.anchorRadius)
  end
end

-- ---------------------------------------------------------------------------------------------
-- 'Peter Parker' intro text (C2WS-T17)
--
-- CET exposes no API that adds a new contact or message thread to CP77's phone (that needs new
-- .journal resources plus localization, i.e. ArchiveXL; see docs/DESIGN.md). Until then this is the
-- interim fallback: a CET ImGui overlay styled as a phone text bubble. Sent only from the debug
-- panel's 'Send Peter Parker intro text' button, never automatically.
--
-- The two quoted lines are verified (see the ticket) and must stay word for word:
--   "With great power comes great responsibility." -- Uncle Ben, Spider-Man (2002)
--   "You know who I am." / "Your friendly neighborhood Spider-Man." -- Spider-Man (2002), Moondance Diner
-- ---------------------------------------------------------------------------------------------

local PeterText = {
  visible = false,
  sentAt = nil,  -- "HH:MM" the overlay was last sent, shown as the message timestamp
  sender = "Peter Parker",
  body = "Hey V -- your friendly neighborhood Spider-Man here. Heard you've picked up a few of my "
    .. "old tricks around Night City: climbing walls on your Mantis Blades, wall-runs, wall-jumps, "
    .. "and a real web-sling swing instead of that grapple-hook thing. Bind a swing key in the CET "
    .. "overlay (Bindings > WebSlinger), hold it while you face the skyline, and let go to fly.\n\n"
    .. "Uncle Ben always told me, \"With great power comes great responsibility.\" So swing safe "
    .. "out there, V.\n\n"
    .. "\"You know who I am.\" Your friendly neighborhood Spider-Man.\n\n"
    .. "-- Peter Parker",
  credit = "Quotes: Uncle Ben and Peter Parker, Spider-Man (2002).",
}
WebSlinger.PeterText = PeterText

--- Shows the 'Peter Parker' intro text overlay (re-sending just brings it back).
function WebSlinger.SendPeterParkerIntroText()
  PeterText.visible = true
  PeterText.sentAt = os.date("%H:%M")
  print("[WebSlinger] text from " .. PeterText.sender .. " sent (overlay fallback)")
end

-- Phone-style text bubble, top-right of the screen. onDraw only.
local function drawPeterText()
  if not PeterText.visible then return end

  local width = GetDisplayResolution()
  local boxWidth = 420
  ImGui.SetNextWindowPos(width - boxWidth - 40, 80, ImGuiCond.Appearing)
  ImGui.SetNextWindowSize(boxWidth, 0, ImGuiCond.Appearing)

  ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 14.0)
  ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 14.0, 12.0)
  ImGui.PushStyleColor(ImGuiCol.WindowBg, 0.05, 0.06, 0.09, 0.94)
  ImGui.PushStyleColor(ImGuiCol.Border, 0.85, 0.12, 0.15, 0.9)
  ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.11, 0.30, 0.62, 1.0)

  local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoCollapse + ImGuiWindowFlags.AlwaysAutoResize
  if ImGui.Begin("WebSlinger: message from Peter Parker", flags) then
    -- Header: contact name (the player-visible sender) and timestamp.
    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.35, 0.35, 1.0)
    ImGui.Text(PeterText.sender)
    ImGui.PopStyleColor(1)
    ImGui.SameLine()
    ImGui.TextDisabled("  text message  " .. tostring(PeterText.sentAt or ""))
    ImGui.Separator()

    -- The bubble itself, sized to the wrapped text so the whole message is readable without scrolling.
    local bubbleWidth = boxWidth - 28
    local wrapWidth = bubbleWidth - 20
    local _, textHeight = ImGui.CalcTextSize(PeterText.body, false, wrapWidth)
    ImGui.PushStyleVar(ImGuiStyleVar.ChildRounding, 12.0)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 10.0, 8.0)
    ImGui.BeginChild("PeterTextBubble", bubbleWidth, (textHeight or 200) + 18, false,
      ImGuiWindowFlags.AlwaysUseWindowPadding + ImGuiWindowFlags.NoScrollbar)
    ImGui.PushTextWrapPos(ImGui.GetCursorPosX() + wrapWidth)
    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 1.0, 1.0, 1.0)
    ImGui.TextWrapped(PeterText.body)
    ImGui.PopStyleColor(1)
    ImGui.PopTextWrapPos()
    ImGui.EndChild()
    ImGui.PopStyleVar(2)

    ImGui.TextDisabled(PeterText.credit)
    if ImGui.Button("Close") then
      PeterText.visible = false
    end
  end
  ImGui.End()

  ImGui.PopStyleColor(3)
  ImGui.PopStyleVar(2)
end

registerForEvent("onInit", function()
  print("[WebSlinger] loaded (wall raycast utility, state machine, web-sling base)")
  observeClimbInput()
  observeWallRunJump()
end)

registerForEvent("onUpdate", function(deltaTime)
  WebSlinger.timing.frameMs = smooth(WebSlinger.timing.frameMs, deltaTime * 1000.0)

  -- Polish (C2WS-T13) runs even while disabled so an exit tilt eases back and a punch ends cleanly.
  updatePolish(math.min(deltaTime, 0.05))

  if WebSlinger.enabled or WebSlinger.debugRaycast then
    updateWallProbe()
  else
    WebSlinger.probe.valid = false
  end

  if not WebSlinger.enabled then
    if WebSlinger.state == States.SLINGING then releaseSling("mod disabled", false) end
    if WebSlinger.state == States.CLIMBING then exitClimb("mod disabled", nil) end
    if WebSlinger.state == States.WALLRUNNING then WebSlinger.EndWallRun("mod disabled", false) end
    WebSlinger.run.jumpQueued = false
    WebSlinger.swing.carry = false
    WebSlinger.swing.lastPos = nil
    WebSlinger.wj.flying, WebSlinger.wj.landedAt, WebSlinger.wj.landedFacing = false, nil, false
    return
  end

  -- Clamp the step so a hitch (menu, loading) can't fling V across the map in one tick.
  local dt = math.min(deltaTime, 0.05)
  updateWallJump(dt)
  updateSling(dt)
  WebSlinger.UpdateClimb(dt)
  updateWallRun(dt)
end)

registerForEvent("onDraw", function()
  if WebSlinger.debugRaycast then
    drawRaycastOverlay()
  end
  drawRope()
  drawPeterText()

  if not ImGui.Begin("WebSlinger") then
    ImGui.End()
    return
  end

  -- CET's ImGui.Checkbox returns (value, pressed).
  local changed
  WebSlinger.enabled, changed = ImGui.Checkbox("Enabled", WebSlinger.enabled)
  ImGui.Text("State: " .. WebSlinger.state)
  local last = WebSlinger.lastTransition
  if last then
    ImGui.Text(string.format("Last transition: %s -> %s at %s (%.1fs ago, #%d)",
      last.from, last.to, last.wallTime, os.clock() - last.clock, WebSlinger.transitionCount))
  else
    ImGui.Text("Last transition: (none yet)")
  end

  -- Re-sling loop verification (C2WS-T12): the recent transitions, newest last. A clean
  -- swing -> run -> jump -> swing take shows a NONE between every two SLINGING entries.
  ImGui.Text(string.format("SLINGING entered without NONE: %d", WebSlinger.slingWithoutNone))
  if ImGui.CollapsingHeader("Transition log") then
    for _, line in ipairs(WebSlinger.transitionLog) do
      ImGui.Text(line)
    end
    if ImGui.Button("Clear transition log") then
      WebSlinger.transitionLog = {}
      WebSlinger.slingWithoutNone = 0
    end
  end

  -- Debug: force each state. ImGui.Button is true only on the click frame, so each click yields at
  -- most one SetState call; clicking the current state is a no-op.
  ImGui.Text("Force state:")
  for i, name in ipairs(STATE_ORDER) do
    if i > 1 then ImGui.SameLine() end
    if ImGui.Button(name) then
      WebSlinger.SetState(name)
    end
  end

  WebSlinger.debugRaycast, changed = ImGui.Checkbox("Debug: show wall raycast", WebSlinger.debugRaycast)
  if WebSlinger.debugRaycast then
    local probe = WebSlinger.probe
    if probe.valid and probe.hit then
      local n = probe.hitNormal
      ImGui.Text(string.format("Wall: HIT  normal (%.2f, %.2f, %.2f)", n.x, n.y, n.z))
    elseif probe.valid then
      ImGui.Text("Wall: none")
    else
      ImGui.Text("Wall: (no player)")
    end
  end

  ImGui.Text(string.format("Frame: %.2f ms   Raycast: %.3f ms",
    WebSlinger.timing.frameMs, WebSlinger.timing.raycastMs))
  ImGui.Separator()
  local s, cfg = WebSlinger.swing, WebSlinger.sling
  ImGui.Text("Web-sling: bind the key under CET Bindings > WebSlinger")
  ImGui.Text(string.format("Key: %s   Grappling: %s   Carry: %s   Attaches: %d",
    s.keyHeld and "HELD" or "up", tostring(WebSlinger.IsGrappling), tostring(s.carry), s.attachCount))
  ImGui.Text(string.format("Jump-sling: %s   Jump-fired swings: %d   Boost leaps: %d",
    s.auto and "ACTIVE" or "off", s.autoCount, s.leapCount))
  if WebSlinger.IsGrappling and s.vel ~= nil then
    ImGui.Text(string.format("Rope: %.1f m   Speed: %.1f m/s   Time: %.2f s",
      s.ropeLength, swingSpeed(s.vel), s.time))
  end
  ImGui.Text("Last search: " .. tostring(s.lastSearch))
  ImGui.Text("Last release: " .. tostring(s.lastRelease or "(none yet)"))
  ImGui.Text("Last wall impact: " .. tostring(WebSlinger.wall.lastImpact))
  local ic = WebSlinger.impact
  ic.WallCheckDistance = ImGui.SliderFloat("Wall check distance", ic.WallCheckDistance, 0.5, 6.0)
  ic.WallLatchAngleThreshold = ImGui.SliderFloat("Latch angle threshold", ic.WallLatchAngleThreshold, 0.0, 1.0)
  ic.MinimumWallRunSpeed = ImGui.SliderFloat("Min wall-run speed", ic.MinimumWallRunSpeed, 0.0, 25.0)
  local c, cc = WebSlinger.climbing, WebSlinger.climb
  if WebSlinger.state == States.CLIMBING and c.pos ~= nil then
    ImGui.Text(string.format("Climb: %.1f m above entry   Move (%.2f, %.2f)   No fall damage: %s",
      c.pos.z - c.startZ, c.moveX, c.moveY, tostring(c.invulnerable)))
  end
  ImGui.Text("Last climb exit: " .. tostring(c.lastExit))
  cc.speedUp = ImGui.SliderFloat("Climb speed up", cc.speedUp, 0.5, 10.0)
  cc.speedStrafe = ImGui.SliderFloat("Climb strafe speed", cc.speedStrafe, 0.5, 10.0)
  cfg.AnchorMaxDistance = ImGui.SliderFloat("Anchor max distance", cfg.AnchorMaxDistance, 10.0, 100.0)
  cfg.reelSpeed = ImGui.SliderFloat("Reel speed", cfg.reelSpeed, 0.0, 15.0)
  cfg.gravity = ImGui.SliderFloat("Swing gravity", cfg.gravity, 5.0, 30.0)
  cfg.steerAccel = ImGui.SliderFloat("Steer accel", cfg.steerAccel, 0.0, 20.0)
  -- Swing cable look (C2WS-T25).
  local rc = WebSlinger.rope
  rc.thickness = ImGui.SliderFloat("Cable thickness", rc.thickness, 1.0, 12.0)
  local newColor, colorUsed = ImGui.ColorEdit4("Cable color", rc.color)
  if colorUsed and type(newColor) == "table" and #newColor >= 4 then rc.color = newColor end
  rc.glowScale = ImGui.SliderFloat("Cable glow width", rc.glowScale, 1.0, 6.0)
  rc.glowAlpha = ImGui.SliderFloat("Cable glow opacity", rc.glowAlpha, 0.0, 1.0)
  rc.handForward = ImGui.SliderFloat("Cable start ahead", rc.handForward, 0.2, 2.0)
  rc.handRight = ImGui.SliderFloat("Cable start right", rc.handRight, -1.0, 1.0)
  rc.handDown = ImGui.SliderFloat("Cable start down", rc.handDown, -0.5, 2.0)  -- C2WS-T29: widened

  ImGui.Separator()
  local r, wr = WebSlinger.run, WebSlinger.wallrun
  ImGui.Text("Wall-run: press jump with a wall to your left/right, or glance off one mid-swing")
  if WebSlinger.state == States.WALLRUNNING and r.vel ~= nil then
    ImGui.Text(string.format("Running: %.2f s   Remaining: %.2f s   Mode: %s", r.time,
      math.max(0.0, wr.WallRunMaxDuration - r.time), r.teleportMode and "teleport" or "SetLinearVelocity"))
    ImGui.Text(string.format("Speed %.1f m/s (measured %.1f, drop-off below %.1f)", r.speed,
      r.measuredSpeed, WebSlinger.impact.MinimumWallRunSpeed))
  end
  ImGui.Text("Last wall-run: " .. tostring(r.lastEntry))
  ImGui.Text("Last wall-run end: " .. tostring(r.lastEnd))
  wr.UseLocomotionVelocity = ImGui.Checkbox("Wall-run via SetLinearVelocity", wr.UseLocomotionVelocity)
  wr.MinWallRunSpeed = ImGui.SliderFloat("Wall-run min speed", wr.MinWallRunSpeed, 5.0, 30.0)
  wr.StickyForce = ImGui.SliderFloat("Wall-run sticky force", wr.StickyForce, 0.0, 5.0)
  wr.AntiGravityZ = ImGui.SliderFloat("Wall-run anti-gravity Z", wr.AntiGravityZ, -2.0, 6.0)
  wr.CameraTiltDeg = ImGui.SliderFloat("Wall-run camera tilt", wr.CameraTiltDeg, 0.0, 25.0)
  wr.WallRunMaxDuration = ImGui.SliderFloat("Wall-run max duration", wr.WallRunMaxDuration, 0.5, 10.0)
  wr.BrakeDecel = ImGui.SliderFloat("Wall-run brake decel", wr.BrakeDecel, 0.0, 40.0)
  wr.ManualTriggerDistance = ImGui.SliderFloat("Wall-run jump reach", wr.ManualTriggerDistance, 0.5, 4.0)
  wr.ManualLatchDistance = ImGui.SliderFloat("Wall-latch jump reach", wr.ManualLatchDistance, 0.5, 2.0)

  ImGui.Separator()
  local wj, wjc = WebSlinger.wj, WebSlinger.walljump
  ImGui.Text("Wall-jump: press jump while climbing or wall-running")
  ImGui.Text(string.format("Flying: %s   Chain: x%d   Jumps: %d", tostring(wj.flying), wj.chainCount, wj.jumpCount))
  if wj.landedAt ~= nil and wj.landedFacing then
    ImGui.Text(string.format("Chain window: %.2f s left", math.max(0.0, wjc.ChainWindow - (wj.clock - wj.landedAt))))
  end
  ImGui.Text("Last wall-jump: " .. tostring(wj.lastResult))
  ImGui.Text("Last wall-jump landing: " .. tostring(wj.lastLanding))
  wjc.OutwardForce = ImGui.SliderFloat("Wall-jump outward force", wjc.OutwardForce, 0.0, 15.0)
  wjc.UpwardForce = ImGui.SliderFloat("Wall-jump upward force", wjc.UpwardForce, 0.0, 15.0)
  wjc.ChainWindow = ImGui.SliderFloat("Wall-jump chain window", wjc.ChainWindow, 0.1, 2.0)
  wjc.Cooldown = ImGui.SliderFloat("Wall-jump cooldown", wjc.Cooldown, 0.0, 2.0)

  -- Polish (C2WS-T13). Compare "Frame" above with this on and off: the polish cost must not move it.
  ImGui.Separator()
  local pp, fx = WebSlinger.polish, WebSlinger.fx
  pp.Enabled = ImGui.Checkbox("Polish: eased tilt + impact shake/FOV punch", pp.Enabled)
  ImGui.Text(string.format("Polish cost: %.3f ms/tick (while animating)   Roll: %.1f deg", fx.costMs, fx.applied))
  ImGui.Text("Last impact feedback: " .. tostring(fx.lastImpulse))
  wr.CameraTiltTime = ImGui.SliderFloat("Wall-run tilt ease time", wr.CameraTiltTime, 0.0, 1.0)
  pp.ShakeAmplitudeDeg = ImGui.SliderFloat("Impact shake (deg)", pp.ShakeAmplitudeDeg, 0.0, 6.0)
  pp.ShakeDuration = ImGui.SliderFloat("Impact shake time", pp.ShakeDuration, 0.0, 1.0)
  pp.FovPunchDeg = ImGui.SliderFloat("Impact FOV punch (deg)", pp.FovPunchDeg, 0.0, 15.0)
  pp.JumpScale = ImGui.SliderFloat("Wall-jump feedback scale", pp.JumpScale, 0.0, 1.5)

  -- Monowire hand anchor (C2WS-T26): cosmetic only, never touches V's equipment.
  ImGui.Separator()
  local mw = WebSlinger.monowire
  mw.HandAnchor = ImGui.Checkbox("Monowire: swing line starts at V's hand", mw.HandAnchor)
  ImGui.Text("Hand anchor source: " .. tostring(mw.source))

  ImGui.Separator()
  if ImGui.Button("Send Peter Parker intro text") then
    WebSlinger.SendPeterParkerIntroText()
  end

  ImGui.End()
end)

return WebSlinger
