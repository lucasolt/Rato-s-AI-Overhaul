DefineClass.AIPolicyCustomSeekCover = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {
            id = "visibility_mode",
            name = "Visibility Mode",
            editor = "choice",
            default = "team",
            items = function(self)
                return {"self", "team", "all"}
            end
        },
        {
            id = "ScalePerDistance",
            editor = "bool",
            default = false,
            read_only = false,
            no_edit = false
        }, {
            id = "ForceCheckLastEnemyPos",
            editor = "bool",
            default = false,
            read_only = false,
            no_edit = false
        }, {
            id = "ExposedAtCloseRange_Score",
            editor = "number",
            default = -100,
            read_only = false,
            no_edit = false
        },
        {
            id = "SimpleGetCover",
            editor = "bool",
            default = false,
            read_only = false,
            no_edit = false
        }, {id = "BaseScore", editor = "number", default = 100, read_only = false, no_edit = false}
    }
}

----- Args
local distance_impact = 100 ---- BUGFIX (B7): era 1.00 (float). Agora percentual.
local max_range = 30
local min_dist = 5 * const.SlabSizeX
local pb_range = const.Weapons.PointBlankRange * const.SlabSizeX
local close_range_mul = 50
local medium_range_mul = 15

local debug = Platform.developer and Platform.cheats and true

local extra_score_arg_mul = 220
-----

function AIPolicyCustomSeekCover:GetEditorView()
    return "Custom Seek Cover"
end

function AIPolicyCustomSeekCover:EvalDest(context, dest, grid_voxel)
    local score = 0

    local ux, uy, uz, ustance_idx = stance_pos_unpack(dest)
    local new_point = point(ux, uy, uz)
    if not dest then
        return score
    end

    local tbl = context.enemies or empty_table

    ----
    local table_num = 0 -- #tbl
    local extra_mul = self.ScalePerDistance and extra_score_arg_mul or 100
    ----

    ---- PERF (C9): estas tabelas eram alocadas em TODA avaliacao de destino,
    ---- mesmo com debug desligado. Esta e uma politica OptLoc (20 usos em
    ---- items.lua), entao rodava sobre todos os destinos do raio de busca.
    ---- `debugforpos_simple` nao tinha sequer um uso ativo -- removida.
    local debugforpos
    if debug then
        debugforpos = {}
    end

    for _, enemy in ipairs(tbl) do
        local visible = true
        if self.visibility_mode == "self" then
            visible = context.enemy_visible[enemy]
        elseif self.visibility_mode == "team" then
            visible = context.enemy_visible_by_team[enemy]
        end

        if visible then
            table_num = table_num + 1
            local cover_score = 0

            if self.SimpleGetCover then
                local cover = GetCoverFrom(dest, context.enemy_pack_pos_stance[enemy])
                cover_score = self:SimpleGetCoverScore(context, self.CoverScores[cover] or 0, dest,
                                                       grid_voxel, enemy)

            else
                cover_score =
                    self:GetCoverScore(context, enemy, context.unit, dest, nil, grid_voxel)
                -- table.insert(debugforpos_simple, {enemy.session_id, cover_score})
            end

            if debug then
                table.insert(debugforpos, {enemy.session_id, cover_score})
            end

            score = score + cover_score
        end
    end

    ------------- If possible, need to check direction
    if self.ForceCheckLastEnemyPos or table_num < 1 then
        local last_pos = context.unit.last_known_enemy_pos
        -- DbgAddCircle(last_pos)
        if last_pos then
            local cover = GetCoverFrom(dest, stance_pos_pack(last_pos))
            local cover_score = self:SimpleGetCoverScore(context, self.CoverScores[cover] or 0,
                                                         dest, last_pos)
            -- table.insert(debugforpos_simple, {"last_pos", cover_score})

            table_num = table_num + 1
            score = score + cover_score
        end
    end

    ---------------------- Debug
    if debug then
        local dbg_txt = ""
        for _, v in ipairs(debugforpos) do
            dbg_txt = dbg_txt .. v[1] .. " = " .. v[2] .. " \n"
        end
        context.unit.ai_context.dest_custom_seek_cover_debug[dest] = dbg_txt
    end

    -----------------------

    return MulDivRound(score / Max(1, table_num), extra_mul, 100)
end

--- Not really used right now
function AIPolicyCustomSeekCover:SimpleGetCoverScore(context, cover_score, dest, grid_voxel, enemy)

    if not dest then
        return cover_score
    end

    local new_pos, dist
    if self.ScalePerDistance and cover_score > 0 then
        new_pos = RATOAI_UnpackPos(dest)
        new_pos = IsValidZ(new_pos) and new_pos or new_pos:SetTerrainZ()
        local enemy_pos = IsValid(enemy) and enemy:GetPos() or enemy
        new_pos = IsValidZ(enemy_pos) and enemy_pos or enemy_pos:SetTerrainZ()

        if enemy_pos then
            dist = Max(min_dist, new_pos:Dist(enemy_pos))
            local range = max_range * const.Scale.AP
            ---- BUGFIX (B7): era
            ----   100 - ((Min(range, dist) * 1.00) / (range * 1.00)) * (100 * distance_impact)
            local ratio = 100 - MulDivRound(Min(range, dist), distance_impact, range)

            cover_score = MulDivRound(cover_score, ratio, 100)
        end

    end

    if self.ExposedAtCloseRange_Score ~= 0 and cover_score <= 0 and context.enemy_grid_voxel[enemy] and
        grid_voxel then
        local x1, y1, z1 = point_unpack(context.enemy_grid_voxel[enemy])
        local x2, y2, z2 = point_unpack(grid_voxel)
        if IsCloser(x1, y1, z1, x2, y2, z2, pb_range + 1) then
            cover_score = self.ExposedAtCloseRange_Score
        elseif IsCloser(x1, y1, z1, x2, y2, z2, pb_range * 2 + 1) then
            cover_score = MulDivRound(self.ExposedAtCloseRange_Score, close_range_mul, 100)
        elseif IsCloser(x1, y1, z1, x2, y2, z2, pb_range * 3 + 1) then
            cover_score = MulDivRound(self.ExposedAtCloseRange_Score, medium_range_mul, 100)
        end
    end

    -- if new_pos then
    --     DbgAddText(enemy.session_id .. " " .. cover_score, new_pos)
    -- end

    return cover_score
end

AIPolicyCustomSeekCover.CoverScores = {
    [const.CoverPass] = 0,
    [const.CoverNone] = 0,
    [const.CoverLow] = 50,
    [const.CoverHigh] = 100
}

function AIPolicyCustomSeekCover:GetCoverScore(context, enemy, unit, dest, target_pos, grid_voxel)
    local prone_cover_CTH = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover
    local cover_max_malus = prone_cover_CTH:ResolveValue("Cover")
    local score = 0

    local target_pos = target_pos or dest and RATOAI_UnpackPos(dest) or unit:GetPos()
    local att_pos = enemy and enemy:GetPos()
    target_pos = RATOAI_ValidatePosZ(target_pos)
    att_pos = RATOAI_ValidatePosZ(att_pos)
    local dist = att_pos:Dist(target_pos)

    if not enemy:IsDowned() and IsValidPos(target_pos) and IsValidPos(att_pos) then

        local distance_to_check_lack_of_cover = 30
        local weapon = enemy:GetActiveWeapons()
        local is_firearm = weapon and IsKindOf(weapon, "Firearm")

        distance_to_check_lack_of_cover = weapon and is_firearm and weapon.WeaponRange or
                                              distance_to_check_lack_of_cover

        if not is_firearm then
            score = self.BaseScore
        elseif dist <= distance_to_check_lack_of_cover * const.SlabSizeX then

            local use, value = RATOAI_CoverCTH(att_pos, target_pos)
            value = value or 0
            if use then
                local ratio = Clamp(MulDivRound(value, 100, cover_max_malus), 0, 100)
                score = MulDivRound(self.BaseScore, ratio, 100)
            end
        end
    end

    if self.ExposedAtCloseRange_Score ~= 0 and score <= 0 and dist then
        ---- BUGFIX (B7): era `* 0.5` e `* 0.1` (float).
        if dist <= const.Weapons.PointBlankRange * const.SlabSizeX then
            score = self.ExposedAtCloseRange_Score
        elseif dist <= const.Weapons.PointBlankRange * 2 * const.SlabSizeX then
            score = MulDivRound(self.ExposedAtCloseRange_Score, 50, 100)
        elseif dist <= const.Weapons.PointBlankRange * 3 * const.SlabSizeX then
            score = MulDivRound(self.ExposedAtCloseRange_Score, 10, 100)
        end
    end

    return score
end

function RATOAI_CoverCTH(attacker_pos, target_pos)
    local prone_cover_CTH = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover
    local exposed_value = prone_cover_CTH:ResolveValue("ExposedCover")
    local full_value = prone_cover_CTH:ResolveValue("Cover")

    local cover, any, coverage = GetCoverPercentage(target_pos, attacker_pos, "Crouch")

    -- if CheckSightCondition(attacker, target, const.usObscured) then
    -- 	exposed_value = exposed_value + const.EnvEffects.DustStormCoverCTHPenalty
    -- 	full_value = full_value + const.EnvEffects.DustStormCoverCTHPenalty
    -- end

    local value = InterpolateCoverEffect(coverage, full_value, exposed_value)
    local metaText = false

    if value < exposed_value then
        return true, value
    end
    return false, 0
end
--[[function AIPolicyCustomSeekCover:EvalDest(context, dest, grid_voxel)
    local score = 0

    local ux, uy, uz, ustance_idx = stance_pos_unpack(dest)

    local tbl = context.enemies or empty_table

    ---
    local denominador = 0
    local total_score = 0
    ---
    for _, enemy in ipairs(tbl) do
        local visible = true
        if self.visibility_mode == "self" then
            visible = context.enemy_visible[enemy]
        elseif self.visibility_mode == "team" then
            visible = context.enemy_visible_by_team[enemy]
        end

        if visible then

            local cover = GetCoverFrom(dest, context.enemy_pack_pos_stance[enemy])
            local cover_score = self.CoverScores[cover] or 0

            -------------
            total_score = total_score + cover_score
            denominador = denominador + 1

            local cover_score1 = cover_score
            if self.ScalePerDistance and cover_score > 0 then
                local ux, uy, uz, ustance_idx = stance_pos_unpack(dest)
                local new_pos = point(ux, uy, uz)

                local dist = new_pos:Dist(enemy:GetPos())
                local range = max_range * const.Scale.AP
                local ratio = 100 - ((Min(range, dist) * 1.00) / (range * 1.00)) *
                                  (100 * distance_impact)

                cover_score = MulDivRound(cover_score, ratio, 100)
                print(enemy.session_id, dist / const.SlabSizeX, cover_score1, cover_score, ratio)

            end

            -------------
            score = score + cover_score

        end
    end

    local score_ratio = 0
    if total_score > 0 then
        total_score = total_score / Max(1, denominador)
        -- score = score / Max(1, denominador)

        local ux, uy, uz, ustance_idx = stance_pos_unpack(dest)
        local new_pos = point(ux, uy, uz)

        score_ratio = ((score * 1.00) / (total_score * 1.00)) * 100
        DbgAddText(total_score .. " / " .. score .. " = " .. score_ratio, new_pos)
    end

    local final_score = MulDivRound(self.Score, score_ratio, 100)
    ic(total_score, score, final_score)
    return score / Max(1, #tbl)
end]]
