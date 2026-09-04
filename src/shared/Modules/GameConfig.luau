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

function GameConfig.IsRangedAttack(attackRange)
	return (attackRange or GameConfig.BASE_ATTACK_RANGE) > GameConfig.BASE_ATTACK_RANGE
end

GameConfig.SUDDEN_DEATH_WARNING_TURN = 15
GameConfig.SUDDEN_DEATH_START_TURN = 20
GameConfig.SUDDEN_DEATH_DAMAGE = 1

GameConfig.GOOD_LUCK_CHANCE = 0.5 -- chance do goodLuck do Mineiro dar +1 de ataque
GameConfig.GOOD_LUCK_HEAL = 2
GameConfig.POISON_DURATION = 3
GameConfig.FREEZE_DURATION = 2
GameConfig.FREEZE_MOVE_RANGE = 1

GameConfig.FREEZE_DAMAGE_MULTIPLIER = 2 -- dano do Kor contra alvo já congelado
GameConfig.MERLIN_DEATH_ATTACK_MAX = 2 -- teto do Faro de Sangue (+1 por morte no tabuleiro)
GameConfig.MERLIN_FRENZY_ATTACK = 2    -- ataque extra enquanto for o último vivo do time
GameConfig.MERLIN_FRENZY_HEAL = 8      -- cura ao entrar em Frenesi, uma vez por partida
GameConfig.MERLIN_FRENZY_KILL_HEAL = 2 -- cura por inimigo abatido durante o Frenesi

GameConfig.NEGATIVE_EFFECTS = {
	poison = true,
	charge = true,
	paralysis = true,
	freeze = true,
	wound = true,
}

function GameConfig.IsNegativeEffect(effectType)
	return GameConfig.NEGATIVE_EFFECTS[effectType] == true
end

GameConfig.FLAME_DURATION = 2
GameConfig.FLAME_DAMAGE = 2
GameConfig.FLAME_FURY_ATTACK = 2
GameConfig.FLAME_FURY_DURATION = 1
GameConfig.FLAME_FURY_MAX_ATTACK = 6
GameConfig.LUCY_FLAME_HEAL = 2

GameConfig.GUST_BLOCKED_DAMAGE = 1
GameConfig.ZEFF_PUSH_BLOCKED_BONUS = 1
GameConfig.WIND_BOOST_MOVE_BONUS = 1

GameConfig.WREN_RANGE = 4

GameConfig.ESTOPIM_DAMAGE = 10
GameConfig.ESTOPIM_DEATH_HOLD = 1.25

GameConfig.FINISH_HOLD_FINAL = 2.2
GameConfig.FINAL_KILL_HOLD = 3.3

GameConfig.VOLT_CHAIN_DAMAGE = 1
GameConfig.VOLT_CHARGES_TO_PARALYZE = 3
GameConfig.VOLT_CHARGE_DURATION = 2
GameConfig.PARALYSIS_DURATION = 1

GameConfig.MORN_SUMMON_IDS = { 21, 22 }
GameConfig.MORN_SUMMON_COOLDOWN = 0

GameConfig.SPYKE_AURA_ATTACK = 1
GameConfig.SPYKE_VENGEANCE_ATTACK = 1
GameConfig.SPYKE_VENGEANCE_DURATION = 1

GameConfig.RUSH_MOVE_RANGE = 4
GameConfig.MOMENTUM_PER_HEX = 1
GameConfig.DODGE_MIN_DISTANCE = 2

-- ===== FÚRIA (Bramm) =====
GameConfig.RAGE_BLOCKED_BONUS = 2
GameConfig.STEALTH_RANGE = 1
GameConfig.STEALTH_HEAL = 1
GameConfig.AMBUSH_BONUS_DAMAGE = 4

function GameConfig.EffectiveAttack(hero)
	if hero.stealth and table.find(hero.abilities or {}, "ambush") then
		return hero.attack + GameConfig.AMBUSH_BONUS_DAMAGE
	end
	return hero.attack
end

GameConfig.STEALTH_OWNER_TRANSPARENCY = 0.65

GameConfig.WEAK_POINT_HEAL = 2
GameConfig.GOLEM_SUMMON_IDS = { 15, 16 }
GameConfig.BARREL_HITS = 2 -- golpes até quebrar, independente do dano
GameConfig.BARREL_HEXES = { "B4", "D4" }

GameConfig.BARREL_HEAL_CHANCE = 0.5 -- o resto da chance vai pro bônus de ataque
GameConfig.BARREL_HEAL = 2
GameConfig.BARREL_ATTACK_BONUS = 1
GameConfig.BARREL_BUFF_DURATION = 1

GameConfig.ABILITIES = {
	SPRINT = "Sprint",
	TAUNT = "Taunt",
	RANGED = "Ranged",
	AGILITY = "Agility",
}

function GameConfig.HasAgility(hero)
	return hero ~= nil and hero.ability == GameConfig.ABILITIES.AGILITY
end

GameConfig.TURN_TIME_LIMIT = 60 -- segundos por turno; 0 desliga o cronômetro
GameConfig.PLACEMENT_TIME_LIMIT = 60
GameConfig.BOT_PLACE_DELAY = 0.8 -- pausa antes do bot escolher, pra dar pra acompanhar
GameConfig.RECONNECT_WINDOW = 90
GameConfig.PROMOTION_UNLOCK_TURN = 10
GameConfig.PROMOTION_HEX_FOR_SLOT = { [1] = "C0", [2] = "C7" }
GameConfig.GRAVE_HITS = 3
GameConfig.GRAVE_CURSE_DAMAGE = 1
GameConfig.RESURRECT_HP = 5
GameConfig.PLAYER_STAND_OUTSET_HEXES = 0.55 -- casas de folga entre a borda do tabuleiro e o competidor
GameConfig.PLAYER_STAND_SCALE = 2.2 -- tamanho dos personagens nas posições de espera (1 = normal)
GameConfig.UI_FONT_BODY = Enum.Font.BuilderSansMedium

GameConfig.MASTER_VOLUME = 0.55
GameConfig.HEX_COLOR_A = Color3.fromRGB(108, 90, 74)
GameConfig.HEX_COLOR_B = Color3.fromRGB(74, 61, 50)
GameConfig.ARENA_ORIGIN = Vector3.new(-233.7, 500, -1400)
GameConfig.ARENA_SPACING = 200
GameConfig.MAX_LIVE_MATCHES = 400

function GameConfig.MatchCapacity()
	local seats = game:GetService("Players").MaxPlayers
	if seats <= 0 then return GameConfig.MAX_LIVE_MATCHES end
	return math.max(1, math.min(GameConfig.MAX_LIVE_MATCHES, seats))
end

GameConfig.CAMERA_FOV = 38
GameConfig.CAMERA_ELEVATION = 44
GameConfig.CAMERA_AZIMUTH = 91
GameConfig.CAMERA_DISTANCE = 75

function GameConfig.MatchCameraCFrame(center, distance)
	distance = distance or GameConfig.CAMERA_DISTANCE

	local az = math.rad(GameConfig.CAMERA_AZIMUTH)
	local el = math.rad(GameConfig.CAMERA_ELEVATION)
	local horizontal = distance * math.cos(el)

	return CFrame.new(center + Vector3.new(
		math.sin(az) * horizontal,
		distance * math.sin(el),
		math.cos(az) * horizontal
	), center)
end

-- GRADE, não fileira. Enfileirar arenas só no X funcionava com 8 e virava um
-- muro com 80: a 200 studs cada, a fileira passa de 16.000 studs por volta do
-- slot 82, e é ali que a precisão de float do Roblox começa a tremer geometria e
-- física. A grade troca esse crescimento linear por raiz quadrada — 100 arenas
-- ocupam 13 colunas por 13 fileiras, uns 2.600 studs de lado, bem dentro da
-- região saudável.
--
-- Os 8 primeiros slots caem EXATAMENTE onde caíam antes (fileira 0 = a linha
-- original), então nada que já esteja montado à mão no place se move.
--
-- Fileira cresce pro Z NEGATIVO, afastando do lobby. Pro positivo, a nona arena
-- começaria a caminhar de volta pra debaixo das ilhas — que é justamente o que a
-- escolha do ARENA_ORIGIN evita (ver o comentário dele: sombra de ilha atravessada
-- no meio do tabuleiro).
GameConfig.ARENA_GRID_COLUMNS = 8

function GameConfig.ArenaOrigin(slot)
	local index = math.max(0, slot - 1)
	local column = index % GameConfig.ARENA_GRID_COLUMNS
	local row = math.floor(index / GameConfig.ARENA_GRID_COLUMNS)

	return GameConfig.ARENA_ORIGIN + Vector3.new(
		column * GameConfig.ARENA_SPACING,
		0,
		-row * GameConfig.ARENA_SPACING
	)
end

-- ===== RAIO DE SPAWN DO LOBBY =====
-- Os 19 SpawnLocations do lobby se espalham até ~30 studs do centro, e o pad
-- de PvP está a ~33 studs — um respawn azarado caía praticamente em cima do
-- pad e disparava a fila sozinho. Só valem spawns dentro deste raio.
GameConfig.LOBBY_SPAWN_RADIUS = 18

-- ===== ÍCONE DE CONEXÃO =====
GameConfig.PING_WARN_MS = 150
GameConfig.PING_BAD_MS = 400

return GameConfig
