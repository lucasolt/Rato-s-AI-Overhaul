function RATOAI_CUAEoptions()
    if IsMod_loaded("LDCUAE") then
        local night_pack = { -- Night Combat Package
            type = {{"Flare", 60}}, -- High probability illumination
            nightOnly = true, -- Night/underground exclusive
            amount = 3 -- Three flare devices
        }

        -- Fumaca e gas sao raros de proposito: a IA ainda nao usa cortina nem area denial
        -- bem o bastante para justificar o volume. As granadas de Smoke/Tear que o jogo ja
        -- distribui por LootDef nao sao tocadas -- isto aqui so limita o que NOS adicionamos.
        -- Efeito colateral util do dedup por tipo (Loadout.lua:98): se a unidade ja veio com
        -- fumaca do loadout base, esta policy e pulada e nao empilha em cima.
        local rare_gas = {type = {{"Smoke", 10}, {"Tear", 18}}, amount = 1}

        local role_table = {

            Artillery = {extraWeapons = {{type = {{"AssaultRifle", 50}, {"SMG", 100}}}}},
            Marksman = {
                weaponComponentsPriorities = {
                    Sniper = {tag = "Precision", prioritySlots = {"Scope", "Mount", "Barrel"}}
                },
                -- weaponComponentsCurve = {
                --     28, 34, 40, 46, 52, 58, 64, 70, 76, 82, 88, 94, 99, 99, 99, 99, 99, 99, 99, 99
                -- },
                extraWeapons = {{type = {{"Handgun", 70}, {"SMG", 100}}, size = 1}},
                replacements = {MeleeWeapon = {discard = true}},

                extraUtility = {{type = {{"Explosive", 10}, {"Flash", 30}}, amount = 1}}
            },
            Soldier = {
                weaponComponentsPriorities = {
                    AssaultRifle = {tag = "Tactical", prioritySlots = {"Muzzle", "Stock", "Barrel"}}
                },

                extraUtility = {
                    night_pack, {type = {{"Explosive", 40}, {"Flash", 50}}, amount = 2}, rare_gas
                }
            },
            Commander = {
                extraUtility = {
                    night_pack, {type = {{"Explosive", 50}, {"Flash", 80}}, amount = 2}, rare_gas
                }
            },
            Demolitions = {
                -- Granadeiro: volume ofensivo mantido, so o gas ficou raro.
                extraUtility = {
                    night_pack, {type = {{"Explosive", 70}, {"Timed", 100}}, amount = 3},
                    {type = {{"Fire", 45}, {"Flash", 90}}, amount = 2},
                    {type = {{"Smoke", 20}, {"Tear", 35}}, amount = 1}
                }

            },
            Recon = {
                weaponComponentsPriorities = {
                    SMG = {
                        tag = "CloseQuarters",
                        prioritySlots = {"Muzzle", "Stock", "Barrel", "Side"}
                    },
                    Handgun = {tag = "CloseQuarters", prioritySlots = {"Scope", "Barrel", "Side"}}
                },
                extraUtility = {night_pack, {type = {{"Flash", 40}, {"Explosive", 50}}, amount = 2}}
            },

            Stormer = {
                weaponComponentsPriorities = {
                    Shotgun = {tag = "CloseQuarters", prioritySlots = {"Barrel", "Muzzle"}}
                },
                extraUtility = {night_pack, {type = {{"Explosive", 20}, {"Fire", 50}}, amount = 2}}

            },
            Heavy = {
                weaponComponentsPriorities = {
                    MachineGun = {tag = "CloseQuarters", prioritySlots = {"Scope", "Stock", "Side"}}
                }
            }
        }

        local cuaeSettings = {
            LoadoutTables = {
                Legion = role_table,
                Rebel = role_table,
                Thugs = role_table,
                Army = role_table,
                Adonis = role_table,
                SuperSoldiers = role_table,
                Militia = role_table
            }
        }
        local cuaeImmunityTable = {'ToxicGasGrenade'}
        CUAEAddImmunityTable(cuaeImmunityTable)
        CUAEForceSettings(cuaeSettings)
        RATOAI_AddExclusionCUAE()
    end
end

function OnMsg.ModsReloaded()
    RATOAI_CUAEoptions()
end
function OnMsg.DataLoaded()
    RATOAI_CUAEoptions()
end
function OnMsg.OptionsApply()
    RATOAI_CUAEoptions()
end

function RATOAI_AddExclusionCUAE()

    if not CurrentModOptions.CUAELoreProgression then
        return
    end

    local german = {'HK23E_1', 'HK33A2_1', 'P90_2', 'HK53_1', 'HK23ECamo_1', 'PSG1', 'G36', 'HK21'}

    local german_common = {'MP5', 'MP5K', 'UMP_1', 'USP_1', 'G3A3_1', 'G3A3Green_1'}

    local eastern_common = {
        'RK95_1', 'RK62_1', 'SKS_1', 'Type56A_1', 'Type56B_1', 'Type56C_1', 'Type56D_1',
        'PapovkaSKS_1', 'Papovka2SKS_1', 'PKM_1', 'RPD_1', 'M76_1', 'PP91_1', 'M70_1', 'M70D_1',
        'AK47'
    }
    local eastern_new = {'AK74', 'RPK74', 'DragunovSVD', 'AKSU', 'Groza_1', 'VSK94_1', 'A91_2'}
    local eastern_special = {'AN94_1', 'VSS_1'}

    local western = {
        'FNMinimi', 'M14SAW_AUTO', 'M16A2', 'AUG', 'FAMAS', 'M4Commando', 'M24Sniper', 'M41Shotgun',
        'MAC11_1', 'M1911_1', "AR10std"
    }

    local other = {'ColtAnaconda', 'DesertEagle', 'Bereta92', 'Glock18', 'B93RR_1', 'Glock17_1'}

    local israeli = {'MicroUZI_1', 'UZI', 'Galil', 'TAR21_1'}

    local old_war = {
        'Mosin_1', 'Delisle_1', 'VigM2_1', 'StenMK2_1', 'STG44R_1', 'P08_1', 'M1Garand_2',
        'Gewehr43_1', 'Gewehr98', 'MP40', 'MG42', 'HiPower', 'Winchester1894', 'Auto5',
        'DoubleBarrelShotgun', "ColtPeacemaker"
    }

    local civilian = {'SteyrScout_1', 'SSG69_1', 'AR15', 'M14SAW'}

    local end_game = {'BarretM82', 'AA12'}

    -- fix for too much sks 
    local excl_table = {
        Army = {"G11_1"},
        Adonis = {"G11_1"},
        Rebel = {'Type56A_1', 'Type56C_1', "G11_1"},
        Thugs = {"M14SAW_AUTO", 'Type56D_1', 'Type56B_1', 'PapovkaSKS_1', 'SKS_1', "G11_1"},
        Legion = {'Type56D_1', 'Type56C_1', 'Papovka2SKS_1', "G11_1"},
        SuperSoldiers = {},
        Militia = {"M14SAW_AUTO", 'Type56D_1', 'Type56D_1', 'Type56C_1', 'Papovka2SKS_1', "G11_1"}
    }

    local non_nazi_old_war = {
        'Mosin_1', 'Delisle_1', 'VigM2_1', 'StenMK2_1', 'P08_1', 'M1Garand_2', 'HiPower',
        'Winchester1894', 'Auto5', 'DoubleBarrelShotgun', "ColtPeacemaker"
    }

    local old_war_except_mosin = {
        'Delisle_1', 'VigM2_1', 'StenMK2_1', 'STG44R_1', 'P08_1', 'M1Garand_2', 'Gewehr43_1',
        'Gewehr98', 'MP40', 'MG42', 'HiPower', 'Winchester1894', 'Auto5', 'DoubleBarrelShotgun',
        "ColtPeacemaker"
    }

    local function add_items(destination, ...)
        for _, list in ipairs({...}) do
            for _, item in ipairs(list) do
                table.insert_unique(destination, item)
            end
        end
    end

    add_items(excl_table.Army, old_war, civilian, eastern_special, eastern_common)
    add_items(excl_table.Adonis, old_war, eastern_common)
    add_items(excl_table.Rebel, german, german_common, western, old_war_except_mosin, civilian)
    add_items(excl_table.Thugs, german, end_game, eastern_special, western)
    add_items(excl_table.Legion, german, end_game, eastern_special)
    add_items(excl_table.SuperSoldiers, non_nazi_old_war, civilian, eastern_special, eastern_common,
              eastern_new, western, israeli)
    add_items(excl_table.Militia, german, end_game, eastern_special)

    CUAEAddExclusionTable(excl_table)
end

