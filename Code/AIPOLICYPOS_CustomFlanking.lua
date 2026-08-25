---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata.
const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- AIPolicyCustomFlanking
----
---- Responde UMA pergunta: "quanto da cobertura do ALVO este destino tira, comparado
---- com a posicao onde estou agora?"
----
---- O score e a diferenca, em PERCENTUAL de cobertura cheia:
----
----     score = cobertura_do_alvo_daqui - cobertura_do_alvo_dali        [-100, +100]
----
---- +100 = o alvo esta totalmente protegido de mim agora e fica totalmente exposto la.
---- 0    = mesma protecao nos dois lugares (andar nao muda nada).
---- <0   = o destino PIORA (o alvo ganha cobertura contra mim) -- so pontua com
----        `PenalizeWorse`, ver a property.
----
---- Sem LOS conta como cobertura total, dos dois lados. E a mesma convencao de antes:
---- "nao consigo atirar nele" e o extremo de "ele esta protegido de mim".
----
---- ------------------------------------------------------------------------------------
---- O QUE MUDOU  --  BUGFIX (B39) + PERF (C14)
----
---- B39.1 -- O GRADIENTE ERA JOGADO FORA. A versao antiga so pontuava numa VIRADA
----   binaria de `in_cover`:
----       if  new.in_cover and not cur.in_cover then delta = delta + w
----       elseif not new.in_cover and cur.in_cover then delta = delta + w
----   Os dois ramos somavam a MESMA expressao (o sinal ja vinha dentro de `w`), entao o
----   if/elseif nao discriminava nada -- so FILTRAVA o caso em que os dois lados estao
----   cobertos. Resultado: cobertura alta -> cobertura baixa, que e metade da protecao
----   do alvo arrancada e um flanco perfeitamente legitimo, pontuava ZERO. So a virada
----   completa (coberto -> exposto) contava. Era a causa do "as vezes ela nao faz nada".
----   Agora a conta e o delta continuo, que e o dado que sempre esteve la nas duas
----   pontas -- nao ha caso especial novo, ha o insumo de volta.
----
---- B39.2 -- ASSIMETRIA ENTRE `0` E `nil`. No destino, alvo sem cobertura deixa a
----   entrada NIL (FUNCTION_ScoreAttacksDetailed.lua:271-276 nao tem `else`). Na posicao
----   atual, alvo sem cobertura grava `0` EXPLICITO (SOURCE_AICreateContext.lua:218). O
----   teste antigo era `if cover_data[enemy] then` -- e `0` e truthy em Lua. Ou seja, um
----   inimigo totalmente exposto na minha cara era lido como "coberto" na origem e
----   "descoberto" no destino. O caso "mover para um tile onde o alvo GANHA cobertura
----   contra mim" nunca disparava ramo nenhum: a metade da PUNICAO estava morta.
----   Aqui o teste e `~= nil` explicito e os dois lados passam pela mesma normalizacao.
----
---- C14.1 -- ALOCACAO POR DESTINO. A versao antiga montava, para CADA destino, duas
----   tabelas de cobertura mais uma subtabela por inimigo, e ainda o `debug_data` --
----   este INCONDICIONALMENTE, com o `local debug = false` do topo do arquivo. Com
----   D = 150-800 destinos e T = 4-12 alvos (PERF_PLAN), da ordem de 10^4 tabelas por
----   unidade por turno, so para o GC comer. Agora nao ha alocacao nenhuma no caminho
----   quente: le direto das tabelas que o AIPrecalcDamageScore ja preencheu.
----
---- C14.2 -- `ResolveValue("Cover")` POR (DESTINO, INIMIGO), tres vezes: uma em cada
----   chamada de IsInCover e outra no CompareCovers (as linhas 42 e 58 antigas, que o
----   PERF_CHANGES.md ja listava como pendentes). Esse preset faz raycast de cover.
----   Agora e `RATOAI_GetMaxCoverCTH()`, que memoriza o valor e ja existia -- lido uma
----   vez por unidade, no cache de parametros.
----
---- C14.3 -- `Update_AIPrecalcDamageScore` e o custo de AP (`GetWeapon_StanceAP` +
----   `Get_AimCost`) sairam do laco: nada disso depende do destino.
----
---- ------------------------------------------------------------------------------------
---- CUIDADOS
----
---- * `Required` + `PenalizeWorse` NAO se combinam. O teste do AIScoreDest e
----   `failed = Required and pscore <= 0`, e com a punicao ligada o score fica negativo
----   em todo tile que nao melhora -- que e a maioria. O destino inteiro seria vetado.
----   As instancias com Required (tres, hoje) devem ficar com PenalizeWorse desligado.
----   O contrario tambem vale como aviso: com Required, esta policy VETA todo destino de
----   onde o flanco nao melhora nada. Era o que ja acontecia -- so que antes, pelo B39.1,
----   quase nenhum destino melhorava, e o veto pegava quase tudo. O conserto do
----   gradiente RELAXA esse veto em vez de apertar.
----
---- * `optimal_location` agora e FALSE. Fora de `context.destinations` o
----   AIPrecalcDamageScore nao mede cobertura nenhuma (o default do 2o argumento e
----   `context.destinations`, SOURCE_AIPrecalcDamageScore.lua:220), entao na lista de
----   OptLoc a policy so podia comparar contra dado inexistente. Note que a flag e
----   `class_filter` do editor, NAO filtro de runtime (mesma observacao do
----   AIPolicyTryNotToBeFlanked): ela impede ADICIONAR novas instancias em OptLoc, mas
----   nao remove a que ja esta la. Quem remove e o portao de `dest_cover == nil` no
----   EvalDest -- e ele devolve 0, nao lixo. Vale tirar a instancia da lista mesmo assim:
----   0 de graca continua sendo 0.
----
---- * O default de `OnlyTarget` virou TRUE. Antes a policy somava todos os inimigos
----   dentro do alcance efetivo, o que fazia o score de flanquear DILUIR quando havia
----   muita gente por perto. Com um alvo so, ela responde exatamente a pergunta do
----   titulo. O modo antigo continua disponivel (`OnlyTarget = false`) e agora tira uma
----   MEDIA em vez de uma soma -- ver o comentario no laco.
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyCustomFlanking = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        ---- ver o cabecalho: fora dos destinos alcancaveis nao existe cobertura medida
        {
            id = "optimal_location",
            editor = "bool",
            default = false,
            read_only = true,
            no_edit = true
        }, {
            id = "ReserveAttackAP",
            name = "Reserve Attack AP",
            help = "do not consider locations where the unit will be out of ap and couldn't attack",
            editor = "choice",
            default = false,
            items = function(self)
                return {"AP", "Stance", false}
            end
        }, {
            id = "OnlyTarget",
            name = "So o alvo do destino",
            help = "Pontua so contra `context.dest_target[dest]` -- o alvo que a IA " ..
                "escolheu para aquele tile.\n" ..
                "Desligado, entra a media sobre todos os inimigos visiveis dentro do " ..
                "alcance efetivo (o alvo do destino pesa o dobro). Cuidado: quanto mais " ..
                "inimigos longe do flanco, mais o sinal dilui.",
            editor = "bool",
            default = true
        }, {
            id = "PenalizeWorse",
            name = "Punir piora (score negativo)",
            help = "Deixa passar o lado NEGATIVO do delta: tile de onde o alvo fica " ..
                "MAIS coberto do que ja esta vira penalidade em vez de zero.\n" ..
                "INCOMPATIVEL com `Required`: o teste e `Required and pscore <= 0`, " ..
                "entao a punicao vetaria o destino inteiro.",
            editor = "bool",
            default = false
        }, {
            id = "visibility_mode",
            name = "Visibility Mode",
            help = "Quem entra na media. So tem efeito com `OnlyTarget` desligado -- " ..
                "com ele ligado quem escolhe o alvo e o AIPrecalcDamageScore.",
            editor = "choice",
            default = "self",
            items = function(self)
                return {"self", "team", "all"}
            end
        }, {
            id = "ScalePerDistance",
            name = "Escalar por distancia",
            help = "Flanquear quem esta longe vale menos: no limite do alcance efetivo " ..
                "a contribuicao cai 25%.\n" ..
                "Vale nos dois modos -- com um alvo so, escala o score inteiro.",
            editor = "bool",
            default = false
        }
    }
}

---- O rotulo entra no `score_details` do painel de debug e entradas com o MESMO rotulo
---- sao somadas -- duas instancias com parametros diferentes precisam de rotulos
---- diferentes. A versao antiga nao tinha GetEditorView: as sete instancias do
---- items.lua apareciam todas como "AIPolicyCustomFlanking".
function AIPolicyCustomFlanking:GetEditorView()
    return string.format("Flanking (%s%s%s)", self.OnlyTarget and "alvo" or
                             ("todos/" .. tostring(self.visibility_mode)),
                         self.PenalizeWorse and ", pune" or "",
                         self.ScalePerDistance and ", por dist" or "")
end

---- Args (mantidos do arquivo antigo, mesma escala)
---- alcance efetivo considerado, em % do context.EffectiveRange
local effective_range_mul = 100
---- quanto a contribuicao cai, em %, do tile colado ate o limite do alcance
local distance_impact = 25
---- quanto o alvo do destino pesa a mais que os outros, no modo de media
local target_weight = 2

---------------------------------------------------------------------------------------------------
---- PARAMETROS DERIVADOS, por (unidade, instancia de policy)
----
---- PERF (C14.3): tudo que nao depende do destino mora aqui. O cache vive no `context`,
---- que e recriado a cada turno da IA (Combat.lua:1141 zera ai_context antes do
---- Execute), entao nao ha como servir dado velho. Chaveado pela INSTANCIA (`self`)
---- porque o mesmo archetype pode ter duas com parametros diferentes.
---------------------------------------------------------------------------------------------------
function AIPolicyCustomFlanking:GetUnitParams(context)
    local cache = context.__flank_params
    if not cache then
        cache = {}
        context.__flank_params = cache
    end
    local p = cache[self]
    if p ~= nil then
        return p
    end
    p = self:CalcUnitParams(context) or false
    cache[self] = p
    return p
end

function AIPolicyCustomFlanking:CalcUnitParams(context)
    local unit = context.unit

    ---- PERF (C14.3): uma vez por unidade, e nao por destino. O `or context` do codigo
    ---- antigo era ruido -- quem chama EvalDest passa `unit.ai_context` (items.lua:563 e
    ---- AIFindOptimalLocation), que e a MESMA tabela que esta funcao preenche.
    Update_AIPrecalcDamageScore(unit)

    ---- PERF (C14.2): memorizado em FUNCTION_ScoreAttacksDetailed. E o mesmo
    ---- `RangeAttackTargetStanceCover:ResolveValue("Cover")` que o codigo antigo
    ---- resolvia tres vezes por (destino, inimigo). Vale -35 hoje: e PENALIDADE de CTH,
    ---- negativa. Nao importa -- as duas pontas guardam na mesma convencao, entao a
    ---- razao contra ele sai positiva de qualquer jeito.
    local max_cover = RATOAI_GetMaxCoverCTH()
    if not max_cover or max_cover == 0 then
        return
    end

    local check_ap = 0
    if self.ReserveAttackAP == "AP" then
        check_ap = context.default_attack_cost
    elseif self.ReserveAttackAP == "Stance" then
        check_ap = context.default_attack_cost +
                       GetWeapon_StanceAP(unit, context.weapon or unit:GetActiveWeapons()) +
                       Get_AimCost(unit)
    end

    local range = MulDivRound(context.EffectiveRange * const.SlabSizeX, effective_range_mul, 100)

    local p = {
        max_cover = max_cover,
        check_ap = check_ap,
        range = range,
        ---- guardado ao quadrado para o filtro de alcance sair em aritmetica pura, sem
        ---- raiz e sem alocar `point` por destino. Lua 5.3 tem inteiro de 64 bits: um
        ---- alcance de 45 tiles da 2,9e9 aqui, bem dentro.
        range_sq = range * range,
        now = context.currentpos_target_cover_score
    }

    ---- lista de candidatos do modo media, filtrada por visibilidade UMA vez. Ordem
    ---- herdada de context.enemies, que o AICreateContext ordena por handle -- entao e
    ---- estavel entre maquinas.
    if not self.OnlyTarget then
        local list, ex, ey, n = {}, {}, {}, 0
        for _, enemy in ipairs(context.enemies or empty_table) do
            local visible = true
            if self.visibility_mode == "self" then
                visible = context.enemy_visible[enemy]
            elseif self.visibility_mode == "team" then
                visible = context.enemy_visible_by_team[enemy]
            end
            if visible and not (enemy:IsDead() or enemy:IsDowned()) then
                local pos = context.enemy_pos[enemy] or enemy:GetPos()
                local x, y = pos:xyz()
                n = n + 1
                list[n], ex[n], ey[n] = enemy, x, y
            end
        end
        p.list, p.ex, p.ey, p.n = list, ex, ey, n
    end

    return p
end

---------------------------------------------------------------------------------------------------
---- DIAGNOSTICO
----
---- `const.RATOAI.FlankDebug = true` no console faz cada destino guardar o passo a passo
---- em context.dest_flanking_pol_debug[dest], que o DEBUG.lua ja mostra no rollover do
---- voxel. Substitui o `local debug = false` do topo do arquivo antigo, que nao dava
---- para ligar sem reeditar o codigo -- e cujo `debug_data` era montado mesmo desligado.
---------------------------------------------------------------------------------------------------
if const.RATOAI.FlankDebug == nil then
    const.RATOAI.FlankDebug = false
end

---- Cobertura do inimigo, em % de cobertura cheia, vista de um lado so.
---- `nil` NAO e zero: na origem significa "nem enxergo ele daqui", no destino significa
---- "sem LOS". Os dois sao protecao TOTAL contra mim. Ver BUGFIX (B39.2).
function AIPolicyCustomFlanking:CoverPct(p, enemy, dest_cover, dest_los)
    local now = p.now[enemy]
    local now_pct = 100
    if now ~= nil then
        now_pct = MulDivRound(now, 100, p.max_cover)
    end

    local dest_pct = 100
    local los = dest_los and dest_los[enemy]
    if los and los ~= 0 then
        dest_pct = MulDivRound(dest_cover[enemy] or 0, 100, p.max_cover)
    end

    return now_pct, dest_pct
end

function AIPolicyCustomFlanking:ScoreEnemy(p, enemy, dest_cover, dest_los, x, y, z)
    local now_pct, dest_pct = self:CoverPct(p, enemy, dest_cover, dest_los)
    local delta = Clamp(now_pct - dest_pct, -100, 100)

    if delta < 0 and not self.PenalizeWorse then
        return 0
    end
    if delta ~= 0 and self.ScalePerDistance and p.range > 0 then
        local d = Min(enemy:GetDist(x, y, z), p.range)
        delta = MulDivRound(delta, 100 - MulDivRound(d, distance_impact, p.range), 100)
    end
    return delta
end

function AIPolicyCustomFlanking:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end
    local p = self:GetUnitParams(context)
    if not p then
        return 0
    end

    ---- `nil` aqui e "destino NAO MEDIDO", nao "sem cobertura": o AIPrecalcDamageScore
    ---- so varre context.destinations. Comparar contra isso seria inventar dado -- e era
    ---- o que a versao antiga fazia na lista de OptLoc, pagando o custo inteiro para
    ---- produzir um valor que o clamp final jogava fora. Ver o cabecalho.
    local dest_cover = context.dest_target_cover_score[dest]
    if not dest_cover then
        return 0
    end

    if (context.dest_ap[dest] or 0) < p.check_ap then
        return 0
    end

    local dest_los = context.dest_target_los[dest]
    local dbg = const.RATOAI.FlankDebug
    local x, y, z

    ---- so desempacota se alguem for usar (distancia ou debug). stance_pos_unpack e
    ---- barato, mas e por destino.
    if self.ScalePerDistance or not self.OnlyTarget or dbg then
        x, y, z = stance_pos_unpack(dest)
    end

    local score, txt

    if self.OnlyTarget then
        local target = context.dest_target[dest]
        if not target then
            return 0
        end
        score = self:ScoreEnemy(p, target, dest_cover, dest_los, x, y, z)
        if dbg then
            local now_pct, dest_pct = self:CoverPct(p, target, dest_cover, dest_los)
            txt = string.format("alvo %s: cobertura daqui %d%% -> dali %d%% = %d",
                                tostring(target.session_id), now_pct, dest_pct, score)
        end
    else
        ---- MEDIA, e nao soma. Somando, N inimigos davam N vezes o score e a policy
        ---- passava a competir pelo NUMERO de inimigos em vez de pela qualidade do
        ---- flanco -- inflando o melhor score do mapa, que e o que o corte multiplicativo
        ---- de 80% (const.AIDecisionThreshold) menos aguenta. Mesmo erro que a
        ---- AIPolicyThreatExposure ja documenta na diluicao dela.
        local target = context.dest_target[dest]
        local acc, wsum = 0, 0
        local lines
        for i = 1, p.n do
            local dx, dy = x - p.ex[i], y - p.ey[i]
            if dx * dx + dy * dy <= p.range_sq then
                local enemy = p.list[i]
                local s = self:ScoreEnemy(p, enemy, dest_cover, dest_los, x, y, z)
                local w = (enemy == target) and target_weight or 1
                acc = acc + s * w
                wsum = wsum + w
                if dbg then
                    lines = lines or {}
                    lines[#lines + 1] = string.format("  %s: %d (peso %d)",
                                                      tostring(enemy.session_id), s, w)
                end
            end
        end
        if wsum == 0 then
            return 0
        end
        score = MulDivRound(acc, 1, wsum)
        if dbg then
            txt = string.format("media de %d inimigos = %d\n%s", wsum, score,
                                table.concat(lines or empty_table, "\n"))
        end
    end

    if dbg then
        context.dest_flanking_pol_debug[dest] = string.format("%s\n  EvalDest %d (x Weight %d)",
                                                              txt, score, self.Weight or 100)
    end

    return score
end
