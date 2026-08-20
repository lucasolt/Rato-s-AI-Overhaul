---------------------------------------------------------------------------------------------------
---- AIPolicyCustomWeaponRange
----
---- Versao propria da AIPolicyWeaponRange do vanilla. A original NAO e sobrescrita --
---- ela tem 29 usos no items.lua e continua disponivel para comparacao lado a lado.
----
---- O QUE MUDA
----
---- A vanilla e um quantificador existencial com saida antecipada:
----
----     for _, enemy in ipairs(context.enemies) do
----         if AIRangeCheck(...) then
----             ...
----             return 100        -- primeiro que casar, ignora todos os outros
----         end
----     end
----
---- Ou seja: "EXISTE um inimigo na faixa" -> 100. Um sniper colado num inimigo pontua
---- nota maxima porque tem outro inimigo la longe dentro da faixa. O erro nao e ignorar
---- perigo (isso e da AIPolicyThreatExposure) -- e escolher o REFERENTE errado. A
---- pergunta pretendida e "estou na distancia certa do inimigo que define minha
---- posicao", e "de alguem" e uma afirmacao bem mais fraca.
----
---- Aqui a resposta depende de qual pergunta a lista faz:
----
----   Mode = "target"    (END TURN) -- mede contra context.dest_target[dest], o alvo que
----                      a IA de fato escolheu para este tile. O AIPrecalcDamageScore
----                      roda ANTES do AIScoreReachableVoxels (AIBehaviors.lua:252/255,
----                      445/446, 534/540), entao o alvo ja esta la, de graca. Bonus: o
----                      AIPolicyDealDamage usa dest_hit_score, que e o hit score DESSE
----                      mesmo alvo -- as duas policies passam a falar do mesmo inimigo.
----
----   Mode = "weighted"  (OPTIMAL LOCATION) -- o OptLoc roda sobre all_destinations, onde
----                      dest_target nao existe: ele nao sabe em quem a unidade vai
----                      atirar. Entao mede contra TODOS os inimigos visiveis, com media
----                      ponderada pela proximidade.
----
---- POR QUE MEDIA PONDERADA E NAO CENTROIDE
----
---- Centroide (media das posicoes dos inimigos) daria um campo liso e O(1) por tile, mas
---- quebra na formacao em pinca: com metade dos inimigos de cada lado, o centroide cai no
---- meio, onde nao ha ninguem, e a policy afirma "daqui eu atiro bem" estando colada nos
---- dois grupos. Como esta policy e OFENSIVA, nao da para terceirizar isso para a Threat
---- Exposure -- ela apenas somaria um negativo em cima de um positivo falso, e archetypes
---- agressivos (peso alto aqui, baixo la) entrariam na pinca assim mesmo.
----
---- Consertar o centroide exige clusterizar e escolher um grupo, o que reintroduz
---- descontinuidade (o score SALTA na fronteira entre grupos) e traz parametros novos.
----
---- Ponderar por proximidade resolve a pinca sem nada disso: e uma versao continua e
---- implicita de "use o grupo mais proximo". Quem esta perto domina o peso, e como quem
---- esta perto demais pontua 0 pelo RangeMin, o tile no meio da pinca cai sozinho.
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyCustomWeaponRange = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {
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
            help = "A vanilla nao filtra visibilidade nenhuma -- conta inimigo que o time " ..
                "nem detectou. Aqui filtra, como as outras policies do mod.",
            editor = "choice",
            default = "team",
            items = function(self)
                return {"self", "team", "all"}
            end
        }, {
            id = "RangeBase",
            name = "Base da faixa",
            help = "Weapon = RangeMin/RangeMax sao % do alcance da SUA arma " ..
                "(context.ExtremeRange). Absolute = sao tiles.",
            editor = "choice",
            default = "Weapon",
            items = function(self)
                return {"Weapon", "Absolute"}
            end
        }, {
            id = "RangeMin",
            name = "Faixa preferida (min)",
            editor = "number",
            default = 30,
            min = 0,
            max = 1000
        }, {
            id = "RangeMax",
            name = "Faixa preferida (max)",
            editor = "number",
            default = 60,
            min = 0,
            max = 1000
        }, {
            id = "Falloff",
            name = "Queda fora da faixa (tiles)",
            help = "Em quantos tiles o score cai de 100 a 0 depois de sair da faixa, dos " ..
                "dois lados. 0 = degrau seco (comportamento binario da vanilla).\n" ..
                "Existe para o Optimal Location: policy binaria cria platos enormes de " ..
                "tiles empatados, e como o OptLoc descarta diferencas dentro do corte de " ..
                "80% e deixa o pathfinder escolher, o platodecide no lugar das policies.",
            editor = "number",
            default = 6,
            min = 0,
            max = 100
        }, {
            id = "WeightFalloff",
            name = "Queda do peso por distancia",
            help = "So no modo weighted. Quanto o inimigo proximo domina a media.\n" ..
                "linear = um inimigo colado entre tres na faixa ideal ainda deixa o tile " ..
                "em ~55.\nquadratica = o colado domina bem mais e o tile despenca.",
            editor = "choice",
            default = "linear",
            items = function(self)
                return {"linear", "quadratica"}
            end
        }, {
            id = "RequireLOS",
            name = "Ignorar tiles que ninguem enxerga",
            help = "A vanilla tambem nao checa LOS: estar na distancia ideal de alguem " ..
                "atras de um muro conta como posicao de tiro. Ligado, zera a policy " ..
                "quando o cache do motor diz que ninguem ve este destino. O cache e " ..
                "agregado por destino, entao nao distingue QUAL inimigo.",
            editor = "bool",
            default = false
        }
    }
}

function AIPolicyCustomWeaponRange:GetEditorView()
    local faixa
    if self.RangeBase == "Absolute" then
        faixa = string.format("%d-%d tiles", self.RangeMin, self.RangeMax)
    else
        faixa = string.format("%d-%d%% do alcance", self.RangeMin, self.RangeMax)
    end
    return string.format("Custom Weapon Range (%s, %s)", self.Mode, faixa)
end

---------------------------------------------------------------------------------------------------
---- Faixa preferida em unidades de mundo. Depende so do contexto, nao do destino, entao
---- e resolvida uma vez por avaliacao e nao por inimigo.
---------------------------------------------------------------------------------------------------
function AIPolicyCustomWeaponRange:GetBand(context)
    local rmin, rmax
    if self.RangeBase == "Absolute" then
        rmin, rmax = self.RangeMin, self.RangeMax
    else
        ---- ExtremeRange ja vem em tiles (weapon.WeaponRange, com o ajuste de 70% para
        ---- escopeta sem slug). Mesma base que o AIRangeCheck do vanilla usa.
        local base = context.ExtremeRange or 1
        rmin = MulDivRound(self.RangeMin, base, 100)
        rmax = MulDivRound(self.RangeMax, base, 100)
    end
    return rmin * const.SlabSizeX, rmax * const.SlabSizeX, self.Falloff * const.SlabSizeX
end

---- 100 dentro da faixa, caindo linearmente ate 0 ao longo de `falloff` para os dois
---- lados. Perto demais vale 0, nunca negativo: negativo e vocabulario da Threat
---- Exposure, e somar penalidade aqui seria contar a mesma proximidade duas vezes.
function AIPolicyCustomWeaponRange:BandScore(dist, rmin, rmax, falloff)
    if dist >= rmin and dist <= rmax then
        return 100
    end
    if falloff <= 0 then
        return 0
    end
    local d = (dist < rmin) and (rmin - dist) or (dist - rmax)
    if d >= falloff then
        return 0
    end
    return 100 - MulDivRound(d, 100, falloff)
end

---- Peso do inimigo como REFERENTE de posicionamento: 100 colado, caindo ate 0 na BORDA
---- EXTERNA DA FAIXA (rmax + falloff) -- ou seja, exatamente onde o BandScore tambem
---- zera. Quem nao pode contribuir com nada tambem nao pesa nada.
----
---- A referencia NAO pode ser o alcance da minha arma: com faixa de sniper (80-120% do
---- alcance), um inimigo na distancia ideal ficaria com peso ~8 (ou ~1 no quadratico) e
---- a policy declararia 22 tiles como ideal enquanto praticamente ignorava quem esta la.
---- Contradicao interna: os pesos precisam cobrir toda a regiao onde o score e nao-nulo.
----
---- Note que a referencia e MINHA faixa, e nao o alcance do inimigo como na
---- RATOAI_ThreatRamp -- a pergunta e "quanto este inimigo define onde eu devo estar",
---- e nao "quanto ele me ameaca".
function AIPolicyCustomWeaponRange:EnemyWeight(dist, weight_ref)
    local w = RATOAI_ThreatRamp(dist, weight_ref)
    if self.WeightFalloff == "quadratica" then
        w = MulDivRound(w, w, 100)
    end
    return w
end

function AIPolicyCustomWeaponRange:IsVisible(context, enemy)
    if self.visibility_mode == "self" then
        return context.enemy_visible[enemy]
    elseif self.visibility_mode == "team" then
        return context.enemy_visible_by_team[enemy]
    end
    return true
end

function AIPolicyCustomWeaponRange:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end

    ---- `false` = o motor checou e ninguem ve; `nil` = destino que nunca entrou na
    ---- batelada do AIUpdateDestLosCache, e ai seguimos avaliando normalmente.
    if self.RequireLOS and g_AIDestEnemyLOSCache and g_AIDestEnemyLOSCache[dest] == false then
        return 0
    end

    local self_pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(dest))
    if not IsValidPos(self_pos) then
        return 0
    end

    local rmin, rmax, falloff = self:GetBand(context)

    ------------------------------------------------------------------------------------
    ---- Modo target: mede contra o alvo escolhido para ESTE destino.
    ---- So existe onde o AIPrecalcDamageScore passou (context.destinations). No OptLoc,
    ---- e em behaviors que nao atacam, dest_target e nil -- e ai cair no modo ponderado
    ---- e melhor que ficar mudo, porque a pergunta "estou a boa distancia" continua
    ---- respondivel sem alvo definido.
    ------------------------------------------------------------------------------------
    if self.Mode == "target" then
        local target = context.dest_target and context.dest_target[dest]
        if IsValid(target) and not (target:IsDead() or target:IsDowned()) then
            local tpos = RATOAI_ValidatePosZ(target:GetPos())
            if IsValidPos(tpos) then
                return self:BandScore(self_pos:Dist(tpos), rmin, rmax, falloff)
            end
        end
    end

    ------------------------------------------------------------------------------------
    ---- Modo ponderado: media sobre os inimigos visiveis, ponderada por proximidade.
    ------------------------------------------------------------------------------------
    ---- `Max(falloff, 1 tile)` garante peso > 0 para quem esta exatamente em rmax mesmo
    ---- com Falloff = 0 (faixa em degrau): senao um inimigo com score 100 sairia da media.
    local weight_ref = rmax + Max(falloff, const.SlabSizeX)
    local total, total_weight = 0, 0

    for _, enemy in ipairs(context.enemies or empty_table) do
        if self:IsVisible(context, enemy) and enemy and not (enemy:IsDead() or enemy:IsDowned()) then
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

    ---- Ninguem visivel dentro do meu alcance: a policy nao tem referencia e nao opina.
    if total_weight <= 0 then
        return 0
    end

    return MulDivRound(total, 1, total_weight)
end
