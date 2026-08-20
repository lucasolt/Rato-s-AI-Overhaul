# Mira, número de ataques e Shooting Stance

Como a IA decide **quantos tiros** dá e **com quanta mira**, e por que o Shooting Stance
do GBO3 complica cada peça disso.

Arquivo central: `Code/SOURCE_AICalcAttacksandAim.lua`. Ele é chamado por
`RATOAI_ScoreAttacksDetailed` **por par (destino, alvo)**, então tudo aqui roda no laço
mais quente do mod.

> Verificado em agosto de 2026 contra o source do jogo, o GBO3 3.51 e medições no processo
> vivo (`tools/dap_probe.py`, ver `DEBUG SERVER.md`). Onde algo é inferência e não
> medição, está marcado.

---

## 1. As três moedas

Não confunda — elas entram em lugares diferentes da conta.

| moeda | de onde vem | quanto (amostra medida: Jungle Carbine) |
|---|---|---|
| **custo do ataque** | `context.default_attack_cost = default_attack:GetAPCost(unit)` | 5,0 AP |
| **custo de mira** | `Get_AimCost(unit)` (`FUNCTIONS_CombatGeneral.lua:162`) | 1,0 AP por nível |
| **custo de stance** | `GetWeapon_StanceAP(unit, weapon)` (`FUNCTIONS_CombatAP.lua:90`) | 4,0 AP |

`Get_AimCost` é `const.Scale.AP` ajustado por chuva (`RainAimingMultiplier`). Ou seja:
**1 AP por nível de mira, exceto chovendo.**

---

## 2. Anatomia do `GetAPCost` — e a pegadinha do `args = nil`

`COMBAT_ACTIONS.lua:20-47` (GBO3 sobrescreve `SingleShot.GetAPCost`):

```lua
local ap_extra   = unit:GetShootingStanceAP(args and args.target or false, weapon,
                                            args and args.aim or 0, action) or 0
local ap_delta   = rat_getDeltaAP(action, weapon)
local cycling_ap = weapon.unbolted and rat_get_manual_cyclingAP(unit, weapon, true) * const.Scale.AP or 0

return unit:GetAttackAPCost(self, weapon1, false, args and args.aim or 0, ap_delta)
       + ap_extra + cycling_ap
```

**O `AICreateContext` chama isso sem `args`**:

```lua
context.default_attack_cost = default_attack:GetAPCost(unit)   -- args = nil
```

Então `target = false` e `aim = 0`. Siga o `target = false` até o fundo:

`Unit:GetShootingStanceAP` (`FUNCTIONS_CombatAP.lua:3`) → em stance, devolve `ap_rotate`:

```lua
ap_rotate = Clamp(ShootingConeAngle(self, weapon, target) * const.Scale.AP, 0,
                  ap_stance + Get_AimCost(self))
```

`ShootingConeAngle` → `GetShootingAngleDiff` (`shooting_stance_functions.lua:106`):

```lua
local target_pos = IsValid(target) and target:GetPos() or target   -- false
if force or Is_AimingAttack() then target_pos = target_pos or GetCursorPos(true) end
if not target_pos then
    return 0        -- <<< sem alvo, ângulo zero
end
```

**Conclusão: `ap_extra = 0` no `default_attack_cost`.** O número que a IA carrega é o
custo *nu* do ataque — sem rotação, sem mira, sem stance. Isso é **bom** (as três entram
separadas depois no `AICalcAttacksAndAim`), mas explica uma discrepância que confunde:

> A UI mostra **5,5 AP** e o `context.default_attack_cost` é **5,0**. Os 0,5 de diferença
> são o `ap_rotate` com um alvo de verdade, que a UI tem e a IA não.

Não é bug. É a mesma ação medida com e sem alvo.

---

## 3. `AICalcAttacksAndAim` — a árvore de decisão

```
min_aim, max_aim = GetBaseAimLevelRange(...)      -- com AI_dont_return_Stance_min_aim_level

has_stance = (AIisPlayingAttacks e tem shooting_stance)
             OU (attacker_pos == unit_pos  E  tem shooting_stance)

se has_stance:  rotation_cost = GetShootingStanceAP(..., "rotate")   ; stance_cost = 0
senão:          stance_cost   = GetWeapon_StanceAP + aim_cost        ; rotation_cost = 0

cost = default_attack_cost                    (+ bolting_cost se a arma cicla e está travada)
total_stance_cost = cost + stance_cost

se AIisPlayingAttacks e tem stance: total_stance_cost = 0 ; stance_cost = 0

has_stance_ap = ap >= total_stance_cost

-- escolha de hipfire (RATOAI_HipfireMaxDist): se preparar custa disparo e está perto,
-- desliga has_stance_ap de propósito

se not has_stance_ap:  stance_cost = 0                (dispara do quadril)
senão:                 min_aim = min_aim + 1          (a stance dá um nível de graça)

desired_aim_level      = GetIdealAimLevels(context, target_dist, max_aim, min_aim)
to_reach_desired_aim   = desired_aim_level - min_aim

┌── RAMO CURTO ── se `not has_stance_ap` OU `to_reach_desired_aim <= 0`:
│      num_atks = Min(max_attacks, Max(0, ap - stance_cost) / cost)
│      todos os disparos saem em `min_aim`, sem escalada de mira
└── RAMO LONGO ── senão:
       first_atk_cost = stance_cost + rotation_cost + cost
       sobe a mira do 1º tiro enquanto sobrar AP e não passar do desired
       repete para os tiros seguintes até acabar AP ou bater max_attacks
```

**`attacker_pos == unit_pos` é o coração disso.** `context.attacker_pos` é o **destino
sendo avaliado** (setado em `AIPrecalcDamageScore`). Então `has_stance` só é verdadeiro no
destino que é a posição atual da unidade. Para todo outro destino a IA orça a re-entrada
na stance — o que está **certo**, ver §5.

---

## 4. Caso traçado: por que o sniper deu 1 tiro e não 2

Medido no jogo (leitura de campo, sem chamar nada):

```
default_attack = SingleShot   default_attack_cost = 5000   (5,0 AP)
Get_AimCost         = 1000    GetWeapon_StanceAP  = 4000
shooting_stance     = ativo   max_attacks (ctx)   = 3      unit.MaxAttacks = 1
unit.ActionPoints   = 11600   dest_ap             = 9100
resultado: attacks = 1, aims = {0}
```

`dest_ap` (9,1) < `ActionPoints` (11,6) ⇒ **o destino avaliado exigia ~2,5 AP de
movimento**, logo `not_moved = false`:

```
has_stance        = false
stance_cost       = 4000 + 1000 = 5000
total_stance_cost = 5000 + 5000 = 10000
has_stance_ap     = 9100 >= 10000  ->  FALSO
  -> stance_cost = 0, min_aim NÃO é incrementado (fica 0)
  -> RAMO CURTO: num_atks = Min(3, 9100/5000) = Min(3, 1) = 1
resultado: 1 tiro, mira 0
```

**É internamente coerente**: "não tenho AP para re-preparar a arma ali, então dou um tiro
de quadril". Não há stance sendo cobrada duas vezes.

Ficando parada (o destino *sendo* a posição atual) a conta muda:

```
has_stance = true -> stance_cost = 0, total_stance_cost = 5000
has_stance_ap = 11600 >= 5000 -> VERDADEIRO -> min_aim += 1
num_atks = Min(3, 11600/5000) = 2        <- dois tiros, com um nível de mira
```

Ou seja: **o "1 tiro" é propriedade do destino escolhido, não do cálculo de stance.**

---

## 5. Ciclo de vida do Shooting Stance

Quem **remove** (é mais gente do que parece):

| gatilho | onde |
|---|---|
| `Move`, `Sprint`, `InteractWith`, `CombatGoto` no início do movimento | `REACTIONS_ShootingStance.lua:40-54` |
| `Move`, `RunAndGun`, `RecklessAssault`, `MobileShot`, `HundredKnives`, `Sprint` ao terminar | `REACTIONS_ShootingStance.lua:56-68` |
| `TakeCover`, `LeaveEmplacement`, `MGPack`, `ThrowGrenade`, `InteractWith`, `ThrowKnife`, `ReloadAction`, `DoubleToss`, `Sprint` | `REACTIONS_ShootingStance.lua:70-83` |
| ficar Prone (só jogador) | `REACTIONS_ShootingStance.lua:11-15` |
| trocar de arma | `SOURCE_SwapWeapon.lua:15` |
| qualquer movimento **fora** de combate | `CharacterEffect/shooting_stance.lua:18` |

> Cuidado ao ler: a reação em `CharacterEffect/shooting_stance.lua` tem `if not g_Combat
> then RemoveStatusEffect(...)`, o que sugere que em combate a stance sobrevive ao
> movimento. **Não sobrevive** — quem remove em combate é o
> `REACTIONS_ShootingStance.lua`, que não checa `g_Combat`. São handlers diferentes para
> a mesma mensagem, e só o segundo manda no caso que importa.

O que a stance faz na conta de AP: `GetShootingStanceAP` devolve **`ap_rotate` em vez de
`ap_stance`** quando a unidade já está em stance. Rotacionar é proporcional ao ângulo até
o alvo, teto em `ap_stance + Get_AimCost`.

E o efeito colateral posicional: `EnterShootingStance` faz
`return_pos_reserved = return_pos; return_pos = false`, o que quebra o invariante
`return_pos or self` do vanilla. Ver **B17** no `WEIGHTS_AUDIT.md`.

---

## 6. O recoil encarece a mira — e a IA não sabe disso

`Rat_recoil` (`CharacterEffect/Rat_recoil.lua:169-170`):

```lua
local aim_cost   = self:ResolveValue("aim_cost")
local extra_cost = cRoundDown(aim_cost * aim_level) * const.Scale.AP
```

Descrição do próprio efeito: *"Currently increases aim cost — up to the third aim level —
by `<aim_cost>`. Moving 3 tiles, reloading, entering Overwatch or exiting Shooting Stance
will remove this effect."*

O valor sai de `FUNCTIONS_recoil.lua:38-54`, é arredondado em passos de 0,5 e **limitado a
5 AP** (`Min(5, aim_cost)`), e limitado ao `stance_cost` em alguns caminhos.

**A IA ignora isso.** Em `SOURCE_AICalcAttacksandAim.lua` existe:

```lua
local recoil_aim_cost = 0
...
-------- Persistant recoil aim cost increase
--- I dont think this is going to work
--[[if not_moved then
    local recoil = unit:GetStatusEffect("Rat_recoil")
    if recoil then
        recoil_aim_cost = recoil:ResolveValue("aim_cost")
    end
end]]
```

O bloco que preencheria está comentado e `recoil_aim_cost` **nunca é usado** no resto da
função. Consequência: a partir do 2º tiro, a IA orça mira a 1 AP quando o jogo vai cobrar
1 + `aim_cost` — ela **planeja mais tiros mirados do que consegue pagar**.

Repare que isso é o defeito de sinal **oposto** ao caso do §4: lá ela subestima a própria
capacidade; aqui superestima. Os dois podem coexistir porque vivem em ramos diferentes.

---

## 7. Lacunas conhecidas

### 7.0 ✅ O laço de tiros seguintes comprava mira ANTES de garantir o tiro — CORRIGIDO (B18)

```lua
while remaining_ap > 0 do
    local current_aim = min_aim
    local max_attacks_reached = index > context.max_attacks

    while remaining_ap >= aim_cost and (current_aim < desired_aim_level or max_attacks_reached) do
        current_aim = current_aim + 1
        remaining_ap = remaining_ap - aim_cost
        if max_attacks_reached then break end
    end

    if remaining_ap >= atk_cost and not max_attacks_reached then
        aims[index] = current_aim ; index = index + 1 ; remaining_ap = remaining_ap - atk_cost
    else
        break
    end
end
```

A mira é comprada **gulosamente até `desired_aim_level`** e só depois se pergunta se o
disparo ainda cabe. Se não couber, o laço faz `break` — **sem nunca recuar um nível de
mira para o tiro caber**.

Traço com `remaining_ap = 3`, `aim_cost = 1`, `cost = 2`, `desired = 3`, `min_aim = 0`:

| passo | mira | AP restante |
|---|---|---|
| compra mira | 1 | 2 |
| compra mira | 2 | 1 |
| compra mira | 3 | 0 |
| `0 >= 2`? não | — | **break, nenhum tiro** |

Ótimo seria mira 1 + disparo = 3 AP, **um tiro**. O laço devolve **zero**.

**Corrigido** (`BUGFIX (B18)`) — o nível só é comprado se o disparo continuar cabendo:

```lua
while remaining_ap - aim_cost >= atk_cost and current_aim < desired_aim_level do
```

Com isso, `AP 9 / tiro 2 / mira 1 / desired 3` passa de `[3]` para `[3, 2]`: um disparo
com mira cheia e outro com o que sobrou.

O **primeiro** disparo não tem esse defeito: ali a mira sai de
`remaining_ap_after_first_atk`, que já teve o custo do ataque descontado.

### 7.0b 🔴 "Gastar o AP que sobrou mirando" está escrito mas não acontece

O `or max_attacks_reached` na condição interna parece existir para despejar AP sobrando em
mira quando não cabem mais disparos. Não é o que ocorre:

1. compra **um** nível e sai do laço interno (`if max_attacks_reached then break end`);
2. grava em `current_aim`;
3. o `if` externo falha (`not max_attacks_reached` é falso) e dá `break`;
4. **`current_aim` é descartado** — nunca chega em `aims`.

Ou seja: queima um `aim_cost` e não produz nada. O AP que sobra **nunca** vira mira.

É exatamente o sintoma observado no sniper: 4,1 AP sobrando e mira 0. Para implementar de
verdade a intenção, o upgrade teria que ir para `aims[#aims]` depois do laço, não para uma
variável local que morre.

### 7.1 🟡 `rotation_cost` some no ramo curto

```lua
-- RAMO CURTO
local num_atks = Min(context.max_attacks, Max(0, ap - stance_cost) / cost)
--                                                    ^^^^^^^^^^^ rotation_cost ausente

-- RAMO LONGO
local first_atk_cost = stance_cost + rotation_cost + cost
```

É a **mesma forma** do `BUGFIX (B14)`, que consertou a ausência do `stance_cost` neste
ramo — mas não incluiu o `rotation_cost` junto.

**Quando morde:** unidade **parada e já em stance** (`has_stance = true`, logo
`rotation_cost > 0` e `stance_cost = 0`) que caia no ramo curto por
`to_reach_desired_aim_level <= 0`. Ou seja: exatamente o caso "sniper em posição girando
para um alvo novo". A contagem de disparos sai inflada pelo custo da rotação.

Não corrigido — está aqui para ser decidido, não é patch aplicado.

**Prioridade baixa por decisão de projeto:** enquanto a IA não trocar de alvo entre
disparos (e hoje ela não troca), a rotação só teria efeito no primeiro tiro, onde ela já é
cobrada no ramo longo. A inconsistência é real mas o impacto prático é pequeno.

### 7.2 🟠 O ramo curto nunca escala mira

Ele devolve **todos** os disparos em `min_aim`. Se `desired_aim_level <= min_aim` isso é
correto por definição. Mas quando ele é alcançado por `not has_stance_ap`, a unidade pode
ter AP sobrando e mesmo assim sair com mira mínima — sem nunca perguntar "e se eu mirasse
em vez de guardar AP?".

Sintoma observado: sniper com 4,1 AP sobrando depois do tiro, mira 0, `Get_AimCost` 1,0.
Ela não gasta o resto e não mira.

### 7.3 🟡 `unit.MaxAttacks` vs `context.max_attacks`

`AICreateContext` faz `context.max_attacks = unit.MaxAttacks + extra_max_attacks`, com
`extra_max_attacks = 2` (0 para RPG e para sniper que destrava ferrolho). Medido: um
sniper com `unit.MaxAttacks = 1` anda com `context.max_attacks = 3`. O teto real de
disparos passa a ser o AP, não o `MaxAttacks` da unidade — deliberado, mas fácil de
esquecer ao ler `max_attacks` e achar que é o limite do personagem.

### 7.4 🟡 Escolha de hipfire é por distância, não por CTH

`RATOAI_HipfireMaxDist` (default `const.Weapons.PointBlankRange`, que o GBO3 sobe para 6)
desliga `has_stance_ap` quando preparar custaria disparo e o alvo está perto. É
aproximação deliberada — comparar CTH exigiria mais uma chamada de `CalcChanceToHit` por
(destino, alvo), que é o gargalo conhecido. Ver o cabeçalho do arquivo.

---

## 8. Ordem de leitura para auditar

1. `Code/SOURCE_AICreateContext.lua:14-42` — de onde saem `default_attack_cost`,
   `max_attacks` e a degradação para `SingleShot` por falta de AP de stance
2. `Code/SOURCE_AICalcAttacksandAim.lua` — a árvore inteira
3. `Rato-s-Gameplay-Balance-and-Overhaul-3/Code/COMBAT_ACTIONS.lua:20-47` — `GetAPCost`
4. `.../Code/FUNCTIONS_CombatAP.lua:3-58` — `GetShootingStanceAP`
5. `.../Code/REACTIONS_ShootingStance.lua` — o ciclo de vida da stance
6. `.../CharacterEffect/Rat_recoil.lua` + `.../Code/FUNCTIONS_recoil.lua` — o encarecimento
   da mira

**Regra de aritmética:** tudo aqui é inteiro com `MulDivRound`; nesta engine `/` é divisão
inteira truncada. Ver `CLAUDE.md`.
