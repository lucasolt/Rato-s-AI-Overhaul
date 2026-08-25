# Orçamento de policies — o que esperar dos pesos, matematicamente

*2026-08-24. Base: `items.lua` como está hoje (v1.12+, branch `claude-performance-refactor`),*
*com `AIPolicyThreatExposure.Penalty` no default atual de `−100`.*
*Companheiro de `WEIGHTS_AUDIT.md` (que é sobre **bugs** de magnitude) e do `AI_SYSTEM_GUIDE.md`
(que é sobre o **pipeline**). Este aqui é sobre **como os pesos de um arquétipo conversam entre
si**, e por que a resposta muda quando o número de policies muda.*

> ⚠ As tabelas 13.1 e 13.4 do `AI_SYSTEM_GUIDE.md` estão **desatualizadas**: descrevem um
> `items.lua` anterior (Soldier com `CustomSeekCover 150`, `CustomFlanking` somando por inimigo,
> bandas de alcance binárias). Os números daqui foram extraídos do `items.lua` atual.

---

## 1. O modelo, numa linha

Todo score de posição, em qualquer behavior, é **uma soma linear** (`SOURCE_AIScoreDest.lua`):

```
S(tile) =  base
         + SOMA_i  W_i/100 x EvalDest_i(tile)
```

onde `base` é:

| contexto | `base` |
|---|---|
| **OptLoc** (`AIFindOptimalLocation`) | `0` |
| **End-Turn** (`AIScoreReachableVoxels`) | `dist_score` em `[0, OptLocWeight]` — gradiente de aproximação ao `best_dest` |
| qualquer um, tile em fogo/gás | `−200` (`const.AIAvoidFireWeigth`), **somado** |

Não há multiplicação entre policies, não há normalização final, não há teto. O que existe são
**três âncoras absolutas** e um filtro relativo. Tudo o que confunde na hora de tunar sai daí.

---

## 2. As três âncoras absolutas (e a invariância que elas quebram)

**Fato central:** multiplicar **todos** os `Weight` de uma lista por `k` não muda decisão nenhuma
— exceto em relação às três âncoras. Score é soma linear, o corte de finalistas é multiplicativo
(80% do melhor) e a roleta é proporcional; tudo isso é invariante a escala.

Logo, "peso alto" e "peso baixo" **não significam nada sozinhos**. Só significam algo contra:

### Âncora 1 — o zero (a mais importante, e a menos óbvia)

- **End-Turn**: a roleta pesa cada finalista por `Max(0, score)`
  (`SOURCE_AIScoreReachableVoxels.lua`). Tile com total ≤ 0 tem **probabilidade zero** de ser
  sorteado.
- **OptLoc**: `if score > 0 then` (`CombatAI.lua:1298`). Tile com total ≤ 0 **nem entra na lista
  de candidatos**.
- **Degeneração**: se *todos* os finalistas ficarem ≤ 0, `total == 0`, a roleta não roda e o
  fallback pega o **argmax**. Ou seja: a IA deixa de ser aleatória e vira determinística, sem
  aviso. O `AIDecisionThreshold` some junto.
- **Assimetria do corte com score negativo**: o filtro é `0,8 x melhor <= score`. Com o melhor
  **positivo**, a janela é `[0,8·melhor, melhor]` — 20% de largura. Com o melhor **negativo**,
  `0,8 x melhor` fica *acima* do melhor: um tile precisa estar **20% mais perto do zero** que o
  melhor até agora só para ser considerado. A janela de empate encolhe drasticamente.

> **Regra 1.** O zero não é escala, é fronteira. O que você tuna quando mexe num peso negativo
> não é "o quanto isso pesa" — é **quantos tiles do mapa deixam de existir**.

### Âncora 2 — `OptLocWeight` (a unidade de medida do End-Turn)

`dist_score` vai de `0` (o destino mais longe do `best_dest`) a `OptLocWeight` (em cima dele) e é
**somado** ao score das policies. Ele é o único termo do End-Turn que não passa por `Weight`.

Por isso: **`OptLocWeight` é a régua**. A pergunta "meu `DealDamage 200` é alto?" só tem resposta
depois de "alto comparado a quê?", e a resposta é: comparado ao `OptLocWeight` do behavior.

```
OptLocW / (influência positiva total)  =  quanto do End-Turn é "andar na direção certa"
                                          em vez de "escolher bem o tile"
```

### Âncora 3 — os `−200` do fogo/gás

Constante absoluta. Num arquétipo cujo orçamento positivo total é 80 (Medic), `−200` é veto
absoluto. Num cujo orçamento é 700 (Beserk, TheMajor), `−200` é 29% — a unidade **pode** escolher
parar dentro do fogo se o resto compensar.

---

## 3. Amplitude ≠ peso: o fator de discriminação `D`

O `Weight` diz qual seria a contribuição se o `EvalDest` fosse de 0 a 100. Quase nenhuma policy
percorre 0 a 100 de verdade. O que decide é a **amplitude que a policy realmente varre entre os
tiles que competem**:

```
influência_i  =  W_i/100  x  (Eval_max_realista − Eval_min_realista)
              =  W_i x D_i
```

`D` é a fração da faixa nominal que a policy usa de fato. **É `influência`, não `Weight`, que
você deve comparar entre policies.**

### 3.1 `AIPolicyDealDamage` — o soft cap tem um teto matemático

Modo `soft` (o **default** hoje, `PATCH_AppendClass_source_classes.lua:78`):

```
score = 100 x h / (h + K)          h = hit_score = SOMA de CTH sobre os disparos
```

Sobre uma faixa realista `h` em `[h1, h2]` a amplitude é

```
D_soft(K) = (h2 − h1)·K / ((h1+K)(h2+K))
```

que é **máxima em `K = raiz(h1·h2)`**, valendo

```
D_max = (raiz(h2/h1) − 1) / (raiz(h2/h1) + 1)
```

⚠ **A faixa de `h` não é a mesma para todo arquétipo, e é ela que manda.** Desde o BUGFIX B21 a
rajada soma CTH **bala a bala** (`RATOAI_BurstHits`), então:

| unidade | `h` típico | razão `h2/h1` | `D_max` | `K` ótimo |
|---|---|---|---|---|
| tiro único aimed (Sniper) | 40 – 250 | 6x | 0,42 | ~100 |
| rajada (Soldier, HeavyGunner) | 50 – 700 | 14x | **0,58** | ~190 |
| a faixa `[100,300]` usada nas tabelas deste doc | 3x | | 0,27 | ~173 |

A tabela abaixo (e o `D = 0,25` que aparece na §6) foi calculada sobre `[100, 300]` — é a faixa
**conservadora**, boa para tiro único de curto alcance. Para o Soldier de rajada o `D` real com
`SoftK = 100` é **0,54**, não 0,25: a influência dele está subestimada em ~2x nas tabelas da §6.
Trate a §6 como piso, não como medida.

Com a faixa conservadora — 1 a 3 acertos esperados, `h` em `[100, 300]`:

| `SoftK` | h=100 | h=200 | h=300 | **D** |
|---|---|---|---|---|
| 50 (Sniper) | 67 | 80 | 86 | **0,19** |
| 100 (default; Soldier, Skirmisher, Brute…) | 50 | 67 | 75 | **0,25** |
| **160 (HeavyGunner)** | 38 | 56 | 65 | **0,268** ← ótimo |
| 173 (= raiz(100·300)) | 37 | 54 | 63 | **0,268** |
| 400 | 20 | 33 | 43 | 0,23 |

> **Regra 2.** Com faixa de 3x em `h`, o modo `soft` **não consegue** discriminar mais que **26,8%
> do seu `Weight` nominal**, escolha o `K` que escolher. Um `DealDamage Weight = 200` em `soft`
> compra no máximo **~54 pontos de decisão**. Tudo acima disso é offset constante — sobe o score
> de todo tile igual, o que só mexe na âncora do zero e na largura da banda de 80%.

Comparação entre modos, mesma faixa `h` em `[100,300]`:

| modo | fórmula | `D` | observação |
|---|---|---|---|
| `soft` | `100h/(h+K)` | **<= 0,27** na faixa 3x; **0,58** na faixa 14x | nunca satura; `K` é botão de **forma**, ver abaixo |
| `cap` | `min(100, 100h/MaxHits)` | 0,5 com `MaxHits=200` | discrimina o dobro, e depois fica **mudo** acima do teto |
| `relative` | `100h/(disparos x Mark)` | ~0,5 | linear até saturar — ⚠ **proibido para arma automática**, ver abaixo |
| `tokill` | `100h/(HP·100/dano)` | ~0,4–0,6 | teto = derrubar; varia com o alvo sorteado |

> 🔴 **`relative` satura em arma automática.** `RATOAI_SkillRef` monta o referencial como
> `context.max_attacks x Marksmanship`, e `max_attacks` conta **ataques, não balas** —
> `context.burst_shots` é campo separado e não entra ali. Uma rajada de 6 rende `h ≈ 350` num
> ataque só, contra um `ref` de ~140–280. Resultado: a policy **pina em 100 exatamente na faixa
> de rajada a curta distância**, que é justamente onde ela deveria discriminar mais. Use
> `relative` só em unidade de tiro único, ou corrija o `ref` multiplicando por
> `context.burst_shots`.

**`SoftK` é forma, não só amplitude.** A curva é côncava, então `K` decide *onde* a sensibilidade
mora:

| `K` | perfil | quem quer isso |
|---|---|---|
| baixo (40–70) | **front-loaded**: o 1º acerto esperado já compra ~2/3 do teto; do 2º em diante quase não muda. Na prática é "ter tiro" como degrau + gradiente fino. | **Sniper** — "acertar um tiro é o que importa" |
| alto (150–250) | **sensível a volume**: continua pagando o 4º, 5º, 6º acerto. | **Soldier / MG de rajada** — "de perto eu despejo e preciso saber disso" |

Nenhum `K` conserta a concavidade: mesmo em `K = 190`, ir de `h = 300` para `h = 700` (mais que
dobrar os acertos) rende só 62 → 79 de eval. **Teto do topo comprimido é o que "soft cap"
significa.** Se o topo tem que pesar mais que isso, o lugar de expressar isso é uma segunda
instância em `tokill`, não um `K` maior.

> **Regra 3.** Se você quer que "de onde eu atiro" pese de verdade, o modo `soft` é o mais caro
> possível: precisa de ~2x o `Weight` de `relative` para a mesma influência. Use `soft` quando a
> intenção for **um piso suave e pouco decisivo**; use `relative` quando o tiro deve mandar.

### 3.2 `AIPolicyThreatExposure` — o oposto: varre quase tudo

```
eval = Penalty x min(threat, saturação) / saturação        saturação = 100 x 3 = 300
```

`Penalty` é `−100` (default de `AIPOLICYPOS_ThreatExposure.lua`; **nenhuma instância do
`items.lua` sobrescreve**, então vale para todos os arquétipos).

`Penalty` escala o sinal inteiro de forma linear e não mexe em onde ele cruza o zero — ele é
puramente um multiplicador. O que decide a amplitude é a faixa de `threat` que os tiles em
disputa realmente cobrem:

```
Ct = (threat_ruim − threat_bom) / saturação
influência_threat = W x (|Penalty|/100) x Ct
```

**Premissa de modelagem (a maior deste documento — meça a sua em §7.4):** 2–4 inimigos visíveis;
tile bom = coberto a média distância (`threat ≈ 30`); tile ruim = exposto a curta distância
(`threat ≈ 250`, perto da saturação 300). Daí `Ct ≈ 0,73`.

Com `Penalty = −100`: `threat 30 → eval −10`; `threat 250 → eval −83`. Amplitude ≈ 73 dos 100
possíveis:

```
influência_threat ≈ 0,73 x W
```

> **Regra 4.** À mesma nominal, **a Threat Exposure decide ~3x mais que um DealDamage `soft`**
> (0,73·W contra 0,25·W). Escrever `DealDamage 200` e `ThreatExposure 125` **não** é "o dano pesa
> mais": é o dano pesando 50 contra a ameaça pesando 91.
>
> Sensibilidade ao `Penalty`, já que é o botão mais direto de agressividade:
> `−100 → 0,73·W` · `−150 → 1,10·W` · `−200 → 1,46·W`. Dobrar o `Penalty` é idêntico a dobrar o
> `Weight` — use um **ou** o outro, nunca os dois, senão a leitura da tabela de fatias mente.

> 📌 **Correção sobre a primeira versão deste arquivo.** A fórmula estava escrita como
> `W x (|P|/100) x 0,95` com `P = −150`, o que contava o fator duas vezes: `0,95` já era a
> amplitude em pontos de eval, não uma fração de `|P|`. A influência da ThreatExposure estava
> **~1,5x inflada** e, junto com a troca de `Penalty` para `−100`, os `A` da §6.2 eram cerca de
> **metade** do que deveriam. As tabelas abaixo já estão com a conta certa.

### 3.3 Tabela de `D` das demais policies

Estimativas de modelagem (§7.4 mostra como medir as suas de verdade):

| Policy | faixa `EvalDest` | `D` estimado | forma |
|---|---|---|---|
| `AIPolicyLosToEnemy` | 0 / 100 | **1,0** | interruptor |
| `AIPolicyWeaponRange` (vanilla) | 0 / 100 (5 se caído) | **1,0** | interruptor |
| `AIPolicyEvadeEnemies` | 0 / 100 | **1,0** | interruptor |
| `AIPolicyIndoorsOutdoors` | 0 / 100 | **1,0** | interruptor |
| `AIPolicyTryNotToBeFlanked` | −100 / 0 | **1,0** | interruptor (negativo) |
| `AIPolicyThreatExposure` | `Penalty` … 0 | **0,73** (P=−100) | rampa saturada |
| `AIPolicyCustomWeaponRange` / `CustomGrenadeRange` | 0 … 100 | 0,8 | tenda com falloff |
| `AIPolicyEncircleEnemy` | 0 … 100 | 0,8 | tenda (0 no lado errado) |
| `AIPolicyMGSetupPosScore` | 0 … `MaxScore` | 0,8 | rampa |
| `AIPolicyTakeCover` / `CustomSeekCover` | 0 … 100 | 0,6 | média sobre inimigos |
| `AIPolicyCustomFlanking` | 0 … 100 (−100 com `PenalizeWorse`) | 0,5 | delta de cobertura |
| `AIPolicyStayNearAllies` | 0 … 100 | 0,5 | rampa |
| `AIPolicyHighGround` (mod) | `−DownhillMax` … 100 | **0,25** | condicional: 0 em mapa plano |
| `AIPolicyDealDamage` | 0 … 100 | 0,19 – 0,5 | ver §3.1 |
| `AIPolicyProximity` | **tiles crus** (0…~60) | — | fora de escala |
| `AIPolicyLastEnemyPos` | 0 … `Weight` | — | **peso ao quadrado** |
| `AIPolicyHealingRange` | 0 … ~1800 | — | fora de escala |

Duas observações que valem por si:

- **Interruptor não é peso.** `LosToEnemy 200` não é "LOS vale duas vezes mais"; é "todo tile sem
  LOS perde 200 pontos de uma vez". Interruptores criam **platôs** — dentro de cada lado do
  degrau eles não discriminam nada, e é o resto da lista que decide. Um arquétipo feito só de
  interruptores (Rocketeer OptLoc, Brute OptLoc, TheMajor OptLoc) tem um número **pequeno** de
  classes de tile e depois escolhe por sorteio dentro da classe.
- **`AIPolicyHighGround` tem peso alto e influência baixa** — não porque a policy seja ruim, mas
  porque em mapa plano ela devolve 0 em todo tile. O `Weight 150` do Sniper só aparece nos poucos
  mapas verticais. Ela é uma **opção**, não um pilar.

---

## 4. A resposta para "muda entre arquétipos porque o número de policies é diferente"

Não muda. O número de policies é irrelevante — o que importa é a **fatia** de cada uma:

```
fatia_i = influência_i / SOMA_j |influência_j|
```

`fatia` é adimensional, não depende de escala global e não depende de quantas policies existem.
Duas policies com fatia 50%/50% se comportam igual a quatro com 25% cada, se as quatro medirem a
mesma coisa. **Três policies com fatias 60/30/10 são um arquétipo com uma prioridade; seis com
17% cada são um arquétipo sem prioridade nenhuma.**

Além das fatias, um arquétipo é descrito por **dois escalares**:

```
A          = SOMA influência positiva / SOMA influência negativa    (agressividade)
R_optloc   = OptLocWeight / SOMA influência positiva                (obediência ao plano)
```

- `A > 1` — a unidade aceita trocar exposição por tiro. `A < 1` — ela recua na dúvida.
  `A = infinito` (sem policy negativa) — ela é cega para o risco no fim do turno.
- `R_optloc > 1` — o gradiente "ande até o `best_dest`" vale mais que todas as policies de fim de
  turno somadas: as `EndTurnPolicies` viram **veto de segurança**, não escolha de posição. Quem
  decide o comportamento é a lista de `OptLocPolicies`.
- `R_optloc < 0,5` — a unidade "esquece" o `best_dest` se achar um tile bom no caminho.

> **Regra 5.** Compare arquétipos por `(fatias, A, R_optloc)` — nunca por `Weight`. Só esses três
> são invariantes a escala e a contagem de policies.

---

## 5. Onde a escala importa e onde não importa

| lista | escala global importa? | por quê |
|---|---|---|
| **`OptLocPolicies`** | **quase não** | só contra os `−200` do fogo/gás e contra o portão `score > 0`. Fora isso é puro ranking. Dobrar todos os pesos do OptLoc de um arquétipo é, na prática, no-op. |
| **`EndTurnPolicies`** | **sim** | `OptLocWeight` é somado sem passar por `Weight`, e o zero é fronteira de sorteio. |

Corolário prático: **arquétipos com uma policy só de OptLoc (`Scout_LastLocation` com
`LastEnemyPos 500`, `Panicked` com `AIRetreatPolicy`) têm peso irrelevante por construção.** O
`500` do Scout (que vira 2500 pelo peso ao quadrado, §6.3) não faz nada: com uma policy só,
qualquer valor > 0 dá o mesmo ranking. Não é um bug com sintoma — é ruído. Mesma coisa para o
`HealingRange 300` do Medic curandeiro: ele é a única policy da lista dele.

---

## 6. Diagnóstico do `items.lua` atual

### 6.1 OptLoc — fatias (aqui só o ranking importa)

| Arquétipo | fatias (influência) | leitura |
|---|---|---|
| **Soldier** | CustomWeaponRange 32% · Encircle 29% · LOS 18% · TakeCover 16% · HighGround 5% | plano: "chegar na banda de alcance, pelo flanco". Sem prioridade dominante — decisão espalhada. |
| **RATOAI_Sniper** | CustomWeaponRange 41% · LOS 25% · HighGround 19% · TakeCover 15% | a banda é 20–40% do alcance (7–14 tiles com SVD 36) — coerente com `GetRangeAccuracy` cheia até `WeaponRange/2`. |
| **HeavyGunner** | CustomWeaponRange 53% · MGSetup 36% · Indoors 11% | duas policies mandam; sem policy de cobertura, correto para quem deita. |
| **Skirmisher** | Encircle 38% · CWR(banda longa) 25% · LOS 16% · CWR(4–10 abs) 12% · TakeCover 9% | envolvimento como pilar. |
| **RATOAI_Demolition** | CWR 33% · LOS 21% · Encircle 17% · TakeCover 12% · Indoors 14% · HighGround 3% | seis policies, nenhuma acima de 33%: **arquétipo sem prioridade**. |
| **RATOAI_Rocketeer** | LOS 43% · Indoors 33% · WeaponRange 22% · HighGround 2% | **só interruptores** — o mapa vira 8 classes de tile e o resto é sorteio. |
| **Brute** | WeaponRange(melee) 53% · WeaponRange(1–14) 26% · Encircle 21% | idem, tudo interruptor. |
| **Medic** | TakeCover 38% · LOS 31% · StayNearAllies 31% | equilibrado de propósito. |
| **TheMajor** / **Beserk** | WeaponRange 85% / 86% | policy única na prática. |

### 6.2 End-Turn — influência medida (h em [100,300], 2–4 inimigos visíveis)

Todas as instâncias de `ThreatExposure` usam o `Penalty` default `−100` → influência `0,73 × W`.
A coluna `A alvo` vem da tabela de papéis da §7.1.

| Arquétipo / behavior | positivo | negativo | **A** | `A` alvo | `OptLocW` | **R_optloc** |
|---|---|---|---|---|---|---|
| **Soldier** StandardAI | 65 (DD 50 + tokill 15) | 91 (Threat 125) | **0,71** | 0,9–1,3 ⚠ | 100 | **1,54** |
| **RATOAI_Sniper** StandardAI | 49 | 73 (Threat 100) | **0,67** | 0,6–1,0 ✔ | 100 | **2,04** |
| **Skirmisher** StandardAI | 80 | 58 (Threat 80) | **1,38** | 1,2–2,0 ✔ | 100 | **1,25** |
| **Skirmisher** Flanking | 150 (Flank 100 + DD 50) | 73 | 2,05 | — | 20 | 0,13 |
| **Brute** StandardAI | 75 | 73 | **1,03** | 1,2–2,0 ⚠ | 100 | **1,33** |
| **HeavyGunner** StandardAI | 214 (MG 160 + DD 54) | 58 | **3,69** | 0,6–1,0 ⚠⚠ | 150 | 0,70 |
| **RATOAI_Demolition** StandardAI | 145 (Granada 120 + DD 25) | 73 | 1,99 | — | 100 | 0,69 |
| **Medic** StandardAI | 20 | 73 | **0,27** | 0,2–0,4 ✔ | 150 | **7,5** |
| **Medic** Healer | 5400 | 0 | inf | — | 1 | 0 |
| **RATOAI_RetreatingMarksman** StandardAI | 25 | 73 | **0,34** | 0,2–0,4 ✔ | 200 | **8,0** |
| **…** Retreat | 175 (Evade 150) | 73 | 2,40 | — | 20 | 0,11 |
| **RATOAI_Rocketeer** StandardAI | 112 | **0** | inf | — | 200 | **1,79** |
| **Pierre** StandardAI | 260 | 50 (Flanked) | 5,2 | — | 100 | 0,38 |
| **TheMajor** StandardAI | 130 | **0** | inf | — | 100 | 0,77 |
| **Beserk** StandardAI | 25 | **0** | inf | — | 100 | **4,0** |
| **Panicked** RetreatAI | 900 | 73 | 12,3 | — | 100 | 0,11 |

Para referência histórica: com o `Penalty −150` dos testes antigos (e a conta corrigida), os `A`
seriam 1/1,5 destes — Soldier 0,47, Sniper 0,45, Skirmisher 0,91, Brute 0,69, HeavyGunner 2,46,
Demolition 1,33, Medic 0,18. **A troca para `−100` moveu o mod inteiro ~50% na direção agressiva
de uma vez só**, que é exatamente o que a Regra 4 avisa sobre mexer no `Penalty`.

### 6.3 As quatro leituras que caem daí

**(a) O Soldier e o Sniper são numericamente o mesmo soldado.**
`A` = 0,71 e 0,67 — indistinguíveis, apesar de os pesos escritos parecerem bem diferentes (o
Sniper compensa o `Weight 100` de ameaça contra o 125 do Soldier com um `SoftK` pior). A
diferenciação entre os dois acontece **inteiramente** nas `OptLocPolicies` (§6.1) e nas signature
actions — não no posicionamento de fim de turno. O Brute descolou (1,03), mas por pouco.

**(b) `R_optloc > 1` em 8 das 16 listas.** Nesses casos, o gradiente de aproximação ao `best_dest`
sozinho vale mais que todas as policies de fim de turno. As `EndTurnPolicies` estão funcionando
como **filtro de segurança** ("não pare num tile suicida"), não como escolha de posição. É uma
arquitetura defensável — mas hoje ela é **acidente de calibragem**, não decisão. No Medic (7,5) e
no RetreatingMarksman (8,0) as `EndTurnPolicies` são praticamente decorativas.

**(c) Quatro arquétipos não têm nenhuma policy negativa no fim de turno**: `RATOAI_Rocketeer`,
`Pierre` (só `TryNotToBeFlanked`, influência 50), `TheMajor`, `Beserk`. Para o Beserk isso é o
desenho. Para o Rocketeer e o TheMajor parece esquecimento: eles param **em qualquer lugar** desde
que a banda de alcance e o LOS batam.

**(d) Com `Penalty −100` a maioria dos arquétipos entrou na banda do papel — sobraram três fora.**

| | `A` | diagnóstico |
|---|---|---|
| **Soldier** | 0,71 | abaixo da banda 0,9–1,3. Falta ~26 pontos de influência positiva; a §7.3 mostra o caminho barato. |
| **Brute** | 1,03 | abaixo da banda 1,2–2,0, e ele é o arquétipo que **precisa** fechar distância. |
| **HeavyGunner** | 3,69 | **muito acima**. `MGSetupPosScore Weight 200` (160 de influência) contra `Threat Weight 80` (58): o freio é 1/4 do acelerador. E a instância dele tem `CoverTrust = 0` — cobertura não cancela nada, então a ameaça já é medida crua e ainda assim perde. Na prática a MG monta onde o cone for bom, exposta ou não. Se isso é o desenho ("ela deita e aceita fogo"), ok; se não, o ajuste é `Threat Weight 80 → 200` (146) ou `MGSetup 200 → 100`. |

Sniper, Skirmisher, Medic e RetreatingMarksman estão dentro da banda dos papéis respectivos.

### 6.4 Botões mortos / suspeitos encontrados no caminho

| # | Onde | O quê |
|---|---|---|
| 1 | `AIPOLICYPOS_CustomSeekCover.lua:423` e `:459` | **`const.RATOAI.ThreatSaturation` nunca é atribuída em lugar nenhum** — as duas linhas que a definiam estão comentadas (`:182` e o bloco de doc), e o grep na pasta `Mods` inteira não acha outra atribuição. A `ThreatExposure` sobrevive porque lê `const.RATOAI.ThreatSaturation or 3`; a `CustomSeekCover` faz `Max(1, const.RATOAI.ThreatSaturation)` **sem `or`**, e só chega lá quando `ThreatRelative > 0`. Hoje a única instância com `ThreatRelative` é a do `Soldier_copy` (arquétipo de teste), então não estoura em jogo — mas é bomba armada, e enquanto isso o "cancelamento" entre as duas policies está documentado como compartilhado e não é. **Descomentar a definição.** |
| 2 | `Soldier`, `Brute` (`DealDamage MaxHits = 100`), `RATOAI_Sniper` (`MaxHits = 100`) | `MaxHits` só vale no modo `cap`. O default é `soft`, e nenhuma instância grava `Normalization`. **Os três `MaxHits` são inertes.** O que age no Sniper é o `SoftK = 50`, que é o pior `K` da tabela da §3.1 (D = 0,19). |
| 3 | `RATOAI_RetreatingMarksman` | `StandardAI Weight = 50` devolve o número 50 cru para a roleta de behaviors (`AIBehavior.Score` default = `self.Weight`); o `PositioningAI` "Retreat" usa o `PositioningAIScore` default, que devolve **o score de posição** (~100–250) x `Weight`/100. Escalas incomparáveis: **a unidade recua em ~75–85% dos turnos**. Mesmo mecanismo no Skirmisher, mas lá o `Weight 40` do `PositioningAI` derruba o número para a mesma ordem do `100` do StandardAI — equilíbrio por acaso. |
| 4 | `RATOAI_Sniper` | `AIPolicyEvadeEnemies {Weight 1, Required true, Range 8 absoluto}` — **este é o idioma certo** e vale copiar: `Required` transforma a policy em portão (`pscore <= 0` → tile inteiro vale 0), e `Weight = 1` a mantém fora do orçamento. Compare com o Skirmisher, cujo `CustomFlanking {Weight 200, Required true}` é portão **e** 100 pontos de influência ao mesmo tempo. |
| 5 | `Scout_LastLocation` | `AIPolicyLastEnemyPos:EvalDest` devolve `self.Weight` e o `AIScoreDest` multiplica por `Weight/100` de novo → `Weight²/100`. Com 500 vira 2500. Sem consequência (policy única, §5), mas o mesmo padrão numa lista com mais policies seria devastador. |
| 6 | `Panicked` | `AIPolicyProximity Weight 1000` sobre um retorno em **tiles crus**. Vira "10 pontos por tile de distância", sem teto. Funciona porque a lista inteira é sobre fugir; não copie o padrão. |

---

## 7. Regras de tuning

### 7.1 O procedimento

1. **Escolha o papel em termos de `A`** antes de tocar em qualquer número:

   | papel | `A` alvo | leitura |
   |---|---|---|
   | Assalto / Brute / Skirmisher | 1,2 – 2,0 | aceita fogo para fechar distância |
   | Infantaria de linha (Soldier) | 0,9 – 1,3 | avança quando o tiro compensa |
   | Suporte de fogo (Sniper, MG) | 0,6 – 1,0 | só troca posição por vantagem clara |
   | Medic / RetreatingMarksman | 0,2 – 0,4 | sobrevive primeiro |
   | Beserk / Panicked | inf / n/a | sem juízo, por desenho |

2. **Escolha `R_optloc`**: a unidade deve *executar o plano* (`R ≈ 1,5–2`; as `EndTurnPolicies` só
   vetam) ou *improvisar* (`R ≈ 0,3–0,6`; as policies mandam)? É o botão que hoje está sendo
   acionado por acidente.

3. **Distribua as fatias do lado positivo.** Alvo prático: a maior fatia entre 40% e 60%. Abaixo
   de 40% nenhuma policy manda e a decisão cai na roleta de 80%; acima de 60% as outras viram
   decoração e você poderia removê-las — o que baratearia o turno, já que cada policy é um laço
   por destino (`PERF_PLAN.md`).

4. **Converta fatia em `Weight` dividindo por `D`** (§3.3). É esse passo que falta hoje, e é ele
   que faz o `DealDamage 200` parecer dominante e valer 25%.

5. **Cheque o zero**: no tile típico *bom* o total tem que ser confortavelmente > 0, senão a
   roleta some (§2, âncora 1). Teste rápido: compare `0,6 x SOMA positivo` com
   `0,5 x SOMA negativo`.

### 7.2 As regras, condensadas

> **R1.** O zero é fronteira, não escala. Peso negativo apaga tiles.
> **R2.** `OptLocWeight` é a régua absoluta do End-Turn. Compare tudo com ele.
> **R3.** `soft` nunca discrimina mais que ~27% do `Weight`; `relative` discrimina ~50%.
> **R4.** `ThreatExposure` com `Penalty −100` vale `0,73 x Weight` de influência — ~3x o
> `DealDamage soft` de mesmo peso. `Penalty` e `Weight` são o mesmo botão; mexa em um só.
> **R5.** Compare arquétipos por `(fatias, A, R_optloc)`, nunca por `Weight`.
> **R6.** `Required` é portão, não peso: ponha `Weight = 1` nas instâncias que só devem vetar.
> **R7.** Interruptor (0/100) não gradua nada — ele **particiona** o mapa. Uma lista só de
> interruptores decide por sorteio dentro da partição.
> **R8.** Não some duas policies que medem a mesma coisa. `DealDamage` **já contém** cobertura do
> alvo, distância (curva de precisão), elevação e postura — tudo vem do `CalcChanceToHit`.
> `CustomWeaponRange`, `HighGround` e `CustomFlanking` na **mesma lista de End-Turn** são
> contagem parcialmente dobrada: têm que entrar como desempate (fatia < 20%) ou como um eixo que
> a CTH não enxerga (alcance de *granada*, cone de MG, coesão com aliados).
> **R9.** No OptLoc a escala é livre; no End-Turn, não. Não copie pesos de uma lista para a outra.

### 7.3 O caso concreto: "ter medo de 2 inimigos, aceitar se expor a 1 se puder matar"

Este é o requisito que dá o desenho inteiro do par DealDamage / ThreatExposure, então vale
resolvê-lo em números.

**Passo 1 — quanto custa se expor, exatamente.** Um inimigo **exposto** contribui com `ramp(d)`
puro (a cobertura cancela via `CoverCancels`, e sem cobertura `uncovered = 100`). Dentro do
`PlateauTiles` (4 tiles) `ramp = 100`. Logo, com `Penalty = −100`:

| exposto a | `threat` | `eval` (sat 300, `MaxThreat` default) | `eval` com **`MaxThreat = 2`** (sat 200) |
|---|---|---|---|
| 1 inimigo colado | 100 | −33 → custo `0,33·W` | **−50 → custo `0,50·W`** |
| 2 inimigos colados | 200 | −67 → custo `0,67·W` | **−100 → custo `W`** |
| 3+ colados | 300 | −100 → custo `W` | −100 → custo `W` |

> O aviso da property (`MaxThreat` próprio só faz sentido com a Seek Cover em `ThreatRelative = 0`)
> **não se aplica** ao Soldier nem ao Sniper: `CoverCancels` está ligado e não há
> `CustomSeekCover` nenhuma nas listas de End-Turn deles.

**Os três botões da ameaça são um só.** Antes da saturação a soma é **linear na contagem**, então
tudo o que decide o comportamento é o custo de UM inimigo exposto colado:

```
c = W_t x |Penalty| / (100 x S)         S = MaxThreat em "inimigos colados"
```

e o custo de `n` inimigos é `n x c`, travando em `S x c`. Consequência que resolve a dúvida
óbvia — **`MaxThreat` NÃO muda a decisão 1-vs-2.** `C1 = c` e `C2 = 2c` qualquer que seja `S`; a
janela de desenho é sempre `(c, 2c)`. `S` decide só **até onde o medo continua crescendo**.

Ou seja: dá para manter sensibilidade ao 3º (ou 4º) inimigo de graça, **rescalando `W_t` por
`S/2`** para preservar o mesmo `c`:

| quer gradiente até | `S` | `W_t` (com `Penalty −100`) | custo 1 / 2 / 3 / 4 exp. colados |
|---|---|---|---|
| 2 inimigos (patamar cedo) | 2 | **125** | 62 / 125 / 125 / 125 |
| **3 inimigos** | **3** | **187** | **62 / 125 / 187 / 187** |
| 4 inimigos | 4 | 250 | 62 / 125 / 187 / 250 |

As três linhas se comportam **identicamente** para 1 e 2 inimigos. O único preço de `S` alto é o
piso mais fundo (`S x c`), que empurra mais tiles para o negativo — e tile negativo tem peso 0 na
roleta (§2, âncora 1). Isso é o efeito desejado ("não fique na frente de três"), mas checar o zero
vira obrigatório: com o Soldier proposto abaixo e `S = 3`, um tile exposto a 3 **com tiro bom**
ainda fecha em +57 (vive, raramente sorteado) e **com tiro ruim** fecha em −39 (morre). É a
separação certa; só não suba `S` sem refazer essa conta.

**Se você quiser um degrau mais duro em 2 do que a linearidade dá**, o caminho é somar duas
instâncias com saturações diferentes — o resultado é uma curva côncava por partes:

| instância | `W` | `MaxThreat` | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|---|
| A (o degrau) | 100 | 2 | −50 | −100 | −100 | −100 |
| B (a cauda) | 75 | 5 | −15 | −30 | −45 | −60 |
| **soma** | | | **−65** | **−130** | **−145** | **−160** |

Passo 1→2 = −65; 2→3 = −15. Cliff em 2, sensibilidade preservada depois. Duas ressalvas antes de
adotar: **(a) custo** — `GetUncovered` chama `GetCoverPercentage` por (destino × inimigo) e **não
tem cache**, então duas instâncias com `CoverCancels` ligado dobram o raycast mais caro da policy
(D×E×2, com D de 150–800); **(b) overlay** — `AIPolicyThreatExposure:GetEditorView()` só
diferencia por `RangeCapTiles` e `FalloffCurve`, então duas instâncias que diferem **apenas** em
`MaxThreat` colapsam numa linha só no debug (§7.4, item 5). Uma linha em `GetEditorView` resolve.

**Passo 2 — a restrição de desenho.** Com `C1` = custo de 1 exposto colado, o ganho positivo de
ir para o tile exposto tem que caber numa janela:

```
C1  <  G + Kill  <  2 x C1
      ^^^^^^^^
      G    = ganho de VOLUME (a instância soft), tile coberto -> tile exposto
      Kill = ganho de LETALIDADE (a instância tokill) quando dali ela derruba o alvo
```

Abaixo de `C1` ela nunca se expõe; acima de `2·C1` ela se expõe a dois. Com `MaxThreat = 2`,
`C1 = W_t/2`, então **todo o lado positivo tem que morar entre `W_t/2` e `W_t`.**

**Passo 3 — "se acha que consegue matar" não pode sair do termo de volume.** A instância `soft`
é monótona em acertos esperados e **não sabe nada sobre o HP do alvo**: ela não distingue "3
acertos num alvo cheio" de "3 acertos em quem cai com 1". Quem responde a pergunta de letalidade
é a segunda instância, em `tokill` — e é por isso que ela existe. No Soldier ela está em
`Weight 30` (influência 15) e no Sniper em `20`: **pequena demais para ser o voto de desempate
que o requisito pede.**

**Passo 4 — os números.**

| | hoje | proposta | por quê |
|---|---|---|---|
| **Soldier** `DealDamage` soft | `W 200, SoftK 100` | `W 200`, **`SoftK 190`** | põe a sensibilidade no volume; `h` dele vai de ~50 (tiro longo marginal) a ~700 (duas rajadas coladas) |
| **Soldier** `DealDamage` tokill | `W 30` | **`W 60`** | é o termo "consigo matar"; a 30 ele nunca decide nada |
| **Soldier** `ThreatExposure` | `W 125` | **`W 187`** (`MaxThreat` fica em 3) | `c = 62` → `C1 = 62`, `C2 = 125`, e o 3º inimigo ainda soma 62; `G+Kill ≈ 92` cai dentro da janela |
| **Sniper** `DealDamage` soft | `W 200, SoftK 50` | **manter** | `K = 50` é front-loaded — é exatamente o "acertar 1 tiro importa". Ver o quadro de forma na §3.1 |
| **Sniper** `ThreatExposure` | `W 100` | **`W 150`** (`MaxThreat` fica em 3) | `c = 50` → `C1 = 50`, `C2 = 100`, 3º inimigo soma 50; `G+Kill ≈ 62` cai dentro |
| **Soldier / HeavyGunner** | — | **não usar `relative`** | satura na rajada, ver o alerta vermelho da §3.1 |

Sobre o `MaxHits = 100` inerte do Soldier, do Brute e do Sniper (§6.4, item 2): ele só ganha
efeito se o modo virar `cap`. Como a recomendação aqui é ficar em `soft`, o certo é **apagar**
esses `MaxHits` do preset para não parecerem calibragem ativa.

E o que *não* fazer: subir o `DealDamage` de 200 para 400 dobra a influência, mas soma ~130
pontos de offset a todo tile com tiro — o que alarga a banda de 80% em termos absolutos e
**aumenta a aleatoriedade** sem aumentar a discriminação. É o erro que a Regra 3 evita. Mexer no
`SoftK` muda a forma sem inflar o offset; é o botão mais barato.

*(Mudança de peso/preset sai pelo editor in-game — `items.lua` é gerado.)*

### 7.4 Como medir os `D` reais em vez de estimar

Os `D` da §3.3 são estimativas de modelagem. Para os seus mapas e mobs, meça:

1. `RATOAI_Debug` ligado (`Platform.developer and Platform.cheats`) → `DEBUG.lua` mostra o
   `score_details` por policy no rollover do voxel; o `AIScoreDest` grava
   `policy:GetEditorView()` junto do `pscore` **já multiplicado pelo `Weight`**.
2. Para ameaça e cobertura, `const.RATOAI.ThreatDebug = true` e
   `const.RATOAI.SeekCoverDebug = true` no console dão o passo a passo por inimigo.
3. Anote, para ~20 destinos do mesmo turno, o **mínimo e o máximo** de cada linha.
   `D_real = (max − min) / Weight`.
4. Cuidado: **não mova a unidade e meça de novo** — os caches de visão e o `ai_context` não
   regeneram, e número medido depois de mover não vale como evidência.
5. Duas instâncias da mesma classe com configurações diferentes **precisam de `GetEditorView`
   diferente**, senão a camada por policy do overlay soma as duas numa linha só.

Feita a medição uma vez por arquétipo, as tabelas da §6 viram números seus e a calibragem deixa de
ser à mão.
