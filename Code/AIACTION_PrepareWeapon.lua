DefineClass.AIPrepareWeapon = {
    __parents = {"AIActionBasicAttack"},
    properties = {
        -- 	{ id = "enemy_score", name = "Enemy Hit Score", editor = "number", default = 100, },
        -- 	{ id = "team_score", name = "Teammate Hit Score", editor = "number", default = -1000, },
        -- 	{ id = "self_score_mod", name = "Self Score Modifier", editor = "number", scale = "percent", default = -100, help = "Score will be modified with this value if the targeted zone includes the unit performing the attack" },
        -- 	{ id = "min_score", name = "Score Threshold", editor = "number", default = 200, help = "Action will not be taken if best score is lower than this", },
    },
    action_id = "R_PrepareWeapon",
    hidden = false
}

---------------------------------------------------------------------------------------------------
---- PARA QUE SERVE O `target` AQUI. A shooting stance tem DIRECAO -- preparar e apontar a arma
---- para um lado. `GetClosestEnemy` devolvia o inimigo mais proximo em linha reta, sem olhar se
---- ha parede no meio: a unidade preparava encarando concreto, gastava o AP e nao ganhava nada.
----
---- O gate usa UMA chamada de CheckLOS para a lista inteira de inimigos (mesma forma que o
---- AIPrecalcConeTargetZones usa), e entre os que TEM linha escolhe o mais proximo. Uma vez por
---- unidade por turno; nao encosta em caminho quente.
----
---- SEM NINGUEM COM LINHA a acao fica indisponivel -- inclusive pulando o fallback de
---- `last_attack_pos`. Esse fallback existia para "encarar de onde veio tiro", que e razoavel em
---- si, mas e exatamente o caso "preparar atras da parede" que se quer evitar. Quem quiser o
---- comportamento antigo tem o interruptor.
----
---- O QUE NAO FAZ (fica registrado): escolher a DIRECAO da parede mais proxima de um inimigo, que
---- seria o ideal. Isso exigiria avaliar direcoes e nao alvos -- varrer angulos, medir cobertura
---- por setor -- e custa numa ordem de grandeza diferente. O mais-proximo-com-linha resolve o
---- sintoma; o resto e refinamento.
---------------------------------------------------------------------------------------------------
const.RATOAI = const.RATOAI or {}

function AIPrepareWeapon:PrecalcAction(context, action_state)
    local unit = context.unit
    local dest = context.ai_destination or GetPackedPosAndStance(unit)
    local x, y, z = stance_pos_unpack(dest)
    local new_pos = point(x, y, z)
    local target

    local enemies = context.enemies or empty_table
    if #enemies > 0 then
        ---- pcall: CheckLOS e engine e recebe uma lista montada pelo context; um alvo despawnado
        ---- no meio do turno nao pode derrubar a escolha de acao.
        local ok, los_any, los_targets = pcall(CheckLOS, enemies, unit, unit:GetSightRadius())
        if ok and los_any then
            local melhor_dist
            for i, enemy in ipairs(enemies) do
                if los_targets[i] and IsValidTarget(enemy) then
                    local d = new_pos:Dist(enemy:GetPos())
                    if not melhor_dist or d < melhor_dist then
                        melhor_dist, target = d, enemy
                    end
                end
            end
        end
    end

    ---- ninguem com linha: nao ha para onde preparar que valha o AP
    if not target then
        return
    end

    local weapon = context.weapon or unit:GetActiveWeapons()
    local cost = weapon and (GetWeapon_StanceAP(unit, weapon) + Get_AimCost(unit)) or -1

    if cost >= 0 and unit:HasAP(cost) then
        action_state.args = {target = target}
        action_state.has_ap = true
    end
end

function AIPrepareWeapon:Execute(context, action_state)
    assert(action_state.args.target and action_state.has_ap)

    AIPlayCombatAction(self.action_id, context.unit, nil, action_state.args)
end
