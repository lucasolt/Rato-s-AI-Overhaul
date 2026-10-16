---------------------------------------------------------------------------------------------------
---- SMOKE SCREEN -- smoke lands where it cuts the enemy's best lines of fire into exposed allies.
----
---- Smoke does not block sight in this game: CheckLOS ignores SmokeObj (measured 2026-10-15), and
---- visibility is built on CheckLOS. What it does is make shots through it bad: GBO3 charges a CTH
---- penalty per gas voxel the line crosses (CTH_smoke.lua), vanilla grazes. So a cloud is worth
---- the penalty it ADDS to each line, and it cuts both ways -- a line where our ally out-guns the
---- enemy counts against the throw.
----
---- Line value = threat(enemy -> ally) - threat(ally -> enemy). Threat = readiness (shooting stance
---- and facing, via RATOAI_SetupFactor; overwatch/pindown aimed at the ally beats both) times how
---- much cover does not stop it. Only enemies the team sees, so nothing here is a wallhack.
----
---- Preset `enemy_score`/`team_score`/`min_score` do not apply to smoke; the gate is SmokeMinScore
---- and the action Weight scales with the score (`weight_pct`, read by AISelectAction).
---------------------------------------------------------------------------------------------------

---- mirrors GBO3's Rat_SmokeVoxelsOnLine; that one only reads g_SmokeObjs, this needs a hypothetical cloud
local line_height = {Standing = 130 * guic, Crouch = 70 * guic, Prone = 30 * guic}

local function LineVoxels(a, b)
    local pa, pb = Rat_ValidZ(a:GetPos()), Rat_ValidZ(b:GetPos())
    local x1, y1 = pa:xy()
    local x2, y2 = pb:xy()
    local z1 = pa:z() + (line_height[a:GetHitStance()] or 100 * guic)
    local z2 = pb:z() + (line_height[b:GetHitStance()] or 100 * guic)
    local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
    local steps = Max(1, point(dx, dy, dz):Len() / (const.SlabSizeZ / 2))
    local list, last = {}, false
    for i = 0, steps do
        local packed = point_pack(WorldToVoxel(x1 + MulDivRound(dx, i, steps),
                                               y1 + MulDivRound(dy, i, steps),
                                               z1 + MulDivRound(dz, i, steps)))
        if packed ~= last then
            last = packed
            list[#list + 1] = packed
        end
    end
    return list
end

---- voxels crossed -> share of the max smoke penalty, 0..100
local function PenaltyPct(n)
    local ee = const.EnvEffects
    local max, per = ee.SmokeCTHPenaltyMax or -60, ee.SmokeCTHPenaltyPerVoxel or -10
    if max >= 0 then
        return n > 0 and 100 or 0
    end
    return Clamp(MulDivRound(per * n, 100, max), 0, 100)
end

local function CountSmoke(voxels, cloud)
    local n = 0
    for _, v in ipairs(voxels) do
        if g_SmokeObjs[v] or (cloud and cloud[v]) then
            n = n + 1
        end
    end
    return n
end

local function Uncovered(att_pos, target)
    local use, value = RATOAI_CoverCTH(att_pos, target:GetPos(), target.stance)
    local full, exposed = RATOAI_GetMaxCoverCTH(), RATOAI_GetExposedCoverCTH()
    if not use or full >= exposed then
        return 100
    end
    local covered = Clamp(MulDivRound(value - exposed, 100, full - exposed), 0, 100)
    return 100 - MulDivRound(covered, Clamp(const.RATOAI.SmokeCoverTrust or 0, 0, 100), 100)
end

local function Threat(context, shooter, target, aimed)
    if not IsKindOf(shooter:GetActiveWeapons(), "Firearm") then
        return 0 ---- smoke doesn't slow a knife
    end
    local ready = aimed and (const.RATOAI.SmokeOverwatchPct or 100) or
                      RATOAI_SetupFactor(shooter, context, target:GetPos(), 100,
                                         const.RATOAI.SmokeCostlyPct or 100)
    return MulDivRound(ready, Uncovered(shooter:GetPos(), target), 100)
end

local function AimedAt(enemy, ally)
    local pd = g_Pindown[enemy]
    return (pd and pd.target == ally) or (g_Overwatch[enemy] and ally:IsThreatened({enemy}, "overwatch"))
end

---- every enemy<->ally line the team can see, with its value and current smoke
local function CollectLines(context)
    local allies = {}
    for _, ally in ipairs(context.allies or empty_table) do
        if IsValidTarget(ally) then
            allies[#allies + 1] = ally
        end
    end
    local lines = {}
    if #allies == 0 then
        return lines
    end
    local own_pct = const.RATOAI.SmokeOwnFirePct or 100
    for _, enemy in ipairs(context.enemies or empty_table) do
        if context.enemy_visible_by_team[enemy] and IsValidTarget(enemy) then
            local srcs = {}
            for i = 1, #allies do
                srcs[i] = enemy
            end
            ---- all blocked returns (false, nil)
            local _, data = CheckLOS(allies, srcs, enemy:GetSightRadius())
            for i, ally in ipairs(allies) do
                if data and data[i] then
                    local v = Threat(context, enemy, ally, AimedAt(enemy, ally)) -
                                  MulDivRound(Threat(context, ally, enemy), own_pct, 100)
                    local vox = LineVoxels(enemy, ally)
                    local base = PenaltyPct(CountSmoke(vox))
                    if v ~= 0 and base < 100 then
                        lines[#lines + 1] = {enemy = enemy, ally = ally, v = v, vox = vox, base = base}
                    end
                end
            end
        end
    end
    return lines
end

---- landing points along the worst lines: near the ally, the middle, and on the enemy
local function Candidates(context, lines, min_range, max_range)
    local worst = table.ifilter(lines, function(_, l)
        return l.v > 0
    end)
    table.sort(worst, function(a, b)
        return a.v > b.v
    end)
    local pts, seen = {}, {}
    local step = 2 * const.SlabSizeX
    for i = 1, Min(#worst, const.RATOAI.SmokeLines or 6) do
        local apos, epos = Rat_ValidZ(worst[i].ally:GetPos()), Rat_ValidZ(worst[i].enemy:GetPos())
        local len = Max(1, apos:Dist(epos))
        local function along(d)
            local x1, y1, z1 = apos:xyz()
            local x2, y2, z2 = epos:xyz()
            return point(x1 + MulDivRound(x2 - x1, d, len), y1 + MulDivRound(y2 - y1, d, len),
                         z1 + MulDivRound(z2 - z1, d, len))
        end
        for _, pt in ipairs{along(Min(step, len)), along(len / 2), epos} do
            pt = SnapToPassSlab(pt)
            local key = pt and point_pack(WorldToVoxel(pt))
            if key and not seen[key] then
                seen[key] = true
                pts[#pts + 1] = pt
            end
        end
    end
    AIFilterTargetPoints(context.unit, pts, min_range, max_range)
    local cap = const.RATOAI.SmokeMaxCandidates or 12
    for i = #pts, cap + 1, -1 do
        pts[i] = nil
    end
    return pts
end

---- the voxel set the cloud would fill, from the real throw (same steps as ExplosionCreateSmokeAOE)
local function SimulateCloud(unit, action_id, target_pt)
    local results = CombatActions[action_id]:GetActionResults(unit, {target = target_pt})
    local trajectory = results.trajectory or empty_table
    local pos = #trajectory > 0 and trajectory[#trajectory].pos or results.target_pos
    if not pos then
        return
    end
    local water = terrain.IsWater(pos) and terrain.GetWaterHeight(pos)
    if water and (not pos:IsValidZ() or water >= pos:z()) then
        return
    end
    pos = SnapToPassSlab(pos) or pos
    local dx, dy = 1, 1
    for i = #trajectory - 1, 1, -1 do
        local step = trajectory[i]
        if step.pos:Dist2D(pos) > 0 then
            local px, py = step.pos:xy()
            local x, y = pos:xy()
            dx = (px == x) and 1 or ((x - px) / abs(x - px))
            dy = (py == y) and 1 or ((y - py) / abs(y - py))
            break
        end
    end
    local gx, gy, gz = WorldToVoxel(pos)
    local smoke = PropagateSmokeInGrid(gx, gy, gz, dx, dy)
    local cloud = {}
    for _, wpt in pairs(smoke or empty_table) do
        cloud[point_pack(WorldToVoxel(wpt))] = true
    end
    return cloud
end

function RATOAI_PrecalcSmokeScreen(self, context, action_state, action_id, max_range)
    if context.target_locked then
        return
    end
    local lines = CollectLines(context)
    local pts = Candidates(context, lines, self.MinDist, max_range)
    local best_pt, best = nil, (const.RATOAI.SmokeMinScore or 0) - 1
    for _, pt in ipairs(pts) do
        local cloud = SimulateCloud(context.unit, action_id, pt)
        if cloud then
            local score = 0
            for _, l in ipairs(lines) do
                local added = PenaltyPct(CountSmoke(l.vox, cloud)) - l.base
                if added > 0 then
                    score = score + MulDivRound(l.v, added, 100)
                end
            end
            if const.RATOAI.ZoneDebug then
                printf("[SMOKE] %s candidate %s score %d", tostring(context.unit.session_id),
                       tostring(pt), score)
            end
            if score > best then
                best_pt, best = pt, score
            end
        end
    end
    if const.RATOAI.ZoneDebug then
        printf("[SMOKE] %s %d lines, %d candidates, best %s", tostring(context.unit.session_id),
               #lines, #pts, best_pt and tostring(best) or "none")
    end
    if best_pt then
        action_state.action_id = action_id
        action_state.target_pos = best_pt
        action_state.score = best
        action_state.weight_pct = Clamp(MulDivRound(best, 100, const.RATOAI.SmokeRefScore or 100),
                                        0, const.RATOAI.SmokeWeightCapPct or 100)
    end
end
