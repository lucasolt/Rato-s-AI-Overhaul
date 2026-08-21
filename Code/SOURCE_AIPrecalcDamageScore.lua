-- local number_of_precalcs = {}
-- function ins_n()
--     Inspect(number_of_precalcs)
-- end
-- function clr_n()
--     number_of_precalcs = {}
-- end
---- DEBUG (D1): linha por alvo dentro de um destino. Funcao de arquivo e nao closure
---- dentro do laco -- o laco de destinos e quente e nao vale alocar uma closure por
---- destino so para o modo de debug.
local function DbgRow(dbg_dest, target)
    local row = dbg_dest.by_target[target]
    if not row then
        row = {}
        dbg_dest.by_target[target] = row
    end
    return row
end

function AIPrecalcDamageScore(context, destinations, preferred_target, debug_data)
    local unit = context.unit

    local weapon = context.weapon
    local action = CombatActions[context.override_attack_id or false] or context.default_attack
    local archetype = context.archetype
    local behavior = context.behavior

    ---- PERF (C8): Update_AIPrecalcDamageScore e chamado POR DESTINO
    ---- (AIPolicyCustomFlanking:EvalDest, AIPolicyMGSetupPosScore:EvalDest) e usa
    ---- `damage_score_precalced` como guard. Mas essa flag so era setada mais
    ---- abaixo, depois de tres `return` prematuros -- entao unidade queimando, sem
    ---- arma, em reposicao ou sem alvos validos reexecutava action:GetTargets() +
    ---- table.ifilter a CADA destino.
    ---- Flag separada para "ja tentei", que nao pode ser confundida com
    ---- "tenho dados de dano validos" (o que damage_score_precalced sinaliza para
    ---- CustomFlanking e para o GetDestArgs de SignaturesCustomScoring).
    ---- So se aplica quando destinations == nil, que e a forma usada por
    ---- Update_AIPrecalcDamageScore. Chamadas com destinos explicitos passam direto.
    if not destinations then
        if context.damage_score_attempted then
            return
        end
        context.damage_score_attempted = true
    end

    if not weapon or context.reposition or unit:HasStatusEffect("Burning") then
        return
    end
    if not destinations and context.damage_score_precalced then
        return
    end

    local action_targets = action:GetTargets({unit})
    local targets = table.ifilter(action_targets, function(idx, target)
        return unit:IsOnEnemySide(target)
    end)
    if #targets == 0 then
        return
    end
    context.damage_score_precalced = true

    -----
    -- if not number_of_precalcs[unit.session_id] then
    --     number_of_precalcs[unit.session_id] = 0
    -- end
    -- number_of_precalcs[unit.session_id] = number_of_precalcs[unit.session_id] + 1
    -- if number_of_precalcs[unit.session_id] > 1 then
    --     bp()
    -- end
    ----

    ---- DEBUG (D1): tabelas por (destino, ALVO). Ate aqui so o alvo VENCEDOR sobrevivia
    ---- desta funcao -- dest_cth/dest_hit_score/dest_target_score guardam best_*, e as
    ---- tabelas target_cth/target_hit/target_score sao locais do laco de destinos. Sem
    ---- isto nao ha como perguntar "e contra o alvo #3, quanto seria o CTH".
    ---- Mesmo criterio de custo do PERF (C9): so existe com RATOAI_Debug.
    local dbg = RATOAI_Debug
    if dbg then
        ---- zerado a cada chamada: e sempre o ultimo precalc que a UI esta olhando.
        ---- `dbg_target_list` NAO e gravado aqui -- `targets` ainda vai ser reatribuido
        ---- pelo filtro de StationedMachineGun/ManningEmplacement mais abaixo, e guardar
        ---- a referencia antiga faria a UI listar alvos que a IA nem chegou a percorrer.
        context.dbg_targets = {}
        context.dbg_target_list = nil
    end

    local target_score_mod = {}
    local tsr = archetype.TargetScoreRandomization
    ---- DEBUG (D1): com `dbg_freeze_target_rand` (setada so pela IModeAIDebug antes de
    ---- reexecutar o precalc) a randomizacao por alvo e reaproveitada em vez de
    ---- re-sorteada -- senao o numero que se esta investigando muda so por ter sido
    ---- observado. O RandRange e SEMPRE consumido, mesmo congelado: pular a chamada
    ---- dessincronizaria o fluxo de RNG da unidade.
    local frozen = context.dbg_freeze_target_rand and context.dbg_target_score_mod_frozen
    for i, target in ipairs(targets) do
        local roll = 100 + ((tsr > 0) and unit:RandRange(-tsr, tsr) or 0)
        target_score_mod[i] = frozen and frozen[target] or roll
    end
    context.target_score_mod = target_score_mod

    if context.dbg_freeze_target_rand then
        local by_target = {}
        for i, target in ipairs(targets) do
            by_target[target] = target_score_mod[i]
        end
        context.dbg_target_score_mod_frozen = by_target
    end

    local base_mod = unit[weapon.base_skill]
    local cost_ap = context.override_attack_cost or context.default_attack_cost

    local max_check_range, is_melee = AIGetWeaponCheckRange(unit, weapon, action)
    local is_heavy = IsKindOf(weapon, "HeavyWeapon")

    ---- BUGFIX (B21): balas por ataque, para RATOAI_BurstHits expandir a rajada.
    ---- Depende so de (arma, acao) -- nem do destino nem do alvo -- entao e resolvido
    ---- UMA vez aqui em vez de por par no laco quente. `GetAutofireShots` devolve 0 ou
    ---- nil para tiro unico, dai o Max(1, ...).
    context.burst_shots = 1
    if weapon and weapon.GetAutofireShots then
        context.burst_shots = Max(1, weapon:GetAutofireShots(action) or 1)
    end

    local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]
    -- stance mod
    -- TODO: #64 check messing around with modCrouchBonus and modProneBonus
    local modCrouchBonus = 0
    local modProneBonus = 0
    -- if IsKindOf(weapon, "Firearm") then
    -- modCrouchBonus = hit_modifiers.AttackerStance:ResolveValue("CrouchBonus")
    -- modProneBonus = hit_modifiers.AttackerStance:ResolveValue("ProneBonus")
    local value = GetComponentEffectValue(weapon, "AccuracyBonusProne", "bonus_cth")
    if value then
        modProneBonus = modProneBonus + value
    end
    -- end
    -- ground difference mod
    local MinGroundDifference = hit_modifiers.GroundDifference:ResolveValue("RangeThreshold") *
                                    const.SlabSizeZ / 100
    local modHighGround = hit_modifiers.GroundDifference:ResolveValue("HighGround")
    local modLowGround = hit_modifiers.GroundDifference:ResolveValue("LowGround")
    -- cover
    local modCover = hit_modifiers.RangeAttackTargetStanceCover:ResolveValue("Cover")
    local modSameTarget = hit_modifiers.SameTarget:ResolveValue("Bonus")

    local target_policies = archetype.TargetingPolicies
    if behavior and #(behavior.TargetingPolicies or empty_table) > 0 then
        target_policies = behavior.TargetingPolicies
    end

    local dest_target = context.dest_target
    local dest_target_score = context.dest_target_score
    local dest_ap = context.dest_ap
    local aim_mod = Presets.ChanceToHitModifier.Default.Aim
    ---
    local pb_cth_mod = Presets.ChanceToHitModifier.Default.PointBlank
    local scope_cth_mod = Presets.ChanceToHitModifier.Default.ScopePenal
    ---
    local dest_cth = {}
    context.dest_cth = dest_cth
    ---- BUGFIX (B10): score de acerto LIMPO, so a soma de CTH sobre os disparos
    ---- (ou seja, acertos esperados x100). Serve para o AIPolicyDealDamage, que e
    ---- uma policy de POSICAO e nao deve carregar Marksmanship, TargetingPolicies
    ---- nem a randomizacao -- esses pertencem a escolha de ALVO.
    local dest_hit_score = {}
    context.dest_hit_score = dest_hit_score
    local lof_params
    local attacker_pos = unit:GetPos()

    -- script-driven modifiers (based on groups)
    local target_modifiers
    for _, groupname in ipairs(unit.Groups) do
        local group_modifiers = gv_AITargetModifiers[groupname]
        for target_group, mod in pairs(group_modifiers) do
            target_modifiers = target_modifiers or {}
            target_modifiers[target_group] = (target_modifiers[target_group] or 0) + mod
            for _, obj in ipairs(Groups[target_group]) do
                if IsKindOf(obj, "Unit") and not table.find(targets, obj) then
                    table.insert(targets, obj) -- make sure the target is considired regardless if it's an enemy or not
                    table.insert(target_score_mod,
                                 100 + ((tsr > 0) and unit:RandRange(-tsr, tsr) or 0))
                end
            end
        end
    end

    if unit:HasStatusEffect("StationedMachineGun") or unit:HasStatusEffect("ManningEmplacement") then
        local ow_units = {unit}
        targets = table.ifilter(targets, function(idx, target)
            return target:IsThreatened(ow_units, "overwatch")
        end)
    end

    if not IsValidTarget(preferred_target) or
        (IsKindOf(preferred_target, "Unit") and preferred_target:IsIncapacitated() or
            not table.find(targets, preferred_target)) then
        preferred_target = nil
    end

    if weapon and not is_melee then
        lof_params = {
            obj = unit,
            action_id = action.id,
            weapon = weapon,
            step_pos = false,
            stance = false,
            range = max_check_range,
            prediction = true,
            output_collisions = true
        }
        if not destinations or #destinations > 1 then
            lof_params.target_spot_group = "Torso"
        end
    end
    --[[	local logdata = {}
	if destinations then
		table.insert(g_AIDamageScoreLog, logdata)
	end
	logdata.preferred_target = preferred_target and (IsKindOf(preferred_target, "Unit") and _InternalTranslate(preferred_target.Name or "") or preferred_target.class) or tostring(preferred_target)--]]
    destinations = destinations or context.destinations
    NetUpdateHash("AIPrecalcDamageScore", unit, hashParamTable(destinations),
                  hashParamTable(targets), preferred_target)

    ---- DEBUG (D1): aqui `targets` ja passou por todas as reatribuicoes (alvos de grupo
    ---- injetados, filtro de emplacement) -- e exatamente a lista que o laco abaixo vai
    ---- percorrer. Ela pode divergir de context.enemies, que era o que a pagina Alvo
    ---- iterava antes.
    if dbg then
        context.dbg_target_list = targets
    end

    ---- PERF (C4): [alvo] -> { [distancia em slabs] -> recoil }. Vive so nesta
    ---- chamada, cobrindo todos os destinos do laco abaixo.
    local recoil_cache = {}

    for j, upos in ipairs(destinations) do
        local ux, uy, uz, ustance_idx = stance_pos_unpack(upos)
        local ustance = StancesList[ustance_idx]
        uz = uz or terrain.GetHeight(ux, uy)

        local ap = dest_ap[upos] or 0
        local best_target, best_cth, best_hit
        local best_score = 0
        local potential_targets, target_score, target_cth = {}, {}, {}
        local target_hit = {} ---- BUGFIX (B10)

        ------------------ Recoil storage -- Only best target goes to context
        local recoil_score = {}
        ------------------

        ------> refactor to follow dest_target_dist model			
        local target_covers = {}
        local target_los = {}
        context.dest_target_dist[upos] = {}
        ----

        ------------------ Debug
        local old_scores_dbg, old_cth_debug = {}, {}
        ------------------

        ---- DEBUG (D1)
        local dbg_dest
        if dbg then
            dbg_dest = {ap = ap, cost_ap = cost_ap, by_target = {}}
            context.dbg_targets[upos] = dbg_dest
            if not (weapon and ap >= cost_ap) then
                dbg_dest.no_ap = true
            end
        end

        if weapon and ap >= cost_ap then
            local pos_mod = base_mod
            pos_mod = pos_mod +
                          (ustance_idx == 2 and modCrouchBonus or ustance_idx == 3 and modProneBonus or
                              0)

            local targets_attack_data
            if not is_melee then
                attacker_pos = point(ux, uy, uz)
                lof_params.step_pos = point_pack(ux, uy, uz)
                lof_params.stance = ustance
                targets_attack_data = GetLoFData(unit, targets, lof_params)
                ---- temporary
                context.attacker_pos = attacker_pos
                ----
            end

            for k, target in ipairs(targets) do
                local tpos = GetPackedPosAndStance(target)
                local dist = stance_pos_dist(upos, tpos)
                ---- temporary
                context.current_target = target
                ---

                ----
                context.dest_target_dist[upos][target] = dist
                ----

                ---- DEBUG (D1): o gate abaixo era uma expressao unica; quebrado em duas
                ---- para poder registrar QUAL das condicoes descartou o alvo. Antes,
                ---- "fora de alcance", "sem linha de fogo" e "CTH zero" eram todos o
                ---- mesmo `-` na tabela de candidatos.
                ---- `lof_ok` so avalia targets_attack_data quando `in_range` -- mesma
                ---- ordem de curto-circuito da expressao original.
                local in_range = dist <= (max_check_range or dist)
                local lof_ok = in_range and
                                   (is_melee or
                                       (targets_attack_data[k] and
                                           not targets_attack_data[k].stuck)) and true or false

                if dbg_dest then
                    local row = DbgRow(dbg_dest, target)
                    row.dist = dist
                    if not in_range then
                        row.reject = "fora de alcance"
                    elseif not lof_ok then
                        local ad = targets_attack_data and targets_attack_data[k]
                        row.reject = (ad and ad.stuck) and "linha de fogo bloqueada" or
                                         "sem linha de fogo"
                    end
                end

                if lof_ok then

                    ------ Recoil CTH Calculation
                    ---- PERF (C3): movido para DENTRO do gate de alcance/LOF.
                    ---- Antes rodava para todo (destino, alvo), inclusive alvos fora
                    ---- de alcance ou sem linha de fogo, cujo valor era descartado.
                    ---- Seguro porque best_target so pode ser um alvo que passou aqui.
                    ---- PERF (C4): cache por bucket de distancia em slabs. Em
                    ---- get_recoil a UNICA entrada que varia entre destinos e `dist`;
                    ---- todo o resto (GetWepRecoil, GetRecoilOther, GetCaliberStrRecoil,
                    ---- GBO_GetROF, bloco de MG) depende so de arma/atacante/acao.
                    ---- O `dist` ja entra numa interpolacao linear grosseira, entao
                    ---- quantizar por slab custa menos de um ponto de CTH.
                    local recoil_cth = 0

                    if IsKindOf(weapon, "Firearm") then
                        local by_dist = recoil_cache[target]
                        if not by_dist then
                            by_dist = {}
                            recoil_cache[target] = by_dist
                        end
                        local slab = dist / const.SlabSizeX
                        recoil_cth = by_dist[slab]
                        if not recoil_cth then
                            recoil_cth = get_recoil(unit, target, target:GetPos(),
                                                    context.default_attack, weapon, nil,
                                                    weapon:GetAutofireShots(context.default_attack),
                                                    nil, nil, nil, nil, nil, attacker_pos)
                            by_dist[slab] = recoil_cth
                        end
                    end

                    recoil_score[target] = recoil_cth
                    -------------

                    ------------ RATO AI precalc
                    local mod = 0

                    ---- BUGFIX (B1): `shot_cth` e a chance de acerto real do PRIMEIRO
                    ---- disparo neste par (destino, alvo). Antes, o que era gravado em
                    ---- context.dest_cth era a variavel externa `base_mod`
                    ---- (= unit[weapon.base_skill], a Marksmanship crua): a declaracao
                    ---- interna do source que a sombreava com a CTH calculada
                    ---- (`local base_mod = mod`) desapareceu quando este bloco
                    ---- substituiu o do vanilla. Como dest_cth e o DENOMINADOR de todas
                    ---- as CustomScoring, distancia e cobertura nao chegavam a
                    ---- influenciar nenhuma escolha de acao especial.
                    ----
                    ---- Usar a CTH de UM disparo, e nao a soma dos N ataques: as
                    ---- penalidades comparadas contra ela (recoil, hipfire, tiro
                    ---- localizado) sao todas por disparo. Somar N diluiria a razao
                    ---- pelo numero de ataques que cabem no AP.
                    local shot_cth

                    if CurrentModOptions.UseSimpleAttacksScoring then
                        ------ Old logic
                        mod, target_covers, target_los, shot_cth =
                            RATOAI_ScoreAttacks_Simple(mod, target, dist, upos, tpos, uz, k, dist,
                                                       ap, context, action, weapon,
                                                       targets_attack_data, target_covers,
                                                       target_los, attacker_pos)
                    else
                        mod, target_covers, target_los, shot_cth =
                            RATOAI_ScoreAttacksDetailed(mod, target, dist, upos, tpos, uz, k, ap,
                                                        context, action, weapon,
                                                        targets_attack_data, target_covers,
                                                        target_los, attacker_pos, recoil_cth)
                    end

                    shot_cth = shot_cth or 0

                    ---- DEBUG (D1)
                    if dbg_dest then
                        local row = DbgRow(dbg_dest, target)
                        row.recoil = recoil_cth
                        row.cth1 = shot_cth
                        row.cover = target_covers[target]
                        row.los = target_los[target]
                        ---- o proprio comprimento da lista de CTH por disparo e a
                        ---- contagem de tiros que AICalcAttacksAndAim devolveu para
                        ---- ESTE alvo -- ela varia com a distancia, entao dois alvos
                        ---- nao sao comparaveis so pela soma de CTH
                        local shots = context.cth_attacks_at[upos] and
                                          context.cth_attacks_at[upos][target]
                        row.shots = shots and #shots or nil
                        if not (mod > const.AIShootAboveCTH) then
                            row.reject = string.format("soma de CTH %d <= %d", mod,
                                                       const.AIShootAboveCTH)
                        end
                    end

                    if mod > const.AIShootAboveCTH then
                        ---- BUGFIX (B10): neste ponto `mod` ainda e a soma pura de CTH
                        ---- devolvida por RATOAI_ScoreAttacks*. Tudo abaixo mistura
                        ---- unidades diferentes no mesmo numero.
                        local hit_score = mod
                        -------------
                        ---- DEBUG (D1): instantaneo de `mod` depois de cada etapa. A
                        ---- pergunta "por que este alvo" quase sempre e "qual destas
                        ---- etapas dominou", e nenhuma delas era observavel.
                        local dbg_chain = dbg_dest and {hit = hit_score}
                        -------------
                        mod = mod + pos_mod
                        if dbg_chain then
                            dbg_chain.pos = mod
                        end
                        -------------------------------------------------------------------------------------------
                        -- Vanilla
                        ---------------------------------------
                        -- modify score by archetype-specific weight and (optional) targeting policies
                        mod = MulDivRound(mod, archetype.TargetBaseScore, 100)
                        if dbg_chain then
                            dbg_chain.base = mod
                        end
                        for _, policy in ipairs(target_policies) do
                            local peval = policy:EvalTarget(unit, target)
                            mod = mod + MulDivRound(peval or 0, policy.Weight, 100)
                            if dbg_chain then
                                dbg_chain.pol_parts = dbg_chain.pol_parts or {}
                                table.insert(dbg_chain.pol_parts, {
                                    name = policy.class,
                                    value = MulDivRound(peval or 0, policy.Weight, 100),
                                })
                            end
                        end
                        if dbg_chain then
                            dbg_chain.pol = mod
                        end

                        if IsKindOf(target, "Unit") and
                            (target:IsDowned() or target:IsGettingDowned()) then
                            mod = MulDivRound(mod, 5, 100)
                            if dbg_chain then
                                dbg_chain.downed = mod
                            end
                        end

                        local attack_data = targets_attack_data and targets_attack_data[k]
                        local ally_in_danger = attack_data and
                                                   (attack_data.best_ally_hits_count or 0) > 0

                        if action and action.AimType == "cone" then
                            ally_in_danger = ally_in_danger or
                                                 AIAllyInDanger(context.allies, context.ally_pos,
                                                                attacker_pos, target,
                                                                const.AIFriendlyFire_LOFConeNear,
                                                                const.AIFriendlyFire_LOFConeFar)
                        else
                            ally_in_danger = ally_in_danger or
                                                 AIAllyInDanger(context.allies, context.ally_pos,
                                                                attacker_pos, target,
                                                                const.AIFriendlyFire_LOFWidth,
                                                                const.AIFriendlyFire_LOFWidth)
                        end
                        if ally_in_danger then
                            mod = MulDivRound(mod, const.AIFriendlyFire_ScoreMod, 100)
                            if dbg_chain then
                                dbg_chain.ff = mod
                            end
                        end

                        mod = MulDivRound(mod, target_score_mod[k], 100)
                        if dbg_chain then
                            dbg_chain.rnd = mod
                            dbg_chain.rnd_pct = target_score_mod[k]
                        end

                        -- apply group-based modifiers
                        if target_modifiers and IsKindOf(target, "Unit") then
                            local group_mod = 0
                            for _, groupname in ipairs(target.Groups) do
                                group_mod = group_mod + (target_modifiers[groupname] or 0)
                            end
                            if group_mod > 0 then
                                mod = MulDivRound(mod, group_mod, 100)
                                if dbg_chain then
                                    dbg_chain.group = mod
                                    dbg_chain.group_pct = group_mod
                                end
                            end
                        end

                        ---- DEBUG (D1): gravado ANTES do desvio de preferred_target, que
                        ---- da `break` e sairia sem registrar a linha deste alvo
                        if dbg_dest then
                            local row = DbgRow(dbg_dest, target)
                            dbg_chain.final = mod
                            row.chain = dbg_chain
                            row.hit = hit_score
                            row.score = mod
                        end

                        --[[table.insert(logdata, {
							name = IsKindOf(target, "Unit") and _InternalTranslate(target.Name or "") or target.class,
							score = mod
						})--]]

                        if mod > 0 and target == preferred_target then
                            best_target = target
                            best_score = mod
                            best_cth = shot_cth ---- BUGFIX (B1): era `base_mod` (Marksmanship)
                            best_hit = hit_score ---- BUGFIX (B10)
                            potential_targets = {}
                            if dbg_dest then
                                dbg_dest.preferred = target
                            end
                            break
                        end

                        ----------------- DEBUG
                        ------------

                        best_score = Max(best_score, mod)
                        target_cth[target] = shot_cth ---- BUGFIX (B1): era `base_mod`
                        target_hit[target] = hit_score ---- BUGFIX (B10)
                        target_score[target] = mod

                        local threshold = MulDivRound(best_score or 0, const.AIDecisionThreshold,
                                                      100)
                        if mod >= threshold then
                            potential_targets[#potential_targets + 1] = target
                            for i = #potential_targets, 1, -1 do
                                local target = potential_targets[i]
                                local score = target_score[target]
                                if score < threshold then
                                    table.remove(potential_targets, i)
                                end
                            end
                            -- best_target, best_score, best_cth = target, mod, base_mod
                        end

                        ----- Clear Context from my additions
                        context.current_target = nil
                        context.attacker_pos = nil
                        -----
                    end
                end
            end
        end

        ------- looped all targets in this pos, store in the context
        context.dest_target_cover_score[upos] = target_covers
        context.dest_target_los[upos] = target_los
        -------

        ---- DEBUG (D1): o corte dos 80% e o sorteio. `best_target` NAO e o de maior
        ---- score -- e um sorteio ponderado entre os finalistas -- entao sem `roll` e
        ---- `total` nao ha como separar "o scoring escolheu mal" de "o dado caiu assim".
        if dbg_dest then
            dbg_dest.best_score = best_score
            dbg_dest.threshold = MulDivRound(best_score or 0, const.AIDecisionThreshold, 100)
            dbg_dest.finalists = potential_targets
        end

        if #potential_targets > 0 then
            local total = 0
            for _, target in ipairs(potential_targets) do
                local score = target_score[target]
                total = total + score
                if debug_data then
                    debug_data[target] = score
                end
            end
            local roll = InteractionRand(total, "AIDecision")
            if dbg_dest then
                dbg_dest.total = total
                dbg_dest.roll = roll
            end
            for _, target in ipairs(potential_targets) do
                local score = target_score[target]
                if roll < score then
                    best_target = target
                    break
                end
                roll = roll - score
            end
            best_target = best_target or potential_targets[#potential_targets] or false
            best_score = target_score[best_target] or 0
            best_cth = target_cth[best_target] or 0
            best_hit = target_hit[best_target] or 0 ---- BUGFIX (B10)

            --[[print("-------------------")
            ic(best_target.session_id)
            ic(best_score)
            ic(old_scores_dbg[best_target])
            ic(best_cth)
            ic(old_cth_debug[best_target])
            ic(recoil_score_dbg[best_target])
            print("-------------------")]]
        end

        --[[
		if destinations and IsKindOf(best_target, "Unit") then
			if best_target == preferred_target then
				printf("%s (%d) selected target (preferred): %s (score %d)", _InternalTranslate(unit.Name or ""), unit.handle, _InternalTranslate(best_target.Name or ""), best_score)
			else
				printf("%s (%d) selected target: %s (score %d)", _InternalTranslate(unit.Name or ""), unit.handle, _InternalTranslate(best_target.Name or ""), best_score)
				printf("  potential targets:")
				for _, target in ipairs(potential_targets) do
					printf("    %s (score %d)", _InternalTranslate(target.Name or ""), target_score[target])
				end
			end
		end--]]

        -- logdata.chosen_target = best_target and (IsKindOf(best_target, "Unit") and _InternalTranslate(best_target.Name or "") or best_target.class) or tostring(best_target)

        ------------------------------
        context.dest_target_recoil_cth[upos] = recoil_score[best_target]
        ------------------------------

        dest_target_score[upos] = best_score ------ This defines DealDamage policy score
        dest_target[upos] = best_target
        dest_cth[upos] = best_cth
        dest_hit_score[upos] = best_hit or 0 ---- BUGFIX (B10)

        ---- DEBUG (D1)
        if dbg_dest then
            dbg_dest.chosen = best_target or nil
        end

        ----Debug vectors
        -- local dux, duy, duz, dustance_idx = stance_pos_unpack(upos)
        -- local debug_score_pos = point(dux, duy, duz)

        -- if best_cth and best_cth > 0 and best_target then
        --     DbgAddText(best_cth, debug_score_pos)
        --     DbgAddVector(debug_score_pos, best_target:GetPos() - debug_score_pos)
        -- end
        -----
    end
end
