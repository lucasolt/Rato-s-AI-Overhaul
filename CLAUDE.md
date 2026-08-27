# CLAUDE.md — Rato's AI Overhaul
 
> **Atualizado:** 2026-08-27 · **Mod:** v1.12 · **Verificado contra:** GBO3 3.51, JA3_CommonLib 1.5
 
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
| Arquivo | Papel | Conteúdo |
|---|---|---|
| `AI_SYSTEM_GUIDE.md` | explicador | Pipeline completo do turno da IA; os 4 tipos de score; `best_dest` vs `ai_destination`; `OptLocWeight`; `AIDecisionThreshold`. **Ponto de partida.** |
| `POLICY_BUDGET.md` | explicador | Modelo matemático dos pesos de policy por arquétipo: influência = `Weight × D`, as três âncoras absolutas, `A` (agressividade) e `R_optloc`, e as regras R1–R9 para tunar. Extraído do `items.lua` atual. |
| `CORRECTION_TRACKER.md` | **tracker** | Bugs de lógica/scoring: o que era, onde, e se já foi aplicado (B1–B40). Achado novo entra aqui como número novo — não como arquivo novo. |
| `PERF.md` | **tracker** | Gargalos de performance e patches C1–C14: o que foi aplicado, o que falta. Mesma regra do acima. |
| `PERF_PROFILING.md` | metodologia | Como instrumentar e medir por policy/fase. É sobre *medir*, não sobre *otimizar* — por isso separado do `PERF.md`. |
| `DEBUG SERVER.md` | ferramenta | Console Lua no jogo rodando via DAP (`tools/dap_probe.py`, porta 8165, só `JA3Debug.exe`). |
| `SIGNATURE_POSITIONING_GAP.md` | decisão em aberto | Investigação: o scoring de posição é cego às signature actions. |
 
**Regra de manutenção:** investigação nova não vira arquivo novo. Se é bug, entra como
número no `CORRECTIONS.md`; se é performance, no `PERF.md`; se é mecanismo, vira seção
num dos dois explicadores. Arquivo próprio só quando nada disso serve — e aí ele nasce
com a linha de `Atualizado:` no topo, como todos os outros.
 
Cada MD tem data no topo. Para saber se alguma está mentindo, `git log -1 --format=%ad -- ARQUIVO.md`
dá a data real da última alteração — não repliquei as datas aqui de propósito, um índice
com datas duplicadas é a coisa que mais rápido fica desatualizada.
 
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
  que o `BUGFIX (B7)` do `CORRECTIONS.md` conserta em vários arquivos. Percentuais são
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
  referenciam `PERF.md`, `CORRECTIONS.md` e a seção 10 do `AI_SYSTEM_GUIDE.md`.
  Manter o padrão ao aplicar novas mudanças; conferir o maior número já usado antes de
  escolher o próximo (as listas não são contíguas).
- **Nunca use o identificador `dbg`** (variável, chave de tabela, ou mencionado em
  comentário) em `Code/*.lua`. Use `trace`.
  *Sintoma:* erro de sintaxe Lua no `JA3.exe` (`'}' expected near ''`) num arquivo que
  está comprovadamente balanceado; comentar a linha acusada só faz o erro pular de lugar.
  O `JA3Debug.exe` **não** é afetado, o que faz o bug parecer impossível até comparar os dois.
  *Causa:* `dbg = empty_func -- WILL BE REMOVED IN GOLD MASTER` (`CommonLua/Core/lib.lua:32`).
  `dbg(...)` é o idioma do engine para expressão só-de-dev, e a etapa de build que o remove
  na Gold Master **não é Lua-aware**: acha o token, procura o próximo `(`, e come texto até
  o `)` correspondente — que pode estar longe. Como este mod nunca chamou `dbg(...)`, só
  usava `dbg` como nome, a poda começava no lugar errado. Já corrompeu até comentário sem
  relação nenhuma com debug.
  *Já feito (2026-08-25):* todo `dbg` isolado renomeado para `trace` em 7 arquivos.
  *Contrato cross-mod:* o campo `dbg` dentro de `context.dbg_expected[dbg_id]` era lido por
  nome pelo mod **`Rato Dev`** (repo separado, `Code/RATODBG_AIDebugUI.lua`) para desenhar o
  painel "Resultado esperado". Já atualizado lá para `e.trace`. Renomear só o lado produtor
  não daria erro — a linha de detalhe sumiria em silêncio. Se `dbg_expected` ganhar campo
  novo, lembre que quem consome está noutro repo.
  *Não tocado de propósito:* compostos com prefixo `dbg_` (`dbg_expected`, `dbg_id`,
  `dbg_rows`, `dbg_available_actions`, …). O caso reproduzido em jogo foi só o token isolado.
  **Risco em aberto:** não sabemos se a etapa de build reage ao token isolado ou a qualquer
  ocorrência da substring. Se o erro voltar no `JA3.exe` depois de confirmar que não há `dbg`
  isolado, o próximo suspeito são os compostos — comece pelo arquivo citado no erro.
  *Exceção:* `dbg(...)` de verdade vindo de dependência ou copiado do source do jogo não é o
  mesmo caso — ali o uso é o que o engine espera. O problema é `dbg` em posição que não é
  chamada de função.
- Repositório git próprio (branches: `main`, `claude-performance-refactor`,
  `New_AiCalcAttacksAndAim`).
- **O GBO3 também é do autor e pode ser modificado.** Ele não é uma dependência
  intocável: se mudar algo lá (expor um valor, quebrar uma função em duas, tornar um
  cálculo consultável sem efeito colateral) simplifica ou barateia o lado da IA, **sugira
  a mudança lá** em vez de contornar aqui. O mesmo vale para o `Rato-s-ToG-Compatibility-Patch`
  e o `Rato-s-Explosive-Overhaul-2.0`.
  Vale ainda assim manter a fronteira explícita: mudança no GBO3 afeta o jogador
  diretamente, então diga o que muda para ele, não só para a IA.
 
