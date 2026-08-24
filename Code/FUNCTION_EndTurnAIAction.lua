function OnMsg.TurnEnded(teamId)
    local t = g_Teams and g_Teams[teamId]
    if t and not (t.side == NetPlayerSide()) then
        for _, unit in ipairs(g_Units) do
            if R_IsAI(unit) then
                RATOAI_EndTurnAIAction(unit)
            end
        end
    end
end

function OnMsg.CombatEnd()
    for _, unit in ipairs(g_Units) do
        if R_IsAI(unit) and unit.RATOAI_ChangedStance then
            unit.RATOAI_ChangedStance = false
            if unit.stance ~= "Standing" and not (unit:IsDead() or unit:IsDowned()) then
                print("RATOAI DEBUG: Resetting stance for unit " .. unit:GetDisplayName())
                unit:SetActionCommand("ChangeStance", nil, nil, "Standing")
            end
        end
    end
end

function RATOAI_EndTurnAIAction(unit)

    if not CurrentThread() then
        CreateGameTimeThread(RATOAI_EndTurnAIAction, unit)
        return
    end

    if unit:HasStatusEffect("Unaware") or unit:IsDead() or unit:IsDowned() then
        return
    end

    RATOAI_EndTurnCycleWeapon(unit)
    -- RATOAI_TryChangeStance(unit)
    -- RATOAI_TryEnterShootingStance(unit)

    ---- Make sure we are not saving AP that we spent in the actions in this function
    local ap = unit.ActionPoints
    local effect = unit:GetStatusEffect("shooting_stance")
    if effect then
        local saved_ap = effect:ResolveValue("AP_Carried") or 0
        saved_ap = Min(ap, saved_ap)
        effect:SetParameter('AP_Carried', saved_ap)
    end
    ----
end

function RATOAI_EndTurnCycleWeapon(unit)
    local context = unit.ai_context
    local weapon = context and context.weapon or unit:GetActiveWeapons()
    if rat_canBolt(weapon) then
        return rat_endturn_bolt(weapon, nil, unit)
    end
    return 0
end

function RATOAI_TryEnterShootingStance(unit)
    if unit:HasPreparedAttack() or unit:HasStatusEffect("ManningEmplacement") or
        unit:HasStatusEffect("StationedMachineGun") then
        return 0
    end

    local ap = unit.ActionPoints
    local weapon = unit:GetActiveWeapons()

    if not weapon or not IsKindOf(weapon, "Firearm") then
        return 0
    end

    if IsKindOfClasses(weapon, "RocketLauncher", "GrenadeLauncher", "Artillery") then
        return 0
    end

    local target = unit:GetClosestEnemy()

    if not target then
        local enemies = table.icopy(GetEnemies(unit))
        if #(enemies or empty_table) == 0 then
            enemies = table.ifilter(GetAllEnemyUnits(unit), function(idx, enemy)
                return not enemy:HasStatusEffect("Hidden")
            end)
        end
        for _, enemy in ipairs(enemies) do
            if enemy.last_attack_pos then
                target = enemy.last_attack_pos
                break
            end
        end
    end

    if not target then
        return 0
    end

    local cost = unit:GetShootingStanceAP(target, weapon, 1)
    if cost > 0 and ap >= cost then
        unit:SetActionCommand("ShootingStanceCommand", "RATOAI_EndTurn_PrepareWeapon", cost,
                              {target = target})
        unit.ActionPoints = unit.ActionPoints - cost
        return cost
    end

    return 0
end

function RATOAI_TryChangeStance(unit)

    if not g_Combat then
        return 0
    end

    if unit:HasPreparedAttack() then
        return 0
    end

    local weapon = unit:GetActiveWeapons()
    if not weapon or not IsKindOf(weapon, "Firearm") then
        return 0
    end

    local stance_effect = unit:GetStatusEffect("shooting_stance")
    local aim_pos = GetAimPos_ShootingStance(stance_effect)

    local angle
    if aim_pos then
        angle = CalcOrientation(unit:GetPos(), aim_pos)
    end

    if unit.species == "Human" and unit.stance ~= "Prone" then
        local cover_high, cover_low = GetCoverTypes(unit)
        local ap = unit.ActionPoints
        if not cover_high and not cover_low then
            local prone_AP = unit.stance == "Crouch" and 1000 or 2000
            if HasPerk(unit, "HitTheDeck") then
                prone_AP = 0
            end
            if ap >= prone_AP then
                unit:SetActionCommand("ChangeStance", "RATOAI_ChangeStance", prone_AP, "Prone")
                unit.ActionPoints = unit.ActionPoints - prone_AP
                unit.RATOAI_ChangedStance = true
                if angle then
                    -- Sleep(1000)
                    unit:AnimatedRotation(angle)
                    -- unit:SetCommand("AnimatedRotation", angle)
                end
                return prone_AP
            end
        end

        if unit.stance ~= "Crouch" then
            local crouch_ap = 1000
            if ap >= crouch_ap then
                unit:SetActionCommand("ChangeStance", "RATOAI_ChangeStance", crouch_ap, "Crouch")
                unit.ActionPoints = unit.ActionPoints - crouch_ap
                unit.RATOAI_ChangedStance = true
                if angle then
                    -- Sleep(1000)
                    unit:AnimatedRotation(angle)
                    -- unit:SetCommand("AnimatedRotation", angle)
                end
                return crouch_ap
            end
        end
    end
    return 0
end

