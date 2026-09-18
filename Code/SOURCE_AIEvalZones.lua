---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata (o CONSTANTS_AI_source ja a cria, mas nao dependemos disso).
const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- DIAGNOSTICO DE ZONAS (granada / fumaca / gas)
----
---- `const.RATOAI.ZoneDebug = true` no console imprime, por AVALIACAO, uma linha por zona
---- candidata com a composicao dela, e no fim qual venceu. Sem isso nao da para separar
---- "nao havia aliado ameacado" de "os pesos nao sao os que eu acho".
----
---- Lembre ao ler: os pontos candidatos saem SO de posicoes de inimigo (e pontos medios
---- entre elas) -- ver AICalcAOETargetPoints. Nenhuma zona nasce centrada num aliado.
---------------------------------------------------------------------------------------------------
if const.RATOAI.ZoneDebug == nil then
    const.RATOAI.ZoneDebug = false
end

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
        local zone_parts = const.RATOAI.ZoneDebug and {} or nil
        for _, unit in ipairs(zone.units) do
            local uscore = 0
            local why = ""
            if not unit:IsDead() and not unit:IsDowned() then
                if unit:IsOnEnemySide(context.unit) then

                    uscore = enemy_score or 0
                    -----------------------------------

                    why = "inimigo"
                    if enemy_cover_score and enemy_cover_score ~= 0 then
                        local cover_high, cover_low = GetCoverTypes(unit)
                        if cover_low or cover_high then
                            uscore = uscore + enemy_cover_score
                            why = why .. "+cobertura"
                        end
                    end

                    if enemy_prepared_attack_score and enemy_prepared_attack_score ~= 0 then
                        if g_Overwatch[unit] then
                            uscore = uscore + enemy_prepared_attack_score
                            why = why .. "+overwatch"
                        end
                    end

                    -----------------------------------

                elseif unit.team == context.unit.team then
                    uscore = team_score or 0
                    why = "aliado"
                    if unit == context.unit then
                        selfmod = self_score_mod or 0
                        why = "EU"
                    end

                    -----------------------------------

                    if ally_threatened_score and ally_threatened_score ~= 0 then
                        if unit:IsThreatened(nil, "overwatch") or unit:IsThreatened(nil, "pindown") then
                            uscore = uscore + ally_threatened_score
                            why = why .. "+AMEACADO"
                        end
                    end
                    -----------------------------------
                end
            end
            score = (score or 0) + uscore
            if zone_parts then
                zone_parts[#zone_parts + 1] = string.format("%s(%s %+d)",
                                                          tostring(unit.session_id),
                                                          why ~= "" and why or "neutro",
                                                          uscore)
            end
        end
        score = score and MulDivRound(score, zone.score_mod or 100, 100)
        ---- BUGFIX: source multiplies by (100 + selfmod). A zone holding me and my allies already
        ---- scores negative, so selfmod -1000 turned -780 into +7020 and the worst zone won.
        ---- -1000 in the presets means "never": veto it, and never let selfmod lift a negative score.
        local vetoed = false
        if score then
            if selfmod <= -100 then
                score, vetoed = nil, true
            elseif score > 0 or selfmod > 0 then
                score = MulDivRound(score, 100 + selfmod, 100)
            end
        end
        if zone_parts then
            printf("[ZONA] %s | %d unidades | selfmod %d%% | score %s %s || %s",
                   tostring(context.unit.session_id), #zone.units, selfmod,
                   vetoed and "VETO (eu no raio)" or tostring(score),
                   (score and score > best_score) and "<== melhor ate agora" or "",
                   table.concat(zone_parts, " "))
        end
        if score and score > best_score then
            best_target, best_score = zone, score
        end
        zone.score = score
    end

    if const.RATOAI.ZoneDebug then
        printf("[ZONA] %s FIM: %d zonas candidatas | corte(min_score) %s | vencedora %s",
               tostring(context.unit.session_id), #zones, tostring(min_score),
               best_target and tostring(best_score) or "NENHUMA (nada passou do corte)")
        printf("[ZONA]   pesos: inimigo %s | aliado %s | self %s%% | cobertura %s | overwatch %s | ameacado %s",
               tostring(enemy_score), tostring(team_score), tostring(self_score_mod),
               tostring(enemy_cover_score), tostring(enemy_prepared_attack_score),
               tostring(ally_threatened_score))
    end

    return best_target, best_score
end
