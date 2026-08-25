# `dbg` é palavra reservada do engine — NUNCA use esse nome em `Code/*.lua`

> Se você é um Claude (ou qualquer outra IA) lendo isto pela primeira vez: não é
> estilo, é uma regra dura. Usar o identificador `dbg` — como variável, como chave
> de tabela, ou até só mencionado dentro de um comentário — em qualquer arquivo de
> `Code/` **quebra o carregamento do mod no executável de release** (`JA3.exe`),
> mesmo que o arquivo esteja 100% sintaticamente correto. `JA3Debug.exe` não é
> afetado, o que faz o bug parecer impossível até você comparar os dois.

## O sintoma

Abrindo o jogo pelo executável normal (`JA3.exe`, não o `JA3Debug.exe`):

```
[mod] Errors while loading mod Rato's AI Overhaul:
Code/FUNCTION_ScoreAttacksDetailed.lua:715 - '}' expected (to close '{' at line 715) near ''
```

O arquivo, lido e conferido com um lexer Lua de verdade (respeitando `--` e `--[[ ]]`),
está perfeitamente balanceado. Comentar a linha acusada não resolve — o erro só
**pula para outro lugar do arquivo** (visto em campo: de `:715` para perto de um
`slot` bem mais adiante). Isso é a assinatura de um problema que não é do
parser Lua real, e sim de alguma etapa de texto que roda ANTES dele, só na build
de release.

## A causa

`CommonLua/Core/lib.lua:32` (source do jogo, `ModTools/Src`, referência):

```lua
dbg = empty_func -- WILL BE REMOVED IN GOLD MASTER
```

`dbg(...)` é o idioma padrão do engine (Zulu/Haemimont) para envolver uma
expressão que só deve ser avaliada em build de desenvolvimento — usado aos montes
no source do próprio jogo (`Banter.lua`, etc.): `dbg(ExpressaoCaraDeDebug())`.

O comentário confirma que existe uma etapa de build, ligada à **Gold Master**
(a build de release — é o que o `JA3.exe` normal carrega; `JA3Debug.exe` é a
build de dev), que remove esse idioma do código antes de compilar. Como o erro
que aparece É um erro de sintaxe Lua genuíno, essa etapa **mexe no texto antes do
compilador Lua rodar** — ou seja, não é Lua-aware. Ela provavelmente:

1. varre o texto atrás do identificador `dbg` (ou até só a substring — não dá
   para saber sem o código-fonte da ferramenta, que não está em `ModTools/Src`);
2. quando acha, tenta remover a "chamada" de debug procurando o próximo `(` e o
   `)` que fecha;
3. como nosso mod nunca chama `dbg(...)` — só usa `dbg` como **nome de variável
   local e chave de tabela** (`local dbg = RATOAI_Debug`, `dbg = dbg,`,
   `dbg = slot and slot.dbg`) — essa etapa encontra o token no lugar errado e
   começa a comer texto a partir dali até o parêntese seguinte que existir no
   arquivo, não importa quão longe. Isso explica tanto o erro de chave quanto o
   fato de ele "pular de lugar" quando você edita o arquivo: a poda começa num
   ponto diferente e para num parêntese diferente.

Isso também explica um efeito colateral visto em campo: um comentário sem
relação nenhuma com `dbg` (descrevendo `RATOAI_LastExpected = {}`) perdeu
literalmente o texto `{}` \` no meio de uma sessão de debug — dano colateral da
mesma poda desgovernada, disparada por um `dbg` em outro ponto do arquivo.

## A prova

Log real de `%AppData%/Jagged Alliance 3/logs/JA3.exe-*.log`, várias tentativas
na mesma noite, todas citando a mesma área do arquivo (`FUNCTION_ScoreAttacksDetailed.lua`,
que tinha `dbg`/`dbg = dbg,`/`dbg = slot and slot.dbg,` em várias tabelas):

```
Code/FUNCTION_ScoreAttacksDetailed.lua:715 - '}' expected near ''
Code/FUNCTION_ScoreAttacksDetailed.lua:718 - '}' expected (to close '{' at line 715) near ''
```

Um checker Python (lexer completo — string curta, string longa `[[ ]]`,
comentário `--` e `--[[ ]]`) confirmou o arquivo balanceado em todo momento;
mesmo um contador ingênuo de `{`/`}` do arquivo inteiro, **fingindo que
comentários não existem**, também batia zero. A única coisa que os dois
checkers não veem — porque nenhum dos dois é a ferramenta real do jogo — é
o que quer que rode antes da compilação Lua na build de release.

## O que foi feito (2026-08-25)

Renomeado todo uso do identificador **standalone** `dbg` (variável local, chave
de tabela, e menções em comentário) para **`trace`**, nos 7 arquivos onde
aparecia:

- `Code/FUNCTION_ScoreAttacksDetailed.lua`
- `Code/AIPOLICYPOS_CustomSeekCover.lua`
- `Code/AIPOLICYPOS_ThreatExposure.lua`
- `Code/AIPOLICYPOS_CustomFlanking.lua`
- `Code/SOURCE_AIPrecalcDamageScore.lua`
- `Code/CONSTANTS_AI_source.lua` (só comentário)
- `Code/UTIL.lua` (só comentário)

**Contrato cross-mod que isso quebrou, e já foi corrigido**: dentro de
`context.dbg_expected[dbg_id] = {...}` (que É um `dbg_*` composto, então ficou de
pé) havia um campo `dbg = slot and slot.dbg` — esse sim o token isolado, guardando
a tabela de detalhe (`cost`, `shots`, `attacks`, `recoil`, `alvo`, `dist`, `cth`)
que `RATOAI_ExpectedFor` monta. O mod companheiro **`Rato Dev`** (outro repo git,
`Mods/Rato Dev/Code/RATODBG_AIDebugUI.lua`) lê esse campo por nome —
`local d = e.dbg` (linha ~1199) — para desenhar a linha "custo/balas/ataques/CTH"
do painel "Resultado esperado". Renomear só o lado produtor (aqui) sem o lado
consumidor (lá) não quebraria em erro nenhum — só faria a linha de detalhe sumir
em silêncio do painel, porque `e.dbg` viraria sempre `nil`. **Já corrigido**: o
`RATODBG_AIDebugUI.lua` foi atualizado para `local d = e.trace`. Se `context.dbg_expected`
ganhar um novo campo de detalhe algum dia, dê um nome que não seja `dbg` — e
lembre que quem lê do outro lado é esse arquivo, num mod totalmente separado.

**Não tocado de propósito**: identificadores compostos que já continham `dbg_`
como prefixo — `dbg_expected`, `dbg_turno`, `dbg_aim_plan`, `dbg_rows`, `dbg_id`,
`dbg_dest`, `dbg_chain`, `dbg_targets`, `dbg_target_list`, `dbg_tiles`,
`dbg_range`, `dbg_text`, `dbg_behavior_scores`, `dbg_action`, `dbg_available_actions`,
`dbg_parts`, `dbg_why`, `dbg_freeze_target_rand`, `dbg_target_score_mod_frozen` —
espalhados por `DEBUG.lua`, `SOURCE_AIPrecalcDamageScore.lua`,
`SOURCE_AISelectAction.lua`, `SOURCE_AIEvalZones.lua`, `SOURCE_AIPlayAttacks.lua`,
`SOURCE_AICreateContext.lua`, `FUNCTION_GunnerBehaviors.lua`,
`FUNCTION_SignaturesCustomScoring.lua`, `AIPOLICYPOS_CustomSeekCover.lua`,
`UTIL.lua`. Isso porque o caso confirmado e reproduzido em jogo foi
especificamente `dbg` como token isolado (variável/chave de tabela), não esses
compostos — e trocar todos de uma vez seria uma refatoração enorme e não pedida.

**Risco em aberto**: não sabemos se a etapa de build reage só ao token isolado
`dbg` ou a qualquer ocorrência da substring `dbg` (o que pegaria os compostos
acima também). Se o erro de sintaxe voltar a aparecer só no executável normal,
DEPOIS de conferir que não sobrou nenhum `dbg` isolado, o próximo suspeito é
esses `dbg_*` compostos — comece pelo arquivo citado no erro.

## A regra, resumida

**Nunca escreva o identificador `dbg` em `Code/*.lua`** — nem como variável, nem
como chave de tabela, nem dentro de um comentário. Use `trace` (ou qualquer
outra palavra que não contenha a substring `dbg`) para variáveis locais que
guardam o flag/buffer de debug de uma função. Isso é independente de, e não
substitui, `RATOAI_Debug` (o global real que liga/desliga o overlay) — só o
literal `dbg` de 3 letras é problemático.

Se dependência nova (GBO3, JA3_CommonLib, Zulib) ou código copiado do source do
jogo trouxer um `dbg(...)` de verdade, **não é o mesmo caso**: ali `dbg` está
sendo usado exatamente como o engine espera (uma chamada real), então
presumivelmente a etapa de build sabe lidar com ele. O problema é só quando
`dbg` aparece em posição que NÃO é chamada de função.
