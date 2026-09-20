function RATOAI_unitprops()
    UnitProperties.properties[#UnitProperties.properties + 1] = {
        id = "RATOAI_flare_added",
        editor = "bool",
        default = false,
        no_edit = true
    }
    UnitProperties.properties[#UnitProperties.properties + 1] = {
        id = "RATOAI_equipament_processed",
        editor = "bool",
        default = false,
        no_edit = true
    }
    UnitProperties.properties[#UnitProperties.properties + 1] = {
        id = "custom_role",
        editor = "text",
        default = false,
        no_edit = true
    }
    UnitProperties.properties[#UnitProperties.properties + 1] = {
        id = "RATOAI_ChangedStance",
        editor = "bool",
        default = false,
        no_edit = true
    }

end

RATOAI_unitprops()
