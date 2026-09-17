const.RATOAI = const.RATOAI or {}

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

---------------------------------------------------------------------------------------------------
---- FINALIST REFINEMENT (aCTH): rank cheap, choose exact.
----
---- THE CASE. Measured 2026-09-16, H4: the destination loop ranks with the LoF spot count
---- (RATOAI_LoFExposure) and no muzzle check, while the shot rolls against the full silhouette
---- probe plus Rat_MuzzleClearance. Pierre -> Kalyna: plan 100% exposed / CTH 7, full probe 33%,
---- real CTH 0. Nine of twelve enemy shots in that fight rolled 0%.
----
---- WHY NOT EVERYWHERE. The full model is ~10-20 ms per (destination, target); the loop scores
---- hundreds of destinations. The finalists inside AIDecisionThreshold are a handful, and they are
---- the only ones whose attack numbers can still change the pick.
----
---- HOW. Top `RefineMaxDests` finalists with a target get AIPrecalcDamageScore again under
---- `__ratoai_refining` (full geometry, destination stance), then AIScoreDest again. Repeats while
---- the best finalist is still unrefined, up to `RefineRounds`, so a demoted leader can't hand the
---- pick to an unverified runner-up. The threshold cut is redone on the refined scores.
---------------------------------------------------------------------------------------------------
if const.RATOAI.RefineFinalists == nil then
    const.RATOAI.RefineFinalists = true
end
if const.RATOAI.RefineMaxDests == nil then
    const.RATOAI.RefineMaxDests = 5
end
if const.RATOAI.RefineRounds == nil then
    const.RATOAI.RefineRounds = 2
end

local function RATOAI_RefineFinalists(context, policies, potential_dests, dest_scores, base_scores,
                                      grid_voxels, unit_voxels)
    local unit = context.unit
    if not const.RATOAI.RefineFinalists or not const.RATOAI.FullGeometry or #potential_dests == 0 or
        not context.dest_target or
        not RATOAI_AngularOn(context.weapon, context.default_attack, unit) then
        return
    end

    local refined, trace = {}, RATOAI_Debug and {}
    for _ = 1, const.RATOAI.RefineRounds do
        local order = {}
        for i = 1, #potential_dests do
            order[i] = i
        end
        table.sort(order, function(a, b)
            return (dest_scores[a] or 0) > (dest_scores[b] or 0)
        end)
        ---- stop once the leader is verified; dests without a target have nothing to refine
        local leader = potential_dests[order[1]]
        if refined[leader] or not context.dest_target[leader] then
            break
        end

        local batch, seen = {}, {}
        for _, i in ipairs(order) do
            local dest = potential_dests[i]
            if #batch >= const.RATOAI.RefineMaxDests then
                break
            end
            if not refined[dest] and not seen[dest] and context.dest_target[dest] then
                seen[dest] = true
                batch[#batch + 1] = dest
            end
        end
        if #batch == 0 then
            break
        end

        ---- the precalc replaces dest_cth/dest_hit_score wholesale: carry the other dests over
        local old_cth, old_hit = context.dest_cth or {}, context.dest_hit_score or {}
        local old_target = trace and {}
        if trace then
            for _, dest in ipairs(batch) do
                old_target[dest] = context.dest_target[dest]
            end
        end
        context.__ratoai_refining = true
        local ok, err = pcall(AIPrecalcDamageScore, context, batch)
        context.__ratoai_refining = false
        for dest, v in pairs(old_cth) do
            if context.dest_cth[dest] == nil and not seen[dest] then
                context.dest_cth[dest] = v
            end
        end
        for dest, v in pairs(old_hit) do
            if context.dest_hit_score[dest] == nil and not seen[dest] then
                context.dest_hit_score[dest] = v
            end
        end
        if not ok then
            print("[RATOAI] finalist refinement failed --", err)
            return
        end

        for i, dest in ipairs(potential_dests) do
            if seen[dest] then
                local before = dest_scores[i]
                table.iclear(unit_voxels)
                dest_scores[i] = AIScoreDest(context, policies, dest, grid_voxels[i], base_scores[i],
                                             unit_voxels)
                if trace then
                    local tgt = context.dest_target[dest]
                    local prev = old_target[dest]
                    trace[#trace + 1] = {
                        before = before,
                        after = dest_scores[i],
                        cth = context.dest_cth[dest],
                        hit = context.dest_hit_score[dest],
                        target = IsKindOf(tgt, "Unit") and tgt.session_id or nil,
                        target_before = IsKindOf(prev, "Unit") and prev.session_id or nil
                    }
                end
            end
        end
        for dest in pairs(seen) do
            refined[dest] = true
        end
    end

    local best
    for i = 1, #dest_scores do
        best = Max(best or dest_scores[i], dest_scores[i])
    end
    ---- a percentage cut of a non-positive best would drop the best itself
    local threshold = (best or 0) > 0 and MulDivRound(best, const.AIDecisionThreshold, 100)
    for i = #potential_dests, 1, -1 do
        if threshold and dest_scores[i] < threshold and #potential_dests > 1 then
            table.remove(potential_dests, i)
            table.remove(dest_scores, i)
            table.remove(base_scores, i)
            table.remove(grid_voxels, i)
        end
    end
    if trace then
        context.dbg_refine = trace
    end
    return best
end

function AIScoreReachableVoxels(context, policies, opt_loc_weight, dest_score_details,
                                cur_dest_preference)
    local unit = context.unit
    policies = table.ifilter(policies, function(idx, policy)
        return policy:MatchUnit(unit)
    end)
    unit.ai_end_turn_search = {}

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B47): marca que o passe de END-TURN esta rodando.
    ----
    ---- Lido por `scope_ok` em FUNCTION_DangerScan.lua, que decide se os termos DANGEROUS PATH e
    ---- TIMED EXPLOSIVE valem neste passe (const.RATOAI.PathDangerScope / TimedDangerScope).
    ----
    ---- Funciona porque `AIScoreDest` tem exatamente DOIS chamadores no jogo -- este e o
    ---- `AIFindOptimalLocation`. Bandeira ligada = End-Turn; desligada = OptLoc. Marcar aqui evita
    ---- ter que sobrescrever o AIFindOptimalLocation so para pendurar a bandeira contraria.
    ----
    ---- Desligada no fim da funcao (ha um unico `return`, no rodape). Se algum dia aparecer saida
    ---- antecipada, ela PRECISA limpar tambem -- bandeira presa em `true` faria o OptLoc se passar
    ---- por End-Turn pelo resto do turno.
    ---------------------------------------------------------------------------------------------
    context.__ratoai_endturn_pass = true

    local total_dist = context.total_dist
    local dest_dist = context.dest_dist or empty_table

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B13): quando a unidade JA ESTA no optimal location, o OptLocWeight sumia
    ---- inteiro da decisao -- e o tile atual ainda levava a penalidade cheia.
    ----
    ---- Cadeia: AIFindOptimalLocation, ao achar um candidato no proprio voxel de partida,
    ---- preenche context.best_dest no laco de cima e PULA o bloco que atribui
    ---- context.best_dest_path (nao ha caminho a percorrer). Com best_dest_path nil,
    ---- AICalcPathDistances (CombatAI.lua:1359-1377) deixa context.total_dist = nil e
    ---- context.dest_dist = {}. Aqui embaixo as DUAS formulas de OptLoc estao atras do
    ---- mesmo portao `total_dist > 0`, entao:
    ----     - dist_score = 0 para TODOS os destinos (o OptLocWeight inteiro -- 200 em
    ----       varios archetypes -- some da conta);
    ----     - o seed do curr_dest fica com -opt_loc_weight SEM escalar, penalidade cheia.
    ----
    ---- Isso e vanilla, nao regressao do mod. Ficava mascarado porque a roleta quebrada
    ---- (ver B9) disparava sempre na primeira iteracao, e a lista e semeada com
    ---- {curr_dest} -- o resultado era "fique onde esta" por acidente. Consertar a roleta
    ---- tirou essa ancora exatamente no caso em que o OptLocWeight fica mudo, e com
    ---- AIDecisionThreshold = 80 dezenas de tiles empatam: a unidade abandona boa posicao.
    ----
    ---- Conserto: a fórmula do gradiente esta certa -- o que falta e o insumo dela. Quando
    ---- dest_dist vem vazio, preenchemos com a distancia direta de cada dest ate o
    ---- best_dest e usamos o MAIOR desses valores como denominador. Assim:
    ----     dest em cima do optimal  -> dist 0        -> dist_score = opt_loc_weight
    ----     dest no limite do alcance -> dist maxima  -> dist_score = 0
    ---- ou seja, exatamente o mesmo gradiente de sempre, so que normalizado pelo raio de
    ---- movimento em vez de pelo comprimento do caminho (que aqui e zero). O viés continua
    ---- sendo viés: soma ao score das policies, nao manda nele.
    ----
    ---- Distancia direta como substituto da distancia de caminho tem precedente no proprio
    ---- source: AITacticCalcPathDistances (AITactics.lua:8-13) faz exatamente
    ---- `context.dest_dist[dest] = stance_pos_dist(context.best_dest, dest)`.
    ---------------------------------------------------------------------------------------------
    local curr_dest = context.voxel_to_dest[context.unit_world_voxel] or
                          context.voxel_to_dest[context.closest_free_pos] or context.unit_stance_pos

    if (not total_dist or total_dist <= 0) and context.best_dest then
        local best_dest = context.best_dest
        local filled, max_dist = {}, 0
        for _, dest in ipairs(context.destinations) do
            local d = stance_pos_dist(best_dest, dest)
            filled[dest] = d
            if d > max_dist then
                max_dist = d
            end
        end
        ---- curr_dest nem sempre esta em context.destinations (fallback do closest_free_pos)
        if not filled[curr_dest] then
            filled[curr_dest] = stance_pos_dist(best_dest, curr_dest)
            max_dist = Max(max_dist, filled[curr_dest])
        end
        ---- max_dist == 0 seria divisao por zero: sem alternativa util, segue como antes
        if max_dist > 0 then
            dest_dist, total_dist = filled, max_dist
        end
    end

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
    ---- parallel to potential_dests, for RATOAI_RefineFinalists to rescore without the loop
    local base_scores, grid_voxels = {score}, {context.unit_grid_voxel}

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
        local base_score = score
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
            base_scores[n + 1] = base_score
            grid_voxels[n + 1] = false
            local threshold = MulDivRound(best_end_score, const.AIDecisionThreshold, 100) -- updated threshold
            for i = n, 1, -1 do
                if dest_scores[i] < threshold then
                    table.remove(dest_scores, i)
                    table.remove(potential_dests, i)
                    table.remove(base_scores, i)
                    table.remove(grid_voxels, i)
                end
            end
        end
        if scores then
            scores.final_score = score
        end
    end

    best_end_score = RATOAI_RefineFinalists(context, policies, potential_dests, dest_scores,
                                            base_scores, grid_voxels, unit_voxels) or best_end_score

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

    ---------------------------------------------------------------------------------------
    ---- BUGFIX (B17): se o destino vencedor e a posicao de cobertura de onde a unidade ja
    ---- esta peekando, ele vira a POSICAO ATUAL dela em vez de um destino de verdade.
    ----
    ---- Sem isto ela faz vai e volta: entra em shooting stance, peeka para P', o scoring
    ---- elege P (a cobertura de onde saiu), ela anda de volta, ataca, e o
    ---- `EnterShootingStance` a peeka para P' outra vez. Ciclo de 2, o turno inteiro.
    ----
    ---- Trocar o destino -- em vez de tentar ensinar o motor que P e P' sao a mesma coisa
    ---- -- porque os portoes que decidem andar leem a unidade DIRETO, nao o context:
    ---- `BeginMovement` (AIBehaviors.lua:145) e `EndMovement` (:202). Com o destino igual
    ---- a posicao atual, os dois caem em `stance_pos_dist == 0` e devolvem "continue" sem
    ---- emitir Move -- e o `AIPlayAttacks` (CombatAI.lua:211) passa a avaliar o ataque de
    ---- P', que e de onde ela realmente atira.
    ----
    ---- As tabelas indexadas por dest (dest_ap, dest_target, ...) nao precisam da chave
    ---- nova: AIPlayAttacks faz `context.dest_ap[dest] or unit.ActionPoints` e reexecuta
    ---- AIPrecalcDamageScore para o dest que receber.
    ----
    ---- Cobre StandardAI, RetreatAI, ApproachInteractableAI e CustomAI, que pegam o
    ---- destino daqui. NAO cobre PositioningAI, que usa `context.positioning_dest`
    ---- (AIBehaviors.lua:369) -- se a oscilacao aparecer num archetype de posicionamento,
    ---- e ali que falta.
    ---------------------------------------------------------------------------------------
    if RATOAI_IsPeekAnchorDest(unit, context.best_end_dest) then
        context.best_end_dest = GetPackedPosAndStance(unit)
    end

    context.closest_dest = closest_dest
    ---- BUGFIX (B47): fim do passe de End-Turn -- ver o cabecalho onde a bandeira e ligada.
    context.__ratoai_endturn_pass = false
    return context.best_end_dest, context.best_end_score
end
