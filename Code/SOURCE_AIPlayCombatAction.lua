const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- LEVANTAR ANTES DE ATIRAR NA PEDRA
----
---- O CASO. LegionRaider:772, deitado, Grizzly a 21 tiles, TropicalRockSharp_01 a 1,2 tile do cano.
---- Medido no processo vivo: 118 de 120 balas simuladas morrem na pedra no primeiro quarto do voo,
---- ZERO chegam. Agachado, 13 de 120 acertam. O CTH que a IA via era 19% deitado contra 22%
---- agachado -- tres pontos entre "impossivel" e "onze por cento".
----
---- POR QUE O MODELO NAO VIA. Rat_MeasureExposure sonda o ALVO: raios do cano ate pontos do corpo.
---- Perto do cano eles sao colineares e atravessam o mesmo vao da pedra; e a fenda que a linha
---- central enfia. A bala nao anda na silhueta, anda no cone. Rat_MuzzleClearance (GBO3) mede isso
---- e agora entra no CTH -- mas so para o JOGADOR, porque 4 raios por destino candidato estouram
---- o orcamento do turno da IA (A.MuzzleProbeAI = false).
----
---- ENTAO A IA PAGA NA EXECUCAO. Uma vez por (posicao, alvo, postura), com cache, no momento em
---- que ja nao ha centenas de candidatos -- so o tiro que vai sair. E o unico momento em que o
---- preco cabe e em que ainda da para fazer algo a respeito.
----
---- POR QUE AQUI E NAO NO Execute DA SIGNATURE. Ha DOIS caminhos de tiro: a signature
---- (AIActionSingleTargetShot:Execute) e o laco "revert to basic attacks" da AIPlayAttacks
---- (CombatAI.lua:296-308), que chama AIPlayCombatAction direto. Os dois passam por aqui.
----
---- O QUE ELE NAO FAZ. Nao muda alvo, nao cancela o ataque e nao desce de postura. So sobe para a
---- postura mais BARATA que desbloqueia o cano, e so se sobrar AP para o ataque depois. Se nenhuma
---- resolve, atira do mesmo jeito -- o tiro ruim continua sendo decisao do planejador, nao daqui.
---------------------------------------------------------------------------------------------------

---- Fracao do anel que precisa sobreviver para o tiro contar como possivel. Abaixo disto a postura
---- e considerada bloqueada. 50 = metade do cone morre no campo proximo.
if const.RATOAI.ShotStanceMinClear == nil then
    const.RATOAI.ShotStanceMinClear = 50
end

---- Desliga tudo (o gate e lido a cada ataque, entao vale no console no meio do turno).
if const.RATOAI.ShotStanceFix == nil then
    const.RATOAI.ShotStanceFix = true
end

---- So subir. Deitado tenta agachado e depois em pe; agachado so em pe.
local RATOAI_StanceUp = {
    Prone = {"Crouch", "Standing"},
    Crouch = {"Standing"}
}

local function RATOAI_ShotWeapon(action, unit)
    if not action or action.ActionType ~= "Ranged Attack" then
        return nil
    end
    ---- pcall: GetAttackWeapons passa por componentes do GBO3 e por Unit:*; nao pode derrubar o
    ---- turno so porque a checagem opcional falhou.
    local ok, w = pcall(action.GetAttackWeapons, action, unit)
    if not ok or not IsKindOf(w, "Firearm") then
        return nil
    end
    return w
end

function RATOAI_ClearShotStance(action_id, unit, args)
    if not const.RATOAI.ShotStanceFix then
        return
    end
    if not (IsValid(unit) and unit.species == "Human") then
        return
    end
    local ladder = RATOAI_StanceUp[unit.stance]
    if not ladder then
        return
    end
    local target = args and args.target
    if not (IsKindOf(target, "Unit") and IsValidTarget(target)) then
        return
    end
    local action = CombatActions[action_id or false]
    local weapon = RATOAI_ShotWeapon(action, unit)
    if not weapon or not Rat_MuzzleClearance then
        return
    end

    local upos, tpos = unit:GetPos(), target:GetPos()
    local min_clear = const.RATOAI.ShotStanceMinClear
    local cur = Rat_MuzzleClearance(unit, target, upos, tpos, weapon, unit.stance, nil, "force")
    if cur >= min_clear then
        return
    end

    ---- o custo do ATAQUE tem de sobrar depois da postura, senao a unidade levanta e nao atira.
    ---- GetAPCost com os args reais: mira e parte do corpo ja escolhidas mudam o preco.
    local ok, attack_ap = pcall(action.GetAPCost, action, unit, args)
    if not ok or type(attack_ap) ~= "number" or attack_ap < 0 then
        return
    end

    for _, stance in ipairs(ladder) do
        local move_ap = GetStanceToStanceAP(unit.stance, stance)
        if move_ap and unit.ActionPoints >= move_ap + attack_ap then
            local clear = Rat_MuzzleClearance(unit, target, upos, tpos, weapon, stance, nil, "force")
            if clear >= min_clear and clear > cur then
                if RATOAI_Debug then
                    printf("[RATOAI] %s: cano bloqueado %s (%d%% do cone) -> %s (%d%%), %d AP",
                           tostring(unit.session_id), tostring(unit.stance), cur, stance, clear,
                           move_ap)
                end
                AIPlayChangeStance(unit, stance, tpos)
                return
            end
        end
    end

    if RATOAI_Debug then
        printf("[RATOAI] %s: cano bloqueado %s (%d%% do cone) e nenhuma postura resolve",
               tostring(unit.session_id), tostring(unit.stance), cur)
    end
end

---------------------------------------------------------------------------------------------------
---- EXECUTION VETO: don't pull the trigger on a shot the roll already says can't hit.
----
---- THE CASE. LegionGoon:489, H4 2026-09-16: 3 aimed pistol shots per turn at Kalyna, two turns,
---- all CTH 0 (target fully occluded). The vanilla "revert to basic attacks" loop in AIPlayAttacks
---- fires at `dest_target` with no CTH gate and spends every AP it has.
----
---- The CTH is asked with `rat_full`, the same model the roll uses (GBO3 SOURCE_UnitCalcChanceToHit),
---- and `prediction` so it doesn't touch the net hash. The exposure cache is shared, so the real
---- shot that follows pays nothing extra.
----
---- Returning false is what AIPlayCombatAction already returns when the action can't start: the
---- basic-attack loop breaks on it and the unit keeps its AP. Only single-target firearm shots.
---------------------------------------------------------------------------------------------------
if const.RATOAI.ShotVeto == nil then
    const.RATOAI.ShotVeto = true
end
---- veto when the real CTH is at or below this (0 = only impossible shots)
if const.RATOAI.ShotVetoMaxCTH == nil then
    const.RATOAI.ShotVetoMaxCTH = 0
end

local RATOAI_VetoAimTypes = {cone = true, ["parabola aoe"] = true, melee = true, ["melee-charge"] = true}

---- Real CTH of the shot about to be fired, or nil when it isn't a single-target firearm shot.
local function RATOAI_RealShotCTH(action_id, unit, args)
    local target = args and args.target
    if not (IsKindOf(target, "Unit") and IsValidTarget(target)) then
        return
    end
    local action = CombatActions[action_id or false]
    if not action or RATOAI_VetoAimTypes[action.AimType] or not RATOAI_ShotWeapon(action, unit) then
        return
    end
    local cth_args = table.copy(args)
    cth_args.prediction = true
    cth_args.rat_full = true
    local ok, cth = pcall(unit.CalcChanceToHit, unit, target, action, cth_args, "chance_only")
    return ok and type(cth) == "number" and cth or nil
end

function RATOAI_ShotVeto(action_id, unit, args)
    local check = const.RATOAI.ShotVeto or RATOAI_Debug
    local cth = check and RATOAI_RealShotCTH(action_id, unit, args)
    if not cth then
        return false
    end
    local veto = const.RATOAI.ShotVeto and cth <= const.RATOAI.ShotVetoMaxCTH
    local context = unit.ai_context
    if RATOAI_Debug and context then
        ---- read by Rato Dev telemetry: planned vs rolled CTH, per shot
        local target = args.target
        local part = args.target_spot_group
        context.dbg_shots = context.dbg_shots or {}
        table.insert(context.dbg_shots, {
            action = action_id,
            aim = args.aim,
            ---- JSON-safe: a preset table here would make LuaToJSON drop the whole telemetry record
            part = type(part) == "table" and part.id or part,
            target = target.session_id,
            cth = cth,
            ---- from the AIPlayAttacks precalc at this tile; the Think-time plan is in telemetry `cth_plan`
            plan_exec = context.dest_cth and context.dest_cth[GetPackedPosAndStance(unit)],
            veto = veto or nil
        })
    end
    if veto and RATOAI_Debug then
        printf("[RATOAI] %s: %s vetoed, real CTH %d vs %s", tostring(unit.session_id),
               tostring(action_id), cth, tostring(args.target.session_id))
    end
    return veto
end

---------------------------------------------------------------------------------------------------
---- O gancho.
----
---- Original guardado em `const.RATOAI`, e nao numa global com guarda de `rawget`: medido no
---- processo vivo, `rawget(_G, ...)` nao enxerga global nenhuma neste engine (ver CLAUDE.md), entao
---- aquele idioma recapturaria a versao JA PATCHEADA a cada reload e empilharia um wrapper por
---- carga. `const` e tabela comum, entao aqui o `or` significa o que diz.
---------------------------------------------------------------------------------------------------
const.RATOAI.OrigAIPlayCombatAction = const.RATOAI.OrigAIPlayCombatAction or AIPlayCombatAction

function AIPlayCombatAction(action_id, unit, ap, args)
    ---- pcall: a checagem e opcional e roda no meio da execucao do turno. Um erro dentro dela nao
    ---- pode impedir o ataque de acontecer.
    local ok, err = pcall(RATOAI_ClearShotStance, action_id, unit, args)
    if not ok then
        print("[RATOAI] RATOAI_ClearShotStance falhou --", err)
    end
    local ok_v, veto = pcall(RATOAI_ShotVeto, action_id, unit, args)
    if not ok_v then
        print("[RATOAI] RATOAI_ShotVeto falhou --", veto)
    elseif veto then
        return false
    end
    return const.RATOAI.OrigAIPlayCombatAction(action_id, unit, ap, args)
end
