function getAISoldierFlankingBehaviorSelectionScore(unit, proto_context)

    ----- Initialization
    local context = unit.ai_context or AICreateContext(unit, proto_context)
    local weapon = context.weapon or unit:GetActiveWeapons()
    local score = 100
    local wep_stance_ap = GetWeapon_StanceAP(unit, weapon) or 1000

    ----- Weights
    local pb_mul = 120 ---- BUGFIX (B7): era 1.2 (float). Agora percentual inteiro.
    local weight_per_AP_stance = -8
    local weight_unbolted = -20
    local weight_mobile_att = 25
    local smg_handgun_score = 40
    local scope_score = -20

    ---- BUGFIX (B5): este bloco estava duplicado (aqui e logo depois do
    ---- weight_per_AP_stance), entao arma de ferrolho levava -40 em vez de -20.
    if weapon and rat_canBolt(weapon) then
        score = score + weight_unbolted
    end

    score = score + MulDivRound(wep_stance_ap, weight_per_AP_stance, const.Scale.AP)

    local available_attacks = weapon.AvailableAttacks or {}
    if IsKindOfClasses(weapon, "SubmachineGun", "Pistol", "Revolver") then
        score = score + smg_handgun_score
    elseif table.find(available_attacks, "MobileShot") or table.find(available_attacks, "RunAndGun") then
        score = score + weight_mobile_att
    end

    if weapon:HasComponent("ScopePenalty1") or weapon:HasComponent("ScopePenalty2") or
        weapon:HasComponent("ScopePenalty3") then
        score = score + scope_score
    end

    local pb_bonus = GetPBbonus(weapon)
    score = score + MulDivRound(pb_bonus, pb_mul, 100)

    -- ic("soldier flank", score)
    return score
end
