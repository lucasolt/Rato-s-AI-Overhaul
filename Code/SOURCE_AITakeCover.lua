function AITakeCover(unit, context)
    local context = unit.ai_context
    ----------------
    if unit:HasStatusEffect("shooting_stance") then
        return
    end
    ---------------

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B12): a funcao inteira era um no-op por precedencia de operador.
    ----
    ---- Original:  (context.ap_after_signature or 0 <= 0)
    ---- Vanilla:   ((context.ap_after_signature or 0) <= 0)   -- CombatAI.lua:511
    ----
    ---- Em Lua `<=` liga mais forte que `or`, entao a expressao era
    ----     context.ap_after_signature or (0 <= 0)  ==  X or true
    ---- sempre verdadeira -> AITakeCover retornava sempre, e o StanceCrouch gratuito do fim da
    ---- ativacao (linha final) nunca rodava.
    ---------------------------------------------------------------------------------------------
    if unit:HasPreparedAttack() or not context or ((context.ap_after_signature or 0) <= 0) then
        return
    end
    local cover_high, cover_low = GetCoverTypes(unit)
    if not cover_high and not cover_low then
        return
    end
    if unit.species == "Human" and unit.stance ~= "Prone" then
        local context = unit.ai_context
        local chance = context and context.behavior and context.behavior.TakeCoverChance or 0
        if chance > 0 and (chance >= 100 or unit:Random(100) < chance) then
            local dest = GetPackedPosAndStance(unit)
            local enemy_visible = context.enemy_visible
            local enemy_pos = context.enemy_pack_pos_stance
            for _, enemy in ipairs(context.enemies) do
                if (enemy_visible[enemy] and GetCoverFrom(dest, enemy_pos[enemy]) or 0) > 0 then
                    AIPlayCombatAction("TakeCover", unit, 0)
                    return
                end
            end
        end
    end
    if cover_low then
        AIPlayCombatAction("StanceCrouch", unit, 0)
    end
end
