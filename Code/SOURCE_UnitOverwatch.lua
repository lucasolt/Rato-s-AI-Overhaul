const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- Cone length is the distance to the aim point (UnitOverwatch.lua:202): an AI aiming at a merc
---- 4 tiles away planted a 4-tile cone. Push the aim point out to the minimum along the same line.
---------------------------------------------------------------------------------------------------
local function MinConeAim(unit, target)
    local pos = IsValid(target) and target:GetPos() or target
    if not IsPoint(pos) then
        return
    end
    local min = (const.RATOAI.OverwatchMinTiles or 0) * const.SlabSizeX
    local upos = unit:GetPos()
    local d = pos:Dist2D(upos)
    if d <= 0 or d >= min then
        return
    end
    local ux, uy = upos:xy()
    local px, py, pz = pos:xyz()
    local x, y = ux + MulDivRound(px - ux, min, d), uy + MulDivRound(py - uy, min, d)
    return pz and point(x, y, pz) or point(x, y)
end

const.RATOAI.OrigOverwatchAction = const.RATOAI.OrigOverwatchAction or Unit.OverwatchAction
function Unit:OverwatchAction(action_id, cost_ap, args)
    if action_id == "Overwatch" and args and self.team and self.team.control == "AI" then
        local aim = MinConeAim(self, args.target)
        if aim then
            args = table.copy(args)
            args.target, args.target_pos = aim, aim
        end
    end
    return const.RATOAI.OrigOverwatchAction(self, action_id, cost_ap, args)
end

---------------------------------------------------------------------------------------------------
---- Vanilla returns before AimTarget, which does the step-out, when the attacker is hidden and the
---- target is not a visible unit (Unit.lua:7394). Spot overwatch aims at a point, so the cone was
---- saved from the step-out tile while the unit stayed in cover. Hidden units quick-play AimTarget.
---------------------------------------------------------------------------------------------------
const.RATOAI.OrigPrepareToAttack = const.RATOAI.OrigPrepareToAttack or Unit.PrepareToAttack
function Unit:PrepareToAttack(attack_args, attack_results)
    if not self.visible and self.command == "OverwatchAction" and self:CanQuickPlayInCombat() then
        local target = attack_args.target
        if not (IsKindOf(target, "Unit") and target.visible) then
            return self:AimTarget(attack_args, attack_results, true)
        end
    end
    return const.RATOAI.OrigPrepareToAttack(self, attack_args, attack_results)
end
