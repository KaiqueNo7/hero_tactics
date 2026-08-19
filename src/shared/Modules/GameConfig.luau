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

-- ===== ARENAS SIMULTÂNEAS =====
-- Cada partida ocupa uma arena própria, lado a lado no eixo X. A taverna mede
-- ~100 studs de largura, então 200 de espaçamento deixa um corredor vazio entre
-- elas — nem a luz das tochas (Range 34) alcança a vizinha.
-- O Y não é zero porque a taverna foi levantada para ~660 studs no place, longe
-- do lobby. A conta que amarra os dois: o BoardSpawner encosta o topo do piso da
-- taverna em ARENA_ORIGIN.Y - 0.5, então o piso atual (topo em 663.5) pede
-- Y = 664. X e Z centralizam o tabuleiro no piso.
--
-- Se um dia a taverna for movida à mão de novo, é este vetor que tem que
-- acompanhar — senão o tabuleiro nasce no vazio, longe do cenário, e a partida
-- roda normalmente só que sem chão nenhum embaixo.
GameConfig.ARENA_ORIGIN = Vector3.new(304, 664, 313)
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
