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
