local beamdata = require("__WePlayBeamLib__/datalib")

-- Balance knobs ------------------------------------------------------------
local RANGE = 15             -- tiles
local COOLDOWN = 20          -- ticks between "shots"; each shot's beam lasts exactly this long, so the stream is continuous
local DAMAGE = 12            -- electric damage per hit
local DAMAGE_INTERVAL = 10   -- ticks between hits while the beam is on a target (12 every 10 ticks = 72 DPS before bonuses)
local ENERGY_PER_SHOT = "60kJ"   -- 60 kJ every 20 ticks = 180 kW while firing
local BUFFER = "600kJ"
-----------------------------------------------------------------------------

local NAME = "wp-phase-disruptor"
local GFX = "__WePlayPhaseDisruptor__/graphics/"

-- Damage beam: does the damage, draws nothing. The stream you see is drawn
-- by control.lua with the beam library.
local damage_beam = {
  type = "beam",
  name = NAME .. "-beam",
  flags = {"not-on-map"},
  hidden = true,
  width = 0.5,
  damage_interval = DAMAGE_INTERVAL,
  graphics_set = beamdata.invisible_beam_graphics(),
  action = {
    type = "direct",
    action_delivery = {
      type = "instant",
      target_effects = {
        {type = "damage", damage = {amount = DAMAGE, type = "electric"}},
        -- every hit keeps the visible stream alive (the shooter may hold one
        -- damage beam on a target for a long time without "firing" again)
        {type = "script", effect_id = NAME .. "-hit"},
      },
    },
  },
}

local equipment = {
  type = "active-defense-equipment",
  name = NAME .. "-equipment",
  sprite = {filename = GFX .. "equipment.png", width = 128, height = 128, priority = "medium", scale = 0.5},
  shape = {width = 2, height = 2, type = "full"},
  energy_source = {
    type = "electric",
    usage_priority = "secondary-input",
    buffer_capacity = BUFFER,
  },
  attack_parameters = {
    type = "beam",
    cooldown = COOLDOWN,
    range = RANGE,
    damage_modifier = 1,
    ammo_category = "laser",  -- laser damage and shooting speed research apply
    ammo_type = {
      energy_consumption = ENERGY_PER_SHOT,
      action = {
        -- 1. the invisible damage beam
        {
          type = "direct",
          action_delivery = {
            type = "beam",
            beam = NAME .. "-beam",
            max_length = RANGE + 3,
            duration = COOLDOWN,
            source_offset = {0, -1.31439},
          },
        },
        -- 2. tell control.lua who fired at what, so it can draw the stream
        {
          type = "direct",
          action_delivery = {
            type = "instant",
            target_effects = {
              {type = "script", effect_id = NAME .. "-fire"},
            },
          },
        },
      },
    },
  },
  automatic = true,
  categories = {"armor"},
}

local item = {
  type = "item",
  name = NAME .. "-equipment",
  icon = GFX .. "icon.png",
  icon_size = 64,
  place_as_equipment_result = NAME .. "-equipment",
  subgroup = "military-equipment",
  order = "b[active-defense]-b[wp-phase-disruptor]",
  stack_size = 20,
}

local recipe = {
  type = "recipe",
  name = NAME .. "-equipment",
  enabled = false,
  energy_required = 10,
  ingredients = {
    {type = "item", name = "personal-laser-defense-equipment", amount = 1},
    {type = "item", name = "processing-unit", amount = 10},
    {type = "item", name = "battery", amount = 20},
  },
  results = {{type = "item", name = NAME .. "-equipment", amount = 1}},
}

local technology = {
  type = "technology",
  name = NAME,
  icon = GFX .. "technology.png",
  icon_size = 256,
  effects = {{type = "unlock-recipe", recipe = NAME .. "-equipment"}},
  prerequisites = {"personal-laser-defense-equipment"},
  unit = {
    count = 300,
    ingredients = {
      {"automation-science-pack", 1},
      {"logistic-science-pack", 1},
      {"military-science-pack", 1},
      {"chemical-science-pack", 1},
      {"utility-science-pack", 1},
    },
    time = 30,
  },
}

-- Sounds, cut from Laser_Beam_01.wav. Played by control.lua through the beam
-- library: start once, loop chunks overlapping every 53 ticks, stop on release.
local SND = "__WePlayPhaseDisruptor__/sound/"
local function sound(name, file, volume)
  return {type = "sound", name = NAME .. "-" .. name, filename = SND .. file, volume = volume}
end

data:extend{
  damage_beam, equipment, item, recipe, technology,
  sound("start", "start.ogg", 0.55),
  sound("loop-1", "loop-1.ogg", 0.45),
  sound("loop-2", "loop-2.ogg", 0.45),
  sound("loop-3", "loop-3.ogg", 0.45),
  sound("stop", "stop.ogg", 0.5),
}
