DefineClass.AIPolicyMGSetupAP = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "CheckLOS", editor = "bool", default = true}
    }
}

function AIPolicyMGSetupAP:EvalDest(context, dest, grid_voxel)
    local unit = context.unit
    local setup_cost = CombatActions.MGSetup:GetAPCost(unit, false)
    local ap = context.dest_ap[dest] or 0

    ---- PERF: gate de AP (aritmetica) antes do gate de LOS (raycast/cache).
    if setup_cost < 0 or ap < setup_cost then
        return 0
    end

    ---- O MGSetup deita a unidade: o LOS que interessa aqui e o LOS DEITADO
    ---- neste tile, nao o da postura do destino. Ver RATOAI_HasLOSToEnemyFromDest.
    if self.CheckLOS and not RATOAI_HasLOSToEnemyFromDest(context, dest) then
        return 0
    end

    return 100
end

---------------------------------------------------------------------------
---- BUGFIX (B11) -- Override de AIPolicyLosToEnemy (source, ClassDef-AI.generated.lua:421)
---------------------------------------------------------------------------
---- E a policy Required do PositioningAI "MG Setup": e ela quem decide para
---- onde o gunner anda. Media o LOS da postura do destino, que para tile com
---- cobertura baixa e Crouch -- exatamente a posicao de onde ele NAO vai
---- conseguir linha depois de deitar. Para arquetipos prone passa a medir
---- deitado; para todos os outros continua identica ao source.
---- (mora neste arquivo para nao dessincronizar metadata.lua/items.lua com um
---- arquivo novo; o lugar natural seria SOURCE_AIPolicyLosToEnemy.lua)
function AIPolicyLosToEnemy:EvalDest(context, dest, grid_voxel)
    local los = RATOAI_HasLOSToEnemyFromDest(context, dest)
    if self.Invert then
        return los and 0 or 100
    end
    return los and 100 or 0
end
