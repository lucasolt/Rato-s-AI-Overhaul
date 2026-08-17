DefineClass.AIPolicyCustomFlanking = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true}, {
            id = "ReserveAttackAP",
            name = "Reserve Attack AP",
            help = "do not consider locations where the unit will be out of ap and couldn't attack",
            editor = "choice",
            default = false,
            items = function(self)
                return {"AP", "Stance", false}
            end
        }, {
            id = "visibility_mode",
            name = "Visibility Mode",
            editor = "choice",
            default = "self",
            items = function(self)
                return {"self", "team", "all"}
            end
        },
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "OnlyTarget", editor = "bool", default = false, read_only = false, no_edit = false},
        {
            id = "ScalePerDistance",
            editor = "bool",
            default = false,
            read_only = false,
            no_edit = false
        }
    }
}

local debug = false
local draw_debug = false

local function IsInCover(unit, enemy, cover_data, los_data)

    local cover_penalty =
        Presets["ChanceToHitModifier"]["Default"]["RangeAttackTargetStanceCover"]:ResolveValue(
            "Cover")

    if not los_data or (not los_data[enemy] or los_data[enemy] == 0) then
        return true, cover_penalty, "No LOS"
    end

    if cover_data and cover_data[enemy] then
        return true, cover_data[enemy]
    end

    return false
end

local function CompareCovers(enemy, current_pos_cover_data, new_pos_cover_data)
    local cover_penalty =
        Presets["ChanceToHitModifier"]["Default"]["RangeAttackTargetStanceCover"]:ResolveValue(
            "Cover")

    local current_cover_cth = current_pos_cover_data[enemy].cover_cth or 0
    local new_cover_cth = new_pos_cover_data[enemy].cover_cth or 0

    ---- BUGFIX (B7): era
    ----   new_ratio     = new_cover_cth     * 1.00 / cover_penalty
    ----   current_ratio = current_cover_cth * 1.00 / cover_penalty
    ----   return current_ratio - new_ratio                 -- float em [-1, 1]
    ---- Como (a/c - b/c) == (a-b)/c, o resultado e identico, mas agora inteiro e em
    ---- PERCENTUAL (100 = a diferenca de uma cobertura cheia). Quem chama passou a
    ---- usar MulDivRound. Aritmetica de ponto flutuante neste caminho entra no
    ---- NetUpdateHash de AIScoreReachableVoxels.
    if not cover_penalty or cover_penalty == 0 then
        return 0
    end
    return MulDivRound(current_cover_cth - new_cover_cth, 100, cover_penalty)
end

---- Args
local effective_range_mul = 100 ---- BUGFIX (B7): era 1.00 (float). Agora percentual.
local distance_impact = 25 ---- BUGFIX (B7): era 0.25 (float). Agora percentual.
local extra_target_weight = 100
local unit_weight = 100
----

function AIPolicyCustomFlanking:GetEnemyWeight(unit, enemy, dist, effective_range, target)
    local weight = unit_weight
    if target and enemy == target then
        weight = weight + extra_target_weight
    end

    if self.ScalePerDistance and (effective_range or 0) > 0 then
        ---- BUGFIX (B7): era
        ----   unit_weight - ((dist * 1.00) / (effective_range * 1.00)) * (100 * distance_impact)
        local falloff = MulDivRound(dist, distance_impact, effective_range)
        weight = MulDivRound(weight, Max(0, unit_weight - falloff), 100)
    end
    return weight
end

function AIPolicyCustomFlanking:EvalDest(context, dest, grid_voxel)

    local unit = context.unit
    local current_pos = context.unit_stance_pos
    context = Update_AIPrecalcDamageScore(unit) or context
    -- context = Update_AICoverLOS_currentpos(unit, current_pos) or context
    -- current_pos = context.unit_stance_pos

    local target = context.dest_target[dest]

    local ap = context.dest_ap[dest] or 0

    local check_ap = self.ReserveAttackAP == "AP" and context.default_attack_cost or
                         self.ReserveAttackAP == "Stance" and
                         (context.default_attack_cost +
                             GetWeapon_StanceAP(unit, context.weapon or unit:GetActiveWeapons()) +
                             Get_AimCost(unit)) or 0

    if ap < check_ap then
        return 0
    end

    local x, y, z = stance_pos_unpack(dest)
    local new_pos = point(x, y, z)

    local enemies = {}
    local enemies_weight = {}

    local effective_range = MulDivRound(context.EffectiveRange * const.SlabSizeX,
                                        effective_range_mul, 100)

    if self.OnlyTarget then
        if target then
            enemies = {target}
            enemies_weight[target] = self:GetEnemyWeight(unit, target, self.ScalePerDistance and
                                                             new_pos:Dist(target:GetPos()) or nil,
                                                         effective_range, target) or 100
        else
            return 0
        end
    else
        for _, enemy in ipairs(context.enemies) do
            local dist = new_pos:Dist(enemy:GetPos())
            if dist <= effective_range then
                local visible = true

                if self.visibility_mode == "self" then
                    visible = context.enemy_visible[enemy]
                elseif self.visibility_mode == "team" then
                    visible = context.enemy_visible_by_team[enemy]
                end

                if visible then
                    local weight = self:GetEnemyWeight(unit, enemy, dist, effective_range, target)
                    enemies_weight[enemy] = weight
                    enemies[#enemies + 1] = enemy
                end
            end
        end
    end

    local context_cover_data = context.dest_target_cover_score[dest]
    local context_los_data = context.dest_target_los[dest]
    local context_currentpos_cover_data = context.currentpos_target_cover_score
    local context_currentpos_los_data = context.enemy_visible

    local current_pos_cover_data, new_pos_cover_data = {}, {}
    for _, enemy in ipairs(enemies) do
        local in_cover, cover_cth, no_los = IsInCover(unit, enemy, context_currentpos_cover_data,
                                                      context_currentpos_los_data)
        current_pos_cover_data[enemy] = {
            in_cover = in_cover,
            cover_cth = cover_cth,
            no_los = no_los
        }

        local in_cover, cover_cth, no_los = IsInCover(unit, enemy, context_cover_data,
                                                      context_los_data)
        new_pos_cover_data[enemy] = {in_cover = in_cover, cover_cth = cover_cth, no_los = no_los}
    end

    local debug_data = {}
    local delta = 0
    for _, enemy in ipairs(enemies) do
        local delta_weight = enemies_weight[enemy] or 100

        debug_data[enemy] = {
            new_in_cover = new_pos_cover_data[enemy].in_cover,
            old_in_cover = current_pos_cover_data[enemy].cover_cth,
            delta = 0,
            cover = context_cover_data and context_cover_data[enemy] or 0,
            los = context_los_data and context_los_data[enemy] or "NoLosData"
        }

        local dif = CompareCovers(enemy, current_pos_cover_data, new_pos_cover_data)
        ---- BUGFIX (B7): CompareCovers agora devolve percentual inteiro (era float
        ---- em [-1, 1]), entao a escala virou MulDivRound. Resultado equivalente.
        delta_weight = MulDivRound(delta_weight, dif, 100)

        if new_pos_cover_data[enemy].in_cover and not current_pos_cover_data[enemy].in_cover then
            delta = delta + delta_weight
            debug_data[enemy].delta = delta_weight
        elseif not new_pos_cover_data[enemy].in_cover and current_pos_cover_data[enemy].in_cover then
            delta = delta + delta_weight
            debug_data[enemy].delta = delta_weight
        end

        -------------------- Simple
        --[[if not new_pos_cover_data[enemy].in_cover then
            delta = delta + delta_weight
            debug_data[enemy].delta = delta_weight
        else
            debug_data[enemy].delta = 0
        end]]
        -------------------- 

    end

    ----------------------- Debug
    if debug then
        if draw_debug then
            DbgAddCircle(new_pos)
        end
        local all_enemy_debug_info = "\n"

        for enemy, data in pairs(debug_data) do
            local delta = data.delta

            local dbg_text = string.format("  %s, 1stCover: %s, 2ndCover: %s Delta: %d, LOS: %s",
                                           tostring(enemy.session_id), tostring(data.old_in_cover),
                                           tostring(data.cover), delta, tostring(data.los))

            all_enemy_debug_info = all_enemy_debug_info .. dbg_text .. "\n"

            if delta ~= 0 then
                local color = delta > 0 and const.clrGreen or delta == 0 and const.clrGray or
                                  const.clrRed
                if not data.los or data.los == 0 then
                    color = const.clrBlue
                end
                if draw_debug then
                    DbgAddVector(new_pos, enemy:GetPos() - new_pos, color)
                end
            end
        end
        local total_dbg_text = string.format("Score: %s", tostring(delta))
        all_enemy_debug_info = total_dbg_text .. all_enemy_debug_info
        context.dest_flanking_pol_debug[dest] = all_enemy_debug_info
    end
    ----------------------- 

    return delta > 0 and delta or 0
end

--[[function AIPolicyCustomFlanking_IndividualTarget:EvalDest(context, dest, grid_voxel)

    local unit = context.unit

    local ap = context.dest_ap[dest] or 0
    if self.ReserveAttackAP and ap < context.default_attack_cost then
        return 0
    end

    local target = context.dest_target[dest]

    if not target then

        return 0
    end
    ic(target.session_id)

    local target_in_cover = IsInCover(unit, target)
    local new_target_in_cover = IsInCover(unit, target, dest)

    return (target_in_cover and not new_target_in_cover) and self.Weight or 0
end]]

--[[function Update_AICoverLOS_currentpos(unit, current_pos_arg)
    local context = unit.ai_context
    local context_copy = table.copy(unit.ai_context)
    local current_pos = current_pos_arg or context.unit_stance_pos -- stance_pos_pack(unit:GetPos())
    if current_pos then
        if not context.dest_target_cover_score[current_pos] or
            not context.dest_target_los[current_pos] then
            print("-- not current_pos", GameTime())
            AIPrecalcDamageScore(context_copy, {current_pos})

            context.dest_target_cover_score[current_pos] =
                context_copy.dest_target_cover_score[current_pos]
            context.dest_target_los[current_pos] = context_copy.dest_target_los[current_pos]
            -- unit.ai_context = context
            return context
        end

    end
    return nil
end]]
