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
        for _, b in ipairs(believed) do
            if impact:Dist(b.pos) <= blast then
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

function AIActionOverwatchSuspect:PrecalcAction(context, action_state)
    local unit = context.unit
    local weapon = context.weapon
    local lk = unit.last_known_enemy_pos
    if not lk or RATOAI_TeamSeesEnemy(context) or unit:HasPreparedAttack() or
        not IsKindOf(weapon, "Firearm") or
        (weapon.PreparedAttackType ~= "Overwatch" and weapon.PreparedAttackType ~= "Both") then
        return
    end
    ---- beyond the weapon's reach the cone covers nothing the merc must cross
    if unit:GetDist(lk) > (context.ExtremeRange or 0) * const.SlabSizeX then
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
    args.target_pos = lk
    args.target = lk
    action_state.args = args
end

function AIActionOverwatchSuspect:IsAvailable(context, action_state)
    return not not action_state.args
end

function AIActionOverwatchSuspect:Execute(context, action_state)
    if AIPlayCombatAction("Overwatch", context.unit, nil, action_state.args) then
        return "done"
    end
end
