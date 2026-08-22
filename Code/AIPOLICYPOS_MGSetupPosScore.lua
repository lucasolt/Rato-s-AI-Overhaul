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
            help = "'team' = so quem o time ja avistou (recomendado; nao depende da postura " ..
                "nem da posicao atual desta unidade). 'all' = todos os inimigos vivos.",
            editor = "choice",
            default = "team",
            items = function(self)
                return {"team", "all"}
            end
        }, {
            id = "ReserveAPforSetup",
            name = "Reservar AP para montar",
            help = "Zera tiles onde nao sobra AP para o MGSetup. Usa o custo real da acao " ..
                "(CombatActions.MGSetup:GetAPCost), nao um numero fixo.\n" ..
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

    c = {
        width = width, ---- LARGURA TOTAL, em minutos (21600 = 360 graus)
        min_range = (params.min_range or 0) * const.SlabSizeX,
        max_range = (params.max_range or 0) * const.SlabSizeX
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
    for _, enemy in ipairs(context.enemies or empty_table) do
        local alive = enemy and not (enemy:IsDead() or enemy:IsDowned())
        local known = (mode == "all") or context.enemy_visible_by_team[enemy]
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
local function RATOAI_MGVerifyLOS(context, key, packed, budget)
    local memo = context.__mg_seen
    if not memo then
        memo = {}
        context.__mg_seen = memo
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
    local los_fixes = rawget(_G, "RATOAI_LOSFixes") ~= false

    local prone_idx = StancesList.Prone
    local prone_key = (stance_idx == prone_idx) and dest or stance_pos_pack(x, y, z, prone_idx)

    if self.RequireLOS and los_fixes and g_AIDestEnemyLOSCache then
        local los = g_AIDestEnemyLOSCache[prone_key]
        if los == nil then
            los = g_AIDestEnemyLOSCache[dest]
        end
        if los == false then
            return 0
        end
    end

    ---- Reserva de AP: custo REAL da acao. dest_ap ausente = tile fora do alcance de movimento.
    if self.ReserveAPforSetup then
        local cost = CombatActions.MGSetup:GetAPCost(context.unit, false) or 0
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
    if self.VerifyLOS and los_fixes then
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
    ---- Maior aglomerado que cabe na largura do cone: janela deslizante circular. Para cada
    ---- inimigo, conta quantos estao dentro de [angulo dele, angulo dele + largura]. O maximo
    ---- e o tamanho do maior grupo que uma orientacao unica do cone consegue cobrir -- e a
    ---- direcao otima sempre pode ser posta com um inimigo na borda, entao a janela ancorada
    ---- em cada inimigo cobre todos os casos.
    ---------------------------------------------------------------------------------------------
    local best = 1
    for i = 1, n do
        local count = 0
        for j = 1, n do
            local diff = angles[j] - angles[i]
            if diff < 0 then
                diff = diff + 21600
            end
            if diff <= cone.width then
                count = count + 1
            end
        end
        if count > best then
            best = count
        end
    end

    local score = self.FirstEnemyScore + (best - 1) * self.ClusterBonus
    return Clamp(score, 0, self.MaxScore)
end
