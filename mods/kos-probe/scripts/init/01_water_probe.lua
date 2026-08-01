-- kos-probe: F2 water-state smoke test for KenshiLua
-- Enable mod "kos-probe" in launcher. Open console: Ctrl+Shift+L
-- Walk into water and watch the logger, or run: kos_water()

local last = nil
local tickAccum = 0
local TICK_EVERY = 30 -- frames of onCharsUpdate approx throttle

local WATER_NAMES = {
  [0] = "NO_WATER",
  [1] = "VERY_SHALLOW_WATER",
  [2] = "THIGH_DEEP_WATER",
  [3] = "DEEP_WATER",
}

local function waterName(v)
  if v == nil then return "nil" end
  return WATER_NAMES[v] or ("UNKNOWN(" .. tostring(v) .. ")")
end

local function selectedCharacter()
  -- Prefer player-selected character if available via game world APIs
  local ok, world = pcall(getGameWorld)
  if not ok or not world then return nil end

  -- Try common selection accessors (vary by KenshiLib version)
  if world.getSelectedCharacter then
    local c = world:getSelectedCharacter()
    if c then return c end
  end
  if world.getPlayerCharacter then
    local c = world:getPlayerCharacter()
    if c then return c end
  end
  -- Fallback: first player squad member if exposed
  if world.getPlayerControlledCharacters then
    local list = world:getPlayerControlledCharacters()
    if list and list[1] then return list[1] end
  end
  return nil
end

function kos_water()
  local c = selectedCharacter()
  if not c then
    print("[kos-probe] no character selected / no player character found")
    return
  end
  local ok, level = pcall(function() return c:getWaterLevel() end)
  if not ok then
    print("[kos-probe] getWaterLevel failed: " .. tostring(level))
    return
  end
  local name = "?"
  pcall(function()
    if c.getName then name = c:getName() end
  end)
  print(string.format("[kos-probe] %s waterLevel=%s (%s)", tostring(name), tostring(level), waterName(level)))
  return level
end

-- Throttled poll while characters update
registerHandler("onCharsUpdate", function()
  tickAccum = tickAccum + 1
  if tickAccum < TICK_EVERY then return end
  tickAccum = 0

  local c = selectedCharacter()
  if not c then return end
  local ok, level = pcall(function() return c:getWaterLevel() end)
  if not ok then return end
  if level ~= last then
    last = level
    print("[kos-probe] water state changed -> " .. waterName(level) .. " (" .. tostring(level) .. ")")
  end
end)

print("[kos-probe] loaded. Select a character, enter water, or run kos_water() in console (Ctrl+Shift+L).")
