---- garante a subtabela: este arquivo LE valores dela e pode carregar antes do
---- CONSTANTS_AI_source. Idempotente.
const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
-- ESCOLHA DE BEHAVIOR DO ARTILHEIRO
--
-- O problema que estas funcoes resolvem: a escolha da ACAO ja sabe decidir entre "atirar de pe" e
-- "montar a MG" (MGSetup_CustomScoring, com a rampa em torno de const.RATOAI.MGSetupMaxHits), mas
-- a escolha da POSICAO nao seguia essa logica. O `Unit:StartAI` sorteia entre os behaviors
-- proporcionalmente ao `Score` de cada um, e enquanto um deles devolvia `self.Weight` cru o
-- sorteio nao sabia de nada.
--
-- O DESENHO: cada behavior responde a SUA pergunta, e so a dela.
--
--   atacar    -> "quanto dano eu consigo fazer este turno, do melhor destino que alcanco?"
--                Nao avalia policy nenhuma: o AIPrecalcDamageScore ja deixou dest_hit_score
--                pronto para todos os destinos, e o maximo dessa tabela E a resposta.
--
--   montar MG -> "quao boa e a melhor posicao de MG que eu alcanco?"
--                Uma passada com as policies do proprio behavior. Nao toca em dano -- que era o
--                ponto: o behavior de MG nao paga analise de dano.
--
-- A REGUA COMUM. Os dois scores entram no mesmo sorteio, entao precisam da mesma escala, senao
-- quem vence e quem tem mais peso de policy somado e nao quem esta melhor. Ambos saem
-- normalizados para 0..100 antes de levar o `Weight` do behavior -- e dai os dois `Weight` do
-- editor viram os unicos numeros a calibrar.
--
-- O DENOMINADOR DO LADO DO DANO E O MESMO `MGSetupMaxHits` da escolha de acao. Isso e de
-- proposito e e o que amarra as duas decisoes: a posicao e a acao passam a medir "o tiro de pe
-- rende?" contra a mesma referencia. Duas contas separadas da mesma pergunta e como elas
-- divergem -- ver RATOAI_MGConeRange (policy x acao, BUGFIX B29) e RATOAI_CoverCTH
-- (SeekCover x ThreatExposure), que existem pelo mesmo motivo.
--
-- CUSTO. O `Update_AIPrecalcDamageScore` e guardado por `damage_score_precalced`, e a chamada
-- que o `StandardAI:Think` faz depois bate no mesmo guard e retorna na hora. O trabalho nao
-- duplica: so acontece mais cedo. Duas consequencias que valem saber:
--   * o `override_attack_id` do behavior vira NO-OP, porque quando o Think for seta-lo o precalc
--     ja rodou. Para o artilheiro isso e quase um alivio -- `MGSetup` ali esta errado de
--     qualquer forma (AimType = "cone", nao causa dano);
--   * o custo do precalc e pago quando o behavior de ataque e AVALIADO, nao quando e escolhido.
--     Nao ha como fugir: nao da para pontuar "quao bom e atacar" sem calcular o ataque.
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
---- A RAMPA, EXTRAIDA.
----
---- Fonte unica da curva que o MGSetup_CustomScoring usa. Devolve o multiplicador em pontos
---- percentuais (+ favorece montar, - favorece atirar) e o limiar que o produziu.
----
---- `nil` quando nao ha resposta: sem estimativa de acertos, ou limiar desligado pela constante.
---- Isso NAO e o mesmo que multiplicador 0 -- 0 quer dizer "exatamente no limiar, indiferente",
---- e quem chama precisa poder separar os dois.
---------------------------------------------------------------------------------------------------
function RATOAI_MGSetupRamp(hits)
    local limiar = const.RATOAI.MGSetupMaxHits or 0
    if not hits or limiar <= 0 then
        return nil, limiar
    end
    if hits <= limiar then
        return MulDivRound(limiar - hits, const.RATOAI.MGSetupBonus or 0, limiar), limiar
    end
    ---- Min com o proprio limiar: satura em 2x. Sem isso, um tiro de pe excepcional levaria o
    ---- multiplicador abaixo de -100 e a acao sumiria -- decisao diferente de "nao serve aqui".
    return -MulDivRound(Min(hits - limiar, limiar), const.RATOAI.MGSetupMalus or 0, limiar), limiar
end

---------------------------------------------------------------------------------------------------
---- Teto de score das EndTurnPolicies de um behavior, para normalizar.
----
---- So conta quem pode SOMAR. O AIPolicyThreatExposure devolve `MulDivRound(self.Penalty, ...)`
---- com Penalty negativo: ele nunca levanta o teto, so desconta dele. Somar o Weight dele ao
---- divisor inflaria o denominador e afundaria o behavior que o usa.
----
---- O teste e pela property `Penalty` e nao pelo nome da classe: qualquer policy futura que siga
---- o mesmo idioma (Penalty negativo = so desconta) e tratada certo sem tocar aqui.
---------------------------------------------------------------------------------------------------
local function TetoDasPolicies(behavior, unit)
    local teto = 0
    for _, policy in ipairs(behavior.EndTurnPolicies or empty_table) do
        if policy:MatchUnit(unit) then
            local w = policy.Weight or 0
            if w > 0 and (policy.Penalty or 0) >= 0 then
                teto = teto + w
            end
        end
    end
    return teto
end

---------------------------------------------------------------------------------------------------
---- BEHAVIOR DE ATAQUE -- pontuado pelo dano.
----
---- Ligar pelo editor: `Score` = RATOAI_GunnerAttackScore(self, unit, proto_context, debug_data)
----
---- Le o MAXIMO de `dest_hit_score` sobre os destinos. E o unico numero que responde "quanto eu
---- consigo fazer este turno" sem avaliar posicao nenhuma -- e ele ja esta calculado.
----
---- `context.destinations` ja existe neste momento: o nosso AICreateContext chama
---- AIFindDestinations (SOURCE_AICreateContext.lua:227). O que ainda nao rodou e o precalc de
---- dano, e e por isso que ele e forcado aqui.
---------------------------------------------------------------------------------------------------
function RATOAI_GunnerAttackScore(behavior, unit, proto_context, debug_data)
    unit.ai_context = unit.ai_context or AICreateContext(unit, proto_context)
    local context = unit.ai_context

    Update_AIPrecalcDamageScore(unit)

    local melhor = 0
    local hit = context.dest_hit_score or empty_table
    for _, dest in ipairs(context.destinations or empty_table) do
        local h = hit[dest]
        if h and h > melhor then
            melhor = h
        end
    end

    ---- Normaliza contra o MESMO limiar da escolha de acao. 100 = o melhor tile rende o limiar
    ---- inteiro. Satura ali de proposito: acima do limiar quem decide se vale mais atirar ou
    ---- montar e a rampa, na escolha da acao -- este numero so precisa dizer "da para atacar".
    local limiar = const.RATOAI.MGSetupMaxHits or 0
    local norma = (limiar > 0) and Min(100, MulDivRound(melhor, 100, limiar)) or
                      (melhor > 0 and 100 or 0)

    if RATOAI_Debug then
        context.dbg_behavior_scores = context.dbg_behavior_scores or {}
        context.dbg_behavior_scores[tostring(behavior.Comment or "atacar")] =
            {bruto = melhor, limiar = limiar, norma = norma, peso = behavior.Weight}
    end

    return MulDivRound(norma, behavior.Weight or 100, 100)
end

---------------------------------------------------------------------------------------------------
---- BEHAVIOR DE MONTAR A MG -- pontuado pela posicao.
----
---- Ligar pelo editor: `Score` = RATOAI_GunnerMGScore(self, unit, proto_context, debug_data)
----
---- Nao toca em dano de proposito. Uma passada de AIScoreDest sobre os destinos com as
---- EndTurnPolicies do proprio behavior, guardando o maximo.
----
---- POR QUE NAO `AIScoreReachableVoxels`: ela nao e uma consulta, e a DECISAO. Escreve
---- `context.best_end_dest`/`best_end_score` -- que o Think ainda vai calcular de verdade -- e,
---- quando ha empate acima do AIDecisionThreshold, consome uma tirada de
---- `InteractionRand("AIDecision")`. Chamar isso dentro de um Score seria gastar RNG
---- sincronizado e sujar estado antes da hora. Aqui so queremos o maximo.
---------------------------------------------------------------------------------------------------
function RATOAI_GunnerMGScore(behavior, unit, proto_context, debug_data)
    unit.ai_context = unit.ai_context or AICreateContext(unit, proto_context)
    local context = unit.ai_context

    local policies = table.ifilter(behavior.EndTurnPolicies or empty_table, function(idx, p)
        return p:MatchUnit(unit)
    end)
    if #policies == 0 then
        return 0
    end

    ---- reaproveitado entre destinos: o AIScoreDest o usa como rascunho de GetVisualVoxels
    local visual_voxels = {}
    local melhor = 0
    for _, dest in ipairs(context.destinations or empty_table) do
        local s = AIScoreDest(context, policies, dest, nil, 0, visual_voxels)
        if s and s > melhor then
            melhor = s
        end
    end

    local teto = TetoDasPolicies(behavior, unit)
    local norma = (teto > 0) and Clamp(MulDivRound(melhor, 100, teto), 0, 100) or 0

    if RATOAI_Debug then
        context.dbg_behavior_scores = context.dbg_behavior_scores or {}
        context.dbg_behavior_scores[tostring(behavior.Comment or "montar MG")] =
            {bruto = melhor, teto = teto, norma = norma, peso = behavior.Weight}
    end

    return MulDivRound(norma, behavior.Weight or 100, 100)
end
