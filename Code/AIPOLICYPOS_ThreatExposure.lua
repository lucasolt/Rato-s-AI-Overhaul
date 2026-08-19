---------------------------------------------------------------------------------------------------
---- AIPolicyThreatExposure
----
---- Responde UMA pergunta: "quanta ameaca alcanca este tile?"
----
---- Existe porque a AIPolicyCustomSeekCover respondia duas perguntas ao mesmo tempo, e
---- mal. La, inimigos fora de alcance entravam no denominador valendo zero, entao um
---- tile com cobertura perfeita contra o unico inimigo que o alcanca pontuava 100/4 se
---- houvesse mais tres inimigos longe. Isso NAO era uma medida de ameaca -- era uma
---- diluicao acidental -- mas era a unica coisa no mod que penalizava "muita gente me
---- vendo" (o AIPolicyDontBeExposedAtCloserRange esta inteiro comentado e o
---- AvoidThreatenedAreas nao aparece no items.lua).
----
---- Ao tornar a Seek Cover uma media ponderada de verdade, aquela diluicao sumiu. Este
---- arquivo devolve o sinal, agora separado e com peso proprio por archetype:
----
----   Seek Cover        -> "quao bem coberto eu estou contra quem me alcanca"  [Exposed, Base]
----   Threat Exposure   -> "quanta gente me alcanca"                           [Penalty, 0]
----
---- Usa RATOAI_ThreatRamp (definida em AIPOLICYPOS_CustomSeekCover.lua) -- a MESMA
---- rampa da Seek Cover, de proposito: as duas nao podem divergir de nocao de alcance.
----
---- NAO esta ligada em nenhum archetype. Adicione onde quiser em items.lua.
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyThreatExposure = {
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
            id = "Penalty",
            name = "Penalidade (saturada)",
            help = "Score quando a ameaca atinge MaxThreat. O retorno vive em [Penalty, 0].",
            editor = "number",
            default = -100
        }, {
            id = "MaxThreat",
            name = "Ameaca de saturacao",
            help = "Quantos inimigos colados equivalem a penalidade cheia. 3 = tres inimigos " ..
                "a queima-roupa, ou seis a meio alcance.\n" ..
                "0 = usar a constante compartilhada RATOAI_ThreatSaturation (recomendado). " ..
                "Um valor proprio aqui SO faz sentido se a Seek Cover deste archetype " ..
                "estiver com ThreatRelative = 0; caso contrario as duas normalizam " ..
                "diferente e o cancelamento entre cobertura e exposicao quebra sem aviso.",
            editor = "number",
            default = 0,
            min = 0,
            max = 20
        }, {
            id = "MeleeRange",
            name = "Alcance corpo a corpo (tiles)",
            help = "Alcance usado para inimigos sem arma de fogo.",
            editor = "number",
            default = 5,
            min = 1,
            max = 30
        }, {
            id = "RequireLOS",
            name = "Ignorar tiles que ninguem enxerga",
            help = "Zera a ameaca quando o cache de LOS do motor diz que NENHUM inimigo " ..
                "ve este destino. O cache e agregado por destino (booleano \"alguem ve\"), " ..
                "nao por inimigo -- entao e um portao do tile inteiro, nao um peso por " ..
                "inimigo. Custo: uma consulta de tabela, zero raycast novo.",
            editor = "bool",
            default = true
        }
    }
}

function AIPolicyThreatExposure:GetEditorView()
    return "Threat Exposure"
end

---- Saturacao efetiva. MaxThreat = 0 (default) usa a constante compartilhada, que e o
---- que mantem esta policy e a Seek Cover na MESMA normalizacao -- pre-requisito para o
---- cancelamento entre cobertura e exposicao. Ver o cabecalho de RATOAI_ThreatSaturation
---- em AIPOLICYPOS_CustomSeekCover.lua.
function AIPolicyThreatExposure:GetSaturation()
    local n = self.MaxThreat
    if not n or n <= 0 then
        n = rawget(_G, "RATOAI_ThreatSaturation") or 3
    end
    return 100 * Max(1, n)
end

---- alcance do inimigo, em unidades de mundo
---- Referencia: AK47 = 24 tiles, rifles 30, snipers 36-45, SMG 14-18, escopeta 8.
---- O `or 0` ingenuo aqui era uma armadilha: WeaponRange nulo ou zero viraria alcance 0,
---- a rampa devolveria 0 e o inimigo sumiria da conta de ameaca sem aviso nenhum.
function AIPolicyThreatExposure:GetEnemyRange(enemy)
    local melee = self.MeleeRange * const.SlabSizeX
    local weapon = enemy:GetActiveWeapons()
    if weapon and IsKindOf(weapon, "Firearm") then
        local range = (weapon.WeaponRange or 0) * const.SlabSizeX
        return range > 0 and range or melee
    end
    return melee
end

---------------------------------------------------------------------------------------------------
---- DIAGNOSTICO
----
---- `RATOAI_ThreatDebug = true` no console faz cada destino guardar o passo a passo em
---- context.dest_threat_exposure_debug[dest], que o DEBUG.lua mostra no rollover do
---- voxel. Desligado, custa uma leitura de global por destino e nada mais.
---- Ligue, passe o mouse no tile, leia, desligue -- constroi string para TODO destino.
---------------------------------------------------------------------------------------------------
if rawget(_G, "RATOAI_ThreatDebug") == nil then
    RATOAI_ThreatDebug = false
end

local function tiles(d)
    return d and (MulDivRound(d, 1, const.SlabSizeX)) or "?"
end

function AIPolicyThreatExposure:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end

    local dbg = RATOAI_ThreatDebug and {} or nil

    ---- Portao de LOS. Distingue `false` (o motor CHECOU e ninguem ve) de `nil` (nunca
    ---- checou -- destino fora de all_destinations). Tratar nil como "sem LOS" zeraria
    ---- silenciosamente tiles que so nao entraram na batelada do AIUpdateDestLosCache,
    ---- entao nil segue contando ameaca normalmente.
    if self.RequireLOS and g_AIDestEnemyLOSCache and g_AIDestEnemyLOSCache[dest] == false then
        return 0
    end

    local target_pos = RATOAI_ValidatePosZ(RATOAI_UnpackPos(dest))
    if not IsValidPos(target_pos) then
        return 0
    end

    local threat = 0

    for _, enemy in ipairs(context.enemies or empty_table) do
        local visible = true
        if self.visibility_mode == "self" then
            visible = context.enemy_visible[enemy]
        elseif self.visibility_mode == "team" then
            visible = context.enemy_visible_by_team[enemy]
        end

        ---- mesmo criterio de "nao ameaca" da Seek Cover: abatido e morto ficam fora
        local alive = enemy and not (enemy:IsDead() or enemy:IsDowned())
        if visible and alive then
            local att_pos = RATOAI_ValidatePosZ(enemy:GetPos())
            if IsValidPos(att_pos) then
                local d = att_pos:Dist(target_pos)
                local range = self:GetEnemyRange(enemy)
                local ramp = RATOAI_ThreatRamp(d, range)
                threat = threat + ramp

                if dbg then
                    dbg[#dbg + 1] = string.format("  %s: %st / alcance %st -> peso %d",
                                                  tostring(enemy.session_id), tostring(tiles(d)),
                                                  tostring(tiles(range)), ramp)
                end
            elseif dbg then
                dbg[#dbg + 1] = string.format("  %s: PULADO (posicao invalida)",
                                              tostring(enemy.session_id))
            end
        elseif dbg then
            dbg[#dbg + 1] = string.format("  %s: PULADO (%s)", tostring(enemy.session_id),
                                          not alive and "abatido/morto" or
                                              ("nao visivel, modo " .. tostring(self.visibility_mode)))
        end
    end

    if dbg then
        local saturation = self:GetSaturation()
        local head = string.format("inimigos em context.enemies: %d | saturacao %d %s " ..
                                       "| Penalty %d | Weight %d",
                                   #(context.enemies or empty_table), saturation,
                                   (not self.MaxThreat or self.MaxThreat <= 0) and "(compartilhada)" or
                                       "(MaxThreat proprio)", self.Penalty, self.Weight or 100)
        local tail = string.format("  SOMA %d / %d -> EvalDest %d", threat, saturation,
                                   threat > 0 and
                                       MulDivRound(self.Penalty, Min(threat, saturation), saturation) or
                                       0)
        context.dest_threat_exposure_debug = context.dest_threat_exposure_debug or {}
        context.dest_threat_exposure_debug[dest] = head .. "\n" .. table.concat(dbg, "\n") .. "\n" ..
                                                       tail
    end

    if threat <= 0 then
        return 0
    end

    ---- normaliza: saturacao inimigos com peso 100 == penalidade cheia. Sem o teto o
    ---- score cresceria com o numero de inimigos e esmagaria as outras policies -- que
    ---- e exatamente o erro que o ScalePerDistance antigo cometia.
    local saturation = self:GetSaturation()
    return MulDivRound(self.Penalty, Min(threat, saturation), saturation)
end
