function AICalcAOETargetPoints(context, min_range, max_range, max_radius, pos_override)
    local target_pts = {}
    local unit = context.unit
    local enemies = context.enemies

    -- add enemy positions
    for i, enemy in ipairs(enemies) do
        if VisibilityCheckAll(unit, enemy, nil, const.uvVisible) then
            target_pts[#target_pts + 1] = context.enemy_pos[enemy]
        end
    end

    local num_targets = #target_pts
    -- add midpoints of enemy pairs
    for i = 1, num_targets - 1 do
        for j = i + 1, num_targets do
            local pt = (target_pts[i] + target_pts[j]) / 2
            if not max_radius or pt:Dist(target_pts[i]) <= max_radius then
                target_pts[#target_pts + 1] = pt
            end
        end
    end

    -- add midpoints of enemy triples
    for i = 1, num_targets - 2 do
        for j = i + 1, num_targets - 1 do
            for k = j + 1, num_targets do
                local pt = (target_pts[i] + target_pts[j] + target_pts[k]) / 3
                if not max_radius or pt:Dist(target_pts[i]) <= max_radius then
                    target_pts[#target_pts + 1] = pt
                end
            end
        end
    end

    -----
    ---- BUGFIX (B35): `pos_override` tem PRECEDENCIA sobre o destino. Quem passa e o
    ---- AIPrecalcConeTargetZones, para que o filtro de alcance e as medicoes de linha saiam da
    ---- MESMA origem -- ver o cabecalho daquele arquivo. Sem override nada muda: granada,
    ---- sinalizador e o caminho de consciencia continuam filtrando pelo destino como antes.
    local dest = pos_override or
                     (context.ai_destination and RATOAI_UnpackPos(context.ai_destination))
    -----
    -- filter out target points not in range
    AIFilterTargetPoints(unit, target_pts, min_range, max_range, dest)

    return target_pts
end

function AIFilterTargetPoints(unit, target_pts, min_range, max_range, dest_override)
    for i = #target_pts, 1, -1 do
        -----
        local dist = dest_override and dest_override:Dist(target_pts[i]) or
            -----
                         unit:GetDist(target_pts[i])

        if dist == 0 or (max_range and dist > max_range) then
            table.remove(target_pts, i)
        elseif min_range and min_range < max_range and dist < min_range then
            table.remove(target_pts, i)
        end
    end
end
