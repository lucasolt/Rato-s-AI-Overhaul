local RATOAI_originalAIPlayAttacks = AIPlayAttacks

---------------------------------------------------------------------------------------------------
---- BUGFIX (B43): aqui houve um `AIReloadWeapons(unit)` antes da chamada original, para cobrir
---- "carregador vazio no inicio do turno" -- o caso em que o laco de ataques do AIPlayAttacks
---- dispara sem municao, falha, e a unidade perde o turno.
----
---- REMOVIDO: era redundante. `AIReloadWeapons` tem TRES call sites, e o que importa aqui nao e
---- nenhum dos dois do AIPlayAttacks (CombatAI.lua:260/318) e sim a PRIMEIRA LINHA de
---- `Unit:StartAI` (Unit.lua:8912) -- antes do SelectArchetype, do behavior e do AICreateContext.
---- A arma ja chega recarregada tanto ao Think quanto a execucao; o caso que se queria cobrir nao
---- existia.
----
---- Fica registrado porque a suposicao errada ("so recarrega depois de atacar") foi o que motivou
---- tambem a AISignatureAction descartada em AIACTION_Reload.lua. Antes de reintroduzir qualquer
---- coisa nessa linha: sao tres call sites, confira os tres.
---------------------------------------------------------------------------------------------------
---- BUGFIX (B56): the status ("restart" etc.) was dropped, so CombatAI.lua:505 always fell
---- through to AITakeCover and TargetChangePolicy = "restart" never restarted.
---- Ends its attacks seeing no enemy: the engine's fallback overwatch (CombatAI.lua:381) only covers
---- a unit that never moved, so these ended with 9-12 AP idle (measured, G8 Raiders 452-454).
---- Aim at the nearest enemy the team sees, else at the suspected spot.
local function RATOAI_LeftoverOverwatch(unit, context)
    if not IsValid(unit) or unit:IsDead() or unit:HasPreparedAttack() or context.reposition then
        return
    end
    for _, enemy in ipairs(context.enemies or empty_table) do
        if IsValidTarget(enemy) and HasVisibilityTo(unit, enemy) then
            return
        end
    end
    local pos, best
    for _, enemy in ipairs(context.enemies or empty_table) do
        if IsValidTarget(enemy) and HasVisibilityTo(unit.team, enemy) then
            local d = unit:GetDist(enemy)
            if not best or d < best then
                pos, best = enemy:GetPos(), d
            end
        end
    end
    local lk = unit.last_known_enemy_pos
    pos = pos or (lk and RATOAI_ValidatePosZ(lk))
    local args = RATOAI_OverwatchArgsAt(context, pos)
    if args and AIPlayCombatAction("Overwatch", unit, nil, args) then
        while not unit:IsIdleCommand() do
            WaitMsg("Idle", 50)
        end
    end
end

---- The engine queued this unit for Unaware (CombatAI.lua:388). With something to look for it holds,
---- and once per turn re-thinks as a scout; only the blind combat end reverts it then.
local function RATOAI_BlindInsteadOfRevert(unit, context)
    if not g_Combat or not table.find(g_UnawareQueue, unit) then
        return
    end
    local target = RATOAI_BlindSearchTarget(unit, context)
    if not target then
        return
    end
    table.remove_value(g_UnawareQueue, unit)
    local turn = g_Combat.current_turn
    if RATOAI_IsScoutArchetype(context.archetype and context.archetype.id) or
        unit.ratoai_blind_search_turn == turn or unit.ActionPoints < 2 * const.Scale.AP then
        return
    end
    unit.ratoai_blind_search_turn = turn
    unit.last_known_enemy_pos = target
    unit.ai_context = nil
    unit:StartAI()
    if not unit.ai_context then
        unit.ai_context = context
        return
    end
    if RATOAI_Debug then
        printf("[RATOAI] %s: blind, searching as %s instead of reverting", tostring(unit.session_id),
               tostring(unit.current_archetype))
    end
    return "restart"
end

---- Attack phase spent no AP but a hipfire fits (Stormer 517, H8 night: 30 AP idle beside a 97% target).
local function RATOAI_LeftoverShot(unit, context, ap_before, planned)
    if not const.RATOAI.LeftoverShot or not IsValid(unit) or unit:IsDead() or context.reposition then
        return
    end
    if unit.ActionPoints < ap_before or unit:HasPreparedAttack() then
        return
    end
    local action, weapon = context.default_attack, context.weapon
    if not action or not IsKindOf(weapon, "Firearm") or IsKindOf(weapon, "HeavyWeapon") then
        return
    end
    local function usable(t)
        return IsValidTarget(t) and not (IsKindOf(t, "Unit") and t:IsIncapacitated()) and
                   HasVisibilityTo(unit, t)
    end
    local target = usable(planned) and planned
    if not target then
        local best
        for _, enemy in ipairs(context.enemies or empty_table) do
            if usable(enemy) then
                local d = unit:GetDist(enemy)
                if not best or d < best then
                    target, best = enemy, d
                end
            end
        end
    end
    local tag = tostring(unit.session_id)
    if not target then
        if RATOAI_Debug and IsValid(planned) then
            printf("[RATOAI] %s: leftover shot skipped, planned target %s not visible (%d AP)", tag,
                   tostring(planned.session_id), unit.ActionPoints)
        end
        return
    end
    local args, has_ap = AIGetAttackArgs(context, action, "Torso", "None", target)
    args.num_shots = action.rat_num_shots
    if not has_ap then
        if RATOAI_Debug then
            printf("[RATOAI] %s: leftover shot skipped, %s costs %d, has %d AP", tag,
                   tostring(action.id), action:GetAPCost(unit, args), unit.ActionPoints)
        end
        return
    end
    local cth_args = table.copy(args)
    cth_args.prediction = true
    cth_args.rat_full = true
    local ok, cth = pcall(unit.CalcChanceToHit, unit, target, action, cth_args, "chance_only")
    if not ok or type(cth) ~= "number" or cth < RATOAI_MinShotCTH(context, weapon) then
        return
    end
    if RATOAI_Debug then
        printf("[RATOAI] %s: leftover shot %s at %s, CTH %d, %d AP", tag, tostring(action.id),
               tostring(target.session_id), cth, unit.ActionPoints)
    end
    AIPlayCombatAction(action.id, unit, nil, args)
end

function AIPlayAttacks(unit, context, dbg_action, force_or_skip_action)
    context.AIisPlayingAttacks = true
    local ap_before = unit.ActionPoints
    local dest = not force_or_skip_action and context.ai_destination or GetPackedPosAndStance(unit)
    local planned = context.dest_target and context.dest_target[dest]
    local status = RATOAI_originalAIPlayAttacks(unit, context, dbg_action, force_or_skip_action)
    if not status and not IsSetpiecePlaying() then
        local ok, res = pcall(RATOAI_BlindInsteadOfRevert, unit, context)
        if not ok then
            print("[RATOAI] RATOAI_BlindInsteadOfRevert failed --", res)
        elseif res then
            context.AIisPlayingAttacks = false
            return res
        end
        if not force_or_skip_action then
            ok, res = pcall(RATOAI_LeftoverShot, unit, context, ap_before, planned)
            if not ok then
                print("[RATOAI] RATOAI_LeftoverShot failed --", res)
            end
        end
        local ok, err = pcall(RATOAI_FireTailBurst, unit, context, force_or_skip_action)
        if not ok then
            print("[RATOAI] RATOAI_FireTailBurst failed --", err)
        end
        if not force_or_skip_action then
            ok, err = pcall(RATOAI_LeftoverOverwatch, unit, context)
            if not ok then
                print("[RATOAI] RATOAI_LeftoverOverwatch failed --", err)
            end
        end
    end
    context.AIisPlayingAttacks = false
    return status
end

---------------------------------------------------------------------------------------------------
---- SUSTENTAR O MODO DE TIRO ESCOLHIDO  (propriedade `SustainedAttack`)
----
---- O QUE O VANILLA FAZ. A AIPlayAttacks (CombatAI.lua:255-310) executa a signature UMA vez,
---- desconta 1 de `max_attacks`, e o resto do turno vai para o bloco "revert to basic attacks",
---- que dispara `context.default_attack.id` num laco de N. O AIActionSingleTargetShot:Execute e
---- literalmente um `AIPlayCombatAction` solto -- nao ha laco nenhum do lado da signature.
----
---- POR QUE ISSO E UM PROBLEMA AQUI E NAO NO VANILLA. La as signatures sao acoes especiais
---- (granada, MG, pin down) e "uma vez por turno" e o desenho. Aqui elas tambem sao os MODOS DE
---- TIRO, e o RATOAI_ExpectedFor pontua cada candidata com `AICalcAttacksAndAim` usando o custo
---- DELA -- ou seja, com N ataques daquela acao. Com a rajada a 4 AP e 12 AP no destino, o score
---- comparou 3 rajadas e a execucao entregava 1 rajada + o que o GetDefaultAttackAction mandasse.
----
---- O QUE ESTA FUNCAO FAZ. Troca o ataque padrao do CONTEXT pela acao que acabou de disparar.
---- O laco de revert entao continua no mesmo modo, e a premissa do scoring passa a valer.
---- Nao ha laco novo, nem copia da AIPlayAttacks: quem conta os ataques e reparte o AP continua
---- sendo o mesmo AICalcAttacksAndAim de sempre, so que agora sobre a acao certa.
----
---- OS TRES CAMPOS ANDAM JUNTOS. `default_attack` sozinho nao basta:
----   `default_attack_cost` -- o AICalcAttacksAndAim orca com ele; sem trocar, a unidade
----                            contaria rajadas ao preco de tiro unico (ou o contrario);
----   `burst_shots`         -- balas por ataque, lido pelo RATOAI_ScoreAttacksDetailed se um
----                            precalc rodar de novo no meio do turno (troca de alvo).
---- Custo NU (`GetAPCost(unit)` sem args), a mesma convencao do AICreateContext -- senao o custo
---- viria com stance/mira embutidos e o planejador somaria os dois de novo.
----
---- E O PLANO DE MIRA TEM DE CAIR. `__ratoai_aim_force` foi escolhido pelo RATOAI_EnsureAimPlan
---- para o ataque padrao ANTIGO, comparando niveis de mira daquele ataque. Mantido, ele seria
---- aplicado a uma acao que nunca foi avaliada -- e o AICalcAttacksAndAim honra o forcado sempre
---- que `action == context.default_attack`, que passou a ser verdade para a acao nova. Zerar faz
---- o planejador voltar a heuristica de distancia, que e o comportamento correto na falta de um
---- plano proprio.
---------------------------------------------------------------------------------------------------
function RATOAI_SustainFiringMode(action, context)
    if not (action and action.SustainedAttack and context) then
        return
    end

    local caction = RATOAI_SignatureAttack(action, context.weapon, context)
    local unit = context.unit
    if not (caction and unit) or caction == context.default_attack then
        return
    end

    ---- pcall: o GetAPCost do GBO3 passa por componentes de arma e por Unit:*; um mod de terceiro
    ---- que quebre ali nao pode derrubar o resto do turno -- e sem custo confiavel o certo e nao
    ---- trocar nada e deixar o vanilla seguir.
    local ok, cost = pcall(caction.GetAPCost, caction, unit)
    if not ok or type(cost) ~= "number" or cost <= 0 then
        return
    end

    context.default_attack = caction
    context.default_attack_cost = cost
    if context.weapon and context.weapon.GetAutofireShots then
        context.burst_shots = Max(1, context.weapon:GetAutofireShots(caction) or 1)
    end

    ---- the rest of the string keeps the signature's planned aim, when it differs from the heuristic
    local level, forced = RATOAI_SignatureAimPlanned(context, caction, "Torso")
    context.__ratoai_aim_force = forced and level or nil
    context.__ratoai_aim_plan = nil

    if RATOAI_Debug then
        printf("[RATOAI] %s: sustentando %s como ataque padrao (custo %d, balas %d)",
               tostring(unit.session_id), tostring(caction.id), cost, context.burst_shots or 1)
    end
end

---- AIActions.lua: fires the resolved attack, then sustains it. Inherited by AIActionMGBurstFire.
function AIActionSingleTargetShot:Execute(context, action_state)
    assert(action_state.has_ap)
    AIPlayCombatAction(action_state.ratoai_action_id or self.action_id, context.unit, nil,
                       action_state.args)
    RATOAI_SustainFiringMode(self, context)
end

---- The attack a shot signature fires. GBO3: BurstFire without a burst limiter is a short autofire,
---- and AutoFire is the long burst -- a view of the preset that carries its length (AILongShots).
---- With a context, AutoFire/MGBurstFire take the length RATOAI_BurstLengthFor picks.
function RATOAI_SignatureAttack(action, weapon, context)
    local id = action.action_id
    if (id == "AutoFire" or id == "MGBurstFire") and context then
        local n = RATOAI_BurstLengthFor(action, context, weapon, id)
        if n then
            return Rat_AutoFireView(n, id)
        end
    end
    if id == "BurstFire" then
        return CombatActions[Rat_ShortBurstAttackId(weapon)]
    elseif id == "AutoFire" then
        return Rat_AutoFireView(const.Combat.Autofire.AILongShots)
    elseif id == "SingleShot" then
        return Rat_SingleShotAction(weapon)
    end
    return CombatActions[id or false]
end

---- AIActions.lua, with the resolved attack and its length in the args. The vanilla IsAvailable only
---- reads AP/ammo/CTH, so a mode the weapon cannot use now must stop here.
function AIActionSingleTargetShot:PrecalcAction(context, action_state)
    local weapon = context.weapon
    if not IsKindOf(weapon, "Firearm") or IsKindOf(weapon, "HeavyWeapon") then
        return
    end
    local action = RATOAI_SignatureAttack(self, weapon, context)
    if not action or not RATOAI_IsAttackModeAvailable(context.unit, weapon, action.id) then
        return
    end

    local unit = context.unit
    local upos = GetPackedPosAndStance(unit)
    local target = context.dest_target[upos]

    local body_parts = AIGetAttackTargetingOptions(unit, context, target, action, self.AttackTargeting)
    local targeting
    if body_parts and #body_parts > 0 then
        local pick = table.weighted_rand(body_parts, "chance", InteractionRand(1000000, "Combat"))
        targeting = pick and pick.id or nil
    end

    ---- the aim the score assumed; the static Aiming param is only the fallback when no plan exists
    local ux, uy, uz = stance_pos_unpack(upos)
    local attacker_pos = point(ux, uy, uz)
    local planned = RATOAI_SignatureAimPlan(context, action, upos, target, attacker_pos, targeting)
    local args, has_ap = AIGetAttackArgs(context, action, targeting or "Torso", planned or self.Aiming)
    args.num_shots = action.rat_num_shots
    action_state.args = args
    action_state.has_ap = has_ap
    action_state.ratoai_action_id = action.id
    if has_ap and IsValidTarget(args.target) then
        local results = action:GetActionResults(context.unit, args)
        action_state.has_ammo = not not results.fired
        action_state.can_hit = results.chance_to_hit > 0
    end
end
