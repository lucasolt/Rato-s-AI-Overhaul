---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata (o CONSTANTS_AI_source ja a cria, mas nao dependemos disso).
const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- Override de AIPrecalcConeTargetZones (source: CombatAI.lua:2040-2145).
----
---- BUGFIX (B26): o parametro `stance` existe na assinatura do vanilla e NUNCA e usado no
---- corpo. Quem passa esse parametro e exatamente um chamador -- o MGSetup:
----
----     -- AIActions.lua:807-809
----     action_state.stance = "Prone" -- MGSetup will change the stance so we need to check
----                                   -- LOS in that stance
----     AIActionBaseConeAttack.PrecalcAction(self, context, action_state)
----
---- ...que repassa para AIPrecalcConeTargetZones(context, action_id, nil, action_state.stance).
---- La dentro, as tres medicoes que decidem quem esta no cone usam a postura ATUAL:
----
----     CheckLOS(units, unit, unit:GetDist(target_pos), nil, cone_angle, angle)   -- nil = stance
----     CheckLOS(targets, unit, max_distance)
----     GetLoFData(unit, targets, { ..., stance = unit.stance, ... })
----
---- Ou seja: a IA decide montar a MG com a linha que ela tem EM PE, deita (MGSetup deita por
---- definicao -- "immobilizing yourself and going prone", CombatAction.MGSetup.Description) e
---- perde a linha. O comentario do source promete o contrario do que o codigo faz.
----
---- POR QUE ISSO SOBREVIVEU AO B25. O B25 empacota os DESTINOS do arquetipo Prone deitados,
---- entao o g_AIDestEnemyLOSCache do artilheiro passou a ser medido deitado -- isso conserta a
---- ESCOLHA DO TILE. Mas a decisao de montar a arma nao passa pelo cache: ela vem do
---- PrecalcAction, e ele mede na hora, na postura do momento. Dois momentos em que a postura
---- do momento NAO e Prone:
----   1. Get_HeavyGunnerShouldUsePositioningBehavior (FUNCTION_*) chama o PrecalcAction na fase
----      de SELECAO DE BEHAVIOR, antes de qualquer movimento, com a unidade em pe. Se a resposta
----      for "da pra montar daqui" (medida em pe), o behavior de reposicionamento nem entra --
----      o artilheiro fica onde esta e monta.
----   2. Qualquer destino que nao virou Prone no B25 (o gate `ap >= cost` da mudanca de postura).
----
---- O CONSERTO E A REGRA DO JOGADOR. A UI do jogador ja faz exatamente isto ao previsualizar o
---- cone do MGSetup (IModeCombatAreaAim.lua:349):
----     local stance = action.id == "MGSetup" and "Prone" or attacker.stance
----     GetAOETiles(attacker_pos, stance, ...) --> CheckLOS(step_positions, step_pos, -1, stance, ...)
---- O jogador ve o cone deitado antes de confirmar; a IA nao via. Aqui a IA passa a usar a
---- mesma medicao.
----
---- FORMA DA CHAMADA -- MEDIDA NO PROCESSO VIVO (sonda DAP, combate real, turno 1, 5 alvos):
----
----   session_id            stance  | pt-stand pt-prone | obj-nil obj-prone
----   LegionButcher:2038    Standing |    5        0     |    5        0
----   LegionButcher:2043    Standing |    4        1     |    4        1
----   LegionGrenadier:408   Standing |    5        4     |    5        4
----   LegionHyena:2037      ""       |    2        0     |    0        0
----
---- Duas coisas ficam provadas. (1) O 4o parametro do CheckLOS FUNCIONA: deitado a linha some
---- na maioria dos casos -- 5 -> 0 no pior deles. E exatamente a magnitude do sintoma relatado.
---- (2) A engine honra a stance pedida MESMO com o objeto `unit` como origem (as colunas obj-*
---- batem com as pt-* em todo humano), entao nao e preciso trocar a origem por um ponto: basta
---- deixar de passar `nil`. A unica linha que diverge e a do cachorro, que nao tem stance --
---- mais um motivo para nao mexer na origem, ja que a forma-objeto e a que o vanilla usa.
----
---- O GetLoFData tambem honra `stance` sozinho, sem step_pos -- medido no mesmo combate
---- (LegionScout:2033: 5 alvos com LOF em pe, 3 deitado). Passar step_pos junto MUDA o
---- resultado (4 em vez de 3: o voxel empacotado nao e exatamente a posicao visual da unidade),
---- entao ele fica de fora: o objetivo aqui e mudar a altura do olho, nao a origem.
----
---- SEM STANCE SOBRESCRITA, NADA MUDA. Overwatch, DanceForMe e EyesOnTheBack chamam esta funcao
---- com stance = nil, e o MGRotate (ja montado) chama com a unidade ja deitada. Nos dois casos
---- `override` e nil e as tres chamadas sao identicas as do vanilla.
----
---- NAO CONSERTA (fica registrado): unit:CalcChanceToHit no fim da funcao continua medindo o CTH
---- na postura real -- ele nao aceita stance hipotetica por argumento (Unit.lua:6947, nenhuma
---- mencao a stance no corpo; os modificadores leem attacker.stance/target.stance direto dos
---- objetos). O gate que importa para o sintoma e a LINHA (os dois CheckLOS + o LOF), nao o
---- numero do CTH. Enquanto houver linha deitado, o CTH medido em pe erra por poucos pontos;
---- quando NAO ha linha deitado, o LOF ja derruba o alvo antes do CTH.
----
---------------------------------------------------------------------------------------------------
---- BUGFIX (B35): DE ONDE O CONE E AVALIADO.
----
---- O vanilla fixa a origem na posicao ATUAL da unidade, e diz por que:
----     local attack_pos = unit:GetPos() -- make sure we're using the current position
----                                      -- in case the unit has moved
---- Isso esta certo para quem chama DEPOIS do movimento -- o AIPlayAttacks (CombatAI.lua:216-232)
---- roda o PrecalcAction das signature actions ja no destino, e ali as duas posicoes coincidem.
----
---- Mas quem pergunta ANTES do movimento recebia uma resposta sobre um lugar onde a unidade nao
---- vai estar. Sintoma medido: o painel de IA mostrava MGSetup "indisponivel -- sem alvo", e no
---- turno real a unidade caminhava e montava a MG normalmente. Nenhum dos dois mentia; eles
---- mediam de lugares diferentes.
----
---- PIOR QUE ISSO: a funcao ja estava MISTURANDO as duas origens. O nosso
---- AICalcAOETargetPoints filtra os pontos candidatos pela distancia ate o DESTINO
---- (SOURCE_AICalcAOETargetPoints.lua), enquanto attack_pos, os dois CheckLOS, o GetLoFData e o
---- CalcChanceToHit mediam da ORIGEM. Antes de andar, portanto, ela mantinha um ponto por estar
---- no alcance do destino e depois o matava por falta de linha da origem -- o pior dos dois
---- mundos, e era o unico numero que aparecia na tela.
----
---- O CONSERTO: `attack_pos_override`. Quem sabe que a unidade ainda vai andar passa a posicao
---- de onde o cone realmente vai ser plantado, e AS SEIS MEDICOES passam a sair de la.
----
---- QUEM PASSA, E QUEM NAO PASSA. So o AIActionBaseConeAttack:PrecalcAction sobrescrito no fim
---- deste arquivo -- que e o caminho do MGSetup (ramo "montar") e do Overwatch como signature
---- action. Os outros dois chamadores continuam recebendo `nil` e rodando byte a byte o vanilla,
---- de proposito:
----   * AIActionMGSetup:PrecalcAction, ramo JA MONTADA (AIActions.lua:810-841) -- a unidade esta
----     presa na arma, nao vai a lugar nenhum; a posicao atual E a posicao de tiro.
----   * UnitAwareness.lua:1090 (ataque de abertura ao ficar consciente) -- ali a unidade atira de
----     onde esta, e o `ai_destination` do context pode ser de outro momento do turno. Adivinhar
----     ali seria trocar um erro conhecido por um silencioso.
----
---- SEM OVERRIDE, NADA MUDA. `attack_pos_override` nil devolve exatamente o comportamento de
---- antes, incluindo a forma-objeto do CheckLOS e a ausencia de step_pos -- que e o que o B26
---- mediu. `const.RATOAI.ConeFromDest = false` no console desliga sem recarregar mod.
---------------------------------------------------------------------------------------------------

function AIPrecalcConeTargetZones(context, action_id, additional_target_pt, stance,
                                  attack_pos_override)
    if context.target_locked then
        return {}
    end

    local unit = context.unit
    local weapon = context.weapon
    local params = weapon:GetAreaAttackParams(action_id, unit)

    local min_range = params.min_range * const.SlabSizeX
    local max_range = params.max_range * const.SlabSizeX

    ---------------------------------------------------------------------------------------------
    ---- COMPRIMENTO DO CONE DA MG (RATOAI_MGConeRange, CONSTANTS_AI_source.lua)
    ----
    ---- So para MGSetup / MGRotate: Overwatch, DanceForMe e EyesOnTheBack passam por aqui e
    ---- ficam byte a byte iguais ao vanilla.
    ----
    ---- `max_range` manda em tres coisas de uma vez, e e por isso que basta trocar aqui:
    ----   1. AICalcAOETargetPoints -- quais inimigos viram direcao candidata;
    ----   2. `target_pos = attack_pos + SetLen(dir, max_range)` -- o COMPRIMENTO do cone que vai
    ----      ser plantado, que e o que decide quem dispara interrupcao;
    ----   3. `CheckLOS(units, unit, unit:GetDist(target_pos), ...)` -- a distancia de LOS do cone.
    ----
    ---- Com os defaults (pct = 100, tiles = 0) o unico efeito e o teto de
    ---- `Min(sight, GetMaxRange())` e a guarda `min >= max` do vanilla -- nenhum encurtamento.
    ---------------------------------------------------------------------------------------------
    if action_id == "MGSetup" or action_id == "MGRotate" then
        min_range, max_range = RATOAI_MGConeRange(unit, weapon, params)
    end

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B35): a origem hipotetica. `nil` = a posicao atual (vanilla).
    ---- Calculada AQUI, antes do AICalcAOETargetPoints, porque o filtro de alcance dele tem de
    ---- usar a mesma origem que as medicoes de linha la embaixo.
    ---------------------------------------------------------------------------------------------
    local hypo = (const.RATOAI.ConeFromDest ~= false) and attack_pos_override or nil

    local target_pts = AICalcAOETargetPoints(context, min_range, max_range, nil, hypo)
    if additional_target_pt then
        target_pts[#target_pts + 1] = additional_target_pt
    end

    -- calc cone areas for each remaining target point
    local zones = {}
    local cone_angle = params.cone_angle
    local targets = {}
    ---- BUGFIX (B35): com override, o apice do cone e o destino. Sem, e o vanilla.
    local attack_pos = hypo or unit:GetPos()
    local units = table.copy(context.enemies)
    table.iappend(units, GetAllAlliedUnits(unit))
    local unit_sight = unit:GetSightRadius()

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B26): a postura em que as linhas sao medidas. `nil` = a atual (vanilla).
    ---------------------------------------------------------------------------------------------
    ---- Interruptor mestre (CONSTANTS_AI_source.lua) + o proprio. Qualquer um em false e a
    ---- funcao volta a ser byte a byte o vanilla.
    local override = (stance and stance ~= unit.stance) and stance or nil
    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B35): a forma-PONTO do CheckLOS nao tem objeto de onde ler postura, entao com
    ---- origem hipotetica a postura passa a ser SEMPRE explicita. E a mesma forma que o proprio
    ---- jogo usa para prever cone de posicao hipotetica (UnitOverwatch.lua:270,
    ---- UnitActions.lua:2710). Sem `hypo`, os dois valores sao os de antes.
    local los_src = hypo or unit
    local los_stance = hypo and (stance or unit.stance) or override
    ---------------------------------------------------------------------------------------------

    for zi, pt in ipairs(target_pts) do
        local dir = pt - attack_pos
        if dir:Len() > 0 then
            local target_pos = (attack_pos + SetLen(dir, max_range)):SetTerrainZ()
            local zone = {target_pos = target_pos, units = {}}
            zones[#zones + 1] = zone

            local angle = CalcOrientation(attack_pos, pt)
            ---- BUGFIX (B35): `unit:GetDist` mede da posicao atual; com origem hipotetica a
            ---- distancia tem de sair do apice do cone, senao o alcance de LOS nao e o do cone.
            local cone_dist = hypo and attack_pos:Dist(target_pos) or unit:GetDist(target_pos)
            local los_any, los_targets = CheckLOS(units, los_src, cone_dist, los_stance,
                                                  cone_angle, angle)
            if los_any then
                for i, target_unit in ipairs(units) do
                    if los_targets[i] and IsValidTarget(target_unit) then
                        zone.units[#zone.units + 1] = target_unit
                        table.insert_unique(targets, target_unit)
                    end
                end
            end
        end
    end

    local check_ally
    if action_id == "Overwatch" then
        local atk_action = context.default_attack
        local aim_type = atk_action.AimType
        local is_aoe = aim_type == "cone" or aim_type == "aoe" or aim_type == "parabola aoe" or
                           aim_type == "line aoe"
        check_ally = not is_aoe
    end

    -- filter LOS targets
    ---- O `max_range` ja carrega o teto de `Min(sight, GetMaxRange())` e o encurtamento do cone
    ---- quando a acao e da MG; sem isso um alvo alem do comprimento do cone passaria neste
    ---- segundo filtro, que e mais largo que o primeiro.
    local max_distance = Min(Min(unit_sight, weapon:GetMaxRange()), max_range)
    local los_any, los_targets = CheckLOS(targets, los_src, max_distance, los_stance)
    if not los_any then
        for _, zone in ipairs(zones) do
            table.iclear(zone.units)
        end
        return zones
    end
    for i = #targets, 1, -1 do
        if not los_any or not los_targets[i] then
            for _, zone in ipairs(zones) do
                table.remove_value(zone.units, targets[i])
            end
            table.remove(targets, i)
        end
    end
    -- check chance to hit
    local targets_attack_data = GetLoFData(unit, targets, {
        obj = unit,
        action_id = context.default_attack.id,
        weapon = weapon,
        stance = los_stance or unit.stance, ---- BUGFIX (B26): sem sobrescrita = unit.stance (vanilla)
        step_pos = hypo, ---- BUGFIX (B35): nil sem override = vanilla
        range = max_distance,
        target_spot_group = "Torso",
        prediction = true
    })
    local action = CombatActions[action_id]
    ---- BUGFIX (B35): `step_pos` e lido pelo CalcChanceToHit como attacker_pos (Unit.lua:6991) e
    ---- repassado a todo modificador. nil sem override = vanilla.
    local args = {target_spot_group = false, step_pos = hypo}
    for i, attack_data in ipairs(targets_attack_data) do
        local target = targets[i]
        local chance_to_hit = 0
        if attack_data and not attack_data.stuck then
            for j, hit_info in ipairs(attack_data.lof) do
                if not check_ally or hit_info.ally_hits_count == 0 then
                    args.target_spot_group = hit_info.target_spot_group
                    chance_to_hit = unit:CalcChanceToHit(target, action, args, "chance_only")
                    if chance_to_hit > 0 then
                        break
                    end
                end
            end
        end
        if chance_to_hit == 0 then
            for _, zone in ipairs(zones) do
                table.remove_value(zone.units, target)
            end
        end
    end
    return zones
end

---------------------------------------------------------------------------------------------------
---- BUGFIX (B35): a posicao de onde o cone vai ser plantado.
----
---- Devolve nil quando nao ha nada a corrigir -- sem destino escolhido (fase de selecao de
---- behavior, onde `ai_destination` ainda nem existe) ou destino igual ao voxel onde a unidade ja
---- esta (o caso do AIPlayAttacks, depois de andar). Nesses casos o chamador passa nil e a
---- avaliacao roda byte a byte como o vanilla.
----
---- A COMPARACAO E POR VOXEL EMPACOTADO, nao por posicao visual. `unit:GetPos()` nao bate com o
---- `stance_pos_unpack` do destino nem quando a unidade esta parada em cima dele -- o proprio
---- B26 mediu isso ("o voxel empacotado nao e exatamente a posicao visual da unidade"). Comparar
---- pontos visuais daria "vai se mexer" quase sempre, e o conserto passaria a agir onde nao
---- devia. E o mesmo idioma do SOURCE_AIGetAttackArgs.lua:45-51.
----
---- Segundo retorno: a POSTURA do destino. O destino carrega postura empacotada junto, e a
---- unidade vai chegar la nela. Quem tem postura propria a impor -- o MGSetup, que deita por
---- definicao -- passa a dele e ignora esta.
---------------------------------------------------------------------------------------------------
function RATOAI_ConeEvalPos(context)
    ---- O movimento ja acabou (ou falhou, e ela ficou pelo caminho): onde ela esta E de onde ela
    ---- vai atirar. Este guard e o que separa "ainda vai andar" de "ja andou" sem depender do
    ---- movimento ter dado certo -- a comparacao de voxel abaixo sozinha diria "vai se mexer"
    ---- para uma unidade que tentou chegar ao destino e nao conseguiu.
    if context.AIisPlayingAttacks then
        return
    end
    local dest = context.ai_destination
    if not dest then
        return
    end
    local upos = GetPackedPosAndStance(context.unit)
    if not upos then
        return
    end
    local ux, uy, uz = stance_pos_unpack(upos)
    local dx, dy, dz, dstance_idx = stance_pos_unpack(dest)
    if ux == dx and uy == dy and uz == dz then
        return ---- ja esta la
    end
    return RATOAI_ValidatePosZ(point(dx, dy, dz)), StancesList[dstance_idx]
end

---------------------------------------------------------------------------------------------------
---- BUGFIX (B35): unico chamador que passa a origem hipotetica.
----
---- Copia fiel de AIActionBaseConeAttack:PrecalcAction (AIActions.lua:187-207); a unica diferenca
---- sao as tres linhas marcadas. Sobrescrever a BASE basta: o AIActionMGSetup:PrecalcAction chama
---- `AIActionBaseConeAttack.PrecalcAction(self, ...)` por indexacao, entao pega esta versao.
----
---- `action_state.stance` tem precedencia sobre a postura do destino: quem a define e o MGSetup,
---- que deita ao montar independentemente da postura em que o destino foi empacotado.
---------------------------------------------------------------------------------------------------
function AIActionBaseConeAttack:PrecalcAction(context, action_state)
    if not IsKindOf(context.weapon, "Firearm") then
        return
    end

    local caction = CombatActions[self.action_id]
    if not caction or caction:GetUIState({context.unit}) ~= "enabled" then
        return
    end

    local args, has_ap = AIGetAttackArgs(context, caction, nil, "None")
    action_state.has_ap = has_ap
    if not has_ap then
        return
    end

    ---- BUGFIX (B35): as tres linhas ----------------------------------------------------------
    local eval_pos, eval_stance = RATOAI_ConeEvalPos(context)
    local zones = AIPrecalcConeTargetZones(context, self.action_id, nil,
                                           action_state.stance or eval_stance, eval_pos)
    --------------------------------------------------------------------------------------------

    local zone, best_score = self:EvalZones(context, zones)
    action_state.score = best_score
    args.target_pos = zone and zone.target_pos
    args.target = zone and zone.target_pos
    action_state.args = args

    g_LastSelectedZone = zone
end
