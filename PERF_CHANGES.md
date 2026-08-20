# Rato's AI Overhaul — Mudanças propostas (para revisão)

Companion do `PERF_PLAN.md`. Aqui está o código concreto de cada mudança.

## Status de aplicação

**Aplicado:** C1–C9, C11, C12, e **F2.3 no `CustomSeekCover`** (com medição — ver a
seção da F2.3). Todas as mudanças estão no código, marcadas com comentários
`---- PERF (Cx)` / `---- PERF (F2.x)` para você achar e reverter individualmente.

**Não aplicado:**

- **C10** (`OptLocSearchRadius` 100 → 80) — você pediu para deixar de fora.
  É o único item que reduziria a cardinalidade do laço OptLoc, então se os ganhos
  medidos não bastarem, é o próximo candidato óbvio.
- **F3.3 parcial** — a cópia órfã `SOURCE_AIPrecalcDamageScore.lua` da raiz foi
  deletada (está versionada, dá para recuperar com `git checkout`). Mas **não**
  removi os arquivos comentados do `metadata.lua`: o `items.lua` mirrora essas
  entradas como `ModItemCodeFile` e o CLAUDE.md diz para nunca editá-lo. Editar só
  o metadata dessincronizaria os dois e provavelmente seria revertido no próximo
  save do editor de mods. Isso tem que sair pelo editor.
- **Fase 2 e F3.1/F3.2** — são esboços, não patches. Exigem validação de
  comportamento e ficam para depois de medir o efeito do que já entrou.
  Exceção: a **F2.3 já saiu do esboço** no `CustomSeekCover`, porque virou medição em vez
  de estimativa. Faltam nela o `CustomFlanking` e o
  `getAIShootingStanceBehaviorSelectionScore`.

**Validação feita:** balanceamento de blocos (`function`/`if`/`for` vs `end`) conferido
em todos os 53 arquivos de `Code/`, e varredura por referências órfãs a símbolos
removidos ou renomeados. Não há interpretador Lua no ambiente, então **nada foi
executado** — a validação é estática. Erros de runtime (nome errado, nil index)
só vão aparecer no jogo.

---

> Os patches abaixo são a proposta original, mantida como registro do raciocínio.
> Onde a implementação divergiu do texto, há uma nota.

Legenda de risco:
- 🟢 **exato** — resultado numérico idêntico, garantido por construção
- 🟡 **equivalente** — mesmo resultado salvo caso de borda documentado
- 🟠 **aproximado** — muda o score; precisa validar comportamento em jogo

---

## Sumário

| # | Mudança | Arquivo | Risco | Ganho |
|---|---|---|---|---|
| C1 | Memoizar CTH por nível de mira | `FUNCTION_ScoreAttacksDetailed.lua` | 🟢 | 2–5× no laço dominante |
| C2 | Remover `CalcValue` de cover duplicado | `FUNCTION_ScoreAttacksDetailed.lua` | 🟡 | −1 preset caro por (dest,alvo) |
| C3 | `get_recoil` para dentro do gate de alcance | `SOURCE_AIPrecalcDamageScore.lua` | 🟢 | −30 a 70% das chamadas |
| C4 | Cache de recoil por distância | `SOURCE_AIPrecalcDamageScore.lua` | 🟡 | ~10× nas restantes |
| C5 | Inverter ordem barato/caro no `CanSurround` | `AIPOLICYPOS_TryNotToBeFlanked.lua` | 🟢 | −70 a 90% dos raycasts |
| C6 | Memoizar `IsSurrounded` por voxel | `AIPOLICYPOS_TryNotToBeFlanked.lua` | 🟢 | −60% do que sobrar |
| C7 | Hoistar resolução de granada | `AIPOLICYPOS_GrenadeRange.lua` | 🟢 | O(A×E) → O(1) |
| C8 | Fechar o precipício do `precalced` | `SOURCE_AIPrecalcDamageScore.lua` | 🟢 | elimina caso patológico |
| C9 | Debug atrás de flag | 3 arquivos | 🟢 | ~3.200 tabelas/turno |
| C10 | `OptLocSearchRadius` 100 → 80 | `items.lua` | 🟠 | −36% de destinos no laço OptLoc |
| C11 | Alocações no caminho quente | 3 arquivos | 🟢 | pressão de GC |
| C12 | `CustomScoring` depois do gate | `SOURCE_AISelectAction.lua` | 🟡 | pequeno, mas grátis |

Fases 2 e 3 (mudanças maiores) estão esboçadas no fim.

---

## C1 — Memoizar `CalcChanceToHit` por nível de mira 🟢

**Arquivo:** `Code/FUNCTION_ScoreAttacksDetailed.lua:36-49`

### Problema

```lua
for i = 1, attacks do
    args.aim = aims[i]
    local attack_mod, attack_base = unit:CalcChanceToHit(target, action, args, "chance_only")
```

Dentro desta função, `target`, `action` e `args.step_pos` são fixos. **A única coisa
que muda entre iterações é `args.aim`.** Mas `CalcChanceToHit` reavalia os ~33 presets
de `ChanceToHitModifier` toda vez.

Verifiquei quais presets realmente dependem de `aim` no corpo (não só na assinatura):

| Preset | Origem | Depende de `aim`? |
|---|---|---|
| `Aim` | vanilla | sim (`local num = aim`) |
| `RangeAttackTargetStanceCover` | vanilla | só se a arma tem `IgnoreCoverCtHWhenFullyAimed` |
| `HipshotPenalty` | GBO3 | sim, fortemente |
| `ScopePenal` | GBO3 | sim (`if aim < 1`) |
| os outros ~29 | — | **não** |

Ou seja: ~29 de 33 presets são recalculados com o mesmo input e o mesmo output.

Além disso, `aims` frequentemente contém **o mesmo valor repetido** — o ramo
`not has_stance_ap or to_reach_desired_aim_level <= 0` de `AICalcAttacksAndAim`
(`SOURCE_AICalcAttacksandAim.lua:123-130`) preenche todos os slots com `min_aim`.

### Solução

Memoizar por valor distinto de `aim`. Como todo o resto do input é fixo, o resultado
é **idêntico por construção** — não é aproximação.

```lua
-- ANTES (linhas 36-49)
    for i = 1, attacks do
        args.aim = aims[i]
        local attack_mod, attack_base = unit:CalcChanceToHit(target, action, args, "chance_only")
        table.insert(context.cth_attacks_at[upos][target], attack_mod)
        mod = mod + attack_mod

        if i > 1 and aims[i] < 3 then
            local recoil_penalty = (aims[i] == 2 and recoil_cth * 0.33 or aims[i] == 1 and
                                       recoil_cth * 0.66 or recoil_cth) * (i - 1)
            mod = mod + recoil_penalty * const.Combat.Recoil.StacksMultiplier
        end
    end
```

```lua
-- DEPOIS
    local cth_by_aim = {}
    for i = 1, attacks do
        local aim_i = aims[i]
        local attack_mod = cth_by_aim[aim_i]
        if not attack_mod then
            args.aim = aim_i
            attack_mod = unit:CalcChanceToHit(target, action, args, "chance_only")
            cth_by_aim[aim_i] = attack_mod
        end

        if debug_ai then
            table.insert(context.cth_attacks_at[upos][target], attack_mod)
        end
        mod = mod + attack_mod

        if i > 1 and aim_i < 3 then
            local recoil_penalty = (aim_i == 2 and recoil_cth * 0.33 or aim_i == 1 and
                                       recoil_cth * 0.66 or recoil_cth) * (i - 1)
            mod = mod + recoil_penalty * const.Combat.Recoil.StacksMultiplier
        end
    end
```

> `attack_base` era capturado e nunca usado — removido.
> `debug_ai` vem de C9.

### Ganho

`attacks` CTHs → `#distinct(aims)` CTHs. Caso comum (todos iguais): **1 em vez de 3–5**.
Caso com escalada de mira: tipicamente 2–3 em vez de 5.

### Se quiser ir além (🟠, opcional)

Dá para reduzir a 1 CTH sempre, computando os ataques seguintes como
`base_cth + delta`, onde `delta` é a soma só dos 4 presets dependentes de mira.
Ganho extra menor que o de C1 e **exige manter a lista de presets sincronizada** —
se o GBO3 ganhar um novo modificador dependente de `aim`, o score silenciosamente
diverge. Só recomendo se C1 sozinho não bastar, e nesse caso com um assert de
validação em modo debug comparando os dois caminhos.

---

## C2 — Remover o `CalcValue` de cover duplicado 🟡

**Arquivo:** `Code/FUNCTION_ScoreAttacksDetailed.lua:51-57`

### Problema

```lua
---------------- For Custom Flanking Policy
local use_cover, cover_value, _, _, type_cover =
    hit_modifiers.RangeAttackTargetStanceCover:CalcValue(unit, target, nil, action, weapon, nil,
                                                         nil, nil, nil, attacker_pos)
```

O `ForEachPreset("ChanceToHitModifier", ...)` dentro do `CalcChanceToHit`
(`Unit.lua:7063`) **já avaliou exatamente este preset**, com os mesmos argumentos.
É trabalho duplicado, e este é um dos presets caros (faz raycast de cover).

### Solução

Duas opções, em ordem de preferência:

**(a) Capturar durante o CTH.** Requer um hook no `CalcChanceToHit` — mais invasivo,
mas elimina a duplicata de verdade.

**(b) Usar o grid pré-calculado.** `context.dest_target_cover_score` só é consumido
por `AIPolicyCustomFlanking:CompareCovers` (`AIPOLICYPOS_CustomFlanking.lua:61-67`),
que faz `cover_cth / cover_penalty` — uma **razão relativa**. O valor de grid do
`GetCoverFrom` serve para o mesmo propósito:

```lua
-- DEPOIS
local cover = GetCoverFrom(GetPackedPosAndStance(target), upos)
if cover == const.CoverLow or cover == const.CoverHigh then
    target_covers[target] = (cover == const.CoverHigh) and modCover or MulDivRound(modCover, 50, 100)
end
```

**Risco:** 🟡 o flanking passa a usar cover discreto (baixo/alto) em vez de contínuo.
Muda o *ranking fino* entre destinos parecidos, não a decisão macro. Vale medir
antes/depois se o flanking ainda escolhe posições sensatas.

Se preferir zero risco de comportamento, pule C2 — C1 já é o ganho grande.

> **Divergência na implementação:** ao aplicar, apareceu um problema que este texto
> não previa. `CompareCovers` compara `dest_target_cover_score` (o lado que C2
> mudou) com `currentpos_target_cover_score`, que é preenchido em
> `AICreateContext.lua:177` — e continuava usando o `CalcValue` contínuo.
> Mudar só um lado faria a comparação misturar escala contínua com discreta e
> enviesar toda decisão de flanquear. Então `AICreateContext` também passou a usar
> `GetCoverFrom`, na mesma base. Isso não é ganho de performance (roda uma vez por
> inimigo por turno) — é o que torna C2 correto.
>
> Se você reverter C2, **reverta os dois lados juntos.**

---

## C3 — `get_recoil` para dentro do gate de alcance 🟢

**Arquivo:** `Code/SOURCE_AIPrecalcDamageScore.lua:201-216`

### Problema

```lua
------ Recoil CTH Calculation
local recoil_cth = 0

if IsKindOf(weapon, "Firearm") then
    recoil_cth = get_recoil(unit, target, target:GetPos(), context.default_attack,
                            weapon, nil, weapon:GetAutofireShots(context.default_attack),
                            nil, nil, nil, nil, nil, attacker_pos)
end

recoil_score[target] = recoil_cth
-------------

if dist <= (max_check_range or dist) and
    (is_melee or targets_attack_data[k] and not targets_attack_data[k].stuck) then
```

O `get_recoil` roda **antes** do gate. Para alvos fora de alcance ou sem linha de
fogo, o valor é calculado e descartado.

### Solução

```lua
-- DEPOIS
if dist <= (max_check_range or dist) and
    (is_melee or targets_attack_data[k] and not targets_attack_data[k].stuck) then

    ------ Recoil CTH Calculation
    local recoil_cth = 0
    if IsKindOf(weapon, "Firearm") then
        recoil_cth = get_recoil(unit, target, target:GetPos(), context.default_attack,
                                weapon, nil, weapon:GetAutofireShots(context.default_attack),
                                nil, nil, nil, nil, nil, attacker_pos)
    end
    recoil_score[target] = recoil_cth
```

**Atenção:** `recoil_score[target]` é lido depois em
`context.dest_target_recoil_cth[upos] = recoil_score[best_target]` (linha 384).
Como `best_target` só pode ser um alvo que **passou** pelo gate, mover para dentro
é seguro. Vale confirmar isso ao aplicar.

### Ganho

Elimina 30–70% das chamadas, dependendo de quantos alvos estão em alcance.

---

## C4 — Cache de recoil por distância 🟡

**Arquivo:** `Code/SOURCE_AIPrecalcDamageScore.lua` (+ opcionalmente `GBO3/Code/FUNCTIONS_recoil.lua`)

### Problema

Em `get_recoil` (`FUNCTIONS_recoil.lua:476-644`), **a única entrada que varia entre
destinos é `dist`**. Tudo o mais — `GetWepRecoil`, `GetRecoilOther`,
`GetCaliberStrRecoil`, `GBO_GetROF`, o bloco de MG, `metaText` — depende só de
`(atacante, alvo, arma, ação, num_shots)`.

E como é chamado com `stacks = nil`, o ramo que consome `metaText` (linha 636)
nunca é atingido: a construção de `metaText` e o `processMetatext` da linha 632-634
são desperdício puro no caminho da IA.

### Solução (a) — cache por bucket de distância, sem tocar no GBO3 🟡

Distâncias são quantizadas em slabs de qualquer forma. Bucketizar por slab reduz
D chamadas para ~`WeaponRange` chamadas distintas (~30):

```lua
-- antes do laço `for j, upos in ipairs(destinations)`:
local recoil_cache = {}   -- [target] -> { [slab_dist] = recoil }

-- dentro do laço de alvos, no lugar da chamada direta:
local recoil_cth = 0
if IsKindOf(weapon, "Firearm") then
    local by_dist = recoil_cache[target]
    if not by_dist then
        by_dist = {}
        recoil_cache[target] = by_dist
    end
    local slab = dist / const.SlabSizeX
    recoil_cth = by_dist[slab]
    if not recoil_cth then
        recoil_cth = get_recoil(unit, target, target:GetPos(), context.default_attack,
                                weapon, nil, weapon:GetAutofireShots(context.default_attack),
                                nil, nil, nil, nil, nil, attacker_pos)
        by_dist[slab] = recoil_cth
    end
end
```

**Risco:** 🟡 o recoil passa a ser constante dentro de um slab de distância. Como o
`dist` já entra numa interpolação linear grosseira (`MulDivRound(dist, max_penalty, max_dist)`),
o erro é sub-ponto de CTH. Contido ao arquivo do AI Overhaul.

### Solução (b) — fatiar a função, ganho maior 🟡

Em `FUNCTIONS_recoil.lua`, separar:

- `get_recoil_profile(attacker, target, action, weapon, num_shots)` → tudo até a
  linha 585, devolvendo `{mod, mg_mod, max_penalty, flat, is_mg}`
- `get_recoil_from_profile(profile, dist, attacker, stacks)` → só a aritmética
  das linhas 586-643

O AI chama `get_recoil_profile` uma vez por alvo, antes do laço de destinos, e
`get_recoil_from_profile` por destino. `get_recoil` vira um wrapper fino que
compõe os dois — o resto do GBO3 continua funcionando sem mudança.

Aproveitar para adicionar `no_meta` e pular `metaText`/`processMetatext`.

**Risco:** 🟡 mexe num arquivo do GBO3 usado pelo jogo inteiro, não só pela IA.
Ganho maior e mais limpo, mas exige testar o CTH do jogador também.

### Bônus: código morto

`FUNCTIONS_recoil.lua:582-585`

```lua
local penalty = 0
local pb_dist = const.Weapons.PointBlankRange * const.SlabSizeX
penalty = MulDivRound(penalty, mod, 100)   -- no-op: penalty é 0
```

`pb_dist` nunca é usado; o `MulDivRound` opera sobre zero.

---

## C5 — Inverter a ordem barato/caro no `CanSurround` 🟢

**Arquivo:** `Code/AIPOLICYPOS_TryNotToBeFlanked.lua:62-112`

### Problema

Esta é política **OptLoc** (11 usos em `items.lua`), então roda sobre **todos** os
destinos do raio — ~800 a 3000. Para cada destino, itera `g_Teams` → `team.units`.

O `CheckLOS` (raycast) roda nas linhas 80-96, e o teste de alcance de arma — barato,
só distância — roda nas linhas 99-109, **depois**. Então pagamos o raycast mesmo
para unidades a 100 slabs de distância, cujo resultado será descartado na linha seguinte.

### Solução

```lua
function Unit:RATOAI_CanSurround(other, check_pos, custom_other_pos)
    -- side
    if not self:IsOnEnemySide(other) or self:IsDead() or self:IsDowned() then
        return false
    end

    if self:HasStatusEffect("Suppressed") then
        return false
    end

    local pos = check_pos or self:GetPos()
    if other:GetPos() == pos then
        return false
    end

    ---------------------------------------------------------------
    -- MOVIDO PARA CIMA: teste de alcance (barato) antes do LOS (raycast)
    local adjacent = self:IsAdjacentTo(other, check_pos)
    local in_range = false
    local w1, w2, weapons = self:GetActiveWeapons()
    for _, weapon in ipairs(weapons) do
        if IsKindOf(weapon, "Firearm") or (IsKindOf(weapon, "MeleeWeapon") and weapon.CanThrow) then
            in_range = in_range or other:GetDist(pos) <= weapon.WeaponRange * const.SlabSizeX
        elseif IsKindOf(weapon, "MeleeWeapon") then
            in_range = in_range or adjacent
        end
    end
    if not in_range then
        return false
    end
    ---------------------------------------------------------------

    -- visibility (raycast) — só para quem passou no teste de alcance
    if check_pos then
        if not CheckLOS(other, self, self:GetSightRadius()) then
            return false
        end
    elseif custom_other_pos then
        if not CheckLOS(custom_other_pos, self, self:GetSightRadius()) then
            return false
        end
    else
        if not HasVisibilityTo(self, other) then
            return false
        end
    end

    return true
end
```

**Risco:** 🟢 os dois testes são `AND` puro; reordenar não muda o resultado.

### Ganho

Elimina o raycast para toda unidade fora de alcance de arma. Em mapas abertos com
inimigos espalhados, tipicamente 70–90% delas.

---

## C6 — Memoizar `IsSurrounded` por voxel 🟢

**Arquivo:** `Code/AIPOLICYPOS_TryNotToBeFlanked.lua:11-22`

### Problema

O resultado de `RATOAI_IsSurrounded` depende só da posição XY. Mas `EvalDest` recebe
`dest`, que é `stance_pos_pack(x, y, z, stance)` — os 3 stances do mesmo voxel são
3 destinos distintos e pagam o cálculo completo 3×.

`pos_table` também é alocado por destino.

### Solução

```lua
function AIPolicyTryNotToBeFlanked:EvalDest(context, dest, grid_voxel)
    local unit = context.unit

    local cache = context.__surrounded_cache
    if not cache then
        cache = {}
        context.__surrounded_cache = cache
    end

    local cached = cache[grid_voxel]
    if cached ~= nil then
        return cached
    end

    local x, y, z = stance_pos_unpack(dest)
    local pos_table = {[unit] = point(x, y, z)}
    local new_surrounded = unit:RATOAI_IsSurrounded(pos_table)

    local score = not new_surrounded and 100 or 0
    cache[grid_voxel] = score
    return score
end
```

**Nota:** `grid_voxel` já chega pronto como parâmetro (`AIScoreDest.lua:26` o passa),
então não há custo extra para montar a chave. O cache vive no `context`, que é
recriado por turno — sem risco de dado velho.

**Risco:** 🟢 `RATOAI_IsSurrounded` não lê stance em lugar nenhum (só `pos`), então
o resultado é genuinamente o mesmo para os 3 stances.

---

## C7 — Hoistar a resolução de granada 🟢

**Arquivo:** `Code/AIPOLICYPOS_GrenadeRange.lua:62-158`

### Problema

```lua
for _, enemy in ipairs(context.enemies) do
    if self:RangeCheckGrenade(context, grid_voxel, enemy, ...) then
```

e dentro de `RangeCheckGrenade`:

```lua
local base_range, cost_check = self:GetGrenadeMaxRangeAndAPcost(context)
```

`GetGrenadeMaxRangeAndAPcost` é **invariante no turno inteiro**, mas roda
`destinos × inimigos` vezes. Cada chamada:

- define 2 closures (`set_to_table`, `any_value_in_table`, linhas 122-142)
- aloca 4 tabelas (linhas 147-150)
- itera `archetype.SignatureActions`
- chama `RATOAI_GetGrenadeActionMaxRangeAndApCost`, que percorre 4 `CombatActions`
  fazendo `GetAttackWeapons` e `GetMaxAimRange`

### Solução

Mover as duas closures para escopo de arquivo e cachear o resultado no `context`:

```lua
-- escopo de arquivo, fora de qualquer função
local function set_to_table(sett)
    local ttable = {}
    for k, b in pairs(sett) do
        if b then
            table.insert_unique(ttable, k)
        end
    end
    if not next(ttable) then
        return false
    end
    return ttable
end

local function any_value_in_table(table1, table2)
    for i, v in ipairs(table1) do
        if table.find(table2, v) then
            return true
        end
    end
    return false
end
```

```lua
function AIPolicyGrenadeRange:GetGrenadeMaxRangeAndAPcost(context)
    local cache = context.__grenade_range_cache
    if cache == nil then
        cache = {}
        context.__grenade_range_cache = cache
    end
    -- chaveado por self: archetypes podem ter várias instâncias da política
    -- com AllowedAoeTypes / AllowedTriggerTypes diferentes
    local hit = cache[self]
    if hit ~= nil then
        return hit.range, hit.cost
    end

    local range, cost = self:CalcGrenadeMaxRangeAndAPcost(context)
    cache[self] = {range = range, cost = cost}
    return range, cost
end
```

…com o corpo atual (linhas 144-158) renomeado para `CalcGrenadeMaxRangeAndAPcost`.

Além disso, no `EvalDest`, tirar a chamada de dentro do laço de inimigos — resolver
uma vez e passar `base_range` adiante, em vez de resolver por inimigo.

**Risco:** 🟢 função pura durante o turno. A única sutileza é a chave `self`:
o cache **precisa** ser por instância da política, não global, porque archetypes
diferentes configuram `AllowedAoeTypes`/`AllowedTriggerTypes` diferentes.

**Atenção — bug pré-existente:** `RATOAI_GetGrenadeActionMaxRangeAndApCost`
(linha 161) atribui `cost = actcost` na linha 176 mas o `return` da linha 182 é
`return max_range` — só um valor. Então `cost_check` em `RangeCheckGrenade:93`
é **sempre `nil`**, e o bloco `if self.SaveAP and cost_check ...` (linhas 99-104)
nunca executa. Não é problema de performance, mas o `SaveAP` desta política está
morto. Vale decidir se conserta junto.

---

## C8 — Fechar o precipício do `damage_score_precalced` 🟢

**Arquivo:** `Code/SOURCE_AIPrecalcDamageScore.lua:16-30`

### Problema

`Update_AIPrecalcDamageScore` (`UTIL.lua:1-9`) é chamado **por destino** em
`AIPolicyCustomFlanking:EvalDest:95` e `AIPolicyMGSetupPosScore:EvalDest:31`.
Seu guard é `context.damage_score_precalced`.

Mas essa flag só é setada na linha 30 — depois de três `return` que a deixam sem setar:

```lua
if not weapon or context.reposition or unit:HasStatusEffect("Burning") then
    return                                     -- <- flag não setada
end
if not destinations and context.damage_score_precalced then
    return
end

local action_targets = action:GetTargets({unit})     -- <- caro: enumera unidades
local targets = table.ifilter(action_targets, function(idx, target)
    return unit:IsOnEnemySide(target)
end)                                                  -- <- aloca tabela + closure
if #targets == 0 then
    return                                     -- <- flag não setada
end
context.damage_score_precalced = true
```

Unidade queimando, sem arma, em reposição ou sem alvos válidos → **cada destino
reexecuta `action:GetTargets` + `table.ifilter`**.

### Solução

Flag separada para "já tentei", independente de "consegui":

```lua
function AIPrecalcDamageScore(context, destinations, preferred_target, debug_data)
    local unit = context.unit
    ...
    if not destinations and context.damage_score_attempted then
        return
    end
    if not destinations then
        context.damage_score_attempted = true
    end

    if not weapon or context.reposition or unit:HasStatusEffect("Burning") then
        return
    end
    if not destinations and context.damage_score_precalced then
        return
    end
    ...
```

Por que uma flag nova em vez de setar `damage_score_precalced` cedo: essa flag
também sinaliza "o contexto tem dados de dano válidos" para
`AIPolicyCustomFlanking` e para o `GetDestArgs` do `SignaturesCustomScoring`.
Setá-la num caminho de falha faria essas políticas lerem tabelas vazias como se
fossem resultado legítimo.

O guard novo só se aplica quando `destinations == nil` (a forma que
`Update_AIPrecalcDamageScore` usa). Chamadas com destinos explícitos —
`CombatAI.lua:216, 276, 334`, `AIBehaviors.lua:413` — continuam passando direto.

**Risco:** 🟢 nenhuma mudança no caminho feliz.

---

## C9 — Debug atrás de flag 🟢

**Arquivos:** `FUNCTION_ScoreAttacksDetailed.lua:30-39`, `SOURCE_AICreateContext.lua:106-112`, `AIPOLICYPOS_CustomSeekCover.lua:79-80`

### Problema

`ScoreAttacksDetailed` monta, por `(dest, alvo)`:

```lua
context.aims_at[upos] = context.aims_at[upos] or {}
context.aims_at[upos][target] = aims
context.cth_attacks_at[upos] = context.cth_attacks_at[upos] or {}
context.cth_attacks_at[upos][target] = context.cth_attacks_at[upos][target] or {}
```

mais um `table.insert` por ataque. Com D=400 e T=8: **~3.200 tabelas + ~9.600 inserts
por turno de unidade**, retidos até o turno acabar.

Esses dados são lidos **apenas** por `IModeAIDebug:GetVoxelRolloverText`
(`DEBUG.lua:83-91`) — ou seja, só com o debug de IA aberto.

O `CustomSeekCover` tem o mesmo padrão nas linhas 79-80: `debugforpos` e
`debugforpos_simple` são alocados sempre, embora `debugforpos` só seja preenchido
sob `if debug` (linha 105) e `debugforpos_simple` esteja inteiramente comentado.

### Solução

Adotar a mesma flag que `CustomSeekCover.lua:54` já usa, num único lugar
compartilhado (sugestão: `UTIL.lua`):

```lua
-- UTIL.lua
RATOAI_Debug = Platform.developer and Platform.cheats and true or false
```

E guardar todos os sítios:

```lua
-- FUNCTION_ScoreAttacksDetailed.lua
if RATOAI_Debug then
    context.aims_at[upos] = context.aims_at[upos] or {}
    context.aims_at[upos][target] = aims
    context.cth_attacks_at[upos] = context.cth_attacks_at[upos] or {}
    context.cth_attacks_at[upos][target] = context.cth_attacks_at[upos][target] or {}
end
```

```lua
-- AIPOLICYPOS_CustomSeekCover.lua — remover as duas linhas 79-80 daqui
local debugforpos
if debug then
    debugforpos = {}
end
```

```lua
-- SOURCE_AICreateContext.lua:106-112
if RATOAI_Debug then
    context.cth_attacks_at = {}
    context.aims_at = {}
    context.dest_flanking_pol_debug = {}
    context.dest_custom_seek_cover_debug = {}
    context.dest_custom_seek_cover_simple_debug = {}
end
```

**Atenção:** `DEBUG.lua:62-91` indexa essas tabelas sem checar existência
(`self.ai_context.dest_flanking_pol_debug[dest]`). Se elas passarem a ser `nil`,
o rollover quebra. Ou mantenha-as como tabelas vazias e guarde só o **preenchimento**
(mais simples e quase todo o ganho), ou adicione `and self.ai_context.X` no `DEBUG.lua`.
Recomendo a primeira: 5 tabelas vazias por turno é irrelevante, as 3.200 é que doem.

---

## C10 — `OptLocSearchRadius` 100 → 80 🟠

**Arquivo:** `items.lua`, linhas 638, 960, 1277, 1412, 2002

### Contexto

Vanilla (`ModTools/Src/Data/AIArchetype.lua`): 21 archetypes com 80, 1 com 100, 1 com 10.
Este mod: 10 com 80, **5 com 100**.

`AIEnumValidDests` (`CombatAI.lua:1208-1237`) faz `ForEachPassSlab` numa bbox de
lado `2r` e filtra por `IsCloser(..., r)`. Área ∝ r²:

```
(80/100)² = 0,64   →   −36% de destinos
```

E esse número multiplica **todo** o laço OptLoc: C5, C6, C7 e a política
`CustomSeekCover` da Fase 2.

### Risco

🟠 Este é o único item da lista que **muda comportamento de propósito**: reduz o raio
de busca por posição ótima, então esses archetypes deixam de considerar
reposicionamentos muito longos. Se o raio 100 foi escolhido deliberadamente para
algum archetype (um Marksman que precisa recuar bastante, por exemplo), reverter
custa alcance tático.

Sugestão: aplicar primeiro nos archetypes onde 100 parece herdado por acidente, e
manter em quem realmente depende. Vale checar quais dos 5 são.

---

## C11 — Alocações no caminho quente 🟢

### C11.1 — `FUNCTION_ShouldMaxAim.lua:31`

```lua
-- ANTES: alocado a cada GetIdealAimLevels, ou seja, por (dest, alvo)
local burst = {"BurstFire", "MGBurstFire", "BuckshotBurst"}
local effective_range_mul = table.find(burst, atk) and 55 or 45
```

```lua
-- DEPOIS: escopo de arquivo
local burst_attacks = {"BurstFire", "MGBurstFire", "BuckshotBurst"}
-- ...
local effective_range_mul = table.find(burst_attacks, atk) and 55 or 45
```

### C11.2 — `SOURCE_AICalcAttacksandAim.lua:98`

```lua
local desired_aim_level = GetIdealAimLevels(context, target_dist, max_aim, min_aim)
local aims = {}                    -- <- morto: redeclarado nas linhas 125 e 148
```

Remover a linha 98.

### C11.3 — `FUNCTION_CustomArchetypeFunc.lua:9-46`

A tabela `map` (5 sub-tabelas, ~20 arrays de string) é reconstruída a cada
`GetArgsForArchetypeAndWeaponSelection`. Mover para escopo de arquivo como
`local ROLE_ARGS = { ... }` e indexar direto.

Menos quente que as outras, mas é uma linha de mudança.

---

## C12 — `CustomScoring` depois do gate de `disable` 🟡

**Arquivo:** `Code/SOURCE_AISelectAction.lua:9-22`

### Problema

```lua
for _, action in ipairs(actions) do
    context.action_states[action] = {}
    local weight_mod, disable, priority = AIGetBias(action.BiasId, context.unit)

    local c_action_weight, custom_disable, action_priority = action:CustomScoring(context)   -- <- sempre

    disable = disable or context.disable_actions[action.BiasId or false] or custom_disable

    if not disable then
```

`CustomScoring` roda para toda ação, inclusive as que serão descartadas na linha
seguinte por bias. Cada uma passa por `GetDestArgs` → `Update_AIPrecalcDamageScore`
(`FUNCTION_SignaturesCustomScoring.lua:6`), e algumas fazem `CalcValue` de presets
(linhas 71, 110, 152, 164, 176, 241).

### Solução

```lua
for _, action in ipairs(actions) do
    context.action_states[action] = {}
    local weight_mod, disable, priority = AIGetBias(action.BiasId, context.unit)

    disable = disable or context.disable_actions[action.BiasId or false]

    if not disable then
        local c_action_weight, custom_disable, action_priority = action:CustomScoring(context)
        disable = custom_disable

        if not disable then
            action:PrecalcAction(context, context.action_states[action])
            ...
        end
    end
end
```

**Risco:** 🟡 se algum `CustomScoring` tiver efeito colateral no `context` que outra
ação depende, a ordem muda. Olhando `FUNCTION_SignaturesCustomScoring.lua`, elas
parecem puras (só leem), mas confirme antes de aplicar — em especial o
`Update_AIPrecalcDamageScore` dentro de `GetDestArgs`, que é justamente um efeito
colateral (popula o contexto). Depois de C8 isso fica idempotente e o risco cai.

---

# Fase 2 — precisa de validação em jogo

Esboços, não patches. Detalhes no `PERF_PLAN.md` (P2.1–P2.6).

### F2.1 — Gate de grid antes do `GetCoverPercentage` 🟠

`AIPOLICYPOS_CustomSeekCover.lua:199-243`. É política OptLoc com 20 usos, e
`SimpleGetCover` nunca é ligado nos archetypes — então **sempre** cai no caminho caro
`GetCoverScore` → `RATOAI_CoverCTH` → `GetCoverPercentage` → `PosGetCoverPercentageFrom`
(amostragem geométrica na engine), `destinos × inimigos` vezes.

Ideia: consultar antes o `GetCoverFrom(dest, context.enemy_pack_pos_stance[enemy])`
(consulta de grid barata, é o que o `AIPolicySeekCover` vanilla usa). Se der
`CoverNone`, pular o raycast e ir direto ao ramo `ExposedAtCloseRange_Score` — o
score sairia perto de zero de qualquer jeito.

Precisa validar que a distribuição de posições escolhidas não muda de forma
perceptível — este é o coração do posicionamento da IA do mod.

### F2.2 — Pré-computar invariantes de inimigo no `AICreateContext` 🟢

Uma tabela por turno com, por inimigo: arma ativa, `is_firearm`, `WeaponRange`,
`GetSightRadius`, `IsDowned`. Hoje `CustomSeekCover:213` e `CanSurround:82,101`
recalculam isso por `(destino, inimigo)`.

Combina bem com C5: depois de F2.2, o teste de alcance que C5 promoveu vira
uma leitura de tabela.

### F2.3 — Hoistar `ResolveValue` de preset 🟢 — **aplicado no CustomSeekCover**

São constantes de preset resolvidas em laço quente:
`CustomSeekCover.lua:200-201, 247-248` (4 por dest×inimigo),
`CustomFlanking.lua:42, 58`, `getAIShootingStanceBehaviorSelectionScore.lua:88, 129`.

Resolver uma vez, em `OnMsg.ModsReloaded` ou no início do combate.

**Medido antes de aplicar** (10k chamadas no processo vivo, `tools/dap_probe.py` — ver
`DEBUG SERVER.md`):

| chamada | µs/chamada |
|---|---|
| `PosGetCoverPercentageFrom` (a query nativa) | 0,8 |
| `GetCover` (lookup de voxel) | 0,8 |
| `GetCoverFrom` | 1,8 |
| `ResolveValue` (1×) | 0,9 |
| `RATOAI_CoverCTH` (o wrapper) | 6,3 |

A leitura que isso força: **o wrapper custa ~7× o trabalho que ele embrulha**. Eram três
`ResolveValue` por par (destino, inimigo) — dois em `RATOAI_CoverCTH` (`Cover`,
`ExposedCover`) e um em `GetCoverScore` (`cover_max_malus`) — ou seja ~2,7 µs de ~7,2 µs
por par, **~37% do custo só relendo constante**.

`Cover` passou a vir de `RATOAI_GetMaxCoverCTH()` (que já existia em
`FUNCTION_ScoreAttacksDetailed.lua`, o "parcial" desta mesma F2.3) em vez de um cache
novo — é o mesmo número do mesmo preset, e dois caches da mesma constante é como elas
divergem. Só `ExposedCover` ganhou cache próprio (`RATOAI_GetExposedCoverCTH`).

Verificado ao vivo que a substituição é valor-idêntica: `Cover = -35`,
`ExposedCover = -5`, `RATOAI_GetMaxCoverCTH() == ResolveValue("Cover")` → `true`.

**Ainda não aplicado:** `CustomFlanking.lua:42, 58` e
`getAIShootingStanceBehaviorSelectionScore.lua:88, 129`.

#### Achado colateral: `SimpleGetCover` era uma armadilha, não um atalho

A mesma medição mostrou que `GetCoverFrom` (1,8 µs) — o caminho do `SimpleGetCover` —
custa **o dobro** de `PosGetCoverPercentageFrom` (0,8 µs), que é o caminho "caro". Ou
seja o modo "simples" era mais lento *e* menos preciso. Estava dormente (0 de 21
instâncias), com o corpo do `SimpleGetCoverScore` inteiramente comentado — a função era a
identidade. Removidos: a property, o ramo no `EvalDest`, e a função. O fallback de
`last_known_enemy_pos` passou a indexar `self.CoverScores` direto.

### F2.4 — Cache dos invariantes de `AICalcAttacksAndAim` 🟢

`GetBaseAimLevelRange`, `Get_AimCost`, `GetWeapon_StanceAP`, `rat_canBolt`,
`rat_get_manual_cyclingAP` são invariantes no turno mas rodam por `(dest, alvo)`.
Só `unit:GetShootingStanceAP(target, ...)` e a aritmética de AP são realmente por alvo.

### F2.5 — Hoistar `AIGetAttackArgs` do laço de alvos 🟡

`ScoreAttacksDetailed.lua:25`. A tabela `args` só depende de `(context, action, step_pos)`.
Construir uma vez por destino e mutar `.target`/`.aim`. Cuidado: `AIGetAttackArgs`
lê `context.dest_target[upos]`, então confirmar que nada depende do `target` de
dentro dela nesse caminho.

---

# Fase 3 — reestruturação

### F3.1 — Scoring em duas fases 🟠 (maior ganho de todos)

Todos os itens acima reduzem **custo por iteração**. Este reduz **cardinalidade**,
e por isso sozinho vale mais que a Fase 1 inteira.

- **Passe 1:** score barato à moda vanilla (`GetCoverFrom` + `GetAccuracy` + `Darkness`,
  exatamente `CombatAI.lua:1556-1581`) sobre todos os `D × T`.
- **Passe 2:** `RATOAI_ScoreAttacksDetailed` completo **apenas** nos top-K destinos
  pelo score barato (K ≈ 20–40), mais o destino atual da unidade.

O resultado consumido é `best_target` + `best_score` por destino. Destinos
claramente ruins nunca vencem, então a perda de fidelidade tende a zero — mas
"tende a zero" aqui é uma hipótese a testar, não um fato. O jeito de validar:
rodar os dois caminhos em paralelo em modo debug e comparar o `best_dest`
escolhido ao longo de vários combates.

### F3.2 — Reduzir candidatos do `TryNotToBeFlanked` 🟡

`RATOAI_IsSurrounded` itera `g_Teams` → `team.units` inteiro. Usar `context.enemies`
(já filtrado por visibilidade e ordenado por handle) cobre o mesmo caso de uso.
Diferença: `context.enemies` pode incluir inimigos não-visíveis em fallback
(`AICreateContext.lua:61-65`) e exclui não-inimigos — verificar se o cerco deveria
considerar unidades neutras.

### F3.3 — Limpeza 🟢

- Deletar `SOURCE_AIPrecalcDamageScore.lua` da **raiz** (22 KB, órfão, não está em
  `metadata.lua` — a versão viva é `Code/SOURCE_AIPrecalcDamageScore.lua`).
- Remover de `metadata.lua` os arquivos 100% comentados: `AIPOLICYPOS_AvoidThreatenedAreas.lua`,
  `AIPOLICYPOS_AvoidDeathSpots.lua`, `AIPOLICYPOS_DontBeExposedAtCloserRange.lua`,
  `FUNCTION_get_ShouldUseGetCloserPositioningBehavior.lua`, `SOURCE_AIPrecalcGrenadeZones.lua`.
  Custam só tempo de parse, mas confundem a leitura.

---

# Ordem sugerida de aplicação

Agrupada para você poder medir o efeito de cada bloco isoladamente:

1. **Instrumentação primeiro** (seção 4 do `PERF_PLAN.md`) — sem linha de base, não dá
   para saber o que funcionou.
2. **Bloco A — grátis e exato:** C3, C5, C6, C8, C9, C11. Nenhum muda comportamento.
3. **Medir.** Se já resolveu, pare aqui.
4. **Bloco B — exato, um pouco mais de trabalho:** C1, C7.
5. **Medir.**
6. **Bloco C — decisões suas:** C10 (alcance tático), C2 e C4 (fidelidade de score),
   C12 (ordem de efeitos colaterais).
7. **Fase 2**, se ainda precisar.
8. **F3.1** só se o resto não bastar — é o maior ganho mas o único que exige
   validação séria de comportamento.
