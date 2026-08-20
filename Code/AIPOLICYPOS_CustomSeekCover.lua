DefineClass.AIPolicyCustomSeekCover = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {
            id = "visibility_mode",
            name = "Visibility Mode",
            editor = "choice",
            default = "team",
            items = function(self)
                return {"self", "team", "all"}
            end
        }, {
            ---- Reaproveitada: agora significa "ponderar a media pela distancia", com o
            ---- peso indo tambem para o DENOMINADOR (media ponderada de verdade).
            ---- Default true -- e o conserto da diluicao, nao um opcional.
            id = "ScalePerDistance",
            name = "Ponderar por distancia (rampa)",
            help = "Cada inimigo pesa 100 colado e 0 no limite do alcance da arma dele. " ..
                "Desligado, todos pesam igual e inimigos fora de alcance diluem a media.",
            editor = "bool",
            default = true,
            read_only = false,
            no_edit = false
        }, {
            id = "ForceCheckLastEnemyPos",
            editor = "bool",
            default = false,
            read_only = false,
            no_edit = false
        }, -- {
        --    id = "ExposedAtCloseRange_Score",
        --    editor = "number",
        --    default = 0,
        --    read_only = false,
        --    no_edit = false
        -- },
        {
            id = "SimpleGetCover",
            editor = "bool",
            default = false,
            read_only = false,
            no_edit = false
        }, {id = "BaseScore", editor = "number", default = 100, read_only = false, no_edit = false},
        {
            ---- Default FALSE de proposito: ligar isto muda o comportamento das 21
            ---- instancias de uma vez. Ligue no archetype que voce esta testando e
            ---- compare, em vez de virar a chave no mod inteiro.
            id = "RequireLOS",
            name = "Ignorar tiles que ninguem enxerga",
            help = "Zera a policy quando o cache de LOS do motor diz que NENHUM inimigo " ..
                "ve este destino. Sem isto, um tile escondido ganha nota cheia de " ..
                "cobertura contra inimigos que nem conseguem olhar para ele. " ..
                "Esconder-se nao perde valor: continua valendo 0 contra o negativo de " ..
                "estar exposto. Mesmo portao da AIPolicyThreatExposure.",
            editor = "bool",
            default = true,
            read_only = false,
            no_edit = false
        }, {
            ---- Default 0 = comportamento identico ao de hoje. Ligue no archetype que
            ---- voce esta testando (sugestao: 75) e compare, em vez de mexer nos 21.
            id = "ThreatRelative",
            name = "Cobertura relativa a ameaca (%)",
            help = "0 = cobertura ABSOLUTA: media pura, um tile longe com cobertura total " ..
                "vale 100 igual a um tile colado com cobertura total.\n" ..
                "100 = cobertura EXTENSIVA: vale o quanto de ameaca ela de fato neutraliza, " ..
                "na mesma escala da Threat Exposure -- longe do inimigo tende a zero, e " ..
                "cobertura total cancela exatamente a exposicao.\n" ..
                "Valores no meio interpolam entre os dois.",
            editor = "number",
            default = 0,
            min = 0,
            max = 100,
            read_only = false,
            no_edit = false
        }
    }
}

----- Args
local distance_impact = 100 ---- BUGFIX (B7): era 1.00 (float). Agora percentual.
local max_range = 30
local min_dist = 5 * const.SlabSizeX
local pb_range = const.Weapons.PointBlankRange * const.SlabSizeX
local close_range_mul_penalty_mul = 75
local medium_range_penalty_mul = 40

---------------------------------------------------------------------------------------------------
---- DIAGNOSTICO
----
---- `RATOAI_SeekCoverDebug = true` no console faz cada destino guardar o passo a passo em
---- context.dest_custom_seek_cover_debug[dest], que o DEBUG.lua mostra no rollover do
---- voxel. Mesmo idioma do `RATOAI_ThreatDebug` da AIPolicyThreatExposure, de proposito:
---- as duas policies so se leem juntas -- o que sobra entre elas vive na media ponderada,
---- e conferir a media exige ver os DOIS lados com os mesmos pesos na mao.
----
---- Antes o gate era `Platform.developer and Platform.cheats`, avaliado UMA vez no load:
---- em build de dev construia string para TODO destino do raio de busca, sem chave para
---- desligar, e imprimia so `id = cover_score` -- sem o peso, que e justamente o termo
---- que fecha a conta. Agora e uma global lida por avaliacao, default desligada.
---- Ligue, passe o mouse no tile, leia, desligue -- constroi string para TODO destino.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_SeekCoverDebug") == nil then
    RATOAI_SeekCoverDebug = false
end

---- distancia em tiles, para o overlay
local function dbg_tiles(d)
    return d and MulDivRound(d, 1, const.SlabSizeX) or "?"
end

---- APOSENTADO: existia so para compensar o encolhimento do ScalePerDistance antigo,
---- que pesava o NUMERADOR e deixava o denominador contando cabecas -- media encolhida,
---- nao media ponderada. Com o peso tambem no denominador a escala se fecha sozinha e
---- este fator de correcao perde a razao de ser. Mantido comentado como registro.
-- local extra_score_arg_mul = 220
-----

---------------------------------------------------------------------------------------------------
---- RAMPA DE AMEACA
----
---- Peso de um inimigo na media de cobertura: 100 colado nele, caindo linearmente ate
---- 0 no limite do alcance da arma dele. Fora do alcance devolve 0 -- o inimigo sai da
---- media em vez de entrar valendo zero e diluir os outros, que era o problema.
----
---- Global de proposito: a AIPolicyThreatExposure usa exatamente esta funcao, para as
---- duas policies nao poderem divergir de rampa.
---------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------
---- SATURACAO DE AMEACA -- COMPARTILHADA
----
---- Quantos "inimigos colados" (peso 100 cada) equivalem a ameaca cheia.
----
---- ATENCAO: este valor TEM que ser o mesmo que o `MaxThreat` da AIPolicyThreatExposure.
---- E dele que sai o cancelamento entre as duas policies: com cobertura relativa a 100%,
----     cobertura + exposicao = SOMA[ w_i * (cobertura_i - 100) ] / saturacao
---- que da exatamente 0 quando a cobertura e total. Se as duas usarem saturacoes
---- diferentes, o cancelamento quebra em SILENCIO -- sobra um vies constante que nao
---- aparece em camada nenhuma do debug. Por isso e uma constante global e nao uma
---- propriedade duplicada nas duas classes.
---------------------------------------------------------------------------------------------------
-- RATOAI_ThreatSaturation = rawget(_G, "RATOAI_ThreatSaturation") or 3

---- `plateau` (opcional, unidades de mundo): distancia ate onde o peso fica em 100
---- antes de comecar a cair. Nil ou 0 = rampa linear pura, identica a de sempre.
----
---- Existe porque a rampa linear a partir do zero contradiz a mecanica do jogo em toda
---- a primeira metade do alcance: `GetRangeAccuracy` devolve precisao CHEIA ate
---- WeaponRange/2, entao um fuzileiro a meio alcance acerta igualzinho a um colado, e a
---- rampa dava 50 para ele. Medido em jogo: AUG de 38 tiles a 8 tiles de distancia, a
---- rampa dava 79 e a precisao real era 100.
----
---- O plato NAO precisa ir ate o effective range para consertar isso. Um plato curto --
---- point blank, 6 tiles -- ja cobre a faixa onde arma automatica e letal por recoil e
---- proximidade, sem comprar o efeito colateral do plato longo: plato ate effective
---- range apaga o gradiente de distancia em metade do alcance e infla o SOMA(w) em
---- ~1.67x, o que joga quase todo tile para cima da saturacao.
function RATOAI_ThreatRamp(dist, range, plateau)
    if not dist or not range or range <= 0 or dist >= range then
        return 0
    end
    plateau = plateau or 0
    if dist <= plateau then
        ---- cobre tambem o caso dist <= 0 quando nao ha plato
        return 100
    end
    if plateau > 0 then
        ---- `plateau >= range` nao chega aqui: dist < range <= plateau cairia no ramo
        ---- acima. A subtracao no denominador e sempre positiva.
        return 100 - MulDivRound(dist - plateau, 100, range - plateau)
    end
    return 100 - MulDivRound(dist, 100, range)
end

function AIPolicyCustomSeekCover:GetEditorView()
    return "Custom Seek Cover"
end

---- Ponto unico de escrita do overlay. A tabela ja nasce em AICreateContext; criada aqui
---- tambem para a policy nao depender da ordem de carga.
function AIPolicyCustomSeekCover:StoreDebug(context, dest, txt)
    context.dest_custom_seek_cover_debug = context.dest_custom_seek_cover_debug or {}
    context.dest_custom_seek_cover_debug[dest] = txt
end

function AIPolicyCustomSeekCover:EvalDest(context, dest, grid_voxel)
    local score = 0

    local ux, uy, uz, ustance_idx = stance_pos_unpack(dest)
    local new_point = point(ux, uy, uz)
    if not dest then
        return score
    end

    ---- Portao de LOS. Zera a policy INTEIRA, positivo e negativo: se ninguem enxerga
    ---- este tile, nao ha cobertura a creditar nem exposicao a punir -- a policy
    ---- simplesmente nao tem opiniao. Sem isto, um tile escondido recebia BaseScore
    ---- cheio por cobertura geometrica contra inimigos que nao conseguem ve-lo.
    ---- `false` = o motor checou e ninguem ve; `nil` = destino que nunca entrou na
    ---- batelada do AIUpdateDestLosCache, e nesse caso seguimos avaliando normalmente.
    if self.RequireLOS and g_AIDestEnemyLOSCache and g_AIDestEnemyLOSCache[dest] == false then
        if RATOAI_SeekCoverDebug then
            self:StoreDebug(context, dest, "PORTAO LOS: nenhum inimigo enxerga este dest -> 0")
        end
        return score
    end

    ---- STANCE: a postura empacotada no dest e a que a unidade REALMENTE adota ao
    ---- chegar -- AIBehavior:EndMovement (AIBehaviors.lua:199) faz
    ---- unit:DoChangeStance(StancesList[stance_idx]) do proprio ai_destination.
    ---- Antes isso era ignorado e a cobertura era sempre medida agachado.
    local ustance = StancesList[ustance_idx]

    local tbl = context.enemies or empty_table

    ---- MEDIA PONDERADA: `score` acumula cover_i * w_i e `total_weight` acumula w_i.
    ---- Com ScalePerDistance desligado todo w_i e 100 e o resultado e identico a media
    ---- simples antiga -- a ponderacao e uma generalizacao estrita, nao um regime novo.
    local table_num = 0 -- #tbl
    local total_weight = 0
    ----

    ---- PERF (C9): estas tabelas eram alocadas em TODA avaliacao de destino,
    ---- mesmo com debug desligado. Esta e uma politica OptLoc (20 usos em
    ---- items.lua), entao rodava sobre todos os destinos do raio de busca.
    ---- `debugforpos_simple` nao tinha sequer um uso ativo -- removida.
    local dbg = RATOAI_SeekCoverDebug and {} or nil

    for _, enemy in ipairs(tbl) do
        local visible = true
        if self.visibility_mode == "self" then
            visible = context.enemy_visible[enemy]
        elseif self.visibility_mode == "team" then
            visible = context.enemy_visible_by_team[enemy]
        end

        if visible then
            table_num = table_num + 1
            local cover_score = 0
            local weight = 100
            local e_dist, e_range, why

            if self.SimpleGetCover then
                local cover = GetCoverFrom(dest, context.enemy_pack_pos_stance[enemy])
                cover_score = self:SimpleGetCoverScore(context, self.CoverScores[cover] or 0, dest,
                                                       grid_voxel, enemy)
                why = "SimpleGetCover (sem rampa)"
            else
                cover_score, weight, e_dist, e_range, why =
                    self:GetCoverScore(context, enemy, context.unit, dest, nil, grid_voxel, ustance)
            end

            weight = weight or 100
            score = score + cover_score * weight
            total_weight = total_weight + weight

            if dbg then
                if weight == 0 then
                    dbg[#dbg + 1] = string.format(
                                        "  %s: %st / alcance %st -> peso 0 (%s) -- FORA da media",
                                        tostring(enemy.session_id), tostring(dbg_tiles(e_dist)),
                                        tostring(dbg_tiles(e_range)), tostring(why))
                else
                    dbg[#dbg + 1] = string.format(
                                        "  %s: %st / alcance %st -> peso %d | cobertura %d (%s)" ..
                                            " | c*w %d", tostring(enemy.session_id),
                                        tostring(dbg_tiles(e_dist)), tostring(dbg_tiles(e_range)),
                                        weight, cover_score, tostring(why), cover_score * weight)
                end
            end
        elseif dbg then
            dbg[#dbg + 1] = string.format("  %s: PULADO (nao visivel, modo %s)",
                                          tostring(enemy.session_id), tostring(self.visibility_mode))
        end
    end

    ------------- If possible, need to check direction
    if self.ForceCheckLastEnemyPos or table_num < 1 then
        local last_pos = context.unit.last_known_enemy_pos
        -- DbgAddCircle(last_pos)
        if last_pos then
            local cover = GetCoverFrom(dest, stance_pos_pack(last_pos))
            local cover_score = self:SimpleGetCoverScore(context, self.CoverScores[cover] or 0,
                                                         dest, last_pos)
            -- table.insert(debugforpos_simple, {"last_pos", cover_score})

            ---- peso cheio: quando nao ha inimigo visivel, esta e a unica informacao
            ---- que existe -- nao faz sentido descontar nada dela
            table_num = table_num + 1
            total_weight = total_weight + 100
            score = score + cover_score * 100

            if dbg then
                dbg[#dbg + 1] = string.format("  last_known_enemy_pos: peso 100 (cheio)" ..
                                                  " | cobertura %d | c*w %d", cover_score,
                                              cover_score * 100)
            end
        elseif dbg then
            dbg[#dbg + 1] = "  last_known_enemy_pos: nao ha posicao conhecida"
        end
    end

    ---- Sigma w == 0: todo mundo visivel esta fora de alcance, ou nao e o tipo de
    ---- ameaca que cobertura resolve. Neutro -- a policy nao tem opiniao sobre este
    ---- tile, em vez de fingir que ele e ruim.
    if total_weight <= 0 then
        if dbg then
            dbg[#dbg + 1] = "  SOMA(w) = 0 -> ninguem que cobertura resolva alcanca este tile"
            dbg[#dbg + 1] = "  EvalDest 0"
            self:StoreDebug(context, dest, self:FormatDebugHeader(context, ustance) .. "\n" ..
                                table.concat(dbg, "\n"))
        end
        return 0
    end

    ---- media ponderada: "que fracao da ameaca apontada para mim eu neutralizo"
    local avg = MulDivRound(score, 1, total_weight)

    if dbg then
        dbg[#dbg + 1] = string.format("  SOMA(c*w) %d / SOMA(w) %d -> media %d", score,
                                      total_weight, avg)
    end

    ---------------------------------------------------------------------------------------
    ---- COBERTURA RELATIVA A AMEACA
    ----
    ---- A media acima e INTENSIVA: e uma razao, entao a escala dos pesos cancela. Um
    ---- inimigo sozinho a 99% do alcance dele (peso 12) com cobertura total devolve os
    ---- mesmos 100 de um inimigo colado (peso 100) com cobertura total. A Threat
    ---- Exposure, que soma os pesos em vez de fazer media, e EXTENSIVA e devolveria -4
    ---- e -33 nesses dois casos. Dai um tile distante marcar 100 de cobertura contra
    ---- -4 de exposicao: a distancia cancela numa policy e nao cancela na outra.
    ----
    ---- `presence` recoloca a escala: quanta ameaca existe aqui, 0..100, na MESMA
    ---- normalizacao da Threat Exposure. Multiplicar a media por ela transforma
    ----     SOMA(c_i * w_i) / SOMA(w_i)        (intensiva)
    ---- em
    ----     SOMA(c_i * w_i) / saturacao        (extensiva)
    ---- que e literalmente "quanta ameaca eu neutralizei", comparavel ponto a ponto com
    ---- o que a exposicao subtrai.
    ----
    ---- ThreatRelative interpola entre as duas leituras em vez de obrigar a escolher.
    ---------------------------------------------------------------------------------------
    local rel = Clamp(self.ThreatRelative or 0, 0, 100)
    if rel > 0 then
        local saturation = 100 * Max(1, RATOAI_ThreatSaturation)
        local presence = Clamp(MulDivRound(total_weight, 100, saturation), 0, 100)
        ---- rel=0 -> fator 100 (nada muda); rel=100 -> fator = presence
        local factor = (100 - rel) + MulDivRound(rel, presence, 100)
        avg = MulDivRound(avg, factor, 100)

        if dbg then
            dbg[#dbg + 1] = string.format("  presence = %d*100/%d = %d%s | ThreatRelative %d" ..
                                              " -> factor %d", total_weight, saturation, presence,
                                          (MulDivRound(total_weight, 100, saturation) > 100) and
                                              " (CLAMPADO)" or "", rel, factor)
        end
    elseif dbg then
        dbg[#dbg + 1] = "  ThreatRelative 0 -> cobertura ABSOLUTA, media entra crua"
    end

    if dbg then
        ---- o Weight nao e aplicado aqui: quem multiplica e o AIScoreDest. Mostrado para
        ---- o numero do overlay bater com a linha "Custom Seek Cover" do Voxel score.
        dbg[#dbg + 1] = string.format("  EvalDest %d  (x Weight %d%% = %d no AIScoreDest)", avg,
                                      self.Weight or 100, MulDivRound(avg, self.Weight or 100, 100))
        self:StoreDebug(context, dest,
                        self:FormatDebugHeader(context, ustance) .. "\n" .. table.concat(dbg, "\n"))
    end

    return avg
end

---- Cabecalho do overlay: os parametros que decidem como as linhas por inimigo se
---- combinam. Sem isto nao da para saber se a media veio ponderada ou nao.
function AIPolicyCustomSeekCover:FormatDebugHeader(context, ustance)
    return string.format("stance %s | BaseScore %d | ThreatRelative %d | ScalePerDistance %s" ..
                             " | saturacao %d | Weight %d | %d inimigos em context.enemies",
                         tostring(ustance), self.BaseScore or 0, self.ThreatRelative or 0,
                         self.ScalePerDistance and "on" or "OFF (todo peso = 100)",
                         100 * Max(1, RATOAI_ThreatSaturation), self.Weight or 100,
                         #(context.enemies or empty_table))
end

--- Not really used right now
function AIPolicyCustomSeekCover:SimpleGetCoverScore(context, cover_score, dest, grid_voxel, enemy)

    if not dest then
        return cover_score
    end

    ---- DESATIVADO. Este era o escalonamento por distancia antigo, e ele nao pode mais
    ---- rodar atras do `ScalePerDistance` agora que a flag mudou de significado (peso no
    ---- denominador) e passou a vir ligada por default -- senao a distancia entraria na
    ---- conta duas vezes. Ficam registrados os dois defeitos dele, para quem for
    ---- reativar o caminho SimpleGetCover algum dia:
    ----
    ----   1. `new_pos` era sobrescrito por `enemy_pos` na linha seguinte, entao o
    ----      `new_pos:Dist(enemy_pos)` media a distancia do inimigo ate ele mesmo -- 0
    ----      sempre. O `dist` caia no `min_dist` e o ratio era constante.
    ----   2. `range = max_range * const.Scale.AP` mistura escala de AP com escala de
    ----      distancia; o `dist` do outro lado esta em unidades de mundo.
    ----
    ---- Este caminho continua sem ponderacao: devolve peso 100 e entra na media como
    ---- todos os outros. E dormente (0 de 21 instancias ligam SimpleGetCover).
    ----
    -- local new_pos, dist
    -- if self.ScalePerDistance and cover_score > 0 then
    --     new_pos = RATOAI_UnpackPos(dest)
    --     new_pos = IsValidZ(new_pos) and new_pos or new_pos:SetTerrainZ()
    --     local enemy_pos = IsValid(enemy) and enemy:GetPos() or enemy
    --     new_pos = IsValidZ(enemy_pos) and enemy_pos or enemy_pos:SetTerrainZ()
    --     if enemy_pos then
    --         dist = Max(min_dist, new_pos:Dist(enemy_pos))
    --         local range = max_range * const.Scale.AP
    --         local ratio = 100 - MulDivRound(Min(range, dist), distance_impact, range)
    --         cover_score = MulDivRound(cover_score, ratio, 100)
    --     end
    -- end

    -- if self.ExposedAtCloseRange_Score ~= 0 and cover_score <= 0 and context.enemy_grid_voxel[enemy] and
    --    grid_voxel then
    --    local x1, y1, z1 = point_unpack(context.enemy_grid_voxel[enemy])
    --    local x2, y2, z2 = point_unpack(grid_voxel)
    --    if IsCloser(x1, y1, z1, x2, y2, z2, pb_range + 1) then
    --        cover_score = self.ExposedAtCloseRange_Score
    --    elseif IsCloser(x1, y1, z1, x2, y2, z2, pb_range * 2 + 1) then
    --        cover_score = MulDivRound(self.ExposedAtCloseRange_Score, close_range_mul_penalty_mul,
    --                                  100)
    --    elseif IsCloser(x1, y1, z1, x2, y2, z2, pb_range * 3 + 1) then
    --        cover_score = MulDivRound(self.ExposedAtCloseRange_Score, medium_range_penalty_mul, 100)
    --    end
    -- end

    -- if new_pos then
    --     DbgAddText(enemy.session_id .. " " .. cover_score, new_pos)
    -- end

    return cover_score
end

AIPolicyCustomSeekCover.CoverScores = {
    [const.CoverPass] = 0,
    [const.CoverNone] = 0,
    [const.CoverLow] = 50,
    [const.CoverHigh] = 100
}

---- `stance` e a postura que a unidade tera NESTE dest. Se quem chama nao passar, sai
---- do proprio dest; so cai no "Crouch" antigo se nao houver dest nenhum.
function AIPolicyCustomSeekCover:GetCoverScore(context, enemy, unit, dest, target_pos, grid_voxel,
                                               stance)
    local prone_cover_CTH = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover
    local cover_max_malus = prone_cover_CTH:ResolveValue("Cover")
    local valid_enemy = enemy and not (enemy:IsDead() or enemy:IsDowned())
    local score = not valid_enemy and self.BaseScore or 0

    ---- Peso deste inimigo na media (2o retorno). Com a rampa desligada todo mundo
    ---- pesa 100 e a media volta a ser a simples de antes.
    ---- Peso 0 = "cobertura nao responde a esta ameaca", e nao "esta ameaca e boa":
    ---- ele sai do denominador em vez de puxar a media pra cima.
    local ramp = self.ScalePerDistance
    local weight = ramp and 0 or 100

    ---- so para o overlay (RATOAI_SeekCoverDebug): alcance considerado e por que este
    ---- inimigo pesou o que pesou. Nao participa de conta nenhuma.
    local dbg_range
    local why = valid_enemy and "sem cobertura" or "abatido/morto"

    local target_pos = target_pos or dest and RATOAI_UnpackPos(dest) or unit:GetPos()
    local att_pos = enemy and enemy:GetPos()
    target_pos = RATOAI_ValidatePosZ(target_pos)
    att_pos = RATOAI_ValidatePosZ(att_pos)
    local dist = att_pos:Dist(target_pos)

    if valid_enemy and IsValidPos(target_pos) and IsValidPos(att_pos) then

        local distance_to_check_lack_of_cover = 30
        local weapon = enemy:GetActiveWeapons()
        local is_firearm = weapon and IsKindOf(weapon, "Firearm")

        distance_to_check_lack_of_cover = weapon and is_firearm and weapon.WeaponRange or
                                              distance_to_check_lack_of_cover

        local range = distance_to_check_lack_of_cover * const.SlabSizeX

        dbg_range = range

        if not is_firearm then
            ---- cobertura nao protege de corpo a corpo: peso 0, fica fora da media
            score = self.BaseScore
            why = "corpo a corpo -- cobertura nao se aplica"
        elseif dist <= range then
            if ramp then
                weight = RATOAI_ThreatRamp(dist, range)
            end

            if not stance and dest then
                local _, _, _, dest_stance_idx = stance_pos_unpack(dest)
                stance = StancesList[dest_stance_idx]
            end

            local use, value = RATOAI_CoverCTH(att_pos, target_pos, stance)
            value = value or 0
            if use then
                local ratio = Clamp(MulDivRound(value, 100, cover_max_malus), 0, 100)
                score = MulDivRound(self.BaseScore, ratio, 100)
                why = string.format("CTH %d/%d", value, cover_max_malus)
            else
                ---- InterpolateCoverEffect devolveu `exposed_value`: coberto de menos para
                ---- registrar. Nao e meia cobertura, e zero.
                why = "coberto de menos (coverage abaixo do minimo)"
            end

            ---- por ultimo: quem manda na linha do overlay e o motivo do PESO, nao o da
            ---- cobertura -- peso 0 tira o inimigo da media independente da cobertura
            if weight == 0 then
                why = "no limite do alcance (rampa = 0)"
            end
        else
            why = "fora de alcance"
        end
    end

    -- if self.ExposedAtCloseRange_Score ~= 0 and score <= 0 and dist then
    --    ---- BUGFIX (B7): era `* 0.5` e `* 0.1` (float).
    --    if dist <= pb_range then
    --        score = self.ExposedAtCloseRange_Score
    --    elseif dist <= pb_range * 2 then
    --        score = MulDivRound(self.ExposedAtCloseRange_Score, close_range_mul_penalty_mul, 100)
    --    elseif dist <= pb_range * 3 then
    --        score = MulDivRound(self.ExposedAtCloseRange_Score, medium_range_penalty_mul, 100)
    --    end
    --    if score < 0 then
    --        why = "exposto a curta distancia"
    --    end
    -- end

    return score, weight, dist, dbg_range, why
end

---- `target_stance` e a postura de QUEM SE PROTEGE (o 3o parametro de
---- GetCoverPercentage, Cover.lua:281). O unico efeito dele la dentro e:
----     if cover == coverLow and target_stance == "Standing" then cover = false end
---- ou seja, Crouch e Prone sao equivalentes; so "Standing" muda alguma coisa, e muda
---- so em cobertura BAIXA. Default "Crouch" mantem o comportamento antigo para quem
---- chamar sem informar a postura.
function RATOAI_CoverCTH(attacker_pos, target_pos, target_stance)
    local prone_cover_CTH = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover
    local exposed_value = prone_cover_CTH:ResolveValue("ExposedCover")
    local full_value = prone_cover_CTH:ResolveValue("Cover")

    local cover, any, coverage = GetCoverPercentage(target_pos, attacker_pos,
                                                    target_stance or "Crouch")

    -- if CheckSightCondition(attacker, target, const.usObscured) then
    -- 	exposed_value = exposed_value + const.EnvEffects.DustStormCoverCTHPenalty
    -- 	full_value = full_value + const.EnvEffects.DustStormCoverCTHPenalty
    -- end

    local value = InterpolateCoverEffect(coverage, full_value, exposed_value)
    local metaText = false

    if value < exposed_value then
        return true, value
    end
    return false, 0
end
--[[function AIPolicyCustomSeekCover:EvalDest(context, dest, grid_voxel)
    local score = 0

    local ux, uy, uz, ustance_idx = stance_pos_unpack(dest)

    local tbl = context.enemies or empty_table

    ---
    local denominador = 0
    local total_score = 0
    ---
    for _, enemy in ipairs(tbl) do
        local visible = true
        if self.visibility_mode == "self" then
            visible = context.enemy_visible[enemy]
        elseif self.visibility_mode == "team" then
            visible = context.enemy_visible_by_team[enemy]
        end

        if visible then

            local cover = GetCoverFrom(dest, context.enemy_pack_pos_stance[enemy])
            local cover_score = self.CoverScores[cover] or 0

            -------------
            total_score = total_score + cover_score
            denominador = denominador + 1

            local cover_score1 = cover_score
            if self.ScalePerDistance and cover_score > 0 then
                local ux, uy, uz, ustance_idx = stance_pos_unpack(dest)
                local new_pos = point(ux, uy, uz)

                local dist = new_pos:Dist(enemy:GetPos())
                local range = max_range * const.Scale.AP
                local ratio = 100 - ((Min(range, dist) * 1.00) / (range * 1.00)) *
                                  (100 * distance_impact)

                cover_score = MulDivRound(cover_score, ratio, 100)
                print(enemy.session_id, dist / const.SlabSizeX, cover_score1, cover_score, ratio)

            end

            -------------
            score = score + cover_score

        end
    end

    local score_ratio = 0
    if total_score > 0 then
        total_score = total_score / Max(1, denominador)
        -- score = score / Max(1, denominador)

        local ux, uy, uz, ustance_idx = stance_pos_unpack(dest)
        local new_pos = point(ux, uy, uz)

        score_ratio = ((score * 1.00) / (total_score * 1.00)) * 100
        DbgAddText(total_score .. " / " .. score .. " = " .. score_ratio, new_pos)
    end

    local final_score = MulDivRound(self.Score, score_ratio, 100)
    ic(total_score, score, final_score)
    return score / Max(1, #tbl)
end]]
