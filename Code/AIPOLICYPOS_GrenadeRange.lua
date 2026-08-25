DefineClass.AIPolicyGrenadeRange = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "CheckLOS", editor = "bool", default = true}, {
            id = "EnvState",
            name = "Environmental State",
            editor = "set",
            default = false,
            three_state = true,
            items = function(self)
                return AIEnvStateCombo
            end
        }, {
            id = "RangeMin",
            name = "Preferred Range (Min)",
            help = "Percent of base preferred range",
            editor = "number",
            default = 80,
            min = 0,
            max = 1000
        }, {
            id = "RangeMax",
            name = "Preferred Range (Max)",
            help = "Percent of base preferred range",
            editor = "number",
            default = 120,
            min = 0,
            max = 1000
        }, {
            id = "DownedWeightModifier",
            name = "Downed Enemy Weight Modifier",
            editor = "number",
            default = 5,
            scale = "%",
            min = 0
        }, {
            id = "AllowedTriggerTypes",
            editor = "set",
            items = {"Contact", "Proximity-Timed", "Proximity", "Timed", "Remote"},
            default = set("Contact", "Proximity-Timed", "Proximity", "Timed", "Remote")
        }, {
            id = "AllowedAoeTypes",
            editor = "set",
            items = {"none", "fire", "smoke", "teargas", "toxicgas"},
            default = set("none")
        }, {id = "SaveAP", editor = "bool", default = false},
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true}
    }
}

----TODO: probably need to check visibility and save ap?
----TODO: add a check to all positioning behaviors, if same position as start then dont use
---- Sometimes positioning behavior uses a position with a bit less score?

function AIPolicyGrenadeRange:GetEditorView()
    return string.format("Be in %d%% to %d%% of grenade range", self.RangeMin, self.RangeMax)
end

function AIPolicyGrenadeRange:EvalDest(context, dest, grid_voxel)
    if self.CheckLOS and not g_AIDestEnemyLOSCache[dest] then
        return 0
    end

    for state, value in pairs(self.EnvState) do
        if value ~= not not GameState[state] then
            return 0
        end
    end
    ---- PERF (C7): resolucao da granada e escala dos ranges saem do laco de
    ---- inimigos -- eram invariantes recalculados por (destino, inimigo).
    local base_range, cost_check = self:GetGrenadeMaxRangeAndAPcost(context)
    if not base_range then
        return 0
    end

    if self.SaveAP and cost_check and cost_check >= 0 then
        local ap = context.dest_ap[dest]
        if ap < cost_check then
            return 0
        end
    end

    local range_min = self.RangeMin and MulDivRound(self.RangeMin, base_range, 100)
    local range_max = self.RangeMax and MulDivRound(self.RangeMax, base_range, 100)

    local enemy_grid_voxel = context.enemy_grid_voxel
    local x1, y1, z1 = point_unpack(grid_voxel)
    local weight = 0
    for _, enemy in ipairs(context.enemies) do
        if RATOAI_GrenadeRangeCheck(x1, y1, z1, enemy_grid_voxel[enemy], range_min, range_max) then
            if enemy:IsIncapacitated() then
                weight = self.DownedWeightModifier
            else
                return 100
            end
        end
    end
    return weight
end

function RATOAI_GrenadeRangeCheck(x1, y1, z1, ppt2, range_min, range_max)
    local x2, y2, z2 = point_unpack(ppt2)
    if (range_min or 0) > 0 and IsCloser(x1, y1, z1, x2, y2, z2, range_min) then
        return false
    end
    if (range_max or 0) > 0 and not IsCloser(x1, y1, z1, x2, y2, z2, range_max + 1) then
        return false
    end
    return true
end

---- PERF (C7): estas duas closures eram RECRIADAS a cada chamada de
---- GetGrenadeMaxRangeAndAPcost, que rodava (destinos x inimigos) vezes.
local function set_to_table(sett)
    local ttable = {}
    for k, b in pairs(sett) do
        if b then
            table.insert_unique(ttable, k)
        end
    end
    if not next(ttable) then
        return false
    end
    return ttable
end

local function any_value_in_table(table1, table2)
    for i, v in ipairs(table1) do
        if table.find(table2, v) then
            return true
        end
    end
    return false
end

---- PERF (C7): o resultado e invariante durante todo o turno da unidade, mas era
---- recalculado por (destino, inimigo) -- alocando 4 tabelas e percorrendo
---- archetype.SignatureActions + 4 CombatActions a cada vez.
---- O cache e chaveado por `self` (nao global) porque archetypes diferentes
---- configuram AllowedAoeTypes / AllowedTriggerTypes diferentes na mesma politica.
function AIPolicyGrenadeRange:GetGrenadeMaxRangeAndAPcost(context)
    local cache = context.__grenade_range_cache
    if not cache then
        cache = {}
        context.__grenade_range_cache = cache
    end

    local hit = cache[self]
    if hit then
        return hit.range, hit.cost
    end

    local range, cost = self:CalcGrenadeMaxRangeAndAPcost(context)
    cache[self] = {range = range, cost = cost}
    return range, cost
end

function AIPolicyGrenadeRange:CalcGrenadeMaxRangeAndAPcost(context)

    local archetype = context and context.archetype
    for i, sig in ipairs(archetype.SignatureActions) do
        if sig.class == "AIActionThrowGrenade" then
            local aoetype = set_to_table(sig.AllowedAoeTypes) or {"none"}
            local triggerType = set_to_table(sig.AllowedTriggerTypes) or {"Contact"}
            local self_aoe_type = set_to_table(self.AllowedAoeTypes) or {"none"}
            local self_trigger_type = set_to_table(self.AllowedTriggerTypes) or {"Contact"}

            if any_value_in_table(self_aoe_type, aoetype) and
                any_value_in_table(self_trigger_type, triggerType) then
                return RATOAI_GetGrenadeActionMaxRangeAndApCost(context, sig, self.SaveAP)
            end
        end
    end
    return false
end

function RATOAI_GetGrenadeActionMaxRangeAndApCost(context, signature, check_ap)
    local max_range, cost
    local actions = {"ThrowGrenadeA", "ThrowGrenadeB", "ThrowGrenadeC", "ThrowGrenadeD"}
    for _, id in ipairs(actions) do
        local caction = CombatActions[id]
        local actcost = check_ap and (caction and caction:GetAPCost(context.unit) or -1)
        local weapon = caction and caction:GetAttackWeapons(context.unit)
        if weapon then
            local aoetype = weapon.aoeType or "none"
            ----
            local triggerType = weapon.TriggerType or "Contact"
            ----
            if weapon and IsKindOf(weapon, "Grenade") and signature.AllowedAoeTypes[aoetype] and
                signature.AllowedTriggerTypes[triggerType] then
                max_range = caction:GetMaxAimRange(context.unit, weapon)
                cost = actcost
                break
            end
        end
    end

    ---- BUGFIX (B38): `cost` era calculado logo acima e depois DESCARTADO -- a funcao devolvia
    ---- so o alcance. Com isso o `cost_check` do EvalDest chegava sempre nil e o gate do
    ---- `SaveAP` nunca disparava: a property existia no editor e nao fazia nada.
    ---- Risco zero em ativar: `SaveAP` esta false em todos os presets do items.lua, entao o
    ---- gate so passa a valer para quem o ligar de proposito daqui em diante.
    return max_range, cost
end

---------------------------------------------------------------------------------------------------
---- AIPolicyCustomGrenadeRange
----
---- O que a AIPolicyCustomWeaponRange e para a AIPolicyWeaponRange, esta e para a
---- AIPolicyGrenadeRange -- mesma critica, mesmo remedio, e o texto daquela vale inteiro aqui.
----
---- A original e um quantificador existencial com saida antecipada: basta UM inimigo na faixa e
---- o tile vale 100, mesmo que os outros cinco estejam colados ou longe demais. E como o score e
---- binario, ela produz platos enormes de tiles empatados -- e o OptLoc descarta diferencas
---- dentro do corte de 80% e deixa o pathfinder escolher, entao o plato decide no lugar da
---- policy.
----
---- Aqui vale a mesma estrutura da irma:
----   Mode = "target"    -> mede contra context.dest_target[dest] (use no End Turn);
----   Mode = "weighted"  -> media sobre os inimigos visiveis ponderada por proximidade (use no
----                         Optimal Location, onde nao ha alvo definido).
----   Falloff            -> o score cai de 100 a 0 ao longo de N tiles fora da faixa, em vez de
----                         cair em degrau.
----
---- HERDA DA AIPolicyGrenadeRange de proposito. A resolucao de qual granada, o alcance dela e o
---- custo de AP sao trabalho nao-trivial e ja estao la, com o cache por `self` do PERF (C7).
---- Duplicar isso seria criar a segunda fonte de verdade sobre "qual granada esta unidade usa" --
---- exatamente o defeito que o BUGFIX B29 consertou entre a policy da MG e a acao dela.
----
---- DUAS DIFERENCAS DELIBERADAS EM RELACAO A MAE:
----
----   1. `CheckLOS` zera so quando o motor CHECOU e ninguem ve (`== false`). A mae trata `nil`
----      -- destino que nunca entrou na batelada do AIUpdateDestLosCache -- como "sem LOS", o
----      que apaga tiles por falta de dado. Mesma leitura da AIPolicyCustomWeaponRange.
----
----   2. Inimigo caido NAO conta -- BUGFIX (B40). Ver abaixo.
----
---- BUGFIX (B40) -- CAIDO NAO E REFERENTE DE POSICIONAMENTO
----
---- Esta policy responde "estou na distancia certa do inimigo que define minha posicao?".
---- Um inimigo caido nao define posicao nenhuma: nao atira, nao se move, e a granada nele e
---- overkill -- o proprio AIPrecalcDamageScore ja corta o score de alvo derrubado para 5%.
----
---- Antes, ele entrava na media ponderada com `w x DownedWeightModifier/100` (5% por default).
---- Parece inofensivo, mas 5% de peso nao e 0: como a policy devolve uma MEDIA (`total /
---- total_weight`), um caido sozinho no alcance de arremesso ainda fazia `total_weight > 0`
---- e a policy OPINAVA -- declarando "boa distancia de granada" um tile medido contra alguem
---- que ja esta fora da luta. Era o unico caso em que ela falava sem ter referente valido.
----
---- Agora ele e pulado no laco, exatamente como na AIPolicyCustomWeaponRange, e o predicado
---- e `IsIncapacitated()` nas duas (superconjunto de morto+caido: pega tambem o que esta no
---- meio da queda e o `command == "Die"`).
----
---- Consequencia da media: pular nao e o mesmo que pesar 0 no numerador -- o caido sai
---- TAMBEM do denominador. Um tile com um caido perto e um inimigo vivo na faixa marca 100,
---- e nao 100 diluido. E o comportamento certo: a nota mede a relacao com quem importa.
----
---- `DownedWeightModifier` fica `no_edit` nesta classe para nao ser um botao que mente no
---- editor. A mae continua usando (ela e o espelho da vanilla e tem 0 usos no items.lua).
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyCustomGrenadeRange = {
    __parents = {"AIPolicyGrenadeRange"},
    __generated_by_class = "ClassDef",

    properties = {
        {
            ---- BUGFIX (B40): esta classe PULA o caido em vez de pesa-lo menos, entao o
            ---- valor daqui nao e lido em lugar nenhum. Fica `no_edit` para nao aparecer
            ---- no editor como um botao sem efeito. A mae continua usando o dela.
            id = "DownedWeightModifier",
            name = "Downed Enemy Weight Modifier",
            help = "Nao usado nesta classe: inimigo caido e ignorado por completo.",
            editor = "number",
            default = 0,
            scale = "%",
            min = 0,
            no_edit = true
        }, {
            id = "Mode",
            name = "Referencia",
            help = "target = mede contra o alvo escolhido para este tile (use no End Turn).\n" ..
                "weighted = media ponderada pela proximidade sobre todos os inimigos " ..
                "visiveis (use no Optimal Location, onde nao ha alvo definido).\n" ..
                "Em 'target', tiles sem alvo caem automaticamente em 'weighted'.",
            editor = "choice",
            default = "weighted",
            items = function(self)
                return {"target", "weighted"}
            end
        }, {
            id = "visibility_mode",
            name = "Visibility Mode",
            help = "A mae nao filtra visibilidade nenhuma -- conta inimigo que o time nem " ..
                "detectou. Aqui filtra, como as outras policies do mod.",
            editor = "choice",
            default = "team",
            items = function(self)
                return {"self", "team", "all"}
            end
        }, {
            id = "RangeBase",
            name = "Base da faixa",
            help = "Grenade = RangeMin/RangeMax sao % do alcance de arremesso resolvido para " ..
                "esta unidade (forca + perk Throwing). Absolute = sao tiles.",
            editor = "choice",
            default = "Grenade",
            items = function(self)
                return {"Grenade", "Absolute"}
            end
        }, {
            id = "Falloff",
            name = "Queda fora da faixa (tiles)",
            help = "Em quantos tiles o score cai de 100 a 0 depois de sair da faixa, dos dois " ..
                "lados. 0 = degrau seco (comportamento binario da mae).",
            editor = "number",
            default = 6,
            min = 0,
            max = 100
        }, {
            id = "WeightFalloff",
            name = "Queda do peso por distancia",
            help = "So no modo weighted. Quanto o inimigo proximo domina a media.\n" ..
                "linear = um inimigo colado entre tres na faixa ideal ainda deixa o tile em " ..
                "~55.\nquadratica = o colado domina bem mais e o tile despenca.",
            editor = "choice",
            default = "linear",
            items = function(self)
                return {"linear", "quadratica"}
            end
        }
    }
}

function AIPolicyCustomGrenadeRange:GetEditorView()
    local faixa
    if self.RangeBase == "Absolute" then
        faixa = string.format("%d-%d tiles", self.RangeMin, self.RangeMax)
    else
        faixa = string.format("%d-%d%% do alcance", self.RangeMin, self.RangeMax)
    end
    return string.format("Custom Grenade Range (%s, %s)", self.Mode, faixa)
end

---------------------------------------------------------------------------------------------------
---- Faixa preferida em unidades de mundo. `base_range` vem em TILES -- e o
---- Grenade:GetMaxAimRange, mesma unidade de WeaponRange, e e por isso que a mae o compara com
---- IsCloser sobre coordenadas de voxel. Aqui medimos em unidades de mundo (Dist entre pontos),
---- entao a conversao e explicita.
---------------------------------------------------------------------------------------------------
function AIPolicyCustomGrenadeRange:GetBand(context, base_range)
    local rmin, rmax
    if self.RangeBase == "Absolute" then
        rmin, rmax = self.RangeMin, self.RangeMax
    else
        rmin = MulDivRound(self.RangeMin, base_range, 100)
        rmax = MulDivRound(self.RangeMax, base_range, 100)
    end
    return rmin * const.SlabSizeX, rmax * const.SlabSizeX, self.Falloff * const.SlabSizeX
end

---- DELEGADAS a AIPolicyCustomWeaponRange, e de proposito: as tres respondem perguntas que nao
---- podem ter duas respostas -- "quao bem esta distancia serve", "quanto este inimigo define
---- onde eu devo estar", "este inimigo conta". Divergir na forma da curva faria os dois lados do
---- mesmo arquetipo discordarem sobre o que e "faixa boa".
----
---- Delegacao em tempo de execucao, e nao alias no load (`X.BandScore = Y.BandScore`): o alias
---- so funcionaria enquanto o CustomWeaponRange carregasse ANTES deste arquivo, e a ordem mora
---- no metadata.lua, que e reordenado pelo editor. Um `nil` silencioso ali seria mais uma
---- mecanica morta sem aviso, que e o defeito que este projeto ja pagou caro varias vezes.
function AIPolicyCustomGrenadeRange:BandScore(dist, rmin, rmax, falloff)
    return AIPolicyCustomWeaponRange.BandScore(self, dist, rmin, rmax, falloff)
end

function AIPolicyCustomGrenadeRange:EnemyWeight(dist, weight_ref)
    return AIPolicyCustomWeaponRange.EnemyWeight(self, dist, weight_ref)
end

function AIPolicyCustomGrenadeRange:IsVisible(context, enemy)
    return AIPolicyCustomWeaponRange.IsVisible(self, context, enemy)
end

function AIPolicyCustomGrenadeRange:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end

    ---- `false` = o motor checou e ninguem ve; `nil` = destino que nunca entrou na batelada do
    ---- AIUpdateDestLosCache, e ai seguimos avaliando normalmente. Ver o cabecalho.
    if self.CheckLOS and g_AIDestEnemyLOSCache and g_AIDestEnemyLOSCache[dest] == false then
        return 0
    end

    for state, value in pairs(self.EnvState) do
        if value ~= not not GameState[state] then
            return 0
        end
    end

    ---- herdado, com o cache por `self` do PERF (C7): invariante no turno
    local base_range, cost = self:GetGrenadeMaxRangeAndAPcost(context)
    if not base_range then
        return 0
    end

    if self.SaveAP and cost and cost >= 0 then
        local ap = context.dest_ap and context.dest_ap[dest]
        if ap and ap < cost then
            return 0
        end
    end

    local self_pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(dest))
    if not IsValidPos(self_pos) then
        return 0
    end

    local rmin, rmax, falloff = self:GetBand(context, base_range)

    ------------------------------------------------------------------------------------------
    ---- Modo target: mede contra o alvo escolhido para ESTE destino. So existe onde o
    ---- AIPrecalcDamageScore passou; sem alvo, cai no ponderado em vez de ficar mudo.
    ------------------------------------------------------------------------------------------
    if self.Mode == "target" then
        local target = context.dest_target and context.dest_target[dest]
        ---- BUGFIX (B40): mesmo predicado da AIPolicyCustomWeaponRange
        if IsValid(target) and not target:IsIncapacitated() then
            local tpos = RATOAI_ValidatePosZ(target:GetPos())
            if IsValidPos(tpos) then
                return self:BandScore(self_pos:Dist(tpos), rmin, rmax, falloff)
            end
        end
    end

    ------------------------------------------------------------------------------------------
    ---- Modo ponderado: media sobre os inimigos visiveis, ponderada por proximidade.
    ------------------------------------------------------------------------------------------
    ---- `Max(falloff, 1 tile)` garante peso > 0 para quem esta exatamente em rmax mesmo com
    ---- Falloff = 0 (faixa em degrau): senao um inimigo com score 100 sairia da media.
    local weight_ref = rmax + Max(falloff, const.SlabSizeX)
    local total, total_weight = 0, 0

    for _, enemy in ipairs(context.enemies or empty_table) do
        ---- BUGFIX (B40): caido fora do numerador E do denominador -- ver o cabecalho
        if self:IsVisible(context, enemy) and enemy and not enemy:IsIncapacitated() then
            local epos = RATOAI_ValidatePosZ(enemy:GetPos())
            if IsValidPos(epos) then
                local dist = self_pos:Dist(epos)
                local w = self:EnemyWeight(dist, weight_ref)
                if w > 0 then
                    total = total + self:BandScore(dist, rmin, rmax, falloff) * w
                    total_weight = total_weight + w
                end
            end
        end
    end

    ---- Ninguem visivel dentro do alcance de arremesso: a policy nao tem referencia e nao opina.
    if total_weight <= 0 then
        return 0
    end

    return MulDivRound(total, 1, total_weight)
end
