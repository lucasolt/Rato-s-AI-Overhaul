# CLAUDE.md — Rato's AI Overhaul

> **Updated:** 2026-08-27 · **Mod:** v1.12 · **Verified against:** GBO3 3.60, JA3_CommonLib 1.5

## Code comments (important)

- Comments must be one line maximum and as concise as possible.
- Only comment non-obvious logic or important decisions/workarounds.
- Never narrate or restate the code.

# Language (important)

Always write the code and your messages in English, even if I speak portuguese sometimes. You use always English


## Workspace structure

### Game source (read-only — API reference only)

- `C:\Steam\steamapps\common\Jagged Alliance 3\ModTools\Src`
  - AI: `Lua/Tactical/CombatAI.lua` (core), `AIBehaviors.lua`, `AIActions.lua`,
    `AIBase.lua` (bias), `AITactics.lua`, `CombatCamera.lua` (`AIExecutionController`)
  - Presets: `Data/ClassDef-AI.lua`, `Data/AIArchetype.lua`

### Dependency libraries (read-only — reference only)

- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\ja3_commonlib`
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Zulib Weapons Core`

### Author's mods

- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Rato's AI Overhaul` — this mod
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Rato-s-Gameplay-Balance-and-Overhaul-3` — GBO3, hard dependency
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Rato-s-Explosive-Overhaul-2.0`
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Rato-s-ToG-Compatibility-Patch---Rebalance`

## What this mod is

Overhaul of enemy AI (id `RATOAI`, v1.12). Makes the AI use GBO3 mechanics
(recoil, shooting stance, hipfire/snapshot, point blank, bolt action) under the **same
rules as the player** — with no AP cheats. Depends on **GBO3 ≥ 3.51** and **JA3_CommonLib ≥ 1.5**.

Optional integration with CUAE (enemy loot/weapons).

## Commits

When you implement code changes, COMMIT them so they can identified later

## Debugging the game

See "DEBUG SERVER.md" for instructions on connecting to the debug server and retrieving realtime data from the running game.

Prefer measuring the live process over reasoning from memory or from screenshots. `tools/dap_probe.py`
evaluates Lua in the running game without a breakpoint, and `loadfile("AppData/Mods/<mod-id>/Code/
FILE.lua")` through it is a real syntax check — there is no Lua interpreter on this machine.

## Reading files

- Grep to locate before reading. Read a whole file only when it is new to the session and small
  (under ~200 lines).
- In a large file, read the slice: `Read` with `offset`/`limit` around the line Grep found.
- Do not re-read a file to verify an edit that was just applied — `Edit` would have failed loudly.
- Exception: when changing behavior rather than looking something up, read wide enough to see the
  whole call chain. A narrow read hides an early return above the match or an override below it.
  Here that usually means the `SOURCE_*` replacement together with the policy or action that
  reaches it.

## Delegating searches

Use the `ja3-source` subagent for questions answered outside this mod's `Code/` — engine APIs,
call sites in `ModTools\Src`, how GBO3 implements a mechanic the AI has to match, whether a
sibling mod reads a property, and preset or load-order lookups in any `items.lua`/`metadata.lua`.
It returns `file:line` findings instead of loading large read-only files into the main conversation.

Keep reasoning and editing in the main session. A subagent's summary is lossy, which is fine for
"where is X" and wrong for "is this logic correct".

## `Code/` structure — prefix = override type

| Prefix | Role |
|---|---|
| `SOURCE_*` | Replace global source functions (`AIScoreDest`, `AISelectAction`, `AIPrecalcDamageScore`, `AICreateContext`, `AICalcAttacksAndAim`, `AIScoreReachableVoxels`, …) |
| `AIPOLICYPOS_*` | New `AIPositioningPolicy` classes (CustomSeekCover, CustomFlanking, ThreatExposure, CustomWeaponRange, GrenadeRange, MGSetup…) |
| `AIPOLICYTARG_*` | New `AITargetingPolicy` classes |
| `AIACTION_*` | New `AISignatureAction` classes (`ThrowFlare`, `PrepareWeapon`) |
| `FUNCTION_*` | Scoring helpers called by `items.lua` presets (`SignaturesCustomScoring`, `ScoreAttacksDetailed`, `ChangeEquipment`, `CustomArchetypeFunc`, the `get*BehaviorSelectionScore` functions) |
| `PATCH_*` | `OnMsg.ClassesGenerate` hooks — `AppendClass`, UnitData definitions |
| `CONSTANTS_AI_source.lua`, `UTIL.lua`, `DEBUG.lua`, `CUAE_options.lua` | Constants, helpers, visual debug, CUAE integration |

### Core hooks

- `PATCH_AppendClass_source_classes.lua` — adds the **`CustomScoring`** property to every
  `AISignatureAction`. This is the hook for the action-selection redesign; it also extends
  `AIPolicyHighGround`.
- `PATCH_UnitData.lua` (**generated**, do not edit manually) + `PATCH_ChangeUnitDataDef.lua` —
  assign archetype, `custom_role`, stats, and flags (`boost_stats`, `add_HWS`,
  `PickCustomArchetype`) to each unit. Triggered by `PATCH_call.lua`.
- `DEBUG.lua` — visual overlay; active only with `RATOAI_Debug` (`Platform.developer and Platform.cheats`).

## Archetypes (defined in `items.lua`)

Vanilla overrides: `Soldier`, `HeavyGunner`, `Skirmisher`, `Brute`, `Medic`, `GuardArea`,
`PinnedDown`, `Panicked`, `Beserk`, `Scout_LastLocation`, `Pierre`, `TheMajor`.

New: `RATOAI_Sniper`, `RATOAI_Demolition`, `RATOAI_Rocketeer`, `RATOAI_RetreatingMarksman`.

## Editing rules

- `items.lua` — generated by the game's mod editor. Contains the presets (archetypes, policies,
  behaviors, actions, mod options) and mirrors the code list.
  **Presets and numbers must continue to be produced only through the in-game editor — never edit them manually.**
  **Exception, authorized on 2026-08-27: registering a new code file.** When creating a
  `Code/*.lua`, add the corresponding block following the pattern already present in the file:
  ```lua
  PlaceObj('ModItemCode', {
      'name', "FILE_NAME",          -- without .lua
      'CodeFileName', "Code/FILE_NAME.lua",
  }),
  ```
  (`'comment'` is optional and some blocks use it.) The position must mirror the one in the
  `code` list in `metadata.lua` — the two are the **same load order**, and desynchronizing them
  breaks loading. The same applies to GBO3 and the author's other mods, which use `items.lua`
  in the same format.

- `metadata.lua` — the `code` list defines the **load order** and is mirrored in `items.lua`.
  Registering a new code file here is allowed (see above); **both files must be updated together**,
  in the same position. Any other modification requires explicit instruction.

- New logic goes in `Code/*.lua`; presets and numbers are produced through the editor.

- **Arithmetic: always use `MulDivRound`, never floats.** This engine runs Lua 5.3 with the
  `/` operator **replaced by integer truncating division** — measured in the live process.

- **Constants and switches live in `const.RATOAI`, never as standalone globals.**
  The old pattern — `if rawget(_G, "RATOAI_X") == nil then RATOAI_X = <default> end` — did **not
  work**: measured in the live process, `rawget(_G, ...)` returns `nil` even when the global is
  defined, because in this engine globals live behind `_G`'s `__index` (the same mechanism
  behind `[mod] Ignored assert: Attempt to use an undefined global`). The condition was always
  true, so the value was reset to the default on every load, and the "let the user predefine it"
  behavior never worked. Worse, this also affected reads: the `RATOAI_DebugForce` switch entered
  in the console was never seen (BUGFIX B32).

  `const` is a regular table — `const.RATOAI.X` can be read and written normally, both from the
  console and DAP, and the `== nil` test once again means what it says. Definitions belong next
  to the code they affect (with `const.RATOAI = const.RATOAI or {}` at the top of the file);
  only general tunables belong in `CONSTANTS_AI_source.lua`.

  Two documented exceptions:
  - `RATOAI_Debug` — state recomputed in `CombatStart` and read in a hot loop as
    `local trace = RATOAI_Debug`.
  - `RATOAI_LastExpected` — data storage, not configuration.

- **Creating a global at runtime is a runtime error.** The engine only allows globals during load;
  at runtime it raises `Attempt to create a new global` and aborts the action in progress. A new
  global must be declared at file scope; `rawset(_G, ...)` bypasses `__newindex`, but it is a
  hack, not a solution.

- **Do not write global guards.**

- **Never use the identifier `dbg`** (variable, table key, or mentioned in a comment) in
  `Code/*.lua`.

  *Cause:* `dbg = empty_func -- WILL BE REMOVED IN GOLD MASTER`
  (`CommonLua/Core/lib.lua:32`).

  `dbg(...)` is the engine's idiom for dev-only expressions, and the build step that removes it
  in the Gold Master **is not Lua-aware**: it finds the token, searches for the next `(`, and
  removes text up to the corresponding `)` — which may be far away. Since this mod never called
  `dbg(...)`, it only used `dbg` as a name, but the pruning started in the wrong place. It has
  already corrupted unrelated comments that had nothing to do with debugging.

- **GBO3 is also authored by me and may be modified.** It is not an untouchable dependency:
  if changing something there (exposing a value, splitting a function into two, making a calculation
  queryable without side effects) simplifies or reduces the cost on the AI side, **suggest the
  change there** instead of working around it here. The same applies to the
  `Rato-s-ToG-Compatibility-Patch` and `Rato-s-Explosive-Overhaul-2.0`.

  The boundary should still remain explicit: changes to GBO3 directly affect the player, so state
  what changes for the player, not just for the AI.