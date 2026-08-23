function OnMsg.CombatActionEnd(unit)
    if unit.action_command == "MGSetup" and R_IsAI(unit) then
        unit.RATOAI_used_mg_setup_this_turn = true

        ---------------------------------------------------------------------------------------
        ---- BUGFIX (B28): montava a MG e atirava em alguem FORA do cone.
        ----
        ---- O filtro de cone existe e esta certo (SOURCE_AIPrecalcDamageScore.lua:187-191):
        ----
        ----     if unit:HasStatusEffect("StationedMachineGun") or ...ManningEmplacement... then
        ----         targets = table.ifilter(targets, function(idx, target)
        ----             return target:IsThreatened({unit}, "overwatch")   -- so quem esta no cone
        ----         end)
        ----     end
        ----
        ---- O problema e a ORDEM, nao o filtro. Dentro de um turno, o AIPlayAttacks
        ---- (CombatAI.lua:216) roda o AIPrecalcDamageScore ANTES de escolher a signature
        ---- action -- ou seja, com a unidade ainda EM PE e SEM a MG montada. O filtro nao
        ---- dispara, o alvo e escolhido livre. Só depois o MGSetup executa e cria o cone. Ao
        ---- voltar, a linha 268 le o alvo que ja estava gravado:
        ----
        ----     local target = (context.dest_target or empty_table)[dest]
        ----
        ---- e atira nele, cone ou nao. O filtro so pegaria no turno SEGUINTE, quando o
        ---- HoldPositionAI "In Setup" refaz o precalc com a unidade ja montada.
        ----
        ---- O conserto reusa o caminho de recuperacao que o proprio vanilla ja tem logo abaixo:
        ----
        ----     if signature_action and (not IsValidTarget(target) or ...) then
        ----         context.dest_ap[dest] = unit.ActionPoints
        ----         context.target_locked = nil
        ----         AIPrecalcDamageScore(context, {dest})
        ----         target = context.dest_target[dest]
        ----     end
        ----
        ---- Apagando o alvo gravado, `IsValidTarget(nil)` e falso e esse bloco refaz o precalc
        ---- -- agora COM o StationedMachineGun aplicado, entao o filtro de cone entra. Nao e
        ---- preciso tocar no AIPlayAttacks.
        ----
        ---- Cuidado registrado: com `TargetChangePolicy = "restart"` esse mesmo bloco reinicia o
        ---- turno inteiro em vez de recalcular. O default e "recalc"
        ---- (ClassDef-AI.generated.lua:33-34) e no items.lua so o `Brute` usa "restart" -- que
        ---- nao monta MG. Ainda assim o guarda esta explicito abaixo: em "restart", nao mexe.
        ----
        ---------------------------------------------------------------------------------------
        local context = unit.ai_context
        if not context or not context.dest_target then
            return
        end
        if not unit:HasStatusEffect("StationedMachineGun") then
            return -- montagem nao vingou (MGPack, rotacao, interrupcao): nada a reajustar
        end
        if context.archetype and context.archetype.TargetChangePolicy == "restart" then
            return
        end

        local dest = context.ai_destination or GetPackedPosAndStance(unit)
        if dest then
            context.dest_target[dest] = nil
            context.target_locked = nil
        end
    end
end

function OnMsg.TurnEnded()
    for _, unit in ipairs(g_Units) do
        unit.RATOAI_used_mg_setup_this_turn = nil
    end
end

--- Moved to GBO combat action GetAPCost

--[[local original_mgpack = Unit.MGPack
function Unit:MGPack()
    if self.RATOAI_used_mg_setup_this_turn then
        return
    end

    original_mgpack(self)
end]]
