---------------------------------------------------------------------------------------------------
---- AIPolicyLosToEnemy at night. g_AIDestEnemyLOSCache is cast at unit:GetSightRadius() with no target,
---- which GBO leaves at daylight range, so a dark enemy 30 tiles away still counted as seen.
---- The shared cache stays daylight: ThreatExposure reads its `false` as "nobody sees this tile".
---------------------------------------------------------------------------------------------------

---- once per context: each enemy's packed pos and the radius this unit would really see it at
local function NightLOSEnemies(context)
    local unit = context.unit
    local sight = unit:GetSightRadius()
    local dark_r = RATOAI_DarkSightRadius(unit)
    local list, any_dark = {}, false
    for _, enemy in ipairs(context.enemies or empty_table) do
        local ppos = context.enemy_pack_pos_stance and context.enemy_pack_pos_stance[enemy]
        local pt = ppos and RATOAI_ValidatePosZ(RATOAI_UnpackPos(ppos))
        if pt and IsValidPos(pt) then
            local lit = IsIlluminated(enemy, nil, nil, pt)
            any_dark = any_dark or not lit
            list[#list + 1] = {ppos = ppos, pt = pt, radius = lit and sight or dark_r}
        end
    end
    return {list = list, sight = sight, any_dark = any_dark}
end

---- one batch over `dests`; dark pairs are distance-filtered first, so only they are cheap
local function NightLOSBatch(memo, dests)
    local targets, srcs = {}, {}
    for _, dest in ipairs(dests) do
        memo.seen[dest] = false
        local dpt = RATOAI_ValidatePosZ(RATOAI_UnpackPos(dest))
        if IsValidPos(dpt) then
            for _, e in ipairs(memo.enemies.list) do
                if IsCloser(dpt, e.pt, e.radius + 1) then
                    targets[#targets + 1] = e.ppos
                    srcs[#srcs + 1] = dest
                end
            end
        end
    end
    if #targets == 0 then
        return
    end
    ---- BUGFIX (B58): all blocked returns (false, nil)
    local _, data = CheckLOS(targets, srcs, memo.enemies.sight)
    if data then
        for i = 1, #srcs do
            if data[i] then
                memo.seen[srcs[i]] = true
            end
        end
    end
end

function RATOAI_NightDestLOS(context, dest)
    local memo = context.__ratoai_night_los
    if not memo then
        memo = {enemies = NightLOSEnemies(context), seen = {}}
        context.__ratoai_night_los = memo
        if memo.enemies.any_dark then
            ---- the daylight cache already rules out every `false` dest
            local dests = {}
            for _, d in ipairs(context.all_destinations or empty_table) do
                if g_AIDestEnemyLOSCache[d] then
                    dests[#dests + 1] = d
                end
            end
            NightLOSBatch(memo, dests)
        end
    end
    if not memo.enemies.any_dark then
        return true
    end
    local seen = memo.seen[dest]
    if seen == nil then
        NightLOSBatch(memo, {dest})
        seen = memo.seen[dest]
    end
    return seen
end

function AIPolicyLosToEnemy:EvalDest(context, dest, grid_voxel)
    local los = g_AIDestEnemyLOSCache[dest]
    if los and (GameState.Night or GameState.Underground) then
        los = RATOAI_NightDestLOS(context, dest)
    end
    if self.Invert then
        return los and 0 or 100
    end
    return los and 100 or 0
end
