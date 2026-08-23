---------------------------------------------------------------------------------------------------
---- CONSTANTES E INTERRUPTORES DO MOD -- todos vivem em `const.RATOAI`.
----
---- POR QUE NAO SAO MAIS GLOBAIS SOLTAS. O idioma antigo era
----     if rawget(_G, "RATOAI_X") == nil then RATOAI_X = <default> end
---- e ele NAO FUNCIONAVA. Medido no processo vivo: `rawget(_G, "RATOAI_LOSFixes")` devolve nil
---- mesmo com o global definido, porque neste engine os globais moram atras do `__index` do _G
---- (e o mesmo mecanismo que produz os "[mod] Ignored assert: Attempt to use an undefined
---- global"). Ou seja, a condicao era SEMPRE verdadeira e o valor era resetado ao default em
---- todo load -- a intencao de "deixar o usuario pre-definir" nunca valeu um dia.
----
---- `const` e uma tabela comum: `const.RATOAI.X` le e escreve normal, no console e no DAP, e o
---- teste `== nil` volta a significar o que diz.
----
---- REGRA: nao criar global nova para constante nem para interruptor. Nem com rawget, nem sem.
---- Ficam de fora, e cada uma tem motivo proprio:
----   RATOAI_Debug       -- nao e constante, e estado recomputado no CombatStart, e e lido em
----                         laco quente como `local dbg = RATOAI_Debug`. Ver UTIL.lua.
----   RATOAI_LastExpected -- deposito de DADOS de debug, nao configuracao.
---- (A valvula do debug, antes RATOAI_DebugForce, MUDOU para const.RATOAI.DebugForce -- ela era
----  lida com rawget e portanto nunca enxergou nada digitado no console. Ver B32 em UTIL.lua.)
---------------------------------------------------------------------------------------------------
const.RATOAI = const.RATOAI or {}

---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata (o CONSTANTS_AI_source ja a cria, mas nao dependemos disso).
const.RATOAI = const.RATOAI or {}

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
----   const.RATOAI.MGConeRangePct    -- % do max_range do cone. 100 = comportamento de hoje.
----                               60 no MG42 da ~23 tiles e derruba o teto de penalidade de
----                               -47 para -36, ainda cobrindo mais que o dobro do cone que o
----                               Grizzly plantou.
----   const.RATOAI.MGConeRangeTiles  -- teto ABSOLUTO em tiles, aplicado depois da porcentagem.
----                               0 = sem teto. Util para nivelar armas de WeaponRange
----                               diferente (RPD_1 = 44, MG42 = 38) num mesmo alcance de
----                               engajamento.
----
---- Piso fixo de 8 tiles, para nenhum ajuste transformar o cone em nada.
----
---- Os dois sao globais de propriedade: `const.RATOAI.MGConeRangePct = 60` no console vale na hora,
---- sem recarregar mod, que e como se afina numero desse tipo.
----
---- >>> O LADO DA ACAO SO VALE COM O SOURCE_AIPrecalcConeTargetZones.lua REGISTRADO. <<<
---- Ele nao esta na lista `code` do metadata.lua -- verificado no processo vivo, quem roda e o
---- `AIPrecalcConeTargetZones` do vanilla (`@Lua/Tactical/CombatAI.lua`). Sem registrar, o
---- parametro muda so a NOTA dos tiles (AIPolicyMGSetupPosScore), e o cone continua sendo
---- plantado no maximo. O B26 esta no mesmo barco.
---------------------------------------------------------------------------------------------------
if const.RATOAI.MGConeRangePct == nil then
    const.RATOAI.MGConeRangePct = 70
end
if const.RATOAI.MGConeRangeTiles == nil then
    const.RATOAI.MGConeRangeTiles = 0
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

    local pct = const.RATOAI.MGConeRangePct or 100
    if pct > 0 and pct < 100 then
        max_r = MulDivRound(max_r, pct, 100)
    end

    local cap = (const.RATOAI.MGConeRangeTiles or 0) * const.SlabSizeX
    if cap > 0 then
        max_r = Min(max_r, cap)
    end

    ---- Piso: nem o encurtamento nem o teto podem descer abaixo de 8 tiles, nem abaixo do
    ---- minimo do proprio cone (senao o anel fica vazio por construcao).
    max_r = Max(max_r, Max(min_r, 8 * const.SlabSizeX))

    return min_r, max_r
end

---------------------------------------------------------------------------------------------------
---- ESCOLHA DE ACAO POR RESULTADO ESPERADO
----
---- Liga o RATOAI_ExpectedRatio (FUNCTION_ScoreAttacksDetailed.lua) nas CustomScoring: em vez
---- de modular o peso do preset por uma razao de CTH ("quanto esta penalidade doi"), modula
---- pela razao entre os ACERTOS ESPERADOS da acao e os do ataque padrao ("quanto ela rende").
----
---- Hoje so a AutoFire_CustomScoring usa. As outras (Pindown, Overwatch, SingleShotTargeted,
---- MobileAttack) continuam no PenaltyScale de proposito: elas pagam AP por efeito que nao e
---- dano -- supressao, interrupcao no turno inimigo, debuff de membro -- e acertos esperados
---- sozinho ordena mal essas tres. Ver a ressalva no cabecalho do RATOAI_ExpectedFor.
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
---- REPLANEJAMENTO DE MIRA POR RESULTADO (const.RATOAI.AimReplanThreshold)
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

---------------------------------------------------------------------------------------------------
if const.RATOAI.AimReplanThreshold == nil then
    const.RATOAI.AimReplanThreshold = 15
end

---------------------------------------------------------------------------------------------------
---- VIES DE SHOOTING STANCE (const.RATOAI.StanceBias, em pontos percentuais)
----
---- Terminar o turno com a arma preparada vale AP no turno SEGUINTE: o proximo ataque nao paga
---- stance outra vez e o min_aim ja comeca em 1. "Acertos esperados" e um estimador de UM turno
---- e por construcao nao ve isso -- este e o termo que repoe a diferenca.
----
---- Aplicado aos dois lados da razao antes de dividir, e so quando a unidade ainda NAO esta
---- preparada. Se as duas pontas preparam (ou nenhuma prepara) ele se cancela sozinho.
---- 0 desliga. Deliberadamente pequeno: e desempate, nao argumento.
---------------------------------------------------------------------------------------------------
if const.RATOAI.StanceBias == nil then
    const.RATOAI.StanceBias = 8
end

---------------------------------------------------------------------------------------------------
---- TERMOS DE PARTE DO CORPO (const.RATOAI.BodyPartEffectBonus, em pontos percentuais)
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
if const.RATOAI.BodyPartEffectBonus == nil then
    const.RATOAI.BodyPartEffectBonus = {Head = 10, Neck = 20, Groin = 15, Arms = 20, Legs = 35, Torso = 0}
end

---------------------------------------------------------------------------------------------------
---- SNIPE / PINDOWN (const.RATOAI.SnipeDistBonus, const.RATOAI.SnipeStuckBonus)
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
if const.RATOAI.SnipeDistBonus == nil then
    const.RATOAI.SnipeDistBonus = 0 ---- % por tile alem do close range
end
if const.RATOAI.SnipeDistBonusMax == nil then
    const.RATOAI.SnipeDistBonusMax = 45 ---- teto do bonus de distancia
end
if const.RATOAI.SnipeStuckBonus == nil then
    const.RATOAI.SnipeStuckBonus = 25 ---- % por condicao de "nao consegue escapar"
end

---------------------------------------------------------------------------------------------------
---- TIRO LOCALIZADO SO COM STANCE
----
---- Criterio de EFICIENCIA, nao limitacao de engine -- a distincao importa para quem for mexer
---- nisto depois. Nada impede a unidade de mirar a cabeca do quadril; o que acontece e que a
---- penalidade da parte do corpo (Head -40) empilha na penalidade de hipfire e o resultado nao
---- compete com nada. Entao, se a unidade nao vai entrar em stance, nem se gasta o calculo.

----
---- NAO se aplica ao PinDown: o custo dele ja embute a stance (GBO3 COMBAT_ACTIONS.lua:455),
---- entao o teste de AP normal ja resolve.
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
---- TETO DA RAZAO DE RESULTADO ESPERADO (const.RATOAI.ExpectedRatioMax)
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
if const.RATOAI.ExpectedRatioMax == nil then
    const.RATOAI.ExpectedRatioMax = 300
end

---------------------------------------------------------------------------------------------------
---- PREPARAR ARMA EM VEZ DE ATIRAR MAL (RATOAI_PrepareWeapon*)
----
---- Situacao: sobra AP para UM tiro de quadril e mais nada. O tiro sai com mira 0, a penalidade de
---- hipfire come a CTH, e o turno acaba com a arma despreparada -- entao o turno SEGUINTE tambem
---- comeca pagando stance. Preparar agora troca um tiro ruim por um turno inteiro de tiros bons.
----
---- `MaxHits` e o limiar de "tiro ruim", em acertos esperados x100 (a mesma unidade do
---- dest_hit_score): 40 = 0.40 acerto. Acima disso o tiro de quadril ja vale a pena e a acao e
---- desabilitada -- preparar nunca deve competir com um tiro que rende.
----
---- `Bonus` e quanto o peso sobe quando o tiro de agora rende ZERO, interpolado linearmente ate 0
---- no limiar. Com 150: 0.00 acerto -> x2.5 no peso; 0.40 acerto -> x1.0.
----
---- `BoltBonus` e o extra para arma de ferrolho. Dois motivos, e os dois sao mecanicos e nao de
---- gosto: (1) o ferrolho entra no custo do disparo (AICalcAttacksAndAim:237-250), entao ela cai
---- neste cenario com mais frequencia que as outras; (2) disparar deixa a arma por ciclar, e o
---- ciclo e cobrado do proximo tiro -- o tiro ruim de hoje encarece o tiro bom de amanha.
---------------------------------------------------------------------------------------------------
if const.RATOAI.PrepareWeaponMaxHits == nil then
    const.RATOAI.PrepareWeaponMaxHits = 40
end
if const.RATOAI.PrepareWeaponBonus == nil then
    const.RATOAI.PrepareWeaponBonus = 150
end
if const.RATOAI.PrepareWeaponBoltBonus == nil then
    const.RATOAI.PrepareWeaponBoltBonus = 160
end
