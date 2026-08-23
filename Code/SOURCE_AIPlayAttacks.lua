local RATOAI_originalAIPlayAttacks = AIPlayAttacks

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

    local caction = CombatActions[action.action_id or false]
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

---- O gancho. Sobrescrever o Execute e o que evita copiar a AIPlayAttacks inteira so para
---- enfiar uma linha depois da chamada -- e o Execute do source e o ponto exato onde "a acao
---- acabou de disparar" e verdade.
----
---- Original guardado NA CLASSE, e nao numa global com guarda de `rawget`: medido no processo
---- vivo, `rawget(_G, ...)` nao enxerga global nenhuma neste engine (ver CLAUDE.md), entao aquele
---- idioma recapturaria o Execute JA PATCHEADO a cada reload e empilharia um wrapper por carga.
---- A tabela da classe e tabela comum, entao aqui o `or` significa o que diz.
----
---- Cobre toda a familia de tiro por heranca, inclusive AIActionMGBurstFire.
AIActionSingleTargetShot.RATOAI_Orig_Execute = AIActionSingleTargetShot.RATOAI_Orig_Execute or
                                                   AIActionSingleTargetShot.Execute

function AIActionSingleTargetShot:Execute(context, action_state)
    local status = AIActionSingleTargetShot.RATOAI_Orig_Execute(self, context, action_state)
    RATOAI_SustainFiringMode(self, context)
    return status
end
