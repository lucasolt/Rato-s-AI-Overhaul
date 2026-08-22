local function AddStartingPerk(class, perk_id)
    local starting_perks = table.copy(class.StartingPerks or {})
    table.insert_unique(starting_perks, perk_id)
    class.StartingPerks = starting_perks
end

local stats = {
    "Health", "Agility", "Dexterity", "Strength", "Wisdom", "Leadership", "Marksmanship",
    "Mechanical", "Explosives", "Medical"
}

local function GetRoleArgs_BoostStats(class)
    local role = class.custom_role or class.role or ""

    if CurrentModOptions.DontBoostMilitia and class.militia then
        return false
    end

    role = class.militia and "Militia" or role

    local map = {
        Commander = {
            Health = {mul = 3, flat = 0},
            Marksmanship = {mul = 0, flat = 10},
            Dexterity = {mul = 10, flat = 8},
            Strength = {mul = 10, flat = 5},
            Agility = {mul = 5, flat = 0},
            Explosives = {mul = 8, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 10, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Stormer = {
            Health = {mul = 0, flat = 8},
            Marksmanship = {mul = 0, flat = 16},
            Dexterity = {mul = 0, flat = 5},
            Strength = {mul = 5, flat = 0},
            Agility = {mul = 0, flat = 5},
            Explosives = {mul = 8, flat = 10},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Marksman = {
            Health = {mul = 0, flat = 12},
            Marksmanship = {mul = 5, flat = 0},
            Dexterity = {mul = 5, flat = 0},
            Strength = {mul = 5, flat = 6},
            Agility = {mul = 0, flat = 0},
            Explosives = {mul = 0, flat = 10},
            Wisdom = {mul = 10, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Heavy = {
            Health = {mul = 15, flat = 0},
            Marksmanship = {mul = 0, flat = 15},
            Dexterity = {mul = 10, flat = 0},
            Strength = {mul = 10, flat = 0},
            Agility = {mul = 0, flat = 5},
            Explosives = {mul = 0, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Soldier = {
            Health = {mul = 0, flat = 5},
            Marksmanship = {mul = 0, flat = 10},
            Dexterity = {mul = 0, flat = 5},
            Strength = {mul = 8, flat = 10},
            Agility = {mul = 0, flat = 8},
            Explosives = {mul = 8, flat = 10},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Recon = {
            Health = {mul = 0, flat = 18},
            Marksmanship = {mul = 10, flat = 0},
            Dexterity = {mul = 5, flat = 0},
            Strength = {mul = 8, flat = 0},
            Agility = {mul = 0, flat = 5},
            Explosives = {mul = 8, flat = 10},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Beast = {
            Health = {mul = 0, flat = 5},
            Marksmanship = {mul = 0, flat = 0},
            Dexterity = {mul = 10, flat = 0},
            Strength = {mul = 5, flat = 0},
            Agility = {mul = 10, flat = 0},
            Explosives = {mul = 0, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Medic = {
            Health = {mul = 15, flat = 20},
            Marksmanship = {mul = 10, flat = 10},
            Dexterity = {mul = 10, flat = 10},
            Strength = {mul = 0, flat = 0},
            Agility = {mul = 4, flat = 0},
            Explosives = {mul = 0, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 10, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Artillery = {
            Health = {mul = 5, flat = 15},
            Marksmanship = {mul = 15, flat = 0},
            Dexterity = {mul = 8, flat = 30},
            Strength = {mul = 8, flat = 0},
            Agility = {mul = 10, flat = 0},
            Explosives = {mul = 15, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Demolitions = {
            Health = {mul = 15, flat = 0},
            Marksmanship = {mul = 8, flat = 0},
            Dexterity = {mul = 10, flat = 0},
            Strength = {mul = 8, flat = 0},
            Agility = {mul = 15, flat = 0},
            Explosives = {mul = 15, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        ArmyCommander = {
            Health = {mul = 3, flat = 0},
            Marksmanship = {mul = 5, flat = 0},
            Dexterity = {mul = 10, flat = 0},
            Strength = {mul = 10, flat = 0},
            Agility = {mul = 5, flat = 0},
            Explosives = {mul = 8, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 10, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Prisioner = {
            Health = {mul = 15, flat = 0},
            Marksmanship = {mul = 10, flat = 0},
            Dexterity = {mul = 15, flat = 0},
            Strength = {mul = 8, flat = 0},
            Agility = {mul = 5, flat = 0},
            Explosives = {mul = 8, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        HyenaHandler = {
            Health = {mul = 15, flat = 0},
            Marksmanship = {mul = 10, flat = 0},
            Dexterity = {mul = 15, flat = 0},
            Strength = {mul = 8, flat = 10},
            Agility = {mul = 0, flat = 0},
            Explosives = {mul = 8, flat = 0},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        },
        Militia = {
            Health = {mul = 10, flat = 5},
            Marksmanship = {mul = 0, flat = 4},
            Dexterity = {mul = 0, flat = 0},
            Strength = {mul = 10, flat = 0},
            Agility = {mul = 0, flat = 10},
            Explosives = {mul = 5, flat = 10},
            Wisdom = {mul = 0, flat = 10},
            Medical = {mul = 0, flat = 0},
            Leadership = {mul = 0, flat = 0},
            Mechanical = {mul = 0, flat = 0}
        }
    }

    local args = map[role] or map["Soldier"]
    local difficulty_mul = CurrentModOptions.BoostStatsDifficulty == "Hard" and 66 or
                               CurrentModOptions.BoostStatsDifficulty == "Normal" and 33 or 100
    if CurrentModOptions.BoostStatsDifficulty ~= "Hardest" then
        local new_args = {}
        for stat, data in pairs(args) do
            new_args[stat] = {}
            for k, v in pairs(data) do
                local new_value = MulDivRound(v, difficulty_mul, 100)
                new_args[stat][k] = new_value
            end
        end
        args = new_args
    end

    return args
end

local function BoostStats(class)

    if CurrentModOptions.BoostStatsDifficulty == "Disabled" then
        return
    end

    local args = GetRoleArgs_BoostStats(class)
    if not args then
        return
    end

    for prop, data in pairs(args) do
        if data.mul ~= 0 then
            class[prop] = Min(100, MulDivRound(class[prop] or 60, 100 + data.mul, 100))
        end
        if data.flat ~= 0 then
            class[prop] = Min(100, (class[prop] or 60) + data.flat)
        end
    end
end

function OnMsg.UnitCreated(unit)
    if R_IsAI(unit) then
        RecalcMaxHitPoints(unit)
    end
end

function OnMsg.UnitEnterCombat(unit)
    if R_IsAI(unit) then
        RecalcMaxHitPoints(unit)
    end
end

function RATOAI_ChangeUnitDataDef(class, props)
    for k, v in pairs(props) do
        if k == "add_HWS" then
            if CurrentModOptions.AddHWStoGunners then
                AddStartingPerk(class, "HeavyWeaponsTraining")
            end
        elseif k == "Explosives" or k == "Dexterity" then
            if CurrentModOptions.ImproveExplosiveStat then
                class[k] = v
            end
        elseif k == "boost_stats" then
            BoostStats(class)
        else
            class[k] = v
        end
    end
end

