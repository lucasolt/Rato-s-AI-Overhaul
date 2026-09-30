const.RATOAI = const.RATOAI or {}

---- Scout search: observe the suspected spot from a standoff ring instead of walking onto it.
if const.RATOAI.ScoutStandoffMinTiles == nil then
    const.RATOAI.ScoutStandoffMinTiles = 4
end
if const.RATOAI.ScoutStandoffMaxTiles == nil then
    const.RATOAI.ScoutStandoffMaxTiles = 14
end
---- Share of the ring score kept by ring tiles that cannot see the suspected spot.
if const.RATOAI.ScoutNoLOSPct == nil then
    const.RATOAI.ScoutNoLOSPct = 40
end

---- Packed suspected enemy position (unit's last_known_enemy_pos), or nil when unknown or already in view.
function RATOAI_SuspectPos(context)
    local cached = context.__ratoai_suspect
    if cached ~= nil then
        return cached or nil
    end
    local unit = context.unit
    local lk = unit and unit.last_known_enemy_pos
    local ppos = false
    if lk then
        local pos = RATOAI_ValidatePosZ(lk)
        if IsValidPos(pos) and not CheckLOS(pos, unit, unit:GetSightRadius()) then
            ppos = stance_pos_pack(pos, StancesList.Crouch)
        end
    end
    context.__ratoai_suspect = ppos
    return ppos or nil
end

local function ScoutBand(context, lk)
    local band = context.__ratoai_scout_band
    if band and band.lk == lk then
        return band
    end
    local slab = const.SlabSizeX
    local unit = context.unit
    local pos = RATOAI_ValidatePosZ(lk)
    local minr = const.RATOAI.ScoutStandoffMinTiles * slab
    local maxr = Clamp((context.EffectiveRange or 0) * slab, minr + 2 * slab,
                       const.RATOAI.ScoutStandoffMaxTiles * slab)
    band = {
        lk = lk,
        pos = pos,
        ppos = stance_pos_pack(pos, StancesList.Crouch),
        minr = minr,
        maxr = maxr,
        ---- normalizer of the approach gradient: dests as far as the unit score ~0
        ref = Max(unit:GetDist(pos) - maxr, maxr),
        radius = unit:GetSightRadius()
    }

    ---- one batched LOS over ring dests only; all_destinations whole would cost ~0.4 s
    local los, srcs, tgts = {}, {}, {}
    for _, dest in ipairs(context.all_destinations or context.destinations or empty_table) do
        local x, y, z = stance_pos_unpack(dest)
        if pos:Dist(x, y, z) <= maxr then
            srcs[#srcs + 1] = dest
            tgts[#tgts + 1] = band.ppos
        end
    end
    if #srcs > 0 then
        local _, data = CheckLOS(tgts, srcs, band.radius)
        for i = 1, #srcs do
            los[srcs[i]] = not not (data and data[i])
        end
    end
    band.los = los
    context.__ratoai_scout_band = band
    return band
end

---- Replaces CombatAI's "stand on the last known position" (ClassDef-AI.generated.lua:396).
function AIPolicyLastEnemyPos:EvalDest(context, dest, grid_voxel)
    local lk = context.unit.last_known_enemy_pos
    if not lk then
        return 0
    end
    local band = ScoutBand(context, lk)
    local w = self.Weight
    local x, y, z = stance_pos_unpack(dest)
    local d = band.pos:Dist(x, y, z)

    ---- capped below a covered observation tile, so outside tiles never tie with one at the 80% cut
    if d > band.maxr then
        local far = MulDivRound(w, 70, 100)
        return far - MulDivRound(d - band.maxr, far, band.ref)
    end

    local score = d >= band.minr and w or MulDivRound(w, d, band.minr)
    local los = band.los[dest]
    if los == nil then
        local _, data = CheckLOS({band.ppos}, {dest}, band.radius)
        los = not not (data and data[1])
        band.los[dest] = los
    end
    if not los then
        return MulDivRound(score, const.RATOAI.ScoutNoLOSPct, 100)
    end
    ---- cover counts only on the ring: off it, cover would stall the approach of far units
    local cover = AIPolicyTakeCover.CoverScores[GetCoverFrom(dest, band.ppos)] or 0
    return MulDivRound(score, 60 + MulDivRound(40, cover, 100), 100)
end

---- Vanilla scores 0 everywhere when nothing is visible; at end of turn, fall back to cover from
---- the suspected spot. Not in OptLoc, where AIPolicyLastEnemyPos already scores ring cover.
function AIPolicyTakeCover:EvalDest(context, dest, grid_voxel)
    local score, seen = 0, false
    local tbl = context.enemies or empty_table
    for _, enemy in ipairs(tbl) do
        local visible = true
        if self.visibility_mode == "self" then
            visible = context.enemy_visible[enemy]
        elseif self.visibility_mode == "team" then
            visible = context.enemy_visible_by_team[enemy]
        end
        if visible then
            seen = true
            local cover = GetCoverFrom(dest, context.enemy_pack_pos_stance[enemy])
            score = score + self.CoverScores[cover]
        end
    end
    if not seen then
        local ppos = context.__ratoai_endturn_pass and RATOAI_SuspectPos(context)
        return ppos and (self.CoverScores[GetCoverFrom(dest, ppos)] or 0) or 0
    end
    return score / Max(1, #tbl)
end

---------------------------------------------------------------------------------------------------
---- Scout location pick (CombatAI.lua:2434). Team memory first; the engine's pick reads the real
---- positions of hidden enemies, so it stays only as the last resort.
---------------------------------------------------------------------------------------------------
local function SpotInView(team, pos)
    for _, ally in ipairs(team and team.units or empty_table) do
        if IsValid(ally) and not ally:IsDead() and CheckLOS(pos, ally, ally:GetSightRadius()) then
            return true
        end
    end
    return false
end

function RATOAI_PickRememberedScoutPos(unit)
    local team = unit.team
    local mem = team and RATOAI_LastSeen[team.side]
    if not mem then
        return
    end
    local turn = g_Combat and g_Combat.current_turn or 0
    local best, best_age, best_dist
    ---- sorted keys: pairs order over unit keys is not sync-safe for a pick
    local enemies = table.keys(mem)
    table.sort(enemies, function(a, b)
        return (a.handle or 0) < (b.handle or 0)
    end)
    for _, enemy in ipairs(enemies) do
        local rec = mem[enemy]
        if IsValidTarget(enemy) and rec.pos then
            local pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(rec.pos))
            local age = Max(0, turn - (rec.turn or turn))
            local dist = unit:GetDist(pos)
            if IsValidPos(pos) and
                (not best or age < best_age or (age == best_age and dist < best_dist)) and
                not SpotInView(team, pos) then
                best, best_age, best_dist = pos, age, dist
            end
        end
    end
    return best
end

---- Engine copy with its bug fixed: it built `targets` (nearest first) and then drew from all enemies.
local function EnginePickScoutLocation(unit)
    local r = 5 * guim
    local enemies = GetAllEnemyUnits(unit)
    if #enemies == 0 then
        return
    end
    local targets
    local nearest, nearby = {}, {}
    for _, enemy in ipairs(enemies) do
        local dist = unit:GetDist(enemy)
        if dist <= r then
            nearest[#nearest + 1] = enemy
            targets = nearest
        elseif dist <= 2 * r then
            nearby[#nearby + 1] = enemy
            targets = targets or nearby
        end
    end
    targets = targets or enemies
    local enemy = table.interaction_rand(targets, "Combat")

    local ux, uy, uz = enemy:GetGridCoords()
    local px, py, pz = VoxelToWorld(ux, uy, uz)
    local bbox = box(px - r, py - r, 0, px + r + 1, py + r + 1, MapSlabsBBox_MaxZ)
    local dests, dest_added = {}, {}
    ForEachPassSlab(bbox, function(x, y, z)
        local gx, gy, gz = WorldToVoxel(x, y, z)
        if IsCloser(gx, gy, gz, ux, uy, uz, r) then
            local world_voxel = point_pack(x, y, z)
            if not dest_added[world_voxel] then
                dests[#dests + 1] = world_voxel
                dest_added[world_voxel] = true
            end
        end
    end)
    if #dests > 0 then
        return point(point_unpack(table.interaction_rand(dests, "Combat")))
    end
end

function AIPickScoutLocation(unit)
    return RATOAI_PickRememberedScoutPos(unit) or EnginePickScoutLocation(unit)
end

---- The engine drops a seen spot only after moving (CombatAI.lua:2488); drop it before planning too.
function RATOAI_RefreshScoutTarget(unit, context)
    local lk = unit.last_known_enemy_pos
    if not lk or context.archetype.id ~= "Scout_LastLocation" then
        return
    end
    local pos = RATOAI_ValidatePosZ(lk)
    if IsValidPos(pos) and CheckLOS(pos, unit, unit:GetSightRadius()) then
        unit.last_known_enemy_pos = AIPickScoutLocation(unit) or lk
    end
end
