# O scoring de posição é cego às signature actions

Registro de investigação. Fontes verificadas no source do jogo
(`ModTools/Src/Lua/Tactical/`) em agosto de 2026.

---

## O problema em uma frase

A IA escolhe **onde ficar** avaliando apenas o **ataque padrão**. Só depois de o destino
estar fixado é que ela pergunta "daqui dá pra fazer alguma coisa especial?".

Consequência: ir para um quadrado que *permitiria* uma granada ou um tiro automático não
vale ponto nenhum na decisão de posição. A ação especial acontece se sobrar oportunidade,
não porque a posição foi escolhida para ela.

---

## A ordem real das decisões

`StandardAI:Think` (`AIBehaviors.lua:240-260`):

```
1. AIFindDestinations
2. AIFindOptimalLocation          -- OptLocPolicies
3. AICalcPathDistances
4. AIPrecalcDamageScore(context)  -- ataque BÁSICO           (linha 252)
5. AIScoreReachableVoxels         -- EndTurnPolicies         (linha 255)
                                  -- define context.ai_destination
6. AIChooseMovementAction
```

As signature actions só entram na **execução**, em `AIPlayAttacks`
(`CombatAI.lua:190`):

```
7. AIPrecalcDamageScore(context, {dest}, target_locked or dest_target[dest])   (216)
8. AIChooseSignatureAction(context)                                            (232)
     -> AISelectAction  (CombatAI.lua:631 -> 589)
          -> action:PrecalcAction(...)
          -> action:IsAvailable(...)
```

Quando o passo 8 roda, `context.ai_destination` já está decidido desde o passo 5.

---

## As duas linhas que provam

**O scoring de posição usa o ataque padrão** — `Code/SOURCE_AIPrecalcDamageScore.lua:12`:

```lua
local action = CombatActions[context.override_attack_id or false] or context.default_attack
```

**As signature actions leem o destino como entrada** — `AIActions.lua:95`, dentro de
`AIActionBasicAttack:PrecalcAction`:

```lua
local dest = context.ai_destination or GetPackedPosAndStance(unit)
```

---

## É pior do que "oportunista"

As ações não são apenas avaliadas depois — várias são **restringidas** ao destino já
escolhido:

| local | o que faz |
|---|---|
| `AIActions.lua:447` e `:517` | `local pref = context.ai_destination and self.DestPreference or "score"` — ações de área preferem posições de ataque próximas ao destino já fixado |
| `AIActions.lua:602` | `if not context.ai_destination then return end` — o MobileShot aborta sem destino |

Ou seja, o destino não é só ignorado na hora de escolher a ação: ele **limita** o que a
ação pode fazer.

---

## A brecha que já existe (e que já usamos uma vez)

O vanilla tem um gancho para isso. Em `AIBehaviors.lua:246-254`, antes do
`AIPrecalcDamageScore`:

```lua
if self.override_attack_id ~= "" then
    context.override_attack_id = self.override_attack_id
end
if self.override_cost_id and CombatActions[self.override_cost_id] then
    context.override_attack_cost = CombatActions[self.override_cost_id]:GetAPCost(unit)
end
AIPrecalcDamageScore(context)
context.override_attack_id = nil
```

Com isso o **scoring de posição passa a usar outra ação**, não a padrão.

Já usamos: `items.lua:871` → `'override_attack_id', "MGSetup"`. É o único uso no mod.

**Limitação:** é por *behavior*, não por *ação*. Serve para "este behavior é sobre montar
a MG". Não serve para "considere granada, automático e básico e escolha a melhor posição
para o conjunto".

---

## Por que a solução óbvia não funciona

Rodar `PrecalcAction` por destino é inviável. Essas funções são caras:

- granada → `AIPrecalcGrenadeZones`
- cone / MG → `AIPrecalcConeTargetZones`

Hoje rodam **uma vez por ação por think**. Por destino seriam centenas de destinos
alcançáveis × ~5 ações = milhares de precalcs pesados por turno. É uma ordem de grandeza
acima do problema de `GetCoverPercentage` que o `PERF_PLAN.md` já classifica como 🟠 (G4),
e com custo por chamada muito maior.

---

## Dois caminhos tratáveis

### A. Proxy barato por ação

Uma policy de posicionamento que aproxima "daqui dá pra usar X" sem rodar o
`PrecalcAction`.

**Já fazemos isso para granada**: `AIPolicyGrenadeRange` (3 usos no `items.lua`).
Generalizável para autofire e cone.

- Barato, encaixa no sistema de policies, peso por archetype.
- É aproximação: pode dizer "dá pra jogar granada" onde o `PrecalcAction` diria que não.

### B. Duas passadas sobre os finalistas

1. Pontuar posições com o ataque básico (como hoje).
2. Pegar os finalistas que já saem do corte de `AIDecisionThreshold` — as listas
   `potential_dests` (End Turn) e `best_dests` (OptLoc) **já existem**.
3. Rodar `PrecalcAction` das signature actions **só nesses ~10-20 tiles**.
4. Reordenar.

- Usa o cálculo real, não proxy.
- Custo controlado: dezenas de precalcs em vez de milhares.
- Não inverte a ordem das fases, então não quebra `DestPreference` nem o MobileShot.
- Exige mexer no `AIScoreReachableVoxels` (que já sobrescrevemos) e possivelmente
  em `AIPlayAttacks`.

**B é a que de fato responde "ir para aquele quadrado me *permite* jogar granada".**
A é a que dá 80% do resultado por 10% do trabalho.

---

## Achado lateral: a roleta de signature action do vanilla nunca rolou

`AISelectAction` (`CombatAI.lua:589`) tem dois bugs no vanilla:

```lua
available[#available + 1] = action
available[available] = action_weight        -- (1) chave errada: a própria tabela
...
local roll = InteractionRand(weight, "AISignatureAction", context.unit)
for _, action in ipairs(available) do
    local w = available[action]             -- sempre nil, por causa de (1)
    if roll <= weight then                  -- (2) compara com o TOTAL, não com w
        return action
    end
    roll = roll - weight                    -- (2) subtrai o TOTAL, não w
end
```

Como `InteractionRand(weight)` devolve `[0, weight-1]`, a condição `roll <= weight` é
sempre verdadeira na primeira iteração. **O vanilla sempre escolhe a primeira ação
disponível na ordem da lista**, e os `Weight` das signature actions nunca são consultados.

**Já corrigido** no nosso `Code/SOURCE_AISelectAction.lua`: `available[action] = action_weight`,
`roll <= w`, `roll = roll - w`. Mesma classe do BUGFIX B9 (a roleta de destino de fim de
turno), em outro lugar.

---

## Em aberto

1. Caminho A, B, ou A agora e B depois?
2. Se B: reordenar apenas o End Turn, ou também o OptLoc? (No OptLoc não há alvo, então o
   `PrecalcAction` de várias ações não tem o que avaliar.)
3. O `override_attack_id` cobre casos suficientes se criarmos behaviors dedicados por tipo
   de ação, em vez de mexer no scoring? É o caminho mais vanilla, mas multiplica behaviors.
