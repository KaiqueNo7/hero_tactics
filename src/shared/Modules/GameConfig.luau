--[[
	GameConfig.lua
	ModuleScript — ReplicatedStorage/Modules/GameConfig

	Constantes centrais do jogo. Mudar valores aqui afeta tudo (server e client),
	já que fica em ReplicatedStorage.
]]

local GameConfig = {}

GameConfig.HEROES_PER_PLAYER = 3

GameConfig.BASE_MOVE_RANGE = 2
GameConfig.SPRINT_MOVE_RANGE = 3

GameConfig.BASE_ATTACK_RANGE = 1
GameConfig.RANGED_ATTACK_RANGE = 3

-- "Este herói ataca à distância?" = alcança além do corpo a corpo.
--
-- Existe porque o código perguntava isso com `attackRange >= 2` espalhado em
-- meia dúzia de lugares — o 2 era o valor do Ranged na época, então a pergunta
-- só acertava por coincidência. Comparar com BASE_ATTACK_RANGE diz o que a
-- pergunta realmente é, e sobrevive a qualquer remexida nos números acima.
function GameConfig.IsRangedAttack(attackRange)
	return (attackRange or GameConfig.BASE_ATTACK_RANGE) > GameConfig.BASE_ATTACK_RANGE
end

GameConfig.SUDDEN_DEATH_WARNING_TURN = 15
GameConfig.SUDDEN_DEATH_START_TURN = 20
GameConfig.SUDDEN_DEATH_DAMAGE = 1

GameConfig.GOOD_LUCK_CHANCE = 0.5 -- chance do goodLuck do Mineiro dar +1 de ataque
GameConfig.POISON_DURATION = 3

-- ===== GELO (Kor) =====
-- Duração 2 não é "dois turnos de congelamento por gosto": é o mínimo que deixa
-- o dobro de dano existir. O contador cai no FIM do turno de quem está
-- congelado, e entre um ataque do Kor e o seguinte passa exatamente um turno do
-- inimigo. Com duração 1 o gelo derreteria antes do segundo golpe e o bônus
-- nunca aconteceria em jogo. Cada golpe do Kor renova o gelo.
GameConfig.FREEZE_DURATION = 2

-- Congelado anda ISTO, não "uma casa a menos". A penalidade relativa deixava o
-- gelo fraco justamente contra quem ele mais precisa segurar: o Sprint (3 casas)
-- perdia uma e continuava com 2, mais do que um herói comum inteiro. Teto
-- absoluto vale o mesmo pra todo mundo — congelou, arrasta o pé.
GameConfig.FREEZE_MOVE_RANGE = 1

GameConfig.FREEZE_DAMAGE_MULTIPLIER = 2 -- dano do Kor contra alvo já congelado

-- ===== O LOBO (Merlin) =====
-- Estes números partem de HEROES_PER_PLAYER = 3. Num esquadrão de três, o
-- Frenesi custa DUAS mortes aliadas — isso acontece em partida equilibrada, não
-- é situação de desespero. O preço é barato, então o ganho tem que ser modesto:
-- num time de cinco o mesmo efeito poderia pagar bem mais.
--
-- Teto de ataque do Merlin: 2 (ficha) + 2 (faro no máximo) + 2 (frenesi) = 6.
-- Fica de propósito abaixo dos ~7 que o Mineiro alcança no fim de jogo, porque
-- ataque em herói corpo a corpo vale duas vezes: é o dano do golpe dele E o do
-- contra-ataque em quem encostar nele. O Mineiro paga esse mesmo número na
-- moeda da sorte, e pode terminar a partida em 3.
GameConfig.MERLIN_DEATH_ATTACK_MAX = 2 -- teto do Faro de Sangue (+1 por morte no tabuleiro)
GameConfig.MERLIN_FRENZY_ATTACK = 2    -- ataque extra enquanto for o último vivo do time
GameConfig.MERLIN_FRENZY_HEAL = 4      -- cura ao entrar em Frenesi, uma vez por partida
GameConfig.MERLIN_FRENZY_KILL_HEAL = 2 -- cura por inimigo abatido durante o Frenesi

-- ===== FOGO (Karo) =====
-- O fogo do Caminho de Chamas é o primeiro efeito do jogo preso a uma CASA, e
-- não a um herói: ele continua queimando depois que o Karo saiu de cima. Por
-- isso não mora em hero.statusEffects como o veneno e o gelo.
--
-- Duração 2 é o que faz o rastro valer alguma coisa. O Karo anda 2 casas por
-- turno (BASE_MOVE_RANGE, ele não tem Sprint), então acende no máximo 2 casas
-- por vez; com duração 1 a primeira já teria apagado quando o inimigo chegasse
-- na segunda, e o "caminho" nunca seria um caminho.
GameConfig.FLAME_DURATION = 2
GameConfig.FLAME_DAMAGE = 2

-- Furor das Chamas: pisar numa casa que JÁ estava em chamas (do próprio Karo,
-- de um passo anterior) dá +1 de ATAQUE por casa. É EMPRÉSTIMO, não ficha
-- nova — mesmo padrão do bônus do barril (attackBonus num status effect,
-- devolvido sozinho pelo ProcessStatusEffects): dura 1 turno de uso e depois
-- volta pro normal, não empilha partida afora.
GameConfig.FLAME_FURY_ATTACK = 1
GameConfig.FLAME_FURY_DURATION = 1

-- Teto do ATAQUE do Karo com o empréstimo somado. Base 2 + no máximo +2 de
-- Furor: dois passos em fogo aceso já enchem o teto, um terceiro não soma mais
-- nada. Sem isso, um caminho comprido cruzando várias chamas antigas vira
-- dano absurdo numa figura de ATK 2.
GameConfig.FLAME_FURY_MAX_ATTACK = 4

-- ===== FURTIVIDADE (Shadow) =====
-- Inimigo A ESTA DISTÂNCIA OU MENOS revela o Shadow; a partir de 2 casas ele
-- some. Igual ao alcance de ataque dele (1, corpo a corpo): só quem está
-- literalmente colado enxerga o vulto — de 2 casas pra longe ele já sumiu.
GameConfig.STEALTH_RANGE = 1
GameConfig.STEALTH_HEAL = 1 -- cura por turno enquanto invisível

-- Só o movimento do INIMIGO tira o Shadow da sombra. O movimento dele próprio
-- não conta contra si mesmo, senão a Emboscada nunca aconteceria: ele precisa
-- ficar adjacente pra bater (alcance 1), e um movimento seu terminando
-- adjacente não deve se contar como revelação — a invisibilidade cairia no
-- passo de andar, antes do golpe. Quem quebra a furtividade dele é o ATAQUE
-- ou o DANO RECEBIDO (de qualquer fonte, com autor ou sem), não a aproximação.
--
-- A conta do Nash é só o estado da sombra, sem olhar posição nenhuma (a regra
-- antiga de "pelas costas" não existe mais em lugar nenhum do jogo):
--
--   invisível  ->  2 de ficha + 4 daqui = 6
--   visível    ->  2
--
-- O ataque de ficha dele é 2 (HeroData) justamente porque o número que importa
-- é o de dentro da sombra. Como é o próprio golpe que revela o Nash, o ataque
-- seguinte já sai por 2 — e se ele for revelado ANTES de bater (levou dano, ou
-- o inimigo colou), esse ataque também sai por 2.
GameConfig.AMBUSH_BONUS_DAMAGE = 4

-- O ataque que o herói causa AGORA, com a sombra já contada — mesmo papel que
-- o MoveRangeOf tem pro alcance depois do gelo. O +4 da Emboscada não mora na
-- ficha (quem aplica o golpe é a própria skill, pelo carimbo que o
-- PerformAttack tira ANTES de a sombra cair), mas o jogador precisa VER o
-- número que vai sair: o crachá do Nash invisível marca 6 e volta pra 2 no
-- instante em que ele é revelado.
--
-- Mora aqui, e não no servidor, porque duas telas leem o mesmo número: o
-- crachá em cima do boneco (HeroView) e a coluna de retratos (via Snapshot).
-- Bônus emprestados por fora (barril, por exemplo) já estão dentro de
-- `hero.attack`, então entram na soma sozinhos.
function GameConfig.EffectiveAttack(hero)
	if hero.stealth and table.find(hero.abilities or {}, "ambush") then
		return hero.attack + GameConfig.AMBUSH_BONUS_DAMAGE
	end
	return hero.attack
end

-- Opacidade com que o DONO enxerga o próprio Shadow invisível. O adversário não
-- vê nada. 0 = sólido, 1 = sumido: 0.65 deixa o vulto legível pra planejar a
-- jogada sem parecer um herói normal.
GameConfig.STEALTH_OWNER_TRANSPARENCY = 0.65

-- ===== GOLEM =====
-- Ao perder a primeira vida, vira DOIS golens novos: um na casa dele, outro na
-- primeira casa adjacente livre. Os ids saem de HeroData.SUMMONS, que fica
-- FORA do catálogo — não são escolhíveis no draft nem vendidos na loja, e os
-- dois exibem `name = "Golem"` (o dataId diferente é só pra não colidirem no
-- mesmo uid).
--
-- 40 de vida num herói de 1 de ataque é o dobro do Ceos, e é o preço de o time
-- inimigo precisar derrubar TRÊS corpos em vez de um. Os golens menores
-- invertem a ficha (2 de ataque, 5 de vida cada): quem quebrou o corpo grande
-- passa a levar pancada dos dois lados, então isso não é alívio nenhum.
GameConfig.GOLEM_SUMMON_IDS = { 15, 16 }

-- ===== BARRIL (objeto neutro) =====
-- Ocupa uma casa como um herói, mas não é de ninguém e não tem vida: quebra por
-- CONTAGEM DE GOLPES, então um ataque de 1 vale o mesmo que um de 5. É o que
-- torna o barril interessante pro time fraco em dano — quebrar custa dois
-- turnos de ataque pra qualquer um.
GameConfig.BARREL_HITS = 2 -- golpes até quebrar, independente do dano

-- Casas FIXAS, não sorteadas. O sorteio no miolo funcionava, mas fazia cada
-- partida começar com um tabuleiro diferente: dava pra abrir num barril colado
-- na sua largada e no outro dia num barril colado na do adversário. Com posição
-- fixa e simétrica (uma de cada lado do centro, mesma fileira), os dois times
-- correm a mesma distância pra disputar o prêmio — e o jogador aprende a abertura
-- em vez de descobrir o mapa toda vez.
GameConfig.BARREL_HEXES = { "B4", "D4" }

GameConfig.BARREL_HEAL_CHANCE = 0.5 -- o resto da chance vai pro bônus de ataque
GameConfig.BARREL_HEAL = 2
GameConfig.BARREL_ATTACK_BONUS = 1

-- Um turno de uso, que é o turno SEGUINTE ao da quebra: o herói gastou o ataque
-- dele no barril, então o bônus só serve daí em diante. Um prazo nunca é
-- consumido no turno em que começa (ver ProcessStatusEffects), e é isso que faz
-- "1" aqui significar um turno inteiro de bônus em vez de nenhum.
GameConfig.BARREL_BUFF_DURATION = 1

GameConfig.ABILITIES = {
	SPRINT = "Sprint",
	TAUNT = "Taunt",
	RANGED = "Ranged",
}

GameConfig.TURN_TIME_LIMIT = 60 -- segundos por turno; 0 desliga o cronômetro
GameConfig.BOT_PLACE_DELAY = 0.8 -- pausa antes do bot escolher, pra dar pra acompanhar

-- ===== CASAS DE PROMOÇÃO =====
-- Duas casas extras na ponta da coluna central (C), além da grade normal de
-- C1..C6 — ver HexGrid.Generate. Ficam trancadas até o turno (rodada)
-- PROMOTION_UNLOCK_TURN, mesma unidade que SUDDEN_DEATH_START_TURN usa: sobe
-- uma vez por RODADA completa (os dois lados jogaram), não por turno individual.
GameConfig.PROMOTION_UNLOCK_TURN = 10

-- Slot 1 larga perto de C7 (linhas altas, ver DEPLOY_ZONES) e slot 2 larga perto
-- de C0 (linhas baixas) — por isso cada um só ativa a casa DISTANTE da própria
-- largada, a "original do oponente". Índice = hero.sideIndex.
GameConfig.PROMOTION_HEX_FOR_SLOT = { [1] = "C0", [2] = "C7" }

-- Golpes do INIMIGO até destruir a lápide de um herói caído. Igual ao barril:
-- conta de golpes, não de dano — um golpe de 1 vale o mesmo que um de 5.
GameConfig.GRAVE_HITS = 3

-- A maldição: quem desfere o golpe que destrói a lápide sofre este dano. É o
-- preço de negar a ressurreição — se fosse de graça, destruir lápide seria a
-- jogada óbvia sempre, sem escolha nenhuma envolvida.
GameConfig.GRAVE_CURSE_DAMAGE = 1

-- Vida fixa do herói que volta pela casa de promoção — não é a vida máxima da
-- ficha dele. Ressuscita frágil: um "segunda chance" de verdade, não um reset.
GameConfig.RESURRECT_HP = 5

-- ===== POSICIONAMENTO DOS COMPETIDORES (confronto estilo Pokémon) =====
-- Os dois ficam em LADOS OPOSTOS do tabuleiro, ambos alinhados com o centro
-- dele, olhando um pro outro por cima do campo.
--
-- Antes era diagonal: slot 1 ancorado em A6, slot 2 em E1 com um desvio lateral
-- de 14 studs. Isso nasceu com a câmera de frente; depois que ela foi pro
-- azimute 91° (olhando o tabuleiro de lado) os dois deixaram de se enxergar —
-- um caía no fundo da cena e o outro na frente, cada um encarando o vazio.
-- Alinhados no mesmo X e separados só no Z, a direção fixa de olhar (±Z) aponta
-- exatamente pro adversário, sem precisar de conta de mira.
--
-- A distância é medida em CASAS a partir da borda do tabuleiro, e não em studs
-- soltos: mudando o tamanho do hexágono, os dois continuam à mesma distância
-- relativa do campo. A conta mora no HexGrid.GetStandPosition/GetStandFacing pra
-- client (jogador local) e server (bonequin do bot) não divergirem.
GameConfig.PLAYER_STAND_OUTSET_HEXES = 1 -- casas de folga entre a borda do tabuleiro e o competidor
GameConfig.PLAYER_STAND_SCALE = 2.2 -- tamanho dos personagens nas posições de espera (1 = normal)

-- ===== FONTE DE TEXTO CORRIDO =====
-- Vale pro que se LÊ: passo de tutorial, descrição de habilidade, aviso.
-- Título e número continuam na Gotham (Black/Bold) — a hierarquia vem do peso,
-- e trocar tudo de família só pra unificar mexeria em dezenas de rótulos que
-- não têm problema nenhum de leitura.
--
-- BuilderSans é a fonte de interface da própria Roblox: altura-x maior que a
-- Gotham no MESMO TextSize, então a mesma frase em 14px fica com letra
-- visivelmente maior sem estourar caixa nenhuma. A Gotham é geométrica, boa em
-- título grande e ruim em parágrafo pequeno sobre fundo escuro, que é
-- exatamente onde este jogo põe texto explicativo.
--
-- Medium, e não Regular: sobre painel escuro o traço fino da Regular some.
GameConfig.UI_FONT_BODY = Enum.Font.BuilderSansMedium

-- ===== COR DAS CASAS =====
-- O xadrez do tabuleiro. Moram aqui, e não no BoardSpawner, porque os DOIS
-- clientes também precisam deles: quando um destaque sai (fim do arraste, fim
-- da seleção), a casa volta pro attribute BaseColor, e a cor daqui é a rede de
-- segurança pra quando esse attribute faltar. Eram três cópias literais do
-- mesmo par de RGB em três arquivos — o tipo de coisa que só se descobre
-- desencontrada depois que alguém muda uma.
--
-- Pedra quente, não azul. O azul claro original nasceu com a arena aberta e
-- clara; dentro da taverna fechada, iluminada só por fogo e janela, ele era a
-- coisa mais clara da cena inteira e estourava de branco — o tabuleiro virava
-- uma mancha luminosa no meio de um ambiente âmbar. Pedra em tom de terra fica
-- abaixo do brilho do piso, e é ela que faz os heróis destacarem.
--
-- Os dois tons são bem separados de propósito. A luz da taverna bate forte no
-- tabuleiro (lustre em cima e os feixes das janelas), e um par de tons próximos
-- lava até virar uma laje só — o xadrez, que é o que deixa contar distância de
-- bate-pronto, simplesmente desaparecia.
GameConfig.HEX_COLOR_A = Color3.fromRGB(108, 90, 74)
GameConfig.HEX_COLOR_B = Color3.fromRGB(74, 61, 50)

-- ===== ARENAS SIMULTÂNEAS =====
-- Cada partida ocupa uma arena própria, lado a lado no eixo X. A taverna mede
-- ~141 studs de largura, então 200 de espaçamento deixa um corredor vazio entre
-- elas.
--
-- ESTE VETOR É A ORIGEM DO TABULEIRO, NÃO O CENTRO DELE. O centro cai em
-- origem + (18, 0, 25.98) — conta que sai do HexGrid (5 colunas de 9 studs, e
-- de C0 a C7 no eixo Z, mais meia peça de margem). Pra centralizar o tabuleiro
-- numa taverna nova: pegue o centro do INTERIOR (face interna das paredes) e
-- subtraia esse (18, 0, 25.98).
--
-- Taverna atual (medida no place, faces internas):
--   X  -285.4 .. -146.0  -> centro -215.70  -> origem X = -233.70
--   Z   -28.9 ..   97.2  -> centro   34.15  -> origem Z =    8.17
--   piso com topo em 499.5, e o BoardSpawner encosta o piso em ORIGIN.Y - 0.5
--                                            -> origem Y =  500
--
-- Se a taverna for movida à mão de novo, é este vetor que tem que acompanhar —
-- senão o tabuleiro nasce no vazio, longe do cenário, e a partida roda
-- normalmente só que sem chão nenhum embaixo. O BoardSpawner avisa no output
-- quando os dois se desencontram.
GameConfig.ARENA_ORIGIN = Vector3.new(-233.7, 500, 8.17)
GameConfig.ARENA_SPACING = 200

-- Cada arena comporta 2 jogadores, então este número TEM que acompanhar o
-- tamanho do servidor: com 8 arenas cabem 16 em partida. Se o servidor for
-- maior que o dobro disto, a diferença é gente parada no lobby recebendo
-- "Todas as arenas estão ocupadas" — a pior primeira impressão possível.
--
-- O tamanho do servidor não se configura por script: é Game Settings > Players
-- > Max Players. Mantenha os dois em par (16 jogadores / 8 arenas).
--
-- Arena parada custa pouco (é cenário clonado, sem script), então o teto real
-- é memória e replicação, não CPU.
GameConfig.MAX_SIMULTANEOUS_MATCHES = 8

function GameConfig.ArenaOrigin(slot)
	return GameConfig.ARENA_ORIGIN + Vector3.new((slot - 1) * GameConfig.ARENA_SPACING, 0, 0)
end

-- ===== RAIO DE SPAWN DO LOBBY =====
-- Os 19 SpawnLocations do lobby se espalham até ~30 studs do centro, e o pad
-- de PvP está a ~33 studs — um respawn azarado caía praticamente em cima do
-- pad e disparava a fila sozinho. Só valem spawns dentro deste raio.
GameConfig.LOBBY_SPAWN_RADIUS = 18

return GameConfig
