# Por que a IA não se agacha — relatório

*2026-08-19. Investigação sobre `Rato's AI Overhaul` + GBO3, source em `ModTools/Src`.*

---

## Leia isto primeiro

**O `Code/AIPOLICYPOS_AvoidThreatenedAreas.lua` está inteiro dentro de um bloco `--[[ ... ]]`.**
Linha 18 abre, linha 217 fecha, o arquivo tem 217 linhas. Ele **não define nada e nunca definiu**.

Dentro dele estavam as suas cópias de `AIFindDestinations` e `AIFindOptimalLocation`. Ou seja:
**quem roda hoje é o `AIFindDestinations` do vanilla, sem nenhuma alteração sua.**

Duas consequências:

1. A mudança que eu apliquei nesse arquivo hoje (marcada `BUGFIX (B11)`) é **decorativa**. Nunca
   executou. O gate de AP do vanilla continua ativo.
2. O `WEIGHTS_AUDIT.md`, seção B8, **já registrava isso**: *"`AIPolicyAvoidDeathSpots`,
   `AIPolicyAvoidThreatenedAreas`, `AIPolicyDontBeExposedAtCloserRange` — arquivos inteiros
   comentados"*. Eu li essa seção quando fui escrever o B11 ali e não conectei. Erro meu.

**Pergunta em aberto para você:** o `AIFindOptimalLocation` comentado lá tinha alguma mudança sua
que você achava que estava ativa? Se tinha, mais coisa do mod está desligada do que só esse arquivo.

---

## Suas duas reclamações

### "Eu queria que eles agachassem *antes de atirar*"

**Boa notícia: no jogo normal isso já funciona.** A ordem em `CombatCamera.lua` é:

| linha | o que acontece |
|---|---|
| 1199 | `behavior:BeginMovement(unit)` — fase de movimento |
| 1220 | `WaitAllCombatActionsEnd()` |
| **1238** | **`behavior:EndMovement(unit)` — aplica a stance do dest** |
| 1245+ | `while #playing > 0` → `AIExecuteUnitBehavior` → `AIPlayAttacks` |

`EndMovement` é quem chama `unit:DoChangeStance(stance)`, e ele roda na **fase de movimento**,
antes do laço de ataques. Quando o dest é `Crouch`, o boneco se agacha antes do primeiro tiro.

**O que eu disse sobre o debug não se aplica ao jogo normal.** `IModeAIDebug:UnitExecuteTurn`
(`IModeAIDebug.lua:296-318`) faz:

```lua
context.behavior:TakeStance(unit)
if dest then context.behavior:BeginMovement(unit) ... end
context.behavior:Play(unit)
AIPlayAttacks(unit, context, action) or AITakeCover(unit)
```

**Sem `EndMovement`.** Então induzir a ação pela interface de debug nunca agacha, por construção.
Pior: nessa sequência o único que mexe em stance é `TakeStance`, que força
`context.archetype.PrefStance` — e `PrefStance` tem default **`"Standing"`**, sendo `Crouch` em
apenas 9 archetypes. Pela interface de debug, vários archetypes são ativamente **levantados**.

> **Regra prática:** qualquer teste de postura tem que ser feito num turno normal. A interface de
> debug mascara o mecanismo inteiro.

### "Eu queria que eles pagassem, não gosto de gerar cheat pra IA"

Concordo, e você está mais perto disso do que parece. O estado real:

- **Planejamento:** o vanilla cobra. `dest_ap[new_dest] = ap - cost` (1000 AP) e o gate
  `ap >= cost`. O destino agachado entra na disputa com 1 AP a menos para atacar, e destinos onde
  não sobra AP simplesmente não viram agachados.
- **Execução:** `EndMovement` chama `unit:DoChangeStance` (`Unit.lua:6435`), que **não debita AP**.
  E o `move_args.toDoStance` de `BeginMovement` (`AIBehaviors.lua:177`) não é consumido por nenhuma
  ação `Move` — só `UnitActions.lua:707`, que é o attack-move do jogador.

Ou seja: a reserva existe só no orçamento. O `unit.ActionPoints` real nunca é decrementado.

**Eu errei aqui hoje.** Minha mudança B11b removia a cobrança do planejamento por causa dessa
folga — o que transformaria em cheat de verdade (AP cheio *e* crouch grátis), exatamente o que você
não quer. Como o arquivo estava comentado, nada disso rodou. No arquivo novo eu **mantive a
cobrança do vanilla**.

Para fechar a folga de verdade, o caminho é sobrescrever `AIBehavior:EndMovement` e debitar lá —
não remover a cobrança do planejamento. Não fiz isso hoje; é mudança de comportamento que merece
decisão acordado.

---

## O que foi aplicado hoje

| marcador | arquivo | roda? | o que faz |
|---|---|---|---|
| **B12** | `SOURCE_AITakeCover.lua` | ✅ sim | A função era um **no-op inteiro** por precedência: `(context.ap_after_signature or 0 <= 0)` parseia como `X or (0<=0)` = sempre verdadeiro. Corrigido para `((… or 0) <= 0)`. Restaura o `StanceCrouch` grátis de fim de ativação do vanilla. |
| **B13** | `SOURCE_AIScoreReachableVoxels.lua` | ✅ sim | Gradiente do `OptLocWeight`. Detalhes abaixo. |
| **B11** | `AIPOLICYPOS_AvoidThreatenedAreas.lua` | ❌ **não** | Dentro do bloco comentado. Código morto. |
| — | `SOURCE_AIFindDestinations.lua` | ⚠️ **falta registrar** | Novo. Repõe a função com o gatilho de crouch configurável. |

### B13, em detalhe (o que você confirmou que funcionou)

Sintoma: unidade abandonava boa posição, frequentemente voltando para tile pior.

`AIFindOptimalLocation`, ao achar um candidato no próprio voxel de partida, preenche
`context.best_dest` no laço de cima e **pula** o bloco que atribui `context.best_dest_path`
(`CombatAI.lua:1318-1348` — confirmei que o **vanilla** tem essa mesma estrutura). Com
`best_dest_path` nil, `AICalcPathDistances` deixa `total_dist = nil` e `dest_dist = {}`. As duas
fórmulas de OptLoc estão atrás do portão `total_dist > 0`, então `dist_score = 0` para **todos** os
destinos — o `OptLocWeight` inteiro (200 em três archetypes) sumia da conta.

Ficava mascarado pela roleta quebrada do **B9**: ela disparava sempre na primeira iteração de uma
lista semeada com `{curr_dest}`, o que dava "fique onde está" por acidente. Consertar a roleta
removeu essa âncora justamente onde o OptLocWeight fica mudo.

Conserto: repor o **insumo**, não trocar a fórmula. Com `dest_dist` vazio, preenche com a distância
direta de cada dest até o `best_dest` e usa a maior delas como denominador. O gradiente volta ao
normal (cheio em cima do ótimo, 0 no limite do alcance), normalizado pelo raio de movimento em vez
do comprimento do caminho, que aqui é zero. Precedente no source: `AITactics.lua:8-13`.

---

## Por que é intermitente ("às vezes agacham")

Três mecanismos independentes, todos ainda ativos:

**1. Gate de AP no destino** (vanilla, ativo). `ap >= 1000` onde `ap` é o que **sobra depois de
chegar lá**. A unidade costuma parar no limite do alcance de movimento — exatamente onde não sobra.
Sobrou → dest `Crouch`. Não sobrou → `Standing`. Intermitente por construção.
*Com a sua exigência de "que eles paguem", este gate é legítimo e deve ficar.*

**2. Lote de movimento abortado** (`CombatCamera.lua:1200-1210`) — **não verificado em execução**:

```lua
result = unit.ai_context.behavior:BeginMovement(unit, trackMove)
if result ~= "continue" then
    local limit = (result == "restart") and i or (i + 1)
    for j = #playing, limit, -1 do
        to_play[#to_play + 1] = playing[j]
        playing[j] = nil
    end
    break
end
```

Se **qualquer** unidade do lote falha ou é interrompida, todas as que vêm **depois dela** saem de
`playing` — e o laço de `EndMovement` (1236-1241) só percorre quem ficou. Essas unidades perdem o
crouch nessa passada sem ter nada de errado. Depende da composição do lote → aleatório.

`BeginMovement` retorna `false` quando `path` é nil (`if not path then return false end`), que era
a sua suspeita: cai exatamente aqui. Mas você observou o problema também **sem** path nil, e
overwatch/interrupção produzem o mesmo `result ~= "continue"`.

**3. `AITakeCover` bloqueado por `shooting_stance`.** Mesmo com o B12, o `return` da linha 4 do
`SOURCE_AITakeCover.lua` barra quem está em shooting stance — e o GBO3 aplica `shooting_stance` em
`OnMsg.OnAttack` sempre que `aim > 0` (`REACTIONS_ShootingStance.lua:101-104`). Ou seja, todo mundo
que mira perde a rede de segurança pelo resto do turno.

---

## Quanto vale agachar (para calibrar depois)

`Data/ChanceToHitModifier.lua`, preset `RangeAttackTargetStanceCover`:
`Cover` = **−20**, `ExposedCover` = −5, `CrouchPenalty` = **−5**, `PronePenalty` = −10.

A lógica (linhas 595-606): **se há cobertura, retorna o valor da cobertura e nunca chega no teste de
crouch** — o −5 só vale a céu aberto. E `GetCoverPercentage` (`Cover.lua:283-285`) **zera cobertura
baixa** para quem está em pé:

| situação | CTH do inimigo contra você |
|---|---|
| em pé, cobertura baixa | **0** — a cobertura é descartada |
| agachado, cobertura baixa | até **−20** |
| em pé, sem cobertura | 0 |
| agachado, sem cobertura | **−5** |

Sua intuição de que "quase nunca é vantagem não abaixar" está numericamente certa.

**O que agachar *não* dá: precisão.** `AttackerStance` não existe como preset — as linhas
`modCrouchBonus = hit_modifiers.AttackerStance:ResolveValue("CrouchBonus")` estão comentadas **no
source do jogo** (`CombatAI.lua:1456-1457`), não é coisa sua. O `modCrouchBonus = 0` do seu
`SOURCE_AIPrecalcDamageScore.lua:76-77` é fiel. O GBO3 dá só marginal: recoil ×0.98
(`__RecoilParams.lua:36`) e hipfire ×1.02 (`__SnapshotHipfireParams.lua:35`).

Conclusão: o ganho de agachar é **defensivo**, vale até 20 pontos de CTH, e trocar um nível de mira
por ele é bom negócio na maior parte dos casos.

---

## O arquivo novo

`Code/SOURCE_AIFindDestinations.lua` — cópia do vanilla (`CombatAI.lua:645-717`) com **uma** variável
isolada:

```lua
RATOAI_CrouchTrigger = "any_cover"   -- "low" | "any_cover" | "always"
```

- `"low"` — vanilla exato: só cobertura baixa
- `"any_cover"` — **atual**: cobertura baixa ou alta
- `"always"` — todo destino vira agachado

A cobrança de AP do vanilla foi **mantida** (`ap >= cost` e `dest_ap[new_dest] = ap - cost`).

> ### ⚠️ Ele não faz nada até ser registrado
> A lista `code` do `metadata.lua`, espelhada no `items.lua`, define o que carrega. Sem registrar
> pelo editor de mods, ele é código morto **exatamente como o arquivo que ele substitui**. Não
> editei nenhum dos dois, conforme o `CLAUDE.md`.

Também **não** repus o `AIFindOptimalLocation` que estava comentado — parecia idêntico ao vanilla,
mas não diffei linha a linha.

**Nada disso foi testado em runtime.** Não há interpretador Lua nesta máquina fora do jogo; revisei
a estrutura à mão.

---

## Ordem sugerida para amanhã

1. **Registrar o `SOURCE_AIFindDestinations.lua`** pelo editor. Sem isso, nada muda.
2. **Testar em turno normal, nunca pela interface de debug** (o debug pula o `EndMovement`).
3. Com `"any_cover"`, ver se os casos de "atrás de caixa alta e em pé" somem.
4. Se ainda ficar intermitente, o suspeito é o **lote abortado** (item 2 acima). Dá para confirmar
   olhando o log do `AIExecutionController`: ele escreve `"  Execution interrupted: %s"` na linha
   1202 sempre que isso acontece.
5. Só então decidir sobre o pagamento real (override de `EndMovement`) e sobre reservar 1 AP para o
   crouch no `AICalcAttacksAndAim` — que hoje **não tem linha nenhuma de crouch** no orçamento e
   torra até o último AP em níveis de mira.

## Dívidas que eu deixei

- O comentário `BUGFIX (B11)` e a seção B11 do `WEIGHTS_AUDIT.md` descrevem mal o defeito: falam de
  um "gate de direção" no `if up then`, que foi leitura minha errada (`GetCover` devolve as 4
  direções ou nenhuma — é teste de "existe dado de cobertura"), e citam `AIPolicyAttack_StanceAP`,
  que tem **0 instâncias** no `items.lua`. Precisa reescrever ou reverter.
- Decidir o que fazer com o `AIPOLICYPOS_AvoidThreatenedAreas.lua`: deletar, ou descomentar e
  diffar contra o vanilla.
- O `RATOAI_TryChangeStance` do `OnMsg.TurnEnded` continua lá e continua quebrado (o
  `SetActionCommand("ShootingStanceCommand", …)` da linha 97 interrompe o `ChangeStance` da linha
  155 antes do `DoChangeStance`). Se o crouch pelo dest funcionar, sobra dele só o prone-sem-cobertura.
