# Auditoria de pesos e scores — Rato's AI Overhaul

*2026-08-17. Base: `Rato's AI Overhaul` v1.12 + `GBO3` (source do jogo em `ModTools/Src`).*
*Companheiro de `AI_SYSTEM_GUIDE.md` — este documento é só sobre **magnitude numérica**.*

> Para o modelo matemático de **como os pesos de um arquétipo conversam entre si** (influência =
> `Weight × D`, âncoras absolutas, `A` e `R_optloc`, regras de tuning e as tabelas por arquétipo
> extraídas do `items.lua` atual), ver **`POLICY_BUDGET.md`**. Aqui ficam os bugs; lá, a
> calibragem.


ESSE ARQUIVO TA DESATUALIZADO EM PARTE

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
| B18 | ✅ aplicado | `SOURCE_AICalcAttacksandAim.lua` — laço de mira comprava nível e perdia o disparo |
| B19 | ✅ aplicado | `SOURCE_AICalcAttacksandAim.lua` — free move contado como AP de ataque |
| B20 | ✅ aplicado | `SOURCE_AIPolicyDealDamage.lua` — desconto de alvo derrubado nos 4 modos |
| B21 | ✅ aplicado | `FUNCTION_ScoreAttacksDetailed.lua`, `SOURCE_AIPrecalcDamageScore.lua` — rajada valia um acerto só |
| B22 | ✅ aplicado | `SOURCE_AICalcAttacksandAim.lua` + **GBO3** `FUNCTIONS_recoil.lua` — sobretaxa de mira do recoil |
| B23a/b | ✅ aplicado | `FUNCTION_ScoreAttacksDetailed.lua` — pilhas de recoil começando em zero + fator de conversão |
| B24 | ✅ aplicado | `FUNCTION_ScoreAttacksDetailed.lua` — penalidade persistente aplicada à soma, não ao CTH do ataque |
| B25 | ⚠️ **aplicado, NÃO resolveu** | `SOURCE_AIFindDestinations.lua` — destino de quem prefere Prone era empacotado em pé. O sintoma do MG continua. **Em aberto.** |
| B26 | ⚠️ **aplicado, não testado em jogo** | `SOURCE_AIPrecalcConeTargetZones.lua` (**novo — falta registrar no editor**) — o parâmetro `stance` do vanilla era ignorado: o cone da MG era decidido com a linha em pé. |
| B27 / C13 | ⚠️ **aplicado, não testado em jogo** | `AIPOLICYPOS_MGSetupPosScore.lua` — reescrita. Ângulo medido da unidade e não do tile, portão de ângulo com unidade errada (razão vs AP), visibilidade da posição atual, média em vez de aglomerado, sem portão de LOS. |
| B28 | ⚠️ **aplicado, não testado em jogo** | `REACTIONS_StopMGPackingUp.lua` — montava a MG e atirava fora do cone. Ordem, não filtro: o precalc roda antes da signature action. |
| B40 | ⚠️ **aplicado, não testado em jogo** | `AIPOLICYPOS_CustomWeaponRange.lua`, `AIPOLICYPOS_GrenadeRange.lua` — inimigo caído deixa de ser referente de posicionamento. Na `CustomGrenadeRange` ele pesava 5% (`DownedWeightModifier`) e, sozinho no alcance, fazia a policy opinar sem referente válido; agora é pulado. Predicado unificado em `IsIncapacitated()` nos 4 pontos (pega também `IsGettingDowned`). `DownedWeightModifier` virou `no_edit` na classe derivada. |
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

---

### 🔴 B18 — O laço de mira comprava nível e depois perdia o disparo

No laço de disparos **subsequentes** de `AICalcAttacksAndAim`, a mira era comprada
gulosamente até `desired_aim_level` e só **depois** se perguntava se o disparo ainda
cabia. Se não coubesse, `break` — sem nunca recuar um nível para o tiro caber.

```lua
while remaining_ap >= aim_cost and (current_aim < desired_aim_level or max_attacks_reached) do
    current_aim = current_aim + 1
    remaining_ap = remaining_ap - aim_cost
    ...
end
if remaining_ap >= atk_cost and not max_attacks_reached then   -- tarde demais
```

**Correção:** o nível só é comprado se o disparo continuar cabendo depois dele.

```lua
while remaining_ap - aim_cost >= atk_cost and current_aim < desired_aim_level do
```

E o teste de teto de ataques subiu para o topo do laço (`if index > max_attacks then
break`), porque no arranjo antigo, com o teto atingido, ele comprava um nível, gravava em
`current_aim`, o `if` falhava e o valor era descartado — queimava AP e não produzia nada.

**Efeito, simulado com a aritmética inteira da engine:**

| caso (AP sobrando, custo tiro, custo mira, desired) | antes | depois |
|---|---|---|
| 3, 2, 1, 3 | `[]` — **zero disparos** | `[1]` |
| 9, 2, 1, 3 | `[3]` | **`[3, 2]`** |
| 5, 5, 1, 3 | `[]` | `[0]` |
| teto de ataques atingido | `[]`, queima 1 AP | `[]`, sem queimar |

A linha `9, 2, 1, 3` é o comportamento que se esperava o tempo todo: um disparo com mira
cheia e, com o que sobrar, outro com mira menor. Antes o segundo disparo simplesmente não
existia.

**O que NÃO foi consertado.** O `or max_attacks_reached` que existia na condição parecia
querer dizer "sem mais disparos, despeje o AP que sobrou em mira do último tiro". Nunca
fez isso — o nível ia para uma variável local que morria no `break`. Continua não
implementado; ver **7.0b** em `AIM_AND_STANCE.md`. É o motivo de a unidade acabar o turno
com AP sobrando e mira 0.

---

### 🔴 B19 — Free move contado como AP de ataque

O `ap` que chega no `AICalcAttacksAndAim` vem de `dest_ap`, que parte de
`unit.ActionPoints` (`CombatAI.lua:1018`). E `ActionPoints` **contém** o `free_move_ap`
(por isso `GetUIActionPoints` o subtrai, `Unit.lua:2266`) — mas free move só paga
**movimento** (`Unit.lua:2315`).

**Medido no processo vivo:** LegionRaider com `AP=19.0`, `free=7.0`, custo de ataque 4.0 e
mira 1.0. Planejava 3 ataques (3 × (4+2) = 18 ≤ 19) tendo 12.0 utilizáveis. Sete AP de
orçamento fantasma, mais de um ataque inteiro.

A linha existiu como `ap = ap - free_move_ap`, com o comentário *"Fixes considering free
move ap as AP"*, e saiu no commit `91b8eb4` ("1.08", 2025-02-04). O **B18** a desmascarou:
antes, o laço desperdiçava AP em mira e descartava disparos, o que cancelava parte da
inflação.

**Não voltou como era.** Lendo a distribuição de `dest_ap` dos 204 destinos daquela unidade,
só **um** valia 19000 (a posição atual) e o seguinte já caía para 16000. Se o free move
descontasse o trajeto haveria um platô em 19000 para tudo dentro dos 7 AP grátis — não há.
Logo `dest_ap = ActionPoints − custo_bruto`, e subtrair o free move **cheio** cobraria o
deslocamento duas vezes. Provavelmente foi por isso que a linha caiu em 2025.

O que sai é só a franquia **não usada**:

```lua
local moved_ap      = Max(0, (context.start_ap or unit.ActionPoints or 0) - (ap or 0))
local leftover_free = Max(0, free_move_ap - moved_ap)
ap = Max(0, (ap or 0) - leftover_free)
```

| m (trajeto) | dest_ap | franquia que sobra | AP de ataque |
|---|---|---|---|
| 0 | 19 | 7 | **12** |
| 3 | 16 | 4 | **12** |
| 7 | 12 | 0 | **12** |
| 10 | 9 | 0 | **9** |

Os 12 se mantêm até o trajeto estourar a franquia — que é a semântica certa. Na execução é
no-op: `AIPlayAttacks` remove o FreeMove antes (`CombatAI.lua:203`).

**Efeito colateral esperado:** reduz `dest_hit_score` em todo destino com free move
sobrando, ou seja ataca de frente a inflação do Deal Damage.

---

### 🟠 B20 — Desconto por alvo derrubado, agora nos quatro modos

O `AIPrecalcDamageScore` aplica 5% ao `target_score` quando o alvo está caído. Mas o
`hit_score`, que alimenta a `AIPolicyDealDamage`, é capturado **antes** disso (ver
**B10**). Um caído que sobreviva ao corte por ser o único candidato chega na policy sem
desconto nenhum — em **qualquer** modo.

Só o `tokill` tratava disso, porque lá era patológico: o modo normaliza pelo HP do alvo, e
quem está caído tem HP no chão, então `needed` vira ~1 e qualquer tiro satura em 100 —
"finalizar o caído" virava a melhor oportunidade do mapa.

Nos outros três o divisor não colapsa, então o efeito é mais brando — mas a direção é a
mesma e continua errada: uma posição não fica boa por render tiro em quem já está fora.

**Correção.** O fator saiu de dentro do `tokill` e virou `RATOAI_DownedFactor`, aplicado
**uma vez no fim** do `EvalDest`, sobre o score de qualquer modo. No `tokill` a ordem é a
mesma de antes — depois do clamp do `KillIsEnough`. O `EvalDest` passou de vários `return`
para um `score` único com fallback explícito (`relative` sem `ref` e `tokill` sem
alvo/dano continuam caindo no `cap`).

**Onde o desconto NÃO é aplicado, de propósito:** o ramo de compatibilidade que lê
`dest_target_score` quando não há `dest_hit_score`. Aquele número já passou pelos 5% do
precalc — aplicar de novo seria desconto em cima de desconto.

Continuam sendo os mesmos 5% do source: se o número mudar, o lugar de mudar é lá.

---

### 🔴 B21 — Uma rajada valia um acerto só

`hit_score` somava um `attack_mod` por **ataque**, e uma rajada de 6 balas é um ataque.
Rajada com CTH 60 contribuía 60 — 0,6 acerto esperado — quando a expectativa real é
várias vezes isso. **Toda arma automática estava subcontada no scoring de posição.**

O jogo rola bala a bala (`Weapon.lua:2149`, e o override do GBO3 em
`SOURCE_FirearmGetAttackResults.lua:255-279`):

```lua
shot_cth = original_cth - cth_loss_per_shot * Min(b-1, MaxShotIndexForRecoilCTHLoss)
if b > 1 then shot_cth = shot_cth - aim_cth end   -- só a 1ª bala fica com o bônus de mira
shot_cth = Clamp(shot_cth, 0, 100)
shot_cth = Max(shot_cth, Min(MultishotMinCTH, original_cth))
```

com `cth_loss_per_shot = -recoil`, do **mesmo `get_recoil`** que a IA já tinha em mãos.
Constantes conferidas no processo vivo: `MaxShotIndexForRecoilCTHLoss = 6`,
`MultishotMinCTH = 5`.

Replicado em `RATOAI_BurstHits`. **Custo: zero `CalcChanceToHit` a mais** — laço de N ≤ 6
com inteiros sobre dois números já calculados. O `GetAutofireShots` foi hoistado para
`context.burst_shots` (depende só de arma e ação, não do par).

**Magnitude — é mudança de balanceamento, não conserto neutro:**

| cenário | antes | depois |
|---|---|---|
| tiro único CTH 60 | 60 | 60 |
| rajada 4, recoil −8 | 60 | **192** |
| rajada 6, recoil −8 | 60 | **240** |
| rajada 6, recoil −15 | 60 | 160 |
| rajada 6, CTH 25, recoil −15 | 25 | 55 |

O **B19** (free move) baixou `hit_score` para todos; este sobe só para automática. Não se
cancelam — o líquido é fuzileiro automático relativamente mais atraído por posição de
tiro. Recoil alto doma sozinho, que é a mecânica certa fazendo o trabalho.

---

### 🔴 B22 — A sobretaxa de mira do recoil, agora prevista

`Rat_recoil` tem uma reação `OnCalcAPCost` que soma
`cRoundDown(aim_cost * aim_level) * const.Scale.AP` a **qualquer** ataque com mira ≥ 1
feito por quem tem pilhas. O planejador não sabia: orçava mira pelo preço base, a execução
cobrava a sobretaxa por cima, o `HasAP` falhava em `AIStartCombatAction` e **o disparo
simplesmente não saía**. Era o `recoil_aim_cost` declarado e comentado no arquivo com um
`--- I dont think this is going to work`.

Só aparecia do segundo disparo em diante, porque o primeiro do turno não tem pilhas.

**Mudança no GBO3 (afeta o jogador):** a fórmula foi **extraída** de dentro de
`ApplyPersistantRecoilEffects` para `Rat_GetRecoilAimCost(attacker, action, weapon, stacks)`
— pura, sem efeito colateral, sem ler nem escrever o efeito. O `ApplyPersistantRecoilEffects`
passou a chamá-la. **Comportamento idêntico para o jogador**; o que muda é que o valor
virou consultável.

Extrair em vez de reimplementar do lado da IA foi deliberado: a fórmula é cheia de float
(`0.7`, `/30.00`, `cRoundFlt` em 0,5, `0.6`) e uma cópia em aritmética inteira divergiria
em silêncio na primeira vez que um desses números mudasse — é o defeito que o
`RECOIL_STACKS_PCT` já tem, duplicado com um comentário de "manter em sincronia".

**Custo: negligível.** `get_recoilP_value` não recebe alvo nem posição, então é invariante
no turno — cacheado por número de pilhas no context, 3-6 chamadas por unidade por turno em
vez de por par (destino, alvo).

O planejador agora modela as pilhas ao longo do turno, inclusive o reset por mira 3
(`ApplyPersistantRecoilEffects` remove tudo e soma 1). Efeito simulado, AK com 19 AP,
rajada 4 AP, mira 1 AP, já em stance:

| sobretaxa | miras planejadas | sobra |
|---|---|---|
| 0,0 AP | `3, 3, 3` | 1,0 |
| 0,5 AP | `3, 3, 1` | 1,0 |
| 1,0 AP | `3, 3` | 3,0 |
| 2,0 AP | `3, 2` | 2,0 |

É o comportamento que faltava: **mirar menos quando mirar fica caro**, em vez de planejar
um disparo que não sai.

**Compatibilidade:** o chamador é guardado por `rawget(_G, "Rat_GetRecoilAimCost")`. Com um
GBO3 anterior a esta mudança a sobretaxa vira 0 e o comportamento é o de antes, sem erro.

---

### 🔴 B23a / B23b — As pilhas de recoil na avaliação

Dois defeitos no mesmo trecho, ambos no `FUNCTION_ScoreAttacksDetailed.lua`.

**B23a — dupla contagem.** As pilhas eram inicializadas lendo o efeito `Rat_recoil` vivo na
unidade. Mas `CalcChanceToHit` **já desconta as pilhas existentes** — elas entram como
modificador dela. Somar de novo punia o primeiro ataque planejado duas vezes. Agora
`stacks` começa em **zero** e só conta o que o próprio turno planejado acumula.

**B23b — fator de conversão.** `RECOIL_STACKS_PCT` era 35, misturando as duas magnitudes de
recoil. Os dois recoils saem do mesmo `get_recoil` e diferem no multiplicador final: `*0.5`
por bala dentro da rajada, `*0.35*n` persistente entre ataques. Como o valor de partida aqui
é o **por bala**, a conversão correta é `0.35/0.5 = 70%`, não 35%. O valor está duplicado do
GBO3 com comentário de sincronia — é exatamente o defeito que o B22 evitou extraindo a
função em vez de copiar a fórmula.

### 🔴 B24 — Um ataque tardio podia apagar um ataque anterior

A penalidade persistente era aplicada ao **acumulado** em vez de ao CTH daquele ataque. Um
segundo ataque com recoil de −500 zerava (ou invertia) a contribuição de um primeiro ataque
que valia 100 — o destino inteiro perdia valor por causa de um disparo marginal que a
unidade nem precisava fazer.

O conserto é estrutural: cada ataque é clampeado em `[0, 100]` (e no piso `MultishotMinCTH`
dentro da rajada) **antes** de entrar na soma. A soma virou monotônica — planejar um ataque
a mais nunca reduz o score de um destino, no máximo soma zero.

### 🔴 B25 — O MG testava a linha de visão em pé e atirava deitado

Sintoma relatado em campo: o artilheiro anda até um tile de onde enxerga o alvo, monta a MG,
deita — e perde a linha.

`AIBuildArchetypePaths` (CombatAI.lua:1063-1075) escolhe **uma** postura por voxel:

```lua
if pn_ap > mn_ap then  pack(pref_stance)  else  pack(move_stance)
```

Só empacota a postura preferida quando o voxel é alcançável **naquela postura** sobrando mais
AP. Andar deitado é caro, então na prática todo destino além de um ou dois tiles cai no ramo
`move_stance`. Para o `HeavyGunner` (PrefStance=Prone, MoveStance=Standing) isso significa que
quase todos os destinos eram empacotados **em pé**.

O que torna isso um bug e não uma aproximação: **o cache de LOS é chaveado pelo destino
empacotado** — `AIUpdateDestLosCache` (CombatAI.lua:862) faz `srcs[count] = dests[i]`, stance
inclusa. Então esses tiles tinham a linha testada em pé. Depois o `AIActionMGSetup:PrecalcAction`
força `action_state.stance = "Prone"` (AIActions.lua:808), na fase de ataques, com a posição já
escolhida. As policies de LOS premiavam **exatamente** os tiles onde em pé se vê e deitado não —
o viés apontava para o erro, não só o tolerava.

**O conserto não é novo.** O passe de Crouch que já existe logo abaixo faz exatamente este
padrão — troca a stance empacotada, mantém `dest_path` na postura de movimento e tira o custo
da mudança do `dest_ap`. O B25 só estende o padrão para PrefStance = Prone. A stance do destino
passa a significar **onde ela termina**, não como ela chega — que é o que `EndMovement` faz de
fato (`DoChangeStance` ao chegar).

Roda antes do `AIEnumValidDests`, então o cache de LOS já nasce com a postura certa.

**Excludente com o passe de Crouch de propósito:** Standing → Crouch → Prone cobraria a mudança
duas vezes, e a unidade vai direto de pé para deitada.

**Alcance da mudança:** todo archetype com `PrefStance = Prone` — hoje `HeavyGunner` e
`AnimTestDummy_Prone`. O `EmplacementGunner` é Standing/Standing e não é afetado. Desligar em
campo: `RATOAI_PronePackDests = false` no console.

**Medido ao vivo** (`LegionGunner:412`, HeavyGunner, 11 AP, sonda DAP, código *antes* do
conserto):

| | |
|---|---|
| destinos | 68 |
| empacotados **Prone** | **0** |
| empacotados Standing | 44 |
| empacotados Crouch | 24 (o passe de agachar já convertia) |
| destinos com LOS cacheada | 68 de 68 — todas em pé ou agachado |

Zero. Não é "quase sempre em pé" — é que o ramo `pref_stance` **nunca dispara** para esta
unidade. Toda a comparação de posição do artilheiro de MG era feita numa postura que ele não ia
usar.

**Efeito do gate `ap >= cost`:** deitar custa 2 AP a partir de Standing (1 a partir de Crouch).
Dos 68 destinos, **43 sobrevivem** ao gate e passam a Prone; os 25 restantes ficam como estavam.
Isso não é uma perda: são exatamente os destinos longe, onde o AP acabou no caminho — ela não
teria AP para montar a MG lá de qualquer forma. O gate e a viabilidade da ação coincidem.

---

#### ⚠️ B25 NÃO RESOLVEU O SINTOMA — retomar daqui

Testado em jogo em **2026-08-21**: o artilheiro de MG **continua** montando e perdendo a linha.
A mudança está aplicada e a medição acima é real, mas ela **não era a causa** (ou não era a
causa *única*). Não há diagnóstico novo ainda — o que segue são as verificações a fazer, em
ordem de custo, **não** conclusões.

**Antes de qualquer coisa, separar "não rodou" de "rodou e não bastou".** É barato e decide o
resto:

1. `RATOAI_PronePackDests` no console. Se vier `nil`, o arquivo não recarregou e o teste não
   testou nada.
2. Rodar de novo o histograma de posturas da mesma unidade (a query está em
   `DEBUG SERVER.md`; foi ela que produziu a tabela acima). Se **Prone continuar 0**, o passe
   não está executando — checar se `context.archetype` chega preenchido e se
   `StancesList[context.archetype.PrefStance]` é 3 de fato.
3. Se Prone > 0 e o sintoma persiste, o empacotamento foi consertado e **o problema é outro**.

**Verificado desde então (ver B26):** o `AIUpdateDestLosCache` roda **imediatamente depois** do
`AIFindDestinations`, dentro do próprio `AICreateContext` (CombatAI.lua:832-836; o override do mod
mantém a ordem, `SOURCE_AICreateContext.lua:225-229`) — a premissa estava certa. E o cache **é**
sensível à postura empacotada: a forma em batelada do `CheckLOS`, com arrays de `stance_pos` como
origem, devolve os mesmos números da forma objeto+stance (medido ao vivo, tabela no B26). Ou seja,
o B25 realmente muda a postura em que o tile é avaliado. O que **falta** medir é o histograma de
posturas com um artilheiro vivo em campo, para saber se o passe está de fato convertendo.

**Pistas para o caso (3), as demais ainda não verificadas:**
- **Pode não ser LOS, e sim o CONE.** A MG tem arco de tiro; `AIPOLICYPOS_MGSetupPosScore.lua`
  usa `GetShootingAngleDiff`. Perder o alvo ao montar pode ser ângulo, não linha — e aí toda
  esta investigação estava no eixo errado desde o começo.
- **A altura muda a linha, e o `stance_pos_dist` é 2D.** Deitar baixa o ponto de origem do tiro;
  se algum passo compara posições ignorando Z/postura (medido: `stance_pos_dist` ignora os dois),
  a diferença some justamente onde importa.
- **`AIActionMGSetup:PrecalcAction` (AIActions.lua:808)** força `action_state.stance = "Prone"`
  na fase de ataques. Vale ler o que mais ele mexe além da postura.

**Lembrete de higiene:** `RATOAI_PronePackDests = false` desliga o passe no console. Se ele for
descartado de vez, tirar junto o guarda `not prone_pass` que hoje desativa o passe de Crouch para
quem prefere Prone — senão o HeavyGunner fica sem agachar **e** sem deitar.

**A conferir também (independente do acima):** os 2 AP saem do `dest_ap` dos 43, e a montagem da
MG também custa. Vale olhar se o artilheiro não ficou parado demais por falta de orçamento nos
destinos bons.

---

### 🔴 B26 — O cone da MG era decidido com a linha de visão em pé

Sintoma que o Lucas isolou depois do B25: **o único caso problemático é ele montar a MG atrás
de cobertura** (ou de outro obstáculo que corta a linha quando ele deita).

O `stance` é um parâmetro declarado na assinatura do `AIPrecalcConeTargetZones`
(CombatAI.lua:2040) e **nunca usado no corpo**. Quem passa esse parâmetro é um chamador só — o
MGSetup, com um comentário que promete exatamente o que não acontece:

```lua
-- AIActions.lua:807-809
action_state.stance = "Prone" -- MGSetup will change the stance so we need to check LOS in that stance
AIActionBaseConeAttack.PrecalcAction(self, context, action_state)
```

As três medições que decidem quem está dentro do cone usavam a postura do momento: os dois
`CheckLOS` (um com `nil` explícito no lugar da stance) e o `GetLoFData` com `stance = unit.stance`.

**Por que o B25 não bastou.** O B25 conserta a *escolha do tile* — o `g_AIDestEnemyLOSCache` do
artilheiro passou a ser medido deitado. A *decisão de montar a arma* não passa pelo cache: ela
sai do `PrecalcAction`, medido na hora. E há dois momentos em que a unidade **ainda não está
deitada** quando esse cálculo roda:

1. **A porta de reposicionamento.** `Get_HeavyGunnerShouldUsePositioningBehavior` chama o
   `PrecalcAction` na fase de seleção de behavior, antes de qualquer movimento, com a unidade em
   pé. Responder "dá pra montar daqui" medindo em pé mantém o behavior de reposicionamento fora
   da disputa.
2. **O lote de movimento abortado** (`CROUCH_REPORT.md`, item 2). `EndMovement` — que é quem
   aplica a postura do destino — só roda para quem sobrou em `playing`. Quando o lote é
   interrompido, a unidade chega ao destino Prone **em pé**, o `PrecalcAction` mede em pé, e o
   `MGSetup` deita na execução. É intermitente por construção, como o sintoma.

**O conserto é a regra do jogador.** A UI do jogador já previsualiza este cone deitada
(`IModeCombatAreaAim.lua:349`):

```lua
local stance = action.id == "MGSetup" and "Prone" or attacker.stance
GetAOETiles(attacker_pos, stance, ...)  -->  CheckLOS(step_positions, step_pos, -1, stance, ...)
```

O jogador vê o cone deitado antes de confirmar. A IA não via. O override repassa o `stance` para
as três chamadas e nada mais — o diff normalizado contra o vanilla é o `local override` e três
argumentos.

#### Medido no processo vivo (sonda DAP, combate real, 5 alvos)

| unidade | pt-stand | pt-prone | obj-nil | obj-prone |
|---|---|---|---|---|
| LegionButcher:2038 | 5 | **0** | 5 | 0 |
| LegionButcher:2043 | 4 | **1** | 4 | 1 |
| LegionGrenadier:408 | 5 | 4 | 5 | 4 |
| LegionRaider:404 | 5 | 3 | 5 | 3 |

Três coisas ficam provadas, e as duas primeiras eram premissas em aberto do B25:

1. **O 4º parâmetro do `CheckLOS` funciona.** Deitar apaga a linha na maioria dos casos — 5 → 0
   no pior deles. É a magnitude do sintoma.
2. **A engine honra a stance pedida mesmo com o objeto `unit` como origem** (colunas `obj-*` ==
   `pt-*` em todo humano). Não é preciso trocar a origem por um ponto: basta parar de passar
   `nil`. A única linha que diverge é a do cachorro, que não tem stance.
3. **O `GetLoFData` honra `stance` sozinho, sem `step_pos`** (LegionScout:2033: 5 alvos com LOF
   em pé, 3 deitado). Passar `step_pos` junto muda o resultado — o voxel empacotado não é
   exatamente a posição visual — então ele ficou de fora: o objetivo é mudar a altura do olho,
   não a origem.

**Não conserta:** `unit:CalcChanceToHit`, no fim da função, continua medindo o CTH na postura
real — ele não aceita postura hipotética por argumento (Unit.lua:6947 não menciona stance; os
modificadores leem `attacker.stance`/`target.stance` dos objetos). O portão que importa é a
linha, não o número: sem linha deitado, o LOF já derruba o alvo antes do CTH.

**Alcance:** só o MGSetup passa stance. Overwatch, DanceForMe e EyesOnTheBack passam `nil`, e o
MGRotate (já montado) chama com a unidade já deitada — nos dois casos as chamadas são as do
vanilla. Desligar em campo: `RATOAI_ConeStanceLOS = false`.

> ⚠️ **Falta registrar no editor de mods.** Sem entrar na lista `code`, é código morto.

---

### 🔴 B27 / PERF C13 — `AIPolicyMGSetupPosScore` reescrita

A policy que deveria responder *"esta é uma boa posição para montar a MG?"* nunca discriminou
tile nenhum. Cinco defeitos, todos lidos no código:

**1. O portão de ângulo era um no-op por incompatibilidade de unidade.** Ela passava
`GetShootingAngleDiff(unit, weapon, enemy, true)` como `angle_override` para o
`RATOAI_GetEnemyCoverScore`, onde o valor é comparado com `angle_ap_threshold * const.Scale.AP`
= **2000**. Mas `GetShootingAngleDiff` (GBO3, `shooting_stance_functions.lua:106-122`) devolve
`abs(unit:AngleToPoint(pos)) / (weapon.OverwatchAngle / 2)` — uma **razão**, tipicamente 0–15.
O caminho sem override passa `unit:GetShootingStanceAP(...)`, que é AP de verdade. Com o
override, `angle_ap <= 2000` era sempre verdadeiro.

**2. O ângulo saía da UNIDADE, não do tile.** `AngleToPoint` usa a posição e a orientação atuais
dela — o mesmo valor para todos os destinos. É a causa direta do "nunca funcionou direito".

**3. A visibilidade também era da posição atual** (`context.enemy_visible`, gravado uma vez por
turno). Um inimigo que só se vê *daqui* entrava na conta de um tile do outro lado do mapa.

**4. Média em vez de aglomerado.** Retornava `score / Max(1, enemies)`: um tile com linha para 4
inimigos alinhados valia o mesmo que um com linha para 1 — justamente o sinal que a policy
existia para dar (`AI_SYSTEM_GUIDE.md` §9.2d).

**5. `Update_AIPrecalcDamageScore(unit)` dentro do `EvalDest`** — precalc completo disparado de
dentro da varredura de tiles (protegido por flag, então roda uma vez, mas roda escondido).

**A nova pergunta é só uma:** *quantos inimigos cabem no meu cone se eu deitar aqui?* Portão de
LOS deitado pelo cache que a engine já calculou (zero raycast novo), anel de alcance do cone
medido **do tile**, e uma janela deslizante circular sobre os ângulos para achar o maior
aglomerado. `cone_angle` é largura **total** — a UI desenha de `-cone_angle/2` a `+cone_angle/2`
(`UnitAOEActionVisuals.lua:450`).

#### Medido no processo vivo, sobre os destinos reais de uma unidade

`LegionRaider:457`, cone 22°, anel 2–23 slabs, 4 inimigos, **1384 tiles**:

| | |
|---|---|
| zerados pelo portão de LOS | 460 |
| com nota | 435 |
| histograma `score:qtd` | `0:949  40:70  70:264  100:101` |
| **tempo total** | **14 ms** |

A versão antiga, nos mesmos 1384 tiles: 4 inimigos × `ChanceToHitModifier:CalcValue` (0,03 ms
medido) + `GetShootingAngleDiff` (0,003 ms) ≈ **200 ms**. Catorze vezes mais barata, e agora com
gradiente de verdade — 70 tiles cobrem 1 inimigo, 264 cobrem 2, 101 cobrem 3.

**Custo depende de onde ela está ligada:** em `EndTurnPolicies` roda por `context.destinations`
(~68); em `OptLocPolicies`, por `context.all_destinations` (1384–1477 medidos, raio 100). A
versão nova aguenta as duas.

**Armadilha registrada:** `ReserveAPforSetup` (que substitui o `ReserveAPforCrouchProne` de 2000
AP fixos pelo custo real de `CombatActions.MGSetup:GetAPCost`) **não** deve ser ligada em
`OptLocPolicies` — tile fora do alcance de movimento não tem `dest_ap` e seria zerado, o que
impediria a IA de mirar uma posição a dois turnos de distância. Default `false`.

**Compatibilidade:** a classe manteve o nome, então o `PlaceObj('AIPolicyMGSetupPosScore', {…})`
do `items.lua` continua válido e o Weight não se perde. As propriedades novas entram com default.

---

#### B27, segunda passada — o portão binário não bastava para CONTAR

Relatado em campo depois da primeira versão: a policy continuava pontuando tiles de onde o
artilheiro não veria nada, **principalmente nas bordas de obstáculo**, e em lugares onde ele não
veria nem de pé — ou seja, o defeito não era de postura.

A causa é a assimetria entre o portão e a contagem: `g_AIDestEnemyLOSCache[dest]` responde
*"**algum** inimigo é visto daqui"*, o que é o critério certo para o tile entrar na disputa e o
insumo errado para contar aglomerado. Borda de obstáculo é exatamente a geometria onde se tem
linha para **um** inimigo — e a contagem, puramente geométrica (anel de alcance + ângulo), dava
crédito pelos outros três atrás da parede.

Conserto: um raio por inimigo do anel, **a partir daquele tile, deitado**, memoizado por tile.
Só os vistos entram na janela deslizante.

**Medido sobre 1509 destinos reais, 22 inimigos conhecidos pelo time, cone 17°:**

| | histograma `score:qtd` | tempo |
|---|---|---|
| só geometria | `0:899  100:610` | 119 ms |
| com checagem | `0:962  40:61  70:76  100:410` | 522 ms (11292 raios) |

Duzentos tiles que reivindicavam nota máxima eram mentira, e o gradiente 40/70/100 só existe com
a checagem — sem ela o resultado é quase binário (0 ou 100).

**Custo, e por que existe orçamento.** Medido: **0,04 ms por raio** (900 tiles × 22 inimigos =
19800 raios em 793 ms numa batelada única; uma chamada por tile custa 1187 ms — batelada só ganha
1,5×, o custo é raio, não chamada). Daí:

- `EndTurnPolicies` (~68 destinos): ~1500 raios, **~70 ms**. É o placement atual e cabe.
- `OptLocPolicies` (~1500 destinos): ~11000 raios, **~520 ms**. Não cabe.

`MaxLOSChecks` (default 4000 ≈ 160 ms) é o teto por turno; estourado, os tiles restantes caem
para geometria pura — e a nota deles fica otimista. **A recomendação é manter a policy em
`EndTurnPolicies`.**

**Isso também explica "pararam de montar".** A policy geométrica mandava o artilheiro para tiles
cegos; chegando lá, o `AIActionMGSetup:PrecalcAction` não acha zona nenhuma (nem em pé — e o B26
nem estava registrado, então era o vanilla medindo) e a ação fica indisponível. Ele anda e não
monta. Com a checagem, esses tiles deixam de ganhar nota.

---

### 🔴 B28 — Montava a MG e atirava em alguém fora do cone

Bug antigo, ressurgido. **O filtro de cone existe e está correto**
(`SOURCE_AIPrecalcDamageScore.lua:187-191`): com `StationedMachineGun`, `targets` é filtrado por
`target:IsThreatened({unit}, "overwatch")`. Nada foi removido dele.

O defeito é de **ordem**. Dentro de um mesmo turno, `AIPlayAttacks` (CombatAI.lua:216) roda o
`AIPrecalcDamageScore` **antes** de escolher a signature action — com a unidade ainda em pé e sem
MG montada. O filtro não dispara. O `MGSetup` executa depois e cria o cone; ao voltar, a linha 268
lê o alvo que já estava gravado:

```lua
local target = (context.dest_target or empty_table)[dest]
```

e atira nele, cone ou não. O filtro só pegaria no turno seguinte, quando o `HoldPositionAI`
"In Setup" refaz o precalc com a unidade já montada.

Conserto em `REACTIONS_StopMGPackingUp.lua` (arquivo já registrado, não precisa de editor):
no `OnMsg.CombatActionEnd` do `MGSetup`, apaga `context.dest_target[dest]`. Isso faz o **caminho
de recuperação que o vanilla já tem** (CombatAI.lua:269-277) refazer o precalc — agora com o
`StationedMachineGun` aplicado, então o filtro de cone entra. Não é preciso tocar no
`AIPlayAttacks`.

Guarda registrada: esse mesmo bloco do vanilla reinicia o turno inteiro quando
`TargetChangePolicy == "restart"`. O default é `"recalc"` e no `items.lua` só o `Brute` usa
`"restart"` — que não monta MG. O guarda está explícito no código mesmo assim.

Interruptor próprio: `RATOAI_MGRetargetAfterSetup = false`. **Não** está sob o `RATOAI_LOSFixes`
de propósito — é bug de outra família, e a ideia é poder testar um sem o outro.

---

### 🔴 B29 — A policy da MG dizia "sim" no teto e o `MGSetup` sumia da lista

Sintoma que o Lucas relatou: a `AIPolicyMGSetupPosScore` pontua positivo em alguns tiles e a
`AIActionMGSetup` não aparece como signature action, sem mensagem nenhuma. Isolado com a sonda
`tools/check_mgsetup_gates.lua`, que roda a cadeia inteira de portões da ação na mesma ordem do
jogo e diz onde morreu. Combate real, turno 1, dois `HeavyGunner`:

```
LegionGunner:411 (RPD_1)
POLICY   nota=0 | 0/115 destinos >0
PORTÃO 4 inimigos=4 | visíveis PARA ESTE ATIRADOR=0 | vistos pelo TIME=4 -> target_pts=0
VEREDITO MGSetup INDISPONÍVEL — morreu em: AICalcAOETargetPoints

LegionGunner:412 (MG42)
POLICY   nota no ai_destination=100 (teto) | 4/57 destinos >0
PORTÃO 5 cone: 5 alvos | PORTÃO 6 alcance: 5/5 | PORTÃO 7 CTH>0 com aim 0: 0/5
PORTÃO 8 score=99 (= min_score-1, sentinela de "nenhuma zona") -> IsAvailable=false
VEREDITO MGSetup INDISPONÍVEL — morreu em: CalcChanceToHit == 0
```

**A causa dominante é o CTH, e ela é circular.** O fim do `AIPrecalcConeTargetZones` descarta do
cone todo alvo com `chance_to_hit == 0`, e o CTH é medido com `aim = 0` na postura de tiro atual —
antes do setup. Decomposto ao vivo (MG42 a 22 m): `base=74 Bipod=-5 HipshotPenalty=-58 Crouch=-9
WeaponCondition=-10` → 0. A ação que existe para montar a arma estava sendo julgada pela pontaria
de quem ainda não montou.

Não era o hipfire: o `if action.id == "MGSetup" then aim = Max(aim, 1) end` já existia, e o
`GetWeaponHipfireOrSnapshotMul` desvia por `aim == 0` (hipfire) vs `aim > 0` (snapshot) — ou seja o
preview já entrava pelo ramo **snapshot**. O que faltava era `opportunity_attack`. O ramo de
interrupção de MG já existe no GBO3 (curva `MGInterruptMaxDist` = 90 tiles em vez de 40,
`MGInterruptBasePenalty` = -16, vezes `MGSetupInterruptMul` = 80) e nunca era alcançado pela
previsão. Medido, mesmo alvo:

| | HipshotPenalty | CTH |
|---|---|---|
| `aim 0` | -58 | 1 |
| `aim 1` (o `Max(aim,1)` que já existia) | -58 | 2 |
| `aim 1` + `opportunity_attack` | **-32** | **19** |
| `aim 3` (modificador some acima de 2) | 0 | 62 |

E a intermitência é literal: rodando a sonda de novo depois que o alvo andou ~2,8 m, o CTH de um
único alvo passou de 0 para 1, o `PORTÃO 7` foi de `0/5` para `1/5`, o score de 99 para 110 e o
`MGSetup` virou DISPONÍVEL. A decisão inteira pendura num limiar duro (`== 0`) sobre um número que
estava errado por ~30 pontos.

**Consertos aplicados.**

*No GBO3 (`CTH_hipfire_and_snapshot.lua`)* — a previsão passa a medir o tiro que a arma vai fazer:
```lua
if action.id == "MGSetup" or action.id == "MGRotate" then
    aim = Max(aim, 1)
    opportunity_attack = true
end
```
O tiro real já chega com `opportunity_attack = true`, então ele não muda; muda só quem pergunta
"quanto eu acertaria se montasse". O jogador não vê CTH por alvo em ação de cone
(`IModeCombatAreaAim` não chama `CalcChanceToHit`).

*No GBO3 (`COMBAT_ACTIONS.lua`, `rat_MGSetup_getap`)* — o custo de deitar deixa de ser invisível:
```lua
if not unit:HasStatusEffect("ManningEmplacement") then
    cost = cost + Max(0, unit:GetStanceToStanceAP("Prone"))
end
```
`Unit:MGSetup` (vanilla, `UnitActions.lua:537`) deita com `DoChangeStance`, que não debita AP —
verificado no processo vivo que nenhum mod substitui as duas funções. Ou seja o prone sempre foi
grátis, para merc e para IA, e por isso o MGSetup custava o mesmo em qualquer posição. Agora: em pé
+2, agachado +1, já deitado +0. Total pago continua o mesmo; o que muda é que ele passa a depender
da posição. Fica **depois** da redução do `HeavyWeaponsTraining` de propósito — a perk barateia
manejo de arma pesada, não o ato de deitar, e assim o piso `min_ap_cost` não engole o delta.

Com isso a conta do B25 fecha nos dois caminhos, medido ao vivo (`GetStanceToStanceAP` = 2000):

| postura do dest | descontado do `dest_ap` pelo B25/crouch | cobrado pelo MGSetup | total |
|---|---|---|---|
| Prone | 2000 | 0 | 2000 |
| Crouch | 1000 | 1000 | 2000 |
| Standing | 0 | 2000 | 2000 |

Antes, o desconto do B25 era **custo fantasma**: o MGSetup cobrava o mesmo dos dois lados e o
`DoChangeStance` do `EndMovement` nunca debitava nada. Confirmado: o LegionGunner:412 escolheu
ficar onde estava e tinha `AP real = 11000` contra `dest_ap = 9000` — a diferença era exatamente a
reserva do prone.

*Na policy (`AIPOLICYPOS_MGSetupPosScore.lua`)* — quatro pontos onde ela respondia uma pergunta
mais frouxa que a da ação:

| | o que era | o que é |
|---|---|---|
| B29a | anel `d >= min_range` cru, sem teto de visão | `min >= max` vira "sem mínimo" (é o que o `AIFilterTargetPoints` do vanilla faz) e o máximo é clampado por `Min(sight, GetMaxRange())`, o segundo `CheckLOS` da ação. Mora em `RATOAI_MGConeRange` (`CONSTANTS_AI_source.lua`), fonte única lida pelos dois lados |
| B29b | pool sempre `enemy_visible_by_team` | novo `visibility_mode = "self"`, o mesmo `VisibilityCheckAll ... uvVisible` do `AICalcAOETargetPoints` |
| B29c | cega para aliados | novo `AllyPenalty` (default 30), subtraído por aliado na janela vencedora |
| B29d | reserva de AP com o custo medido da postura ATUAL | medido da postura **do destino**, senão o dest empacotado Prone paga a postura duas vezes |

O B29a vale para a `BrowningM2HMG`, que continua com `min == max == WeaponRange` — para ela o gate
antigo era `d == max_range`, ou seja a policy zerava **todo** tile. As MGs comuns já tinham `min=2`
por causa do override do GBO3, então ali o efeito é só o teto de visão.

**Custo do B29c, e por que a ordem importa.** O anel é largo (2,4 m a ~50 m) e o time é grande:
medido, **22 a 24 dos 26 aliados** do artilheiro caem dentro dele. Passar todos pelo lote de raios
custaria ~3000 raios por turno só em amigo — o teto inteiro do `MaxLOSChecks`. O cone, porém, é
estreito (645 a 1049 minutos nas MGs medidas, 11° a 17°), então o filtro barato vem primeiro: só
entra no lote de raios o aliado cujo ângulo cabe em alguma janela ancorada num inimigo que já
sobreviveu ao LOS. Na prática sobram 0 a 2.

**O que a policy continua sem ver, de propósito:** o CTH. Ele foi consertado do outro lado. Medir
CTH por tile aqui custaria um `CalcValue` por inimigo por tile — exatamente o que o B27 tirou.

*Na `AIPOLICYPOS_MGSetupAP.lua`* — mesma correção de reserva (B29d), mais duas que só existiam ali:
a consulta ao `g_AIDestEnemyLOSCache` usava o `dest` cru (postura que ele por acaso tem, não Prone)
e tratava `nil` como "sem linha". Essa policy roda com `Required = true` no `PositioningAI`
"MG Setup", então erro ali não dilui: **elimina** o destino.

---

### 🎛️ `RATOAI_MGConeRangePct` / `RATOAI_MGConeRangeTiles` — comprimento do cone da MG

Não é bug, é uma liberdade que o jogador tem e a IA não. Medido no processo vivo, dois cones
ativos no mesmo combate:

```
Grizzly (merc)      dist até target_pos = 15481   (~13 tiles, escolha do jogador)
LegionGunner:412    dist até target_pos = 45600   (= max_range exato)
```

`AIPrecalcConeTargetZones` monta o alvo com `target_pos = attack_pos + SetLen(dir, max_range)`, e
para MachineGun `max_range` é o `WeaponRange` inteiro. A IA sempre planta no máximo.

Encurtar importa porque o número de interrupções é limitado (medido: o LegionGunner:412 tinha
**uma**), e um cone de 38 tiles gasta essa única interrupção no primeiro inimigo que pisar na
borda. Rampa do `HipshotPenalty` (MG42, interrupção de MG, aim 1):

| tiles | 4 | 8 | 12 | 16 | 20 | 24 | 28 | 32 | 36 |
|---|---|---|---|---|---|---|---|---|---|
| penal | -10 | -14 | -21 | -29 | -33 | -36 | -40 | -45 | -47 |

~1,2 ponto por tile, **sem joelho** — não há ótimo para derivar, o corte é escolha de projeto. Por
isso é parâmetro, e por isso o default (`pct = 100`, `tiles = 0`) não muda nada. Efeito medido dos
ajustes:

```
RPD_1 WR=38   100/0=38t   60/0=22t   100/20=20t   10/0=8t (piso)
RPD_1 WR=44   100/0=42t   60/0=25t   100/20=20t   10/0=8t
MG42  WR=38   100/0=38t   60/0=22t   100/20=20t   10/0=8t
```

(o `42t` do RPD_1 de WR=44 é o teto de `GetMaxRange`, não o encurtamento.)

Os dois são globais de propriedade — `RATOAI_MGConeRangePct = 60` no console vale na hora. O
`context.__mg_cone` da policy cacheia por turno, então um ajuste no meio do turno só aparece no
próximo.

**Ressalva:** o lado que planta o cone está em `SOURCE_AIPrecalcConeTargetZones.lua`, que **não
está registrado** na lista `code` do `metadata.lua` — verificado no processo vivo, quem roda é o
`AIPrecalcConeTargetZones` do vanilla (`@Lua/Tactical/CombatAI.lua`). Sem registrar pelo editor, o
parâmetro muda só a nota dos tiles e o cone continua sendo plantado no máximo. **O B26 está no
mesmo barco — ele nunca rodou.** O outro arquivo em disco fora da lista é
`SOURCE_AIGetBias.lua`.

---

### 🎛️ Interruptor mestre: `RATOAI_LOSFixes`

Definido em `CONSTANTS_AI_source.lua`. `RATOAI_LOSFixes = false` no console devolve **as três**
intervenções de linha de visão ao comportamento anterior, na hora, sem recarregar mod nem sair do
combate:

| | arquivo | o que volta a ser |
|---|---|---|
| B25 | `SOURCE_AIFindDestinations.lua` | destino de PrefStance=Prone volta a ser empacotado em pé |
| B26 | `SOURCE_AIPrecalcConeTargetZones.lua` | cone da MG volta a ser medido na postura atual |
| B27 | `AIPOLICYPOS_MGSetupPosScore.lua` | portão de LOS e checagem por inimigo desligados (a nota vira geometria pura) |
| B29c | `AIPOLICYPOS_MGSetupPosScore.lua` | o raio que confirma o aliado no cone (o desconto por aliado continua, por geometria pura) |
| B29e | `AIPOLICYPOS_MGSetupAP.lua` | a consulta ao cache de LOS volta a usar o `dest` cru em vez da chave Prone |

Os individuais continuam valendo (`RATOAI_PronePackDests`, `RATOAI_ConeStanceLOS`, e as
propriedades `RequireLOS` / `VerifyLOS`); o mestre tem precedência.

Fora dele, de propósito: a policy em si e o B28.

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
