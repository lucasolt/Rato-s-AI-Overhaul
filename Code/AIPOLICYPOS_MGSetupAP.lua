---------------------------------------------------------------------------------------------------
---- AIPolicyMGSetupAP -- "da para montar a MG neste tile?"
----
---- Portao binario, usado com `Required = true` no PositioningAI "MG Setup". Required quer dizer
---- que nota 0 DESQUALIFICA o destino, entao cada erro aqui nao dilui: elimina.
----
---- BUGFIX (B29d/e) -- tres coisas estavam medindo o tile errado:
----
----   1. CUSTO NA POSTURA ERRADA. Desde a mudanca no GBO3 (`rat_MGSetup_getap`), o custo do
----      MGSetup inclui a mudanca de postura para Prone, e o `GetAPCost` a mede a partir da
----      postura ATUAL da unidade. O que vale aqui e a postura EMPACOTADA no dest -- e onde ela
----      vai estar quando montar. Sem a troca, o destino que o passe B25 do AIFindDestinations
----      ja empacotou Prone (e do qual ja descontou a mudanca do `dest_ap`) pagava a postura
----      duas vezes, e o filtro cortava tiles que a unidade alcanca de sobra.
----
----   2. CHAVE DO CACHE DE LOS SEM POSTURA. `g_AIDestEnemyLOSCache` e chaveado pelo destino
----      EMPACOTADO, entao consultar o `dest` cru mede a postura que ele por acaso tem. O
----      MGSetup deita por definicao; a consulta tem que ser pela chave Prone, como na
----      AIPolicyMGSetupPosScore e na AIPolicyThreatExposure.
----
----   3. `nil` TRATADO COMO "SEM LINHA". `not g_AIDestEnemyLOSCache[dest]` nao distingue
----      "checado e nao tem linha" (false) de "nunca checado" (nil). Tile fora da batelada do
----      AIUpdateDestLosCache era eliminado por falta de dado, nao por falta de linha.
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyMGSetupAP = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "CheckLOS", editor = "bool", default = true}
    }
}

function AIPolicyMGSetupAP:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end

    local unit = context.unit
    local x, y, z, stance_idx = stance_pos_unpack(dest)
    if not x then
        return 0
    end

    local los_fixes = rawget(_G, "RATOAI_LOSFixes") ~= false
    local prone_idx = StancesList.Prone
    local prone_key = (stance_idx == prone_idx) and dest or stance_pos_pack(x, y, z, prone_idx)

    if self.CheckLOS and g_AIDestEnemyLOSCache then
        local key = los_fixes and prone_key or dest
        local los = g_AIDestEnemyLOSCache[key]
        if los == nil then
            los = g_AIDestEnemyLOSCache[dest]
        end
        ---- `nil` = nunca checado; so `false` elimina.
        if los == false then
            return 0
        end
    end

    local setup_cost = CombatActions.MGSetup:GetAPCost(unit, false) or 0
    if not unit:HasStatusEffect("ManningEmplacement") then
        ---- Troca a mudanca de postura medida da postura ATUAL pela medida da postura DO DESTINO.
        ---- `Unit:GetStanceToStanceAP(stance, override)` devolve -1 quando ja se esta nela (dai o
        ---- `Max(0, ...)`) e ja trata a perk HitTheDeck.
        setup_cost = setup_cost - Max(0, unit:GetStanceToStanceAP("Prone")) +
                         Max(0, unit:GetStanceToStanceAP("Prone", StancesList[stance_idx]))
    end

    local ap = context.dest_ap[dest] or 0

    return ap >= setup_cost and 100 or 0
end
