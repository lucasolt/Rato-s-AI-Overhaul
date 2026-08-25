UndefineClass('SuperSoldier_Assault_copy')
DefineClass.SuperSoldier_Assault_copy = {
	__parents = { "UnitData" },
	__generated_by_class = "ModItemUnitDataCompositeDef",


	__copy_group = "SiegfriedSuperSoldiers",
	object_class = "UnitData",
	Health = 75,
	Agility = 75,
	Dexterity = 75,
	Strength = 85,
	Wisdom = 56,
	Leadership = 50,
	Marksmanship = 84,
	Mechanical = 50,
	Explosives = 39,
	Medical = 52,
	Portrait = "UI/EnemiesPortraits/ArmyHeavy",
	Name = T(255682331059, "Soldat"),
	Randomization = true,
	Affiliation = "SuperSoldiers",
	StartingLevel = 6,
	neutral_retaliate = true,
	AIKeywords = {
		"Control",
	},
	role = "Soldier",
	MaxAttacks = 2,
	PickCustomArchetype = function (self, proto_context)  end,
	MaxHitPoints = 50,
	StartingPerks = {
		"AutoWeapons",
		"Berserker",
		"HoldPosition",
		"DieselPerk",
	},
	AppearancesList = {
		PlaceObj('AppearanceWeight', {
			'Preset', "Landsbach_SuperSoldier_Assault",
		}),
	},
	Equipment = {
		"SuperSoldier_Assault",
	},
	AdditionalGroups = {},
	Tier = "Elite",
	pollyvoice = "Joey",
	gender = "Male",
	VoiceResponseId = "SuperSoldier_Assault",
}

