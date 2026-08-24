# Guia de Arte dos Heróis

Referência pra gerar heróis novos na mesma IA de imagem, batendo com o que já existe
no jogo. Baseado nos sprites reais (`HeroData.CATALOG`), não em suposição.

## Duas eras visuais (existe uma inconsistência hoje)

O elenco tem dois estilos diferentes, porque foram gerados em momentos diferentes:

- **Era 1 — folha clássica** (`SPRITE_SHEET`, heróis 1–9: Ralph, Vic, Mineiro, Blade,
  Dante, Ceos, Noctin, Elaria, Bramm). Pixel art mais simples: poucas cores por
  personagem, sombreado quase plano (1–2 tons por área), contorno preto grosso e
  uniforme, silhueta curta e larga (~3 cabeças de altura), quadro fixo 165×231.
- **Era 2 — sprites individuais** (heróis 10–14: Kor, Merlin, Karo, Nash, Golem).
  Pixel art mais detalhada: gradientes de sombra em 3–4 tons, luz direcional clara
  (lado iluminado vs lado em sombra), contorno mais fino e às vezes colorido (não só
  preto), acessórios com textura própria (couro, pedra, pelo), proporção um pouco
  mais alongada (~3.5–4 cabeças). Canvas próprio por herói, sempre fundo transparente.

**Recomendação (confirmada pelo usuário):** para heróis novos, seguir a **Era 1** —
é o estilo alvo. A Era 2 é mais detalhada mas é OUTRO estilo, não o que queremos
replicar; as fichas dela abaixo ficam só como registro do que já existe no jogo.

## Regras que valem pras duas eras

- **Fundo transparente**, sempre. Nunca cenário atrás do personagem — ele é recortado
  e colado em molduras diferentes (tabuleiro, carta de draft, retrato de UI).
- **Pose única, de corpo inteiro, de frente ou 3/4**, estática (idle), nunca em ação
  de câmera lateral pura. Arma/prop já em punho, pronta, não guardada.
- **Proporção chibi**: cabeça grande em relação ao corpo, torso curto, pernas curtas
  e grossas — nunca proporção realista 7–8 cabeças.
- **Contorno escuro fechando toda a silhueta**, mesmo onde o contorno de dentro (entre
  peças de roupa) é mais fino ou some.
- **Uma cor de assinatura por herói**, geralmente ligada à arma/efeito da habilidade,
  não à roupa toda — é ela que aparece como o `color` do herói na UI (barra de vida,
  moldura, ícone). Fogo laranja pro Karo, gelo azul pro Kor, verde veneno pro Vic, etc.
- **Silhueta legível em miniatura**: o jogo usa o mesmo desenho encolhido pra carta e
  pro ícone pequeno da UI, então a pose/arma tem que ficar reconhecível pequena — nada
  de detalhe que só existe de perto.

## Prompt-base — Era 1 (estilo alvo)

Baseado direto nos 6 heróis de referência (Mineiro, Vic, Ralph, Ceos, Blade, Dante):

```
16-bit SNES-style pixel art character sprite, chibi proportions (~2.5-3 heads
tall, oversized round head, short stocky body, thick short limbs), bold
uniform black outline, flat cel-shading with only 2 shade tones per surface
(base color + one hard-edged shadow tone, NO gradients, NO dithering, NO
soft anti-aliased blending), bright warm saturated color palette, simple
minimal facial features (small round eyes, tiny or no nose, calm/determined
expression), small glossy highlight speck on rounded surfaces, chunky rounded
boots and hands, standing idle battle-ready pose holding weapon/tool in hand,
slight side or 3/4 turn of the head, plain white or transparent background,
no scenery, no ground shadow gradient, full body, single character centered
in frame, clean fantasy-RPG game asset
```

Coisas a **evitar explicitamente** (o que puxaria pra Era 2 ou pra outro estilo):
sombreado em gradiente, múltiplos tons de sombra, contorno colorido/fino,
textura de material realista (couro, pelo, pedra com detalhe), proporção
alongada, luz direcional forte com rim light.

---

## Fichas por herói

### 1. Ralph — brawler (starter)
Boné vermelho, regata cinza-clara justa, calça jeans azul-escura, pele morena/bronzeada,
tufo de cabelo castanho escapando do boné, postura ereta de lutador de rua. Sem arma —
luta com os punhos (habilidade `firstPunch`). Cor de assinatura: terracota
`RGB(205,92,70)`.

### 2. Vic — gorgona venenosa (redesign, Era 2 — ver nota abaixo)
Substituiu o design antigo (planta de capuz de folhas). Mulher-serpente: da cintura
pra baixo é cauda de cobra verde com listras amarelo-esverdeadas na barriga; da
cintura pra cima veste um robe/quimono verde de manga comprida com friso dourado e
faixa dourada na cintura, gola em V que cobre o tronco (versão "menos sexualizada"
do primeiro rascunho, que tinha o torso à mostra). Cabelo é um emaranhado de cobras
vivas (4, olhos vermelhos), tiara dourada com gema verde na testa, brincos longos
dourados, pele morena-clara, olhos verdes, expressão séria/calma. Sem arma — veneno
é o próprio corpo (`poisonAttack`). Cor de assinatura: verde `RGB(120,180,90)`.

**Nota de inconsistência:** esse redesign saiu no estilo Era 2 (sombreado em
gradiente, contorno fino, textura de escama/tecido detalhada) — não no Era 1 que
ficou definido como alvo pro resto do elenco. Sinalizando, não travando: se quiser
manter a Vic assim mesmo destoando, ou regerar ela em Era 1 depois, os dois caminhos
ficam abertos.

### 3. Mineiro — sortudo
Capacete de mineração amarelo com lanterna frontal, barba ruiva cheia, jaqueta jeans
azul aberta sobre camisa clara, calça marrom, botas de trabalho. Segura uma picareta/
machado curto na mão direita. Habilidade de sorte (`goodLuck`) — expressão confiante,
quase sorridente. Cor de assinatura: marrom-areia `RGB(180,140,70)`.

### 4. Blade — espadachim
Cabelo castanho curto, cachecol/echarpe laranja ao redor do pescoço, colete azul-acinzentado
sobre camisa clara, calça bege, empunha uma espada reta de duas mãos já erguida.
Ataca em linha reta (`beyondFront`) — pose de quem vai golpear pra frente. Cor de
assinatura: cinza-aço `RGB(150,150,165)`.

### 5. Dante — arqueiro (starter)
Capuz e túnica verde-floresta, luvas/braçadeiras marrons, porta um arco já preparado
com flecha e aljava nas costas. Ranged + suporte de equipe (`trustInTeam`). Cor de
assinatura: azul `RGB(90,150,200)` (contraste proposital com a roupa verde — é a cor
"de time" dele na UI, não da roupa).

### 6. Ceos — tanque vegetal (starter)
Corpo musgoso verde-escuro, "cabeça" com topo laranja/vermelho lembrando um fruto ou
casco de castanha, postura larga e parada (tanque de linha de frente, `Taunt`). Regenera
absorvendo dano (`absorbRoots`) — nenhuma arma, corpo robusto é a defesa. Cor de
assinatura: verde-sálvia `RGB(110,160,120)`.

### 7. Noctin — sombra solitária
Silhueta quase toda preta, capuz e manto cobrindo o corpo inteiro, feições apagadas
sob a sombra do capuz (só sugestão de rosto, sem detalhe). Sprint + dobra de dano
isolado (`aloneIsBetter`) — pose fechada, ombros curvados, personagem que não quer
ser visto. Cor de assinatura: índigo escuro `RGB(80,80,110)`.

### 8. Elaria — curandeira (Ranged)
Cabelo longo ruivo-alaranjado solto, vestido/manto longo vermelho-vinho com cinto,
segura um cajado de madeira alto (mais alto que ela) com as duas mãos. Cura e remove
efeitos negativos da equipe (`health`, `clean`) — pose serena, olhar calmo. Cor de
assinatura: lavanda `RGB(190,130,200)` (cor de time na UI; a roupa em si é vermelha).

### 9. Bramm — bruto tanque (Taunt)
Pele alaranjada, dois pequenos chifres/protuberâncias na cabeça, torso nu ou quase,
peitoral com uma placa de armadura escura presa por correias, físico corpulento e
largo. Empurra inimigos com fúria (`rage`) — postura agressiva, ombros pra frente.
Cor de assinatura: marrom-alaranjado `RGB(160,110,60)`.

### 10. Kor — mago de gelo (Era 2)
Capuz e capa grandes em branco-gelo/creme com barra dourada, forrado por dentro em
tom escuro; rosto quase todo coberto pela sombra do capuz, com o pouco de pele visível
brilhando em azul-gelo translúcido (como se fosse feito de gelo, não pele normal).
Roupa por baixo preto-azulada, capa longa até os pés. Empunha um cajado marrom alto
encimado por um cristal de gelo azul brilhante. Efeito de congelamento em toda ficha
(`iceEffect`, `iceStorm`). Cor de assinatura: azul-gelo `RGB(150,210,240)`.

### 11. Merlin — o lobo guerreiro (Era 2)
Lobo bípede, pelagem cinza-escura/preta despenteada, focinho e peito com mecha branca,
olhos vermelhos brilhantes (únicos pontos de cor quente no personagem). Veste tiras de
couro marrom-escuro cruzadas no peito com fivelas prateadas, protetores de couro nos
braços e pernas. Carrega uma espada às costas, presa por uma correia diagonal. Fica
mais forte a cada morte em campo e enlouquece sozinho no time (`bloodScent`, `frenzy`).
Cor de assinatura: vinho-acastanhado `RGB(150,70,60)`.

### 12. Karo — mago de fogo (Era 2)
Cabelo espetado branco-prateado, olhos brilhando em laranja-fogo, capa longa vermelho-
sangue esvoaçante. Roupa por baixo roxo-escura (túnica e calça), com peças de armadura
de couro marrom em ombros, antebraços e cintura (cinto largo com fivela). Chama de fogo
viva flutuando sobre a palma da mão direita; rastro de fogo saindo do chão perto dos
pés/botas, como se ele mesmo estivesse pegando fogo por baixo. Controla zona com fogo
(`flamePath`, `flameStrike`, `flameFury`). Cor de assinatura: laranja-fogo
`RGB(255,140,70)`.

### 13. Nash — assassino furtivo, ex-"Shadow" (Era 2)
Não é humanoide comum — figura completamente encapuzada num manto marrom rasgado e
esfarrapado nas bordas, sem rosto definido: só um vão de escuridão de onde brilham dois
olhos vermelhos e uma boca sorrindo com dentes afiados vermelho-brilhantes. Mãos como
garras escuras saindo das mangas, postura encurvada e agachada (agazapado, pronto pra
avançar). Sem arma — ataca com as garras ao sair da invisibilidade (`stealth`,
`ambush`). Cor de assinatura: azul-acinzentado `RGB(80,90,120)` (cor de time na UI; o
manto em si é marrom-terra).

### 14. Golem (e mini-golens 15/16) — colosso de pedra (Era 2)
Corpo inteiro de blocos de rocha cinza-claro e cinza-escuro encaixados, rachaduras bege
por onde escapa um brilho laranja (o "núcleo" — visível como um olho único brilhante no
centro do rosto). Musgo e tufos de grama verde crescem nos ombros, no topo da cabeça
(como dois chifres de musgo) e nas laterais do tronco. Base do personagem apoiada sobre
pedras soltas e grama. Braços grossos e desproporcionalmente grandes (tanque puro,
`Taunt`). Ao perder a primeira vida se parte em dois golens menores — **mesmo desenho,
só reescalado a 60%**, sem redesenhar (`shatter`). Cor de assinatura: cinza-pedra
`RGB(140,140,140)`.

---

## Exemplo de prompt completo — Era 1 (Blade)

```
16-bit SNES-style pixel art character sprite, chibi proportions (~2.5-3 heads
tall, oversized round head, short stocky body, thick short limbs), bold
uniform black outline, flat cel-shading with only 2 shade tones per surface
(base color + one hard-edged shadow tone, NO gradients, NO dithering, NO
soft anti-aliased blending), bright warm saturated color palette, simple
minimal facial features (small round eyes, tiny or no nose, calm/determined
expression), small glossy highlight speck on rounded surfaces, chunky rounded
boots and hands, standing idle battle-ready pose holding weapon/tool in hand,
slight side or 3/4 turn of the head, plain white or transparent background,
no scenery, no ground shadow gradient, full body, single character centered
in frame, clean fantasy-RPG game asset —
young swordsman, short brown hair, bright orange scarf around his neck,
blue-gray vest over a light shirt, tan trousers, brown boots, gripping a
long straight two-handed sword already raised in front of him, ready to
strike forward
```

Repita essa estrutura pra qualquer herói novo: prompt-base Era 1 fixo + parágrafo
específico da ficha dele, sempre citando cor de assinatura, arma/prop e o gancho
visual da habilidade. Pra heróis já existentes na Era 2 (Kor, Merlin, Karo, Nash,
Golem) que você queira REFAZER no estilo Era 1, use a mesma receita: prompt-base
Era 1 + a descrição de roupa/arma/gancho que já está na ficha deles, ignorando as
instruções de sombreado/textura da Era 2.
