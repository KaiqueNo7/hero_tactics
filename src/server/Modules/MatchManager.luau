--[[
	MatchManager.lua
	ModuleScript — ServerScriptService/Modules/MatchManager

	Estado autoritativo da partida: draft alternado (1,2,1,2), movimento,
	combate, skills, turnos cronometrados e revanche.

	Não desenha nada: toda a apresentação está no HeroView. Este módulo só
	decide o que aconteceu e manda o HeroView mostrar.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local Skills = require(ServerScriptService.Modules.Skills)
local HeroView = require(ServerScriptService.Modules.HeroView)

local MatchUpdate = ReplicatedStorage.Remotes.MatchUpdate

local MatchManager = {}

-- aliases: mantêm as chamadas de sempre funcionando, agora servidas pelo HeroView
local UpdateHeroVisual = HeroView.UpdateStats
local Say = HeroView.Say

-- ===== AJUSTE FINO =====
local DEPLOY_ROWS = 2
local BOT_ACTION_DELAY = 0.7
local COUNTER_ATTACK_DELAY = 0.4

local BOT_ID = "BOT"

local match = nil
local turnToken = 0
local SkillApi

-- ===================== ZONAS =====================
-- Casas de largada fixas, uma por coluna, na primeira fileira de cada lado.
local PLAYER_1 = { "A6", "B7", "C6", "D7", "E6" }
local PLAYER_2 = { "A1", "B1", "C1", "D1", "E1" }

local function BuildDeployZones()
	local playerZone, botZone = {}, {}

	for _, hexId in ipairs(PLAYER_1) do
		if HexGrid.GetHex(hexId) then
			table.insert(playerZone, hexId)
		else
			warn("MatchManager: hex de largada inexistente: " .. hexId)
		end
	end

	for _, hexId in ipairs(PLAYER_2) do
		if HexGrid.GetHex(hexId) then
			table.insert(botZone, hexId)
		else
			warn("MatchManager: hex de largada inexistente: " .. hexId)
		end
	end

	return playerZone, botZone
end

-- ===================== CONSULTAS =====================
local function GetHeroAt(hexId)
	local hex = HexGrid.GetHex(hexId)
	return hex and hex.occupiedBy or nil
end

local function GetAlliesInRange(hero, range)
	local allies = {}
	for _, other in pairs(match.heroes) do
		if other ~= hero and other.isAlive and other.ownerId == hero.ownerId then
			if HexGrid.Distance(hero.position, other.position) <= range then
				table.insert(allies, other)
			end
		end
	end
	return allies
end

local function LivingHeroesOf(ownerId)
	local result = {}
	for _, hero in pairs(match.heroes) do
		if hero.ownerId == ownerId and hero.isAlive then
			table.insert(result, hero)
		end
	end
	return result
end

-- ===================== SKILLS =====================
local function TriggerSkills(hero, triggerName, target, isCounterAttack, ctx)
	if not hero.isAlive and triggerName ~= "onDie" then return end

	for _, key in ipairs(hero.abilities) do
		local skill = Skills[key]
		if skill and skill.apply and table.find(skill.triggers, triggerName) then
			local scope = ctx or {}
			scope.hero = hero
			scope.target = target
			scope.isCounterAttack = isCounterAttack or false
			scope.api = setmetatable({
				Say = function(target, text) HeroView.Say(target, text, key) end,
			}, { __index = SkillApi })

			local ok, err = pcall(skill.apply, scope)
			if not ok then
				warn(("Skill %s falhou em %s: %s"):format(key, hero.name, tostring(err)))
			end
			UpdateHeroVisual(hero)
		end
	end
end

-- ===================== DANO / CURA =====================
local ApplyDamage, KillHero

function KillHero(hero)
	hero.isAlive = false
	-- a casa NÃO é liberada: o túmulo continua ocupando o hex
	TriggerSkills(hero, "onDie")

	HeroView.PlayAnimation(hero, "die")
	HeroView.Destroy(hero)
	HeroView.CreateGrave(hero)

	print(("%s foi derrotado! O túmulo bloqueia %s."):format(hero.name, hero.position))
end

function ApplyDamage(hero, amount, attacker, isCounterAttack)
	if not hero.isAlive then return end

	-- passivas que reduzem dano recebido (ex: autoDefense do Ralph)
	for _, key in ipairs(hero.abilities) do
		local skill = Skills[key]
		if skill and skill.modifyIncomingDamage then
			amount = skill.modifyIncomingDamage(amount, {
				hero = hero, attacker = attacker, isCounterAttack = isCounterAttack or false,
			})
		end
	end

	-- efeito 'wound' soma dano extra (mesma regra do hero.js)
	for _, effect in ipairs(hero.statusEffects) do
		if effect.type == "wound" then amount += 1 end
	end

	hero.currentHp -= amount
	UpdateHeroVisual(hero)
	HeroView.PlayAnimation(hero, "hit")
	Say(hero, "-" .. tostring(amount), "damage")

	if hero.currentHp <= 0 then
		KillHero(hero)
	else
		TriggerSkills(hero, "onDamage", attacker, isCounterAttack)
	end
end

local function Heal(hero, amount)
	if not hero.isAlive then return end
	hero.currentHp = math.min(hero.currentHp + amount, hero.maxHp)
	UpdateHeroVisual(hero)
	HeroView.PlayHealSound(hero)
	Say(hero, "+" .. tostring(amount), "heal")
end

local function IncreaseAttack(hero, amount)
	hero.attack += amount
	UpdateHeroVisual(hero)
	Say(hero, (amount > 0 and "+" or "") .. tostring(amount) .. " ATK", amount > 0 and "buff" or "debuff")
end

-- ===================== STATUS EFFECTS =====================
local function FindStatusEffect(hero, effectType)
	for _, effect in ipairs(hero.statusEffects) do
		if effect.type == effectType then return effect end
	end
	return nil
end

local function ApplyStatusEffect(hero, effect)
	table.insert(hero.statusEffects, effect)
	UpdateHeroVisual(hero)
end

local function ClearStatusEffects(hero)
	hero.statusEffects = {}
	UpdateHeroVisual(hero)
end

-- Roda no fim do turno do próprio herói: aplica o efeito e decrementa
local function ProcessStatusEffects(hero)
	local remaining = {}

	for _, effect in ipairs(hero.statusEffects) do
		if effect.damagePerTurn then
			ApplyDamage(hero, effect.damagePerTurn, nil, false)
		end
		if effect.duration > 1 then
			effect.duration -= 1
			table.insert(remaining, effect)
		end
	end

	hero.statusEffects = remaining
	UpdateHeroVisual(hero)
end

-- ===================== MOVIMENTO =====================
-- Reposiciona sem bookkeeping de turno — usado pelo empurrão do rage
local function ForceMove(hero, hexId)
	if not HexGrid.IsFree(hexId) then return false end

	HexGrid.ClearOccupant(hero.position)
	hero.position = hexId
	HexGrid.SetOccupant(hexId, hero)
	HeroView.SetPosition(hero, hexId)
	return true
end

-- ===================== API DAS SKILLS =====================
SkillApi = {
	ApplyDamage = function(hero, amount, attacker, isCounterAttack)
		ApplyDamage(hero, amount, attacker, isCounterAttack)
	end,
	Heal = Heal,
	IncreaseAttack = IncreaseAttack,
	GetHeroAt = GetHeroAt,
	GetAlliesInRange = GetAlliesInRange,
	GetLineBeyond = HexGrid.GetLineBeyond,
	IsFree = HexGrid.IsFree,
	ForceMove = ForceMove,
	FindStatusEffect = FindStatusEffect,
	ApplyStatusEffect = ApplyStatusEffect,
	ClearStatusEffects = ClearStatusEffects,
	Say = Say,
}

-- ===================== SNAPSHOT =====================
local function TurnSecondsLeft()
	if not match.turn or GameConfig.TURN_TIME_LIMIT <= 0 then return nil end
	local elapsed = os.clock() - match.turn.startedAt
	return math.max(0, math.floor(GameConfig.TURN_TIME_LIMIT - elapsed))
end

local function Snapshot()
	local heroes = {}
	for _, hero in pairs(match.heroes) do
		table.insert(heroes, {
			uid = hero.uid,
			dataId = hero.dataId,
			name = hero.name,
			position = hero.position,
			currentHp = hero.currentHp,
			maxHp = hero.maxHp,
			attack = hero.attack,
			ability = hero.ability,
			attackRange = hero.attackRange,
			moveRange = hero.moveRange,
			isAlive = hero.isAlive,
			isMine = hero.ownerId ~= BOT_ID,
			hasMoved = match.turn and match.turn.moved[hero.uid] or false,
			hasAttacked = match.turn and match.turn.attacked[hero.uid] or false,
		})
	end

	return {
		phase = match.phase,
		deployZone = match.playerZone,
		placedCount = match.placedCount,
		botPlacedCount = match.botPlacedCount,
		placementOwner = match.placementOwner,
		heroesPerPlayer = GameConfig.HEROES_PER_PLAYER,
		usedHeroIds = match.usedHeroIds,
		heroes = heroes,
		turnNumber = match.turn and match.turn.number or 0,
		isMyTurn = match.turn and match.turn.ownerId == match.playerId or false,
		turnSecondsLeft = TurnSecondsLeft(),
		turnTimeLimit = GameConfig.TURN_TIME_LIMIT,
		suddenDeath = match.turn and match.turn.number >= GameConfig.SUDDEN_DEATH_START_TURN or false,
		winner = match.winner,
		message = match.message,
	}
end

local function Broadcast(message)
	match.message = message
	MatchUpdate:FireClient(match.player, Snapshot())
	match.message = nil
end

-- ===================== HERÓIS =====================
local function CreateHero(dataId, ownerId, hexId)
	local data = HeroData.GetById(dataId)
	if not data then return nil end

	local hero = {
		uid = ownerId .. "_" .. dataId,
		dataId = dataId,
		name = data.name,
		ownerId = ownerId,
		baseAttack = data.attack,
		attack = data.attack,
		maxHp = data.hp,
		currentHp = data.hp,
		ability = data.ability,
		abilities = data.abilities,
		attackRange = HeroData.GetAttackRange(data),
		moveRange = HeroData.GetMoveRange(data),
		position = hexId,
		isAlive = true,
		statusEffects = {},
		firstAttack = false,
		firstPunchApplied = false,
	}

	match.heroes[hero.uid] = hero
	HexGrid.SetOccupant(hexId, hero)
	HeroView.Create(hero)
	return hero
end

-- ===================== FIM DE JOGO =====================
local function CheckGameOver()
	local playerAlive = #LivingHeroesOf(match.playerId)
	local botAlive = #LivingHeroesOf(BOT_ID)

	if playerAlive == 0 or botAlive == 0 then
		match.phase = "finished"
		if playerAlive == 0 and botAlive == 0 then
			match.winner = "draw"
		else
			match.winner = (botAlive == 0) and "player" or "bot"
		end
		return true
	end
	return false
end

local function ResultMessage()
	if match.winner == "draw" then return "Empate!" end
	return match.winner == "player" and "Você venceu!" or "Você perdeu!"
end

-- ===================== COMBATE =====================
local function PerformAttack(attacker, target, isCounterAttack)
	HeroView.PlayAnimation(attacker, "attack")
	HeroView.PlayAttackSound(attacker)
	if attacker.attackRange >= 2 then
		HeroView.ShowRangedAttack(attacker, target)
	end

	local ctx = { damageApplied = false }
	TriggerSkills(attacker, isCounterAttack and "onCounterAttack" or "onAttack",
		target, isCounterAttack, ctx)

	if not ctx.damageApplied and target.isAlive then
		ApplyDamage(target, attacker.attack, attacker, isCounterAttack)
	end

	attacker.firstAttack = true
	UpdateHeroVisual(attacker)
end

-- ===================== TURNOS =====================
local BeginTurn

local function BotPlayTurn()
	task.spawn(function()
		task.wait(BOT_ACTION_DELAY)

		for _, hero in ipairs(LivingHeroesOf(BOT_ID)) do
			if not match or match.phase ~= "battle" or match.turn.ownerId ~= BOT_ID then return end

			if hero.isAlive then
				-- move em direção ao inimigo mais fraco
				if not match.turn.moved[hero.uid] and not match.turn.attacked[hero.uid] then
					local enemies = LivingHeroesOf(match.playerId)
					if #enemies > 0 then
						local weakest = enemies[1]
						for _, enemy in ipairs(enemies) do
							if enemy.currentHp < weakest.currentHp then weakest = enemy end
						end

						local reach = HexGrid.ComputeReach(hero.position, hero.moveRange)
						local bestHex, bestDist = nil, math.huge
						for hexId in pairs(reach) do
							if HexGrid.IsFree(hexId) then
								local d = HexGrid.Distance(hexId, weakest.position)
								if d < bestDist then bestDist, bestHex = d, hexId end
							end
						end

						if bestHex then
							MatchManager.MoveHero(nil, hero.uid, bestHex)
							task.wait(BOT_ACTION_DELAY)
						end
					end
				end

				if not match or match.phase ~= "battle" then return end

				-- ataca quem estiver ao alcance
				if hero.isAlive and not match.turn.attacked[hero.uid] then
					local reach = HexGrid.ComputeReach(hero.position, hero.attackRange)
					for hexId in pairs(reach) do
						local occupant = GetHeroAt(hexId)
						if occupant and occupant.isAlive and occupant.ownerId ~= BOT_ID then
							MatchManager.AttackHero(nil, hero.uid, occupant.uid)
							task.wait(BOT_ACTION_DELAY)
							break
						end
					end
				end
			end
		end

		if match and match.phase == "battle" and match.turn.ownerId == BOT_ID then
			MatchManager.EndTurn(nil)
		end
	end)
end

function BeginTurn(ownerId, number)
	turnToken += 1
	local token = turnToken

	match.turn = {
		ownerId = ownerId,
		number = number,
		moved = {},
		attacked = {},
		counterAttack = false,
		token = token,
		startedAt = os.clock(),
	}

	-- onTurnStart dispara pros heróis dos DOIS lados (igual ao Phaser)
	for _, hero in pairs(match.heroes) do
		if hero.isAlive then
			TriggerSkills(hero, "onTurnStart")
		end
	end

	local message = nil
	if number == GameConfig.SUDDEN_DEATH_WARNING_TURN then
		message = "⚠ Morte Súbita se aproxima!"
	end

	if number >= GameConfig.SUDDEN_DEATH_START_TURN then
		for _, hero in pairs(match.heroes) do
			if hero.isAlive then
				ApplyDamage(hero, GameConfig.SUDDEN_DEATH_DAMAGE, nil, false)
			end
		end
		message = "☠ Morte Súbita: todos perdem 1 de vida!"
	end

	if CheckGameOver() then
		Broadcast(ResultMessage())
		return
	end

	Broadcast(message)

	-- cronômetro: encerra o turno sozinho quando o tempo acaba
	if GameConfig.TURN_TIME_LIMIT > 0 then
		task.delay(GameConfig.TURN_TIME_LIMIT, function()
			if not (match and match.turn and match.turn.token == token and match.phase == "battle") then return end

			-- espera uma animação em curso terminar, senão o EndTurn seria recusado
			local waited = 0
			while match and match.busy and waited < 3 do
				task.wait(0.1)
				waited += 0.1
			end

			if match and match.turn and match.turn.token == token and match.phase == "battle" then
				Broadcast("⏱ Tempo esgotado!")
				MatchManager.EndTurn(nil)
			end
		end)
	end

	if ownerId == BOT_ID then
		BotPlayTurn()
	end
end

function MatchManager.EndTurn(player)
	if not match or match.phase ~= "battle" then return end
	if match.busy then return end
	if player and (match.player ~= player or match.turn.ownerId ~= match.playerId) then return end

	-- fim de turno de quem está encerrando: veneno primeiro, depois skills
	local endingOwner = match.turn.ownerId
	for _, hero in pairs(match.heroes) do
		if hero.ownerId == endingOwner and hero.isAlive then
			ProcessStatusEffects(hero)
			if hero.isAlive then
				TriggerSkills(hero, "onTurnEnd")
			end
		end
	end

	if CheckGameOver() then
		Broadcast(ResultMessage())
		return
	end

	local wasStarter = (endingOwner == match.starterId)
	local nextOwner = (endingOwner == match.playerId) and BOT_ID or match.playerId
	local nextNumber = match.turn.number + (wasStarter and 0 or 1)

	BeginTurn(nextOwner, nextNumber)
end

-- ===================== AÇÕES =====================
-- player == nil significa ação do bot (já validada internamente)
local function AuthorizeAction(player, hero)
	if not match or match.phase ~= "battle" then return false end
	if match.busy then return false end
	if not hero or not hero.isAlive then return false end
	if hero.ownerId ~= match.turn.ownerId then return false end

	if player then
		if match.player ~= player then return false end
		if match.turn.ownerId ~= match.playerId then return false end
	end
	return true
end

function MatchManager.MoveHero(player, heroUid, hexId)
	local hero = match and match.heroes[heroUid]
	if not AuthorizeAction(player, hero) then return end

	-- canMoveHero: não pode ter movido NEM atacado neste turno
	if match.turn.moved[heroUid] or match.turn.attacked[heroUid] then return end
	if type(hexId) ~= "string" or not HexGrid.GetHex(hexId) then return end
	if not HexGrid.IsFree(hexId) then return end

	-- FindPath já garante alcance e caminho livre: substitui o ComputeReach
	local path = HexGrid.FindPath(hero.position, hexId, hero.moveRange)
	if not path then return end

	-- o estado lógico muda na hora; a caminhada é só visual
	HexGrid.ClearOccupant(hero.position)
	hero.position = hexId
	HexGrid.SetOccupant(hexId, hero)
	match.turn.moved[heroUid] = true

	-- onMove dispara pros heróis dos dois lados (igual ao Phaser)
	for _, other in pairs(match.heroes) do
		if other.isAlive then
			TriggerSkills(other, "onMove")
		end
	end

	Broadcast()

	-- caminha casa por casa; busy trava ações concorrentes durante o passeio
	local thisMatch = match
	thisMatch.busy = true
	HeroView.WalkPath(hero, path)
	thisMatch.busy = false

	Broadcast()
end

function MatchManager.AttackHero(player, attackerUid, targetUid)
	local attacker = match and match.heroes[attackerUid]
	local target = match and match.heroes[targetUid]
	if not AuthorizeAction(player, attacker) then return end
	if not target or not target.isAlive then return end
	if target.ownerId == attacker.ownerId then return end
	if match.turn.attacked[attackerUid] then return end

	-- alcance + caminho livre até o alvo
	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange)
	if not reach[target.position] then return end

	-- Taunt: inimigo com Taunt adjacente ao atacante trava o ataque em outro alvo
	if target.ability ~= GameConfig.ABILITIES.TAUNT then
		for _, neighbor in ipairs(HexGrid.GetNeighbors(attacker.position)) do
			local occupant = neighbor.occupiedBy
			if occupant and occupant.isAlive
				and occupant.ownerId ~= attacker.ownerId
				and occupant.ability == GameConfig.ABILITIES.TAUNT then
				Broadcast(("%s está bloqueado por Taunt de %s"):format(attacker.name, occupant.name))
				return
			end
		end
	end

	PerformAttack(attacker, target, false)
	match.turn.attacked[attackerUid] = true

	-- contra-ataque: uma vez por turno, se o alvo sobreviveu e alcança o atacante
	if not match.turn.counterAttack and target.isAlive and attacker.isAlive then
		if HexGrid.Distance(target.position, attacker.position) <= target.attackRange then
			match.turn.counterAttack = true

			local thisMatch = match
			thisMatch.busy = true
			task.wait(COUNTER_ATTACK_DELAY)
			thisMatch.busy = false

			PerformAttack(target, attacker, true)
		end
	end

	if CheckGameOver() then
		Broadcast(ResultMessage())
		return
	end

	Broadcast()
end

-- ===================== DRAFT ALTERNADO (1,2,1,2) =====================
local function AvailableHeroIds()
	local available = {}
	for _, data in ipairs(HeroData.CATALOG) do
		if not match.usedHeroIds[data.id] then
			table.insert(available, data.id)
		end
	end
	return available
end

local function FreeHexesIn(zone)
	local free = {}
	for _, hexId in ipairs(zone) do
		if HexGrid.IsFree(hexId) then
			table.insert(free, hexId)
		end
	end
	return free
end

local function StartBattleIfReady()
	if match.placedCount >= GameConfig.HEROES_PER_PLAYER
		and match.botPlacedCount >= GameConfig.HEROES_PER_PLAYER then
		match.phase = "battle"
		print("MatchManager: draft concluído, combate começou.")
		BeginTurn(match.starterId, 1)
		return true
	end
	return false
end

local function BotPlaceOne()
	if not match or match.phase ~= "placement" then return end

	local available = AvailableHeroIds()
	local free = FreeHexesIn(match.botZone)

	if #available > 0 and #free > 0 then
		local dataId = available[math.random(#available)]
		local hexId = free[math.random(#free)]
		CreateHero(dataId, BOT_ID, hexId)
		match.usedHeroIds[dataId] = true
		match.botPlacedCount += 1
	end

	if StartBattleIfReady() then return end

	match.placementOwner = "player"
	Broadcast()
end

function MatchManager.PlaceHero(player, dataId, hexId)
	if not match or match.player ~= player then return end
	if match.phase ~= "placement" then return end
	if match.placementOwner ~= "player" then return end
	if match.placedCount >= GameConfig.HEROES_PER_PLAYER then return end
	if type(dataId) ~= "number" or type(hexId) ~= "string" then return end
	if not HeroData.GetById(dataId) then return end
	if match.usedHeroIds[dataId] then return end
	if not table.find(match.playerZone, hexId) then return end
	if not HexGrid.IsFree(hexId) then return end

	CreateHero(dataId, match.playerId, hexId)
	match.usedHeroIds[dataId] = true
	match.placedCount += 1

	if StartBattleIfReady() then return end

	match.placementOwner = "bot"
	Broadcast()

	task.delay(GameConfig.BOT_PLACE_DELAY, BotPlaceOne)
end

-- ===================== CICLO DA PARTIDA =====================
function MatchManager.StartMatch(player)
	-- regenera o grid pra zerar ocupação (essencial na revanche)
	HexGrid.Generate()

	local playerZone, botZone = BuildDeployZones()

	match = {
		player = player,
		playerId = tostring(player.UserId),
		starterId = tostring(player.UserId), -- o player sempre começa
		phase = "placement",
		heroes = {},
		playerZone = playerZone,
		botZone = botZone,
		usedHeroIds = {},
		placedCount = 0,
		botPlacedCount = 0,
		placementOwner = "player", -- player escolhe primeiro: 1,2,1,2...
		turn = nil,
		winner = nil,
		busy = false,
	}

	HeroView.ClearAll()
	HeroView.PlayGlobalSound("MatchStart")

	Broadcast()
	print(("MatchManager: draft iniciado. Zona do player: %d hexes."):format(#playerZone))
end

function MatchManager.Replay(player)
	if not match or match.player ~= player then return end
	if match.phase ~= "finished" then return end
	MatchManager.StartMatch(player)
end

function MatchManager.LeaveMatch(player)
	if not match or match.player ~= player then return end

	HeroView.ClearAll()

	local board = Workspace:FindFirstChild("Board")
	if board then board:Destroy() end

	MatchUpdate:FireClient(player, { phase = "lobby" })
	match = nil
end

function MatchManager.GetMatch()
	return match
end

return MatchManager
