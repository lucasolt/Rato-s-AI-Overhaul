-- const.AIDecisionThreshold = 80 -- targets/locations up to this percent of max scored target/location can be selected
-- const.AIPointBlankTargetMod = 50 -- targets in point-blank range get +50% score
-- const.AIFallbackWeight_OpenDoor = 100
-- const.AIFallbackWeight_ClosedDoor = 40
-- const.AIFallbackWeight_Window = 70
-- const.AIAvoidFireWeigth = -200
-- const.AIAvoidGasWeigth = -200
-- const.AIAvoidBombardEdge = 100 -- % of score retained at the border of the zone
-- const.AIAvoidBombardCenter = 30 -- % of score retained at the center of the zone
-- const.AIFriendlyFire_MaxRange = 10 * const.SlabSizeX -- max range to ally for it to be considered in danger
-- const.AIFriendlyFire_LOFWidth = 100 * guic -- max distance from an ally to the line between position and target considered in danger
-- const.AIFriendlyFire_LOFConeNear = 100 * guic -- same as above for cone attacks (near side of the cone, positioned at attacker)
-- const.AIFriendlyFire_LOFConeFar = 300 * guic -- same as above for cone attacks (far side of the cone, positioned at AIFriendlyFire_MaxRange)
-- const.AIFriendlyFire_ScoreMod = 50 -- % of damage score evaluation remanining when an ally is in danger
-- const.AIShootAboveCTH = 0
---------------------------------------------------------------------------------------------------
---- INTERRUPTOR MESTRE DAS CORRECOES DE LOS
----
---- `RATOAI_LOSFixes = false` no console devolve as tres intervencoes de linha de visao ao
---- comportamento anterior NA HORA -- sem recarregar mod, sem sair do combate. Existe para
---- fazer A/B de bug intermitente, que e o unico jeito de saber se um deles e a causa.
----
---- O que ele desliga:
----   B25   SOURCE_AIFindDestinations.lua        -- destino empacotado Prone p/ PrefStance=Prone
----   B26   SOURCE_AIPrecalcConeTargetZones.lua  -- cone da MG medido deitado
----   B27   AIPOLICYPOS_MGSetupPosScore.lua      -- portao de LOS + verificacao por inimigo
----   B29c  AIPOLICYPOS_MGSetupPosScore.lua      -- raio que confirma o aliado no cone
----   B29e  AIPOLICYPOS_MGSetupAP.lua            -- chave Prone na consulta ao cache de LOS
----
---- Os interruptores individuais continuam valendo (RATOAI_PronePackDests,
---- RATOAI_ConeStanceLOS, e as propriedades RequireLOS / VerifyLOS da policy). O mestre tem
---- PRECEDENCIA: com ele em false, os individuais nao importam.
----
---- O que ele NAO desliga: a policy em si (a nota por aglomerado no cone continua saindo, so
---- que por geometria pura, sem checar linha) e o reajuste de alvo pos-MGSetup do
---- REACTIONS_StopMGPackingUp.lua, que tem interruptor proprio (RATOAI_MGRetargetAfterSetup)
---- por ser bug de OUTRA familia -- alvo fora do cone, nao linha de visao.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_LOSFixes") == nil then
    RATOAI_LOSFixes = true
end

---------------------------------------------------------------------------------------------------
---- COMPRIMENTO DO CONE QUE A IA PLANTA NO MGSetup
----
---- O JOGADOR ESCOLHE, A IA NAO. Medido no processo vivo, dois cones ativos no mesmo combate:
----     Grizzly (merc)      dist ate target_pos = 15481  (~13 tiles, escolha do jogador)
----     LegionGunner:412    dist ate target_pos = 45600  (= max_range exato)
---- O `AIPrecalcConeTargetZones` monta o alvo do cone com
----     target_pos = attack_pos + SetLen(dir, max_range)
---- e `max_range` para MachineGun e o WeaponRange INTEIRO (as outras classes usam 75% dele,
---- Firearm:GetOverwatchConeParam). A IA sempre planta no maximo; o jogador planta onde quer.
---- Isso e o contrario da regra da casa -- e aqui a regra a mais e do jogador.
----
---- POR QUE ENCURTAR AJUDA. O numero de interrupcoes e limitado (`GetNumMGInterruptAttacks`;
---- medido, o LegionGunner:412 tinha **uma**). Um cone de 38 tiles gasta essa unica interrupcao
---- no primeiro inimigo que pisar na borda -- e na borda o tiro nao vale nada. Rampa do
---- HipshotPenalty medida ao vivo (MG42, interrupcao de MG, aim 1):
----
----     tiles     4     8    12    16    20    24    28    32    36
----     penal   -10   -14   -21   -29   -33   -36   -40   -45   -47
----
---- Nao ha joelho: e ~1,2 ponto por tile. Entao o corte e escolha de projeto, nao um otimo que
---- da para derivar -- por isso e parametro, e por isso o default nao muda nada.
----
----   RATOAI_MGConeRangePct    -- % do max_range do cone. 100 = comportamento de hoje.
----                               60 no MG42 da ~23 tiles e derruba o teto de penalidade de
----                               -47 para -36, ainda cobrindo mais que o dobro do cone que o
----                               Grizzly plantou.
----   RATOAI_MGConeRangeTiles  -- teto ABSOLUTO em tiles, aplicado depois da porcentagem.
----                               0 = sem teto. Util para nivelar armas de WeaponRange
----                               diferente (RPD_1 = 44, MG42 = 38) num mesmo alcance de
----                               engajamento.
----
---- Piso fixo de 8 tiles, para nenhum ajuste transformar o cone em nada.
----
---- Os dois sao globais de propriedade: `RATOAI_MGConeRangePct = 60` no console vale na hora,
---- sem recarregar mod, que e como se afina numero desse tipo.
----
---- >>> O LADO DA ACAO SO VALE COM O SOURCE_AIPrecalcConeTargetZones.lua REGISTRADO. <<<
---- Ele nao esta na lista `code` do metadata.lua -- verificado no processo vivo, quem roda e o
---- `AIPrecalcConeTargetZones` do vanilla (`@Lua/Tactical/CombatAI.lua`). Sem registrar, o
---- parametro muda so a NOTA dos tiles (AIPolicyMGSetupPosScore), e o cone continua sendo
---- plantado no maximo. O B26 esta no mesmo barco.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_MGConeRangePct") == nil then
    RATOAI_MGConeRangePct = 70
end
if rawget(_G, "RATOAI_MGConeRangeTiles") == nil then
    RATOAI_MGConeRangeTiles = 0
end

---------------------------------------------------------------------------------------------------
---- Alcance efetivo do cone da MG. Fonte UNICA para os dois lados -- a policy que pontua o tile
---- e a funcao que planta o cone -- porque discordancia entre eles e exatamente o bug B29.
----
---- Devolve `min_range, max_range` em unidades do mundo, ja com:
----   * a guarda `min >= max` do vanilla (AIFilterTargetPoints): min == max quer dizer "sem
----     minimo", nao "so a casca do circulo". Vale para a BrowningM2HMG, que continua assim;
----   * o teto de `Min(sight, weapon:GetMaxRange())`, que e o segundo CheckLOS da acao;
----   * os parametros de encurtamento acima.
---------------------------------------------------------------------------------------------------
function RATOAI_MGConeRange(unit, weapon, params)
    if not params then
        return 0, 0
    end

    local min_r = (params.min_range or 0) * const.SlabSizeX
    local max_r = (params.max_range or 0) * const.SlabSizeX
    if min_r >= max_r then
        min_r = 0
    end

    if unit and weapon then
        max_r = Min(max_r, Min(unit:GetSightRadius(), weapon:GetMaxRange()))
    end

    local pct = RATOAI_MGConeRangePct or 100
    if pct > 0 and pct < 100 then
        max_r = MulDivRound(max_r, pct, 100)
    end

    local cap = (RATOAI_MGConeRangeTiles or 0) * const.SlabSizeX
    if cap > 0 then
        max_r = Min(max_r, cap)
    end

    ---- Piso: nem o encurtamento nem o teto podem descer abaixo de 8 tiles, nem abaixo do
    ---- minimo do proprio cone (senao o anel fica vazio por construcao).
    max_r = Max(max_r, Max(min_r, 8 * const.SlabSizeX))

    return min_r, max_r
end

---------------------------------------------------------------------------------------------------
---- ESCOLHA DE ACAO POR RESULTADO ESPERADO (RATOAI_ExpectedActionScore)
----
---- Liga o RATOAI_ExpectedRatio (FUNCTION_ScoreAttacksDetailed.lua) nas CustomScoring: em vez
---- de modular o peso do preset por uma razao de CTH ("quanto esta penalidade doi"), modula
---- pela razao entre os ACERTOS ESPERADOS da acao e os do ataque padrao ("quanto ela rende").
----
---- Em false, cada CustomScoring volta byte a byte ao caminho antigo -- o ramo novo e um
---- `elseif` guardado, nao uma substituicao. Serve para comparar os dois lado a lado no mesmo
---- combate: `RATOAI_ExpectedActionScore = false` pelo console/DAP entre dois turnos.
----
---- Hoje so a AutoFire_CustomScoring usa. As outras (Pindown, Overwatch, SingleShotTargeted,
---- MobileAttack) continuam no PenaltyScale de proposito: elas pagam AP por efeito que nao e
---- dano -- supressao, interrupcao no turno inimigo, debuff de membro -- e acertos esperados
---- sozinho ordena mal essas tres. Ver a ressalva no cabecalho do RATOAI_ExpectedFor.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_ExpectedActionScore") == nil then
    RATOAI_ExpectedActionScore = true
end

---------------------------------------------------------------------------------------------------
---- REPLANEJAMENTO DE MIRA POR RESULTADO (RATOAI_AimReplan / RATOAI_AimReplanThreshold)
----
---- Liga o RATOAI_EnsureAimPlan: uma vez por turno, no destino e alvo ja escolhidos, o nivel de
---- mira do ataque padrao passa a ser escolhido pelos acertos esperados em vez de pela heuristica
---- de distancia do GetIdealAimLevels. O caminho quente (o laco de destinos) NAO e tocado.
----
---- O limiar e a margem, em pontos percentuais, que DESCER de nivel de mira precisa vencer.
---- Subir nao paga margem. A assimetria e proposital: "acertos esperados" nao enxerga a chance de
---- CRITICO que a mira compra (o reset de pilhas de recoil do nivel 3 ele enxerga), entao errar
---- para o lado de mirar mais e o erro barato. Subir o numero deixa o replan mais conservador;
---- 0 o torna um otimizador puro, que converge para spray e nao e o que se quer.
----
---- Em false, o GetIdealAimLevels volta a mandar sozinho e o ramo de sobrescrita do
---- AICalcAttacksAndAim nem e alcancado.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_AimReplan") == nil then
    RATOAI_AimReplan = true
end
if rawget(_G, "RATOAI_AimReplanThreshold") == nil then
    RATOAI_AimReplanThreshold = 15
end

---------------------------------------------------------------------------------------------------
---- VIES DE SHOOTING STANCE (RATOAI_StanceBias, em pontos percentuais)
----
---- Terminar o turno com a arma preparada vale AP no turno SEGUINTE: o proximo ataque nao paga
---- stance outra vez e o min_aim ja comeca em 1. "Acertos esperados" e um estimador de UM turno
---- e por construcao nao ve isso -- este e o termo que repoe a diferenca.
----
---- Aplicado aos dois lados da razao antes de dividir, e so quando a unidade ainda NAO esta
---- preparada. Se as duas pontas preparam (ou nenhuma prepara) ele se cancela sozinho.
---- 0 desliga. Deliberadamente pequeno: e desempate, nao argumento.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_StanceBias") == nil then
    RATOAI_StanceBias = 8
end

---------------------------------------------------------------------------------------------------
---- TERMOS DE PARTE DO CORPO (RATOAI_BodyPartEffectBonus, em pontos percentuais)
----
---- Tiro localizado SEMPRE paga CTH a mais e ganha outra coisa em troca. A parte NUMERICA dessa
---- troca ja vem do jogo e nao precisa ser inventada -- `Presets.TargetBodyPart.Default[x]`
---- carrega `damage_mod` e o scoring o aplica direto. Medido no processo vivo:
----     Head  tohit -40  dmg  +80   armadura: Head
----     Neck  tohit -40  dmg  +40   armadura: NENHUMA
----     Groin tohit -20  dmg  +25   armadura: NENHUMA
----     Arms  tohit -15  dmg  -25   armadura: nenhuma
----     Legs  tohit -10  dmg  -50   armadura: Legs
----     Torso tohit   0  dmg    0   armadura: Torso
----
---- Esta tabela e SO o resto -- o que o damage_mod nao expressa:
----   Head  -- critico/execucao, alem do +80 de dano;
----   Neck / Groin -- ignoram a cobertura de armadura, entao o dano passa mais inteiro do que o
----                   damage_mod sozinho sugere;
----   Arms  -- derrubar arma e estragar a mira do alvo, que vale mais que o -25 de dano custa;
----   Legs  -- Slowed. Precisa ser o maior da tabela justamente porque o damage_mod (-50) e o
----            pior de todos: sem este termo a IA nunca miraria perna.
----
---- GROSSEIROS DE PROPOSITO. Nao existe medicao limpa para "quanto vale desarmar" -- depende do
---- turno seguinte, que este estimador nao simula. Sao desempates, nao argumentos: nenhum deles
---- inverte sozinho uma diferenca grande de acertos esperados.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_BodyPartEffectBonus") == nil then
    RATOAI_BodyPartEffectBonus = {
        Head = 10,
        Neck = 20,
        Groin = 15,
        Arms = 20,
        Legs = 35,
        Torso = 0,
    }
end

---------------------------------------------------------------------------------------------------
---- SNIPE / PINDOWN (RATOAI_SnipeDistBonus, RATOAI_SnipeStuckBonus)
----
---- ATENCAO ao nome: no GBO3 a acao `PinDown` NAO suprime. Ela estende bastante o alcance da arma
---- e deixa o tiro muito acurado -- e um SNIPE. O scoring antigo tratava como supressao (bonus
---- por alvo em cobertura), que e a leitura vanilla e esta errada aqui.
----
---- As duas condicoes em que ela compensa:
----   1. LONGE -- onde o ataque normal ja perdeu acuracia e a extensao de alcance vale. O ganho
----      de CTH em si NAO precisa de termo: ele aparece sozinho no CalcChanceToHit e portanto na
----      razao de acertos esperados. Este bonus e so o vies de "e o tipo de tiro para longe".
----   2. ALVO PRESO -- quem nao consegue sair da linha ate o proximo turno. Tiro caro e lento
----      contra alvo que vai se mover e AP jogado fora.
----
---- Percentual por tile ALEM do close range, com teto. Zero desliga qualquer um dos dois.
---------------------------------------------------------------------------------------------------
---- DEFAULT ZERO, e a razao merece registro. Este bonus foi escrito ANTES do snipe passar a ser
---- pontuado por resultado esperado, e virou redundante: a razao ja SOBE sozinha com a distancia,
---- porque o ataque normal perde acuracia com o alcance e o snipe nao (mira maxima, +50% de
---- alcance, ignora cobertura baixa). Somar uma rampa por cima seria contar a mesma vantagem
---- duas vezes -- e o vies embutido no insumo e melhor que o coeficiente colado na saida.
---- Sobe para 2 ou 3 se em campo o snipe nunca disparar.
if rawget(_G, "RATOAI_SnipeDistBonus") == nil then
    RATOAI_SnipeDistBonus = 0 ---- % por tile alem do close range
end
if rawget(_G, "RATOAI_SnipeDistBonusMax") == nil then
    RATOAI_SnipeDistBonusMax = 45 ---- teto do bonus de distancia
end
if rawget(_G, "RATOAI_SnipeStuckBonus") == nil then
    RATOAI_SnipeStuckBonus = 25 ---- % por condicao de "nao consegue escapar"
end

---------------------------------------------------------------------------------------------------
---- TIRO LOCALIZADO SO COM STANCE (RATOAI_TargetedNeedsStance)
----
---- Criterio de EFICIENCIA, nao limitacao de engine -- a distincao importa para quem for mexer
---- nisto depois. Nada impede a unidade de mirar a cabeca do quadril; o que acontece e que a
---- penalidade da parte do corpo (Head -40) empilha na penalidade de hipfire e o resultado nao
---- compete com nada. Entao, se a unidade nao vai entrar em stance, nem se gasta o calculo.
----
---- Em false, o tiro localizado do quadril volta a ser avaliado e concorre pelo numero que
---- realmente vale -- que e baixo. A diferenca pratica e "nao aparece" contra "aparece com peso
---- ruim"; a segunda e mais honesta e a primeira e mais barata.
----
---- NAO se aplica ao PinDown: o custo dele ja embute a stance (GBO3 COMBAT_ACTIONS.lua:455),
---- entao o teste de AP normal ja resolve.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_TargetedNeedsStance") == nil then
    RATOAI_TargetedNeedsStance = true
end

---------------------------------------------------------------------------------------------------
---- TETO DA RAZAO DE RESULTADO ESPERADO (RATOAI_ExpectedRatioMax)
----
---- A razao multiplica o `Weight` do preset, entao ela e um FATOR e nao uma nota -- sem teto, um
---- denominador pequeno vira peso arbitrariamente grande. Duas situacoes reais:
----   base = 0  -- ataque padrao nao rende nada (alvo longe demais, unidade ruim, CTH no chao).
----                A acao especial vira a unica coisa util, e recebe o teto.
----   base ~ 0  -- base 5 com hits 150 daria razao 3000; um preset de 200 viraria 6000 e
----                dominaria o sorteio inteiro.
----
---- 300 = "vale ate tres vezes o ataque padrao". Acima disso a diferenca deixa de ser quantitativa
---- (a acao e melhor) e passa a ser qualitativa (a outra nao funciona) -- e vantagem qualitativa
---- nao deve virar numero grande, so o maior numero.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_ExpectedRatioMax") == nil then
    RATOAI_ExpectedRatioMax = 300
end
