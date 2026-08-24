# Rato's AI Overhaul — Plano de instrumentação

Companion do `PERF_PLAN.md` (onde está o tempo) e do `PERF_CHANGES.md` (o que já foi
aplicado: C1–C13). Este arquivo é sobre **medir**, não sobre otimizar: como sair do
palpite e ter número por policy e por fase.

Status: **implementado** no Rato Dev (N1–N4). Nada disso vive no mod de produção.

| Onde | O quê |
|---|---|
| `Rato Dev/Code/RATOTEL_AITelemetry.lua` | o profiler inteiro + o campo `prof` no JSONL |
| `Rato Dev/Code/RATODBG_AIDebugUI.lua` | a aba **Perf** do painel |

Ficou dentro do `RATOTEL_AITelemetry.lua` em vez de arquivo novo de propósito: arquivo novo
precisa entrar no `metadata.lua` **e** no `items.lua` pelo editor, que é exatamente a armadilha
que manteve o `SOURCE_AIPrecalcConeTargetZones.lua` dormente. Estes dois já estão registrados.

## Como usar

```
const.RATOAI.Profile = true
```

no console (ou o link na aba **Perf**), e rode o turno. Os wrappers entram na primeira unidade
que raciocinar depois disso — não no load, porque a ordem de carga entre os dois mods não é
garantida e vários desses globais são sobrescritos pelo AI Overhaul.

Interruptor **separado** do `RATOAI_Debug`: perfilar com o debug ligado mede as tabelas de debug
que o PERF C9 tirou do caminho quente — ou seja, mede o overlay, não a IA.

Uma vez instalados, os wrappers ficam. Desligar o interruptor não os remove; eles viram um
`if not cur then return f(...) end`. Para voltar ao custo zero, recarregue o mod.

### Lendo os números

- **`AIScoreDest` contém as policies** — ele é quem chama `EvalDest`. A diferença entre o ms dele
  e a soma das policies é o custo do próprio laço. Não some as duas seções.
- **`z` perto de `n`** quer dizer que o relógio não resolveu aquela linha: ignore o ms dela e
  olhe `aloc` e `n/dest`, que são exatos.
- **`n / opt`** entrega quantas instâncias daquela classe o archetype carrega.

---

## 1. O que os contadores de hoje medem — e o que não medem

A página "Tempos" do painel são os `thihk_steps` do vanilla (`AIBehaviors.lua:56-70`):
`BeginStep`/`EndStep` em volta de **think / destinations / optimal location /
end of turn location / movement action**.

| # | Limitação | Evidência |
|---|---|---|
| 1 | **Não existem no turno real.** `BeginStep` retorna na 1ª linha se `debug_data` for nil, e o turno real chama `behavior:Think(unit)` sem tabela. Só o overlay passa uma. | `CombatCamera.lua:1004, 1018`; `UnitAwareness.lua:938` |
| 2 | **Cobrem só o Think.** `AISelectAction`, `AIChooseSignatureAction`, `AIPlayAttacks` e a execução ficam de fora. | `AIBehaviors.lua:232-260` |
| 3 | **Granularidade errada.** "optimal location" é bloco único — e é dentro dele que rodam as ~6 policies × A destinos. Confirma que o laço OptLoc é caro, não diz qual policy. | — |
| 4 | **Amostra enviesada para cima.** O painel mede com `RATOAI_Debug` ligado (as tabelas que o C9 tirou do caminho quente voltam) e limpa `g_AIDestEnemyLOSCache`/`g_AIDestIndoorsCache` antes de cada `Process` — mede sempre o caso frio. | `RATODBG_AIDebugUI.lua:1931-1935` |

O `RATOTEL_AITelemetry` já grava um registro por unidade por turno em JSONL, mas
**não grava tempo nenhum** — o `dd` que ele passa ao `StartAI` captura só os scores
de behavior.

---

## 2. Proposta — quatro camadas

Tudo no **Rato Dev**, atrás de `const.RATOAI.Profile` (separado do `RATOAI_Debug`:
perfilar com as tabelas de debug ligadas mede o overlay, não a IA). Wrappers
aditivos, resultado devolvido intacto, `pcall` como o resto da telemetria.

### N1 · Atribuição por instância de policy
É a camada que responde "é o flanking ou é o score detalhado?".

`AIScoreDest` (`SOURCE_AIScoreDest.lua:24`) é choke point único, mas é código de
produção. Melhor: varrer `ClassDescendants("AIPositioningPolicy")` no load do Rato Dev
e trocar o `EvalDest` de cada classe que tem um próprio por um wrapper que acumula
ticks + contagem. Zero linha na produção, e pega de graça as policies vanilla
(`LosToEnemy`, `HighGround`, `IndoorsOutdoors`) — o denominador contra o qual as
nossas têm de ser julgadas.

**Agregar por instância, não por classe.** O `RATOAI_Demolition` tem duas
`AIPolicyGrenadeRange` com ranges e pesos diferentes (`items.lua:1750` e `1761`), e
cada uma paga preço cheio por destino. Agregado por classe, isso some.

Espalhamento nos presets (nº de instâncias em `items.lua`): `CustomSeekCover` 17,
`ThreatExposure` 16, `LosToEnemy` 16, `CustomWeaponRange` 11, `CustomFlanking` 8,
`TryNotToBeFlanked` 6, `HighGround` 6, `IndoorsOutdoors` 5, `MGSetupPosScore` 4,
`GrenadeRange` 2.

### N2 · As fases que ninguém cronometra
Envolver os globais: `AIFindDestinations`, `AIScoreReachableVoxels`,
`AIPrecalcDamageScore`, `AIFindOptimalLocation`, `AISelectAction`,
`AIChooseSignatureAction`, `AIPlayAttacks`.

E envolver o `Think` de cada behavior para passar uma tabela nossa quando o profiler
estiver ligado — assim os cinco rótulos vanilla passam a existir **no turno real** de
graça. Tabela nova a cada `Think`: o `BeginStep` tem `assert(not thihk_steps[label])`.

### N3 · Contadores de primitiva, não cronômetro
`GetPreciseTicks` é milissegundo; um `CheckLOS` está ordens de grandeza abaixo.
Cronometrar chamada a chamada mede o relógio. O que vale é **contar**:
`CalcChanceToHit`, `GetCoverPercentage`, `CheckLOS`, `get_recoil`, `AIGetAttackArgs`,
`AICalcAttacksAndAim`, `RATOAI_ScoreAttacksDetailed`.

A razão *contagem / #destinos* é melhor métrica que o ms porque é **determinística**.
Hoistar uma chamada faz o ms cair com ruído; faz a contagem cair de 9.600 para 400 sem
o que discutir. Foi assim que o C4 se provou.

Ressalva: `CheckLOS` é da engine e o jogo inteiro usa. Contar só na janela entre
reset-no-início-do-turno-da-unidade e leitura-no-fim.

### N4 · Normalização
Todo registro sai com `#all_destinations`, `#destinations`, `#enemies`, `#targets`,
`max_attacks`. Um turno de 40 ms com 300 destinos e outro de 40 ms com 1.400 são
diagnósticos opostos; sem cardinalidade viram a mesma linha.

---

## 3. Onde isso aparece

| Saída | Papel |
|---|---|
| Página nova no painel | Uma unidade, ao vivo, para iterar enquanto se mexe no código. Amostra única e fria. |
| Campo `prof` no JSONL da telemetria | O que presta para diagnosticar. `pending[unit]` já existe desde o `StartAI`, então o `Think` instrumentado tem onde escrever e o `CaptureAfter` emite junto. |

Agregar depois com script Python sobre o JSONL: ms por policy, µs por destino,
contagem de primitiva por destino, e o **p95** — é a cauda que trava o jogo, não a média.

---

## 4. Armadilhas

- **Resolução de 1 ms** do `GetPreciseTicks` (ver N3).
- **Overhead do próprio wrapper**: `EvalDest` envolvido roda A × ~6 vezes. Medir com um
  wrap-identidade antes de acreditar em qualquer número.
- **O profiler não pode mudar decisão.** Wrapper aditivo, como a telemetria já faz.

---

## 5. O que já se sabe antes de medir

C1–C13 entraram, então o custo unitário fácil já foi cortado. O que sobra no
`PERF_PLAN` é o que ataca **cardinalidade**:

- **P3.1** (duas fases no `AIPrecalcDamageScore`, detalhado só no top-K) — único item
  do plano inteiro que reduz cardinalidade em vez de custo unitário.
- **P2.1** (gate de grid antes do `GetCoverPercentage` no `CustomSeekCover`).
- **C10** (`OptLocSearchRadius` 100 → 80 em 4 archetypes, −36% de destinos) — melhor
  retorno por esforço, mas é `items.lua`: tem que sair pelo editor.

Palpite a ser confirmado ou derrubado pela medição: os favoritos são
`CustomSeekCover` (17 instâncias, sem o gate do P2.1) e `AIPrecalcDamageScore`, não o
`TryNotToBeFlanked` — que já levou C5 e C6 e aparece em só 6 presets.

**Ordem sugerida:** N1 + N4 primeiro (juntos respondem a pergunta), N3 junto porque é
barato e sem ruído, N2 depois.
