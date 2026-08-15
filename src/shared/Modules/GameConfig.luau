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
-- Compartilhado entre CameraController (client, posiciona o player) e
-- BoardSpawner (server, posiciona o bonequin do bot) pra ficarem lado a lado.
GameConfig.PLAYER_SIDE_MARGIN = 6
GameConfig.PLAYER_STAND_BACK = 5
GameConfig.BOT_DUMMY_GAP = 9 -- distância do bonequin em relação ao player

return GameConfig
