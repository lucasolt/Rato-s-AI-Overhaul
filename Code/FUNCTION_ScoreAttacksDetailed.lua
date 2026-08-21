---- PERF (F2.3 parcial): ResolveValue e uma constante de preset, mas era resolvida
---- dentro de lacos quentes. Resolvida uma vez e cacheada.
---- Nao da para resolver no escopo do arquivo: os Presets ainda nao existem no
---- momento em que o mod carrega.
local max_cover_cth
function RATOAI_GetMaxCoverCTH()
    if not max_cover_cth then
        max_cover_cth =
            Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover:ResolveValue("Cover")
    end
    return max_cover_cth
end

function OnMsg.ModsReloaded()
    max_cover_cth = nil
end

---- BUGFIX (B7): const.Combat.Recoil.StacksMultiplier e um float (0.35). Multiplicacao
---- de ponto flutuante neste caminho entra no NetUpdateHash de AIPrecalcDamageScore e
---- e fonte classica de desync. Versao inteira, em percentual.
---- MANTER EM SINCRONIA com GBO3 Code/__RecoilParams.lua:9
local RECOIL_STACKS_PCT = 35

---- fracao do recoil que se aplica por nivel de mira (era 0.33 / 0.66 / 1.0)
local recoil_pct_by_aim = {[0] = 100, [1] = 66, [2] = 33}

---------------------------------------------------------------------------------------------------
---- BUGFIX (B21): uma RAJADA valia um acerto so.
----
---- `hit_score` somava um `attack_mod` por ATAQUE, e uma rajada de 6 balas e um ataque.
---- Rajada com CTH 60 contribuia 60 -- 0,6 acerto esperado -- quando a expectativa real
---- e varias vezes isso. Toda arma automatica estava subcontada no scoring de posicao.
----
---- O jogo rola BALA A BALA. Formula real, de SOURCE_FirearmGetAttackResults.lua:255-279
---- do GBO3 (que por sua vez espelha Weapon.lua:2149):
----
----     shot_cth = original_cth - cth_loss_per_shot * Min(b-1, MaxShotIndexForRecoilCTHLoss)
----     se b > 1:  shot_cth = shot_cth - aim_cth      <- so a 1a bala fica com o bonus de mira
----     shot_cth = Clamp(shot_cth, 0, 100)
----     shot_cth = Max(shot_cth, Min(MultishotMinCTH, original_cth))    <- piso
----
---- com `cth_loss_per_shot = -recoil`, do MESMO `get_recoil` que a IA ja tem em maos.
---- Aqui `recoil_cth` ja vem negativo, entao a subtracao vira soma.
----
---- CUSTO: laco de N <= 6 com inteiros, ZERO `CalcChanceToHit` a mais -- os dois insumos
---- (`original_cth` e `recoil_cth`) ja estao calculados e cacheados quando este laco roda.
----
---- Constantes conferidas no processo vivo: MaxShotIndexForRecoilCTHLoss = 6,
---- MultishotMinCTH = 5.
---------------------------------------------------------------------------------------------------
---- Valor do modificador `Aim` para um nivel, cacheado na tabela do chamador.
---- `cache` nil = arma de tiro unico: nao ha bala 2 para perder o bonus, devolve 0.
local function RATOAI_AimBonus(cache, aim_level, unit, target, action, weapon)
    if not cache or (aim_level or 0) <= 0 then
        return 0
    end
    local v = cache[aim_level]
    if v == nil then
        local use, bonus = Presets.ChanceToHitModifier.Default.Aim:CalcValue(
                               unit, target, nil, action, weapon, nil, nil, aim_level)
        v = (use and bonus) or 0
        cache[aim_level] = v
    end
    return v
end

local function RATOAI_BurstHits(original_cth, shots, recoil_cth, aim_cth)
    if shots <= 1 then
        return original_cth
    end
    local max_idx = const.Combat.MaxShotIndexForRecoilCTHLoss or 6
    local floor_cth = Min(const.Combat.MultishotMinCTH or 5, original_cth)
    local total = 0
    for b = 1, shots do
        ---- recoil_cth e negativo; Min(b-1, max_idx) congela a degradacao apos o teto
        local c = original_cth + (recoil_cth or 0) * Min(b - 1, max_idx)
        if b > 1 then
            c = c - (aim_cth or 0)
        end
        total = total + Max(floor_cth, Clamp(c, 0, 100))
    end
    return total
end

function RATOAI_ScoreAttacksDetailed(mod, target, target_dist, upos, tpos, uz, k, ap, context,
                                     action, weapon, targets_attack_data, target_covers, target_los,
                                     attacker_pos, recoil_cth)
    local unit = context.unit
    ---- PERF (C2): `hit_modifiers` ficou sem uso aqui depois que o CalcValue
    ---- duplicado de cover saiu. Restam apenas as referencias comentadas abaixo.
    --------------------------

    -- 	local MinGroundDifference = hit_modifiers.GroundDifference:ResolveValue("RangeThreshold") *
    -- 	const.SlabSizeZ / 100
    -- local modHighGround = hit_modifiers.GroundDifference:ResolveValue("HighGround")
    -- local modLowGround = hit_modifiers.GroundDifference:ResolveValue("LowGround")
    -- local modSameTarget = hit_modifiers.SameTarget:ResolveValue("Bonus")
    -- local tx, ty, tz, tstance_idx = stance_pos_unpack(tpos)
    -- tz = tz or terrain.GetHeight(tx, ty)

    -- local is_heavy = IsKindOf(weapon, "HeavyWeapon")
    -- if not is_heavy then
    --     mod = mod +
    --               (uz > tz + MinGroundDifference and modHighGround or uz < tz - MinGroundDifference and
    --                   modLowGround or 0)
    --     mod = mod + (unit:GetLastAttack() == target and modSameTarget or 0)
    -- end

    local attacks, aims = AICalcAttacksAndAim(context, ap, target_dist)
    local args = AIGetAttackArgs(context, action, "Torso", "None")

    args.step_pos = context.attacker_pos
    args.prediction = true

    ---- PERF (C9): estas tabelas so sao lidas por IModeAIDebug:GetVoxelRolloverText.
    ---- Eram criadas por (destino, alvo) -- na casa dos milhares por turno --
    ---- e retidas ate o turno acabar.
    local dbg = RATOAI_Debug
    if dbg then
        context.aims_at[upos] = context.aims_at[upos] or {}
        context.aims_at[upos][target] = aims
        context.cth_attacks_at[upos] = context.cth_attacks_at[upos] or {}
        ---- BUGFIX (B15): era `or {}`. Dentro de UMA chamada de AIPrecalcDamageScore o
        ---- par (upos, target) e visitado uma vez so, mas o precalc roda mais de uma vez
        ---- por turno (e a UI de debug o reexecuta de proposito na camada
        ---- "target_recalc") -- e o `table.insert` abaixo entao APENDAVA na lista da
        ---- passada anterior, dobrando a contagem de disparos. Zerar e o correto.
        context.cth_attacks_at[upos][target] = {}
    end

    ---- PERF (C1): memoizacao do CTH por nivel de mira.
    ---- Dentro desta funcao `target`, `action` e `args.step_pos` sao fixos: a UNICA
    ---- entrada que muda entre iteracoes e `args.aim`. Mas CalcChanceToHit reavalia
    ---- os ~33 presets de ChanceToHitModifier toda vez, e so 4 deles dependem de
    ---- aim (Aim, ScopePenal, HipshotPenalty e RangeAttackTargetStanceCover quando
    ---- a arma tem IgnoreCoverCtHWhenFullyAimed).
    ---- Como todo o resto do input e identico, o resultado memoizado e igual por
    ---- construcao -- nao e aproximacao.
    ---- Ganho: AICalcAttacksAndAim costuma devolver todos os `aims` iguais (ramo
    ---- `not has_stance_ap or to_reach_desired_aim_level <= 0`), entao o caso comum
    ---- passa de 3-5 CTHs completos para 1.
    ---- BUGFIX (B1): a CTH do primeiro disparo precisa ser devolvida para
    ---- AIPrecalcDamageScore gravar em context.dest_cth. Antes, dest_cth acabava
    ---- recebendo `unit[weapon.base_skill]` (a Marksmanship crua), porque a linha
    ---- `local base_mod = mod` do source -- que sombreava a variavel externa com a
    ---- CTH calculada -- desapareceu quando este bloco substituiu o do vanilla.
    local first_cth

    ---- BUGFIX (B21): balas por ataque. Uma rajada e UM ataque no laco abaixo, mas N
    ---- balas na resolucao -- ver RATOAI_BurstHits.
    ---- Vem do context: `GetAutofireShots` depende so de (arma, acao), nao do destino
    ---- nem do alvo, entao e resolvido uma vez em AIPrecalcDamageScore.
    local burst_shots = context.burst_shots or 1

    ---- O bonus de mira so vale para a PRIMEIRA bala da rajada; as seguintes o perdem.
    ---- Tabela criada SO quando a arma e automatica -- em arma de tiro unico nao ha
    ---- segunda bala para perder bonus, e `RATOAI_AimBonus` devolve 0 sem alocar nada.
    ---- PERF (C11): funcao de arquivo, nao closure. Este trecho roda por par
    ---- (destino, alvo) e uma closure por par e exatamente o que o C11 tirou daqui.
    local aim_cth_by_level = burst_shots > 1 and {} or nil

    local cth_by_aim = {}
    for i = 1, attacks do
        local aim_i = aims[i]
        local attack_mod = cth_by_aim[aim_i]
        if not attack_mod then
            args.aim = aim_i
            attack_mod = unit:CalcChanceToHit(target, action, args, "chance_only")
            cth_by_aim[aim_i] = attack_mod
        end

        if i == 1 then
            first_cth = attack_mod
        end

        if dbg then
            ---- guardado o CTH da bala LIDER, nao a expectativa da rajada -- e o numero
            ---- que a pagina Alvo mostra por disparo, e o que se compara com o dest_cth
            table.insert(context.cth_attacks_at[upos][target], attack_mod)
        end

        mod = mod + RATOAI_BurstHits(attack_mod, burst_shots, recoil_cth,
                                    RATOAI_AimBonus(aim_cth_by_level, aim_i, unit, target,
                                                    action, weapon))

        if i > 1 and aim_i < 3 then
            ---- BUGFIX (B7): era
            ----   (aim_i == 2 and recoil_cth * 0.33 or aim_i == 1 and recoil_cth * 0.66
            ----    or recoil_cth) * (i - 1) * const.Combat.Recoil.StacksMultiplier
            ---- Mesma conta, agora inteira.
            local aim_pct = recoil_pct_by_aim[aim_i] or 100
            local recoil_penalty = MulDivRound(recoil_cth or 0, aim_pct * (i - 1), 100)

            mod = mod + MulDivRound(recoil_penalty, RECOIL_STACKS_PCT, 100)
        end
    end

    ---------------- For Custom Flanking Policy
    ---- PERF (C2): o ForEachPreset dentro do CalcChanceToHit acima ja avaliou
    ---- RangeAttackTargetStanceCover com estes mesmos argumentos -- refaze-lo aqui
    ---- era trabalho duplicado, e este preset faz raycast de cover.
    ---- O unico consumidor de target_covers e AIPolicyCustomFlanking:CompareCovers,
    ---- que usa a RAZAO cover_cth/cover_penalty. O valor de grid serve ao mesmo fim.
    local cover = GetCoverFrom(tpos, upos)
    if cover == const.CoverHigh then
        target_covers[target] = RATOAI_GetMaxCoverCTH()
    elseif cover == const.CoverLow then
        target_covers[target] = MulDivRound(RATOAI_GetMaxCoverCTH(), 50, 100)
    end

    target_los[target] = targets_attack_data and targets_attack_data[k] and
                             targets_attack_data[k].los

    return mod, target_covers, target_los, first_cth
end

function RATOAI_ScoreAttacks_Simple(hit_mod, target, target_dist, upos, tpos, uz, k, dist, ap,
                                    context, action, weapon, targets_attack_data, target_covers,
                                    target_los, attacker_pos)
    local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]
    local MinGroundDifference = hit_modifiers.GroundDifference:ResolveValue("RangeThreshold") *
                                    const.SlabSizeZ / 100
    local modHighGround = hit_modifiers.GroundDifference:ResolveValue("HighGround")
    local modLowGround = hit_modifiers.GroundDifference:ResolveValue("LowGround")
    local modSameTarget = hit_modifiers.SameTarget:ResolveValue("Bonus")
    local pb_cth_mod = Presets.ChanceToHitModifier.Default.PointBlank
    local scope_cth_mod = Presets.ChanceToHitModifier.Default.ScopePenal

    local aim_mod = Presets.ChanceToHitModifier.Default.Aim
    local unit = context.unit

    local tx, ty, tz, tstance_idx = stance_pos_unpack(tpos)
    tz = tz or terrain.GetHeight(tx, ty)

    local is_heavy = IsKindOf(weapon, "HeavyWeapon")
    if not is_heavy then
        hit_mod = hit_mod +
                      (uz > tz + MinGroundDifference and modHighGround or uz < tz -
                          MinGroundDifference and modLowGround or 0)
        hit_mod = hit_mod + (unit:GetLastAttack() == target and modSameTarget or 0)
    end

    ---------------------- Cover penalty score reworked
    local use_cover, cover_value, _, _, type_cover =
        hit_modifiers.RangeAttackTargetStanceCover:CalcValue(unit, target, nil, action, weapon, nil,
                                                             nil, nil, nil, attacker_pos)
    if use_cover then
        if type_cover == "Cover" then
            target_covers[target] = cover_value
        end
        hit_mod = hit_mod + cover_value
    end

    target_los[target] = targets_attack_data and targets_attack_data[k] and
                             targets_attack_data[k].los

    local use_meleecth, melee_range_cth = hit_modifiers.RangedMeleePenal:CalcValue(unit, target,
                                                                                   nil, action,
                                                                                   weapon, nil, nil,
                                                                                   nil, nil,
                                                                                   attacker_pos)
    if use_meleecth then
        hit_mod = hit_mod + melee_range_cth
    end

    local penalty = is_heavy and 0 or (100 - weapon:GetAccuracy(dist))

    local mod = hit_mod - penalty -- dist_penalty
    -- environmental modifiers when applicable

    local apply, value, target_spot_group, weapon1, weapon2, lof, aim, opportunity_attack
    apply, value = hit_modifiers.Darkness:CalcValue(unit, target, target_spot_group, action,
                                                    weapon1, weapon2, lof, aim, opportunity_attack,
                                                    attacker_pos)
    if apply then
        mod = mod + value
    end

    --------------------- Point blank rework
    if not is_heavy then
        local pb_apply, pb_value = pb_cth_mod:CalcValue(unit, target, target_spot_group, action,
                                                        weapon, nil, nil, nil, false, attacker_pos)
        if pb_apply then
            mod = mod + pb_value
        end
    end
    --------------------

    mod = Max(0, mod)

    ---- BUGFIX (B1): mesma correcao do caminho "Detailed" -- devolver a CTH do
    ---- primeiro disparo para que context.dest_cth deixe de receber a Marksmanship.
    local first_cth

    if mod > const.AIShootAboveCTH then
        -- calc base score based on cth/attacks/aiming
        local base_mod = mod
        local attacks, aims = AICalcAttacksAndAim(context, ap, target_dist)

        ---- DEBUG (D1): paridade com o caminho "Detailed". Sem isto a tabela de
        ---- candidatos e o detalhe tiro a tiro ficavam vazios com
        ---- UseSimpleAttacksScoring ligado.
        local dbg = RATOAI_Debug
        if dbg then
            context.aims_at[upos] = context.aims_at[upos] or {}
            context.aims_at[upos][target] = aims
            context.cth_attacks_at[upos] = context.cth_attacks_at[upos] or {}
            context.cth_attacks_at[upos][target] = {}
        end

        mod = 0
        for i = 1, attacks do
            local use, bonus, scope_use, scope_penal

            if (aims[i] or 0) > 0 then

                use, bonus = aim_mod:CalcValue(unit, context.current_target, nil,
                                               context.default_attack, context.weapon, nil, nil,
                                               aims[i])
                scope_use, scope_penal = scope_cth_mod:CalcValue(unit, context.current_target, nil,
                                                                 context.default_attack,
                                                                 context.weapon, nil, nil, aims[i],
                                                                 nil, context.attacker_pos)
            end

            local shot_cth = base_mod + (use and bonus or 0) + (scope_use and scope_penal or 0)
            if i == 1 then
                first_cth = shot_cth
            end

            if dbg then
                table.insert(context.cth_attacks_at[upos][target], shot_cth)
            end

            mod = mod + shot_cth
        end
    end

    -- ic(mod)
    return mod, target_covers, target_los, first_cth
end
