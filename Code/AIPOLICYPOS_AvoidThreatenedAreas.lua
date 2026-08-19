-- DefineClass.AIPolicyAvoidThreatenedAreas = {
--     __parents = {"AIPositioningPolicy"},
--     __generated_by_class = "ClassDef",
--     properties = {
--         {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
--         {id = "CheckLOS", editor = "bool", default = true}
--     }
-- }
-- function AIPolicyAvoidThreatenedAreas:EvalDest(context, dest, grid_voxel)
--     local enemy
--     local enemy_ow = g_Overwatch[enemy]
-- @ dist
-- @ cone_angle
-- @ target_pos 
-- @ orient or or CalcOrientation(enemy:GetPos(), enemy_ow.target_pos)
-- end
--------------------------
--[[
function AIFindDestinations(unit, context)
    local pos = GetPassSlab(unit) or unit:GetPos()
    local destinations, paths, dest_ap, dest_path, voxel_to_dest, closest_free_pos =
        AIBuildArchetypePaths(unit, pos, context)
    if not closest_free_pos then
        if unit.ActionPoints == 0 then
            assert(not "AI try to act with 0 action points!!!")
        else
            print("AI can't find unit free destination prints!!!")
            printf("      AP = %d", unit.ActionPoints)
            printf("      Command = %s", unit.command)
            printf("      Status effects: %s", table.concat(table.keys(unit.StatusEffects), ", "))
            printf("      Pos: %s", tostring(unit:GetPos()))
            printf("      Pass slab pos: %s", tostring(GetPassSlab(unit) or ""))
            printf("      Target dummy pos %s",
                   unit.target_dummy and tostring(unit.target_dummy:GetPos()) or "")
            local o = GetOccupiedBy(unit:GetPos(), unit)
            if o then
                printf("Other pos %s", tostring(o:GetPos()))
                printf("Other target dummy pos %s",
                       o.target_dummy and tostring(o.target_dummy:GetPos()) or "")
                printf("Other efResting=%d", o:GetEnumFlags(const.efResting))
                if o.reposition_dest then
                    printf("Other reposition dest=%s",
                           tostring(point(stance_pos_unpack(o.reposition_dest))))
                end
            end
            assert(not "AI can't find unit free destination")
        end
    end
    local crouch_idx = StancesList.Crouch
    local important_dests = context.important_dests or {}
    context.important_dests = important_dests

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B11): o dest so virava Crouch se houvesse cobertura ao NORTE, e ainda pagava
    ---- 1 AP que nunca e gasto de verdade.
    ----
    ---- Original (identico ao vanilla, CombatAI.lua:682-703):
    ----     if cost and ap and ap >= cost then
    ----         local up, right, down, left = GetCover(x, y, z)
    ----         if up then
    ----             local cover_low = up == low or right == low or down == low or left == low
    ----
    ---- (a) `if up then` -- GetCover devolve as 4 direcoes, mas so a norte abria o bloco. Muro
    ----     baixo a leste/oeste/sul => o dest continuava Standing.
    ----     Isso nao afeta so a postura: `GetCoverPercentage` (Cover.lua:283-285) ZERA cobertura
    ----     baixa quando target_stance == "Standing", entao o tile era scorado por
    ----     AIPolicyCustomSeekCover como campo aberto. A IA nem queria ir pra la.
    ----
    ---- (b) custo fantasma -- quem aplica a postura no destino e AIBehavior:EndMovement
    ----     (AIBehaviors.lua:199-210) via unit:DoChangeStance, que NAO cobra AP (Unit.lua:6435).
    ----     O `move_args.toDoStance` de BeginMovement (AIBehaviors.lua:177) nao e consumido por
    ----     nenhuma acao Move -- so UnitActions.lua:707 (attack-move do jogador) o le.
    ----     Ou seja: o plano descontava 1000 AP que a execucao nunca gasta, e esse AP fantasma
    ----     piorava o dest agachado em AIPolicyAttack_StanceAP e no damage score, fazendo o tile
    ----     em pe ganhar a roleta de AIScoreReachableVoxels.
    ----
    ---- Com (b), a tabela `change_stance_costs` (3 chamadas a GetStanceToStanceAP por unidade)
    ---- virou codigo morto e foi removida junto.
    ---------------------------------------------------------------------------------------------
    -- preprocess destinations to find those where we need to change stance at the dest to take cover
    local low = const.CoverLow
    -- local high = const.CoverHigh
    for i, dest in ipairs(destinations) do
        local x, y, z, stance_idx = stance_pos_unpack(dest)
        if stance_idx ~= crouch_idx then
            local ap = dest_ap[dest]
            if ap then
                local up, right, down, left = GetCover(x, y, z)
                ---- BUGFIX (B11a): qualquer direcao, nao so a norte
                if up or right or down or left then
                    local cover_low = up == low or right == low or down == low or left == low
                    -- local cover_high = up == high or right == high or down == high or left == high
                    if cover_low then -- and not cover_high then
                        table.remove_value(important_dests, dest)
                        local new_dest = stance_pos_pack(x, y, z, crouch_idx)
                        destinations[i] = new_dest
                        voxel_to_dest[point_pack(x, y, z)] = new_dest
                        ---- BUGFIX (B11b): sem debito -- EndMovement aplica de graca
                        dest_ap[new_dest] = ap
                        dest_path[new_dest] = dest_path[dest]
                        table.insert_unique(important_dests, new_dest)
                    end
                end
            end
        end
    end

    context.destinations = destinations -- available destinations
    context.dest_ap = dest_ap -- dest -> available ap
    context.combat_paths = paths
    context.dest_combat_path = dest_path -- dest -> index in context.combat_paths (to reach this dest)
    context.voxel_to_dest = voxel_to_dest
    context.closest_free_pos = closest_free_pos

    context.all_destinations = AIEnumValidDests(context)
end

function AIFindOptimalLocation(context, dest_score_details)
    if context.best_dest then
        -- optimal location doesn't change across behaviors, no need to recalc it
        return context.best_dest
    end

    local unit = context.unit
    context.best_dests = {}

    local r = context.archetype.OptLocSearchRadius * const.SlabSizeX
    local ux, uy, uz = point_unpack(context.unit_grid_voxel)
    local px, py, pz = VoxelToWorld(ux, uy, uz)
    local bbox = box(px - r, py - r, 0, px + r + 1, py + r + 1, MapSlabsBBox_MaxZ)
    context.best_score = 0
    local unit_voxels = {}
    local dest_scores = {}

    local policies = table.ifilter(context.archetype.OptLocPolicies, function(idx, policy)
        return policy:MatchUnit(unit)
    end)

    for _, dest in ipairs(context.all_destinations) do
        local x, y, z = stance_pos_unpack(dest)
        local gx, gy, gz = WorldToVoxel(x, y, z)
        local world_voxel = point_pack(x, y, z)
        local grid_voxel = point_pack(gx, gy, gz)
        -- eval_voxel(x, y, z, context, ux, uy, uz)

        if not context.voxel_to_dest[world_voxel] then
            context.voxel_to_dest[world_voxel] = dest
        end
        local scores
        if dest_score_details then
            scores = {}
            dest_score_details[dest] = scores
        end
        table.iclear(unit_voxels)
        local score = AIScoreDest(context, policies, dest, grid_voxel, 0, unit_voxels, scores)
        if score > 0 then
            context.best_score = Max(context.best_score, score)
            local threshold = MulDivRound(context.best_score, const.AIDecisionThreshold, 100)
            if score >= threshold then
                dest_scores[dest] = score
                context.best_dests[#context.best_dests + 1] = dest
                for i = #context.best_dests, 1, -1 do
                    local dest = context.best_dests[i]
                    if dest_scores[dest] < threshold then
                        table.remove(context.best_dests, i)
                    end
                end
            end
        end
        if scores then
            scores.final_score = score
        end
    end

    -- check if a best dest candidate is on our starting voxel, default to it
    for _, dest in ipairs(context.best_dests) do
        if stance_pos_dist(context.unit_stance_pos, dest) == 0 then
            context.best_dest = dest
        end
    end

    if not context.best_dest and #(context.best_dests or empty_table) > 0 then
        if #(context.best_dests or empty_table) > 15 then
            context.collapsed = CollapsePoints(context.best_dests, 1)
        else
            context.collapsed = context.best_dests
        end
        local pf_dests = {}
        for i, dest in ipairs(context.collapsed) do
            local x, y, z = stance_pos_unpack(dest)
            pf_dests[i] = point(x, y, z)
        end

        context.best_dest_path = pf.GetPosPath(unit, pf_dests)
        if #(context.best_dest_path or empty_table) > 0 then
            local voxel = point_pack(SnapToPassSlabXYZ(context.best_dest_path[1]))
            local dest = context.voxel_to_dest[voxel]
            if not dest then
                -- try non-snapped
                voxel = point_pack(context.best_dest_path[1])
                dest = context.voxel_to_dest[voxel]
            end
            -- assert(dest and (not dest_score_details or dest_score_details[dest]))
            context.best_dest = dest
        end
    end

    context.dest_scores = dest_scores
    context.best_dest = context.best_dest or context.voxel_to_dest[context.unit_world_voxel] or
                            context.unit_stance_pos
    if context.dest_combat_path[context.best_dest] then
        table.insert_unique(context.important_dests, context.best_dest)
        table.insert_unique(context.destinations, context.best_dest)
    end
    return context.best_dest
end
]] 
