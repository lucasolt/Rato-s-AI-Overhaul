DefineClass.AIPolicySaveAP = {
    __parents = {"AIPositioningPolicy"},
    __generated_by_class = "ClassDef",

    properties = {
        {id = "end_of_turn", editor = "bool", default = true, read_only = true, no_edit = true},
        {id = "optimal_location", editor = "bool", default = true, read_only = true, no_edit = true},
        {
            id = "ReserveAP",
            name = "Reserve AP",
            help = "do not consider locations where the unit will be out of ap",
            editor = "number",
            default = 2

        }, {
            id = "SaveforBoltingAction",
            name = "Save AP for Bolting Action",
            help = "",
            editor = "bool",
            default = false

        }, {
            id = "SaveforShootingStance",
            name = "Save AP to enter Shooting Stance",
            help = "",
            editor = "bool",
            default = false

        }

    }
}

function AIPolicySaveAP:EvalDest(context, dest, grid_voxel)

    local ap = context.dest_ap[dest] or 0

    local check_ap = R_VanillaAP(self.ReserveAP or 0)

    local unit = context.unit
    local weapon = context.weapon or unit and unit:GetActiveWeapons()

    if self.SaveforBoltingAction and weapon and rat_canBolt(weapon) and weapon.unbolted then
        check_ap = check_ap + R_VanillaAP(rat_get_manual_cyclingAP(unit, weapon, true))
    end

    if self.SaveforShootingStance and weapon then
        check_ap = check_ap + (GetWeapon_StanceAP(unit, weapon) + Get_AimCost(unit)) or 0
    end

    return ap < check_ap and 0 or 100
end
