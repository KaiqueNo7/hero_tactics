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
GameConfig.RANGED_ATTACK_RANGE = 2

GameConfig.SUDDEN_DEATH_WARNING_TURN = 15
GameConfig.SUDDEN_DEATH_START_TURN = 20
GameConfig.SUDDEN_DEATH_DAMAGE = 1

GameConfig.GOOD_LUCK_CHANCE = 0.5 -- chance do goodLuck do Mineiro dar +1 de ataque
GameConfig.POISON_DURATION = 3

GameConfig.ABILITIES = {
	SPRINT = "Sprint",
	TAUNT = "Taunt",
	RANGED = "Ranged",
}

GameConfig.PLAYER_CORNER_HEX = "A1" -- hex mais próximo de onde o player fica parado / câmera se ancora

GameConfig.TURN_TIME_LIMIT = 60 -- segundos por turno; 0 desliga o cronômetro
GameConfig.BOT_PLACE_DELAY = 0.8 -- pausa antes do bot escolher, pra dar pra acompanhar

-- ===== POSICIONAMENTO AO LADO DO TABULEIRO =====
-- Os dois competidores ficam à esquerda do tabuleiro (-X), lado a lado no eixo
-- Z, olhando pra arena. Usado pelo CameraController (posiciona o jogador local)
-- e pelo BoardSpawner (posiciona o bonequin do bot). A conta em si mora no
-- HexGrid.GetStandPosition pra não divergir entre client e server.
GameConfig.PLAYER_SIDE_MARGIN = 9 -- distância à esquerda da borda do tabuleiro
GameConfig.PLAYER_STAND_SPACING = 7 -- distância entre os dois competidores

-- ===== ARENAS SIMULTÂNEAS =====
-- Cada partida ocupa uma arena própria, lado a lado no eixo X. A taverna mede
-- ~100 studs de largura, então 200 de espaçamento deixa um corredor vazio entre
-- elas — nem a luz das tochas (Range 34) alcança a vizinha.
GameConfig.ARENA_ORIGIN = Vector3.new(300, 0, 300)
GameConfig.ARENA_SPACING = 200
GameConfig.MAX_SIMULTANEOUS_MATCHES = 6

function GameConfig.ArenaOrigin(slot)
	return GameConfig.ARENA_ORIGIN + Vector3.new((slot - 1) * GameConfig.ARENA_SPACING, 0, 0)
end

-- ===== RAIO DE SPAWN DO LOBBY =====
-- Os 19 SpawnLocations do lobby se espalham até ~30 studs do centro, e o pad
-- de PvP está a ~33 studs — um respawn azarado caía praticamente em cima do
-- pad e disparava a fila sozinho. Só valem spawns dentro deste raio.
GameConfig.LOBBY_SPAWN_RADIUS = 18

return GameConfig
