local function VoxelToPoint(voxel)
    return point(point_unpack(voxel))
end

local function DestToPoint(dest)
    local x, y, z = stance_pos_unpack(dest)
    return point(x, y, z)
end

local function PlaceTextFx(text, pos, color)
    local dbg_text = Text:new()
    dbg_text:SetText(tostring(text))
    dbg_text:SetPos(pos)
    if color then
        dbg_text:SetColor(color)
    end
    return dbg_text
end

local ap_scale = const.Scale.AP

local function format_ap(ap)
    return ap and string.format("%d.%d", ap / ap_scale, (10 * ap / ap_scale) / 10) or "N/A"
end

function IModeAIDebug:GetVoxelRolloverText()
    if not self.ai_context then
        return ""
    end
    local x, y, z = point_unpack(self.selected_voxel)
    local dest = self.ai_context.voxel_to_dest[self.selected_voxel]
    local opt_dest = dest or
                         stance_pos_pack(x, y, z, StancesList[self.ai_context.archetype.PrefStance])

    local opt_scores = self.think_data.optimal_scores[opt_dest] or empty_table
    local rch_scores = self.think_data.reachable_scores[dest]

    local arch = self.selected_unit:GetArchetype()

    local x, y, z = point_unpack(self.selected_voxel)
    local text = string.format("Selected voxel: %d, %d%s", x, y, z and (", " .. z) or "")
    if dest then
        local dx, dy, dz, ds = stance_pos_unpack(dest)
        text = text ..
                   string.format("\n  Dest: %d, %d%s, %s", dx, dy, dz and (", " .. dz) or "",
                                 StancesList[ds])
        text = text .. string.format("\n  Pathfind dist: %s", self.ai_context.dest_dist and
                                         tostring(self.ai_context.dest_dist[dest]) or "N/A")
    end

    local move_stance_idx = StancesList[arch.MoveStance]
    local pref_stance_idx = StancesList[arch.PrefStance]

    text = text .. string.format("\n  Available AP: %s (%s), %s (%s)\n", arch.MoveStance,
                                 format_ap(
                                     self.ai_context.dest_ap[stance_pos_pack(x, y, z,
                                                                             move_stance_idx)]),
                                 arch.PrefStance, format_ap(
                                     self.ai_context.dest_ap[stance_pos_pack(x, y, z,
                                                                             pref_stance_idx)]))
    -----------------------------------------
    if dest and self.ai_context.dest_flanking_pol_debug[dest] then

        text = text .. "\n\nFlanking Policy Debug:\n"
        text = text .. "  " .. self.ai_context.dest_flanking_pol_debug[dest] .. "\n"

    end

    ---- so existe com const.RATOAI.SeekCoverDebug ligado
    local cover_dbg = self.ai_context.dest_custom_seek_cover_debug
    if dest and cover_dbg and cover_dbg[dest] then
        text = text .. "\n\nCustom Seek Cover Policy Debug:\n" .. cover_dbg[dest] .. "\n"
    end

    ---- Este bloco imprimia `dest_custom_seek_cover_debug` -- o mesmo texto do
    ---- bloco de cima, duplicado -- em vez da tabela `_simple_`. Nada escreve na tabela
    ---- simple hoje (o `table.insert(debugforpos_simple, ...)` da policy esta comentado),
    ---- entao o bloco fica dormente ate alguem reativar aquele caminho.
    local cover_simple_dbg = self.ai_context.dest_custom_seek_cover_simple_debug
    if dest and cover_simple_dbg and cover_simple_dbg[dest] then
        text = text .. "\n\nCustom Seek Cover Policy Debug (Simple):\n" ..
                   cover_simple_dbg[dest] .. "\n"
    end

    ---- so existe com const.RATOAI.ThreatDebug ligado
    local threat_dbg = self.ai_context.dest_threat_exposure_debug
    if dest and threat_dbg and threat_dbg[dest] then
        text = text .. "\n\nThreat Exposure Debug:\n" .. threat_dbg[dest] .. "\n"
    end

    ---- so existe com const.RATOAI.PathDangerDebug ligado
    local path_dbg = self.ai_context.dest_path_danger_debug
    if dest and path_dbg and path_dbg[dest] then
        text = text .. "\n\nPath Danger Debug:\n" .. path_dbg[dest] .. "\n"
    end

    ---- so existe com const.RATOAI.EncircleDebug ligado
    local encircle_dbg = self.ai_context.dest_encircle_debug
    if dest and encircle_dbg and encircle_dbg[dest] then
        text = text .. "\n\nEncircle Enemy Debug:\n" .. encircle_dbg[dest] .. "\n"
    end

    if dest and self.ai_context.aims_at[dest] then
        for enemy, aims in pairs(self.ai_context.aims_at[dest]) do
            local aim_text = ""
            for i, aim in ipairs(aims) do
                aim_text = aim_text .. aim .. " , "
            end
            text = text .. "\n  " .. enemy.session_id .. " aims: " .. aim_text
        end
    end
    -----------------------------------------

    text = text .. "\nVoxel score: " .. (opt_scores.final_score or "N/A")
    for i = 1, #opt_scores, 2 do
        text = text .. string.format("\n  %s: %d", opt_scores[i], opt_scores[i + 1])
    end

    if rch_scores then
        text = text .. string.format("\n\nEnd Turn score: %d", rch_scores.final_score)
        for i = 1, #rch_scores, 2 do
            text = text .. string.format("\n  %s: %d", rch_scores[i], rch_scores[i + 1])
        end
    end

    return text
end
