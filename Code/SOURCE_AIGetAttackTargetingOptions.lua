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
---------------------------------------------------------------------------------------------------
---- IMPLICIT HEAD AIM (aCTH). A torso-only single shot also weighs the head, priced by its share
---- (RATOAI_AimedPartMul). The cone centers where the aim is, so a head over cover or a prone
---- target can be the better aim; the value only says so when the geometry does. Bursts are out:
---- the ladder climbs off a head.
---------------------------------------------------------------------------------------------------
const.RATOAI = const.RATOAI or {}
if const.RATOAI.HeadAimWithTorso == nil then
    const.RATOAI.HeadAimWithTorso = true
end

local TORSO_ONLY = {Torso = true}

function RATOAI_ImplicitHeadAim(unit, context, action, targeting)
    if not const.RATOAI.HeadAimWithTorso or not action then
        return false
    end
    if targeting and (not targeting.Torso or targeting.Head) then
        return false
    end
    local weapon = context.weapon
    if not RATOAI_AngularOn(weapon, action, unit) or action.AimType ~= "line" then
        return false
    end
    return (weapon:GetAutofireShots(action) or 1) <= 1
end

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
    action = action or context.default_attack
    local head_opt = RATOAI_ImplicitHeadAim(unit, context, action, targeting)
    local parts_set = targeting or (head_opt and TORSO_ONLY)
    if IsKindOf(target, "Unit") and parts_set then
        local implicit_head
        for _, part in ipairs(target:GetBodyParts(context.weapon)) do
            local listed = parts_set[part.id]
            local implicit = head_opt and part.id == "Head"
            ---- with no preset set only torso and the implicit head are worth a CTH call
            if targeting or listed or implicit then
                ---- CalcChanceToHit, not GetActionResults: same number (measured), but no pellet
                ---- scatter rolled on attacker:Random, and the head share comes back in `args`
                local args = {target = target, aim = 3, target_spot_group = part.id}
                local ok, cth = pcall(unit.CalcChanceToHit, unit, target, action, args,
                                      "chance_only")
                cth = ok and cth or 0
                body_parts = body_parts or {}
                if cth > 0 then
                    ---- chance x retorno da parte, ver o cabecalho. Piso 1: uma parte com CTH > 0
                    ---- nunca pode virar peso ZERO no sorteio so porque o damage_mod dela e ruim --
                    ---- isso a tiraria da lista na pratica, e a decisao de nao mirar perna e do
                    ---- scoring, nao deste sorteio.
                    local share = args.rat_head_share
                    local opt = {
                        id = part.id,
                        chance = Max(1, MulDivRound(cth, RATOAI_AimedPartMul(part.id, share), 100)),
                        share = share
                    }
                    table.insert(fallback, opt)
                    if listed then
                        valid = true
                        table.insert(body_parts, opt)
                    elseif implicit then
                        implicit_head = opt
                    end
                end
            end
        end
        ---- the implicit head joins the draw only when it is worth more than the torso
        if valid and implicit_head then
            local torso = table.find_value(body_parts, "id", "Torso")
            if not torso or implicit_head.chance > torso.chance then
                table.insert(body_parts, implicit_head)
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

