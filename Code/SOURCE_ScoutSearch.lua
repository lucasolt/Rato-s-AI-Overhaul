const.RATOAI = const.RATOAI or {}

---- Scout search: observe the suspected spot from a standoff ring instead of walking onto it.
if const.RATOAI.ScoutStandoffMinTiles == nil then
    const.RATOAI.ScoutStandoffMinTiles = 4
end
if const.RATOAI.ScoutStandoffMaxTiles == nil then
    const.RATOAI.ScoutStandoffMaxTiles = 14
end
---- Within this distance of the spot, a reachable tile in its view with no AP to shoot is a trap.
if const.RATOAI.ScoutContactTiles == nil then
    const.RATOAI.ScoutContactTiles = 20
end
---- Walking flood from the spot, in tiles; tiles beyond it count as this far.
if const.RATOAI.ScoutWalkFloodTiles == nil then
    const.RATOAI.ScoutWalkFloodTiles = 24
end

---- Distance from the suspected spot as walked, never less than straight-line: straight-line through
---- a floor read 4 tiles for a tile 18 AP of stairs away (measured, Raider:454).
function RATOAI_SpotDist(context, pos, x, y, z)
    local d = pos:Dist(x, y, z)
    local key = point_pack(pos)
    local flood = context.__ratoai_spot_flood
    if not flood or flood.key ~= key then
        local walk = Presets.ConstDef["Action Point Costs"].Walk.value
        local tiles = const.RATOAI.ScoutWalkFloodTiles
        local start = SnapToPassSlab(pos)
        local cp
        if start and walk > 0 then
            cp = CombatPath:new()
            cp:RebuildPaths(context.unit, tiles * walk, start, "Standing", true, true)
        end
        flood = {key = key, walk = walk, cap = tiles * const.SlabSizeX, ap = cp and cp.paths_ap}
        context.__ratoai_spot_flood = flood
    end
    if not flood.ap then
        return d
    end
    local ap = flood.ap[point_pack(x, y, z)]
    if not ap then
        return Max(d, flood.cap)
    end
    return Max(d, MulDivRound(ap, const.SlabSizeX, flood.walk))
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
        radius = unit:GetSightRadius(),
        contact = const.RATOAI.ScoutContactTiles * slab,
        need = context.default_attack_cost or 0
    }

    ---- reachable this turn: world voxel -> AP left on arrival (voxel_to_dest can't tell, OptLoc fills it)
    local reach = {}
    for _, dest in ipairs(context.destinations or empty_table) do
        local ap = context.dest_ap and context.dest_ap[dest]
        if ap then
            local x, y, z = stance_pos_unpack(dest)
            local v = point_pack(x, y, z)
            reach[v] = Max(reach[v] or ap, ap)
            if RATOAI_SpotDist(context, pos, x, y, z) <= band.contact then
                band.in_contact = true
            end
        end
    end
    band.reach = reach

    ---- one batched LOS over ring + reachable contact tiles; all_destinations whole would cost ~0.4 s
    local los, srcs, tgts = {}, {}, {}
    for _, dest in ipairs(context.all_destinations or context.destinations or empty_table) do
        local x, y, z = stance_pos_unpack(dest)
        local d = RATOAI_SpotDist(context, pos, x, y, z)
        if d <= band.maxr or (d <= band.contact and reach[point_pack(x, y, z)]) then
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

local function DestLOS(band, dest)
    local los = band.los[dest]
    if los == nil then
        local _, data = CheckLOS({band.ppos}, {dest}, band.radius)
        los = not not (data and data[1])
        band.los[dest] = los
    end
    return los
end

local function DestCover(band, dest)
    return AIPolicyTakeCover.CoverScores[GetCoverFrom(dest, band.ppos)] or 0
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
    local d = RATOAI_SpotDist(context, band.pos, x, y, z)
    local close = d >= band.minr and w or MulDivRound(w, d, band.minr)

    ---- FAR: nothing reachable is near the spot yet -- rush toward an observation tile on the ring
    if not band.in_contact then
        ---- capped below a covered observation tile, so outside tiles never tie with one at the 80% cut
        if d > band.maxr then
            local far = MulDivRound(w, 70, 100)
            return far - MulDivRound(d - band.maxr, far, band.ref)
        end
        if not DestLOS(band, dest) then
            return MulDivRound(close, 40, 100)
        end
        return MulDivRound(close, 60 + MulDivRound(40, DestCover(band, dest), 100), 100)
    end

    ---- CONTACT: only tiles reachable this turn, so the end-turn pull stops where this says
    local ap = band.reach[point_pack(x, y, z)]
    if not ap then
        return 0
    end
    if d <= band.contact and DestLOS(band, dest) then
        if ap < band.need then
            return 0 ---- in its view with no AP to answer: the trap that killed scouts one by one
        end
        if d <= band.maxr then
            return MulDivRound(close, 70 + MulDivRound(30, DestCover(band, dest), 100), 100)
        end
    end
    ---- concealed staging: closer is better, so next turn's step into view is short and armed
    local stage = MulDivRound(close, 60, 100)
    if d > band.minr then
        stage = stage - MulDivRound(d - band.minr, stage, band.contact)
    end
    return stage
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

---- lk is only this unit's own last sighting (UnitAwareness.lua:689); the team's memory is shared
---- and at least as fresh. Holders kept watching a spot 12 tiles off the team's (measured).
local function ScoutTarget(unit)
    return RATOAI_PickRememberedScoutPos(unit) or unit.last_known_enemy_pos
end

---- Threat from unseen enemies decays per consecutive search turn, so a blocked seeker edges forward.
if const.RATOAI.ScoutBoldStepPct == nil then
    const.RATOAI.ScoutBoldStepPct = 25
end
if const.RATOAI.ScoutBoldMinPct == nil then
    const.RATOAI.ScoutBoldMinPct = 25
end
MapVar("RATOAI_ScoutSearchTurns", {})

function OnMsg.CombatStart(dynamic_data)
    if not dynamic_data then
        RATOAI_ScoutSearchTurns = {}
    end
end

local function CountSearchTurn(unit)
    local turn = g_Combat and g_Combat.current_turn or 0
    local rec = RATOAI_ScoutSearchTurns[unit.session_id]
    if not rec then
        rec = {turn = turn, n = 1}
        RATOAI_ScoutSearchTurns[unit.session_id] = rec
    elseif rec.turn ~= turn then
        rec.n = rec.turn == turn - 1 and rec.n + 1 or 1
        rec.turn = turn
    end
    return rec.n
end

function RATOAI_RefreshScoutTarget(unit, context)
    local id = context.archetype.id
    if id ~= "Scout_LastLocation" and id ~= "RATOAI_Scout_Hold" then
        return
    end
    local n = CountSearchTurn(unit)
    if id == "Scout_LastLocation" and n > 1 then
        context.__ratoai_search_pct = Max(const.RATOAI.ScoutBoldMinPct,
                                          100 - const.RATOAI.ScoutBoldStepPct * (n - 1))
    end
    local lk = ScoutTarget(unit)
    if not lk then
        return
    end
    ---- the engine drops a seen spot only after moving (CombatAI.lua:2488); drop it before planning
    local pos = RATOAI_ValidatePosZ(lk)
    if IsValidPos(pos) and CheckLOS(pos, unit, unit:GetSightRadius()) then
        lk = EnginePickScoutLocation(unit) or lk
    end
    unit.last_known_enemy_pos = lk
end

function RATOAI_TeamSeesEnemy(context)
    for _, enemy in ipairs(context.enemies or empty_table) do
        if context.enemy_visible_by_team and context.enemy_visible_by_team[enemy] then
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------------------------------
---- Where the team believes each lost enemy is: {enemy, pos, pct}. Same rules as ThreatExposure:
---- live memory where he was seen, expired or disproven memory at the suspected spot.
---------------------------------------------------------------------------------------------------
function RATOAI_BelievedEnemies(context)
    local cached = context.__ratoai_believed
    if cached then
        return cached
    end
    local list = {}
    local suspect = RATOAI_SuspectPos(context)
    local suspect_pos = suspect and RATOAI_UnpackPos(suspect)
    local turns = const.RATOAI.ThreatMemoryTurns or 0
    for _, enemy in ipairs(context.enemies or empty_table) do
        if IsValidTarget(enemy) and not enemy:IsDowned() then
            local mem, age = RATOAI_LastSeenPos(context.unit, enemy)
            if mem then
                local fresh = turns > 0 and age < turns and
                                  not RATOAI_ThreatMemoryStale(context, enemy, mem)
                if fresh then
                    list[#list + 1] = {enemy = enemy, pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(mem)),
                                       pct = MulDivRound(const.RATOAI.ThreatMemoryPct or 0, turns - age,
                                                         turns)}
                elseif suspect_pos then
                    list[#list + 1] = {enemy = enemy, pos = suspect_pos,
                                       pct = const.RATOAI.ThreatSuspectPct or 0}
                end
            end
        end
    end
    context.__ratoai_believed = list
    return list
end

---------------------------------------------------------------------------------------------------
---- SEEKERS AND HOLDERS. Every unit turning scout in the same turn walked into the same guns one
---- by one. Per team per turn, the ScoutSeekers units closest to their suspected spot search; the
---- others already in contact range hold out of view (RATOAI_Scout_Hold). Far units keep closing.
---------------------------------------------------------------------------------------------------
if const.RATOAI.ScoutSeekers == nil then
    const.RATOAI.ScoutSeekers = 2
end

---- base archetypes that would rather hold than search; Skirmishers search first
local ScoutNaturalHolders = {
    RATOAI_Sniper = true,
    HeavyGunner = true,
    RATOAI_Rocketeer = true,
    RATOAI_RetreatingMarksman = true
}
local ScoutRoles = {}

local function ScoutRank(unit)
    local lk = ScoutTarget(unit)
    if not lk then
        return max_int
    end
    local d = unit:GetDist(lk)
    if ScoutNaturalHolders[unit.archetype] then
        d = d + 1000 * const.SlabSizeX
    elseif unit.archetype == "Skirmisher" then
        d = d - 5 * const.SlabSizeX
    end
    return d
end

function RATOAI_IsScoutSeeker(unit)
    local lk = ScoutTarget(unit)
    if not lk or unit:GetDist(lk) > const.RATOAI.ScoutContactTiles * const.SlabSizeX then
        return true
    end
    local team, turn = unit.team, g_Combat and g_Combat.current_turn or 0
    local roles = ScoutRoles[team.side]
    if not roles or roles.turn ~= turn then
        local list = {}
        for _, u in ipairs(team.units) do
            if IsValid(u) and not u:IsDead() and not u:IsIncapacitated() then
                list[#list + 1] = {unit = u, rank = ScoutRank(u)}
            end
        end
        table.sort(list, function(a, b)
            if a.rank ~= b.rank then
                return a.rank < b.rank
            end
            return a.unit.handle < b.unit.handle
        end)
        roles = {turn = turn, seekers = {}}
        for i = 1, Min(#list, const.RATOAI.ScoutSeekers) do
            roles.seekers[list[i].unit] = true
        end
        ScoutRoles[team.side] = roles
    end
    return roles.seekers[unit] or false
end

---- on UnitProperties: mod code loads before ClassesBuilt, so Unit hasn't inherited it yet
local RATOAI_SelectArchetype_orig = UnitProperties.SelectArchetype
function UnitProperties:SelectArchetype(proto_context)
    RATOAI_SelectArchetype_orig(self, proto_context)
    if self.current_archetype == "Scout_LastLocation" and Archetypes.RATOAI_Scout_Hold and
        not RATOAI_IsScoutSeeker(self) then
        self.current_archetype = "RATOAI_Scout_Hold"
    end
end
