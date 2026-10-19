---------------------------------------------------------------------------------------------------
---- AIPolicyStayNearAllies -- coesao de esquadrao: premia estar PERTO dos aliados.
---------------------------------------------------------------------------------------------------

DefineClass.AIPolicyStayNearAllies = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {
            id = "MinDist",
            name = "Distancia ideal (tiles)",
            help = "nesta distancia ou mais perto, score maximo",
            editor = "number",
            default = 2,
            min = 0,
        },
        {
            id = "MaxDist",
            name = "Distancia limite (tiles)",
            help = "nesta distancia ou mais longe, score zero",
            editor = "number",
            default = 10,
            min = 1,
        },
        {
            id = "TargetDist",
            name = "Medida",
            help = "min = distancia ao aliado mais proximo; average = media de todos",
            editor = "choice",
            default = "min",
            items = function(self)
                return {"min", "average"}
            end,
        },
        {
            id = "AllyPlannedPosition",
            name = "Usar destino planejado do aliado",
            help = "considera o aliado na posicao para onde ele decidiu ir neste turno, quando ja decidiu",
            editor = "bool",
            default = true,
        },
        {
            id = "IgnoreDowned",
            name = "Ignorar caidos",
            help = "aliado incapacitado nao conta para a coesao",
            editor = "bool",
            default = true,
        },
    },
}

function AIPolicyStayNearAllies:GetEditorView()
    return string.format("Ficar perto de aliados (%d-%d tiles, %s)", self.MinDist, self.MaxDist,
                         self.TargetDist)
end

function AIPolicyStayNearAllies:EvalDest(context, dest, grid_voxel)
    local unit = context.unit
    local scale = const.SlabSizeX

    local best, sum, num = nil, 0, 0

    for _, ally in ipairs(context.allies or empty_table) do
        if ally ~= unit and IsValid(ally) and not ally:IsDead() and
            not (self.IgnoreDowned and ally:IsIncapacitated()) then

            local apos = context.ally_pack_pos_stance and context.ally_pack_pos_stance[ally]
            if self.AllyPlannedPosition and ally.ai_context and ally.ai_context.ai_destination then
                apos = ally.ai_context.ai_destination
            end

            if apos then
                local dist = MulDivRound(stance_pos_dist(dest, apos), 1, scale)
                num = num + 1
                sum = sum + dist
                if not best or dist < best then
                    best = dist
                end
            end
        end
    end

    if num == 0 then
        return 0 ---- sozinho: nada a medir
    end

    local dist = (self.TargetDist == "average") and MulDivRound(sum, 1, num) or best

    local lo = Min(self.MinDist, self.MaxDist)
    local hi = Max(self.MinDist, self.MaxDist)

    if dist <= lo then
        return 100
    end
    if dist >= hi or hi == lo then
        return 0
    end
    return MulDivRound(hi - dist, 100, hi - lo)
end
