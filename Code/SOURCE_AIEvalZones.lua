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
