local debug = false
---TODO: Consider leaving this function as "pre-planning" and moving the more complex logic to when the positions are defined?
function AICalcAttacksAndAim(context, ap, target_dist)

    ------- Fix for min aim
    local unit = context.unit
    unit.AI_dont_return_Stance_min_aim_level = true --- avoiding duplicates. GetBaseAimLevelRange check considers unit position, not future positions like the current function calculates
    local min_aim, max_aim = unit:GetBaseAimLevelRange(context.default_attack, false)
    unit.AI_dont_return_Stance_min_aim_level = false

    local free_move_ap = unit.free_move_ap or 0
    ----

    ---- Shooting Stance checks
    local stance_cost = 0
    local recoil_aim_cost = 0
    local rotation_cost = 0
    local aim_cost = Get_AimCost(unit)

    local not_moved, has_stance

    if IsKindOf(context.weapon, "Firearm") then
        local unit_pos = unit and unit:GetPos()
        local attack_pos = context.attacker_pos

        if context.AIisPlayingAttacks and unit:HasStatusEffect("shooting_stance") then
            has_stance = true
        elseif attack_pos and unit_pos then
            attack_pos = attack_pos:SetTerrainZ()
            unit_pos = unit_pos:SetTerrainZ()

            not_moved = attack_pos == unit_pos
            has_stance = not_moved and context.unit:HasStatusEffect("shooting_stance")
        end

        -------- Persistant recoil aim cost increase
        --- I dont think this is going to work 
        --[[if not_moved then
            local recoil = unit:GetStatusEffect("Rat_recoil")
            if recoil then
                recoil_aim_cost = recoil:ResolveValue("aim_cost")
            end
        end]]

        if has_stance then
            rotation_cost = unit:GetShootingStanceAP(context.current_target, context.weapon, 1,
                                                     context.default_attack, "rotate")
        else
            stance_cost = GetWeapon_StanceAP(unit, context.weapon) + aim_cost
        end
    end
    ------

    local cost = context.default_attack_cost

    ---- Manual Cycling
    local bolting_cost = 0
    local is_unbolted, can_bolt

    if context.weapon and rat_canBolt(context.weapon) then
        can_bolt = true
        bolting_cost = rat_get_manual_cyclingAP(unit, context.weapon, true) * const.Scale.AP
        is_unbolted = context.weapon.unbolted
    end

    if can_bolt and not is_unbolted then ---- if is_unbolted the atk_cost will already have bolting cost
        ap = ap + bolting_cost ----- otherwise, discount the first shot cost
        cost = cost + bolting_cost ---- and increase the atk cost
    end

    ----

    local total_stance_cost = cost + stance_cost

    ---- support for reverting to basic attacks from AIPlayAttacks (always on the same position as the signature)
    if context.AIisPlayingAttacks and unit:HasStatusEffect("shooting_stance") then
        total_stance_cost = 0
        stance_cost = 0
    end

    -- total_stance_cost = (context.ap_after_signature and unit:HasStatusEffect("shooting_stance")) and
    --                         0 or total_stance_cost
    -- stance_cost = (context.ap_after_signature and unit:HasStatusEffect("shooting_stance")) and 0 or
    --                   stance_cost
    ----

    local has_stance_ap = ap >= total_stance_cost

    if not has_stance_ap then ------- Verify if has AP to enter Stance
        stance_cost = 0
        ---RATOAI_TryDegradeToSingleShot(context)
    else ---- and modify min aim level if it has
        min_aim = min_aim + 1
    end
    -------

    local desired_aim_level = GetIdealAimLevels(context, target_dist, max_aim, min_aim)
    ---- PERF (C11.2): removido `local aims = {}` morto aqui -- era redeclarado
    ---- nos dois caminhos de retorno abaixo, entao esta tabela era pura alocacao

    local to_reach_desired_aim_level = desired_aim_level - min_aim

    ------ Debug
    if debug then
        print("----AI calc attacks and aim ----")
        print("min aim = ", min_aim)
        print("has_stance =", has_stance)
        print("not moved = ", not_moved)
        print("base cost = ", cost)
        print("stance cost = ", stance_cost)
        print("rotation_cost = ", rotation_cost)
        print("cycling cost = ", bolting_cost, not is_unbolted)
        -- print("recoil_aim_cost = ", recoil_aim_cost)
        print("total_stance_cost = ", total_stance_cost)
        print("has_stance_ap = ", has_stance_ap)
        print("baseap = ", ap)
        print("free_move_ap = ", free_move_ap)
        -- print("atts = ", num_attacks)
        -- print("remaining ap = ", remaining)
        print("current target = ", context.current_target.session_id)
    end
    ------

    if not has_stance_ap or to_reach_desired_aim_level <= 0 then
        ---- BUGFIX (B14): era `ap / cost`, o AP CRU. Este ramo nao descontava o
        ---- `stance_cost` que a unidade vai pagar para entrar em shooting stance -- o
        ---- caminho normal desconta (`first_atk_cost = stance_cost + rotation_cost +
        ---- cost`), so este nao.
        ----
        ---- Quando mordia: perto, `GetIdealAimLevels` devolve o proprio `min_aim` (o
        ---- nivel 1 ja veio junto com a stance), entao `to_reach` da 0 e cai aqui. A
        ---- estimativa saia com a contagem de disparos de quem NAO preparou e a CTH de
        ---- quem preparou -- os dois melhores lados, inflando justamente os destinos de
        ---- aproximacao colada.
        ----
        ---- Medido em jogo, um turno, 5 unidades: 29 ocorrencias, 33 disparos inflados,
        ---- pior caso 2. Concentrado em 1-9 tiles e AP baixo no destino, com severidade
        ---- proporcional ao custo de stance da arma (2 a 4 AP na amostra).
        ----
        ---- `Max(0, ...)`: sem AP para o primeiro disparo depois de preparar, o certo e
        ---- zero disparos, nao um numero negativo virando teto no `Min`.
        ----
        ---- Nota: quando nao ha AP para a stance, `stance_cost` ja e 0 mais acima e esta
        ---- linha nao muda nada -- o caso do hipfire por falta de AP continua correto.
        local num_atks = Min(context.max_attacks, Max(0, ap - stance_cost) / cost)
        local aims = {}
        for i = 1, num_atks do
            aims[i] = min_aim
        end
        return num_atks, aims
    end

    local remaining_ap = ap

    -- Calculate the cost of the first attack
    local first_atk_cost = stance_cost + rotation_cost + cost
    local remaining_ap_after_first_atk = remaining_ap - first_atk_cost

    -- Determine the first attack aim level
    local aim = min_aim
    if to_reach_desired_aim_level > 0 then
        while remaining_ap_after_first_atk >= aim_cost and aim < desired_aim_level do
            aim = aim + 1
            remaining_ap_after_first_atk = remaining_ap_after_first_atk - aim_cost
        end
    end

    -- Record the first aim level
    local aims = {aim}
    remaining_ap = remaining_ap_after_first_atk

    -- Process subsequent attacks
    local index = 2

    while remaining_ap > 0 do
        local current_aim = min_aim
        local atk_cost = cost
        local max_attacks_reached = index > context.max_attacks

        -- Increase aim level if possible or max attacks reached
        while remaining_ap >= aim_cost and (current_aim < desired_aim_level or max_attacks_reached) do
            current_aim = current_aim + 1
            remaining_ap = remaining_ap - aim_cost
            if max_attacks_reached then
                break
            end
        end

        -- Perform attack if enough AP remains and max attacks not reached
        if remaining_ap >= atk_cost and not max_attacks_reached then
            aims[index] = current_aim
            index = index + 1
            remaining_ap = remaining_ap - atk_cost
        else
            break
        end
    end

    local num_attacks = #aims

    ------ Debug
    if debug then
        print("AI atks and aim = ", num_attacks, aims)
        print("-----------------------------------")
        print(HasPerk(unit, "shooting_stance"))
    end
    ------

    -- ic(#aims, aims)
    return num_attacks, aims
end
