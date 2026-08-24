---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata (o CONSTANTS_AI_source ja a cria, mas nao dependemos disso).
const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- Override de AIFindDestinations (source: CombatAI.lua:645-717).
----
---- POR QUE ESTE ARQUIVO EXISTE
---- A copia que existia em AIPOLICYPOS_AvoidThreatenedAreas.lua esta INTEIRA dentro de um
---- bloco `--[[ ... ]]` (linha 18 abre, 217 fecha) -- o arquivo nao define nada e nunca
---- definiu. O WEIGHTS_AUDIT.md ja registrava isso na secao B8. Ou seja: quem roda hoje e o
---- AIFindDestinations do vanilla, sem nenhuma alteracao do mod.
----
---- Este arquivo repoe a funcao com UMA mudanca isolada (const.RATOAI.CrouchTrigger abaixo).
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
const.RATOAI.CrouchTrigger = const.RATOAI.CrouchTrigger or "any_cover"

---------------------------------------------------------------------------------------------------
---- Empacotar o destino na PrefStance quando ela e Prone -- ver o bloco BUGFIX (B25) abaixo.
---- Global para dar como desligar no console se aparecer efeito colateral em campo.
---------------------------------------------------------------------------------------------------

local function RATOAI_WantsCrouch(cover_low, cover_high)
    local mode = const.RATOAI.CrouchTrigger
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

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B25): quem prefere PRONE tinha o destino empacotado EM PE.
    ----
    ---- `AIBuildArchetypePaths` (CombatAI.lua:1063-1075) escolhe UMA stance por voxel:
    ----     if pn_ap > mn_ap then  pack(pref_stance)  else  pack(move_stance)
    ---- Ou seja, so empacota a stance preferida quando o voxel e alcancavel NAQUELA
    ---- postura sobrando mais AP. Andar deitado e caro, entao praticamente todo destino
    ---- alem de um ou dois tiles cai no ramo `move_stance`.
    ----
    ---- Para o HeavyGunner (PrefStance=Prone, MoveStance=Standing) isso e grave: o cache
    ---- de LOS e chaveado pelo destino EMPACOTADO (AIUpdateDestLosCache usa
    ---- `srcs[i] = dests[i]`), entao esses tiles tem a linha testada EM PE. Depois o
    ---- MGSetup forca Prone -- o proprio vanilla comenta isso em AIActions.lua:808 -- e a
    ---- linha some. As policies de LOS premiavam exatamente os tiles onde em pe se ve e
    ---- deitado nao.
    ----
    ---- O conserto usa o mesmo padrao do bloco de Crouch logo abaixo: a stance do destino
    ---- e ONDE ELA TERMINA, nao como ela chega. `dest_path` continua sendo a stance de
    ---- movimento, e o custo da mudanca sai do `dest_ap`. Roda antes do
    ---- `AIEnumValidDests`, entao o cache de LOS ja nasce com a postura certa.
    ----
    ---- Excludente com o passe de Crouch de proposito: converter Standing -> Crouch ->
    ---- Prone cobraria a mudanca duas vezes, e ela vai direto de pe para deitada.
    ---------------------------------------------------------------------------------------------
    local prone_idx = StancesList.Prone
    local pref_idx = context.archetype and StancesList[context.archetype.PrefStance] or 0

    local prone_pass = (pref_idx == prone_idx)

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B36): so deita onde deitar significa alguma coisa.
    ----
    ---- O passe acima convertia TODO destino alcancavel, e andar deitado e caro -- o artilheiro
    ---- atravessava o mapa rastejando para chegar a um tile onde nao ha ninguem para atirar.
    ----
    ---- Fora do alcance o destino fica em pe, e isso NAO reabre o B25: o problema la era o cache
    ---- de LOS medir em pe um tile onde a unidade terminaria deitada. Aqui ela realmente termina
    ---- em pe, entao a medicao passa a ser a correta para aquele tile. Quando ela chegar perto o
    ---- bastante, o proximo turno reempacota deitado e o B25 volta a valer onde importa.
    ----
    ---- O custo e um Dist por (destino, inimigo) com saida no primeiro que passar -- aritmetica
    ---- de ponto, sem raycast e sem consulta de grid.
    ---------------------------------------------------------------------------------------------
    local prone_gate
    if prone_pass then
        prone_gate = AIGetWeaponCheckRange(unit, context.weapon, context.default_attack) or 0
        local cap = (const.RATOAI.PronePackTiles or 0) * const.SlabSizeX
        if cap > 0 then
            prone_gate = Min(prone_gate, cap)
        end
    end

    ---- `pairs` e nao `ipairs` porque enemy_pos e chaveado por unidade. A ordem nao importa: o
    ---- retorno e o MINIMO, que independe da ordem de visita -- nao ha acumulacao nem sorteio,
    ---- entao nada disso entra no hash de rede.
    ---- Devolve nil quando nao ha inimigo posicionado; quem chama decide o que isso significa.
    local function dist_inimigo(x, y, z)
        local p = point(x, y, z)
        local best
        for _, epos in pairs(context.enemy_pos or empty_table) do
            if epos then
                local d = p:Dist(epos)
                if not best or d < best then
                    best = d
                end
            end
        end
        return best
    end

    local function perto_de_inimigo(x, y, z)
        if not prone_gate or prone_gate <= 0 then
            return true
        end
        local d = dist_inimigo(x, y, z)
        return (d and d <= prone_gate) and true or false
    end

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B37): tile aberto empacota Prone em vez de em pe.
    ----
    ---- Quem liga e o ARQUETIPO (property ExposedProne, ver PATCH_AppendClass_source_classes) --
    ---- e nao uma constante, porque isto e decisao de desenho de unidade e nao afinacao numerica.
    ---- `const.RATOAI.ExposedProne` sobrou como valvula MESTRA: false derruba para todo mundo
    ---- sem recarregar mod, que e o que serve para A/B no console.
    ----
    ---- Resolvido UMA vez, fora do laco: nem a property nem o raio mudam por destino.
    ---------------------------------------------------------------------------------------------
    local arch = context.archetype
    local exposed_prone = (const.RATOAI.ExposedProne ~= false) and arch and arch.ExposedProne and
                              true or false
    local exposed_min = (arch and arch.ExposedProneMinTiles or 0) * const.SlabSizeX

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B37): a conversao para Prone num lugar so.
    ----
    ---- Ela e alcancavel por DOIS caminhos -- destino empacotado em pe e destino que ja veio
    ---- empacotado agachado (PrefStance = Crouch, tile perto o bastante para o
    ---- AIBuildArchetypePaths ter escolhido a postura preferida). Duplicar o corpo duplicaria
    ---- tambem a contabilidade de dest_ap / dest_path / important_dests, que e onde esse tipo de
    ---- codigo erra.
    ----
    ---- O custo sai SEMPRE da postura empacotada atual para Prone: e o mesmo idioma do B25, e e
    ---- o que a unidade de fato paga -- ela anda na stance de `dest_path` e muda uma vez no fim
    ---- (AIBehavior:EndMovement). Cobrar de pe quem ja chega agachado inventaria AP.
    ---------------------------------------------------------------------------------------------
    local function deitar_no_destino(i, dest, x, y, z, stance_idx, ap)
        local d = dist_inimigo(x, y, z)
        local longe = (exposed_min <= 0) or (d and d >= exposed_min) or false
        local prone_cost = GetStanceToStanceAP(StancesList[stance_idx], "Prone")
        if not (longe and prone_cost and ap and ap >= prone_cost) then
            return
        end
        table.remove_value(important_dests, dest)
        local new_dest = stance_pos_pack(x, y, z, prone_idx)
        destinations[i] = new_dest
        voxel_to_dest[point_pack(x, y, z)] = new_dest
        dest_ap[new_dest] = ap - prone_cost
        dest_path[new_dest] = dest_path[dest]
        table.insert_unique(important_dests, new_dest)
    end

    if prone_pass then
        for i, dest in ipairs(destinations) do
            local x, y, z, stance_idx = stance_pos_unpack(dest)
            ---- stance_idx 0 e o "sem postura" do StancesList; o passe de Crouch se protege
            ---- dele por tabelar os custos com ipairs (que pula o indice 0). Aqui a chamada e
            ---- direta, entao o guarda e explicito.
            if stance_idx ~= prone_idx and stance_idx > 0 and perto_de_inimigo(x, y, z) then
                local cost = GetStanceToStanceAP(StancesList[stance_idx], "Prone")
                local ap = dest_ap[dest]
                if cost and ap and ap >= cost then
                    table.remove_value(important_dests, dest)
                    local new_dest = stance_pos_pack(x, y, z, prone_idx)
                    destinations[i] = new_dest
                    voxel_to_dest[point_pack(x, y, z)] = new_dest
                    dest_ap[new_dest] = ap - cost
                    dest_path[new_dest] = dest_path[dest]
                    table.insert_unique(important_dests, new_dest)
                end
            end
        end
    end

    -- preprocess destinations to find those where we need to change stance at the dest to take cover
    local low = const.CoverLow
    local high = const.CoverHigh
    for i, dest in ipairs(destinations) do
        local x, y, z, stance_idx = stance_pos_unpack(dest)
        if not prone_pass and stance_idx ~= crouch_idx then
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
                elseif exposed_prone and not up and stance_idx ~= prone_idx then
                    ---- BUGFIX (B37): `not up` e o mesmo idioma do bloco acima -- ausencia de
                    ---- dado de cobertura no voxel, ou seja, tile ABERTO. Cobertura alta cai no
                    ---- WantsCrouch ou fica em pe de proposito: ela ja protege sem custar AP.
                    ----
                    ---- `elseif` e nao um segundo passe: assim as duas conversoes sao
                    ---- MUTUAMENTE EXCLUSIVAS por destino, e nenhum tile paga agachar e depois
                    ---- deitar. E a mesma razao do `not prone_pass` que exclui o passe do B25.
                    deitar_no_destino(i, dest, x, y, z, stance_idx, ap)
                end
            end
        elseif not prone_pass and exposed_prone and stance_idx == crouch_idx then
            ---------------------------------------------------------------------------------
            ---- BUGFIX (B37): o destino que JA VEIO agachado.
            ----
            ---- O passe acima o ignora (`stance_idx ~= crouch_idx`) porque nao ha nada a fazer
            ---- quando a resposta ja e Crouch. Mas para o B37 ha: se o tile e ABERTO, agachado
            ---- nao e a resposta -- foi so a postura que o AIBuildArchetypePaths escolheu por
            ---- sobrar AP, num arquetipo com PrefStance = Crouch. Sem este ramo, justamente as
            ---- unidades mais propensas a chegar agachadas nunca deitariam no aberto.
            ---------------------------------------------------------------------------------
            local up = GetCover(x, y, z)
            if not up then
                deitar_no_destino(i, dest, x, y, z, stance_idx, dest_ap[dest])
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
