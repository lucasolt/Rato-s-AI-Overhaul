---------------------------------------------------------------------------------------------------
---- AIPolicyHighGround normalizada.
----
---- Original (Data/ClassDef-AI.lua):
----     return self.Weight * (z - uz)
----
---- Tres problemas, medidos no jogo rodando:
----
----   1. PESO AO QUADRADO. O AIScoreDest ainda faz MulDivRound(peval, Weight, 100),
----      entao a contribuicao real era Weight^2/100 x dZ. Weight 80 -> 64 por voxel;
----      Weight 200 -> 400 por voxel. Dobrar o peso quadruplicava o efeito, o que
----      torna a policy impossivel de sintonizar junto com as outras.
----
----   2. LINEAR E SEM TETO. Era a unica policy ilimitada da lista -- num mapa
----      vertical ela sozinha decidia o best_dest.
----
----   3. DESCONECTADA DO BENEFICIO REAL. Medicoes (SlabSizeZ=700, 1 andar =
----      CameraTacFloorHeight 2800 = 4 voxels Z; GroundDifference Min=10 Max=20
----      limiar=300%=3 voxels):
----
----         dZ  andares   CTH real
----          1-2   1/4-1/2    0
----          3     3/4      +10
----          4     1        +10.5
----          8     2        +12.5
----         12     3        +14.5
----         20     5        +18.5
----         23+    ~6       +20  (teto)
----
----      Ou seja: o primeiro andar vale +10, cada andar seguinte ~+2. A policy
----      pagava linear: achava 5 andares 5x melhor que 1, quando e 1,8x.
----
---- ESCOLHA DE PROJETO: a curva aqui NAO copia o degrau do modelo de CTH.
---- O limiar de 3 voxels do jogo faria um degrau ou meio andar valer zero, e a IA
---- nunca daria o primeiro passo rumo ao telhado. Como esta policy vive so no
---- OptLoc -- onde ela representa "estou indo na direcao certa" ao longo de varios
---- turnos, e nao o bonus de tiro deste disparo -- ela premia desde dZ=1 e satura.
----
---- Fica SO no OptLoc de proposito (a classe nao declara end_of_turn). No fim de
---- turno a altura ja e paga pelo DealDamage: RATOAI_ScoreAttacksDetailed chama
---- CalcChanceToHit, que avalia o preset GroundDifference. Colocar a policy tambem
---- nas EndTurnPolicies contaria altura duas vezes. No OptLoc o DealDamage nao pode
---- rodar (dest_target_score ainda esta vazio), entao la ela e a unica representacao
---- de altura que existe.
---------------------------------------------------------------------------------------------------

---- curva "front-loaded": sobe rapido e achata, imitando o formato da curva de CTH.
----   f(d) = 100 * d * (2F - d) / F^2,  saturando em 100 quando d >= F
---- Com F = 8 (2 andares):  dZ=1 -> 23   dZ=4 (1 andar) -> 75   dZ=8 -> 100
local function FrontLoaded(d, full)
    if d <= 0 then
        return 0
    end
    if d >= full then
        return 100
    end
    return MulDivRound(d * (2 * full - d), 100, full * full)
end

function AIPolicyHighGround:EvalDest(context, dest, grid_voxel)
    local _, _, z = point_unpack(grid_voxel)
    if not z then
        return 0
    end

    local full = Max(1, self.FullBonusDz or 8)
    local ref

    if self.Reference == "enemies" then
        ---- altura relativa aos INIMIGOS: taticamente correto (e o que o CTH mede),
        ---- e mantem score alto enquanto voce estiver por cima. Custo: vira uma
        ---- policy QUALIFICANTE -- pontua alto tambem no tile atual, inflando o piso
        ---- do OptLoc (ver Falha A no guia).
        local sum, num = 0, 0
        for _, enemy in ipairs(context.enemies or empty_table) do
            local ev = context.enemy_grid_voxel and context.enemy_grid_voxel[enemy]
            if ev then
                local _, _, ez = point_unpack(ev)
                if ez then
                    sum = sum + ez
                    num = num + 1
                end
            end
        end
        if num == 0 then
            return 0
        end
        ref = MulDivRound(sum, 1, num)
    else
        ---- default "self": altura relativa a posicao ATUAL da unidade.
        ---- Vale 0 no tile atual por construcao, entao e DISCRIMINANTE e nao infla
        ---- o piso. Em compensacao, precisa da penalidade de descida para a unidade
        ---- que ja esta em cima nao ser puxada para baixo pelas outras policies.
        local _, _, uz = point_unpack(context.unit_grid_voxel)
        if not uz then
            return 0
        end
        ref = uz
    end

    local d = z - ref
    if d >= 0 then
        return FrontLoaded(d, full)
    end

    ---- descida: mesma curva, com teto proprio e menor.
    ---- Menor de proposito: o jogo NAO penaliza terreno baixo (o ramo Low Ground do
    ---- preset GroundDifference esta comentado no source, `return false, 0`). A
    ---- penalidade aqui existe so para nao abrir mao da altura ja conquistada, nao
    ---- para modelar perda de CTH -- por isso nao e simetrica.
    local down = Max(0, self.DownhillMax or 60)
    return -MulDivRound(FrontLoaded(-d, full), down, 100)
end
