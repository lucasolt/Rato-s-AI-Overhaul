---------------------------------------------------------------------------------------------------
---- AIPolicyDealDamage normalizado.
----
---- O vanilla devolve `context.dest_target_score[dest]` CRU. Esse numero e usado em
---- duas comparacoes com naturezas diferentes:
----
----   * escolha de ALVO  -> quer Marksmanship, TargetingPolicies, randomizacao
----   * escolha de TILE  -> quer so "quanto tiro sai daqui"
----
---- Como o mesmo numero servia aos dois, a policy de posicao carregava coisas que
---- nao dizem respeito a posicao nenhuma:
----
----   raw = (SUM CTH + recoil)          <- isto sim depende do tile
----       + Marksmanship                <- constante da unidade (bug M1)
----       x TargetBaseScore/100
----       + SUM TargetingPolicies       <- "este alvo e desejavel", nao "este tile e bom"
----       x randomizacao +-TargetScoreRandomization
----
---- Alem de misturar unidades, o resultado e ILIMITADO e cresce com a proximidade
---- (mais disparos cabem no AP E cada disparo tem CTH maior), enquanto toda outra
---- policy tem teto no proprio Weight. Dai a unidade se jogar em posicao exposta.
----
---- Aqui usamos `context.dest_hit_score` (ver BUGFIX B10 em SOURCE_AIPrecalcDamageScore),
---- que e apenas a soma de CTH sobre os disparos -- ou seja, ACERTOS ESPERADOS x100,
---- ja descontado o recoil.
----
---- ATENCAO: o valor devolvido NAO e uma chance de acerto. E "quantos acertos
---- esperados este tile rende, como fracao do teto configurado". 100 significa
---- "atingiu o teto", nao "100% de acerto".
---------------------------------------------------------------------------------------------------
---- Acertos esperados (x100) que valem score 100. 400 = 4 acertos esperados.
---- Abaixo disso o score e proporcional; acima, satura.
---- Subir  -> a IA continua distinguindo posicoes muito boas (mais agressiva de perto)
---- Descer -> satura antes, a cobertura pesa mais cedo
local RATOAI_DealDamage_MaxHits = 400

function AIPolicyDealDamage:GetEditorView()
    return string.format("Deal Damage (%s, normalizado)", self.CheckLOS and "w/ LOS" or "w/o LOS")
end

function AIPolicyDealDamage:EvalDest(context, dest, grid_voxel)
    if self.CheckLOS and not g_AIDestEnemyLOSCache[dest] then
        return 0
    end

    local hits = context.dest_hit_score and context.dest_hit_score[dest]
    if not hits then
        ---- contexto antigo ou caminho que nao passou por AIPrecalcDamageScore:
        ---- cai no comportamento anterior em vez de zerar a policy
        local raw = context.dest_target_score[dest] or 0
        return
            raw > 0 and Min(100, MulDivRound(raw, 100, 100 * Max(1, context.max_attacks or 1))) or 0
    end

    if hits <= 0 then
        return 0
    end

    return Min(100, MulDivRound(hits, 100, Max(1, RATOAI_DealDamage_MaxHits)))
end
