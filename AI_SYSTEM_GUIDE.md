# Guia da IA de Jagged Alliance 3

*Escrito em 2026-08-17. Base: source em `Steam/steamapps/common/Jagged Alliance 3/ModTools/Src/`
e o mod `Rato's AI Overhaul` v1.12.*

Este documento explica **como a IA decide**, com foco em três perguntas:

1. O que é a *Best Pos* (localização ótima) e como ela difere dos outros scores.
2. Como a IA escolhe entre arquétipos e entre ações.
3. Por que uma unidade distante às vezes não avança — e onde intervir.

---

## 0. Mapa dos arquivos

### Source do jogo

| Arquivo | Conteúdo |
|---|---|
| `Lua/Tactical/CombatAI.lua` | **O núcleo.** Contexto, destinos, scoring de posição e de alvo, execução de ataques. 2643 linhas. |
| `Lua/Tactical/AIBehaviors.lua` | Classes de *behavior* (`StandardAI`, `PositioningAI`, `HoldPositionAI`, `RetreatAI`, `CustomAI`, `ApproachInteractableAI`). |
| `Lua/Tactical/AIActions.lua` | Classes de *signature action* (`AIActionMGSetup`, `AIActionThrowGrenade`, `AIActionSingleTargetShot`, …). |
| `Lua/Tactical/AIBase.lua` | Sistema de *bias* (modificadores temporários de peso, disable, priority). |
| `Lua/Tactical/AITactics.lua` | `TacticalMap` — áreas de combate nomeadas por marker (GuardArea). |
| `Lua/Tactical/CombatCamera.lua` | `AIExecutionController` — orquestra o turno inteiro do time da IA (a partir da linha 570). |
| `Data/ClassDef-AI.lua` | Definição das **policies** de posição (`AIPolicy*`) e de alvo (`AITargeting*`), e do preset `AIArchetype`. |
| `Data/AIArchetype.lua` | Os arquétipos vanilla (`Soldier`, `HeavyGunner`, `Skirmisher`, `Brute`, `Medic`, `Artillery`, `GuardArea`, …). |
| `Lua/ClassDefs/ClassDef-Zulu.generated.lua` | `UnitProperties:SelectArchetype` (linha ~2049) e as props de IA da unidade (`archetype`, `AIKeywords`, `MaxAttacks`, …). |
| `Lua/UI/IModeAIDebug.lua` | O modo de debug visual da IA. |

### Seu mod (o que sobrescreve o quê)

- `SOURCE_*.lua` → substituem funções globais do source (`AIScoreDest`, `AISelectAction`, `AIPrecalcDamageScore`, `AICreateContext`, `AICalcAttacksAndAim`, …).
- `AIPOLICYPOS_*.lua` → novas classes `AIPositioningPolicy`.
- `AIPOLICYTARG_*.lua` → novas classes `AITargetingPolicy`.
- `AIACTION_*.lua` → novas `AISignatureAction` (`ThrowFlare`, `PrepareWeapon`).
- `PATCH_AppendClass_source_classes.lua` → **adiciona a property `CustomScoring` a toda `AISignatureAction`** (esse é o gancho central do seu redesenho de escolha de ações).
- `items.lua` → seus arquétipos (`Soldier`, `HeavyGunner`, `RATOAI_Sniper`, `RATOAI_Demolition`, …).

---

## 1. O pipeline completo de um turno da IA

```
AIExecutionController:Execute(units)          [CombatCamera.lua]
│
├─ FASE 1 — "Think" de todo mundo, antes de qualquer um agir
│   para cada unidade: unit:StartAI()          [Unit.lua:8908]
│       ├─ SelectArchetype()                   → define unit.current_archetype
│       ├─ escolhe o BEHAVIOR (roleta ponderada por Score())
│       └─ AICreateContext(unit, proto_context) → monta unit.ai_context
│              └─ behavior:EnumDestinations()  → AIFindDestinations()
│              └─ AIUpdateDestLosCache()       → g_AIDestEnemyLOSCache
│
├─ FASE 2 — ordenação por turn_phase (Early / Normal / Late)
│   AIGetNextPhaseUnits()                      [CombatAI.lua:2330]
│
└─ FASE 3 — para cada grupo de unidades, em ordem:
    behavior:Think(unit)                       [AIBehaviors.lua]
    │   ├─ AIFindDestinations()      → onde consigo chegar ESTE turno
    │   ├─ AIFindOptimalLocation()   → *** BEST POS *** (onde eu QUERIA estar)
    │   ├─ AICalcPathDistances()     → distância de cada destino até a Best Pos
    │   ├─ AIPrecalcDamageScore()    → melhor alvo e score de dano por destino
    │   ├─ AIScoreReachableVoxels()  → *** ai_destination *** (para onde vou hoje)
    │   └─ AIChooseMovementAction()  → RunAndGun / MobileShot / Charge?
    │
    AIExecuteUnitBehavior(unit)                [CombatAI.lua:486]
    │   ├─ behavior:TakeStance()
    │   ├─ behavior:BeginMovement()  → Move (ou a movement action)
    │   ├─ behavior:EndMovement()
    │   ├─ behavior:Play()           (RetreatAI despawna, ApproachInteractable interage…)
    │   └─ AIPlayAttacks()           [CombatAI.lua:190]
    │        ├─ AIChooseSignatureAction()  → ação especial (1x por turno)
    │        ├─ ataques básicos            → AICalcAttacksAndAim()
    │        └─ fallback: mover pro closest_dest / overwatch / voltar a Unaware
    │   └─ AITakeCover()
```

Ponto importante: **o "Think" de todas as unidades acontece antes de qualquer execução**, e o
`ai_context` de cada uma fica visível para as outras. Por isso existe o filtro em
`AIBuildArchetypePaths` (CombatAI.lua:1116) que remove destinos já "reservados"
(`u.ai_context.ai_destination`) por aliados, e por isso `AIPolicyFlanking` /
`AIPolicyProximity` têm a opção `AllyPlannedPosition`.

---

## 2. Os quatro tipos de score (não confunda)

Este é o ponto que mais gera confusão. São **quatro sistemas de pontuação diferentes**, com
unidades e propósitos distintos:

| # | Score | Função | Quem avalia | Resultado |
|---|---|---|---|---|
| 1 | **Behavior score** | Qual comportamento a unidade adota neste turno | `behavior:Score()` | roleta ponderada → `context.behavior` |
| 2 | **Optimal Location** (*Best Pos*) | Onde a unidade **gostaria** de estar, ignorando AP | `archetype.OptLocPolicies` | `context.best_dest` |
| 3 | **End-Turn Location** | Onde a unidade **vai** terminar o turno, dado o AP | `behavior.EndTurnPolicies` | `context.ai_destination` |
| 4 | **Target score** | Em quem atirar, e quanto vale atirar de cada tile | `archetype.TargetingPolicies` + CTH | `context.dest_target[dest]`, `dest_target_score[dest]` |

E, por cima disso, **Action score**: qual signature action usar (seção 6).

### 2.1 A distinção crítica: Best Pos ≠ ai_destination

**`best_dest` (Best Pos)** — `AIFindOptimalLocation()`, CombatAI.lua:1262

- Varre **`context.all_destinations`**: todos os tiles passáveis num raio de
  `archetype.OptLocSearchRadius` tiles (80 no seu Soldier, 100 no seu HeavyGunner),
  **independente de ser alcançável neste turno**. Ver `AIEnumValidDests()` (linha 1208).
- Usa **`archetype.OptLocPolicies`** (só as policies com a flag `optimal_location = true`).
- **Não considera AP.** É "o lugar ideal do mapa pra mim".
- Cacheado: `if context.best_dest then return context.best_dest end` — não muda entre behaviors.
- É a **âncora estratégica de longo prazo**: a única coisa no sistema que puxa a unidade para
  além do alcance de movimento de um turno.

**`ai_destination`** — `AIScoreReachableVoxels()`, CombatAI.lua:1707

- Varre **`context.destinations`**: só os tiles alcançáveis **neste turno** com o AP disponível.
- Usa **`behavior.EndTurnPolicies`** (só as policies com `end_of_turn = true`).
- Soma um **`dist_score`**: quanto mais perto da Best Pos, maior o bônus, escalado por
  `behavior.OptLocWeight`.
- É a **decisão tática do turno**.

O acoplamento entre os dois é feito por `AICalcPathDistances()` (linha 1359):

```lua
-- 1. calcula o caminho da unidade até best_dest
context.best_dest_path = pf.GetPosPath(unit, pf_dests)   -- dentro de AIFindOptimalLocation
-- 2. mede a distância ao longo desse caminho
path_voxels, voxel_dist, total_dist = CalcPathVoxels(context.best_dest_path)
-- 3. flood-fill: propaga distâncias do caminho para todos os destinos alcançáveis
AICalcDistancesFromReachableLocations(context)  -- preenche context.dest_dist[dest]
```

E dentro de `AIScoreReachableVoxels`:

```lua
local dist = dest_dist[dest] or 100*guim
local dist_score = MulDivRound(100 - MulDivRound(100, dist, total_dist), opt_loc_weight, 100)
score = dist_score + AIScoreDest(context, policies, dest, ...)
```

Ou seja: **`OptLocWeight` é literalmente o tamanho, em pontos brutos de score, do gradiente
"ande em direção à Best Pos"**. Ele compete de igual pra igual com os pesos das `EndTurnPolicies`.
Default = 100. Se as suas policies de fim de turno somam 300–500 pontos, um `OptLocWeight` de 20
(como no seu `PositioningAI` de flanqueamento) é ruído.

### 2.2 O `AIDecisionThreshold` (const = 80)

Está em três lugares e explica a "aleatoriedade" da IA:

- **Best Pos** (linha 1300): mantém em `best_dests` todo tile com score ≥ 80% do máximo.
- **End-Turn** (linha 1756): mantém em `potential_dests` todo destino com score ≥ 80% do melhor.
- **Alvo** (linha 1647): mantém em `potential_targets` todo alvo com score ≥ 80% do melhor.

Depois faz uma **roleta ponderada** entre os finalistas. Não é "escolhe o melhor" — é "escolhe
aleatoriamente entre os quase-melhores". Isso é intencional (variedade), mas é a fonte primária
de comportamento errático quando os scores estão achatados.

### 2.3 Como uma policy pontua

`AIScoreDest()` (CombatAI.lua:1135; sua versão em `SOURCE_AIScoreDest.lua`):

```lua
for _, policy in ipairs(policies) do
    local peval  = policy:EvalDest(context, dest, grid_voxel)   -- normalmente 0..100
    local pscore = MulDivRound(peval or 0, policy.Weight, 100)  -- escala pelo Weight
    local failed = policy.Required and pscore <= 0              -- (seu mod: <= 0; vanilla: == 0)
    score = score + pscore
    if failed then return 0 end                                  -- veto total
end
```

Três coisas a lembrar:

1. `Weight` é um **percentual**, não um valor absoluto. `Weight = 300` com `EvalDest` retornando
   100 dá 300 pontos.
2. **`Required = true` é um veto**: se a policy der 0, o tile inteiro vale 0. Você usa isso muito
   (`AIPolicyLosToEnemy` Required no MG, `AIPolicyCustomSeekCover` Required no flanqueamento).
   É poderoso e é a causa mais comum de "não achou lugar nenhum → não se moveu".
3. Nem toda policy retorna 0..100. `AIPolicyDealDamage` retorna
   `context.dest_target_score[dest]` **cru** — que costuma valer centenas. `AIPolicyHighGround`
   retorna `Weight * (z - uz)`. `AIPolicyProximity` retorna distância em tiles. Misturar essas
   com policies normalizadas desbalanceia tudo silenciosamente.

Antes das policies, `AIScoreDest` aplica dois modificadores globais: fogo/gás adjacente
(`const.AIAvoidFireWeigth = -200`) e zona de bombardeio. Depois de tudo, aplica os
**Bias Markers** do mapa (multiplicador percentual por região — o level designer usa isso para
empurrar a IA pra fora ou pra dentro de áreas).

### 2.4 As flags `optimal_location` e `end_of_turn`

Cada classe de policy declara duas booleanas read-only que dizem **onde ela pode ser usada**:

```lua
PlaceObj('PropertyDefBool', { 'id', "optimal_location", 'default', true }),  -- pode ir em OptLocPolicies
PlaceObj('PropertyDefBool', { 'id', "end_of_turn",      'default', true }),  -- pode ir em EndTurnPolicies
```

O editor filtra por isso (`class_filter = function(name, class, obj) return class.optimal_location end`).

> **Achado no seu mod:** `AIPolicyMGSetupAP` declara **só** `end_of_turn = true`. Ela nunca pode
> ser usada como policy de localização ótima. `AIPolicyMGSetupPosScore` declara as duas — mas
> **nenhuma das duas está sendo usada em nenhum arquétipo do `items.lua`**. Estão definidas e
> mortas.

### 2.5 Target score — `AIPrecalcDamageScore()` (CombatAI.lua:1418)

Roda **por destino**. Para cada par (destino, alvo):

```
mod = base_skill(Marksmanship/etc)
    + bônus de stance (crouch/prone)
    + high/low ground
    + SameTarget
    + cover do alvo (negativo)
    - penalidade de distância (100 - weapon:GetAccuracy(dist))
    + Darkness
    ×(1 + AIPointBlankTargetMod/100) se point blank      -- const = 50 → +50%
→ se mod > const.AIShootAboveCTH (=0):
    mod = Σ (CTH + bônus de mira) sobre os N ataques que cabem no AP  -- AICalcAttacksAndAim
    mod = mod × archetype.TargetBaseScore / 100
    mod = mod + Σ (policy:EvalTarget() × policy.Weight/100)   -- TargetingPolicies
    mod ×= 5%   se o alvo está Downed
    mod ×= const.AIFriendlyFire_ScoreMod (50%)  se um aliado está na linha
    mod ×= target_score_mod  -- randomização ±TargetScoreRandomization%
→ dest_target_score[dest] = melhor score; dest_target[dest] = alvo escolhido (roleta ≥80%)
```

Note que isso **não é dano** — é uma proxy baseada em chance de acerto × número de ataques.
`AIPolicyDealDamage` só repassa esse número como score de posição. É por isso que ela domina
qualquer outra policy quando há alvo (score na casa das centenas contra 0–100 das outras) e
some completamente quando não há.

Também note o gate `if weapon and ap >= cost_ap` (linha 1541): **um destino onde a unidade
não sobra AP para atacar tem `dest_target_score = 0`**. Isso é o que faz a IA parar antes de
gastar todo o AP andando.

---

## 3. Escolha do arquétipo

`UnitProperties:SelectArchetype(proto_context)` — `ClassDef-Zulu.generated.lua:2049`.
É uma **cascata de if/elseif**, não um score:

```lua
if self.retreating                    then archetype = "Deserter"
elseif HasStatusEffect("Panicked")    then archetype = "Panicked"
elseif HasStatusEffect("Berserk")     then archetype = "Berserk"
elseif emplacement assignado          then archetype = "EmplacementGunner"
elseif command == "Reposition"        then archetype = self.RepositionArchetype
end

-- Scout: se não tem arquétipo ainda e não vê nenhum inimigo
if can_scout and #GetVisibleEnemies() == 0 then
    self.last_known_enemy_pos = self.last_known_enemy_pos or AIPickScoutLocation(self)
    if self.last_known_enemy_pos then archetype = "Scout_LastLocation" end
end

-- PinnedDown: se algum inimigo tem pindown nela, rola PinnedDownChance (default 50%)
...

self.current_archetype = archetype
    or template.PickCustomArchetype(self, proto_context)   -- << seu gancho
    or self.archetype                                       -- << o do UnitDataDef
    or "Assault"
```

E na leitura:

```lua
function Unit:GetArchetype()
    return Archetypes[self.script_archetype]          -- override de script/quest, prioridade máxima
        or Archetypes[self.current_archetype]
        or Archetypes.Soldier
end
```

**Onde você intervém:** `PickCustomArchetype` (per-UnitDataDef) — é exatamente o que
`FUNCTION_CustomArchetypeFunc.lua` + `PATCH_ChangeUnitDataDef.lua` fazem no seu mod. É o único
ponto realmente flexível; toda a cascata acima é hardcoded no source.

**Consequência importante:** o arquétipo é escolhido **uma vez, no início do turno**, antes de
qualquer avaliação de posição. Não existe "trocar de arquétipo no meio do turno". Se você quer
que um gunner mude de postura conforme a situação, isso tem que ser **behavior**, não arquétipo.

---

## 4. Escolha do behavior

`Unit:StartAI()` — `Unit.lua:8908`. Aqui **sim** é score:

```lua
for i, behavior in ipairs(archetype.Behaviors) do
    if behavior:MatchUnit(self) then                          -- RequiredKeywords
        weight_mod, disable, priority = AIGetBias(behavior.BiasId, self)
        priority = priority or behavior.Priority
    else
        weight_mod, disable = 0, true
    end
    if not disable then
        local score = MulDivRound(behavior:Score(self, proto_context, debug_data), weight_mod, 100)
        if score > 0 then
            if priority then forced_behavior = behavior; break end   -- << atalho
            scores[#scores+1] = score; available[#available+1] = behavior
            total = total + score
        end
    end
end
-- roleta ponderada sobre `available`
```

Regras práticas:

- **`Priority = true` + score > 0 = seleção imediata**, ignora todo o resto da lista. É um
  short-circuit, não um "peso alto".
- A **ordem importa** por causa disso: o primeiro `Priority` que pontuar ganha.
- `Score` default de `AIBehavior` é `return self.Weight` (constante).
- `PositioningAI` tem um `Score` default diferente: `PositioningAIScore` roda
  `AIScoreReachableVoxels(ctx, self.EndTurnPolicies, 0)` e retorna
  `score × Weight/100`. Ou seja, **o behavior de posicionamento se auto-avalia pela qualidade do
  melhor tile que ele conseguiria alcançar**. Se as `EndTurnPolicies` dele vetarem tudo
  (`Required`), o score é 0 e o behavior não é escolhido. Elegante — e é a raiz do problema do MG
  (seção 8).
- `HoldPositionAI` só faz `AIPrecalcDamageScore` na posição atual — não anda, não procura
  Best Pos.
- `behavior:GetTurnPhase(unit)` retorna `"Late"` se a unidade está `IsThreatened()`
  (sob overwatch), senão o `turn_phase` configurado. Isso define a **ordem de ação dentro do
  time**: `Early` → `Normal` → `Late`. É como você faz um scout ir na frente ou um medic depois.

### Quais behaviors chamam `AIFindOptimalLocation` (isto é: quais sabem andar longe)

| Behavior | `AIFindOptimalLocation` | `OptLocWeight` usado | Anda em direção à Best Pos? |
|---|---|---|---|
| `StandardAI` | **sim** | `self.OptLocWeight` | **sim** |
| `RetreatAI` | sim (se não pode despawnar) | `self.OptLocWeight` | sim |
| `ApproachInteractableAI` | não (usa a pos do interactable como best_dest) | `self.OptLocWeight` | sim |
| `CustomAI` | sim (ou `PickOptimalLoc` custom) | `self.OptLocWeight` | sim |
| **`PositioningAI`** | **não** | **hardcoded `0`** | **não** |
| `HoldPositionAI` | não | — | não |

```lua
-- AIBehaviors.lua:360
function PositioningAI:Think(unit, debug_data)
    local context = unit.ai_context
    AIFindDestinations(unit, context)
    context.positioning_dest = AIScoreReachableVoxels(context, self.EndTurnPolicies, 0, ...)
    --                                                                              ^^^ zero
    context.ai_destination = context.positioning_dest
    context.movement_action = AIChooseMovementAction(context)
end
```

**`PositioningAI` é, por construção, um behavior de reposicionamento de UM turno.** Ele não tem
memória de longo prazo nem gradiente de aproximação. A property `OptLocWeight` do behavior existe
na UI mas é ignorada por essa classe.

---

## 5. Como a IA sabe para onde pode ir

`AIFindDestinations()` → `AIBuildArchetypePaths()` (CombatAI.lua:1009):

1. Constrói **dois** `CombatPath`: um com `archetype.MoveStance` e outro com
   `archetype.PrefStance` (se diferentes), cada um descontando o custo de troca de stance.
2. Para cada voxel alcançável, escolhe a stance que sobra mais AP e empacota
   `dest = stance_pos_pack(x, y, z, stance_idx)`.
3. `CollapsePoints(destinations, 1)` — **reduz drasticamente a lista** (amostragem espacial).
   Tiles em `context.important_dests` são re-inseridos depois (posições de melee, de cura, a
   Best Pos).
4. Remove destinos já reservados por aliados.

Depois, `AIFindDestinations` faz um pós-processamento: destino que não está em Crouch mas tem
cover baixo adjacente e AP sobrando vira Crouch automaticamente.

`AIUpdateDestLosCache()` (linha 862) preenche `g_AIDestEnemyLOSCache[dest] = true/false` em lote
(até 100 raycasts por batch, com `Sleep(10)` entre eles). É o que `AIPolicyLosToEnemy` e
`AIPolicyDealDamage(CheckLOS)` consultam. **É a parte mais cara do think.**

---

## 6. Escolha da ação (signature actions)

Duas listas separadas, filtradas por `action.movement`:

```lua
AIChooseSignatureAction(context)  -- movement == false, rodado em AIPlayAttacks
AIChooseMovementAction(context)   -- movement == true,  rodado no fim do Think
```

Ambas chamam `AIGetSignatureActions()` → **se `behavior.SignatureActions` não estiver vazia, usa
ela; senão usa `archetype.SignatureActions`**. Não há merge. É override total.

Depois vai para `AISelectAction()` (CombatAI.lua:589 / seu `SOURCE_AISelectAction.lua`):

```lua
weight = base_weight                        -- archetype.BaseAttackWeight (ataque básico "concorre")
for _, action in ipairs(actions) do
    weight_mod, disable, priority = AIGetBias(action.BiasId, unit)
    disable = disable or context.disable_actions[action.BiasId]
    -- [SEU MOD] gate extra:
    c_weight, custom_disable, action_priority = action:CustomScoring(context)
    if not disable then
        action:PrecalcAction(context, state)          -- calcula args, alvo, zona, score
        if action:IsAvailable(context, state) then
            action_weight = MulDivRound(c_weight, weight_mod, 100)
            if priority then return action end        -- << short-circuit
            available[#available+1] = action; weight = weight + action_weight
        end
    end
end
-- roleta ponderada; `base_weight` é a fatia do "ataque básico" (nenhuma signature)
```

Pontos importantes:

- **`base_weight = archetype.BaseAttackWeight`** representa "não usar nenhuma signature action,
  só atacar normal". Se você quer signature actions frequentes, baixe esse valor; se quer raras,
  suba.
- **`Priority = true`** na ação = short-circuit igual ao dos behaviors.
- `PrecalcAction` é chamado **para toda ação não desabilitada**, e é caro (calcula zonas de cone,
  LOF, alvos). Seu comentário `PERF (C12)` no `SOURCE_AISelectAction.lua` move o `CustomScoring`
  para antes justamente para pular esse custo — mas note que ele agora roda **antes** de
  `PrecalcAction`, então `CustomScoring` não pode depender de `action_state`.
- `action_state.score` (setado por várias `PrecalcAction`) é usado por `AIGetActionWeight()`, mas
  **`AISelectAction` não chama `AIGetActionWeight`** — só `AIChooseSignatureAction` a usa
  indiretamente… na verdade, no vanilla, `action_state.score` só é lido em `AIGetActionWeight`,
  que **não é chamado em lugar nenhum do fluxo principal**. Código morto no source. Seu
  `CustomScoring` é a forma correta de introduzir score contextual.
- Só **uma** signature action por turno (`context.max_attacks = context.max_attacks - 1` e depois
  o loop de ataques básicos).

### Sistema de Bias (`AIBase.lua`)

`AIBiasModification` permite que uma ação, ao ser usada, modifique pesos por N turnos:

```lua
PlaceObj('AIBiasModification', { 'BiasId', "SmokeGrenade", 'Effect', "disable", 'Period', 0 })
PlaceObj('AIBiasModification', { 'BiasId', "SmokeGrenade", 'Value', -33, 'ApplyTo', "Team" })
```

- `Effect = "disable"` → bloqueia; `"priority"` → força; `"modify"` → soma `Value` ao
  `weight_mod` percentual.
- `Period = 0` significa `end_turn = current_turn + 0` → expira no fim do turno atual
  (`AIUpdateBiases` remove quando `end_turn < current_turn`). Na prática: "uma vez por turno".
- `ApplyTo = "Team"` → o time inteiro. É assim que você evita que 5 soldados joguem fumaça no
  mesmo turno.
- `AIGetBias` retorna `disable = true` se `weight_mod <= 0`. Ou seja, acumular `-100` de modifier
  desabilita.

---

## 7. Execução: movimento e ataques

`AIPlayAttacks()` (CombatAI.lua:190) roda **depois** do movimento. Ordem:

1. Re-roda `AIPrecalcDamageScore` no destino atual (o mundo mudou desde o Think).
2. Signature action (se houver).
3. Se o alvo morreu: `TargetChangePolicy` — `"recalc"` (só reescolhe alvo daqui) ou
   `"restart"` (**refaz o turno inteiro da unidade**, incluindo movimento). `"restart"` é caro
   mas é o que permite a IA reagir de verdade.
4. Ataques básicos: `AICalcAttacksAndAim(context, ap)` distribui o AP entre número de ataques e
   níveis de mira, limitado por `unit.MaxAttacks` e `weapon.MaxAimActions`.
5. **Fallback** (linha 358) — se a unidade não gastou AP nenhum:
   - move para `context.closest_dest` (o destino com melhor `dist_score`, cacheado em
     `AIScoreReachableVoxels`);
   - se ainda não saiu do lugar: `archetype.FallbackAction == "overwatch"` →
     `AIPlaceFallbackOverwatch()`;
   - se falhar: **volta para Unaware** (`g_UnawareQueue`) se não vê nenhum inimigo.

Esse fallback é a rede de segurança contra "a IA passou o turno parada", mas ele depende de
`closest_dest`, que só existe se houve gradiente de Best Pos (`dist_score > 0`). Ver seção 8.

---

## 8. Diagnóstico: por que a unidade distante não avança

Este é o seu problema histórico. Há **cinco** modos de falha distintos, e eles produzem sintomas
diferentes.

### Falha A — a Best Pos cai em cima do próprio tile (a mais comum)

`AIFindOptimalLocation`, CombatAI.lua:1317:

```lua
-- check if a best dest candidate is on our starting voxel, default to it
for _, dest in ipairs(context.best_dests) do
    if stance_pos_dist(context.unit_stance_pos, dest) == 0 then
        context.best_dest = dest
    end
end
```

`best_dests` contém **todo tile com score ≥ 80% do máximo**. Se a unidade está atrás de uma boa
cobertura, `AIPolicyCustomSeekCover` / `AIPolicyTakeCover` dão score alto no tile atual, e ele
entra na lista de finalistas. Então a Best Pos **é a posição atual**.

Consequência em cascata:

```
best_dest == unit_stance_pos
  → best_dest_path nunca é calculado (o bloco pf.GetPosPath está no `if not context.best_dest`)
  → AICalcPathDistances: path_voxels = nil → context.dest_dist = {}
  → AIScoreReachableVoxels: total_dist = 0
      → dist_score = 0 para TODOS os destinos      (zero gradiente de aproximação)
      → mas o tile atual recebe base_score = -opt_loc_weight  (penalidade fixa!)
      → closest_dest = nil (best_dist_score nunca > 0) → fallback de movimento morto
```

**Sintoma: a unidade fica trocando de posição sem se aproximar.** É literalmente isso: o tile
atual é penalizado em `-OptLocWeight`, todos os outros empatam em 0 + policies, e a roleta de
80% escolhe um vizinho aleatório. Todo turno.

### Falha B — todas as OptLocPolicies dão 0 a longa distância

Olhe as `OptLocPolicies` do seu `Soldier`:

```lua
AIPolicyCustomSeekCover  Weight 150
AIPolicyLosToEnemy       Weight 100   → 0 se não há LOS
AIPolicyWeaponRange      Weight 200, 30%–50%   → 0 fora da faixa
AIPolicyWeaponRange      Weight  20, 51%–100%  → 0 fora da faixa
AIPolicyTryNotToBeFlanked Weight 50
```

Além de 100% do alcance da arma, **as duas `WeaponRange` e a `LosToEnemy` retornam 0**. O que
sobra é cobertura e não-ser-flanqueado — que são maximizados **perto de onde a unidade já está**.
Não existe nenhuma policy com gradiente contínuo em direção ao inimigo.

Resultado: `best_score` é dominado por cobertura, `best_dests` são tiles com cobertura espalhados
pelo raio de 80 tiles, e aí vem a Falha C.

### Falha C — `pf.GetPosPath` escolhe o candidato **mais próximo**, não o melhor

```lua
context.best_dest_path = pf.GetPosPath(unit, pf_dests)   -- pf_dests = todos os finalistas ≥80%
local voxel = point_pack(SnapToPassSlabXYZ(context.best_dest_path[1]))
context.best_dest = context.voxel_to_dest[voxel]
```

`pf.GetPosPath` com uma lista de destinos retorna o caminho para o **mais barato de alcançar**.
Como `best_dests` é achatado pelo threshold de 80%, isso vira "vá para o tile decente mais
perto". A unidade avança 3 tiles, e no turno seguinte o mesmo cálculo escolhe outro tile decente
perto — ela nunca compromete com o objetivo distante.

**Isso é o "ele fica trocando de posição" em câmera lenta.**

### Falha D — `OptLocSearchRadius` menor que a distância ao inimigo

`AIEnumValidDests` monta uma bbox de `OptLocSearchRadius × SlabSizeX` em volta da unidade e
descarta qualquer tile fora dela (`IsCloser(gx, gy, gz, ux, uy, uz, radius)`). Se o inimigo está a
90 tiles e o raio é 80, **nenhum tile perto do inimigo entra na avaliação**. Seus valores (80 no
Soldier, 100 no HeavyGunner) são generosos, mas mapas grandes com engajamento a longa distância
podem estourar.

### Falha E — `Required` vetando tudo

Com `AIPolicyLosToEnemy { Required = true }` (você usa isso no `PositioningAI` do HeavyGunner),
qualquer tile sem linha de visão vale **0**. Se a unidade está atrás de um morro sem LOS para
lugar nenhum alcançável, `AIScoreReachableVoxels` retorna score 0 → `PositioningAIScore` retorna
0 → **o behavior nem é selecionado**. Ela cai no `StandardAI`, que também não tem alvo, e não faz
nada.

Note ainda que seu `SOURCE_AIScoreDest.lua` mudou `pscore == 0` para `pscore <= 0`. Isso é
correto para suportar policies negativas, mas **aumenta a superfície de veto**: qualquer policy
`Required` que possa retornar valor negativo agora zera o tile.

### Como atacar cada um

| Falha | Correção |
|---|---|
| A | Adicionar uma `OptLocPolicy` com `Required=true` que **exclua o tile atual** quando há inimigo distante — é exatamente para isso que existe `AIPolicyDistanceFromStart { Away = true, Distance = N, Required = true }`. Ou uma policy custom que retorne 0 para `stance_pos_dist(dest, unit_stance_pos) == 0`. |
| B | Adicionar uma policy de **gradiente contínuo** em direção ao inimigo. `AIPolicyProximity(TargetUnits="enemies", TargetDist="min")` retorna a distância em tiles — com `Weight` **negativo** ela vira "chegue perto". Melhor ainda: escrever uma `AIPolicyApproachEnemies` que retorne `100 - MulDivRound(100, dist, max_dist)` (normalizada 0..100, comportada). |
| C | Reduzir o achatamento: subir os pesos das policies que discriminam de verdade, ou pós-filtrar `context.best_dests` para o de maior score antes do `pf.GetPosPath` (é um override pequeno de `AIFindOptimalLocation`). |
| D | Subir `OptLocSearchRadius`. Custo: `ForEachPassSlab` sobre uma bbox quadrática. |
| E | Trocar `Required` por `Weight` alto + uma policy de fallback; ou dar ao behavior um `Score` que não dependa de `AIScoreReachableVoxels` retornar > 0. |

E, transversalmente: **`OptLocWeight` precisa ser comparável à soma das `EndTurnPolicies`**. Se
`AIPolicyDealDamage` entrega 400 pontos e o `OptLocWeight` é 100, atacar sempre ganha de avançar
— o que é certo quando há alvo e errado quando não há.

---

## 9. Caso concreto: o Heavy Gunner e o setup da MG

### 9.0 As regras do jogo (o que a MG realmente é)

A MG é **portátil**. Não existe "ninho" no sentido de emplacement — o que existe é a ação
`MGSetup`, que deita a unidade e cria um cone permanente de ataques de interrupção.
`CombatAction.MGSetup.Description`: *"Focus on a cone-shaped area, immobilizing yourself and going
prone. You can only shoot enemies inside that cone."*

Parâmetros relevantes, já com as mudanças do GBO3:

| Parâmetro | Valor | Fonte |
|---|---|---|
| Ângulo do cone | `OverwatchAngle × 110% + 3°` | `SOURCE_ChangeMGSetupGetAreaParams.lua` (`MGSetupConeMul=110`, `MGSetupConeFlat=180` minutos) |
| Alcance máximo do cone | **`WeaponRange` inteiro** para `MachineGun` (75% para as outras armas) | `Firearm:GetOverwatchConeParam("MaxRange")`, override do GBO3 |
| Alcance mínimo | 2 tiles | idem |
| Custo | escala com Strength entre `min_cost` e `max_cost`; já inclui deitar | `CombatAction.MGSetup.GetAPCost` |
| Ataques de interrupção | `GetNumMGInterruptAttacks()`, função do AP restante | idem |

Consequências de design que caem direto do código:

1. **Distância não é o critério; LOF é.** O cone chega ao alcance total da arma (36 tiles para
   HK21/Minimi no GBO3), então "mais longinho" é gratuito. O que decide é conseguir traçar linha de
   tiro deitado.
2. **Agrupamento já é premiado — mas só na posição atual.** `AICalcAOETargetPoints` gera pontos de
   mira em cada inimigo *e nos pontos médios de todos os pares e trios*; `AIEvalZones` soma
   `enemy_score` por inimigo dentro do cone. Com `enemy_score = 110`, um cone com 3 inimigos vale
   330 contra 110 de um cone com 1. A preferência por aglomerado é automática **na hora de escolher
   a direção**, e inexistente na hora de escolher o *tile* (§9.2d).
3. **`min_score = 100` é um piso, não uma preferência.** Com `enemy_score = 110`, ele significa
   "pelo menos 1 inimigo no cone". Se você quisesse exigir 2, seria 220 — mas isso bloquearia
   setups legítimos contra alvo único. Deixe em 100 e confie na comparação entre zonas.
4. **Cobertura é inimiga do setup.** Deitado atrás de cobertura baixa você não passa a linha por
   cima dela. Por isso o `HeavyGunner` não deve ter policy de cobertura no OptLoc — e não tem.
   Mas o motor tem um viés pró-cobertura escondido que atrapalha (§9.2b).
5. **Recuar é barato.** `Unit:Move` chama `Unit:MGPack()` **internamente e de graça** antes de
   andar (`Unit.lua:4483`). A *ação* `MGPack` custa 1 AP; a função interna, zero. Um behavior de
   recuo não precisa de nenhum tratamento especial: basta mandar mover.

### 9.1 Como está hoje no seu mod (`items.lua`, `HeavyGunner`, linha 811)

**1. `StandardAI`** — `Score` = `self.Weight` (300, Priority).
`EndTurnPolicies`: só `AIPolicyDealDamage`. `override_attack_id/cost_id = "MGSetup"`.
`SignatureActions`: `AIActionMGSetup` (Priority, Weight 300, `CustomScoring` retorna 0+disable se já
montado) e `AIActionMGBurstFire`.

**2. `PositioningAI` "MG Setup"** (Weight 50, Priority) — só entra se
`Get_HeavyGunnerShouldUsePositioningBehavior()` = `true`, isto é: *"o `MGSetup` foi pré-calculado da
posição atual e NÃO está disponível"*.
`OptLocWeight = 20` (**ignorado — `PositioningAI:Think` passa 0**).
`EndTurnPolicies`: `TryNotToBeFlanked(50, Required)`, `LastEnemyPos(300)`,
`WeaponRange(300, 30–50%)`, `WeaponRange(50, 51–60%)`, `LosToEnemy(Required)`.
`TakeCoverChance = 50`.

**3. `HoldPositionAI` "In Setup"** (Weight 200) — se já tem `StationedMachineGun`.
`AIActionMGBurstFire` (Aiming Maximum) + `AIActionMGSetup` (para rotacionar/desmontar).

Não existe behavior de recuo.

### 9.2 Os cinco problemas, em ordem de impacto

**(a) O behavior de posicionamento não sabe andar longe.**
`PositioningAI:Think` chama `AIScoreReachableVoxels(context, EndTurnPolicies, 0)` — zero hardcoded.
Nunca calcula `best_dest`, nunca calcula `dest_dist`. Só escolhe entre tiles alcançáveis com o AP
deste turno. Se a posição de tiro está a dois turnos, ela é invisível. **Este é o bug central da sua
pergunta original.**

**(b) O motor converte à força destinos em "agachado atrás de cobertura".**
`AIFindDestinations` (CombatAI.lua:679–704), *antes de qualquer policy rodar*:

```lua
for i, dest in ipairs(destinations) do
    local x, y, z, stance_idx = stance_pos_unpack(dest)
    if stance_idx ~= crouch_idx then                     -- Prone e Standing entram aqui
        local cost = change_stance_costs[stance_idx]
        local ap = dest_ap[dest]
        if cost and ap and ap >= cost then
            local up, right, down, left = GetCover(x, y, z)
            if up and (up == low or right == low or down == low or left == low) then
                destinations[i] = stance_pos_pack(x, y, z, crouch_idx)   -- vira Crouch
                dest_ap[new_dest] = ap - cost                            -- e paga o AP
            end
        end
    end
end
```

Para o `HeavyGunner` (`PrefStance = Prone`, `MoveStance = Standing` por default) **todo destino
alcançável com cobertura baixa adjacente é convertido em Crouch**. Efeitos em cadeia:

- o LOS daquele tile passa a ser calculado **agachado**, não deitado;
- `dest_ap` é reduzido pelo custo da troca de postura;
- `AIBehavior:EndMovement` agacha a unidade ao chegar;
- o `MGSetup` depois tem que deitar de novo.

É um viés pró-cobertura hardcoded, não desligável por configuração, e é **a causa mais direta do
"ele vai pra trás de cobertura e não consegue ver nada"**.

**(c) O check de disponibilidade do `MGSetup` ignora a postura prone.**
`AIActionMGSetup:PrecalcAction` faz:

```lua
action_state.stance = "Prone" -- MGSetup will change the stance so we need to check LOS in that stance
AIActionBaseConeAttack.PrecalcAction(self, context, action_state)
```

que repassa para `AIPrecalcConeTargetZones(context, action_id, nil, action_state.stance)`. **O
parâmetro `stance` é declarado na assinatura e nunca usado no corpo da função** (CombatAI.lua:2040).
Dentro dela, tudo é medido da postura atual:

```lua
local attack_pos = unit:GetPos()
local los_any, los_targets = CheckLOS(units, unit, unit:GetDist(target_pos), nil, cone_angle, angle)
local targets_attack_data = GetLoFData(unit, targets, { ..., stance = unit.stance, ... })
```

Ou seja: **a IA decide montar a MG com base na linha de tiro que ela tem de pé (ou agachada), deita,
e pode perder a linha.** O comentário no código promete o contrário. Você não sobrescreve essa
função, então o bug está ativo no seu mod. Combinado com (b), é exatamente o cenário que você
descreveu.

**(d) Não há noção de aglomerado na escolha do tile.**
`AIPolicyLosToEnemy` é binário: "algum inimigo visível daqui". Um tile com LOF para 4 inimigos
alinhados e um tile com LOF para 1 inimigo recebem os mesmos 200 pontos. O agrupamento só entra
depois, na escolha da *direção* do cone. Falta uma policy que responda "quantos inimigos caberiam
no meu cone se eu deitasse aqui".
As duas que você escreveu para isso (`AIPolicyMGSetupPosScore`, `AIPolicyMGSetupAP`) **não estão
plugadas em nenhum arquétipo**, e `AIPolicyMGSetupPosScore` mede ângulo a partir da unidade, não do
tile candidato, além de chamar `Update_AIPrecalcDamageScore` dentro do `EvalDest` (caro por tile).

**(e) O gate é binário e local.** `Get_HeavyGunnerShouldUsePositioningBehavior` pergunta "consigo
montar **daqui**?", nunca "existe um tile melhor?". Como (c) mede a postura errada, a resposta
também pode estar errada.

Detalhes menores: `TakeCoverChance = 50` no `PositioningAI` contradiz o intento (na prática é
inofensivo, porque `AITakeCover` retorna cedo se `HasPreparedAttack()` ou se nenhuma signature
rodou — mas ponha 0 por clareza). E `AIPrecalcConeTargetZones` retorna `{}` se
`context.target_locked`, que só é setado por `StartCinematicCombatCamera` — durante uma cinemática,
`MGSetup`/`MGRotate` ficam indisponíveis.

### 9.3 Desenho revisado

Quatro peças. As duas primeiras são correções de motor; as duas últimas são conteúdo.

---

**Peça 1 — parar de agachar o gunner à força.**
Sobrescreva `AIFindDestinations` copiando o source e pulando a conversão quando o arquétipo prefere
prone (só o `HeavyGunner`, no seu mod):

```lua
-- em SOURCE_AIFindDestinations.lua
-- ... corpo idêntico ao source, exceto:
local skip_crouch_conversion = context.archetype.PrefStance == "Prone"
for i, dest in ipairs(destinations) do
    local x, y, z, stance_idx = stance_pos_unpack(dest)
    if not skip_crouch_conversion and stance_idx ~= crouch_idx then
        -- ... conversão original
    end
end
```

Efeito colateral desejável: os destinos alcançáveis do gunner passam a ser Prone/Standing, e o
`g_AIDestEnemyLOSCache` deles deixa de ser calculado agachado.

---

**Peça 2 — LOS sempre medido deitado, perto e longe.**
`AIEnumValidDests` usa `context.voxel_to_dest[world_voxel]` para tiles alcançáveis e
`stance_pos_pack(..., PrefStance)` para o resto. Isso faz o `g_AIDestEnemyLOSCache` medir prone
longe e Standing/Crouch perto — semântica inconsistente. Para um arquétipo prone, force a postura:

```lua
-- dentro do push_dest de AIEnumValidDests
local dest = context.voxel_to_dest[world_voxel]
if not dest or context.archetype.PrefStance == "Prone" then
    dest = stance_pos_pack(x, y, z, StancesList[context.archetype.PrefStance])
end
```

Como `AIUpdateDestLosCache` itera `context.all_destinations`, o cache passa a conter LOS **prone**
para todo tile do raio, de graça (é a mesma batelada de raycasts). `AIScoreReachableVoxels` continua
usando `context.destinations`, então o movimento não muda.

---

**Peça 3 — a policy que mede a qualidade da posição de tiro.**
Substitui o `AIPolicyMGSetupPosScore`. Responde: *"se eu deitasse aqui, quantos inimigos caberiam no
meu cone?"* — puro, sem tocar em `dest_ap`, `dest_target` nem `AIPrecalcDamageScore`, então é
seguro como `OptLocPolicy` (§13.3).

```lua
DefineClass.AIPolicyMGFiringPosition = {
    __parents = {"AIPositioningPolicy"},
    properties = {
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "end_of_turn",      editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "FirstEnemyScore",  editor = "number", default = 40,
         help = "score por conseguir cobrir pelo menos um inimigo"},
        {id = "ClusterBonus",     editor = "number", default = 30,
         help = "score adicional por cada inimigo extra no mesmo cone"},
        {id = "MaxScore",         editor = "number", default = 100},
        {id = "RequireLOS",       editor = "bool",   default = true},
    },
}

function AIPolicyMGFiringPosition:GetEditorView()
    return "MG: cobrir inimigos com o cone"
end

-- params do cone nao dependem do tile: calcula uma vez por turno
local function MG_Cone(context)
    local c = context.__mg_cone
    if c == nil then
        local weapon = context.weapon
        if not IsKindOf(weapon, "Firearm") or not CombatActions.MGSetup then
            context.__mg_cone = false
            return false
        end
        local p = weapon:GetAreaAttackParams("MGSetup", context.unit)
        local ang = p and p.cone_angle or 0
        if ang <= 0 then
            context.__mg_cone = false
            return false
        end
        c = {
            width     = ang,                                    -- minutos (21600 = 360 graus)
            min_range = (p.min_range or 0) * const.SlabSizeX,
            max_range = (p.max_range or 0) * const.SlabSizeX,
        }
        context.__mg_cone = c
    end
    return c
end

function AIPolicyMGFiringPosition:EvalDest(context, dest, grid_voxel)
    local cone = MG_Cone(context)
    if not cone then return 0 end

    local x, y, z = stance_pos_unpack(dest)
    local prone_dest = stance_pos_pack(x, y, z, StancesList.Prone)

    -- gate barato: LOS deitado ja esta em batelada no cache (ver Peca 2)
    if self.RequireLOS and not AIHasLOSToEnemyFromDest(prone_dest) then
        return 0
    end

    local from = point(x, y, z)
    if not from:IsValidZ() then from = from:SetTerrainZ() end

    -- inimigos dentro do anel de alcance do cone
    local angles, n = {}, 0
    for _, enemy in ipairs(context.enemies) do
        if not enemy:IsIncapacitated() then
            local epos = context.enemy_pos[enemy]
            if epos then
                local d = from:Dist2D(epos)
                if d >= cone.min_range and d <= cone.max_range then
                    n = n + 1
                    angles[n] = CalcOrientation(from, epos)
                end
            end
        end
    end
    if n == 0 then return 0 end

    -- maior aglomerado que cabe na largura do cone (janela deslizante circular)
    local best = 1
    for i = 1, n do
        local count = 0
        for j = 1, n do
            local diff = angles[j] - angles[i]
            if diff < 0 then diff = diff + 21600 end
            if diff <= cone.width then count = count + 1 end
        end
        if count > best then best = count end
    end

    local score = self.FirstEnemyScore + (best - 1) * self.ClusterBonus
    return Min(self.MaxScore, score)
end
```

Custo: uma varredura O(n²) sobre o número de inimigos (n = 4–8 na prática, ~50 comparações
inteiras) por tile, atrás de um gate de LOS que já está em cache. É ordens de magnitude mais barato
que o `AIPolicyMGSetupPosScore` atual.

Com os defaults acima: 1 inimigo = 40, 2 = 70, 3 = 100 (teto). É o gradiente contínuo que o
`AIPolicyLosToEnemy` binário não dá, **e ao mesmo tempo o critério de agrupamento**.

---

**Peça 4 — os behaviors.**

`OptLocPolicies` do arquétipo (a Best Pos = "de onde eu quero atirar"):

```
AIPolicyMGFiringPosition  300   -- cobrir inimigos com o cone, deitado: o critério principal
LosToEnemy                150   -- reforça o gate
Range                     100 @ 50–100%   -- preferência suave por standoff
Range                      15 @ 0–200%    -- catch-all: nunca deixa o score plano
LastEnemyPos               80   -- gradiente contínuo quando não há LOS de lugar nenhum
IndoorsOutdoors            60 (Indoors=false)
HighGround                 90   -- efetivo 81/nível; ajuda a passar por cima de cobertura
-- SEM policy de cobertura, de propósito
```

Note que a banda de alcance virou secundária: o `AIPolicyMGFiringPosition` já usa o alcance real do
cone (2 → `WeaponRange`) como filtro. O `Range @50–100%` só desempata a favor de ficar longe.

**Behavior A — aproximar (substitui o `PositioningAI` "MG Setup"):**
troque a classe para `StandardAI`, que é a única que calcula `best_dest` e o gradiente:

```
StandardAI  "Buscar posição de tiro"
  Score = 0 se já montado OU se MGSetup já está disponível daqui; senão Weight (300)
  OptLocWeight = 350                      -- alto: o objetivo é chegar lá
  turn_phase = "Normal"
  EndTurnPolicies:
      AIPolicyAttackAP           150      -- 0/100 normalizado: sobra AP pra montar?
      AIPolicyMGFiringPosition   200      -- se der pra montar já neste tile, ótimo
      AIPolicyLosToEnemy         100
      AIPolicyTryNotToBeFlanked   50      -- desempate, NÃO Required
  SignatureActions: AIActionMGSetup (Priority)
  TakeCoverChance = 0
```

`R = 350 / (150+200+100+50) = 0,7` — "chegue ao objetivo, mas aproveite se der pra montar no
caminho". Compare com o `R ≈ 0` de hoje.

Duas coisas importantes: `AIPolicyAttackAP` em vez de `AIPolicyDealDamage` (§15.2 — o `DealDamage`
cru esmagaria o gradiente), e **nenhum `Required`**, para a Best Pos nunca colapsar (§14.2 regra 6).

Reescreva o gate para comparar posições em vez de perguntar "daqui dá?":

```lua
function Get_HeavyGunnerShouldUsePositioningBehavior(behavior, unit, proto_context, debug_data)
    unit.ai_context = unit.ai_context or AICreateContext(unit, proto_context)
    local context = unit.ai_context
    if unit:HasStatusEffect("StationedMachineGun") or unit:HasStatusEffect("ManningEmplacement") then
        return false
    end
    local best = AIFindOptimalLocation(context)          -- cacheado em context.best_dest
    return best and stance_pos_dist(best, context.unit_stance_pos) > 0
end
```

Com isso, a **Falha A** (Best Pos = tile atual) deixa de ser bug e passa a ser o sinal correto:
"estou no melhor lugar, monte a arma".

**Behavior B — em setup (mantenha o `HoldPositionAI` "In Setup").**
Já está certo. "Atirar em qualquer alvo no cone" é garantido pelo source e o seu override
preservou (`SOURCE_AIPrecalcDamageScore.lua:130`):

```lua
if unit:HasStatusEffect("StationedMachineGun") or unit:HasStatusEffect("ManningEmplacement") then
    targets = table.ifilter(targets, function(idx, target)
        return target:IsThreatened({unit}, "overwatch")   -- só quem está dentro do meu cone
    end)
end
```

Rotação também já funciona: quando montado, `AIActionMGSetup:PrecalcAction` monta as zonas com
`curr_target_pt` no fim da lista, aplica `cur_zone_mod` nela, e emite `MGRotate` se outra zona
ganhar (ou `MGPack` se nenhuma passar o `min_score`). Seu `cur_zone_mod = 140` torna a zona atual 40%
melhor — é o botão anti-churn. Se ele rotaciona demais, suba para 160–180; se fica olhando pro vazio,
baixe.

**Behavior C — recuar (novo).**
"Exposto" para uma MG deitada quer dizer: inimigos com linha para mim **fora do meu cone**, perto.
Eles atiram e eu não posso responder sem gastar AP rotacionando.

```lua
function RATOAI_MGExposureScore(unit, proto_context)
    unit.ai_context = unit.ai_context or AICreateContext(unit, proto_context)
    local context = unit.ai_context
    if not unit:HasStatusEffect("StationedMachineGun") then return 0 end

    local pb    = const.Weapons.PointBlankRange * const.SlabSizeX
    local upos  = unit:GetPos()
    local score = 0

    for _, enemy in ipairs(context.enemies) do
        if not enemy:IsIncapacitated() and context.enemy_visible_by_team[enemy] then
            -- enemy:IsThreatened({unit}, "overwatch") == está dentro do MEU cone
            if not enemy:IsThreatened({unit}, "overwatch") then
                local d = upos:Dist(context.enemy_pos[enemy] or upos)
                if d <= pb * 2 then
                    score = score + 100
                elseif d <= pb * 4 then
                    score = score + 40
                end
            end
        end
    end

    if unit:IsThreatened() then score = score + 50 end   -- sob overwatch/pindown
    if MulDivRound(unit.HitPoints, 100, unit.MaxHitPoints) < 50 then score = score + 50 end

    return score
end
```

```
PositioningAI  "MG Recuar"
  Weight = 200,  Fallback = false
  Score  = MulDivRound(RATOAI_MGExposureScore(unit, proto_context), self.Weight, 100)
  EndTurnPolicies:
      AIPolicyLosToEnemy   200 (Invert = true)          -- quebrar linha
      AIPolicyProximity    800 (enemies, min)           -- afastar (retorno CRU em tiles, §13.4)
      AIPolicyDistanceFromStart 100 (Away, Distance=4, Required)  -- obrigar a sair do lugar
      AIPolicyCustomSeekCover 150                       -- aqui cobertura É desejável
  TakeCoverChance = 100
```

Aqui o `PositioningAI` é a classe **certa**: recuo é uma reação de um turno, e o
`opt_loc_weight = 0` hardcoded é o comportamento desejado. `Required` também é apropriado — se não
houver rota de fuga, o `PositioningAIScore` retorna 0 e o behavior é corretamente descartado em
favor do "In Setup".

E não precisa de nenhum `MGPack`: `Unit:Move` desmonta de graça (§9.0 item 5).

> A simetria vale como regra geral: **`PositioningAI` é a classe correta para movimentos reativos
> de um turno (recuar, flanquear) e a classe errada para buscar um objetivo de vários turnos.**

### 9.4 Ordem de implementação sugerida

1. Peça 1 (não agachar) — isolada, efeito imediato e visível.
2. Peça 2 (LOS prone consistente) — pré-requisito da Peça 3.
3. Peça 3 (`AIPolicyMGFiringPosition`) nas `OptLocPolicies`, ainda com o behavior antigo.
   Confira no `IModeAIDebug` se a Best Pos passou a cair em posições de tiro plausíveis.
4. Peça 4 Behavior A (`StandardAI` + `OptLocWeight` alto) — é aqui que a aproximação aparece.
5. Peça 4 Behavior C (recuo) — por último, porque depende de o gunner já se posicionar bem.

O bug (c) (`stance` ignorado em `AIPrecalcConeTargetZones`) fica **em aberto**: consertar de
verdade exige reescrever a função para aceitar `step_pos`/`stance` e repassá-los a `CheckLOS` e
`GetLoFData`. As Peças 1 e 2 reduzem muito a exposição a ele (o gunner deixa de ser agachado à
força e a Best Pos passa a ser escolhida com LOS prone), mas o check final de disponibilidade do
`MGSetup` continua medindo a postura atual.


## 10. Ferramentas de debug

**Modo visual da IA** — `CheatOpenAIDebug()` (`Lua/Cheat.lua:832`), só funciona com
`g_Combat` ativo e fora de multiplayer. Abre `IModeAIDebug`:

- Recalcula o think da unidade selecionada do zero (`unit.ai_context = nil; unit:StartAI(...)`).
- Mostra, por voxel: score da **Optimal Location** decomposto policy a policy, score de
  **End Turn** decomposto, AP disponível em cada stance, distância de pathfinding até a Best Pos.
- Permite **forçar** um behavior (`UnitForceBehavior`) ou uma action (`UnitForceAction`) e ver o
  resultado.
- Seu `DEBUG.lua` já estende `IModeAIDebug:GetVoxelRolloverText` com os debugs das suas policies
  (`dest_flanking_pol_debug`, `dest_custom_seek_cover_debug`, `aims_at`).

Este é **a ferramenta certa** para o problema de aproximação: selecione o gunner distante, olhe
onde o marcador de Best Pos caiu. Se ele está em cima da própria unidade, é a Falha A. Se está
num tile próximo qualquer, é a Falha C. Se todos os voxels mostram score 0, é a Falha B/E.

**Log textual** — `g_AIExecutionController.enable_logging = true` popula `g_LastTurnAILog` com
behavior escolhido, signature action escolhida, alvo, número de ataques e resultado de cada um.

**Outros:** `dbgShowAIDestCache()` (CombatAI.lua:851) desenha o cache de LOS;
`DbgShowLastSelectedZone()` (AIActions.lua:176) desenha o polígono da última zona de cone
escolhida — útil justamente para MG/overwatch/buckshot.

### 10.1 `context.dbg_targets` — por que a IA escolheu **aquele** alvo

Marcador de rastreio no código: `---- DEBUG (D1)`.

`AIPrecalcDamageScore` avalia **todos** os alvos em **todos** os destinos, mas só o
vencedor sobrevive da função: `dest_cth`, `dest_hit_score` e `dest_target_score` guardam
`best_*`, e as tabelas `target_cth` / `target_hit` / `target_score` são locais do laço de
destinos. Não havia como perguntar *"e contra o alvo #3, quanto seria o CTH"*.

`context.dbg_targets[dest]` repõe esse eixo. Só existe com `RATOAI_Debug` (mesmo critério
de custo do `PERF (C9)`), é zerado a cada chamada do precalc e tem esta forma:

```lua
context.dbg_targets[dest] = {
    ap, cost_ap, no_ap,          -- orçamento do destino
    best_score, threshold,       -- o corte de AIDecisionThreshold (80%)
    total, roll,                 -- o sorteio ponderado entre finalistas
    finalists = { <alvo>, ... },
    chosen, preferred,
    by_target = {
        [<alvo>] = {
            dist, cover, los, recoil,
            shots,               -- nº de disparos (varia com a DISTÂNCIA)
            cth1,                -- CTH do 1º disparo
            hit,                 -- soma de CTH sobre os disparos, já com recoil
            score,               -- score final do alvo
            reject,              -- motivo do descarte, quando houve
            chain = { hit, pos, base, pol, pol_parts, downed, ff, rnd, rnd_pct,
                      group, group_pct, final },
        },
    },
}
```

Três coisas que só ficam visíveis com isso:

1. **`best_target` não é o de maior score.** É um sorteio ponderado
   (`InteractionRand`) entre os finalistas ≥ 80% do melhor. Somado ao
   `TargetScoreRandomization` do arquétipo (10 a 40 no vanilla — ±40% em alguns), a
   ordenação chega bem ruidosa no sorteio. Sem `roll`/`total` não dá para separar
   *"o scoring escolheu mal"* de *"o dado caiu assim"*.
2. **`shots` varia com a distância** (`AICalcAttacksAndAim(context, ap, target_dist)`),
   então `hit` — a soma de CTH — não é comparável entre dois alvos sem olhar quantos
   disparos cada soma tem dentro.
3. **Motivo do descarte.** `fora de alcance`, `sem linha de fogo`,
   `linha de fogo bloqueada` e `soma de CTH <= AIShootAboveCTH` eram todos o mesmo `-`.

Consumidor: a página **Alvo** do `RATODBG_AIDebugUI.lua` (mod *Rato Dev*) — tabela de
candidatos com a cadeia aberta, `p%` de cada finalista, e um cartão por alvo com o CTH
disparo a disparo (de `cth_attacks_at` / `aims_at`).

**Congelamento da randomização.** Todo precalc disparado pela UI re-sorteia
`target_score_mod`, ou seja, o número muda só por ter sido observado.
`IModeAIDebug:PrecalcForDebug` seta `context.dbg_freeze_target_rand` antes de chamar, e o
precalc então reaproveita o sorteio anterior. O `RandRange` continua sendo consumido
mesmo congelado — pular a chamada dessincronizaria o fluxo de RNG da unidade.

### 10.2 O overlay pontuava as ações num momento que o turno real não tem

Marcador: `---- DEBUG (D3)`, em `IModeAIDebug:Process` (mod *Rato Dev*).

O vanilla (`Lua/UI/IModeAIDebug.lua:117`) chama, nesta ordem:

```lua
context.behavior:Think(...)
AIChooseSignatureAction(context)                       -- CustomScoring roda AQUI
AIPrecalcDamageScore(context, {ai_destination}, ...)   -- alvo do destino só DEPOIS
```

O turno real (`AIPlayAttacks`, CombatAI.lua:216-232) faz **o contrário**: precalc do destino
único primeiro, escolha da signature depois. E isso não é detalhe de ordem — toda
`CustomScoring` lê `context.dest_target[upos]` pelo `GetDestArgs`, e o precalc de destino
único **reescreve** esse alvo.

Caso medido (LegionGunner:412, turno 1, destino 157800/177000):

| | alvo | dist | CTH | resultado |
|---|---|---|---|---|
| `MGSetup_CustomScoring` (antes do precalc) | Barry | 24621 (20 tiles) | 0 | `hits = 0` → peso 250 |
| página Alvo (depois do precalc) | Grizzly | 3600 (3 tiles) | 47 | 2 ataques, 2,1 acertos |

As duas páginas do mesmo painel falavam de momentos diferentes. Pior: a 3 tiles o portão de
`RATOAI_GetCloseRange` teria **desabilitado** a `MGSetup` — ou seja, o painel mostrava com peso
inflado uma ação que o turno real nem teria listado. Um bug fantasma inteiro, só do observador.

O `Process` do *Rato Dev* passou a ser cópia do vanilla com a ordem do `AIPlayAttacks`, mais dois
detalhes que o painel não replicava: `dest_ap[dest] = dest_ap[dest] or unit.ActionPoints` e o
`preferred_target` (no turno real o alvo do sweep tem preferência no recálculo —
`SOURCE_AIPrecalcDamageScore.lua:520` dá `break` nele; passando `nil`, o painel re-escolhia do
zero). **Limite conhecido:** o `AIPlayAttacks` remove o `FreeMove` antes de tudo isso e o painel
não pode remover (seria mexer no estado da unidade fora do turno dela), então para destinos
dentro da franquia de free move o `leftover_free` do `BUGFIX (B19)` desconta no painel e não no
turno — diferença de até um tiro na contagem.

### 10.3 Contra quem o resultado esperado foi medido

Marcador: `---- DEBUG (D4)`.

`RATOAI_ExpectedFor` **não escolhe alvo** — ele mede o que o `dest_target[upos]` entregou. Sem
registrar quem foi, `razão 250 com 0.00 acerto` é indistinguível de `0.00 acerto contra o alvo
errado`; recuperar isso custou uma sessão de DAP lendo `dbg.dist` e cruzando com
`dest_target_dist`. Agora `dbg.alvo` sai junto de custo/balas/ataques, e as `CustomScoring` que
montam a linha à mão (`MGSetup`, `PrepareWeapon`) gravam `alvo` (e `dist`, no MGSetup) direto na
linha. A página Ações imprime `alvo: <id> (N tiles)` embaixo da razão.

### 10.4 Desabilitada ≠ indisponível

Marcador: `---- DEBUG (D5)`.

São dois portões diferentes, param em pontos diferentes do laço do `AISelectAction`, e o painel
só enxergava um deles:

| estado | quem decide | `PrecalcAction` roda? | o que aparecia antes |
|---|---|---|---|
| **desabilitada** | bias, `disable_actions`, ou o 2º retorno da `CustomScoring` | não | **nada** — sumia da lista |
| **indisponível** | `IsAvailable` (AP, munição, CTH, alvo) | sim | linha cinza com `false` |

A ação desabilitada não era inserida em `dbg_available_actions`, então quem olhava via uma lista
com um item a menos e nenhuma pista de que ele existia — e o `IndisponivelPorque` do painel não
tinha `action_state` nenhum para ler (ele só poderia dizer `[não avaliada]`, que é verdade e é
inútil). Agora as duas entram com `weight = false`, e `disabled_by` (`"CustomScoring"` ou
`"bias"`) separa uma da outra; o painel escreve `desabilitada pela CustomScoring` /
`desabilitada pelo bias` / `[falta: AP, munição, …]`. A telemetria carrega o mesmo campo em `off`.

---

## 11. Armadilhas e bugs do source (importantes para modding)

1. **`AISelectAction` — roleta quebrada no vanilla** (CombatAI.lua:618):
   ```lua
   for _, action in ipairs(available) do
       local w = available[action]
       if roll <= weight then return action end   -- compara com `weight` (o total!), não `w`
       roll = roll - weight
   end
   ```
   Como `roll < weight` sempre, **a primeira ação disponível sempre vence**. A ordem da lista de
   signature actions do vanilla é, na prática, uma lista de prioridade. Seu
   `SOURCE_AISelectAction.lua` corrige (`if roll <= w`), o que muda o comportamento de todos os
   arquétipos — inclusive os que você não redefiniu. Vale ter isso em mente ao comparar com o
   vanilla.

2. **`AIScoreReachableVoxels` — soma errada** (CombatAI.lua:1790):
   ```lua
   local total = 0
   for _, score in ipairs(potential_dests) do total = total + score end
   ```
   Itera `potential_dests` (que contém `dest` empacotados — inteiros gigantes) em vez de
   `dest_scores`. O `total` fica astronômico, o `roll` quase sempre cai fora, e o loop seguinte
   (`if score <= roll`) devolve o **primeiro** destino de `potential_dests` — que é sempre
   `curr_dest`. Efeito colateral: **a IA vanilla tem um viés forte a ficar parada.** Você não
   corrigiu isso; corrigir muda muita coisa (para melhor, provavelmente, mas é uma mudança grande
   e vale testar isolada).

3. **`AIGetActionWeight` é código morto** — `action_state.score` calculado pelas
   `PrecalcAction` (zone attacks, MG setup) nunca influencia a escolha no vanilla.

4. **`AIPrecalcConeTargetZones` ignora o parâmetro `stance`** (CombatAI.lua:2040). Ele está na
   assinatura, `AIActionMGSetup:PrecalcAction` passa `"Prone"` com um comentário explicando por que
   é necessário, e o corpo nunca o lê: `attack_pos = unit:GetPos()`, `CheckLOS(units, unit, ...)` e
   `GetLoFData(..., stance = unit.stance, ...)` usam todos a postura **atual**. A disponibilidade do
   `MGSetup` é avaliada de pé/agachado e executada deitado. Ver §9.2c.

5. **`AIFindDestinations` converte destinos em Crouch atrás de cobertura baixa**
   (CombatAI.lua:679–704) — antes de qualquer policy rodar, gastando AP, e **sem respeitar
   `archetype.PrefStance`**. Para arquétipos prone (HeavyGunner) isso sabota o posicionamento e
   contamina o `g_AIDestEnemyLOSCache` com LOS medido na postura errada. Não é desligável por
   configuração. Ver §9.2b.

6. **`AIAltArchetypeOnAllyDeath`** (AIBase.lua:138) conta `dead = dead + 1` para **todo** aliado,
   vivo ou morto. Nunca funcionou.

7. **`AICMyStatusEffect:Score`** (ClassDef-AI.lua:271) usa a variável global `id`, inexistente.

8. **`AIPolicyProximity` com `TargetDist = "average"`** divide por `num`, que nunca é
   incrementado. Só `"min"` e `"total"` funcionam.

9. **`AIPolicyIndoorsOutdoors:EvalDest` retorna booleano**, não número — vira `1`/`0` na
   aritmética. Seu `SOURCE_AIPolicyIndoorsOutdoors_EvalDest.lua` já mexe nisso.

10. **Custo de performance**: `EvalDest` roda para **cada tile candidato** — `all_destinations`
   pode ter centenas de entradas num raio de 80–100 tiles. Qualquer coisa dentro de uma policy que
   faça raycast, `GetLoFData`, `AIPrecalcDamageScore` ou alocação de tabela vai multiplicar por
   N. Cacheie no `context` por `grid_voxel` (é o que `AIPolicyStimRange` faz com
   `context.voxel_stim_score`).

---

## 12. Referência rápida — onde mexer para obter o quê

| Quero que… | Mexo em |
|---|---|
| unidade X use outro arquétipo | `PickCustomArchetype` no UnitDataDef |
| a IA escolha entre posturas diferentes no mesmo turno | `Behaviors` do arquétipo + `Score` de cada um |
| a IA saiba **onde queria estar** (longo prazo) | `archetype.OptLocPolicies` + `OptLocSearchRadius` |
| a IA **caminhe** em direção a esse lugar | behavior que chame `AIFindOptimalLocation` (`StandardAI`/`CustomAI`) + `OptLocWeight` alto |
| a IA escolha melhor **onde parar hoje** | `behavior.EndTurnPolicies` |
| a IA escolha melhor **em quem atirar** | `archetype.TargetingPolicies` / `behavior.TargetingPolicies` |
| uma ação especial seja mais/menos frequente | `action.Weight` + `CustomScoring` (seu) + `archetype.BaseAttackWeight` |
| uma ação seja usada no máximo 1x/turno pelo time | `OnActivationBiases` com `Effect="disable"`, `Period=0`, `ApplyTo="Team"` |
| uma unidade aja antes/depois das outras | `behavior.turn_phase` (`Early`/`Normal`/`Late`) |
| a IA reavalie o turno ao matar o alvo | `archetype.TargetChangePolicy = "restart"` |
| a IA não fique parada sem fazer nada | `archetype.FallbackAction = "overwatch"` |
| empurrar a IA para fora/dentro de uma região do mapa | Bias Markers (no editor de mapa) |

---

## 13. Comparação: suas `OptLocPolicies` vs. as vanilla

### 13.1 Tabela lado a lado

| Arquétipo | Vanilla | Seu mod |
|---|---|---|
| **Soldier** | TakeCover 50 · HighGround 200 · **LosToEnemy 300** · Range 50 @10–25% · Range 100 @26–49% · **Range 150 @50–100%** · raio 80 | CustomSeekCover 150 · LosToEnemy 100 · **Range 200 @30–50%** · Range 20 @51–100% · TryNotToBeFlanked 50 · raio 80 |
| **HeavyGunner** | **Range 600 @40–80%** · LosToEnemy 200 · raio 80 | Range 200 @30–50% · Range 20 @51–100% · **LosToEnemy 200** · Indoors=false 50 · raio 100 |
| **Skirmisher** | Range 300 @2–8 tiles (abs) · LosToEnemy 100 · raio 80 | Range 100 @5–12 (abs) · Range 20 @13–30 (abs) · LosToEnemy 100 · TryNotToBeFlanked 50 · CustomSeekCover 150 · raio 80 |
| **Brute** | Range 100 melee · LosToEnemy 100 · raio 80 | Range 500 melee · Range 100 @0–10 (abs) · Range 20 @11–30 (abs) · LosToEnemy 100 · TryNotToBeFlanked 50 · CustomSeekCover 100 · raio 80 |
| **Medic** | TakeCover 100 · LosToEnemy 100 | **CustomSeekCover 350** · LosToEnemy 100 |
| **Scout_LastLocation** | LastEnemyPos 100 | **LastEnemyPos 500** · CustomSeekCover 100 |
| **Artillery** | Range 100 @20–50 (abs) — só isso | *(substituído por `RATOAI_Demolition` / `RATOAI_Rocketeer`)* |
| **RATOAI_Sniper** | — | HighGround 80 · LosToEnemy 100 · Range 200 @30–50% · Range 60 @51–75% · Range 40 @76–120% · raio 100 |
| **RATOAI_Rocketeer** | — | Range 300 @12–18 (abs) · Range 50 @19–30 (abs) · LosToEnemy 300 · Indoors=false 100 · HighGround 20 · raio 100 |
| **RATOAI_Demolition** | — | LosToEnemy 100 · Indoors=false 100 · GrenadeRange 150 @30–50% · Range 80 @30–50% · Range 10 @51–100% · CustomSeekCover 150 · HighGround 10 · raio 100 |

### 13.2 O que mudou de fato

**(a) Você inverteu a preferência de distância do Soldier.**
Vanilla: `50–100%` do alcance vale **150**, `26–49%` vale 100, `10–25%` vale 50 — o soldado vanilla
**prefere ficar longe**. Seu mod: `30–50%` vale **200**, `51–100%` vale 20 — o seu soldado
**prefere fechar para média distância**. É uma escolha de design legítima (e coerente com o GBO,
onde a precisão a longa distância caiu), mas é uma inversão total, não um ajuste.

**(b) O peso relativo do LOS caiu no Soldier — e subiu no HeavyGunner, corretamente.**
Vanilla Soldier: LOS = 300 de um orçamento de ~500 (60%). Seu Soldier: LOS = 100 de ~500 (20%).
Vanilla HeavyGunner: LOS = 200 contra Range 600 (25%). Seu HeavyGunner: LOS = 200 contra
Range 200+20 (48%). Para a MG **essa inversão está certa**: o que habilita o `MGSetup` é ter LOF
para os inimigos, e a distância é secundária — o cone do setup alcança o `WeaponRange` **inteiro**
(§9.0). O que falta não é reduzir o LOS; é o LOS binário virar uma medida de *quantos* inimigos
entram no cone a partir daquele tile.

**(c) Cobertura passou a ser um pilar do posicionamento estratégico — exceto no HeavyGunner.**
Vanilla usa `AIPolicyTakeCover` com peso 50 (Soldier) ou nem usa (HeavyGunner, Skirmisher,
Artillery). Você usa `AIPolicyCustomSeekCover` com 100–350 em Soldier, Skirmisher, Brute, Medic,
Sniper, Demolition, Scout e Pierre. Isso é o que faz a sua IA "usar mais cobertura" — mas é também
a causa direta da **Falha A** da seção 8 nesses arquétipos: como a unidade normalmente já está
atrás de alguma cobertura, o tile atual tende a entrar nos finalistas de 80% e a Best Pos colapsa
na posição atual.

O **HeavyGunner não tem policy de cobertura no OptLoc**, e isso está certo: ele deita para montar
a MG, e cobertura baixa bloqueia a linha de tiro de quem está prone. O risco de colapso da Best
Pos nele é baixo — o problema dele é outro (§9).

**(d) Você abandonou o `AIPolicyHighGround` — e, onde usou, ele está quase nulo.**

> ⚠ **Bug de escala.** `AIPolicyHighGround:EvalDest` retorna `self.Weight * (z - uz)`, e
> `AIScoreDest` depois faz `MulDivRound(peval, policy.Weight, 100)`. O peso entra **ao quadrado**:
> contribuição real = `Weight² / 100 × Δz`.

| | Weight | Efetivo por nível Z |
|---|---|---|
| Soldier vanilla | 200 | **400** |
| RATOAI_Sniper | 80 | 64 |
| TheMajor | 30 | 9 |
| RATOAI_Rocketeer | 20 | 4 |
| RATOAI_Demolition | 10 | **1** (nulo) |
| Soldier (seu) | — | 0 |

O soldado vanilla ganha 400 pontos por nível de elevação — mais do que o LOS inteiro. É o que faz
a IA vanilla subir em telhados. Seus valores de 10–30 são ruído numérico. Se você quer que o
sniper prefira altura de forma comparável a uma banda de alcance (200), o `Weight` precisa ser
~**140–160**, não 80.

**(e) O ponto mais importante: o GBO3 aumentou os alcances das armas, e suas bandas percentuais
andaram junto.**

`AIPolicyWeaponRange` com `RangeBase = "Weapon"` usa `context.ExtremeRange = weapon.WeaponRange`
(alcance **total**, não o efetivo). O GBO3 sobe esses valores em ~50%:

| Arma | Vanilla | GBO3 |
|---|---|---|
| AK47 / AK74 / AR15 | 24 | 36 / 36 / 32 |
| M16A2 | 24 | 34 |
| HK21 / FN Minimi | 30 | 36 |
| Dragunov SVD | 30 | 36 |

Traduzindo as bandas para tiles reais:

| | Banda | Vanilla (AK47, 24) | GBO3 (AK74, 36) |
|---|---|---|---|
| Soldier vanilla | 10–25% | 2,4 – 6,0 | — |
| Soldier vanilla | 26–49% | 6,2 – 11,8 | — |
| Soldier vanilla | 50–100% | 12,0 – 24,0 | — |
| **Soldier seu** | 30–50% | — | **10,8 – 18,0** |
| **Soldier seu** | 51–100% | — | 18,4 – 36,0 |

**Resultado: entre 0 e ~11 tiles do inimigo, as duas policies de alcance do seu Soldier retornam
0.** No vanilla, essa faixa era coberta por duas bandas. Onze tiles é a distância de combate mais
comum do jogo. Nessa faixa o seu `best_dest` é decidido **exclusivamente** por
`CustomSeekCover(150) + LosToEnemy(100) + TryNotToBeFlanked(50)` — três policies que premiam
ficar onde já se está. É aqui que a IA "trava" e passa a trocar de cobertura em vez de manobrar.

O mesmo vale para o HeavyGunner (0–10,8 tiles zerados) e o Sniper (0–10,8 tiles zerados, com o
agravante de armas de 36–42 tiles → 0–12,6).

**Não afeta** `Skirmisher`, `Brute`, `Rocketeer` e `RetreatingMarksman`, que usam
`RangeBase = "Absolute"` — imunes à inflação de alcance do GBO. Foi a decisão certa nesses casos.

**(f) Raio de busca.** Você subiu de 80 para 100 no Sniper, HeavyGunner, Demolition e Rocketeer.
Coerente com os alcances maiores do GBO3. O Soldier ficou em 80 — com AK74 de 36 tiles, 80 ainda
é ~2,2× o alcance da arma, o que é suficiente.

### 13.3 Armadilha: policies que dependem de dados que ainda não existem

Na ordem de `StandardAI:Think`, **`AIFindOptimalLocation` roda ANTES de `AIPrecalcDamageScore` e
de `AICalcPathDistances`**. Portanto, durante a avaliação da Best Pos:

- `context.dest_ap[dest]` é **nil** para todo tile fora do alcance de movimento deste turno
  (só `context.destinations` têm AP calculado);
- `context.dest_target[dest]` está **vazio**;
- `context.dest_dist` **não existe**.

Consequência: qualquer policy que consulte esses campos e retorne 0 quando estiverem ausentes
**dá 0 em todo tile distante** — exatamente onde ela mais precisaria funcionar.

O source respeita isso: `AIPolicyDealDamage` e `AIPolicyAttackAP` declaram **só** `end_of_turn`.
`AIPolicyFlanking` declara os dois mas usa `dest_ap` — é uma armadilha do próprio vanilla.

No seu mod, duas classes declaram `optimal_location = true` **e** dependem de `dest_ap`/`dest_target`:

- `AIPolicyCustomFlanking` — usa `dest_ap` (`ReserveAttackAP`) e `dest_target` (`OnlyTarget`).
  Hoje só está em `EndTurnPolicies`, então está OK — mas é uma mina se você a mover para
  `OptLocPolicies`.
- `AIPolicyMGSetupPosScore` — usa `context.dest_ap[dest]` com `ReserveAPforCrouchProne`, e chama
  `Update_AIPrecalcDamageScore` de dentro do `EvalDest`. **Se você plugar essa policy nas
  `OptLocPolicies` do HeavyGunner (que é o plano da seção 9), ela vai zerar todo tile fora do
  alcance de movimento se `ReserveAPforCrouchProne` estiver ligado.** Deixe essa flag em `false`
  no uso como OptLoc, ou remova a dependência de `dest_ap`.

### 13.4 Armadilha: normalização inconsistente entre suas policies

| Policy | Faixa de retorno | Escala com nº de inimigos? |
|---|---|---|
| `AIPolicyLosToEnemy` | 0 / 100 | não |
| `AIPolicyWeaponRange` | 0 / 100 (degrau) | não (é um OR) |
| `AIPolicyTryNotToBeFlanked` | 0 / 100 | não |
| `AIPolicyCustomSeekCover` | −100 … +100 (×2,2 com `ScalePerDistance`) — **média** | não ✔ |
| `AIPolicyCustomFlanking` | ±200 **por inimigo, somado** | **sim** ⚠ |
| `AIPolicyHighGround` | `Weight × Δz`, ilimitado | não |
| `AIPolicyDealDamage` | score de alvo cru (centenas) | indiretamente |
| `AIPolicyProximity` | distância em tiles, cru | sim (`total`/`average`) |

`AIPolicyCustomFlanking` somar por inimigo em vez de tirar média significa que, com 8 inimigos
visíveis, um `Weight = 50` pode render 400–800 pontos e engolir todas as outras policies. Com 2
inimigos, rende 100–200. **O comportamento da IA muda com o tamanho do esquadrão inimigo**, o que
é quase certamente não intencional. Dividir por `#enemies` (como o `CustomSeekCover` já faz)
resolveria.

---

## 14. Boas práticas para definir a Best Pos

### 14.1 O contrato mental

> A Best Pos responde a **uma** pergunta: *"se eu pudesse teletransportar esta unidade para
> qualquer tile num raio de N, para onde eu a mandaria?"*
>
> Não é "onde eu consigo chegar", não é "de onde eu atiro melhor agora", não é "onde estou
> seguro". É o **objetivo tático de médio prazo do papel daquela unidade**.

Se a resposta para o seu arquétipo for "depende do AP que sobrou", você está escrevendo uma
`EndTurnPolicy`, não uma `OptLocPolicy`.

### 14.2 As sete regras

**1. A Best Pos nunca pode ser "onde eu já estou" por acidente.**
Esse é o modo de falha que mata o sistema inteiro (Falha A, seção 8). Duas defesas:

- **Estrutural:** o grosso do orçamento da Best Pos deve vir de propriedades que o tile atual
  *tipicamente não tem* — estar na banda de alcance certa, ter elevação, estar do lado certo do
  inimigo. Cobertura e "não estar flanqueado" são propriedades que a posição atual quase sempre
  já satisfaz; elas devem ser **critérios de desempate, não pilares**.
- **Explícita:** quando você *quer* forçar reposicionamento, use
  `AIPolicyDistanceFromStart { Away = true, Distance = N, Required = true }`. É a única policy do
  jogo feita para isso e você não a usa em lugar nenhum.

**2. Cubra todo o domínio de distância, sem buracos.**
`AIPolicyWeaponRange` é um **degrau**, não uma rampa: 100 dentro da banda, 0 fora. Uma escada de
bandas aproxima uma rampa. Regra prática: a soma das bandas deve cobrir de `0` até
`~130%` do alcance, sem lacuna. Uma banda larga de peso baixo como catch-all
(`RangeMin=0, RangeMax=200, Weight=10`) garante que o score nunca seja totalmente plano.

**3. Tenha pelo menos uma policy contínua e monotônica na distância ao inimigo.**
Sem isso, todos os tiles dentro de uma banda empatam, o limiar de 80% os transforma em
finalistas, e o `pf.GetPosPath` escolhe o mais próximo — a unidade nunca compromete com o
objetivo (Falha C). Candidatas: `AIPolicyHighGround` (contínua em Δz, boa como desempate),
`AIPolicyLastEnemyPos` (contínua, decai linearmente com a distância à última posição conhecida —
subutilizada; você só a usa no Scout e no MG), ou uma policy custom de aproximação.

**4. Normalize tudo em 0…100 e deixe o `Weight` ser o único botão.**
Isso vale principalmente para as policies que você escreve. Média sobre inimigos, não soma.
E lembre da armadilha do `HighGround` (peso ao quadrado).

**5. Escolha um orçamento e distribua percentualmente.**
Fixe um teto (500 é um número confortável, e coincidentemente é o que tanto o vanilla quanto o
seu Soldier já têm) e distribua:

| Camada | % do orçamento | Papel |
|---|---|---|
| Banda de distância / geometria de tiro | **40–60%** | define o papel tático |
| LOS | 15–25% | filtro suave |
| Elevação / indoor-outdoor | 10–20% | qualidade do terreno |
| Cobertura / não-flanqueado | **10–20%** | desempate, não pilar |
| Catch-all de longo alcance | 5–10% | garante gradiente sempre |

Compare com o seu Soldier hoje: distância 44%, LOS 20%, elevação 0%, cobertura 40%. A cobertura
está ocupando o dobro do que deveria e não há nada de elevação nem catch-all.

**6. `Required` nas `OptLocPolicies`: praticamente nunca.**
`AIFindOptimalLocation` **não tem fallback bom**: se tudo der 0, `best_dest` vira a posição atual
e o gradiente de longo prazo morre em silêncio. Use `Required` em `EndTurnPolicies` de um
`PositioningAI`, onde zerar tudo tem um efeito *útil* (o `PositioningAIScore` retorna 0 e o
behavior é corretamente descartado em favor de outro).

**7. Nada de `dest_ap`, `dest_target` ou `dest_dist` dentro de uma `OptLocPolicy`.**
Ver 13.3. Se precisar de "tenho AP para atacar de lá", isso é uma `EndTurnPolicy`
(`AIPolicyAttackAP`).

### 14.3 Receitas por papel

**Fuzileiro / Soldier** — quer estar na banda de tiro efetivo, com LOS, de preferência alto.
```
Range   200 @ 15–45%      -- banda principal (com AK74/36 → 5,4–16 tiles)
Range   120 @ 46–85%      -- banda secundária
Range    10 @ 0–200%      -- catch-all: nunca deixa o score plano
LosToEnemy      200
HighGround      120        -- efetivo 144/nível
CustomSeekCover  80        -- desempate
TryNotToBeFlanked 40       -- desempate
```

**Heavy Gunner** — quer uma posição de tiro: cone cobrindo o máximo de inimigos, ao ar livre,
deitado. Ver §9.3 Peça 4 para a versão completa e comentada.
```
MGFiringPosition 300       -- quantos inimigos cabem no cone daqui (§9.3 Peça 3)
LosToEnemy       150
Range            100 @ 50–100%   -- preferência suave por standoff
Range             15 @ 0–200%    -- catch-all
LastEnemyPos      80       -- gradiente contínuo quando não há LOS de lugar nenhum
IndoorsOutdoors   60 (Indoors=false)
HighGround        90       -- efetivo 81/nível; ajuda a passar por cima de cobertura
```
**Nenhuma policy de cobertura**, e isso é deliberado: o gunner deita para montar a MG, e cobertura
baixa bloqueia a linha de tiro de quem está prone. Cobertura só aparece no behavior de recuo.

**Sniper** — elevação e distância são o papel inteiro.
```
Range   200 @ 45–110%
Range    60 @ 20–44%
Range    20 @ 0–200%
HighGround      150        -- efetivo 225/nível: o diferencial do sniper
LosToEnemy      150
CustomSeekCover  60
```

**Skirmisher / Brute** — `Absolute` está certo; adicione só o catch-all e um gradiente.
```
Range 300 @ 2–8 (abs)  ·  Range 60 @ 9–20 (abs)  ·  Range 15 @ 0–100 (abs)
LosToEnemy 100  ·  CustomSeekCover 50
```

---

## 15. Balanceando Best Pos (`OptLocWeight`) vs. destino alcançável

### 15.1 O que está sendo comparado

Em `AIScoreReachableVoxels`, cada destino alcançável recebe:

```
score(dest) = dist_score(dest)  +  Σ EndTurnPolicies(dest)
              └─ 0 … OptLocWeight   └─ orçamento das policies de fim de turno
```

`dist_score` vale `OptLocWeight` no tile mais próximo da Best Pos e `0` no mais distante,
linearmente. Então a razão que decide tudo é:

```
                 OptLocWeight
  R  =  ─────────────────────────────────
        Σ (peso máximo das EndTurnPolicies)
```

- `R ≈ 0,1` → a unidade **ignora** o objetivo e otimiza o turno local. É a IA vanilla.
- `R ≈ 0,5` → equilíbrio: avança quando não há nada melhor a fazer, para quando há.
- `R ≈ 1,5+` → a unidade **marcha** para o objetivo quase ignorando cobertura e tiro.

### 15.2 O problema do `AIPolicyDealDamage`

`AIPolicyDealDamage` retorna `context.dest_target_score[dest]` **cru** — tipicamente 200–800 com
peso 100. Ele sozinho define `Σ EndTurnPolicies`, e o denominador de `R` explode:

| | `OptLocWeight` | `DealDamage` | R efetivo |
|---|---|---|---|
| HeavyGunner **vanilla** | 100 (default) | Weight **1000** → 2000–8000 | **~0,015** |
| Soldier vanilla | 100 | 100 → 200–800 | ~0,15 |
| Soldier (seu) | 100 | 100 → 200–800 | ~0,15 (0,4 sem alvo) |
| RATOAI_Sniper (seu) | 150 | 150 → 300–1200 | ~0,15 |
| RATOAI_Rocketeer (seu) | 200 | 100 → 200–800 | ~0,3 |
| Medic (seu, behavior de cura) | **1** | HealingRange 300 | ~0,003 |

O `HeavyGunner` vanilla com `DealDamage` peso 1000 é literalmente "se eu enxergo qualquer coisa,
nunca me mexo". É por isso que o gunner vanilla parece uma estátua — e você já corrigiu isso
baixando para o default.

**Recomendação:** trate `AIPolicyDealDamage` como um refinamento, não como o pilar.
`Weight = 20–40` traz o score cru de centenas para dezenas e o coloca na mesma escala das outras
policies. Para expressar "reserve AP e tenha alguém para atirar", use
`AIPolicyAttackAP` (retorna 0/100, normalizado) com peso alto, e deixe o `DealDamage` como
refinamento:

```
AIPolicyAttackAP    200      -- binário: sobra AP para atacar deste tile?
AIPolicyDealDamage   30      -- refinamento: e o tiro é bom?
```

Isso muda o significado de `R` de "quanto o tiro vale" para algo controlável.

### 15.3 Como escolher `OptLocWeight` na prática

Um procedimento que funciona:

1. Some o **teto realista** das `EndTurnPolicies` do behavior, tratando `DealDamage` pelo valor
   cru que você observa no debug (não pelo `Weight`).
2. Decida a personalidade do behavior:

| Personalidade | `OptLocWeight` |
|---|---|
| "atire de onde estiver" (defensivo, guarnição, MG montada) | `0,1 × Σ` |
| "avance com bom senso" (fuzileiro padrão) | `0,4 – 0,6 × Σ` |
| "chegue ao objetivo" (gunner procurando ninho, rocketeer buscando banda, scout) | `1,0 – 1,5 × Σ` |
| "corra" (retirada, pânico) | `2 × Σ` + `Required` de retirada |

3. **Teste no `IModeAIDebug`**: selecione a unidade e leia, no rollover, a linha
   `"Distance to optimal location"` do bloco *End Turn score*. Esse número **é** o `dist_score`.
   Compare-o com a soma das outras linhas. Se ele for < 10% do total em todos os tiles, o
   `OptLocWeight` está baixo demais para importar.

### 15.4 O caso especial: quando **não** há alvo

Quando o inimigo está fora de alcance/LOS, `DealDamage` = 0 e o denominador de `R` desaba. É
exatamente o momento em que você quer que a unidade avance — e, por sorte, é o que acontece
naturalmente. **Mas só se `best_dest ≠ posição atual`.** Se as suas `OptLocPolicies` colapsaram
na posição atual (13.2c), `dist_score` é 0 em todo lugar e a unidade fica trocando de cobertura
com um `-OptLocWeight` de penalidade no tile atual.

Ou seja: **as regras 1, 2 e 3 da seção 14.2 são pré-requisito para o balanceamento de
`OptLocWeight` fazer qualquer sentido.** Não adianta subir `OptLocWeight` se a Best Pos está a
zero tiles de distância.

### 15.5 Checklist de diagnóstico

Abra o `IModeAIDebug` com a unidade problemática selecionada:

| Sintoma no debug | Diagnóstico | Correção |
|---|---|---|
| Marcador de Best Pos em cima da unidade | Falha A — colapso da Best Pos | 14.2 regras 1 e 5 |
| Best Pos a 2–5 tiles, muda toda rodada | Falha C — empate achatado + `GetPosPath` | 14.2 regra 3 |
| Todos os voxels com *Voxel score* = 0 | Falha B/E — todas as OptLoc deram 0 (ou um `Required` vetou) | 14.2 regras 2 e 6 |
| Best Pos correta, mas `"Distance to optimal location"` ≈ 0 em tudo | `OptLocWeight` baixo demais | 15.3 |
| Best Pos correta, `dist_score` visível, mas a unidade não anda | `DealDamage` dominando | 15.2 |
| `Pathfind dist: N/A` nos tiles | não há caminho até a Best Pos (ou `best_dest` = pos atual) | verificar Falha A / conectividade |
