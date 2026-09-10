# Estrelas nas batalhas contra bots — análise e proposta

Leitura do código em disco, sem alterações. 2026-09-10.

---

## Resumo

A conclusão principal é que **quase tudo que este sistema precisa já existe no
projeto**, construído para os desafios de herói. Não é preciso criar um
`BattleStarRules` novo: o `Objectives` já é o avaliador data-driven pedido no
item "não hardcode", e o `ChallengeStore` já é o save de melhor resultado com
recompensa só na primeira conquista.

Encontrei **um conflito real** entre a regra proposta e o modelo de estrelas
existente, com uma solução limpa, e **duas decisões de design** que preciso que
você tome antes de eu implementar.

---

## 1. Análise do sistema atual

### Campanha e batalhas contra bots

`Campaign.FIGHTS` é a lista de confrontos. Cada entrada tem `hero` (o prêmio),
`group`, `team` (o time do bot) e `island`. Não existe registro de "bots
derrotados": vencer o confronto X e possuir o herói X são a mesma coisa, e quem
guarda isso é o `HeroUnlockService`. Toda a progressão (grupo liberado,
confronto feito, PvP liberado) é derivada dessa lista única.

A partida contra bot é uma partida normal com `match.fight` preenchido e
`match.vsBot = true`.

### Turnos

`match.turn.number` **é um contador de rodada, não de jogada**. A linha que
manda é `nextNumber = match.turn.number + (wasStarter and 0 or 1)`: o número só
avança quando o segundo jogador encerra. Os dois lados agem dentro do mesmo
número.

Isso resolve o edge case do seu pedido sem ambiguidade nenhuma, e a resposta é
melhor do que a pergunta sugere: não existe "meio turno 9".

### Condição de vitória

`CheckGameOver` conta heróis vivos dos dois lados e encerra quando um chega a
zero. Já existe um despachante de regras: `match.rules.resolve` vale
`elimination`, `manual` ou uma chave em `MatchManager.Resolvers`. Os desafios de
herói registram `MatchManager.Resolvers.challenge`.

### Promoção e revive

`side.promotionUsed` já existe, é por lado, nasce `false` e vira `true` na
ressurreição bem-sucedida. Nunca é revertido durante a partida.

**Isso já é exatamente o `PromotionUsed` que você pediu.** Não precisa de campo
novo.

### Heróis vivos

`LivingHeroesOf(match, ownerId)` devolve todos os vivos do lado, **incluindo
invocados**. Para estrelas isso não serve direto (ver decisão B).

### Save

`ChallengeStore` guarda por jogador uma linha por herói com `stars` e `turns`
por índice. O `Record` faz `row.stars[index] = math.max(previous, stars)` e
devolve `gained = math.max(0, stars - previous)`.

**Isso já é o "nunca substituir resultado melhor por pior" e o "recompensa só na
primeira vez".** O padrão está pronto e testado.

### UI de vitória

`BattleClient` tem o painel de resultado com a palavra VITÓRIA, um subtítulo que
hoje mostra só `"%d turnos"`, e os cards do time. O `summary` do snapshot já
carrega `turns`. É onde as estrelas entram.

### Seleção de fases

O lobby desenha um quadrado por confronto (`buildFightSquare`) e já sabe mostrar
progresso de estrelas: a aba de desafios usa `starLine(earned)`, que hoje é o
caractere `★` repetido.

---

## 2. Regra formal

Traduzindo o seu pedido para condições verificáveis, com `T` = `turn.number` no
momento da vitória, `A` = heróis principais vivos, `P` = promoção usada:

```
vitória             → pelo menos 1 estrela
2ª estrela          → A >= 2  e  não P
3ª estrela          → T <= 9  e  A == 3  e  não P
```

`T <= 9` é literalmente "antes do turno 10", porque o número é de rodada.

---

## 3. Precedência — e o conflito

**O conflito.** O `StarsEarned` que já existe é **aditivo**: começa em 1 e soma
uma por condição cumprida. A sua regra é **em degraus com teto**: promoção
limita a 1 estrela mesmo que as outras condições estejam cumpridas.

No modelo aditivo puro, "venceu no turno 8, 3 vivos, usou promoção" daria 2
estrelas (base + a de 3 estrelas), e o seu documento diz que deve dar 1.

**A solução.** Colocar "não usou promoção" nas **duas** condições, e não só na
de 2 estrelas. Aí o modelo aditivo produz exatamente o resultado em degraus, sem
precisar de teto nenhum. Verificado nos oito casos:

| T <= 9 | A | P | 2ª | 3ª | Total | Esperado |
|---|---|---|---|---|---|---|
| sim | 3 | não | ✓ | ✓ | 3 | 3 |
| sim | 3 | sim | ✗ | ✗ | 1 | 1 |
| não | 3 | não | ✓ | ✗ | 2 | 2 |
| não | 3 | sim | ✗ | ✗ | 1 | 1 |
| sim | 2 | não | ✓ | ✗ | 2 | 2 |
| sim | 2 | sim | ✗ | ✗ | 1 | 1 |
| qualquer | 1 | não | ✗ | ✗ | 1 | 1 |
| qualquer | 1 | sim | ✗ | ✗ | 1 | 1 |

Bate em todos. **Nenhuma máquina de precedência precisa ser escrita**, e o
avaliador de estrelas dos desafios serve sem alteração.

---

## 4. Estrutura de dados

Reaproveitando o que existe. Duas verificações novas no `Objectives`:

```lua
CHECKS.heroesAlive   -- { kind = "heroesAlive", count = 3 }
CHECKS.noPromotion   -- { kind = "noPromotion" }
```

E a regra padrão num lugar só, aplicada a todo confronto que não declare a sua:

```lua
Campaign.DEFAULT_STARS = {
    { text = "Terminar com 2 heróis de pé, sem usar a Casa de Promoção",
      check = { kind = "allOf", checks = {
          { kind = "heroesAlive", count = 2 },
          { kind = "noPromotion" },
      } } },
    { text = "Vencer antes do turno 10 com o time inteiro vivo",
      check = { kind = "allOf", checks = {
          { kind = "withinTurns", turns = 9 },
          { kind = "heroesAlive", count = 3 },
          { kind = "noPromotion" },
      } } },
}
```

`allOf` é a terceira verificação nova, e é o que dá a flexibilidade futura que
você pediu sem inventar dezenas de condições: qualquer confronto pode declarar
`stars = { ... }` próprio e sair do padrão. "Win in 7 turns" já é expressável
hoje com `withinTurns`.

`withinTurns` já existe e já compara `<=`.

---

## 5. Integração com a campanha

O quadrado do confronto no lobby ganha as estrelas conquistadas, do mesmo jeito
que a aba de desafios já mostra. Nenhuma regra de desbloqueio muda: continua
sendo posse do herói, e estrela não tranca nada.

---

## 6. Integração com o save

`ChallengeStore` guarda por `heroId` e `index`. Um confronto de campanha também
é identificado por um herói (o prêmio) e não tem índice.

Duas opções:

- **Reusar o `ChallengeStore`** com um índice reservado. Barato, mas mistura duas
  coisas diferentes na mesma linha e vai confundir mais tarde.
- **Um `FightStore` novo**, cópia enxuta do `ChallengeStore` com chave só por
  herói. Um arquivo a mais, sem ambiguidade.

Recomendo o segundo. O `ChallengeStore` tem cerca de 150 linhas e metade é
`Sanitize`, que dá para reaproveitar por cópia sem herdar o índice.

---

## 7. Integração com recompensa

O confronto já paga XP, moedas e o herói desbloqueado. As estrelas entram como
uma **segunda fonte, paga só nas estrelas novas**, exatamente como os desafios:

```lua
run.xp = gained * Campaign.XP_PER_STAR
```

Como `gained` vem do `max` do save, repetir a batalha com resultado igual ou pior
paga zero. Não há farm.

Todos os valores num lugar só, ao lado de `HeroChallenges.XP_PER_STAR`.

---

## 8. UI

**Tela de vitória.** Abaixo da palavra VITÓRIA, antes dos cards do time. Três
estrelas sempre desenhadas: as conquistadas acesas, as perdidas apagadas.

Embaixo, a lista de motivos, que é o que ensina a melhorar:

```
✓ Vitória
✓ Antes do turno 10
✗ Casa de Promoção usada
```

**O ícone.** Hoje o projeto desenha estrela como o caractere `★`. Para o visual
que você pediu, sem depender de asset novo: `TextLabel` com o glifo, `UIGradient`
dourado, `UIStroke` escuro para destacar do fundo, e um brilho por trás.

**A animação.** Uma por vez, com atraso entre elas: entra grande e transparente,
encolhe até o tamanho com `Back Out` (o estalo), gira poucos graus, e solta um
clarão que some. A estrela não conquistada entra apagada e sem som.

Se você tiver ou quiser subir um asset de estrela, é trocar o `TextLabel` por
`ImageLabel` e o resto da animação continua igual.

---

## 9. Casos especiais

| Caso | Comportamento com a regra proposta |
|---|---|
| Vitória no turno 9 | `T <= 9` verdadeiro, 3 estrelas possível |
| Vitória no turno 10 | falso, teto de 2 |
| Empate (morte simultânea) | `winner == "draw"`, sem vitória, zero estrelas |
| Veneno ou fogo mata na virada | `ProcessStatusEffects` roda antes do `CheckGameOver`, então o número de vivos já está correto |
| Promoção no mesmo turno da vitória | `promotionUsed` é marcado na ressurreição, que acontece antes; o teto vale |
| Revive seguido de vitória imediata | mesmo caso, teto de 1 |
| Herói revivido morre de novo | irrelevante: a marca não é revertida |
| Ralph | não tem revive próprio; o `firstPunch` não interage |
| Summons do Morn | não contam (decisão B) |
| Golem estilhaçado | **decisão B** |
| Morn em campo | **decisão A**, e é o caso mais sério |

---

## 10. Arquivos afetados

| Arquivo | Mudança |
|---|---|
| `src/server/Modules/Objectives.luau` | três verificações novas |
| `src/shared/Modules/Campaign.luau` | `DEFAULT_STARS`, `XP_PER_STAR`, `StarsFor(fight)` |
| `src/server/Modules/FightStore.luau` | novo, save de melhor resultado |
| `src/server/Modules/MatchManager.luau` | avaliar e publicar estrelas na vitória de `match.fight` |
| `src/client/BattleClient.client.luau` | estrelas e motivos na tela de vitória |
| `src/client/LobbyMenu.client.luau` | estrelas no quadrado do confronto |
| `src/dev/CoreChecks.server.luau` | tabela-verdade das oito combinações |

---

## 11. Possíveis bugs

- **Contagem durante a resolução.** As estrelas têm que ser avaliadas dentro do
  `CheckGameOver`, no mesmo instante em que o vencedor é decidido. Avaliar depois
  do `EndMatch` leria um tabuleiro já limpo.
- **Idempotência.** `CheckGameOver` pode ser chamado mais de uma vez. Precisa da
  mesma trava `rankingDone` que o ranking usa, senão as estrelas seriam gravadas
  duas vezes e o `gained` do segundo daria zero, mas o log sairia dobrado.
- **Partida sem jogador humano.** Bot contra bot e `BalanceSim` passam pelo mesmo
  `CheckGameOver`. Precisa sair cedo quando não há `side.player`.
- **`match.rules.progression`.** Desafio e sandbox desligam progressão; as
  estrelas de campanha têm que respeitar o mesmo flag.

---

## 12. Plano de implementação

1. `Objectives`: `heroesAlive`, `noPromotion`, `allOf`. Testável isolado.
2. `Campaign`: regra padrão e `StarsFor(fight)`.
3. `CoreChecks`: a tabela-verdade das oito combinações, antes de ligar no jogo.
4. `FightStore`: save e `Record` devolvendo `gained`.
5. `MatchManager`: avaliar na vitória, gravar, publicar no snapshot.
6. `BattleClient`: estrelas e motivos.
7. `LobbyMenu`: progresso no quadrado.

Os passos 1 a 4 não tocam em nada que já roda. O risco começa no 5.

---

## 13. Critérios de aceitação

- Vitória no turno 9, 3 vivos, sem promoção → 3 estrelas.
- Vitória no turno 10, 3 vivos, sem promoção → 2 estrelas.
- Vitória com 2 vivos, sem promoção → 2 estrelas.
- Qualquer vitória com promoção usada → 1 estrela.
- Derrota ou empate → nada gravado.
- Repetir com resultado pior → save mantém o melhor e paga zero.
- Regras de combate, turno, revive e promoção inalteradas.
- Cliente nunca envia estrela; o snapshot só recebe o resultado.

---

# Decisões que preciso de você

## A. Morn quebra a regra sem o jogador escolher

A passiva `lanternReturn` do Morn revive ele sozinho quando **qualquer** aliado
pisa na Casa de Promoção, e esse caminho **marca `promotionUsed = true`**. O
jogador não escolhe nada.

Ou seja: com Morn no time, encostar na Casa de Promoção derruba o teto para 1
estrela automaticamente. Isso é uma armadilha, não um desafio.

- **A1 (recomendo).** Separar "promoção deliberada" da automática. A marca das
  estrelas só é ligada no caminho em que o jogador escolhe um túmulo.
- **A2.** Aceitar como está, e o time com Morn joga com uma regra mais dura.

## B. O Golem estilhaçado conta como vivo?

O Golem morre, vira dois mini-golens e o túmulo dele fica **pendente** até o
último pedaço cair. No instante da vitória ele pode estar com `isAlive = false` e
ainda ter duas peças em campo.

- **B1 (recomendo).** Contar como vivo enquanto não foi enterrado, usando o
  `gravePending` que já existe. Combina com a ficha dele, que promete que ele
  morre duas vezes.
- **B2.** Contar como morto assim que estilhaça. Mais simples de explicar, mas
  torna o Golem uma escolha ruim para quem busca 3 estrelas.

Nos dois casos os invocados do Morn e os mini-golens **não** contam como
unidades próprias.

## C. Telemetria de retry

`botBattleStarted` e `retry` precisam de um contador que sobreviva entre
partidas, e hoje o `Tally` é por herói dentro de uma partida. Dá para somar no
`FightStore`, mas é campo novo no save.

Vale a pena na primeira versão, ou fica para quando você for olhar dificuldade?
