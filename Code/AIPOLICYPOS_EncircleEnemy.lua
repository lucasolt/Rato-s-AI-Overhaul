---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata.
const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- AIPolicyEncircleEnemy
----
---- Atrator de ENVOLVIMENTO. Responde uma pergunta: "para envolver a formacao inimiga,
---- este tile esta na direcao certa?"
----
---- Nenhuma policy do mod tem nocao de FORMACAO. Todas leem a relacao unidade <-> inimigo
---- (cobertura contra ele, alcance ate ele, LOS dele) e nenhuma le a relacao
---- TIME <-> TIME. Por isso a IA converge para uma bolha frontal: cada unidade otimiza
---- sozinha contra os mesmos inimigos e chega, sozinha, na mesma resposta. Manobra de
---- pinca nao emerge de scoring individual -- ela precisa de um plano compartilhado, e
---- e isso que este arquivo adiciona.
----
---- ------------------------------------------------------------------------------------
---- 1. O REFERENCIAL (calculado UMA vez por turno, para o time inteiro)
----
---- Dois centroides -- A (aliados vivos do time) e E (inimigos vivos conhecidos) -- e o
---- eixo que os liga:
----
----     u = normalize(E - A)      eixo de AVANCO   (aponta para o inimigo)
----     v = perp(u)               eixo LATERAL     (aponta para o flanco "+1")
----
---- Todo ponto do mapa vira um par (f, l): f = quanto avancou no eixo u a partir de A,
---- l = quanto se afastou do eixo, com sinal. Por construcao l(A) = l(E) = 0: o eixo
---- passa exatamente pelos dois centroides, entao `l` ja E a distancia com sinal ate a
---- linha imaginaria que liga os dois times.
----
----                     l > 0  (flanco +1)
----          . . . . . . . . . . . . . . . .
----                  A ----u----> E              <- eixo, l = 0
----          . . . . . . . . . . . . . . . .
----                     l < 0  (flanco -1)
----
---- 2. A LINHA DE FRENTE
----
---- E o `f` onde os dois times se encostam. Dois modos (`LineMode`):
----   * "centroids" (default) -- meio do caminho entre os centroides. Robusto: um
----     batedor perdido la na frente nao move a linha.
----   * "contact" -- meio do caminho entre o aliado mais avancado e o inimigo mais
----     avancado. Mais literal ("a linha esta onde as pontas se tocam"), mas basta UMA
----     unidade fora de lugar para a linha pular o mapa inteiro.
---- Nao usa os objetos de cobertura em uso: a posicao do cover E a posicao da unidade,
---- entao ele nao adiciona informacao nenhuma alem da que os centroides ja tem. O que
---- cobertura ADICIONARIA e a DIRECAO de onde cada um se protege -- um eixo de ameaca
---- por unidade em vez de um eixo global. Fica como refinamento futuro; o custo e o
---- mesmo (n unidades, uma vez por turno), mas so vale a pena se o eixo global se
---- mostrar ruim em mapas com combate em dois eixos ao mesmo tempo.
----
---- 3. O SCORE DE UM TILE  (dois numeros, 0..100 cada)
----
---- LP -- progresso LATERAL, uma TENDA com pico no objetivo de flanco:
----      objetivo G = borda lateral da formacao inimiga (do lado atribuido a esta
----      unidade) + FlankMarginTiles. LP = 0 no eixo, sobe ate 100 em G, e DESCE de
----      volta a 0 depois. E tenda, e nao rampa saturada, de proposito: rampa saturada
----      nao tem pico, entao "mais lateral" seria sempre >= e a unidade correria para a
----      borda do mapa. A tenda define um ANEL de envolvimento com raio finito.
----      No lado ERRADO (l com o sinal oposto ao atribuido), LP = 0 -- e o que impede as
----      duas pontas da pinca de trocarem de lado no meio da manobra.
----
---- FP -- progresso PARA A FRENTE: 0 na linha de frente, 100 em f(E) + DepthTiles.
----      Atras da linha, 0.
----
---- E a composicao, que e o coracao da coisa:
----
----      score = LP x ( LateralShare + (100 - LateralShare) x FP / 100 ) / 100
----
---- FP so pontua MULTIPLICADO por LP. Ou seja: avancar SO vale se voce ja esta fora do
---- flanco. Ir para a frente pelo meio da linha vale exatamente zero por esta policy.
---- O campo de score resultante tem o maximo na intersecao "faixa do flanco" x "fundo
---- da formacao inimiga", e o caminho de subida a partir de qualquer ponto e um ARCO --
---- primeiro abre, depois avanca. Nao foi preciso codificar arco nenhum; ele cai fora
---- do portao multiplicativo.
----
---- `LateralShare` e o quanto se ganha so por abrir, sem ter passado a linha (default
---- 40). Se for 0, uma unidade que ainda nao passou a linha nao ve gradiente NENHUM e a
---- policy fica inerte justamente para quem precisa comecar a manobra.
----
---- 4. OS DOIS LADOS (a pinca)
----
---- Cada unidade do time recebe um lado (-1 / +1) no plano do turno. O lado natural e o
---- sinal do proprio `l` -- quem ja esta na esquerda vai pela esquerda. Com
---- `BalanceSides` (default ligado), se um lado ficar com 2+ unidades a mais que o
---- outro, as unidades MAIS PROXIMAS DO EIXO do lado cheio trocam de lado ate a
---- diferenca cair para 1. Troca quem esta no meio, nunca quem ja esta na ponta: a
---- travessia mais curta e a menos exposta.
----
---- `WingFraction` limita a manobra as unidades das PONTAS: com 50, so a metade mais
---- lateral do time envolve; o resto devolve 0 e fica a cargo das outras policies
---- (a base de fogo que segura a linha enquanto as pontas abrem).
----
---- 5. POR QUE UM SNAPSHOT POR TURNO, E NAO LEITURA AO VIVO
----
---- Nao e (so) economia. Na FASE 3 do turno as unidades pensam e agem INTERCALADAS
---- (AI_SYSTEM_GUIDE secao 1): se o plano fosse recalculado a cada `Think`, a primeira
---- unidade a abrir pelo flanco moveria o centroide aliado para aquele lado, o que gira
---- o eixo, o que move as bordas laterais, o que muda o lado atribuido as proximas --
---- realimentacao positiva, com a formacao inteira derivando atras da primeira unidade
---- que se mexeu. O snapshot congela o referencial no inicio do turno, que e o unico
---- jeito de as N unidades executarem o MESMO plano.
---- O plano e construido na primeira chamada de EvalDest do turno, que acontece antes
---- de qualquer unidade do time ter andado.
----
---- 6. CUSTO
----
---- Plano: O(n_aliados + n_inimigos), uma vez por turno do time. Ruido.
---- Por destino: uma leitura de tabela (cache no context), duas multiplicacoes e um
---- MulDivRound para o lateral -- e os tiles do lado errado saem AI, antes de tocar no
---- eixo de avanco. Sem alocacao, sem `point`, sem raycast, sem chamada de engine.
---- Nao ha cache por grid_voxel (como o da TryNotToBeFlanked): a conta e mais barata
---- que o hash que o cache custaria.
----
---- 7. CUIDADOS
----
---- * `Required` NAO: metade do mapa devolve 0 por construcao (lado errado), e Required
----   vetaria todos esses tiles -- inclusive o proprio tile onde a unidade esta.
---- * No OptLoc, `AIFindOptimalLocation` guarda TODOS os tiles com score >= 80% do
----   melhor e depois manda o pathfinder no MAIS PERTO deles (pf.GetPosPath). Como o
----   pico desta policy e uma FAIXA (a tenda so restringe o lateral), o resultado
----   pratico e "va para o ponto mais proximo da faixa de envolvimento" -- exatamente o
----   passo seguinte do arco, e nao uma corrida ate o fundo do mapa.
---- * Ela NAO sabe de cobertura, ameaca ou alcance. Isso e de proposito -- e um vetor
----   estrategico. Sem Threat Exposure / Seek Cover na mesma lista, a unidade envolve
----   pelo caminho mais exposto que existir.
---- * Nao esta ligada em nenhum archetype. Adicione onde quiser pelo editor in-game.
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyEncircleEnemy = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        ---- serve aos dois: e um vetor estrategico (OptLoc) que tambem discrimina bem
        ---- entre tiles alcancaveis (EndTurn). Ver a secao 7 sobre `Required`.
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true}, {
            id = "LineMode",
            name = "Linha de frente",
            help = "centroids = meio do caminho entre os centroides dos dois times " ..
                "(robusto, default).\n" ..
                "contact = meio do caminho entre as duas pontas mais avancadas " ..
                "(literal, mas uma unidade fora de lugar move a linha inteira).",
            editor = "choice",
            default = "centroids",
            items = function(self)
                return {"centroids", "contact"}
            end
        }, {
            id = "FlankMarginTiles",
            name = "Margem do flanco (tiles)",
            help = "Quanto ALEM da borda lateral da formacao inimiga fica o pico da " ..
                "tenda. 0 = envolver rente a borda (a unidade para no ultimo inimigo " ..
                "da fila em vez de contornar).",
            editor = "number",
            default = 10,
            min = 0,
            max = 40
        }, {
            id = "OverrunTiles",
            name = "Largura da queda (tiles)",
            help = "Quantos tiles depois do pico a tenda leva para voltar a zero.\n" ..
                "0 = tenda simetrica (a queda tem a mesma largura da subida) -- " ..
                "recomendado, porque acompanha automaticamente formacoes largas.\n" ..
                "Valor pequeno aperta o anel de envolvimento numa faixa estreita; " ..
                "valor grande deixa a unidade se afastar mais sem perder score.",
            editor = "number",
            default = 0,
            min = 0,
            max = 60
        }, {
            id = "DepthTiles",
            name = "Profundidade (tiles)",
            help = "Onde o progresso PARA A FRENTE satura, contado a partir do " ..
                "centroide inimigo. 0 = envolver ate ficar lado a lado com a formacao; " ..
                "valores maiores empurram a unidade para a retaguarda inimiga.",
            editor = "number",
            default = 6,
            min = 0,
            max = 40
        }, {
            id = "LateralShare",
            name = "Parte lateral do score (%)",
            help = "Quanto do score se ganha SO por estar na faixa do flanco, sem ter " ..
                "passado a linha de frente. O resto so vem com o avanco.\n" ..
                "0 = quem ainda esta atras da linha nao ve gradiente nenhum (policy " ..
                "inerte justamente para quem precisa comecar a manobra).\n" ..
                "100 = a policy vira so um empurrao para os lados, sem nocao de avanco.",
            editor = "number",
            default = 40,
            min = 0,
            max = 100
        }, {
            id = "ForwardLookaheadTiles",
            name = "Teto de avanco por turno (tiles)",
            help = "Limita o alvo de avanco a no maximo X tiles a frente de onde a " ..
                "unidade esta AGORA. Encurta o arco: ela abre e avanca por etapas em " ..
                "vez de mirar direto na retaguarda inimiga.\n" ..
                "0 = desligado (default). Referencia util: o alcance de movimento de " ..
                "um turno (~10-15 tiles).",
            editor = "number",
            default = 8,
            min = 0,
            max = 60
        }, {
            id = "MinSeparationTiles",
            name = "Separacao minima (tiles)",
            help = "Abaixo desta distancia entre os centroides a policy se desliga " ..
                "inteira. Times embolados nao tem flanco: o eixo fica curto, gira com " ..
                "qualquer passo, e o envolvimento vira ruido de alta frequencia.",
            editor = "number",
            default = 6,
            min = 1,
            max = 60
        }, {
            id = "BalanceSides",
            name = "Equilibrar os dois lados",
            help = "Forca a pinca: se um flanco tiver 2+ unidades a mais que o outro, " ..
                "as mais proximas do eixo trocam de lado.\n" ..
                "Desligado, cada uma vai pelo lado em que ja esta -- se o time todo " ..
                "estiver de um lado so, vira um gancho unico em vez de pinca.",
            editor = "bool",
            default = true
        }, {
            id = "WingFraction",
            name = "Fracao do time que envolve (%)",
            help = "So as unidades mais LATERAIS do time recebem a manobra; as de " ..
                "dentro devolvem 0 e ficam por conta das outras policies.\n" ..
                "100 = todas (default). 50 = so as pontas. Vale por TIME, contando " ..
                "todo mundo vivo -- inclusive quem nem tem esta policy no archetype.",
            editor = "number",
            default = 100,
            min = 1,
            max = 100
        }
    }
}

---- O rotulo entra no `score_details` do painel de debug e entradas com o MESMO rotulo
---- sao somadas -- duas instancias com parametros diferentes precisam de rotulos
---- diferentes. Ver AIPolicyThreatExposure:GetEditorView.
function AIPolicyEncircleEnemy:GetEditorView()
    return string.format("Encircle Enemy (flanco +%dt, fundo +%dt%s)", self.FlankMarginTiles or 0,
                         self.DepthTiles or 0, (self.WingFraction or 100) < 100 and
                             string.format(", %d%% do time", self.WingFraction) or "")
end

---------------------------------------------------------------------------------------------------
---- O PLANO DO TURNO
----
---- Slot unico: o AIExecutionController processa um time inteiro de cada vez, entao
---- nunca ha dois times pensando no mesmo instante. A chave (time, turno) sozinha ja
---- garante a corretude -- o slot unico e so o formato mais barato de guardar isso.
----
---- Guarda tambem os planos INVALIDOS (`valid = false`). Sem isso, um turno sem
---- inimigos conhecidos reconstruiria o plano em CADA destino -- milhares de vezes por
---- unidade.
----
---- Contem so GEOMETRIA e RANKING, nunca limiares: as properties sao por instancia de
---- policy e o plano e compartilhado por todas elas. Por isso guarda os DOIS modos de
---- linha e os DOIS lados (natural e equilibrado) -- quem escolhe e a policy, na hora
---- de pontuar.
---------------------------------------------------------------------------------------------------
g_RATOAI_EncirclePlan = false

function OnMsg.CombatEnd()
    g_RATOAI_EncirclePlan = false
end

local function EncircleAlive(u)

    return u and not u:IsDead() and not u:IsDowned() and u:IsAware() and
               (IsKindOf(u:GetActiveWeapons(), "Firearm"))
end

---- centroide inteiro. Soma maxima ~ 30 unidades x 2e5 = 6e6: sem risco de estouro.
local function EncircleCentroid(units)
    local n = #units
    if n == 0 then
        return
    end
    local sx, sy = 0, 0
    for _, u in ipairs(units) do
        local x, y = u:GetPosXYZ()
        sx, sy = sx + x, sy + y
    end
    return MulDivRound(sx, 1, n), MulDivRound(sy, 1, n)
end

---- (f, l) de um ponto do mundo, em unidades de mundo.
---- u e v tem comprimento guim, entao o produto escalar sai escalado por guim e a
---- divisao devolve a projecao crua. Magnitude: 2e5 x 1e3 x 2 = 4e8, dentro do inteiro.
function RATOAI_EncircleProject(plan, x, y)
    local dx, dy = x - plan.ax, y - plan.ay
    return MulDivRound(dx * plan.ux + dy * plan.uy, 1, guim),
           MulDivRound(dx * plan.vx + dy * plan.vy, 1, guim)
end

function RATOAI_BuildEncirclePlan(unit, team, turn)
    local plan = {team = team, turn = turn, valid = false}

    local allies = {}
    for _, u in ipairs(team.units or empty_table) do
        if EncircleAlive(u) then
            allies[#allies + 1] = u
        end
    end

    ---- MESMO criterio do AICreateContext: o que o TIME enxerga, com queda para "todos"
    ---- quando ninguem tem visual mas a unidade continua ciente. GetEnemies devolve a
    ---- MESMA tabela compartilhada para o time inteiro, entao o plano nao depende de
    ---- qual unidade o construiu.
    local src = GetEnemies(unit)
    if #(src or empty_table) == 0 then
        src = GetAllEnemyUnits(unit)
    end
    local enemies = {}
    for _, u in ipairs(src or empty_table) do
        if EncircleAlive(u) then
            enemies[#enemies + 1] = u
        end
    end

    if #allies == 0 or #enemies == 0 then
        return plan
    end

    local ax, ay = EncircleCentroid(allies)
    local ex, ey = EncircleCentroid(enemies)
    local sep = point(ax, ay, 0):Dist(point(ex, ey, 0))
    ---- eixo degenerado: os dois centroides no mesmo lugar. O MinSeparationTiles da
    ---- policy corta bem antes disso -- este guarda e o do SetLen, que nao normaliza
    ---- vetor nulo.
    if sep < const.SlabSizeX then
        return plan
    end

    local dir = SetLen(point(ex - ax, ey - ay, 0), guim)
    plan.ax, plan.ay = ax, ay
    plan.ux, plan.uy = dir:x(), dir:y()
    ---- perpendicular no plano: (x, y) -> (-y, x). Mantem o comprimento guim.
    plan.vx, plan.vy = -plan.uy, plan.ux
    plan.sep = sep
    ---- f do centroide inimigo. E exatamente a separacao, porque u aponta de A para E.
    plan.f_enemy = sep

    ---- extensao lateral da formacao inimiga e ponta mais avancada dela (a que esta
    ---- mais perto de nos, ou seja, o MENOR f).
    local l_min, l_max, f_enemy_near
    for _, u in ipairs(enemies) do
        local x, y = u:GetPosXYZ()
        local f, l = RATOAI_EncircleProject(plan, x, y)
        l_min = l_min and Min(l_min, l) or l
        l_max = l_max and Max(l_max, l) or l
        f_enemy_near = f_enemy_near and Min(f_enemy_near, f) or f
    end
    plan.l_min, plan.l_max = l_min, l_max

    ---- dados por unidade + a ponta aliada mais avancada (o MAIOR f)
    local f_ally_far
    local data = {}
    for _, u in ipairs(allies) do
        local x, y = u:GetPosXYZ()
        local f, l = RATOAI_EncircleProject(plan, x, y)
        f_ally_far = f_ally_far and Max(f_ally_far, f) or f
        data[u] = {f = f, l = l, side = (l < 0) and -1 or 1}
    end
    plan.unit = data
    plan.n_units = #allies
    plan.n_enemies = #enemies

    plan.f_line_mid = MulDivRound(plan.f_enemy, 1, 2)
    plan.f_line_gap = MulDivRound(f_ally_far + f_enemy_near, 1, 2)

    ---- ORDEM CANONICA: por |l| crescente, desempate por handle. Serve as duas coisas
    ---- que precisam ser identicas em todas as maquinas -- o ranking de "quem esta na
    ---- ponta" e a escolha de quem troca de lado. Sem o desempate por handle, duas
    ---- unidades a mesma distancia do eixo poderiam sair em ordens diferentes e a
    ---- divergencia entraria no NetUpdateHash.
    local order = table.icopy(allies)
    table.sort(order, function(a, b)
        local la, lb = abs(data[a].l), abs(data[b].l)
        if la ~= lb then
            return la < lb
        end
        return a.handle < b.handle
    end)
    ---- rank 1 = a mais lateral do time (por isso a contagem invertida)
    for i = #order, 1, -1 do
        data[order[i]].rank = #order - i + 1
    end

    ---- EQUILIBRIO: quem troca de lado e sempre quem esta mais PERTO do eixo (inicio de
    ---- `order`), porque e a travessia mais curta e a que menos expoe. Guardado num
    ---- campo separado porque `BalanceSides` e por instancia de policy.
    local count = {[-1] = 0, [1] = 0}
    for _, u in ipairs(order) do
        local d = data[u]
        d.side_balanced = d.side
        count[d.side] = count[d.side] + 1
    end
    local guard = 0
    while abs(count[1] - count[-1]) >= 2 and guard < #order do
        guard = guard + 1
        local big = (count[1] > count[-1]) and 1 or -1
        local moved = false
        for _, u in ipairs(order) do
            local d = data[u]
            if d.side_balanced == big and not d.flipped then
                d.side_balanced = -big
                d.flipped = true
                count[big] = count[big] - 1
                count[-big] = count[-big] + 1
                moved = true
                break
            end
        end
        if not moved then
            break
        end
    end

    plan.valid = true
    return plan
end

function RATOAI_GetEncirclePlan(unit)
    local team = unit and unit.team
    if not team then
        return false
    end
    local turn = g_Combat and g_Combat.current_turn or 0
    local plan = g_RATOAI_EncirclePlan
    if not (plan and plan.team == team and plan.turn == turn) then
        plan = RATOAI_BuildEncirclePlan(unit, team, turn)
        g_RATOAI_EncirclePlan = plan
    end
    return plan.valid and plan or false
end

---------------------------------------------------------------------------------------------------
---- PARAMETROS DERIVADOS, por (unidade, instancia de policy)
----
---- Tudo que nao depende do destino sai do laco quente e mora aqui: o lado ja embutido
---- no eixo lateral, o pico da tenda, a largura da queda e os dois `f` de referencia.
---- O cache vive no `context`, que e recriado a cada turno junto com o plano -- nao ha
---- como servir dado velho. Chaveado pela INSTANCIA da policy (`self`), porque o mesmo
---- archetype pode ter duas com parametros diferentes.
----
---- `false` e um resultado legitimo e cacheado: "esta unidade nao envolve neste turno".
---------------------------------------------------------------------------------------------------
function AIPolicyEncircleEnemy:GetUnitParams(context)
    local cache = context.__encircle_params
    if not cache then
        cache = {}
        context.__encircle_params = cache
    end
    local d = cache[self]
    if d ~= nil then
        return d
    end
    d = self:CalcUnitParams(context) or false
    cache[self] = d
    return d
end

function AIPolicyEncircleEnemy:CalcUnitParams(context)
    local unit = context.unit
    local plan = RATOAI_GetEncirclePlan(unit)
    if not plan then
        return
    end

    ---- times embolados nao tem flanco -- ver a property
    if plan.sep < (self.MinSeparationTiles or 1) * const.SlabSizeX then
        return
    end

    local info = plan.unit[unit]
    if not info then
        ---- reforco que entrou depois do plano do turno: nao esta no ranking, entao vai
        ---- pelo lado natural e sem o portao do `WingFraction`. No turno seguinte entra
        ---- na conta normalmente.
        local f, l = RATOAI_EncircleProject(plan, unit:GetPosXYZ())
        info = {f = f, l = l, side = (l < 0) and -1 or 1}
    elseif (self.WingFraction or 100) < 100 then
        ---- so as N mais laterais do time envolvem. Max(1, ...) garante que a fracao
        ---- nunca zera a manobra inteira por arredondamento.
        local allowed = Max(1, MulDivRound(plan.n_units, self.WingFraction, 100))
        if (info.rank or 1) > allowed then
            return
        end
    end

    local s = self.BalanceSides and (info.side_balanced or info.side) or info.side

    ---- pico da tenda: borda lateral inimiga DAQUELE lado + margem.
    ---- `s * borda` e a largura da formacao para aquele lado -- positiva quando ela se
    ---- estende para la, NEGATIVA quando a formacao inteira esta do outro lado. O Max
    ---- com a margem cobre esse segundo caso: sem ele o objetivo lateral sairia negativo
    ---- e a tenda inverteria, pontuando o lado errado.
    local edge = (s > 0) and plan.l_max or plan.l_min
    local margin = (self.FlankMarginTiles or 0) * const.SlabSizeX
    local G = Max(margin, s * edge + margin)
    if G <= 0 then
        ---- margem 0 com a formacao toda do outro lado: sem objetivo lateral, sem manobra
        return
    end

    local decay = (self.OverrunTiles or 0) * const.SlabSizeX
    if decay <= 0 then
        decay = G ---- tenda simetrica
    end

    local f0 = (self.LineMode == "contact") and plan.f_line_gap or plan.f_line_mid
    local f1 = plan.f_enemy + (self.DepthTiles or 0) * const.SlabSizeX

    ---- teto de avanco: encurta o arco para o alcance de um turno
    local look = (self.ForwardLookaheadTiles or 0) * const.SlabSizeX
    if look > 0 then
        f1 = Min(f1, info.f + look)
    end
    ---- f1 <= f0 acontece de verdade: formacoes interpenetradas com LineMode=contact, ou
    ---- lookahead curto numa unidade atrasada. Sem este piso a rampa dividiria por <= 0.
    if f1 <= f0 then
        f1 = f0 + const.SlabSizeX
    end

    return {
        ax = plan.ax,
        ay = plan.ay,
        ux = plan.ux,
        uy = plan.uy,
        ---- lado ja embutido no eixo lateral: economiza uma multiplicacao por destino e
        ---- deixa o teste "lado errado" ser um unico `<= 0`.
        svx = s * plan.vx,
        svy = s * plan.vy,
        s = s,
        G = G,
        decay = decay,
        f0 = f0,
        f1 = f1,
        share = Clamp(self.LateralShare or 0, 0, 100)
    }
end

---------------------------------------------------------------------------------------------------
---- DIAGNOSTICO
----
---- `const.RATOAI.EncircleDebug = true` no console faz cada destino guardar o passo a
---- passo em context.dest_encircle_debug[dest], que o DEBUG.lua mostra no rollover do
---- voxel. Desligado, custa uma leitura de tabela por destino e nada mais.
----
---- Para ver o PLANO (eixo, linha de frente, faixas de flanco, lado de cada unidade)
---- desenhado no mapa: `RATOAI_DbgEncircle()` no console.
----
---- Para FORCAR o recalculo do plano (centroides, eixo, etc.) sem esperar o turno mudar
---- -- util depois de mover unidades pelo editor -- `RATOAI_RecalcEncirclePlan()` no
---- console. Redesenha o overlay sozinho.
---------------------------------------------------------------------------------------------------
if const.RATOAI.EncircleDebug == nil then
    const.RATOAI.EncircleDebug = false
end

function AIPolicyEncircleEnemy:EvalDest(context, dest, grid_voxel)
    if not dest then
        return 0
    end
    local d = self:GetUnitParams(context)
    if not d then
        return 0
    end

    local x, y = stance_pos_unpack(dest)
    local dx, dy = x - d.ax, y - d.ay

    ---- LATERAL primeiro: metade do mapa (o lado errado) sai daqui, antes de tocar no
    ---- eixo de avanco.
    local w = MulDivRound(dx * d.svx + dy * d.svy, 1, guim)
    if w <= 0 then
        return 0
    end

    local lp
    if w <= d.G then
        lp = MulDivRound(w, 100, d.G)
    else
        lp = 100 - MulDivRound(w - d.G, 100, d.decay)
        if lp <= 0 then
            return 0
        end
    end

    local f = MulDivRound(dx * d.ux + dy * d.uy, 1, guim)
    local fp = Clamp(MulDivRound(f - d.f0, 100, d.f1 - d.f0), 0, 100)
    local score = MulDivRound(lp, d.share + MulDivRound(100 - d.share, fp, 100), 100)

    if const.RATOAI.EncircleDebug then
        local t = const.SlabSizeX
        context.dest_encircle_debug = context.dest_encircle_debug or {}
        context.dest_encircle_debug[dest] = string.format(
                                                "lado %s | lateral %dt de %dt (queda %dt) -> LP %d\n" ..
                                                    "avanco %dt | linha %dt -> fundo %dt -> FP %d\n" ..
                                                    "  LP x (%d%% + %d%% x FP) -> EvalDest %d (x Weight %d)",
                                                d.s > 0 and "+1" or "-1", MulDivRound(w, 1, t),
                                                MulDivRound(d.G, 1, t), MulDivRound(d.decay, 1, t),
                                                lp, MulDivRound(f, 1, t), MulDivRound(d.f0, 1, t),
                                                MulDivRound(d.f1, 1, t), fp, d.share, 100 - d.share,
                                                score, self.Weight or 100)
    end

    return score
end

---------------------------------------------------------------------------------------------------
---- Overlay do plano. `RATOAI_DbgEncircle()` no console, ou passando uma unidade.
---- Desenha: o eixo A->E, as duas linhas de frente (ciano = centroids, amarela =
---- contact), as faixas de flanco dos dois lados para uma margem de referencia, e o
---- lado/rank de cada unidade do time.
---------------------------------------------------------------------------------------------------
function RATOAI_DbgEncircle(unit, margin_tiles)
    unit = unit or (IsKindOf(SelectedObj, "Unit") and SelectedObj)
    if not unit then
        print("RATOAI_DbgEncircle: passe uma unidade (ou selecione uma)")
        return
    end
    local plan = RATOAI_GetEncirclePlan(unit)
    if not plan then
        print("RATOAI_DbgEncircle: sem plano valido para o time de", unit.session_id)
        return
    end

    DbgClearVectors()
    DbgClearTexts()

    ---- volta de (f, l) para o mundo. u e v tem comprimento guim.
    local function P(f, l)
        local x = plan.ax + MulDivRound(f, plan.ux, guim) + MulDivRound(l, plan.vx, guim)
        local y = plan.ay + MulDivRound(f, plan.uy, guim) + MulDivRound(l, plan.vy, guim)
        return point(x, y, terrain.GetHeight(x, y) + MulDivRound(guim, 1, 2))
    end

    local span = Max(plan.l_max - plan.l_min, 8 * const.SlabSizeX) + 12 * const.SlabSizeX
    local margin = (margin_tiles or 6) * const.SlabSizeX

    DbgAddVector(P(0, 0), P(plan.f_enemy, 0) - P(0, 0), const.clrWhite)

    DbgAddVector(P(plan.f_line_mid, -span), P(plan.f_line_mid, span) - P(plan.f_line_mid, -span),
                 const.clrCyan)
    DbgAddVector(P(plan.f_line_gap, -span), P(plan.f_line_gap, span) - P(plan.f_line_gap, -span),
                 const.clrYellow)

    local f_deep = plan.f_enemy + 4 * const.SlabSizeX
    for _, l in ipairs({plan.l_max + margin, plan.l_min - margin}) do
        DbgAddVector(P(plan.f_line_mid, l), P(f_deep, l) - P(plan.f_line_mid, l), const.clrGreen)
        DbgAddCircle(P(f_deep, l), const.SlabSizeX, const.clrGreen)
    end

    DbgAddText(string.format("A (%d)", plan.n_units), P(0, 0), const.clrWhite)
    DbgAddText(string.format("E (%d)", plan.n_enemies), P(plan.f_enemy, 0), const.clrRed)

    for u, info in pairs(plan.unit) do
        DbgAddText(string.format("%s %s r%d", tostring(u.session_id),
                                 (info.side_balanced or info.side) > 0 and "+1" or "-1",
                                 info.rank or 0), u:GetPos(),
                   (info.side_balanced ~= info.side) and const.clrYellow or const.clrWhite)
    end

    print(string.format("Encircle plan: turno %s | %d aliados, %d inimigos | separacao %dt | " ..
                            "lateral inimiga [%dt, %dt] | linha centroids %dt, contato %dt",
                        tostring(plan.turn), plan.n_units, plan.n_enemies,
                        MulDivRound(plan.sep, 1, const.SlabSizeX),
                        MulDivRound(plan.l_min, 1, const.SlabSizeX),
                        MulDivRound(plan.l_max, 1, const.SlabSizeX),
                        MulDivRound(plan.f_line_mid, 1, const.SlabSizeX),
                        MulDivRound(plan.f_line_gap, 1, const.SlabSizeX)))
end

---------------------------------------------------------------------------------------------------
---- RECALCULO MANUAL DO PLANO, pelo console
----
---- O plano so se recalcula sozinho quando o turno MUDA (RATOAI_GetEncirclePlan compara
---- plan.turn com g_Combat.current_turn) -- e de proposito, ver secao 5 do cabecalho: se
---- recalculasse a cada Think, a primeira unidade a andar giraria o eixo para as
---- proximas. Fora do fluxo normal da IA (moveu unidade pelo editor, testando cenario,
---- depurando no meio do turno) essa protecao vira o contrario do que voce quer -- o
---- plano fica velho e voce nao tem como forcar. Esta funcao e essa valvula.
----
---- Aceita uma unidade (ou usa a selecionada) SO para achar o time -- o plano e por time,
---- nao por unidade. Ignora o slot em cache e reconstroi na hora, com as posicoes ATUAIS.
----
---- Nao apaga cache por-unidade (context.__encircle_params, dentro de AIPolicyEncircleEnemy:
---- GetUnitParams): aquele vive no ai_context de cada unidade, que este arquivo nao tem
---- como alcancar daqui. Sem problema para o uso do console -- serve para inspecionar o
---- plano ANTES do turno da IA rodar; se voce recalcular no MEIO do turno de uma unidade
---- que ja pensou, ela so ve o plano novo na proxima vez que pensar.
---------------------------------------------------------------------------------------------------
function RATOAI_RecalcEncirclePlan(unit, redraw)
    unit = unit or (IsKindOf(SelectedObj, "Unit") and SelectedObj)
    if not unit or not unit.team then
        print("RATOAI_RecalcEncirclePlan: passe uma unidade (ou selecione uma) com time valido")
        return false
    end

    local turn = g_Combat and g_Combat.current_turn or 0
    local plan = RATOAI_BuildEncirclePlan(unit, unit.team, turn)
    g_RATOAI_EncirclePlan = plan

    if not plan.valid then
        print("RATOAI_RecalcEncirclePlan: sem plano valido (falta aliado ou inimigo vivo " ..
              "conhecido, ou os dois centroides estao mais perto que a separacao minima)")
        return plan
    end

    print(string.format(
              "RATOAI_RecalcEncirclePlan: recalculado -- %d aliados, %d inimigos, separacao %dt",
              plan.n_units, plan.n_enemies, MulDivRound(plan.sep, 1, const.SlabSizeX)))

    if redraw ~= false then
        RATOAI_DbgEncircle(unit)
    end
    return plan
end
