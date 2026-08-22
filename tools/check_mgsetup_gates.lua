---------------------------------------------------------------------------------------------------
---- Por que o MGSetup nao apareceu como signature action?
----
---- Roda a cadeia inteira de portoes do AIActionMGSetup na MESMA ordem em que o jogo roda e
---- imprime onde ela morreu, ao lado da nota que a AIPolicyMGSetupPosScore deu para o mesmo
---- destino. Quando os dois discordam, a linha "VEREDITO" diz qual portao discordou.
----
---- Uso:  python tools/dap_probe.py -f tools/check_mgsetup_gates.lua
----
---- O adapter DAP trunca a resposta por volta de 900 caracteres, entao o relatorio inteiro fica
---- em `MGPROBE` (tabela de linhas) e a chamada devolve uma fatia de cada vez. Paginas seguintes:
----   python tools/dap_probe.py 'MGPROBE_page(2)' 'MGPROBE_page(3)'
----
---- So le. As unicas escritas sao a global MGPROBE, tabelas de scratch, e os campos de cache
---- por turno da propria policy (context.__mg_*), que ela recalcula sozinha.
---------------------------------------------------------------------------------------------------
(function()
    local out = {}

    MGPROBE_page = function(n, per)
        per = per or 8
        local lines = MGPROBE or {}
        local first = (n - 1) * per + 1
        local buf = {string.format("[pagina %d de %d]", n, (#lines + per - 1) / per)}
        for i = first, Min(first + per - 1, #lines) do
            buf[#buf + 1] = lines[i]
        end
        return table.concat(buf, "\n")
    end

    local function L(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    local function find_policy()
        for _, a in pairs(Archetypes or {}) do
            for _, b in ipairs(a.Behaviors or {}) do
                for _, p in ipairs(b.EndTurnPolicies or {}) do
                    if p.class == "AIPolicyMGSetupPosScore" then return p end
                end
                for _, p in ipairs(b.OptLocPolicies or {}) do
                    if p.class == "AIPolicyMGSetupPosScore" then return p end
                end
            end
        end
    end

    local function find_sig(context)
        local b = context.behavior
        local pools = {b and b.SignatureActions, context.archetype and context.archetype.SignatureActions}
        for _, pool in ipairs(pools) do
            for _, a in ipairs(pool or {}) do
                if a.class == "AIActionMGSetup" then return a end
            end
        end
        for _, bb in ipairs((context.archetype or {}).Behaviors or {}) do
            for _, a in ipairs(bb.SignatureActions or {}) do
                if a.class == "AIActionMGSetup" then return a end
            end
        end
    end

    local policy = find_policy()
    L("policy AIPolicyMGSetupPosScore encontrada: %s | turn=%s side=%s",
      tostring(policy ~= nil), tostring(g_Combat and g_Combat.current_turn),
      tostring(g_Teams and g_CurrentTeam and g_Teams[g_CurrentTeam] and g_Teams[g_CurrentTeam].side))

    for _, team in ipairs(g_Teams or {}) do
        for _, u in ipairs(team.units or {}) do
            local c = u.ai_context
            local w = c and (c.weapon or u:GetActiveWeapons())
            if c and c.archetype and w and IsKindOf(w, "MachineGun") then
                local dead = nil
                L("")
                L("================ %s (%s, %s) ================",
                  tostring(u.session_id), tostring(u.current_archetype), w.class)

                ---- nota da policy no destino escolhido + espalhamento pelos destinos
                local dest = c.ai_destination
                local pol_here, pol_pos, pol_best, pol_n = -1, 0, 0, 0
                if policy then
                    c.__mg_cone, c.__mg_enemies, c.__mg_seen, c.__mg_los_checks = nil, nil, nil, nil
                    pol_here = dest and policy:EvalDest(c, dest, nil) or -1
                    for _, d in ipairs(c.destinations or {}) do
                        local s = policy:EvalDest(c, d, nil)
                        pol_n = pol_n + 1
                        if s > 0 then pol_pos = pol_pos + 1 end
                        if s > pol_best then pol_best = s end
                    end
                end
                L("POLICY   nota no ai_destination=%d | %d/%d destinos >0 | melhor=%d | mode=%s ReserveAP=%s",
                  pol_here, pol_pos, pol_n, pol_best,
                  tostring(policy and policy.visibility_mode), tostring(policy and policy.ReserveAPforSetup))

                ---- AP: o que o planejamento acha vs o que a unidade tem
                local setup_cost = CombatActions.MGSetup:GetAPCost(u, false)
                local dap = dest and c.dest_ap and c.dest_ap[dest]
                L("AP       real=%d dest_ap=%s setup=%d (stanceAP=%d + flat) | reserva prone no dest_ap=%d (nunca paga na execucao)",
                  u.ActionPoints, tostring(dap), setup_cost, GetWeapon_StanceAP(u, w),
                  GetStanceToStanceAP("Standing", "Prone") or 0)

                local sig = find_sig(c)
                if not sig then
                    L("PORTAO 1 nenhuma AIActionMGSetup na lista de signature actions deste behavior")
                else
                    ---- 1. bias / disable_actions / CustomScoring
                    local wm, dis, pri = AIGetBias(sig.BiasId, u)
                    local dis2 = (c.disable_actions or {})[sig.BiasId or false]
                    local cw, cdis = sig:CustomScoring(c)
                    L("PORTAO 1 bias mod=%s disable=%s prio=%s | disable_actions=%s | CustomScoring w=%s disable=%s",
                      tostring(wm), tostring(dis), tostring(pri), tostring(dis2), tostring(cw), tostring(cdis))
                    if dis or dis2 or cdis then dead = dead or "bias/CustomScoring" end

                    ---- 2. GetUIState (mede a unidade AGORA: AP real, agua, arma, municao)
                    local st, reason = CombatActions.MGSetup:GetUIState({u})
                    L("PORTAO 2 GetUIState=%s (%s) | UIHasAP(%d)=%s municao=%s",
                      tostring(st), reason and tostring(_InternalTranslate(reason)) or "-",
                      setup_cost, tostring(u:UIHasAP(setup_cost)), tostring(w.ammo and w.ammo.Amount))
                    if st ~= "enabled" then dead = dead or "GetUIState" end

                    ---- 3. AIGetAttackArgs -> has_ap
                    local _, has_ap = AIGetAttackArgs(c, CombatActions.MGSetup, nil, "None")
                    L("PORTAO 3 AIGetAttackArgs has_ap=%s", tostring(has_ap))
                    if not has_ap then dead = dead or "has_ap" end

                    ---- 4..7: a cadeia do AIPrecalcConeTargetZones, passo a passo
                    local p = w:GetAreaAttackParams("MGSetup", u)
                    local minr, maxr = p.min_range * const.SlabSizeX, p.max_range * const.SlabSizeX
                    local vis_self, vis_team = 0, 0
                    for _, e in ipairs(c.enemies or {}) do
                        if VisibilityCheckAll(u, e, nil, const.uvVisible) then vis_self = vis_self + 1 end
                        if (c.enemy_visible_by_team or {})[e] then vis_team = vis_team + 1 end
                    end
                    local pts = AICalcAOETargetPoints(c, minr, maxr)
                    L("PORTAO 4 inimigos=%d | visiveis PARA ESTE ATIRADOR agora=%d | vistos pelo TIME=%d -> target_pts=%d",
                      #(c.enemies or {}), vis_self, vis_team, #pts)
                    if #pts == 0 then
                        dead = dead or "AICalcAOETargetPoints (VisibilityCheckAll do proprio atirador)"
                    end

                    local override = (u.stance ~= "Prone") and "Prone" or nil
                    local units = table.copy(c.enemies)
                    local n_en = #units
                    table.iappend(units, GetAllAlliedUnits(u))
                    local attack_pos, targets, best_cone = u:GetPos(), {}, 0
                    for _, pt in ipairs(pts) do
                        local dir = pt - attack_pos
                        if dir:Len() > 0 then
                            local tpos = (attack_pos + SetLen(dir, maxr)):SetTerrainZ()
                            local any, los = CheckLOS(units, u, u:GetDist(tpos), override,
                                                      p.cone_angle, CalcOrientation(attack_pos, pt))
                            local n = 0
                            if any then
                                for i, tu in ipairs(units) do
                                    if los[i] and IsValidTarget(tu) then
                                        n = n + 1
                                        table.insert_unique(targets, tu)
                                    end
                                end
                            end
                            if n > best_cone then best_cone = n end
                        end
                    end
                    L("PORTAO 5 LOS no cone (stance=%s, pool=%d inimigos + %d aliados): melhor zona=%d, alvos distintos=%d",
                      tostring(override or u.stance), n_en, #units - n_en, best_cone, #targets)
                    if #targets == 0 and #pts > 0 then dead = dead or "CheckLOS do cone" end

                    local maxd = Min(u:GetSightRadius(), w:GetMaxRange())
                    local any, los = CheckLOS(targets, u, maxd, override)
                    local kept = {}
                    if any then
                        for i, tu in ipairs(targets) do
                            if los[i] then kept[#kept + 1] = tu end
                        end
                    end
                    L("PORTAO 6 LOS de alcance (maxd=%d = min(sight %d, GetMaxRange %d)): %d/%d",
                      maxd, u:GetSightRadius(), w:GetMaxRange(), #kept, #targets)
                    if #kept == 0 and #targets > 0 then dead = dead or "CheckLOS de alcance" end

                    local lof = GetLoFData(u, kept, {
                        obj = u, action_id = c.default_attack.id, weapon = w,
                        stance = override or u.stance, range = maxd,
                        target_spot_group = "Torso", prediction = true
                    })
                    local cth_ok = 0
                    for i, ad in ipairs(lof or {}) do
                        local cth = 0
                        if ad and not ad.stuck then
                            for _, hi in ipairs(ad.lof) do
                                cth = u:CalcChanceToHit(kept[i], CombatActions.MGSetup,
                                                        {target_spot_group = hi.target_spot_group},
                                                        "chance_only")
                                if cth > 0 then break end
                            end
                        end
                        if cth > 0 then cth_ok = cth_ok + 1 end
                        local aimed = u:CalcChanceToHit(kept[i], CombatActions.MGSetup,
                                                        {target_spot_group = "Torso", aim = 3},
                                                        "chance_only")
                        L("           %s cth(aim0)=%d cth(aim3)=%d%s",
                          tostring(kept[i].session_id), cth, aimed, (ad and ad.stuck) and " STUCK" or "")
                    end
                    L("PORTAO 7 CTH>0 com aim 0 na postura de tiro ATUAL: %d/%d", cth_ok, #kept)
                    if cth_ok == 0 and #kept > 0 then
                        dead = dead or "CalcChanceToHit == 0 (hipfire sem shooting stance)"
                    end

                    ---- 8. o precalc de verdade + o limiar do EvalZones
                    local ss = {}
                    sig:PrecalcAction(c, ss)
                    local avail = sig:IsAvailable(c, ss)
                    L("PORTAO 8 PrecalcAction: has_ap=%s score=%s target_pos=%s | min_score=%s enemy=%s team=%s -> IsAvailable=%s",
                      tostring(ss.has_ap), tostring(ss.score), tostring(ss.args and ss.args.target_pos),
                      tostring(sig.min_score), tostring(sig.enemy_score), tostring(sig.team_score),
                      tostring(avail))
                    if not avail then dead = dead or "EvalZones abaixo do min_score" end

                    L("VEREDITO policy=%d | MGSetup %s%s", pol_here,
                      avail and "DISPONIVEL" or "INDISPONIVEL",
                      (not avail) and (" -- morreu em: " .. tostring(dead)) or "")
                end
            end
        end
    end
    MGPROBE = out
    return MGPROBE_page(1)
end)()
