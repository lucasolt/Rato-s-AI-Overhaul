---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata (o CONSTANTS_AI_source ja a cria, mas nao dependemos disso).
const.RATOAI = const.RATOAI or {}

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
            default = "self",
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
                "0 = usar a constante compartilhada const.RATOAI.ThreatSaturation (recomendado). " ..
                "Um valor proprio aqui SO faz sentido se a Seek Cover deste archetype " ..
                "estiver com ThreatRelative = 0; caso contrario as duas normalizam " ..
                "diferente e o cancelamento entre cobertura e exposicao quebra sem aviso.",
            editor = "number",
            default = 0,
            min = 0,
            max = 20
        }, {
            ---------------------------------------------------------------------------
            ---- O CANCELADOR
            ----
            ---- Liga o modo em que a cobertura cancela a ameaca DENTRO desta policy, em
            ---- vez de a AIPolicyCustomSeekCover creditar cobertura por fora.
            ----
            ---- Existe porque as duas policies separadas se DESSINCRONIZAM no clamp. Com
            ---- a soma acima da saturacao, a ameaca trava em `Penalty` e a cobertura NAO
            ---- trava junto: o inimigo extra nao consegue mais aumentar a punicao (ja
            ---- esta no teto) mas continua entrando no numerador da media de cobertura.
            ---- Resultado medido: um tile exposto ao IMP marcava -100, e o MESMO tile
            ---- exposto ao IMP com um Igor coberto por perto marcava -51. Um inimigo a
            ---- mais apontando uma arma MELHORAVA a nota do tile em 49 pontos.
            ----
            ---- Aqui cada inimigo entra com `rampa x (100 - cobertura)`, que e sempre
            ---- >= 0, e o clamp cai sobre a SOMA. Com isso:
            ----   * monotonico -- inimigo do qual estou coberto contribui exatamente 0,
            ----     nunca credito; nao existe mais o caso perverso;
            ----   * "1 ou 1000 da no mesmo" sai de graca, porque o clamp agora esta em
            ----     cima de uma soma monotona: 3 colados expostos saturam igual a 1;
            ----   * o gradiente de distancia continua, porque a rampa continua.
            ----
            ---- ATENCAO: ligando isto, a AIPolicyCustomSeekCover do MESMO grupo de
            ---- policies vira contagem dobrada. Tire ela da lista (ou zere o Weight).
            ---- A Seek Cover continua util sozinha em listas sem esta policy.
            ---------------------------------------------------------------------------
            id = "CoverCancels",
            name = "Cobertura cancela a ameaca (aqui dentro)",
            help = "Cada inimigo entra com rampa x (100 - cobertura). Cobertura total " ..
                "contra ele zera a contribuicao dele.\n" ..
                "LIGANDO ISTO, remova a AIPolicyCustomSeekCover desta mesma lista -- " ..
                "senao a cobertura conta duas vezes.",
            editor = "bool",
            default = true
        }, {
            ---- Vies de risco. Diferente do `Penalty` e do `Weight`, que escalam o sinal
            ---- inteiro e nao mudam onde ele cruza o zero: com 100 aqui, cobertura total
            ---- zera a ameaca exatamente; com 70, cobertura total ainda deixa 30% da
            ---- ameaca de pe. E o botao de "quanto eu confio em cobertura", que e o mesmo
            ---- que "quanto eu prefiro sobreviver a avancar".
            id = "CoverTrust",
            name = "Confianca na cobertura (%)",
            help = "So com `CoverCancels` ligado. 100 = cobertura total cancela a ameaca " ..
                "por inteiro (agressiva). Abaixo disso sobra ameaca mesmo coberta, e a " ..
                "IA fica mais cautelosa. 0 = cobertura nao vale nada.",
            editor = "number",
            default = 90,
            min = 0,
            max = 100
        }, {
            ---------------------------------------------------------------------------
            ---- RAIO DE EXCLUSAO DA COBERTURA
            ----
            ---- A cobertura e medida contra a posicao ATUAL do inimigo: RATOAI_CoverCTH
            ---- chama GetCoverPercentage(target_pos, attacker_pos, ...). Quanto mais
            ---- perto ele esta, mais barato e para ele mudar essa posicao -- 2 ou 3
            ---- tiles custam 1-2 AP, e a cobertura que estamos creditando deixa de
            ---- existir ANTES do tiro. A 20 tiles ele nao contorna nada no mesmo turno.
            ---- Ou seja: nao e a cobertura que vale menos de perto, e a MEDICAO que e
            ---- volatil de perto. Este parametro cobra esse risco.
            ----
            ---- ATENCAO -- isto NAO espelha a mecanica do jogo, ao contrario do
            ---- PlateauTiles. O RangeAttackTargetStanceCover
            ---- (Data/ChanceToHitModifier.lua:580-606) nao tem termo de distancia
            ---- nenhum: cobertura vale os mesmos -20 de CTH a 1 tile e a 30. Isto e
            ---- vies de risco da IA, deliberado, nao correcao de conta. Deixe em 0 se
            ---- quiser a leitura crua do jogo.
            ----
            ---- 0 = desligado (default -- nao mexe em nenhum archetype ja calibrado).
            ---- Referencia natural: const.Weapons.PointBlankRange, que o GBO3 sobe de 4
            ---- para 6 tiles (Rato-s-Gameplay-Balance-and-Overhaul-3/Code/__MainParams.lua:62).
            ---- 2-3 tiles e o ajuste conservador: pega so quem contorna a cobertura com 1 AP.
            ---------------------------------------------------------------------------
            id = "CoverNearTiles",
            name = "Raio de exclusao da cobertura (tiles)",
            help = "Abaixo desta distancia a confianca na cobertura cai de CoverTrust " ..
                "ate CoverTrustNear, linearmente, chegando em CoverTrustNear com o " ..
                "inimigo colado.\n" .. "0 = desligado: cobertura vale igual a qualquer distancia.\n" ..
                "So tem efeito com `CoverCancels` ligado.",
            editor = "number",
            default = 12,
            min = 0,
            max = 30
        }, {
            ---- O piso da rampa acima. Separado do CoverTrust de proposito: um controla
            ---- "quanto eu confio em cobertura", o outro "quanto eu desconfio dela com
            ---- o cara no meu colo". Sao dois botoes independentes.
            id = "CoverTrustNear",
            name = "Confianca na cobertura colado (%)",
            help = "Confianca aplicada com o inimigo a distancia 0. Interpola " ..
                "linearmente ate CoverTrust em CoverNearTiles tiles.\n" ..
                "0 = colado, cobertura nao vale nada -- o inimigo entra com a ameaca " ..
                "cheia, como se fosse corpo a corpo.\n" .. "So tem efeito com CoverNearTiles > 0.",
            editor = "number",
            default = 40,
            min = 0,
            max = 100
        }, {
            ---- Ver o cabecalho de RATOAI_ThreatRamp em AIPOLICYPOS_CustomSeekCover.lua
            ---- para o porque. Resumo: a rampa linear a partir do zero contradiz a curva
            ---- de precisao do jogo em toda a primeira metade do alcance.
            id = "PlateauTiles",
            name = "Plato da rampa (tiles)",
            help = "Distancia ate onde o inimigo pesa 100 antes de a rampa comecar a " ..
                "cair. 0 = rampa linear desde o tile colado (comportamento antigo).\n" ..
                "const.Weapons.PointBlankRange = 6 tiles -- e a faixa onde automatica e " ..
                "letal por recoil e proximidade, independente de precisao.\n" ..
                "Cuidado: plato maior infla o SOMA(w) e satura mais cedo; se subir muito " ..
                "aqui, suba a saturacao junto.",
            editor = "number",
            default = 4,
            min = 0,
            max = 30
        }, {
            ---------------------------------------------------------------------------
            ---- TETO DE ALCANCE
            ----
            ---- Corta o alcance que ENTRA na rampa: com teto 20, um sniper de 36 tiles
            ---- e tratado como se tivesse 20 -- pesa 100 no plato, cai ate 0 em 20, e
            ---- alem de 20 nao conta mais. Um SMG de 16 nao muda nada, porque ja esta
            ---- abaixo do teto.
            ----
            ---- Note que isto NAO so remove o inimigo distante: ele passa a cair mais
            ---- RAPIDO em toda a faixa, porque a rampa inteira e reescalada para o teto.
            ---- Se a intencao for so afundar a cauda longa e manter o gradiente de
            ---- perto, use `FalloffCurve` -- os dois sao knobs diferentes.
            ----
            ---- Isto e vies de risco, nao mecanica do jogo: o sniper de 36 tiles acerta
            ---- de 30 tiles tanto quanto antes. E a forma de dizer "so me preocupo com
            ---- quem esta perto de mim AGORA".
            ----
            ---- ATENCAO: se a AIPolicyCustomSeekCover estiver na MESMA lista (ou seja,
            ---- `CoverCancels` desligado aqui), ela continua com o alcance cheio e as
            ---- duas passam a discordar de quem ameaca o tile. Com CoverCancels ligado
            ---- (default) a Seek Cover ja deve estar fora da lista e nao ha conflito.
            ---------------------------------------------------------------------------
            id = "RangeCapTiles",
            name = "Teto de alcance considerado (tiles)",
            help = "Alcance maximo que qualquer inimigo pode ter aos olhos desta " ..
                "policy. Quem tem arma mais longa e tratado como se tivesse este " ..
                "alcance; alem dele, nao conta.\n" ..
                "0 = desligado (default): vale o WeaponRange de cada arma.",
            editor = "number",
            default = 0,
            min = 0,
            max = 60
        }, {
            ---------------------------------------------------------------------------
            ---- CURVATURA DA QUEDA
            ----
            ---- Suavizacao de cauda longa sem cortar ninguem: mantem 100 no plato e 0 no
            ---- alcance, e afunda o meio. Com 100 (quadratica pura) o inimigo a meio
            ---- alcance pesa 25 em vez de 50, e a 3/4 do alcance pesa 6 em vez de 25.
            ----
            ---- Preferivel ao `RangeCapTiles` quando a queixa e "inimigo longe pesa
            ---- demais" mas voce nao quer um ponto de corte duro nem reescalar a rampa
            ---- de quem esta perto: aqui o gradiente proximo fica quase intacto.
            ---- Os dois se somam se voce ligar ambos.
            ---------------------------------------------------------------------------
            id = "FalloffCurve",
            name = "Curvatura da queda (%)",
            help = "0 = queda linear do plato ate o alcance (default). " ..
                "100 = quadratica: a cauda longa vira quase nada e a ameaca se " ..
                "concentra em quem esta perto. Valores no meio interpolam.\n" ..
                "Nao muda o peso no plato (100) nem no limite do alcance (0).",
            editor = "number",
            default = 0,
            min = 0,
            max = 100
        }, {
            id = "MeleeRange",
            name = "Alcance corpo a corpo (tiles)",
            help = "Alcance usado para inimigos sem arma de fogo.",
            editor = "number",
            default = 8,
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

---- O rotulo NAO e cosmetico: `AIScoreDest` grava `policy:GetEditorView()` no
---- `score_details`, e a camada por policy do painel de debug SOMA entradas com o mesmo
---- rotulo. Duas instancias com alcances diferentes precisam de rotulos diferentes.
function AIPolicyThreatExposure:GetEditorView()
    local partes = {}
    if (self.RangeCapTiles or 0) > 0 then
        partes[#partes + 1] = string.format("teto %dt", self.RangeCapTiles)
    end
    if (self.FalloffCurve or 0) > 0 then
        partes[#partes + 1] = string.format("curva %d%%", self.FalloffCurve)
    end
    if #partes == 0 then
        return "Threat Exposure"
    end
    return "Threat Exposure (" .. table.concat(partes, ", ") .. ")"
end

---- Saturacao efetiva. MaxThreat = 0 (default) usa a constante compartilhada, que e o
---- que mantem esta policy e a Seek Cover na MESMA normalizacao -- pre-requisito para o
---- cancelamento entre cobertura e exposicao. Ver o cabecalho de const.RATOAI.ThreatSaturation
---- em AIPOLICYPOS_CustomSeekCover.lua.
function AIPolicyThreatExposure:GetSaturation()
    local n = self.MaxThreat
    if not n or n <= 0 then
        n = const.RATOAI.ThreatSaturation or 3
    end
    return 100 * Max(1, n)
end

---- alcance do inimigo, em unidades de mundo
---- Referencia: AK47 = 24 tiles, rifles 30, snipers 36-45, SMG 14-18, escopeta 8.
---- O `or 0` ingenuo aqui era uma armadilha: WeaponRange nulo ou zero viraria alcance 0,
---- a rampa devolveria 0 e o inimigo sumiria da conta de ameaca sem aviso nenhum.
---- 2o retorno: se e arma de fogo. Quem cancela ameaca com cobertura precisa saber --
---- cobertura nao protege de corpo a corpo, entao o cancelamento nao pode valer para
---- quem vem no facao. Mesmo criterio que a AIPolicyCustomSeekCover usa para tirar
---- melee da media dela.
---- 3o retorno: se o teto mordeu. So serve ao overlay -- sem ele nao da para saber se
---- o "alcance" mostrado e o da arma ou o teto da policy.
function AIPolicyThreatExposure:GetEnemyRange(enemy)
    local melee = self.MeleeRange * const.SlabSizeX
    local range, is_firearm = melee, false
    local weapon = enemy:GetActiveWeapons()
    if weapon and IsKindOf(weapon, "Firearm") then
        local r = (weapon.WeaponRange or 0) * const.SlabSizeX
        range, is_firearm = r > 0 and r or melee, true
    end
    ---- teto: reescala a rampa inteira, nao so corta a ponta. Vale tambem para melee --
    ---- um teto menor que MeleeRange encolhe o alcance do facao junto, que e o que
    ---- "nada alem de X tiles me ameaca" quer dizer.
    local cap = (self.RangeCapTiles or 0) * const.SlabSizeX
    if cap > 0 and range > cap then
        return cap, is_firearm, true
    end
    return range, is_firearm
end

---- Confianca efetiva na cobertura contra UM inimigo, 0..100.
---- Sem CoverNearTiles e o CoverTrust cru, exatamente como sempre foi -- por isso o
---- default 0 nao muda nenhum preset existente. Com ele, interpola linearmente de
---- CoverTrustNear (colado) ate CoverTrust (em CoverNearTiles ou mais longe).
---- Ver o cabecalho da property CoverNearTiles para o porque.
function AIPolicyThreatExposure:GetCoverTrust(dist)
    local trust = Clamp(self.CoverTrust or 100, 0, 100)
    local near = (self.CoverNearTiles or 0) * const.SlabSizeX
    if near <= 0 or not dist or dist >= near then
        return trust
    end
    local near_trust = Clamp(self.CoverTrustNear or 0, 0, 100)
    ---- (trust - near_trust) pode ser negativo se alguem inverter os dois no editor;
    ---- o Clamp final segura isso sem virar buraco silencioso.
    return Clamp(near_trust + MulDivRound(trust - near_trust, dist, near), 0, 100)
end

---- Fracao da ameaca deste inimigo que a cobertura NAO neutraliza, 0..100.
---- Usa RATOAI_CoverCTH -- a mesma funcao da AIPolicyCustomSeekCover, de proposito: as
---- duas nao podem divergir na leitura de cobertura, e esta e a unica forma de garantir
---- isso sem duplicar a conta.
---- 2o retorno: a confianca efetiva usada. So serve ao overlay -- sem ela nao da para
---- distinguir "nao ha cobertura neste tile" de "ha, mas o cara esta colado". Vem nil
---- nos casos em que cobertura nem chegou a ser consultada.
function AIPolicyThreatExposure:GetUncovered(att_pos, target_pos, stance, is_firearm, dist)
    ---- cobertura nao para corpo a corpo: ameaca inteira, sem desconto
    if not is_firearm then
        return 100
    end
    local use, value = RATOAI_CoverCTH(att_pos, target_pos, stance)
    if not use then
        return 100
    end
    local full = Presets.ChanceToHitModifier.Default.RangeAttackTargetStanceCover:ResolveValue(
                     "Cover")
    if not full or full == 0 then
        return 100
    end
    ---- `dist` chega pronto do EvalDest (ja calculado la); o fallback existe so para
    ---- quem chamar este metodo de fora, e nao paga Dist() no caminho quente.
    local trust = self:GetCoverTrust(dist or att_pos:Dist(target_pos))
    local cover = Clamp(MulDivRound(value or 0, 100, full), 0, 100)
    cover = MulDivRound(cover, trust, 100)
    return 100 - cover, trust
end

---------------------------------------------------------------------------------------------------
---- DIAGNOSTICO
----
---- `const.RATOAI.ThreatDebug = true` no console faz cada destino guardar o passo a passo em
---- context.dest_threat_exposure_debug[dest], que o DEBUG.lua mostra no rollover do
---- voxel. Desligado, custa uma leitura de global por destino e nada mais.
---- Ligue, passe o mouse no tile, leia, desligue -- constroi string para TODO destino.
---------------------------------------------------------------------------------------------------
if const.RATOAI.ThreatDebug == nil then
    const.RATOAI.ThreatDebug = false
end

local function tiles(d)
    return d and (MulDivRound(d, 1, const.SlabSizeX)) or "?"
end

function AIPolicyThreatExposure:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end

    local dbg = const.RATOAI.ThreatDebug and {} or nil

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

    ---- STANCE do proprio dest: e a que a unidade adota ao chegar (AIBehavior:EndMovement).
    ---- So importa quando a cobertura entra na conta -- GetCoverPercentage zera cobertura
    ---- BAIXA para quem esta de pe (Cover.lua:283).
    local cancels = self.CoverCancels
    local stance
    if cancels then
        local _, _, _, stance_idx = stance_pos_unpack(dest)
        stance = StancesList[stance_idx]
    end
    local plateau = (self.PlateauTiles or 0) * const.SlabSizeX
    local near = (self.CoverNearTiles or 0) * const.SlabSizeX
    local curve = Clamp(self.FalloffCurve or 0, 0, 100)

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
                local range, is_firearm, capped = self:GetEnemyRange(enemy)
                local ramp = RATOAI_ThreatRamp(d, range, plateau, curve)

                ---- `uncovered` e 100 no modo classico: a policy nao olha cobertura e a
                ---- contribuicao e a rampa crua, exatamente como antes.
                local uncovered, trust = 100, nil
                if cancels and ramp > 0 then
                    uncovered, trust = self:GetUncovered(att_pos, target_pos, stance, is_firearm, d)
                end
                local contrib = (uncovered == 100) and ramp or MulDivRound(ramp, uncovered, 100)
                threat = threat + contrib

                if dbg then
                    if cancels then
                        ---- so anota quando o raio realmente mordeu -- senao poluiria
                        ---- toda linha do overlay com um numero que nunca muda
                        local near_note = ""
                        if trust and near > 0 and d < near then
                            near_note = string.format(" | COLADO: confianca %d%%", trust)
                        end
                        dbg[#dbg + 1] = string.format(
                                            "  %s: %st / alcance %st%s -> peso %d" ..
                                                " | exposto %d%% -> contribui %d%s",
                                            tostring(enemy.session_id), tostring(tiles(d)),
                                            tostring(tiles(range)), capped and " (teto)" or "",
                                            ramp, uncovered, contrib, near_note)
                    else
                        dbg[#dbg + 1] = string.format("  %s: %st / alcance %st%s -> peso %d",
                                                      tostring(enemy.session_id),
                                                      tostring(tiles(d)), tostring(tiles(range)),
                                                      capped and " (teto)" or "", ramp)
                    end
                end
            elseif dbg then
                dbg[#dbg + 1] = string.format("  %s: PULADO (posicao invalida)",
                                              tostring(enemy.session_id))
            end
        elseif dbg then
            dbg[#dbg + 1] = string.format("  %s: PULADO (%s)", tostring(enemy.session_id),
                                          not alive and "abatido/morto" or
                                              ("nao visivel, modo " ..
                                                  tostring(self.visibility_mode)))
        end
    end

    if dbg then
        local saturation = self:GetSaturation()
        local head = string.format("inimigos em context.enemies: %d | saturacao %d %s " ..
                                       "| Penalty %d | Weight %d\n" ..
                                       "modo: %s | plato %st | stance %s",
                                   #(context.enemies or empty_table), saturation,
                                   (not self.MaxThreat or self.MaxThreat <= 0) and "(compartilhada)" or
                                       "(MaxThreat proprio)", self.Penalty, self.Weight or 100,
                                   cancels and
                                       string.format("cobertura CANCELA (confianca %d%%%s)",
                                                     Clamp(self.CoverTrust or 100, 0, 100),
                                                     (near > 0) and
                                                         string.format(
                                                             ", caindo a %d%% dentro de %st",
                                                             Clamp(self.CoverTrustNear or 0, 0, 100),
                                                             tostring(tiles(near))) or "") or
                                       "classico (so ameaca)", tostring(tiles(plateau)) ..
                                       ((self.RangeCapTiles or 0) > 0 and
                                           string.format(" | teto %dt", self.RangeCapTiles) or "") ..
                                       (curve > 0 and string.format(" | curva %d%%", curve) or ""),
                                   tostring(stance or "-"))
        local tail = string.format("  SOMA %d / %d -> EvalDest %d", threat, saturation,
                                   threat > 0 and
                                       MulDivRound(self.Penalty, Min(threat, saturation), saturation) or
                                       0)
        context.dest_threat_exposure_debug = context.dest_threat_exposure_debug or {}
        context.dest_threat_exposure_debug[dest] =
            head .. "\n" .. table.concat(dbg, "\n") .. "\n" .. tail
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
