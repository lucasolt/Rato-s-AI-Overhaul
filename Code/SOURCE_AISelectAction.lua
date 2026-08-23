function AISelectAction(context, actions, base_weight, dbg_available_actions)
    local available = {}
    local weight = base_weight or 0
    --------- base_weight is from the default attack
    ---context.choose_actions = {{action = false, weight = weight, priority = false}}

    context.action_states = context.action_states or {}

    for _, action in ipairs(actions) do

        context.action_states[action] = {}
        local weight_mod, disable, priority = AIGetBias(action.BiasId, context.unit)

        --------------------------------------------
        ---- PERF (C12): CustomScoring rodava para TODA acao, inclusive as que
        ---- seriam descartadas pelo bias na linha seguinte. Cada uma passa por
        ---- GetDestArgs -> Update_AIPrecalcDamageScore e varias fazem CalcValue
        ---- de presets. Agora so roda para acoes que sobreviveram ao gate.
        disable = disable or context.disable_actions[action.BiasId or false]

        local c_action_weight, action_priority, custom_disable
        if not disable then
            c_action_weight, custom_disable, action_priority = action:CustomScoring(context)
            disable = custom_disable
        end
        --------------------------------------------

        if not disable then

            action:PrecalcAction(context, context.action_states[action])
            if action:IsAvailable(context, context.action_states[action]) then
                --------------------------------------------
                -- local action_weight = MulDivRound(action.Weight, weight_mod, 100)
                local action_weight = MulDivRound(c_action_weight, weight_mod, 100)

                -- priority = priority or action.Priority
                priority = priority or action_priority
                --------------------------------------------

                if dbg_available_actions then
                    table.insert(dbg_available_actions,
                                 {action = action, weight = action_weight, priority = priority})
                end
                if priority then
                    return action
                end
                available[#available + 1] = action
                ----
                available[action] = action_weight
                ---
                weight = weight + action_weight
            elseif dbg_available_actions then
                table.insert(dbg_available_actions, {action = action, weight = false})
            end

            -----------------------------------------------------------------------------------
            ---- DEBUG (D5): DESABILITADA nao e o mesmo que INDISPONIVEL, e o painel nao tinha
            ---- como distinguir -- porque a acao desabilitada simplesmente NAO ERA INSERIDA e
            ---- sumia da lista. Quem olhava via uma lista com um item a menos e nenhuma pista
            ---- de que ele existia.
            ----
            ---- Os dois estados sao portoes diferentes e param em pontos diferentes do laco:
            ----   desabilitada  -- bias, `disable_actions` ou o 2o retorno da CustomScoring.
            ----                    O PrecalcAction NEM RODA, entao o `action_state` fica vazio
            ----                    e o `IndisponivelPorque` do painel nao tem o que ler.
            ----   indisponivel  -- passou pelo gate, o PrecalcAction rodou, e o IsAvailable
            ----                    reprovou (AP, municao, CTH, alvo).
            ----
            ---- `weight = false` nos dois casos, que e a forma que o painel ja sabe pintar de
            ---- cinza; `disabled_by` e o que separa um do outro.
            -----------------------------------------------------------------------------------
        elseif dbg_available_actions then
            table.insert(dbg_available_actions, {
                action = action,
                weight = false,
                disabled_by = custom_disable and "CustomScoring" or "bias"
            })
        end
    end

    if not available then
        return
    end

    if weight > 0 then
        local roll = InteractionRand(weight, "AISignatureAction", context.unit)

        for _, action in ipairs(available) do
            local w = available[action]

            if roll <= w then
                return action
            end

            roll = roll - w
        end
    end

    return -- available[#available]
end

