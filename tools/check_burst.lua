-- Verifica a expansao de rajada (B21) e a sobretaxa de mira (B22).
-- Leitura pura: nao chama nada da engine com posicao construida.
--
--   python tools/dap_probe.py --timeout 20 -f tools/check_burst.lua
--
-- Precisa de RATOAI_Debug ligado e de uma unidade da IA com ai_context vivo
-- (ou seja: durante o turno da IA, ou com o painel de debug aberto).
(function()
    local L = {}
    local function p(...) L[#L + 1] = string.format(...) end

    p("Rat_GetRecoilAimCost = %s   (false = GBO3 nao recarregado; B22 inativo)",
      tostring(rawget(_G, "Rat_GetRecoilAimCost") ~= nil))
    p("RATOAI_Debug = %s", tostring(RATOAI_Debug))

    ---- reimplementa RATOAI_BurstHits aqui, para COMPARAR com o que ficou gravado.
    ---- se os dois baterem, a implementacao esta fazendo o que a formula diz.
    local function burst(cth, shots, recoil, aim_cth)
        if shots <= 1 then return cth end
        local max_idx = const.Combat.MaxShotIndexForRecoilCTHLoss or 6
        local fl = Min(const.Combat.MultishotMinCTH or 5, cth)
        local t = 0
        for b = 1, shots do
            local c = cth + (recoil or 0) * Min(b - 1, max_idx)
            if b > 1 then c = c - (aim_cth or 0) end
            t = t + Max(fl, Clamp(c, 0, 100))
        end
        return t
    end

    local achou = 0
    for _, team in ipairs(g_Teams or {}) do
        for _, u in ipairs(team.units or {}) do
            local c = u.ai_context
            if c and c.dbg_targets then
                local w = c.weapon
                p("")
                p("== %s | arma=%s | acao=%s | burst_shots=%s ==", tostring(u.session_id),
                  tostring(w and w.class), tostring(c.default_attack and c.default_attack.id),
                  tostring(c.burst_shots))

                for dest, dd in pairs(c.dbg_targets) do
                    for tgt, row in pairs(dd.by_target or {}) do
                        ---- so os pares com UM ataque: ali `hit` tem que ser exatamente a
                        ---- expansao da rajada, sem o termo de recoil ENTRE ataques
                        if row.hit and row.shots == 1 and row.cth1 then
                            achou = achou + 1
                            local esperado_sem_mira = burst(row.cth1, c.burst_shots or 1,
                                                            row.recoil, 0)
                            local dif = row.hit - esperado_sem_mira
                            p("  %s: cth1=%s recoil=%s balas=%s | hit=%s | esperado(mira 0)=%s | dif=%s",
                              tostring(tgt.session_id), tostring(row.cth1), tostring(row.recoil),
                              tostring(c.burst_shots), tostring(row.hit),
                              tostring(esperado_sem_mira), tostring(dif))
                            p("      razao hit/cth1 = %s  (1 = rajada NAO expandiu)",
                              tostring(MulDivRound(row.hit, 100, Max(1, row.cth1)) / 100) .. "," ..
                                  tostring(MulDivRound(row.hit, 100, Max(1, row.cth1)) % 100))
                        end
                    end
                end
            end
        end
    end

    if achou == 0 then
        p("")
        p("nenhum par (destino, alvo) com 1 ataque e dados de debug.")
        p("ligue RATOAI_Debug, abra o painel de AI debug numa unidade inimiga e rode de novo.")
    end
    return table.concat(L, "\n")
end)()
