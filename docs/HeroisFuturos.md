# Heróis futuros — ideias em aberto

Caderno de ideias de heróis que ainda **não** estão no jogo. Cada uma anota o conceito,
a mecânica proposta, **onde já existe código parecido** (pra saber o tamanho real do
trabalho) e as perguntas que ficaram em aberto.

Nada aqui está implementado. Quando uma ideia vira herói de verdade, ela sai deste
arquivo e vira ficha em [ArteDosHerois.md](ArteDosHerois.md) + entrada no
`HeroData.CATALOG`.

**Já saiu daqui:** Lucy (irmã do Karo, suporte de fogo) — implementada, id 17. Zeff
(controle de posicionamento, `gustPush`) — implementado, id 18.

---

## 1. O Homem-Bomba

**Conceito:** vida baixa, ataque baixo. O valor dele não é o que faz vivo — é o que
acontece quando morre. O jogo ideal é levá-lo pro meio do time inimigo e deixar morrer
lá.

**Estética:** em aberto (o usuário ainda está pensando).

**Mecânica proposta:**
- **Estopim** — ao morrer, causa 10 de dano em todos os inimigos a 1 casa de distância.

**Precedente no código:** `Skills.iceStorm` (Kor) é literalmente essa forma —
`triggers = { "onDie" }` + laço em `GetEnemiesInRange(ctx.hero, 1)`. Trocar
`Freeze(...)` por `ApplyDamage(...)` já seria a habilidade inteira. Trabalho baixo.

**O número a vigiar — 10 é muito alto:** o elenco tem vida entre 14 (Nash/Noctin) e 40
(Golem), e a maioria fica em 18–23. 10 de dano **mata ou quase mata quase todo mundo**,
e num 3v3 com os três inimigos colados isso é 30 de dano de uma vez — um wipe de time
inteiro numa morte só. Provavelmente vira a jogada dominante da partida. Sugestão: começar
mais baixo (5–6) e subir se parecer fraco, em vez do contrário.

**"E se o inimigo simplesmente não matá-lo?" — problema resolvido, não precisa de
mecânica extra.** Chegamos a levantar isso como buraco de design, mas o jogo já dá a
ele duas formas de morrer sem depender da vontade do inimigo:

1. **Contra-ataque.** Ele ataca, o alvo revida, ele apanha — parado exatamente onde
   quis. Com vida baixa, isso o mata em poucos turnos **no lugar que ele escolheu**.
   Ele se detona sozinho; ninguém precisa cooperar. (Confirmado em
   `MatchManager.PerformAttack`: o revide sai sempre que
   `Distance(alvo, atacante) <= alvo.attackRange`.)
2. **Rastro de fogo de um Karo inimigo.** Fogo do outro lado causa `FLAME_DAMAGE` em
   quem atravessa — dano que ele nem precisa provocar.

Dá também pra somar veneno, Morte Súbita e maldição de túmulo. Ou seja: ignorá-lo não
funciona, e ele não precisa de "pavio" nenhum. **Uma habilidade só basta.**

**Detalhe que afeta o ritmo:** só existe **um contra-ataque por turno no total** da
partida (`match.turn.counterAttack`), não um por golpe. Então ele apanha no máximo um
revide por turno — a detonação leva alguns turnos pra chegar, não é imediata.

---

## 2. O Invocador (tipo Yorick)

**Conceito:** colhe as almas dos que morrem em campo e as põe pra lutar.

**Mecânica proposta:**
- **Colheita de Almas** — quando um herói (de qualquer lado) morre a até 2 casas dele,
  invoca uma Alma (1 de ataque / 1 de vida) numa casa livre adjacente. Teto de **2 almas
  vivas** ao mesmo tempo.
- **Última Vontade** — quando uma Alma morre, causa 1 de dano em quem deu o golpe final.
- **Elo dos Mortos** — enquanto tiver ao menos 1 Alma viva, ele recebe 1 a menos de dano.

**Decisão de design importante:** as almas **não têm turno próprio** — não andam nem
atacam sozinhas. Só ocupam casa e revidam quando atacadas (o contra-ataque já é
automático pra qualquer herói). Isso evita ter que inventar um sistema de turno pra
unidades secundárias.

**Precedente no código:** `Skills.shatter` (Golem) já invoca heróis no meio da partida
via `ctx.api.Summon(...)`, com as fichas em `HeroData.SUMMONS` (fora do `CATALOG`, pra
não aparecerem na loja/draft). O gatilho é que muda: lá é a própria morte, aqui é a
morte **de outro herói por perto**. Trabalho médio.

**Por que o teto de 2:** o tabuleiro é pequeno e o time tem 3 heróis
(`HEROES_PER_PLAYER`). Sem teto, uma partida longa vira um tabuleiro entupido de bonecos
1/1 — deixa de ser estratégia e vira bagunça.

---

## 3. O Velocista

**Conceito:** quanto mais longe corre em linha reta, mais forte o golpe. Sem correr,
quase não machuca.

**Mecânica proposta:**
- `Sprint` (a passiva de movimento que já existe — 3 casas em vez de 2)
- **Investida** — se atacar no mesmo turno em que se moveu em **linha reta** (sem virar
  no meio do caminho), ganha +1 de ataque por casa percorrida, até um teto. Empréstimo
  de 1 turno, não acumula.
- **Fuga** — o ataque que sai de uma corrida em linha reta não pode ser revidado.

**Precedente no código:** `Skills.flameFury` (Karo) é exatamente esse formato de bônus
temporário por casa percorrida — conta casas, multiplica por uma constante, aplica teto,
guarda num status effect de 1 turno que o `ProcessStatusEffects` devolve sozinho. Trocar
"casa em chamas" por "casa em linha reta" é a mudança. O "não pode ser revidado" já
existe na Emboscada do Nash. Trabalho baixo/médio.

**Ficha sugerida:** ataque base bem baixo (1–2), vida baixa/média. Ele é glass cannon:
alinhar a corrida é a jogada inteira, e o adversário tem contra-jogo se posicionando pra
cortar a linha reta.

---

## 4. O Elétrico

**Conceito:** não mata rápido — rouba o turno do inimigo.

**Preocupação levantada pelo usuário (e respeitada aqui):** o jogo já tem bastante dano
em área (Karo, Blade) e já tem bastante status empilhando na UI da partida. Então esta
proposta é **single-target de propósito** e **não usa o sistema de status effects**.

**Mecânica proposta:**
- **Choque Acumulado** — cada ataque dele no mesmo alvo empilha 1 carga. Ao chegar em 3,
  o alvo fica **Paralisado**: perde a ação inteira do turno seguinte, e as cargas zeram.
- `Ranged` (eletricidade à distância combina, e o diferencia de Karo/Blade que são corpo
  a corpo).

**Precedente no código:** o contador de golpes da lápide (`GRAVE_HITS`) e do barril
(`BARREL_HITS`) já são exatamente "N golpes até acontecer algo", com o número aparecendo
num crachá pequeno — e explicitamente **contam golpes, não dano** (um golpe de 1 vale o
mesmo que um de 5). Reaproveitar esse padrão num alvo vivo evita criar um tipo de status
novo e um ícone novo na UI. Trabalho médio.

**Ideia cortada de propósito:** um ataque em corrente que também acerta um vizinho do
paralisado. Bate de frente com a preocupação de "já tem AoE demais" — fica registrado
como descartado, não esquecido.

---

## 5. A Sniper

**Conceito:** alcance longo, mas só em linha reta. Quanto mais longe o alvo, mais dano.

**Mecânica proposta:**
- **Linha de Tiro** — só pode atacar alvo alinhado com ela numa das 6 direções retas do
  hexágono. Alcance maior que o `Ranged` comum (ex.: 5 casas em vez de 3), mas *só*
  nessas linhas. Inimigo fora do alinhamento simplesmente não é alvo válido, mesmo perto.
- **Tiro Longo** — dano cresce com a distância, em **degraus fixos** (ex.: até 2 casas,
  normal; 3–4, +1; 5, +2).

**Precedente no código:** a geometria de linha reta já existe (`HexGrid.GetLineBeyond`,
usada pelo `beyondFront` do Blade e pelo `rage` do Bramm) — aqui ela vira **filtro de
alvo válido** em vez de "estende o golpe". O alcance próprio sai do campo `attackRange`
da ficha, que já existe justamente pra exceções (`HeroData.GetAttackRange`). Trabalho médio.

**Sobre a preocupação de UI que o usuário levantou** ("como explicar o dano variável na
tela?"): **não precisa mostrar**. O jogo já tem precedente disso — o dano dobrado do Kor
contra alvo congelado (`FREEZE_DAMAGE_MULTIPLIER`) não aparece em prévia nenhuma; o
crachá mostra sempre o ataque base e o dobro só acontece no impacto. A Sniper pode seguir
igual.

**Por que degraus em vez de fórmula contínua:** "sem limite, quanto mais longe mais dano"
não tem teto — em mapa grande vira abate garantido, não dá pra balancear, e não cabe numa
frase de habilidade (o padrão do `SKILL_INFO` é sempre "causa +X quando Y"). Todo bônus
progressivo que já existe no jogo tem teto (`FLAME_FURY_MAX_ATTACK`,
`MERLIN_DEATH_ATTACK_MAX`).

---

## Notas gerais

- **Nomes:** todos provisórios. O elenco usa nomes próprios curtos (Ralph, Vic, Kor,
  Nash, Karo, Lucy, Zeff), não títulos genéricos.
- **Nenhum destes tem IA de bot pensada ainda.** Vale lembrar que o próprio Karo já não
  tem — o `BotBrain` não sabe usar o rastro de fogo dele estrategicamente. Então nascer
  sem IA otimizada é o normal da casa, não regressão.
- **Onde as habilidades vivem:** mecânica em `src/server/Modules/Skills.luau`, números em
  `src/shared/Modules/GameConfig.luau`, ficha e texto de UI em
  `src/shared/Modules/HeroData.luau`, confronto da campanha em
  `src/shared/Modules/Campaign.luau`.
