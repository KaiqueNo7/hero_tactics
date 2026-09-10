# Auditoria de segurança — Hero Tactics

Leitura completa do código em disco, sem alterações. Data: 2026-09-10.
Branch: `feat/casas-promocao`.

---

## Resumo executivo

**O princípio fundamental do pedido já está atendido.** Li todos os handlers de
`OnServerEvent` do projeto. Não existe nenhum caminho em que o cliente informe
dano, vida, atributo, posição, moeda, XP ou vencedor. O contrato de todos os
remotes é intenção pura: uids e uma string de casa.

Não encontrei nenhuma vulnerabilidade P0. Encontrei **uma P1**, que é
justamente sobre Ranked e precisa ser resolvida antes da expansão, e três itens
menores.

A parte mais cara do seu pedido, a migração para servidor autoritativo, não
precisa acontecer: a arquitetura já é assim. O trabalho real é menor do que o
escopo do pedido sugere.

---

## A. Arquitetura atual

Existem cinco RemoteEvents. Só três recebem chamada do cliente.

| Remote | Direção | Handler |
|---|---|---|
| `GameAction` | cliente → servidor, e servidor → cliente | `GameStartTrigger:467` |
| `PlaceHero` | cliente → servidor | `GameStartTrigger:462` |
| `Tutorial` (`Tutorial.REMOTE_NAME`) | cliente → servidor | `GameStartTrigger:506` |
| `MatchUpdate` | só servidor → cliente | nenhum |
| `BoardReady` | só servidor → cliente | nenhum |
| `RosterUpdate` | só servidor → cliente | nenhum |
| `LobbyStatus` | só servidor → cliente | nenhum |

`GameAction` é um despachante único com quinze ações. Todas passam antes por
`AllowAction`, um limitador de doze ações por segundo por jogador.

O estado verdadeiro da partida vive em `matches[matchId]` dentro do
`MatchManager`, que roda no servidor. O cliente recebe um snapshot por
jogador via `MatchUpdate` e desenha a partir dele. `BattleClient` não guarda
nem calcula nada de gameplay: `heroByUid` lê o snapshot, e `paint` só colore
casas.

**A partida não é escolhida pelo cliente.** Toda entrada começa com
`MatchOfPlayer(player)`, que varre as partidas ativas procurando o lado cujo
`side.player` é aquele `Player`. O cliente nunca envia um `MatchId`, então o
item 6 do seu pedido está satisfeito por construção e não é falsificável.

---

## B. Superfície de ataque

Tudo que um cliente comprometido consegue enviar:

```
GameAction:FireServer(action, arg1, arg2, arg3)
PlaceHero:FireServer(dataId, hexId)
Tutorial:FireServer(lessonId)
```

Quinze ações em `GameAction`: `move`, `attack`, `endTurn`, `replay`,
`resurrect`, `allyChoice`, `leaveMatch`, `matchLog`, `cancelQueue`, `queue`,
`claimRewards`, `fight`, `challenge`, `sandbox`.

Nenhuma delas aceita um número que vire estado. Os únicos números que
atravessam a fronteira são `dataId` em `PlaceHero` e `heroId`/`index` em
`challenge`, e os três são validados contra catálogos do servidor.

---

## C. Vulnerabilidades

| Sistema | Vulnerabilidade | Severidade | Exploit possível | Correção |
|---|---|---|---|---|
| Ranked / abandono | `AwardAbandon` dá XP de vitória a quem fica, mas nunca chama `LeaderboardService.RecordWin` e não penaliza quem sai | **P1 — High** | Perdendo uma PvP ranqueada, sair pela ação `leaveMatch` nega ao adversário a vitória no ranking. Sair de propósito é melhor que cair de conexão, porque `ForfeitDisconnected` registra a vitória e `AwardAbandon` não | Tratar saída deliberada como derrota: mesmo caminho do `ForfeitDisconnected`, com `rankingDone` e `IsRankedPvp` |
| Rate limit | Orçamento único de 12/s cobre todas as ações, inclusive `matchLog`, que devolve até 400 entradas de log | P2 — Medium | 12 serializações completas do log por segundo por jogador, multiplicado por jogadores, como amplificador barato de CPU e banda | Orçamento por ação, com teto muito menor para leituras pesadas |
| Auditoria | Nenhum log de segurança existe. `AllowAction` descarta em silêncio e `Reject` só avisa o cliente | P2 — Medium | Abuso sistemático é invisível. Não dá para saber se alguém está sondando | Contador por jogador de recusas, com amostragem no output |
| Recompensa | `RewardQueueService.Take` lê e depois limpa, com uma chamada de DataStore que cede no meio | P2 — Medium | Dois `claimRewards` na mesma janela leem antes de qualquer um limpar, e a comemoração aparece duas vezes | `SafeStore.Update` atômico em vez de Get seguido de Set |
| Sandbox | `IsDev(player)` é `ENABLED and player ~= nil`, e não consulta `DevAccess` como o CLAUDE.md afirma | P3 — Low | Nenhum hoje: o módulo inteiro vira no-op fora do Studio | Fazer o código cumprir o contrato documentado |
| Acesso | `DevAccess.UNLOCK_FOR_OWNER_FRIENDS` continua `true` | P3 — Low | Amigos do dono jogam com o elenco inteiro | Virar para `false` antes do lançamento, como o próprio arquivo manda |

### Sobre a P1

É o único item que muda resultado competitivo, e chega pelo botão normal de
sair da partida. Não precisa de executor nem de script. Como o ranking hoje é
uma contagem de vitórias, negar a vitória do adversário é o exploit inteiro.

`ForfeitDisconnected` já tem a forma certa: checa `IsRankedPvp`, protege com
`match.rankingDone` e registra. O caminho de saída deliberada precisa da mesma
coisa.

---

## D. O que já é exclusivo do servidor

Verificado linha a linha:

- **Atributos.** `CreateHero` monta o herói a partir de `HeroData.GetById(dataId)`.
  `attack`, `maxHp`, `attackRange` e `moveRange` nunca vêm do remote.
- **Dano.** `PerformAttack` calcula tudo. A skill mais complexa recebe um `ctx`
  montado pelo servidor e não tem acesso ao remote.
- **Posição.** `hero.position` e `match.occupied` só mudam dentro do
  `MatchManager`. `HeroView.SetPosition` é consequência, nunca causa. Um herói
  arrastado por exploit local não muda casa lógica nenhuma.
- **Turno.** `match.turn`, `turn.moved`, `turn.attacked`, `turn.bonusMove`,
  `turnToken` e `sceneToken` são todos internos.
- **Posse de herói.** `side.unlockedIds = UnlockedIdsFor(player)`, que vem do
  `HeroUnlockService`. `PlaceHero` recusa `dataId` fora dessa lista.
- **Economia.** Moeda e XP saem de `Progression.MatchCoins(result)` e
  `Progression.MatchReward(result, survivors, vsBot)`, com `result` e
  `survivors` derivados do tabuleiro.
- **Furtividade.** O snapshot é montado por espectador e o Nash invisível sai
  da lista do adversário. Não há vazamento a corrigir.

### A única exceção deliberada

`TutorialService.MarkSeen` confia no cliente para dizer que viu uma lição. Está
documentado e é seguro: valida tipo, valida contra `Tutorial.GetLesson`, e é
idempotente. O pior caso é alguém pular o próprio tutorial.

---

## E. Remote contract

O contrato que o código já aplica hoje.

| Ação | Payload | Validação existente |
|---|---|---|
| `move` | `heroUid: string`, `hexId: string` | `AuthorizeAction`, `CanMove`, tipo, `HexGrid.Exists`, `IsFree`, `FindPath` com alcance |
| `attack` | `attackerUid: string`, `targetUid: string` | `AuthorizeAction`, já atacou, alvo vivo, time inimigo, furtivo, alcance, Taunt, corrente |
| `endTurn` | nenhum | fase, `busy`, suspenso, lado é do jogador |
| `resurrect` | `heroUid: string` | promoção pendente, dono, opção na lista |
| `allyChoice` | `heroUid: string` | oferta aberta, dono, alvo na lista, fonte viva e não incapacitada |
| `PlaceHero` | `dataId: number`, `hexId: string` | fase, vez de posicionar, teto, tipos, catálogo, sem repetido, desbloqueado, zona, casa livre |
| `challenge` | `command: string`, `heroId`, `index` | `tonumber`, desafio existe, desbloqueado, não está em partida |
| `Tutorial` | `lessonId: string` | tipo, lista branca, idempotente |

Os uids chegam como string arbitrária e são usados apenas como chave de tabela,
então lixo vira `nil` e cai nas guardas. Uma table gigante ou um `Instance` como
uid também vira `nil` na indexação. `NaN` e `inf` não têm por onde entrar: os
dois números aceitos passam por `type(x) ~= "number"` seguido de consulta a
catálogo, e nenhum vira aritmética.

---

## F. Rate limits recomendados

O atual é um só, de 12/s, para tudo. Sugestão de separar por peso:

| Grupo | Teto | Razão |
|---|---|---|
| `move`, `attack`, `allyChoice`, `resurrect`, `endTurn` | 8/s | folga larga para duplo clique e latência |
| `queue`, `fight`, `challenge`, `leaveMatch`, `replay` | 2/s | são transições, não ações de jogo |
| `matchLog`, `claimRewards` | 1 a cada 2s | leem e serializam bastante |

Manter o descarte silencioso para excesso pequeno. Contar as recusas por
jogador e só reportar quando o padrão for impossível para um humano.

---

## G. State machine

Ela já existe, distribuída em vez de nomeada: `match.phase` vale `placement`,
`battle` ou `finished`, e `AuthorizeAction` é o guarda único que consulta
`phase`, `busy`, `suspendedAt` e `pendingPromotion`.

Formalizar em um módulo separado é possível, mas hoje seria trocar um guarda
central que funciona por um sistema com mais peças. **Não recomendo antes de
resolver a P1.** O que vale reforçar é o item 26 do seu pedido: nenhuma ação
depois de `finished`. Isso já é verdade para `move`, `attack`, `allyChoice` e
`endTurn`, todos barrados por `AuthorizeAction`.

`match.busy` já é o `ActionLock` do item 25. Ele é ligado durante contra-ataque,
`deathHold`, andar casa a casa e a Troca do Shin.

---

## H. Segurança da economia

Moeda e XP são creditados no momento em que são ganhos, dentro do servidor. A
fila de recompensa guarda apenas o que ainda **não foi comemorado**, e por isso
uma repetição do `claimRewards` mostra a festa de novo sem creditar nada. O
único conserto é o da corrida citada em C.

`CoinService` é o único lugar autorizado a registrar `ProcessReceipt`, e é ele
quem decide quanto vale cada recibo. O cliente só abre o prompt.

---

## I. Segurança do Ranked

**Importante:** PDL, MMR, série e elo não existem no código. `LeaderboardService`
tem exatamente duas funções, `RecordWin` e `GetTop`. O Ranked de hoje é uma
contagem de vitórias.

Então os itens 29 e 30 do seu pedido são, em quase tudo, requisitos para um
sistema a construir, e não achados de auditoria. O que já existe e está correto:
o vencedor é decidido por `CheckGameOver` lendo heróis vivos, e não há nenhum
remote que aceite um resultado.

O que precisa entrar junto com o PDL, quando ele for construído:

- Saída deliberada conta como derrota (a P1).
- `rankingDone` estendido para cobrir toda escrita de ranking, não só a vitória.
- Chave de idempotência por `MatchId` na escrita, para que um retry de DataStore
  não credite duas vezes.

---

## J. Plano de migração

Curto, porque a base já é autoritativa.

1. **P1, antes de expandir Ranked.** Saída deliberada em PvP ranqueada passa pelo
   mesmo caminho do `ForfeitDisconnected`. Uma função só, chamada pelos dois.
2. **P2 rate limit.** Trocar o orçamento único por uma tabela de tetos por ação.
   Cerca de quinze linhas no `GameStartTrigger`.
3. **P2 auditoria.** Um contador por jogador dentro do próprio `AllowAction`,
   com print amostrado. Sem serviço novo.
4. **P2 recompensa.** `Take` com `SafeStore.Update` atômico.
5. **P3.** `IsDev` consultando `DevAccess`, e o flag de amigos do dono para
   `false` no lançamento.

Nada disso muda o contrato dos remotes, então o cliente não precisa ser tocado e
não há risco de quebrar partida em andamento.

---

## Respostas diretas aos itens em aberto

**Item 5, ActionSequence.** Não recomendo. O servidor já rejeita repetição por
estado, e não por nonce: um `move` repetido cai em `CanMove` porque
`turn.moved[uid]` ficou marcado, um `attack` repetido cai em
`turn.attacked[uid]`, e um `allyChoice` repetido cai porque `pendingAlly` virou
`nil`. Um contador de sequência seria uma segunda fonte de verdade para algo que
o estado da partida já responde, com o custo de dessincronizar em reconexão.
Onde replay realmente funcionaria, o estado já barra.

**Item 22, duplo clique.** Já resolvido pelo mesmo mecanismo. A segunda ação é
ignorada em silêncio, sem punição.

**Item 36, honeypots.** Não recomendo agora. A vantagem é sinal de alta
confiança: só um executor chama um remote que nenhuma UI usa. As desvantagens
são três, e pesam mais nesta fase. Aumenta a superfície que você precisa manter
segura. Gera falso positivo quando alguém legítimo usa uma ferramenta de
inspeção. E, principalmente, custa tempo que rende muito mais na P1, que é um
buraco real e não um detector.

**Item 39, testes de exploit.** Boa parte da sua lista já é impossível por
construção, e o teste correspondente testaria um caminho que não existe.
`Attack = 999`, `HP = 999`, `MoveDistance` impossível, forçar vitória, forçar
Coins, XP ou PDL: nenhum desses valores tem remote por onde entrar. Vale
escrever testes para o que é alcançável: ação fora do turno, ataque com herói
morto, herói de outro jogador, alvo fora da partida, `endTurn` duplicado,
`claimRewards` duplicado e o abandono ranqueado.

**Item 37, performance.** A validação atual já usa o estado da própria partida.
`MatchOfPlayer` varre `matches`, que tem tamanho de dezenas, e nenhuma validação
faz scan de Workspace. Não vi risco aqui.

**Item 38, modularização.** O `MatchManager` está em 3300 linhas, mas a
segurança dele já está concentrada em `AuthorizeAction` e `AllowAction`, que
são pequenos e legíveis. Quebrar em `RequestValidator`, `ActionValidator` e
`RateLimiter` agora adicionaria três arquivos para mover código que já é curto.
Recomendo esperar até que a segunda ou terceira regra nova precise do mesmo
lugar.

---

## K. Testes propostos

Alcançáveis e que valem automação no `CoreChecks`:

| Caso | Esperado |
|---|---|
| `move` com herói do adversário | recusado por `AuthorizeAction` |
| `attack` fora do turno | recusado |
| `attack` com herói morto | recusado |
| `attack` no mesmo alvo duas vezes com Zaro | recusado por `ChainHits` |
| `endTurn` duas vezes seguidas | segunda não faz nada |
| `PlaceHero` com herói não desbloqueado | recusado |
| `PlaceHero` com herói repetido | recusado |
| `PlaceHero` fora da zona de largada | recusado |
| `allyChoice` sem oferta aberta | recusado |
| abandono em PvP ranqueada | vitória registrada para quem ficou |

Os quatro últimos exigem uma partida montada, então cabem melhor num teste
manual roteirizado do que no harness atual.
