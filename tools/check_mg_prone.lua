-- Sonda: o artilheiro de MG esta avaliando tudo deitado?
--
--   python tools/dap_probe.py -f tools/check_mg_prone.lua
--
-- Rodar com um HeavyGunner VIVO e com ai_context (o jogo apaga o context no fim do turno
-- da unidade, entao o melhor momento e durante o turno inimigo, com o jogo pausado ou
-- logo depois de o artilheiro agir).
--
-- SO LE. Nao chama PrecalcAction, nao mexe em ai_context, nao consome RNG. O unico
-- calculo e CheckLOS, que e consulta pura, sempre a partir de coordenadas que vieram do
-- jogo (stance_pos_unpack de um dest real).
--
-- O que cada bloco responde:
--   [1] posturas  -- o passe do B25 (SOURCE_AIFindDestinations.lua) esta convertendo?
--                    Prone = 0 significa que NAO rodou. Era 0/68 na medicao antes do B25.
--   [2] cache     -- quantos desses destinos tem LOS, e em que postura ela foi medida
--                    (a postura esta empacotada na propria chave do cache).
--   [3] tile atual -- em pe vs deitado, do lugar onde ele esta. Diferenca grande aqui e o
--                    sintoma "monta atras de cover e perde a linha" em estado puro.
(function()
    local out = {}
    local function cnt(v)
        local c = 0
        for _, b in ipairs(v or {}) do if b then c = c + 1 end end
        return c
    end

    local gunners = {}
    for _, t in ipairs(g_Teams or {}) do
        for _, u in ipairs(t.units or {}) do
            local arch = not u:IsDead() and u:GetArchetype()
            local pref = arch and arch.PrefStance
            if pref == "Prone" then gunners[#gunners + 1] = u end
        end
    end
    if #gunners == 0 then return "nenhuma unidade viva com PrefStance = Prone" end

    for _, u in ipairs(gunners) do
        local c = u.ai_context
        local arch = u:GetArchetype()
        out[#out + 1] = string.format("== %s | archetype=%s PrefStance=%s | stance=%s AP=%s | context=%s",
            tostring(u.session_id), tostring(arch and arch.id), tostring(arch and arch.PrefStance),
            tostring(u.stance), tostring(u.ActionPoints), c and "sim" or "NAO (sem ai_context)")

        if c then
            -- [1] histograma de posturas dos destinos alcancaveis
            local hist, tot = {0, 0, 0}, 0
            local zero = 0
            for _, dest in ipairs(c.destinations or {}) do
                local _, _, _, si = stance_pos_unpack(dest)
                tot = tot + 1
                if si and si >= 1 and si <= 3 then hist[si] = hist[si] + 1 else zero = zero + 1 end
            end
            out[#out + 1] = string.format("   [1] destinos=%d | Standing=%d Crouch=%d Prone=%d sem-postura=%d",
                tot, hist[1], hist[2], hist[3], zero)
            out[#out + 1] = string.format("       RATOAI_PronePackDests=%s RATOAI_CrouchTrigger=%s RATOAI_ConeStanceLOS=%s",
                tostring(rawget(_G, "RATOAI_PronePackDests")),
                tostring(rawget(_G, "RATOAI_CrouchTrigger")),
                tostring(rawget(_G, "RATOAI_ConeStanceLOS")))

            -- [2] cache de LOS por postura da chave
            local seen, los = {0, 0, 0}, {0, 0, 0}
            local nilos = 0
            for _, dest in ipairs(c.all_destinations or c.destinations or {}) do
                local _, _, _, si = stance_pos_unpack(dest)
                local v = g_AIDestEnemyLOSCache and g_AIDestEnemyLOSCache[dest]
                if si and si >= 1 and si <= 3 then
                    seen[si] = seen[si] + 1
                    if v then los[si] = los[si] + 1 end
                end
                if v == nil then nilos = nilos + 1 end
            end
            out[#out + 1] = string.format("   [2] cache LOS: Standing %d/%d | Crouch %d/%d | Prone %d/%d | sem entrada=%d",
                los[1], seen[1], los[2], seen[2], los[3], seen[3], nilos)
        end

        -- [3] a linha do tile atual, em pe vs deitado
        local enemies = {}
        for _, t in ipairs(g_Teams or {}) do
            if t:IsEnemySide(u.team) then
                for _, e in ipairs(t.units or {}) do
                    if not e:IsDead() and not e:IsDowned() then enemies[#enemies + 1] = e end
                end
            end
        end
        if #enemies > 0 then
            local sight = u:GetSightRadius()
            local _, vs = CheckLOS(enemies, u, sight, "Standing")
            local _, vc = CheckLOS(enemies, u, sight, "Crouch")
            local _, vp = CheckLOS(enemies, u, sight, "Prone")
            out[#out + 1] = string.format("   [3] daqui: em pe ve %d | agachado %d | DEITADO %d (de %d inimigos)",
                cnt(vs), cnt(vc), cnt(vp), #enemies)
        end
    end
    return table.concat(out, "\n")
end)()
