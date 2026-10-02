---- Copy of AIActionMobileShot:PrecalcAction (AIActions.lua:597) gated on the engine's own shot plan:
---- execution re-picks the nearest reachable enemy per shot, not the precalc's dest_target.
function AIActionMobileShot:PrecalcAction(context, action_state)
    local unit = context.unit
    local action = CombatActions[self.action_id]

    if not context.ai_destination then
        return
    end

    local state = action:GetUIState({unit})
    if state ~= "enabled" then
        return
    end

    local x, y, z = stance_pos_unpack(context.ai_destination)
    local target_pos = point(x, y, z)
    local shot_voxels, shot_targets, shot_ch, canceling_reason =
        CalcMobileShotAttacks(unit, action, target_pos)
    shot_voxels = shot_voxels or empty_table
    shot_targets = shot_targets or empty_table
    shot_ch = shot_ch or empty_table

    if not (shot_voxels[1] and not canceling_reason[1] and IsValidTarget(shot_targets[1])) then
        return
    end

    ---- same floor the damage precalc applies to every other attack
    local min_cth = RATOAI_MinShotCTH(context, action:GetAttackWeapons(unit))
    for i, target in ipairs(shot_targets) do
        if target and (shot_ch[i] or 0) < min_cth then
            return
        end
    end

    action_state.args = {goto_pos = target_pos}
    local cost = action:GetAPCost(unit, action_state.args)
    action_state.has_ap = (cost >= 0) and unit:HasAP(cost)
end
