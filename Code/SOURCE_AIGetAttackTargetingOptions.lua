---------------------------------------------------------------------------------------------------
---- PESO DA PARTE = CHANCE x RETORNO  (e memoizacao por turno)
----
---- DUAS MUDANCAS.
----
---- 1. O `chance` deixou de ser a CTH crua. A CTH sozinha ordena as partes pelo que e FACIL
----    acertar, e por construcao isso e sempre o torso -- ela ja carrega a penalidade de tiro
----    localizado e nao carrega nada do que o tiro localizado ganha. Multiplicar pelo
----    RATOAI_BodyPartMul (o `damage_mod` do preset do jogo, Head +80 / Legs -50, vezes o bonus
----    de efeito) transforma o peso em RETORNO ESPERADO. O sorteio continua sendo sorteio -- a
----    variedade e desejavel e o InteractionRand tem de continuar sendo consumido -- mas passa a
----    sortear proporcional ao que cada parte rende, nao ao que e facil.
----
---- 2. Memoizacao por (alvo, acao, targeting) dentro do context. Esta funcao chama
----    `action:GetActionResults` UMA VEZ POR PARTE, que e caro, e agora ela e chamada duas vezes
----    no mesmo turno: pelo SingleShotTargeted_CustomScoring (BUGFIX B31, para o peso descrever a
----    mesma parte que o tiro) e pelo PrecalcAction logo depois. Sem o memo, o conserto do B31
----    dobraria o custo; com ele, sai de graca.
----
----    A chave usa a IDENTIDADE da tabela `targeting`, que e a do preset e portanto estavel. O
----    context morre no fim do turno da unidade, entao nao ha invalidacao a fazer.
---------------------------------------------------------------------------------------------------
function AIGetAttackTargetingOptions(unit, context, target, action, targeting)
    local body_parts
    targeting = targeting or context.archetype.BaseAttackTargeting
    ----
    local valid, fallback = false, {}
    ---

    local memo
    if context and target and targeting then
        memo = context.__ratoai_targeting_memo
        if not memo then
            memo = {}
            context.__ratoai_targeting_memo = memo
        end
        local por_alvo = memo[target]
        if not por_alvo then
            por_alvo = {}
            memo[target] = por_alvo
        end
        local chave = tostring((action or context.default_attack or empty_table).id) .. "|" ..
                          tostring(targeting)
        local cache = por_alvo[chave]
        if cache then
            return cache
        end
        memo = {por_alvo = por_alvo, chave = chave}
    end
    if IsKindOf(target, "Unit") and targeting then
        action = action or context.default_attack
        ---
        local args = {target = target, aim = 3}
        ---
        local parts = target:GetBodyParts(context.weapon)
        for _, part in ipairs(parts) do
            args.target_spot_group = part.id
            local results = action:GetActionResults(unit, args)
            body_parts = body_parts or {}
            results.chance_to_hit = results.chance_to_hit or 0
            -- table.insert(body_parts, {id = part.id, chance = results.chance_to_hit})
            if results.chance_to_hit > 0 then
                ---- chance x retorno da parte, ver o cabecalho. Piso 1: uma parte com CTH > 0
                ---- nunca pode virar peso ZERO no sorteio so porque o damage_mod dela e ruim --
                ---- isso a tiraria da lista na pratica, e a decisao de nao mirar perna e do
                ---- scoring, nao deste sorteio.
                local peso = Max(1, MulDivRound(results.chance_to_hit,
                                                RATOAI_BodyPartMul(part.id), 100))
                table.insert(fallback, {id = part.id, chance = peso})
                if targeting[part.id] then
                    valid = true
                    -----
                    table.insert(body_parts, {id = part.id, chance = peso})
                    -----
                end
            end
        end
    end
    ----
    local res = valid and body_parts or fallback
    if memo then
        memo.por_alvo[memo.chave] = res
    end
    return res
    ----
end

