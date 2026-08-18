---------------------------------------------------------------------------------------------------
---- BUGFIX (B9): a roleta de destino de fim de turno do vanilla nao usava os scores.
----
---- Original (CombatAI.lua:1789-1803):
----     local total = 0
----     for _, score in ipairs(potential_dests) do   -- itera os DEST empacotados,
----         total = total + score                    -- nao os scores
----     end
----     local roll = InteractionRand(total, "AIDecision")
----     for i, dest in ipairs(potential_dests) do
----         local score = dest_scores[i]
----         if score <= roll then                    -- comparacao invertida
----             context.best_end_dest = dest
----             break
----         end
----         roll = roll - score
----     end
----
---- `potential_dests` guarda posicoes empacotadas (inteiros na ordem de 1e10), entao
---- `total` ficava astronomico, `roll` sempre maior que qualquer score, e a condicao
---- `score <= roll` disparava na PRIMEIRA iteracao. Como a lista e semeada com
---- `{curr_dest}`, o resultado era quase sempre "fique onde esta".
----
---- Consequencia: os pesos das EndTurnPolicies so decidiam QUEM ENTRAVA na lista de
---- finalistas (o corte de const.AIDecisionThreshold), nunca quem ganhava.
----
---- Consertos:
----   1. somar `dest_scores` em vez de `potential_dests`;
----   2. comparar `roll < w` (roleta ponderada padrao);
----   3. ignorar pesos negativos na soma -- AIScoreDest pode devolver negativo e isso
----      corromperia o sorteio;
----   4. caso degenerado (todos os finalistas <= 0): pegar o de maior score em vez de
----      cair no ultimo da lista;
----   5. `cur_dest_preference == "avoid"` removia de `potential_dests` sem remover de
----      `dest_scores`, dessincronizando os dois arrays.
---------------------------------------------------------------------------------------------------
---- Bonus percentual aplicado ao peso do TILE ATUAL no sorteio.
----   0   = comportamento corrigido puro (a posicao atual concorre pelo score)
----   100 = a posicao atual conta dobrado
----   400 = a posicao atual conta 5x -- perto do viés antigo de ficar parado
---- Serve para migrar a calibragem aos poucos em vez de virar a chave de uma vez.
---- (definir em CONSTANTS_AI_source.lua se quiser um valor fixo -- aquele arquivo
----  carrega antes deste, e o `or` abaixo preserva o valor)
local RATOAI_StayPutBonus = 0

function AIScoreReachableVoxels(context, policies, opt_loc_weight, dest_score_details,
                                cur_dest_preference)
    local unit = context.unit
    policies = table.ifilter(policies, function(idx, policy)
        return policy:MatchUnit(unit)
    end)
    unit.ai_end_turn_search = {}

    local total_dist = context.total_dist
    local dest_dist = context.dest_dist or empty_table

    local curr_dest = context.voxel_to_dest[context.unit_world_voxel] or
                          context.voxel_to_dest[context.closest_free_pos] or context.unit_stance_pos
    local dist = dest_dist[curr_dest] or total_dist
    local score = -opt_loc_weight

    if (total_dist or 0) > 0 then
        score = MulDivRound(score, dist, total_dist)
    end

    local unit_voxels = {}
    local best_end_score = curr_dest and
                               AIScoreDest(context, policies, curr_dest, context.unit_grid_voxel,
                                           score, unit_voxels)

    -- cache the best voxel on the way to optimal location to use as fallback if needed
    local best_dist_score, closest_dest
    local potential_dests, dest_scores = {curr_dest}, {best_end_score}

    for _, dest in ipairs(context.destinations) do
        total_dist = Max(total_dist or 0, dest_dist[dest] or 0)
    end

    for _, dest in ipairs(context.destinations) do
        local score = 0
        local scores

        local dist = dest_dist[dest] or 100 * guim
        local dist_score = 0
        if total_dist and total_dist > 0 then
            dist_score = MulDivRound(100 - MulDivRound(100, dist, total_dist), opt_loc_weight, 100)
        end
        if dist_score > (best_dist_score or 0) then
            best_dist_score, closest_dest = dist_score, dest
        end

        score = score + dist_score
        if dest_score_details then
            scores = {"Distance to optimal location", dist_score}
            dest_score_details[dest] = scores
        end

        table.iclear(unit_voxels)
        score = AIScoreDest(context, policies, dest, nil, score, unit_voxels, scores)

        if MulDivRound(best_end_score or 0, const.AIDecisionThreshold, 100) <= score then
            best_end_score = Max(score, best_end_score or 0)
            local n = #potential_dests
            potential_dests[n + 1] = dest
            dest_scores[n + 1] = score
            local threshold = MulDivRound(best_end_score, const.AIDecisionThreshold, 100) -- updated threshold
            for i = n, 1, -1 do
                if dest_scores[i] < threshold then
                    table.remove(dest_scores, i)
                    table.remove(potential_dests, i)
                end
            end
        end
        if scores then
            scores.final_score = score
        end
    end

    -- pick best_end_dest/score from potential_dests
    assert(#potential_dests > 0)
    context.best_end_dest = false
    if cur_dest_preference == "prefer" then
        if table.find(potential_dests, curr_dest) then
            context.best_end_dest = curr_dest
        end
    elseif cur_dest_preference == "avoid" then
        ---- BUGFIX (B9.5): o original removia so de potential_dests, deixando
        ---- dest_scores desalinhado a partir daquele indice.
        for i = #potential_dests, 1, -1 do
            if potential_dests[i] == curr_dest and #potential_dests > 1 then
                table.remove(potential_dests, i)
                table.remove(dest_scores, i)
            end
        end
    end

    NetUpdateHash("AIScoreReachableVoxels", unit, unit:GetPos(), unit.ActionPoints,
                  context.archetype.id, #(context.destinations or ""),
                  hashParamTable(context.destinations), #(potential_dests or ""),
                  hashParamTable(potential_dests), cur_dest_preference)

    if not context.best_end_dest then
        --------------------------------------------------------------------------
        ---- BUGFIX (B9): roleta ponderada de verdade (ver cabecalho do arquivo)
        --------------------------------------------------------------------------
        ---- curr_dest pode aparecer DUAS vezes na lista: uma semeada antes do laco
        ---- (base negativa -opt_loc_weight) e outra adicionada pelo proprio laco
        ---- (com dist_score positivo). Com a roleta funcionando isso dobraria a
        ---- chance de ficar parado. Mantem so a entrada de maior score.
        local curr_best_i
        for i = 1, #potential_dests do
            if potential_dests[i] == curr_dest then
                if not curr_best_i or (dest_scores[i] or 0) > (dest_scores[curr_best_i] or 0) then
                    curr_best_i = i
                end
            end
        end

        local weights, total = {}, 0
        for i = 1, #potential_dests do
            local w = Max(0, dest_scores[i] or 0)
            if potential_dests[i] == curr_dest then
                if i ~= curr_best_i then
                    w = 0 ---- entrada duplicada do tile atual
                elseif RATOAI_StayPutBonus ~= 0 then
                    w = MulDivRound(w, 100 + RATOAI_StayPutBonus, 100)
                end
            end
            weights[i] = w
            total = total + w
        end

        if total > 0 then
            local roll = InteractionRand(total, "AIDecision")
            for i, dest in ipairs(potential_dests) do
                local w = weights[i]
                if roll < w then
                    context.best_end_dest = dest
                    break
                end
                roll = roll - w
            end
        end

        if not context.best_end_dest then
            ---- degenerado: todos os finalistas com score <= 0. Pega o de maior score
            ---- em vez de cair no ultimo da lista.
            local best_i
            for i = 1, #potential_dests do
                if not best_i or (dest_scores[i] or 0) > (dest_scores[best_i] or 0) then
                    best_i = i
                end
            end
            context.best_end_dest = potential_dests[best_i or #potential_dests] or curr_dest
        end
        --------------------------------------------------------------------------
    end
    context.best_end_score = best_end_score

    context.closest_dest = closest_dest
    return context.best_end_dest, context.best_end_score
end
