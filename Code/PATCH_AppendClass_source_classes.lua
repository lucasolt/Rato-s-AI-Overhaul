function OnMsg.ClassesGenerate(classdefs)

    AppendClass.AISignatureAction = {
        properties = {
            {
                id = "CustomScoring",
                name = "Custom Scoring",
                editor = "func",
                default = function(self)
                    return self.Weight, false, self.Priority
                end,
                params = "self, context"
            }
        }
    }

    ---- propriedades da AIPolicyHighGround normalizada (ver SOURCE_AIPolicyHighGround.lua)
    AppendClass.AIPolicyHighGround = {
        properties = {
            {
                id = "FullBonusDz",
                name = "Altura para score maximo (voxels Z)",
                help = "1 andar = 4 voxels Z. 8 = dois andares. Acima disso satura em 100.",
                editor = "number",
                default = 8,
                min = 1,
                max = 40
            }, {
                id = "DownhillMax",
                name = "Penalidade maxima ao descer",
                help = "0 desliga a penalidade. O jogo nao penaliza terreno baixo; isto existe so para a unidade nao abrir mao da altura que ja tem.",
                editor = "number",
                default = 60,
                min = 0,
                max = 100
            }, {
                id = "Reference",
                name = "Altura relativa a",
                help = "self = posicao atual da unidade (discriminante, 0 no tile atual). enemies = altura media dos inimigos (taticamente correto, mas qualificante).",
                editor = "choice",
                default = "self",
                items = function(self)
                    return {"self", "enemies"}
                end
            }
        }
    }

    AppendClass.AIActionBaseZoneAttack = {
        properties = {
            {
                id = "enemy_cover_mod",
                name = "Enemy In Cover Score",
                help = "this value, scaled by InterpolatedCoverEffect %, will be added to the AIEvalZones score for a enemy in cover",
                editor = "number",
                default = 0
            }, {
                id = "EnemyPreparedAttackScore",
                name = "Enemy With Prepared Attack Score",
                help = "this value will be added to the AIEvalZones score for an enemy with a prepared attack",
                editor = "number",
                default = 0
            }, {
                id = "AllyThreatenedScore",
                name = "Ally Threatened",
                help = "this value will be added to the AIEvalZones score for an ally threatened by prepared attacks",
                editor = "number",
                default = 0
            }
        }
    }

    AppendClass.AIActionThrowGrenade = {
        properties = {
            {
                id = "AllowedTriggerTypes",
                editor = "set",
                items = {"Contact", "Proximity-Timed", "Proximity", "Timed", "Remote"},
                default = set("Contact", "Proximity-Timed", "Proximity", "Timed", "Remote")
            }
        }
    }

    AppendClass.AIActionPinDown = {
        properties = {
            {
                id = "AttackTargeting",
                help = "if any parts are set the unit will pick one of them randomly for each of its basic attacks; otherwise it will always use the default (torso) attacks",
                editor = "dropdownlist",
                default = "Torso",
                items = {"Arms", "Groin", "Head", "Legs", "Torso"}
            }
        }
    }

end

