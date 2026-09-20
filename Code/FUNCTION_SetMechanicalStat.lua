local aff_table = {
    Legion = 5,
    Rebel = 10,
    Adonis = 20,
    Army = 15,
    Thugs = 5,
    SuperSoldiers = 25,
    Militia = 10,
}

local function mechanicalStatforUnjam(unit)
    if not unit then return 0 end
    local aff_stat = unit.Affiliation and aff_table[unit.Affiliation] or 10
    local level_stat = MulDivRound(unit:GetLevel() or 1, 500, 100)
    local random = InteractionRand(20, "GBO_AIstatMech")

    return Min(100, random + level_stat + aff_stat)
end

function RATOAI_SetMechanicalStat(unit)

    if not CurrentModOptions["ImproveMechanicalStat"] then return end
    -- the flag alone is not enough: saves written by the broken version carry it with the stat lost
    if unit.RATOAI_MechanicalSkillSet and (unit:GetBase("Mechanical") or 0) > 0 then return end

    if not R_IsAI(unit) or unit.species ~= "Human" then return end

    local skill = Max(mechanicalStatforUnjam(unit), unit:GetBase("Mechanical") or 0)
    if RATOAI_Debug then
        print("RATOAI - Setting", unit.unitdatadef_id, "mechanical skill from", unit:GetBase("Mechanical"), "to", skill)
    end

    -- Mechanical is a modifiable property: the value lives in base_Mechanical and any
    -- SyncWithSession copies only that, so a plain field write is wiped on the next sync
    unit:SetBase("Mechanical", skill)
    unit.RATOAI_MechanicalSkillSet = true

    local unit_data = gv_UnitData[unit.session_id]
    if unit_data then
        unit_data:SetBase("Mechanical", skill)
        unit_data.RATOAI_MechanicalSkillSet = true
    end
end

function OnMsg.UnitEnterCombat(unit)
    RATOAI_SetMechanicalStat(unit)
end
