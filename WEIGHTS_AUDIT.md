# Auditoria de pesos e scores — Rato's AI Overhaul

*2026-08-17. Base: `Rato's AI Overhaul` v1.12 + `GBO3` (source do jogo em `ModTools/Src`).*
*Companheiro de `AI_SYSTEM_GUIDE.md` — este documento é só sobre **magnitude numérica**.*

## Status das correções

Aplicadas no código (procure por `BUGFIX (Bn)` nos arquivos):

| # | Status | Arquivos tocados |
|---|---|---|
| B1 | ✅ aplicado | `FUNCTION_ScoreAttacksDetailed.lua`, `SOURCE_AIPrecalcDamageScore.lua` |
| B2 | ✅ aplicado | `FUNCTION_SignaturesCustomScoring.lua` |
| B5 | ✅ aplicado | `FUNCTION_getAISoldierFlankingBehaviorSelectionScore.lua` |
| B6 | ✅ aplicado | `FUNCTION_SignaturesCustomScoring.lua` (`PenaltyScale`) |
| B7 | ✅ aplicado | `FUNCTION_ScoreAttacksDetailed.lua`, `AIPOLICYPOS_CustomFlanking.lua`, `AIPOLICYPOS_CustomSeekCover.lua`, os dois `getAI*BehaviorSelectionScore` |
| B11 | ✅ aplicado | `AIPOLICYPOS_AvoidThreatenedAreas.lua` (o override de `AIFindDestinations`) |
| B12 | ✅ aplicado | `SOURCE_AITakeCover.lua` |
| B13 | ✅ aplicado | `SOURCE_AIScoreReachableVoxels.lua` |
| B14 | ✅ aplicado | `SOURCE_AICalcAttacksandAim.lua` |
| B15 | ✅ aplicado | `FUNCTION_ScoreAttacksDetailed.lua` (só afeta o modo de debug) |
| B16 | ✅ aplicado | `UTIL.lua` — `RATOAI_Debug` congelava em `false` no load |
| B17 | ✅ aplicado | `UTIL.lua`, `SOURCE_AICreateContext.lua`, `SOURCE_AIScoreReachableVoxels.lua` — âncora de peek (oscilação do shooting stance) |
| B3, B4 | ⏸️ **não aplicado** | são calibragem, não bug — mudam o balanceamento |
| B8 | ⏸️ não aplicado | código morto, inofensivo |
| M1 – M7 | ⏸️ **não aplicado** | magnitude / calibragem |

---

## Parte 0 — Tradução: o que cada peso significa de verdade

Antes de qualquer diagnóstico, o problema central: **o mod usa a palavra "Weight" para cinco
coisas com unidades diferentes.** Ajustar um sem saber qual é dá a sensação de "botei à olho e não
sei o que mudou".

| Campo | Unidade real | O que significa "100" | Faixa que você usa |
|---|---|---|---|
| `AIPositioningPolicy.Weight` | **percentual** multiplicando o retorno do `EvalDest` | "conta o valor cheio desta policy" | 20 – 600 |
| retorno do `EvalDest` | **pontos absolutos** de score de posição | por convenção, "condição plenamente satisfeita" | −220 … +800 ⚠ |
| `AISignatureAction.Weight` | **fatia de roleta** (bilhetes de loteria) | mesma chance que "não usar nenhuma ação especial" | 50 – 500 |
| `archetype.BaseAttackWeight` | fatia de roleta do "só atirar normal" | — | 100 – 150 |
| `AIBehavior.Weight` | fatia de roleta, **mas passa pelo `Score()`** | depende do `Score()` — ver abaixo | 5 – 300 |
| `AIBehavior.OptLocWeight` | **pontos absolutos**, teto do gradiente de aproximação | — | 0 – 200 |
| `AITargetingPolicy.Weight` | percentual multiplicando `EvalTarget` | — | 20 – 200 |
| retorno do `CustomScoring` | **fatia de roleta absoluta** (substitui o `Weight`) | — | 0 – 500 |
| retorno de `getAI*BehaviorSelectionScore` | **percentual**, 100 = neutro | "não mexe no `Weight`" | 0 – 250 |
| `archetype.TargetBaseScore` | percentual sobre o score de CTH | — | 100 |

### As três regras que caem daí

**1. Peso de policy é porcentagem; peso de ação é bilhete de loteria.**
`AIPolicyLosToEnemy Weight=200` significa "LOS vale 200 pontos". `AIActionThrowGrenade Weight=200`
significa "granada tem 200 bilhetes num sorteio". São grandezas incomparáveis, mesmo escritas
igual.

**2. `behavior.Weight` só é comparável a outro `behavior.Weight` se os dois `Score()` tiverem a
mesma escala.** E os seus não têm — é o achado nº 3.

**3. Uma ação com `Priority = true` não tem peso: ela tem um interruptor.**
`AISelectAction` faz `if priority then return action end`. O `Weight` é ignorado por completo.

---

## Parte 1 — Bugs de matemática (consertar antes de rebalancear)

Ordenados por impacto. Os quatro primeiros invalidam parte do seu design atual, então rebalancear
os pesos antes de consertá-los seria calibrar em cima de números errados.

### 🔴 B1 — `dest_cth` não é chance de acerto: é a Marksmanship crua

`SOURCE_AIPrecalcDamageScore.lua:337,346`

No source, `base_mod` é declarado **duas** vezes, e a segunda declaração sombreia a primeira:

```lua
-- vanilla, CombatAI.lua
local base_mod = unit[weapon.base_skill]          -- (1) o atributo Marksmanship
...
if mod > const.AIShootAboveCTH then
    local base_mod = mod                          -- (2) sombreia: a CTH calculada
    ...
    target_cth[target] = base_mod                 -- grava (2) = CTH  ✔
```

Na sua versão, o bloco que continha a linha (2) foi substituído por
`RATOAI_ScoreAttacksDetailed`, e a linha `local base_mod = mod` desapareceu junto. As gravações
sobraram apontando para (1):

```lua
best_cth = base_mod            -- linha 337  -> Marksmanship
target_cth[target] = base_mod  -- linha 346  -> Marksmanship
```

**Consequência:** `context.dest_cth[dest]` é o atributo Marksmanship da unidade — **constante para
todo destino e todo alvo**. E `dest_cth` é o denominador de *todas* as suas `CustomScoring`:

```lua
ratio = MulDivRound(dest_cth + penalidade, 100, dest_cth)
```

Isso quebra a premissa central do mod. A ideia era "a chance de usar Autofire depende da minha
situação"; na prática a única entrada que varia é a penalidade, porque o denominador é um número
fixo da fábrica. **Distância e cobertura não afetam nenhuma decisão de ação especial** — exceto
pelo portão binário de 6 tiles (achado B4).

Efeito colateral perverso: um inimigo com Marksmanship 90 tolera até −90 de recoil antes de
desistir do Autofire; um com Marksmanship 40 desiste em −40. A decisão passa a depender do
atributo em vez da chance real de acertar.

**Correção** (uma linha). Dentro de `RATOAI_ScoreAttacksDetailed`, devolva também a CTH do
primeiro tiro, e grave essa:

```lua
-- em RATOAI_ScoreAttacksDetailed, no fim:
return mod, target_covers, target_los, cth_by_aim[aims[1]]
```
```lua
-- em AIPrecalcDamageScore:
local first_cth
mod, target_covers, target_los, first_cth =
    RATOAI_ScoreAttacksDetailed(...)
...
best_cth          = first_cth or 0     -- linha 337
target_cth[target] = first_cth or 0    -- linha 346
```

Depois disso, as suas `ratio` passam a medir o que você queria: *"que fração da minha chance de
acerto esta penalidade come?"*

---

### 🔴 B2 — `Pindown_CustomScoring` está desligada inteira

`FUNCTION_SignaturesCustomScoring.lua:212`

```lua
function Pindown_CustomScoring(self, context)
    local weight, disable, priority = self.Weight, false, self.Priority
    if true then
        return weight, disable, priority     -- <<< sai aqui, sempre
    end
    ... 70 linhas mortas ...
```

Todo o scoring contextual de Pindown (cobertura do alvo, `Slowed`, alvo já ameaçado, bônus por
níveis extras de mira, veto em curta distância) nunca executa. O `RATOAI_Sniper` usa Pindown com
peso fixo 80, duas vezes na lista.

Provavelmente foi um `if true then` de debug que ficou. Ao reativar, note que a função depende de
`dest_cth` — ou seja, **conserte B1 primeiro**, senão ela vai começar a rodar com o denominador
errado.

---

### 🟠 B3 — O `HoldPositionAI` "ShootingStance" ganha de lavada, sempre

Não é bug de código; é bug de **unidade**. `getAIShootingStanceBehaviorSelectionScore` é escrita
como percentual (começa em `local score = 100`), mas o `Weight` do behavior multiplica esse valor:

```lua
'Score', function (self, unit, proto_context, debug_data)
    local score = getAIShootingStanceBehaviorSelectionScore(unit, proto_context)
    return MulDivRound(score, self.Weight, 100)      -- 100 × 150/100 = 150 no piso
end,
```

Então `Weight = 150` não significa "1,5× o padrão": significa "piso 150, típico 280". Enquanto
isso o `StandardAI` do mesmo arquétipo usa o `Score` default (`return self.Weight`) com
`Weight = 50` — um número puro.

**Conta para um fuzileiro com AR (APStance 4), 3 inimigos visíveis a ~12 tiles, ele exposto, eles
em cobertura baixa:**

| Termo | Valor |
|---|---|
| base | 100 |
| AP de stance (`+10` por AP × 4) | +40 |
| bolt-action (`+30`) | 0 (AR) |
| inimigo a ≤6 tiles (`−60` cada) | 0 |
| inimigo no cone sem cobertura (`+35` × fração descoberta) × 3 | +51 |
| eu sem cobertura (`−20` × fração descoberta) × 3 | −60 |
| **total** | **131** |
| × `Weight` 150 / 100 | **≈ 197** |

Contra: `StandardAI` = **50**, `PositioningAI` "Soldier Flanking" ≈ **48**.

→ **ShootingStance leva ~67% dos turnos.** Sem cobertura nos inimigos sobe para ~280, e vira 74%.

E como o mod dá `shooting_stance` à unidade assim que ela entra em stance, o efeito prático é:
**depois que um inimigo se planta, ele quase nunca sai de lá.** É a sensação de IA passiva.

Isso se repete em todo arquétipo (o multiplicador está no `Weight`, e o piso do `Score` é 100):

| Arquétipo | `Weight` do ShootingStance | piso efetivo | `StandardAI` | piso do ShootingStance vs StandardAI |
|---|---|---|---|---|
| Soldier | 150 | 150 | 50 | **3,0×** |
| RATOAI_Sniper | 200 | 200 | 150 | 1,3× |
| Skirmisher | 80 | 80 | 80 | 1,0× |
| RATOAI_Demolition | 50 | 50 | 100 | 0,5× |
| Brute | 5 | 5 | 100 | 0,05× |
| RATOAI_RetreatingMarksman | 5 | 5 | 50 | 0,1× |

Brute e RetreatingMarksman estão calibrados. Sniper faz sentido (é o papel dele). **Soldier está
3× acima do que você provavelmente quis.**

**Correção conceitual:** decida se `getAIShootingStanceBehaviorSelectionScore` é um **percentual**
ou um **peso absoluto**. As duas opções funcionam, mas você tem que escolher:

- **(a) Percentual (recomendado):** deixe `Weight = 100` no behavior e ajuste as constantes da
  função. Aí "ShootingStance vs StandardAI" fica sendo `score/100 × 100` contra `50` — e você
  controla o equilíbrio pelo `StandardAI.Weight`, que é um número legível.
- **(b) Peso absoluto:** faça a função retornar `0..100` (divida pelo número de inimigos, tire o
  base 100) e mantenha o `Weight` como escala.

---

### 🟠 B4 — O portão de 6 tiles mata todas as outras ações especiais

`FUNCTION_SignaturesCustomScoring.lua:43` e `:65`

```lua
if dist and dist <= const.Weapons.PointBlankRange * const.SlabSizeX then
    priority = true
end
```

Duas coisas se combinam mal:

1. O GBO3 subiu `const.Weapons.PointBlankRange` de 2 (vanilla) para **6 tiles**
   (`__MainParams.lua:63`). Então "point blank" cobre uma faixa de combate normal, não um encontro
   cara-a-cara.
2. `Priority` em `AISelectAction` é `return action` imediato — não um peso alto.

E `AIAttackSingleTarget:AutoFire` é o **primeiro** item da lista de signature actions do Soldier.

**Resultado: a ≤6 tiles, se o Autofire estiver disponível, ele é escolhido com 100% de certeza.**
Granada, overwatch, tiro em membro, carga — nada disso é sequer avaliado. Aproximadamente metade
dos engajamentos do jogo acontece dentro de 6 tiles.

**Correção:** troque o interruptor por um multiplicador forte. Mantém a intenção ("de perto,
rajada é o certo") sem apagar o resto:

```lua
if dist and dist <= const.Weapons.PointBlankRange * const.SlabSizeX then
    weight = MulDivRound(weight, 250, 100)   -- 200 -> 500: domina, mas não monopoliza
else
    ... modulação por recoil ...
end
```

Com 500 bilhetes contra um pool de ~700, o Autofire fica em ~70% a curta distância em vez de 100%,
e ainda sobra espaço para uma granada bem posicionada.

---

### 🟡 B5 — `weight_unbolted` aplicado duas vezes

`FUNCTION_getAISoldierFlankingBehaviorSelectionScore.lua:17-19` e `:23-25` são o **mesmo bloco,
copiado**:

```lua
if weapon and rat_canBolt(weapon) then
    score = score + weight_unbolted     -- -20
end
score = score + MulDivRound(wep_stance_ap, weight_per_AP_stance, const.Scale.AP)
if weapon and rat_canBolt(weapon) then
    score = score + weight_unbolted     -- -20 outra vez
end
```

Arma ferrolho leva **−40** em vez de −20. Somado ao `−8` por AP de stance (um Mosin com APStance 5
→ −40), o score de flanqueamento de um atirador de ferrolho é `100 − 40 − 40 = 20`, contra ~100 de
um AR. Provavelmente é o efeito que você queria, mas com o dobro da força e por acidente.

---

### 🟡 B6 — `score_mod = 100 - (100 - ratio)` é `ratio`

Aparece em cinco lugares. É álgebra idêntica, sem efeito — mas esconde a fórmula real de quem lê
depois (inclusive de você). O que o código faz é:

```
peso_final = peso × (dest_cth + penalidade) / dest_cth
```

Vale simplificar e nomear:

```lua
local function PenaltyScale(cth, penalty)
    -- "que fração da minha chance de acerto sobra depois desta penalidade?"
    if not cth or cth <= 0 then return 100 end
    return Max(0, MulDivRound(cth + penalty, 100, cth))
end
```

Isso também resolve a divisão por zero e o caso `cth` nil de uma vez, nos cinco lugares.

---

### 🟡 B7 — Aritmética de ponto flutuante no caminho de decisão sincronizada

O motor sincroniza decisões de IA por hash (`NetUpdateHash` em `AIPrecalcDamageScore`,
`AIScoreReachableVoxels`, `AICreateContext`). Ponto flutuante é a fonte clássica de divergência
entre máquinas. Ocorrências no seu código de score:

| Arquivo | Expressão |
|---|---|
| `__RecoilParams.lua:9` | `const.Combat.Recoil.StacksMultiplier = 0.35` |
| `FUNCTION_ScoreAttacksDetailed.lua:87-90` | `recoil_cth * 0.33`, `* 0.66`, `* StacksMultiplier` |
| `FUNCTION_getAISoldierFlankingBehaviorSelectionScore.lua:40` | `pb_bonus * 1.2` |
| `AIPOLICYPOS_CustomSeekCover.lua:236-238` | `ExposedAtCloseRange_Score * 0.5`, `* 0.1` |
| `AIPOLICYPOS_CustomSeekCover.lua:165-167` | `dist * 1.00 / (range * 1.00)` |
| `AIPOLICYPOS_CustomFlanking.lua:63-66` | `cover_cth * 1.00 / cover_penalty` |

Existe uma pasta `Mods/DesyncDebugLogs` no seu diretório, o que sugere que você já teve desync.
Não afirmo que a causa é essa — mas é o suspeito de sempre, e a conversão é mecânica:

```lua
recoil_cth * 0.33        ->  MulDivRound(recoil_cth, 33, 100)
* const.Combat.Recoil.StacksMultiplier(0.35)  ->  MulDivRound(x, 35, 100)
pb_bonus * 1.2           ->  MulDivRound(pb_bonus, 120, 100)
ExposedAtCloseRange_Score * 0.5   ->  MulDivRound(score, 50, 100)
dist * 1.00 / range      ->  MulDivRound(100, dist, range)
```

Independente de desync, `MulDivRound` também evita que scores fracionários entrem em comparações
de threshold de forma imprevisível.

---

### 🔴 B11 — A IA não valorizava cobertura baixa (e por isso não se agachava)

`AIPOLICYPOS_AvoidThreatenedAreas.lua` (o override de `AIFindDestinations`). A conversão de dest
`Standing` → `Crouch` em tile com cobertura baixa é o **único** ponto onde a postura final é
decidida — todo o scoring depois dela já é stance-aware (`SOURCE_AIScoreDest.lua:3-9`,
`AIPOLICYPOS_CustomSeekCover.lua:393-399`, `SOURCE_AIPrecalcDamageScore.lua:178-210`).

**(a) `if up then`** — `GetCover` devolve as 4 direções, mas só a norte abria o bloco. Muro baixo
a leste/oeste/sul e o dest continuava `Standing`. O efeito não é só cosmético: `GetCoverPercentage`
(`Cover.lua:283-285`) **zera** cobertura baixa quando `target_stance == "Standing"`, então
`AIPolicyCustomSeekCover` scorava o tile como campo aberto. A IA nem queria ir para lá.

**(b) custo fantasma** — o plano descontava 1000 AP (`dest_ap[new_dest] = ap - cost`), mas quem
aplica a postura é `AIBehavior:EndMovement` (`AIBehaviors.lua:199-210`) via `unit:DoChangeStance`,
que **não cobra AP** (`Unit.lua:6435`). O `move_args.toDoStance` de `BeginMovement`
(`AIBehaviors.lua:177`) não é lido por nenhuma ação `Move`. Esse AP fantasma penalizava o dest
agachado em `AIPolicyAttack_StanceAP` e no damage score, fazendo o tile em pé ganhar a roleta de
`AIScoreReachableVoxels`.

Ambos corrigidos. Cobertura **alta** continua sem converter (de propósito: em pé atrás de muro alto
já se tem cobertura total, e agachar custaria LOF).

### 🔴 B12 — `AITakeCover` era um no-op inteiro

`SOURCE_AITakeCover.lua:9`. `(context.ap_after_signature or 0 <= 0)` — em Lua `<=` liga mais forte
que `or`, então a expressão é `X or (0 <= 0)` = sempre verdadeira, e a função retornava sempre.
O vanilla (`CombatAI.lua:511`) tem os parênteses no lugar: `((context.ap_after_signature or 0) <= 0)`.
Isso matava o `StanceCrouch` gratuito de fim de ativação, que é a rede de segurança para quem chegou
num tile de cobertura por outra policy.

Continua valendo o gate próprio do mod na linha 4 (`shooting_stance`), e o do vanilla:
`ap_after_signature` só é preenchido quando rodou uma signature action (`CombatAI.lua:256`).

### 🔴 B13 — O `OptLocWeight` some quando a unidade já está no lugar ótimo

`SOURCE_AIScoreReachableVoxels.lua`. Sintoma: a unidade abandona uma boa posição sem motivo,
frequentemente voltando para um tile pior.

`AIFindOptimalLocation`, ao encontrar um candidato no próprio voxel de partida, preenche
`context.best_dest` no laço de cima e **pula** o bloco que atribui `context.best_dest_path` — não há
caminho a percorrer. Com `best_dest_path` nil, `AICalcPathDistances` (`CombatAI.lua:1359-1377`)
deixa `context.total_dist = nil` e `context.dest_dist = {}`. E as duas fórmulas de OptLoc daqui
estão atrás do mesmo portão `total_dist > 0`:

- `dist_score = 0` para **todos** os destinos — o `OptLocWeight` inteiro (200 em três archetypes,
  150 em dois) simplesmente não entra na conta;
- o seed do `curr_dest` fica com `-opt_loc_weight` **sem escalar**, penalidade cheia.

É vanilla, não regressão do mod — mas ficava mascarado pela roleta quebrada do **B9**, que
disparava sempre na primeira iteração sobre uma lista semeada com `{curr_dest}`: o resultado era
"fique onde está" por acidente. Consertar a roleta removeu essa âncora exatamente no caso em que o
`OptLocWeight` fica mudo, e com `AIDecisionThreshold = 80` dezenas de tiles empatam no sorteio.

Conserto: a fórmula do gradiente está certa — o que falta é o **insumo** dela. Quando `dest_dist`
vem vazio, preenchemos com a distância direta de cada dest até o `best_dest` e usamos o **maior**
desses valores como denominador. O gradiente volta a ser o de sempre — `opt_loc_weight` cheio em
cima do ótimo, decaindo até 0 no limite do alcance de movimento — só que normalizado pelo raio de
movimento em vez do comprimento do caminho, que aqui é zero. Continua sendo **viés somado** ao
score das policies, não um veto.

Distância direta como substituta da distância de caminho tem precedente no próprio source:
`AITacticCalcPathDistances` (`AITactics.lua:8-13`) faz exatamente
`context.dest_dist[dest] = stance_pos_dist(context.best_dest, dest)`.

---

### 🟢 B8 — Coisas mortas

- `ShouldMaxAim()` (`FUNCTION_ShouldMaxAim.lua:5`) — o comentário diz "used in
  AICalcAttacksAndAim", mas a sua `AICalcAttacksAndAim` usa `GetIdealAimLevels`. Nunca chamada.
- `AIPolicyMGSetupPosScore` e `AIPolicyMGSetupAP` — definidas, não usadas em nenhum arquétipo.
- `if not available then return end` em `SOURCE_AISelectAction.lua:59` — `available` é sempre uma
  tabela, logo sempre truthy. Nunca dispara.
- `AIPolicyAvoidDeathSpots`, `AIPolicyAvoidThreatenedAreas`, `AIPolicyDontBeExposedAtCloserRange`
  — arquivos inteiros comentados.

Nada disso quebra nada; só limpa o mapa mental.

---

### 🔴 B14 — O ramo antecipado de `AICalcAttacksAndAim` não descontava o custo de stance

`AICalcAttacksAndAim` tem um retorno antecipado para quando não há nível de mira a
conquistar:

```lua
if not has_stance_ap or to_reach_desired_aim_level <= 0 then
    local num_atks = Min(context.max_attacks, (ap / cost))   -- AP CRU
```

O `stance_cost` (entrar em shooting stance + o nível de mira que vem junto) era cobrado
no orçamento — `min_aim` subia para 1, e a CTH passava a ser de **snapshot** em vez de
hipfire — mas **não era subtraído do AP** na hora de contar disparos. O caminho normal
desconta certinho (`first_atk_cost = stance_cost + rotation_cost + cost`); só este ramo
não descontava.

**Quando mordia.** Perto, `GetIdealAimLevels` devolve o próprio `min_aim` (point blank →
mira mínima; até 45% do effective range → nível 1, que já é o mínimo quando há stance).
Aí `to_reach_desired_aim_level` dá 0 e a execução cai neste ramo. A estimativa saía com a
**contagem de disparos de quem não preparou** e a **CTH de quem preparou**.

O efeito era concentrado, não difuso: destinos colados e com pouco AP restante — ou seja,
exatamente as posições de aproximação agressiva.

**Medição** (um turno, 5 unidades, com instrumentação temporária):

| unidade | ocorrências | pior caso | disparos inflados |
|---|---|---|---|
| LegionGoon:452 | 12 | 1 | 12 |
| LegionRaider:457 | 8 | 2 | 11 |
| LegionRaider:454 | 5 | 1 | 5 |
| LegionRaidLeader:453 | 3 | 1 | 3 |
| LegionRaider:462 | 1 | 2 | 2 |
| **total** | **29** | **2** | **33** |

Distância 1–9 tiles, AP no destino 4–17, custo de stance observado 2 AP (×11), 3 AP
(×14), 4 AP (×3) — a severidade escala com o peso da arma.

Em score: `conta 2, deveria 1` dobra o `hit_score` do destino. Com CTH ~60 por disparo e
`AIPolicyDealDamage` no modo `cap` (MaxHits 200, Weight 150), isso é ~90 contra ~45 — um
swing da ordem de grandeza do peso inteiro da `AIPolicyThreatExposure`.

**Lacuna que permanece.** A IA nunca *escolhe* hipfire: `stance_cost` só é zerado quando
falta AP, nunca por decisão. Dentro de ~7–8 tiles, largar a preparação e disparar mais
rende mais acertos esperados (a penalidade de hipfire é linear e só é severa longe:
−123×d/28 contra −61×d/40 do snapshot). Antes deste conserto os dois erros se cancelavam
em parte — ela contava como se hipfirasse. Agora a conta está honesta e a lacuna ficou
visível, que é o estado certo para decidir se vale implementar a escolha.

---

### 🟢 B15 — `cth_attacks_at` acumulava disparos entre passadas do precalc

Só afeta o modo de debug, mas invalidava o número que se estava olhando.

`FUNCTION_ScoreAttacksDetailed.lua` guarda a CTH disparo a disparo por par
(destino, alvo) sob `RATOAI_Debug`:

```lua
context.cth_attacks_at[upos][target] = context.cth_attacks_at[upos][target] or {}
...
table.insert(context.cth_attacks_at[upos][target], attack_mod)
```

Dentro de **uma** chamada de `AIPrecalcDamageScore` cada par é visitado uma vez só, e o
`or {}` era inofensivo. Mas o precalc roda mais de uma vez por turno, e a UI de debug o
reexecuta de propósito (camada "target_recalc", e a página Alvo quando não há
`ai_destination`). A partir da segunda passada o `table.insert` **apendava na lista da
passada anterior**: um alvo de 3 disparos aparecia com 6, depois 9.

Corrigido para `= {}`. Zerar é o correto justamente porque o par é visitado uma única vez
por chamada.

---

### 🔴 B16 — `RATOAI_Debug` congelava em `false`: todo o debug do mod estava morto

`UTIL.lua:6` avaliava a flag **uma vez**, na execução do arquivo:

```lua
RATOAI_Debug = Platform.developer and Platform.cheats and true or false
```

Em build goldmaster `Platform.developer` é `nil` quando este mod carrega. Quem liga as
duas flags é o `ForceDev.lua` do mod **Rato Dev**, que carrega **depois** — e o próprio
comentário dele já documentava isso ("a flag só vira true aqui, DEPOIS").

Resultado: `RATOAI_Debug` ficava `false` para sempre, e com ele **todo** caminho de debug
do mod — `cth_attacks_at`, `aims_at`, `dbg_targets` — nunca era preenchido, mesmo com o
painel de debug aberto e os cheats ligados. O rollover de voxel mostrava a seção de
`aims` vazia; a página Alvo mostrava as colunas novas todas com `-`.

É o **mesmo erro** que `AIPOLICYPOS_CustomSeekCover.lua:101` já registrava para o gate
antigo daquela policy. A refatoração do `PERF (C9)` centralizou a flag numa global só,
mas herdou a avaliação no load.

**Confirmado no processo vivo** (via `tools/dap_probe.py`, ver `DEBUG SERVER.md`):

```
tostring(RATOAI_Debug)                                       => false
tostring(Platform.developer) .. " / " .. tostring(Platform.cheats)  => true / true
```

**Correção.** `RATOAI_RecomputeDebugFlag()` recalcula em `ClassesBuilt`, `ModsReloaded` e
`CombatStart`. Continua sendo um booleano simples e não uma função — o caminho quente lê
`local dbg = RATOAI_Debug` por chamada e não pode pagar uma chamada de função; só o
*momento* da avaliação mudou. `CombatStart` sozinho já bastaria para a correção, e está
lá justamente para não depender de qual marco de carregamento é tarde o bastante.

`RATOAI_DebugForce = true/false` trava o valor à mão. Sem essa válvula, ligar
`RATOAI_Debug` no console seria desfeito no `CombatStart` seguinte — exatamente quando se
está tentando depurar.

---

### 🔴 B17 — Vai e volta do shooting stance: a IA oscilava entre a cobertura e o peek

**Sintoma.** A unidade entra em shooting stance, peeka para fora da cobertura, o
`evaluate` diz que a melhor posição é a cobertura de onde ela acabou de sair, ela volta,
ataca, peeka de novo. Ciclo de 2, o turno inteiro.

**Causa: um invariante do vanilla que o GBO3 quebrou.** No source, todo sistema resolve
`return_pos or self` — a posição de cobertura é a canônica e o peek é apresentação:

| | |
|---|---|
| `Cover.lua:131-132` | cobertura calculada a partir de `return_pos` |
| `Unit.lua:6290` | `IsInCover` usa `self.return_pos or self` |
| `Unit.lua:7584` | `attack_args.step_pos = ... or self.return_pos or ...` |

`Unit:EnterShootingStance` (GBO3, `shooting_stance_functions.lua:13-16`) faz
`return_pos_reserved = return_pos; return_pos = false` para a unidade **ficar** peekada.
Com `return_pos` limpo, todos aqueles fallbacks passam a ver o voxel exposto como o real.

O GBO3 remendou **um** consumidor: o CTH dele próprio. `CTH_cover_prone.lua:101` faz
`target.return_pos_reserved or target.return_pos or false` e, se `peek_percent > 80`,
aplica valor de cobertura mesmo assim — o modificador "Peeking from Cover". Ou seja,
**pelo modelo do jogo ela tem cobertura enquanto peeka**; só a IA não sabia.

**Por que remendar as policies de cobertura não resolveria.** P (cobertura) e P' (peek)
continuariam sendo dois destinos distintos com scores distintos, e enquanto houver dois
há gradiente entre eles. A oscilação só morre fazendo os dois serem o *mesmo* destino —
é conserto de insumo, não de score.

**Correção.** `RATOAI_GetPeekAnchor(unit)` (UTIL.lua) devolve
`return_pos_reserved or return_pos or false` — a mesma expressão do `CTH_cover_prone`.
Aplicada em três pontos:

1. `AICreateContext` — `pos`, e o `gx,gy,gz` do `unit_grid_voxel` junto.
2. **`AIUpdateContext`** — override novo, no fim do mesmo arquivo. Sem ele a âncora do
   item 1 seria desfeita: `AIPlayAttacks` chama `AIUpdateContext` (`CombatAI.lua:204`) e
   ele reescreve `unit_pos` / `unit_stance_pos` / `unit_grid_voxel` a partir da posição
   literal.

3. **`AIScoreReachableVoxels`** — se o destino vencedor é a âncora, ele vira
   `GetPackedPosAndStance(unit)`, ou seja a posição **atual** da unidade.

**Por que o item 3 foi preciso — e por que os itens 1 e 2 sozinhos não bastaram.**

A primeira versão desta correção parou nos itens 1 e 2, com a justificativa de que
`AIBehaviors.lua:83-85` decidiria o movimento a partir de `context.unit_stance_pos`.
**Isso estava errado em dois pontos**, e a oscilação continuou em jogo:

- Aquele bloco é o `AIBehavior:TakeStance` — decide **postura**, não movimento.
- Os portões que de fato decidem andar leem a unidade **direto**, nunca o context:
  `AIBehavior:BeginMovement` usa `stance_pos_pack(unit, unit.stance)`
  (`AIBehaviors.lua:145-148`) e `EndMovement` usa `GetPackedPosAndStance(unit)` (`:202`).

Ou seja: a âncora conserta a **avaliação** (cobertura medida em P, que é o que o
`CTH_cover_prone` do GBO3 já fazia), mas nunca chega na **decisão de andar** — para o
motor, P e P' seguem sendo tiles diferentes. Por isso o item 3 troca o destino em vez de
tentar ensinar o motor que os dois são a mesma coisa.

`AIUpdateContext` também não roda onde eu supus: `CombatAI.lua:204` está dentro de
`AIPlayAttacks`, que é a fase de **ataque** — depois do movimento. O item 2 continua
correto e útil (mantém a âncora durante o ataque), mas nunca poderia impedir o passo.

**Medido no processo vivo** (`tools/dap_probe.py`) e é o que torna o item 3 robusto:
`stance_pos_dist` é distância **2D pura** — ignora stance *e* Z. Dois packs com stance 1
vs 3, ou com Z de um `SlabSizeZ` de diferença, dão `dist = 0`. Então a comparação da
âncora não precisa casar postura nem altura.

**A divisão que cai de graça:** `CombatAI.lua:211` monta o `dest` do
`AIPrecalcDamageScore` com `context.ai_destination` — que agora é a posição literal P'.
Então fica cobertura de P (pelo context ancorado), tiro de P'. É o comportamento do jogo.

**Cobertura do item 3:** `StandardAI`, `RetreatAI`, `ApproachInteractableAI` e `CustomAI`
pegam o destino de `AIScoreReachableVoxels`. **`PositioningAI` não** — ele usa
`context.positioning_dest` (`AIBehaviors.lua:369`). Se a oscilação reaparecer num
archetype de posicionamento, é ali que falta.

**O que fica em aberto.**

- A origem do pathfinding (`AIFindDestinations`, `SOURCE_AIFindDestinations.lua:55`)
  **não** foi ancorada — é onde mora o risco de
  `assert(not "AI can't find unit free destination")`, e não é necessária para matar a
  oscilação. O custo é um viés de um tile *contra* ficar parada. Se na prática isso ainda
  a fizer querer se mexer, é o próximo passo.
- **Ponto cego novo:** ancorada em P, a IA deixa de ver o caso em que o ângulo do peek já
  não dá cobertura (`peek_percent <= 80`) e ela está genuinamente exposta. A correção de
  verdade é as policies usarem o mesmo teste
  `GetCoverPercentage(attacker_pos, return_pos)` do CTH do GBO3 — parte do problema maior
  de "o modelo de cobertura da IA ≠ o modelo do jogo".

## Parte 2 — Problemas de magnitude (não são bugs, são calibragem)

### M1 — Somar Marksmanship ao score de dano dilui a discriminação

`SOURCE_AIPrecalcDamageScore.lua:279`

```lua
mod = mod + pos_mod     -- pos_mod = Marksmanship + bônus prone de componente
```

No vanilla, `pos_mod` era **parte do cálculo de CTH** (`hit_mod = pos_mod; mod = hit_mod - penalty`).
Na sua versão, `RATOAI_ScoreAttacksDetailed` já devolve uma soma de `CalcChanceToHit` — que **já
inclui a Marksmanship**. Então a linha acima soma o atributo uma segunda vez, como constante.

Magnitude: 3 ataques a 50% de CTH → `mod = 150`, + Marksmanship 70 → 220. **32% do score de alvo é
um número que não distingue nada.** Efeito: comprime as diferenças entre destinos e entre alvos
exatamente onde o limiar de 80% decide.

Exemplo: dois destinos, um com 3×50 = 150 e outro com 3×40 = 120.
- sem o offset: `120 < 0,8 × 150 = 120`? empata na borda — o pior é eliminado por um ponto.
- com o offset: 220 vs 190; limiar 176 → **os dois entram no sorteio**.

Ou seja, o offset faz a IA ficar mais indiferente sobre de onde atirar. Remover a linha 279 é a
correção; se você quer manter algum peso de atributo, use `archetype.TargetBaseScore` (que é
percentual e existe para isso).

### M2 — `Autofire` e `SuppressiveFire` são a mesma ação, e uma delas ignora o recoil

Ambas são `action_id = "AutoFire"`; a diferença é `Aiming = "Maximum"` vs `"Remaining AP"`.

```
Autofire        W=200   CustomScoring = AutoFire_CustomScoring   (modula por recoil)
SuppressiveFire W=180   CustomScoring = return self.Weight       (não modula nada)
```

Então: 380 bilhetes de rajada, e **quando o recoil torna a rajada ruim, a variante Suppressive
continua com os 180 inteiros.** O portão de recoil que você construiu é contornado por metade do
peso. É provavelmente a razão de "os inimigos metralham demais" mesmo com a lógica de recoil no
lugar.

### M3 — Distribuição real de ações do Soldier

Cenário: fuzileiro com AR, 1 granada de fragmentação, dia, alvo a 12 tiles em cobertura baixa,
recoil −25, Marksmanship 70, 2 inimigos agrupados.

| Ação | `Weight` | após `CustomScoring` | fatia |
|---|---|---|---|
| *(nenhuma — ataque básico)* | 100 (`BaseAttackWeight`) | 100 | **11%** |
| Autofire | 200 | 129 | 14% |
| SuppressiveFire | 180 | 180 | **20%** |
| Overwatch | 100 | 81 | 9% |
| GroinShot | 50 | 36 | 4% |
| ArmShot | 50 | 36 | 4% |
| LegShot | 50 | 36 (45 se alvo com SMG/pistola) | 4% |
| Granada (min_score 100) | 100 | 100 | 11% |
| Granada 200 (min_score 200) | 200 | 200 | **22%** |
| **total** | | **898** | |

Leituras:
- **Rajada = 34%** (as duas variantes somadas).
- **Granada = 33%** quando há 2+ inimigos agrupados. Como cada soldado carrega 1–2 granadas e o
  bias de reuso é só `−20` **em si mesmo** (não no time), o comportamento emergente é: *o esquadrão
  despeja todas as granadas nos dois primeiros turnos*. Se a intenção era "infantaria usa de vez em
  quando", isso está ~3× acima.
- **Ataque básico = 11%.** Um `BaseAttackWeight` de 100 contra um pool de 800 significa "só atiro
  normal em 1 de 9 turnos".
- A ≤6 tiles, essa tabela inteira é substituída por "Autofire, 100%" (B4).

### M4 — Policies que escalam com o número de inimigos

Já anotado no guia (§13.4), repetido aqui porque é magnitude: `AIPolicyCustomFlanking` **soma** por
inimigo (±200 cada), enquanto `AIPolicyCustomSeekCover` tira **média**. Com 8 inimigos, um
`CustomFlanking Weight=50` pode render 400–800 e engolir um `CustomSeekCover Weight=150`.

O mesmo padrão está em `getAIShootingStanceBehaviorSelectionScore`: os termos `+35` (inimigo no
cone), `−20` (eu exposto) e `−60` (inimigo perto) **acumulam por inimigo** sobre um base de 100.
Com 1 inimigo o score é ~145; com 6, ~280 (ou negativo se estiverem perto). A personalidade da IA
muda com o tamanho do esquadrão inimigo.

### M5 — A faixa de mira intermediária quase não existe

`GetIdealAimLevels` (`FUNCTION_ShouldMaxAim.lua:21`):

```
effective_range = EffectiveRange × 45%        (55% para rajadas)
EffectiveRange  = WeaponRange / 2
```

Para um AK74 do GBO3 (`WeaponRange = 36`): `EffectiveRange = 18` → `× 45% = 8,1 tiles`.
E `point_blank = 6 tiles`.

| distância | mira |
|---|---|
| ≤ 6 tiles | `min_aim` (não mira) |
| 6 – 8,1 tiles | `max(1, min_aim)` |
| > 8,1 tiles | **`max_aim`** (mira máxima) |

A faixa intermediária tem 2 tiles de largura. Na prática a decisão é binária: perto não mira, longe
mira tudo. Pior: para uma SMG (`WeaponRange` ~18 → `EffectiveRange` 9 → ×45% = 4,05) com
`point_blank` de SMG = 6 × 70% = 4,2 tiles, temos `effective_range < point_blank` → **o `elseif`
é inalcançável** e não existe faixa intermediária nenhuma.

Se a intenção era um degradê, o `45%` deveria ser aplicado ao `WeaponRange`, não ao
`EffectiveRange` (que já é metade). Com `WeaponRange × 45% = 16,2 tiles`, a faixa fica 6 → 16
tiles, que é uma banda útil.

### M6 — `BaseMovementWeight = 10` significa "sempre atacar em movimento"

As ações com `movement = true` (`AIActionMobileShot`, `AIActionCharge`, `AIActionHyenaCharge`) não
entram no sorteio de signature actions — vão para um sorteio **separado**,
`AIChooseMovementAction`, cujo peso base é `archetype.BaseMovementWeight`.

O `BaseMovementWeight` é a fatia de "**não** atacar em movimento".

| Arquétipo | `BaseMovementWeight` | pool de movimento | chance de *não* usar |
|---|---|---|---|
| **Soldier** | **10** | RunAndGun 160 + MobileShot 160 = 320 | **3%** |
| RATOAI_Sniper | 10 | RunAndGun 100 + MobileShot 100 = 200 | 5% |
| Skirmisher | 100 (default) | 200 + 200 = 400 | 20% |
| Brute | 10 | RunAndGun 100 + MobileShot 100, **ambos `Priority`** | **0%** |
| Rocketeer | 100 (default) | 100 + 100 = 200 | 33% |

Ou seja: **sempre que um fuzileiro tem um Mobile Shot válido, ele o usa em 97% dos turnos** (100%
a ≤6 tiles, por causa do B4). O Brute usa sempre, por `Priority` — o que é coerente com o papel
dele, mas no Soldier é provavelmente acidente: `BaseMovementWeight = 10` parece ter sido copiado do
vanilla (que também usa 10), onde o pool de movimento tinha uma única ação e a roleta estava
quebrada de qualquer forma (§11.1 do guia).

*Sugestão: `Soldier.BaseMovementWeight = 150`* → chance de não usar sobe para 32%, e o Mobile Shot
volta a ser uma opção tática em vez do modo padrão de andar.

Note que `AIActionMobileShot:PrecalcAction` só fica disponível se já existe um `ai_destination` e
se há um tiro válido no caminho — então isso não é "97% dos turnos", é "97% dos turnos em que a IA
já decidiu se mover e tem linha no caminho". Ainda assim é alto.

### M7 — Valores efetivos vs. valores escritos (tabela de referência)

Para você não precisar reconstruir isso de cabeça:

| Constante | Escrito | Efetivo | Onde |
|---|---|---|---|
| `AIPolicyHighGround.Weight` | 80 | **64 por nível Z** (peso ao quadrado) | `ClassDef-AI.lua` |
| `weight_per_AP_stance` | 10 | +10 por AP × APStance (1–6) = **+10 a +60** | ShootingStance |
| `weight_unbolted` | 30 | +30 | ShootingStance |
| `weight_unbolted` (flanking) | −20 | **−40** (duplicado, B5) | Flanking |
| `weight_per_AP_stance` (flanking) | −8 | −8 a −48 | Flanking |
| `weight_close_enemy` | −60 | **−60 por inimigo** a ≤6 tiles | ShootingStance |
| `weight_enemy_in_cone` | 35 | 0 a +35 **por inimigo** | ShootingStance |
| `weight_no_cover` | −20 | −20 a 0 **por inimigo** | ShootingStance |
| `ExposedAtCloseRange_Score` | −100 | −100 / −50 / −10 por faixa de distância | CustomSeekCover |
| `extra_score_arg_mul` | 220 | ×2,2 no score todo, se `ScalePerDistance` | CustomSeekCover |
| `unit_weight` + `extra_target_weight` | 100 + 100 | ±200 **por inimigo, somado** | CustomFlanking |
| `const.Weapons.PointBlankRange` | 6 | 6 tiles (vanilla: 2) — usado como portão | GBO3 |
| `const.Combat.Recoil.MaxPenalty` | −90 | recoil pode zerar o Autofire sozinho | GBO3 |

---

## Parte 3 — Mudanças propostas, com a racional

Em ordem. Cada bloco é independente do seguinte, então dá para parar em qualquer ponto e testar.

### Etapa 1 — Consertar a matemática (sem mudar nenhum peso)

| # | O que | Por quê, em humanês |
|---|---|---|
| B1 | gravar a CTH real em `dest_cth` | *"Hoje a IA decide se metralha comparando o recoil com o quão bom atirador ela é. Deveria comparar com a chance de acerto que ela realmente tem naquele tiro."* Sem isso, distância e cobertura não influenciam nenhuma escolha de ação especial. |
| B2 | remover o `if true then` | *"Toda a lógica de Pindown que você escreveu está desligada há tempo."* |
| B6 | extrair `PenaltyScale(cth, penalty)` | *"Cinco cópias da mesma fórmula, escrita de um jeito que esconde o que ela faz, e nenhuma protege contra CTH zero."* |
| B7 | trocar floats por `MulDivRound` | *"Multiplicação com vírgula em código que o motor usa para sincronizar partidas em rede. É a causa clássica de desync — e você tem uma pasta de logs de desync aí."* |
| M1 | remover `mod = mod + pos_mod` | *"A Marksmanship já está dentro do CalcChanceToHit. Somar de novo adiciona ~70 pontos iguais a todo destino, o que faz a IA ficar mais indiferente sobre de onde atirar."* |

**Efeito esperado depois da Etapa 1:** o comportamento vai mudar *sem você tocar num peso*, porque
os moduladores contextuais passam a funcionar de verdade. Rode assim primeiro; é possível que
metade dos ajustes abaixo fiquem desnecessários.

### Etapa 2 — Tirar os interruptores escondidos

**2a. Portão de 6 tiles → multiplicador** (B4)
```lua
-- AutoFire_CustomScoring e MobileAttack_CustomScoring
if dist and dist <= const.Weapons.PointBlankRange * const.SlabSizeX then
    weight = MulDivRound(weight, 250, 100)
else
    weight = MulDivRound(weight, PenaltyScale(dest_cth, dest_recoil), 100)
end
```
*Racional: "de perto, rajada é a jogada certa" continua verdade — mas hoje isso é uma certeza
absoluta que apaga granada, overwatch e tiro em membro em metade dos combates. Com 250% de peso ela
ganha em ~7 de 10 turnos, o que já lê como "a IA prefere rajada de perto" sem eliminar a variedade.*

**2b. `SuppressiveFire` passa a usar o mesmo `CustomScoring` do Autofire** (M2)
```lua
'CustomScoring', function (self, context)
    return AutoFire_CustomScoring(self, context)
end,
```
*Racional: hoje o portão de recoil que você construiu é contornado por 180 dos 380 bilhetes de
rajada. Se recoil deve reduzir a vontade de metralhar, tem que reduzir nas duas variantes.*

Considere também **fundir as duas** numa só ação: elas disparam a mesma `AutoFire`, e a diferença
(`Aiming = "Maximum"` vs `"Remaining AP"`) já é resolvida pelo `AICalcAttacksAndAim`.

### Etapa 3 — Normalizar as escalas

**3a. Escolher a unidade dos `Score()` de behavior** (B3)

Recomendo tratar as funções `getAI*BehaviorSelectionScore` como **percentual** e deixar o `Weight`
do behavior fazer o trabalho de escala:

```lua
-- items.lua, HoldPositionAI "ShootingStance" do Soldier
'Weight', 100,      -- era 150
```

E, dentro da função, dividir os termos por-inimigo pelo número de inimigos (M4):

```lua
-- getAIShootingStanceBehaviorSelectionScore, no fim do loop
local n = Max(1, num_enemies_considered)
score = 100 + fixed_terms + MulDivRound(per_enemy_terms, 100, n * 100)
```

*Racional: "score começa em 100" e "Weight multiplica" são duas escalas empilhadas. Com Weight 150
você não pediu "50% mais chance": pediu "piso de 150 contra um StandardAI de 50", ou seja 3× — e o
valor típico é 280, ou seja 5,6×. Depois de normalizar, o `StandardAI.Weight` volta a ser o botão
legível: quer a IA mais móvel? sobe ele. Quer mais plantada? desce.*

Ponto de partida sugerido para o Soldier: `ShootingStance Weight = 100`,
`StandardAI Weight = 100`, `Soldier Flanking Weight = 25`. Isso dá aproximadamente
**ShootingStance ~45% / StandardAI ~40% / Flanking ~15%** num cenário neutro, em vez dos atuais
67 / 17 / 16.

**3b. `AIPolicyCustomFlanking` tira média em vez de somar** (M4)
```lua
return delta > 0 and MulDivRound(delta, 100, Max(1, #enemies)) or 0
```
*Racional: com 2 inimigos a policy vale 200; com 8, vale 800. A "personalidade" do arquétipo muda
conforme o tamanho do esquadrão que ele encontra, o que é impossível de calibrar.*

### Etapa 4 — Recalibrar o pool de ações especiais

Com B1 e M2 no lugar, o pool passa a responder ao contexto. Os números abaixo são um ponto de
partida, não um alvo:

| Ação (Soldier) | Hoje | Sugerido | Racional |
|---|---|---|---|
| `BaseAttackWeight` | 100 | **200** | *"Atirar normal é a ação padrão de um fuzileiro. 11% é baixo demais — a IA parece que está sempre fazendo truque."* |
| Autofire | 200 | 200 | ok |
| SuppressiveFire | 180 | **fundir com Autofire** | duplicata |
| Overwatch | 100 | 100 | ok |
| Groin / Arm / Leg | 50 / 50 / 50 | 50 / 50 / 50 | ok — 12% somados é uma boa taxa de "tiro esperto" |
| Granada | 100 | **60** | *"Cada soldado tem 1–2 granadas e as joga nos 2 primeiros turnos. 60 espalha o uso pela luta."* |
| Granada 200 | 200 | **120** | idem, e o `min_score` 200 já garante que só sai contra 2+ alvos |
| Flare | 200 | 200 | ok — só à noite, e o bias de time já limita |
| Launcher | 200 | 200 | ok — limitado por munição |

Total ≈ 200 + 200 + 100 + 150 + 180 = 830, com **ataque básico em 24%** e granadas em 22%.

E no pool de movimento, que é separado (M6):

| Campo (Soldier) | Hoje | Sugerido | Racional |
|---|---|---|---|
| `BaseMovementWeight` | 10 | **150** | *"Hoje, sempre que existe um Mobile Shot válido o fuzileiro usa em 97% dos turnos. Com 150 ele passa a usar em ~2 de 3, e andar normalmente volta a ser uma opção."* |

E, para racionar granadas de verdade, o bias precisa ser de **time**, não de si:
```lua
PlaceObj('AIBiasModification', {
    'BiasId', "AssaultGrenadeThrow",
    'Value', -50, 'Period', 1, 'ApplyTo', "Team",   -- era -20, Self
}),
```
*Racional: hoje cada soldado decide sozinho, então 6 soldados a 33% dão 2 granadas por turno.
Com o modificador no time, a primeira granada esfria a vontade dos outros cinco.*

### Etapa 5 — Faixa de mira (M5)

```lua
-- GetIdealAimLevels
local effective_range = MulDivRound(context.ExtremeRange, effective_range_mul, 100)
--                                          ^^^^^^^^^^^^ era context.EffectiveRange
```
*Racional: `EffectiveRange` já é metade do alcance da arma, então aplicar 45% em cima dá 22% do
alcance — abaixo do point blank de 6 tiles do GBO. A faixa "mira parcial" tem 2 tiles de largura,
e para SMG ela nem existe. Usando o alcance total, a faixa vira 6 → 16 tiles, que é onde a maior
parte do combate acontece.*

---

## Parte 4 — Como medir se funcionou

Três instrumentos, do mais barato ao mais caro:

**1. Log de decisão.** `g_AIExecutionController.enable_logging = true` já grava behavior e
signature action escolhidos por unidade em `g_LastTurnAILog`. Rode dois combates antes e depois de
cada etapa e conte as frequências. É a única forma honesta de saber se "34% de rajada" virou o que
você quer.

**2. Um dump do pool.** `AISelectAction` já recebe `dbg_available_actions` e o `IModeAIDebug`
popula. Adicionar ao seu `DEBUG.lua` a lista `{ação, peso final, %}` mostra a tabela da M3 ao vivo,
para a unidade e o contexto reais, em vez de uma estimativa.

**3. Rollover de posição.** Para os pesos de policy, o `IModeAIDebug` já decompõe policy a policy.
A linha `"Distance to optimal location"` é o `dist_score` (ver `AI_SYSTEM_GUIDE.md` §15.3).

Uma sugestão de processo, porque o problema aqui não é ter escolhido números ruins — é não ter um
jeito de ver o número: **faça a Etapa 1 inteira, meça, e só depois mexa em peso.** Boa parte da
calibragem "à olho" pode estar compensando os bugs B1/M1, e vai ficar errada em sentido contrário
depois do conserto.
