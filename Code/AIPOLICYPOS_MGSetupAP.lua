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

    local prone_idx = StancesList.Prone
    local prone_key = (stance_idx == prone_idx) and dest or stance_pos_pack(x, y, z, prone_idx)

    if self.CheckLOS and g_AIDestEnemyLOSCache then
        local key = prone_key
        local los = g_AIDestEnemyLOSCache[key]
        if los == nil then
            los = g_AIDestEnemyLOSCache[dest]
        end
        ---- `nil` = nunca checado; so `false` elimina.
        if los == false then
            return 0
        end
    end

    ---- Troca a mudanca de postura medida da postura ATUAL pela medida da postura DO DESTINO.
    ---- As duas pontas saem do MESMO `rat_MGSetup_StanceAP` (GBO3) que o `GetAPCost` usa por
    ---- dentro -- a formula tem guarda de emplacamento, HitTheDeck e free move, e escrever
    ---- qualquer uma delas de novo aqui e como o B29d nasceu.
    ----
    ---- BUGFIX (B33): o termo RECOLOCADO passa `ignore_free_move`. O desconto de free move existe
    ---- para o jogador (ver o cabecalho da funcao no GBO3); para a IA ele e miragem, porque o
    ---- `AIPlayAttacks` (CombatAI.lua:202) faz `RemoveStatusEffect("FreeMove")` ANTES de escolher
    ---- signature action. Esta policy roda no posicionamento, com o pool ainda cheio; quando o
    ---- MGSetup for de fato executado o pool sera zero. Orcar com o desconto aprovaria tiles que a
    ---- acao depois recusa -- exatamente o sintoma do B29d.
    ---- O termo DESCONTADO nao leva a valvula de proposito: ele tem que reproduzir o que o
    ---- `GetAPCost` embutiu agora, com free move e tudo, senao a subtracao nao cancela.
    local setup_cost = (CombatActions.MGSetup:GetAPCost(unit, false) or 0) -
                           rat_MGSetup_StanceAP(unit) +
                           rat_MGSetup_StanceAP(unit, StancesList[stance_idx], "ignore_free_move")

    local ap = context.dest_ap[dest] or 0

    return ap >= setup_cost and 100 or 0
end
