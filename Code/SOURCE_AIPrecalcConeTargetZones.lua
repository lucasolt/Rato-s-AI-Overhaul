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
---- Desligar em campo: RATOAI_ConeStanceLOS = false, ou RATOAI_LOSFixes = false (mestre,
---- desliga tambem o B25 e os portoes da AIPolicyMGSetupPosScore).
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_ConeStanceLOS") == nil then
    RATOAI_ConeStanceLOS = true
end

function AIPrecalcConeTargetZones(context, action_id, additional_target_pt, stance)
    if context.target_locked then
        return {}
    end

    local unit = context.unit
    local weapon = context.weapon
    local params = weapon:GetAreaAttackParams(action_id, unit)

    local min_range = params.min_range * const.SlabSizeX
    local max_range = params.max_range * const.SlabSizeX

    local target_pts = AICalcAOETargetPoints(context, min_range, max_range)
    if additional_target_pt then
        target_pts[#target_pts + 1] = additional_target_pt
    end

    -- calc cone areas for each remaining target point
    local zones = {}
    local cone_angle = params.cone_angle
    local targets = {}
    local attack_pos = unit:GetPos() -- make sure we're using the current position in case the unit has moved
    local units = table.copy(context.enemies)
    table.iappend(units, GetAllAlliedUnits(unit))
    local unit_sight = unit:GetSightRadius()

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B26): a postura em que as linhas sao medidas. `nil` = a atual (vanilla).
    ---------------------------------------------------------------------------------------------
    ---- Interruptor mestre (CONSTANTS_AI_source.lua) + o proprio. Qualquer um em false e a
    ---- funcao volta a ser byte a byte o vanilla.
    local los_fixes = rawget(_G, "RATOAI_LOSFixes") ~= false
    local override = los_fixes and RATOAI_ConeStanceLOS and stance and stance ~= unit.stance and
                         stance or nil
    ---------------------------------------------------------------------------------------------

    for zi, pt in ipairs(target_pts) do
        local dir = pt - attack_pos
        if dir:Len() > 0 then
            local target_pos = (attack_pos + SetLen(dir, max_range)):SetTerrainZ()
            local zone = {target_pos = target_pos, units = {}}
            zones[#zones + 1] = zone

            local angle = CalcOrientation(attack_pos, pt)
            local los_any, los_targets = CheckLOS(units, unit, unit:GetDist(target_pos),
                                                  override, cone_angle, angle)
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
    local max_distance = Min(unit_sight, weapon:GetMaxRange())
    local los_any, los_targets = CheckLOS(targets, unit, max_distance, override)
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
        stance = override or unit.stance, ---- BUGFIX (B26): sem sobrescrita = unit.stance (vanilla)
        range = max_distance,
        target_spot_group = "Torso",
        prediction = true
    })
    local action = CombatActions[action_id]
    local args = {target_spot_group = false}
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
