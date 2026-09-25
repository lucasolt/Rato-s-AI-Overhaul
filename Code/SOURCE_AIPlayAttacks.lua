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
function AIPlayAttacks(unit, context, dbg_action, force_or_skip_action)
    context.AIisPlayingAttacks = true
    RATOAI_originalAIPlayAttacks(unit, context, dbg_action, force_or_skip_action)
    context.AIisPlayingAttacks = false
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

    local caction = RATOAI_SignatureAttack(action, context.weapon)
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

    context.__ratoai_aim_force = nil
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
function RATOAI_SignatureAttack(action, weapon)
    local id = action.action_id
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
    local action = RATOAI_SignatureAttack(self, weapon)
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

    local args, has_ap = AIGetAttackArgs(context, action, targeting or "Torso", self.Aiming)
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
