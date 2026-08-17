local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]

---- BUGFIX (B6): as cinco copias de
----     ratio     = MulDivRound(cth + penalty, 100, cth)
----     score_mod = 100 - (100 - ratio)        -- isto e apenas `ratio`
----     weight    = MulDivRound(weight, score_mod, 100)
---- eram algebra identidade escrita de um jeito que escondia a formula, e nenhuma
---- protegia contra cth nil ou zero (divisao por zero).
----
---- O que a conta responde: "que fracao da minha chance de acerto sobra depois desta
---- penalidade?". 100 = a penalidade nao custa nada; 0 = consome a CTH inteira;
---- negativo = consome mais do que eu tenho (a acao deve ser descartada).
local function PenaltyScale(cth, penalty)
    if not cth or cth <= 0 then
        return 100 ---- sem CTH conhecida, nao modula
    end
    return MulDivRound(cth + (penalty or 0), 100, cth)
end

local function GetDestArgs(self, context)

    local unit = context.unit
    context = Update_AIPrecalcDamageScore(unit) or context

    local action = IsKindOf(self, "AIActionPinDown") and CombatActions["PinDown"] or
                       CombatActions[self.action_id]
    local dist, target, dest_cth, dest_recoil, attacker_pos
    local upos = context.ai_destination

    if not upos then ---- HoldPosition Behavior
        local packed_pos = GetPackedPosAndStance(unit)
        if packed_pos and context.dest_cth and context.dest_cth[packed_pos] then
            upos = packed_pos
        end
    end

    if upos then
        dest_cth = context.dest_cth and context.dest_cth[upos]
        dest_recoil = context.dest_target_recoil_cth and context.dest_target_recoil_cth[upos]
        local ux, uy, uz, ustance_idx = stance_pos_unpack(upos)
        attacker_pos = point(ux, uy, uz)
        target = context.dest_target[upos]
        if target then
            dist = context.dest_target_dist[upos] and context.dest_target_dist[upos][target] or
                       attacker_pos:Dist(target:GetPos())
        end
    end

    return upos, unit, action, dist, target, dest_cth, dest_recoil, attacker_pos
end

function AutoFire_CustomScoring(self, context)
    local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]
    local weight, disable, priority = self.Weight, false, self.Priority

    local upos, unit, action, dist, target, dest_cth, dest_recoil, attacker_pos = GetDestArgs(self,
                                                                                              context)
    if dist and dist <= const.Weapons.PointBlankRange * const.SlabSizeX then
        priority = true
    elseif dest_recoil then
        weight = MulDivRound(weight, PenaltyScale(dest_cth, dest_recoil), 100)
    end

    return Max(0, weight), weight < 0 and true or disable, priority
end

function MobileAttack_CustomScoring(self, context)
    local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]
    local weight, disable, priority = self.Weight, false, self.Priority

    local upos, unit, action, dist, target, dest_cth, dest_recoil, attacker_pos = GetDestArgs(self,
                                                                                              context)

    local use, snap_penal

    if dist and dist <= const.Weapons.PointBlankRange * const.SlabSizeX then
        priority = true
    elseif dist then
        if dist > RATOAI_GetCloseRange() then
            return 0, true, false
        elseif target and attacker_pos then
            use, snap_penal = hit_modifiers.HipshotPenalty:CalcValue(unit, target, nil, action,
                                                                     unit:GetActiveWeapons(), nil,
                                                                     nil, 1, false, attacker_pos,
                                                                     target:GetPos())
            weight = MulDivRound(weight, PenaltyScale(dest_cth, use and snap_penal or 0), 100)
        end
    end

    return Max(0, weight), weight < 0 and true or disable, priority
end

function SingleShotTargeted_CustomScoring(self, context)
    local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]
    local weight, disable, priority = self.Weight, false, self.Priority

    local upos, unit, action, dist, target, dest_cth, dest_recoil, attacker_pos = GetDestArgs(self,
                                                                                              context)

    local leg_mul = 125

    local body_part = "Head"

    if IsKindOf(self, "AIActionPinDown") then
        body_part = self.AttackTargeting
    else
        for part, boleano in pairs(self.AttackTargeting) do
            if boleano then
                body_part = part
                break
            end
        end
    end

    local leg_shot = body_part == "Legs"

    if upos and target then
        local use, targeted_penal = hit_modifiers.TargetedShot:CalcValue(unit, target,
                                                                         Presets.TargetBodyPart
                                                                             .Default[body_part],
                                                                         action,
                                                                         unit:GetActiveWeapons(),
                                                                         nil, nil, 3, false,
                                                                         attacker_pos,
                                                                         target:GetPos())
        weight = MulDivRound(weight, PenaltyScale(dest_cth, use and targeted_penal or 0), 100)
    end

    if target and leg_shot then
        local target_weapon = target:GetActiveWeapons()
        if target_weapon and
            IsKindOfClasses(target_weapon, "SubmachineGun", "MeleeWeapon", "Pistol", "Revolver") then
            weight = MulDivRound(weight, leg_mul, 100)
        end
    end

    return Max(0, weight), weight < 0 and true or disable, priority
end

function Overwatch_CustomScoring(self, context)
    local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]
    local weight, disable, priority = self.Weight, false, self.Priority

    local upos, unit, action, dist, target, dest_cth, dest_recoil, attacker_pos = GetDestArgs(self,
                                                                                              context)

    if not upos then
        return weight, disable, priority
    end

    local under_timed_multiplier = 125
    local sniper_mul = 60
    ---------
    local interrupt_cth_mod = 0
    local ow_cth = 0
    local use
    if target and attacker_pos then
        use, ow_cth = hit_modifiers["OpportunityAttack"]:CalcValue(unit, target, false, action,
                                                                   context.weapon, nil, nil, 1,
                                                                   true, attacker_pos,
                                                                   target:GetPos())
    end

    interrupt_cth_mod = interrupt_cth_mod + ow_cth
    ---------

    ---------
    local snap_penal = 0
    if unit and target then
        use, snap_penal = hit_modifiers.HipshotPenalty:CalcValue(unit, target, nil, action,
                                                                 unit:GetActiveWeapons(), nil, nil,
                                                                 1, false, attacker_pos,
                                                                 target:GetPos())
    end

    interrupt_cth_mod = interrupt_cth_mod + snap_penal
    ---------

    ---------
    local cover_penal = 0
    if unit and target then -- TODO: Make a special ratio for the cover. The more cover/cth ratio, the more chances to use overwatch
        use, cover_penal = hit_modifiers.RangeAttackTargetStanceCover:CalcValue(unit, target, nil,
                                                                                action,
                                                                                unit:GetActiveWeapons(),
                                                                                nil, nil, 1, false,
                                                                                attacker_pos,
                                                                                target:GetPos())
    end

    interrupt_cth_mod = interrupt_cth_mod + (cover_penal * -1)

    ---------
    weight = MulDivRound(weight, PenaltyScale(dest_cth, interrupt_cth_mod), 100)
    ---------

    if target and (target:IsUnderTimedTrap() or target:IsUnderBombard()) then
        weight = MulDivRound(weight, under_timed_multiplier, 100)
    end

    if context.unit and (context.unit.role or '') == "Marksman" then
        weight = MulDivRound(weight, sniper_mul, 100)
    end

    return Max(0, weight), weight < 0 and true or disable, priority
end

---------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Pindown_CustomScoring(self, context)
    local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]
    local weight, disable, priority = self.Weight, false, self.Priority
    -- if true then
    --    return weight, disable, priority
    -- end

    local upos, unit, action, dist, target, dest_cth, dest_recoil, attacker_pos = GetDestArgs(self,
                                                                                              context)

    if not upos then
        return weight, disable, priority
    end
    if dist and dist <= RATOAI_GetCloseRange() then
        return 0, true, false
    end
    -------------------------------------------------------
    if self.AttackTargeting ~= "Torso" then
        ---- BUGFIX (B2): a chamada descartava silenciosamente o 2o retorno
        ---- (`disable`), entao um alvo que o scoring localizado quisesse vetar
        ---- continuava valendo peso aqui.
        local targeted_weight, targeted_disable = SingleShotTargeted_CustomScoring(self, context)
        if targeted_disable then
            return 0, true, false
        end
        weight = targeted_weight
    end
    -------------------------------------------------------

    local _, max_aim = unit:GetBaseAimLevelRange(action, target) or 0, 3
    local extra_aim = Max(0, max_aim - 3)
    local extra_aim_bonus_mul = (extra_aim * 12) + 100
    -----------

    local pindown_score = 0
    ---------
    local cover_penal = 0
    local use, cover_type, _
    if unit and target then -- TODO: Make a special ratio for the cover. The more cover/cth ratio, the more chances to use overwatch
        ---- BUGFIX (B2): RangeAttackTargetStanceCover:CalcValue devolve
        ---- (use, value, name, metaText, type) -- o tipo e o 5o retorno, nao o 3o.
        ---- Como estava, `cover_type` recebia o `name` (um objeto T()), a comparacao
        ---- com "Cover" nunca dava verdadeira e o bonus por alvo em cobertura era
        ---- sempre zero. Ver GBO3 Code/CTH_cover_prone.lua:94.
        use, cover_penal, _, _, cover_type =
            hit_modifiers.RangeAttackTargetStanceCover:CalcValue(unit, target, nil,
                                                                 context.default_attack,
                                                                 unit:GetActiveWeapons(), nil, nil,
                                                                 1, false, attacker_pos,
                                                                 target:GetPos())
    end

    if use and (cover_type or "") == "Cover" then
        pindown_score = pindown_score + (cover_penal * -1)
    end

    weight = MulDivRound(weight, PenaltyScale(dest_cth, pindown_score), 100)

    -----------------
    if target and IsKindOf(target, "Unit") then
        if target:HasStatusEffect("Slowed") then
            weight = MulDivRound(weight, 120, 100)
        end
        if target:IsThreatened(nil, 'overwatch') or target:IsThreatened(nil, "melee") then
            weight = MulDivRound(weight, 120, 100)
        end
    end
    -----------------

    weight = MulDivRound(weight, extra_aim_bonus_mul, 100)

    return Max(0, weight), weight < 0 and true or disable, priority
end

function GrenadeLaunchCustomScoring(self, context)
    local unit = context.unit
    local weight, disable, priority = self.Weight, false, self.Priority

    if unit.indoors then
        weight = MulDivRound(weight, 30, 100)
    end

    return weight, disable, priority
end
