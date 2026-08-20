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

    -----------------------------------------------------------------------------------
    ---- Normalizacao da AIPolicyDealDamage (ver SOURCE_AIPolicyDealDamage.lua)
    ----
    ---- A policy converte "acertos esperados" num score 0..100. Como converter e a
    ---- pergunta, e as tres respostas tem defeitos diferentes -- por isso e uma escolha
    ---- por instancia, e nao uma constante no arquivo.
    -----------------------------------------------------------------------------------
    AppendClass.AIPolicyDealDamage = {
        properties = {
            {
                id = "Normalization",
                name = "Normalizacao dos acertos",
                help = "relative = 100 significa: extraio daqui tudo que sou capaz. " ..
                    "Divide pela capacidade da propria unidade, entao a escala fica " ..
                    "igual para todos e nao ha o que calibrar -- so o Weight. Recomendado.\n" ..
                    "cap    = linear ate MaxHits e PLANO depois (comportamento antigo).\n" ..
                    "soft   = saturacao suave, nunca fica plana: 6 acertos sempre valem " ..
                    "mais que 3. Corrige o ponto cego do cap, que e justamente entre as " ..
                    "melhores posicoes de tiro.\n" ..
                    "tokill = 100 significa \"daqui eu derrubo o alvo\". O teto passa a " ..
                    "ser o HP dele em vez de uma constante escolhida a dedo.",
                editor = "choice",
                default = "relative",
                items = function(self)
                    return {"relative", "cap", "soft", "tokill"}
                end
            }, {
                id = "MaxHits",
                name = "Acertos (x100) que valem 100  [cap]",
                help = "So no modo `cap`. 200 = dois acertos esperados atingem o teto. " ..
                    "Subir -> continua distinguindo posicoes muito boas (mais agressiva de " ..
                    "perto). Descer -> satura antes, a cobertura pesa mais cedo.",
                editor = "number",
                default = 200,
                min = 1,
                max = 2000
            }, {
                id = "SoftK",
                name = "Meia-escala  [soft]",
                help = "So no modo `soft`. Score = 100 x acertos / (acertos + K), entao K " ..
                    "e onde o score passa por 50. Com K=200: 1 acerto->33, 2->50, 4->67, " ..
                    "10->83. Nunca chega a 100, entao o Weight efetivo encolhe -- suba o " ..
                    "Weight ao ligar este modo.",
                editor = "number",
                default = 200,
                min = 1,
                max = 2000
            }, {
                ---------------------------------------------------------------------
                ---- Marksmanship e AP total sao constantes DA UNIDADE: valem o mesmo
                ---- em todo destino, entao nao dizem nada sobre posicao -- so deslocam
                ---- a escala inteira daquela unidade contra as outras policies. Medido
                ---- nos inimigos: Marksmanship de 56 (LegionScout) a 100
                ---- (AdonisSquadLeader), e o hit_score chega a 3x por causa disso
                ---- multiplicado por mais AP. Resultado: mob ruim medroso, mob bom
                ---- temerario, sem que nenhum dos dois tenha achado posicao melhor.
                ----
                ---- Aqui o divisor e interpolado entre o fixo (MaxHits/SoftK) e um
                ---- referencial INTRINSECO da unidade -- `max_attacks x Marksmanship`,
                ---- ou seja "todos os meus disparos acertando no meu nivel".
                ----
                ---- Intrinseco, e nao "o melhor tile do turno", de proposito: um
                ---- referencial situacional daria 100 ao melhor tile mesmo num turno
                ---- sem tiro nenhum, e quebraria a comparacao com a ameaca, que esta em
                ---- unidade absoluta.
                ----
                ---- Nao se aplica ao modo `tokill`: la o divisor e o HP do alvo e o
                ---- ponto do modo e letalidade absoluta -- atirador ruim genuinamente
                ---- nao mata, e cancelar habilidade contradiria o modo.
                ---------------------------------------------------------------------
                id = "SkillNormalize",
                name = "Cancelar habilidade da unidade (%)  [cap/soft]",
                help = "0 = comportamento atual: unidade boa pontua mais so por ser boa.\n" ..
                    "100 = a capacidade cancela por completo -- mesma posicao, mesma " ..
                    "nota, seja Goon ou SquadLeader.\n" ..
                    "Quem esta em SkillRefScore nao muda de nota; quem esta abaixo SOBE. " ..
                    "Ancore no seu mob mais capaz para o efeito ser elevar os fracos.\n" ..
                    "Nao tem efeito no modo `tokill`.",
                editor = "number",
                default = 0,
                min = 0,
                max = 100
            }, {
                ---- Ancora da normalizacao, em "disparos x Marksmanship". 400 = uma
                ---- unidade que consegue 4 disparos com Marksmanship 100. A unidade que
                ---- bate exatamente esta marca mantem o divisor intacto; as abaixo dela
                ---- sobem de nota, as acima descem.
                id = "SkillRefScore",
                name = "Ancora da normalizacao (disparos x Mark)",
                help = "Capacidade da unidade de REFERENCIA: disparos que ela consegue " ..
                    "vezes a Marksmanship dela. 400 = 4 disparos com Mark 100.\n" ..
                    "Quem bate esta marca nao muda de nota -- entao ancore no seu mob " ..
                    "mais capaz e os fracos e que sobem.",
                editor = "number",
                default = 655,
                min = 1,
                max = 4000
            }, {
                id = "KillIsEnough",
                name = "Derrubar ja vale 100  [tokill]",
                help = "So no modo `tokill`. Ligado, o score satura quando os acertos " ..
                    "esperados bastam para derrubar o alvo -- overkill nao vale nada. " ..
                    "Desligado, continua crescendo (util se voce quiser que ela prefira " ..
                    "margem de seguranca sobre o minimo necessario).",
                editor = "bool",
                default = true
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

