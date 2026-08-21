local debug = false

---------------------------------------------------------------------------------------------------
---- ESCOLHA DE HIPFIRE
----
---- Ate aqui a IA nunca ESCOLHIA disparar do quadril: `stance_cost` so era zerado quando
---- faltava AP. Preparar a arma era automatico sempre que desse, mesmo colado -- e colado
---- e justamente onde nao compensa, porque a penalidade de hipfire e linear na distancia
---- (-123 x d/28) e perto ela e quase nula, enquanto o custo de preparar (2 a 4 AP,
---- medido em jogo) vale 1 a 2 disparos inteiros.
----
---- O criterio e por DISTANCIA e nao por comparacao de CTH de proposito: comparar CTH
---- exigiria uma chamada extra de CalcChanceToHit por (destino, alvo), que e o gargalo
---- conhecido deste mod. A distancia sai de graca, e a penalidade sendo linear faz o
---- limiar ser uma aproximacao honesta do ponto de virada (calculado em ~7-8 tiles para
---- as armas da amostra).
----
---- `RATOAI_HipfireMaxDist = 0` desliga e volta ao comportamento antigo (sempre preparar).
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_HipfireMaxDist") == nil then
    RATOAI_HipfireMaxDist = const.Weapons.PointBlankRange
end

---- numero de disparos que o laco `for i = 1, n` de fato executa
local function RATOAI_ShotsOf(n)
    return n - n % 1
end

---------------------------------------------------------------------------------------------------
---- DIAGNOSTICO DE MIRA / CONTAGEM DE ATAQUES
----
---- `local debug = true` no topo liga. UMA linha por chamada, no log do jogo
---- (AppData/Roaming/Jagged Alliance 3/logs/). A versao anterior eram 13 `print`
---- separados por par (destino, alvo) -- milhares de linhas por turno, ilegivel e caro.
----
---- `RATOAI_AimDebugUnit = "413"` (qualquer trecho do session_id) filtra para uma
---- unidade so. Sem filtro, sai tudo.
----
---- Campos que respondem a pergunta do free move:
----   ap      = o que a funcao recebeu (dest_ap na predicao, ActionPoints na execucao)
----   AP      = unit.ActionPoints agora
----   free    = unit.free_move_ap  -- so paga MOVIMENTO, mas esta dentro do AP
----   start   = context.start_ap   -- AP no inicio do turno
---- Se `ap` > `AP - free`, a estimativa esta contando free move como AP de ataque.
----
---- `pred` vs `EXEC` separa as duas chamadas: a predicao roda por (destino, alvo) no
---- scoring; a execucao roda uma vez em AIPlayAttacks (CombatAI.lua:285). As ultimas
---- linhas `pred` antes de um `EXEC` sao do destino ESCOLHIDO -- o AIPlayAttacks
---- reexecuta o precalc so nele antes de atirar.
---------------------------------------------------------------------------------------------------
local function RATOAI_AimDebugLine(context, unit, ap, target_dist, cost, stance_cost, rotation_cost,
                                   bolting_cost, min_aim, desired, has_stance, has_stance_ap,
                                   attacks, aims)
    local filt = rawget(_G, "RATOAI_AimDebugUnit")
    if filt and not tostring(unit.session_id):find(tostring(filt), 1, true) then
        return
    end
    local free = unit.free_move_ap or 0
    printf("[AIM] %s %s | ap=%s AP=%s free=%s start=%s limpo=%s | dist=%s | cost=%s stance=%s " ..
               "rot=%s bolt=%s | min_aim=%s desired=%s stance?=%s stance_ap?=%s max_atk=%s " ..
               "|| tiros=%s miras=%s", tostring(unit.session_id),
           context.AIisPlayingAttacks and "EXEC" or "pred", tostring(ap),
           tostring(unit.ActionPoints), tostring(free), tostring(context.start_ap),
           tostring((unit.ActionPoints or 0) - free),
           target_dist and tostring(MulDivRound(target_dist, 1, const.SlabSizeX)) or "nil",
           tostring(cost), tostring(stance_cost), tostring(rotation_cost), tostring(bolting_cost),
           tostring(min_aim), tostring(desired), tostring(has_stance), tostring(has_stance_ap),
           tostring(context.max_attacks), tostring(attacks),
           aims and table.concat(aims, ",") or "nil")
end
---TODO: Consider leaving this function as "pre-planning" and moving the more complex logic to when the positions are defined?
function AICalcAttacksAndAim(context, ap, target_dist)

    ------- Fix for min aim
    local unit = context.unit
    unit.AI_dont_return_Stance_min_aim_level = true --- avoiding duplicates. GetBaseAimLevelRange check considers unit position, not future positions like the current function calculates
    local min_aim, max_aim = unit:GetBaseAimLevelRange(context.default_attack, false)
    unit.AI_dont_return_Stance_min_aim_level = false

    local free_move_ap = unit.free_move_ap or 0

    ---------------------------------------------------------------------------------------
    ---- BUGFIX (B19): o `ap` que chega aqui contava o free move como AP de ataque.
    ----
    ---- `free_move_ap` esta DENTRO de `ActionPoints` (Unit.lua:2266, por isso
    ---- `GetUIActionPoints` o subtrai) mas so paga MOVIMENTO (Unit.lua:2315). E o `ap`
    ---- da predicao vem de `dest_ap`, que parte de `unit.ActionPoints`
    ---- (CombatAI.lua:1018) -- ou seja, com o free move inteiro dentro.
    ----
    ---- Medido no processo vivo: LegionRaider com AP=19.0, free=7.0, custo de ataque
    ---- 4.0 e mira 1.0. Ela planejava 3 ataques (3 x (4+2) = 18 <= 19) quando so tinha
    ---- 12.0 utilizaveis. Sete AP de orcamento fantasma, mais de um ataque inteiro.
    ----
    ---- A linha existiu como `ap = ap - free_move_ap` e saiu no commit 91b8eb4 ("1.08",
    ---- 2025-02-04). Nao volta assim: `dest_ap` NAO desconta o trajeto com free move --
    ---- verificado lendo a distribuicao de `dest_ap` dos 204 destinos daquela unidade,
    ---- onde so UM valia 19000 (a posicao atual) e o seguinte ja caia para 16000. Se
    ---- houvesse desconto haveria um plato em 19000 para tudo dentro dos 7 AP gratis.
    ---- Logo `dest_ap = ActionPoints - custo_bruto`, e subtrair o free move CHEIO
    ---- cobraria o deslocamento duas vezes.
    ----
    ---- O que precisa sair e so o que SOBRA da franquia depois do trajeto:
    ----     m  = start_ap - ap                  custo bruto ate este destino
    ----     F' = Max(0, free_move_ap - m)       franquia nao usada
    ---- Com A=19 e F=7: m=0 -> 12 | m=3 -> 12 | m=7 -> 12 | m=10 -> 9.
    ---- O AP de ataque so cai depois que o trajeto estoura a franquia, que e a
    ---- semantica correta.
    ----
    ---- Na EXECUCAO e no-op: AIPlayAttacks remove o FreeMove antes (CombatAI.lua:203),
    ---- entao `free_move_ap` ja e 0 e `F'` da 0.
    ---------------------------------------------------------------------------------------
    local moved_ap = Max(0, (context.start_ap or unit.ActionPoints or 0) - (ap or 0))
    local leftover_free = Max(0, free_move_ap - moved_ap)
    ap = Max(0, (ap or 0) - leftover_free)
    ----

    ---- Shooting Stance checks
    local stance_cost = 0
    local recoil_aim_cost = 0
    local rotation_cost = 0
    local aim_cost = Get_AimCost(unit)

    local not_moved, has_stance

    if IsKindOf(context.weapon, "Firearm") then
        local unit_pos = unit and unit:GetPos()
        local attack_pos = context.attacker_pos

        if context.AIisPlayingAttacks and unit:HasStatusEffect("shooting_stance") then
            has_stance = true
        elseif attack_pos and unit_pos then
            attack_pos = attack_pos:SetTerrainZ()
            unit_pos = unit_pos:SetTerrainZ()

            not_moved = attack_pos == unit_pos
            has_stance = not_moved and context.unit:HasStatusEffect("shooting_stance")
        end

        -------- Persistant recoil aim cost increase
        --- I dont think this is going to work 
        --[[if not_moved then
            local recoil = unit:GetStatusEffect("Rat_recoil")
            if recoil then
                recoil_aim_cost = recoil:ResolveValue("aim_cost")
            end
        end]]

        if has_stance then
            rotation_cost = unit:GetShootingStanceAP(context.current_target, context.weapon, 1,
                                                     context.default_attack, "rotate")
        else
            stance_cost = GetWeapon_StanceAP(unit, context.weapon) + aim_cost
        end
    end
    ------

    local cost = context.default_attack_cost

    ---- Manual Cycling
    local bolting_cost = 0
    local is_unbolted, can_bolt

    if context.weapon and rat_canBolt(context.weapon) then
        can_bolt = true
        bolting_cost = rat_get_manual_cyclingAP(unit, context.weapon, true) * const.Scale.AP
        is_unbolted = context.weapon.unbolted
    end

    if can_bolt and not is_unbolted then ---- if is_unbolted the atk_cost will already have bolting cost
        ap = ap + bolting_cost ----- otherwise, discount the first shot cost
        cost = cost + bolting_cost ---- and increase the atk cost
    end

    ----

    local total_stance_cost = cost + stance_cost

    ---- support for reverting to basic attacks from AIPlayAttacks (always on the same position as the signature)
    if context.AIisPlayingAttacks and unit:HasStatusEffect("shooting_stance") then
        total_stance_cost = 0
        stance_cost = 0
    end

    -- total_stance_cost = (context.ap_after_signature and unit:HasStatusEffect("shooting_stance")) and
    --                         0 or total_stance_cost
    -- stance_cost = (context.ap_after_signature and unit:HasStatusEffect("shooting_stance")) and 0 or
    --                   stance_cost
    ----

    local has_stance_ap = ap >= total_stance_cost

    -----------------------------------------------------------------------------------
    ---- Perto o bastante e o AP de preparar custa disparo? Entao dispara do quadril.
    ----
    ---- As DUAS condicoes importam. Se preparar nao custa disparo nenhum -- porque o
    ---- `max_attacks` ja e o teto, ou porque sobra AP -- entao a stance e CTH melhor de
    ---- graca e seria burrice abrir mao dela. Sem esse segundo teste a regra viraria
    ---- "colado nunca prepara", que troca um vies por outro.
    ----
    ---- Desligar `has_stance_ap` e o suficiente: o bloco abaixo zera o `stance_cost` e
    ---- nao sobe o `min_aim`, entao os disparos saem em aim 0 (= hipfire) e a contagem
    ---- volta a ser `ap / cost`. E o mesmo caminho que ja existia para falta de AP.
    ----
    ---- Vale para a EXECUCAO tambem, nao so para o score: o vanilla AIPlayAttacks usa
    ---- esta mesma funcao (`args.aim = aim[i]`), e com aim 0 fora de stance o custo real
    ---- cai em `GetHipfire_StanceAP`, que devolve 0. A conta fecha dos dois lados.
    -----------------------------------------------------------------------------------
    if has_stance_ap and stance_cost > 0 and target_dist and (RATOAI_HipfireMaxDist or 0) > 0 and
        target_dist <= RATOAI_HipfireMaxDist * const.SlabSizeX then
        local n_prep = RATOAI_ShotsOf(Min(context.max_attacks, Max(0, ap - stance_cost) / cost))
        local n_hip = RATOAI_ShotsOf(Min(context.max_attacks, ap / cost))
        if n_hip > n_prep then
            has_stance_ap = false
        end
    end

    if not has_stance_ap then ------- Verify if has AP to enter Stance
        stance_cost = 0
        ---RATOAI_TryDegradeToSingleShot(context)
    else ---- and modify min aim level if it has
        min_aim = min_aim + 1
    end
    -------

    local desired_aim_level = GetIdealAimLevels(context, target_dist, max_aim, min_aim)
    ---- PERF (C11.2): removido `local aims = {}` morto aqui -- era redeclarado
    ---- nos dois caminhos de retorno abaixo, entao esta tabela era pura alocacao

    local to_reach_desired_aim_level = desired_aim_level - min_aim

    if not has_stance_ap or to_reach_desired_aim_level <= 0 then
        ---- BUGFIX (B14): era `ap / cost`, o AP CRU. Este ramo nao descontava o
        ---- `stance_cost` que a unidade vai pagar para entrar em shooting stance -- o
        ---- caminho normal desconta (`first_atk_cost = stance_cost + rotation_cost +
        ---- cost`), so este nao.
        ----
        ---- Quando mordia: perto, `GetIdealAimLevels` devolve o proprio `min_aim` (o
        ---- nivel 1 ja veio junto com a stance), entao `to_reach` da 0 e cai aqui. A
        ---- estimativa saia com a contagem de disparos de quem NAO preparou e a CTH de
        ---- quem preparou -- os dois melhores lados, inflando justamente os destinos de
        ---- aproximacao colada.
        ----
        ---- Medido em jogo, um turno, 5 unidades: 29 ocorrencias, 33 disparos inflados,
        ---- pior caso 2. Concentrado em 1-9 tiles e AP baixo no destino, com severidade
        ---- proporcional ao custo de stance da arma (2 a 4 AP na amostra).
        ----
        ---- `Max(0, ...)`: sem AP para o primeiro disparo depois de preparar, o certo e
        ---- zero disparos, nao um numero negativo virando teto no `Min`.
        ----
        ---- Nota: quando nao ha AP para a stance, `stance_cost` ja e 0 mais acima e esta
        ---- linha nao muda nada -- o caso do hipfire por falta de AP continua correto.
        local num_atks = Min(context.max_attacks, Max(0, ap - stance_cost) / cost)
        local aims = {}
        for i = 1, num_atks do
            aims[i] = min_aim
        end
        if debug then
            RATOAI_AimDebugLine(context, unit, ap, target_dist, cost, stance_cost, rotation_cost,
                                bolting_cost, min_aim, desired_aim_level, has_stance, has_stance_ap,
                                num_atks, aims)
        end
        return num_atks, aims
    end

    local remaining_ap = ap

    -- Calculate the cost of the first attack
    local first_atk_cost = stance_cost + rotation_cost + cost
    local remaining_ap_after_first_atk = remaining_ap - first_atk_cost

    -- Determine the first attack aim level
    local aim = min_aim
    if to_reach_desired_aim_level > 0 then
        while remaining_ap_after_first_atk >= aim_cost and aim < desired_aim_level do
            aim = aim + 1
            remaining_ap_after_first_atk = remaining_ap_after_first_atk - aim_cost
        end
    end

    -- Record the first aim level
    local aims = {aim}
    remaining_ap = remaining_ap_after_first_atk

    -- Process subsequent attacks
    local index = 2

    while remaining_ap > 0 do
        local current_aim = min_aim
        local atk_cost = cost

        ---- BUGFIX (B18): antes isto era `local max_attacks_reached = index > max_attacks`
        ---- testado LA EMBAIXO, no `if` do disparo. Quando o teto era atingido, o laco de
        ---- mira abaixo ainda comprava um nivel, gravava em `current_aim`, e entao o `if`
        ---- falhava e dava break -- descartando `current_aim`. Ou seja: queimava AP e nao
        ---- produzia nada. Sair aqui e equivalente na saida e nao gasta o AP a toa.
        ----
        ---- O `or max_attacks_reached` que existia na condicao do laco de mira parecia
        ---- querer dizer "sem mais disparos, despeje o AP que sobrou em mira". Nunca fez
        ---- isso: o nivel ia para uma variavel local que morria no break. Continua NAO
        ---- implementado -- ver 7.0b em AIM_AND_STANCE.md.
        if index > context.max_attacks then
            break
        end

        ---- BUGFIX (B18): a condicao era `remaining_ap >= aim_cost`, ou seja comprava
        ---- mira ate `desired_aim_level` e SO ENTAO perguntava se o disparo ainda cabia.
        ---- Se nao coubesse, dava break sem nunca recuar um nivel -- e o disparo se
        ---- perdia inteiro.
        ----
        ---- Exemplo com remaining_ap 3, aim_cost 1, cost 2, desired 3: comprava mira
        ---- 1, 2, 3 (sobrando 0), o `3 >= 2` falhava e devolvia ZERO disparos. O otimo
        ---- era mira 1 + disparo = 3 AP, um disparo.
        ----
        ---- Agora o nivel so e comprado se o disparo continuar cabendo depois dele.
        while remaining_ap - aim_cost >= atk_cost and current_aim < desired_aim_level do
            current_aim = current_aim + 1
            remaining_ap = remaining_ap - aim_cost
        end

        if remaining_ap >= atk_cost then
            aims[index] = current_aim
            index = index + 1
            remaining_ap = remaining_ap - atk_cost
        else
            break
        end
    end

    local num_attacks = #aims

    if debug then
        RATOAI_AimDebugLine(context, unit, ap, target_dist, cost, stance_cost, rotation_cost,
                            bolting_cost, min_aim, desired_aim_level, has_stance, has_stance_ap,
                            num_attacks, aims)
    end

    -- ic(#aims, aims)
    return num_attacks, aims
end
