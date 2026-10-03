const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- AIActionThrowGrenadeBlind -- grenade at where the team believes lost enemies are.
---- The engine scores a throw by GetActionResults, i.e. the REAL units in the blast; aimed at a
---- hidden merc's spot that is knowing what the AI can't. Here enemies come only from
---- RATOAI_BelievedEnemies and the zone is scaled by their trust. Own units do come from the real
---- results: the AI knows where its team is.
---------------------------------------------------------------------------------------------------
DefineClass.AIActionThrowGrenadeBlind = {
    __parents = {"AIActionThrowGrenade"},
    hidden = false
}

function AIActionThrowGrenadeBlind:GetEditorView()
    return "Throw grenade (blind, at believed enemy positions)"
end

local function OwnUnitHit(hit, team)
    local obj = hit.obj
    if not IsKindOf(obj, "Unit") or obj.team ~= team then
        return false
    end
    if (hit.damage or 0) > 0 then
        return true
    end
    for _, effect in ipairs(hit.effects or empty_table) do
        if effect and effect ~= "" then
            return true
        end
    end
    return false
end

function AIActionThrowGrenadeBlind:PrecalcAction(context, action_state)
    if RATOAI_TeamSeesEnemy(context) then
        return
    end
    local believed = RATOAI_BelievedEnemies(context)
    if #believed == 0 then
        return
    end

    local unit = context.unit
    local action_id, grenade
    for _, id in ipairs{"ThrowGrenadeA", "ThrowGrenadeB", "ThrowGrenadeC", "ThrowGrenadeD"} do
        local caction = CombatActions[id]
        local cost = caction and caction:GetAPCost(unit) or -1
        if cost > 0 and unit:HasAP(cost) then
            local weapon = caction:GetAttackWeapons(unit)
            if IsKindOf(weapon, "Grenade") and self.AllowedAoeTypes[weapon.aoeType or "none"] and
                self.AllowedTriggerTypes[weapon.TriggerType or "Contact"] then
                action_id, grenade = id, weapon
                break
            end
        end
    end
    if not action_id then
        return
    end

    local max_range = Min(self.MaxDist, grenade:GetMaxAimRange(unit) * const.SlabSizeX)
    local blast = grenade.AreaOfEffect * const.SlabSizeX

    ---- one candidate per distinct believed position
    local pts, seen = {}, {}
    for _, b in ipairs(believed) do
        local key = point_pack(SnapToVoxel(b.pos))
        if not seen[key] then
            seen[key] = true
            pts[#pts + 1] = b.pos
        end
    end
    AIFilterTargetPoints(unit, pts, self.MinDist, max_range)

    local caction = CombatActions[action_id]
    local zones = {}
    for _, pt in ipairs(pts) do
        local results = caction:GetActionResults(unit, {target = pt})
        local traj = results.trajectory or empty_table
        local impact = #traj > 0 and traj[#traj].pos or results.target_pos or pt
        local units, trust, n = {}, 0, 0
        local iz = impact:IsValidZ() and impact:z() or terrain.GetHeight(impact)
        for _, b in ipairs(believed) do
            ---- same level only: a floor is 3.5 m and the blast ~3.6 m, so 3D distance let a
            ---- grenade landing upstairs "hit" mercs right below it (measured, Raider:453)
            local bz = b.pos:IsValidZ() and b.pos:z() or terrain.GetHeight(b.pos)
            if impact:Dist2D(b.pos) <= blast and abs(iz - bz) <= 2 * const.SlabSizeZ then
                units[#units + 1] = b.enemy
                trust, n = trust + b.pct, n + 1
            end
        end
        if n > 0 then
            for _, hit in ipairs(results) do
                if OwnUnitHit(hit, unit.team) then
                    table.insert_unique(units, hit.obj)
                end
            end
            zones[#zones + 1] = {target_pos = pt, units = units, score_mod = trust / n}
        end
    end

    ---- no cover / prepared-attack terms: both read the real enemy, which nobody is looking at
    local zone, score = AIEvalZones(context, zones, self.min_score, self.enemy_score,
                                    self.team_score, self.self_score_mod, nil, nil,
                                    self.AllyThreatenedScore)
    if zone then
        action_state.action_id = action_id
        action_state.target_pos = zone.target_pos
        action_state.score = score
    end
end

---------------------------------------------------------------------------------------------------
---- AIActionOverwatchSuspect -- overwatch toward the suspected spot when nobody is visible.
---- The engine's fallback overwatch (CombatAI.lua:381) only fires for a unit that neither moved
---- nor acted, and indoors aims at doors and windows instead of the spot.
---------------------------------------------------------------------------------------------------
DefineClass.AIActionOverwatchSuspect = {
    __parents = {"AISignatureAction"},
    hidden = false,
    voice_response = "AIOverwatch"
}

function AIActionOverwatchSuspect:GetEditorView()
    return "Overwatch the suspected enemy spot"
end

---- Where the enemy comes into view on its way from pos to the unit: the first tile of its walk (the
---- spot flood's path, else the straight line) that the unit sees within range. A doorway, stair top
---- or corner, found per turn. Aiming at pos itself left a sniper's cone 0/54 visible (LegionSniper:458).
local function OverwatchAim(context, pos)
    local unit = context.unit
    local spot = RATOAI_ValidatePosZ(pos)
    if not IsValidPos(spot) then
        return
    end
    local slab = const.SlabSizeX
    local range = (context.ExtremeRange or 0) * slab
    local upos = unit:GetPos()
    local at = SnapToPassSlab(upos) or upos
    ---- own flood: the scoring one (24 tiles) missed a sniper 19 tiles off up a stair
    local key = point_pack(spot)
    local flood = context.__ratoai_ow_flood
    if not flood or flood.key ~= key then
        local walk = Presets.ConstDef["Action Point Costs"].Walk.value
        local tiles = Clamp(2 * upos:Dist(spot) / slab, 24, 60)
        local start = SnapToPassSlab(spot)
        local cp
        if start and walk > 0 then
            cp = CombatPath:new()
            cp:RebuildPaths(unit, tiles * walk, start, "Standing", true, true)
        end
        flood = {key = key, cp = cp}
        context.__ratoai_ow_flood = flood
    end
    local path = flood.cp and flood.cp:GetCombatPathFromPos(at)

    ---- spot first, so the first visible tile is where it steps into view
    local tiles = {}
    if path then
        for i = #path, 1, -1 do
            tiles[#tiles + 1] = point(point_unpack(path[i]))
        end
    else
        local n = Max(1, upos:Dist(spot) / slab)
        local sx, sy, sz = spot:xyz()
        local ux, uy, uz = upos:xyz()
        sz, uz = sz or terrain.GetHeight(spot), uz or terrain.GetHeight(upos)
        for i = 0, n do
            local p = SnapToPassSlab(point(sx + MulDivRound(ux - sx, i, n), sy + MulDivRound(uy - sy, i, n),
                                           sz + MulDivRound(uz - sz, i, n)))
            if p then
                tiles[#tiles + 1] = p
            end
        end
    end

    local cands, packed = {}, {}
    for _, p in ipairs(tiles) do
        local d = unit:GetDist(p)
        if d <= range and d >= 2 * slab then
            cands[#cands + 1] = p
            packed[#packed + 1] = stance_pos_pack(p, StancesList.Standing)
        end
    end
    if #packed == 0 then
        return
    end
    local _, data = CheckLOS(packed, unit, range)
    for i = 1, #packed do
        if data and data[i] then
            return cands[i]
        end
    end
end

---- Overwatch args aimed where the enemy coming from pos would appear, or nil when weapon, sight,
---- AP or UI state rule it out.
function RATOAI_OverwatchArgsAt(context, pos)
    local unit = context.unit
    local weapon = context.weapon
    if not pos or unit:HasPreparedAttack() or not IsKindOf(weapon, "Firearm") or
        (weapon.PreparedAttackType ~= "Overwatch" and weapon.PreparedAttackType ~= "Both") then
        return
    end
    local aim = OverwatchAim(context, pos)
    if not aim then
        return
    end
    local caction = CombatActions.Overwatch
    if not caction or caction:GetUIState({unit}) ~= "enabled" then
        return
    end
    local args, has_ap = AIGetAttackArgs(context, caction, nil, "None")
    if not args or not has_ap then
        return
    end
    args.target_pos = aim
    args.target = aim
    return args
end

function AIActionOverwatchSuspect:PrecalcAction(context, action_state)
    local lk = context.unit.last_known_enemy_pos
    if lk and not RATOAI_TeamSeesEnemy(context) then
        action_state.args = RATOAI_OverwatchArgsAt(context, lk)
    end
end

function AIActionOverwatchSuspect:IsAvailable(context, action_state)
    return not not action_state.args
end

function AIActionOverwatchSuspect:Execute(context, action_state)
    if AIPlayCombatAction("Overwatch", context.unit, nil, action_state.args) then
        return "done"
    end
end
