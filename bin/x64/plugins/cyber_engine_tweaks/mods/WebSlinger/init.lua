-- WebSlinger: Mantis Blade wall-climb, wall-run/jump, and web-sling traversal for Cyberpunk 2077.
-- Skeleton only -- no traversal mechanics are implemented yet. See docs/DESIGN.md in the repo
-- root for the planned states and the open question on CET-Lua vs. RED4ext.

local WebSlinger = {
  enabled = false,
  state = "none", -- "none" | "climbing" | "wallrunning" | "slinging"
}

registerForEvent("onInit", function()
  print("[WebSlinger] loaded (skeleton, no mechanics active)")
end)

registerForEvent("onUpdate", function(deltaTime)
  if not WebSlinger.enabled then return end
  -- TODO: wall-climb / wall-run / wall-jump / web-sling state machine goes here.
end)

registerForEvent("onDraw", function()
  if not ImGui.Begin("WebSlinger") then
    ImGui.End()
    return
  end

  local changed
  changed, WebSlinger.enabled = ImGui.Checkbox("Enabled", WebSlinger.enabled)
  ImGui.Text("State: " .. WebSlinger.state)
  ImGui.TextWrapped("No traversal mechanics implemented yet -- scaffold only.")

  ImGui.End()
end)

return WebSlinger
