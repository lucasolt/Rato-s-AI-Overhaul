---------------------------------------------------------------------------------------------------
---- FUNCTION_SetArchetypePolicies
----
---- Controle central dos pesos (Weight) de AIPositioningPolicy e do OptLocWeight de cada
---- AIBehavior, para todos os arquetipos do mod, num unico lugar -- sem abrir a arvore do
---- editor in-game policy por policy.
----
---- O items.lua continua sendo quem define a ESTRUTURA (quais policies existem, em que
---- behavior, em que ordem) -- isso so muda pelo editor, como sempre. Este arquivo so
---- SOBRESCREVE o campo .Weight (e .OptLocWeight) das instancias ja carregadas, depois que
---- todos os presets terminaram de carregar (OnMsg.DataLoaded).
----
---- RATOAI_SoldierWeights (logo abaixo) e a fonte de verdade dos pesos do Soldier -- uma
---- tabela unica preenchida a mao, no formato de "spec" que RATOAI_ApplyArchetypeWeights ja
---- entende (Behaviors[key].EndTurn[classe] / OptLoc[classe]). RATOAI_BuildArchetypeWeights
---- aplica essa tabela ao proprio Soldier e deriva os outros arquetipos dela por soma ou
---- MulDivRound -- nunca lendo o Soldier de volta do items.lua carregado (Archetypes.Soldier).
---- Editar o Soldier e so mudar os numeros ali; tudo que deriva dele acompanha.
----
---- Uso: RATOAI_BuildArchetypeWeights() devolve a tabela de overrides, uma entrada por
---- arquetipo -- incluindo o proprio "Soldier".
----
---- Uma policy que aparece mais de uma vez na mesma lista (ex.: dois AIPolicyDealDamage, um
---- "soft" e um "tokill") se distingue por OCORRENCIA: a 1a com essa classe, a 2a, etc. Passe
---- um numero para sobrescrever so a 1a ocorrencia, ou uma lista {v1, v2, ...} para varias;
---- 'false' num slot da lista pula aquela ocorrencia (deixa o Weight do items.lua como esta).
----
---- Cada behavior se identifica pelo BiasId (se nao vazio) ou pelo Comment (fallback) -- os
---- mesmos rotulos que ja aparecem no editor e no sistema de bias.
----
---- Toda chave de override (classe de policy ou behavior) que nao for encontrada na lista real
---- estoura um assert -- typo ou o preset mudou no editor e a tabela ficou desatualizada. Nao
---- degrada em silencio.
---------------------------------------------------------------------------------------------------

---- aplica os overrides de uma tabela {class_name = valor ou {v1, v2, ...}} sobre uma lista de
---- policies real (OptLocPolicies ou EndTurnPolicies de um behavior).
local function RATOAI_ApplyWeightOverrides(list, overrides, label)
    if not list or not overrides then
        return
    end

    local seen = {}
    for _, policy in ipairs(list) do
        local class_name = policy.class
        seen[class_name] = (seen[class_name] or 0) + 1

        local override = overrides[class_name]
        if override ~= nil then
            local value
            if type(override) == "table" then
                value = override[seen[class_name]]
            elseif seen[class_name] == 1 then
                value = override
            end
            if value and value ~= false then
                policy.Weight = value
            end
        end
    end

    for class_name in pairs(overrides) do
        assert(seen[class_name], string.format(
            "RATOAI_SetArchetypePolicies: %s tem override pra %s, mas essa policy nao existe na lista " ..
            "(typo, ou o preset mudou no editor e a tabela ficou desatualizada)",
            label, class_name))
    end
end

local function RATOAI_GetBehaviorKey(behavior)
    if behavior.BiasId and behavior.BiasId ~= "" then
        return behavior.BiasId
    end
    if behavior.Comment and behavior.Comment ~= "" then
        return behavior.Comment
    end
    return behavior.class
end

local function RATOAI_ApplyArchetypeWeights(archetype_id, spec)
    local archetype = Archetypes[archetype_id]
    assert(archetype, "RATOAI_SetArchetypePolicies: arquetipo desconhecido: " .. tostring(archetype_id))

    RATOAI_ApplyWeightOverrides(archetype.OptLocPolicies, spec.OptLoc, archetype_id .. " OptLoc")

    local behavior_specs = spec.Behaviors
    if not behavior_specs then
        return
    end

    local matched = {}
    for _, behavior in ipairs(archetype.Behaviors) do
        local key = RATOAI_GetBehaviorKey(behavior)
        local behavior_spec = behavior_specs[key]
        if behavior_spec then
            matched[key] = true
            if behavior_spec.OptLocWeight then
                behavior.OptLocWeight = behavior_spec.OptLocWeight
            end
            RATOAI_ApplyWeightOverrides(behavior.EndTurnPolicies, behavior_spec.EndTurn,
                archetype_id .. "." .. tostring(key) .. " EndTurn")
        end
    end

    for key in pairs(behavior_specs) do
        assert(matched[key], string.format(
            "RATOAI_SetArchetypePolicies: %s nao tem behavior com BiasId/Comment %q pra sobrescrever",
            archetype_id, key))
    end
end

---- Tabela unica com os pesos do Soldier -- preencha AQUI, a mao. E a fonte de verdade: nao e
---- lida do items.lua, e sim aplicada por cima dele (via RATOAI_ApplyArchetypeWeights, mais
---- abaixo). Os outros arquetipos derivam dela, nunca do Archetypes.Soldier carregado.
local RATOAI_SoldierWeights = {
    Behaviors = {
        StandardAI = {
			-- OptLocWeight = 100,
            EndTurn = {
                AIPolicyDealDamage = { 150, 50 }, -- soft 190, tokill
                AIPolicyThreatExposure = 200,
            },
        },
    },
    OptLoc = {
		AIPolicyCustomWeaponRange = 110,
        AIPolicyLosToEnemy = 50,
		AIPolicyEncircleEnemy = 100,
		AIPolicyHighGround = 50, --- z = 4
    },
}

local RATOAI_SniperWeights = {
	Behaviors = {
		StandardAI = {
			-- OptLocWeight = 100,
			EndTurn = {
				AIPolicyDealDamage = { 200, 40 }, -- soft 50, tokill
				AIPolicyThreatExposure = 150,
			},
		},
	},
	OptLoc = {
		AIPolicyHighGround = 150, --- z = 8
		AIPolicyLosToEnemy = 50,
		AIPolicyCustomWeaponRange = 100,
	},
}

local RATOAI_SkirmisherWeights = {
	Behaviors = {
		StandardAI = {
			-- OptLocWeight = 100,
			EndTurn = {
				AIPolicyDealDamage = { 175, 75 }, -- soft 190, tokill
				AIPolicyThreatExposure = 170,
			},
		},
		PositioningAI = {
			EndTurn = {
				AIPolicyDealDamage = { 200, 75 }, -- soft 190, tokill
				AIPolicyThreatExposure = 120,
				AIPolicyCustomFlanking = 100, -- required, alvo, reserve ap stance
			},
		},
	},
	OptLoc = {
		AIPolicyCustomWeaponRange = 100,
		AIPolicyLosToEnemy = 50,
		AIPolicyEncircleEnemy = 150,
	},
}
---- Tabela central. Adicione um arquetipo por chave; cada um pode derivar seus numeros de
---- RATOAI_SoldierWeights por soma ou MulDivRound (nunca "*", ver CLAUDE.md sobre divisao
---- inteira).
----
---- Exemplo abaixo: RATOAI_Sniper derivado do Soldier -- mesmo DealDamage "soft" (sniper
---- tambem quer volume de acerto), tokill um pouco mais barato, ThreatExposure mais frouxo
---- (papel de suporte de fogo, nao de linha de frente), HighGround triplicado (o Sniper e
---- quem realmente usa elevacao) e LosToEnemy igual.
function RATOAI_BuildArchetypeWeights()
    local soldier_deal_damage_soft = RATOAI_SoldierWeights.Behaviors.Standard.EndTurn.AIPolicyDealDamage[1]
    local soldier_deal_damage_tokill = RATOAI_SoldierWeights.Behaviors.Standard.EndTurn.AIPolicyDealDamage[2]
    local soldier_threat_exposure = RATOAI_SoldierWeights.Behaviors.Standard.EndTurn.AIPolicyThreatExposure
    local soldier_high_ground = RATOAI_SoldierWeights.OptLoc.AIPolicyHighGround
    local soldier_los_to_enemy = RATOAI_SoldierWeights.OptLoc.AIPolicyLosToEnemy

    return {
        Soldier = RATOAI_SoldierWeights,

        RATOAI_Sniper = {
            Behaviors = {
                Standard = {
                    EndTurn = {
                        AIPolicyDealDamage = { soldier_deal_damage_soft, soldier_deal_damage_tokill - 10 },
                        AIPolicyThreatExposure = soldier_threat_exposure - 50,
                    },
                },
            },
            OptLoc = {
                AIPolicyHighGround = MulDivRound(soldier_high_ground, 300, 100),
                AIPolicyLosToEnemy = soldier_los_to_enemy,
            },
        },
    }
end

function RATOAI_SetArchetypePolicies()
    for archetype_id, spec in pairs(RATOAI_BuildArchetypeWeights()) do
        RATOAI_ApplyArchetypeWeights(archetype_id, spec)
    end
end

function OnMsg.DataLoaded()
    --RATOAI_SetArchetypePolicies()
end

function OnMsg.ModsReloaded()
    --RATOAI_SetArchetypePolicies()
end
