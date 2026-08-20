# Custom Seek Cover — como o `EvalDest` chega no score

Guia de leitura de `Code/AIPOLICYPOS_CustomSeekCover.lua`. Números conferidos contra
`items.lua` e contra o preset `RangeAttackTargetStanceCover` em agosto de 2026.

> **Estado deste guia.** As seções sobre `SimpleGetCover` foram atualizadas quando esse
> caminho foi removido do código (ver `PERF_CHANGES.md`, F2.3). O **resto do guia é mais
> antigo que o arquivo** e tem defasagem conhecida que ninguém revisou ainda: ele descreve
> `ScalePerDistance` com default `false` (hoje é `true`, e mudou de significado — virou
> peso no denominador), cita `ExposedAtCloseRange_Score` como propriedade viva (hoje está
> comentada), e menciona um `extra_mul` de 220 que foi aposentado. Os números de linha da
> §8 também não valem mais. Trate §2, §5 e §6 como histórico até alguém reconferir.

---

## 1. Onde a policy entra

`AIScoreDest` (`Code/SOURCE_AIScoreDest.lua:25-38`) roda todas as policies de posição de um
destino e soma:

```lua
local peval  = policy:EvalDest(context, dest, grid_voxel)
local pscore = MulDivRound(peval or 0, policy.Weight, 100)
score = score + pscore
```

Ou seja: **o que o `EvalDest` devolve ainda passa pelo `Weight`** antes de virar a linha que
você vê no painel de debug. Um `EvalDest` de 40 com `Weight 125` aparece como 50.

Se a policy for `Required` e o `pscore` sair `<= 0`, o tile inteiro é vetado (`return 0`), não
importa quão bom ele seja nas outras policies. Só uma das 21 instâncias usa isso.

A policy declara `end_of_turn = true` **e** `optimal_location = true` (linhas 7-8), então ela
roda nas duas passadas — pode aparecer duas vezes no mesmo think, com pesos diferentes, e as
duas linhas compartilham o mesmo rótulo "Custom Seek Cover".

---

## 2. A fórmula, em uma linha

Com a configuração que existia no `items.lua` quando este guia foi escrito, o que rodava
era isto e só isto (hoje `ScalePerDistance` vem ligado por default e o peso entra também
no denominador — a fórmula abaixo é o caso particular de todos os pesos iguais):

```
EvalDest = ( Σ cover_score(inimigo)  para cada inimigo visível ) / (nº de inimigos visíveis)
```

Uma **média**, não uma soma. Isso é deliberado — é a regra que o `AI_SYSTEM_GUIDE.md` chama de
"média sobre inimigos, não soma", pra policy não explodir de escala conforme o número de
inimigos em campo. Mas tem uma consequência forte, que está na §7.

---

## 3. `EvalDest` passo a passo (linha 63)

### 3.1 Filtro de visibilidade (linhas 88-95)

```lua
if self.visibility_mode == "self" then
    visible = context.enemy_visible[enemy]
elseif self.visibility_mode == "team" then
    visible = context.enemy_visible_by_team[enemy]
end
```

Default é `"team"` — e nenhuma instância muda isso. Então **é a visão do time inteiro** que
conta: a unidade busca cobertura contra inimigos que ela pessoalmente não está vendo, desde que
algum aliado veja. Com `"all"`, `visible` fica `true` pra todo mundo (onisciente).

### 3.2 O loop (linhas 96-117)

Para cada inimigo visível:

- `table_num` incrementa — **este é o denominador**, e ele incrementa para todo inimigo visível,
  independente de esse inimigo ter contribuído com alguma coisa;
- `cover_score` sai do `GetCoverScore` (§4);
- soma em `score`.

### 3.3 O ramo `last_known_enemy_pos` (linhas 119-132)

```lua
if self.ForceCheckLastEnemyPos or table_num < 1 then
```

Dispara quando **não havia nenhum inimigo visível** (ou sempre, se `ForceCheckLastEnemyPos`
estiver ligado — nenhuma instância liga). Aí ele mede cobertura contra a última posição
conhecida de inimigo, usando o **outro** caminho de pontuação:

```lua
local cover = GetCoverFrom(dest, stance_pos_pack(last_pos))
local cover_score = self.CoverScores[cover] or 0
```

`CoverScores` (linhas 195-200) é uma tabela discreta:

| classe | score |
|---|---|
| `CoverPass` | 0 |
| `CoverNone` | 0 |
| `CoverLow` | 50 |
| `CoverHigh` | 100 |

Isso incrementa `table_num` também, e entra na mesma média.

**Cuidado:** este ramo produz valores numa escala diferente do loop principal (0/50/100 discreto
contra um contínuo derivado de CTH), e os dois caem no mesmo somatório. Enquanto os dois não
coexistem — e hoje não coexistem, porque este ramo só roda quando o loop principal não rodou —
não dá problema. Se você ligar `ForceCheckLastEnemyPos` em algum archetype, passam a coexistir.

### 3.4 O retorno (linha 145)

```lua
return MulDivRound(score / Max(1, table_num), extra_mul, 100)
```

`extra_mul` é `220` se `ScalePerDistance` estiver ligado, senão `100` (linha 76). Como nenhuma
instância liga, na prática é sempre `× 100%`, ou seja, a média crua.

---

## 4. `GetCoverScore` — o cálculo de verdade (linha 202)

É aqui que 100% do score realmente nasce. Cinco saídas possíveis, e três delas devolvem `0` —
o que faz tiles muito diferentes parecerem idênticos no debug.

### 4.1 Os ramos

| # | condição | resultado |
|---|---|---|
| 1 | inimigo `IsDowned()`, ou posição inválida | `0` |
| 2 | arma do inimigo **não** é `Firearm` | `BaseScore` cheio (100) |
| 3 | `dist <= weapon.WeaponRange * SlabSizeX` e há cobertura útil | `BaseScore × ratio` |
| 4 | mesma coisa, mas a cobertura é fraca demais (`use == false`) | `0` |
| 5 | `dist > weapon.WeaponRange * SlabSizeX` | `0` |

Repare no ramo 2: contra um inimigo de faca, **qualquer** tile vale nota máxima. E no ramo 5: o
alcance usado é o da **arma do inimigo**, não da sua — a pergunta é "esse cara consegue me
acertar daqui?".

### 4.2 O ratio de cobertura (linhas 226-231)

```lua
local use, value = RATOAI_CoverCTH(att_pos, target_pos)
if use then
    local ratio = Clamp(MulDivRound(value, 100, cover_max_malus), 0, 100)
    score = MulDivRound(self.BaseScore, ratio, 100)
end
```

**O detalhe que quebra quem mexe aqui sem olhar: esses valores são negativos.**

`cover_max_malus` é `ResolveValue("Cover")` do preset `RangeAttackTargetStanceCover` — é um
*malus* de chance de acerto, e vale **-35** no seu Balance Overhaul 4
(`CTH_cover_prone.lua:86`). O `value` que sai do `RATOAI_CoverCTH` também é negativo.

Então `MulDivRound(value, 100, cover_max_malus)` é **negativo ÷ negativo = ratio positivo**, em
percentual de "cobertura cheia". Cobertura total → ratio 100 → score = `BaseScore`.

> Se você algum dia "proteger" essa divisão com um `Max(1, cover_max_malus)`, o denominador
> vira 1, o ratio vira um número muito negativo, o `Clamp` esmaga pra 0, e **todo tile passa a
> valer 0 ou negativo**. É um jeito garantido de quebrar a policy inteira sem erro no log.

### 4.3 `RATOAI_CoverCTH` (linha 249)

É uma cópia do ramo de cobertura do `RangeAttackTargetStanceCover:CalcValue` do jogo (compare
com `CTH_cover_prone.lua:79-95`), sem a parte de tempestade de areia — está comentada nas
linhas 256-259.

```lua
local cover, any, coverage = GetCoverPercentage(target_pos, attacker_pos, "Crouch")
local value = InterpolateCoverEffect(coverage, full_value, exposed_value)
if value < exposed_value then
    return true, value
end
return false, 0
```

- `coverage` é a % de cobertura geométrica entre as duas posições;
- `InterpolateCoverEffect` interpola entre `exposed_value` (cobertura baixa) e `full_value`
  (cobertura alta) — ambos negativos;
- `value < exposed_value` significa "mais negativo que o piso de exposto", ou seja, **tem
  cobertura de verdade**. Se não passar, devolve `false, 0` e o tile cai no ramo 4.

O `"Crouch"` ali é **fixo** — ver §7.

### 4.4 A penalidade de exposição (linhas 235-244)

```lua
if self.ExposedAtCloseRange_Score ~= 0 and score <= 0 and dist then
    if     dist <= pb_range     then score = self.ExposedAtCloseRange_Score
    elseif dist <= pb_range * 2 then score = ExposedAtCloseRange_Score × 75%
    elseif dist <= pb_range * 3 then score = ExposedAtCloseRange_Score × 40%
    end
end
```

`pb_range = const.Weapons.PointBlankRange * const.SlabSizeX` (linha 50).

Ela só dispara quando o score **já era 0 ou menos** — isto é, ela transforma "não me protege"
em "me expõe ativamente", e só perto. É o que dá o gradiente negativo que você vê perto dos
inimigos.

Três coisas sobre ela:

- `dist` é sempre um número, então o `and dist` da condição nunca reprova nada — é decorativo;
- ela pega os ramos 1, 4 **e** 5. Um inimigo **abatido** a dois tiles de distância cai no ramo 1
  (score 0) e portanto gera penalidade cheia, como se estivesse te mirando;
- ela **substitui** o score, não soma.

---

## 5. `SimpleGetCover` — removido

Existiu um segundo caminho de pontuação, ligado pela property `SimpleGetCover`: em vez do
CTH real, ele lia a tabela discreta `CoverScores` via `GetCoverFrom`. Estava dormente (0
de 21 instâncias o ligavam) e o corpo do `SimpleGetCoverScore` estava inteiramente
comentado — a função era a identidade.

Foi removido depois que a medição no processo vivo mostrou que ele não era sequer o
caminho barato que aparentava ser:

| chamada | µs/chamada |
|---|---|
| `PosGetCoverPercentageFrom` (o caminho "caro", via `RATOAI_CoverCTH`) | 0,8 |
| `GetCoverFrom` (o caminho "simples") | **1,8** |

O modo simples custava o dobro *e* era menos preciso. Restou só o uso de `GetCoverFrom` no
ramo `last_known_enemy_pos` da §3.3, que agora indexa `CoverScores` direto.

Detalhe que sobrevive como aviso: `ScalePerDistance` já foi lido em dois lugares com
significados diferentes. Hoje tem um significado só — peso na média ponderada, no
numerador **e** no denominador.

---

## 6. Como está configurada hoje

21 instâncias no `items.lua`. Propriedades efetivamente usadas:

| propriedade | default | quantas instâncias mudam |
|---|---|---|
| `Weight` | 100 | 13 — valores de 20 a 300 |
| `ExposedAtCloseRange_Score` | -100 | 11 — valores 0, -10, -40, -50, -200 |
| `Required` | false | 1 |
| `BaseScore` | 100 | **0** |
| `visibility_mode` | "team" | **0** |
| `ScalePerDistance` | false | **0** |
| `ForceCheckLastEnemyPos` | false | **0** |

Seis instâncias são `PlaceObj('AIPolicyCustomSeekCover', nil)` — tudo default.

**Consequência:** o caminho real é sempre `GetCoverScore` → `RATOAI_CoverCTH`, com
`BaseScore` 100 e visibilidade de time. O ramo `last_known_enemy_pos` da §3.3 é o único
outro caminho vivo.

---

## 7. Consequências práticas

Coisas que o comportamento em jogo mostra e que saem direto da matemática acima.

### O denominador dilui

`table_num` conta todo inimigo visível, inclusive os que devolveram 0 por estarem fora de
alcance. Um tile com cobertura perfeita contra o único inimigo que te alcança, com mais 3
inimigos longe visíveis, pontua `100 / 4 = 25` — o mesmo que um tile com cobertura mediana
contra todos. Você é penalizado por ter inimigos distantes no campo de visão do time.

É a explicação mais comum pra "por que esse tile ótimo pontuou tão baixo".

### A stance do destino é ignorada

`EvalDest` desempacota `ustance_idx` na linha 66 e **nunca usa**. E o `GetCoverPercentage` da
linha 254 é chamado com `"Crouch"` fixo. A IA avalia o mesmo voxel em 2-3 stances como destinos
distintos — e todos recebem cobertura idêntica.

Ou seja: pra esta policy, "deitado atrás do muro baixo" e "de pé atrás do muro baixo" são a
mesma coisa. Quem desempata stance é outra policy (`Attack_StanceAP`, `MGSetupAP`), não esta.

### Inimigos abatidos empurram a IA pra longe

Ramo 1 → score 0 → penalidade de exposição a curta distância. A unidade evita tiles perto de
corpos caídos como se fossem ameaças. `GetEnemies()` não filtra downed — o próprio check da
linha 213 mostra que eles chegam aqui.

### Escala

Com `BaseScore` 100 e média, o `EvalDest` vive em `[ExposedAtCloseRange_Score, 100]`. Depois do
`Weight`, uma instância com `Weight 300` e `ExposedAtCloseRange_Score -200` pode cuspir -600 num
tile — o suficiente pra dominar sozinha a soma do `AIScoreDest`. Vale conferir contra o
`WEIGHTS_AUDIT.md` antes de mexer em peso aqui.

---

## 8. Mapa rápido do arquivo

| linhas | o quê |
|---|---|
| 1-44 | `DefineClass` e propriedades editáveis |
| 46-57 | constantes locais (`pb_range`, multiplicadores de penalidade, `extra_score_arg_mul`) |
| 63-146 | `EvalDest` — loop, ramo `last_pos`, média |
| — | ~~`SimpleGetCoverScore`~~ — removido, ver §5 |
| 195-200 | tabela `CoverScores` |
| 202-247 | `GetCoverScore` — o caminho que roda de verdade |
| 249-268 | `RATOAI_CoverCTH` — cópia do CalcValue do jogo |
| 269-fim | versão antiga do `EvalDest`, comentada |
