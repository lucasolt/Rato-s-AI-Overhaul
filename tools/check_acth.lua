-- Read-only: for every living enemy -> player pair, the CTH the cheap planning path sees vs the CTH the roll uses.
(function()
    local out = {}
    local ok_patch = debug.getinfo(Rat_AngularCTH, "u").nparams >= 12
    out[#out + 1] = "GBO3 rat_full plumbing loaded: " .. tostring(ok_patch) ..
                        " | FullGeometry=" .. tostring(const.RATOAI.FullGeometry) ..
                        " Refine=" .. tostring(const.RATOAI.RefineFinalists) ..
                        " Veto=" .. tostring(const.RATOAI.ShotVeto) ..
                        " | telemetry records=" .. tostring(RATOTEL_Records and #RATOTEL_Records)
    local players = {}
    for _, t in ipairs(g_Teams) do
        if t.side == "player1" then
            for _, u in ipairs(t.units) do
                if not u:IsDead() then players[#players + 1] = u end
            end
        end
    end
    for _, t in ipairs(g_Teams) do
        if t.side == "enemy1" then
            for _, a in ipairs(t.units) do
                local action = not a:IsDead() and a:GetDefaultAttackAction()
                if action then
                    for _, p in ipairs(players) do
                        local base = {target = p, target_spot_group = "Torso", aim = 0, prediction = true}
                        local full = table.copy(base)
                        full.rat_full = true
                        local ok1, cheap = pcall(a.CalcChanceToHit, a, p, action, base, "chance_only")
                        local ok2, real = pcall(a.CalcChanceToHit, a, p, action, full, "chance_only")
                        if ok1 and ok2 and cheap ~= real then
                            out[#out + 1] = string.format("%s -> %s  %d tiles  cheap=%s real=%s",
                                tostring(a.session_id):gsub(".*:", ""), tostring(p.session_id),
                                a:GetDist(p) // const.SlabSizeX, tostring(cheap), tostring(real))
                        end
                    end
                end
            end
        end
    end
    if #out == 1 then
        out[#out + 1] = "no pair where the two models disagree"
    end
    return table.concat(out, "\n")
end)()
