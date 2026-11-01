-- WebSlinger: Mantis Blade wall-climb, wall-run/jump, and web-sling traversal for Cyberpunk 2077.
-- This file provides the wall-detection raycast utility (C2WS-T4) every mechanic builds on, plus
-- its debug overlay, the traversal state machine (C2WS-T5: States + SetState with per-state
-- onEnter/onExit hooks), and the web-sling base (C2WS-T6: hold-to-swing hotkey, cone anchor
-- search, rope-constrained pendulum physics, release with momentum carry), and the wall-impact
-- angle check during a swing (C2WS-T7: latch vs. wall-run hand-off). See docs/DESIGN.md in
-- the repo root for the states, the raycast API notes, and the web-sling design decisions.

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

local WebSlinger = {
  enabled = false,
  States = States,
  state = States.NONE,
  lastTransition = nil, -- { from, to, clock, wallTime } of the most recent SetState, nil if none yet
  transitionCount = 0,

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
    retryInterval = 0.15,       -- with the key held and no rope, re-search this often
    launchSpeed = 5.0,          -- upward hop (m/s) when firing from the ground
    carryMaxTime = 4.0,         -- momentum carry after release hands back to native physics after this
  },

  -- Live web-sling state. Written only by the onUpdate tick (and SetState hooks).
  swing = {
    keyHeld = false,      -- current state of the CET-bound swing input, polled each tick
    keyWasHeld = false,   -- keyHeld as of the previous tick, for edge detection
    anchor = nil,         -- Vector4 world anchor point while attached
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
}

-- Collision groups the probe tests against. Walls are static geometry; terrain covers rock faces.
local WALL_COLLISION_GROUPS = { "Static", "Terrain" }

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
  local dx, dy, dz = nx - from.x, ny - from.y, nz - from.z
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

  if landed then
    releaseSling("landed", false)
  elseif dist <= cfg.anchorReachDistance then
    releaseSling("reached anchor", true)
  elseif s.time >= cfg.maxSwingTime then
    releaseSling("swing time cap", true)
  elseif s.keyHeld and s.time >= cfg.chainMinSwingTime and v.z > 0.0 then
    -- Chain point: V has swung past the bottom of the arc (in her direction of travel) by at least
    -- chainReleaseAngleDeg and is rising. Letting go here launches her forward into the next swing.
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
function WebSlinger.TriggerWallLatch(wallNormal2D, hitPos, velocity)
  local w = WebSlinger.wall
  w.normal, w.hitPos, w.velocity = wallNormal2D, hitPos, velocity
  WebSlinger.SetState(States.CLIMBING)
end

--- Hands V to the wall-run mechanic (C2WS-T9): records the wall and entry velocity, enters
-- WALLRUNNING.
function WebSlinger.InitiateWallRun(wallNormal2D, velocity, hitPos)
  local w = WebSlinger.wall
  w.normal, w.hitPos, w.velocity = wallNormal2D, hitPos, velocity
  WebSlinger.SetState(States.WALLRUNNING)
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
  local currentSpeed = swingSpeed(v)
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
    if s.anchor == nil then
      -- Entered SLINGING without a rope (e.g. the debug Force state button): nothing to swing on.
      releaseSling("no anchor", false)
    elseif not held then
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

-- The visible cable while swinging: a line from V's hand to the anchor.
local function drawRope()
  local s = WebSlinger.swing
  if not WebSlinger.IsGrappling or s.anchor == nil or s.pos == nil then return end
  local drawList = ImGui.GetBackgroundDrawList()
  local white = ImGui.GetColorU32(0.95, 0.95, 0.95, 0.9)
  local hand = vec4(s.pos.x, s.pos.y, s.pos.z + WebSlinger.sling.handHeight)
  drawWorldLine(drawList, hand, s.anchor, white, 2.0)
  drawWorldPoint(drawList, s.anchor, white, 4.0)
end

registerForEvent("onInit", function()
  print("[WebSlinger] loaded (wall raycast utility, state machine, web-sling base)")
end)

registerForEvent("onUpdate", function(deltaTime)
  WebSlinger.timing.frameMs = smooth(WebSlinger.timing.frameMs, deltaTime * 1000.0)

  if WebSlinger.enabled or WebSlinger.debugRaycast then
    updateWallProbe()
  else
    WebSlinger.probe.valid = false
  end

  if not WebSlinger.enabled then
    if WebSlinger.state == States.SLINGING then releaseSling("mod disabled", false) end
    WebSlinger.swing.carry = false
    WebSlinger.swing.lastPos = nil
    return
  end

  -- Clamp the step so a hitch (menu, loading) can't fling V across the map in one tick.
  updateSling(math.min(deltaTime, 0.05))
  -- TODO: wall-climb / wall-run / wall-jump mechanics go here.
end)

registerForEvent("onDraw", function()
  if WebSlinger.debugRaycast then
    drawRaycastOverlay()
  end
  drawRope()

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
  cfg.AnchorMaxDistance = ImGui.SliderFloat("Anchor max distance", cfg.AnchorMaxDistance, 10.0, 100.0)
  cfg.reelSpeed = ImGui.SliderFloat("Reel speed", cfg.reelSpeed, 0.0, 15.0)
  cfg.gravity = ImGui.SliderFloat("Swing gravity", cfg.gravity, 5.0, 30.0)
  cfg.steerAccel = ImGui.SliderFloat("Steer accel", cfg.steerAccel, 0.0, 20.0)

  ImGui.End()
end)

return WebSlinger
