# CLAUDE.md — Rato's AI Overhaul

## Estrutura do workspace

### Source do jogo (somente leitura — apenas referência de API)
- `C:\Steam\steamapps\common\Jagged Alliance 3\ModTools\Src`
  - IA: `Lua/Tactical/CombatAI.lua` (núcleo), `AIBehaviors.lua`, `AIActions.lua`,
    `AIBase.lua` (bias), `AITactics.lua`, `CombatCamera.lua` (`AIExecutionController`)
  - Presets: `Data/ClassDef-AI.lua`, `Data/AIArchetype.lua`

### Bibliotecas de dependência (somente leitura — apenas referência)
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\ja3_commonlib`
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Zulib Weapons Core`

### Mods do autor
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Rato's AI Overhaul` — este mod
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Rato-s-Gameplay-Balance-and-Overhaul-3` — GBO3, dependência dura
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Rato-s-Explosive-Overhaul-2.0`
- `C:\Users\Lucas\AppData\Roaming\Jagged Alliance 3\Mods\Rato-s-ToG-Compatibility-Patch---Rebalance`

## O que é este mod
Overhaul da IA inimiga (id `RATOAI`, v1.12). Faz a IA usar as mecânicas do GBO3
(recoil, shooting stance, hipfire/snapshot, point blank, bolt action) sob as **mesmas
regras do jogador** — sem cheats de AP. Depende de **GBO3 ≥ 3.51** e **JA3_CommonLib ≥ 1.5**.
Integração opcional com CUAE (loot/armas dos inimigos).

## Documentação interna (ler ANTES de mexer no scoring)
| Arquivo | Conteúdo |
|---|---|
| `AI_SYSTEM_GUIDE.md` | Pipeline completo do turno da IA; os 4 tipos de score; `best_dest` vs `ai_destination`; `OptLocWeight`; `AIDecisionThreshold`. **Ponto de partida.** |
| `WEIGHTS_AUDIT.md` | Auditoria de magnitude numérica dos pesos. Status B1–B8 / M1–M7 (o que foi aplicado e o que é calibragem pendente). |
| `SEEKCOVER_GUIDE.md` | Leitura linha a linha de `AIPOLICYPOS_CustomSeekCover.lua`. |
| `SIGNATURE_POSITIONING_GAP.md` | Investigação: o scoring de posição é cego às signature actions. |
| `PERF_PLAN.md` / `PERF_CHANGES.md` | Gargalos de performance e os patches C1–C12 (C10 e Fase 2 não aplicados). |

## Estrutura do `Code/` — prefixo = tipo de override
| Prefixo | Papel |
|---|---|
| `SOURCE_*` | Substituem funções globais do source (`AIScoreDest`, `AISelectAction`, `AIPrecalcDamageScore`, `AICreateContext`, `AICalcAttacksAndAim`, `AIScoreReachableVoxels`, …) |
| `AIPOLICYPOS_*` | Novas classes `AIPositioningPolicy` (CustomSeekCover, CustomFlanking, ThreatExposure, CustomWeaponRange, GrenadeRange, MGSetup…) |
| `AIPOLICYTARG_*` | Novas classes `AITargetingPolicy` |
| `AIACTION_*` | Novas `AISignatureAction` (`ThrowFlare`, `PrepareWeapon`) |
| `FUNCTION_*` | Helpers de scoring chamados pelos presets do `items.lua` (`SignaturesCustomScoring`, `ScoreAttacksDetailed`, `ChangeEquipment`, `CustomArchetypeFunc`, os `get*BehaviorSelectionScore`) |
| `PATCH_*` | Ganchos de `OnMsg.ClassesGenerate` — `AppendClass`, defs de UnitData |
| `CONSTANTS_AI_source.lua`, `UTIL.lua`, `DEBUG.lua`, `CUAE_options.lua` | Constantes, helpers, debug visual, integração CUAE |

### Ganchos centrais
- `PATCH_AppendClass_source_classes.lua` — adiciona a property **`CustomScoring`** a toda
  `AISignatureAction`. É o gancho do redesenho de escolha de ações; também estende
  `AIPolicyHighGround`.
- `PATCH_UnitData.lua` (**gerado**, não editar à mão) + `PATCH_ChangeUnitDataDef.lua` —
  atribuem archetype, `custom_role`, stats e flags (`boost_stats`, `add_HWS`,
  `PickCustomArchetype`) por unidade. Disparados por `PATCH_call.lua`.
- `DEBUG.lua` — overlay visual; ativo só com `RATOAI_Debug` (`Platform.developer and Platform.cheats`).

## Arquétipos (definidos em `items.lua`)
Vanilla sobrescritos: `Soldier`, `HeavyGunner`, `Skirmisher`, `Brute`, `Medic`, `GuardArea`,
`PinnedDown`, `Panicked`, `Beserk`, `Scout_LastLocation`, `Pierre`, `TheMajor`.
Novos: `RATOAI_Sniper`, `RATOAI_Demolition`, `RATOAI_Rocketeer`, `RATOAI_RetreatingMarksman`.

## Regras de edição
- `items.lua` — **gerado pelo editor de mods do jogo. NUNCA editar.** Contém os presets
  (archetypes, policies, behaviors, actions, mod options) e espelha a lista de código.
  Mudança de peso/preset tem que sair pelo editor in-game.
- `metadata.lua` — não editar sem instrução explícita; a lista `code` define a **ordem de
  carregamento** e está espelhada no `items.lua` (editar um dessincroniza o outro).
- Lógica nova vai em `Code/*.lua`; presets e números vão pelo editor.
- Marcadores de rastreio no código: `---- PERF (Cx)` e `BUGFIX (Bn)` — referenciam
  `PERF_CHANGES.md` e `WEIGHTS_AUDIT.md`. Manter o padrão ao aplicar novas mudanças.
- Repositório git próprio (branches: `main`, `claude-performance-refactor`,
  `New_AiCalcAttacksAndAim`).
