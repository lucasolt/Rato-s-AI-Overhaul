---- PERF (C9): flag unica para todo o mod. Quando falsa, os caminhos de debug
---- nao alocam nada. Mesma condicao que AIPOLICYPOS_CustomSeekCover ja usava.
---- As tabelas de debug do context continuam sendo criadas (vazias) em
---- AICreateContext, porque DEBUG.lua as indexa sem checar existencia --
---- o que custava caro era o PREENCHIMENTO delas, nao a criacao.
----
---- BUGFIX (B16): a flag era avaliada UMA vez, na execucao deste arquivo -- o mesmo
---- erro que o comentario de AIPOLICYPOS_CustomSeekCover.lua:101 ja registrava para o
---- gate antigo daquela policy. Em build goldmaster `Platform.developer` e nil quando
---- este mod carrega; quem liga as duas flags e o `ForceDev.lua` do mod *Rato Dev*,
---- que carrega DEPOIS. Resultado: `RATOAI_Debug` congelava em false e TODO caminho de
---- debug do mod ficava morto (cth_attacks_at, aims_at, dbg_targets) mesmo com o painel
---- de debug aberto e os cheats ligados.
----
---- Continua sendo um booleano simples, e nao uma funcao: o caminho quente le
---- `local trace = RATOAI_Debug` por chamada e nao pode pagar uma chamada de funcao.
---- So o momento da avaliacao mudou.
----
---- `const.RATOAI.DebugForce = true/false` no console trava o valor; nil (o default) volta
---- ao automatico. Sem essa valvula, ligar `RATOAI_Debug` a mao seria
---- desfeito na proxima recomputacao -- e a recomputacao acontece no CombatStart,
---- exatamente quando se esta tentando depurar.
---- BUGFIX (B32): a valvula estava quebrada pelo mesmo motivo do idioma antigo de constantes.
---- `rawget(_G, "RATOAI_DebugForce")` NAO ve um global setado pelo console, porque neste engine
---- os globais moram atras do `__index` do _G -- ou seja, digitar `RATOAI_DebugForce = true` no
---- console nunca teve efeito nenhum. Agora mora em const.RATOAI, que e tabela comum e le e
---- escreve normal. Ver o cabecalho de CONSTANTS_AI_source.lua.
function RATOAI_RecomputeDebugFlag()
    local forced = const.RATOAI and const.RATOAI.DebugForce
    if forced ~= nil then
        RATOAI_Debug = forced and true or false
        return
    end
    RATOAI_Debug = Platform.developer and Platform.cheats and true or false
end


RATOAI_RecomputeDebugFlag()

---- ClassesBuilt e o primeiro marco depois que TODO codigo de mod ja executou (o
---- proprio ForceDev.lua se apoia nisso). ModsReloaded cobre o reload em runtime, e
---- CombatStart e a rede de seguranca barata -- e o unico momento em que a flag
---- importa, e nao esta em caminho quente.
----
---- BUGFIX (B45): estas tres linhas estavam COMENTADAS, o que reabria o B16 por inteiro -- a
---- chamada solta acima e a unica que rodava, e ela roda no load, quando `Platform.developer`
---- ainda e nil. A flag congelava em false para sempre e TODO o caminho de debug do mod ficava
---- morto: `dbg_expected` (painel "Resultado esperado" do Rato Dev), `cth_attacks_at` e `aims_at`
---- sao todos porteados por `RATOAI_Debug`.
----
---- Medido no processo vivo em 2026-08-27, com o painel aberto e os cheats ligados:
----   RATOAI_Debug                        => false
----   Platform.developer / Platform.cheats => true / true
----   const.RATOAI.DebugForce              => nil
----   RATOAI_RecomputeDebugFlag()          => RATOAI_Debug vira true
---- Ou seja: as entradas estavam todas certas e faltava so alguem chamar a recomputacao. O B16
---- foi diagnosticado e escrito, mas o gancho nunca foi ligado -- por isso o sintoma voltou
---- parecendo outro bug (as linhas de detalhe do painel sumindo, atribuidas ao rename dbg->trace
---- e depois ao B44).
OnMsg.ClassesBuilt = RATOAI_RecomputeDebugFlag
OnMsg.ModsReloaded = RATOAI_RecomputeDebugFlag
OnMsg.CombatStart = RATOAI_RecomputeDebugFlag

---------------------------------------------------------------------------------------------------
---- BUGFIX (B17): posicao ANCORA de uma unidade peekada.
----
---- No vanilla, todo sistema resolve `return_pos or self` -- a posicao de cobertura e a
---- canonica, e o peek e so apresentacao: Cover.lua:131-132 (cobertura),
---- Unit.lua:6290 (IsInCover), Unit.lua:7584 (step_pos do ataque).
----
---- O `EnterShootingStance` do GBO3 (shooting_stance_functions.lua:13-16) faz
---- `return_pos_reserved = return_pos; return_pos = false` para a unidade FICAR peekada.
---- Com `return_pos` limpo, todos aqueles fallbacks passam a enxergar a posicao exposta
---- como a real. O GBO3 remendou um consumidor so -- o CTH dele proprio, em
---- CTH_cover_prone.lua:101, que da valor de cobertura a quem esta peekando
---- ("Peeking from Cover"). Esta funcao repoe o mesmo invariante para a IA, com a
---- MESMA expressao daquele arquivo.
----
---- Devolve `false` quando nao ha peek -- os chamadores caem no caminho vanilla intacto.
---- O ponto sempre veio de um GetPassSlab (UnitAppearance.lua:1240), entao e um slab
---- valido com Z bom; nao precisa de saneamento.
---------------------------------------------------------------------------------------------------
function RATOAI_GetPeekAnchor(unit)
    return unit and (unit.return_pos_reserved or unit.return_pos) or false
end

---------------------------------------------------------------------------------------------------
---- BUGFIX (B17): o destino escolhido e a propria posicao de cobertura de onde a unidade
---- ja esta peekando?
----
---- Ancorar so o CONTEXTO nao bastou para matar a oscilacao: o portao de movimento
---- (`AIBehavior:BeginMovement`, AIBehaviors.lua:145-148) le a unidade DIRETO --
---- `stance_pos_pack(unit, unit.stance)` -- e nao `context.unit_stance_pos`. O mesmo em
---- `EndMovement:202`. Ou seja, a ancora conserta a AVALIACAO mas nunca chega na decisao
---- de andar; para o motor, P (cobertura) e P' (peek) continuam sendo tiles diferentes.
----
---- Comparacao puramente 2D, e de proposito: medido no processo vivo que
---- `stance_pos_dist` ignora tanto a stance quanto o Z (dois packs com stance 1 vs 3, ou
---- com Z de um SlabSizeZ de diferenca, dao dist 0). Entao nao e preciso casar postura
---- nem altura -- e nao adiantaria tentar.
---------------------------------------------------------------------------------------------------
function RATOAI_IsPeekAnchorDest(unit, dest)
    if not dest then
        return false
    end
    local anchor = RATOAI_GetPeekAnchor(unit)
    if not anchor then
        return false
    end
    local ax, ay, az = anchor:xyz()
    az = az or terrain.GetHeight(ax, ay)
    return stance_pos_dist(dest, stance_pos_pack(ax, ay, az, StancesList[unit.stance])) == 0
end

function Update_AIPrecalcDamageScore(unit)
    local context = unit.ai_context or {}
    if not context.damage_score_precalced then
        AIPrecalcDamageScore(context)
        unit.ai_context = context
        return context
    end
    return nil
end

function R_IsAI(unit)
    local side = unit and unit.team and unit.team.side or ''
    if (side == "player1" or side == "player2") then
        return false
    end
    return true
end

function IsMod_loaded(mod_id) --- made by Toni
    local mod_check = table.find(ModsLoaded, 'id', mod_id) or nil -- Replace "Mod_Id" with exact case sensitive modID you're testing for.

    if mod_check then
        return true
    end
    return false
end

function RATOAI_UnpackPos(pos)
    if not pos then
        return
    end
    local ux, uy, uz, ustance_idx = stance_pos_unpack(pos)
    local new_pos = point(ux, uy, uz)
    return new_pos
end

function RATOAI_ValidatePosZ(point)
    return IsValidZ(point) and point or point:SetTerrainZ()
end

function RATOAI_GetCloseRange()
    return rat_close_range() or (((const.Weapons.PointBlankRange * 2) + (1)) * const.SlabSizeX)
end

---------------------------------------------------------------------------------------------------
---- DEBUG (D8): ISOLAR QUEM CONTA COMO AMEACA
----
---- Ferramenta de ANALISE, nao mecanismo de jogo. Com varios inimigos em campo, os efeitos da
---- AIPolicyThreatExposure (rampa de distancia, cancelamento por cobertura, postura, custo de
---- preparo) chegam ao tile todos SOMADOS -- e um numero que e a soma de quatro coisas nao deixa
---- verificar nenhuma delas. Restringindo a ameaca a UM inimigo, cada termo fica legivel.
----
---- `const.RATOAI.ThreatOnly` -- conjunto de session_id. Vazio/false = todos contam (o normal).
----     const.RATOAI.ThreatOnly = {MD = true}                        -- so o MD
----     const.RATOAI.ThreatOnly = {MD = true, Grizzly = true}        -- os dois
----     const.RATOAI.ThreatOnly = false                              -- volta ao normal
----
---- Mesmo idioma do `const.RATOAI.AimDebugUnit`, que ja filtra o log de mira por session_id.
---- O painel do mod *Rato Dev* escreve nesta tabela pelos toggles da pagina Controles -- ver o
---- contrato cross-mod no fim deste bloco.
----
---- ONDE MORDE: so nas leituras de AMEACA (AIPolicyThreatExposure e os cones de overwatch do
---- FUNCTION_DangerScan). NAO filtra `context.enemies`, de proposito -- fazer isso mudaria em quem
---- a IA atira, e ai o teste deixaria de ser sobre o scoring de posicao e passaria a ser sobre
---- outra coisa. Alvo continua sendo escolhido entre todos.
----
---- DEIXE DESLIGADO EM PARTIDA VALENDO. Ligado, a IA fica cega para a ameaca de quem esta fora da
---- lista e vai parar em lugar idiota. E para inspecionar um turno, nao para jogar.
----
---- CONTRATO CROSS-MOD: o *Rato Dev* (repo separado, `Code/RATODBG_AIDebugUI.lua`) le e escreve
---- `const.RATOAI.ThreatOnly` por session_id, e chama `IModeAIDebug:Process` para recalcular. Se o
---- formato desta tabela mudar (por handle, por exemplo), o painel de la para de funcionar em
---- silencio -- do mesmo jeito que aconteceu com o `dbg_expected` (ver CLAUDE.md).
---------------------------------------------------------------------------------------------------
const.RATOAI.ThreatOnly = false

---- `true` = este inimigo conta como ameaca. Uma leitura de tabela quando o filtro esta desligado,
---- que e o caso normal e o unico que roda em partida.
function RATOAI_ThreatCounts(enemy)
    local only = const.RATOAI.ThreatOnly
    if not only or next(only) == nil then
        return true
    end
    return only[enemy.session_id] and true or false
end

---------------------------------------------------------------------------------------------------
---- LEITURA DE VISIBILIDADE -- forma unica dos tres modos
----
---- O trio `if "self" -> enemy_visible / elseif "team" -> enemy_visible_by_team / else true` esta
---- escrito a mao em cinco lugares do mod (ThreatExposure, CustomSeekCover x2, CustomFlanking,
---- CustomWeaponRange). Esta funcao e a mesma conta num lugar so, para o codigo novo nao virar o
---- sexto. As policies existentes NAO foram convertidas -- conversao em massa de caminho quente
---- pede medicao, e nao havia motivo para arriscar junto com outra mudanca.
----
---- Valor desconhecido cai em "team", que e o default E o modo seguro. Note que isto e o OPOSTO
---- do que o `scope_ok` do FUNCTION_DangerScan faz (la, desconhecido cai no permissivo) -- e de
---- proposito: la o risco de um typo e desligar um mecanismo em silencio; aqui o risco e a IA
---- passar a enxergar o que nao devia, que e cheat. Em cada caso o fallback e o lado seguro.
----
---- LEMBRE (vale para os tres modos): as duas tabelas sao calculadas UMA vez no AICreateContext, a
---- partir da posicao ATUAL da unidade (SOURCE_AICreateContext.lua:200-201). O modo e constante do
---- TURNO -- nao varia por destino, e nenhum deles responde "o que eu enxergaria de la".
---------------------------------------------------------------------------------------------------
function RATOAI_EnemyVisible(context, enemy, mode)
    if mode == "all" then
        return true
    end
    if mode == "self" then
        return (context.enemy_visible and context.enemy_visible[enemy]) and true or false
    end
    return (context.enemy_visible_by_team and context.enemy_visible_by_team[enemy]) and true or false
end
-- GetPackedPosAndStance(unit, stance)
