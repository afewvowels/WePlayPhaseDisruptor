-- Phase Disruptor: draws the wandering stream for each disruptor shot.
--
-- The equipment fires an invisible damage beam every COOLDOWN ticks, plus a
-- script trigger that tells us who fired at what. We keep one library beam
-- per shooter+target, refresh it on every shot, and let it go when the
-- shots stop or the target dies. When a shooter switches targets, its idle
-- beam swings over to the new one instead of popping.

local beamlib = require("__WePlayBeamLib__/beamlib")
local Beam = beamlib.beam

local FIRE_EFFECT = "wp-phase-disruptor-fire"   -- when the equipment starts a shot
local HIT_EFFECT = "wp-phase-disruptor-hit"     -- every damage tick of the beam
local EQUIPMENT = "wp-phase-disruptor-equipment"

local COOLDOWN = 20             -- must match data.lua
local RANGE = 15                -- must match data.lua
local DAMAGE_INTERVAL = 10      -- must match data.lua
local LINGER = math.max(COOLDOWN, DAMAGE_INTERVAL) + 4   -- ticks after the last shot or hit before letting go
local DEATH_SPARKS = 16         -- extra sparks when a target dies
local MAX_STREAMS_PER_TARGET = 8   -- cap on streams drawn from one shooter into one target
local DETAIL_BUDGET = 2          -- streams per suit that get sparks, filament, tip glow and light; the rest are just the stream
local UPDATE_INTERVAL = 2       -- redraw each stream every Nth tick; streams are staggered so the work is spread out


local TARGET_OFFSET = {0, -0.3}
local SOURCE_OFFSETS = {
  character = {0, -1.31439},    -- same as the vanilla personal laser defense
  car = {0, -0.6},
  ["spider-vehicle"] = {0, -1.0},
}
local DEFAULT_SOURCE_OFFSET = {0, -0.6}

-- Crossing the streams ------------------------------------------------------
-- When streams from two different shooters (players, vehicles) lock onto the
-- same target, it blows up. Total protonic reversal.
local CROSS_SETTING = "wp-phase-disruptor-cross-streams"
local SINGLE_SETTING = "wp-phase-disruptor-single-stream"
local CROSS_RADIUS = 6          -- tiles
local CROSS_DAMAGE = 600        -- explosion damage at the center, less toward the edge
local CROSS_COOLDOWN = 180      -- ticks before the same target can blow up again
local CROSS_EXTRA_BLASTS = 6    -- smaller explosions scattered around the big one
local CROSS_SPARKS = 40         -- spark burst on every stream involved
local BIG_BLASTS = {"massive-explosion", "big-explosion", "medium-explosion"}
local SMALL_BLASTS = {"big-explosion", "medium-explosion", "explosion"}

-- Look --------------------------------------------------------------------
local function stream_options()
  local opts = beamlib.presets.proton()
  opts.sound = {
    start = "wp-phase-disruptor-start",
    loop = {"wp-phase-disruptor-loop-1", "wp-phase-disruptor-loop-2", "wp-phase-disruptor-loop-3"},
    stop = "wp-phase-disruptor-stop",
    start_ticks = 78,   -- first hum chunk starts as the 1.45 s ignition fades out
    loop_ticks = 53,    -- 1 s chunks with 0.12 s soft edges overlap by their fades
    volume = 1,
  }
  return opts
end
-----------------------------------------------------------------------------

local on_tick

local function sync()
  if storage.by_source and next(storage.by_source) then
    script.on_event(defines.events.on_tick, on_tick)
  else
    script.on_event(defines.events.on_tick, nil)
  end
end

local function has_disruptor(entity)
  local ok, grid = pcall(function() return entity.grid end)
  if not (ok and grid) and entity.type == "character" then
    ok, grid = pcall(function()
      local armor = entity.get_inventory(defines.inventory.character_armor)
      return armor and armor[1] and armor[1].valid_for_read and armor[1].grid
    end)
  end
  if not (ok and grid) then return false end
  local ok2, count = pcall(grid.count, EQUIPMENT)
  return ok2 and count and count > 0
end

local function plausible_shooter(entity, target)
  return entity and entity.valid and entity ~= target and entity.unit_number
    and entity.type ~= "beam" and entity.surface == target.surface
end

-- Who fired? The trigger system doesn't always report what you'd expect, so
-- check both reported entities, then fall back to the nearest equipped
-- character or vehicle in range.
local function find_shooter(event, target)
  -- (not ipairs: it would stop at a nil source_entity and never see cause_entity)
  local candidates = {event.source_entity, event.cause_entity}
  for i = 1, 2 do
    local candidate = candidates[i]
    if plausible_shooter(candidate, target) and candidate.force ~= target.force then
      return candidate
    end
  end
  local best, best_d
  local tp = target.position
  local found = target.surface.find_entities_filtered{
    position = tp, radius = RANGE + 4,
    type = {"character", "car", "spider-vehicle"},
  }
  for _, e in pairs(found) do
    if e.force ~= target.force and has_disruptor(e) then
      local p = e.position
      local d = (p.x - tp.x) ^ 2 + (p.y - tp.y) ^ 2
      if not best_d or d < best_d then best, best_d = e, d end
    end
  end
  return best
end

-- How many of this shooter's live streams have full detail.
local function full_detail_count(list)
  local n = 0
  for _, entry in ipairs(list) do
    if not entry.lite and not entry.beam.released then n = n + 1 end
  end
  return n
end

local function new_entry(source, target, tick, silent, list)
  local opts = stream_options()
  -- Lite streams are just the glowing stream: no sparks, filament, tip glow or
  -- light. Extra streams on a target that already has one are always lite
  -- (and silent, the hum is already playing); past the detail budget, new
  -- streams on other targets are lite too.
  local lite = silent or (list and full_detail_count(list) >= DETAIL_BUDGET)
  if lite then opts.sparks, opts.helix, opts.tip, opts.light = nil, nil, nil, nil end
  if silent then opts.sound = nil end
  storage.next_phase = ((storage.next_phase or 0) + 1) % UPDATE_INTERVAL
  opts.surface = source.surface
  opts.source = source
  opts.source_offset = SOURCE_OFFSETS[source.type] or DEFAULT_SOURCE_OFFSET
  opts.target = target
  opts.target_offset = TARGET_OFFSET
  return {source = source, target = target, last = tick, silent = silent or nil, lite = lite or nil,
          phase = storage.next_phase, beam = Beam.new(opts)}
end

local function on_fire(event)
  local effect = event.effect_id
  if effect ~= FIRE_EFFECT and effect ~= HIT_EFFECT then return end
  local target = event.target_entity
  if not (target and target.valid) then return end
  local tick = event.tick

  -- A hit on a target we're already drawing: keep its streams alive (cheap
  -- path, no shooter lookup). Several disruptors in one suit usually pick the
  -- same target, and the game doesn't say which piece fired, so we count hits
  -- per damage window: N hits = N beams = N streams.
  -- (If several shooters are on the same target we can't tell whose beam hit,
  -- so all their streams get refreshed.)
  if effect == HIT_EFFECT then
    local id = target.unit_number
    local wanted = 1
    if id then
      local h = storage.hits[id]
      if not h or tick - h.start >= DAMAGE_INTERVAL then
        h = {start = tick, n = 0, prev = h and (tick - h.start < 2 * DAMAGE_INTERVAL) and h.n or 0}
        storage.hits[id] = h
      end
      h.n = h.n + 1
      wanted = math.min(MAX_STREAMS_PER_TARGET, math.max(h.n, h.prev))
    end
    if settings.global[SINGLE_SETTING].value then wanted = 1 end
    local found, found_list, found_source = 0, nil, nil
    for _, list in pairs(storage.by_source) do
      for _, entry in ipairs(list) do
        if entry.target == target and not entry.beam.released then
          found = found + 1
          if found <= wanted then entry.last = tick end  -- extras beyond the count fade out
          found_list, found_source = found_list or list, found_source or entry.source
        end
      end
    end
    if found > 0 then
      if found < wanted and found_source and found_source.valid then
        found_list[#found_list + 1] = new_entry(found_source, target, tick, true, found_list)
      end
      return
    end
  end

  local source = find_shooter(event, target)
  if not source then return end
  local key = source.unit_number
  local list = storage.by_source[key]
  if not list then
    list = {}
    storage.by_source[key] = list
  end

  -- Already on this target: keep it alive.
  for _, entry in ipairs(list) do
    if entry.target == target and not entry.beam.released then
      entry.last = tick
      return
    end
  end
  -- A beam from this shooter that has let go or missed a shot swings over.
  -- Only full-detail streams do this; lite and silent ones just fade out, and
  -- the next new stream gets whatever detail budget is free.
  for _, entry in ipairs(list) do
    if not entry.silent and not entry.lite and (entry.beam.released or tick - entry.last > COOLDOWN + 2
        or not (entry.target and entry.target.valid)) then
      Beam.set_target(entry.beam, target, TARGET_OFFSET)
      entry.target = target
      entry.last = tick
      return
    end
  end
  -- Otherwise (several disruptors on one shooter), a new stream.
  list[#list + 1] = new_entry(source, target, tick, false, list)
  sync()
end

local function first_existing(names)
  for _, name in ipairs(names) do
    if prototypes.entity[name] then return name end
  end
end

local function cross_streams(target, entries, tick)
  local surface = target.surface
  local pos = target.position
  storage.cross_cooldown[target.unit_number] = tick + CROSS_COOLDOWN

  for _, entry in ipairs(entries) do Beam.spark_burst(entry.beam, CROSS_SPARKS) end

  local big = first_existing(BIG_BLASTS)
  local small = first_existing(SMALL_BLASTS)
  if big then surface.create_entity{name = big, position = pos} end
  if small then
    for _ = 1, CROSS_EXTRA_BLASTS do
      local a = math.random() * 2 * math.pi
      local r = 1 + math.random() * (CROSS_RADIUS - 2)
      surface.create_entity{name = small, position = {x = pos.x + math.cos(a) * r, y = pos.y + math.sin(a) * r}}
    end
  end

  for _, e in pairs(surface.find_entities_filtered{position = pos, radius = CROSS_RADIUS}) do
    if e.valid and e.is_entity_with_health then
      local p = e.position
      local d = math.sqrt((p.x - pos.x) ^ 2 + (p.y - pos.y) ^ 2)
      local amount = CROSS_DAMAGE * (1 - 0.7 * math.min(1, d / CROSS_RADIUS))
      pcall(e.damage, amount, "neutral", "explosion")
    end
  end
end

-- Finds targets that streams from two or more different shooters are on.
local function check_crossings(tick)
  if not settings.global[CROSS_SETTING].value then return end
  local on_target = {}
  for key, list in pairs(storage.by_source) do
    for _, entry in ipairs(list) do
      local target = entry.target
      if not entry.beam.released and target and target.valid and target.unit_number then
        local t = on_target[target.unit_number]
        if not t then
          t = {target = target, sources = {}, count = 0, entries = {}}
          on_target[target.unit_number] = t
        end
        if not t.sources[key] then
          t.sources[key] = true
          t.count = t.count + 1
        end
        t.entries[#t.entries + 1] = entry
      end
    end
  end
  for id, t in pairs(on_target) do
    if t.count >= 2 and (storage.cross_cooldown[id] or 0) <= tick then
      cross_streams(t.target, t.entries, tick)
    end
  end
  -- forget expired cooldowns and old hit counts now and then
  if tick % 600 == 0 then
    for id, until_tick in pairs(storage.cross_cooldown) do
      if until_tick <= tick then storage.cross_cooldown[id] = nil end
    end
    for id, h in pairs(storage.hits) do
      if tick - h.start > 600 then storage.hits[id] = nil end
    end
  end
end

on_tick = function(event)
  local tick = event.tick
  check_crossings(tick)
  for key, list in pairs(storage.by_source) do
    for i = #list, 1, -1 do
      local entry = list[i]
      local beam = entry.beam
      local source = entry.source
      if not (source and source.valid and source.surface == beam.surface) then
        Beam.destroy(beam)
        table.remove(list, i)
      elseif (tick + (entry.phase or 0)) % UPDATE_INTERVAL == 0 then
        local _, _, target_ok = Beam.update(beam, tick)
        if not beam.released then
          if not target_ok then
            Beam.spark_burst(beam, DEATH_SPARKS)
            Beam.release(beam)
          elseif tick - entry.last > LINGER then
            Beam.release(beam)
          end
        elseif Beam.is_idle(beam) then
          Beam.destroy(beam)
          table.remove(list, i)
        end
      end
    end
    if #list == 0 then storage.by_source[key] = nil end
  end
  if not next(storage.by_source) then sync() end
end

script.on_event(defines.events.on_script_trigger_effect, on_fire)

script.on_init(function()
  storage.by_source = {}
  storage.cross_cooldown = {}
  storage.hits = {}
end)

script.on_configuration_changed(function()
  storage.by_source = storage.by_source or {}
  storage.cross_cooldown = storage.cross_cooldown or {}
  storage.hits = storage.hits or {}
  -- Streams saved by older versions use old drawing settings; clear them out.
  -- They come straight back on the next hit with the current settings.
  for _, list in pairs(storage.by_source) do
    for _, entry in ipairs(list) do Beam.destroy(entry.beam) end
  end
  storage.by_source = {}
  sync()
end)

script.on_load(sync)
