const.RATOAI = const.RATOAI or {}

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
        if IsValidPos(pos) and not CheckLOS(pos, unit, RATOAI_SightRadiusAt(unit, pos)) then
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
        radius = RATOAI_SightRadiusAt(unit, pos),
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

---- Scout whose optimal location is beyond this turn's reach: rush, not weigh cover against a trip-long
---- gradient. Keyed on the contact band, holders and seekers one floor above the spot never moved (Raider:452/457).
function RATOAI_ScoutRushing(context)
    local id = context.archetype and context.archetype.id
    if id ~= "Scout_LastLocation" and id ~= "RATOAI_Scout_Hold" then
        return false
    end
    local best = context.best_dest
    return best and not (context.dest_ap and context.dest_ap[best]) or false
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

---- Ends in view of the spot, or inside the standoff where LOS to one voxel means nothing, without AP
---- to answer: the trap that killed scouts one by one (Raider:461 ended 1 tile from 3 mercs on 1.4 AP).
function RATOAI_ScoutTrapDest(context, dest)
    local id = context.archetype and context.archetype.id
    local lk = context.unit.last_known_enemy_pos
    if not lk or (id ~= "Scout_LastLocation" and id ~= "RATOAI_Scout_Hold") then
        return false
    end
    local band = ScoutBand(context, lk)
    local x, y, z = stance_pos_unpack(dest)
    local ap = band.reach[point_pack(x, y, z)]
    if not ap or ap >= band.need then
        return false
    end
    local d = RATOAI_SpotDist(context, band.pos, x, y, z)
    return d < band.minr or d <= band.contact and DestLOS(band, dest)
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
    if RATOAI_ScoutTrapDest(context, dest) then
        return 0
    end
    if d <= band.contact and DestLOS(band, dest) then
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
        if IsValid(ally) and not ally:IsDead() and CheckLOS(pos, ally, RATOAI_SightRadiusAt(ally, pos)) then
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
    local in_view = function(pos)
        return SpotInView(team, pos)
    end
    for _, enemy in ipairs(enemies) do
        local rec = mem[enemy]
        ---- a spot the team sees empty moves along his heading; nothing out of view there = disproven
        local ppos = IsValidTarget(enemy) and rec.pos and RATOAI_ProjectMemory(rec.pos, rec.heading, in_view)
        if ppos then
            local pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(ppos))
            local age = Max(0, turn - (rec.turn or turn))
            local dist = unit:GetDist(pos)
            if not best or age < best_age or (age == best_age and dist < best_dist) then
                best, best_age, best_dist = pos, age, dist
            end
        end
    end
    return best
end

---------------------------------------------------------------------------------------------------
---- The engine's pick reads the REAL position of a random enemy. Kept as a rough pull toward the
---- nearest merc, standing in for heard gunfire: fuzzier when close (ScoutApproxMinTiles), where a
---- tight spot would be a wallhack, and never a tile the team already sees empty.
---- It also matched floors in voxel units against a world radius, so any floor passed; now the
---- spot is on the enemy's own floor.
---------------------------------------------------------------------------------------------------
local function EnginePickScoutLocation(unit)
    local enemy, enemy_dist
    for _, e in ipairs(GetAllEnemyUnits(unit)) do
        local d = unit:GetDist(e)
        if not enemy or d < enemy_dist then
            enemy, enemy_dist = e, d
        end
    end
    if not enemy then
        return
    end
    local near = enemy_dist < const.RATOAI.ScoutApproxMinTiles * const.SlabSizeX
    local r = (near and const.RATOAI.ScoutApproxNearRadiusTiles or const.RATOAI.ScoutApproxRadiusTiles) *
                  const.SlabSizeX
    local ex, ey, ez = RATOAI_ValidatePosZ(enemy:GetPos()):xyz()
    local floor_dz = 2 * const.SlabSizeZ
    local bbox = box(ex - r, ey - r, 0, ex + r + 1, ey + r + 1, MapSlabsBBox_MaxZ)
    local dests, dest_added = {}, {}
    ForEachPassSlab(bbox, function(x, y, z)
        local dx, dy = x - ex, y - ey
        if dx * dx + dy * dy <= r * r and abs((z or ez) - ez) <= floor_dz then
            local world_voxel = point_pack(x, y, z)
            if not dest_added[world_voxel] then
                dests[#dests + 1] = world_voxel
                dest_added[world_voxel] = true
            end
        end
    end)
    ---- random tries, not a full scan: SpotInView casts one ray per teammate
    for _ = 1, Min(#dests, const.RATOAI.ScoutApproxTries) do
        local v, idx = table.interaction_rand(dests, "Combat")
        local pt = point(point_unpack(v))
        if not SpotInView(unit.team, pt) then
            return pt
        end
        dests[idx] = dests[#dests]
        dests[#dests] = nil
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
    ---- saves from before the point_unpack fix carry an off-map spot that asserts in point_pack
    if unit.last_known_enemy_pos and not terrain.IsPointInBounds(unit.last_known_enemy_pos) then
        unit.last_known_enemy_pos = false
    end
    local lk = ScoutTarget(unit)
    if not lk then
        return
    end
    ---- the engine drops a seen spot only after moving (CombatAI.lua:2488); drop it before planning
    local pos = RATOAI_ValidatePosZ(lk)
    if IsValidPos(pos) and CheckLOS(pos, unit, RATOAI_SightRadiusAt(unit, pos)) then
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
                local belief = turns > 0 and age < turns and RATOAI_MemoryBelief(context, enemy, mem)
                if belief then
                    list[#list + 1] = {enemy = enemy, pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(belief)),
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
---- SEEKERS AND HOLDERS, by role. Long guns hold out of view of the spot (RATOAI_Scout_Hold); every
---- other archetype searches. A rank cap of 2 seekers left most of the team holding (G8: 5 of 8).
---- With no Soldier, Skirmisher or Brute alive on the team, the long guns search too.
---------------------------------------------------------------------------------------------------
local ScoutNaturalHolders = {
    RATOAI_Sniper = true,
    HeavyGunner = true,
    RATOAI_Rocketeer = true,
    RATOAI_RetreatingMarksman = true
}
local ScoutSearchers = {
    Soldier = true,
    Skirmisher = true,
    Brute = true
}
---- unused since roles went by archetype; kept declared so saves that persisted it still load
MapVar("RATOAI_ScoutRoles", {})

function RATOAI_IsScoutSeeker(unit)
    local lk = ScoutTarget(unit)
    if not ScoutNaturalHolders[unit.archetype] or not lk or
        unit:GetDist(lk) > const.RATOAI.ScoutContactTiles * const.SlabSizeX then
        return true
    end
    for _, u in ipairs(unit.team.units) do
        if ScoutSearchers[u.archetype] and IsValid(u) and not u:IsDead() and not u:IsIncapacitated() then
            return false
        end
    end
    return true
end

---- on UnitProperties: mod code loads before ClassesBuilt, so Unit hasn't inherited it yet
local RATOAI_SelectArchetype_orig = UnitProperties.SelectArchetype
function UnitProperties:SelectArchetype(proto_context)
    ---- a spot in view is already disproven; nil makes the engine ask AIPickScoutLocation instead
    local lk = self.last_known_enemy_pos
    if lk and IsKindOf(self, "Unit") then
        local pos = RATOAI_ValidatePosZ(lk)
        if IsValidPos(pos) and CheckLOS(pos, self, RATOAI_SightRadiusAt(self, pos)) then
            self.last_known_enemy_pos = false
        end
    end
    RATOAI_SelectArchetype_orig(self, proto_context)
    if self.current_archetype == "Scout_LastLocation" and Archetypes.RATOAI_Scout_Hold and
        not RATOAI_IsScoutSeeker(self) then
        self.current_archetype = "RATOAI_Scout_Hold"
    end
end

---------------------------------------------------------------------------------------------------
---- RE-PICK AFTER A REVEAL. Archetypes are picked once, when the team's turn starts
---- (CombatCamera.lua:869); later phases only re-Think. A merc revealed by an earlier phase left the
---- rest scouting: Scout:456 walked next to Kalyna on 0.7 AP with a 97% tile in reach (G8, T8).
---- Before each phase, scouts within contact range of a merc the team now sees run StartAI again,
---- which picks their base archetype (and its turn phase). Farther scouts keep rushing.
---------------------------------------------------------------------------------------------------
local function ScoutNearVisibleEnemy(unit)
    local id = unit.current_archetype
    if (id ~= "Scout_LastLocation" and id ~= "RATOAI_Scout_Hold") or not unit.ai_context or
        unit:IsIncapacitated() then
        return false
    end
    local contact = const.RATOAI.ScoutContactTiles * const.SlabSizeX
    for _, enemy in ipairs(unit:GetVisibleEnemies()) do
        if unit:GetDist(enemy) <= contact then
            return true
        end
    end
    return false
end

const.RATOAI.OrigAIGetNextPhaseUnits = const.RATOAI.OrigAIGetNextPhaseUnits or AIGetNextPhaseUnits
function AIGetNextPhaseUnits(units, max)
    for _, unit in ipairs(units) do
        if ScoutNearVisibleEnemy(unit) then
            if RATOAI_Debug then
                printf("[RATOAI] %s: merc revealed mid-turn, re-picking archetype (was %s)",
                       tostring(unit.session_id), tostring(unit.current_archetype))
            end
            unit:StartAI()
        end
    end
    return const.RATOAI.OrigAIGetNextPhaseUnits(units, max)
end
