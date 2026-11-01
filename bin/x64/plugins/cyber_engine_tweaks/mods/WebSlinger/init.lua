-- WebSlinger: Mantis Blade wall-climb, wall-run/jump, and web-sling traversal for Cyberpunk 2077.
-- No traversal mechanics are implemented yet. This file provides the wall-detection raycast
-- utility (C2WS-T4) every later mechanic builds on, plus its debug overlay. See docs/DESIGN.md in
-- the repo root for the planned states and the raycast API notes.

local WebSlinger = {
  enabled = false,
  state = "none", -- "none" | "climbing" | "wallrunning" | "slinging"

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

registerForEvent("onInit", function()
  print("[WebSlinger] loaded (wall raycast utility, no traversal mechanics active)")
end)

registerForEvent("onUpdate", function(deltaTime)
  WebSlinger.timing.frameMs = smooth(WebSlinger.timing.frameMs, deltaTime * 1000.0)

  if WebSlinger.enabled or WebSlinger.debugRaycast then
    updateWallProbe()
  else
    WebSlinger.probe.valid = false
  end

  if not WebSlinger.enabled then return end
  -- TODO: wall-climb / wall-run / wall-jump / web-sling state machine goes here.
end)

registerForEvent("onDraw", function()
  if WebSlinger.debugRaycast then
    drawRaycastOverlay()
  end

  if not ImGui.Begin("WebSlinger") then
    ImGui.End()
    return
  end

  local changed
  changed, WebSlinger.enabled = ImGui.Checkbox("Enabled", WebSlinger.enabled)
  ImGui.Text("State: " .. WebSlinger.state)

  changed, WebSlinger.debugRaycast = ImGui.Checkbox("Debug: show wall raycast", WebSlinger.debugRaycast)
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
  ImGui.TextWrapped("No traversal mechanics implemented yet.")

  ImGui.End()
end)

return WebSlinger
