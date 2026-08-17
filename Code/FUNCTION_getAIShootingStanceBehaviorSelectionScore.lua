---- Parameters
local angle_ap_threshold = 2 -- AP
local closeness_threshold = 6 -- slab
local distance_to_check_lack_of_cover = 30 -- slab
local effective_range_mul = 150 ---- BUGFIX (B7): era 1.5 (float). Agora percentual.

----- Weights
local weight_close_enemy = -60
local weight_no_cover = -20
local weight_enemy_in_cone = 35
local weight_per_AP_stance = 10
local weight_unbolted = 30

function getAIShootingStanceBehaviorSelectionScore(unit, proto_context)

    --[[if unit:HasStatusEffect("ManningEmplacement") or unit:HasStatusEffect("StationedMachineGun") then
        return 0
    end]]

    if not unit:HasStatusEffect("shooting_stance") then
        return 0
    end

    local voxels, head = unit:GetVisualVoxels()

    if AreVoxelsInFireRange(voxels) or g_SmokeObjs[head] or unit:IsUnderTimedTrap() or
        unit:IsUnderBombard() then
        return 0
    end

    ----- Initialization
    local context = unit.ai_context or AICreateContext(unit, proto_context)
    local weapon = context.weapon or unit:GetActiveWeapons()
    if not weapon or not IsKindOf(weapon, "Firearm") then
        return 0
    end

    if IsKindOfClasses(weapon, "RocketLauncher", "GrenadeLauncher", "Artillery") then
        return 0
    end

    local score = 100
    local no_enemy_in_range = true
    local att_pos = context.unit_pos or unit:GetPos()

    ----- Stance AP score
    local wep_stance_ap = GetWeapon_StanceAP(unit, weapon) or 1000
    score = score + MulDivRound(wep_stance_ap, weight_per_AP_stance, const.Scale.AP)
    -----
    if weapon and rat_canBolt(weapon) then
        score = score + weight_unbolted
    end
    ----

    for enemy, pos in pairs(context.enemy_pos) do
        if not enemy:IsDowned() and context.enemy_visible[enemy] and IsValidPos(pos) and
            IsValidPos(att_pos) then
            local pos = IsValidZ(pos) and pos or pos:SetTerrainZ()
            att_pos = IsValidZ(att_pos) and att_pos or att_pos:SetTerrainZ()
            local dist = att_pos:Dist(pos)

            if dist <= closeness_threshold * const.SlabSizeX then
                score = score + weight_close_enemy
            end

            local enemy_visible = false
            score, enemy_visible = RATOAI_GetEnemyCoverScore(unit, enemy, context, score, att_pos,
                                                             pos, dist)
            score = RATOAI_SelfCoverToEnemyScore(unit, enemy, context, score, att_pos, pos, dist)

            if enemy_visible then
                no_enemy_in_range = false
            end
        end
    end

    score = no_enemy_in_range and 0 or score
    return score
end

function RATOAI_GetEnemyCoverScore(unit, enemy, context, score, att_pos, target_pos, dist,
                                   angle_override)
    local context = context or unit.ai_context
    local weapon = context.weapon or unit:GetActiveWeapons()
    local enemy_in_range = false

    local prone_cover_CTH = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover
    local cover_max_malus = prone_cover_CTH:ResolveValue("Cover")

    if not enemy:IsDowned() and context.enemy_visible[enemy] and IsValidPos(target_pos) and
        IsValidPos(att_pos) then
        local target_pos = IsValidZ(target_pos) and target_pos or target_pos:SetTerrainZ()
        att_pos = IsValidZ(att_pos) and att_pos or att_pos:SetTerrainZ()
        local dist = dist or att_pos:Dist(target_pos)

        local effective_range = MulDivRound(context.EffectiveRange * const.SlabSizeX,
                                            effective_range_mul, 100)
        if dist <= effective_range then

            local angle_ap = angle_override or
                                 unit:GetShootingStanceAP(enemy, weapon, 1, false, "rotate")

            if angle_ap <= angle_ap_threshold * const.Scale.AP then
                local use, value = prone_cover_CTH:CalcValue(unit, enemy, false,
                                                             context.default_attack, weapon, nil,
                                                             nil, 0, false, att_pos, target_pos)

                value = value or 0
                if use then
                    local ratio = 100 - Clamp(MulDivRound(value, 100, cover_max_malus), 0, 100)
                    local add = MulDivRound(weight_enemy_in_cone, ratio, 100)
                    score = score + add
                    -- print("enemy cover", use, enemy.session_id, value, ratio, add)
                end
                enemy_in_range = true
            end
        end
        return score, enemy_in_range
    end
end

function RATOAI_SelfCoverToEnemyScore(unit, enemy, context, score, att_pos, target_pos, dist,
                                      angle_override, w_override)
    local context = context or unit.ai_context
    local weapon = context.weapon or unit:GetActiveWeapons()
    local enemy_in_range = false
    local weight = w_override or weight_no_cover

    local prone_cover_CTH = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover
    local cover_max_malus = prone_cover_CTH:ResolveValue("Cover")
    -- {
    --     Cover = prone_cover_CTH:ResolveValue("Cover"),
    --     Crouch = prone_cover_CTH:ResolveValue("CrouchPenalty"),
    --     Prone = prone_cover_CTH:ResolveValue("PronePenalty")
    -- }

    if not enemy:IsDowned() and context.enemy_visible[enemy] and IsValidPos(target_pos) and
        IsValidPos(att_pos) then
        local target_pos = IsValidZ(target_pos) and target_pos or target_pos:SetTerrainZ()
        att_pos = IsValidZ(att_pos) and att_pos or att_pos:SetTerrainZ()
        local dist = dist or att_pos:Dist(target_pos)

        if dist <= distance_to_check_lack_of_cover * const.SlabSizeX then
            local enemy_weapon = enemy:GetActiveWeapons()
            if enemy_weapon and not enemy_weapon:IsKindOf("MeleeWeapon") then
                local use, value = prone_cover_CTH:CalcValue(enemy, unit, false, nil, enemy_weapon,
                                                             nil, nil, 0, false, target_pos, att_pos)
                value = value or 0
                if use then
                    local max_penalty = cover_max_malus -- cover_max_malus[type_cover] or cover_max_malus.Cover
                    local ratio = 100 - Clamp(MulDivRound(value, 100, cover_max_malus), 0, 100)
                    local add = MulDivRound(weight, ratio, 100)
                    score = score + add
                    -- print("self cover", use, enemy.session_id, value, ratio, add)
                end
            end
        end
    end
    return score
end

