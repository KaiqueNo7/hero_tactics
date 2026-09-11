# Ranked 1v1 MD3 — análise e proposta

Leitura do código em disco, sem alterações. 2026-09-10.

---

## Resumo

Metade do que a série precisa **já existe**, construída para outras coisas: o
despachante de regras de partida, o reinício de partida no mesmo slot, a janela
de reconexão e o padrão de resultado idempotente. Nada disso precisa ser
inventado, e reaproveitar é o que mantém o refactor pequeno.

O que não existe é o Ranked em si. Hoje "ranked" é **uma contagem de vitórias**:
o `LeaderboardService` tem duas funções, `RecordWin` e `GetTop`. Não há elo, PDL,
MMR, série, fila por habilidade nem tela própria.

E há uma dívida marcada para esta feature: o **P1 da auditoria de segurança**,
que é o abandono deliberado não registrar a vitória do adversário. Ele entra
aqui.

---

## 1. Arquitetura atual relevante

### O que dá pra reaproveitar

| Peça existente | Serve pra |
|---|---|
| `match.rules.resolve` + `MatchManager.Resolvers` | registrar um resolvedor `"series"`, como os desafios já fazem com `"challenge"` |
| `RestartMatch(match, fight)` | o reset entre games: derruba a cena e sobe outra no MESMO slot |
| `SuspendForReconnect` / `ForfeitDisconnected` / `RECONNECT_WINDOW` | desconexão e volta |
| `match.starsDone` (em `AwardFightStars`) | o padrão de "processa uma vez só" |
| `FightStore` | molde de store por jogador com merge e clamp |
| `ProgressionService.GetLevel(userId)` | o portão de nível 5, server-side |
| `LobbyZoneBuilder.EnsureLobbyPads` | onde o pad dourado entra |
| `RewardQueueService` | a comemoração que sobrevive a fechar o jogo |

### O que existe e é insuficiente

**Fila.** `OnPvpPadTouched` empilha jogadores numa lista e pareia os dois
primeiros. FIFO puro, sem habilidade, sem nível, uma fila só.

**Ranking.** `IsRankedPvp(match)` decide se o resultado conta, e o único efeito é
`LeaderboardService.RecordWin`. Não há derrota registrada.

**Economia.** `Progression.MatchReward` devolve 30, 40 ou 60 por vitória PvP
conforme sobreviventes, 20 por derrota ou empate, e **10 fixos** por vitória
contra bot. `MatchCoins` devolve 50 na vitória e 0 no resto. É praticamente
binário, que é a queixa do item 20.

**Abandono.** `AwardAbandon` dá XP de vitória a quem fica e **não registra
nada de ranking**. Sair de propósito é hoje melhor que cair de conexão.

---

## 2. Arquitetura proposta

Quatro arquivos novos e nenhum sistema paralelo.

| Arquivo | Papel |
|---|---|
| `src/shared/Modules/Ranked.luau` | elos, faixas, fórmulas de PDL e MMR, config. Puro, sem estado |
| `src/server/Modules/RankedStore.luau` | elo, PDL, MMR, vitórias, derrotas e séries por jogador |
| `src/server/Modules/RankedService.luau` | a fila com bandas, a série, o resolvedor, o resultado |
| `src/client/RankedClient.client.luau` | tela VS, indicador MD3, resultado da série |

A série NÃO é um modo de partida novo. É um `match` normal com
`rules.resolve = "series"`, e o `RankedService` registra
`MatchManager.Resolvers.series`. Exatamente o caminho que os desafios de herói
já abriram.

---

## 3. Fórmula de MMR

Elo clássico, que é previsível e tem meia página de código.

```
esperado(A) = 1 / (1 + 10 ^ ((mmrB - mmrA) / 400))
mmrA' = mmrA + K * (resultado - esperado(A))
```

`resultado` é 1 na vitória da série e 0 na derrota. Empate não existe em MD3.

`K` decrescente por experiência, para o rating assentar:

| Séries disputadas | K |
|---|---|
| 0 a 9 | 60 |
| 10 a 29 | 40 |
| 30 ou mais | 24 |

MMR inicial: **1000**. O jogador nunca vê esse número.

## 4. Fórmula de PDL

O PDL é a face visível, e ele **segue** o MMR em vez de ser uma segunda verdade.

```
base   = 18
delta  = clamp(mmrOponente - mmrJogador, -400, 400)
ajuste = round(delta / 400 * 10)

vitória: ganho  = clamp(base + ajuste,  8, 30)
derrota: perda  = clamp(base - ajuste,  8, 30)
```

Ganhar de alguém 400 acima rende 28; ganhar de alguém 400 abaixo rende 8. Perder
para um mais forte custa 8; perder para um mais fraco custa 28. Simétrico e
legível.

Bônus de placar, pequeno de propósito para não virar alvo de exploit:
**2 PDL a mais no 2 a 0**.

## 5. Configuração dos elos

```lua
Ranked.PDL_PER_RANK = 100
Ranked.RANKS = { "Bronze", "Silver", "Gold", "Platinum", "Diamond", "Master" }
```

O estado guardado é **um número só**: `pdlTotal`. Elo e PDL dentro do elo são
derivados.

```
rankIndex = min(floor(pdlTotal / 100), #RANKS - 1)
pdlNoElo  = pdlTotal % 100
```

Isso resolve os itens 3 e 4 sem código de transição: 87 + 18 = 105 vira
Silver 5, e 108 - 15 = 93 vira Bronze 93. O excedente nunca se perde porque
nunca existiu como coisa separada.

`pdlTotal` tem piso em 0. Bronze 0 não desce mais.

### Master

Recomendo a opção **D adaptada**: Master é o índice final e o PDL **continua
acumulando sem teto** lá dentro. Um Master com 340 aparece como "Master 340".
Isso já é a ordenação de um leaderboard competitivo sem precisar de Master
Points agora, e não muda o formato salvo quando ele existir.

## 6. Matchmaking

Fila própria, separada da casual. Cada entrada guarda `player`, `mmr`, `level` e
`entrouEm`.

Duas condições, e as duas precisam passar:

```
|mmrA - mmrB| <= banda(tempo)
|levelA - levelB| <= 10
```

| Tempo na fila | Banda de MMR |
|---|---|
| 0 a 15s | 100 |
| 15 a 30s | 250 |
| 30 a 60s | 500 |
| acima de 60s | sem limite |

A banda usada é a do jogador que está esperando **há mais tempo**, senão dois
recém-chegados nunca se pareariam com alguém antigo. O nível entra como guarda
de experiência, que é o "democrático" do pedido, e afrouxa junto depois de 60s
para a fila não travar num servidor vazio.

PDL nunca entra no pareamento, só o MMR.

## 7. Fluxo de UI

```
pad dourado
  -> nível < 5: recusa e mostra "Desbloqueia no nível 5"
  -> entra na fila, HUD de busca com tempo
  -> par encontrado
  -> servidor monta a série e envia os dois perfis
  -> TELA VS (2.5s)
  -> arena carrega
  -> Game 1  [indicador MD3 no HUD]
  -> placar intermediário (1.8s)
  -> Game 2
  -> placar, e Game 3 se 1 a 1
  -> RESULTADO DA SÉRIE
  -> promoção, se houver
  -> lobby
```

## 8. Tela VS

Um payload só, montado no servidor, com o que ele já sabe:

```lua
{ nome, elo, pdlNoElo, vitoriasRanked, level, userId }
```

O cliente busca o avatar pelo `userId` com `Players:GetUserThumbnailAsync`, que
é dado público e não gameplay. Nada de elo, PDL, vitórias ou nível vem do
cliente. Fecha o item 12.

## 9. Indicador MD3

Três caixas por jogador, ao lado do painel de turno que já existe. Vencidas
acesas, a do game corrente pulsando, as futuras apagadas.

O estado vem do snapshot em `state.series = { games = {"win","loss",nil}, meu = 1,
dele = 1, game = 3 }`. É leitura pura, o cliente não conta nada.

Cabe em cerca de 90 por 22 pixels, e some fora do Ranked.

## 10. Resultado final

Template próprio, separado do painel de vitória atual: placar da série, elo,
PDL antes, variação, PDL depois, XP, moedas e vitórias totais. Promoção ganha um
segundo passo com o emblema do elo novo.

## 11. Nova economia de XP

O problema atual é que o XP é quase binário. A proposta soma parcelas pequenas,
nenhuma delas manipulável por alongar a partida:

```
XP = base(modo) + vitória + desempenho + primeira do dia
```

| Parcela | Casual | Bot | Ranked (série) |
|---|---|---|---|
| base | 15 | 8 | 40 |
| vitória | +25 | +12 | +60 |
| por herói vivo | +8 | +4 | +10 |
| 2 a 0 | — | — | +25 |
| primeira vitória do dia | +50 | +50 | +50 |

Nada paga por duração, por dano bruto nem por número de ataques, que é o item 21.
Herói vivo é a única métrica de desempenho e ela **encurta** a partida em vez de
alongá-la.

## 12. Nova economia de Coins

Mais apertada que o XP, como o item 22 pede:

| Evento | Coins |
|---|---|
| vitória casual | 25 |
| vitória contra bot | 10 |
| série ranqueada concluída | 40 |
| vitória na série | +60 |
| promoção de elo | 250 |
| primeira vitória do dia | 100 |

Derrota não paga moeda em nenhum modo. A vitória contra bot cai de 50 para 10,
que é o que fecha o farm em confronto fácil repetido.

**Isto é um nerf de economia** e afeta quem já joga. Precisa da sua confirmação.

## 13. Abandono e reconexão

| Situação | Efeito |
|---|---|
| Caiu e voltou dentro da janela | série continua de onde parou |
| Caiu e não voltou | perde a série, adversário ganha PDL normal |
| Saiu pelo botão | **perde a série na hora**, sem esperar |
| Saiu com a série já decidida | nada muda, resultado já processado |

Quem abandona recebe XP e moedas **de derrota**, nunca de conclusão.

O caminho de saída deliberada passa a chamar a mesma função do
`ForfeitDisconnected`, que é a correção do P1 pendente da auditoria.

## 14. Alterações por arquivo

| Arquivo | Mudança |
|---|---|
| `GameStartTrigger.server.luau` | pad dourado, ação `rankedQueue`, portão de nível |
| `LobbyZoneBuilder.luau` | o terceiro pad ao lado dos dois existentes |
| `MatchManager.luau` | `rules.resolve = "series"`, expor o reinício para o serviço, corrigir o abandono |
| `Progression.luau` | as novas parcelas de XP e moedas |
| `LeaderboardService.luau` | ordenar por PDL em vez de vitórias |
| `BattleClient.client.luau` | indicador MD3 no HUD |
| `LobbyMenu.client.luau` | Ranked bloqueado abaixo do nível 5 |

## 15. Riscos

- **Re-draft entre games.** O `RestartMatch` reexecuta o posicionamento. Numa
  série isso triplica o tempo de preparo. Decisão sua, no fim do documento.
- **Fila vazia.** Com poucos jogadores online o Ranked não pareia. A banda que
  abre depois de 60s ajuda, mas em servidor vazio não há solução.
- **Inflação de MMR.** Sem decaimento, quem para de jogar congela alto. Aceitável
  na primeira versão.
- **O nerf de moedas** muda o que jogadores atuais já esperam ganhar.
- **Fim de série durante uma cinemática.** A câmera de finalização e a tela de
  resultado da série competem. O mesmo bastão que já existe na câmera resolve.

## 16. Plano de implementação

1. `Ranked.luau` puro, com as fórmulas, e a tabela-verdade no `CoreChecks`.
   Não toca em nada que roda.
2. `RankedStore.luau`, molde do `FightStore`.
3. Pad dourado e portão de nível. Já dá pra ver no lobby.
4. `RankedService.luau`: fila com bandas e a série sem UI nova.
5. Resultado da série, PDL, MMR e a correção do abandono.
6. Tela VS e indicador MD3.
7. Economia nova de XP e moedas.
8. Telemetria.

As etapas 1 e 2 não afetam nada em produção. O risco começa na 4.

## 17. Critérios de aceitação

- Nível 4 vê Ranked bloqueado e o servidor recusa a entrada na fila.
- Dois jogadores com MMR próximo pareiam em menos de 15s.
- Série termina em 2 a 0 ou 2 a 1, e o PDL muda **uma vez só**.
- 87 + 18 vira Silver 5. 8 - 15 vira Bronze 93.
- Nada do Game 1 aparece no Game 2.
- Game 2 começa com quem não começou o Game 1.
- Reenviar o remote de fim de série não paga PDL de novo.
- Sair pelo botão em ranqueada conta derrota.
- Casual, campanha e desafios não mudam de comportamento.

---

# Decisões que preciso de você

**Ritmo:** confirmado 30 segundos por turno na ranqueada (`GameConfig.RANKED_TURN_TIME_LIMIT`).
O relógio virou valor por partida, em `rules.turnSeconds`; o casual segue em 60.

**A. Draft a cada game?** O `RestartMatch` hoje refaz o posicionamento. Recomendo
manter o draft só no Game 1 e nos seguintes reposicionar o mesmo time nas casas
de largada: a série anda mais rápido e a composição escolhida vira parte da
estratégia da série. A alternativa é redraftar tudo, que dá contra-escolha mas
triplica o tempo parado.

**B. O nerf de moedas.** A vitória contra bot cai de 50 para 10. É o que fecha o
farm, mas muda o que os jogadores atuais já esperam. Confirma?

**C. Master.** Confirma o PDL acumulando sem teto lá dentro, exibido como
"Master 340"?
