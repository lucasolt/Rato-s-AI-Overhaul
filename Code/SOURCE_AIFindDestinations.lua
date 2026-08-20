---------------------------------------------------------------------------------------------------
---- Override de AIFindDestinations (source: CombatAI.lua:645-717).
----
---- POR QUE ESTE ARQUIVO EXISTE
---- A copia que existia em AIPOLICYPOS_AvoidThreatenedAreas.lua esta INTEIRA dentro de um
---- bloco `--[[ ... ]]` (linha 18 abre, 217 fecha) -- o arquivo nao define nada e nunca
---- definiu. O WEIGHTS_AUDIT.md ja registrava isso na secao B8. Ou seja: quem roda hoje e o
---- AIFindDestinations do vanilla, sem nenhuma alteracao do mod.
----
---- Este arquivo repoe a funcao com UMA mudanca isolada (RATOAI_CrouchTrigger abaixo).
---- O AIFindOptimalLocation, que tambem esta comentado la, NAO foi reposto -- ele parecia
---- identico ao vanilla, mas isso nao foi diffado linha a linha.
----
---- >>> ESTE ARQUIVO SO FAZ ALGUMA COISA SE ESTIVER REGISTRADO NO EDITOR DE MODS. <<<
---- A lista `code` do metadata.lua (espelhada no items.lua) define o que carrega. Sem
---- registrar, ele e codigo morto exatamente como o arquivo que ele substitui.
---------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------
---- QUANDO O DESTINO VIRA "AGACHADO"
----
---- A postura empacotada no dest e a que a unidade adota ao chegar: AIBehavior:EndMovement
---- (AIBehaviors.lua:199-210) faz unit:DoChangeStance(StancesList[stance_idx]). Isso roda na
---- FASE DE MOVIMENTO (CombatCamera.lua:1238), antes da fase de ataques -- ou seja, agachar
---- pelo dest ja acontece ANTES do primeiro tiro.
----
----   "low"       -- vanilla: so cobertura BAIXA. Atras de cobertura alta fica em pe (e
----                  mecanicamente correto: em pe atras de muro alto a cobertura ja e total
----                  e a linha de tiro fica melhor).
----   "any_cover" -- cobertura baixa OU alta. [ATUAL]
----   "always"    -- todo destino vira agachado, com ou sem cobertura. Vale -5 no CTH
----                  inimigo mesmo a ceu aberto (RangeAttackTargetStanceCover/CrouchPenalty),
----                  mas cobra 1 AP em TODO destino e avalia toda LOF agachada.
----
---- CUSTO: o gate `ap >= cost` e o `dest_ap[new_dest] = ap - cost` do vanilla foram MANTIDOS
---- de proposito. A IA reserva o AP da mudanca de postura no planejamento, entao o destino
---- agachado concorre com 1 AP a menos para atacar. Nao e de graca.
---- (Ressalva honesta: na EXECUCAO o DoChangeStance de EndMovement nao debita AP de fato --
----  a reserva existe so no orcamento do planejamento. Fechar essa folga exige sobrescrever
----  AIBehavior:EndMovement; ver o relatorio CROUCH_REPORT.md.)
---------------------------------------------------------------------------------------------------
RATOAI_CrouchTrigger = rawget(_G, "RATOAI_CrouchTrigger") or "any_cover"

local function RATOAI_WantsCrouch(cover_low, cover_high)
    local mode = RATOAI_CrouchTrigger
    if mode == "always" then
        return true
    end
    if mode == "any_cover" then
        return cover_low or cover_high
    end
    return cover_low
end

function AIFindDestinations(unit, context)
    local pos = GetPassSlab(unit) or unit:GetPos()
    local destinations, paths, dest_ap, dest_path, voxel_to_dest, closest_free_pos =
        AIBuildArchetypePaths(unit, pos, context)
    if not closest_free_pos then
        if unit.ActionPoints == 0 then
            assert(not "AI try to act with 0 action points!!!")
        else
            print("AI can't find unit free destination prints!!!")
            printf("      AP = %d", unit.ActionPoints)
            printf("      Command = %s", unit.command)
            printf("      Status effects: %s", table.concat(table.keys(unit.StatusEffects), ", "))
            printf("      Pos: %s", tostring(unit:GetPos()))
            printf("      Pass slab pos: %s", tostring(GetPassSlab(unit) or ""))
            printf("      Target dummy pos %s",
                   unit.target_dummy and tostring(unit.target_dummy:GetPos()) or "")
            local o = GetOccupiedBy(unit:GetPos(), unit)
            if o then
                printf("Other pos %s", tostring(o:GetPos()))
                printf("Other target dummy pos %s",
                       o.target_dummy and tostring(o.target_dummy:GetPos()) or "")
                printf("Other efResting=%d", o:GetEnumFlags(const.efResting))
                if o.reposition_dest then
                    printf("Other reposition dest=%s",
                           tostring(point(stance_pos_unpack(o.reposition_dest))))
                end
            end
            assert(not "AI can't find unit free destination")
        end
    end

    local crouch_idx = StancesList.Crouch
    local important_dests = context.important_dests or {}
    context.important_dests = important_dests
    local change_stance_costs = {}
    for stance_idx in ipairs(StancesList) do
        change_stance_costs[stance_idx] = GetStanceToStanceAP(StancesList[stance_idx], "Crouch")
    end

    -- preprocess destinations to find those where we need to change stance at the dest to take cover
    local low = const.CoverLow
    local high = const.CoverHigh
    for i, dest in ipairs(destinations) do
        local x, y, z, stance_idx = stance_pos_unpack(dest)
        if stance_idx ~= crouch_idx then
            local cost = change_stance_costs[stance_idx]
            local ap = dest_ap[dest]
            if cost and ap and ap >= cost then
                ---- GetCover devolve as 4 direcoes ou nenhuma; `if up` e um teste de "existe
                ---- dado de cobertura neste voxel", nao de direcao. Mesmo idioma em
                ---- GetCoversAt / GetCoverTypes / GetUnitOrientationToHighCover (Cover.lua).
                local up, right, down, left = GetCover(x, y, z)
                local cover_low, cover_high
                if up then
                    cover_low = up == low or right == low or down == low or left == low
                    cover_high = up == high or right == high or down == high or left == high
                end
                if RATOAI_WantsCrouch(cover_low, cover_high) then
                    table.remove_value(important_dests, dest)
                    local new_dest = stance_pos_pack(x, y, z, crouch_idx)
                    destinations[i] = new_dest
                    voxel_to_dest[point_pack(x, y, z)] = new_dest
                    dest_ap[new_dest] = ap - cost
                    dest_path[new_dest] = dest_path[dest]
                    table.insert_unique(important_dests, new_dest)
                end
            end
        end
    end

    context.destinations = destinations -- available destinations
    context.dest_ap = dest_ap -- dest -> available ap
    context.combat_paths = paths
    context.dest_combat_path = dest_path -- dest -> index in context.combat_paths (to reach this dest)
    context.voxel_to_dest = voxel_to_dest
    context.closest_free_pos = closest_free_pos

    context.all_destinations = AIEnumValidDests(context)
end
