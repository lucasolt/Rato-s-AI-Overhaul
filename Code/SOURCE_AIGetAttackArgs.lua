---------------------------------------------------------------------------------------------------
---- BUGFIX (B30): a acao de assinatura sumia quando o destino escolhido so trocava de POSTURA.
----
---- `GetPackedPosAndStance` empacota posicao E postura numa chave so. O vanilla usa essa chave
---- para achar o alvo (CombatAI.lua:1955), mas o `ai_destination` costuma vir com a postura
---- PREFERIDA do arquetipo, que a unidade ainda nao adotou quando o PrecalcAction roda.
----
---- Medido no processo vivo (LegionScout:2021, arquetipo Skirmisher, PrefStance = Crouch):
----     cur  = 160200,163800,7700 / Standing   -> dest_target[cur]  = nil
----     dest = 160200,163800,7700 / Crouch     -> dest_target[dest] = <alvo>
---- MESMO TILE. A unidade decidiu ficar onde estava e agachar. `args.target` saia nil, e o
---- `AIActionSingleTargetShot:IsAvailable` (AIActions.lua:753) reprovava no `IsValidTarget` --
---- silenciosamente, sem log. Toda signature action de tiro morria nesse caso, e ele nao e
---- raro: qualquer arquetipo com PrefStance diferente da postura atual cai nele.
----
---- QUE ISTO E VANILLA, E QUE O PROPRIO VANILLA SABE. Tres linhas abaixo, o bloco de AP
---- desempacota as duas chaves e compara SO O PONTO, ignorando a postura de proposito -- ele ja
---- trata "mesma posicao, postura diferente" como "a unidade nao se moveu". A linha do alvo
---- simplesmente nao recebeu o mesmo cuidado.
----
---- FORMA DO CONSERTO: fallback, nao substituicao. `upos` continua sendo a chave primaria, e o
---- `ai_destination` so e consultado quando a primaria nao tem alvo. Assim nenhum caso que hoje
---- funciona muda de resposta -- so os que devolviam nil passam a devolver o alvo que o resto
---- do fluxo (AIPlayAttacks, dest_cth, dest_hit_score) ja usava para aquele mesmo destino.
----
---- NAO CONSERTADO, fica registrado: no mesmo cenario o `unit_ap` abaixo cai em
---- `GetUIActionPoints()` (15400 na medicao) em vez de `dest_ap[ai_destination]` (14400), porque
---- as POSICOES batem -- ou seja, o orcamento ignora o AP de agachar. E otimista por um passo de
---- postura. Mexer nisso muda quanto AP a IA acha que tem, que e mudanca de comportamento de
---- outra magnitude; fica para uma conversa propria.
---------------------------------------------------------------------------------------------------
function AIGetAttackArgs(context, action, target_spot_group, aim_type, override_target)
    local upos = GetPackedPosAndStance(context.unit)
    local target = override_target or context.dest_target[upos]

    if not target and context.ai_destination then
        target = context.dest_target[context.ai_destination]
    end
    local args = {target = target, target_spot_group = target_spot_group or "Torso"}

    local dest_ap
    ----
    local dest_pos
    ---
    if context.ai_destination then
        local u_x, u_y, u_z = stance_pos_unpack(upos)
        local dest_x, dest_y, dest_z = stance_pos_unpack(context.ai_destination)

        if point(u_x, u_y, u_z) ~= point(dest_x, dest_y, dest_z) then
            dest_ap = context.dest_ap[context.ai_destination]
        end
        ---
        dest_pos = point(dest_x, dest_y, dest_z)
        ---
    end

    local unit_ap = dest_ap or context.unit:GetUIActionPoints()
    ----
    local unit_pos = dest_pos or context.unit:GetPos()

    ------------------
    if unit_pos and target then
        local dist = unit_pos:Dist(target)
        if dist <= const.Weapons.PointBlankRange * const.SlabSizeX then
            aim_type = aim_type ~= "None" and "Remaining AP" or aim_type
        end
    end
    local min_aim, max_aim = context.unit:GetBaseAimLevelRange(action, false)

    ------------------

    if action.id == "Overwatch" then
        local attacks, aim = context.unit:GetOverwatchAttacksAndAim(action, args, unit_ap)
        args.num_attacks = attacks
        args.aim_ap = aim
        ----
    elseif action.id == "PinDown" then
        args.aim = max_aim
        -----
    elseif aim_type ~= "None" then
        -- args.aim = context.weapon.MaxAimActions
        ---------
        --------TODO: Check if Shooting Stance is correctly being considered

        args.aim = max_aim
        --------
        -- if aim_type == "Remaining AP" then
        -- while args.aim > 0 and not context.unit:HasAP(action:GetAPCost(context.unit, args)) do
        -----
        if aim_type == "Remaining AP" then
            ----
            while args.aim > min_aim and
                ---
                not context.unit:HasAP(action:GetAPCost(context.unit, args)) do
                args.aim = args.aim - 1
            end
        end
    end

    local cost = action:GetAPCost(context.unit, args)
    local has_ap = cost >= 0 and (unit_ap >= cost)

    return args, has_ap, target
end
