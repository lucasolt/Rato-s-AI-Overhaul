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

---------------------------------------------------------------------------------------------------
---- Conversao do recoil POR BALA para o recoil PERSISTENTE.
----
---- Sao dois recoils diferentes, e o mod so calcula um deles:
----
----   por bala (dentro da rajada)   get_recoil(..., num_shots = N, stacks = nil)
----                                 -> penalty * 0.5            <- e este que a IA guarda
----   persistente (entre ataques)   get_recoil(..., aim, num_shots = false, stacks = n)
----                                 -> penalty * 0.35 * n, depois * (1 - 0.34 * aim)
----
---- Os dois partem do MESMO `penalty` -- mesmos parametros de arma, calibre, forca,
---- componentes, stance. `num_shots` so entra num lugar do GetCaliberStrRecoil, e so
---- para arma com tracante (`* Other.Tracer`, 0.89).
----
---- Logo, converter de um para o outro e 0.35 / 0.5 = **0.70**.
----
---- BUGFIX (B23b): era 35, o `StacksMultiplier` do GBO3 copiado cru. Mas aquele 0.35
---- pertence ao ramo que parte do `penalty` BRUTO; aplicado sobre um valor que ja levou
---- o 0.5, saia pela METADE. O recoil persistente estava sendo subestimado em 2x.
----
---- RESSALVA: em arma com tracante a conversao fica ~12% fora, porque o valor guardado
---- levou o 0.89 e o persistente nao. Nao vale um segundo `get_recoil` cacheado so por
---- isso -- se um dia valer, o lugar e o cache de bucket do PERF (C4).
----
---- BUGFIX (B7): era float (`const.Combat.Recoil.StacksMultiplier`), e float neste
---- caminho entra no NetUpdateHash e e fonte classica de desync. Percentual inteiro.
---------------------------------------------------------------------------------------------------
local RECOIL_STACKS_PCT = 70

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
    ---- BUGFIX (B24): tiro unico tambem clampa. Desde que o recoil persistente entra na
    ---- CTH do ataque (e nao na soma), `original_cth` pode chegar negativo aqui -- e um
    ---- ataque nunca pode CONTRIBUIR negativo para os acertos esperados. No caminho de
    ---- rajada abaixo o clamp por bala ja resolvia; este ramo escapava.
    if shots <= 1 then
        return Clamp(original_cth, 0, 100)
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
        context.burst_hits_at[upos] = context.burst_hits_at[upos] or {}
        context.burst_hits_at[upos][target] = {}
        context.recoil_loss_at[upos] = context.recoil_loss_at[upos] or {}
        context.recoil_loss_at[upos][target] = 0
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

    ---- BUGFIX (B23a): pilhas de recoil PERSISTENTE acumuladas DENTRO desta sequencia.
    ----
    ---- Comeca em ZERO de proposito, e nao nas pilhas que a unidade ja carrega. As que
    ---- ela ja tem estao no efeito `Rat_recoil`, cuja reacao de CTH o `CalcChanceToHit`
    ---- abaixo ja aplica -- ou seja, ja estao dentro de `attack_mod`. Somar de novo aqui
    ---- seria contar duas vezes.
    ----
    ---- Este acumulador existe so para as pilhas que a IA PREVE que vao surgir ao longo
    ---- do turno planejado, e que por isso nao existem no momento da consulta. E o mesmo
    ---- motivo do portao `i > 1`: o primeiro ataque nao ganha penalidade manual porque
    ---- ele ainda nao gerou pilha nenhuma.
    local stacks = 0

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

        ---- RECOIL PERSISTENTE -- outro recoil, nao o de dentro da rajada.
        ---- O de dentro da rajada esta no RATOAI_BurstHits e NAO depende de pilhas.
        ---- Este aqui e o `Rat_recoil`: acumula entre ATAQUES e some com mira 3.
        ----
        ---- BUGFIX (B24): ele era somado ao `mod` ACUMULADO, fora da expansao da rajada.
        ---- Com isso uma penalidade grande no 2o ataque comia o que o 1o tinha rendido --
        ---- um recoil de -500 invalidava um ataque anterior de 100. Nao e o que o jogo
        ---- faz: o `Rat_recoil` aplica em `data.mod_add`, ou seja mexe na CTH DAQUELE
        ---- ataque antes das balas rolarem, e ai cada bala clampa sozinha em [0, 100].
        ---- Agora entra na CTH do ataque, antes de expandir. O piso sai de graca.
        ----
        ---- BUGFIX (B7): era float; agora inteiro.
        ---- BUGFIX (B23a): a contagem era `i - 1`. Mas um ataque com mira 3 ZERA as
        ---- pilhas (ApplyPersistantRecoilEffects remove tudo e soma 1), entao o ataque
        ---- seguinte volta a 1 pilha em vez de seguir contando. Agora `stacks` acompanha,
        ---- com a MESMA progressao que o planejador de AP usa em AICalcAttacksAndAim.
        local eff_cth = attack_mod
        if i > 1 and aim_i < 3 and stacks > 0 then
            local aim_pct = recoil_pct_by_aim[aim_i] or 100
            local recoil_penalty = MulDivRound(recoil_cth or 0, aim_pct * stacks, 100)

            local perda = MulDivRound(recoil_penalty, RECOIL_STACKS_PCT, 100)
            eff_cth = eff_cth + perda
            if dbg then
                context.recoil_loss_at[upos][target] =
                    context.recoil_loss_at[upos][target] + perda
            end
        end

        if dbg then
            ---- a CTH da bala LIDER deste ataque, ja com o recoil persistente dentro --
            ---- e o numero que a rajada de fato expandiu
            table.insert(context.cth_attacks_at[upos][target], eff_cth)
        end

        local expanded = RATOAI_BurstHits(eff_cth, burst_shots, recoil_cth,
                                          RATOAI_AimBonus(aim_cth_by_level, aim_i, unit, target,
                                                          action, weapon))
        if dbg then
            table.insert(context.burst_hits_at[upos][target], expanded)
        end
        mod = mod + expanded

        stacks = (aim_i > 2) and 1 or (stacks + 1)
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
