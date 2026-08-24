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
            }, {
                -------------------------------------------------------------------------------
                ---- ATAQUE ALTERNATIVO x ACAO ESPECIAL
                ----
                ---- O vanilla so tem o segundo comportamento, e o embute na AIPlayAttacks
                ---- (CombatAI.lua:255-262): a signature Execute UMA vez, `max_attacks` cai 1, e o
                ---- resto do turno vai para o `context.default_attack` no bloco "revert to basic
                ---- attacks". Faz sentido para o que a palavra "signature" descreve -- granada,
                ---- montar a MG, preparar a arma, um golpe especial: coisas que se faz uma vez.
                ----
                ---- Neste mod as signatures tambem sao os MODOS DE TIRO (AutoFire, BurstFire,
                ---- SingleShot localizado), e para essas o comportamento vanilla e incoerente
                ---- duas vezes:
                ----   1. A unidade "escolhe" atirar em rajada e no segundo disparo do MESMO turno
                ----      volta para o que o GetDefaultAttackAction mandar, sem ter decidido nada.
                ----   2. O scoring nao descreve isso. O RATOAI_ExpectedFor mede N ataques da acao
                ----      candidata (`AICalcAttacksAndAim` com o custo DELA), entao o peso que
                ----      elegeu a acao foi calculado sobre um turno que nao vai acontecer.
                ----
                ---- Ligado, a acao passa a ser o ataque padrao do resto do turno -- o laco de
                ---- revert continua no mesmo modo de tiro, e ai a conta do scoring vira verdade.
                ---- Ver RATOAI_SustainFiringMode em SOURCE_AIPlayAttacks.lua.
                ----
                ---- Default `false` = vanilla. So aparece no editor nas signatures de tiro
                ---- (AIActionSingleTargetShot e derivadas, inclusive AIActionMGBurstFire): nas
                ---- demais o Execute nao chama o sustain, e um interruptor visivel que nao faz
                ---- nada e pior que interruptor nenhum.
                -------------------------------------------------------------------------------
                id = "SustainedAttack",
                name = "Sustentar o modo de tiro no turno",
                help = "Desligado (vanilla): a acao dispara UMA vez e o resto do turno usa o " ..
                    "ataque padrao da arma -- comportamento de 'acao especial'.\n" ..
                    "Ligado: a acao vira o ataque padrao do resto do turno, ou seja a unidade " ..
                    "sustenta o modo de tiro que escolheu -- comportamento de 'ataque " ..
                    "alternativo'. E o que o scoring por resultado esperado ja pressupoe: ele " ..
                    "mede N ataques DESTA acao, nao 1 dela mais N-1 do padrao.",
                editor = "bool",
                default = false,
                no_edit = function(self)
                    return not IsKindOf(self, "AIActionSingleTargetShot")
                end
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
                default = "soft",
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
                default = 100,
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

    -------------------------------------------------------------------------------------------
    ---- POSTURA DE DESTINO POR COBERTURA  (BUGFIX B37, SOURCE_AIFindDestinations.lua)
    ----
    ---- NAO E A MESMA COISA QUE `PrefStance`, e a diferenca importa:
    ----
    ----   PrefStance  = "que postura eu GOSTO de ter". E uma preferencia constante, e o motor a
    ----                 usa em dois lugares: o AIBuildArchetypePaths empacota o destino nela
    ----                 quando sobra AP para chegar assim, e o AIBehavior:TakeStance a adota no
    ----                 fim do turno se ja estiver no destino. Nao olha o tile.
    ----
    ----   ExposedProne = "que postura ESTE TILE pede". Olha a cobertura do voxel e decide por
    ----                 destino: com cobertura, agacha (regra de sempre); aberto, deita.
    ----
    ---- Convivem: o PrefStance continua mandando em tudo que nao seja tile aberto. Nos
    ---- arquetipos com PrefStance = Prone esta property nao tem efeito nenhum -- o B25 ja deita
    ---- em tudo o que estiver ao alcance, e as duas conversoes se excluem para nao cobrar a
    ---- mudanca de postura duas vezes.
    -------------------------------------------------------------------------------------------
    AppendClass.AIArchetype = {
        properties = {
            {
                category = "Strategy",
                id = "ExposedProne",
                name = "Prone When Exposed",
                help = "No tile SEM cobertura nenhuma, empacota o destino deitado em vez de em " ..
                    "pe. Tile com cobertura continua seguindo a regra de agachar." .. "\n" ..
                    "Sem efeito quando Stance Preference = Prone (essa ja deita em tudo).",
                editor = "bool",
                default = false
            }, {
                category = "Strategy",
                id = "ExposedProneMinTiles",
                name = "Prone Exclusion Radius",
                help = "Distancia ate o inimigo mais proximo abaixo da qual NAO se deita, em " ..
                    "tiles. Deitado colado no inimigo e armadilha: levantar custa AP, o campo " ..
                    "de tiro e pior e a unidade fica presa." .. "\n" .. "0 = deita a qualquer " ..
                    "distancia.",
                editor = "number",
                default = 8,
                min = 0,
                max = 30,
                no_edit = function(self)
                    return not self.ExposedProne
                end
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

