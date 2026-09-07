---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata (o CONSTANTS_AI_source ja a cria, mas nao dependemos disso).
const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- AIPolicyThreatExposure
----
---- Responde UMA pergunta: "quanta ameaca alcanca este tile?"
----
---- Existe porque a AIPolicyCustomSeekCover respondia duas perguntas ao mesmo tempo, e
---- mal. La, inimigos fora de alcance entravam no denominador valendo zero, entao um
---- tile com cobertura perfeita contra o unico inimigo que o alcanca pontuava 100/4 se
---- houvesse mais tres inimigos longe. Isso NAO era uma medida de ameaca -- era uma
---- diluicao acidental -- mas era a unica coisa no mod que penalizava "muita gente me
---- vendo" (o AIPolicyDontBeExposedAtCloserRange esta inteiro comentado e o
---- AvoidThreatenedAreas nao aparece no items.lua).
----
---- Ao tornar a Seek Cover uma media ponderada de verdade, aquela diluicao sumiu. Este
---- arquivo devolve o sinal, agora separado e com peso proprio por archetype:
----
----   Seek Cover        -> "quao bem coberto eu estou contra quem me alcanca"  [Exposed, Base]
----   Threat Exposure   -> "quanta gente me alcanca"                           [Penalty, 0]
----
---- Usa RATOAI_ThreatRamp (definida em AIPOLICYPOS_CustomSeekCover.lua) -- a MESMA
---- rampa da Seek Cover, de proposito: as duas nao podem divergir de nocao de alcance.
----
---- NAO esta ligada em nenhum archetype. Adicione onde quiser em items.lua.
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyThreatExposure = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {
            id = "visibility_mode",
            name = "Visibility Mode",
            editor = "choice",
            default = "team",
            items = function(self)
                return {"self", "team", "all"}
            end
        }, {
            id = "Penalty",
            name = "Penalidade (saturada)",
            help = "Score quando a ameaca atinge MaxThreat. O retorno vive em [Penalty, 0].",
            editor = "number",
            default = -100
        }, {
            id = "MaxThreat",
            name = "Ameaca de saturacao",
            help = "Quantos inimigos colados equivalem a penalidade cheia. 3 = tres inimigos " ..
                "a queima-roupa, ou seis a meio alcance.\n" ..
                "0 = usar a constante compartilhada const.RATOAI.ThreatSaturation (recomendado). " ..
                "Um valor proprio aqui SO faz sentido se a Seek Cover deste archetype " ..
                "estiver com ThreatRelative = 0; caso contrario as duas normalizam " ..
                "diferente e o cancelamento entre cobertura e exposicao quebra sem aviso.",
            editor = "number",
            default = 0,
            min = 0,
            max = 20
        }, {
            ---------------------------------------------------------------------------
            ---- O CANCELADOR
            ----
            ---- Liga o modo em que a cobertura cancela a ameaca DENTRO desta policy, em
            ---- vez de a AIPolicyCustomSeekCover creditar cobertura por fora.
            ----
            ---- Existe porque as duas policies separadas se DESSINCRONIZAM no clamp. Com
            ---- a soma acima da saturacao, a ameaca trava em `Penalty` e a cobertura NAO
            ---- trava junto: o inimigo extra nao consegue mais aumentar a punicao (ja
            ---- esta no teto) mas continua entrando no numerador da media de cobertura.
            ---- Resultado medido: um tile exposto ao IMP marcava -100, e o MESMO tile
            ---- exposto ao IMP com um Igor coberto por perto marcava -51. Um inimigo a
            ---- mais apontando uma arma MELHORAVA a nota do tile em 49 pontos.
            ----
            ---- Aqui cada inimigo entra com `rampa x (100 - cobertura)`, que e sempre
            ---- >= 0, e o clamp cai sobre a SOMA. Com isso:
            ----   * monotonico -- inimigo do qual estou coberto contribui exatamente 0,
            ----     nunca credito; nao existe mais o caso perverso;
            ----   * "1 ou 1000 da no mesmo" sai de graca, porque o clamp agora esta em
            ----     cima de uma soma monotona: 3 colados expostos saturam igual a 1;
            ----   * o gradiente de distancia continua, porque a rampa continua.
            ----
            ---- ATENCAO: ligando isto, a AIPolicyCustomSeekCover do MESMO grupo de
            ---- policies vira contagem dobrada. Tire ela da lista (ou zere o Weight).
            ---- A Seek Cover continua util sozinha em listas sem esta policy.
            ---------------------------------------------------------------------------
            id = "CoverCancels",
            name = "Cobertura cancela a ameaca (aqui dentro)",
            help = "Cada inimigo entra com rampa x (100 - cobertura). Cobertura total " ..
                "contra ele zera a contribuicao dele.\n" ..
                "LIGANDO ISTO, remova a AIPolicyCustomSeekCover desta mesma lista -- " ..
                "senao a cobertura conta duas vezes.",
            editor = "bool",
            default = true
        }, {
            ---- Vies de risco. Diferente do `Penalty` e do `Weight`, que escalam o sinal
            ---- inteiro e nao mudam onde ele cruza o zero: com 100 aqui, cobertura total
            ---- zera a ameaca exatamente; com 70, cobertura total ainda deixa 30% da
            ---- ameaca de pe. E o botao de "quanto eu confio em cobertura", que e o mesmo
            ---- que "quanto eu prefiro sobreviver a avancar".
            id = "CoverTrust",
            name = "Confianca na cobertura (%)",
            help = "So com `CoverCancels` ligado. 100 = cobertura total cancela a ameaca " ..
                "por inteiro (agressiva). Abaixo disso sobra ameaca mesmo coberta, e a " ..
                "IA fica mais cautelosa. 0 = cobertura nao vale nada.",
            editor = "number",
            default = 80,
            min = 0,
            max = 100
        }, {
            ---------------------------------------------------------------------------
            ---- RAIO DE EXCLUSAO DA COBERTURA
            ----
            ---- A cobertura e medida contra a posicao ATUAL do inimigo: RATOAI_CoverCTH
            ---- chama GetCoverPercentage(target_pos, attacker_pos, ...). Quanto mais
            ---- perto ele esta, mais barato e para ele mudar essa posicao -- 2 ou 3
            ---- tiles custam 1-2 AP, e a cobertura que estamos creditando deixa de
            ---- existir ANTES do tiro. A 20 tiles ele nao contorna nada no mesmo turno.
            ---- Ou seja: nao e a cobertura que vale menos de perto, e a MEDICAO que e
            ---- volatil de perto. Este parametro cobra esse risco.
            ----
            ---- ATENCAO -- isto NAO espelha a mecanica do jogo, ao contrario do
            ---- PlateauTiles. O RangeAttackTargetStanceCover
            ---- (Data/ChanceToHitModifier.lua:580-606) nao tem termo de distancia
            ---- nenhum: cobertura vale os mesmos -20 de CTH a 1 tile e a 30. Isto e
            ---- vies de risco da IA, deliberado, nao correcao de conta. Deixe em 0 se
            ---- quiser a leitura crua do jogo.
            ----
            ---- 0 = desligado (default -- nao mexe em nenhum archetype ja calibrado).
            ---- Referencia natural: const.Weapons.PointBlankRange, que o GBO3 sobe de 4
            ---- para 6 tiles (Rato-s-Gameplay-Balance-and-Overhaul-3/Code/__MainParams.lua:62).
            ---- 2-3 tiles e o ajuste conservador: pega so quem contorna a cobertura com 1 AP.
            ---------------------------------------------------------------------------
            id = "CoverNearTiles",
            name = "Raio de exclusao da cobertura (tiles)",
            help = "Abaixo desta distancia a confianca na cobertura cai de CoverTrust " ..
                "ate CoverTrustNear, linearmente, chegando em CoverTrustNear com o " ..
                "inimigo colado.\n" .. "0 = desligado: cobertura vale igual a qualquer distancia.\n" ..
                "So tem efeito com `CoverCancels` ligado.",
            editor = "number",
            default = 12,
            min = 0,
            max = 30
        }, {
            ---- O piso da rampa acima. Separado do CoverTrust de proposito: um controla
            ---- "quanto eu confio em cobertura", o outro "quanto eu desconfio dela com
            ---- o cara no meu colo". Sao dois botoes independentes.
            id = "CoverTrustNear",
            name = "Confianca na cobertura colado (%)",
            help = "Confianca aplicada com o inimigo a distancia 0. Interpola " ..
                "linearmente ate CoverTrust em CoverNearTiles tiles.\n" ..
                "0 = colado, cobertura nao vale nada -- o inimigo entra com a ameaca " ..
                "cheia, como se fosse corpo a corpo.\n" .. "So tem efeito com CoverNearTiles > 0.",
            editor = "number",
            default = 0,
            min = 0,
            max = 100
        }, {
            ---------------------------------------------------------------------------
            ---- POSTURA DO DESTINO ABATE AMEACA  (espelha o GBO3)
            ----
            ---- Diferente de tudo que esta acima, isto NAO e vies de risco -- e mecanica
            ---- do jogo que a policy estava ignorando. O CTH_cover_prone.lua do GBO3
            ---- reescreve o RangeAttackTargetStanceCover para dar ao alvo agachado ou
            ---- deitado uma penalidade de CTH que CRESCE COM A DISTANCIA:
            ----
            ----   Prone  = PronePenalty  x min(d, ProneMaxTiles)  / ProneMaxTiles
            ----   Crouch = CrouchPenalty x min(d, CrouchMaxTiles) / CrouchMaxTiles
            ----   abaixo de 1.5 tiles, nada -- colado, deitar nao adianta
            ----
            ---- Com os numeros atuais do GBO3 (Cover -35, Prone -30, Crouch -12): deitado
            ---- a 24+ tiles vale 86% de uma cobertura cheia; agachado a 26+ tiles vale
            ---- 34%. De perto os dois tendem a zero -- que e a razao de a rampa existir.
            ----
            ---- NAO SOMA COM COBERTURA, e a prioridade e a mesma do jogo: se
            ---- RATOAI_CoverCTH diz que a cobertura se aplica neste tile, ela manda e a
            ---- postura nao entra. A postura so pega o tile SEM cobertura util -- que e
            ---- justamente o tile aberto onde a IA precisava de um motivo para deitar.
            ----
            ---- (No GBO3 o Prone e testado ANTES da cobertura e retorna primeiro; aqui
            ---- cobertura vem primeiro nos dois casos, de proposito. Cobertura cheia -35
            ---- e mais forte que o Prone -30 em qualquer distancia, entao dar prioridade
            ---- a ela e o resultado conservador -- a IA nunca superestima o tile.)
            ---------------------------------------------------------------------------
            id = "StanceCancels",
            name = "Postura do destino abate a ameaca",
            help = "Agachar/deitar no destino reduz a ameaca que chega nele, com o " ..
                "efeito CRESCENDO com a distancia (colado nao adianta nada). Espelha o " ..
                "RangeAttackTargetStanceCover do GBO3.\n" ..
                "Nao soma com cobertura: onde ha cobertura util, ela tem prioridade e a " ..
                "postura nao entra.",
            editor = "bool",
            default = true
        }, {
            ---- Mesmo papel do CoverTrust, para a outra fonte de abatimento: 100 = a IA
            ---- acredita na postura exatamente como o jogo a paga. Abaixo disso ela
            ---- desconta -- util porque deitar tem custo de AP para desfazer, e um tile
            ---- so bom deitado e um tile do qual e caro sair.
            id = "StanceTrust",
            name = "Confianca na postura (%)",
            help = "So com `StanceCancels` ligado. 100 = a postura vale o que o GBO3 paga " ..
                "em CTH. Abaixo disso a IA desconta o beneficio (deitar prende a unidade: " ..
                "levantar custa AP no turno seguinte). 0 = postura nao vale nada.",
            editor = "number",
            default = 70,
            min = 0,
            max = 100
        }, {
            ---- Espelham os `max_dist` hardcoded do CTH_cover_prone.lua (24 e 26 tiles).
            ---- Se aqueles mudarem no GBO3, mude estes junto -- sao o mesmo numero, e nao
            ---- ha como ler de la (estao dentro do corpo da CalcValue, nao no preset).
            id = "ProneMaxTiles",
            name = "Distancia de saturacao do Prone (tiles)",
            help = "Distancia em que deitado rende o PronePenalty CHEIO; abaixo dela o " ..
                "beneficio cai linearmente ate zero. Espelha o max_dist = 24 do " ..
                "CTH_cover_prone.lua do GBO3 -- mantenha os dois iguais.",
            editor = "number",
            default = 24,
            min = 1,
            max = 60
        }, {
            id = "CrouchMaxTiles",
            name = "Distancia de saturacao do Crouch (tiles)",
            help = "Idem para agachado. Espelha o max_dist = 26 do CTH_cover_prone.lua " ..
                "do GBO3.",
            editor = "number",
            default = 26,
            min = 1,
            max = 60
        }, {
            ---- Ver o cabecalho de RATOAI_ThreatRamp em AIPOLICYPOS_CustomSeekCover.lua
            ---- para o porque. Resumo: a rampa linear a partir do zero contradiz a curva
            ---- de precisao do jogo em toda a primeira metade do alcance.
            id = "PlateauTiles",
            name = "Plato da rampa (tiles)",
            help = "Distancia ate onde o inimigo pesa 100 antes de a rampa comecar a " ..
                "cair. 0 = rampa linear desde o tile colado (comportamento antigo).\n" ..
                "const.Weapons.PointBlankRange = 6 tiles -- e a faixa onde automatica e " ..
                "letal por recoil e proximidade, independente de precisao.\n" ..
                "Cuidado: plato maior infla o SOMA(w) e satura mais cedo; se subir muito " ..
                "aqui, suba a saturacao junto.",
            editor = "number",
            default = 6,
            min = 0,
            max = 30
        }, {
            ---------------------------------------------------------------------------
            ---- TETO DE ALCANCE
            ----
            ---- Corta o alcance que ENTRA na rampa: com teto 20, um sniper de 36 tiles
            ---- e tratado como se tivesse 20 -- pesa 100 no plato, cai ate 0 em 20, e
            ---- alem de 20 nao conta mais. Um SMG de 16 nao muda nada, porque ja esta
            ---- abaixo do teto.
            ----
            ---- Note que isto NAO so remove o inimigo distante: ele passa a cair mais
            ---- RAPIDO em toda a faixa, porque a rampa inteira e reescalada para o teto.
            ---- Se a intencao for so afundar a cauda longa e manter o gradiente de
            ---- perto, use `FalloffCurve` -- os dois sao knobs diferentes.
            ----
            ---- Isto e vies de risco, nao mecanica do jogo: o sniper de 36 tiles acerta
            ---- de 30 tiles tanto quanto antes. E a forma de dizer "so me preocupo com
            ---- quem esta perto de mim AGORA".
            ----
            ---------------------------------------------------------------------------
            id = "RangeCapTiles",
            name = "Teto de alcance considerado (tiles)",
            help = "Alcance maximo que qualquer inimigo pode ter aos olhos desta " ..
                "policy. Quem tem arma mais longa e tratado como se tivesse este " ..
                "alcance; alem dele, nao conta.\n" ..
                "0 = desligado (default): vale o WeaponRange de cada arma.",
            editor = "number",
            default = 0,
            min = 0,
            max = 60
        }, {
            ---------------------------------------------------------------------------
            ---- CURVATURA DA QUEDA
            ----
            ---- Suavizacao de cauda longa sem cortar ninguem: mantem 100 no plato e 0 no
            ---- alcance, e afunda o meio. Com 100 (quadratica pura) o inimigo a meio
            ---- alcance pesa 25 em vez de 50, e a 3/4 do alcance pesa 6 em vez de 25.
            ----
            ---- Preferivel ao `RangeCapTiles` quando a queixa e "inimigo longe pesa
            ---- demais" mas voce nao quer um ponto de corte duro nem reescalar a rampa
            ---- de quem esta perto: aqui o gradiente proximo fica quase intacto.
            ---- Os dois se somam se voce ligar ambos.
            ---------------------------------------------------------------------------
            id = "FalloffCurve",
            name = "Curvatura da queda (%)",
            help = "0 = queda linear do plato ate o alcance (default). " ..
                "100 = quadratica: a cauda longa vira quase nada e a ameaca se " ..
                "concentra em quem esta perto. Valores no meio interpolam.\n" ..
                "Nao muda o peso no plato (100) nem no limite do alcance (0).",
            editor = "number",
            default = 0,
            min = 0,
            max = 100
        }, {
            id = "MeleeRange",
            name = "Alcance corpo a corpo (tiles)",
            help = "Alcance usado para inimigos sem arma de fogo.",
            editor = "number",
            default = 8,
            min = 1,
            max = 30
        }, {
            ---------------------------------------------------------------------------
            ---- CUSTO DE PREPARO -- quanto AP falta ao inimigo para me acertar BEM
            ----
            ---- NAO e vies inventado: e mecanica do GBO3 que a policy ignorava. Ela so
            ---- olhava distancia e cobertura, entao um inimigo mirando exatamente para o
            ---- tile e um inimigo de costas, despreparado, contavam a mesma ameaca.
            ----
            ---- A FONTE (Unit:GetShootingStanceAP, FUNCTIONS_CombatAP.lua:3-58):
            ----
            ----     ap_rotate = Clamp(ShootingConeAngle(self, weapon, target) * Scale.AP,
            ----                       0, ap_stance + Get_AimCost(self))
            ----     ...
            ----     if stance     then return ap_rotate       ---- ja preparado: so girar
            ----     elseif aim<1  then return ap_hipfire       ---- tiro de quadril
            ----     end           return ap_stance             ---- preparar do zero
            ----
            ---- Tres leituras que so aparecem medindo, e que definem o modelo:
            ----
            ---- 1. `ShootingConeAngle` conta em MEIOS-CONES (`OverwatchAngle / 2`, divisao
            ----    INTEIRA). Dentro do meio-cone, girar custa 0. Cada meio-cone a mais
            ----    custa 1 AP.
            ----
            ---- 2. `GetHipfire_StanceAP` esta marcada `---- not used` e retorna 0 SEMPRE
            ----    (FUNCTIONS_CombatAP.lua:129-139). Ou seja: quem NAO esta em stance nao
            ----    fica impedido de atirar -- fica impedido de atirar BEM. O preco do
            ----    hipfire e CTH, nao AP. Por isso o custo modelado aqui e o do tiro de
            ----    QUALIDADE, e para quem esta fora de stance ele e `ap_stance`.
            ----
            ---- 3. O teto NAO e um numero fixo: e `ap_stance + Get_AimCost`, e varia
            ----    bastante por arma. Medido ao vivo em 28/08:
            ----
            ----      Gewehr98  arco 5.4g   ap_stance 5000   teto 6000  (6 meios-cones)
            ----      DoubleBbl arco 7.5g   ap_stance 3000   teto 4000  (4 meios-cones)
            ----      MP40      arco 11g    ap_stance 2000   teto 3000  (3 meios-cones)
            ----      UZI       arco 12.7g  ap_stance 2000   teto 3000  (3 meios-cones)
            ----
            ---- O MODELO. Tudo vira UMA moeda -- AP para o tiro de qualidade -- e essa
            ---- moeda e normalizada pelo mesmo teto que o proprio jogo usa no Clamp:
            ----
            ----     em stance      -> ap_rotate (0 .. teto), pelo angulo ate ESTE tile
            ----     fora de stance -> ap_stance  (preparar do zero)
            ----     custo 0        -> SetupReadyPct     (pronto, alinhado: pior para mim)
            ----     custo == teto  -> SetupCostlyPct    (caro para ele: melhor para mim)
            ----
            ---- E o que torna os dois estados COMPARAVEIS em vez de mundos separados:
            ---- como o teto e `ap_stance + aim_cost`, estar fora de stance cai
            ---- naturalmente em `ap_stance / (ap_stance + aim_cost)` do caminho -- um
            ---- pouco MENOS ruim que estar em stance apontado para o lado oposto. Isso
            ---- nao foi escolhido: e o que os numeros do jogo dizem, e faz sentido
            ---- (girar 180 graus custa mais que preparar do zero virado para onde quiser).
            ----
            ---- O gradiente e ESCALONADO, nao suave, e de proposito: o custo em AP e
            ---- inteiro. Suavizar o lado do angulo deixaria de ser comparavel com o lado
            ---- do `ap_stance`, que e um AP de verdade -- e comparar os dois e o ponto.
            ---- A resolucao dos degraus vem da arma (3 a 6 passos, tabela acima).
            ----
            ---- Deliberadamente FRACO: o inimigo pode virar, e virar satura. Isto e
            ---- desempate entre tiles parecidos, nao argumento.
            ---------------------------------------------------------------------------
            id = "SetupBias",
            name = "Custo de preparo do inimigo enviesa a ameaca",
            help = "Pesa cada inimigo por quanto AP falta a ele para dar um tiro BOM " ..
                "neste tile: em stance e alinhado = 0 (ameaca cheia); em stance e fora " ..
                "do arco = custo de girar; fora de stance = custo de entrar em stance.\n" ..
                "Emplacamento (overwatch permanente) gira de graca, entao conta sempre " ..
                "como pronto. Sem arma de fogo nao se aplica.",
            editor = "bool",
            default = true
        }, {
            id = "SetupReadyPct",
            name = "Ameaca de quem esta PRONTO (%)",
            help = "Multiplicador quando o inimigo pode atirar bem aqui sem gastar AP " ..
                "nenhum (em stance, tile dentro do meio-cone). 100 = sem efeito.\n" ..
                "0 = usar const.RATOAI.ThreatSetupReady (recomendado -- e o valor " ..
                "ajustavel no console sem recarregar mod).",
            editor = "number",
            default = 0,
            min = 0,
            max = 300
        }, {
            id = "SetupCostlyPct",
            name = "Ameaca de quem esta DESPREPARADO (%)",
            help = "Multiplicador quando o custo de preparo satura no teto do jogo " ..
                "(ap_stance + aim_cost). 100 = sem efeito.\n" ..
                "0 = usar const.RATOAI.ThreatSetupCostly. Para zerar de verdade use 1, " ..
                "nao 0 -- 0 aqui significa 'herdar a constante'.",
            editor = "number",
            default = 0,
            min = 0,
            max = 300
        }, {
            ---------------------------------------------------------------------------
            ---- READINESS SHAPES THE FALLOFF, NOT JUST THE AMPLITUDE
            ----
            ---- `SetupReadyPct`/`SetupCostlyPct` scale the whole contribution by a
            ---- constant -- the same multiplier at 2 tiles and at 25. The mechanic they
            ---- proxy is not constant: being out of stance moves the enemy from the
            ---- Snapshot CTH curve to the Hipfire one (CTH_hipfire_and_snapshot.lua:85-88
            ---- forces aim = Max(1, aim) for stance / emplacement / permanent overwatch),
            ---- and both curves are ramps in DISTANCE:
            ----
            ----   hipfire  = dist x MaxPenalty / MaxDistforPenalty   (-123 over 28 tiles)
            ----   snapshot = idem                                    ( -61 over 40 tiles)
            ----
            ---- The gap between them is ~6 CTH at 2 tiles and ~80 at 28. Point blank,
            ---- being unprepared costs almost nothing -- everything kills there, hipfire
            ---- included. At range it is the whole shot.
            ----
            ---- So readiness is routed into `FalloffCurve` instead of the amplitude: the
            ---- unprepared enemy gets `curve + spread`, the ready one keeps the policy
            ---- own curve. RATOAI_ThreatRamp pins both ends of that curve -- 100 at the
            ---- plateau, 0 at the weapon range -- so only the middle moves:
            ----
            ----   range 30, plateau 6, spread 100 (measured in the live process):
            ----     d =  6   ready 100   unprepared 100   <- identical, point blank
            ----     d =  7   ready  96   unprepared  92   <- still nearly identical
            ----     d = 10   ready  83   unprepared  69
            ----     d = 15   ready  62   unprepared  38
            ----     d = 22   ready  33   unprepared  11
            ----     d = 29   ready   4   unprepared   0   <- same cutoff, both ends pinned
            ----
            ---- NOT done by shrinking the enemy `range`, which is the tempting version
            ---- (the two slopes differ by ~2.9x): the ramp returns a hard 0 past `range`,
            ---- so an unprepared sniper at 20 tiles would weigh literally nothing and the
            ---- AI would stand in the open in front of him -- he needs 5 AP to fix that
            ---- and has a whole turn. The curve keeps the cutoff at the real range.
            ----
            ---- Driven by the raw cost/cap readiness, not by `face`: retuning
            ---- SetupReadyPct must not silently move the curve. Turning this up means
            ---- turning the amplitude spread DOWN (110/90), or the two double-count.
            ----
            ---- 0 = off (default -- no calibrated archetype moves).
            ---------------------------------------------------------------------------
            id = "SetupCurveSpread",
            name = "Readiness bends the falloff (%)",
            help = "Extra falloff curvature applied to an UNPREPARED enemy, on top of " ..
                "FalloffCurve. 0 = off. 100 = a fully unprepared enemy decays " ..
                "quadratically while a ready one keeps the policy own curve.\n" ..
                "Leaves the weight at the plateau (100) and at the weapon range (0) " ..
                "untouched -- it cannot make a distant enemy vanish, only sink.\n" ..
                "Needs `SetupBias` on.",
            editor = "number",
            default = 0,
            min = 0,
            max = 100
        }, {
            id = "RequireLOS",
            name = "Ignorar tiles que ninguem enxerga",
            help = "Zera a ameaca quando o cache de LOS do motor diz que NENHUM inimigo " ..
                "ve este destino. O cache e agregado por destino (booleano \"alguem ve\"), " ..
                "nao por inimigo -- entao e um portao do tile inteiro, nao um peso por " ..
                "inimigo. Custo: uma consulta de tabela, zero raycast novo.",
            editor = "bool",
            default = true
        }, {
            ---------------------------------------------------------------------------
            ---- MEMORIA  (BUGFIX B52)
            ----
            ---- Sem isto, um inimigo que quebra a linha de visao vale ZERO neste
            ---- somatorio -- e o tile na frente da arma dele, que era o pior do mapa
            ---- no turno passado, fica limpo neste. A IA anda para dentro do arco de
            ---- tiro e o inimigo reaparece atirando. Nao le como cautela nem como peso
            ---- mal calibrado: le como a IA nao ter memoria de um segundo atras.
            ----
            ---- Ligado, o inimigo invisivel continua na conta a partir da ultima
            ---- posicao em que a EQUIPE dele o viu (RATOAI_LastSeenPos), com a ameaca
            ---- descontada por MemoryPct e envelhecida ate MemoryTurns.
            ----
            ---- Nao e cheat: a posicao vem de uma leitura que a propria equipe fez,
            ---- e envelhece. O cheat seria o que a policy faz com inimigo VISIVEL --
            ---- ler `enemy:GetPos()` -- aplicado a quem ninguem esta vendo.
            ---------------------------------------------------------------------------
            id = "MemoryStandin",
            name = "Lembrar da ultima posicao vista",
            help = "Inimigo que sumiu continua pesando, a partir de onde foi visto " ..
                "pela ultima vez, com desconto de confianca e prazo de validade." .. "\n" ..
                "A memoria e da EQUIPE, nao da unidade -- entao com Visibility Mode " ..
                "\"self\" o substituto ainda usa o que a equipe viu. E deliberado: " ..
                "saber onde o inimigo estava e coisa que se repassa pelo radio.",
            editor = "bool",
            default = true
        }, {
            id = "MemoryPct",
            name = "Confianca na memoria (%)",
            help = "Quanto vale a ameaca de um inimigo LEMBRADO, contra a de um " ..
                "visivel, no turno em que ele sumiu. Cai linearmente ate zero em " ..
                "MemoryTurns." .. "\n" ..
                "0 = usar const.RATOAI.ThreatMemoryPct (recomendado).",
            editor = "number",
            default = 0,
            min = 0,
            max = 100,
            no_edit = function(self)
                return not self.MemoryStandin
            end
        }, {
            id = "MemoryTurns",
            name = "Validade da memoria (turnos)",
            help = "Turnos ate a memoria valer zero. 1 = so o turno em que sumiu." .. "\n" ..
                "0 = usar const.RATOAI.ThreatMemoryTurns (recomendado).",
            editor = "number",
            default = 0,
            min = 0,
            max = 10,
            no_edit = function(self)
                return not self.MemoryStandin
            end
        }
    }
}

---- O rotulo NAO e cosmetico: `AIScoreDest` grava `policy:GetEditorView()` no
---- `score_details`, e a camada por policy do painel de debug SOMA entradas com o mesmo
---- rotulo. Duas instancias com alcances diferentes precisam de rotulos diferentes.
function AIPolicyThreatExposure:GetEditorView()
    local partes = {}
    if (self.RangeCapTiles or 0) > 0 then
        partes[#partes + 1] = string.format("teto %dt", self.RangeCapTiles)
    end
    if (self.FalloffCurve or 0) > 0 then
        partes[#partes + 1] = string.format("curva %d%%", self.FalloffCurve)
    end
    if self.StanceCancels then
        partes[#partes + 1] = "postura"
    end
    if self.SetupBias and (self.SetupCurveSpread or 0) > 0 then
        partes[#partes + 1] = string.format("preparo +%d%%", self.SetupCurveSpread)
    end
    if #partes == 0 then
        return "Threat Exposure"
    end
    return "Threat Exposure (" .. table.concat(partes, ", ") .. ")"
end

---- Saturacao efetiva. MaxThreat = 0 (default) usa a constante compartilhada, que e o
---- que mantem esta policy e a Seek Cover na MESMA normalizacao -- pre-requisito para o
---- cancelamento entre cobertura e exposicao. Ver o cabecalho de const.RATOAI.ThreatSaturation
---- em AIPOLICYPOS_CustomSeekCover.lua.
---------------------------------------------------------------------------------------------------
---- TETO DE UM INIMIGO SO  (BUGFIX B49)
----
---- Quanto vale, no maximo, UM inimigo maximamente ameacador. Era 100 implicitamente, e o
---- `SetupReadyPct = 115` quebrou isso sem ninguem notar: um inimigo passou a poder valer 115 e a
---- saturacao (100 x N) deixou de significar "N inimigos".
----
---- Medido na pratica com N = 3 e ready = 115, ANTES do conserto:
----     3 prontos       -> 345, clampado em 300 -> 100% da penalidade
----     3 neutros (100) -> 300                  -> 100% da penalidade   <-- IDENTICO
----     3 despreparados -> 225                  ->  75%
---- Ou seja, "pronto" e "neutro" eram indistinguiveis: o bonus so conseguia chegar ao teto mais
---- cedo, nunca registrar acima dele. `SetupCostly` carregava sinal em toda a faixa e
---- `SetupReady` virava headroom desperdicado.
----
---- O conserto NAO e cortar o bonus -- ele deve mesmo poder aumentar. E fazer o teto acompanhar:
---- se um inimigo pode valer 115, entao "penalidade cheia" passa a ser N x 115. O invariante volta
---- a ser exato e o bonus continua valendo, agora relativo a todo o resto:
----     3 prontos       -> 345 / 345 -> 100%
----     3 neutros       -> 300 / 345 ->  87%
----     3 despreparados -> 225 / 345 ->  65%
----
---- Deriva do `SetupReadyPct` em vez de virar knob novo, de proposito: dois numeros que precisam
---- concordar e um que vai dessincronizar. Mudar o bonus reescala o teto sozinho.
---------------------------------------------------------------------------------------------------
function AIPolicyThreatExposure:GetEnemyCeiling()
    local ceiling = 100
    if self.SetupBias and const.RATOAI.ThreatSetupBias ~= false then
        local ready = (self.SetupReadyPct or 0) > 0 and self.SetupReadyPct or
                          (const.RATOAI.ThreatSetupReady or 100)
        ceiling = Max(ceiling, ready)
    end
    return ceiling
end

---- Ameaca que equivale a penalidade cheia: N inimigos no teto de um so.
---- ATENCAO ao ler `const.RATOAI.ThreatSaturation`: medido no processo vivo (28/08) que ele e
---- **nil**. O ConstDef criado no editor registra `const.RATOAI_ThreatSaturation` (flat, com
---- underscore), nao a versao pontuada -- entao quem manda e sempre o `or 3` aqui embaixo, e
---- mexer naquele preset no editor nao tem efeito nenhum.
function AIPolicyThreatExposure:GetSaturation()
    local n = self.MaxThreat
    if not n or n <= 0 then
        n = const.RATOAI.ThreatSaturation or 3
    end
    return self:GetEnemyCeiling() * Max(1, n)
end

---- alcance do inimigo, em unidades de mundo
---- Referencia: AK47 = 24 tiles, rifles 30, snipers 36-45, SMG 14-18, escopeta 8.
---- O `or 0` ingenuo aqui era uma armadilha: WeaponRange nulo ou zero viraria alcance 0,
---- a rampa devolveria 0 e o inimigo sumiria da conta de ameaca sem aviso nenhum.
---- 2o retorno: se e arma de fogo. Quem cancela ameaca com cobertura precisa saber --
---- cobertura nao protege de corpo a corpo, entao o cancelamento nao pode valer para
---- quem vem no facao. Mesmo criterio que a AIPolicyCustomSeekCover usa para tirar
---- melee da media dela.
---- 3o retorno: se o teto mordeu. So serve ao overlay -- sem ele nao da para saber se
---- o "alcance" mostrado e o da arma ou o teto da policy.
function AIPolicyThreatExposure:GetEnemyRange(enemy)
    local melee = self.MeleeRange * const.SlabSizeX
    local range, is_firearm = melee, false
    local weapon = enemy:GetActiveWeapons()
    if weapon and IsKindOf(weapon, "Firearm") then
        local r = (weapon.WeaponRange or 0) * const.SlabSizeX
        range, is_firearm = r > 0 and r or melee, true
    end
    ---- teto: reescala a rampa inteira, nao so corta a ponta. Vale tambem para melee --
    ---- um teto menor que MeleeRange encolhe o alcance do facao junto, que e o que
    ---- "nada alem de X tiles me ameaca" quer dizer.
    local cap = (self.RangeCapTiles or 0) * const.SlabSizeX
    if cap > 0 and range > cap then
        return cap, is_firearm, true
    end
    return range, is_firearm
end

---- Confianca efetiva na cobertura contra UM inimigo, 0..100.
---- Sem CoverNearTiles e o CoverTrust cru, exatamente como sempre foi -- por isso o
---- default 0 nao muda nenhum preset existente. Com ele, interpola linearmente de
---- CoverTrustNear (colado) ate CoverTrust (em CoverNearTiles ou mais longe).
---- Ver o cabecalho da property CoverNearTiles para o porque.
function AIPolicyThreatExposure:GetCoverTrust(dist)
    local trust = Clamp(self.CoverTrust or 100, 0, 100)
    local near = (self.CoverNearTiles or 0) * const.SlabSizeX
    if near <= 0 or not dist or dist >= near then
        return trust
    end
    local near_trust = Clamp(self.CoverTrustNear or 0, 0, 100)
    ---- (trust - near_trust) pode ser negativo se alguem inverter os dois no editor;
    ---- o Clamp final segura isso sem virar buraco silencioso.
    return Clamp(near_trust + MulDivRound(trust - near_trust, dist, near), 0, 100)
end

---------------------------------------------------------------------------------------------------
---- RAMPA DE POSTURA
----
---- Parte da mitigacao por postura que NAO depende do inimigo: quanto agachar/deitar
---- neste destino chega a valer no alcance cheio, e onde a rampa satura. Constante para
---- o destino inteiro, entao o EvalDest resolve isto UMA vez e o laco por inimigo so faz
---- a interpolacao linear -- os ResolveValue ficam fora do caminho quente.
----
---- A mitigacao e expressa na MESMA moeda da cobertura ("% de uma cobertura cheia"),
---- dividindo pelo mesmo `Cover` que o GetUncovered usa. E o que permite as duas se
---- substituirem sem trocar de escala.
----
---- Retorna: mitigacao no alcance cheio (0..100), distancia de saturacao, distancia
---- minima abaixo da qual o jogo nao paga nada. 0 quando nao ha o que aplicar.
---------------------------------------------------------------------------------------------------
function AIPolicyThreatExposure:GetStanceRamp(stance)
    if not self.StanceCancels or (stance ~= "Crouch" and stance ~= "Prone") then
        return 0
    end
    local preset = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover
    local full = preset:ResolveValue("Cover")
    if not full or full == 0 then
        return 0
    end

    local pen, max_tiles
    if stance == "Prone" then
        pen, max_tiles = preset:ResolveValue("PronePenalty"), self.ProneMaxTiles or 24
    else
        pen, max_tiles = preset:ResolveValue("CrouchPenalty"), self.CrouchMaxTiles or 26
    end
    if not pen or pen == 0 or max_tiles <= 0 then
        return 0
    end

    ---- ambos negativos (penalidades de CTH), entao a razao sai positiva
    local mitig = Clamp(MulDivRound(pen, 100, full), 0, 100)
    mitig = MulDivRound(mitig, Clamp(self.StanceTrust or 100, 0, 100), 100)

    ---- 1.5 tiles: o mesmo corte do CTH_cover_prone.lua. MulDivRound em vez de
    ---- `1.5 * SlabSizeX` porque literal decimal vira float e float vaza pro NetUpdateHash.
    return mitig, max_tiles * const.SlabSizeX, MulDivRound(3, const.SlabSizeX, 2)
end

---- Fracao da ameaca deste inimigo que a cobertura NAO neutraliza, 0..100.
---- Usa RATOAI_CoverCTH -- a mesma funcao da AIPolicyCustomSeekCover, de proposito: as
---- duas nao podem divergir na leitura de cobertura, e esta e a unica forma de garantir
---- isso sem duplicar a conta.
----
---- COBERTURA TEM PRIORIDADE, POSTURA E O FALLBACK. `RATOAI_CoverCTH` devolve
---- `use = false` exatamente no caso em que o jogo NAO aplica cobertura (o
---- `value < exposed_value` la dentro) -- ou seja, o ponto em que o
---- RangeAttackTargetStanceCover do GBO3 cai no ramo de Crouch. Encaixar a postura ai e
---- reproduzir a prioridade do jogo, nao inventar uma.
----
---- 2o retorno: a confianca efetiva usada (so overlay). 3o: qual fonte abateu --
---- "cobertura", "postura" ou nil.
function AIPolicyThreatExposure:GetUncovered(att_pos, target_pos, stance, is_firearm, dist,
                                             stance_mitig, stance_max_d, stance_min_d, full)
    ---- nem cobertura nem postura param corpo a corpo: o RangeAttackTargetStanceCover
    ---- inteiro exige `IsKindOf(weapon1, "Firearm")`. Ameaca cheia, sem desconto.
    if not is_firearm then
        return 100
    end

    dist = dist or att_pos:Dist(target_pos)

    ---- `full` chega pronto do DestParams: e constante, e resolve-lo aqui custava um
    ---- ResolveValue por inimigo POR destino. O fallback so serve a quem chamar de fora.
    full = full or
               Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover:ResolveValue("Cover")
    local use, value = RATOAI_CoverCTH(att_pos, target_pos, stance)
    if use and full and full ~= 0 then
        local trust = self:GetCoverTrust(dist)
        local cover = Clamp(MulDivRound(value or 0, 100, full), 0, 100)
        cover = MulDivRound(cover, trust, 100)
        return 100 - cover, trust, "cobertura"
    end

    ---- sem cobertura util: a postura assume. `stance_mitig` chega pronto do EvalDest;
    ---- o fallback existe so para quem chamar este metodo de fora.
    if not stance_mitig then
        stance_mitig, stance_max_d, stance_min_d = self:GetStanceRamp(stance)
    end
    if not stance_mitig or stance_mitig <= 0 or dist < (stance_min_d or 0) then
        return 100
    end

    ---- linear ate a saturacao, exatamente como o GBO3: perto vale pouco, longe vale tudo
    local mitig = MulDivRound(stance_mitig, Min(dist, stance_max_d), stance_max_d)
    return 100 - Clamp(mitig, 0, 100), nil, "postura"
end

function RATOAI_SetupParams(enemy, context)
    local cache = context and context.__ratoai_setup
    if cache then
        local hit = cache[enemy]
        if hit ~= nil then
            return hit
        end
    elseif context then
        cache = {}
        context.__ratoai_setup = cache
    end

    local params = false
    local weapon = enemy:GetActiveWeapons()
    if weapon and IsKindOf(weapon, "Firearm") then
        local ap_stance = GetWeapon_StanceAP(enemy, weapon)
        local cap = ap_stance + Get_AimCost(enemy)
        if cap > 0 then
            local ow = g_Overwatch[enemy]
            params = {
                ---- mesmo teste de "ja preparado" do GetShootingStanceAP:13-15
                stance = enemy:HasStatusEffect("shooting_stance") or
                    enemy:HasStatusEffect("ManningEmplacement") or
                    enemy:HasStatusEffect("StationedMachineGun") or false,
                free_rot = (ow and ow.permanent) or false,
                half = (weapon.OverwatchAngle or 0) / 2,
                ap_stance = ap_stance,
                cap = cap
            }
        end
    end

    if cache then
        cache[enemy] = params
    end
    return params
end

---------------------------------------------------------------------------------------------------
---- Multiplicador da ameaca deste inimigo sobre ESTE tile, em %. 100 = sem efeito.
----
---- Reproduz o ramo do `GetShootingStanceAP` que se aplica ao inimigo e normaliza pelo teto do
---- proprio jogo. `AngleToPoint` e a mesma leitura do `GetShootingAngleDiff` do GBO3 -- conferido
---- ao vivo que bate exatamente com `AngleDiff(CalcOrientation(pos, alvo), GetOrientationAngle())`.
---------------------------------------------------------------------------------------------------
function RATOAI_SetupFactor(enemy, context, target_pos, ready_pct, costly_pct)
    local p = RATOAI_SetupParams(enemy, context)
    if not p then
        return 100
    end

    local cost
    if p.free_rot then
        cost = 0 ---- emplacamento: gira de graca, esta sempre pronto
    elseif p.stance then
        if p.half <= 0 then
            return 100 ---- arma sem cone declarado: nao da para medir o angulo
        end
        ---- MESMA conta do ShootingConeAngle: meios-cones INTEIROS fora do eixo
        local widths = abs(enemy:AngleToPoint(target_pos)) / p.half
        cost = Min(widths * const.Scale.AP, p.cap)
    else
        ---- fora de stance: o tiro de qualidade custa preparar do zero. O hipfire nao entra
        ---- porque ele nao custa AP nenhum -- o preco dele e CTH, e isso ja aparece noutro lugar.
        cost = Min(p.ap_stance, p.cap)
    end

    ---- 2o retorno: prontidao normalizada em 0..100 (100 = atira bem aqui de graca).
    ---- Sai de cost/cap e NAO do fator devolvido, para o `SetupCurveSpread` ficar
    ---- independente dos knobs de amplitude. nil = nao ha o que pesar (os dois returns
    ---- antecipados acima), e e por isso que o chamador pula a modulacao da curva.
    local ready_t = 100 - MulDivRound(100, cost, p.cap)
    if cost <= 0 then
        return ready_pct, ready_t
    end
    if cost >= p.cap then
        return costly_pct, ready_t
    end
    return ready_pct - MulDivRound(ready_pct - costly_pct, cost, p.cap), ready_t
end

function RATOAI_ThreatEnemyFactor(enemy, context)
    local mods = const.RATOAI.ThreatEffectMods
    if not mods or next(mods) == nil then
        return 100
    end

    ---- Status effect nao muda entre destinos dentro da mesma avaliacao, e esta funcao
    ---- roda uma vez POR DESTINO por inimigo. Sem cache seria um HasStatusEffect por
    ---- efeito registrado, por inimigo, por destino -- milhares de consultas por turno.
    local cache = context and context.__ratoai_threat_factor
    if cache then
        local hit = cache[enemy]
        if hit then
            return hit
        end
    elseif context then
        cache = {}
        context.__ratoai_threat_factor = cache
    end

    local factor = 100
    for effect_id, pct in pairs(mods) do
        if enemy:HasStatusEffect(effect_id) then
            factor = MulDivRound(factor, Max(0, pct), 100)
        end
    end

    if cache then
        cache[enemy] = factor
    end
    return factor
end

---- Chave do diagnostico; o cabecalho completo esta junto do EvalDest, la embaixo.
if const.RATOAI.ThreatDebug == nil then
    const.RATOAI.ThreatDebug = false
end

local function tiles(d)
    return d and (MulDivRound(d, 1, const.SlabSizeX)) or "?"
end

---------------------------------------------------------------------------------------------------
---- LOS POR INIMIGO  (BUGFIX B50)
----
---- `g_AIDestEnemyLOSCache` responde "ALGUEM ve este destino" -- agregado sobre a equipe
---- inteira, e so para os destinos que o `AIUpdateDestLosCache` chegou a processar (ele
---- para cedo e vai removendo da lista os que ja foram vistos).
----
---- Medido em combate real, Rocketeer:23 x Smiley_FS, 2360 destinos:
----     Smiley ENXERGA                                     69
----     cache `nil` (nunca checado, o portao deixava passar) 2215
----     cache `false`                                       10
----     sem LOS do Smiley E sem cobertura -> ameaca CHEIA  1789
----
---- Ou seja: o portao antigo cobria 10 destinos de 2360. Cobertura tambem nao substitui
---- LOS -- `GetCoverPercentage` so acha cobertura ADJACENTE ao tile, entao um tile escuro
---- porque tem um predio inteiro na frente nao tem objeto de cobertura ao lado nenhum,
---- devolve nil, e o inimigo entra com a rampa inteira. Sao duas perguntas diferentes:
---- "tem parede no meu pe" e "ele consegue me ver".
----
---- CUSTO. Uma chamada BATELADA de CheckLOS por inimigo, sobre `context.destinations` --
---- a lista que esta policy realmente pontua. Medido no processo vivo: 17 ms para 85
---- destinos x 7 inimigos. A mesma conta sobre `all_destinations` (2360) custa 435 ms, e
---- e por isso que a batelada NAO e sobre ela: as 17 instancias em items.lua estao todas
---- em `EndTurnPolicies`, que roda por `context.destinations`; nenhuma em OptLocPolicies.
---- Se algum dia uma entrar la, esta funcao passa a pagar o preco alto -- meca antes.
----
---- `nil` continua significando "nao da para saber" e NAO bloqueia, mesma escolha
---- conservadora do portao antigo. A diferenca e que agora quase nunca e nil.
---------------------------------------------------------------------------------------------------
---- BUGFIX (B52): `ppos_override` e a posicao LEMBRADA de um inimigo invisivel. O cache por
---- inimigo continua valendo sem chave nova porque a escolha entre "posicao atual" e "posicao
---- lembrada" e ESTAVEL dentro do turno: ou o inimigo esta visivel a chamada inteira, ou nao esta.
function RATOAI_ThreatEnemyLOS(context, enemy, dest, ppos_override)
    if not context or not dest then
        return nil
    end
    local cache = context.__ratoai_enemy_los
    if not cache then
        cache = {}
        context.__ratoai_enemy_los = cache
    end

    local ppos = ppos_override or
                     (context.enemy_pack_pos_stance and context.enemy_pack_pos_stance[enemy])
    local per = cache[enemy]
    if per == nil then
        per = false
        local dests = context.destinations
        if ppos and dests and #dests > 0 then
            local srcs, tgts = {}, {}
            for i = 1, #dests do
                srcs[i] = dests[i]
                tgts[i] = ppos
            end
            local _, data = CheckLOS(tgts, srcs, enemy:GetSightRadius())
            if data then
                per = {}
                for i = 1, #dests do
                    per[dests[i]] = not not data[i]
                end
            end
        end
        cache[enemy] = per
    end

    if not per then
        return nil
    end
    local hit = per[dest]
    if hit ~= nil then
        return hit
    end

    ---- destino fora da batelada -- o painel de debug avalia tiles avulsos. Uma raia so,
    ---- memoizada na mesma tabela, entao um rollover repetido nao paga de novo.
    if not ppos then
        return nil
    end
    local _, data = CheckLOS({ppos}, {dest}, enemy:GetSightRadius())
    hit = not not (data and data[1])
    per[dest] = hit
    return hit
end

---------------------------------------------------------------------------------------------------
---- MEMORIA VELHA DEMAIS PARA ACREDITAR  (BUGFIX B52)
----
---- Lembrar de onde o inimigo estava so ajuda enquanto nao da para conferir. Se a unidade ENXERGA
---- o tile lembrado e nao ve ninguem la, a memoria esta objetivamente errada -- e continuar
---- pesando por ela faz a IA se esconder de um fantasma que ela esta olhando.
----
---- E o mesmo criterio que o motor aplica ao `last_known_enemy_pos`: chegou a ter linha de visao
---- para o ponto, apaga (CombatAI.lua:2489-2495). Aqui nao se apaga o registro -- outra unidade da
---- equipe, de outro angulo, pode nao ter esse alcance -- so nao se usa nesta avaliacao.
----
---- Uma unica raia por inimigo por turno, memoizada no context: `dest` nao entra, porque a
---- pergunta e sobre a unidade que decide, nao sobre o tile que ela avalia.
---------------------------------------------------------------------------------------------------
function RATOAI_ThreatMemoryStale(context, enemy, ppos)
    local unit = context and context.unit
    if not unit or not ppos then
        return false
    end
    local cache = context.__ratoai_mem_stale
    if not cache then
        cache = {}
        context.__ratoai_mem_stale = cache
    end
    local hit = cache[enemy]
    if hit ~= nil then
        return hit
    end
    local pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(ppos))
    hit = IsValidPos(pos) and CheckLOS(pos, unit, unit:GetSightRadius()) and true or false
    cache[enemy] = hit
    return hit
end

---------------------------------------------------------------------------------------------------
---- Confianca nesta memoria, em %. 0 = nao usar (nunca vi, ou a memoria venceu).
---- Linear: cheia no turno em que sumiu, zero em `turns`.
---------------------------------------------------------------------------------------------------
function AIPolicyThreatExposure:MemoryConfidence(age)
    if not age then
        return 0
    end
    local turns = (self.MemoryTurns or 0) > 0 and self.MemoryTurns or
                      (const.RATOAI.ThreatMemoryTurns or 0)
    if turns <= 0 or age >= turns then
        return 0
    end
    local base = (self.MemoryPct or 0) > 0 and self.MemoryPct or
                     (const.RATOAI.ThreatMemoryPct or 0)
    return MulDivRound(base, turns - age, turns)
end

---------------------------------------------------------------------------------------------------
---- O ATALHO AGREGADO AINDA VALE?  (BUGFIX B52)
----
---- O `EvalDest` comeca com um atalho barato: se `g_AIDestEnemyLOSCache[dest]` e `false`, NINGUEM
---- ve este tile, entao nao ha o que somar. Ele e do motor e e calculado sobre as posicoes REAIS
---- dos inimigos -- inclusive as que esta equipe nao esta enxergando.
----
---- Com a memoria ligada isso deixa de ser um atalho e vira uma contradicao: a policy passa a
---- afirmar "de onde eu vi ele por ultimo, ele alcanca este tile" e o atalho responde "nao, porque
---- de onde ele esta AGORA ele nao alcanca" -- que e precisamente a informacao que a IA nao tem.
---- Na pratica o atalho apagaria o recurso justamente no caso que ele existe para cobrir: o
---- inimigo que saiu de vista e por isso parou de aparecer no cache.
----
---- Entao o atalho so vale quando nao ha memoria nenhuma em jogo neste turno. Uma passada pelos
---- inimigos, memoizada por (context, instancia da policy) -- por instancia porque MemoryTurns e
---- MemoryPct sao por preset e mudam a resposta.
---------------------------------------------------------------------------------------------------
function AIPolicyThreatExposure:HasMemoryStandin(context)
    if not self.MemoryStandin then
        return false
    end
    local cache = context.__ratoai_mem_any
    if not cache then
        cache = {}
        context.__ratoai_mem_any = cache
    end
    local hit = cache[self]
    if hit ~= nil then
        return hit
    end

    hit = false
    for _, enemy in ipairs(context.enemies or empty_table) do
        if IsValid(enemy) and not (enemy:IsDead() or enemy:IsDowned()) and
            not self:SeesEnemy(context, enemy) then
            local ppos, age = RATOAI_LastSeenPos(context.unit, enemy)
            if ppos and self:MemoryConfidence(age) > 0 and
                not RATOAI_ThreatMemoryStale(context, enemy, ppos) then
                hit = true
                break
            end
        end
    end
    cache[self] = hit
    return hit
end

---------------------------------------------------------------------------------------------------
---- NUCLEO COMPARTILHADO -- constantes do destino + contribuicao de um inimigo
----
---- O `EvalDest` daqui e o `Decompose` do painel (Rato Dev/RATODBG_AIDebugUI.lua) precisam
---- da MESMA conta, e enquanto cada um resolvia a sua eles divergiam em silencio a cada
---- knob novo. Ja tinha acontecido tres vezes -- `FalloffCurve`, `ThreatEffectMods` e o
---- custo de preparo, cada um patchado no painel depois do fato -- e o `SetupCurveSpread`
---- foi a quarta. Agora ha um caminho de calculo so; o painel consome estes dois metodos.
---------------------------------------------------------------------------------------------------
function AIPolicyThreatExposure:SeesEnemy(context, enemy)
    local mode = self.visibility_mode
    if mode == "self" then
        return (context.enemy_visible and context.enemy_visible[enemy]) and true or false
    elseif mode == "team" then
        return (context.enemy_visible_by_team and context.enemy_visible_by_team[enemy]) and true or
                   false
    end
    return true
end

---- Constantes do destino: nada aqui depende do inimigo, entao o laco por inimigo so consome.
function AIPolicyThreatExposure:DestParams(dest)
    local _, _, _, stance_idx = stance_pos_unpack(dest)
    local p = {
        ---- STANCE do proprio dest: e a que a unidade adota ao chegar (AIBehavior:EndMovement).
        ---- So importa quando cobertura ou postura entram na conta -- GetCoverPercentage zera
        ---- cobertura BAIXA para quem esta de pe (Cover.lua:283-285).
        stance = StancesList[stance_idx],
        cancels = self.CoverCancels,
        plateau = (self.PlateauTiles or 0) * const.SlabSizeX,
        near = (self.CoverNearTiles or 0) * const.SlabSizeX,
        curve = Clamp(self.FalloffCurve or 0, 0, 100),
        ceiling = self:GetEnemyCeiling(),
        ---- hoisted: era um ResolveValue por inimigo POR destino, dentro do GetUncovered,
        ---- num arquivo cujo proprio comentario manda manter ResolveValue fora do laco quente
        full = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover:ResolveValue(
            "Cover")
    }

    ---- so vale com CoverCancels ligado -- desligado, esta policy e a classica (ameaca crua)
    ---- e quem credita protecao e a AIPolicyCustomSeekCover, por fora. Abater aqui por postura
    ---- reintroduziria o desalinhamento de clamp que o CoverCancels existe para resolver.
    if p.cancels then
        p.stance_mitig, p.stance_max_d, p.stance_min_d = self:GetStanceRamp(p.stance)
    end

    local setup = self.SetupBias and (const.RATOAI.ThreatSetupBias ~= false)
    p.spread = setup and Clamp(self.SetupCurveSpread or 0, 0, 100) or 0
    if setup then
        p.ready_pct = (self.SetupReadyPct or 0) > 0 and self.SetupReadyPct or
                          (const.RATOAI.ThreatSetupReady or 100)
        p.costly_pct = (self.SetupCostlyPct or 0) > 0 and self.SetupCostlyPct or
                           (const.RATOAI.ThreatSetupCostly or 100)
        ---- os dois em 100 nao mudam nada: pula o trabalho por inimigo. O `spread` entra no
        ---- teste porque e o mesmo termo, e funciona com a amplitude neutra (100/100) -- que
        ---- e justamente o pareamento recomendado.
        if p.ready_pct == 100 and p.costly_pct == 100 and p.spread <= 0 then
            setup = false
        end
    end
    p.setup = setup
    return p
end

---------------------------------------------------------------------------------------------------
---- Contribuicao de UM inimigo neste destino. Devolve `bruta, liquida`:
----   bruta   -- rampa ja pesada por status effect e preparo, SEM cobertura
----   liquida -- a mesma, depois do abatimento por cobertura/postura
---- A diferenca entre as duas e exatamente o que a camada "Cobertura CANCELOU" mostra.
----
---- O clamp do teto cai sobre a BRUTA e a liquida sai dela ja clampada. Assim `ceiling`
---- continua querendo dizer "o maximo que UM inimigo vale" (BUGFIX B49) e o abatimento por
---- cobertura nunca precisa competir com o clamp -- que era a fonte do caso perverso que o
---- proprio CoverCancels existe para matar.
----
---- `out` (opcional, REUTILIZAVEL entre iteracoes) recebe os detalhes para o trace e para o
---- painel. Passar a mesma tabela no laco inteiro mantem o custo em zero alocacoes.
---------------------------------------------------------------------------------------------------
function AIPolicyThreatExposure:EnemyContribution(context, enemy, dest, target_pos, p, out)
    if out then
        out.skip, out.los, out.fonte, out.trust = nil, nil, nil, nil
        out.ready_t, out.capped, out.d, out.range = nil, nil, nil, nil
        out.ramp, out.uncovered, out.face, out.fator, out.curve_e = nil, nil, nil, nil, nil
        out.mem_pct, out.mem_age = nil, nil
    end

    ---- mesmo criterio de "nao ameaca" da Seek Cover: abatido e morto ficam fora.
    ---- SUBIU (B52): antes vinha depois do teste de visibilidade, mas morto nao ameaca nem de
    ---- memoria -- e este teste e mais barato que consultar a memoria e conferir a validade dela.
    if not (IsValid(enemy) and not (enemy:IsDead() or enemy:IsDowned())) then
        if out then
            out.skip = "abatido/morto"
        end
        return 0, 0
    end

    -----------------------------------------------------------------------------------------------
    ---- ONDE ELE ESTA -- ou, quando nao da para ver, onde ele estava  (BUGFIX B52)
    ----
    ---- `mem_pct` fica nil para inimigo VISIVEL: e o que distingue os dois regimes daqui para
    ---- baixo, e nao um `100` que se confundiria com "lembrado, mas com confianca cheia".
    -----------------------------------------------------------------------------------------------
    local mem_pct, mem_age
    local mem_ppos
    if not self:SeesEnemy(context, enemy) then
        if not self.MemoryStandin then
            if out then
                out.skip = "nao visivel, modo " .. tostring(self.visibility_mode)
            end
            return 0, 0
        end

        local ppos, age = RATOAI_LastSeenPos(context.unit, enemy)
        mem_pct = ppos and self:MemoryConfidence(age) or 0
        if mem_pct <= 0 then
            if out then
                out.skip = ppos and string.format("memoria vencida (%d turnos)", age or -1) or
                               "nao visivel e nunca visto"
            end
            return 0, 0
        end

        if RATOAI_ThreatMemoryStale(context, enemy, ppos) then
            if out then
                out.skip = "memoria desmentida (enxergo o tile e ele nao esta la)"
            end
            return 0, 0
        end

        mem_ppos, mem_age = ppos, age
    end
    ---- DEBUG (D8): filtro de isolamento do painel. Sempre true em partida normal.
    if not RATOAI_ThreatCounts(enemy) then
        if out then
            out.skip = "FILTRO ThreatOnly"
        end
        return 0, 0
    end

    ---- BUGFIX (B52): a posicao LEMBRADA quando nao ha visao. Ler `enemy:GetPos()` de um inimigo
    ---- que ninguem esta vendo era a unica parte desta policy que a IA nao tinha como saber.
    local att_pos = RATOAI_ValidatePosZ(mem_ppos and RATOAI_UnpackPos(mem_ppos) or enemy:GetPos())
    if not IsValidPos(att_pos) then
        if out then
            out.skip = "posicao invalida"
        end
        return 0, 0
    end

    ---- BUGFIX (B50): quem nao me ve nao me ameaca. Ver o cabecalho de RATOAI_ThreatEnemyLOS.
    if self.RequireLOS and RATOAI_ThreatEnemyLOS(context, enemy, dest, mem_ppos) == false then
        if out then
            out.skip, out.los = "sem LOS", false
        end
        return 0, 0
    end

    local d = att_pos:Dist(target_pos)
    local range, is_firearm, capped = self:GetEnemyRange(enemy)

    ---- ANTES da rampa: a prontidao dobra a queda, entao e entrada da rampa e nao so
    ---- multiplicador da saida dela. Ver a property SetupCurveSpread.
    ---- BUGFIX (B52): sem preparo para inimigo LEMBRADO. O termo pergunta "ele esta em stance e
    ---- ja apontado para este tile?", e stance e angulo sao estado ATUAL -- exatamente o que se
    ---- perdeu junto com a visao. A posicao antiga a IA leu; a postura de agora, nao.
    local face, ready_t, curve_e = 100, nil, p.curve
    if p.setup and not mem_pct then
        face, ready_t = RATOAI_SetupFactor(enemy, context, target_pos, p.ready_pct, p.costly_pct)
        if p.spread > 0 and ready_t then
            curve_e = Min(100, p.curve + MulDivRound(p.spread, 100 - ready_t, 100))
        end
    end

    local ramp = RATOAI_ThreatRamp(d, range, p.plateau, curve_e)

    ---- `uncovered` fica 100 no modo classico: a policy nao olha cobertura e a contribuicao
    ---- e a rampa crua, exatamente como antes do CoverCancels existir.
    local uncovered, trust, fonte = 100, nil, nil
    if p.cancels and ramp > 0 then
        uncovered, trust, fonte = self:GetUncovered(att_pos, target_pos, p.stance, is_firearm, d,
                                                    p.stance_mitig, p.stance_max_d, p.stance_min_d,
                                                    p.full)
    end

    ---- status effect e custo de preparo escalam a capacidade DESTE inimigo, e por isso
    ---- entram na BRUTA -- os dois lados. Aplicar so na liquida jogaria o efeito deles
    ---- dentro de "cancelada", que quer dizer "o que a COBERTURA tirou" e passaria a mentir.
    local fator = RATOAI_ThreatEnemyFactor(enemy, context)
    local mods = fator
    if face ~= 100 then
        mods = MulDivRound(mods, face, 100)
    end
    ---- BUGFIX (B52): a confianca na memoria entra junto com os outros multiplicadores da
    ---- CAPACIDADE deste inimigo, e por isso na BRUTA -- "posso estar errado sobre ele" e do
    ---- mesmo tipo que "ele esta suprimido", e nao algo que a cobertura deste tile cancelou.
    if mem_pct then
        mods = MulDivRound(mods, mem_pct, 100)
    end

    local bruta = (mods == 100) and ramp or MulDivRound(ramp, mods, 100)
    if bruta > p.ceiling then
        bruta = p.ceiling
    end
    local liquida = (uncovered == 100) and bruta or MulDivRound(bruta, uncovered, 100)

    if out then
        out.d, out.range, out.capped = d, range, capped
        out.ramp, out.uncovered, out.trust, out.fonte = ramp, uncovered, trust, fonte
        out.face, out.ready_t, out.curve_e, out.fator = face, ready_t, curve_e, fator
        out.is_firearm = is_firearm
        out.mem_pct, out.mem_age = mem_pct, mem_age
    end
    return bruta, liquida
end

---- Normalizacao final: `saturation` inimigos no teto == penalidade cheia. Sem o teto o score
---- cresceria com o numero de inimigos e esmagaria as outras policies -- que e exatamente o
---- erro que o ScalePerDistance antigo cometia. Metodo porque o painel precisa da MESMA linha.
function AIPolicyThreatExposure:Normalize(soma)
    if not soma or soma <= 0 then
        return 0
    end
    local sat = self:GetSaturation()
    return MulDivRound(self.Penalty, Min(soma, sat), sat)
end

---------------------------------------------------------------------------------------------------
---- DIAGNOSTICO
----
---- `const.RATOAI.ThreatDebug = true` no console faz cada destino guardar o passo a passo em
---- context.dest_threat_exposure_debug[dest], que o DEBUG.lua mostra no rollover do voxel.
---- Desligado, custa uma leitura de tabela por destino e nada mais. Ligue, passe o mouse no
---- tile, leia, desligue -- constroi string para TODO destino.
---------------------------------------------------------------------------------------------------
function AIPolicyThreatExposure:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end

    local trace = const.RATOAI.ThreatDebug and {} or nil

    ---- Portao de LOS agregado, do motor. Continua valendo como atalho BARATO: se ele diz que
    ---- NINGUEM ve o tile, nao ha o que somar e nem vale abrir o laco. Distingue `false` (o
    ---- motor CHECOU e ninguem ve) de `nil` (nunca checou), e nil segue passando -- o portao
    ---- que de fato resolve o caso agora e o por inimigo, dentro do EnemyContribution.
    ---- BUGFIX (B52): `not self:HasMemoryStandin(context)` -- ver o cabecalho daquele metodo.
    ---- A ordem importa: `HasMemoryStandin` custa uma passada pelos inimigos UMA vez por turno,
    ---- e o teste de tabela a esquerda continua descartando a maioria dos destinos de graca.
    if self.RequireLOS and g_AIDestEnemyLOSCache and g_AIDestEnemyLOSCache[dest] == false and
        not self:HasMemoryStandin(context) then
        return 0
    end

    local target_pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(dest))
    if not IsValidPos(target_pos) then
        return 0
    end

    local p = self:DestParams(dest)
    local out = trace and {} or nil
    local threat = 0

    for _, enemy in ipairs(context.enemies or empty_table) do
        local bruta, liquida = self:EnemyContribution(context, enemy, dest, target_pos, p, out)
        threat = threat + liquida

        if trace then
            local id = tostring(enemy.session_id)
            if out.skip then
                trace[#trace + 1] = string.format("  %s: PULADO (%s)", id, out.skip)
            elseif not p.cancels then
                trace[#trace + 1] = string.format("  %s: %st / alcance %st%s -> peso %d%s", id,
                                                  tostring(tiles(out.d)),
                                                  tostring(tiles(out.range)),
                                                  out.capped and " (teto)" or "", out.ramp,
                                                  out.mem_pct and
                                                      string.format(
                                                          " | LEMBRADO ha %d turno(s), %d%%",
                                                          out.mem_age or 0, out.mem_pct) or "")
            else
                local nota = ""
                ---- BUGFIX (B52): primeiro de todos, porque muda o que a LINHA INTEIRA significa
                ---- -- distancia e alcance passam a ser medidos de um ponto que talvez ja nao
                ---- tenha ninguem. Sem isto o overlay mostra uma ameaca sem fonte visivel e quem
                ---- le procura o bug na rampa.
                if out.mem_pct then
                    nota = string.format(" | LEMBRADO: visto ha %d turno(s), confianca %d%%",
                                         out.mem_age or 0, out.mem_pct)
                end
                ---- so anota quando o raio realmente mordeu -- senao poluiria toda linha do
                ---- overlay com um numero que nunca muda
                if out.trust and p.near > 0 and out.d < p.near then
                    nota = string.format(" | COLADO: confianca %d%%", out.trust)
                end
                if out.fator ~= 100 then
                    nota = nota .. string.format(" | status: ameaca x%d%%", out.fator)
                end
                if out.face ~= 100 or out.curve_e ~= p.curve then
                    local sp = RATOAI_SetupParams(enemy, context)
                    local como
                    if not sp then
                        como = "?"
                    elseif sp.free_rot then
                        como = "emplacado (gira gratis)"
                    elseif sp.stance then
                        como = string.format("stance, %dg fora do arco de %dg",
                                             abs(enemy:AngleToPoint(target_pos)) // 60,
                                             sp.half // 60)
                    else
                        como = string.format("FORA de stance (entrar custa %d)", sp.ap_stance)
                    end
                    nota = nota ..
                               string.format(" | PREPARO: %s, teto %s -> x%d%%", como,
                                             sp and tostring(sp.cap) or "?", out.face)
                    if out.curve_e ~= p.curve then
                        nota = nota .. string.format(" (pronto %d%% -> curva %d%%)",
                                                     out.ready_t or 0, out.curve_e)
                    end
                end
                trace[#trace + 1] = string.format(
                                        "  %s: %st / alcance %st%s -> peso %d | exposto %d%% (%s)" ..
                                            " -> bruta %d, liquida %d%s", id,
                                        tostring(tiles(out.d)), tostring(tiles(out.range)),
                                        out.capped and " (teto)" or "", out.ramp, out.uncovered,
                                        tostring(out.fonte or "nada"), bruta, liquida, nota)
            end
        end
    end

    if trace then
        local saturation = self:GetSaturation()
        local ceiling = p.ceiling

        -------------------------------------------------------------------------------------
        ---- LINHA DE ESCALA -- traduz a normalizacao para pontos de score.
        ----
        ---- O painel mostrava `saturacao 345 | Penalty -100 | Weight 100` e deixava a divisao
        ---- por conta do leitor. Ninguem faz essa conta de cabeca no meio de um turno, e o
        ---- resultado e a saturacao parecer arbitraria. Aqui ela vira o que se quer saber:
        ---- quanto vale UM inimigo, e onde e o piso.
        -------------------------------------------------------------------------------------
        local w = self.Weight or 100
        local piso = MulDivRound(self.Penalty, w, 100)
        local por_inimigo = MulDivRound(MulDivRound(self.Penalty, ceiling, saturation), w, 100)
        local n_inim = MulDivRound(saturation, 1, Max(1, ceiling))

        local escala = string.format(
                           "ESCALA: 1 inimigo no maximo = %d  |  piso da policy = %d  |  " ..
                               "satura em %d inimigos\n" ..
                               "  Penalty %d x Weight %d%%, teto por inimigo %d, saturacao %d %s",
                           por_inimigo, piso, n_inim, self.Penalty, w, ceiling, saturation,
                           (not self.MaxThreat or self.MaxThreat <= 0) and
                               "(MaxThreat compartilhado)" or "(MaxThreat proprio)")

        local modo = p.cancels and
                         string.format("cobertura CANCELA (confianca %d%%%s)",
                                       Clamp(self.CoverTrust or 100, 0, 100), (p.near > 0) and
                                           string.format(", caindo a %d%% dentro de %st",
                                                         Clamp(self.CoverTrustNear or 0, 0, 100),
                                                         tostring(tiles(p.near))) or "") or
                         "classico (so ameaca)"

        local extras = tostring(tiles(p.plateau)) .. "t" ..
                           ((p.stance_mitig or 0) > 0 and
                               string.format(" | postura %s abate ate %d%% em %st",
                                             tostring(p.stance), p.stance_mitig,
                                             tostring(tiles(p.stance_max_d))) or "") ..
                           ((self.RangeCapTiles or 0) > 0 and
                               string.format(" | teto %dt", self.RangeCapTiles) or "") ..
                           (p.curve > 0 and string.format(" | curva %d%%", p.curve) or "") ..
                           (p.spread > 0 and
                               string.format(" | preparo curva +%d%%", p.spread) or "") ..
                           (self.RequireLOS and " | LOS por inimigo" or "")

        local head = escala .. "\n" ..
                         string.format("inimigos em context.enemies: %d\n" ..
                                           "modo: %s | plato %s | stance %s",
                                       #(context.enemies or empty_table), modo, extras,
                                       tostring(p.stance or "-"))

        ---- O rodape fecha a conta ate o numero que o AIScoreDest de fato soma no tile. Antes
        ---- parava no EvalDest, que ainda nao tem o Weight -- e era o ultimo lugar onde faltava
        ---- uma divisao mental para amarrar o painel ao score.
        local eval = self:Normalize(threat)
        local tail = string.format("  SOMA %d de %d (%d%% da saturacao)  ->  EvalDest %d" ..
                                       "  ->  somado no tile: %d", threat, saturation,
                                   MulDivRound(100, Min(threat, saturation), saturation), eval,
                                   MulDivRound(eval, w, 100))
        context.dest_threat_exposure_debug = context.dest_threat_exposure_debug or {}
        context.dest_threat_exposure_debug[dest] =
            head .. "\n" .. table.concat(trace, "\n") .. "\n" .. tail
    end

    return self:Normalize(threat)
end
