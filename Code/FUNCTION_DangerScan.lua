---- garante a subtabela: este arquivo DEFINE valores nela. Idempotente, e imune a
---- reordenacao do metadata (o CONSTANTS_AI_source ja a cria, mas nao dependemos disso).
const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- BUGFIX (B47): o planejador da IA e cego ao CAMINHO. So olha o tile onde ela para.
----
---- O QUE ACONTECIA
---- `AIScoreDest` (CombatAI.lua:1135-1160) tem um bloco de perigo no topo -- fogo adjacente
---- (`AreVoxelsInFireRange`), gas (`g_SmokeObjs[head]`) -- e um de zona de bombardeio no fim
---- (`g_Bombard`). Os tres perguntam a MESMA coisa: "o tile FINAL e perigoso?". Nenhum olha os
---- voxels intermediarios.
----
---- Do outro lado, o pathfinder tambem nao olha. `CombatPath:RebuildPaths` (CombatPath.lua:70-72)
---- passa UM unico parametro de perigo para o `GetCombatPathPositions`:
----     local avoid_mines = unit and not player_controlled
---- Ou seja: minas o motor evita; gas, fumaca, fogo e cone de Overwatch nao entram no custo do
---- caminho de jeito nenhum.
----
---- Resultado: a IA sabe nao PARAR na nuvem de gas e atravessa ela alegremente. Sabe nao parar
---- perto do fogo e passa colada nele. E entra em cone de Overwatch de graca -- na EXECUCAO ela
---- leva o tiro (`Unit:CombatGoto` roda `CheckProvokeOpportunityAttacks` e para no ponto de
---- provocacao, Unit.lua:3350-3367), mas o PLANEJAMENTO escolheu o caminho como se fosse gratis.
---- Ela repete: entra no cone, leva a reacao, replaneja, entra de novo.
----
---- O jogo ja tem a funcao que responde isso -- `AnyInterruptsAlongPath` (Utility.lua:1567), que
---- e o aviso vermelho da UI do jogador. Ela NUNCA e chamada pela IA, e nao serve como esta: faz
---- `GetLoFData` por dummy (raycast) e custaria o mundo rodada por destino.
----
---- O QUE ESTE ARQUIVO FAZ
---- Repoe o INSUMO que falta -- "quanto perigo este caminho atravessa" -- como termo aditivo no
---- score do destino, na mesma moeda do `AIAvoidFireWeigth` que ja existe. Continua sendo vies em
---- gradiente: soma ao score, nao manda nele. Um caminho perigoso ate um tile excelente ainda
---- pode ganhar; um caminho perigoso ate um tile mediocre nao ganha mais.
----
---- O QUE ENTRA E O QUE NAO ENTRA
----   gas nocivo  -- SIM, e SO teargas/toxicgas: fumaca comum nao machuca ninguem, so bloqueia
----                  visao. Lista BRANCA em const.RATOAI.PathHarmfulGas -- ver o cabecalho dela
----                  para o buraco que a lista negra do vanilla tem. Mascara de gas anula.
----   fogo        -- SIM. `AreVoxelsInFireRange` e consulta de tabela (`g_DistToFire`), barata.
----   overwatch   -- SIM, por CONE e nao por tile (cruzar dispara a interrupcao uma vez, entao
----                  correr 8 tiles dentro dele nao e 8x pior que cruzar 1) e COM RAMPA DE
----                  DISTANCIA: cruzar a 3 tiles do atirador nao e cruzar na ponta do cone. Por
----                  cone vale o PIOR ponto do trajeto. Ver const.RATOAI.PathOverwatchPlateau.
----   pindown     -- NAO. No GBO3 o `PinDown` virou SNIPE: ataque adiado que dispara no inicio do
----                  proximo turno se o alvo continuar na linha, e NAO uma interrupcao de
----                  movimento. Confirmado tambem no vanilla: `CheckProvokeOpportunityAttacks`
----                  (UnitOverwatch.lua:1247-1320) so tem ramos de trap, melee interrupt e
----                  overwatch -- pindown nunca esteve la. O `Unit:IsThreatened(nil, "pindown")`
----                  testa `g_Pindown[enemy].target == self`, que e "estou MARCADO", nao "meu
----                  caminho cruza alguma coisa". Nao ha cone de pindown a evitar.
----   explosivo timed -- NAO, aqui. Ele detona por RELOGIO, nao por contato: atravessar o raio no
----                  meio do turno e inofensivo, o que mata e TERMINAR o turno dentro dele. Isso e
----                  pergunta de tile final e mora no `AIScoreDest` (ver RATOAI_TimedTrapDanger).
----   mina Contact/Proximity -- NAO. E o unico perigo que o pathfinder ja trata sozinho, pelo
----                  `avoid_mines` acima. Duplicar aqui seria contar duas vezes.
----
---- CUSTO: A ARVORE DE CAMINHOS E MEMOIZAVEL
---- `cpath.paths_prev_pos` mapeia voxel -> voxel anterior, com a origem apontando para `false`.
---- Isso e uma ARVORE enraizada na posicao da unidade: o caminho de qualquer destino e sufixo do
---- caminho do pai dele. Entao o perigo acumulado ate um voxel so precisa ser calculado UMA vez;
---- cada destino novo sobe a arvore ate bater em algo ja memoizado. Amortizado, o laco de
---- destinos custa O(numero de voxels da arvore) no total, e nao O(destinos x comprimento).
----
---- Com tudo desligado (sem gas, sem fogo, sem overwatch inimigo visivel) o custo e tres testes
---- de tabela por TURNO, nao por destino -- o snapshot e resolvido uma vez e guardado no context.
---------------------------------------------------------------------------------------------------

---- Liga/desliga o mecanismo inteiro. Valvula mestra para A/B no console.
const.RATOAI.PathDanger = true

---------------------------------------------------------------------------------------------------
---- EM QUAL PASSE O PERIGO CONTA  ("endturn" | "optloc" | "both")
----
---- `AIScoreDest` serve a DOIS passes que fazem perguntas diferentes, e o mesmo numero nao serve
---- para os dois:
----
----   End-Turn  (AIScoreReachableVoxels) -- "ONDE EU PARO?". Compromisso real. Nota negativa so
----             vira peso 0 na roleta, entao penalizar forte aqui apenas descarta o destino, que
----             e o efeito desejado.
----
----   OptLoc    (AIFindOptimalLocation)  -- "PARA ONDE EU CAMINHO?". E um FAROL, nao um destino:
----             a unidade anda na direcao dele por varios turnos. E aqui esta o problema medido em
----             2026-08-28 (LegionRaider:775, turno 3): `AIFindOptimalLocation` tem
----             `if score > 0 then` (CombatAI.lua:1287) -- nota <= 0 e DESCARTADA, nao ranqueada.
----             Com as notas de OptLoc entre 92 e 339 daquele turno, um -170 nao rebaixava o
----             candidato: APAGAVA. Medido: dos 26 destinos penalizados, 0 sobreviveram no
----             `dest_scores`.
----
---- Isso contraria o "vies em gradiente" do resto do mod: a IA deixa de CONSIDERAR uma boa posicao
---- atras do cone em vez de considera-la e achar cara. Num corredor onde o unico avanco passa pelo
---- cone, ela pode travar.
----
---- DEFAULT "endturn": o perigo de trajeto decide onde PARAR, e nao para onde mirar o avanco. O
---- caminho ate o farol e reavaliado a cada turno de qualquer forma, e e no End-Turn que a escolha
---- de fato acontece.
---- "both" restaura o comportamento de 28/08 (o que voce viu no painel). "optloc" existe so para
---- fechar a matriz de teste.
const.RATOAI.PathDangerScope = "endturn"

---- Idem para o explosivo timed. Default "both" -- este NAO foi medido como problematico, e nao
---- mudo comportamento que nao foi questionado. Parar em cima de bomba armada e ruim nos dois
---- passes; se o descarte no OptLoc incomodar, ponha "endturn" aqui tambem.
const.RATOAI.TimedDangerScope = "both"

---- Penalidades, em pontos de score. Positivas aqui, SUBTRAIDAS na conta -- ler
---- "quanto vale evitar" e mais facil que ler um monte de negativo empilhado.
---- Referencia de escala: `const.AIAvoidFireWeigth` = -200 e o que o jogo cobra para PARAR
---- dentro do fogo. Um tile de caminho vale menos que isso de proposito -- passar nao e parar.
const.RATOAI.PathGasPenalty = 60 ---- por VOXEL de gas nocivo atravessado
const.RATOAI.PathFirePenalty = 60 ---- por VOXEL em alcance de fogo atravessado
---- Por CONE cruzado, e agora e o valor NO PIOR PONTO do trajeto -- a rampa de distancia (abaixo)
---- multiplica isto por 0..100%. Subiu de 130 para 170 junto com a rampa, e a razao merece
---- registro: com valor fixo, 130 valia em qualquer lugar do cone; com rampa, 130 passaria a valer
---- so colado no atirador e TODO o resto do cone ficaria mais barato que antes -- a rampa sozinha
---- so enfraquece o mecanismo. 170 mantem o cruzamento de perto decisivo e deixa a rampa fazer o
---- trabalho dela na cauda. CALIBRAGEM POR RACIOCINIO, nao medida -- ajuste em campo.
const.RATOAI.PathOverwatchPenalty = 100

---- Teto do total. Sem ele um caminho longo dentro da fumaca somaria centenas de pontos e
---- esmagaria todas as policies -- que e exatamente o erro que o `ScalePerDistance` antigo
---- cometia (ver o cabecalho da AIPolicyThreatExposure). Com teto, "ruim" e "pessimo" convergem,
---- que e o comportamento certo: os dois devem perder para qualquer caminho limpo.
const.RATOAI.PathDangerMax = 400

---------------------------------------------------------------------------------------------------
---- QUAIS GASES MACHUCAM  (lista BRANCA, e nao lista negra)
----
---- So `teargas` e `toxicgas` fazem alguma coisa: e o unico lugar em que o proprio jogo separa os
---- tipos (Grenade.lua:2090-2093, e os efeitos em :928 e :988). `smoke` puro e obscurante -- e ate
---- BOM atravessar, porque quebra linha de tiro.
----
---- Lista branca e nao `~= "smoke"` por dois motivos. O primeiro e correcao: `SmokeObj:GetGasType`
---- (Grenade.lua:1997) e `self.zones and self.zones[1] and self.zones[1].gas_type` -- pode devolver
---- **nil ou false**, e com lista negra um voxel de tipo indefinido seria tratado como nocivo.
---- (O `AnyInterruptsAlongPath` do vanilla, Utility.lua:1580, tem exatamente esse buraco.)
---- O segundo e extensibilidade: se um mod acrescentar gas novo, ele entra aqui e nao muda codigo.
----
---- LIMITACAO CONHECIDA, herdada do jogo: um mesmo voxel pode pertencer a VARIAS zonas
---- (`table.insert_unique(obj.zones, self)`, Grenade.lua:2077) e o `GetGasType` so olha a
---- PRIMEIRA. Fumaca comum sobreposta a lacrimogeneo pode se declarar "smoke" e passar batido.
---- Vale o mesmo para o aviso do jogador, entao a IA erra igual ao jogador -- e nao pior.
const.RATOAI.PathHarmfulGas = {teargas = true, toxicgas = true}

---------------------------------------------------------------------------------------------------
---- RAMPA DE DISTANCIA DO OVERWATCH
----
---- Cruzar o cone a 3 tiles do atirador nao e a mesma coisa que cruzar na ponta dele. A penalidade
---- cheia so vale de perto e cai ate a borda do alcance do cone.
----
---- Usa `RATOAI_ThreatRamp` (AIPOLICYPOS_CustomSeekCover.lua) -- a MESMA rampa da Seek Cover e da
---- ThreatExposure, de proposito: as tres nao podem divergir de nocao de "quanto perto e perto".
----
---- `range` da rampa e o `overwatch.dist` do proprio cone, que ja e o alcance efetivo dele
---- (UnitOverwatch.lua:202 o monta com Clamp entre min_range e max_range da arma). Entao:
----     colado / dentro do plato  -> 100 -> penalidade cheia
----     na ponta do cone          ->   0 -> so o piso abaixo
----
---- Por CONE conta o PIOR ponto do trajeto (a maior rampa), nao a soma: cruzar dispara a
---- interrupcao uma vez, e o que importa e de onde o tiro sai melhor para o inimigo.
const.RATOAI.PathOverwatchPlateau = 6 ---- tiles de penalidade cheia. 6 = const.Weapons.PointBlankRange
const.RATOAI.PathOverwatchCurve = 0 ---- 0 = queda linear; 100 = quadratica (afunda a cauda longa)

---------------------------------------------------------------------------------------------------
---- QUEM A IA ENXERGA PARA EFEITO DE CONE  ("team" | "self" | "all")
----
---- Existe por CONSISTENCIA: toda policy de posicao do mod expoe `visibility_mode`
---- (ThreatExposure, CustomSeekCover, CustomWeaponRange, GrenadeRange, MGSetupPosScore...), e este
---- arquivo era o unico lugar do mod com o modo CRAVADO no codigo. Isso e ruim nao pelo default --
---- "team" e o certo -- mas porque impede A/B e esconde a decisao de quem for calibrar depois.
----
----   "team" (default) -- `HasVisibilityTo(unit.team, enemy)`. A IA nao evita cone que o time dela
----            nao avistou. E o fair play do mod: evitar um cone invisivel seria cheat.
----   "self" -- so o que ESTA unidade enxerga agora. Mais restrito que o jogo: o overwatch dispara
----            contra ela independente de quem avistou, entao "self" a deixa levar tiro que o time
----            sabia estar la. Util para isolar, ruim para jogar.
----   "all"  -- ignora visibilidade. Tira a variavel da equacao ao depurar; e cheat em partida.
----
---- ATENCAO, e vale para os tres modos: as duas tabelas sao calculadas UMA vez no AICreateContext,
---- a partir da posicao ATUAL da unidade (`SOURCE_AICreateContext.lua:200-201`). Ou seja, o modo e
---- constante do TURNO e nao varia por destino -- nenhum deles responde "o que eu enxergaria de
---- la". Visibilidade liga/desliga o inimigo inteiro da conta, nunca cria gradiente entre tiles.
---------------------------------------------------------------------------------------------------
const.RATOAI.PathOverwatchVisibility = "team"

---- PISO: cruzar nunca e de graca. Sem ele, um cone cruzado exatamente na borda contribui ZERO --
---- e o inimigo ainda leva o tiro, so que com CTH ruim. E a diferenca entre "pouco perigoso" e
---- "inofensivo", e a rampa sozinha nao sabe expressar a primeira.
---- Em % da PathOverwatchPenalty. 0 desliga o piso e devolve a rampa crua.
const.RATOAI.PathOverwatchMinPct = 15 --15

---------------------------------------------------------------------------------------------------
---- EXPLOSIVO TIMED NO TILE FINAL
----
---- `Unit:IsUnderTimedTrap` (UnitOverwatch.lua:1690) ja existe e faz exatamente esta conta -- mas
---- para a posicao ATUAL da unidade, e so devolve booleano. A IA precisa da versao por POSICAO
---- HIPOTETICA e em gradiente, para ordenar destinos em vez de so reprovar um.
----
---- Gradiente e nao booleano pelo mesmo motivo do `g_Bombard` (AIScoreDest:1176-1184): a borda do
---- raio e muito menos ruim que o centro, e um corte duro faz a IA tratar "um passo pra dentro" e
---- "em cima da bomba" como a mesma coisa.
----
---- Penalidade no CENTRO, caindo linearmente ate 0 na borda do `AreaOfEffect`. Acima do
---- AIAvoidFireWeigth (-200) de proposito: fogo se atravessa e se apaga, bomba armada nao.
const.RATOAI.DestTimedPenalty = 250

---- Diagnostico. `const.RATOAI.PathDangerDebug = true` no console faz cada destino guardar o
---- passo a passo em context.dest_path_danger_debug[dest], que o DEBUG.lua mostra no rollover.
---- Ligue, passe o mouse no tile, leia, desligue -- constroi string para TODO destino.
const.RATOAI.PathDangerDebug = false

local SLAB = const.SlabSizeX

---------------------------------------------------------------------------------------------------
---- QUAL PASSE ESTA RODANDO
----
---- `context.__ratoai_endturn_pass` e ligado pelo override de `AIScoreReachableVoxels`
---- (SOURCE_AIScoreReachableVoxels.lua) e desligado quando ele termina. Funciona porque
---- `AIScoreDest` tem exatamente DOIS chamadores no jogo inteiro -- `AIFindOptimalLocation`
---- (CombatAI.lua:1297) e o proprio `AIScoreReachableVoxels` (:1724 e :1754). Verificado por grep
---- no source em 2026-08-28.
----
---- Ou seja: bandeira ligada = End-Turn; qualquer outra chamada = OptLoc. Nao precisei sobrescrever
---- o AIFindOptimalLocation para isso, o que evita mais uma copia de funcao de source no mod.
----
---- Valor desconhecido cai em "both" DE PROPOSITO. Um scope digitado errado no console tem que
---- deixar o mecanismo ligado, nunca mudo -- mecanismo que parece ligado e nao faz nada e
---- exatamente o erro que o BUGFIX B34 passou uma sessao inteira limpando.
---------------------------------------------------------------------------------------------------
local function scope_ok(context, scope)
    if scope == "both" or scope == nil then
        return true
    end
    local endturn = context.__ratoai_endturn_pass and true or false
    if scope == "endturn" then
        return endturn
    end
    if scope == "optloc" then
        return not endturn
    end
    return true
end

---- Nota no overlay quando o termo existe mas o escopo o desligou. Sem isto, o painel de OptLoc
---- ficaria simplesmente VAZIO -- indistinguivel de "nao ha perigo" e de "a feature quebrou", que
---- foi precisamente a confusao de 28/08. Custa uma string, e so com o debug ligado.
local function note_out_of_scope(context, dest, termo, scope)
    if not const.RATOAI.PathDangerDebug then
        return
    end
    context.dest_path_danger_debug = context.dest_path_danger_debug or {}
    context.dest_path_danger_debug[dest] = string.format(
                                               "%s NAO APLICADO neste passe.\n" ..
                                                   "  escopo atual: %s = %q (passe = %s)\n" ..
                                                   "  ponha \"both\" para valer nos dois.", termo,
                                               termo == "TIMED EXPLOSIVE" and
                                                   "const.RATOAI.TimedDangerScope" or
                                                   "const.RATOAI.PathDangerScope", tostring(scope),
                                               context.__ratoai_endturn_pass and "End-Turn" or
                                                   "OptLoc")
end

---------------------------------------------------------------------------------------------------
---- SNAPSHOT DE PERIGO DO TURNO
----
---- Resolvido UMA vez por context e guardado nele. Nada aqui muda entre destinos: a nuvem de gas,
---- o fogo e os cones plantados sao os mesmos para todos os candidatos da mesma avaliacao.
----
---- Ressalva honesta de validade: o context sobrevive ao turno inteiro da unidade, entao se ela
---- ANDAR e com isso queimar a unica interrupcao de um overwatch (`num_attacks` cai a zero), o
---- snapshot fica velho ate o proximo `AICreateContext`. E vies desatualizado, nao portao -- no
---- pior caso ela evita um cone que ja nao morde mais. Preferi isso a refazer o snapshot em
---- caminho quente.
----
---- Devolve `false` quando nao ha NADA a checar -- e o portao barato que faz o mecanismo custar
---- quase nada em mapa limpo.
---------------------------------------------------------------------------------------------------
local function build_hazards(context)
    local unit = context.unit
    if not unit then
        return false
    end

    ---- Mascara de gas: mesma leitura do AnyInterruptsAlongPath (Utility.lua:1570-1571).
    ---- Mascara com Condition > 0 anula gas nocivo por completo, entao nem se olha g_SmokeObjs.
    local mask = unit:GetItemInSlot("Head", "GasMaskBase")
    local gas = (not mask or mask.Condition <= 0) and next(g_SmokeObjs) ~= nil
    local fire = next(g_Fire) ~= nil

    ---------------------------------------------------------------------------------------------
    ---- Cones de overwatch inimigos.
    ----
    ---- Iterar `context.enemies` e nao `g_Overwatch` de proposito: assim a visibilidade sai de
    ---- graca das tabelas que o context ja montou.
    ----
    ---- `LightStep` desliga o gatilho de overwatch no movimento
    ---- (UnitOverwatch.lua:1313: `trigger_type == "move" and not HasPerk(self, "LightStep")`).
    ---- Quem tem o perk atravessa cone de graca e nao deve pagar vies nenhum.
    ---------------------------------------------------------------------------------------------
    local ow = {}
    if not HasPerk(unit, "LightStep") then
        local vis_mode = const.RATOAI.PathOverwatchVisibility
        for _, enemy in ipairs(context.enemies or empty_table) do
            local data = g_Overwatch[enemy]
            ---- DEBUG (D8): `RATOAI_ThreatCounts` e o filtro de isolamento do painel do Rato Dev.
            ---- Sempre true em partida normal -- ver o cabecalho dele em UTIL.lua.
            if data and (data.num_attacks or 0) > 0 and RATOAI_ThreatCounts(enemy) and
                RATOAI_EnemyVisible(context, enemy, vis_mode) and
                not (enemy:IsDead() or enemy:IsDowned()) and data.pos and (data.dist or 0) > 0 then
                ow[#ow + 1] = {
                    pos = data.pos,
                    ---- `orient` e `angle` sao o mesmo valor no vanilla (os dois saem do mesmo
                    ---- CalcOrientation em UnitOverwatch.lua:223 e :236). O `or` espelha o idioma
                    ---- do Unit:IsThreatened, que le `orient` primeiro.
                    angle = data.orient or data.angle,
                    cone = data.cone_angle or 0,
                    dist = data.dist,
                    min2d = data.min_distance_2d,
                    who = enemy
                }
            end
        end
    end

    if not gas and not fire and #ow == 0 then
        return false
    end

    return {
        unit = unit,
        gas = gas,
        fire = fire,
        ow = ow,
        ---- resolvidos UMA vez: sao constantes e seriam lidos por voxel da arvore
        harmful = const.RATOAI.PathHarmfulGas or empty_table,
        ow_plateau = (const.RATOAI.PathOverwatchPlateau or 0) * SLAB,
        ow_curve = const.RATOAI.PathOverwatchCurve or 0,
        ow_floor = Clamp(const.RATOAI.PathOverwatchMinPct or 0, 0, 100),
        ---- so para o overlay: sem isto nao da para distinguir "nenhum cone visivel" de
        ---- "o modo de visibilidade filtrou todos", que e o tipo de silencio que ja custou uma
        ---- investigacao inteira nesta feature.
        ow_vis = const.RATOAI.PathOverwatchVisibility or "team",
        ---- postura de MOVIMENTO, nao a do destino: os voxels intermediarios sao atravessados
        ---- andando. A postura do destino so e adotada no EndMovement, ja no fim.
        move_stance = context.archetype and context.archetype.MoveStance or unit.stance,
        voxels = {}
    }
end

local function get_hazards(context)
    local hz = context.__ratoai_hazards
    if hz == nil then
        hz = build_hazards(context) or false
        context.__ratoai_hazards = hz
    end
    return hz
end

---------------------------------------------------------------------------------------------------
---- EXPOSICAO AOS CONES NESTE VOXEL
----
---- Preenche `out[i]` com 0..100 para cada cone: 0 = nao cobre este voxel, >0 = cobre e vale tanto
---- da penalidade cheia. Zero significa "nao cruzou", e e por isso que o PISO e aplicado AQUI e
---- nao la na frente -- assim um unico numero carrega as duas informacoes e o acumulador so
---- precisa saber tirar o maximo.
----
---- Separado do `voxel_danger` porque o TILE FINAL precisa so disto: gas e fogo do destino ja sao
---- respondidos pelo bloco do topo do AIScoreDest, e chamar o voxel_danger inteiro para descartar
---- metade custaria um GetVisualVoxels por destino -- no laco mais quente do mod.
---------------------------------------------------------------------------------------------------
local function cone_ramps(voxel, hz, out)
    local ow = hz.ow
    local n = #ow
    if n == 0 then
        return
    end
    local x, y, z = point_unpack(voxel)
    local p = RATOAI_ValidatePosZ(point(x, y, z))
    for i = 1, n do
        local c = ow[i]
        out[i] = 0
        local d = c.pos:Dist2D(p)
        ---- `d > 0` evita o CalcOrientation degenerado em cima do proprio atirador; estar colado
        ---- nele nao e problema de cone de qualquer forma.
        if d > 0 and d <= c.dist and (not c.min2d or d >= c.min2d) then
            ---- teste de setor 2D. Ignora paredes de proposito: o CheckLOS que o motor faz de
            ---- verdade custa raycast, e aqui isso rodaria por voxel da arvore. Superestima o cone
            ---- (marca tile que a parede protegeria), e o erro cai para o lado seguro.
            if abs(AngleDiff(CalcOrientation(c.pos, p), c.angle)) * 2 <= c.cone then
                ---- `c.dist` como range: e o alcance efetivo DESTE cone, nao o da arma solta.
                ---- Na ponta a rampa devolve 0, e ai o piso e que fala.
                out[i] = Max(RATOAI_ThreatRamp(d, c.dist, hz.ow_plateau, hz.ow_curve), hz.ow_floor)
            end
        end
    end
end

---- Custo de gas/fogo deste voxel. Os cones saem por fora (cone_ramps) porque sao acumulados por
---- MAXIMO e nao por soma.
local function voxel_danger(voxel, hz)
    if not hz.gas and not hz.fire then
        return 0
    end

    local cost = 0
    local voxels = hz.voxels
    ---- GetVisualVoxels PREENCHE mas nao limpa (Unit.lua:6116 faz `voxels = voxels or {}`).
    ---- Sem o iclear, um voxel de 2 celulas herdaria a terceira celula do voxel anterior e o
    ---- AreVoxelsInFireRange leria fogo que nao esta no caminho. Mesmo cuidado que o
    ---- AIScoreReachableVoxels toma antes de cada AIScoreDest.
    table.iclear(voxels)
    local _, head = hz.unit:GetVisualVoxels(voxel, hz.move_stance, voxels)

    if hz.gas and head then
        local smoke = g_SmokeObjs[head]
        if smoke then
            ---- lista BRANCA -- ver o cabecalho de const.RATOAI.PathHarmfulGas. GetGasType pode
            ---- devolver nil/false, e nesse caso nada acontece, que e o certo.
            local gt = smoke:GetGasType()
            if gt and hz.harmful[gt] then
                cost = cost + (const.RATOAI.PathGasPenalty or 0)
            end
        end
    end
    if hz.fire and AreVoxelsInFireRange(voxels) then
        cost = cost + (const.RATOAI.PathFirePenalty or 0)
    end

    return cost
end

---------------------------------------------------------------------------------------------------
---- ACUMULADOR MEMOIZADO
----
---- `cost[v]` (gas/fogo, somado) e `ramp[i][v]` (cone `i`, acumulado por MAXIMO) guardam o perigo
---- do trecho ESTRITAMENTE ENTRE a origem e `v` -- nem a origem nem o proprio `v` entram.
----
---- Maximo e nao soma para os cones porque cruzar um cone dispara a interrupcao UMA vez: o que
---- define quanto doi e o melhor ponto de tiro que o inimigo consegue ao longo do trecho, nao
---- quantos tiles foram pisados la dentro. Somar faria um caminho tangente longo parecer pior que
---- um atravessando bem na cara do atirador.
----
----   origem  -- fora porque a unidade JA esta la. Penalizar o gas em que ela ja se encontra
----              tornaria todo destino igualmente ruim e nao ordenaria nada. E o mesmo raciocinio
----              do `break` que o AnyInterruptsAlongPath faz quando o primeiro dummy ja esta
----              dentro da nuvem (Utility.lua:1581-1584).
----   proprio -- fora porque o tile final ja e respondido pelo bloco de fogo/gas do AIScoreDest.
----              Contar aqui tambem seria a mesma penalidade duas vezes. O cone de overwatch no
----              tile final NAO cai nesse caso e e somado a parte por quem chama.
----
---- Sobe a arvore empilhando os voxels ainda nao memoizados e desce preenchendo. Iterativo e nao
---- recursivo: caminho de IA pode ter dezenas de nos e recursao aqui e risco sem ganho nenhum.
---------------------------------------------------------------------------------------------------
---- Preenche `out[i]` com a rampa acumulada do cone `i` ate `voxel` e devolve o custo de gas/fogo.
local function accumulate(prev, slot, voxel, hz, out)
    local cost_tbl, ramp_tbl = slot.cost, slot.ramp
    local scratch, best, cells = slot.scratch, slot.best, slot.cells
    local nc = #hz.ow

    local n = 0
    local v = voxel
    while v and cost_tbl[v] == nil do
        n = n + 1
        scratch[n] = v
        v = prev[v]
    end

    ---- `v` aqui e um voxel ja memoizado, ou `false` (a origem tem prev == false).
    local cost = (v and cost_tbl[v]) or 0
    for i = 1, nc do
        best[i] = (v and ramp_tbl[i][v]) or 0
    end

    for i = n, 1, -1 do
        local w = scratch[i]
        cost_tbl[w] = cost
        for j = 1, nc do
            ramp_tbl[j][w] = best[j]
        end
        ---- `prev[w] == false` identifica a ORIGEM -- ela e memoizada com 0 mas nao contribui.
        if prev[w] then
            cost = cost + voxel_danger(w, hz)
            cone_ramps(w, hz, cells)
            for j = 1, nc do
                if cells[j] > best[j] then
                    best[j] = cells[j]
                end
            end
        end
    end

    for i = 1, nc do
        out[i] = ramp_tbl[i][voxel]
    end
    return cost_tbl[voxel]
end

---------------------------------------------------------------------------------------------------
---- PENALIDADE DE CAMINHO PARA UM DESTINO
----
---- Devolve um numero <= 0, pronto para somar ao score. `x, y, z` sao os do destino ja
---- desempacotados -- quem chama (AIScoreDest) ja os tem, e refazer o unpack seria desperdicio no
---- caminho mais quente do mod.
---------------------------------------------------------------------------------------------------
function RATOAI_PathDanger(context, dest, x, y, z)
    if not const.RATOAI.PathDanger or not context or not dest then
        return 0
    end

    ---- escopo antes de qualquer conta: fora do passe escolhido nao se paga nem a varredura
    local scope = const.RATOAI.PathDangerScope
    if not scope_ok(context, scope) then
        note_out_of_scope(context, dest, "DANGEROUS PATH", scope)
        return 0
    end

    local hz = get_hazards(context)
    if not hz then
        return 0
    end

    ---- Sem caminho ate aqui nao ha o que varrer. E o caso normal em AIFindOptimalLocation, que
    ---- pontua `all_destinations` (inclui voxel fora do alcance de movimento) -- e ali o silencio
    ---- e a resposta certa: o optimal location e um farol para onde caminhar, nao um compromisso
    ---- de fim de turno. Quem escolhe de verdade e o AIScoreReachableVoxels, e la todo destino tem
    ---- caminho.
    local stance_idx = context.dest_combat_path and context.dest_combat_path[dest]
    local cpath = stance_idx and context.combat_paths and context.combat_paths[stance_idx]
    local prev = cpath and cpath.paths_prev_pos
    if not prev then
        return 0
    end

    local voxel = point_pack(x, y, z)
    ---- `prev[voxel]` nil = voxel fora da arvore; `false` = e a propria origem. Nos dois casos nao
    ---- ha trecho percorrido. Mesmo portao do CombatPath:GetCombatPathFromPos (CombatPath.lua:110).
    if not prev[voxel] then
        return 0
    end

    local nc = #hz.ow
    local memo = context.__ratoai_path_memo
    if not memo then
        memo = {}
        context.__ratoai_path_memo = memo
    end
    local slot = memo[stance_idx]
    if not slot then
        slot = {cost = {}, ramp = {}, scratch = {}, best = {}, cells = {}, out = {}}
        ---- uma tabela voxel->rampa POR CONE. Parece muito, mas sao poucos cones e a alternativa
        ---- (uma tabelinha por voxel) alocaria uma tabela por no da arvore -- pressao de GC no
        ---- laco mais quente do mod, que e exatamente o que nao se quer.
        for i = 1, nc do
            slot.ramp[i] = {}
        end
        memo[stance_idx] = slot
    end

    local out = slot.out
    local cost = accumulate(prev, slot, voxel, hz, out)

    ---- O CONE NO TILE FINAL conta. Parar dentro do cone dispara a interrupcao igual a cruzar --
    ---- e ainda deixa a unidade acampada na mira do inimigo. Nao ha duplicidade com o bloco de
    ---- fogo/gas do AIScoreDest: aquele nao sabe nada de overwatch.
    local cells = slot.cells
    cone_ramps(voxel, hz, cells)

    local pen = const.RATOAI.PathOverwatchPenalty or 0
    local ow_total, cones = 0, 0
    for i = 1, nc do
        local r = Max(out[i], cells[i])
        if r > 0 then
            cones = cones + 1
            ow_total = ow_total + MulDivRound(pen, r, 100)
            out[i] = r ---- guarda a rampa efetiva para o bloco de debug
        end
    end

    local total = cost + ow_total
    if total <= 0 then
        return 0
    end

    local cap = const.RATOAI.PathDangerMax or 0
    local capped = total
    if cap > 0 then
        capped = Min(total, cap)
    end

    if const.RATOAI.PathDangerDebug then
        local partes = {}
        for i = 1, nc do
            local r = Max(out[i], cells[i])
            if r > 0 then
                partes[#partes + 1] = string.format("%s %d%% -> %d",
                                                    tostring(hz.ow[i].who.session_id), r,
                                                    MulDivRound(pen, r, 100))
            end
        end
        context.dest_path_danger_debug = context.dest_path_danger_debug or {}
        context.dest_path_danger_debug[dest] = string.format(
                                                   "gas/fogo no trajeto: %d\n" ..
                                                       "cones cruzados: %d de %d visiveis (modo %s)%s\n" ..
                                                       "  total %d (teto %d) -> score %d", cost,
                                                   cones, #hz.ow, tostring(hz.ow_vis),
                                                   #partes > 0 and
                                                       ("\n  " .. table.concat(partes, "\n  ")) or "",
                                                   total, cap, -capped)
    end

    return -capped
end

---------------------------------------------------------------------------------------------------
---- EXPLOSIVO TIMED NO TILE FINAL
----
---- Espelha o filtro do `Unit:IsUnderTimedTrap` (UnitOverwatch.lua:1690-1700), com tres desvios
---- deliberados:
----
---- 1. `Proximity-Timed` tambem conta. Ele VIRA "Timed" no instante em que e armado
----    (Traps.lua:781-783), entao tratar so o "Timed" perderia a bomba no turno em que ela passa a
----    importar. Antes de armar, o lado proximidade dela ja e coberto pelo `avoid_mines` do
----    pathfinder.
----
---- 2. `trap.TriggerType` cru, e nao `rawget(obj, "TriggerType")`. O rawget aparece em
----    `UpdateTimedExplosives` (Traps.lua:588) e ali ele MORDE: `DynamicSpawnLandmine` declara
----    `TriggerType = "Proximity-Timed"` como default de CLASSE (Traps.lua:992), e rawget pula o
----    metatable e devolve nil para toda instancia que nao sobrescreveu o campo. As outras duas
----    leituras do proprio source (`TrapsTickingSound`:676 e `IsUnderTimedTrap`:1692) usam o campo
----    direto -- e sao elas que estao certas.
----
---- 3. Gradiente em vez de booleano, pelo motivo do cabecalho do DestTimedPenalty.
----
---- `trap.visible` e o portao de conhecimento e nao precisa de nada alem: bomba invisivel nao
---- entra, e uma armada e visivel por construcao (so `visible` toca o `ExplosiveTick`,
---- Traps.lua:676-677). E o mesmo criterio do IsUnderTimedTrap -- se ele bastasse menos, o aviso
---- do jogador tambem estaria errado.
---------------------------------------------------------------------------------------------------
---- `context` e `dest` entram so para o escopo e o overlay -- a conta em si depende apenas da
---- posicao. Quem chama e o gancho do AIScoreDest, que ja tem os dois na mao.
function RATOAI_TimedTrapDanger(context, dest, x, y, z)
    local pen = const.RATOAI.DestTimedPenalty or 0
    local traps = g_Traps
    if pen <= 0 or not traps or #traps == 0 then
        return 0
    end

    local scope = const.RATOAI.TimedDangerScope
    if context and not scope_ok(context, scope) then
        note_out_of_scope(context, dest, "TIMED EXPLOSIVE", scope)
        return 0
    end

    local p = RATOAI_ValidatePosZ(point(x, y, z))
    local worst = 0

    for _, trap in ipairs(traps) do
        ---- IsValid PRIMEIRO: ler campo de objeto ja destruido e a ordem errada, mesmo que na
        ---- pratica o g_Traps seja limpo junto. O IsUnderTimedTrap do source nem testa.
        local tt = IsValid(trap) and trap.TriggerType
        if (tt == "Timed" or tt == "Proximity-Timed") and trap.visible and not trap.done and
            not trap:IsDead() and trap:IsValidPos() then
            local r = (trap.AreaOfEffect or 0) * SLAB
            if r > 0 then
                local d = p:Dist(trap:GetPos())
                if d < r then
                    ---- linear: `pen` no centro, 0 na borda. Mesma forma do gradiente de
                    ---- g_Bombard, so que aditiva em vez de multiplicativa -- multiplicar aqui
                    ---- daria zero de penalidade para o tile que ja tem score zero, e o tile em
                    ---- cima da bomba nao pode empatar com um tile qualquer.
                    local v = MulDivRound(pen, r - d, r)
                    if v > worst then
                        worst = v
                    end
                end
            end
        end
    end

    return -worst
end
