---- PERF (C9): flag unica para todo o mod. Quando falsa, os caminhos de debug
---- nao alocam nada. Mesma condicao que AIPOLICYPOS_CustomSeekCover ja usava.
---- As tabelas de debug do context continuam sendo criadas (vazias) em
---- AICreateContext, porque DEBUG.lua as indexa sem checar existencia --
---- o que custava caro era o PREENCHIMENTO delas, nao a criacao.
RATOAI_Debug = Platform.developer and Platform.cheats and true or false

function Update_AIPrecalcDamageScore(unit)
    local context = unit.ai_context or {}
    if not context.damage_score_precalced then
        AIPrecalcDamageScore(context)
        unit.ai_context = context
        return context
    end
    return nil
end

function R_IsAI(unit)
    local side = unit and unit.team and unit.team.side or ''
    if (side == "player1" or side == "player2") then
        return false
    end
    return true
end

function IsMod_loaded(mod_id) --- made by Toni
    local mod_check = table.find(ModsLoaded, 'id', mod_id) or nil -- Replace "Mod_Id" with exact case sensitive modID you're testing for.

    if mod_check then
        return true
    end
    return false
end

function RATOAI_UnpackPos(pos)
    if not pos then
        return
    end
    local ux, uy, uz, ustance_idx = stance_pos_unpack(pos)
    local new_pos = point(ux, uy, uz)
    return new_pos
end

function RATOAI_ValidatePosZ(point)
    return IsValidZ(point) and point or point:SetTerrainZ()
end

function RATOAI_GetCloseRange()
    return rat_close_range() or (((const.Weapons.PointBlankRange * 2) + (1)) * const.SlabSizeX)
end
-- GetPackedPosAndStance(unit, stance)

---------------------------------------------------------------------------
---- BUGFIX (B11) -- LOS medido DEITADO (arquetipos com PrefStance == "Prone")
---------------------------------------------------------------------------
---- O motor so guarda LOS na postura do DESTINO (g_AIDestEnemyLOSCache), e a
---- postura do destino nunca e Prone: AIFindDestinations (CombatAI.lua:679)
---- converte em Crouch todo tile com cobertura baixa adjacente, e o resto fica
---- Standing. So que o gunner que monta a MG termina DEITADO -- entao a linha
---- que escolheu a posicao nao e a linha que ele vai ter depois do MGSetup.
---- Este cache responde "deitado neste tile, vejo algum inimigo?".
---- Chave = voxel (point_pack), nao o dest: context.destinations e
---- context.all_destinations trazem o mesmo tile com posturas diferentes.
----
---- Cobre so context.destinations (tiles alcancaveis neste turno). Nao precisa
---- cobrir o resto: AIEnumValidDests (CombatAI.lua:1229) empacota todo tile FORA
---- do alcance com StancesList[archetype.PrefStance] -- para o gunner isso ja e
---- Prone, entao o g_AIDestEnemyLOSCache desses tiles ja e LOS deitado. O buraco
---- era exatamente o conjunto alcancavel, que vem de voxel_to_dest em
---- Standing/Crouch. Por isso o fallback e o cache do motor, nao um raycast novo
---- (com OptLocSearchRadius = 100 all_destinations tem dezenas de milhares de
---- tiles -- fazer raycast preguicoso por tile dentro do AIScoreDest travaria).

local prone_los_batch = 100 ---- mesmo teto de raios por chamada do AIUpdateDestLosCache

function RATOAI_IsProneArchetype(context)
    local archetype = context and context.archetype
    return (archetype and archetype.PrefStance == "Prone") and true or false
end

local function RATOAI_ProneSrcFromDest(dest)
    if not dest then
        return
    end
    local x, y, z = stance_pos_unpack(dest)
    if not x then
        return
    end
    if not z then
        z = terrain.GetHeight(x, y)
    end
    return point_pack(x, y, z), stance_pos_pack(x, y, z, StancesList.Prone), x, y, z
end

---- Passe em batelada, chamado uma vez por turno do gunner (AICreateContext).
function RATOAI_UpdateProneLosCache(unit, context, can_yield)
    local cache = {}
    context.prone_los_cache = cache

    local enemies = context.enemies or empty_table
    local dests = context.destinations or empty_table
    if #enemies == 0 or #dests == 0 then
        return cache
    end

    local voxels, src_by_voxel = {}, {}
    for _, dest in ipairs(dests) do
        local voxel, src = RATOAI_ProneSrcFromDest(dest)
        if voxel and src_by_voxel[voxel] == nil then
            src_by_voxel[voxel] = src
            voxels[#voxels + 1] = voxel
            cache[voxel] = false
        end
    end

    local sight = unit:GetSightRadius()
    local targets, srcs, voxel_of, count = {}, {}, {}, 0

    local function flush()
        if count == 0 then
            return
        end
        local los_any, los_data = CheckLOS(targets, srcs, sight)
        if los_any then
            for i, value in ipairs(los_data) do
                if value then
                    cache[voxel_of[i]] = true
                end
            end
        end
        table.iclear(targets)
        table.iclear(srcs)
        table.iclear(voxel_of)
        count = 0
        if can_yield and CurrentThread() and GetInGameInterfaceMode() ~= "IModeAIDebug" then
            Sleep(10) ---- mesmo yield do AIUpdateDestLosCache
        end
    end

    for _, enemy in ipairs(enemies) do
        local ppos = context.enemy_pack_pos_stance[enemy]
        if ppos and IsValid(enemy) and not enemy:IsDead() then
            for _, voxel in ipairs(voxels) do
                ---- tile que ja viu algum inimigo nao precisa de mais raios
                if not cache[voxel] then
                    count = count + 1
                    targets[count] = ppos
                    srcs[count] = src_by_voxel[voxel]
                    voxel_of[count] = voxel
                    if count >= prone_los_batch then
                        flush()
                    end
                end
            end
            flush() ---- fecha o inimigo atual para o proximo aproveitar a poda
        end
    end
    flush()

    return cache
end

function RATOAI_HasProneLOSFromDest(context, dest)
    local cache = context and context.prone_los_cache
    if cache then
        local voxel = RATOAI_ProneSrcFromDest(dest)
        local cached = voxel and cache[voxel]
        if cached ~= nil then
            return cached
        end
    end

    ---- tile fora do conjunto alcancavel: o cache do motor ja o mediu deitado
    return g_AIDestEnemyLOSCache[dest] and true or false
end

---- LOS para inimigos a partir de um destino, na postura em que a unidade vai
---- realmente ficar: deitada para os arquetipos prone, a do destino para o resto.
function RATOAI_HasLOSToEnemyFromDest(context, dest)
    if RATOAI_IsProneArchetype(context) then
        return RATOAI_HasProneLOSFromDest(context, dest)
    end
    return g_AIDestEnemyLOSCache[dest] and true or false
end
