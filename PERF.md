# Rato's AI Overhaul — Performance

Companion do `PERF_PROFILING.md` (como medir — instrumentação, não otimização). Este
arquivo é o tracker: o que foi identificado, o que foi aplicado, o que falta. A
explicação de cada mudança já aplicada vive junto do código, no comentário
`---- PERF (Cx)` correspondente, com o mesmo nível de detalhe que os `BUGFIX (Bn)` — não
duplicar aqui.

## Status

| # | Mudança | Arquivo | Risco | Status |
|---|---|---|---|---|
| C1 | Memoizar CTH por nível de mira | `FUNCTION_ScoreAttacksDetailed.lua` | 🟢 exato | ✅ aplicado |
| C2 | Remover `CalcValue` de cover duplicado | `FUNCTION_ScoreAttacksDetailed.lua` | 🟡 equivalente | ✅ aplicado |
| C3 | `get_recoil` para dentro do gate de alcance | `SOURCE_AIPrecalcDamageScore.lua` | 🟢 exato | ✅ aplicado |
| C4 | Cache de recoil por distância | `SOURCE_AIPrecalcDamageScore.lua` | 🟡 equivalente | ✅ aplicado |
| C5 | Inverter ordem barato/caro no `CanSurround` | `AIPOLICYPOS_TryNotToBeFlanked.lua` | 🟢 exato | ✅ aplicado |
| C6 | Memoizar `IsSurrounded` por voxel | `AIPOLICYPOS_TryNotToBeFlanked.lua` | 🟢 exato | ✅ aplicado |
| C7 | Hoistar resolução de granada | `AIPOLICYPOS_GrenadeRange.lua` | 🟢 exato | ✅ aplicado |
| C8 | Fechar o precipício do `precalced` | `SOURCE_AIPrecalcDamageScore.lua` | 🟢 exato | ✅ aplicado |
| C9 | Debug atrás de flag | 3 arquivos | 🟢 exato | ✅ aplicado |
| C10 | `OptLocSearchRadius` 100 → 80 | `items.lua` | 🟠 aproximado | ⏸️ não aplicado — pedido explícito pra deixar de fora; é o único item que reduz a cardinalidade do laço OptLoc, candidato óbvio se as medições não bastarem |
| C11 / C11.1 / C11.2 / C11.3 | Alocações no caminho quente (função de arquivo em vez de closure; tabelas constantes em vez de realocadas) | `FUNCTION_ScoreAttacksDetailed.lua`, `FUNCTION_ShouldMaxAim.lua`, `SOURCE_AICalcAttacksandAim.lua`, `FUNCTION_CustomArchetypeFunc.lua` | 🟢 exato | ✅ aplicado |
| C12 | `CustomScoring` só depois do gate, não pra toda ação | `SOURCE_AISelectAction.lua` | 🟡 equivalente | ✅ aplicado |
| C13 | Cache de recoil por `(stacks, action)`, não só `stacks` | `SOURCE_AICalcAttacksandAim.lua` | 🟡 correção de cache, não só perf | ✅ aplicado — sem entrada até agora. Necessário porque `RATOAI_ExpectedFor` passou a avaliar ações alternativas; sem o `action` na chave, o cache devolveria o custo de mira da ação errada |
| C14 / C14.1 / C14.2 / C14.3 | Zero alocação por destino no `CustomFlanking` (lia de tabelas já preenchidas em vez de remontar); `ResolveValue("Cover")` de 3× por (destino, inimigo) pra 1× por unidade via `RATOAI_GetMaxCoverCTH()` | `AIPOLICYPOS_CustomFlanking.lua` | 🟢 exato | ✅ aplicado — sem entrada até agora. Veio junto do B39 (o gradiente de cobertura que era jogado fora); ordem de grandeza antiga: 10⁴ tabelas/unidade/turno só para o GC comer, com D=150–800 destinos e T=4–12 alvos |
| G11 | Arquivos mortos | — | 🟢 | ⏸️ não aplicado |
| F2.3 | `CustomSeekCover` medido em vez de estimado | `AIPOLICYPOS_CustomSeekCover.lua` | — | ✅ aplicado, parcial — faltam `CustomFlanking` e `getAIShootingStanceBehaviorSelectionScore` |
| F3.3 | Remover cópia órfã de `SOURCE_AIPrecalcDamageScore.lua` na raiz | — | — | ⏸️ parcial — arquivo deletado (versionado, recuperável com `git checkout`), mas as entradas comentadas no `metadata.lua` continuam: editar só o metadata dessincronizaria do `items.lua`, que espelha a mesma lista. Isso tem que sair pelo editor in-game |
| Fase 2 / F3.1 / F3.2 | Reestruturação maior | — | 🔴 alto risco | ⏸️ esboços, não patches. Aguardando medição do efeito do que já entrou |

**Validação:** balanceamento de blocos (`function`/`if`/`for` vs `end`) conferido em todos
os arquivos de `Code/`, e varredura por referências órfãs a símbolos removidos ou
renomeados. Não há interpretador Lua no ambiente de dev — validação é estática, nada foi
executado. Erros de runtime (nome errado, nil index) só aparecem no jogo.
