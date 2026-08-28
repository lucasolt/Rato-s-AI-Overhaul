const.RATOAI = const.RATOAI or {}

---------------------------------------------------------------------------------------------------
---- BUGFIX (B46): a IA era BLINDADA contra emperramento e contra desgaste de arma.
----
---- No vanilla, `FirearmBase:ReliabilityCheck` (Weapon.lua:934) -- unico lugar que rola jam E que
---- degrada `Condition` -- tem o corpo inteiro dentro de `attacker.team.control ~= "AI"`. Nao e
---- ausencia de mecanismo, e exclusao explicita: arma de inimigo nunca emperra e nunca se gasta.
---- Mesmo padrao do BUGFIX B43 (recarga gratis), e a mesma razao para remover: a proposta declarada
---- do mod e por a IA sob as mesmas regras do jogador.
----
---- POR QUE ESTE ARQUIVO E UMA LINHA E NAO UMA COPIA DA FUNCAO.
---- Uma versao anterior daqui sobrescrevia a `ReliabilityCheck` inteira. Isso funcionava enquanto
---- ninguem mais mexesse nela -- mas a FORMULA de jam e de desgaste e balanceamento que afeta o
---- JOGADOR, e portanto escopo do GBO3, nao deste mod. Com os dois sobrescrevendo a mesma funcao, o
---- RATOAI (que carrega depois, por ser dependente) venceria e apagaria a formula do GBO3 EM
---- SILENCIO -- o tipo de colisao que so aparece meses depois como "o balanceamento nao esta
---- valendo".
----
---- Entao o GBO3 passou a ser o dono da funcao (`SOURCE_ReliabilityAndJam.lua`) e a expor o portao
---- como constante. Aqui sobra so a decisao que E deste mod: ligar o portao para a IA.
---- Ver `__JamParams.lua` no GBO3 para a formula e os demais parametros.
----
---- EFEITO COLATERAL DE LIGAR: o portao do vanilla governa jam E perda de `Condition` ao mesmo
---- tempo -- sao o mesmo `if`. Entao arma saqueada de inimigo que lutou muito passa a vir em
---- condicao pior. E mudanca de economia de loot para o jogador, nao so de dificuldade.
----
---- COMO DESLIGAR:
----   sessao viva  -> `const.Weapons.WearAppliesToAI = false` no console (efeito imediato)
----   permanente   -> `const.RATOAI.AIWeaponJam = false` antes deste arquivo carregar, ou remover
----                   a entrada dele do `metadata.lua`
---------------------------------------------------------------------------------------------------
if const.RATOAI.AIWeaponJam == nil then
    const.RATOAI.AIWeaponJam = true
end

---- Atribuicao incondicional, e nao um `== nil`: o GBO3 ja definiu `WearAppliesToAI = false` como
---- default dele (carrega antes, por ser dependencia), entao um guard de nil aqui nunca dispararia.
const.Weapons.WearAppliesToAI = const.RATOAI.AIWeaponJam and true or false
