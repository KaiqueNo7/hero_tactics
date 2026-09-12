--[[
	MatchManager.lua
	ModuleScript — ServerScriptService/Modules/MatchManager

	O ORQUESTRADOR da partida: ciclo de vida (começar, terminar, revanche,
	abandono, reconexão), fluxo de turnos e o laço do bot. As REGRAS moram nos
	serviços que ele chama — CombatCore, MovementService, AttackService,
	PlacementService, PromotionService, BoardObjectService, MatchOutcome.

	VÁRIAS PARTIDAS AO MESMO TEMPO
	Antes existia um único `match` de módulo — um jogo por servidor. Agora o
	módulo é um registro: cada partida é uma tabela própria, com o seu tabuleiro
	num slot de arena diferente (GameConfig.ArenaOrigin), suas pastas de heróis e
	túmulos, sua ocupação de casas e sua plateia de som. Toda função interna
	recebe o `match` em que está mexendo; nenhuma lê estado global. É isso que
	garante que uma partida não enxergue nem atrapalhe a outra.

	Cada jogador recebe o seu próprio snapshot, com `isMine`/`isMyTurn`/`winner`
	já do ponto de vista dele.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local Arenas = require(ReplicatedStorage.Modules.Arenas)
local HeroView = require(ServerScriptService.Modules.View.HeroView)
local MatchClock = require(ServerScriptService.Modules.Match.MatchClock)
local MatchSnapshot = require(ServerScriptService.Modules.Match.MatchSnapshot)
local MatchRewards = require(ServerScriptService.Modules.Match.MatchRewards)
local MatchLog = require(ServerScriptService.Modules.Match.MatchLog)
local MatchBroadcast = require(ServerScriptService.Modules.Match.MatchBroadcast)
local CombatCore = require(ServerScriptService.Modules.Combat.CombatCore)
local MatchRegistry = require(ServerScriptService.Modules.Match.MatchRegistry)
local PlacementService = require(ServerScriptService.Modules.Combat.PlacementService)
local MatchOutcome = require(ServerScriptService.Modules.Match.MatchOutcome)
local PromotionService = require(ServerScriptService.Modules.Combat.PromotionService)
local BoardObjectService = require(ServerScriptService.Modules.Combat.BoardObjectService)
local AttackService = require(ServerScriptService.Modules.Combat.AttackService)
local MovementService = require(ServerScriptService.Modules.Combat.MovementService)
local BotTurn = require(ServerScriptService.Modules.AI.BotTurn)
local TryTriggerPromotion = PromotionService.TryTrigger
local SetStance = PromotionService.SetStance
local BoardSpawner = require(ServerScriptService.Modules.Arena.BoardSpawner)
local LeaderboardService = require(ServerScriptService.Modules.Data.LeaderboardService)
local HeroUnlockService = require(ServerScriptService.Modules.Data.HeroUnlockService)
local Campaign = require(ReplicatedStorage.Modules.Campaign)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local SideOf = MatchQuery.SideOf
local OpponentSide = MatchQuery.OpponentSide
local LivingHeroesOf = MatchQuery.LivingHeroesOf

local BoardReady = ReplicatedStorage.Remotes.BoardReady

local MatchManager = {}

MatchManager.Resolvers = MatchOutcome.Resolvers

-- ===== AJUSTE FINO =====
local BOT_ID = "BOT"
local BOT_ONE_ID = "BOT_A"

-- ===== REGISTRO DE PARTIDAS =====
-- Quem existe neste servidor agora mora no MatchRegistry.

local DEFAULT_RULES = {
	draft = true,
	objects = true,
	promotion = true,
	suddenDeath = true,
	progression = true,
	resolve = "elimination",
	botPolicy = "brain",
	-- nil = usa o GameConfig.TURN_TIME_LIMIT. A ranqueada vai passar
	-- GameConfig.RANKED_TURN_TIME_LIMIT aqui; ninguém mais muda o ritmo.
	turnSeconds = nil,
}

local function BuildRules(overrides)
	local rules = {}
	for key, value in pairs(DEFAULT_RULES) do rules[key] = value end
	for key, value in pairs(overrides or {}) do rules[key] = value end
	return rules
end

-- declaradas cedo porque se chamam entre si
local BeginTurn
local EndMatch
local NextOpenFight

-- O Estilhaçar do Golem invoca pela API das skills (BuildSkillApi), que é
-- montada bem antes do CreateHero existir no arquivo.
local CreateHero

-- ===================== ZONAS =====================
-- Casas de largada fixas, uma por coluna, na primeira fileira de cada lado.
local DEPLOY_ZONES = {
	{ "A6", "B7", "C6", "D7", "E6" },
	{ "A1", "B1", "C1", "D1", "E1" },
}

local function BuildDeployZone(hexIds)
	local zone = {}
	for _, hexId in ipairs(hexIds) do
		if HexGrid.Exists(hexId) then
			table.insert(zone, hexId)
		else
			warn("MatchManager: hex de largada inexistente: " .. hexId)
		end
	end
	return zone
end

-- ===================== LADOS =====================
local SideOfPlayer = MatchRegistry.SideOfPlayer
local MatchOfPlayer = MatchRegistry.MatchOfPlayer

-- ===================== CONSULTAS =====================
local function UnlockedIdsFor(player)
	return HeroUnlockService.GetPlayableIds(player)
end

local function AllHeroIds()
	local ids = {}
	for _, data in ipairs(HeroData.CATALOG) do
		ids[data.id] = true
	end
	return ids
end


local function SetStandScale(player, scale)
	local character = player and player.Character
	if not character then return end
	pcall(function() character:ScaleTo(scale) end)
end

local LogEvent = MatchLog.Event
local Tally = MatchLog.Tally

local KillHero = CombatCore.KillHero
local TriggerSkills = CombatCore.TriggerSkills
local ApplyDamage = CombatCore.ApplyDamage
local ApplyStatusEffect = CombatCore.ApplyStatusEffect
local ProcessStatusEffects = CombatCore.ProcessStatusEffects
local TickFlames = CombatCore.TickFlames
local AllyOptionsFor = CombatCore.AllyOptionsFor
local BuildSkillApi = CombatCore.BuildSkillApi


local TurnLimit = MatchClock.TurnLimit
local TurnIsTimed = MatchClock.TurnIsTimed
local TurnSecondsLeft = MatchClock.TurnSecondsLeft

MatchSnapshot.Bind({
	AllyOptionsFor = AllyOptionsFor,
	NextOpenFight = function(player, fight) return NextOpenFight(player, fight) end,
})


local Broadcast = MatchBroadcast.Send

function CreateHero(match, dataId, ownerId, hexId)
	local data = HeroData.GetById(dataId)
	if not data then return nil end

	local hero = {
		uid = match.id .. "_" .. ownerId .. "_" .. dataId,
		dataId = dataId,
		name = data.name,
		ownerId = ownerId,
		sideIndex = SideOf(match, ownerId).index, -- 1 = azul, 2 = vermelho (o HeroView pinta)
		baseAttack = data.attack,
		attack = data.attack,
		maxHp = data.hp,
		currentHp = data.hp,
		ability = data.ability,
		abilities = data.abilities,
		attackRange = HeroData.GetAttackRange(data),
		moveRange = HeroData.GetMoveRange(data),
		deathSound = data.deathSound,
		deathHold = data.deathHold,
		attackSound = data.attackSound,
		position = hexId,
		isAlive = true,
		statusEffects = {},
		firstAttack = false,
		firstPunchApplied = false,
		frenzyActive = false, -- Merlin: Frenesi ligado agora
		frenzyHealed = false, -- Merlin: a cura de entrada do Frenesi já saiu
		stealth = false,

		weakPoint = math.random(HexGrid.DIRECTION_COUNT),
		weakPointTurn = match.turn and match.turn.number or 0,

		stats = {
			dealt = 0,
			taken = 0,
			healed = 0,
			kills = 0,
			biggestHit = 0,
			attacks = 0,
			turnsAlive = 0,
			ccApplied = 0,
			special = {},
		},
		noGrave = false,
		gravePending = false,
		graveOwner = nil,
		graveHex = nil, -- casa do último pedaço que caiu; é onde a lápide sobe

		skullCooldown = 0,
		summoner = nil,
		stance = data.stance,

		view = match.view,
	}

	local previous = match.heroes[hero.uid]
	if previous and not previous.isAlive then
		hero.stats = previous.stats

		if match.occupied[previous.position] == previous then
			match.occupied[previous.position] = nil
		end
		HeroView.ClearGrave(previous)
	end

	match.heroes[hero.uid] = hero
	match.occupied[hexId] = hero
	HeroView.Create(hero)
	HeroView.PlayPlaceSound(match.view)
	return hero
end

CombatCore.Bind({ CreateHero = CreateHero })
MatchOutcome.Bind({ EndMatch = function(match) return EndMatch(match) end })
PlacementService.Bind({
	CreateHero = CreateHero,
	BeginTurn = function(match, ownerId, number) return BeginTurn(match, ownerId, number) end,
})
PromotionService.Bind({ CreateHero = CreateHero })
BotTurn.Bind({ EndTurn = function(player, match) return MatchManager.EndTurn(player, match) end })

local AwardXp = MatchRewards.AwardXp

local CheckGameOver = MatchOutcome.CheckGameOver



local MatchIsLive = MatchRegistry.IsLive

function ArmTurnClock(match, token)
	if not TurnIsTimed(match) then return end

	local left = TurnSecondsLeft(match) or TurnLimit(match)

	task.delay(math.max(left, 0.1), function()
		if not (MatchIsLive(match) and match.turn and match.turn.token == token
			and match.phase == "battle") then return end

		if match.suspendedAt then return end
		if (TurnSecondsLeft(match) or 0) > 0 then
			ArmTurnClock(match, token)
			return
		end

		-- espera uma animação em curso terminar, senão o EndTurn seria recusado
		local waited = 0
		while MatchIsLive(match) and match.busy and waited < 3 do
			task.wait(0.1)
			waited += 0.1
		end

		if MatchIsLive(match) and match.turn and match.turn.token == token
			and match.phase == "battle" and not match.suspendedAt then
			Broadcast(match, "⏱ Tempo esgotado!")
			MatchManager.EndTurn(nil, match)
		end
	end)
end

function BeginTurn(match, ownerId, number)
	match.turnToken += 1
	local token = match.turnToken

	local side = SideOf(match, ownerId)
	LogEvent(match, "turn", side and side.index,
		("Turno %d — %s"):format(number, side and side.player and side.player.DisplayName or "Bot"))

	match.turn = {
		ownerId = ownerId,
		number = number,
		moved = {},
		attacked = {},
		bonusMove = {},
		weakChain = {},
		counterAttack = false,
		token = token,
		startedAt = os.clock(),
	}

	-- A oferta de aliado vale pelo turno em que nasceu. Zerar aqui, ANTES do
	-- onTurnStart, é o que faz a lista ser recalculada do zero a cada turno de
	-- quem abre a oferta (quem ganhou escudo no turno passado some das opções
	-- sozinho), o que fecha a oferta que o jogador escolheu ignorar, e o que
	-- limita a Troca do Shin a uma por turno sem inventar contador de ação.
	match.pendingAlly = {}

	CombatCore.AgeWeakPoints(match)

	-- onTurnStart dispara pros heróis dos DOIS lados (igual ao Phaser)
	for _, hero in pairs(match.heroes) do
		if hero.isAlive then
			TriggerSkills(match, hero, "onTurnStart")
		end
	end

	local message = nil
	if match.rules.suddenDeath and number == GameConfig.SUDDEN_DEATH_WARNING_TURN then
		message = "Morte Súbita se aproxima!"
	end

	if match.rules.suddenDeath and number >= GameConfig.SUDDEN_DEATH_START_TURN then
		message = "Morte Súbita: todos perdem 1 de vida!"
		for _, hero in pairs(match.heroes) do
			if hero.isAlive then
				ApplyDamage(match, hero, GameConfig.SUDDEN_DEATH_DAMAGE, nil, false, nil, "suddenDeath")
			end
		end
	end

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	Broadcast(match, message)

	-- cronômetro: encerra o turno sozinho quando o tempo acaba
	ArmTurnClock(match, token)

	local promotionHex = side and GameConfig.PROMOTION_HEX_FOR_SLOT[side.index]
	local standing = promotionHex and match.occupied[promotionHex]
	if standing and standing.isAlive and standing.ownerId == ownerId then
		TryTriggerPromotion(match, standing)
	end

	if SideOf(match, ownerId).isBot then
		BotTurn.Play(match, ownerId)
	end
end

function MatchManager.EndTurn(player, match)
	match = match or MatchOfPlayer(player)
	if not match or match.phase ~= "battle" then return end
	if match.busy then return end
	if match.suspendedAt then return end
	-- ESCOLHA ABERTA NA VIRADA DO TURNO. A decisão é feita com o relógio do turno
	-- correndo, sem prazo próprio: são dois túmulos, não uma deliberação.
	--
	-- Quem não escolheu perde a escolha, não o uso: deixar a Casa de Promoção
	-- passar em branco custaria ao jogador um recurso de uma vez por partida por
	-- ter demorado. O SORTEIO é de propósito — usar a conta tática do bot daria
	-- ao jogador que estourou o tempo a mesma qualidade de quem decidiu, e isso
	-- premia estourar. Bot continua com a conta dele, que é o turno dele.
	if match.pendingPromotion then
		if player then return end

		local dono = SideOf(match, match.pendingPromotion.ownerId)
		local opcoes = match.pendingPromotion.options

		-- A lista nasce com pelo menos um túmulo (o TryTriggerPromotion nem abre
		-- a escolha sem isso), mas ela é guardada e lida um turno depois. Vazia,
		-- `math.random(0)` estoura — e estourar aqui trava a virada de turno.
		if #opcoes == 0 then
			match.pendingPromotion = nil
		else
			local escolhido = (dono and dono.isBot)
				and BotTurn.PickResurrection(match, match.pendingPromotion.ownerId, opcoes)
				or opcoes[math.random(#opcoes)]

			MatchManager.Resurrect(nil, escolhido, match)
		end
	end

	local currentSide = SideOf(match, match.turn.ownerId)
	if player and currentSide.player ~= player then return end

	local endingOwner = match.turn.ownerId
	for _, hero in pairs(match.heroes) do
		if hero.isAlive then
			local ownTurnEnding = hero.ownerId == endingOwner
			if ownTurnEnding then hero.stats.turnsAlive += 1 end
			ProcessStatusEffects(match, hero, ownTurnEnding)

			if ownTurnEnding and hero.isAlive then
				TriggerSkills(match, hero, "onTurnEnd")
			end
		end
	end

	TickFlames(match, endingOwner)

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	local wasStarter = (endingOwner == match.starterId)
	local nextOwner = OpponentSide(match, endingOwner).id
	local nextNumber = match.turn.number + (wasStarter and 0 or 1)

	BeginTurn(match, nextOwner, nextNumber)
end



local STREAM_TIMEOUT = 5

local function StreamArenaTo(players, origin)
	if not Workspace.StreamingEnabled then return end

	local center = HexGrid.GetBoardCenter(origin)
	local pending = 0

	for _, player in ipairs(players) do
		if player and player.Parent then
			pending += 1
			task.spawn(function()
				local ok, err = pcall(function()
					player:RequestStreamAroundAsync(center, STREAM_TIMEOUT)
				end)
				if not ok then
					warn(("MatchManager: streaming da arena falhou para %s: %s")
						:format(player.Name, tostring(err)))
				end
				pending -= 1
			end)
		end
	end

	local waited = 0
	while pending > 0 and waited < STREAM_TIMEOUT + 1 do
		task.wait(0.1)
		waited += 0.1
	end
end

local AllocateSlot = MatchRegistry.AllocateSlot

function MatchManager.MoveHero(player, heroUid, hexId, match)
	MovementService.MoveHero(player, heroUid, hexId, match)
end

function MatchManager.AttackHero(player, attackerUid, targetUid, match)
	AttackService.AttackHero(player, attackerUid, targetUid, match)
end

function MatchManager.PlaceHero(player, dataId, hexId)
	PlacementService.PlaceHero(player, dataId, hexId)
end

function MatchManager.Resurrect(player, heroUid, match)
	PromotionService.Resurrect(player, heroUid, match)
end

function MatchManager.ResolveAllyChoice(player, sourceUid, heroUid, match)
	PromotionService.ResolveAllyChoice(player, sourceUid, heroUid, match)
end

function MatchManager.HasFreeSlot()
	return true
end

function MatchManager.IsInMatch(player)
	return MatchOfPlayer(player) ~= nil
end

function MatchManager.StartMatch(playerOne, playerTwo, slot, fight, options)
	local botVsBot = options ~= nil and options.botVsBot == true
	local sandbox = options ~= nil and options.sandbox == true
	if not playerOne and not botVsBot then return false end

	local rules = BuildRules(options and options.rules)
	if sandbox then
		rules.draft = false
		rules.objects = false
		rules.promotion = false
		rules.suddenDeath = false
		rules.progression = false
		rules.resolve = "manual"
	end
	if botVsBot then rules.progression = false end

	slot = slot or AllocateSlot()
	if not slot then return false end

	local matchId = MatchRegistry.NextId()
	local origin = GameConfig.ArenaOrigin(slot)

	local players = {}
	if playerOne then table.insert(players, playerOne) end
	if playerTwo then table.insert(players, playerTwo) end

	local theme = (options and options.theme) or Arenas.ForMatch(fight)
	local boardFolder = BoardSpawner.SpawnBoard(slot, playerTwo == nil, fight and fight.hero, theme)
	if boardFolder then boardFolder:SetAttribute("MatchId", matchId) end

	local sides = {
		{
			index = 1,
			id = playerOne and tostring(playerOne.UserId) or BOT_ONE_ID,
			player = playerOne,
			name = playerOne and playerOne.DisplayName or "Bot",
			isBot = playerOne == nil,
			zone = BuildDeployZone(DEPLOY_ZONES[1]),
			placedCount = 0,
			promotionUsed = false, -- este lado gastou a Casa de Promoção (a cota é PROMOTION_TEAMS_PER_MATCH)
		},
		{
			index = 2,
			id = playerTwo and tostring(playerTwo.UserId) or BOT_ID,
			player = playerTwo,
			name = playerTwo and playerTwo.DisplayName or "Bot",
			isBot = playerTwo == nil,
			zone = BuildDeployZone(DEPLOY_ZONES[2]),
			placedCount = 0,
			promotionUsed = false,
		},
	}

	sides[1].unlockedIds = playerOne and UnlockedIdsFor(playerOne) or AllHeroIds()
	sides[2].unlockedIds = playerTwo and UnlockedIdsFor(playerTwo) or sides[1].unlockedIds
	sides[2].roster = fight and fight.team or nil

	if options and options.rosters then
		sides[1].roster = options.rosters[1]
		sides[2].roster = options.rosters[2]
	end

	local sideIndexById = {}
	for index, side in ipairs(sides) do
		sideIndexById[side.id] = index
	end

	local match = {
		id = matchId,
		slot = slot,
		origin = origin,
		boardFolder = boardFolder,
		view = HeroView.CreateView(matchId, origin, players, theme),
		theme = theme,
		sides = sides,
		sideIndexById = sideIndexById,
		vsBot = playerTwo == nil,
		rematch = {},
		rematchOpen = true,
		fight = fight,
		simulated = botVsBot,
		sandbox = sandbox,
		rules = rules,
		challenge = options and options.challenge or nil,
		onFinish = options and options.onFinish or nil,
		onStats = options and options.onStats or nil,
		phase = "placement",
		heroes = {},
		barrels = {},
		nextBarrelId = 0,
		occupied = {},
		flames = {},
		log = {},
		usedHeroIds = {},
		placementSide = 1, -- lado 1 escolhe primeiro: 1,2,1,2...
		placementToken = 0,
		placementStartedAt = nil,
		starterId = sides[math.random(2)].id,
		turn = nil,
		turnToken = 0,
		winner = nil,
		finisher = nil,
		lastDeath = nil,
		lastSeen = {},
		busy = false,
		pendingPromotion = nil, -- ver TryTriggerPromotion/MatchManager.Resurrect
		pendingAlly = {}, -- ver OfferAllyChoice/MatchManager.ResolveAllyChoice
	}

	match.skillApi = BuildSkillApi(match)

	MatchRegistry.Add(match)

	if rules.objects then BoardObjectService.SpawnBarrels(match) end

	StreamArenaTo(players, origin)

	local hexSize = HexGrid.GetHexSize()
	if playerOne then
		SetStandScale(playerOne, GameConfig.PLAYER_STAND_SCALE)
		BoardReady:FireClient(playerOne, hexSize, origin, 1)
	end
	if playerTwo then
		SetStandScale(playerTwo, GameConfig.PLAYER_STAND_SCALE)
		BoardReady:FireClient(playerTwo, hexSize, origin, 2)
	end

	HeroView.PlayMatchSound(match.view, "MatchStart")

	if not rules.draft then
		match.phase = "battle"
		if rules.resolve ~= "challenge" then
			BeginTurn(match, sides[1].id, 1)
		end
	else
		PlacementService.StartClock(match)
		Broadcast(match)

		if sides[1].isBot then
			task.delay(GameConfig.BOT_PLACE_DELAY, function()
				PlacementService.BotPlaceOne(match)
			end)
		end
	end

	local label = playerTwo and "PvP" or (playerOne and "vs bot" or "bot vs bot")
	print(("MatchManager: partida %d no slot %d (%s)."):format(matchId, slot, label))
	return true
end

local function ClearScene(match)
	HeroView.ClearMatch(match.view)

	match.sceneToken = (match.sceneToken or 0) + 1
	match.turnToken += 1

	if match.turn then
		match.turn.moved = {}
		match.turn.attacked = {}
		match.turn.bonusMove = {}
		match.turn.weakChain = {}
		match.turn.counterAttack = false
		match.turn.token = match.turnToken
	end

	match.heroes = {}
	match.occupied = {}
	match.barrels = {}
	match.flames = {}
	match.usedHeroIds = {}
	match.lastSeen = {}
	match.log = {}
	match.pendingPromotion = nil
	match.pendingAlly = {}
	match.finisher = nil
	match.lastDeath = nil
	match.winner = nil
	match.message = nil
	match.statsRecorded = nil
	match.fightStars = nil
	match.starsDone = nil
	match.busy = false
	match.phase = "battle"
end

function EndMatch(match)
	HeroView.ClearMatch(match.view)
	HeroView.DestroyView(match.view)

	if match.boardFolder and match.boardFolder.Parent then
		match.boardFolder:Destroy()
	end

	for _, side in ipairs(match.sides) do
		if side.player then
			SetStandScale(side.player, 1)
			MatchBroadcast.ToLobby(side.player)
		end
	end

	MatchRegistry.Remove(match)
end

function NextOpenFight(player, justWon)
	return Campaign.NextOpen(HeroUnlockService.GetEarnedIds(player), justWon)
end

local function RestartMatch(match, fight)
	local playerOne = match.sides[1].player
	local playerTwo = match.sides[2].player
	local slot = match.slot

	if not playerOne then
		playerOne, playerTwo = playerTwo, nil
	end
	if not playerOne then return end

	HeroView.ClearMatch(match.view)
	HeroView.DestroyView(match.view)
	MatchRegistry.Remove(match)

	MatchManager.StartMatch(playerOne, playerTwo, slot, fight, { theme = match.theme })
end

function MatchManager.Replay(player)
	local match = MatchOfPlayer(player)
	if not match or match.phase ~= "finished" then return end
	if match.challenge then return end

	if not match.vsBot then
		local side = SideOfPlayer(match, player)
		if not side or not match.rematchOpen then return end

		match.rematch[side.id] = true

		for _, other in ipairs(match.sides) do
			if other.player and not match.rematch[other.id] then
				Broadcast(match)
				return
			end
		end

		RestartMatch(match, match.fight)
		return
	end

	local fight = match.fight
	if fight and match.winner == tostring(player.UserId) then
		fight = NextOpenFight(player, fight) or fight
	end

	RestartMatch(match, fight)
end

local function AwardAbandon(match, leavingSide)
	if match.phase == "finished" then return end

	local stayingSide = match.sides[leavingSide.index == 1 and 2 or 1]
	if not stayingSide.player or stayingSide.isBot then return end

	local survivors = math.max(#LivingHeroesOf(match, stayingSide.id), 1)
	AwardXp(match, stayingSide, "win", survivors)
end

function MatchManager.LeaveMatch(player)
	local match = MatchOfPlayer(player)
	if not match then return end

	local side = SideOfPlayer(match, player)

	if match.phase == "finished" and side and not match.vsBot then
		match.rematchOpen = false
		side.player = nil

		SetStandScale(player, 1)
		MatchBroadcast.ToLobby(player)

		for _, other in ipairs(match.sides) do
			if other.player then
				Broadcast(match)
				return
			end
		end
	end

	if side then AwardAbandon(match, side) end

	EndMatch(match)
end

local function SuspendForReconnect(match, side)
	match.suspendedAt = os.clock()
	match.suspendedId = side.id
	match.suspendedName = side.name or "Adversário"
	side.awaitingReconnect = true

	if match.turn then
		match.turn.pausedLeft = TurnSecondsLeft(match)
	end
	match.placementToken += 1

	Broadcast(match)

	local stamp = match.suspendedAt
	task.delay(GameConfig.RECONNECT_WINDOW, function()
		if not MatchIsLive(match) then return end
		if match.suspendedAt ~= stamp then return end

		MatchManager.ForfeitDisconnected(match)
	end)
end

function MatchManager.ResumeFromReconnect(match, side, player)
	match.suspendedAt = nil
	match.suspendedId = nil
	match.suspendedName = nil
	side.awaitingReconnect = nil
	side.player = player

	SetStandScale(player, GameConfig.PLAYER_STAND_SCALE)

	StreamArenaTo({ player }, match.origin)
	BoardReady:FireClient(player, HexGrid.GetHexSize(), match.origin, side.index)

	if match.phase == "placement" then
		PlacementService.StartClock(match)
	elseif match.turn then
		local limite = TurnLimit(match)
		match.turn.startedAt = os.clock() - (limite - (match.turn.pausedLeft or limite))
		match.turn.pausedLeft = nil
		ArmTurnClock(match, match.turn.token)
	end

	Broadcast(match, ("%s voltou para a partida."):format(side.name or "O adversário"))
end

function MatchManager.ForfeitDisconnected(match)
	if match.phase == "finished" then return end

	local losingSide, winningSide
	for _, side in ipairs(match.sides) do
		if side.id == match.suspendedId then losingSide = side else winningSide = side end
	end
	if not (losingSide and winningSide) then return end

	local ranked, why = MatchOutcome.IsRankedPvp(match)

	match.suspendedAt = nil
	match.suspendedId = nil
	match.suspendedName = nil
	losingSide.awaitingReconnect = nil

	match.phase = "finished"
	match.winner = winningSide.id

	if not match.rankingDone then
		match.rankingDone = true

		if ranked and winningSide.player then
			print(("[Ranking] vitoria por desconexao registrada para %s"):format(winningSide.player.Name))
			LeaderboardService.RecordWin(tonumber(winningSide.id))
		else
			print(("[Ranking] desconexao ignorada — %s"):format(why or "sem vencedor humano"))
		end
	end

	AwardXp(match, winningSide, "win", math.max(#LivingHeroesOf(match, winningSide.id), 1))
	losingSide.player = nil

	Broadcast(match, "Adversário não voltou a tempo.")
end

function MatchManager.HandlePlayerLeft(player)
	local match = MatchOfPlayer(player)
	if not match then return end

	local side = SideOfPlayer(match, player)
	if not side then return end

	local other = match.sides[side.index == 1 and 2 or 1]
	local canWait = GameConfig.RECONNECT_WINDOW > 0
		and match.phase ~= "finished"
		and not match.vsBot
		and not match.fight
		and other.player ~= nil
		and not match.suspendedAt

	if canWait then
		side.player = nil
		SuspendForReconnect(match, side)
		return
	end

	AwardAbandon(match, side)
	side.player = nil
	EndMatch(match)
end

function MatchManager.HandlePlayerRejoined(player)
	local wanted = tostring(player.UserId)

	for _, match in pairs(MatchRegistry.All()) do
		if match.suspendedAt and match.suspendedId == wanted then
			for _, side in ipairs(match.sides) do
				if side.id == wanted and side.awaitingReconnect then
					MatchManager.ResumeFromReconnect(match, side, player)
					return true
				end
			end
		end
	end

	return false
end

function MatchManager.GetLog(player)
	local match = MatchOfPlayer(player)
	return match and match.log or {}
end

function MatchManager.ActiveCount()
	return MatchRegistry.Count()
end

MatchManager.Internal = {
	MatchOfPlayer = MatchOfPlayer,
	CreateHero = CreateHero,
	CreateBarrel = BoardObjectService.CreateBarrel,
	KillHero = KillHero,
	PerformAttack = AttackService.PerformAttack,
	TriggerSkills = TriggerSkills,
	ApplyStatusEffect = ApplyStatusEffect,
	Broadcast = Broadcast,
	BeginTurn = BeginTurn,
	ClearScene = ClearScene,
	EndMatch = EndMatch,
	SetStance = SetStance,
}

return MatchManager
