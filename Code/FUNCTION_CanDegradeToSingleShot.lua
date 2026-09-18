const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- DEGRADAR PARA TIRO UNICO NA HORA DE ATIRAR
----
---- O PROBLEMA E DE TEMPO, NAO DE CONTA. O AICreateContext ja escolhe SingleShot quando nao ha AP
---- para "stance + rajada" -- mas ele decide na CRIACAO DO CONTEXTO, com o AP cheio e antes de
---- qualquer movimento. Depois a unidade anda (ou e interrompida no meio, o que uma mina faz), e
---- chega no destino com menos AP do que a decisao pressupos. O `context.default_attack` continua
---- sendo BurstFire, o AIPlayAttacks pede o plano, recebe ZERO ataques, e o turno acaba com AP
---- sobrando e nenhum tiro dado -- mesmo havendo AP de sobra para um tiro unico.
----
---- Foi assim que apareceu em campo: unidade parada por mina, entrou em stance, e nao atirou.
----
---- QUANDO ESTA FUNCAO RODA. So na chamada de EXECUCAO do AICalcAttacksAndAim -- a que o
---- AIPlayAttacks faz com dois argumentos (`AICalcAttacksAndAim(context, unit.ActionPoints)`).
---- O jeito de reconhece-la e `context.AIisPlayingAttacks and not target_dist`: a predicao SEMPRE
---- passa distancia, a execucao nunca passa. Nao e idioma inventado aqui -- e o mesmo teste que o
---- FUNCTION_ShouldMaxAim.lua:23 ja usa para a mesma distincao.
----
---- Isso importa: se rodasse na predicao, ela trocaria o ataque padrao no meio do laco de
---- destinos e todo o scoring passaria a comparar acoes diferentes entre si.
----
---- O QUE FICA INCONSISTENTE, e e aceitavel. O scoring do turno (dest_hit_score, as razoes de
---- resultado esperado) foi calculado com a rajada; a execucao sai com tiro unico. Os numeros do
---- painel vao descrever a acao que NAO foi disparada. E o preco de consertar no ultimo momento
---- possivel -- e o outro lado da moeda e nao atirar, que e pior.
---------------------------------------------------------------------------------------------------

---- Modos cujo uso depende da municao carregada (GBO3 troca chumbo <-> slug pelo GetUIState).
local RATOAI_AmmoSwappedModes = {SingleShot = true, BurstFire = true, CancelShot = true}
local RATOAI_BuckshotModes = {Buckshot = true, BuckshotBurst = true, DoubleBarrel = true, CancelShotCone = true}

---- Mesma regra do Unit:GetDefaultAttackAction: listado em AvailableAttacks E nao "hidden" no
---- GetUIState. So a lista nao basta -- o GBO3 lista SingleShot em toda escopeta (modo slug).
function RATOAI_IsAttackModeAvailable(unit, weapon, action_id)
    local action = CombatActions[action_id or false]
    if not (unit and action and IsKindOf(weapon, "Firearm")) then
        return false
    end
    local listed = weapon.AvailableAttacks and table.find(weapon.AvailableAttacks, action_id)
    if not listed and not (action_id == "AutoFire" and weapon:CanAutofire()) then
        return false
    end
    if IsKindOf(weapon, "Shotgun") then
        local slug = IsSlugLoaded(weapon)
        if (slug and RATOAI_BuckshotModes[action_id]) or (not slug and RATOAI_AmmoSwappedModes[action_id]) then
            return false
        end
    end
    local ok, state = pcall(action.GetUIState, action, {unit}, {weapon = weapon, skip_ap_check = true})
    return ok and state ~= "hidden"
end

function RATOAI_TryDegradeToSingleShot(context, ap_in, target_dist)
    ---- so na execucao, e uma vez por turno
    if target_dist or not context.AIisPlayingAttacks or context.__ratoai_degraded then
        return
    end

    local weapon, unit = context.weapon, context.unit
    local atual = context.default_attack
    if not (weapon and unit and atual) or atual.id == "SingleShot" then
        return
    end
    if not RATOAI_IsAttackModeAvailable(unit, weapon, "SingleShot") then
        return
    end

    local single = CombatActions.SingleShot
    ---- pcall: o GetAPCost do GBO3 passa por componentes de arma e por Unit:*; um mod de terceiro
    ---- que quebre ali nao pode derrubar o turno da IA.
    local ok, cost = pcall(single.GetAPCost, single, unit)
    if not ok or type(cost) ~= "number" or cost <= 0 then
        return
    end

    ---- marca ANTES de recursar: o AICalcAttacksAndAim vai chamar esta funcao de novo se o tiro
    ---- unico tambem nao couber, e ai a resposta certa e mesmo zero.
    context.__ratoai_degraded = true
    context.default_attack = single
    context.default_attack_cost = cost
    if weapon.GetAutofireShots then
        context.burst_shots = Max(1, weapon:GetAutofireShots(single) or 1)
    end

    if RATOAI_Debug then
        printf("[RATOAI] %s: %s nao coube no AP do destino, degradando para SingleShot",
               tostring(unit.session_id), tostring(atual.id))
    end

    return AICalcAttacksAndAim(context, ap_in, target_dist)
end
