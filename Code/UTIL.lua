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
