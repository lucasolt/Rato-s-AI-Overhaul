const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- AIPolicyScoutHold -- holder half of the scout search (see SOURCE_ScoutSearch.lua roles).
---- Wait out of view of the suspected spot, close enough that a merc leaving it walks into the
---- holder's overwatch, in cover from it.
---------------------------------------------------------------------------------------------------
DefineClass.AIPolicyScoutHold = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {
            id = "MinTiles",
            name = "Min distance (tiles)",
            help = "Closer than this to the suspected spot scores down to 0 at the spot.",
            editor = "number",
            default = 6
        }, {
            id = "MaxTiles",
            name = "Max distance (tiles)",
            help = "Cap of the hold band; the band ends at the weapon's effective range below it.",
            editor = "number",
            default = 18
        }, {
            id = "InViewPct",
            name = "In view of the spot (%)",
            help = "Share of the score kept by a tile that can see the suspected spot.",
            editor = "number",
            default = 30
        }
    }
}

function AIPolicyScoutHold:GetEditorView()
    return "Scout hold (out of view of the suspected spot)"
end

local function HoldBand(self, context, ppos)
    local band = context.__ratoai_hold_band
    if band and band.ppos == ppos then
        return band
    end
    local slab = const.SlabSizeX
    local minr = self.MinTiles * slab
    band = {
        ppos = ppos,
        pos = RATOAI_UnpackPos(ppos),
        minr = minr,
        maxr = Clamp((context.EffectiveRange or 0) * slab, minr + 2 * slab, self.MaxTiles * slab),
        radius = context.unit:GetSightRadius(),
        los = {}
    }
    context.__ratoai_hold_band = band
    return band
end

function AIPolicyScoutHold:EvalDest(context, dest, grid_voxel)
    local ppos = RATOAI_SuspectPos(context)
    if not ppos then
        return 0
    end
    local band = HoldBand(self, context, ppos)
    local x, y, z = stance_pos_unpack(dest)
    local d = RATOAI_SpotDist(context, band.pos, x, y, z)

    local score
    if d < band.minr then
        score = MulDivRound(100, d, band.minr)
    elseif d <= band.maxr then
        score = 100
    else
        score = Max(0, 100 - MulDivRound(100, d - band.maxr, band.maxr))
    end
    if score <= 0 then
        return 0
    end

    ---- LOS only for tiles that can still score; one ray each, memoized per context
    local los = band.los[dest]
    if los == nil then
        local _, data = CheckLOS({band.ppos}, {dest}, band.radius)
        los = not not (data and data[1])
        band.los[dest] = los
    end
    if los then
        return MulDivRound(score, self.InViewPct, 100)
    end
    local cover = AIPolicyTakeCover.CoverScores[GetCoverFrom(dest, band.ppos)] or 0
    return MulDivRound(score, 70 + MulDivRound(30, cover, 100), 100)
end
