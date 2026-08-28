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
