const.RATOAI = const.RATOAI or {}
const.RATOAI.ReloadThresholdPct = const.RATOAI.ReloadThresholdPct or 50 -- recarrega abaixo desta fracao do carregador

---------------------------------------------------------------------------------------------------
---- BUGFIX (B43): a IA recarregava de graca.
----
---- O QUE O VANILLA FAZ. `AIReloadWeapons` (CombatAI.lua:2399) recarrega arma vazia ou abaixo de
---- metade do carregador, sem descontar AP e sem nunca perguntar se ha AP.
----
---- SAO TRES OS CALL SITES, e o terceiro e o que mais importa e o mais facil de nao ver:
----   CombatAI.lua:260  -- depois da signature action
----   CombatAI.lua:318  -- depois de cada ataque basico
----   Unit.lua:8912     -- PRIMEIRA linha de `Unit:StartAI`, antes do SelectArchetype, do behavior
----                        e do AICreateContext
---- O terceiro significa que a arma chega ao THINK ja recarregada -- e que a cobranca introduzida
---- aqui acontece no inicio do turno, mudando o AP com que TODO o scoring de destino e feito, e nao
---- so o da execucao. Ver a valvula `const.RATOAI.ReloadCostsAP` mais abaixo.
----
---- O source tem uma `local function CanReload(unit, weapon)` no topo do arquivo que checa
---- `unit:HasAP(CombatActions["Reload"]:GetAPCost(unit))`, mas ela nao e chamada em lugar nenhum
---- do jogo. Codigo morto: a checagem existe, a execucao a ignora.
----
---- POR QUE NAO SE PODE ROTEAR PELA ACTION "Reload" DO JOGADOR (tentado e revertido).
---- Parece o caminho limpo -- `AIPlayCombatAction("Reload", unit, nil, {item_id=...})` reaproveita
---- `AIStartCombatAction` -> `StartCombatAction` -> `ConsumeAP` e ganharia a checagem de AP de
---- graca. Nao funciona: `Unit:ReloadAction` (UnitActions.lua:2059) resolve a municao por
---- `GetAvailableAmmos`, que so olha o slot de inventario da unidade e o `GetSquadBag(self.Squad)`
---- (Mercenary.lua:285-317). INIMIGO NAO CARREGA MUNICAO em nenhum dos dois. `ammo` sai nil, o
---- `while ammo and ...` de `UnitInventory:ReloadWeapon` (Mercenary.lua:364) nunca roda, e a
---- chamada e um no-op silencioso -- a IA para de recarregar em vez de passar a pagar.
----
---- E por isso que o vanilla fabrica: `GetAmmosWithCaliber` devolve PRESETS, `PlaceInventoryItem`
---- cria o item, e `DoneObject` o destroi depois de usado. O ramo parcial e mais direto ainda --
---- `ammo.Amount = firearm.MagazineSize` conjura balas no carregador ja montado. Ou seja: o "de
---- graca" do vanilla nao e so o AP, e a MUNICAO. Nao existe economia de municao para a IA, e
---- introduzir uma seria outro projeto (loot, distribuicao por unidade, CUAE) -- fora do escopo
---- deste bugfix, que e sobre AP.
----
---- O QUE ESTA FUNCAO FAZ. Mantem a fabricacao vanilla intacta (byte a byte nos tres ramos) e
---- envolve cada recarga num portao de AP: custo por `CombatActions.Reload:GetAPCost`, que devolve
---- `weapon.ReloadAP` (ou -1 se emperrada, Data/CombatAction.lua:3423), e pagamento por
---- `unit:ConsumeAP(cost, "Reload")` -- a mesma chamada que o caminho do jogador faz
---- (UnitActions.lua:1988). Sem AP, a arma fica como esta e a unidade segue o turno com ela.
----
---- O planejamento correspondente esta em SOURCE_AICalcAttacksandAim.lua: e la que o carregador
---- passa a limitar a contagem de disparos e o ReloadAP sai do orcamento, para que o custo entre
---- no `dest_target_score` em vez de aparecer como surpresa na execucao.
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
---- DE ONDE SAI O CUSTO  (`const.RATOAI.ReloadAPSource`)
----
---- MEDIDO NO PROCESSO VIVO em 2026-08-27, com a modlist do autor. O mod de Workshop
---- **"Revised Mags II"** (id `URkxyfE`, so existe em .hpk) sobrescreve
---- `CombatActions.Reload.GetAPCost` -- `debug.getinfo` aponta
---- `@Mod/URkxyfE/Code/OR_ReloadCombatAction.lua:2`. O override devolve:
----     nil como args  -> -1  (para qualquer unidade)
----     QUALQUER tabela -> 0   para arma de carregador destacavel
----                     -> ReloadAP real so para algumas (Gewehr98, ferrolho)
---- Testado com a forma de args que a propria UI do jogador usa
---- (`{weapon=idx, target=classe, item_id=id}`, IModeCommonUnitControl.lua:2038): tambem 0.
----
---- E NAO E ESPECIFICO DA IA -- medido em mercs: Gewehr98 => 3000, PapovkaSKS_1 => 0, UZI => 0.
---- Ou seja o JOGADOR tambem recarrega de graca essas armas nesta modlist.
----
---- ESCOLHA DO AUTOR: **"weapon"**. O Revised Mags precifica recarga por PENTE -- carregar sem
---- pente sai caro, com pente sai barato --, e essa economia inteira nao se aplica a IA: inimigo
---- nao tem pente nem inventario. Pedir o custo aquele override e perguntar a um sistema que nao
---- tem resposta para este caso; o `0` que ele devolve nao e "de graca", e "nao sei".
----
---- `weapon.ReloadAP` e a resposta certa porque e onde o GBO3 -- que E do autor e E dependencia
---- dura -- escreve os custos: `PATCH_GBO_weapons.lua` seta a property direto por arma
---- (AA12 3000, Auto5 4000, FNMinimi 5000, ...). E como e property e nao constante, o valor lido
---- ja vem com os modificadores de componente aplicados, incluindo o `ReloadAPIncrease` que o
---- proprio GBO3 usa em `Assign_magsize.lua`. Ou seja: mexer no balanceamento do GBO3 continua
---- mexendo no custo que a IA paga, sem tocar neste arquivo.
----
----   "weapon"  (default) sempre `weapon.ReloadAP` -- o custo do GBO3, independente de modlist.
----   "action"  paridade estrita com o que `CombatActions.Reload:GetAPCost` disser, 0 inclusive.
----   "max"     o maior dos dois -- honra um custo MAIOR vindo de outro mod, nunca aceita 0.
----
---- `-1` continua significando "a acao nao se aplica" (emplacement, arma emperrada) nos tres modos
---- e nunca vira recarga.
---------------------------------------------------------------------------------------------------
if const.RATOAI.ReloadAPSource == nil then
    const.RATOAI.ReloadAPSource = "weapon"
end

---- custo de recarga desta arma, ou -1 quando a acao nao se aplica (emplacement, arma emperrada)
function RATOAI_ReloadAPCost(unit, firearm)
    ---- pcall: o GetAPCost passa por status effects e componentes de arma; um mod de terceiro que
    ---- quebre ali nao pode derrubar o turno da IA -- sem custo confiavel, nao se recarrega.
    local ok, cost = pcall(CombatActions.Reload.GetAPCost, CombatActions.Reload, unit,
                           {item_id = firearm.id})
    if not ok or type(cost) ~= "number" then
        cost = -1
    end

    ---- a acao se declarou inaplicavel: respeitado em todos os modos
    if cost < 0 then
        return -1
    end

    local modo = const.RATOAI.ReloadAPSource
    if modo == "action" then
        return cost
    end

    local nominal = firearm.ReloadAP or 0
    if modo == "weapon" then
        return nominal
    end
    return Max(cost, nominal) ---- "max"
end

---------------------------------------------------------------------------------------------------
---- VALVULA. `const.RATOAI.ReloadCostsAP = false` no console devolve o comportamento vanilla exato
---- (recarga gratis) sem descarregar o mod. Existe porque o call site que MAIS importa e o menos
---- obvio: `AIReloadWeapons` e a primeira linha de `Unit:StartAI` (Unit.lua:8912), entao esta
---- cobranca acontece no comeco do turno de cada unidade, ANTES do scoring -- e portanto muda o AP
---- com que toda a avaliacao de destino e feita, nao so a execucao.
----
---- E o primeiro interruptor a mexer se algo no comportamento da IA ficar estranho depois deste
---- bugfix: com ele em `false` o mod inteiro volta ao orcamento de AP de antes, e o que sobrar de
---- sintoma nao veio daqui.
---------------------------------------------------------------------------------------------------
if const.RATOAI.ReloadCostsAP == nil then
    const.RATOAI.ReloadCostsAP = true
end

---- ha AP para recarregar esta arma? cobra e devolve true; senao devolve false sem cobrar nada
local function RATOAI_PayReload(unit, firearm)
    if not const.RATOAI.ReloadCostsAP then
        return true ---- vanilla: recarrega sempre, de graca
    end
    local cost = RATOAI_ReloadAPCost(unit, firearm)
    if cost < 0 or not unit:HasAP(cost, "Reload") then
        return false
    end
    if cost > 0 then
        unit:ConsumeAP(cost, "Reload")
    end
    return true
end

---------------------------------------------------------------------------------------------------
---- BUGFIX (B46): a IA DESEMPERRA a arma, pagando o AP da acao `Unjam`.
----
---- POR QUE AQUI E NAO NUMA AISignatureAction. Desemperrar nao e escolha tatica que compita com
---- atacar -- e precondicao de atacar, igual a recarga. Medido em jogo: unidade com arma emperrada
---- simplesmente nao consegue atirar (`Unit:CanUseWeapon` devolve `AttackDisableReasons.
---- WeaponJammed`, Unit.lua:6641), entao nao ha turno a "escolher" -- ou destrava, ou o turno e
---- perdido. Como signature action ela ainda disputaria o slot UNICO do turno com granada/MGSetup e
---- exigiria plugar a classe em cada arquetipo pelo editor in-game.
----
---- POR QUE ESTE PASSE E O LUGAR CERTO. `AIReloadWeapons` e o passe de MANUTENCAO DE ARMA da IA, e
---- os call sites dele sao exatamente os que o unjam precisa -- em especial a primeira linha de
---- `Unit:StartAI` (Unit.lua:8912), que roda ANTES do SelectArchetype e do AICreateContext. Isso e
---- o que faz esta peca nao precisar encostar no scoring: a arma chega ao Think ja destravada e o
---- AP ja descontado, entao `AICalcAttacksAndAim` e o `dest_target_score` avaliam a situacao
---- verdadeira sozinhos. E a licao do teto por carregador revertido no B43 -- nao remodelar o
---- planejador quando da para consertar o INSUMO que ele le.
----
---- ORDEM IMPORTA: unjam antes de reload. Arma emperrada nao recarrega -- `CombatAction.Reload.
---- GetAPCost` devolve -1 quando `weapon.jammed` (Data/CombatAction.lua:3423), e o
---- `RATOAI_ReloadAPCost` repassa esse -1 como "nao se aplica". Destravando primeiro, a mesma
---- passada ainda consegue recarregar se sobrar AP.
----
---- MUTACAO DIRETA, NAO `AIPlayCombatAction`. Diferente do reload -- onde a action do jogador nao
---- servia porque depende de `GetAvailableAmmos` e inimigo nao tem municao (ver acima) -- aqui a
---- action funcionaria: `Unit:UnjamWeapon` (UnitActions.lua:2091) so chama `weapon:Unjam(self)`,
---- sem tocar em inventario. O motivo de nao usar e outro: este passe roda dentro do `Unit:StartAI`,
---- ou seja na fase de THINK, antes de qualquer unidade executar. Disparar ali uma combat action de
---- verdade (que agenda comando, toca animacao e espera com `WaitCombatActionsPostAction`) seria
---- executar no meio do planejamento coletivo. `ConsumeAP` + `weapon:Unjam(unit)` e o mesmo par que
---- a recarga ja usa, e e seguro nas duas fases.
----
---- GAP DE PARIDADE CONHECIDO: `Unit:UnjamWeapon` chama `ProvokeOpportunityAttacks` antes de
---- destravar -- o jogador pode levar tiro de oportunidade enquanto conserta. Este caminho pula
---- isso. E uma vantagem pequena e deliberada da IA, registrada aqui em vez de escondida.
----
---- O QUE `weapon:Unjam(unit)` FAZ (Weapon.lua:982) -- vale saber porque decide o balanceamento:
---- `SkillCheck(unit, "Mechanical", (100-Condition) + (100-Reliability))`, e `SkillCheck`
---- (Unit.lua:9045) e DETERMINISTICO: `threshold <= stat` passa, senao falha. Medido em campo,
---- inimigo tem `Mechanical = 0`, entao na pratica sempre falha. Mas falhar NAO trava a arma: perde
---- `Condition` (entre `JamConditionLossMin`=3 e `JamConditionLossMax`=16) e destrava assim mesmo
---- (`self.jammed = false`, Weapon.lua:1012) -- so fica quebrada de vez se a condicao chegar a 0.
---- Ou seja o inimigo desemperra estragando a arma, e arma ruim emperra mais: a espiral e o
---- balanceamento, e ela se auto-limita porque `num_safe_attacks` (=`JamFixNumSafeAttacks`, 2) e
---- concedido mesmo na falha. Subir o `Mechanical` dos arquetipos pelo editor e o dial para tornar
---- um inimigo bom nisso -- nao precisa de codigo.
---------------------------------------------------------------------------------------------------
if const.RATOAI.UnjamCostsAP == nil then
    const.RATOAI.UnjamCostsAP = true
end

function RATOAI_AIUnjamWeapons(unit)
    local firearms = select(3, unit:GetActiveWeapons("Firearm"))
    table.iappend(firearms, select(3, unit:GetActiveWeapons("HeavyWeapon")))
    for _, firearm in ipairs(firearms) do
        ---- arma quebrada nao tem conserto em combate: o proprio `Unjam` do jogo se esconde nesse
        ---- caso (`GetUIState`, Data/CombatAction.lua:2725) e o `Unit:UnjamWeapon` a pula.
        if firearm.jammed and not firearm:IsCondition("Broken") then
            ---- pcall: o GetAPCost passa por perks (MrFixit) e componentes; um mod de terceiro que
            ---- quebre ali nao pode derrubar o turno da IA. Medido: 5000 nesta modlist, e a funcao
            ---- NAO esta sequestrada por mod nenhum (`@Data/CombatAction.lua`) -- ao contrario do
            ---- `Reload`, que o "Revised Mags II" sobrescreve.
            local ok, cost = pcall(CombatActions.Unjam.GetAPCost, CombatActions.Unjam, unit, nil)
            if not ok or type(cost) ~= "number" then
                cost = -1
            end

            if not const.RATOAI.UnjamCostsAP then
                cost = 0
            end

            if cost >= 0 and unit:HasAP(cost, "Unjam") then
                if cost > 0 then
                    unit:ConsumeAP(cost, "Unjam")
                end
                firearm:Unjam(unit)
                ObjModified(unit)
            end
        end
    end
end

function AIReloadWeapons(unit)
    if IsMerc(unit) or not R_IsAI(unit) then return end
    ---- BUGFIX (B46): antes da recarga -- arma emperrada nao recarrega (ver o cabecalho acima)
    RATOAI_AIUnjamWeapons(unit)
    local firearms = select(3, unit:GetActiveWeapons("Firearm"))
    table.iappend(firearms, select(3, unit:GetActiveWeapons("HeavyWeapon")))
    for _, firearm in ipairs(firearms) do
        if not firearm.ammo then
            local ammos = unit:GetAvailableAmmos(firearm) or empty_table
            local ammo
            if #ammos > 0 then
                if RATOAI_PayReload(unit, firearm) then
                    ammo = ammos[1]
                    ammo.Amount = Max(ammo.Amount, firearm.MagazineSize)
                    unit:ReloadWeapon(firearm, ammo, "delay fx", "ai")
                    CreateFloatingText(unit, T(160472488023, "Reload"))
                    ObjModified(unit)
                end
            else
                ammos = GetAmmosWithCaliber(firearm.Caliber, "sorted")
                if #ammos > 0 and RATOAI_PayReload(unit, firearm) then
                    ammo = PlaceInventoryItem(ammos[1].id)
                    ammo.Amount = firearm.MagazineSize
                    unit:ReloadWeapon(firearm, ammo, "delay fx", "ai")
                    CreateFloatingText(unit, T(160472488023, "Reload"))
                    DoneObject(ammo)
                    ObjModified(unit)
                end
            end
        elseif firearm.ammo.Amount <
            Max(1, MulDivRound(firearm.MagazineSize, const.RATOAI.ReloadThresholdPct, 100)) then
            ---- limiar era `firearm.MagazineSize / 2` cru no vanilla. Vira MulDivRound com um
            ---- percentual configuravel -- mesma conta com 50, e sem `/` (CLAUDE.md: o operador e
            ---- divisao inteira truncada neste engine).
            if RATOAI_PayReload(unit, firearm) then
                local ammo = firearm.ammo
                ammo.Amount = firearm.MagazineSize
                unit:ReloadWeapon(firearm, ammo, "delay fx", "ai")
                CreateFloatingText(unit, T(160472488023, "Reload"))
                ObjModified(unit)
            end
        end
    end
end

