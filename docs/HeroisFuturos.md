# Heróis futuros — ideias em aberto

Caderno de ideias de heróis que ainda **não** estão no jogo. Cada uma anota o conceito,
a mecânica proposta, **onde já existe código parecido** (pra saber o tamanho real do
trabalho) e as perguntas que ficaram em aberto.

Nada aqui está implementado. Quando uma ideia vira herói de verdade, ela sai deste
arquivo e vira ficha em [ArteDosHerois.md](ArteDosHerois.md) + entrada no
`HeroData.CATALOG`.

**Já saiu daqui:** Lucy (irmã do Karo, suporte de fogo) — implementada, id 17.

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

## 2. Zeff, o do Vento ← **PRÓXIMO A IMPLEMENTAR** (desenho fechado)

**Conceito:** controle de posicionamento. Não mata — desmonta formação.

**Ficha:** ataque **2**, vida **17**, passiva `Sprint`, sem `Ranged`, sem `Taunt`.
Habilidade única: `gustPush` (Rajada).

### Estética

Referência escolhida: jovem lutador de vento, noite de lua cheia, paleta fria.

- **Cabelo liso e caído**, branco-prateado, franja repartida caindo sobre a testa e
  mechas emoldurando o rosto — corte tipo Light Yagami (*Death Note*), não espetado.
  Isso é o que mais o separa do Karo; ver a nota de leitura abaixo.
- **Pele muito clara**, quase branca. Ele é pálido por inteiro.
- **Olhos** brilhando num ciano pálido, **sem pupila visível**: dois pontos de luz.
- **Roupa** em camadas, azul-acinzentada clara, tipo quimono/manto: **gola muito alta e
  enrolada** cobrindo o pescoço e o queixo, com um **cachecol longo esvoaçando atrás**
  dele. É o cachecol que carrega o movimento na pose parada.
- **Faixa preta** amarrada na cintura (obi), pontas soltas.
- **Panos enrolados** em antebraços e canelas.
- **Sem arma.** Uma **esfera de vento ciano brilhante** flutua sobre a palma da mão —
  é o gancho visual da Rajada, o que ele empurra.
- **Fiapos de vento ciano** curvando ao redor dos pés.

**Cor de assinatura sugerida:** ciano-esverdeado, algo como `RGB(150, 230, 220)` — e
**não** um azul-céu. Motivo abaixo.

### Nota de leitura (ler antes de gerar a arte)

Ele encosta em dois heróis que já existem, e o jogo mostra esse desenho encolhido na
carta do draft e no ícone pequeno da UI:

- **Kor** já é branco-e-azul-gelo com olhos brilhando e cor de assinatura
  `RGB(150,210,240)`. Um azul-céu pro Zeff faria os dois disputarem a mesma cor na barra
  de vida e na moldura.
- **Karo** também é branco-prateado de cabelo.

O que separa os três, e precisa ser preservado na arte:

| | Silhueta | Cabelo | Paleta |
|---|---|---|---|
| Kor | encapuzado, capa fechada, **cajado** | escondido no capuz | azul-gelo + creme + dourado |
| Karo | capa esvoaçante, chama na mão | **espetado** | **quente** (vermelho, roxo, laranja) |
| Zeff | **sem capuz**, gola alta + cachecol, esfera na mão | **liso e caído** | **fria** (ciano, cinza-azulado, preto) |

- **Contra o Karo**, o que separa é o **cabelo** (liso caído × espetado) somado à paleta
  (fria × quente). Trocar o espetado pelo liso foi ganho — a silhueta da cabeça agora
  difere de longe, não só a cor.
- **Contra o Kor**, sobra só a **silhueta**: ele não tem capuz nem cajado, e tem cachecol
  e esfera. Sem a pele escura pra ajudar, esse contraste de silhueta é o que segura a
  leitura — vale exagerar a gola alta e o cachecol solto, e **não** dar capa longa a ele.

**Cuidado extra, agora que ele é pálido por inteiro:** pele clara + cabelo branco + manto
azul-claro é um personagem quase sem contraste interno, e a moldura do tabuleiro é clara.
Encolhido, ele vira uma mancha branca. A **faixa preta da cintura** deixa de ser detalhe
e vira âncora — vale mantê-la larga e bem escura, junto com os panos dos antebraços num
tom mais fechado, pra ele não sumir na carta do draft.

### Prompt de arte (Era 1)

Duas mudanças no prompt-base padrão, de propósito: a paleta vira **fria** (o padrão
pede "warm") e ele não segura arma nenhuma.

```
16-bit SNES-style pixel art character sprite, chibi proportions (~2.5-3 heads
tall, oversized round head, short stocky body, thick short limbs), bold
uniform black outline, flat cel-shading with only 2 shade tones per surface
(base color + one hard-edged shadow tone, NO gradients, NO dithering, NO
soft anti-aliased blending), bright COOL saturated color palette, simple
minimal facial features, small glossy highlight speck on rounded surfaces,
chunky rounded boots and hands, standing idle battle-ready pose, slight side
or 3/4 turn of the head, plain white or transparent background, no scenery,
no ground shadow gradient, full body, single character centered in frame,
clean fantasy-RPG game asset —
young wind fighter, STRAIGHT SILVER-WHITE HAIR falling flat with a parted
fringe over the forehead and strands framing the face (NOT spiky), very pale
porcelain skin, glowing pale cyan eyes with no visible pupils, pale blue-gray
layered robe with a very tall wrapped collar covering the neck and chin, a
long scarf trailing behind him in the wind, WIDE BLACK SASH tied at the waist
with loose ends, dark cloth wraps on forearms and shins, no weapon — a small
glowing cyan orb of swirling wind floating above his open palm, faint cyan
wind streaks curling around his feet
```

**Mecânica — uma habilidade só:**
- **Rajada** (`onAttack`) — ao atacar, todos os **outros** inimigos colados no alvo são
  empurrados 1 casa **para longe do alvo**. O alvo em si não sai do lugar e leva o dano
  normal; quem estava em volta dele é que voa.
- **Empurrão bloqueado** (casa ocupada ou fora do tabuleiro): não acontece nada com
  aquele herói. Sem conversão em dano — o Bramm faz isso (`RAGE_BLOCKED_BONUS`), mas
  este herói não é sobre dano, e formação apertada demais pra abrir é uma resposta
  legítima do adversário.

**Por que ataque 2 e não 1:** todo herói de ataque 1 do elenco tem alguma proteção que
justifica o número — alcance (Kor, Elaria), vida de tanque (Ceos 33, Bramm 30, Golem 40)
ou compensação própria (o veneno da Vic). Um corpo a corpo de ataque 1, frágil e sem
Taunt seria o único sem nenhuma das três: entraria, causaria 1 e sairia. Ataque 2 o
coloca na faixa de Nash/Karo/Merlin — relevante sem ser ameaça.

**Por que vida 17:** os três heróis com `Sprint` têm as vidas mais baixas do jogo (14,
14 e 18). Mobilidade se paga com fragilidade, e ele não é exceção — 17 fica entre o Nash
e o Mineiro.

**Por que sem Ranged:** o contra-ataque não exige adjacência — a regra real é
`Distance(alvo, atacante) <= alvo.attackRange` (`MatchManager.PerformAttack`). Um herói
corpo a corpo **não revida** quem o acerta de 3 casas. Com `Ranged`, a Rajada viraria
desmonte de formação todo turno, de graça, sem risco nenhum. Corpo a corpo ele precisa
entrar, e paga o revide por isso. O `Sprint` existe pra compensar: ele é rápido pra
chegar, frágil pra ficar.

**Uma habilidade só é o padrão da casa**, não preguiça: Vic, Blade, Ceos, Bramm e Golem
também têm exatamente uma.

**Esboço da implementação** (só APIs que já existem em `BuildSkillApi`):

```lua
Skills.gustPush = {
	triggers = { "onAttack" },
	apply = function(ctx)
		-- ALIADOS DO ALVO, não "inimigos do alvo": quem é aliado do alvo é
		-- inimigo de quem atacou. Mesma leitura que o aloneIsBetter do Noctin
		-- já faz pra saber se o alvo está sozinho.
		-- O GetAlliesInRange nunca devolve o próprio alvo, então ele fica
		-- parado sozinho, sem precisar de exceção escrita à mão.
		for _, other in ipairs(ctx.api.GetAlliesInRange(ctx.target, 1)) do
			-- casa na linha alvo -> empurrado, um passo além: "pra longe do alvo"
			local away = ctx.api.GetLineBeyond(ctx.target.position, other.position, 1)[1]
			if away and ctx.api.IsFree(away) then
				ctx.api.ForceMove(other, away)
				ctx.api.Effect(other)
			end
		end
		-- sem damageApplied: o alvo leva o golpe normal
	end,
}
```

**Precedente no código:** `Skills.rage` (Bramm) já é esse mesmo trio
(`GetLineBeyond` + `IsFree` + `ForceMove`) — só muda a origem do empurrão, que aqui é o
**alvo** em vez do atacante. E `Skills.aloneIsBetter` (Noctin) já usa
`GetAlliesInRange(ctx.target, 1)` exatamente assim. Trabalho baixo: uma skill nova, uma
entrada no catálogo, uma no `SKILL_INFO`. Zero mudança em `MatchManager`.

**Por que ele agrega tanto:** o jogo inteiro hoje **premia andar junto** e ninguém pune
isso. Ele é o primeiro contra-jogo direto a:
- `emberShield` da Lucy (só protege quem está adjacente a ela)
- `trustInTeam` do Dante (+1 de ataque com aliados do lado)
- `health`/`clean` da Elaria (só alcança aliados adjacentes)
- `flameStrike` do Karo (o giro só compensa com vários inimigos colados)
- o Homem-Bomba acima — a Rajada tira todo mundo do raio da explosão

**Combo que nasce de graça:** a Rajada **isola** o alvo. E o `aloneIsBetter` do Noctin
causa o **dobro** de dano em alvo sem nenhum aliado adjacente. Vento abre, Noctin
executa — sem uma linha de código pra ligar os dois, os dois já se enxergam pela regra
que existe. É a primeira sinergia de time do jogo que não é entre irmãos.

**Falta só a arte.** Nome, ficha, habilidade e prompt já estão fechados acima — quando o
sprite estiver no Roblox, é só o asset ID pra implementar.

---

## 3. O Invocador (tipo Yorick)

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

## 4. O Velocista

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

## 5. O Elétrico

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

## 6. A Sniper

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
  Nash, Karo, Lucy), não títulos genéricos.
- **Nenhum destes tem IA de bot pensada ainda.** Vale lembrar que o próprio Karo já não
  tem — o `BotBrain` não sabe usar o rastro de fogo dele estrategicamente. Então nascer
  sem IA otimizada é o normal da casa, não regressão.
- **Onde as habilidades vivem:** mecânica em `src/server/Modules/Skills.luau`, números em
  `src/shared/Modules/GameConfig.luau`, ficha e texto de UI em
  `src/shared/Modules/HeroData.luau`, confronto da campanha em
  `src/shared/Modules/Campaign.luau`.
