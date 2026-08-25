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
| `POLICY_BUDGET.md` | Modelo matemático dos pesos de policy por arquétipo: influência = `Weight × D`, as três âncoras absolutas, `A` (agressividade) e `R_optloc`, e as regras R1–R9 para tunar. Extraído do `items.lua` atual — **é o que substitui as tabelas 13.1/13.4 do guia**. |
| `SEEKCOVER_GUIDE.md` | Leitura linha a linha de `AIPOLICYPOS_CustomSeekCover.lua`. |
| `SIGNATURE_POSITIONING_GAP.md` | Investigação: o scoring de posição é cego às signature actions. |
| `PERF_PLAN.md` / `PERF_CHANGES.md` | Gargalos de performance e os patches C1–C12 (C10 e Fase 2 não aplicados). |
| `DEBUG SERVER.md` | Console Lua no jogo rodando via DAP (`tools/dap_probe.py`, porta 8165, só `JA3Debug.exe`). |
| `AIM_AND_STANCE.md` | Mira, nº de ataques e Shooting Stance: as três moedas de AP, a árvore do `AICalcAttacksAndAim`, ciclo de vida da stance, o recoil que encarece mira. |
| `DBG_RESERVED_WORD.md` | **Ler antes de nomear qualquer variável de debug.** `dbg` é usado pelo engine (`dbg(...)`, ver `lib.lua:32`) e uma etapa de build (Gold Master) mexe no texto por causa disso — usar `dbg` como identificador em `Code/*.lua` quebra o carregamento só no executável normal (`JA3.exe`), nunca no `JA3Debug.exe`. Use `trace`. |

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
- **Aritmética: sempre `MulDivRound`, nunca float.** Esta engine roda Lua 5.3 com o
  operador `/` **substituído por divisão inteira truncada** — medido no processo vivo:
  `9900/5000 = 1`, `4999/5000 = 0`, `11/4 = 2`, e `math.type(9100/5000) == "integer"`.
  Literais decimais (`1.82`) continuam sendo float. Qualquer float que entre num caminho
  de decisão sincronizada vaza para o `NetUpdateHash` e é fonte clássica de desync — é o
  que o `BUGFIX (B7)` do `WEIGHTS_AUDIT.md` conserta em vários arquivos. Percentuais são
  inteiros: `MulDivRound(valor, pct, 100)`.
  Corolário: guardas do tipo `x = x - x % 1` ("tira a parte fracionária") são no-op depois
  de uma divisão inteira — não escreva, e desconfie das que encontrar.
- **Constantes e interruptores vivem em `const.RATOAI`, nunca em global solta.**
  O idioma antigo — `if rawget(_G, "RATOAI_X") == nil then RATOAI_X = <default> end` — **não
  funcionava**: medido no processo vivo, `rawget(_G, ...)` devolve `nil` mesmo com o global
  definido, porque neste engine os globais moram atrás do `__index` do `_G` (é o mesmo mecanismo
  dos `[mod] Ignored assert: Attempt to use an undefined global`). A condição era sempre
  verdadeira, o valor era resetado ao default em todo load, e o "deixe o usuário pré-definir"
  nunca valeu um dia. Pior, valia para leitura também: a válvula `RATOAI_DebugForce` digitada no
  console nunca foi enxergada (BUGFIX B32).
  `const` é tabela comum — `const.RATOAI.X` lê e escreve normal, no console e no DAP, e o teste
  `== nil` volta a significar o que diz. Definições ficam junto do código que afetam (com
  `const.RATOAI = const.RATOAI or {}` no topo do arquivo); só os tunables gerais moram no
  `CONSTANTS_AI_source.lua`.
  Exceção única e documentada: `RATOAI_Debug` (estado recomputado no `CombatStart` e lido em laço
  quente como `local trace = RATOAI_Debug`) e `RATOAI_LastExpected` (depósito de dados, não config).
- **Criar global em runtime é erro de execução.** O engine só permite no load — em runtime levanta
  `Attempt to create a new global` e derruba a ação em curso. Global nova se declara no escopo do
  arquivo; `rawset(_G, ...)` contorna o `__newindex` mas é gambiarra, não solução.
- **Nunca escrever guard de global.** Nada de `rawget(_G, "f") and f(...)`, nada de
  `if not _G.f then return end`, nada de checar se uma função de dependência existe antes de
  chamar. GBO3, JA3_CommonLib e Zulib são dependências **duras** — se sumirem, o mod está quebrado
  de qualquer jeito, e é melhor estourar do que degradar em silêncio. Chame nu, como o
  `rat_close_range` (`UTIL.lua`) e o `GetWeapon_StanceAP` (`AIACTION_PrepareWeapon.lua`) sempre
  fizeram. Onde a chamada de terceiro pode legitimamente explodir (conta que passa por componente
  de arma, opção de mod), o que protege é `pcall` — não um teste de existência.
  Isto não é preferência de estilo: os guards com `rawget` eram **todos** no-op pelo motivo do item
  acima, e cada um deixou um mecanismo inteiro morto sem aviso — o `BUGFIX B22` (sobretaxa de mira
  do recoil) nasceu inerte, o bônus de ferrolho nunca foi aplicado, o filtro de `CharacterEffectDefs`
  nunca filtrou. Todos removidos no `BUGFIX B34`.
  Definir global no arquivo continua permitido, desde que **fora de função** (escopo de arquivo,
  no load) — é o mesmo limite do item acima.
- Marcadores de rastreio no código: `---- PERF (Cx)`, `BUGFIX (Bn)` e `DEBUG (Dn)` —
  referenciam `PERF_CHANGES.md`, `WEIGHTS_AUDIT.md` e a seção 10 do `AI_SYSTEM_GUIDE.md`.
  Manter o padrão ao aplicar novas mudanças; conferir o maior número já usado antes de
  escolher o próximo (as listas não são contíguas).
- **Nunca use o identificador `dbg`** (variável, chave de tabela, ou mencionado em
  comentário) em `Code/*.lua` — é reservado pelo engine (`dbg(...)`, ver `lib.lua:32` e
  [[DBG_RESERVED_WORD.md]]) e quebra o carregamento do mod só no executável normal
  (`JA3.exe`), nunca no `JA3Debug.exe`, com um erro de sintaxe Lua que parece não fazer
  sentido porque o arquivo está de fato correto. Use `trace`.
- Repositório git próprio (branches: `main`, `claude-performance-refactor`,
  `New_AiCalcAttacksAndAim`).
- **O GBO3 também é do autor e pode ser modificado.** Ele não é uma dependência
  intocável: se mudar algo lá (expor um valor, quebrar uma função em duas, tornar um
  cálculo consultável sem efeito colateral) simplifica ou barateia o lado da IA, **sugira
  a mudança lá** em vez de contornar aqui. O mesmo vale para o `Rato-s-ToG-Compatibility-Patch`
  e o `Rato-s-Explosive-Overhaul-2.0`.
  Vale ainda assim manter a fronteira explícita: mudança no GBO3 afeta o jogador
  diretamente, então diga o que muda para ele, não só para a IA.
