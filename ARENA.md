# Arena — AI vs AI matches and weight evolution

Two AI teams fight without a human. One side may run mutated policy weights; the winner is
decided by a fitness number, and a Python loop breeds the next generation.

- Game side: `Rato Dev/Code/RATOARENA_AIvsAI.lua` (`RatoArena_*` functions).
- Driver: `tools/arena.py` (`saves`, `space`, `match`, `report`, `evolve`), talks to the running
  game over DAP for you (see `DEBUG SERVER.md` only if something breaks).
- Output: `arena/` (git-ignored) — `results.jsonl`, `space/<archetype>.json`,
  `evolve/<run>/{state.json,generations.jsonl}`.

## 0. Everything from the game console

Press **Enter** (or Alt-Shift-C) in the dev build and type Lua. No Python, no DAP:

```lua
RatoArena_Census("enemy1")                 -- what archetypes a side is made of
RatoArena_Saves("arena")                   -- savegame names, filtered
RatoArena_Start({max_turns = 12})          -- fight right now, on the map you are on
RatoArena_Print()                          -- progress, then the full result
RatoArena_Stop()                           -- end early, give control back
```

`RatoArena_Run` is the loop: it reloads the save before every match, so each one starts from the
same state. This is what makes scores comparable.

```lua
RatoArena_Run({save = "ratoarena save.savegame.sav", matches = 3, max_turns = 12,
               time_factor = 3000, label = "baseline"})
RatoArena_Report()                         -- mean and spread per label
RatoArena_Abort()                          -- stop after the current match
```

And evolution, also in the console:

```lua
RatoArena_Evolve({save = "ratoarena save.savegame.sav", side = "enemy1",
                  archetypes = {"Soldier"}, pop = 6, gens = 10, repeats = 2,
                  max_turns = 12, time_factor = 3000})
RatoArena_PrintGenome()                    -- best genome so far, as pasteable Lua
```

Progress prints to the console *and* to the game log, so a long run leaves a record. A genome
lives in memory only: `RatoArena_PrintGenome()` is how a winner survives the session — copy it
out of the console or the log.

The Python driver (`tools/arena.py`) does the same things from a terminal and additionally writes
`arena/*.jsonl` for later analysis. It is optional; the console covers the whole workflow.

## 1. Setup, once

1. Run `JA3Debug.exe` — the console and the debug port only exist there.
2. Get into the combat you want as the arena, then **save**. Every match reloads that save, so it
   is the whole experiment: map, squads, gear, positions.
3. `RatoArena_Saves("arena")` prints the exact name to pass as `save = "..."`.

### Choosing the save — this decides what you measure

- **No scripted boss fights.** H4 (Pierre) rewrites archetypes mid-fight: mercs standing in its
  yard areas became `GuardArea`. H2/Erny-style ordinary sector fights are fine.
- **Save at the start of a turn**, with both sides already aware of each other. Combat ends when
  no aware enemy is left, and an unaware side just ends the match early.
- **Balanced-ish sides.** A 5-vs-9 slaughter scores the same for every genome; you learn nothing.
- **Short and decisive beats long.** Every turn is real time (~45 s at `--time-factor 3000`).

## 1b. Composition — make every archetype show up

A save whose enemies are all `Soldier` only ever exercises one archetype's weights. Check what a
side actually is, then fill the gaps:

```bash
python tools/arena.py compose --side enemy1 --dry
python tools/arena.py compose --side enemy1
```

(console equivalents: `RatoArena_Census("enemy1")`, `RatoArena_Compose("enemy1", {dry = true})`,
`RatoArena_Compose("enemy1")`.)

It spawns one **real unit type** per missing archetype, drawn from the faction already fighting —
`LegionSniper` for `RATOAI_Sniper`, `LegionRocketeer` for the rocketeer, and so on — so the gear
and stats match the archetype. Relabelling a shotgunner as a sniper would only produce nonsense.
Turrets, artillery, beasts and scripted-boss archetypes are skipped.

**Then save the game, and point `--save` at that savegame.** The spawns live in the running
session only; every match reloads the save, so an unsaved composition is lost.

`--remove N` despawns N units of the most common archetype first, to keep team size (and the
balance) where it was. `--family Adonis` draws from another faction.

### A target ratio instead

`compose` fills gaps; `mix` reconciles a side to a ratio, spawning and despawning as needed:

```bash
python tools/arena.py mix --side enemy1 --size 14 --pct Soldier=50,Skirmisher=30   --utility HeavyGunner,RATOAI_Sniper,RATOAI_Demolition --dry
```

Percentages are taken first; what's left of `--size` is split round-robin over `--utility`, in
priority order. Any archetype named in neither list is despawned, so the side ends up exactly as
described. The console form is `RatoArena_Mix("enemy1", {size = 14, pct = {...}, utility = {...}})`.

A ratio and "one of every archetype" fight each other on a small team: six utility archetypes at
20% needs 30 units. Either accept a shortlist (the default three) or raise `--size`.

Note `PickCustomArchetype`: several unit types switch to a close-range archetype when enemies get
near (a sniper becomes `RATOAI_RetreatingMarksman`). The census reports what a unit *is*; what it
plays as can differ per turn, by design.

## 2. See the genes

```bash
python tools/arena.py space Soldier RATOAI_Sniper
```

Writes `arena/space/<archetype>.json`: every numeric property reachable from the archetype, as
`{"p": path, "v": current, "min", "max"}`. A path addresses one number:

```
Behaviors/Standard#1/EndTurnPolicies/AIPolicyDealDamage#1/Weight
OptLocPolicies/AIPolicyHighGround#1/Weight
SignatureActions/AIActionThrowGrenade#1/Weight
```

`#n` is the occurrence of that class in the list (the Soldier has two `AIPolicyDealDamage`, soft
and to-kill). Behaviors are addressed by `BiasId` when they have one. Soldier: 119 numeric genes,
22 of them `Weight`.

A genome is a JSON file, only the genes you override:

```json
{ "Soldier": { "Behaviors/Standard#1/EndTurnPolicies/AIPolicyThreatExposure#1/Weight": 150 } }
```

Genomes are applied per side through a copy of the archetype. The presets in `items.lua` are
never written, and the other side keeps the shipped numbers.

## 3. One match

```bash
python tools/arena.py match --side enemy1 --save "arena.savegame.sav" --max-turns 12 --time-factor 3000
python tools/arena.py match --side enemy1 --genome arena/my_genome.json --save "arena.savegame.sav"
```

Console: `RatoArena_Run({save = "...", matches = 1, max_turns = 12, time_factor = 3000})`.

It loads the save, applies the genome, hands every human team to the AI, prints the turn-by-turn
status, and appends a record to `arena/results.jsonl`. Each record has, per side: `hp0`/`hp`,
`dead`, `down`, `alive`, `dealt`, `friendly`, `attacks`, `kills`, plus one row per unit.

Unknown gene paths abort the match instead of being ignored — a typo can't silently evaluate the
baseline and look like a null result.

### Fitness

From `--side`'s point of view, higher is better:

```
100 * (fraction of enemy HP removed  - fraction of own HP lost)
100 * (fraction of enemies taken out - fraction of own taken out)
 +50 win / -50 loss    (a turn-cap draw scores 0 here)
```

HP and casualties are read from the units at the end, not accumulated during the fight, because a
unit that bleeds out has no killer and would not be counted otherwise. Most capped matches end as
a draw; the HP terms are what separate genomes.

## 4. Measure the noise before you trust anything

Combat is random. **Run the baseline three or four times before evolving:**

```bash
for i in 1 2 3; do python tools/arena.py match --side enemy1 --save "arena.savegame.sav" --max-turns 12 --time-factor 3000 --label baseline; done
python tools/arena.py report --side enemy1
```

Console: `RatoArena_Run({..., matches = 3, label = "baseline"})`, then `RatoArena_Report()`.

Both print, per label: number of matches, mean fitness, and the spread between best and worst.

The spread is your noise floor. A genome that beats the baseline by less than that spread has
proven nothing — raise `--repeats`, or pick a save whose outcome is less swingy. This is the whole
experiment: without it, evolution just selects for lucky rolls.

## 5. Evolve

```bash
python tools/arena.py evolve --run soldier1 --side enemy1 --archetypes Soldier \
  --save "arena.savegame.sav" --pop 6 --gens 10 --repeats 2 --max-turns 12 --time-factor 3000
```

Console: `RatoArena_Evolve({save = "...", archetypes = {"Soldier"}, pop = 6, gens = 10})` — the
option names match the flags below, and `genes` is a Lua pattern (default `"Weight$"`).

Each generation: keep the `--elite` best, fill back to `--pop` by mutating an elite, evaluate
every new genome `--repeats` times, sort by mean fitness, write
`arena/evolve/<run>/generations.jsonl`. Generation 0 includes the unmutated baseline, so every
score is relative to the current weights.

Knobs that matter:

| flag | default | meaning |
|---|---|---|
| `--genes` | `/Weight$` | regex over gene paths; only matching genes mutate |
| `--rate` | 0.15 | per-gene mutation probability (at least one gene always moves) |
| `--sigma` | 25 | mutation step, percent of the gene's value |
| `--repeats` | 2 | matches per genome — raise it when the noise floor is high |
| `--pop` / `--elite` / `--gens` | 6 / 2 / 10 | population, survivors, generations |

Start with `/Weight$`: weights are the gradient the scoring system is built on, they are
comparable to each other, and a bad value degrades behavior instead of breaking it. Widening
`--genes` to tuning constants (`SoftK`, `CoverTrust`, ranges) is a much rougher search space.

**Budget:** matches ≈ `pop * repeats` per generation, minus cached elites. At ~45 s/turn and 12
turns that is roughly 9 min per match — the defaults are an overnight run. Interrupt anytime; the
same command resumes from `arena/evolve/<run>/state.json`.

## 6. Read the outcome, then promote it by hand

```bash
python tools/arena.py report --side enemy1 --run soldier1
```

It prints the generation ladder (best and all scores per generation) and the best genome so far.
In the console each generation prints its scores as it finishes, and `RatoArena_PrintGenome()`
dumps the best one as pasteable Lua — the only way a genome outlives the session.

Look for the best score climbing **and** staying above the noise floor. Then re-run the winning
genome a few times with `match` on its own; the winner of a noisy tournament is biased upward by
selection, so it usually scores lower on a fresh evaluation.

A genome is **not** a shippable change. Numbers live in presets, and per CLAUDE.md presets are
only edited through the in-game mod editor. Treat a winner as a hypothesis: read the paths it
moved, decide whether the direction makes sense (this is the same question `WEIGHTS_AUDIT.md`
asks), and type the values into the editor yourself.

## Known limits

- **A genome is tuned against one save.** It may be fitting one map, one squad and one starting
  position. Confirm a winner on a second save before believing it generalizes.
- **Asymmetry.** The evolved side plays against baseline AI on a specific map; sides are not
  mirrored. To cancel map bias, evaluate the same genome on both sides and compare.
- **Elites keep their old scores** (evaluations are cached by genome), so a lucky elite can
  survive on one good run. Raise `--repeats` if the ladder looks unstable.
- **Asserts stop everything.** In the debug build, an engine assert (e.g. `AI can't find unit free
  destination`) halts Lua and the DAP connection until someone clicks in-game — an unattended run
  dies there.
- Mercs driven by the AI use the merc archetypes; they are not tuned enemies, they are an opponent.
