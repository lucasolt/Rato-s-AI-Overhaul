---- PERF (C11.3): tabela constante, era reconstruida inteira (5 sub-tabelas,
---- ~20 arrays de string) a cada chamada de GetArgsForArchetypeAndWeaponSelection
local ROLE_ARGS = {
        Marksman = {
            main_w_classes = {"SniperRifle", "AssaultRifle"},
            close_w_classes = {"SubmachineGun", "Revolver", "Pistol"},
            close_archetype = "RATOAI_RetreatingMarksman",
            vr = "AIArchetypeScared",
            dist = 8
        },
        Stormer = {
            main_w_classes = {"Firearm"},
            close_w_classes = {"MeleeWeapon", "Shotgun"},
            close_archetype = "Brute",
            vr = "AIArchetypeAngry",
            dist = 8
        },
        Artillery = {
            main_w_classes = {"Artillery", "GrenadeLauncher"},
            close_w_classes = {"SubmachineGun", "Revolver", "Pistol", "AssaultRifle"},
            close_archetype = "RATOAI_RetreatingMarksman",
            vr = "AIArchetypeScared",
            dist = 7
        },
        Rocketeer = {
            main_w_classes = {"Artillery", "RocketLauncher"},
            close_w_classes = {"SubmachineGun", "Revolver", "Pistol", "AssaultRifle"},
            close_archetype = "RATOAI_RetreatingMarksman",
            vr = "AIArchetypeScared",
            dist = 6
        },
        ArmyCommander = { ---- ????? not sure why they had this in vanilla
            main_w_classes = {"Firearm"},
            close_w_classes = {"Firearm"},
            close_archetype = "Soldier",
            vr = "AIArchetypeAngry",
            dist = 12
        }

}

function GetArgsForArchetypeAndWeaponSelection(unit)

    if not unit then
        return false
    end

    local role = unit.custom_role or unit.role or ''

    local args = ROLE_ARGS[role] or false

    if not args then
        ic()
        print("RATOAI - ERROR - No args found for PickCustomArchetype for unit_id: ",
              unit.session_id, " role:", role)
    end

    return args
end

----

function CloseRangeArchetypeSelection(self, context)
    local archetype = self.archetype
    local args = GetArgsForArchetypeAndWeaponSelection(self)

    if not args then
        return archetype
    end

    local enemy, dist = GetNearestEnemy(self)

    ----- This is wrong, it should then look at the next closer enemy, but ok.
    if not enemy or enemy:IsIncapacitated() then
        return archetype
    end

    local weapon_classes = args.main_w_classes

    local check_dist = args.dist or const.Weapons.PointBlankRange

    if enemy and dist <= check_dist * const.SlabSizeX then
        weapon_classes = args.close_w_classes
        archetype = args.close_archetype or archetype
        if args.vr then
            PlayVoiceResponse(self, args.vr)
        end
    end

    local active_w = self:GetActiveWeapons()
    local slot = self.current_weapon or self:GetEquippedWeaponSlot(active_w)
    local alt_slot = slot and (slot == "Handheld A" and "Handheld B" or "Handheld A")
    local secondary_weapons_table = alt_slot and self:GetEquippedWeapons(alt_slot)

    local correct_weapon_equipped = false
    for i, class in ipairs(weapon_classes) do
        if IsKindOf(active_w, class) then
            correct_weapon_equipped = true
            break
        end
    end

    local function can_change()
        if not correct_weapon_equipped and secondary_weapons_table then
            for i, wep in ipairs(secondary_weapons_table) do
                for j, class in ipairs(weapon_classes) do
                    if IsKindOf(wep, class) then
                        return true
                    end
                end
            end
        end
        return false
    end

    if can_change() then
        AIPlayCombatAction("ChangeWeapon", self, 0)
    end

    return archetype
end
