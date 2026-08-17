# Rato's AI Overhaul — Plano de Eficiência

Análise dos gargalos introduzidos pelas modificações do mod sobre o AI vanilla
(`ModTools/Src/Lua/Tactical/CombatAI.lua`, `AIBehaviors.lua`, `Unit.lua`).

---

## 1. Onde o tempo é gasto

Dois laços dominam o turno de cada unidade de IA:

| Laço | Origem | Cardinalidade típica |
|---|---|---|
| `AIFindOptimalLocation` → `AIScoreDest` → `policy:EvalDest` | vanilla | **A** = `all_destinations` ≈ 800–3000 slabs (raio `OptLocSearchRadius`) |
| `AIPrecalcDamageScore` → laço `dest × target` | override do mod | **D** = `context.destinations` ≈ 150–800 · **T** = alvos ≈ 4–12 |

O mod não mudou a cardinalidade desses laços — mudou drasticamente **o custo por
iteração**. É aí que está todo o problema.

---

## 2. Gargalos, por ordem de impacto

### G1 — `CalcChanceToHit` completo dentro do laço `dest × target` 🔴 crítico

`Code/FUNCTION_ScoreAttacksDetailed.lua:38`

```lua
for i = 1, attacks do
    args.aim = aims[i]
    local attack_mod, attack_base = unit:CalcChanceToHit(target, action, args, "chance_only")
```

O vanilla (`CombatAI.lua:1556-1594`) nunca chama `CalcChanceToHit` aqui. Ele usa
aritmética barata (`GetCoverFrom` no grid + `GetAccuracy` + `Darkness:CalcValue`)
e só depois soma o bônus de mira.

`Unit:CalcChanceToHit` (`Unit.lua:7063`) faz `ForEachPreset("ChanceToHitModifier", ...)`
— **~33 presets** (27 vanilla + 6 do GBO3), cada um com `CalcValue` própria, várias
com raycast (cover, LOS, darkness, scope, point blank). Além disso aloca a tabela
`mod_data` e uma closure por chamada.

Custo por turno de unidade: `D × T × attacks` CTHs completos.
Com D=400, T=8, attacks=3 → **9.600 CTH ≈ 317.000 `CalcValue`**. O vanilla faz **zero**.

Agrava:
- `AIGetAttackArgs` é chamado por `(dest, target)` (`ScoreAttacksDetailed.lua:25`) — refaz
  `GetPackedPosAndStance`, `GetBaseAimLevelRange` e `action:GetAPCost` toda vez.
- `RangeAttackTargetStanceCover:CalcValue` na linha 52-54 é **trabalho duplicado**:
  o `ForEachPreset` dentro do `CalcChanceToHit` já avaliou exatamente esse preset.

### G2 — `get_recoil` fora do gate de alcance 🔴 crítico

`Code/SOURCE_AIPrecalcDamageScore.lua:204-212`

```lua
if IsKindOf(weapon, "Firearm") then
    recoil_cth = get_recoil(unit, target, target:GetPos(), ...)
end
-- ...só DEPOIS:
if dist <= (max_check_range or dist) and (is_melee or targets_attack_data[k] ...) then
```

Roda para **todo** `(dest, target)`, inclusive alvos fora de alcance ou sem LOF —
casos em que o resultado é descartado.

Pior: `get_recoil` (`GBO3/Code/FUNCTIONS_recoil.lua:476`) é caro e alocador —
monta `metaText`, chama `GetWepRecoil`, `GetRecoilOther`, `GetCaliberStrRecoil`,
`GBO_GetROF` e faz `rT()`/`processMetatext`. E como é chamado com `stacks = nil`,
o ramo que usaria o `metaText` nem é atingido: é lixo puro.

E é quase todo **invariante por destino**: só o termo `dist` muda entre destinos
(linhas 590-599). O resto (`mod`) depende apenas de `(atacante, arma, ação, num_shots)`.

### G3 — `AIPolicyTryNotToBeFlanked`: raycast por destino × unidade 🔴 crítico

`Code/AIPOLICYPOS_TryNotToBeFlanked.lua:11-60` — política **OptLoc** (usada 11× em `items.lua`),
então roda sobre os **A** destinos, não os D.

`RATOAI_IsSurrounded` itera `g_Teams` → `team.units` e, para cada uma, chama
`RATOAI_CanSurround`, que cai no ramo `custom_other_pos` e executa
`CheckLOS(custom_other_pos, self, self:GetSightRadius())` — **um raycast por
(destino, unidade)**. Com A=1500 e 14 unidades: **~21.000 raycasts**.

O `IsSurrounded` vanilla usa `HasVisibilityTo` (pré-computado). Aqui a posição
hipotética força o raycast.

Agrava:
- O teste de alcance de arma (`other:GetDist(pos) <= WeaponRange`, linha 105) roda
  **depois** do raycast — a ordem barata/cara está invertida.
- `self:GetActiveWeapons()` e `self:GetSightRadius()` por (destino, unidade).
- `ConvexHull2D` + laço O(n²) de `Dot2D` por destino.
- Alocação de `pos_table` e `enemy_pos` por destino.
- O resultado depende só do voxel XY, mas os 3 stances do mesmo voxel pagam 3×.

### G4 — `AIPolicyCustomSeekCover`: `GetCoverPercentage` por destino × inimigo 🟠 alto

`Code/AIPOLICYPOS_CustomSeekCover.lua:199-243` — também **OptLoc** (20× em `items.lua`).

`SimpleGetCover` nunca é ligado nos archetypes, então sempre cai no caminho caro
`GetCoverScore` → `RATOAI_CoverCTH` → `GetCoverPercentage` → `PosGetCoverPercentageFrom`
(engine, amostragem geométrica). A=1500 × 8 inimigos → **~12.000 chamadas**.

O vanilla `AIPolicySeekCover` usa `GetCoverFrom(dest, enemy_pack_pos_stance[enemy])`,
uma consulta de grid pré-calculada.

Agrava, tudo por `(destino, inimigo)`:
- 4 `ResolveValue` (2 em `GetCoverScore:200-201`, 2 em `RATOAI_CoverCTH:247-248`).
- `enemy:GetActiveWeapons()` + `IsKindOf` (linha 213).
- `RATOAI_ValidatePosZ` × 2 + `att_pos:Dist(target_pos)` — aloca points.
- `debugforpos` e `debugforpos_simple` são alocados **sempre**, mesmo com `debug == false`
  (linhas 79-80).

### G5 — `AIPolicyGrenadeRange`: resolução da granada por destino × inimigo 🟠 alto

`Code/AIPOLICYPOS_GrenadeRange.lua:77-88` chama `RangeCheckGrenade` por inimigo, que
chama `GetGrenadeMaxRangeAndAPcost` (linha 93) — função **totalmente invariante no turno**.

Cada chamada: define 2 closures (`set_to_table`, `any_value_in_table`), aloca 4 tabelas,
itera `archetype.SignatureActions`, e então `RATOAI_GetGrenadeActionMaxRangeAndApCost`
percorre 4 `CombatActions` chamando `GetAttackWeapons` e `GetMaxAimRange`.

### G6 — Precipício silencioso no `Update_AIPrecalcDamageScore` 🟠 alto

`Code/UTIL.lua:1-9`, chamado **por destino** em `AIPolicyCustomFlanking:EvalDest:95`
e `AIPolicyMGSetupPosScore:EvalDest:31`.

O guard é `context.damage_score_precalced`. Mas em `SOURCE_AIPrecalcDamageScore.lua`
a flag só é setada na **linha 30** — depois de quatro `return` prematuros:

```lua
if not weapon or context.reposition or unit:HasStatusEffect("Burning") then return end  -- :16
if not destinations and context.damage_score_precalced then return end                   -- :19
local action_targets = action:GetTargets({unit})                                          -- :23
local targets = table.ifilter(action_targets, ...)
if #targets == 0 then return end                                                          -- :27
context.damage_score_precalced = true                                                     -- :30
```

Se a unidade está queimando, sem arma, em reposição, ou sem alvos válidos, a flag
**nunca** é setada — e cada `EvalDest` re-executa `action:GetTargets({unit})`
(enumera todas as unidades) + `table.ifilter` (aloca tabela). Por destino.

### G7 — Tabelas de debug alocadas em produção 🟡 médio

`ScoreAttacksDetailed.lua:31-39` cria `context.aims_at[upos]`, `context.cth_attacks_at[upos]`
e `context.cth_attacks_at[upos][target]` + um `table.insert` por ataque. São
`D × T` tabelas + `D × T × attacks` inserts, retidos o turno inteiro, e lidos
**apenas** por `IModeAIDebug:GetVoxelRolloverText` (`DEBUG.lua:83`).

Mesma coisa com `dest_flanking_pol_debug`, `dest_custom_seek_cover_debug` e
`dest_custom_seek_cover_simple_debug`, sempre alocados em `AICreateContext:110-112`.

### G8 — `AISelectAction` avalia `CustomScoring` antes do gate 🟡 médio

`Code/SOURCE_AISelectAction.lua:16` roda `action:CustomScoring(context)` para **toda**
ação, inclusive as prestes a serem desabilitadas por bias na linha 19. Cada
`CustomScoring` passa por `GetDestArgs` → `Update_AIPrecalcDamageScore`.

### G9 — Alocações no caminho quente 🟡 médio

- `FUNCTION_ShouldMaxAim.lua:31` — `local burst = {"BurstFire", "MGBurstFire", "BuckshotBurst"}`
  alocado a cada `GetIdealAimLevels`, ou seja, por `(dest, target)`.
- `SOURCE_AICalcAttacksandAim.lua:98` — `local aims = {}` é código morto
  (redeclarado nas linhas 125 e 148).
- `FUNCTION_CustomArchetypeFunc.lua:9` — a tabela `map` inteira (5 sub-tabelas)
  é reconstruída a cada `GetArgsForArchetypeAndWeaponSelection`.
- `AICalcAttacksAndAim` recalcula por `(dest, target)` coisas invariantes no turno:
  `GetBaseAimLevelRange`, `Get_AimCost`, `GetWeapon_StanceAP`, `rat_canBolt`,
  `rat_get_manual_cyclingAP`.

### G10 — `OptLocSearchRadius` aumentado 🟡 médio (correção trivial)

O mod subiu 4 archetypes de 80 → 100 (`items.lua:638, 960, 1277, 1412, 2002`).
Vanilla usa 80 em 21 de 23 archetypes.

Área ∝ r²: **(100/80)² = 1,56×** mais destinos no laço OptLoc — multiplicando
G3, G4 e G5 diretamente.

### G11 — Arquivos mortos 🟢 baixo

- `SOURCE_AIPrecalcDamageScore.lua` na **raiz** (22 KB) não está em `metadata.lua`
  — cópia órfã, apenas confunde.
- Totalmente comentados mas carregados: `AIPOLICYPOS_AvoidThreatenedAreas.lua`,
  `AIPOLICYPOS_AvoidDeathSpots.lua`, `AIPOLICYPOS_DontBeExposedAtCloserRange.lua`,
  `FUNCTION_get_ShouldUseGetCloserPositioningBehavior.lua`, `SOURCE_AIPrecalcGrenadeZones.lua`.

---

## 3. Plano de correção, por ordem de retorno

### Fase 1 — Ganhos grandes, risco baixo (sem mudança de comportamento)

**P1.1 · Um `CalcChanceToHit` por `(dest, target)`, não por ataque** — ataca G1
Entre ataques só muda `args.aim`. Apenas os modificadores `Aim` e `ScopePenal`
dependem de `aim`. Calcule o CTH completo uma vez com `aims[1]` e derive os
demais somando o delta de `aim_mod:CalcValue` / `scope_cth_mod:CalcValue`
(que é exatamente o que `RATOAI_ScoreAttacks_Simple:147-158` já faz).
→ corte de **3–5×** no gargalo dominante.

**P1.2 · Remover o `RangeAttackTargetStanceCover:CalcValue` duplicado** — G1
`ScoreAttacksDetailed.lua:52-54`. Ou capture o valor durante o `ForEachPreset`
do CTH, ou aceite o `GetCoverFrom` de grid (que a política de flanking consome
como número relativo de qualquer forma).

**P1.3 · Mover `get_recoil` para dentro do gate de alcance** — G2
`SOURCE_AIPrecalcDamageScore.lua`: mover o bloco 204-212 para dentro do
`if dist <= max_check_range ...` da linha 215. Uma linha, elimina todo o recoil
de alvos descartados.

**P1.4 · Fatiar `get_recoil` em parte invariante + termo de distância** — G2
Extrair `get_recoil_mod(attacker, target, action, weapon, num_shots)` (tudo até a
linha 585 de `FUNCTIONS_recoil.lua`) e cachear por alvo **antes** do laço de destinos.
Por destino sobra só a aritmética de `dist` (linhas 586-599).
Adicionar um parâmetro `no_meta` que pula a construção de `metaText` e
`processMetatext` — a IA nunca usa o texto.

**P1.5 · Inverter a ordem barato/caro no `RATOAI_CanSurround`** — G3
`AIPOLICYPOS_TryNotToBeFlanked.lua`: rodar o teste de distância/alcance de arma
(linhas 99-109) **antes** do `CheckLOS` (linhas 80-96). Mata a maioria dos raycasts
sem alterar o resultado.

**P1.6 · Memoizar `RATOAI_IsSurrounded` por `grid_voxel`** — G3
O resultado não depende do stance. Cachear em `context` elimina ~2/3 das chamadas
(3 stances por voxel).

**P1.7 · Hoistar `GetGrenadeMaxRangeAndAPcost`** — G5
Cachear o `(max_range, cost)` no `context` (invariante no turno) e, no mínimo,
chamar uma vez por `EvalDest` em vez de uma vez por inimigo.
Mover `set_to_table` / `any_value_in_table` para o escopo do arquivo.

**P1.8 · Setar `damage_score_precalced` em todos os `return` prematuros** — G6
Ou usar uma flag separada `context.damage_score_attempted`. Elimina o precipício
de re-executar `action:GetTargets` por destino.

**P1.9 · `OptLocSearchRadius` 100 → 80** — G10
Nos 4 archetypes de `items.lua`. **−36% de destinos** no laço OptLoc inteiro,
multiplicando todo o ganho de P1.5–P1.7 e P2.1.

**P1.10 · Guardar tabelas de debug atrás da flag** — G7
`ScoreAttacksDetailed.lua:31-39` e `AICreateContext.lua:110-112`. Usar
`Platform.developer and Platform.cheats` como já é feito em `CustomSeekCover.lua:54`.

### Fase 2 — Ganhos grandes, exige validação de comportamento

**P2.1 · Gate de grid antes do `GetCoverPercentage`** — G4
Em `AIPolicyCustomSeekCover:GetCoverScore`, consultar primeiro o
`GetCoverFrom(dest, context.enemy_pack_pos_stance[enemy])`. Se der `CoverNone`,
pular o raycast e ir direto para o ramo `ExposedAtCloseRange_Score` — o score
sairia ~0 de qualquer forma. Validar que a distribuição de posições escolhidas
não muda de forma perceptível.

**P2.2 · Pré-computar invariantes de inimigo no `AICreateContext`** — G3, G4
Uma tabela por turno com, por inimigo: arma ativa, `is_firearm`, `WeaponRange`,
`GetSightRadius`, `IsDowned`, `distance_to_check_lack_of_cover`. Hoje isso é
recalculado por `(destino, inimigo)` em `CustomSeekCover:213` e
`CanSurround:82,101`.

**P2.3 · Hoistar os `ResolveValue` de preset para locais de arquivo** — G4
`CustomSeekCover.lua:200-201, 247-248`, `CustomFlanking.lua:42, 58`,
`getAIShootingStanceBehaviorSelectionScore.lua:88, 129`.
São constantes de preset; resolver uma vez no `OnMsg.ModsReloaded` / início de combate.

**P2.4 · Cachear os invariantes de `AICalcAttacksAndAim`** — G9
`GetBaseAimLevelRange`, `Get_AimCost`, `GetWeapon_StanceAP`, `rat_canBolt`,
`rat_get_manual_cyclingAP` num `context.__aim_cache` montado uma vez por turno.
Só `unit:GetShootingStanceAP(target, ...)` e a aritmética de AP ficam por alvo.

**P2.5 · `CustomScoring` depois do gate de `disable`** — G8
`SOURCE_AISelectAction.lua`: calcular `weight_mod, disable, priority` primeiro,
e só chamar `action:CustomScoring(context)` se `not disable`.

**P2.6 · Hoistar `AIGetAttackArgs` do laço de alvos** — G1
A tabela `args` só depende de `(context, action, step_pos)`. Construir uma vez por
destino e mutar `.target` / `.aim` no laço de alvos.

### Fase 3 — Reestruturação (maior ganho, maior risco)

**P3.1 · Scoring em duas fases no `AIPrecalcDamageScore`** — G1
Passe 1: score barato à moda vanilla (`GetCoverFrom` + `GetAccuracy` + `Darkness`)
sobre todos os `D × T`. Passe 2: `RATOAI_ScoreAttacksDetailed` completo **apenas**
nos top-K destinos (K ≈ 20–40, pelo score barato) e no destino atual.

Como o resultado final é `best_target` + `best_score` por destino, e destinos
claramente ruins nunca vencem, a perda de fidelidade é mínima. Este é o único
caminho que reduz a **cardinalidade** em vez do custo unitário — sozinho vale
mais do que toda a Fase 1 junta.

**P3.2 · Reduzir o conjunto de candidatos do `TryNotToBeFlanked`** — G3
Iterar `context.enemies` (já filtrado por visibilidade e ordenado) em vez de
`g_Teams` → `team.units` completo.

**P3.3 · Limpeza** — G11
Deletar a cópia órfã da raiz; remover de `metadata.lua` os arquivos 100% comentados.

---

## 4. Como medir

Antes de mexer, instrumentar para ter linha de base por turno de unidade:

```lua
-- envolver, com GetPreciseTicks():
--   AIFindOptimalLocation   -> custo do laço OptLoc  (G3, G4, G5)
--   AIPrecalcDamageScore    -> custo do laço dest×target (G1, G2)
--   AIPlayAttacks / AISelectAction
```

Contadores úteis (resetar por turno): número de `CalcChanceToHit`, de `CheckLOS`,
de `GetCoverPercentage`, de `get_recoil`, e `#context.destinations` /
`#context.all_destinations`. A razão entre esses contadores e a contagem de
destinos diz imediatamente se um hoist funcionou.

Cenário de teste: um mapa com 10+ inimigos e unidades com AP alto (muitos destinos
alcançáveis) — é onde os multiplicadores explodem.
