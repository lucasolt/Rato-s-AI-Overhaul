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

---------------------------------------------------------------------------------------------------
---- PESO POR RESULTADO ESPERADO, COM PORTAO DE AP E FALLBACK
----
---- Substitui a modulacao por RAZAO DE CTH (o PenaltyScale acima, "quanto esta penalidade doi")
---- pela razao entre os ACERTOS ESPERADOS da acao e os do ataque padrao ("quanto ela rende").
---- Base 100 nos dois casos, entao os `Weight` dos presets continuam significando o mesmo.
----
---- TRES PORTOES, nesta ordem, e a ordem importa:
----   1. sem destino ou sem alvo -> nao ha o que medir, peso passa intacto;
----   2. `has_ap` do AIGetAttackArgs -> e a MESMA resposta que o IsAvailable vai usar daqui a
----      pouco para reprovar a acao. Desabilitar aqui da o mesmo desfecho, mais cedo, e poupa os
----      4 a 8 CalcChanceToHit do ExpectedFor. Sem este portao os dois lados se contradizem no
----      painel: "razao 127" numa acao marcada "[falta: AP]", porque o ExpectedFor DEGRADA o
----      plano quando falta AP (larga a stance, atira do quadril) e o IsAvailable nao degrada;
----   3. razao nil (sem denominador confiavel) -> cai no PenaltyScale de sempre.
----
---- `fallback_penalty` e a penalidade que a formula antiga usava para AQUELA acao -- recoil na
---- AutoFire, penalidade de tiro localizado no SingleShot. Ela so e consultada no caminho 3.
---------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------
---- COMPENSACAO DE PARTE DO CORPO
----
---- Tiro localizado paga CTH e recebe outra coisa. A razao de acertos esperados ja cobra o preco
---- (a penalidade entra pelo target_spot_group do CalcChanceToHit) mas nao credita nada em troca
---- -- sem isto, mirar qualquer parte seria sempre pior que o torso, por construcao.
----
---- Dois fatores, e vale distinguir o que e medido do que e chute:
----   damage_mod -- do preset do proprio jogo. Head +80, Legs -50. Multiplicar por ele converte
----                 "acertos esperados" em "dano esperado", que e a moeda comparavel com o
----                 ataque padrao (torso, damage_mod 0). Isto nao e aproximacao.
----   efeito     -- const.RATOAI.BodyPartEffectBonus. Este e o grosseiro: critico, desarmar, Slowed,
----                 ignorar armadura. Sem medicao limpa possivel, porque o valor esta no turno
----                 seguinte e este estimador so simula um turno.
---------------------------------------------------------------------------------------------------
function RATOAI_BodyPartMul(body_part)
    if not body_part or body_part == "Torso" then
        return 100
    end
    local preset = Presets.TargetBodyPart.Default[body_part]
    local mul = 100 + ((preset and preset.damage_mod) or 0)
    local bonus = (const.RATOAI.BodyPartEffectBonus or empty_table)[body_part] or 0
    mul = MulDivRound(mul, 100 + bonus, 100)
    return Max(0, mul)
end

---------------------------------------------------------------------------------------------------
---- EFEITOS DE "NAO CONSEGUE ESCAPAR" QUE EXISTEM NESTA INSTALACAO
----
---- Nem todo efeito da lista e do jogo base. `PinnedDown` vem do mod *Pinned Down*, que o design
---- do Overhaul quase pressupoe -- mas so quase: e dependencia de DESIGN, nao de codigo, e quem
---- joga pode nao ter baixado.
----
---- O filtro nao e por seguranca: `HasStatusEffect` com id inexistente devolve falso sem
---- reclamar. E por legibilidade -- sem ele aquele ramo vira codigo morto silencioso e quem le
---- nao consegue distinguir "nao dispara nunca" de "nao esta instalado". Com o filtro, a lista
---- resolvida DIZ o que esta valendo nesta instalacao.
----
---- Nao checa id de mod de proposito: o efeito pode passar a vir de outra fonte, e o que importa
---- e se ele existe, nao quem o trouxe.
----
---- Resolvido uma vez e cacheado -- os CharacterEffectDefs nao existem quando o mod carrega.
---- Mesmo padrao do RATOAI_GetMaxCoverCTH em FUNCTION_ScoreAttacksDetailed.lua.
---------------------------------------------------------------------------------------------------
local STUCK_CANDIDATOS = {
    "StationedMachineGun", ---- base: presa na arma montada
    "ManningEmplacement", ---- base: idem
    "PinnedDown", ---- mod *Pinned Down* (opcional)
    "Slowed", ---- base
    "Suppressed" ---- base
}

local stuck_effects

function RATOAI_GetStuckEffects()
    if not stuck_effects then
        stuck_effects = {}
        ---- BUGFIX (B34): era `local defs = rawget(_G, "CharacterEffectDefs")`, que nao enxerga
        ---- global nenhuma neste engine -- `defs` vinha nil sempre e o `not defs` deixava passar a
        ---- lista inteira. O filtro nunca filtrou, e a lista resolvida MENTIA sobre o que esta
        ---- valendo nesta instalacao, que e a unica coisa que ela existe para dizer.
        ---- Acesso direto agora: esta funcao so roda em combate, muito depois do load, e a razao
        ---- do lazy (os defs nao existirem quando o mod carrega) e coberta pelo proprio cache.
        for _, id in ipairs(STUCK_CANDIDATOS) do
            if CharacterEffectDefs[id] then
                stuck_effects[#stuck_effects + 1] = id
            end
        end
    end
    return stuck_effects
end

function OnMsg.ModsReloaded()
    stuck_effects = nil
end

local function ExpectedWeight(self, context, weight, upos, action, target, attacker_pos, body_part,
                              dest_cth, fallback_penalty)
    if not (upos and target and action) then
        return weight, false
    end

    local _, has_ap = AIGetAttackArgs(context, action, body_part or "Torso", self.Aiming or "None",
                                      target)
    if not has_ap then
        return 0, true
    end

    ---- DEBUG (D7): `self.SustainedAttack` decide COMO o numerador e montado -- N ataques da
    ---- acao (ela vira o ataque padrao do turno) ou 1 ataque dela mais o padrao com o resto do
    ---- AP. E a mesma propriedade que governa a execucao no SOURCE_AIPlayAttacks, de proposito.
    local ratio = RATOAI_ExpectedRatio(context, action, upos, target, attacker_pos, body_part,
                                       self.SustainedAttack)
    if ratio then
        ---- zero acertos esperados nao e "peso baixo", e "nao faz sentido": desabilita e ainda
        ---- poupa o PrecalcAction desta acao no AISelectAction.
        if ratio <= 0 then
            return 0, true
        end
        return MulDivRound(weight, ratio, 100), false
    end

    return MulDivRound(weight, PenaltyScale(dest_cth, fallback_penalty or 0), 100), false
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
    local weight, disable, priority = self.Weight, false, self.Priority

    local upos, unit, action, dist, target, dest_cth, dest_recoil, attacker_pos = GetDestArgs(self,
                                                                                              context)
    ---- O point blank continua sendo PRIORIDADE, e nao um numero. E regra tatica deliberada
    ---- ("colado, despeja o pente"), nao artefato do scoring -- e o resultado esperado
    ---- concordaria com ela de qualquer jeito, com 10 a 15 balas e sem penalidade de distancia.
    ---- Deixar de fora mantem a flag mudando uma coisa so. 
    if dist and dist <= const.Weapons.PointBlankRange * const.SlabSizeX then
        priority = true
    else
        weight, disable = ExpectedWeight(self, context, weight, upos, action, target, attacker_pos,
                                         "Torso", dest_cth, dest_recoil)
    end

    return Max(0, weight), disable, priority
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

    local default_attack_id = context.default_attack and context.default_attack.id or ""
    local is_default_attack = not IsKindOf(self, "AIActionPinDown") and
                                  (not next(self.AttackTargeting) or self.AttackTargeting["Torso"]) and
                                  (default_attack_id == self.action_id)
    if is_default_attack then
        return 0, true, false
    end
    local hit_modifiers = Presets["ChanceToHitModifier"]["Default"]
    local weight, disable, priority = self.Weight, false, self.Priority

    local upos, unit, action, dist, target, dest_cth, dest_recoil, attacker_pos = GetDestArgs(self,
                                                                                              context)

    local leg_mul = 125

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B31): o peso descrevia uma parte do corpo e o tiro saia em outra.
    ----
    ---- Aqui a parte era "a primeira `true` na ordem do `pairs`" sobre o set AttackTargeting.
    ---- La no AIActionSingleTargetShot:PrecalcAction (AIActions.lua:733) a parte e sorteada com
    ---- `table.weighted_rand(body_parts, "chance", InteractionRand(...))`. Com um set de duas
    ---- partes, o peso podia falar da cabeca e a bala sair na perna -- e a penalidade de tiro
    ---- localizado difere MUITO entre elas (Head -40, Legs -10), entao nao era erro de
    ---- arredondamento.
    ----
    ---- Pior: `pairs` nao tem ordem garantida. Este peso alimenta o InteractionRand da escolha
    ---- de acao, que entra no NetUpdateHash -- era fonte de desync, nao so de imprecisao.
    ----
    ---- Agora as duas pontas leem a MESMA lista (o AIGetAttackTargetingOptions, memoizado por
    ---- turno) e o scoring assume a parte de maior peso, que e o resultado mais provavel do
    ---- sorteio. Continua sendo uma aproximacao -- o sorteio pode cair noutra -- mas e uma
    ---- aproximacao DETERMINISTICA da distribuicao certa, em vez de um valor arbitrario.
    ---------------------------------------------------------------------------------------------
    local body_part = "Head"

    if IsKindOf(self, "AIActionPinDown") then
        body_part = self.AttackTargeting
    elseif target then
        local opcoes = AIGetAttackTargetingOptions(unit, context, target, action,
                                                   self.AttackTargeting)
        local melhor = 0
        for _, o in ipairs(opcoes or empty_table) do
            local peso = o.chance or 0
            if peso > melhor then
                melhor, body_part = peso, o.id
            end
        end
        if melhor <= 0 then
            body_part = "Torso"
        end
    end

    local leg_shot = body_part == "Legs"

    if upos and target then
        ---------------------------------------------------------------------------------------
        ---- A penalidade de tiro localizado continua sendo calculada, mas agora so como
        ---- FALLBACK: e o que o ExpectedWeight usa quando nao ha denominador confiavel.
        ---- No caminho normal quem manda e a razao de acertos esperados, e ela ja carrega esta
        ---- penalidade por dentro -- o `body_part` chega ao target_spot_group do
        ---- CalcChanceToHit, que e de onde a penalidade sai. Aplicar aqui E la seria contar
        ---- duas vezes; por isso o valor entra so pelo parametro de fallback.
        ----
        ---- E ha o que a formula antiga NAO via e a nova ve: tiro localizado costuma exigir
        ---- mira maxima, mira custa AP, e AP custa ataques. Uma penalidade de -20 num plano de
        ---- tres tiros nao e a mesma coisa que -20 num plano de um tiro so.
        ---------------------------------------------------------------------------------------
        local use, targeted_penal = hit_modifiers.TargetedShot:CalcValue(unit, target,
                                                                         Presets.TargetBodyPart
                                                                             .Default[body_part],
                                                                         action,
                                                                         unit:GetActiveWeapons(),
                                                                         nil, nil, 3, false,
                                                                         attacker_pos,
                                                                         target:GetPos())
        local d
        weight, d = ExpectedWeight(self, context, weight, upos, action, target, attacker_pos,
                                   body_part, dest_cth, use and targeted_penal or 0)
        disable = disable or d

        ---- credita o que o tiro localizado ganha, agora que a razao ja cobrou o que ele custa
        weight = MulDivRound(weight, RATOAI_BodyPartMul(body_part), 100)
    end

    ---- TERMO DE EFEITO, nao de acerto: continua multiplicando DEPOIS da razao. Tiro na perna
    ---- em quem carrega arma de curto alcance vale pelo Slowed, nao pelo dano, e nada disso
    ---- aparece em "acertos esperados". A razao mede o custo de acertar; este multiplicador
    ---- mede o que o acerto compra. Camadas diferentes de proposito.
    if target and leg_shot then
        local target_weapon = target:GetActiveWeapons()
        if target_weapon and
            IsKindOfClasses(target_weapon, "SubmachineGun", "MeleeWeapon", "Pistol", "Revolver") then
            weight = MulDivRound(weight, leg_mul, 100)
        end
    end

    return Max(0, weight), disable, priority
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

    -----------------------------------------------------------------------------------------------
    ---- SNIPE, NAO SUPRESSAO.
    ----
    ---- No GBO3 a acao `PinDown` nao suprime ninguem: ela estende bastante o alcance da arma e
    ---- deixa o tiro muito acurado. O scoring que estava aqui era a leitura VANILLA -- dava bonus
    ---- proporcional a cobertura do alvo, que e como se pontua supressao (vale a pena prender
    ---- quem esta atras de cobertura justamente porque acertar e dificil). Para um snipe isso e o
    ---- contrario do que se quer.
    ----
    ---- O QUE SUMIU E POR QUE NAO FAZ FALTA. O bloco removido chamava
    ---- RangeAttackTargetStanceCover so para virar o sinal da penalidade de cobertura. Ele
    ---- carregava o BUGFIX (B2) -- o `cover_type` vinha do 5o retorno e nao do 3o -- que fica
    ---- registrado aqui porque a licao sobrevive a funcao: aquele CalcValue devolve
    ---- (use, value, name, metaText, type).
    ----
    ---- O GANHO DE CTH DO SNIPE NAO PRECISA DE TERMO. Alcance estendido e acuracia aparecem
    ---- sozinhos no CalcChanceToHit, portanto na razao de acertos esperados. Pontuar isso a mao
    ---- seria contar duas vezes. O que sobra sao os dois vieses que a razao NAO ve:
    -----------------------------------------------------------------------------------------------
    if self.AttackTargeting == "Torso" then
        ---- o localizado ja passou pelo ExpectedWeight la em cima, via
        ---- SingleShotTargeted_CustomScoring; so o torso falta.
        local d
        weight, d = ExpectedWeight(self, context, weight, upos, action, target, attacker_pos,
                                   "Torso", dest_cth, 0)
        if d then
            return 0, true, false
        end
    end

    ---- 1. LONGE. A razao ja diz se o tiro rende; este vies diz que ESTE tipo de tiro e o de
    ---- longa distancia. Rampa por tile alem do close range (o veto de perto ja aconteceu no
    ---- inicio da funcao), com teto para nao virar argumento sozinho no fim do mapa.
    local close = RATOAI_GetCloseRange()
    if dist and close and (const.RATOAI.SnipeDistBonus or 0) > 0 then
        local tiles_alem = Max(0, (dist - close) / const.SlabSizeX)
        local bonus = Min(const.RATOAI.SnipeDistBonusMax or 0,
                          tiles_alem * const.RATOAI.SnipeDistBonus)
        weight = MulDivRound(weight, 100 + bonus, 100)
    end

    ---- 2. ALVO PRESO. Tiro caro e lento contra quem vai sair da linha e AP jogado fora.
    ---- A lista vem do RATOAI_GetStuckEffects, que filtra pelos efeitos presentes nesta
    ---- instalacao -- `PinnedDown` e do mod *Pinned Down*, dependencia de design e nao de codigo.
    ---- Conferido no processo vivo: `Immobilized` e `Pinned` NAO existem neste jogo, apesar de
    ---- parecerem obvios. Emplacement/MG sao os mais fortes (a unidade esta literalmente presa na
    ---- arma), mas CONTAR condicoes em vez de pesar cada uma mantem isto no lugar de desempate
    ---- que ele deve ocupar.
    if target and IsKindOf(target, "Unit") and (const.RATOAI.SnipeStuckBonus or 0) > 0 then
        local presos = 0
        for _, ef in ipairs(RATOAI_GetStuckEffects()) do
            if target:HasStatusEffect(ef) then
                presos = presos + 1
            end
        end
        ---- ameacado por overwatch/melee tambem prende: mover custa levar o tiro
        if target:IsThreatened(nil, "overwatch") or target:IsThreatened(nil, "melee") then
            presos = presos + 1
        end
        if presos > 0 then
            weight = MulDivRound(weight, 100 + Min(3, presos) * const.RATOAI.SnipeStuckBonus, 100)
        end
    end

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

---------------------------------------------------------------------------------------------------
---- PREPARAR A ARMA EM VEZ DE ATIRAR MAL  (AIPrepareWeapon / R_PrepareWeapon)
----
---- Ligar pelo editor: `CustomScoring` = PrepareWeapon_CustomScoring na AIPrepareWeapon do
---- arquetipo. Sem isso a acao nao existe na pratica -- ela esta definida em
---- AIACTION_PrepareWeapon.lua mas nao esta em SignatureActions de arquetipo nenhum.
----
---- A PERGUNTA QUE ELA RESPONDE. Sobrou AP para um tiro de quadril e mais nada. Vale atirar?
---- Quase sempre nao: o tiro sai com mira 0, o hipfire come a CTH, e no fim do turno a arma
---- continua despreparada -- entao o turno seguinte TAMBEM comeca pagando stance. Preparar troca
---- um tiro ruim por um turno inteiro de tiros bons.
----
---- COMO ELA SABE QUE O TIRO SERIA RUIM. Nao ha estimativa nova aqui: e o mesmo
---- RATOAI_ExpectedFor do ataque padrao que ja alimenta todas as outras razoes. Dele vem o
---- `aim1` (o nivel de mira do primeiro disparo do plano) e os acertos esperados. `aim1 == 0` e,
---- literalmente, "este plano e de quadril" -- e a decisao que o AICalcAttacksAndAim ja tomou ao
---- ver que nao havia AP para a stance. Repetir esse teste com aritmetica propria seria a segunda
---- copia da regra, que e o que este arquivo evita desde o B6.
----
---- POR QUE NAO E "SE PUDER, PREPARE". Preparar so vale quando atirar NAO vale. Acima do limiar a
---- acao e desabilitada, e nao apenas despriorizada: um tiro que rende nunca deve concorrer com
---- nao atirar.
---------------------------------------------------------------------------------------------------
---- DEBUG (D6): grava a linha do painel para MGSetup/PrepareWeapon num lugar so, chamado de
---- TODO ramo que "respondeu" (mediu o tiro padrao e tem limiar). Tres coisas que sairam disto:
----
---- 1. `ratio` E `peso` SAO COISAS DIFERENTES, e o campo `ratio` era usado para as duas. No ramo
----    "ja rende" ele guardava o PESO CRU do preset (150, 80, o que o editor tiver); no ramo
----    interpolado, o PESO JA MULTIPLICADO (250). Nenhum dos dois respondia "quanto rende", que
----    e o que o nome promete. Agora `ratio` e a razao, e `peso_base`/`peso_final` sao o peso.
----
---- 2. O NUMERADOR E O LIMIAR, e nao os acertos do tiro. Esta e a parte que faz a razao daqui
----    significar o MESMO que a das acoes de tiro. La, `ratio = ExpectedFor(acao) / ExpectedFor(
----    ataque padrao)`: numerador = quanto a ACAO rende, denominador = quanto rende so atirar.
----    Aqui a acao nao dispara -- montar a MG, preparar a arma --, entao nao ha o que medir, e
----    quem faz as vezes do valor dela e o LIMIAR: por construcao ele e "quanto o tiro
----    precisaria render para NAO valer a pena trocar por esta acao".
----    Logo `ratio = limiar / hits_padrao`, e nao o contrario. Com 0.31 de tiro contra limiar
----    0.80 a razao e 258 ("montar rende 2,6x mais que atirar de pe"), nao 39.
----    O teste de que esta na direcao certa: o corte em 100 cai EXATAMENTE em cima do portao que
----    as duas funcoes ja usam (`hits >= limiar` -> nao infla / desabilita), entao "razao > 100"
----    quer dizer a mesma coisa na lista inteira.
----    `hits`/`base` seguem a mesma convencao das outras linhas -- `hits` = valor da ACAO,
----    `base` = valor de so atirar --, e por isso o painel imprime "(0.80 vs padrao 0.31)" sem
----    precisar de caso especial. `proxy = true` marca que aquele numerador e um limiar
----    constante e nao uma medicao, que e a unica diferenca real entre as duas familias.
----
---- 3. O ramo "ja rende" NAO GRAVAVA NADA -- `return` antes do `if RATOAI_Debug`. A acao continua
----    HABILITADA (nao e um `disable`), entao `dbg_expected[id]` ficava com o valor da ULTIMA
----    chamada que passou pelo bloco de baixo: de um RESTART anterior no MESMO turno (o
----    `AIActionMGSetup:PrecalcAction` devolve "restart" via MGPack, e o `context` -- e por
----    tabela, o `dbg_expected` -- nao e limpo entre um restart e o proximo; o cabecalho do
----    PrepareWeapon_Fallback_CustomScoring ja registrava esse risco para outro campo). O painel
----    mostrava um numero de outra posicao/alvo como se fosse desta chamada.
local function RegistrarExpectedMG(context, id, hits_padrao, limiar, peso_base, peso_final, target,
                                   dist, motivo)
    if not RATOAI_Debug then
        return
    end
    context.dbg_expected = context.dbg_expected or {}
    context.dbg_expected[id] = {
        hits = limiar, ---- valor da ACAO (proxy) -- ver o item 2 acima
        base = hits_padrao, ---- valor de simplesmente atirar
        ratio = RATOAI_RatioBase100(limiar, hits_padrao),
        proxy = true,
        peso_base = peso_base,
        peso_final = peso_final,
        alvo = IsKindOf(target, "Unit") and target.session_id or tostring(target),
        dist = dist,
        motivo = motivo
    }
end

function PrepareWeapon_CustomScoring(self, context, bloqueador)
    local weight, disable, priority = self.Weight, false, self.Priority
    local unit = context.unit

    ---- ja preparada: nao ha o que preparar
    if not unit or unit:HasStatusEffect("shooting_stance") then
        return 0, true, false
    end

    if bloqueador then
        local bloqueio = RATOAI_SignatureAvailableBefore(context, self, bloqueador)

        if RATOAI_Debug then
            context.dbg_expected = context.dbg_expected or {}
            context.dbg_expected["R_PrepareWeapon"] = {
                motivo = bloqueio and string.format("cede para %s (disponivel)", tostring(bloqueio)) or
                    "nada acima disponivel -- preparar"
            }
        end

        if bloqueio then
            return 0, true, false
        end
    end
    ---- o teto do vies, usado pelos casos em que atirar rende ZERO. Interpolar de 0 ate o limiar
    ---- e o caso continuo; estes sao o extremo do mesmo eixo, nao uma regra separada.
    local bonus = const.RATOAI.PrepareWeaponBonus or 0
    local function Preparar(mult)
        local w = MulDivRound(weight, 100 + mult, 100)
        ---- ferrolho: o tiro de hoje deixa a arma por ciclar e encarece o tiro de amanha
        ---- BUGFIX (B34): havia um `rawget(_G, "rat_canBolt")` no meio deste teste, e ele era nil
        ---- mesmo com a funcao carregada -- o bonus de ferrolho NUNCA foi aplicado, e o
        ---- `PrepareWeaponBoltBonus` era constante morta. O guard saiu em vez de ser consertado:
        ---- `rat_canBolt` e do GBO3, que e dependencia dura. Ver SOURCE_AICalcAttacksandAim.lua.
        if context.weapon and rat_canBolt(context.weapon) then
            w = MulDivRound(w, const.RATOAI.PrepareWeaponBoltBonus or 100, 100)
        end
        return Max(0, w), false, priority
    end

    local upos, _, _, dist, target, _, _, attacker_pos = GetDestArgs(self, context)

    ---------------------------------------------------------------------------------------------
    ---- SEM ALVO NO DESTINO. O turno vai acabar sem ataque nenhum, e o AP que sobra nao tem uso
    ---- melhor: preparar agora significa que o PROXIMO turno comeca sem pagar stance e com
    ---- min_aim ja em 1.
    ---- Nao ha risco de a unidade "deixar de atirar por causa disto": esta e uma signature de
    ---- NAO-movimento, escolhida depois de o destino estar fechado, e se houvesse alvo ele
    ---- estaria em dest_target. E o AIPrepareWeapon:PrecalcAction ainda exige um inimigo
    ---- conhecido (GetClosestEnemy ou um last_attack_pos) para virar disponivel -- sem ninguem
    ---- para encarar, a acao cai sozinha no IsAvailable.
    ---------------------------------------------------------------------------------------------
    if not (upos and target) then
        return Preparar(bonus)
    end

    local hits, attacks, aim1 = RATOAI_ExpectedFor(context, context.default_attack, upos, target,
                                                   attacker_pos)
    if not hits then
        return weight, disable, priority ---- nao deu para responder: peso do preset, sem opiniao
    end

    ---- NENHUM ataque cabe no AP. Mesmo caso do anterior, por outro caminho: sobra AP, nao sai
    ---- tiro. (`attacks == 0` tambem zera `aim1`, entao este teste tem de vir antes.)
    if (attacks or 0) <= 0 then
        return Preparar(bonus)
    end

    ---- o plano do turno NAO e de quadril: a unidade vai preparar e atirar, ou ja tem stance.
    ---- Preparar como acao separada seria gastar o AP do proprio tiro.
    if (aim1 or 0) > 0 then
        return 0, true, false
    end

    local limiar = const.RATOAI.PrepareWeaponMaxHits or 0
    if limiar <= 0 then
        return 0, true, false ---- limiar desligado pela constante: atirar ganha, sem opiniao a dar
    end

    if hits >= limiar then
        ---- DEBUG (D6): grava mesmo desabilitando -- ver o comentario de RegistrarExpectedMG.
        ---- Sem isto o campo ficava com o valor de uma chamada anterior (ex.: de um RESTART no
        ---- mesmo turno), e o motivo do disable ja aparece separado na pagina Acoes (DEBUG D5).
        RegistrarExpectedMG(context, "R_PrepareWeapon", hits, limiar, weight, 0, target, dist,
                            string.format(
                                "tiro de quadril rende %d.%02d, limiar %d.%02d -- atirar ganha",
                                hits / 100, hits % 100, limiar / 100, limiar % 100))
        return 0, true, false ---- o tiro de quadril rende o bastante; atirar ganha
    end

    ---- interpolacao linear: quanto mais perto de zero rende o tiro de agora, mais vale preparar
    local w, d, pr = Preparar(MulDivRound(limiar - hits, bonus, limiar))

    RegistrarExpectedMG(context, "R_PrepareWeapon", hits, limiar, weight, w, target, dist,
                        string.format("tiro de quadril rende %d.%02d, limiar %d.%02d", hits / 100,
                                      hits % 100, limiar / 100, limiar % 100))

    return w, d, pr
end

---------------------------------------------------------------------------------------------------
---- PREPARAR A ARMA COMO ULTIMO RECURSO  (AIPrepareWeapon / R_PrepareWeapon)
----
---- Variante BOOLEANA da PrepareWeapon_CustomScoring, para quem tem uma acao MELHOR que preparar
---- e quer preparar so quando ela nao da. Caso de uso: o HeavyGunner -- montar a MG e o que
---- importa; se nao der para montar mas ainda der para atirar, que atire; se nao der nenhuma das
---- duas, prepara a arma e comeca o proximo turno com a stance paga e min_aim ja em 1.
----
---- NAO ESTIMA NADA. Sem razao de CTH, sem acertos esperados, sem limiar: a pergunta e
---- "alguma acao ACIMA de mim nesta lista esta DISPONIVEL?", e quem responde e o motor, pelo
---- mesmo `action:IsAvailable(context, action_states[action])` que a AISelectAction acabou de
---- calcular nesta passada. Zero conta nova e zero segunda copia da regra -- inclusive a regra de
---- "da para montar a MG", que e cara (AIPrecalcConeTargetZones) e ja foi paga.
----
---- POR ISSO A ORDEM DA LISTA E QUE MANDA, e o AIPrepareWeapon tem de ficar por ULTIMO em
---- `SignatureActions` (que e onde um fallback mora). O laco para quando encontra a si mesmo: o
---- que vem antes bloqueia, o que vem depois e ignorado de proposito -- a AISelectAction so
---- sobrescreve `action_states[action]` quando CHEGA naquela acao, e o context nao e limpo entre
---- um "restart" e o proximo, entao ler adiante seria ler estado da passada anterior.
----
---- `bloqueador` (opcional): um `action_id` -- "MGSetup", por exemplo. Com ele, so aquela acao
---- bloqueia; sem ele, qualquer acao acima bloqueia.
----
---- LIMITE CONHECIDO -- O ATAQUE PADRAO NAO E UMA SIGNATURE. Ele entra na AISelectAction como
---- `base_weight` (`archetype.BaseAttackWeight`), fora da lista, e nenhum portao booleano daqui o
---- enxerga. Para o gunner DESMONTADO isso e o caso normal e nao a excecao: o AIActionMGBurstFire
---- so faz PrecalcAction com `StationedMachineGun` (AIActions.lua:868), entao desmontado ele
---- NUNCA fica disponivel -- quem fuzila e o ataque padrao. Ou seja, "atirar mal x preparar" se
---- resolve no Weight do AIPrepareWeapon contra o BaseAttackWeight do arquetipo, nao aqui.
----
---- E LEMBRAR QUE PREPARAR NO FIM DO TURNO JA ACONTECE SOZINHO: o RATOAI_TryEnterShootingStance
---- (FUNCTION_EndTurnAIAction.lua) entra em shooting stance com o AP que sobrar, de graca. O que
---- esta acao acrescenta e RESERVAR o turno para isso -- impedir que o AP vire um tiro ruim --,
---- nao a stance em si.
---------------------------------------------------------------------------------------------------
function PrepareWeapon_Fallback_CustomScoring(self, context, bloqueador)
    local unit = context and context.unit
    if not unit then
        return 0, true, false
    end

    ---- ja preparada, ou montado na MG / no emplacamento: nao ha o que preparar. Mesmo criterio
    ---- do RATOAI_TryEnterShootingStance, de proposito -- se ele nao prepara nesses estados, esta
    ---- acao tambem nao pode ganhar o turno para tentar.
    if unit:HasStatusEffect("shooting_stance") or unit:HasStatusEffect("StationedMachineGun") or
        unit:HasStatusEffect("ManningEmplacement") then
        return 0, true, false
    end

    local bloqueio = RATOAI_SignatureAvailableBefore(context, self, bloqueador)

    if RATOAI_Debug then
        context.dbg_expected = context.dbg_expected or {}
        context.dbg_expected["R_PrepareWeapon"] = {
            motivo = bloqueio and string.format("cede para %s (disponivel)", tostring(bloqueio)) or
                "nada acima disponivel -- preparar"
        }
    end

    if bloqueio then
        return 0, true, false
    end

    return self.Weight, false, self.Priority
end

---------------------------------------------------------------------------------------------------
---- MONTAR A MG EM VEZ DE ATIRAR MAL EM PE  (AIActionMGSetup / MGSetup)
----
---- Ligar pelo editor: `CustomScoring` = MGSetup_CustomScoring na AIActionMGSetup do arquetipo
---- (HeavyGunner e afins).
----
---- A MESMA PERGUNTA DO PrepareWeapon_CustomScoring, virada do avesso. La a comparacao era
---- "atirar mal de quadril x preparar"; aqui e "atirar agora, de pe, x montar a MG". Montar deita
---- a unidade e gasta o turno sem disparar -- so compensa quando o tiro que ela daria ESTE turno,
---- do jeito que esta, ja seria ruim. Contra alvo perto o tiro de pe normalmente ja rende, e ai
---- nao ha razao para trocar por um turno inteiro de preparacao.
----
---- MESMO ESTIMADOR do PrepareWeapon: RATOAI_ExpectedFor(context, context.default_attack, ...)
---- no destino e no alvo que o posicionamento ja escolheu (context.dest_target, via GetDestArgs).
---- Nao reestima CTH aqui, so compara o numero que a outra CustomScoring ja confia.
----
---- PERTO, NEM COMPARA. RATOAI_GetCloseRange (mesmo criterio do MobileAttack_CustomScoring e do
---- Pindown_CustomScoring, nao o PointBlankRange mais apertado do AutoFire) desliga a acao direto.
---- Sem este veto explicito o resultado dependeria da ORDEM das signature actions no arquetipo --
---- o AISelectAction devolve a PRIMEIRA acao com priority (SOURCE_AISelectAction.lua:45) e nada
---- aqui pode contar com o MGSetup vir depois do ataque padrao naquela lista.
----
---- JA MONTADA: outra pergunta. Com StationedMachineGun ou ManningEmplacement, esta CustomScoring
---- roda para o ramo de GIRAR/DESMONTAR do AIActionMGSetup:PrecalcAction (AIActions.lua:810-841),
---- nao para a decisao de montar -- o vies de "tiro inicial ruim" nao se aplica, e a funcao
---- devolve o peso do preset sem opiniao.
---------------------------------------------------------------------------------------------------
function MGSetup_CustomScoring(self, context)
    local weight, disable, priority = self.Weight, false, self.Priority
    local unit = context.unit

    if not unit or unit:HasStatusEffect("StationedMachineGun") or
        unit:HasStatusEffect("ManningEmplacement") then
        return weight, disable, priority
    end

    local upos, _, _, dist, target, _, _, attacker_pos = GetDestArgs(self, context)

    if dist and dist <= const.Weapons.PointBlankRange * const.SlabSizeX then -- RATOAI_GetCloseRange() then
        return 0, true, false
    end

    if not (upos and target) then
        return weight, disable, priority ---- nada para comparar: peso do preset, sem opiniao
    end

    local hits = RATOAI_ExpectedFor(context, context.default_attack, upos, target, attacker_pos)
    if not hits then
        return weight, disable, priority ---- nao deu para responder
    end

    local limiar = const.RATOAI.MGSetupMaxHits or 0
    if limiar <= 0 then
        return weight, disable, priority ---- limiar desligado pela constante: nada a dizer
    end

    if hits >= limiar then
        ---- DEBUG (D6): grava mesmo sem inflar -- ver o comentario de RegistrarExpectedMG.
        RegistrarExpectedMG(context, "MGSetup", hits, limiar, weight, weight, target, dist,
                            string.format(
                                "tiro de pe rende %d.%02d, limiar %d.%02d -- ja rende, sem inflar",
                                hits / 100, hits % 100, limiar / 100, limiar % 100))
        return weight, disable, priority ---- o tiro de pe ja rende; nao precisa inflar
    end

    ---- interpolacao linear, mesmo molde do Preparar() acima: quanto pior o tiro de agora,
    ---- mais vale montar a MG.
    local bonus = const.RATOAI.MGSetupBonus or 0
    local mult = MulDivRound(limiar - hits, bonus, limiar)
    local peso_final = MulDivRound(weight, 100 + mult, 100)

    RegistrarExpectedMG(context, "MGSetup", hits, limiar, weight, peso_final, target, dist,
                        string.format("tiro de pe rende %d.%02d, limiar %d.%02d", hits / 100,
                                      hits % 100, limiar / 100, limiar % 100))

    return Max(0, peso_final), disable, priority
end

---- "Alguma acao ACIMA desta na lista de signatures esta disponivel agora?" Devolve o action_id
---- (ou o nome da classe) da primeira que estiver, ou nil. Ver o cabecalho acima para o porque do
---- "acima" e nao "qualquer".
----
---- Sobre `context.action_states`: a entrada de uma acao passa a existir no momento em que a
---- AISelectAction chega nela -- VAZIA se o bias ou a CustomScoring desabilitaram (o PrecalcAction
---- nem roda), preenchida se rodou. IsAvailable sobre a tabela vazia devolve false/nil em todas as
---- classes do source (todas comecam por `action_state.has_ap`), entao "desabilitada" e
---- "indisponivel" dao no mesmo aqui, que e exatamente o que se quer de um portao de fallback.
function RATOAI_SignatureAvailableBefore(context, self_action, bloqueador)
    local states = context.action_states
    if not states then
        return
    end
    for _, action in ipairs(AIGetSignatureActions(context) or empty_table) do
        if action == self_action then
            return
        end
        local state = states[action]
        if state and (not bloqueador or action.action_id == bloqueador) then
            ---- pcall: IsAvailable de uma acao de terceiro nao pode derrubar a escolha do turno
            local ok, disponivel = pcall(action.IsAvailable, action, context, state)
            if ok and disponivel then
                return action.action_id or action.class
            end
        end
    end
end
