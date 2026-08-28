# Rato's AI Overhaul — Tracker de correções

Lista de bugs de lógica/scoring encontrados e seu status. **Não é sobre calibragem de
pesos** — isso muda a cada sessão e não compensa manter sincronizado num arquivo; o
modelo de como os pesos se comparam fica em `POLICY_BUDGET.md`, sem tracker de status.

Busque `BUGFIX (Bn)` no código pra ver a correção aplicada, com o raciocínio completo —
a descrição aqui é só o resumo pra saber se já foi mexido e onde.

## Status

| # | O que era o bug | Onde | Status |
|---|---|---|---|
| B1 | `dest_cth` virava Marksmanship crua, não CTH real — distância/cobertura paravam de influenciar ações especiais | `SOURCE_AIPrecalcDamageScore.lua` | ✅ aplicado |
| B2 | `Pindown_CustomScoring` inteira desligada por um `if true then` | `FUNCTION_SignaturesCustomScoring.lua` | ✅ aplicado |
| B5 | `weight_unbolted` aplicado em dobro no flanking score | `FUNCTION_getAISoldierFlankingBehaviorSelectionScore.lua` | ✅ aplicado |
| B6 | 5 cópias da mesma fórmula de penalidade, escrita de um jeito que escondia o que fazia, sem proteção contra CTH zero | `FUNCTION_SignaturesCustomScoring.lua` | ✅ aplicado |
| B7 | Aritmética float no caminho de decisão sincronizada — fonte clássica de desync | `FUNCTION_ScoreAttacksDetailed.lua`, `AIPOLICYPOS_CustomFlanking.lua`, `AIPOLICYPOS_CustomSeekCover.lua`, os `getAI*BehaviorSelectionScore` | ✅ aplicado |
| B11 | IA não valorizava cobertura baixa (não se agachava) | `AIPOLICYPOS_AvoidThreatenedAreas.lua` | ⚠️ decorativo — o arquivo inteiro está comentado (`--[[ ]]`), quem roda é o vanilla sem alteração nenhuma. Não reverifiquei se isso mudou |
| B12 | `AITakeCover` era um no-op inteiro | `SOURCE_AITakeCover.lua` | ✅ aplicado |
| B13 | `OptLocWeight` sumia quando a unidade já estava no lugar ótimo | `SOURCE_AIScoreReachableVoxels.lua` | ✅ aplicado |
| B14 | Ramo antecipado do `AICalcAttacksAndAim` não descontava o custo de stance | `SOURCE_AICalcAttacksandAim.lua` | ✅ aplicado |
| B15 | `cth_attacks_at` acumulava disparos entre passadas do precalc (só afeta debug) | `FUNCTION_ScoreAttacksDetailed.lua` | ✅ aplicado |
| B16 | `RATOAI_Debug` congelava em `false` no load — debug do mod inteiro morto | `UTIL.lua` | ⚠️ **estava marcado como aplicado e não estava** — os 3 `OnMsg` que são a correção ficaram comentados. Ver B45 |
| B17 | Shooting stance oscilava entre cobertura e peek | `UTIL.lua`, `SOURCE_AICreateContext.lua`, `SOURCE_AIScoreReachableVoxels.lua` | ✅ aplicado |
| B18 | Laço de mira comprava nível e só depois perguntava se o disparo cabia — podia devolver zero disparos | `SOURCE_AICalcAttacksandAim.lua` | ✅ aplicado |
| B19 | Free move contado como AP de ataque | `SOURCE_AICalcAttacksandAim.lua` | ✅ aplicado |
| B20 | Desconto por alvo derrubado, agora nos 4 modos | `SOURCE_AIPolicyDealDamage.lua` | ✅ aplicado |
| B21 | Rajada valia um acerto só | `FUNCTION_ScoreAttacksDetailed.lua`, `SOURCE_AIPrecalcDamageScore.lua` | ✅ aplicado |
| B22 | Sobretaxa de mira do recoil não entrava no planejamento — IA orçava mais tiros do que conseguia pagar | `SOURCE_AICalcAttacksandAim.lua` + GBO3 `FUNCTIONS_recoil.lua` | ✅ aplicado |
| B23a/b | Pilhas de recoil não começavam do zero na avaliação | `FUNCTION_ScoreAttacksDetailed.lua` | ✅ aplicado |
| B24 | Ataque tardio podia apagar um ataque anterior na penalidade persistente | `FUNCTION_ScoreAttacksDetailed.lua` | ✅ aplicado |
| B25 | Destino de quem prefere Prone empacotado em pé | `SOURCE_AIFindDestinations.lua` | ⚠️ relatado como não-resolvido em 17/08. B36/B37 mexem na mesma área depois — não reverifiquei se o sintoma fechou |
| B26 | Cone da MG decidido com a linha de visão em pé | `SOURCE_AIPrecalcConeTargetZones.lua` | ⚠️ não testado em jogo (17/08) |
| B27 | `AIPolicyMGSetupPosScore` reescrita — ângulo, portão, visibilidade, aglomerado | `AIPOLICYPOS_MGSetupPosScore.lua` | ⚠️ não testado em jogo (17/08) |
| B28 | Montava a MG e atirava fora do cone — ordem, não filtro (precalc roda antes da signature action) | `REACTIONS_StopMGPackingUp.lua` | ⚠️ não testado em jogo (17/08) |
| B29 | `MGSetup` sumia da lista mesmo com policy positiva — CTH circular medida antes do setup | `AIPOLICYPOS_MGSetupPosScore.lua` e outros (sub-itens c/d/e em arquivos do cluster MG) | ⚠️ não testado em jogo (17/08) |
| B31 | Peso descrevia uma parte do corpo, tiro saía em outra (`pairs` sem ordem garantida) | `FUNCTION_SignaturesCustomScoring.lua`, `SOURCE_AIGetAttackTargetingOptions.lua` | ✅ aplicado |
| B32 | `RATOAI_DebugForce` nunca era visto pelo console (`rawget` contra global atrás do `__index`) | `UTIL.lua` | ✅ aplicado |
| B33 | Orçamento de AP do MGSetup descontava free move que a IA não tem mais na hora de executar | `AIPOLICYPOS_MGSetupAP.lua`, `AIPOLICYPOS_MGSetupPosScore.lua` | ✅ aplicado |
| B34 | Sobretaxa de recoil na mira nascia morta (`rawget` sempre nil) — mascarava o B22 | `FUNCTION_SignaturesCustomScoring.lua`, `SOURCE_AICalcAttacksandAim.lua` | ✅ aplicado |
| B35 | Cone da MG avaliado da posição errada quando perguntado antes do movimento | `CONSTANTS_AI_source.lua`, `SOURCE_AICalcAOETargetPoints.lua`, `SOURCE_AIPrecalcConeTargetZones.lua` | ✅ aplicado |
| B36 | IA rastejava o mapa inteiro pra chegar num tile vazio — agora só deita onde compensa | `CONSTANTS_AI_source.lua`, `SOURCE_AIFindDestinations.lua` | ✅ aplicado |
| B37 | Tile aberto agora empacota Prone em vez de em pé, por arquétipo (`ExposedProne`), com válvula mestra `const.RATOAI.ExposedProne` | `CONSTANTS_AI_source.lua`, `SOURCE_AIFindDestinations.lua`, `PATCH_AppendClass_source_classes.lua` | ✅ aplicado |
| B38 | `cost` do `SaveAP` era calculado e descartado — o gate nunca disparava | `AIPOLICYPOS_GrenadeRange.lua` | ✅ aplicado |
| B39 | Gradiente de cobertura era jogado fora (só virada binária contava) + assimetria `0`/`nil` entre origem e destino | `AIPOLICYPOS_CustomFlanking.lua` | ✅ aplicado |
| B40 | Inimigo caído deixa de ser referente de posicionamento | `AIPOLICYPOS_CustomWeaponRange.lua`, `AIPOLICYPOS_GrenadeRange.lua` | ⚠️ não testado em jogo (17/08) |
| B43 | `AIReloadWeapons` recarregava de graça — 0 AP, sem checagem, apesar de o source ter uma `CanReload` (checa AP) que nunca era chamada em lugar nenhum | `SOURCE_AIReloadWeapons.lua` — mantém a fabricação de munição do vanilla (inimigo não carrega munição; a action `"Reload"` do jogador não serve), agora atrás de portão de AP + `ConsumeAP`. Válvula `const.RATOAI.ReloadCostsAP` | ⚠️ não testado em jogo (27/08). **Atenção:** `AIReloadWeapons` é chamada em `Unit:StartAI` (Unit.lua:8912), então a cobrança cai no início do turno e muda o AP de todo o scoring — não só o da execução |

| B44 | Painel "Resultado esperado" do `Rato Dev` parou de mostrar o detalhe tiro a tiro. Não era o rename `dbg`→`trace` (esse está correto dos dois lados): a chave composta do memo `__ratoai_expected` era escrita à mão em **dois** lugares e divergiu — o produtor passou a usar `action@aim@body@ap@stance_paid`, o consumidor do bloco de debug continuou em `action@aim@body`. Chave nunca casava → `slot` nil → `trace`/`motivo` nil, em silêncio | `FUNCTION_ScoreAttacksDetailed.lua` (chave agora nasce só em `RATOAI_ExpectedKey`) | ⚠️ não testado em jogo (27/08) |

| B45 | Os 3 `OnMsg` que ligam `RATOAI_RecomputeDebugFlag` estavam comentados — reabria o B16 inteiro. Painel do `Rato Dev` mostrando tudo sem chance de acerto era isto: `dbg_expected`, `cth_attacks_at` e `aims_at` são todos porteados por `RATOAI_Debug` | `UTIL.lua` | ✅ aplicado — **causa medida no processo vivo** (27/08): flag `false` com `Platform.developer`/`cheats` ambos `true` e `DebugForce` nil; chamar a recomputação à mão virava `true` |

| B46 | IA era blindada contra emperramento **e** contra desgaste de arma — `FirearmBase:ReliabilityCheck` tinha `attacker.team.control ~= "AI"` no gate, exclusão explícita do vanilla. E não havia lógica nenhuma de unjam na IA | **GBO3** `SOURCE_ReliabilityAndJam.lua` + `__JamParams.lua` (dono da fórmula e do portão `const.Weapons.WearAppliesToAI`); **RATOAI** `SOURCE_ReliabilityCheck.lua` (só liga o portão) e `SOURCE_AIReloadWeapons.lua` (`RATOAI_AIUnjamWeapons`, antes da recarga; válvula `const.RATOAI.UnjamCostsAP`) | ✅ caminho de unjam **medido ao vivo** (27/08): destravou, −5000 AP, −16 Condition, `num_safe_attacks`=2. Fórmula nova de jam/desgaste **não testada em jogo** |
| B47 | O planejador era cego ao **caminho**: só pontuava o tile final. A IA sabia não *parar* em gás/fogo e atravessava os dois de graça, e entrava em cone de Overwatch sem nenhum custo no plano (na execução ela leva o tiro, replaneja, e repete). O pathfinder também não ajuda — `CombatPath:RebuildPaths` passa um único parâmetro de perigo, `avoid_mines` | `FUNCTION_DangerScan.lua` (novo: `RATOAI_PathDanger`, `RATOAI_TimedTrapDanger`), gancho em `SOURCE_AIScoreDest.lua`, bandeira de passe em `SOURCE_AIScoreReachableVoxels.lua`, overlay em `DEBUG.lua` | ✅ varredura de trajeto **medida ao vivo** (28/08): 26/27 acertos contra verdade independente, 0 falso positivo. O `PathDangerScope` que saiu daí ainda **não foi rodado** |

### B47 — o que entra, o que não entra, e por quê

`gás nocivo` e `fogo` contam **por voxel** atravessado. `overwatch` conta **por cone** e não por
tile — cruzar dispara a interrupção uma vez, então correr 8 tiles dentro do cone não é 8× pior que
cruzar 1 — e **com rampa de distância**: cruzar a 3 tiles do atirador não é cruzar na ponta do
cone. Por cone vale o *pior ponto* do trajeto (acumulação por máximo, não por soma).

A rampa é a `RATOAI_ThreatRamp` — a mesma da Seek Cover e da ThreatExposure, de propósito: as três
não podem divergir de noção de "quanto perto é perto". O `range` dela é o `overwatch.dist` do
próprio cone (`UnitOverwatch.lua:202` já o monta com `Clamp` entre min/max range da arma), então
plateau → penalidade cheia e ponta do cone → só o piso (`PathOverwatchMinPct`, 15%). O piso existe
porque cruzar na borda não é inofensivo: o inimigo ainda atira, só que com CTH ruim.

**Gás é lista branca** (`const.RATOAI.PathHarmfulGas = {teargas, toxicgas}`), não `~= "smoke"`.
Fumaça comum não machuca — só bloqueia visão, e atravessar chega a ser bom. Além disso a lista
negra tinha um bug real: `SmokeObj:GetGasType` (`Grenade.lua:1997`) é
`self.zones and self.zones[1] and self.zones[1].gas_type` e **pode devolver nil/false** — com
lista negra, gás de tipo indefinido seria tratado como nocivo. O `AnyInterruptsAlongPath` do
vanilla (`Utility.lua:1580`) tem exatamente esse buraco.

Ficaram **de fora**, cada um por um motivo diferente:

- **pindown** — no GBO3 o `PinDown` virou *Snipe*: ataque adiado que dispara no início do próximo
  turno, não interrupção de movimento. E mesmo no vanilla ele nunca esteve no caminho:
  `CheckProvokeOpportunityAttacks` (`UnitOverwatch.lua:1247-1320`) só tem ramos de trap, melee
  interrupt e overwatch. O `IsThreatened(nil, "pindown")` testa `g_Pindown[enemy].target == self`,
  que é "estou marcado" — não há cone a evitar.
- **explosivo timed** — detona por relógio, não por contato. Atravessar o raio no meio do turno é
  inofensivo; o que mata é *terminar* o turno dentro dele. Por isso virou pergunta de tile final
  (`RATOAI_TimedTrapDanger`, gradiente igual ao do `g_Bombard`) e não entrou no scan de caminho.
- **mina Contact/Proximity** — é o único perigo que o pathfinder já trata sozinho, via
  `avoid_mines`. Duplicar aqui seria contar duas vezes.

### B47 — o custo é amortizado, não por destino

`cpath.paths_prev_pos` é uma **árvore** enraizada na posição da unidade (a origem aponta para
`false`), então o caminho de qualquer destino é sufixo do caminho do pai. O perigo acumulado é
memoizado por voxel: cada destino novo sobe a árvore até bater em algo já calculado. Amortizado, o
laço de destinos custa O(voxels da árvore), não O(destinos × comprimento).

Com mapa limpo (sem gás, sem fogo, sem cone inimigo visível) o snapshot de perigo resolve `false`
uma vez por `context` e o mecanismo inteiro custa uma leitura de tabela por destino.

### B47 — medido ao vivo (28/08, LegionRaider:775, turno 3)

Sonda DAP no processo rodando, MD com overwatch ativo (cone de **6 tiles**, 22°, `num_attacks`=3),
unidade a 4 tiles do MD, 270 destinos. Varri o caminho de cada destino por fora (verdade
independente) e comparei com o que o mod marcou:

| | |
|---|---|
| caminho cruza o cone **e** foi marcado | 26 |
| cruza mas **não** foi marcado | 1 |
| marcado **sem** cruzar (falso positivo) | 0 |
| limpo | 243 |

O único "miss" é o caso excluído de propósito: destino cujo caminho só toca o cone **na origem** —
a unidade já está lá.

**A varredura de trajeto funciona.** Dos 26 marcados, **23 estão geometricamente fora do cone** —
distância ao MD de 8 a 21 tiles, num cone de 6. Impossível vir do tile final. A região penalizada é
a *sombra* do cone vista da unidade (ápice na unidade, não no MD), que no overlay parece uma cunha
indo até o alcance da arma. Está correto: são os destinos inalcançáveis sem atravessar.

A rampa de distância também apareceu — tiles com `-143` em vez de `-170` (84% da penalidade), de
trajetos que cruzaram já passando do platô.

### B47 — o achado que gerou o `PathDangerScope`

No mesmo turno: `best_end_score` = **82**, notas de OptLoc entre **92 e 339**. Com penalidade de
−170:

```
PENALIZADOS que sobreviveram no dest_scores (OptLoc):  0
PENALIZADOS descartados (score <= 0):                 26
```

`AIFindOptimalLocation` tem `if score > 0 then` (`CombatAI.lua:1287`) — nota ≤ 0 é **descartada**,
não ranqueada. Então no passe de OptLoc a penalidade não rebaixava o candidato: **apagava**. Isso
contraria o "viés em gradiente" do resto do mod — a IA deixa de *considerar* uma boa posição atrás
do cone, em vez de considerá-la e achar cara.

Daí `const.RATOAI.PathDangerScope` (`"endturn"` default | `"optloc"` | `"both"`) e
`TimedDangerScope` (`"both"` default). O discriminador é `context.__ratoai_endturn_pass`, ligado no
override de `AIScoreReachableVoxels` — funciona porque `AIScoreDest` tem **exatamente dois**
chamadores no jogo (`AIFindOptimalLocation` e `AIScoreReachableVoxels`), verificado por grep.

`"both"` restaura o comportamento de 28/08. Com o debug ligado, um termo fora de escopo escreve no
overlay dizendo isso — overlay vazio não pode ser confundido com feature quebrada de novo.

### B47 — o que ainda não foi verificado

- O `PathDangerScope` em si **não foi rodado em jogo** (só o mecanismo de 28/08 foi). Não há Lua no
  ambiente; a checagem do código novo foi balanceamento de blocos, sync `metadata.lua` ×
  `items.lua`, saída única em `AIScoreReachableVoxels` (a bandeira não pode ficar presa), e
  conferência dos símbolos do engine contra o source.
- As **magnitudes** (`PathGasPenalty` 60, `PathFirePenalty` 60, `PathOverwatchPenalty` 170, teto
  400, `DestTimedPenalty` 250, `PathOverwatchMinPct` 15) são chute calibrado pela escala do
  `AIAvoidFireWeigth` (−200), não medição. Todas vivem em `const.RATOAI.*` e são ajustáveis no
  console sem recarregar mod.
- O `PathOverwatchPenalty` subiu de 130 para 170 **junto com** a rampa de distância, e não por
  medição: com valor fixo 130 valia em qualquer ponto do cone; com rampa passaria a valer só
  colado no atirador, e todo o resto ficaria mais barato que antes — a rampa sozinha só enfraquece
  o mecanismo. Se em campo a IA passar a dar voltas absurdas para evitar cone, é o primeiro número
  a baixar.
- O teste de cone é **geométrico 2D e ignora paredes** — superestima (marca tile que a parede
  protegeria). Erro deliberado para o lado seguro, mas se em campo a IA evitar cones que uma
  parede já bloqueia, é aqui que está.
- `const.RATOAI.PathDangerDebug = true` no console mostra a composição por tile no rollover.

### B46 — a fórmula mora no GBO3, não aqui

Jam e desgaste afetam **o jogador**, então a fórmula é escopo do GBO3. Se os dois mods
sobrescrevessem `ReliabilityCheck`, o RATOAI (que carrega depois, por ser dependente) apagaria a
fórmula do GBO3 **em silêncio**. Divisão: GBO3 é dono da função e expõe
`const.Weapons.WearAppliesToAI` (default `false` = vanilla); o RATOAI só liga o portão.

Mudança de significado: `Reliability` deixa de ser velocidade de desgaste e vira **resistência a
emperrar**. Os valores herdados estavam calibrados como taxa de desgaste (por isso Gewehr98 25 e
BarretM82 10, invertendo a realidade) — proposta de reescala em `reliability_proposta.lua` no
scratchpad, valores finais são do autor.

### B46 — o que saber antes de calibrar

- **Um gate, dois efeitos.** No vanilla o mesmo `if` governa o sorteio de jam **e** a perda de
  `Condition` por disparo. Destravar um destrava o outro. Efeito para o jogador: arma saqueada de
  inimigo que lutou muito vem em condição pior. É mudança de economia de loot, não só de
  dificuldade.
- **Já morde hoje.** Medido em combate: armas de inimigo já chegam com Condition espalhada
  (57, 74, 76, 77, 82, 100) — vem do `RandomizeCondition` do loadout vanilla (±30). Um AK47 em 57
  já tem ~10% de chance de emperrar por ataque. Não precisa de peça adicional.
- **`SkillCheck` é determinístico**, não aleatório (`threshold <= stat`). Inimigo tem
  `Mechanical = 0` e threshold `(100−Condition)+(100−Reliability)`, então **sempre falha** — mas
  falhar destrava assim mesmo, perdendo Condition (3 a 16). A arma só trava de vez se chegar a 0.
  Espiral auto-limitada: `num_safe_attacks`=2 é concedido mesmo na falha. **Dial de balanceamento:
  subir `Mechanical` do arquétipo pelo editor**, sem código.
- **Gap de paridade deliberado:** o caminho da IA pula o `ProvokeOpportunityAttacks` que
  `Unit:UnjamWeapon` faz para o jogador.

### B43 — por que não cobrava mesmo com a válvula ligada

Medido no processo vivo (27/08): o mod de Workshop **"Revised Mags II"** (`URkxyfE`, só em `.hpk`)
sobrescreve `CombatActions.Reload.GetAPCost` e devolve **0** para arma de carregador destacável —
inclusive com a forma de args que a UI do jogador usa. Como o gate era `if cost > 0 then ConsumeAP`,
nunca cobrava. Não é específico da IA: medido em mercs, `Gewehr98` → 3000, `PapovkaSKS_1` → 0,
`UZI` → 0. **O jogador também recarrega de graça essas armas nesta modlist.**

Daí o `const.RATOAI.ReloadAPSource`. **Default `weapon`**, decisão do autor: o Revised Mags precifica
por pente (sem pente caro, com pente barato) e essa economia não se aplica à IA, que não tem pente
nem inventário — o `0` dele é "não sei", não "de graça". `weapon.ReloadAP` é onde o **GBO3** escreve
os custos (`PATCH_GBO_weapons.lua`, por arma), e por ser property já vem com os modificadores de
componente aplicados, incluindo o `ReloadAPIncrease` do próprio GBO3 (`Assign_magsize.lua`) — ou
seja, rebalancear no GBO3 continua mexendo no que a IA paga.

### B43 — tentativa revertida (teto por carregador)

Houve também um teto por carregador no `AICalcAttacksAndAim` (limitar disparos por `ammo.Amount` e
tirar o `ReloadAP` do orçamento), para pôr a decisão de recarregar no orçamento em vez de numa ação.
**Revertido** — zerava a contagem de ataques em campo (painel mostrava tudo sem chance de acerto).
A causa exata não foi estabelecida; o comentário no arquivo lista os suspeitos não descartados e
como medir. Não retomar sem medir primeiro.

### B43 — pendência de limpeza

A primeira tentativa foi uma `AISignatureAction` (`AIReloadWeapon`, `Code/AIACTION_Reload.lua`) e
**não funcionou**: ela roteava pela action `"Reload"` do jogador, que resolve munição por
`GetAvailableAmmos` — e inimigo não carrega munição, nem no inventário nem em squad bag. A chamada
virava no-op silencioso e a IA parava de recarregar (pior que o vanilla, que ao menos fabricava).

A classe foi mantida **viva e inerte** porque o `items.lua` tem um `PlaceObj('AIReloadWeapon', nil)`
nas `SignatureActions` de um arquétipo, posto pelo editor. Para remover de vez: tirar a ação pelo
editor in-game, salvar, e só então apagar o arquivo.

## Fora desta lista, de propósito

- **Calibragem de pesos/magnitude** (o que era B3, B4, B8 e M1–M7 no doc antigo) — não é
  bug, é ajuste de balanceamento. Vive em `POLICY_BUDGET.md` se quiser o modelo, mas sem
  tracker de status aqui.
- **B41, B42** — dois achados de uma sessão de revisão (rotation_cost ausente no ramo
  curto do `AICalcAttacksAndAim`, e AP sobrando que não vira mira) nunca chegaram a
  entrar num arquivo antes dele ser apagado. Confirmei via código que ainda são reais.
  Não incluí de volta aqui porque você não confirmou se quer — avisa se quiser que eu
  adicione.
