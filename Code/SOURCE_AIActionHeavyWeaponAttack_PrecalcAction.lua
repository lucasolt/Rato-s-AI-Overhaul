---- Vanilla aims every heavy weapon only at enemies the shooter sees itself. Mortars sit 20-50 tiles
---- back, so they rarely do and never fired; the player bombards anything the squad sees.
function AIActionHeavyWeaponAttack:PrecalcAction(context, action_state)
    local caction = CombatActions[self.action_id]
    local cost = caction and caction:GetAPCost(context.unit) or -1
    local weapon = caction and caction:GetAttackWeapons(context.unit)

    if not weapon or cost < 0 or not context.unit:HasAP(cost) or not weapon.ammo or
        weapon.ammo.Amount < 1 then
        return
    end
    if self.SmokeGrenade ~= (weapon.ammo.aoeType == "smoke") then
        return
    end
    local bombard = self.action_id == "Bombard"
    if bombard and context.unit.indoors then
        return
    end

    local max_range = Min(self.MaxDist, caction:GetMaxAimRange(context.unit, weapon) * const.SlabSizeX)
    local blast_radius = weapon.ammo.AreaOfEffect * const.SlabSizeX
    local target_pts = bombard and not context.target_locked and
                           AICalcAOETargetPoints(context, self.MinDist, max_range, blast_radius, nil,
                                                 "team") or nil
    local zones = AIPrecalcGrenadeZones(context, self.action_id, self.MinDist, max_range,
                                        blast_radius, weapon.ammo.aoeType, target_pts)

    if self.LimitRange then
        local attacker = context.unit
        local range = self.MaxTargetRange * const.SlabSizeX
        zones = table.ifilter(zones, function(idx, zone)
            return attacker:GetDist(zone.target_pos) <= range
        end)
    end

    local zone, score = self:EvalZones(context, zones)
    if zone then
        action_state.action_id = self.action_id
        action_state.target_pos = zone.target_pos
        action_state.score = score
    end
end
