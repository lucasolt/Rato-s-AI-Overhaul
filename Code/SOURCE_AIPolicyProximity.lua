---------------------------------------------------------------------------------------------------
---- BUGFIX: AIPolicyProximity nunca funcionou no modo "min" -- que e o DEFAULT.
----
---- Original (Data/ClassDef-AI.lua):
----     local score = 0                      -- inicia em ZERO
----     ...
----         else
----             assert(tdist == "min")
----             if not score or score > dist then   -- `not 0` e FALSE em Lua,
----                 score = dist                    -- e `0 > dist` tambem.
----             end                                 -- a atribuicao nunca roda.
----         end
----
---- Resultado: com TargetDist = "min", a policy devolve 0 sempre, qualquer que seja
---- o Weight. Atinge todos os usos que existem hoje, porque nenhum sobrescreve o
---- default: ActiveCivilian e CorazonBoss no vanilla, e o Panicked deste mod.
----
---- Segundo bug, no modo "average": `num` e declarado como 0 e nunca incrementado,
---- entao `if tdist == "average" and num > 0` nunca dispara e a media nunca e
---- calculada -- "average" se comportava igual a "total".
----
---- Correcoes:
----   1. `score` comeca nil, entao o primeiro `not score` pega;
----   2. `num` e incrementado de verdade, e a media usa divisao inteira;
----   3. distancia em tiles via MulDivRound em vez de `/ scale` (o original
----      produzia fracao, que entra no NetUpdateHash de AIScoreReachableVoxels);
----   4. ignora unidades mortas/incapacitadas -- `context.allies` e o time inteiro,
----      cadaver incluso, e distancia para cadaver nao diz nada.
----
---- SEMANTICA (nao mudou): o score E a distancia, entao Weight positivo AFASTA.
---- Para aproximar, use AIPolicyStayNearAllies, que devolve 0..100 normalizado.
---------------------------------------------------------------------------------------------------

function AIPolicyProximity:EvalDest(context, dest, grid_voxel)
    local unit = context.unit
    local target_enemies = self.TargetUnits == "enemies"
    local units = target_enemies and context.enemies or context.allies
    local tdist = self.TargetDist

    local score, num = nil, 0
    local scale = const.SlabSizeX

    for _, other in ipairs(units or empty_table) do
        if other ~= unit and IsValid(other) and not other:IsDead() then
            local upos
            if target_enemies then
                upos = context.enemy_pack_pos_stance[other]
            else
                upos = context.ally_pack_pos_stance[other]
                if self.AllyPlannedPosition and other.ai_context then
                    upos = other.ai_context.ai_destination or upos
                end
            end

            if upos then
                local dist = MulDivRound(stance_pos_dist(dest, upos), 1, scale)
                num = num + 1
                if tdist == "total" or tdist == "average" then
                    score = (score or 0) + dist
                elseif not score or score > dist then
                    ---- "min": distancia ao mais proximo
                    score = dist
                end
            end
        end
    end

    if tdist == "average" and num > 0 then
        score = MulDivRound(score or 0, 1, num)
    end

    score = score or 0
    return score >= self.MinScore and score or 0
end
