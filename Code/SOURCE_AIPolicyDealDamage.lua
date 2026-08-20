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
---- esperados este tile rende", convertido para 0..100 pela normalizacao escolhida.
---- 100 significa "atingiu o teto da normalizacao", nao "100% de acerto".
---------------------------------------------------------------------------------------------------
---- TRES NORMALIZACOES, escolhidas por instancia na property `Normalization`
---- (definida em PATCH_AppendClass_source_classes.lua):
----
----   cap    -- linear ate MaxHits, PLANO depois. Comportamento historico e o default.
----             Defeito: acima do teto todo tile marca 100, entao a policy fica MUDA
----             exatamente entre as melhores posicoes de tiro, que e onde discriminar
----             mais importa. A escolha ali cai inteira nas outras policies.
----
----   soft   -- 100 x h / (h + SoftK). Continua limitada (assintota em 100, que era o
----             motivo de o teto existir) mas nunca fica plana: 6 acertos sempre valem
----             mais que 3. Nunca ATINGE 100, entao o Weight efetivo encolhe.
----
----   tokill -- normaliza pelos acertos necessarios para DERRUBAR o alvo escolhido.
----             100 passa a significar "daqui eu derrubo ele", e o teto vira o HP do
----             alvo em vez de uma constante escolhida a dedo -- overkill nao vale nada,
----             que e a razao certa para existir um teto.
----             Ressalvas: (a) o alvo sai de uma ROLETA no AIPrecalcDamageScore, entao o
----             normalizador varia um pouco entre destinos por motivo alheio a posicao;
----             (b) um inimigo ferido faz todo tile parecer melhor -- comportamento
----             correto (finalizar), mas e mudanca de ranking que nao vem da posicao.
----
---- Nao normalize pelo melhor tile DO TURNO (score = 100 x h / melhor_h). E tentador
---- porque se auto-escala e elimina a constante, mas quebra a comparacao com a ameaca:
---- num turno em que o melhor tiro possivel e pessimo, o melhor tile ainda marcaria 100
---- e a unidade avancaria com o mesmo entusiasmo de quando podia matar. A ameaca esta em
---- unidade absoluta; o dano precisa estar tambem.
---------------------------------------------------------------------------------------------------

function AIPolicyDealDamage:GetEditorView()
    local modo = self.Normalization or "cap"
    local detalhe
    if modo == "soft" then
        detalhe = string.format("suave K=%d", self.SoftK or 200)
    elseif modo == "tokill" then
        detalhe = self.KillIsEnough and "para derrubar" or "para derrubar, sem teto"
    else
        detalhe = string.format("teto %d", self.MaxHits or 200)
    end
    return string.format("Deal Damage (%s, %s)", self.CheckLOS and "w/ LOS" or "w/o LOS", detalhe)
end

---- Dano por acerto da unidade que esta decidindo. Constante dentro do turno, e a policy
---- roda uma vez por destino -- entao fica no context, calculado no maximo uma vez.
---- `false` guardado = "ja tentei e nao deu", para nao repetir a tentativa por destino.
local function RATOAI_DamagePerHit(context)
    local cached = context.__ratoai_dmg_per_hit
    if cached ~= nil then
        return cached or nil
    end

    local unit, weapon = context.unit, context.weapon
    local dmg
    if unit and weapon and unit.GetBaseDamage then
        ---- pcall: GetBaseDamage passa por componentes de arma e efeitos: um mod de
        ---- terceiro que quebre ali nao pode derrubar o turno da IA
        local ok, v = pcall(unit.GetBaseDamage, unit, weapon)
        if ok and type(v) == "number" and v > 0 then
            dmg = v
        end
    end

    context.__ratoai_dmg_per_hit = dmg or false
    return dmg
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

    local modo = self.Normalization or "cap"

    ---- saturacao suave: sem teto duro, sem trecho plano
    if modo == "soft" then
        return MulDivRound(100, hits, hits + Max(1, self.SoftK or 200))
    end

    ---- acertos necessarios para derrubar o alvo escolhido neste destino
    if modo == "tokill" then
        local target = context.dest_target and context.dest_target[dest]
        local dmg = RATOAI_DamagePerHit(context)
        if IsValid(target) and dmg then
            ---- `needed` na MESMA escala de `hits` (acertos x100): HP/dano x 100
            local needed = Max(1, MulDivRound(Max(1, target.HitPoints or 1), 100, dmg))
            local score = MulDivRound(hits, 100, needed)
            return self.KillIsEnough and Min(100, score) or score
        end
        ---- sem alvo valido ou sem estimativa de dano: cai no `cap` em vez de zerar a
        ---- policy, senao um destino sem alvo escolhido perderia o score de tiro inteiro
    end

    return Min(100, MulDivRound(hits, 100, Max(1, self.MaxHits or 200)))
end
