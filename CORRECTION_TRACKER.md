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
| B16 | `RATOAI_Debug` congelava em `false` no load — debug do mod inteiro morto | `UTIL.lua` | ✅ aplicado |
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

## Fora desta lista, de propósito

- **Calibragem de pesos/magnitude** (o que era B3, B4, B8 e M1–M7 no doc antigo) — não é
  bug, é ajuste de balanceamento. Vive em `POLICY_BUDGET.md` se quiser o modelo, mas sem
  tracker de status aqui.
- **B41, B42** — dois achados de uma sessão de revisão (rotation_cost ausente no ramo
  curto do `AICalcAttacksAndAim`, e AP sobrando que não vira mira) nunca chegaram a
  entrar num arquivo antes dele ser apagado. Confirmei via código que ainda são reais.
  Não incluí de volta aqui porque você não confirmou se quer — avisa se quiser que eu
  adicione.
