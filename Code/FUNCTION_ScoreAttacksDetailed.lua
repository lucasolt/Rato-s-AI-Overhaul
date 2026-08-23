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

---------------------------------------------------------------------------------------------------
---- RESULTADO ESPERADO DE UMA ACAO ALTERNATIVA  (flag RATOAI_ExpectedActionScore)
----
---- O PROBLEMA. As CustomScoring modulam o peso do preset por uma RAZAO DE CTH --
---- "que fracao da minha chance de acerto sobra depois desta penalidade" (o PenaltyScale
---- de FUNCTION_SignaturesCustomScoring). Isso responde "quanto doi", nunca "quanto
---- rende": nao ve quantas balas a acao dispara, quantos ataques cabem no AP, nem se a
---- unidade vai conseguir preparar a arma para atirar com ela.
----
---- Medido no processo vivo (LegionRaider/AK47, GBO3, 12 AP, stance+mira 5 AP):
----     SingleShot  2 AP / 1 bala      BurstFire  4 AP / 3 balas     AutoFire  8 AP / 10 balas
---- A AutoFire nao cabe com a stance (8 + 5 = 13 > 12), entao ela SEMPRE sai do quadril,
---- em mira 0. A decisao real nunca foi "rajada ou auto", e sim "auto do quadril contra
---- rajada preparada" -- e nenhuma das duas pontas disso aparecia no scoring.
----
---- O QUE ESTA FUNCAO FAZ. Roda a mesma conta do RATOAI_ScoreAttacksDetailed (o mesmo
---- RATOAI_BurstHits, o mesmo recoil persistente, o mesmo RATOAI_AimBonus) para UMA acao
---- candidata, no destino e no alvo que ja foram escolhidos.
----
---- POR QUE E BARATO. Ela so e chamada de dentro de uma CustomScoring, e a
---- AIChooseSignatureAction roda UMA vez por turno de unidade (CombatAI.lua:232), depois
---- que o AIPrecalcDamageScore ja foi refeito para o destino unico (CombatAI.lua:216).
---- Ou seja: um destino, um alvo, o AP real. O custo e O(#acoes) -- da ordem de uma
---- dezena de CalcChanceToHit por turno, contra os milhares que o laco de destinos ja
---- gastou. Nao encosta no caminho quente.
----
---- SEM DIVISAO POR AP. Todas as candidatas recebem o MESMO orcamento `ap`, e e o
---- AICalcAttacksAndAim que diz quantos ataques cabem em cada uma. Entao a soma de
---- acertos ja e comparavel como esta -- normalizar por AP seria dividir duas vezes.
---- NAO MODELADO (fica registrado): o AP que sobra. A BurstFire deste exemplo usa 9 de
---- 12 AP e o AIPlayAttacks depois reverte para ataques basicos com os 3 restantes. Quem
---- sobra com AP quebrado esta sendo levemente subestimado aqui.
----
---- Devolve `hits` (acertos esperados x100, a mesma unidade de context.dest_hit_score) e
---- `attacks`. Devolve nil quando nao da para responder -- o chamador cai no caminho antigo.
---------------------------------------------------------------------------------------------------
---- DEBUG (D2): declarada AQUI, no escopo do arquivo. O engine so permite criar global
---- durante o load -- em runtime `RATOAI_LastExpected = {}` levanta
---- "Attempt to create a new global" e derruba a escolha de acao da unidade (medido: o
---- sprocall do AIPlayAttacks engoliu, mas a unidade perdeu a signature action).
---- Criar sempre, e nao so com RATOAI_Debug: a flag e recomputada no CombatStart
---- (UTIL.lua:40), depois deste load -- decidir aqui pela flag decidiria cedo demais.
if rawget(_G, "RATOAI_LastExpected") == nil then
    RATOAI_LastExpected = {}
end

function RATOAI_ExpectedFor(context, action, upos, target, attacker_pos)
    local unit, weapon = context.unit, context.weapon
    if not (unit and weapon and action and upos) or not IsValidTarget(target) then
        return
    end

    ---- memo por (destino, acao). A AISelectAction chama cada CustomScoring uma vez, mas
    ---- a IModeAIDebug reexecuta o fluxo de proposito -- e o Pindown_CustomScoring chama
    ---- o SingleShotTargeted_CustomScoring por dentro.
    local memo = context.__ratoai_expected
    if not memo or memo.upos ~= upos then
        memo = {upos = upos}
        context.__ratoai_expected = memo
    end
    ---- chave inclui o nivel forcado: o RATOAI_EnsureAimPlan avalia o MESMO ataque em
    ---- varios niveis, e sem isso a segunda avaliacao devolveria a primeira.
    local key = tostring(action.id) .. "@" .. tostring(context.__ratoai_aim_force)
    local cached = memo[key]
    if cached then
        return cached.hits, cached.attacks, cached.aim1, cached.stance
    end

    ---- MESMA convencao de context.default_attack_cost (AICreateContext:
    ---- `default_attack:GetAPCost(unit)`, sem args) -- senao o custo da candidata viria
    ---- com stance/mira embutidos e o do default nao, e a comparacao mentiria.
    ---- pcall: GetAPCost do GBO3 passa por componentes de arma e por Unit:*; um mod de
    ---- terceiro que quebre ali nao pode derrubar o turno da IA.
    local ok, cost = pcall(action.GetAPCost, action, unit)
    if not ok or type(cost) ~= "number" or cost <= 0 then
        return
    end

    local shots = 1
    if weapon.GetAutofireShots then
        shots = Max(1, weapon:GetAutofireShots(action) or 1)
    end

    local ap = (context.dest_ap and context.dest_ap[upos]) or unit.ActionPoints or 0
    local dist = context.dest_target_dist and context.dest_target_dist[upos] and
                     context.dest_target_dist[upos][target]

    ---- O AICalcAttacksAndAim le `context.attacker_pos` (postura/stance) e
    ---- `context.current_target` (custo de rotacao da shooting stance) direto do context.
    ---- O laco do AIPrecalcDamageScore preenche os dois antes de chamar e limpa depois --
    ---- ou seja, aqui eles chegam nil. Reproduzir as MESMAS condicoes e o que mantem o
    ---- numerador comparavel com o denominador (dest_hit_score, que saiu daquele laco).
    local prev_pos, prev_target = context.attacker_pos, context.current_target
    context.attacker_pos, context.current_target = attacker_pos, target
    local ok_calc, attacks, aims, paid_stance = pcall(AICalcAttacksAndAim, context, ap, dist,
                                                      action, cost)
    context.attacker_pos, context.current_target = prev_pos, prev_target
    if not ok_calc then
        return
    end
    attacks = attacks or 0
    if attacks <= 0 then
        memo[key] = {hits = 0, attacks = 0}
        return 0, 0
    end

    ---- Recoil POR BALA desta acao. O cache do PERF (C4) NAO serve: ele e do
    ---- default_attack, e `num_shots` -- que muda com a acao -- entra no
    ---- GetCaliberStrRecoil. Uma chamada por acao por turno.
    ---- BUGFIX (B7): `get_recoil` termina em MulDivRound, mas MulDivRound PRESERVA float
    ---- quando a entrada e float -- medido no processo vivo: MulDivRound(1.5,100,100)
    ---- devolve 1.5, math.type "float". Este numero vira peso de acao, que vira roll
    ---- sincronizado, entao arredonda aqui.
    local recoil_cth = 0
    if IsKindOf(weapon, "Firearm") then
        local ok_r, r = pcall(get_recoil, unit, target, target:GetPos(), action, weapon, nil,
                              shots, nil, nil, nil, nil, nil, attacker_pos)
        recoil_cth = (ok_r and type(r) == "number") and cRound(r) or 0
    end

    ---- `target` explicito no 5o parametro: sem ele o AIGetAttackArgs preenche
    ---- `args.target` com `context.dest_target[GetPackedPosAndStance(unit)]` -- o alvo da
    ---- posicao ATUAL da unidade, que nao e necessariamente o alvo que estamos pontuando.
    local args = AIGetAttackArgs(context, action, "Torso", "None", target)
    args.step_pos = attacker_pos
    args.prediction = true

    ---- PERF (C1), mesma memoizacao: dentro deste laco so `args.aim` muda.
    local cth_by_aim = {}
    local aim_cth_by_level = shots > 1 and {} or nil
    local hits, stacks = 0, 0

    for i = 1, attacks do
        local aim_i = aims[i] or 0
        local attack_mod = cth_by_aim[aim_i]
        if not attack_mod then
            args.aim = aim_i
            attack_mod = unit:CalcChanceToHit(target, action, args, "chance_only")
            cth_by_aim[aim_i] = attack_mod
        end

        ---- recoil PERSISTENTE, identico ao ramo do RATOAI_ScoreAttacksDetailed
        ---- (B23a/B24): entra na CTH do ataque antes de expandir a rajada, e comeca em
        ---- zero porque as pilhas que a unidade ja carrega ja estao no CalcChanceToHit.
        local eff_cth = attack_mod
        if i > 1 and aim_i < 3 and stacks > 0 then
            local aim_pct = recoil_pct_by_aim[aim_i] or 100
            local recoil_penalty = MulDivRound(recoil_cth, aim_pct * stacks, 100)
            eff_cth = eff_cth + MulDivRound(recoil_penalty, RECOIL_STACKS_PCT, 100)
        end

        hits = hits + RATOAI_BurstHits(eff_cth, shots, recoil_cth,
                                       RATOAI_AimBonus(aim_cth_by_level, aim_i, unit, target,
                                                       action, weapon))
        stacks = (aim_i > 2) and 1 or (stacks + 1)
    end

    ---- DEBUG (D2): os insumos que produziram o numero. Sem eles "a IA escolheu auto"
    ---- nao se distingue de "a IA sorteou auto" -- e sao justamente custo, balas e
    ---- contagem de ataques que a conta antiga nao enxergava.
    local dbg
    if RATOAI_Debug then
        dbg = {cost = cost, shots = shots, attacks = attacks, recoil = recoil_cth,
               ap = ap, dist = dist, aims = table.concat(aims, ",", 1, attacks)}
        local cths = {}
        for aim_lvl, v in pairs(cth_by_aim) do
            cths[#cths + 1] = string.format("a%d=%d", aim_lvl, v)
        end
        table.sort(cths)
        dbg.cth = table.concat(cths, " ")
    end

    memo[key] = {hits = hits, attacks = attacks, dbg = dbg, aim1 = aims[1],
                 stance = paid_stance and true or false}
    return hits, attacks, aims[1], paid_stance
end

---------------------------------------------------------------------------------------------------
---- REPLANEJAMENTO DE MIRA POR RESULTADO  (flag RATOAI_AimReplan)
----
---- O QUE ELE CONSERTA. `GetIdealAimLevels` escolhe o nivel de mira por distancia. Ele
---- nunca pergunta se DOIS ataques com mira baixa rendem mais que UM com mira alta --
---- que e a pergunta que o AP faz. Medido em campo (MP40, rajada de 3, custo 3 AP, mira
---- 1 AP, recoil -26), o nivel otimo troca com o AP e nao e monotonico:
----     8 AP  -> mira 1 (2 ataques, 1.05)   contra mira 3 (1 ataque,  0.90)
----    12 AP  -> mira 3 (2 ataques, 1.80)   contra mira 1 (3 ataques, 1.35)
----    16 AP  -> mira 2 (3 ataques, 2.16)   contra mira 3 (2 ataques, 1.80)
----
---- POR QUE UM LIMIAR, E POR QUE ELE E ASSIMETRICO. "Acertos esperados" NAO ve tudo que a
---- mira compra: ela aumenta a chance de CRITICO, e o nivel 3 ZERA as pilhas de recoil
---- persistente. O segundo efeito o calculo enxerga (o laco de `stacks` esta no
---- RATOAI_ExpectedFor); o critico nao. Entao o vies fica do lado de MANTER a mira alta:
---- descer de nivel exige superar o limiar, subir e de graca. Sem isso o replan viraria
---- um otimizador que sempre converge para spray, que e exatamente o que nao se quer.
----
---- O QUE ELE NAO REFAZ. A contagem de ataques, o teto de max_attacks e a sobretaxa de
---- mira cobrada pelo recoil acumulado (B22) continuam saindo do AICalcAttacksAndAim --
---- este codigo so escolhe o nivel e deixa o planejador de sempre fazer a conta de AP.
----
---- CUSTO: no maximo 4 avaliacoes por (destino, alvo), uma vez por turno, na janela em
---- que destino e alvo ja estao decididos. O caminho quente (o laco de destinos) nao e
---- tocado -- la o GetIdealAimLevels continua mandando sozinho.
---------------------------------------------------------------------------------------------------
function RATOAI_EnsureAimPlan(context, upos, target, attacker_pos)
    if not RATOAI_AimReplan then
        return
    end
    local plan = context.__ratoai_aim_plan
    if plan and plan.upos == upos and plan.target == target then
        return plan.level
    end

    local action = context.default_attack
    if not action then
        return
    end

    ---- o plano da heuristica, que e a referencia a ser batida
    context.__ratoai_aim_force = nil
    local base_hits, _, heur_level = RATOAI_ExpectedFor(context, action, upos, target,
                                                        attacker_pos)
    if not base_hits or not heur_level then
        context.__ratoai_aim_plan = {upos = upos, target = target, level = nil}
        return
    end

    local margem = RATOAI_AimReplanThreshold or 15
    local best_level, best_hits = heur_level, base_hits
    local dbg_rows = RATOAI_Debug and {}

    for lvl = 0, 3 do
        context.__ratoai_aim_force = lvl
        local h, atks, real_lvl = RATOAI_ExpectedFor(context, action, upos, target, attacker_pos)
        if dbg_rows and h then
            dbg_rows[#dbg_rows + 1] = string.format("m%s=%dx/%d", tostring(real_lvl), atks or 0, h)
        end
        if h and real_lvl then
            ---- assimetria: descer de mira precisa vencer a margem, subir nao
            local alvo_hits = (real_lvl < heur_level) and
                                  MulDivRound(base_hits, 100 + margem, 100) or base_hits
            if h > alvo_hits and h > best_hits then
                best_level, best_hits = real_lvl, h
            end
        end
    end

    ---- nil quando o replan concorda com a heuristica: assim o AICalcAttacksAndAim nem
    ---- entra no ramo de sobrescrita e o comportamento fica identico ao de antes.
    context.__ratoai_aim_force = (best_level ~= heur_level) and best_level or nil
    context.__ratoai_aim_plan = {upos = upos, target = target, level = best_level}

    if RATOAI_Debug then
        context.dbg_aim_plan = {
            heur = heur_level, base = base_hits, best = best_level, hits = best_hits,
            margem = margem, planos = dbg_rows and table.concat(dbg_rows, " "),
        }
    end

    return best_level
end

---------------------------------------------------------------------------------------------------
---- Razao em base 100 entre o resultado desta acao e o do ataque padrao.
---- 100 = rende o mesmo que simplesmente atirar; 200 = rende o dobro; 0 = nao rende nada.
----
---- O DENOMINADOR SAI DE GRACA: context.dest_hit_score[upos] (BUGFIX B10) ja e a soma
---- limpa de CTH do default_attack naquele destino, contra o MESMO alvo (dest_target) e
---- com o MESMO orcamento de AP -- o AIPlayAttacks reexecuta o precalc para o destino
---- escolhido com `dest_ap[dest] = unit.ActionPoints` antes de escolher a acao.
----
---- Base 100 de proposito: e a mesma forma do PenaltyScale que ela substitui, entao os
---- `Weight` dos presets continuam significando o que significavam.
---------------------------------------------------------------------------------------------------
function RATOAI_ExpectedRatio(context, action, upos, target, attacker_pos)
    if not RATOAI_ExpectedActionScore then
        return
    end
    ---- decide o nivel de mira do ataque padrao ANTES de medi-lo: o denominador tem que
    ---- ser o plano que a unidade vai de fato executar, nao o que a heuristica sugeria.
    RATOAI_EnsureAimPlan(context, upos, target, attacker_pos)

    ---- DENOMINADOR. Preferencia pelo RATOAI_ExpectedFor do proprio ataque padrao, e nao
    ---- pelo dest_hit_score: os dois medem a mesma coisa, mas o dest_hit_score foi
    ---- calculado no precalc, ANTES do replan de mira, e ficaria descolado do plano real.
    ---- Refazer o precalc para corrigi-lo NAO e opcao -- ele consome RNG (RandRange por
    ---- alvo, InteractionRand na escolha) e uma chamada a mais desloca a sequencia
    ---- sincronizada. O ExpectedFor nao toca em RNG nenhum.
    local base, _, _, base_stance = RATOAI_ExpectedFor(context, context.default_attack, upos,
                                                       target, attacker_pos)
    if not base or base <= 0 then
        base = context.dest_hit_score and context.dest_hit_score[upos]
        base_stance = nil
    end
    if not base or base <= 0 then
        return ---- sem denominador confiavel: quem chamou volta ao caminho antigo
    end
    local hits, _, _, act_stance = RATOAI_ExpectedFor(context, action, upos, target, attacker_pos)
    if not hits then
        return
    end

    -----------------------------------------------------------------------------------------------
    ---- VIES DE SHOOTING STANCE (RATOAI_StanceBias)
    ----
    ---- Terminar o turno preparado vale AP no turno SEGUINTE -- o proximo ataque nao paga
    ---- stance de novo, e o min_aim ja comeca em 1. Nada disso aparece em "acertos
    ---- esperados deste turno", que e um estimador de um turno so.
    ----
    ---- So se aplica quando a unidade NAO esta preparada agora: quem ja tem a stance nao
    ---- ganha nada por manter, e as duas pontas pagariam o mesmo bonus de qualquer jeito.
    ----
    ---- Aplicado nos DOIS lados antes da razao, e nao na razao depois: assim ele e um
    ---- termo de valor, e nao um empurrao arbitrario em favor de uma acao. Se as duas
    ---- preparam (ou nenhuma prepara), o fator se cancela e a razao nao muda -- que e
    ---- exatamente o que se quer.
    ----
    ---- LEVE de proposito, como pedido: o default de 8% nao vira desempate sozinho em
    ---- nada que nao esteja ja quase empatado.
    -----------------------------------------------------------------------------------------------
    local bias = RATOAI_StanceBias or 0
    if bias > 0 and not context.unit:HasStatusEffect("shooting_stance") then
        if act_stance then
            hits = MulDivRound(hits, 100 + bias, 100)
        end
        if base_stance then
            base = MulDivRound(base, 100 + bias, 100)
        end
    end

    local ratio = MulDivRound(hits, 100, base)

    ---- DEBUG (D2): o par (acertos da acao, acertos do ataque padrao) que produziu a
    ---- razao. Sem isto, "por que a IA escolheu auto" nao tem resposta observavel.
    if RATOAI_Debug then
        local m = context.__ratoai_expected
        local slot = m and m[tostring(action.id) .. "@" .. tostring(context.__ratoai_aim_force)]
        context.dbg_expected = context.dbg_expected or {}
        context.dbg_expected[action.id or "?"] = {
            hits = hits, base = base, ratio = ratio, dbg = slot and slot.dbg,
            stance = act_stance, base_stance = base_stance,
        }

        ---- ...e uma copia FORA do context. O ai_context e zerado no fim da execucao do
        ---- time (CombatCamera.lua:1362 no fluxo normal, Combat.lua:1142 no
        ---- AIExecutionController), entao qualquer leitura feita DEPOIS do turno inimigo
        ---- -- que e a unica hora em que da para ler com calma -- pega nil. Este global
        ---- so existe com RATOAI_Debug e guarda o ultimo turno de cada unidade.
        local unit = context.unit
        local id = unit and unit.session_id
        if id then
            local store = RATOAI_LastExpected
            local turn = (g_Combat and g_Combat.current_turn) or 0
            local rec = store[id]
            if not rec or rec.turn ~= turn or rec.upos ~= upos then
                rec = {turn = turn, upos = upos, actions = {}}
                store[id] = rec
            end
            rec.base = base
            rec.default_attack = context.default_attack and context.default_attack.id

            ---- DEBUG (D2): o DENOMINADOR auditavel. `base` (= dest_hit_score) e a soma de
            ---- acertos do ataque padrao, mas o numero de ataques que produziu essa soma
            ---- nao fica gravado em lugar nenhum -- e e ele que carrega a diferenca de AP
            ---- entre os modos de tiro. Sem esta linha nao da para saber se a razao subiu
            ---- porque a acao rende mais ou porque o denominador levou ataques de menos.
            ---- Recalculo, e nao leitura: o precalc nao guarda a contagem. Uma chamada por
            ---- turno, so com RATOAI_Debug.
            local ok_b, b_atks, b_aims = pcall(AICalcAttacksAndAim, context,
                                               context.dest_ap and context.dest_ap[upos],
                                               context.dest_target_dist and
                                                   context.dest_target_dist[upos] and
                                                   context.dest_target_dist[upos][target])
            if ok_b then
                rec.base_attacks = b_atks
                rec.base_aims = b_aims and table.concat(b_aims, ",", 1, b_atks or 0)
            end
            rec.aim_plan = context.dbg_aim_plan
            rec.stance_bias = (bias > 0) and
                                  string.format("acao=%s padrao=%s", tostring(act_stance),
                                                tostring(base_stance)) or nil
            rec.base_shots = context.burst_shots
            rec.base_cost = context.default_attack_cost
            rec.stance = unit:HasStatusEffect("shooting_stance")
            rec.max_attacks = context.max_attacks
            rec.weapon = context.weapon and context.weapon.class
            rec.ap = context.dest_ap and context.dest_ap[upos]
            rec.dest_cth = context.dest_cth and context.dest_cth[upos]
            rec.target = IsKindOf(target, "Unit") and target.session_id or tostring(target)
            rec.actions[action.id or "?"] = {
                hits = hits, ratio = ratio, dbg = slot and slot.dbg,
            }
        end
    end

    return ratio
end
