function AIActionBaseZoneAttack:EvalZones(context, zones)
    return AIEvalZones(context, zones, self.min_score, self.enemy_score, self.team_score,
                       self.self_score_mod, self.enemy_cover_mod, self.EnemyPreparedAttackScore,
                       self.AllyThreatenedScore) -- , self.enemy_height_mod)
    --- addition of "self.enemy_cover_mod" and "enemy_height_mod"
end

function AIEvalZones(context, zones, min_score, enemy_score, team_score, self_score_mod,
                     enemy_cover_score, enemy_prepared_attack_score, ally_threatened_score) -- , heigth_score)
    local best_target, best_score = nil, (min_score or 0) - 1

    for _, zone in ipairs(zones) do
        local score
        local selfmod = 0
        for _, unit in ipairs(zone.units) do
            local uscore = 0
            if not unit:IsDead() and not unit:IsDowned() then
                if unit:IsOnEnemySide(context.unit) then

                    uscore = enemy_score or 0
                    -----------------------------------

                    if enemy_cover_score and enemy_cover_score ~= 0 then
                        local cover_high, cover_low = GetCoverTypes(unit)
                        if cover_low or cover_high then
                            uscore = uscore + enemy_cover_score
                        end
                    end

                    if enemy_prepared_attack_score and enemy_prepared_attack_score ~= 0 then
                        if g_Overwatch[unit] then
                            uscore = uscore + enemy_prepared_attack_score
                        end
                    end

                    -----------------------------------

                elseif unit.team == context.unit.team then
                    uscore = team_score or 0
                    if unit == context.unit then
                        selfmod = self_score_mod or 0
                    end

                    -----------------------------------

                    if ally_threatened_score and ally_threatened_score ~= 0 then
                        if unit:IsThreatened(nil, "overwatch") or unit:IsThreatened(nil, "pindown") then
                            uscore = uscore + ally_threatened_score
                        end
                    end
                    -----------------------------------
                end
            end
            score = (score or 0) + uscore
        end
        score = score and MulDivRound(score, zone.score_mod or 100, 100)
        score = score and MulDivRound(score, 100 + selfmod, 100)
        if score and score > best_score then
            best_target, best_score = zone, score
        end
        zone.score = score
    end

    return best_target, best_score
end

---------------------------------------------------------------------------
---- BUGFIX (B11) -- Override de AIPrecalcConeTargetZones (source, CombatAI.lua:2040)
---------------------------------------------------------------------------
---- BUG do source: a assinatura declara `stance` e AIActionMGSetup:PrecalcAction
---- passa "Prone" com o comentario "MGSetup will change the stance so we need to
---- check LOS in that stance" -- mas o corpo NUNCA usa o parametro. Tudo era
---- medido da postura atual (CheckLOS a partir de `unit`, GetLoFData com
---- stance = unit.stance). Ou seja: a IA decidia montar a MG pela linha de tiro
---- que tinha EM PE (ou agachada), deitava, e podia perder a linha -- e a zona
---- escolhida podia estar cheia de alvos que ela nao alcanca deitada.
---- Aqui o parametro passa a valer. Sem `stance` (Overwatch, MGRotate ja
---- montado) o caminho e byte a byte o do source.
---- (mora neste arquivo, que ja e o dos calculos de zona de cone, para nao
---- dessincronizar metadata.lua/items.lua com um arquivo novo)
function AIPrecalcConeTargetZones(context, action_id, additional_target_pt, stance)
    if context.target_locked then
        return {}
    end

    local unit = context.unit
    local weapon = context.weapon
    local params = weapon:GetAreaAttackParams(action_id, unit)

    local min_range = params.min_range * const.SlabSizeX
    local max_range = params.max_range * const.SlabSizeX

    local target_pts = AICalcAOETargetPoints(context, min_range, max_range)
    if additional_target_pt then
        target_pts[#target_pts + 1] = additional_target_pt
    end

    -- calc cone areas for each remaining target point
    local zones = {}
    local cone_angle = params.cone_angle
    local targets = {}
    local attack_pos = unit:GetPos() -- make sure we're using the current position in case the unit has moved
    local units = table.copy(context.enemies)
    table.iappend(units, GetAllAlliedUnits(unit))
    local unit_sight = unit:GetSightRadius()

    ---- postura em que a unidade vai estar quando a acao acontecer
    local check_stance = stance or unit.stance
    local stance_override = check_stance ~= unit.stance
    local los_src = stance_override and attack_pos or unit
    local los_stance = stance_override and check_stance or nil

    for zi, pt in ipairs(target_pts) do
        local dir = pt - attack_pos
        if dir:Len() > 0 then
            local target_pos = (attack_pos + SetLen(dir, max_range)):SetTerrainZ()
            local zone = {target_pos = target_pos, units = {}}
            zones[#zones + 1] = zone

            local angle = CalcOrientation(attack_pos, pt)
            local los_any, los_targets = CheckLOS(units, los_src, unit:GetDist(target_pos),
                                                  los_stance, cone_angle, angle)
            if los_any then
                for i, target_unit in ipairs(units) do
                    if los_targets[i] and IsValidTarget(target_unit) then
                        zone.units[#zone.units + 1] = target_unit
                        table.insert_unique(targets, target_unit)
                    end
                end
            end
        end
    end

    local check_ally
    if action_id == "Overwatch" then
        local atk_action = context.default_attack
        local aim_type = atk_action.AimType
        local is_aoe = aim_type == "cone" or aim_type == "aoe" or aim_type == "parabola aoe" or
                           aim_type == "line aoe"
        check_ally = not is_aoe
    end

    -- filter LOS targets
    local max_distance = Min(unit_sight, weapon:GetMaxRange())
    local los_any, los_targets = CheckLOS(targets, los_src, max_distance, los_stance)
    if not los_any then
        for _, zone in ipairs(zones) do
            table.iclear(zone.units)
        end
        return zones
    end
    for i = #targets, 1, -1 do
        if not los_any or not los_targets[i] then
            for _, zone in ipairs(zones) do
                table.remove_value(zone.units, targets[i])
            end
            table.remove(targets, i)
        end
    end
    -- check chance to hit
    local targets_attack_data = GetLoFData(unit, targets, {
        obj = unit,
        action_id = context.default_attack.id,
        weapon = weapon,
        ---- era stance = unit.stance: a linha de fogo tem que sair da postura
        ---- em que a unidade vai atirar (deitada, no caso do MGSetup)
        stance = check_stance,
        range = max_distance,
        target_spot_group = "Torso",
        prediction = true
    })
    local action = CombatActions[action_id]
    local args = {target_spot_group = false}
    for i, attack_data in ipairs(targets_attack_data) do
        local target = targets[i]
        local chance_to_hit = 0
        if attack_data and not attack_data.stuck then
            for j, hit_info in ipairs(attack_data.lof) do
                if not check_ally or hit_info.ally_hits_count == 0 then
                    args.target_spot_group = hit_info.target_spot_group
                    chance_to_hit = unit:CalcChanceToHit(target, action, args, "chance_only")
                    if chance_to_hit > 0 then
                        break
                    end
                end
            end
        end
        if chance_to_hit == 0 then
            for _, zone in ipairs(zones) do
                table.remove_value(zone.units, target)
            end
        end
    end
    return zones
end
