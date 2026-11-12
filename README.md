# WePlay: Phase Disruptor

Armor equipment for Factorio 2.1 that locks wild, wandering energy streams onto nearby enemies. Just don't cross the streams.

![Phase Disruptor in action](https://i.imgur.com/RnE7rNK.gif)

- **Mod portal:** https://mods.factorio.com/mod/WePlayPhaseDisruptor
- **Requires:** [WePlay: Beam Library](https://mods.factorio.com/mod/WePlayBeamLib) ([source](https://github.com/afewvowels/WePlayBeamLib)) ≥ 0.6.1

## What it does

- A 2x2 armor module that automatically fires at enemies within 15 tiles, like personal laser defense.
- 12 electric damage every 10 ticks per stream (72 per second), boosted by laser damage and shooting speed research.
- Powered by your suit: 180 kW while firing, 600 kJ buffer per module.
- Each stream wanders through smoothed, swaying waypoints, with a blue filament coiling around it, a glowing tip, a light and impact sparks. Streams shoot out from the emitter, swing over to new targets, and let go with a spark burst when a target dies.
- Every module draws its own stream. Streams from the same suit are in phase and safe to cross.
- **Crossing the streams:** when streams from two *different* emitters (two players, or a player and their spidertron) lock onto the same target, it explodes.
- Sound: an ignition burst, a seamless crackling hum and a power-down.

Unlocked by the **Phase disruptor** technology after Personal laser defense. Recipe: 1 personal laser defense, 10 processing units, 20 batteries.

## Map settings

| Setting | Default | |
|---|---|---|
| `wp-phase-disruptor-cross-streams` | on | Crossing the streams explosion |
| `wp-phase-disruptor-single-stream` | off | Draw one stream per suit per target, however many modules are hitting it |

Both are runtime-global, so they can be changed mid-game.

## How it works

Factorio draws beams as straight strips, so the visible stream is drawn by script and the game's own beam only does the damage.

### Data stage (`data.lua`)

- **`active-defense-equipment`** with `beam` attack parameters (cooldown 20 ticks, range 15, `ammo_category = "laser"`). Each shot runs two actions:
  1. An invisible damage beam, `wp-phase-disruptor-beam` (graphics from `beamdata.invisible_beam_graphics()`). Its target effects deal the damage and fire the `wp-phase-disruptor-hit` script trigger every damage tick.
  2. A `wp-phase-disruptor-fire` script trigger on the target.
- Sound prototypes for the start, three loop chunks and the stop.
- Item, recipe and technology.

### Runtime (`control.lua`)

- **Who fired at what.** `on_script_trigger_effect` gives the target. The shooter is `source_entity` or `cause_entity` when either is plausible; otherwise the nearest character or vehicle with a disruptor in range is used.
- **Keeping streams alive.** The game can hold one damage beam on a target for a long time without firing again, so streams are refreshed by the per-damage-tick **hit** trigger, not just the fire trigger. A stream lets go 24 ticks after its last shot or hit.
- **One stream per beam.** The game doesn't say which module fired, so hits on a target are counted per 10-tick damage window: N hits means N beams, so N streams (capped at 8). Extra streams on the same target are silent and skip sparks, filament, tip glow and light.
- **Detail budget.** The first 2 streams per suit get full detail; any more are just the stream.
- **Retargeting.** When a shooter's stream has let go or missed a shot, it swings over to the new target instead of a new stream being created.
- **Crossing the streams.** Each tick, targets with streams from two or more shooters explode (massive explosion plus scattered smaller ones, up to 600 damage in 6 tiles with falloff), with a 3-second cooldown per target.
- **Performance.** Streams redraw every other tick, staggered so half update on even ticks and half on odd. Typical cost on a test map: about 0.2–0.3 ms for one stream, 0.3–0.5 ms for eight over a biter base.

All drawing (paths, wander, helix filament, sparks, sound timing) comes from [WePlay: Beam Library](https://github.com/afewvowels/WePlayBeamLib); see its README for the API.

### Tuning knobs

At the top of `control.lua`:

| Constant | Default | |
|---|---|---|
| `COOLDOWN`, `RANGE`, `DAMAGE_INTERVAL` | 20, 15, 10 | must match `data.lua` |
| `LINGER` | 24 | ticks after the last shot or hit before a stream lets go |
| `MAX_STREAMS_PER_TARGET` | 8 | |
| `DETAIL_BUDGET` | 2 | full-detail streams per suit |
| `UPDATE_INTERVAL` | 2 | redraw every Nth tick |
| `CROSS_RADIUS`, `CROSS_DAMAGE`, `CROSS_COOLDOWN` | 6, 600, 180 | crossing explosion |

The look itself (colors, wander, filament, sparks, grow speed) is `beamlib.presets.proton()` plus the sound settings in `stream_options()`. Damage, power and range are at the top of `data.lua`.

## Files

```
control.lua        stream tracking, crossing explosions
data.lua           equipment, damage beam, sounds, item, recipe, technology
settings.lua       map settings
locale/en/         English strings
graphics/          icon, equipment sprite, technology icon
sound/             start, loop-1..3, stop (.ogg)
```

## Credits

- Inspired by the proton packs from *Ghostbusters*. This is a fan tribute and is not affiliated with or endorsed by Sony Pictures.
- The equipment icon was made with AI image generation (Grok).
- Sounds were cut from "Laser Beam 01" (SOUND_SOURCE_HERE).

## License

Code is released under the [Unlicense](https://unlicense.org/). The sound files are not covered by the Unlicense and stay under their original licence.
