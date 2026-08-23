---------------------------------------------------------------------------------------------------
---- AIPolicyMGSetupPosScore -- REESCRITA (BUGFIX B27 / PERF C13)
----
---- Responde UMA pergunta: **"se eu deitasse neste tile, quantos inimigos caberiam no meu cone?"**
----
---- Nada mais. Nao mede cobertura, nao mede dano, nao chama precalc. Cobertura ja e a
---- AIPolicyCustomSeekCover / AIPolicyThreatExposure; dano ja e a AIPolicyDealDamage. O que
---- faltava no arquetipo do artilheiro era exatamente isto, e a versao anterior tentava
---- responder as tres coisas ao mesmo tempo.
----
---------------------------------------------------------------------------------------------------
---- O QUE ESTAVA ERRADO NA VERSAO ANTERIOR (todos verificados no codigo, nao deduzidos)
----
---- 1. **O portao de angulo era um no-op por incompatibilidade de unidade.** Ela fazia
----
----        local angle = GetShootingAngleDiff(unit, weapon, enemy, true)
----        RATOAI_GetEnemyCoverScore(unit, enemy, context, score, new_pos, pos, nil, angle)
----
----    e la dentro o argumento cai em `angle_override`, comparado com
----    `angle_ap_threshold * const.Scale.AP` = **2000**. So que `GetShootingAngleDiff`
----    (GBO3, `shooting_stance_functions.lua:106-122`) devolve
----    `abs(unit:AngleToPoint(pos)) / (weapon.OverwatchAngle / 2)` -- uma **razao**, tipicamente
----    0..15, nunca AP. O caminho sem override passa `unit:GetShootingStanceAP(...)`, que e AP de
----    verdade. Ou seja: o teste `angle_ap <= 2000` era sempre verdadeiro e o angulo nunca
----    filtrou nada.
----
---- 2. **O angulo era medido a partir da UNIDADE, nao do tile candidato.** `AngleToPoint` usa a
----    posicao e a orientacao atuais dela. O valor era identico para os 68 destinos -- a policy
----    devolvia praticamente a mesma nota para todo tile, que e o "nunca funcionou direito".
----
---- 3. **A visibilidade tambem era da posicao atual.** O laco filtrava por
----    `context.enemy_visible[enemy]` (`HasVisibilityTo(unit, enemy)`, gravado uma vez por turno
----    no AICreateContext). Um inimigo que so se ve DAQUI entrava na conta de um tile do outro
----    lado do mapa, e um que so se veria DE LA nao entrava nunca.
----
---- 4. **`Update_AIPrecalcDamageScore(unit)` dentro do EvalDest.** Uma policy de posicao
----    disparando um `AIPrecalcDamageScore` completo, no meio da varredura de tiles. E
----    protegido por `context.damage_score_precalced`, entao roda uma vez so -- mas roda escondido
----    dentro de um laco de scoring, e o retorno (`or context`) ainda trocava o context local.
----
---- 5. **Media em vez de aglomerado.** O retorno era `score / Max(1, enemies)`. Um tile com linha
----    para 4 inimigos alinhados valia o mesmo que um com linha para 1 -- exatamente o sinal que
----    a policy existia para dar (`AI_SYSTEM_GUIDE.md` 9.2d).
----
---- 6. **Sem portao de LOS.** Era a unica policy do arquetipo sem o
----    `if ... g_AIDestEnemyLOSCache[dest] == false then return 0 end` das outras tres, e a mais
----    cara por tile: `ChanceToHitModifier:CalcValue` por inimigo (0,03 ms medido no processo
----    vivo). Medido tambem: **442 de 1477** tiles do raio de OptLoc tem LOS -- o portao pula 70%
----    do trabalho usando o cache que a engine JA calculou, sem nenhum raycast novo.
----
---------------------------------------------------------------------------------------------------
---- COMO A NOVA VERSAO MEDE
----
---- Por tile: um lookup no cache de LOS, um `Dist2D` e um `CalcOrientation` por inimigo, e uma
---- janela deslizante circular O(n^2) sobre os angulos (n = 4-8 na pratica, ~50 comparacoes
---- inteiras). Sem CalcValue, sem GetShootingAngleDiff, sem precalc.
----
---- O cone: `weapon:GetAreaAttackParams("MGSetup", unit)` da `cone_angle` (LARGURA TOTAL em
---- minutos -- a UI desenha de `-cone_angle/2` a `+cone_angle/2`, `UnitAOEActionVisuals.lua:450`)
---- e o anel `min_range`..`max_range`. Nao dependem do tile, entao sao resolvidos uma vez por
---- turno e guardados no context.
----
---- CUSTO POR PLACEMENT -- vale saber onde ela esta ligada:
----   * `EndTurnPolicies` -> roda por `context.destinations` (68 medidos naquele turno);
----   * `OptLocPolicies`  -> roda por `context.all_destinations` (**1477** medidos, raio 100).
---- Com o portao de LOS a versao nova aguenta os dois; a antiga custava ~200 ms no OptLoc.
----
---- ARMADILHA do ReserveAPforSetup em OptLocPolicies: tiles fora do alcance de movimento nao tem
---- `dest_ap`, entao a reserva zera todos eles e a "melhor posicao" nunca pode estar a mais de um
---- turno de distancia. Por isso o default e `false`. Ligue so no placement de EndTurn.
----
---------------------------------------------------------------------------------------------------
---- BUGFIX (B29) -- QUATRO LUGARES ONDE A POLICY DIZIA "SIM" E A ACAO DIZIA "NAO"
----
---- Sintoma medido em campo (sonda `tools/check_mgsetup_gates.lua`, combate real): o
---- LegionGunner:412 tinha nota 100 -- o TETO -- no destino escolhido, e o `AIActionMGSetup`
---- saia da lista de signature actions sem nenhuma mensagem. A policy respondia a pergunta dela
---- certo; o que estava errado era ela estar respondendo uma pergunta MAIS FROUXA que a da acao.
----
----   a) ANEL. `min_range >= max_range` quer dizer "sem minimo" (e o que o AIFilterTargetPoints
----      do vanilla faz), e o alcance efetivo e limitado por `Min(sight, GetMaxRange())`, que e
----      o segundo CheckLOS do AIPrecalcConeTargetZones. Ver RATOAI_MGCone.
----   b) QUEM CONTA. A acao gera ponto de mira so para inimigo que ESTA unidade enxerga agora
----      (`VisibilityCheckAll ... uvVisible`). Medido: LegionGunner:411 com 4 inimigos vistos
----      pelo time e 0 por ele -- target_pts = 0, MGSetup indisponivel. Novo modo
----      `visibility_mode = "self"`.
----   c) ALIADOS. O pool das zonas e `enemies + GetAllAlliedUnits`, e aliado no cone vale
----      `team_score` (-20 / -10 nos presets). Novo `AllyPenalty`, com o aliado passando pelo
----      mesmo lote de raios do inimigo.
----   d) RESERVA DE AP. Agora que o custo do MGSetup inclui a mudanca para Prone (GBO3,
----      `rat_MGSetup_getap`), a reserva tem que medir a partir da postura DO DESTINO, senao o
----      destino empacotado Prone pelo B25 paga a postura duas vezes.
----
---- O que a policy CONTINUA sem ver, de proposito: o CTH. Ele foi consertado do outro lado --
---- o preview do MGSetup passou a ser medido como a interrupcao que a MG realmente faz
---- (GBO3, `CTH_hipfire_and_snapshot.lua`). Medir CTH por tile aqui custaria um CalcValue por
---- inimigo por tile, que e justamente o que o B27 tirou.
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyMGSetupPosScore = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {
            id = "FirstEnemyScore",
            name = "Score do primeiro inimigo",
            help = "Nota por conseguir cobrir pelo menos um inimigo com o cone, deitado daqui.",
            editor = "number",
            default = 40
        }, {
            id = "ClusterBonus",
            name = "Bonus por inimigo extra",
            help = "Somado por cada inimigo ALEM do primeiro que cabe no MESMO cone. " ..
                "Com os defaults: 1 inimigo = 40, 2 = 70, 3 = 100 (teto).",
            editor = "number",
            default = 30
        }, {
            id = "MaxScore",
            name = "Teto",
            help = "O retorno vive em [0, MaxScore]. AIScoreDest multiplica pelo Weight/100.",
            editor = "number",
            default = 100
        }, {
            id = "RequireLOS",
            name = "Exigir LOS deitado",
            help = "Zera o tile quando o cache de LOS diz que NINGUEM e visto dali deitado. " ..
                "Usa g_AIDestEnemyLOSCache, ja calculado pela engine -- nao custa raycast. " ..
                "Cache ausente (nil) nao zera: significa 'nunca checado', nao 'sem linha'.",
            editor = "bool",
            default = true
        }, {
            id = "VerifyLOS",
            name = "Checar linha por inimigo",
            help = "O portao RequireLOS so diz 'ALGUM inimigo e visto daqui'. Sem esta opcao a " ..
                "contagem do aglomerado e GEOMETRIA PURA -- anel de alcance mais angulo -- e um " ..
                "tile na borda de um obstaculo, com linha para um inimigo so, leva credito pelos " ..
                "outros tres que estao atras da parede. Ligada, cada inimigo do anel e checado " ..
                "com um raio a partir DESTE tile, deitado, e so os vistos contam.\n" ..
                "Custo medido: 0,04 ms por raio. Ver MaxLOSChecks.",
            editor = "bool",
            default = true
        }, {
            id = "MaxLOSChecks",
            name = "Orcamento de raios por turno",
            help = "Teto de raios que a verificacao gasta por turno da unidade. Estourou, os " ..
                "tiles restantes caem para geometria pura (e a nota deles fica otimista).\n" ..
                "Referencia medida: EndTurnPolicies = ~68 tiles x inimigos do anel (~270 raios, " ..
                "11 ms). OptLocPolicies = ~1400 tiles (~5600 raios, 220 ms) -- e por isso que " ..
                "existe teto.",
            editor = "number",
            default = 4000,
            min = 0
        }, {
            id = "visibility_mode",
            name = "Quem conta como inimigo",
            help = "'team' = quem o time ja avistou (default; nao depende da postura nem da " ..
                "posicao atual desta unidade).\n" ..
                "'self' = so quem ESTA unidade enxerga agora, o mesmo VisibilityCheckAll que " ..
                "o AICalcAOETargetPoints usa para gerar as zonas do MGSetup. Paridade exata " ..
                "com a acao, ao preco de ignorar a inteligencia do time ao ESCOLHER o tile.\n" ..
                "'all' = todos os inimigos vivos.",
            editor = "choice",
            default = "team",
            items = function(self)
                return {"team", "self", "all"}
            end
        }, {
            id = "AllyPenalty",
            name = "Desconto por aliado no cone",
            help = "Subtraido por cada ALIADO que cai no mesmo cone. A AIEvalZones ja faz isso " ..
                "(o pool dela e `enemies + GetAllAlliedUnits`, e o aliado vale `team_score`), " ..
                "entao sem isto a policy manda a unidade para um tile cuja unica zona a " ..
                "propria acao rejeita por ter amigo na linha. 0 desliga.",
            editor = "number",
            default = 30,
            min = 0
        }, {
            id = "ReserveAPforSetup",
            name = "Reservar AP para montar",
            help = "Zera tiles onde nao sobra AP para o MGSetup. Usa o custo real da acao " ..
                "(CombatActions.MGSetup:GetAPCost), corrigido para a POSTURA DO DESTINO -- o " ..
                "custo inclui a mudanca para Prone, e o GetAPCost a mede a partir da postura " ..
                "atual da unidade, nao da que o dest carrega.\n" ..
                "NAO ligue em OptLocPolicies: tile fora do alcance de movimento nao tem " ..
                "dest_ap e seria zerado, o que impede a IA de mirar uma posicao a dois turnos.",
            editor = "bool",
            default = false
        }
    }
}

function AIPolicyMGSetupPosScore:GetEditorView()
    return "MG: inimigos que cabem no cone (deitado)"
end

---------------------------------------------------------------------------------------------------
---- Parametros do cone: nao dependem do tile. Resolvidos uma vez por context (= uma vez por
---- turno da unidade) e guardados nele. `false` = esta unidade nao monta MG nenhuma.
---------------------------------------------------------------------------------------------------
local function RATOAI_MGCone(context)
    local c = context.__mg_cone
    if c ~= nil then
        return c
    end

    local unit = context.unit
    local weapon = context.weapon or (unit and unit:GetActiveWeapons())
    local action = CombatActions.MGSetup

    if not action or not weapon or not IsKindOf(weapon, "Firearm") or
        not weapon.GetAreaAttackParams then
        context.__mg_cone = false
        return false
    end

    local ok, params = pcall(weapon.GetAreaAttackParams, weapon, "MGSetup", unit)
    local width = ok and params and params.cone_angle or 0
    if width <= 0 then
        context.__mg_cone = false
        return false
    end

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B29a): o anel tem que ser o MESMO que a acao usa, entao ele sai da fonte unica
    ---- (`RATOAI_MGConeRange`, em CONSTANTS_AI_source.lua) que o
    ---- SOURCE_AIPrecalcConeTargetZones.lua tambem consulta. Discordancia entre os dois e o
    ---- proprio B29. La estao documentados: a guarda `min >= max` do vanilla, o teto de
    ---- `Min(sight, GetMaxRange())` e os parametros de encurtamento do cone.
    ---------------------------------------------------------------------------------------------
    local min_r, max_r = RATOAI_MGConeRange(unit, weapon, params)
    if max_r <= 0 then
        context.__mg_cone = false
        return false
    end

    c = {
        width = width, ---- LARGURA TOTAL, em minutos (21600 = 360 graus)
        min_range = min_r,
        max_range = max_r
    }
    context.__mg_cone = c
    return c
end

---------------------------------------------------------------------------------------------------
---- Inimigos considerados + posicoes, resolvidos uma vez por context pelo mesmo motivo.
---------------------------------------------------------------------------------------------------
local function RATOAI_MGEnemies(context, mode)
    local cached = context.__mg_enemies
    if cached and context.__mg_enemies_mode == mode then
        return cached
    end

    ---- `pos` para geometria (anel + angulo), `packed` para o raio de LOS (pos + postura do
    ---- inimigo, mesma forma que o AIUpdateDestLosCache usa como alvo).
    local list = {pos = {}, packed = {}, n = 0}
    local unit = context.unit
    for _, enemy in ipairs(context.enemies or empty_table) do
        local alive = enemy and not (enemy:IsDead() or enemy:IsDowned())
        ---- BUGFIX (B29b): 'self' e o mesmo teste que o AICalcAOETargetPoints faz para gerar as
        ---- zonas do MGSetup. Sem ele, um inimigo que o TIME avistou mas que esta unidade nao
        ---- enxerga pontua o tile e depois nao vira ponto de mira nenhum -- medido em campo:
        ---- LegionGunner:411 com vis_team=4 e vis_self=0, target_pts=0, MGSetup indisponivel.
        local known
        if mode == "all" then
            known = true
        elseif mode == "self" then
            known = VisibilityCheckAll(unit, enemy, nil, const.uvVisible)
        else
            known = context.enemy_visible_by_team[enemy]
        end
        if alive and known then
            local pos = context.enemy_pos[enemy] or enemy:GetPos()
            local packed = context.enemy_pack_pos_stance[enemy]
            if IsValidPos(pos) and packed then
                local n = list.n + 1
                list.n = n
                list.pos[n] = RATOAI_ValidatePosZ(pos)
                list.packed[n] = packed
            end
        end
    end

    context.__mg_enemies = list
    context.__mg_enemies_mode = mode
    return list
end

---------------------------------------------------------------------------------------------------
---- Aliados, pelo mesmo motivo e no mesmo formato -- BUGFIX (B29c).
----
---- A AIEvalZones nao pontua so inimigos: o pool que entra nas zonas e
---- `context.enemies + GetAllAlliedUnits(unit)` (AIPrecalcConeTargetZones), e cada aliado dentro
---- do cone soma `team_score`, que nos presets do artilheiro e -20 / -10. Com
---- `enemy_score = 110` e `min_score = 100`, UM aliado na linha ja derruba a zona de um inimigo
---- abaixo do limiar. A policy nao via nada disso e mandava a unidade justamente para la.
----
---- Medido em campo: das 5 unidades que entraram nas zonas do LegionGunner:412, uma era o
---- LegionRaider:415, aliado dele.
---------------------------------------------------------------------------------------------------
local function RATOAI_MGAllies(context)
    local cached = context.__mg_allies
    if cached then
        return cached
    end

    local unit = context.unit
    local list = {pos = {}, packed = {}, n = 0}
    for _, ally in ipairs(GetAllAlliedUnits(unit) or empty_table) do
        if ally ~= unit and not (ally:IsDead() or ally:IsDowned()) and ally:IsValidPos() then
            local pos = RATOAI_ValidatePosZ(ally:GetPos())
            if IsValidPos(pos) then
                local n = list.n + 1
                list.n = n
                list.pos[n] = pos
                list.packed[n] = GetPackedPosAndStance(ally)
            end
        end
    end

    context.__mg_allies = list
    return list
end

---------------------------------------------------------------------------------------------------
---- Checagem de linha por inimigo, a partir de UM tile, deitado. Memoizada por tile e com
---- orcamento de raios por turno.
----
---- Por que ela e necessaria: o `g_AIDestEnemyLOSCache` responde "ALGUM inimigo e visto daqui",
---- que e o portao certo para entrar na disputa mas o insumo errado para CONTAR aglomerado. Um
---- tile na borda de obstaculo costuma ter linha para exatamente um inimigo -- e sem esta
---- checagem ele leva nota cheia pelos outros que estao atras da parede.
----
---- Por que ela nao pode ser uma matriz completa: medido no processo vivo, **0,04 ms por raio**
---- (900 tiles x 22 inimigos = 19800 raios em 793 ms numa unica batelada). Uma matriz de todo
---- all_destinations custaria mais de um segundo. Aqui so entram os inimigos do ANEL do tile, e
---- so em tiles que ja passaram o portao barato.
----
---- Devolve nil quando o orcamento acabou -- o chamador cai para geometria pura.
---------------------------------------------------------------------------------------------------
local function RATOAI_MGVerifyLOS(context, key, packed, budget, tag)
    local memos = context.__mg_seen
    if not memos then
        memos = {}
        context.__mg_seen = memos
    end
    ---- Duas memos por tile: o lote de inimigos e o de aliados tem tamanhos diferentes, entao
    ---- nao podem dividir a mesma linha.
    local memo = memos[tag or "enemy"]
    if not memo then
        memo = {}
        memos[tag or "enemy"] = memo
    end
    local row = memo[key]
    if row ~= nil then
        return row
    end

    local need = #packed
    if need == 0 then
        return nil
    end

    local used = context.__mg_los_checks or 0
    if used + need > (budget or 0) then
        context.__mg_los_budget_hit = true
        return nil
    end
    context.__mg_los_checks = used + need

    local sight = context.__mg_sight
    if not sight then
        sight = context.unit:GetSightRadius()
        context.__mg_sight = sight
    end

    local srcs = {}
    for i = 1, need do
        srcs[i] = key
    end

    local any, vals = CheckLOS(packed, srcs, sight)
    row = {}
    for i = 1, need do
        row[i] = (any and vals and vals[i]) and true or false
    end
    memo[key] = row
    return row
end

function AIPolicyMGSetupPosScore:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end

    local cone = RATOAI_MGCone(context)
    if not cone then
        return 0
    end

    local x, y, z, stance_idx = stance_pos_unpack(dest)
    if not x then
        return 0
    end

    ---------------------------------------------------------------------------------------------
    ---- Portao de LOS -- DEITADO. A chave do cache carrega a postura, entao consultar `dest`
    ---- cru mediria a postura que ele por acaso tem. Consulta a chave Prone primeiro; se ela
    ---- nao existe (arquetipo que nao e Prone, tile fora da batelada), cai para o proprio dest;
    ---- se nenhuma das duas foi checada, nao zera -- `nil` e "nunca checado", nao "sem linha".
    ---- Mesmo criterio da AIPolicyThreatExposure.
    ---------------------------------------------------------------------------------------------
    ---- Interruptor mestre (CONSTANTS_AI_source.lua). Em false, a policy volta a pontuar por
    ---- geometria pura -- que e o comportamento a comparar quando se esta cacando bug
    ---- intermitente.

    local prone_idx = StancesList.Prone
    local prone_key = (stance_idx == prone_idx) and dest or stance_pos_pack(x, y, z, prone_idx)

    if self.RequireLOS and g_AIDestEnemyLOSCache then
        local los = g_AIDestEnemyLOSCache[prone_key]
        if los == nil then
            los = g_AIDestEnemyLOSCache[dest]
        end
        if los == false then
            return 0
        end
    end

    ---------------------------------------------------------------------------------------------
    ---- Reserva de AP: custo REAL da acao, medido NA POSTURA DO DESTINO -- BUGFIX (B29d).
    ----
    ---- Desde a mudanca no GBO3 (`rat_MGSetup_getap`), o custo do MGSetup inclui a mudanca de
    ---- postura para Prone. Mas o `GetAPCost` a mede a partir da postura ATUAL da unidade, e o
    ---- que vale aqui e a postura que o `dest` carrega -- e onde ela vai estar quando montar.
    ---- Sem esta troca, um artilheiro em pe avaliando um destino ja empacotado Prone (o passe
    ---- B25 do AIFindDestinations) pagaria a mudanca duas vezes: uma descontada do `dest_ap`
    ---- pelo B25, outra dentro do `cost` -- que e exatamente o custo dobrado que este bloco
    ---- existia para NAO criar.
    ----
    ---- `Unit:GetStanceToStanceAP(stance, override)` aceita a postura de origem por argumento,
    ---- devolve -1 quando ja se esta nela (dai o `Max(0, ...)`) e ja trata a perk `HitTheDeck`.
    ---- `dest_ap` ausente = tile fora do alcance de movimento.
    ---------------------------------------------------------------------------------------------
    if self.ReserveAPforSetup then
        local unit = context.unit
        local cost = CombatActions.MGSetup:GetAPCost(unit, false) or 0
        if not unit:HasStatusEffect("ManningEmplacement") then
            cost = cost - Max(0, unit:GetStanceToStanceAP("Prone")) +
                       Max(0, unit:GetStanceToStanceAP("Prone", StancesList[stance_idx]))
        end
        if (context.dest_ap[dest] or 0) < cost then
            return 0
        end
    end

    local from = RATOAI_ValidatePosZ(point(x, y, z))
    if not IsValidPos(from) then
        return 0
    end

    ---- Inimigos dentro do anel de alcance do cone, medido DESTE tile.
    local enemies = RATOAI_MGEnemies(context, self.visibility_mode)
    local angles, ring_packed, n = {}, {}, 0
    for i = 1, enemies.n do
        local epos = enemies.pos[i]
        local d = from:Dist2D(epos)
        if d >= cone.min_range and d <= cone.max_range then
            n = n + 1
            angles[n] = CalcOrientation(from, epos)
            ring_packed[n] = enemies.packed[i]
        end
    end
    if n == 0 then
        return 0
    end

    ---------------------------------------------------------------------------------------------
    ---- Um raio por inimigo do anel, deitado, deste tile. Sem isto a contagem e geometria pura e
    ---- premia a borda de obstaculo: linha para um inimigo, credito por todos.
    ---------------------------------------------------------------------------------------------
    if self.VerifyLOS then
        local seen = RATOAI_MGVerifyLOS(context, prone_key, ring_packed, self.MaxLOSChecks)
        if seen then
            local kept = 0
            for i = 1, n do
                if seen[i] then
                    kept = kept + 1
                    angles[kept] = angles[i]
                end
            end
            n = kept
            if n == 0 then
                return 0
            end
        end
    end

    ---------------------------------------------------------------------------------------------
    ---- BUGFIX (B29c): aliados que cairiam no cone.
    ----
    ---- ORDEM IMPORTA POR CUSTO. O anel e largo (2,4 m a ~50 m) e o time e grande: medido em
    ---- campo, **22 a 24 dos 26 aliados** do artilheiro estao dentro do anel. Passar todos eles
    ---- pelo lote de raios custaria ~3000 raios por turno so em amigo (o teto inteiro do
    ---- MaxLOSChecks) para achar os zero ou um que importam.
    ----
    ---- O cone, porem, e ESTREITO -- 645 a 1049 minutos nas MGs medidas, ou seja 11 a 17 graus.
    ---- Entao o filtro barato vem primeiro: so entra no lote de raios o aliado cujo angulo cabe
    ---- em ALGUMA janela ancorada num inimigo que ja sobreviveu ao LOS. Na pratica sobram 0 a 2.
    ---------------------------------------------------------------------------------------------
    local ally_angles, na = nil, 0
    if (self.AllyPenalty or 0) > 0 then
        local allies = RATOAI_MGAllies(context)
        local cand_ang, cand_packed, nc = {}, {}, 0
        for i = 1, allies.n do
            local apos = allies.pos[i]
            local d = from:Dist2D(apos)
            if d >= cone.min_range and d <= cone.max_range then
                local ang = CalcOrientation(from, apos)
                for j = 1, n do
                    local diff = ang - angles[j]
                    if diff < 0 then
                        diff = diff + 21600
                    end
                    if diff <= cone.width then
                        nc = nc + 1
                        cand_ang[nc] = ang
                        cand_packed[nc] = allies.packed[i]
                        break
                    end
                end
            end
        end

        if nc > 0 and self.VerifyLOS then
            local seen = RATOAI_MGVerifyLOS(context, prone_key, cand_packed, self.MaxLOSChecks,
                                            "ally")
            if seen then
                local kept = 0
                for i = 1, nc do
                    if seen[i] then
                        kept = kept + 1
                        cand_ang[kept] = cand_ang[i]
                    end
                end
                nc = kept
            end
        end
        ally_angles, na = cand_ang, nc
    end

    ---------------------------------------------------------------------------------------------
    ---- Melhor cone: janela deslizante circular ancorada em cada inimigo. Para cada ancora,
    ---- conta quem cai em [angulo dela, angulo dela + largura] e pontua a zona como a
    ---- AIEvalZones pontuaria -- inimigos somam, aliados subtraem. A direcao otima sempre pode
    ---- ser posta com um inimigo na borda, entao ancorar em cada inimigo cobre todos os casos.
    ---------------------------------------------------------------------------------------------
    local best_score = 0
    for i = 1, n do
        local hits = 0
        for j = 1, n do
            local diff = angles[j] - angles[i]
            if diff < 0 then
                diff = diff + 21600
            end
            if diff <= cone.width then
                hits = hits + 1
            end
        end
        local friendlies = 0
        for j = 1, na do
            local diff = ally_angles[j] - angles[i]
            if diff < 0 then
                diff = diff + 21600
            end
            if diff <= cone.width then
                friendlies = friendlies + 1
            end
        end
        local s = self.FirstEnemyScore + (hits - 1) * self.ClusterBonus - friendlies *
                      self.AllyPenalty
        if s > best_score then
            best_score = s
        end
    end

    return Clamp(best_score, 0, self.MaxScore)
end
